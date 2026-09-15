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
    return json(200, { ok: true, aguardando: 0, respondidas: 0, anotadas: 0, falhas: 0 });
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

      const mensagens: Anthropic.MessageParam[] = [
        {
          role: 'user',
          content:
            'Esta conversa com o dono (JSON). A última mensagem do histórico é a que está esperando resposta.\n\n' +
            JSON.stringify({ dono: contexto.dono, negocio: contexto.negocio, history: contexto.history }) +
            '\n\nO QUE AINDA FALTA NO CADASTRO DELE (a chave entre colchetes é obrigatória em `anotar`, e você nunca inventa uma):\n' +
            (pauta || '(nada — o cadastro está completo)'),
        },
      ];

      let sessaoId: string | null = null;
      let turnoId: string | null = null;
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

      if (acao === 'REPLY') {
        for (let i = 0; i < textos.length; i++) {
          await rpc(supabaseUrl, serviceKey, 'enqueue_outbound_message', {
            p_tenant_id: item.tenant_id,
            p_conversation_id: item.conversation_id,
            p_body_text: textos[i],
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
              p_texto: textos.join('\n'),
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

      resultados.push({ conversationId: item.conversation_id, action: acao, messages: textos, uso });
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
      falhas,
      dryRun,
    })
  );

  return json(200, { ok: true, aguardando: fila.length, respondidas, anotadas, falhas, dryRun, resultados });
});
