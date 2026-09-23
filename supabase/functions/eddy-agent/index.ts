import 'jsr:@supabase/functions-js/edge-runtime.d.ts';
import Anthropic from 'npm:@anthropic-ai/sdk@0.120.0';

import { camposCorrompidos } from '../whatsapp-agent/resposta-limpa.ts';

// eddy-agent — o agente que conversa com o DONO do salao, nao com as clientes.
//
// ONDE ELE ENTRA NA CORRENTE: exatamente a mesma do agente das clientes.
//   whatsapp-webhook -> inbox_events -> projecao -> crm_messages -> [aqui]
//   -> outbox_messages -> whatsapp-sender -> Cloud API
//
// O QUE MUDA E SO O LADO DA CONVERSA. O canal do Eddy tem `purpose = 'DONO'`, e
// e isso que separa as duas filas: `list_owner_conversations_awaiting_eddy` so
// enxerga canal de dono, e a fila do agente das clientes so enxerga canal de
// cliente. Um dono nunca pode ser atendido como se fosse cliente, e vice-versa.
//
// O QUE ELE PODE ESCREVER, E POR QUE NAO PODE MAIS QUE ISSO. Ele escreve pelo
// mesmo braco que a tela de onboarding ja usa desde a etapa 5:
// `app.onboarding_record_answer`, que passa pela lista branca de quatro
// destinos e pelo limite de confianca de 0,75. O Eddy nao ganhou poder novo
// sobre o banco -- ganhou uma porta de entrada nova. Preco entra no RASCUNHO,
// que nao vale para ninguem ate o dono publicar, e toda escrita guarda o valor
// anterior para o desfazer continuar sendo um clique.
//
// A TRAVA QUE VEM ANTES DE TUDO: numero desconhecido nao configura nada. Se o
// telefone de quem escreveu nao estiver em `app.owner_whatsapp`, o Eddy nao
// sabe de qual salao se trata -- e escrever no cadastro do salao errado e o
// pior erro que ele poderia cometer. Nesse caso ele passa para uma pessoa.

const MODELO = 'claude-sonnet-5';
const ESFORCO = 'low' as const;
const CACHE_TTL = '1h' as const;
const MAX_VOLTAS = 4;

type Aguardando = {
  conversation_id: string;
  tenant_id: string;
  last_inbound_message_id: string;
  waiting_seconds: number;
};

type Decisao = {
  action: 'REPLY' | 'HANDOFF';
  messages: string[];
  reason: string;
};

type Pendencia = { chave: string; modulo: string; pergunta: string; contexto: string };

type Habilidade = { nome: string; quemFaz: string[] };

const FERRAMENTAS: Anthropic.Tool[] = [
  {
    name: 'anotar',
    description:
      'Guarda no cadastro do salão uma resposta que o dono acabou de dar. Use a chave exata que veio na lista de pendências: você nunca inventa uma chave.',
    input_schema: {
      type: 'object',
      properties: {
        chave: { type: 'string', description: 'A chave da pendência, como veio na lista.' },
        modulo: { type: 'string', description: 'O módulo da pendência, como veio na lista.' },
        entendido: {
          type: 'string',
          description:
            'Uma frase curta em português que o dono lê para conferir: "Escova custa R$ 60".',
        },
        valorTexto: {
          type: 'string',
          description: 'Para regra ou definição, escrita COM AS PALAVRAS DELE.',
        },
        valorNumero: {
          type: 'number',
          description: 'Para preço, em reais, sem símbolo: 60, não "R$ 60,00".',
        },
        confianca: {
          type: 'number',
          description:
            '0.9 quando ele disse com todas as letras, 0.5 quando você está interpretando, 0.3 quando é chute. Abaixo de 0,75 o sistema não grava, só mostra para ele conferir.',
        },
      },
      required: ['chave', 'modulo', 'entendido', 'confianca'],
      additionalProperties: false,
    },
  },
  {
    name: 'criar_servico',
    description:
      'Cria no rascunho um serviço que ainda não existe no catálogo dele. A habilidade tem que ser uma da lista que você recebeu: você nunca inventa uma.',
    input_schema: {
      type: 'object',
      properties: {
        nome: { type: 'string', description: 'O nome do serviço, como ele chamou.' },
        habilidade: {
          type: 'string',
          description:
            'Qual habilidade da equipe faz. EXATAMENTE como veio na lista de habilidades do salão.',
        },
        duracaoMinutos: {
          type: 'number',
          description: 'Quanto tempo leva, em minutos. Ou ele disse, ou você pergunta antes.',
        },
        precoReais: {
          type: 'number',
          description: 'Quanto custa, em reais, sem símbolo. Deixe vazio se ele ainda não disse.',
        },
        confianca: {
          type: 'number',
          description:
            'Mesma régua do `anotar`. Abaixo de 0,75 o serviço NÃO é criado: pergunte a ele antes.',
        },
      },
      required: ['nome', 'habilidade', 'duracaoMinutos', 'confianca'],
      additionalProperties: false,
    },
  },
  {
    name: 'definir_preco',
    description:
      'Grava o preço de um serviço. É POR AQUI que preço se grava, nunca pelo `anotar`. Use ehPiso quando o dono disser "a partir de": sem isso a atendente vai cravar o valor como se fosse final.',
    input_schema: {
      type: 'object',
      properties: {
        servicoId: {
          type: 'string',
          description: 'O id que veio depois de SERVICO_PRECO: na lista de pendências.',
        },
        precoReais: { type: 'number', description: 'Em reais, sem símbolo: 160, não "R$ 160,00".' },
        ehPiso: {
          type: 'boolean',
          description:
            'true quando ele disse "a partir de", "começa em", "varia". false quando é valor fechado. Na dúvida, pergunte a ele; não chute.',
        },
        confianca: { type: 'number', description: 'Mesma régua do `anotar`. Abaixo de 0,75 não grava.' },
      },
      required: ['servicoId', 'precoReais', 'ehPiso', 'confianca'],
      additionalProperties: false,
    },
  },
  {
    name: 'criar_variacao',
    description:
      'Quando o mesmo serviço tem mais de um preço (por tamanho, por tipo, por parte do cabelo), cada preço vira uma variação. Uma chamada por preço. Sem isto só o primeiro valor sobrevive e os outros somem.',
    input_schema: {
      type: 'object',
      properties: {
        servicoId: { type: 'string', description: 'O id do serviço, como veio na pendência.' },
        nome: {
          type: 'string',
          description: 'Como o dono chamou essa variação: "raiz", "raiz com muito cabelo", "cabelo todo".',
        },
        precoReais: { type: 'number', description: 'O preço desta variação, em reais.' },
        confianca: { type: 'number', description: 'Abaixo de 0,75 não grava.' },
      },
      required: ['servicoId', 'nome', 'precoReais', 'confianca'],
      additionalProperties: false,
    },
  },
  {
    name: 'desativar_servico',
    description:
      'Tira do catálogo um serviço que o salão não faz. Só depois de ele confirmar. O serviço não é apagado, fica inativo.',
    input_schema: {
      type: 'object',
      properties: {
        nome: { type: 'string', description: 'O nome do serviço, exatamente como está no catálogo.' },
      },
      required: ['nome'],
      additionalProperties: false,
    },
  },
  // AS QUATRO PERGUNTAS QUE ELE FAZIA SEM TER ONDE ESCREVER A RESPOSTA.
  //
  // 23/09/2026: `owner_setup_state` devolvia cinco pendências e ele só sabia
  // gravar a última. Perguntava o nome do salão, a dona respondia, e ele dizia
  // "anotei" — mentindo, porque não havia ferramenta. Na mensagem seguinte a
  // pergunta voltava. Estas quatro fecham o ciclo.
  {
    name: 'registrar_identidade',
    description:
      'Grava o nome do salão e o endereço. É a primeira pendência de um salão novo. Endereço pela metade não serve: a cliente sai para a rua com ele — ou ele dita inteiro, ou você pergunta de novo.',
    input_schema: {
      type: 'object',
      properties: {
        nome: { type: 'string', description: 'O nome do salão, como ele chamou.' },
        endereco: {
          type: 'string',
          description:
            'O endereço completo: rua, número, bairro e cidade. Deixe vazio se ele ainda não disse tudo.',
        },
        confianca: {
          type: 'number',
          description: 'Mesma régua do `anotar`. Abaixo de 0,75 não grave: pergunte.',
        },
      },
      required: ['nome', 'confianca'],
      additionalProperties: false,
    },
  },
  {
    name: 'criar_membro_equipe',
    description:
      'Cadastra uma pessoa que atende no salão. Uma chamada por pessoa. Num salão de uma pessoa só, a dona também entra aqui — ela atende.',
    input_schema: {
      type: 'object',
      properties: {
        nome: { type: 'string', description: 'O nome da pessoa, como ele falou.' },
        tipo: {
          type: 'string',
          enum: ['PROFESSIONAL', 'ASSISTANT'],
          description: 'PROFESSIONAL para quem executa o serviço, ASSISTANT para quem auxilia.',
        },
        confianca: { type: 'number', description: 'Mesma régua do `anotar`.' },
      },
      required: ['nome', 'confianca'],
      additionalProperties: false,
    },
  },
  {
    name: 'criar_habilidade',
    description:
      'Cria uma habilidade da equipe (corte, coloração, mechas...) e liga a quem a faz. Use quando o serviço que ele citou exige uma habilidade que ainda não existe. A equipe tem que existir antes: sem ninguém cadastrado, esta ferramenta recusa e te devolve a pergunta certa.',
    input_schema: {
      type: 'object',
      properties: {
        nome: { type: 'string', description: 'O nome da habilidade, como ele falou.' },
        quemFaz: {
          type: 'array',
          items: { type: 'string' },
          description:
            'Os nomes de quem faz, como já estão cadastrados. Deixe vazio para valer para a equipe inteira — que é o certo no salão de uma pessoa só.',
        },
        confianca: { type: 'number', description: 'Mesma régua do `anotar`.' },
      },
      required: ['nome', 'confianca'],
      additionalProperties: false,
    },
  },
  {
    name: 'definir_horario_funcionamento',
    description:
      'Define os dias e horários do salão. Manda a SEMANA INTEIRA de uma vez: esta ferramenta substitui o que havia, não acrescenta. Dia: 0 é domingo, 6 é sábado. Só os dias em que abre.',
    input_schema: {
      type: 'object',
      properties: {
        dias: {
          type: 'array',
          description: 'Um item por dia em que o salão abre.',
          items: {
            type: 'object',
            properties: {
              dia: { type: 'number', description: '0 domingo, 1 segunda ... 6 sábado.' },
              abre: { type: 'string', description: 'Hora de abrir, formato HH:MM.' },
              fecha: { type: 'string', description: 'Hora de fechar, formato HH:MM.' },
            },
            required: ['dia', 'abre', 'fecha'],
            additionalProperties: false,
          },
        },
        confianca: { type: 'number', description: 'Mesma régua do `anotar`.' },
      },
      required: ['dias', 'confianca'],
      additionalProperties: false,
    },
  },
  {
    name: 'resumo',
    description:
      'Mostra o que mudou no rascunho e o que ainda falta para poder publicar. Chame antes de falar em publicar: você não pode publicar sem ter lido isto nesta conversa.',
    input_schema: { type: 'object', properties: {}, additionalProperties: false },
  },
  {
    name: 'publicar',
    description:
      'Põe no ar o que está no rascunho. Só depois de você ter chamado `resumo`, contado a ele o que mudou, e ele ter confirmado NESTA conversa.',
    input_schema: {
      type: 'object',
      properties: {
        confirmacaoDoDono: {
          type: 'string',
          description:
            'As palavras dele autorizando, copiadas como ele escreveu. Não invente e não parafraseie.',
        },
      },
      required: ['confirmacaoDoDono'],
      additionalProperties: false,
    },
  },
  {
    name: 'atender',
    description: 'Registra o que fazer nesta conversa. Sempre a última chamada.',
    strict: true,
    input_schema: {
      type: 'object',
      properties: {
        action: {
          type: 'string',
          enum: ['REPLY', 'HANDOFF'],
          description:
            'REPLY: você vai falar com o dono agora. HANDOFF: uma pessoa da EDDigital precisa assumir.',
        },
        messages: {
          type: 'array',
          items: { type: 'string' },
          description: 'As mensagens para o dono, uma por balão. Vazio quando for HANDOFF.',
        },
        reason: { type: 'string', description: 'Uma frase para o painel. Nunca é enviada.' },
      },
      required: ['action', 'messages', 'reason'],
      additionalProperties: false,
    },
  },
];

function json(status: number, body: unknown): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'content-type': 'application/json; charset=utf-8' },
  });
}

async function rpc(url: string, key: string, fn: string, args: unknown): Promise<unknown> {
  const r = await fetch(`${url}/rest/v1/rpc/${fn}`, {
    method: 'POST',
    headers: { apikey: key, Authorization: `Bearer ${key}`, 'content-type': 'application/json' },
    body: JSON.stringify(args),
  });
  if (!r.ok) throw new Error(`RPC ${fn}: ${r.status} ${await r.text()}`);
  return await r.json();
}

async function autorizado(req: Request, url: string, key: string): Promise<boolean> {
  const token = req.headers.get('x-worker-token');
  if (!token) return false;
  try {
    return (await rpc(url, key, 'verify_worker_token', { p_token: token })) === true;
  } catch {
    return false;
  }
}

Deno.serve(async (req: Request) => {
  const supabaseUrl = Deno.env.get('SUPABASE_URL');
  const serviceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
  const anthropicKey = Deno.env.get('ANTHROPIC_API_KEY');

  if (!supabaseUrl || !serviceKey) return json(500, { ok: false, reason: 'SUPABASE_ENV_MISSING' });
  if (!(await autorizado(req, supabaseUrl, serviceKey))) {
    return json(401, { ok: false, reason: 'WORKER_TOKEN_INVALID' });
  }
  if (!anthropicKey) return json(500, { ok: false, reason: 'ANTHROPIC_API_KEY_MISSING' });

  let corpo: { limit?: number; dryRun?: boolean; quietSeconds?: number } = {};
  if (req.method === 'POST') {
    try {
      corpo = (await req.json()) ?? {};
    } catch {
      corpo = {};
    }
  }
  const limite = Math.min(Math.max(corpo.limit ?? 5, 1), 20);
  const dryRun = corpo.dryRun === true;
  const quietSeconds = typeof corpo.quietSeconds === 'number' ? corpo.quietSeconds : 25;

  let fila: Aguardando[];
  try {
    fila = (await rpc(supabaseUrl, serviceKey, 'list_owner_conversations_awaiting_eddy', {
      p_limit: limite,
      p_quiet_seconds: quietSeconds,
    })) as Aguardando[];
  } catch (erro) {
    return json(500, { ok: false, reason: 'QUEUE_READ_FAILED', detail: String(erro) });
  }

  if (!Array.isArray(fila) || fila.length === 0) {
    return json(200, {
      ok: true,
      aguardando: 0,
      respondidas: 0,
      anotadas: 0,
      criados: 0,
      publicacoes: 0,
      falhas: 0,
    });
  }

  // O prompt do Eddy, uma vez por lote e byte a byte igual entre as chamadas,
  // para o cache da API valer. `DONO` e o que separa o prompt dele do prompt do
  // agente das clientes -- ele nao herda uma linha das regras de atendimento.
  let regras: string;
  try {
    regras = ((await rpc(supabaseUrl, serviceKey, 'agent_prompt', { p_agent: 'DONO' })) as string) ?? '';
  } catch (erro) {
    return json(500, { ok: false, reason: 'PROMPT_READ_FAILED', detail: String(erro) });
  }
  if (regras.trim().length < 300) {
    return json(500, { ok: false, reason: 'PROMPT_VAZIO', tamanho: regras.length });
  }

  const anthropic = new Anthropic({ apiKey: anthropicKey });
  const resultados: unknown[] = [];
  let respondidas = 0;
  let anotadas = 0;
  let criados = 0;
  let publicacoes = 0;
  let falhas = 0;

  for (const item of fila) {
    try {
      const contexto = (await rpc(supabaseUrl, serviceKey, 'build_owner_context', {
        p_conversation_id: item.conversation_id,
        p_history_limit: 20,
      })) as {
        ok?: boolean;
        reason?: string;
        dono?: { conhecido?: boolean; tenantId?: string; nome?: string; negocio?: string };
        negocio?: unknown;
        history?: unknown;
      };

      if (!contexto?.ok) throw new Error(`contexto indisponivel: ${contexto?.reason ?? '?'}`);

      // NUMERO DESCONHECIDO NAO CONFIGURA NADA.
      //
      // Sem saber de qual salao e o dono, qualquer escrita cairia no cadastro
      // de outra pessoa. Aqui o Eddy nao arrisca: passa para uma pessoa.
      if (!contexto.dono?.conhecido || !contexto.dono.tenantId) {
        await rpc(supabaseUrl, serviceKey, 'mark_agent_decision', {
          p_tenant_id: item.tenant_id,
          p_message_id: item.last_inbound_message_id,
          p_decision: 'HANDOFF',
          p_reason: 'Numero nao cadastrado como dono de nenhum salao.',
        });
        resultados.push({ conversationId: item.conversation_id, action: 'HANDOFF', motivo: 'DONO_DESCONHECIDO' });
        continue;
      }

      const tenantId = contexto.dono.tenantId;
      const pendencias = (await rpc(supabaseUrl, serviceKey, 'onboarding_pendencies', {
        p_tenant_id: tenantId,
      })) as Pendencia[];

      const pauta = (Array.isArray(pendencias) ? pendencias : [])
        .map((p) => `- [${p.chave}] (${p.modulo}) ${p.pergunta} — hoje: ${p.contexto}`)
        .join('\n');

      // A lista fechada de habilidades. Sem ela na mesa, `criar_servico` vira
      // adivinhacao: o bloco EDDY_CRIAR_SERVICO manda escolher da lista, e a
      // lista tem que estar aqui para ele poder obedecer.
      let habilidades: Habilidade[] = [];
      try {
        habilidades = (await rpc(supabaseUrl, serviceKey, 'onboarding_habilidades', {
          p_tenant_id: tenantId,
        })) as Habilidade[];
      } catch {
        habilidades = [];
      }
      const listaHabilidades = (Array.isArray(habilidades) ? habilidades : [])
        .map((h) => `- ${h.nome} (faz: ${(h.quemFaz ?? []).join(', ') || 'ninguém ativo'})`)
        .join('\n');

      const mensagens: Anthropic.MessageParam[] = [
        {
          role: 'user',
          content:
            'Esta conversa com o dono (JSON). A última mensagem do histórico é a que está esperando resposta.\n\n' +
            JSON.stringify({ dono: contexto.dono, negocio: contexto.negocio, history: contexto.history }) +
            '\n\nO QUE AINDA FALTA NO CADASTRO DELE (a chave entre colchetes é obrigatória em `anotar`, e você nunca inventa uma):\n' +
            (pauta || '(nada — o cadastro está completo)') +
            '\n\nAS HABILIDADES QUE ESTE SALÃO TEM (é desta lista que você escolhe em `criar_servico`, escrita exatamente assim; você nunca inventa uma):\n' +
            (listaHabilidades || '(nenhuma habilidade com gente ativa — não dá para criar serviço agora)'),
        },
      ];

      let sessaoId: string | null = null;
      let turnoId: string | null = null;
      // A trava do publicar, e ela e tecnica, nao so instrucao no prompt: sem
      // ter chamado `resumo` nesta conversa, `publicar` e recusado aqui mesmo,
      // antes de chegar ao banco. Prompt convence; codigo garante.
      let viuOResumo = false;
      // QUANTAS GRAVACOES EXISTIAM ANTES DESTE TURNO.
      //
      // 23/09/2026, primeira conversa real num salao zerado. A dona mandou o
      // nome e o endereco do salao. O Eddy respondeu "Anotei: Eduarda Defiume
      // Beauty, na Rua Rui Barbosa, 323, Centro, Jardinopolis" -- e no banco
      // `units.name` continuava "Unidade unica" e `address_json` continuava
      // vazio. Ele disse que anotou duas vezes e nao chamou ferramenta nenhuma.
      //
      // POR QUE `tool_choice: 'any'` NAO IMPEDE ISSO: `atender` tambem e uma
      // ferramenta. O modelo cumpre a obrigacao de chamar alguma coisa
      // chamando so o `atender` com o texto pronto, e a gravacao nunca
      // acontece. A obrigacao e de chamar UMA ferramenta, nao a CERTA.
      //
      // Entao a diferenca entre o antes e o depois e a unica prova de que
      // alguma coisa foi escrita de verdade.
      const criadosAoEntrar = criados;
      let jaCobreiAMentira = false;
      let decisao: Decisao | null = null;
      let motivoFalha: string | null = null;
      const uso = { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, voltas: 0 };
      let jaCobreiACorrupcao = false;

      for (let volta = 0; volta < MAX_VOLTAS; volta++) {
        const resposta = await anthropic.messages.create({
          model: MODELO,
          max_tokens: 2000,
          thinking: { type: 'adaptive' },
          output_config: { effort: ESFORCO },
          system: [{ type: 'text', text: regras, cache_control: { type: 'ephemeral', ttl: CACHE_TTL } }],
          tools: FERRAMENTAS,
          tool_choice: { type: 'any' },
          messages: mensagens,
        });

        const u = (resposta.usage ?? {}) as Record<string, number>;
        uso.voltas += 1;
        uso.input += u.input_tokens ?? 0;
        uso.output += u.output_tokens ?? 0;
        uso.cacheRead += u.cache_read_input_tokens ?? 0;
        uso.cacheWrite += u.cache_creation_input_tokens ?? 0;

        const chamadas = resposta.content.filter(
          (b): b is Anthropic.ToolUseBlock => b.type === 'tool_use'
        );
        if (chamadas.length === 0) {
          motivoFalha = 'NO_TOOL_CALL';
          break;
        }

        const desfecho = chamadas.find((c) => c.name === 'atender');
        if (desfecho) {
          const escolha = desfecho.input as Decisao;
          const sujos = camposCorrompidos(escolha);
          if (sujos.length > 0 && !jaCobreiACorrupcao && volta < MAX_VOLTAS - 1) {
            jaCobreiACorrupcao = true;
            mensagens.push({ role: 'assistant', content: resposta.content });
            mensagens.push({
              role: 'user',
              content: chamadas.map((c) => ({
                type: 'tool_result' as const,
                tool_use_id: c.id,
                content:
                  'NAO ENVIEI: a chamada veio com marcacao de ferramenta dentro do texto (' +
                  sujos.join(', ') +
                  '). Cada campo tem que ter SO o texto em portugues. Chame atender de novo, limpo.',
              })),
            });
            continue;
          }

          // A TRAVA DO "ANOTEI".
          //
          // Se o texto que ele quer mandar afirma que gravou, e nenhuma
          // ferramenta de escrita subiu o contador neste turno, a mensagem NAO
          // sai. Ele recebe de volta o proprio texto e tem que chamar a
          // ferramenta de verdade antes de repetir a frase.
          //
          // Cobro uma vez so: se ele insistir, deixo passar e o desencontro
          // fica no historico para a gente ver -- travar em laco calaria o
          // agente, que e um problema pior que uma frase errada.
          const prometeuTerGravado =
            /\b(anotei|anotado|gravei|gravado|registrei|registrado|cadastrei|cadastrado|salvei|guardei|atualizei)\b/i;
          const falaQueGravou = (escolha.messages ?? []).some((m) =>
            prometeuTerGravado.test(String(m ?? ''))
          );

          if (
            falaQueGravou &&
            criados === criadosAoEntrar &&
            !jaCobreiAMentira &&
            volta < MAX_VOLTAS - 1
          ) {
            jaCobreiAMentira = true;
            mensagens.push({ role: 'assistant', content: resposta.content });
            mensagens.push({
              role: 'user',
              content: chamadas.map((c) => ({
                type: 'tool_result' as const,
                tool_use_id: c.id,
                content:
                  'NAO ENVIEI. Voce escreveu que anotou, e nao chamou nenhuma ferramenta que grava ' +
                  'neste turno. Dizer "anotei" sem ter gravado e mentir para o dono: ele vai embora ' +
                  'achando que esta feito, e na proxima conversa a mesma pergunta volta. ' +
                  'Escolha: chame a ferramenta certa agora (nome e endereco do salao sao ' +
                  '`registrar_identidade`, pessoa e `criar_membro_equipe`, dias e horarios sao ' +
                  '`definir_horario_funcionamento`, habilidade e `criar_habilidade`, servico e ' +
                  '`criar_servico`, preco e `definir_preco`, regra e `anotar`) -- ou, se faltar ' +
                  'informacao, chame `atender` de novo e apenas PERGUNTE, sem dizer que anotou.',
              })),
            });
            continue;
          }

          decisao = escolha;
          break;
        }

        mensagens.push({ role: 'assistant', content: resposta.content });
        const devolucoes: Anthropic.ToolResultBlockParam[] = [];

        for (const chamada of chamadas) {
          let texto: string;
          if (chamada.name === 'anotar') {
            const args = chamada.input as {
              chave: string;
              modulo: string;
              entendido: string;
              valorTexto?: string;
              valorNumero?: number;
              confianca: number;
            };
            // PRECO NAO PASSA MAIS POR AQUI.
            //
            // `anotar` grava um numero so. Foi assim que a Coloracao, que tem
            // tres precos, virou R$ 160 e os outros dois sumiram -- e o Eddy
            // disse ao dono que tinha anotado os tres. Redirecionar no codigo,
            // e nao so no prompt, porque este e o caminho que ele ja conhece.
            if (args.chave?.startsWith('SERVICO_PRECO:')) {
              devolucoes.push({
                type: 'tool_result',
                tool_use_id: chamada.id,
                content:
                  'NAO gravei. Preco de servico nao se grava pelo `anotar`. Use `definir_preco` ' +
                  '(e diga ehPiso=true se ele falou "a partir de"). Se o servico tiver mais de um ' +
                  'preco, cada um vira uma chamada de `criar_variacao`.',
              });
              continue;
            }
            try {
              // A sessao e o turno sao os mesmos da tela de onboarding: o que o
              // Eddy escreve aparece no historico do dono e pode ser desfeito
              // la, sem uma segunda verdade.
              sessaoId ??= (await rpc(supabaseUrl, serviceKey, 'eddy_sessao', {
                p_tenant_id: tenantId,
              })) as string;
              turnoId ??= (await rpc(supabaseUrl, serviceKey, 'eddy_turno', {
                p_tenant_id: tenantId,
                p_session_id: sessaoId,
                p_quem: 'DONO',
                p_texto: null,
              })) as string;

              const gravado = (await rpc(supabaseUrl, serviceKey, 'onboarding_record_answer', {
                p_session_id: sessaoId,
                p_turn_id: turnoId,
                p_key: args.chave,
                p_modulo: args.modulo,
                p_entendido: args.entendido,
                p_valor_texto: args.valorTexto ?? null,
                p_valor_numero: typeof args.valorNumero === 'number' ? args.valorNumero : null,
                p_confidence: args.confianca,
              })) as { status?: string; motivo?: string } | null;

              const estado = gravado?.status ?? 'DESCONHECIDO';
              anotadas += estado === 'APLICADO' ? 1 : 0;
              texto =
                estado === 'APLICADO'
                  ? 'Gravado no cadastro dele.'
                  : `Nao gravei: ${gravado?.motivo ?? estado}. Confirme com ele antes de insistir.`;
            } catch (erro) {
              texto = `Nao deu para gravar agora (${String(erro).slice(0, 120)}). Siga a conversa.`;
            }
          } else if (chamada.name === 'criar_servico') {
            const args = chamada.input as {
              nome: string;
              habilidade: string;
              duracaoMinutos: number;
              precoReais?: number;
              confianca: number;
            };
            // Mesma regua do `anotar`: abaixo de 0,75 nao escreve. Um servico
            // criado por engano fica no catalogo dele e a atendente oferece.
            if (typeof args.confianca !== 'number' || args.confianca < 0.75) {
              texto =
                'NAO criei: a sua confianca ficou abaixo de 0,75. Pergunte a ele e so crie quando ele tiver dito com todas as letras.';
            } else {
              try {
                const r = (await rpc(supabaseUrl, serviceKey, 'onboarding_criar_servico', {
                  p_tenant_id: tenantId,
                  p_nome: args.nome,
                  p_habilidade: args.habilidade,
                  p_duracao_min: Math.round(args.duracaoMinutos),
                  p_preco_reais: typeof args.precoReais === 'number' ? args.precoReais : null,
                })) as {
                  ok?: boolean;
                  reason?: string;
                  servico?: string;
                  habilidade?: string;
                  habilidades?: Habilidade[];
                } | null;

                if (r?.ok) {
                  criados += 1;
                  texto =
                    `Criei "${r.servico}" no rascunho, com a habilidade ${r.habilidade}. ` +
                    'Nenhuma cliente ve isso ate ele publicar. Confirme com ele antes de criar o proximo.';
                } else if (r?.reason === 'HABILIDADE_NAO_EXISTE_NESTE_SALAO') {
                  const nomes = (r.habilidades ?? []).map((h) => h.nome).join(', ');
                  texto =
                    `NAO criei: "${args.habilidade}" nao e uma habilidade deste salao. ` +
                    `As que existem sao: ${nomes}. Pergunte a ele qual delas corresponde -- nao escolha a mais parecida.`;
                } else if (r?.reason === 'SERVICO_JA_EXISTE') {
                  texto = `NAO criei: ja existe um servico chamado "${args.nome}" no cadastro dele. Confirme se ele quer mudar o que ja existe.`;
                } else {
                  texto = `NAO criei: ${r?.reason ?? 'motivo desconhecido'}. Confirme com ele antes de insistir.`;
                }
              } catch (erro) {
                texto = `Nao deu para criar agora (${String(erro).slice(0, 120)}). Siga a conversa.`;
              }
            }
          } else if (chamada.name === 'definir_preco') {
            const args = chamada.input as {
              servicoId: string;
              precoReais: number;
              ehPiso: boolean;
              confianca: number;
            };
            if (typeof args.confianca !== 'number' || args.confianca < 0.75) {
              texto = 'NAO gravei: confianca abaixo de 0,75. Pergunte o valor a ele de novo.';
            } else {
              try {
                const r = (await rpc(supabaseUrl, serviceKey, 'onboarding_definir_preco', {
                  p_tenant_id: tenantId,
                  p_service_id: args.servicoId,
                  p_preco_reais: args.precoReais,
                  p_e_piso: args.ehPiso === true,
                })) as { ok?: boolean; reason?: string; servico?: string; ehPiso?: boolean } | null;
                if (r?.ok) {
                  anotadas += 1;
                  texto = r.ehPiso
                    ? `Gravado: ${r.servico} a partir de R$ ${args.precoReais}. Confirme com ele que e "a partir de" mesmo.`
                    : `Gravado: ${r.servico} R$ ${args.precoReais}, valor fechado.`;
                } else {
                  texto = `NAO gravei: ${r?.reason ?? 'motivo desconhecido'}.`;
                }
              } catch (erro) {
                texto = `Nao deu para gravar o preco agora (${String(erro).slice(0, 120)}).`;
              }
            }
          } else if (chamada.name === 'criar_variacao') {
            const args = chamada.input as {
              servicoId: string;
              nome: string;
              precoReais: number;
              confianca: number;
            };
            if (typeof args.confianca !== 'number' || args.confianca < 0.75) {
              texto = 'NAO gravei: confianca abaixo de 0,75. Confirme com ele antes.';
            } else {
              try {
                const r = (await rpc(supabaseUrl, serviceKey, 'onboarding_criar_variacao', {
                  p_tenant_id: tenantId,
                  p_service_id: args.servicoId,
                  p_nome: args.nome,
                  p_preco_reais: args.precoReais,
                })) as { ok?: boolean; reason?: string; nome?: string } | null;
                if (r?.ok) {
                  anotadas += 1;
                  texto = `Gravado: variacao "${r.nome}" R$ ${args.precoReais}. Se houver mais precos, chame de novo, um por vez.`;
                } else if (r?.reason === 'VARIACAO_JA_EXISTE') {
                  texto = `Ja existe uma variacao "${args.nome}" neste servico. Confirme com ele se e outra coisa ou se e a mesma.`;
                } else {
                  texto = `NAO gravei: ${r?.reason ?? 'motivo desconhecido'}.`;
                }
              } catch (erro) {
                texto = `Nao deu para gravar a variacao agora (${String(erro).slice(0, 120)}).`;
              }
            }
          } else if (chamada.name === 'desativar_servico') {
            const args = chamada.input as { nome: string };
            try {
              const r = (await rpc(supabaseUrl, serviceKey, 'onboarding_desativar_servico_por_nome', {
                p_tenant_id: tenantId,
                p_nome: args.nome,
              })) as { ok?: boolean; reason?: string; servico?: string; procurado?: string } | null;
              if (r?.ok) {
                texto = `Tirei "${r.servico}" do catalogo. Ele continua salvo, so nao aparece mais. Confirme com ele antes do proximo.`;
              } else if (r?.reason === 'SERVICO_NAO_ENCONTRADO') {
                texto = `Nao achei nenhum servico chamado "${r.procurado}" no catalogo dele. Confirme o nome com ele.`;
              } else if (r?.reason === 'NOME_AMBIGUO') {
                texto = `Tem mais de um servico com o nome "${r.procurado}". Pergunte a ele qual e.`;
              } else {
                texto = `NAO tirei: ${r?.reason ?? 'motivo desconhecido'}.`;
              }
            } catch (erro) {
              texto = `Nao deu para tirar do catalogo agora (${String(erro).slice(0, 120)}).`;
            }
          } else if (chamada.name === 'registrar_identidade') {
            const args = chamada.input as { nome: string; endereco?: string; confianca: number };
            if (typeof args.confianca !== 'number' || args.confianca < 0.75) {
              texto = 'NAO gravei: confianca abaixo de 0,75. Pergunte o nome e o endereco de novo.';
            } else {
              try {
                const r = (await rpc(supabaseUrl, serviceKey, 'onboarding_registrar_identidade', {
                  p_tenant_id: tenantId,
                  p_nome: args.nome,
                  p_endereco: typeof args.endereco === 'string' ? args.endereco : null,
                })) as { ok?: boolean; reason?: string; salao?: string; endereco?: string } | null;

                if (r?.ok) {
                  criados += 1;
                  texto = r.endereco
                    ? `Gravei: salao "${r.salao}", endereco "${r.endereco}".`
                    : `Gravei o nome "${r.salao}". Falta o endereco -- pergunte a rua, numero, bairro e cidade.`;
                } else if (r?.reason === 'ENDERECO_CURTO_DEMAIS') {
                  texto =
                    'NAO gravei o endereco: veio curto demais. Cliente sai para a rua com ele. Peca rua, numero, bairro e cidade.';
                } else {
                  texto = `NAO gravei: ${r?.reason ?? 'motivo desconhecido'}.`;
                }
              } catch (erro) {
                texto = `Nao deu para gravar agora (${String(erro).slice(0, 120)}). Siga a conversa.`;
              }
            }
          } else if (chamada.name === 'criar_membro_equipe') {
            const args = chamada.input as { nome: string; tipo?: string; confianca: number };
            if (typeof args.confianca !== 'number' || args.confianca < 0.75) {
              texto = 'NAO cadastrei: confianca abaixo de 0,75. Confirme o nome com ele.';
            } else {
              try {
                const r = (await rpc(supabaseUrl, serviceKey, 'onboarding_criar_membro_equipe', {
                  p_tenant_id: tenantId,
                  p_nome: args.nome,
                  p_tipo: args.tipo === 'ASSISTANT' ? 'ASSISTANT' : 'PROFESSIONAL',
                })) as { ok?: boolean; reason?: string; pessoa?: string } | null;

                if (r?.ok) {
                  criados += 1;
                  texto = `Cadastrei ${r.pessoa} na equipe. Se tiver mais gente, me fale um por vez.`;
                } else if (r?.reason === 'PESSOA_JA_EXISTE') {
                  texto = `NAO cadastrei: ${args.nome} ja esta na equipe.`;
                } else {
                  texto = `NAO cadastrei: ${r?.reason ?? 'motivo desconhecido'}.`;
                }
              } catch (erro) {
                texto = `Nao deu para cadastrar agora (${String(erro).slice(0, 120)}). Siga a conversa.`;
              }
            }
          } else if (chamada.name === 'criar_habilidade') {
            const args = chamada.input as { nome: string; quemFaz?: string[]; confianca: number };
            if (typeof args.confianca !== 'number' || args.confianca < 0.75) {
              texto = 'NAO criei: confianca abaixo de 0,75. Confirme com ele.';
            } else {
              try {
                const r = (await rpc(supabaseUrl, serviceKey, 'onboarding_criar_habilidade', {
                  p_tenant_id: tenantId,
                  p_nome: args.nome,
                  p_quem_faz: Array.isArray(args.quemFaz) && args.quemFaz.length ? args.quemFaz : null,
                })) as {
                  ok?: boolean;
                  reason?: string;
                  habilidade?: string;
                  quemFaz?: string[];
                  pergunteAntes?: string;
                  naoEncontrados?: string[];
                } | null;

                if (r?.ok) {
                  criados += 1;
                  texto =
                    `Criei a habilidade "${r.habilidade}", feita por ${(r.quemFaz ?? []).join(', ')}. ` +
                    'Agora da para criar servico que use ela.';
                } else if (r?.reason === 'SALAO_SEM_EQUIPE') {
                  // A recusa que ensina a ordem: equipe -> habilidade -> servico.
                  texto =
                    'NAO criei: nao ha ninguem cadastrado no salao ainda, e habilidade sem quem a faca ' +
                    `nao serve para nada. Pergunte antes: "${r.pergunteAntes}"`;
                } else if (r?.reason === 'NINGUEM_RECONHECIDO') {
                  texto =
                    `NAO criei: nao achei ${(r.naoEncontrados ?? []).join(', ')} na equipe. ` +
                    'Cadastre a pessoa primeiro com `criar_membro_equipe`.';
                } else {
                  texto = `NAO criei: ${r?.reason ?? 'motivo desconhecido'}.`;
                }
              } catch (erro) {
                texto = `Nao deu para criar agora (${String(erro).slice(0, 120)}). Siga a conversa.`;
              }
            }
          } else if (chamada.name === 'definir_horario_funcionamento') {
            const args = chamada.input as {
              dias: { dia: number; abre: string; fecha: string }[];
              confianca: number;
            };
            if (typeof args.confianca !== 'number' || args.confianca < 0.75) {
              texto = 'NAO gravei: confianca abaixo de 0,75. Confirme os dias e horarios com ele.';
            } else {
              try {
                const r = (await rpc(
                  supabaseUrl,
                  serviceKey,
                  'onboarding_definir_horario_funcionamento',
                  { p_tenant_id: tenantId, p_dias: args.dias ?? [] }
                )) as {
                  ok?: boolean;
                  reason?: string;
                  horarios?: { dia: string; abre: string; fecha: string }[];
                } | null;

                if (r?.ok) {
                  criados += 1;
                  const lista = (r.horarios ?? [])
                    .map((h) => `${h.dia} ${h.abre.slice(0, 5)}-${h.fecha.slice(0, 5)}`)
                    .join(', ');
                  texto = `Gravei o horario: ${lista}. Nos dias que nao estao aqui o salao fica fechado -- confirme com ele.`;
                } else if (r?.reason === 'HORARIO_INVERTIDO') {
                  texto = 'NAO gravei: tem dia com a hora de fechar antes da de abrir. Confirme com ele.';
                } else if (r?.reason === 'DIAS_NAO_INFORMADOS') {
                  texto = 'NAO gravei: voce nao mandou dia nenhum. Pergunte que dias o salao abre.';
                } else {
                  texto = `NAO gravei: ${r?.reason ?? 'motivo desconhecido'}.`;
                }
              } catch (erro) {
                texto = `Nao deu para gravar agora (${String(erro).slice(0, 120)}). Siga a conversa.`;
              }
            }
          } else if (chamada.name === 'resumo') {
            try {
              const r = (await rpc(supabaseUrl, serviceKey, 'onboarding_resumo_pela_conversa', {
                p_conversation_id: item.conversation_id,
              })) as Record<string, unknown> | null;
              viuOResumo = true;
              texto =
                'O que esta no rascunho agora (conte isso a ele em portugues, antes de falar em publicar):\n' +
                JSON.stringify(r);
            } catch (erro) {
              texto = `Nao consegui ler o rascunho agora (${String(erro).slice(0, 120)}). Nao fale em publicar sem isso.`;
            }
          } else if (chamada.name === 'publicar') {
            const args = chamada.input as { confirmacaoDoDono: string };
            if (!viuOResumo) {
              texto =
                'NAO publiquei: voce ainda nao chamou `resumo` nesta conversa. ' +
                'Chame o resumo, conte a ele o que mudou, espere ele confirmar, e so entao publique.';
            } else if (!args.confirmacaoDoDono || args.confirmacaoDoDono.trim().length < 2) {
              texto = 'NAO publiquei: faltou a confirmacao dele, com as palavras dele.';
            } else {
              try {
                const r = (await rpc(supabaseUrl, serviceKey, 'onboarding_publicar_pela_conversa', {
                  p_conversation_id: item.conversation_id,
                  p_confirmacao: args.confirmacaoDoDono,
                })) as {
                  ok?: boolean;
                  reason?: string;
                  detalhe?: string;
                  pendencias?: { oQueFalta?: string }[];
                  versao?: { versionNumber?: number };
                } | null;

                if (r?.ok) {
                  publicacoes += 1;
                  texto =
                    `Publicado. A configuracao no ar agora e a versao ${r.versao?.versionNumber ?? '?'}. ` +
                    'Diga isso a ele em uma linha.';
                } else if (r?.reason === 'FALTA_COISA') {
                  const faltas = (r.pendencias ?? []).map((p) => `- ${p.oQueFalta}`).join('\n');
                  texto =
                    'NAO publiquei porque falta coisa. Leia isto para ele, do jeito que esta:\n' +
                    faltas;
                } else if (r?.reason === 'NADA_PARA_PUBLICAR') {
                  texto = 'NAO publiquei: nao ha nada mudado no rascunho. Diga isso a ele.';
                } else if (r?.reason === 'NAO_E_O_DONO') {
                  texto =
                    'NAO publiquei: este numero nao esta cadastrado como dono deste salao. Nao insista e nao explique a trava.';
                } else {
                  texto = `NAO publiquei: ${r?.reason ?? 'motivo desconhecido'}${r?.detalhe ? ' — ' + r.detalhe : ''}.`;
                }
              } catch (erro) {
                texto = `Nao deu para publicar agora (${String(erro).slice(0, 120)}). Nao diga que publicou.`;
              }
            }
          } else {
            texto = 'Ferramenta desconhecida.';
          }
          devolucoes.push({ type: 'tool_result', tool_use_id: chamada.id, content: texto });
        }

        mensagens.push({ role: 'user', content: devolucoes });
      }

      try {
        await rpc(supabaseUrl, serviceKey, 'agent_record_usage', {
          p_tenant_id: tenantId,
          p_conversation_id: item.conversation_id,
          p_modelo: MODELO,
          p_esforco: ESFORCO,
          p_voltas: uso.voltas,
          p_input: uso.input,
          p_output: uso.output,
          p_cache_write: uso.cacheWrite,
          p_cache_read: uso.cacheRead,
          p_desfecho: decisao ? decisao.action : (motivoFalha ?? 'SEM_DECISAO'),
        });
      } catch {
        // Medir nao pode derrubar o atendimento.
      }

      if (!decisao) throw new Error(motivoFalha ?? 'SEM_DECISAO');

      const textos = (decisao.messages ?? [])
        .map((t) => (typeof t === 'string' ? t.trim() : ''))
        .filter((t) => t.length > 0)
        .slice(0, 3)
        .map((t) => t.replace(/\s*—\s*/g, ' - ').replace(/\s*–\s*/g, ' - '));

      let acao = decisao.action;
      if (camposCorrompidos(decisao).includes('messages')) acao = 'HANDOFF';
      if (acao === 'REPLY' && textos.length === 0) acao = 'HANDOFF';

      if (dryRun) {
        resultados.push({ conversationId: item.conversation_id, action: acao, messages: textos, uso, dryRun: true });
        continue;
      }

      // HANDOFF NAO PODE SER MUDO.
      //
      // 20/09, 09:15. A dona confirmou "Confirmo" para remover quatro servicos.
      // O Eddy decidiu HANDOFF -- corretamente, porque remover servico nao era
      // dele -- e HANDOFF manda `messages` vazio. Ela nao recebeu nada e ficou
      // achando que tinha sido feito.
      //
      // Silencio e pior que "nao consigo". Se ele nao tem o que dizer, o codigo
      // diz por ele. E o pedido vira alerta para a Eduarda, porque um dono
      // pedindo o que o produto nao faz e informacao de produto, nao incidente.
      const saidas =
        acao === 'REPLY'
          ? textos
          : ['Isso aqui eu não consigo fazer por aqui. Já avisei a Eduarda e ela te retorna.'];

      if (acao === 'HANDOFF') {
        const ultimaDoDono =
          (contexto.history as { direction?: string; text?: string }[] | undefined)
            ?.filter((h) => h.direction === 'INBOUND')
            .slice(-1)[0]?.text ?? '';
        try {
          await rpc(supabaseUrl, serviceKey, 'registrar_pedido_fora_do_alcance', {
            p_conversation_id: item.conversation_id,
            p_pedido_do_dono: ultimaDoDono,
            p_motivo_do_eddy: decisao.reason ?? '',
          });
          // Aprender e livre: fica gravado com as palavras dele, mesmo que
          // ninguem olhe hoje. O que e revisado depois e so a promocao.
          await rpc(supabaseUrl, serviceKey, 'registrar_conhecimento_solto', {
            p_tenant_id: tenantId,
            p_conversation_id: item.conversation_id,
            p_palavras: ultimaDoDono,
            p_modulo: null,
            p_escopo: null,
            p_porque: decisao.reason ?? 'HANDOFF sem motivo escrito',
          });
        } catch (erro) {
          // Registrar o pedido nao vale derrubar a resposta ao dono -- mas
          // engolir CALADO foi o que deixou este caminho quebrado por dois
          // dias. As duas funcoes existiam so em `app`, sem espelho em
          // `public`, e o PostgREST devolvia 404 a cada HANDOFF. O Eddy dizia
          // "ja avisei a Eduarda" e `agent_alerts` seguia com zero linhas.
          // Agora o erro aparece no log da funcao, que e onde alguem procura.
          console.error(
            'HANDOFF: nao consegui registrar o pedido fora do alcance',
            JSON.stringify({
              conversationId: item.conversation_id,
              tenantId,
              erro: String(erro).slice(0, 300),
            })
          );
        }
      }

      {
        for (let i = 0; i < saidas.length; i++) {
          await rpc(supabaseUrl, serviceKey, 'enqueue_outbound_message', {
            p_tenant_id: item.tenant_id,
            p_conversation_id: item.conversation_id,
            p_body_text: saidas[i],
            p_actor: 'AGENT',
            p_idempotency_key: `eddy:${item.last_inbound_message_id}:${i}`,
          });
        }
        // O que ele disse ao dono entra no historico do onboarding tambem, para
        // a tela mostrar a mesma conversa que aconteceu no WhatsApp.
        if (sessaoId) {
          try {
            await rpc(supabaseUrl, serviceKey, 'eddy_turno', {
              p_tenant_id: tenantId,
              p_session_id: sessaoId,
              p_quem: 'SISTEMA',
              p_texto: saidas.join('\n'),
            });
          } catch {
            // historico da tela nao vale derrubar a resposta
          }
        }
        respondidas++;
      }

      await rpc(supabaseUrl, serviceKey, 'mark_agent_decision', {
        p_tenant_id: item.tenant_id,
        p_message_id: item.last_inbound_message_id,
        p_decision: acao,
        p_reason: decisao.reason,
      });

      try {
        await rpc(supabaseUrl, serviceKey, 'clear_agent_failures', {
          p_tenant_id: item.tenant_id,
          p_conversation_id: item.conversation_id,
        });
      } catch {
        // limpeza de falhas nao derruba o turno
      }

      resultados.push({ conversationId: item.conversation_id, action: acao, messages: saidas, uso });
    } catch (erro) {
      falhas++;
      const detalhe = String(erro);
      console.error(
        JSON.stringify({ event: 'eddy_turn_failed', conversationId: item.conversation_id, erro: detalhe })
      );
      try {
        await rpc(supabaseUrl, serviceKey, 'record_agent_failure', {
          p_tenant_id: item.tenant_id,
          p_conversation_id: item.conversation_id,
          p_detail: detalhe.slice(0, 800),
          p_definitive: detalhe.includes('NO_TOOL_CALL'),
        });
      } catch {
        // registrar a falha nao pode gerar outra
      }
      resultados.push({ conversationId: item.conversation_id, action: 'ERROR', detail: detalhe.slice(0, 300) });
    }
  }

  console.log(
    JSON.stringify({
      event: 'eddy_batch_done',
      modelo: MODELO,
      promptBytes: regras.length,
      aguardando: fila.length,
      respondidas,
      anotadas,
      criados,
      publicacoes,
      falhas,
      dryRun,
    })
  );

  return json(200, {
    ok: true,
    aguardando: fila.length,
    respondidas,
    anotadas,
    criados,
    publicacoes,
    falhas,
    dryRun,
    resultados,
  });
});
