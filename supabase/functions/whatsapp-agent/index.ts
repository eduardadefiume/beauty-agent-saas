// whatsapp-agent — o cerebro. Le as conversas que estao esperando, decide o que
// dizer e enfileira a resposta.
//
// ONDE ELE ENTRA NA CORRENTE:
//   whatsapp-webhook -> inbox_events -> project_inbox_events -> crm_messages
//   -> [aqui] -> outbox_messages -> whatsapp-sender -> Cloud API
//
// Cada elo ja e idempotente por conta propria. Este continua a regra: a chave
// de idempotencia da resposta deriva do id da mensagem recebida, entao duas
// invocacoes simultaneas produzem no maximo um envio.
//
// O QUE ELE NAO FAZ, DE PROPOSITO. Nao agenda. Agendar exige o motor
// deterministico de disponibilidade e reserva temporaria de horario; um agente
// que confirma um horario que nao existe causa mais estrago do que um agente
// que diz "vou confirmar com a equipe". Enquanto o motor nao estiver ligado
// aqui, pedido de agendamento e HANDOFF -- passa para o humano.
//
// POR QUE STRICT TOOL USE E NAO TEXTO LIVRE. A saida do modelo alimenta uma
// fila de envio real. Com `strict: true` a API garante que o argumento valida
// contra o schema antes de chegar aqui; sem isso seria preciso confiar em
// JSON.parse de um texto e tratar cada variacao de formato como caso de erro.

import 'jsr:@supabase/functions-js/edge-runtime.d.ts';
import Anthropic from 'npm:@anthropic-ai/sdk@0.120.0';

// Opus 5 e a escolha deliberada: a conversa e o produto. Uma resposta que soa
// robotica na primeira semana e o motivo de o William desistir do piloto, e a
// diferenca de custo por mensagem e irrelevante perto disso.
const MODELO = 'claude-opus-5';

// Poucos servicos, historico curto: nao ha o que ponderar longamente. Esforco
// baixo mantem a latencia perto do tempo em que uma pessoa responderia.
const ESFORCO = 'low' as const;

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

const FERRAMENTA: Anthropic.Tool = {
  name: 'responder_cliente',
  description:
    'Registra a decisao sobre esta conversa: responder a cliente agora ou passar para a equipe humana.',
  strict: true,
  input_schema: {
    type: 'object',
    properties: {
      action: {
        type: 'string',
        enum: ['REPLY', 'HANDOFF'],
        description:
          'REPLY quando voce consegue responder com o que esta no contexto. HANDOFF quando a resposta exigiria inventar algo, agendar, negociar preco ou tratar reclamacao.',
      },
      messages: {
        type: 'array',
        items: { type: 'string' },
        description:
          'As mensagens a enviar, na ordem, uma por balao de WhatsApp. Vazio quando action for HANDOFF.',
      },
      reason: {
        type: 'string',
        description:
          'Uma frase curta, para o painel da equipe, explicando a decisao. Nunca e enviada a cliente.',
      },
    },
    required: ['action', 'messages', 'reason'],
    additionalProperties: false,
  },
};

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

// O prompt de sistema carrega a persona e as proibicoes; o contexto vai na
// mensagem do usuario. A separacao nao e estetica: o prompt e identico em toda
// chamada e o contexto muda a cada uma, o que e exatamente o formato que o
// cache de prefixo da API premia.
function promptDeSistema(): string {
  return [
    'Voce atende pelo WhatsApp as clientes de um negocio de beleza, no lugar da equipe.',
    'Escreve em portugues do Brasil, como uma recepcionista atenciosa escreve de verdade:',
    'frases curtas, sem formalidade de escritorio, sem emoji em excesso, sem jargao de robo.',
    'Nada de "Prezada cliente", "estamos a disposicao" ou "conforme solicitado".',
    '',
    'REGRAS QUE NAO SE QUEBRAM:',
    '1. Voce so pode afirmar o que estiver no contexto desta conversa. Nao existe',
    '   conhecimento seu sobre este negocio fora do que vier no JSON.',
    '2. Preco: se priceMinor vier nulo, o preco NAO esta definido. Diga que vai',
    '   confirmar com a equipe. Nunca estime, nunca cite faixa, nunca compare.',
    '3. Voce nao agenda, nao reserva, nao confirma horario e nao cancela.',
    '   Qualquer pedido de marcar, remarcar ou cancelar e HANDOFF.',
    '4. Voce nao negocia desconto, nao trata reclamacao e nao promete prazo.',
    '5. Se catalogWarning estiver presente, o negocio nao publicou servicos.',
    '   Nao invente lista de servicos: e HANDOFF.',
    '6. Nunca diz que e uma inteligencia artificial a menos que perguntem',
    '   diretamente; se perguntarem, responde com honestidade e sem rodeio.',
    '7. Na duvida entre responder e passar para a equipe, passe para a equipe.',
    '   Silencio de dois minutos custa menos que uma informacao errada.',
    '',
    'FORMATO:',
    '- No maximo 3 mensagens, cada uma com no maximo 350 caracteres.',
    '- Uma ideia por mensagem. Se cabe em uma, mande uma so.',
    '- Chame a cliente pelo primeiro nome quando o contexto trouxer o nome.',
    '',
    'Registre sua decisao chamando a ferramenta responder_cliente.',
  ].join('\n');
}

async function decidir(
  anthropic: Anthropic,
  contexto: unknown,
): Promise<{ decisao: Decisao | null; usage: unknown; motivoFalha?: string }> {
  const resposta = await anthropic.messages.create({
    model: MODELO,
    max_tokens: 4000,
    thinking: { type: 'adaptive' },
    output_config: { effort: ESFORCO },
    system: promptDeSistema(),
    tools: [FERRAMENTA],
    tool_choice: { type: 'tool', name: 'responder_cliente' },
    messages: [
      {
        role: 'user',
        content:
          'Contexto desta conversa (JSON). A ultima mensagem do historico e a que ' +
          'esta esperando resposta.\n\n' +
          JSON.stringify(contexto),
      },
    ],
  });

  if (resposta.stop_reason === 'refusal') {
    return { decisao: null, usage: resposta.usage, motivoFalha: 'MODEL_REFUSAL' };
  }

  const bloco = resposta.content.find(
    (b): b is Anthropic.ToolUseBlock => b.type === 'tool_use' && b.name === 'responder_cliente',
  );
  if (!bloco) {
    return { decisao: null, usage: resposta.usage, motivoFalha: 'NO_TOOL_CALL' };
  }

  return { decisao: bloco.input as Decisao, usage: resposta.usage };
}

Deno.serve(async (req) => {
  const supabaseUrl = Deno.env.get('SUPABASE_URL');
  const serviceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
  const anthropicKey = Deno.env.get('ANTHROPIC_API_KEY');

  if (!supabaseUrl || !serviceKey) {
    return json(500, { ok: false, reason: 'SUPABASE_ENV_MISSING' });
  }
  if (!anthropicKey) {
    return json(500, { ok: false, reason: 'ANTHROPIC_API_KEY_MISSING' });
  }

  // Corpo opcional. `dryRun` existe para testar o texto que o agente produziria
  // sem enfileirar nada -- e como se olha a qualidade da conversa antes de
  // deixar o agente falar com uma cliente de verdade.
  let corpo: { limit?: number; dryRun?: boolean } = {};
  if (req.method === 'POST') {
    try {
      corpo = (await req.json()) ?? {};
    } catch {
      corpo = {};
    }
  }
  const limite = Math.min(Math.max(corpo.limit ?? 5, 1), 20);
  const dryRun = corpo.dryRun === true;

  let fila: Aguardando[];
  try {
    fila = (await rpc(supabaseUrl, serviceKey, 'list_conversations_awaiting_agent', {
      p_limit: limite,
    })) as Aguardando[];
  } catch (erro) {
    return json(500, { ok: false, reason: 'QUEUE_READ_FAILED', detail: String(erro) });
  }

  if (!Array.isArray(fila) || fila.length === 0) {
    return json(200, { ok: true, aguardando: 0, respondidas: 0, repassadas: 0, falhas: 0 });
  }

  const anthropic = new Anthropic({ apiKey: anthropicKey });
  const resultados: unknown[] = [];
  let respondidas = 0;
  let repassadas = 0;
  let falhas = 0;

  for (const item of fila) {
    try {
      const contexto = (await rpc(supabaseUrl, serviceKey, 'build_agent_context', {
        p_conversation_id: item.conversation_id,
        p_history_limit: 20,
      })) as { ok?: boolean; reason?: string };

      if (!contexto?.ok) {
        throw new Error(`contexto indisponivel: ${contexto?.reason ?? 'desconhecido'}`);
      }

      const { decisao, usage, motivoFalha } = await decidir(anthropic, contexto);

      if (!decisao) {
        throw new Error(motivoFalha ?? 'SEM_DECISAO');
      }

      // Texto vazio com action REPLY seria um envio em branco. Trata como
      // repasse: e o que o modelo efetivamente fez, ainda que tenha se
      // rotulado errado.
      const textos = (decisao.messages ?? [])
        .map((t) => (typeof t === 'string' ? t.trim() : ''))
        .filter((t) => t.length > 0)
        .slice(0, 3);

      const vaiResponder = decisao.action === 'REPLY' && textos.length > 0;

      if (dryRun) {
        resultados.push({
          conversationId: item.conversation_id,
          action: vaiResponder ? 'REPLY' : 'HANDOFF',
          reason: decisao.reason,
          messages: textos,
          usage,
          dryRun: true,
        });
        continue;
      }

      const enviados: unknown[] = [];
      if (vaiResponder) {
        for (let i = 0; i < textos.length; i++) {
          const enfileirado = await rpc(supabaseUrl, serviceKey, 'enqueue_outbound_message', {
            p_tenant_id: item.tenant_id,
            p_conversation_id: item.conversation_id,
            p_body_text: textos[i],
            p_actor: 'AGENT',
            // Deriva do id da mensagem que motivou a resposta: reprocessar a
            // mesma conversa nunca gera um segundo envio.
            p_idempotency_key: `agent:${item.last_inbound_message_id}:${i}`,
          });
          enviados.push(enfileirado);
        }
      }

      // So marca depois de enfileirar. Se o enfileiramento estourar, a mensagem
      // fica sem decisao e volta na proxima rodada -- que e o comportamento
      // desejado para uma falha de infraestrutura.
      await rpc(supabaseUrl, serviceKey, 'mark_agent_decision', {
        p_tenant_id: item.tenant_id,
        p_message_id: item.last_inbound_message_id,
        p_decision: vaiResponder ? 'REPLY' : 'HANDOFF',
        p_reason: decisao.reason,
      });

      if (vaiResponder) respondidas++;
      else repassadas++;

      resultados.push({
        conversationId: item.conversation_id,
        action: vaiResponder ? 'REPLY' : 'HANDOFF',
        reason: decisao.reason,
        messages: textos,
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

      // Falha do modelo (recusa, formato) e definitiva para esta mensagem:
      // repetir gastaria token para o mesmo resultado. Falha de rede ou de
      // banco nao marca nada e volta na proxima rodada.
      if (detalhe.includes('MODEL_REFUSAL') || detalhe.includes('NO_TOOL_CALL')) {
        try {
          await rpc(supabaseUrl, serviceKey, 'mark_agent_decision', {
            p_tenant_id: item.tenant_id,
            p_message_id: item.last_inbound_message_id,
            p_decision: 'ERROR',
            p_reason: detalhe.slice(0, 400),
          });
        } catch (erroMarca) {
          console.error(
            JSON.stringify({ event: 'mark_decision_failed', erro: String(erroMarca) }),
          );
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
      aguardando: fila.length,
      respondidas,
      repassadas,
      falhas,
      dryRun,
    }),
  );

  return json(200, {
    ok: true,
    aguardando: fila.length,
    respondidas,
    repassadas,
    falhas,
    dryRun,
    resultados,
  });
});
