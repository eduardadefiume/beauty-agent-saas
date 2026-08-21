// whatsapp-agent — o cerebro. Le as conversas que estao esperando, decide o que
// dizer e enfileira a resposta.
//
// ONDE ELE ENTRA NA CORRENTE:
//   whatsapp-webhook -> inbox_events -> project_inbox_events -> crm_messages
//   -> [aqui] -> outbox_messages -> whatsapp-sender -> Cloud API
//
// TRES DECISOES QUE MOLDAM ESTE ARQUIVO:
//
// 1. O PROMPT E PARTIDO EM DOIS, E ISSO E ECONOMIA, NAO ESTETICA.
//    A primeira versao mandava catalogo e historico juntos na mensagem do
//    usuario: 5.252 tokens de entrada por mensagem, US$ 0,030 cada. O cache da
//    API cobra 10% pela leitura de um prefixo ja visto, mas so se o prefixo for
//    byte a byte identico. Catalogo misturado com historico nunca e identico.
//    Agora o que e igual para todo o salao (catalogo, horario, equipe) vai no
//    system com marca de cache; o que muda por conversa vai depois. Qualquer
//    coisa que varie dentro do bloco cacheado -- um relogio, um id -- derruba o
//    cache em silencio e a conta volta a subir sem aviso.
//
// 2. O AGENTE NUNCA DIZ QUE VAI VERIFICAR.
//    Ou ele responde, ou ele fica quieto e pergunta ao dono por dentro. "Vou
//    confirmar com a equipe e te retorno" e a frase que denuncia um robo e
//    joga a responsabilidade de volta para a cliente. Uma recepcionista que
//    nao sabe o preco nao anuncia que vai perguntar: ela vira e pergunta.
//
// 3. ELE NAO AGENDA SOZINHO -- AINDA.
//    O motor de disponibilidade existe (packages/scheduling-engine) mas nao
//    esta ligado aqui. Ate estar, pedido de horario vira pergunta ao dono, com
//    o dia e o servico ja formulados. A dona responde "sabado 9h ou 14h" e o
//    agente devolve isso a cliente como se sempre soubesse. Funciona, e e
//    honesto: quem tem a agenda hoje e a pessoa.

import 'jsr:@supabase/functions-js/edge-runtime.d.ts';
import Anthropic from 'npm:@anthropic-ai/sdk@0.120.0';

// Sonnet 5 e nao Opus 5: com o cache ligado, a diferenca de qualidade nesta
// tarefa (conversa curta sobre um catalogo pequeno) nao paga cinco vezes o
// preco de saida. Trocar de volta e uma linha, se a conversa cair de nivel.
const MODELO = 'claude-sonnet-5';

// Conversa de recepcao nao pede deliberacao longa. Esforco baixo mantem a
// resposta perto do tempo em que uma pessoa responderia.
const ESFORCO = 'low' as const;

// Uma hora de cache em vez de cinco minutos. Salao tem movimento irregular:
// com cinco minutos, cada intervalo de calmaria paga a escrita de novo. A
// escrita de 1h custa o dobro da de 5min, mas se paga a partir da terceira
// mensagem da hora.
const CACHE_TTL = '1h' as const;

type Aguardando = {
  conversation_id: string;
  tenant_id: string;
  last_inbound_message_id: string;
  waiting_seconds: number;
  trigger: string;
};

type Decisao = {
  action: 'REPLY' | 'ASK_OWNER' | 'HANDOFF';
  messages: string[];
  ownerQuestion: string;
  contextSummary: string;
  reason: string;
};

const FERRAMENTA: Anthropic.Tool = {
  name: 'atender',
  description: 'Registra o que fazer nesta conversa.',
  strict: true,
  input_schema: {
    type: 'object',
    properties: {
      action: {
        type: 'string',
        enum: ['REPLY', 'ASK_OWNER', 'HANDOFF'],
        description:
          'REPLY: você sabe a resposta e vai falar com a cliente agora. ASK_OWNER: falta uma informação que só a dona tem (preço, horário livre, confirmar agendamento) — a cliente NÃO recebe nada. HANDOFF: assunto delicado que uma pessoa precisa conduzir (reclamação, problema no resultado, cobrança).',
      },
      messages: {
        type: 'array',
        items: { type: 'string' },
        description:
          'As mensagens para a cliente, uma por balão de WhatsApp. Vazio quando action não for REPLY.',
      },
      ownerQuestion: {
        type: 'string',
        description:
          'Só quando action for ASK_OWNER. A pergunta para a dona, direta e específica, do jeito que se pergunta para alguém ocupada: "Quanto custa a progressiva japonesa?" ou "Tem horário sábado 29/08 para mechas loiras?". Vazio nos outros casos.',
      },
      contextSummary: {
        type: 'string',
        description:
          'Só quando action for ASK_OWNER. Uma frase dizendo o que a cliente quer, para a dona responder sem abrir a conversa. Vazio nos outros casos.',
      },
      reason: {
        type: 'string',
        description: 'Uma frase curta para o painel da equipe. Nunca é enviada à cliente.',
      },
    },
    required: ['action', 'messages', 'ownerQuestion', 'contextSummary', 'reason'],
    additionalProperties: false,
  },
};

// As regras. Ficam antes dos dados do salão no prompt de sistema, e as duas
// coisas juntas formam o prefixo cacheado.
const REGRAS = [
  'Você é a recepcionista deste negócio de beleza no WhatsApp. Não é assistente, não é robô,',
  'não é atendimento automático: você é a pessoa que atende as clientes.',
  '',
  'COMO VOCÊ ESCREVE',
  'Português do Brasil, do jeito que se escreve no WhatsApp. Frases curtas. Calorosa sem ser',
  'melosa. Um emoji aqui e ali, nunca em toda mensagem. Chama a cliente pelo primeiro nome',
  'quando você sabe.',
  'Nada de "Prezada", "estamos à disposição", "conforme solicitado", "peço que aguarde".',
  '',
  'A REGRA QUE NÃO SE QUEBRA: VOCÊ NUNCA NARRA O QUE VAI FAZER',
  'Nunca escreva "vou verificar", "vou confirmar com a equipe", "já te retorno", "um momento",',
  '"deixa eu ver". Nenhuma variação disso. Ou você responde a pergunta, ou você não manda nada',
  'e usa ASK_OWNER. A cliente não precisa saber que houve um obstáculo — para ela, você só',
  'demorou um pouquinho para responder, como qualquer pessoa demora.',
  '',
  'RESPONDA O QUE FOI PERGUNTADO, E SÓ',
  'Se perguntaram o preço, fale do preço. Não emende a duração. Se perguntaram a duração, fale',
  'da duração. Cada informação a mais que ninguém pediu deixa a conversa com cara de folheto.',
  '',
  'PUXE PARA O AGENDAMENTO',
  'Depois de responder, convide: "Gostaria de agendar um horário?" — naturalmente, sem insistir,',
  'e só quando fizer sentido na conversa.',
  '',
  'ELOGIO SE RESPONDE COM GRATIDÃO DE VERDADE',
  'Quando a cliente elogia o trabalho, o resultado, o atendimento: agradeça como uma pessoa',
  'agradece. Fique feliz. "Ai, que bom que você gostou! Fico muito feliz mesmo 🥰". Nunca',
  'responda elogio com informação de catálogo.',
  '',
  'QUANDO USAR ASK_OWNER (e não mandar nada para a cliente)',
  '- Preço que não está no catálogo, ou que está como null.',
  '- Horário disponível: você não enxerga a agenda. Pergunte à dona o dia e o serviço.',
  '- Confirmar um agendamento que a cliente aceitou.',
  '- Qualquer coisa sobre este negócio que não esteja nos dados que você recebeu.',
  'Escreva a pergunta como se perguntasse para a dona no meio do salão: curta e específica.',
  '',
  'QUANDO A DONA JÁ TE RESPONDEU',
  'Se vier `ownerAnswers`, a informação é sua agora. Responda a cliente com naturalidade, como',
  'quem sempre soube. Nunca diga "consultei", "verifiquei" ou "a equipe me informou". E termine',
  'o que começou: se era preço, ofereça agendar; se era horário, ofereça o horário.',
  '',
  'QUANDO USAR HANDOFF',
  'Reclamação, resultado que não agradou, cobrança, qualquer coisa delicada que uma pessoa',
  'precisa conduzir. Não mande nada e passe adiante.',
  '',
  'NUNCA INVENTE',
  'Você só pode afirmar o que estiver nos dados desta conversa. Não existe conhecimento seu',
  'sobre este negócio fora daí. Preço nulo significa que o preço não está definido — não',
  'estime, não cite faixa, não compare. Use ASK_OWNER.',
  '',
  'FORMATO',
  'No máximo 3 mensagens, cada uma até 350 caracteres. Uma ideia por mensagem. Se cabe em uma,',
  'mande uma só.',
  '',
  'EXEMPLOS DO TOM CERTO',
  '',
  'Cliente: "Quanto tempo demora a progressiva sem formol? Meu cabelo é médio"',
  'Você: "Oi, Camila! Boa tarde 😊" / "A progressiva sem formol em cabelo médio leva cerca de',
  '3h30." / "Gostaria de agendar um horário?"',
  '',
  'Cliente: "Oi, vcs fazem japonesa? Quanto custa?"',
  'Você: ASK_OWNER — pergunta à dona "Quanto custa a progressiva japonesa?" e não manda nada.',
  '(Errado seria responder o tempo, que ninguém perguntou, ou dizer que vai confirmar o valor.)',
  '',
  'Cliente: "Amei meu cabelo, ficou perfeito!!"',
  'Você: "Aaah, que alegria ler isso! 🥰" / "Fico muito feliz que tenha ficado do jeito que você',
  'queria." — e nada de catálogo.',
  '',
  'Registre sua decisão chamando a ferramenta atender.',
].join('\n');

function json(status: number, body: unknown): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'content-type': 'application/json; charset=utf-8' },
  });
}

async function rpc(url: string, key: string, fn: string, args: unknown): Promise<unknown> {
  const resposta = await fetch(`${url}/rest/v1/rpc/${fn}`, {
    method: 'POST',
    headers: {
      apikey: key,
      Authorization: `Bearer ${key}`,
      'content-type': 'application/json',
    },
    body: JSON.stringify(args),
  });
  if (!resposta.ok) {
    throw new Error(`RPC ${fn} falhou: ${resposta.status} ${await resposta.text()}`);
  }
  return await resposta.json();
}

// Segundo fator, alem do verify_jwt.
//
// verify_jwt so garante que o token e assinado por este projeto -- e a chave
// anon satisfaz isso e e publica, embutida no JavaScript do site. Sem este
// cheque, qualquer visitante poderia disparar o worker. O token vive no Vault:
// quem chama e quem confere leem da mesma fonte, e ele nunca precisa passar
// pela mao de ninguem.
async function autorizado(req: Request, url: string, key: string): Promise<boolean> {
  const token = req.headers.get('x-worker-token');
  if (!token) return false;
  try {
    return (await rpc(url, key, 'verify_worker_token', { p_token: token })) === true;
  } catch (erro) {
    console.error(JSON.stringify({ event: 'worker_token_check_failed', erro: String(erro) }));
    return false;
  }
}

type Uso = {
  input_tokens?: number;
  output_tokens?: number;
  cache_creation_input_tokens?: number;
  cache_read_input_tokens?: number;
};

async function decidir(
  anthropic: Anthropic,
  estavel: unknown,
  volatil: unknown,
): Promise<{ decisao: Decisao | null; usage: Uso; motivoFalha?: string }> {
  const resposta = await anthropic.messages.create({
    model: MODELO,
    max_tokens: 2000,
    thinking: { type: 'adaptive' },
    output_config: { effort: ESFORCO },
    // Dois blocos, e a marca de cache no segundo. Tudo que vem antes da marca
    // entra no prefixo cacheado: as regras (fixas) e os dados do salao (fixos
    // enquanto ninguem republicar o catalogo).
    system: [
      { type: 'text', text: REGRAS },
      {
        type: 'text',
        text: 'DADOS DESTE NEGÓCIO (JSON):\n' + JSON.stringify(estavel),
        cache_control: { type: 'ephemeral', ttl: CACHE_TTL },
      },
    ],
    tools: [FERRAMENTA],
    tool_choice: { type: 'tool', name: 'atender' },
    messages: [
      {
        role: 'user',
        content:
          'Esta conversa (JSON). A última mensagem do histórico é a que está esperando resposta.\n\n' +
          JSON.stringify(volatil),
      },
    ],
  });

  const usage = (resposta.usage ?? {}) as Uso;

  if (resposta.stop_reason === 'refusal') {
    return { decisao: null, usage, motivoFalha: 'MODEL_REFUSAL' };
  }

  const bloco = resposta.content.find(
    (b): b is Anthropic.ToolUseBlock => b.type === 'tool_use' && b.name === 'atender',
  );
  if (!bloco) {
    return { decisao: null, usage, motivoFalha: 'NO_TOOL_CALL' };
  }

  return { decisao: bloco.input as Decisao, usage };
}

Deno.serve(async (req) => {
  const supabaseUrl = Deno.env.get('SUPABASE_URL');
  const serviceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
  const anthropicKey = Deno.env.get('ANTHROPIC_API_KEY');

  if (!supabaseUrl || !serviceKey) {
    return json(500, { ok: false, reason: 'SUPABASE_ENV_MISSING' });
  }
  // Autorizacao antes de qualquer outra coisa: quem nao passou daqui nao
  // descobre nem se a chave da Anthropic esta configurada.
  if (!(await autorizado(req, supabaseUrl, serviceKey))) {
    return json(401, { ok: false, reason: 'WORKER_TOKEN_INVALID' });
  }
  if (!anthropicKey) {
    return json(500, { ok: false, reason: 'ANTHROPIC_API_KEY_MISSING' });
  }

  // Corpo opcional. `dryRun` mostra o texto que o agente produziria sem
  // enfileirar nada -- e como se olha a qualidade da conversa antes de deixar o
  // agente falar com uma cliente de verdade. `quietSeconds` a 0 desliga a
  // espera por silencio, o que so faz sentido em teste.
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
    fila = (await rpc(supabaseUrl, serviceKey, 'list_conversations_awaiting_agent', {
      p_limit: limite,
      p_quiet_seconds: quietSeconds,
    })) as Aguardando[];
  } catch (erro) {
    return json(500, { ok: false, reason: 'QUEUE_READ_FAILED', detail: String(erro) });
  }

  if (!Array.isArray(fila) || fila.length === 0) {
    return json(200, { ok: true, aguardando: 0, respondidas: 0, perguntadas: 0, repassadas: 0, falhas: 0 });
  }

  const anthropic = new Anthropic({ apiKey: anthropicKey });
  const resultados: unknown[] = [];
  let respondidas = 0;
  let perguntadas = 0;
  let repassadas = 0;
  let falhas = 0;
  const somaUso: Uso = {
    input_tokens: 0,
    output_tokens: 0,
    cache_creation_input_tokens: 0,
    cache_read_input_tokens: 0,
  };

  for (const item of fila) {
    try {
      const contexto = (await rpc(supabaseUrl, serviceKey, 'build_agent_context', {
        p_conversation_id: item.conversation_id,
        p_history_limit: 20,
      })) as { ok?: boolean; reason?: string; stable?: unknown; volatile?: unknown };

      if (!contexto?.ok) {
        throw new Error(`contexto indisponivel: ${contexto?.reason ?? 'desconhecido'}`);
      }

      const { decisao, usage, motivoFalha } = await decidir(
        anthropic,
        contexto.stable,
        contexto.volatile,
      );

      somaUso.input_tokens! += usage.input_tokens ?? 0;
      somaUso.output_tokens! += usage.output_tokens ?? 0;
      somaUso.cache_creation_input_tokens! += usage.cache_creation_input_tokens ?? 0;
      somaUso.cache_read_input_tokens! += usage.cache_read_input_tokens ?? 0;

      if (!decisao) {
        throw new Error(motivoFalha ?? 'SEM_DECISAO');
      }

      const textos = (decisao.messages ?? [])
        .map((t) => (typeof t === 'string' ? t.trim() : ''))
        .filter((t) => t.length > 0)
        .slice(0, 3);

      // REPLY sem texto seria um envio em branco. Vale o que o modelo fez, nao
      // o rotulo que ele deu.
      let acao = decisao.action;
      if (acao === 'REPLY' && textos.length === 0) acao = 'HANDOFF';
      if (acao === 'ASK_OWNER' && (decisao.ownerQuestion ?? '').trim().length < 3) acao = 'HANDOFF';

      if (dryRun) {
        resultados.push({
          conversationId: item.conversation_id,
          trigger: item.trigger,
          action: acao,
          reason: decisao.reason,
          messages: textos,
          ownerQuestion: acao === 'ASK_OWNER' ? decisao.ownerQuestion : undefined,
          contextSummary: acao === 'ASK_OWNER' ? decisao.contextSummary : undefined,
          usage,
          dryRun: true,
        });
        continue;
      }

      const enviados: unknown[] = [];

      if (acao === 'REPLY') {
        for (let i = 0; i < textos.length; i++) {
          enviados.push(
            await rpc(supabaseUrl, serviceKey, 'enqueue_outbound_message', {
              p_tenant_id: item.tenant_id,
              p_conversation_id: item.conversation_id,
              p_body_text: textos[i],
              p_actor: 'AGENT',
              // Deriva do id da mensagem que motivou a resposta, mais o gatilho:
              // a retomada depois da resposta da dona e um envio novo e legitimo
              // sobre a mesma mensagem, entao a chave precisa distingui-los.
              p_idempotency_key: `agent:${item.last_inbound_message_id}:${item.trigger}:${i}`,
            }),
          );
        }
        // A resposta da dona foi usada; não traz a conversa de volta à fila.
        await rpc(supabaseUrl, serviceKey, 'consume_owner_answers', {
          p_tenant_id: item.tenant_id,
          p_conversation_id: item.conversation_id,
        });
      } else if (acao === 'ASK_OWNER') {
        await rpc(supabaseUrl, serviceKey, 'record_owner_question', {
          p_tenant_id: item.tenant_id,
          p_conversation_id: item.conversation_id,
          p_message_id: item.last_inbound_message_id,
          p_question: decisao.ownerQuestion,
          p_context_summary: decisao.contextSummary,
        });
      }

      // Só marca depois de agir. Se o enfileiramento estourar, a mensagem fica
      // sem decisão e volta na próxima rodada -- que é o certo para uma falha
      // de infraestrutura.
      await rpc(supabaseUrl, serviceKey, 'mark_agent_decision', {
        p_tenant_id: item.tenant_id,
        p_message_id: item.last_inbound_message_id,
        p_decision: acao,
        p_reason: decisao.reason,
      });

      if (acao === 'REPLY') respondidas++;
      else if (acao === 'ASK_OWNER') perguntadas++;
      else repassadas++;

      resultados.push({
        conversationId: item.conversation_id,
        trigger: item.trigger,
        action: acao,
        reason: decisao.reason,
        messages: textos,
        ownerQuestion: acao === 'ASK_OWNER' ? decisao.ownerQuestion : undefined,
        enfileirados: enviados,
        usage,
      });
    } catch (erro) {
      falhas++;
      const detalhe = String(erro);
      console.error(
        JSON.stringify({
          event: 'agent_turn_failed',
          conversationId: item.conversation_id,
          erro: detalhe,
        }),
      );

      // Falha do modelo (recusa, formato) é definitiva para esta mensagem:
      // repetir gastaria token para o mesmo resultado. Falha de rede ou de
      // banco não marca nada e volta na próxima rodada.
      if (detalhe.includes('MODEL_REFUSAL') || detalhe.includes('NO_TOOL_CALL')) {
        try {
          await rpc(supabaseUrl, serviceKey, 'mark_agent_decision', {
            p_tenant_id: item.tenant_id,
            p_message_id: item.last_inbound_message_id,
            p_decision: 'ERROR',
            p_reason: detalhe.slice(0, 400),
          });
        } catch (erroMarca) {
          console.error(JSON.stringify({ event: 'mark_decision_failed', erro: String(erroMarca) }));
        }
      }

      resultados.push({
        conversationId: item.conversation_id,
        action: 'ERROR',
        detail: detalhe.slice(0, 400),
      });
    }
  }

  console.log(
    JSON.stringify({
      event: 'agent_batch_done',
      modelo: MODELO,
      aguardando: fila.length,
      respondidas,
      perguntadas,
      repassadas,
      falhas,
      dryRun,
      uso: somaUso,
    }),
  );

  return json(200, {
    ok: true,
    modelo: MODELO,
    aguardando: fila.length,
    respondidas,
    perguntadas,
    repassadas,
    falhas,
    dryRun,
    uso: somaUso,
    resultados,
  });
});
