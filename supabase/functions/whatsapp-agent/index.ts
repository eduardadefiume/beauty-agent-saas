// whatsapp-agent — o cerebro. Le as conversas que estao esperando, decide o que
// dizer e enfileira a resposta.
//
// ONDE ELE ENTRA NA CORRENTE:
//   whatsapp-webhook -> inbox_events -> project_inbox_events -> crm_messages
//   -> [aqui] -> outbox_messages -> whatsapp-sender -> Cloud API
//
// O QUE MORA AQUI E O QUE NAO MORA MAIS.
//
// Ate a v27 este arquivo carregava o prompt inteiro: 35 KB de texto sobre como
// falar, o que nunca dizer, como receber cliente nova. Em duas horas de teste
// ao vivo foram mais de dez correcoes, e quase todas eram uma frase. Cada
// frase custava um deploy do arquivo inteiro, montado a mao, e o repositorio
// acabou divergindo do que estava publicado.
//
// Agora o prompt vive em app.agent_prompt_blocks e chega por RPC. Aqui fica so
// o MOTOR:
//   - as ferramentas e o laco de decisao;
//   - a conversao de milissegundos para "sabado as 8h", que nunca pode ser
//     feita pelo modelo;
//   - as travas que nao podem depender de o modelo se comportar: nao afirmar
//     agendamento que nao existe, nao mandar mensagem vazia, nao usar
//     travessao;
//   - o teto de falhas, para uma conversa quebrada nao virar torneira aberta.
//
// A REGRA PARA DECIDIR ONDE UMA COISA VAI:
//   Se e comportamento e da para escrever em portugues, e prompt: vai para o
//   banco. Se e invariante que precisa valer mesmo quando o modelo erra, e
//   codigo: fica aqui.

import 'jsr:@supabase/functions-js/edge-runtime.d.ts';
import Anthropic from 'npm:@anthropic-ai/sdk@0.120.0';

// Sonnet 5 e nao Opus 5: com o cache ligado, a diferenca de qualidade nesta
// tarefa (conversa curta sobre um catalogo pequeno) nao paga a diferenca de
// preco de saida. Trocar de volta e uma linha, se a conversa cair de nivel.
const MODELO = 'claude-sonnet-5';

// Conversa de recepcao nao pede deliberacao longa.
const ESFORCO = 'low' as const;

// Uma hora de cache em vez de cinco minutos. Salao tem movimento irregular:
// com cinco minutos, cada intervalo de calmaria paga a escrita de novo.
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

// Ferramentas: duas de agenda, uma de ficha, uma de desfecho.
//
// POR QUE FERRAMENTA E NAO CONTEXTO PRE-CARREGADO. Nao da para adivinhar antes
// de ler a mensagem qual servico e qual dia a cliente quer; carregar a agenda
// inteira de trinta dias em toda conversa seria caro e inutil.
const FERRAMENTAS: Anthropic.Tool[] = [
  {
    name: 'consultar_horarios',
    description:
      'Consulta a agenda real e devolve os horários livres para um serviço. Use antes de falar qualquer horário: você não sabe a agenda de cabeça.',
    strict: true,
    input_schema: {
      type: 'object',
      properties: {
        servicoId: { type: 'string', description: 'O id do serviço, como está no catálogo.' },
        aPartirDe: {
          type: 'string',
          description:
            'Data de início da busca, no formato AAAA-MM-DD. Use a data de hoje quando a cliente não disser um dia.',
        },
        dias: {
          type: 'integer',
          description:
            'Quantos dias procurar a partir dali. Use 1 para um dia específico, 7 para "essa semana".',
        },
      },
      required: ['servicoId', 'aPartirDe', 'dias'],
      additionalProperties: false,
    },
  },
  {
    name: 'reservar_horario',
    description:
      'Marca o horário de verdade na agenda. Só use depois de a cliente aceitar um horário específico que VOCÊ ofereceu na consulta anterior. Enquanto você não chamar esta ferramenta e receber a confirmação, NÃO EXISTE agendamento nenhum.',
    strict: true,
    input_schema: {
      type: 'object',
      properties: {
        opcao: {
          type: 'integer',
          description: 'O número da opção na última consulta de horários (1, 2, 3...).',
        },
      },
      required: ['opcao'],
      additionalProperties: false,
    },
  },
  // A ficha so anda se alguem escrever nela. Sem isto o agente descobria na
  // conversa que o cabelo e curto, dizia "perfeito, vi aqui" e no minuto
  // seguinte a lista de pendencias mandava perguntar o comprimento de novo.
  //
  // Nao e estrito de proposito: o modelo manda so o que descobriu neste turno,
  // e o que nao vier fica como estava. O banco nunca apaga campo preenchido.
  {
    name: 'anotar_na_ficha',
    description:
      'Guarda na ficha da cliente o que VOCÊ descobriu nesta conversa, seja porque ela contou, seja porque você viu na foto que ela mandou. Mande apenas os campos que você descobriu agora. Use SEMPRE que aparecer uma informação nova, antes de responder.',
    input_schema: {
      type: 'object',
      properties: {
        nome: {
          type: 'string',
          description: 'Como ela quer ser chamada, quando ela disser o nome na conversa.',
        },
        comprimento: {
          type: 'string',
          description:
            'O comprimento do cabelo DELA, com o rótulo exato que aparece nos rótulos válidos. Nunca tire isso de foto de referência.',
        },
        temQuimica: { type: 'boolean', description: 'Se ela tem alguma química no cabelo.' },
        quimicaQual: { type: 'string', description: 'Qual química, nas palavras dela.' },
        quimicaHaQuantoTempo: {
          type: 'string',
          description:
            'Há quanto tempo foi a última química, com as palavras dela: "uns 2 anos", "6 meses". PREFIRA este campo: a conta de calendário é feita pelo sistema.',
        },
        quimicaQuando: {
          type: 'string',
          description: 'Só quando ela disser a data exata, AAAA-MM-DD.',
        },
        quimicaFormol: {
          type: 'string',
          enum: ['COM_FORMOL', 'SEM_FORMOL', 'NAO_SABE'],
          description: 'Só quando ela disser. Nunca deduza.',
        },
        temColoracao: { type: 'boolean', description: 'Se o cabelo é colorido ou tem tintura.' },
        coloracaoHaQuantoTempo: {
          type: 'string',
          description:
            'Há quanto tempo foi a última coloração, com as palavras dela. Prefira este campo.',
        },
        coloracaoQuando: {
          type: 'string',
          description: 'Só quando ela disser a data exata, AAAA-MM-DD.',
        },
        tomQueQuer: {
          type: 'string',
          description:
            'O tom que ela quer alcançar, do jeito que ela descreveu ou como você viu na foto de referência.',
        },
        observacao: {
          type: 'string',
          description:
            'Uma linha sobre o caso dela que a ficha não tem campo para guardar. Some ao que já existe, nunca substitui.',
        },
      },
      additionalProperties: false,
    },
  },
  {
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
            'REPLY: você sabe a resposta e vai falar com a cliente agora. ASK_OWNER: falta uma informação que só a dona tem e você NÃO consegue responder nada de útil agora, a cliente NÃO recebe nada. HANDOFF: assunto delicado que uma pessoa precisa conduzir.',
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
            'A pergunta para a dona, direta e específica. Obrigatória quando action for ASK_OWNER. TAMBÉM pode vir junto de um REPLY: aí você responde à cliente o que sabe e pergunta à dona só o pedaço que falta. Vazio quando não há nada a perguntar.',
        },
        contextSummary: {
          type: 'string',
          description:
            'Uma frase dizendo o que a cliente quer, para a dona responder sem abrir a conversa. Preencha sempre que houver ownerQuestion.',
        },
        reason: {
          type: 'string',
          description: 'Uma frase curta para o painel da equipe. Nunca é enviada à cliente.',
        },
      },
      required: ['action', 'messages', 'ownerQuestion', 'contextSummary', 'reason'],
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

// Segundo fator, alem do verify_jwt: a chave anon satisfaz verify_jwt e e
// publica. O token de worker vive no Vault.
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

// Chama a scheduling-api com o cracha de worker. O motor de disponibilidade
// vive la e continua sendo o unico: o agente consulta, nao recalcula.
async function agenda(
  supabaseUrl: string,
  serviceKey: string,
  workerToken: string,
  corpo: Record<string, unknown>
): Promise<{ ok: boolean; data?: unknown; error?: string }> {
  const r = await fetch(`${supabaseUrl}/functions/v1/scheduling-api`, {
    method: 'POST',
    headers: {
      Authorization: `Bearer ${serviceKey}`,
      'x-worker-token': workerToken,
      'content-type': 'application/json',
    },
    body: JSON.stringify(corpo),
  });
  const body = (await r.json().catch(() => ({}))) as { data?: unknown; error?: string };
  if (!r.ok) return { ok: false, error: body.error ?? `HTTP ${r.status}` };
  return { ok: true, data: body.data };
}

// Horario legivel para uma pessoa em Sao Paulo. A conversao fica aqui e nao no
// modelo: pedir para um modelo transformar milissegundos em "sabado as 8h" e
// convidar um erro que a cliente le como horario confirmado.
function horarioLocal(ms: number): string {
  return new Date(ms).toLocaleString('pt-BR', {
    timeZone: 'America/Sao_Paulo',
    weekday: 'long',
    day: '2-digit',
    month: '2-digit',
    hour: '2-digit',
    minute: '2-digit',
  });
}

type Candidato = {
  startMs: number;
  endMs: number;
  steps: unknown[];
};

type EstadoDaConversa = {
  configurationVersionId?: string;
  serviceId?: string;
  serviceName?: string;
  candidatos: Candidato[];
};

// O que a conversa ja decidiu sobre agenda, lido do banco no inicio da leva.
// Sem isso o servico e reescolhido do zero a cada leva de mensagens: foi assim
// que o agente ofereceu sabado as 8h para um servico de 240 min e, na leva
// seguinte, consultou a agenda para outro de 360 min -- que nao cabe em
// sabado nenhum -- e concluiu que o horario tinha sumido.
type Foco = {
  serviceId: string;
  serviceName: string;
  configurationVersionId: string | null;
  candidates: Candidato[];
  ageMinutes: number;
};

// Depois disso os horarios guardados nao valem mais: outra cliente pode ter
// pegado. O servico continua valendo -- ele nao vence.
const FOCO_CANDIDATOS_VALIDOS_MINUTOS = 12 * 60;

// O teto de voltas existe para o caso de o modelo insistir em consultar sem
// nunca decidir: sem ele, uma conversa confusa viraria uma sequencia infinita
// de chamadas pagas.
const MAX_VOLTAS = 4;

async function decidir(
  anthropic: Anthropic,
  regras: string,
  estavel: unknown,
  volatil: unknown,
  ambiente: {
    supabaseUrl: string;
    serviceKey: string;
    workerToken: string;
    tenantId: string;
    unitId: string;
    conversationId: string;
    clientePhone: string | null;
    clienteNome: string | null;
  }
): Promise<{
  decisao: Decisao | null;
  usage: Uso;
  motivoFalha?: string;
  agendou?: { quando: string; appointmentId: string } | null;
}> {
  // A DIRETRIZ DO TURNO, colada depois do JSON da conversa: e a ultima coisa
  // que o modelo le antes de decidir. Nasceu de tres erros seguidos.
  //
  // 1. A lista `client.missing` chegava completa e ele oferecia horario assim
  //    mesmo, porque o historico tinha ele proprio oferecendo aquele horario
  //    antes. Regra la atras no prompt perdia para o peso da conversa.
  // 2. Corrigido isso, ele passou a pedir foto do cabelo de quem so tinha dado
  //    bom dia. Por isso a diretriz tem dois caminhos, e o primeiro e
  //    simplesmente receber quem chegou.
  // 3. A cliente respondeu "faz uns 2 anos" no meio de outra frase, ele anotou
  //    metade, a pendencia continuou aberta e a diretriz mandou perguntar de
  //    novo o que ela ja tinha dito.
  const faltas =
    (volatil as { client?: { missing?: Array<{ campo: string; perguntaSugerida: string }> } })
      ?.client?.missing ?? [];
  const investigando = faltas.length > 0;

  const diretrizDoTurno = investigando
    ? '\n\nATENÇÃO, ISTO VALE PARA ESTA RESPOSTA E GANHA DE TUDO:\n' +
      'A ficha desta cliente está incompleta. Faltam ' +
      faltas.length +
      ' informações.\n' +
      'Antes de escrever, decida em que ponto a conversa está.\n' +
      '\n' +
      'CAMINHO A: ela ainda NÃO disse o que quer fazer (só cumprimentou, só falou oi). Então\n' +
      'você ACOLHE e não pergunta NADA sobre o cabelo:\n' +
      '  1) o cumprimento, devolvendo a pergunta se ela perguntou como você está;\n' +
      '  2) se você não sabe o nome dela, "Qual o seu nome?" e PARA aí;\n' +
      '     se você já sabe, dê as boas-vindas com o nome e pergunte como pode ajudar.\n' +
      '\n' +
      'CAMINHO B: ela JÁ disse o que quer. Aí sim a ficha entra:\n' +
      '  1) o cumprimento, se você ainda não cumprimentou nesta leva de mensagens;\n' +
      '  2) esta pergunta:\n' +
      '     "' +
      faltas[0].perguntaSugerida +
      '"\n' +
      'Pode reescrever com as suas palavras.\n' +
      'ANTES DE PERGUNTAR, releia o histórico. Se ela JÁ respondeu isso em alguma mensagem, mesmo ' +
      'de passagem, NÃO pergunte de novo: chame anotar_na_ficha com o que ela disse e siga para o ' +
      'assunto seguinte.\n' +
      '\n' +
      'Nos dois caminhos: NÃO ofereça horário, NÃO confirme horário e NÃO insista num horário ' +
      'que você já ofereceu antes nesta conversa.\n' +
      'E NÃO comente, conclua nem tranquilize sobre o que a cliente acabou de te contar: anote e ' +
      'siga. Quem diz o que a química dela significa é a avaliação, nunca você.'
    : '';

  const mensagens: Anthropic.MessageParam[] = [
    {
      role: 'user',
      content:
        'Esta conversa (JSON). A última mensagem do histórico é a que está esperando resposta.\n\n' +
        JSON.stringify(volatil) +
        diretrizDoTurno,
    },
  ];

  // O foco e lido antes da primeira volta: e ele que impede o servico de
  // trocar sozinho entre uma leva de mensagens e a seguinte.
  let foco: Foco | null = null;
  try {
    foco = (await rpc(ambiente.supabaseUrl, ambiente.serviceKey, 'agent_scheduling_focus', {
      p_conversation_id: ambiente.conversationId,
    })) as Foco | null;
  } catch (erro) {
    console.error('FOCO_LEITURA_FALHOU', ambiente.conversationId, String(erro));
  }

  // O servico com que a conversa ENTROU neste turno. E ele que manda na hora
  // de reservar: consultar outro servico e so informacao, mas marcar outro
  // servico e mandar a cliente para o procedimento errado.
  const servicoDoInicioDoTurno = foco?.serviceId ?? null;

  const estado: EstadoDaConversa = { candidatos: [] };
  if (foco?.serviceId) {
    estado.serviceId = foco.serviceId;
    estado.serviceName = foco.serviceName;
    if (foco.ageMinutes <= FOCO_CANDIDATOS_VALIDOS_MINUTOS) {
      estado.configurationVersionId = foco.configurationVersionId ?? undefined;
      estado.candidatos = foco.candidates ?? [];
    }
  }

  // A diretriz da agenda vai colada na mesma mensagem, depois da diretriz da
  // ficha: e a ultima coisa que o modelo le antes de escolher a ferramenta.
  if (foco?.serviceId) {
    const primeira = mensagens[0];
    primeira.content =
      (primeira.content as string) +
      '\n\nESTA CONVERSA JÁ ESTÁ NUM SERVIÇO: ' +
      foco.serviceName +
      '.\n' +
      'Foi nesse serviço que você consultou a agenda e foi dele que saiu qualquer horário ' +
      'que você já ofereceu. Se precisar consultar a agenda de novo, consulte ESSE serviço.\n' +
      'Só troque de serviço se a CLIENTE pedir outra coisa - e, se trocar, diga a ela que ' +
      'trocou, porque o horário e o tempo mudam junto.' +
      (estado.candidatos.length > 0
        ? '\nOs horários que você já tem na mão para esse serviço:\n' +
          estado.candidatos.map((c, i) => `${i + 1}. ${horarioLocal(c.startMs)}`).join('\n') +
          '\nSe ela aceitou um desses, chame reservar_horario com o número dele. ' +
          'Não precisa consultar de novo.'
        : '');
  }

  const usage: Uso = {
    input_tokens: 0,
    output_tokens: 0,
    cache_creation_input_tokens: 0,
    cache_read_input_tokens: 0,
  };
  let agendou: { quando: string; appointmentId: string } | null = null;

  for (let volta = 0; volta < MAX_VOLTAS; volta++) {
    const resposta = await anthropic.messages.create({
      model: MODELO,
      max_tokens: 2000,
      thinking: { type: 'adaptive' },
      output_config: { effort: ESFORCO },
      // O prompt vem do banco e os dados do negocio vem do contexto. A marca de
      // cache fica no segundo bloco e cobre o prefixo inteiro: por isso a
      // ordem dos blocos do prompt e deterministica no banco.
      system: [
        { type: 'text', text: regras },
        {
          type: 'text',
          text: 'DADOS DESTE NEGÓCIO (JSON):\n' + JSON.stringify(estavel),
          cache_control: { type: 'ephemeral', ttl: CACHE_TTL },
        },
      ],
      // Sem ficha, sem reserva. Nao e castigo: marcar quimica sem saber o que
      // ja foi feito naquele cabelo e o erro que queima cliente.
      tools: investigando ? FERRAMENTAS.filter((f) => f.name !== 'reservar_horario') : FERRAMENTAS,
      tool_choice: { type: 'any' },
      messages: mensagens,
    });

    const u = (resposta.usage ?? {}) as Uso;
    usage.input_tokens! += u.input_tokens ?? 0;
    usage.output_tokens! += u.output_tokens ?? 0;
    usage.cache_creation_input_tokens! += u.cache_creation_input_tokens ?? 0;
    usage.cache_read_input_tokens! += u.cache_read_input_tokens ?? 0;

    if (resposta.stop_reason === 'refusal') {
      return { decisao: null, usage, motivoFalha: 'MODEL_REFUSAL' };
    }

    const chamadas = resposta.content.filter(
      (b): b is Anthropic.ToolUseBlock => b.type === 'tool_use'
    );
    if (chamadas.length === 0) {
      return { decisao: null, usage, motivoFalha: 'NO_TOOL_CALL' };
    }

    // `atender` encerra, mesmo que o modelo tenha pedido outras coisas junto.
    const desfecho = chamadas.find((c) => c.name === 'atender');
    if (desfecho) {
      return { decisao: desfecho.input as Decisao, usage, agendou };
    }

    mensagens.push({ role: 'assistant', content: resposta.content });

    const resultados: Anthropic.ToolResultBlockParam[] = [];

    for (const chamada of chamadas) {
      let texto: string;

      if (chamada.name === 'consultar_horarios') {
        const args = chamada.input as { servicoId: string; aPartirDe: string; dias: number };
        // A troca silenciosa de servico e o erro que esta consulta existe para
        // pegar: mesmo horario, servico com outra duracao, agenda responde
        // outra coisa. Nao bloqueio -- a cliente pode ter mudado de ideia --
        // mas o modelo tem que ler em voz alta que trocou.
        const trocouDeServico =
          !!estado.serviceId && !!args.servicoId && args.servicoId !== estado.serviceId;
        const servicoAnterior = estado.serviceName;
        const busca = await agenda(
          ambiente.supabaseUrl,
          ambiente.serviceKey,
          ambiente.workerToken,
          {
            action: 'searchSlots',
            tenantId: ambiente.tenantId,
            unitId: ambiente.unitId,
            serviceId: args.servicoId,
            searchFrom: `${args.aPartirDe}T00:00:00-03:00`,
            searchDays: Math.min(Math.max(args.dias ?? 7, 1), 30),
            clientPhoneDigits: ambiente.clientePhone,
            clientName: ambiente.clienteNome,
          }
        );

        if (!busca.ok) {
          texto = `Não foi possível consultar a agenda: ${busca.error}. Não invente horário, use ASK_OWNER.`;
        } else {
          const dados = busca.data as {
            configurationVersionId: string;
            serviceId: string;
            candidates: Candidato[];
          };
          estado.configurationVersionId = dados.configurationVersionId;
          estado.serviceId = dados.serviceId;
          estado.candidatos = dados.candidates ?? [];

          // O foco vira fato no banco: a proxima leva de mensagens le isso e
          // consulta o mesmo servico em vez de escolher outro do zero.
          try {
            const gravado = (await rpc(
              ambiente.supabaseUrl,
              ambiente.serviceKey,
              'agent_set_scheduling_focus',
              {
                p_tenant_id: ambiente.tenantId,
                p_conversation_id: ambiente.conversationId,
                p_service_id: dados.serviceId,
                p_configuration_version_id: dados.configurationVersionId,
                p_candidates: estado.candidatos,
              }
            )) as { serviceName?: string } | null;
            estado.serviceName = gravado?.serviceName ?? estado.serviceName;
          } catch (erro) {
            console.error('FOCO_GRAVACAO_FALHOU', ambiente.conversationId, String(erro));
          }

          const cabecalho = estado.serviceName ? `Agenda de ${estado.serviceName}:` : 'Agenda:';

          const aviso = trocouDeServico
            ? `ATENÇÃO: esta conversa estava em ${servicoAnterior ?? 'outro serviço'} e você ` +
              `acabou de consultar ${estado.serviceName ?? 'um serviço diferente'}. Serviços ` +
              'diferentes têm durações diferentes, então os horários mudam. Se a cliente não ' +
              'pediu para trocar, consulte de novo o serviço de antes. Se ela pediu, avise a ' +
              'ela que o horário mudou junto.\n\n'
            : '';

          texto =
            aviso +
            (estado.candidatos.length === 0
              ? `${cabecalho} nenhum horário livre nesse período. Isso é a agenda falando: ` +
                'esse horário não existe. Não peça para a dona confirmar assim mesmo - ' +
                'ofereça outro período ou outro dia.'
              : cabecalho +
                '\n' +
                estado.candidatos
                  .map(
                    (c, i) =>
                      `${i + 1}. ${horarioLocal(c.startMs)} (termina ${horarioLocal(c.endMs)})`
                  )
                  .join('\n') +
                '\n\nISTO AINDA NÃO É UM AGENDAMENTO. Só existe agendamento depois de reservar_horario.');
        }
      } else if (chamada.name === 'reservar_horario') {
        const args = chamada.input as { opcao: number };
        const escolhido = estado.candidatos[(args.opcao ?? 1) - 1];

        // A TRAVA DO SERVICO. Aviso nao basta: o modelo ja leu o aviso, trocou
        // de servico assim mesmo e marcou 13h de um procedimento de 5 horas
        // para uma cliente que tinha aceitado 8h de outro. Dentro de um turno
        // o servico nao muda. Trocar exige um turno novo -- que e o tempo de
        // dizer a cliente que trocou.
        const trocouNaHoraDeMarcar =
          servicoDoInicioDoTurno != null &&
          estado.serviceId != null &&
          estado.serviceId !== servicoDoInicioDoTurno;

        if (trocouNaHoraDeMarcar) {
          console.error(
            JSON.stringify({
              event: 'reserva_bloqueada_por_troca_de_servico',
              conversationId: ambiente.conversationId,
              servicoDoTurno: servicoDoInicioDoTurno,
              servicoTentado: estado.serviceId,
            })
          );
          texto =
            'NÃO reservei: esta conversa era de outro serviço e você trocou no meio. ' +
            'Marcar o serviço errado é pior que não marcar. Consulte de novo o serviço de ' +
            'antes e ofereça o horário dele. Se a cliente realmente quer outro serviço, ' +
            'fale isso com ela primeiro e marque na próxima mensagem.';
        } else if (!escolhido || !estado.configurationVersionId || !estado.serviceId) {
          texto = 'Essa opção não existe. Consulte os horários antes de reservar.';
        } else {
          // Reserva temporaria e confirmacao, na sequencia. O hold protege a
          // corrida entre duas clientes pedindo o mesmo horario no mesmo
          // segundo.
          const hold = await agenda(
            ambiente.supabaseUrl,
            ambiente.serviceKey,
            ambiente.workerToken,
            {
              action: 'createHold',
              tenantId: ambiente.tenantId,
              unitId: ambiente.unitId,
              configurationVersionId: estado.configurationVersionId,
              serviceId: estado.serviceId,
              startsAt: new Date(escolhido.startMs).toISOString(),
              endsAt: new Date(escolhido.endMs).toISOString(),
              plan: { steps: escolhido.steps },
              idempotencyKey: `agente:${ambiente.tenantId}:${escolhido.startMs}:${estado.serviceId}`,
            }
          );

          if (!hold.ok) {
            texto = `Não deu para segurar esse horário: ${hold.error}. Consulte de novo e ofereça outro.`;
          } else {
            const holdId = (hold.data as { holdId?: string }).holdId;
            const confirmacao = await agenda(
              ambiente.supabaseUrl,
              ambiente.serviceKey,
              ambiente.workerToken,
              {
                action: 'confirmHold',
                tenantId: ambiente.tenantId,
                unitId: ambiente.unitId,
                holdId,
                customerLabel: ambiente.clienteNome,
              }
            );
            if (!confirmacao.ok) {
              texto = `A reserva não foi confirmada: ${confirmacao.error}. Não diga que está marcado.`;
            } else {
              const dados = confirmacao.data as { appointmentId?: string };
              agendou = {
                quando: horarioLocal(escolhido.startMs),
                appointmentId: dados.appointmentId ?? '',
              };
              // Marcou: o foco morre. Se ela voltar amanha para marcar outra
              // coisa, comeca do zero em vez de arrastar os candidatos de um
              // agendamento que ja aconteceu.
              try {
                await rpc(
                  ambiente.supabaseUrl,
                  ambiente.serviceKey,
                  'agent_clear_scheduling_focus',
                  { p_conversation_id: ambiente.conversationId }
                );
              } catch (erro) {
                console.error('FOCO_LIMPEZA_FALHOU', ambiente.conversationId, String(erro));
              }
              estado.candidatos = [];
              texto = `Marcado com sucesso para ${horarioLocal(escolhido.startMs)}. Agora sim, confirme para a cliente.`;
            }
          }
        }
      } else if (chamada.name === 'anotar_na_ficha') {
        // Falhar aqui nao derruba o turno: a cliente esperando resposta importa
        // mais que um campo que pode ser perguntado de novo depois.
        try {
          const gravado = (await rpc(
            ambiente.supabaseUrl,
            ambiente.serviceKey,
            'record_client_facts_for_conversation',
            { p_conversation_id: ambiente.conversationId, p_facts: chamada.input }
          )) as {
            ok?: boolean;
            ignorados?: string[];
            aindaFalta?: Array<{ perguntaSugerida: string }>;
          };

          if (gravado?.ok) {
            const falta = gravado.aindaFalta ?? [];
            texto =
              'Anotado na ficha.' +
              (gravado.ignorados?.length
                ? ` Não deu para gravar: ${gravado.ignorados.join(', ')}.`
                : '') +
              (falta.length
                ? ` Ainda falta saber ${falta.length}. A próxima pergunta é: "${falta[0].perguntaSugerida}"`
                : ' A ficha está completa, pode seguir para o horário.');
          } else {
            texto = 'Não deu para anotar agora. Siga a conversa normalmente.';
          }
        } catch (erroFicha) {
          console.error(JSON.stringify({ event: 'ficha_write_failed', erro: String(erroFicha) }));
          texto = 'Não deu para anotar agora. Siga a conversa normalmente.';
        }
      } else {
        texto = 'Ferramenta desconhecida.';
      }

      resultados.push({ type: 'tool_result', tool_use_id: chamada.id, content: texto });
    }

    mensagens.push({ role: 'user', content: resultados });
  }

  return { decisao: null, usage, motivoFalha: 'MAX_VOLTAS_ATINGIDO', agendou };
}

Deno.serve(async (req) => {
  const supabaseUrl = Deno.env.get('SUPABASE_URL');
  const serviceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
  const anthropicKey = Deno.env.get('ANTHROPIC_API_KEY');

  if (!supabaseUrl || !serviceKey) {
    return json(500, { ok: false, reason: 'SUPABASE_ENV_MISSING' });
  }
  if (!(await autorizado(req, supabaseUrl, serviceKey))) {
    return json(401, { ok: false, reason: 'WORKER_TOKEN_INVALID' });
  }
  if (!anthropicKey) {
    return json(500, { ok: false, reason: 'ANTHROPIC_API_KEY_MISSING' });
  }

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
    return json(200, {
      ok: true,
      aguardando: 0,
      respondidas: 0,
      perguntadas: 0,
      repassadas: 0,
      falhas: 0,
    });
  }

  // O PROMPT VEM DO BANCO, uma vez por lote.
  //
  // Uma vez, e nao por conversa, por dois motivos: e o mesmo texto para todas,
  // e ele precisa ser byte a byte identico entre as chamadas para o cache da
  // API valer.
  //
  // Se nao vier, o lote inteiro para. Agente sem regra nenhuma conversando com
  // cliente de verdade e pior que agente calado: sem o prompt ele nao sabe que
  // nao pode inventar preco, nem que nao pode afirmar agendamento.
  let regras: string;
  try {
    regras = ((await rpc(supabaseUrl, serviceKey, 'agent_prompt', {})) as string) ?? '';
  } catch (erro) {
    console.error(JSON.stringify({ event: 'prompt_read_failed', erro: String(erro) }));
    return json(500, { ok: false, reason: 'PROMPT_READ_FAILED', detail: String(erro) });
  }
  if (regras.trim().length < 500) {
    console.error(JSON.stringify({ event: 'prompt_vazio', tamanho: regras.length }));
    return json(500, { ok: false, reason: 'PROMPT_VAZIO', tamanho: regras.length });
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
      })) as {
        ok?: boolean;
        reason?: string;
        unitId?: string;
        stable?: unknown;
        volatile?: unknown;
      };

      if (!contexto?.ok) {
        throw new Error(`contexto indisponivel: ${contexto?.reason ?? 'desconhecido'}`);
      }

      const volatilTipado = contexto.volatile as
        { contact?: { whatsapp?: string | null; displayName?: string | null } } | undefined;

      const { decisao, usage, motivoFalha, agendou } = await decidir(
        anthropic,
        regras,
        contexto.stable,
        contexto.volatile,
        {
          supabaseUrl,
          serviceKey,
          workerToken: req.headers.get('x-worker-token') ?? '',
          tenantId: item.tenant_id,
          unitId: contexto.unitId ?? '',
          conversationId: item.conversation_id,
          clientePhone: volatilTipado?.contact?.whatsapp ?? null,
          clienteNome: volatilTipado?.contact?.displayName ?? null,
        }
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
        .slice(0, 3)
        // Cinto e suspensorio para a regra do travessao: mesmo instruido, o
        // modelo escorrega, e um travessao sozinho ja entrega a maquina.
        .map((t) => t.replace(/\s*—\s*/g, ' - ').replace(/\s*–\s*/g, ' - '));

      // NAO SE ANUNCIA UM AGENDAMENTO QUE NAO EXISTE.
      //
      // O modelo escreveu "seu horario de sabado 05/09 as 8h ja esta
      // confirmado" sem ter chamado reservar_horario. A ferramenta estava na
      // mesa e a ficha estava completa; ele simplesmente afirmou. Nenhuma regra
      // de prompt pode ser a unica defesa: uma cliente que aparece no salao num
      // horario que ninguem sabe que existe e o pior desfecho do produto.
      const AFIRMA_AGENDAMENTO =
        /(est[áa]\s+(confirmad|marcad|agendad|reservad)|j[áa]\s+est[áa]\s+(confirmad|marcad)|foi\s+(confirmad|marcad|agendad|reservad)|deixei\s+(marcad|reservad)|agendamento\s+confirmad)/i;
      const mentiuAgendamento = agendou == null && textos.some((t) => AFIRMA_AGENDAMENTO.test(t));

      let acao = decisao.action;
      if (mentiuAgendamento) {
        console.error(
          JSON.stringify({
            event: 'agendamento_afirmado_sem_reserva',
            conversationId: item.conversation_id,
            textos,
          })
        );
        acao = 'HANDOFF';
      }
      // REPLY sem texto seria um envio em branco. Vale o que o modelo fez, nao
      // o rotulo que ele deu.
      if (acao === 'REPLY' && textos.length === 0) acao = 'HANDOFF';
      if (acao === 'ASK_OWNER' && (decisao.ownerQuestion ?? '').trim().length < 3) acao = 'HANDOFF';

      if (dryRun) {
        resultados.push({
          conversationId: item.conversation_id,
          trigger: item.trigger,
          action: acao,
          reason: decisao.reason,
          messages: textos,
          ownerQuestion: (decisao.ownerQuestion ?? '').trim() || undefined,
          contextSummary: decisao.contextSummary,
          agendou: agendou ?? undefined,
          mentiuAgendamento: mentiuAgendamento || undefined,
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
              // sobre a mesma mensagem.
              p_idempotency_key: `agent:${item.last_inbound_message_id}:${item.trigger}:${i}`,
            })
          );
        }
        await rpc(supabaseUrl, serviceKey, 'consume_owner_answers', {
          p_tenant_id: item.tenant_id,
          p_conversation_id: item.conversation_id,
        });

        // RESPONDER E PERGUNTAR AO MESMO TEMPO.
        //
        // A cliente escreveu "pode sim" e, na mensagem seguinte, "voce passa
        // cartao?". As duas cairam no mesmo turno. Com uma decisao so por
        // turno, a duvida sobre pagamento virou ASK_OWNER, e ASK_OWNER e
        // silencio total: o aceite do horario morreu junto.
        const perguntaJunto = (decisao.ownerQuestion ?? '').trim();
        if (perguntaJunto.length >= 3) {
          try {
            await rpc(supabaseUrl, serviceKey, 'record_owner_question', {
              p_tenant_id: item.tenant_id,
              p_conversation_id: item.conversation_id,
              p_message_id: item.last_inbound_message_id,
              p_question: perguntaJunto,
              p_context_summary: decisao.contextSummary,
            });
          } catch (erroPergunta) {
            console.error(
              JSON.stringify({
                event: 'owner_question_with_reply_failed',
                erro: String(erroPergunta),
              })
            );
          }
        }
      } else if (acao === 'ASK_OWNER') {
        await rpc(supabaseUrl, serviceKey, 'record_owner_question', {
          p_tenant_id: item.tenant_id,
          p_conversation_id: item.conversation_id,
          p_message_id: item.last_inbound_message_id,
          p_question: decisao.ownerQuestion,
          p_context_summary: decisao.contextSummary,
        });
      }

      // So marca depois de agir. Se o enfileiramento estourar, a mensagem fica
      // sem decisao e volta na proxima rodada.
      await rpc(supabaseUrl, serviceKey, 'mark_agent_decision', {
        p_tenant_id: item.tenant_id,
        p_message_id: item.last_inbound_message_id,
        p_decision: acao,
        p_reason: mentiuAgendamento
          ? 'BLOQUEADO: afirmou agendamento sem ter reservado. ' + (decisao.reason ?? '')
          : decisao.reason,
      });

      try {
        await rpc(supabaseUrl, serviceKey, 'clear_agent_failures', {
          p_tenant_id: item.tenant_id,
          p_conversation_id: item.conversation_id,
        });
      } catch (erroLimpeza) {
        console.error(
          JSON.stringify({ event: 'clear_failures_failed', erro: String(erroLimpeza) })
        );
      }

      if (acao === 'REPLY') respondidas++;
      else if (acao === 'ASK_OWNER') perguntadas++;
      else repassadas++;

      resultados.push({
        conversationId: item.conversation_id,
        trigger: item.trigger,
        action: acao,
        reason: decisao.reason,
        messages: acao === 'REPLY' ? textos : [],
        bloqueadas: mentiuAgendamento ? textos : undefined,
        ownerQuestion: (decisao.ownerQuestion ?? '').trim() || undefined,
        agendou: agendou ?? undefined,
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
        })
      );

      // Falha do modelo (recusa, formato) e definitiva para ESTA mensagem:
      // repetir gastaria token para chegar ao mesmo lugar. Falha de rede ou de
      // banco e passageira e merece nova tentativa.
      const definitiva = detalhe.includes('MODEL_REFUSAL') || detalhe.includes('NO_TOOL_CALL');

      // Toda falha e registrada: e esse registro que afasta a proxima tentativa
      // (2, 4, 8, 16 minutos) e estaciona a conversa no quinto tropeco.
      let parada: { failures?: number; parked?: boolean } = {};
      try {
        parada = (await rpc(supabaseUrl, serviceKey, 'record_agent_failure', {
          p_tenant_id: item.tenant_id,
          p_conversation_id: item.conversation_id,
          p_detail: detalhe.slice(0, 800),
          p_definitive: definitiva,
        })) as { failures?: number; parked?: boolean };
      } catch (erroRegistro) {
        console.error(
          JSON.stringify({ event: 'record_failure_failed', erro: String(erroRegistro) })
        );
      }

      if (definitiva) {
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
        falhasSeguidas: parada.failures,
        // Estacionada = o agente desistiu e a conversa espera uma pessoa.
        estacionada: parada.parked === true ? true : undefined,
      });
    }
  }

  console.log(
    JSON.stringify({
      event: 'agent_batch_done',
      modelo: MODELO,
      promptBytes: regras.length,
      aguardando: fila.length,
      respondidas,
      perguntadas,
      repassadas,
      falhas,
      dryRun,
      uso: somaUso,
    })
  );

  return json(200, {
    ok: true,
    modelo: MODELO,
    promptBytes: regras.length,
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
