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

import { falasDaConversa, travaDoProcedimento } from './antes-do-horario.ts';
import { avisoDeVolta, frasesRepetidas, voltasDaCliente } from './nao-insista.ts';
import {
  condicaoComercialIgnorada,
  respostaSemProximoPasso,
  ultimaLevaDaCliente,
} from './fecha-a-conversa.ts';
import { precosDoNegocio, precosSemLastro } from './preco-com-lastro.ts';
import { camposCorrompidos, semEscapes, semMarcacao } from './resposta-limpa.ts';

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
        aPartirDaHora: {
          type: 'string',
          description:
            'Hora a partir da qual procurar, HH:MM, quando a cliente pediu uma hora ("às 10h" -> "10:00", "à tarde" -> "13:00"). Vazio ("") quando ela não pediu hora.',
        },
      },
      required: ['servicoId', 'aPartirDe', 'dias', 'aPartirDaHora'],
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
            'REPLY: você sabe a resposta e vai falar com a cliente agora. ASK_OWNER: falta uma informação que só a dona tem e você NÃO consegue responder nada de útil agora; a cliente recebe sozinha um aviso de que vai ser confirmado, e você não escreve nada. HANDOFF: assunto delicado que uma pessoa precisa conduzir.',
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
            'Uma PERGUNTA para a dona, direta e específica, que ela responde com uma frase. Obrigatória quando action for ASK_OWNER. TAMBÉM pode vir junto de um REPLY: aí você responde à cliente o que sabe e pergunta à dona só o pedaço que falta. Resumo do atendimento não é pergunta: sem pergunta de verdade, vazio.',
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
  // Quantas idas ao modelo esta mensagem custou. E o numero que diz se o
  // agente esta resolvendo de primeira ou tateando.
  voltas?: number;
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

/** Os nomes dos servicos do salao, sem repetir (rascunho e publicado). */
function nomesDoCatalogo(estavel: unknown): string[] {
  const catalogo = (estavel as { catalog?: unknown } | null)?.catalog;
  if (!Array.isArray(catalogo)) return [];
  const nomes = new Set<string>();
  for (const servico of catalogo) {
    const nome = (servico as { name?: unknown })?.name;
    if (typeof nome === 'string' && nome.trim().length > 0) nomes.add(nome.trim());
  }
  return [...nomes];
}

/** O que devolver ao modelo quando a trava do procedimento pega a resposta. */
function recadoDaTrava(
  falta: 'PROCEDIMENTO' | 'PRECO' | 'AFIRMOU' | 'IRMAOS' | 'AVALIAR',
  opcoes: string[],
  servico: string | null
): string {
  if (falta === 'PRECO') {
    return (
      'NAO ENVIEI. Voce esta oferecendo horario sem a cliente ter ouvido QUANTO custa. ' +
      'Diga o valor do procedimento antes do horario, na mesma leva. Ninguem marca sem ' +
      'saber quanto vai pagar.'
    );
  }

  if (falta === 'AVALIAR') {
    return (
      'NAO ENVIEI. Ela te pediu INDICACAO, e voce respondeu com cardapio.\n' +
      '"Qual e melhor" nao tem resposta de catalogo, tem resposta de cabelo. Quem indica ' +
      'quimica precisa saber o TOM que ela quer e COMO O CABELO DELA ESTA hoje -- e as duas ' +
      'coisas voce ainda nao tem na ficha. Listar servico antes disso e empurrar a escolha ' +
      'para ela, que e justo quem nao tem como escolher: ela veio perguntar porque nao sabe.\n' +
      'Entao a resposta deste turno e PEDIR o que decide: a foto do cabelo dela hoje e o tom ' +
      'que ela quer alcancar, uma coisa por vez. Diga em uma linha por que voce esta pedindo ' +
      '("pra te indicar a certa eu preciso ver como ele esta"), e so.\n' +
      'Preco, lista de opcoes e horario ficam para depois da foto.'
    );
  }

  if (falta === 'IRMAOS') {
    return (
      'NAO ENVIEI. O que ela pediu cabe em MAIS DE UM servico deste salao: ' +
      opcoes.join(', ') +
      '. Quem escolhe entre eles e ela, nunca voce -- e menos ainda pelo que voce leu na ' +
      'ficha dela. Voce escreveu preco, horario ou o nome de um deles como se estivesse ' +
      'decidido; ela le isso como decisao tomada.\n' +
      'Reescreva assim: diga as opcoes COM O QUE DIFERENCIA uma da outra, em uma linha ' +
      'cada, e termine perguntando qual. Se o valor for o mesmo em todas, pode dizer o ' +
      'valor -- desde que a pergunta de qual esteja na mesma resposta.\n' +
      'MAS ATENCAO: isso vale quando o que separa os irmaos e PREFERENCIA DELA. Quando o ' +
      'que separa depende do CABELO dela -- o tom, a textura, se tem cor, o estado do fio -- ' +
      'listar nao ajuda, porque ela nao tem como escolher. Ai a resposta e pedir a foto do ' +
      'cabelo e o tom que ela quer, e indicar depois de ver.\n' +
      'E se voce JA tinha afirmado um deles antes nesta conversa, comece reconhecendo: ' +
      'ela precisa saber que aquilo mudou, senao fica achando que ja estava combinado.'
    );
  }

  if (falta === 'AFIRMOU') {
    return (
      'NAO ENVIEI. Voce escreveu "' +
      (servico ?? 'esse procedimento') +
      '" como se estivesse combinado, e a cliente NUNCA pediu isso (ou ja disse que nao e ' +
      'isso). Quando voce afirma, ela le como decisao tomada. Se voce acha que e esse o ' +
      'procedimento, PERGUNTE -- e se ela nao disse o que quer, a pergunta e essa, sem ' +
      'nome de servico nenhum junto.'
    );
  }

  return (
    'NAO ENVIEI. Voce esta oferecendo horario de um procedimento que a CLIENTE nao escolheu. ' +
    'Nao vale voce ter escrito o nome antes: o que vale e ela ter pedido, com as palavras ' +
    'dela, ou ter dito sim quando voce perguntou. Antes do horario: pergunte o que ela quer ' +
    'fazer, confirme com o nome do servico e diga o valor. As perguntas sobre o cabelo dela ' +
    'so fazem sentido depois que voce souber o procedimento.'
  );
}

// O teto de voltas existe para o caso de o modelo insistir em consultar sem
// nunca decidir: sem ele, uma conversa confusa viraria uma sequencia infinita
// de chamadas pagas.
// Sao quatro cobrancas possiveis, cada uma disparando no maximo uma vez:
// chamada corrompida, trava do procedimento, resposta sem proximo passo e
// frase repetida. Com o teto em 4, a quarta nunca chegava a caber.
const MAX_VOLTAS = 5;

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
      'E se você JÁ FEZ essa pergunta antes nesta conversa e ela não respondeu, não reenvie a ' +
      'mesma frase. Ela leu e não respondeu: ou não era a hora, ou o que ela queria era outra ' +
      'coisa. Responda o que ela perguntou agora; a ficha espera.\n' +
      '\n' +
      'Nos dois caminhos: NÃO ofereça horário, NÃO confirme horário e NÃO insista num horário ' +
      'que você já ofereceu antes nesta conversa.\n' +
      'E NÃO comente, conclua nem tranquilize sobre o que a cliente acabou de te contar: anote e ' +
      'siga. Quem diz o que a química dela significa é a avaliação, nunca você.'
    : '';

  // ELA VOLTOU NUM PONTO QUE JÁ FOI TRATADO.
  //
  // Vem antes da diretriz da ficha de propósito: quando a cliente corrige, a
  // correção ganha do checklist. Foi o checklist que, em 16/09, reenviou a
  // pergunta da foto palavra por palavra enquanto ela perguntava outra coisa.
  // O porquê está em nao-insista.ts.
  const avisoDaVolta = avisoDeVolta(voltasDaCliente(falasDaConversa(volatil)));

  const mensagens: Anthropic.MessageParam[] = [
    {
      role: 'user',
      content:
        'Esta conversa (JSON). A última mensagem do histórico é a que está esperando resposta.\n\n' +
        JSON.stringify(volatil) +
        (avisoDaVolta ? '\n\n' + avisoDaVolta : '') +
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
          'Não precisa consultar de novo.\n' +
          // 24/09/2026: a cliente pediu 10h, a lista guardada ia de 08:00 a
          // 09:45 (so os primeiros livres) e a atendente disse duas vezes que
          // 10h nao tinha -- com o sabado vazio.
          'Esta lista são só os PRIMEIROS livres da última consulta, não a agenda inteira. ' +
          'Se ela pedir um horário que não está aqui, consulte de novo com aPartirDaHora nele antes de dizer que não tem.'
        : '');
  }

  const usage: Uso = {
    input_tokens: 0,
    output_tokens: 0,
    cache_creation_input_tokens: 0,
    cache_read_input_tokens: 0,
    voltas: 0,
  };
  let agendou: { quando: string; appointmentId: string } | null = null;
  // A cobranca do proximo passo acontece UMA vez por turno. Duas seria um
  // agente discutindo consigo mesmo, e cada volta custa dinheiro.
  let jaCobreiOProximoPasso = false;
  let jaCobreiACorrupcao = false;
  let jaCobreiOHorarioPrematuro = false;
  // "Nao tem" so depois de consultar. 24/09/2026: a cliente pediu 10h duas
  // vezes e ouviu "ja olhei de novo, 10h nao tem mesmo" -- sem consulta
  // nenhuma naquele turno, com o sabado vazio.
  let consultouNesteTurno = false;
  let jaCobreiONaoTem = false;
  let jaCobreiARepeticao = false;
  // A conversa inteira, as duas vozes. Sem a voz DELA nao da para saber se o
  // procedimento foi escolhido ou se foi o agente que inventou.
  const conversa = falasDaConversa(volatil);
  const catalogoDeNomes = nomesDoCatalogo(estavel);
  const levaDaCliente = ultimaLevaDaCliente(volatil);

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
        // DUAS CAMADAS DE CACHE, E A PRIMEIRA E O GANHO DE SER MULTIEMPRESA.
        //
        // As ferramentas e estas regras sao IGUAIS para todo salao -- sao a
        // regua da profissao, nao o vocabulario de um negocio. Com um ponto de
        // cache aqui, essa camada e escrita uma vez e lida por todos os saloes:
        // com um cliente economiza pouco, com cinquenta a escrita deixa de ser
        // paga cinquenta vezes. E ela fica quente sozinha, porque basta um
        // salao com movimento para renovar.
        //
        // O segundo ponto fecha o prefixo do salao. Sem os dois, o prefixo
        // inteiro vira um bloco unico por salao e a parte global e paga de novo
        // em cada um.
        {
          type: 'text',
          text: regras,
          cache_control: { type: 'ephemeral', ttl: CACHE_TTL },
        },
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
    usage.voltas! += 1;
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
      const decisao = desfecho.input as Decisao;

      // A CONVERSA NAO MORRE SEM PROXIMO PASSO.
      //
      // A cliente perguntou e a resposta nao devolveu nem pergunta, nem
      // horario, nem agendamento: ela fica olhando para a tela sem saber o que
      // fazer. O porque e o caso real estao em fecha-a-conversa.ts.
      //
      // Aqui eu NAO descarto a resposta -- devolvo o turno uma vez, dizendo o
      // que faltou. So faco isso quando `atender` veio sozinho: se o modelo
      // pediu outras ferramentas junto, cada uma precisa da propria resposta, e
      // o caminho normal ja cuida disso.
      // A CHAMADA VEIO QUEBRADA: nao vale nem discutir o conteudo.
      //
      // Aconteceu duas vezes em 14/09, sempre no mesmo lugar: a marcacao da
      // propria ferramenta escrita dentro de um campo de texto. O porque esta
      // em resposta-limpa.ts. Pedir de novo resolve na maioria das vezes, e e
      // mais barato que qualquer alternativa.
      const sujos = camposCorrompidos(decisao);
      if (sujos.length > 0 && !jaCobreiACorrupcao && volta < MAX_VOLTAS - 1) {
        jaCobreiACorrupcao = true;
        console.error(
          JSON.stringify({
            event: 'decisao_corrompida',
            conversationId: ambiente.conversationId,
            campos: sujos,
          })
        );
        mensagens.push({ role: 'assistant', content: resposta.content });
        mensagens.push({
          role: 'user',
          content: chamadas.map((c) => ({
            type: 'tool_result' as const,
            tool_use_id: c.id,
            content:
              c.id === desfecho.id
                ? 'NAO ENVIEI: a sua chamada veio com marcacao de ferramenta dentro do texto, ' +
                  'nos campos ' +
                  sujos.join(', ') +
                  '. Cada campo tem que conter SO o texto em portugues, sem nenhuma tag. ' +
                  'Chame atender de novo, com os mesmos campos escritos limpos.'
                : 'Ignorado: refaca junto com a chamada de atender.',
          })),
        });
        continue;
      }

      const NEGA_HORARIO =
        /\bn[ãa]o\s+(tenho|tem|temos|consigo|h[áa])\b[^.!?\n]{0,40}\b\d{1,2}\s*(h\b|h\d{2}|:\d{2})|\b\d{1,2}\s*(h\b|h\d{2}|:\d{2})[^.!?\n]{0,30}\bn[ãa]o\s+(tenho|tem|temos|d[áa])\b/i;
      if (
        decisao.action === 'REPLY' &&
        !consultouNesteTurno &&
        !jaCobreiONaoTem &&
        volta < MAX_VOLTAS - 1 &&
        (Array.isArray(decisao.messages) ? decisao.messages : []).some((m) =>
          NEGA_HORARIO.test(String(m ?? ''))
        )
      ) {
        jaCobreiONaoTem = true;
        mensagens.push({ role: 'assistant', content: resposta.content });
        mensagens.push({
          role: 'user',
          content: chamadas.map((c) => ({
            type: 'tool_result' as const,
            tool_use_id: c.id,
            content:
              'NAO ENVIEI. Voce disse que um horario nao tem sem consultar a agenda neste turno. ' +
              'A lista que voce tinha e so dos primeiros livres. Chame consultar_horarios com ' +
              'aPartirDaHora no horario que ela pediu e responda com o que a agenda disser.',
          })),
        });
        continue;
      }

      // HORARIO DE QUE, E POR QUANTO.
      //
      // O caso da Rayana esta inteiro em antes-do-horario.ts: oito perguntas
      // sobre quimica e um "tenho amanha as 13h" no fim, de um servico que ela
      // nunca escolheu e cujo valor ela nunca ouviu.
      const fala = Array.isArray(decisao.messages) ? decisao.messages : [];
      const trava =
        decisao.action === 'REPLY' &&
        chamadas.length === 1 &&
        !jaCobreiOHorarioPrematuro &&
        volta < MAX_VOLTAS - 1
          ? travaDoProcedimento(
              fala,
              conversa,
              estado.serviceName ?? null,
              catalogoDeNomes,
              faltas.map((f) => f.campo)
            )
          : { falta: null, opcoes: [] as string[] };
      const prematuro = trava.falta;

      if (prematuro) {
        jaCobreiOHorarioPrematuro = true;
        console.error(
          JSON.stringify({
            event: 'horario_antes_do_combinado',
            conversationId: ambiente.conversationId,
            falta: prematuro,
            servicoEmFoco: estado.serviceName ?? null,
            opcoes: trava.opcoes,
          })
        );
        mensagens.push({ role: 'assistant', content: resposta.content });
        mensagens.push({
          role: 'user',
          content: [
            {
              type: 'tool_result',
              tool_use_id: desfecho.id,
              content: recadoDaTrava(prematuro, trava.opcoes, estado.serviceName ?? null),
            },
          ],
        });
        continue;
      }

      // A MESMA FRASE DE NOVO.
      //
      // 16/09: "Ainda estou esperando aquela foto do seu cabelo hoje, pode me
      // mandar?" saiu igual às 10:07 e às 10:58, com uma pergunta dela no meio.
      // Para a cliente isso não é insistência simpática: é a prova de que o que
      // ela escreveu não foi lido.
      //
      // Por que não basta a regra de prompt: a resposta de 10:58 veio de um
      // modelo que já tinha, escrito no prompt, "não repita pergunta já feita".
      const repetidas =
        decisao.action === 'REPLY' &&
        chamadas.length === 1 &&
        !jaCobreiARepeticao &&
        volta < MAX_VOLTAS - 1
          ? frasesRepetidas(
              fala,
              conversa.filter((f) => f.direction === 'OUTBOUND').map((f) => String(f.text ?? ''))
            )
          : [];

      if (repetidas.length > 0) {
        jaCobreiARepeticao = true;
        console.error(
          JSON.stringify({
            event: 'frase_repetida',
            conversationId: ambiente.conversationId,
            frases: repetidas,
          })
        );
        mensagens.push({ role: 'assistant', content: resposta.content });
        mensagens.push({
          role: 'user',
          content: [
            {
              type: 'tool_result',
              tool_use_id: desfecho.id,
              content:
                'NAO ENVIEI. Voce esta reenviando frase que ja mandou nesta conversa: "' +
                repetidas.join('" / "') +
                '". Ela leu isso e respondeu OUTRA coisa. Mandar de novo diz a ela que ' +
                'voce nao leu o que ela escreveu. Ou essa frase some da resposta, ou ela ' +
                'volta de um jeito que reconhece o que ela disse no meio. E antes de ' +
                'reescrever: se ela voltou num assunto, o problema nao e ela nao ter ' +
                'respondido -- e a sua resposta anterior nao ter servido. Conserte aquilo ' +
                'primeiro, em voz alta.',
            },
          ],
        });
        continue;
      }

      const semProximoPasso =
        decisao.action === 'REPLY' &&
        chamadas.length === 1 &&
        !jaCobreiOProximoPasso &&
        volta < MAX_VOLTAS - 1 &&
        (respostaSemProximoPasso(
          Array.isArray(decisao.messages) ? decisao.messages : [],
          levaDaCliente,
          estado.candidatos.length > 0 || agendou != null
        ) ||
          // A pergunta de dinheiro nao morre nem quando ha horario na resposta:
          // ali a conversa anda, mas a duvida que decide se cabe no bolso dela
          // fica para tras.
          condicaoComercialIgnorada(
            Array.isArray(decisao.messages) ? decisao.messages : [],
            levaDaCliente,
            typeof decisao.ownerQuestion === 'string' ? decisao.ownerQuestion : ''
          ));

      if (semProximoPasso) {
        jaCobreiOProximoPasso = true;
        console.error(
          JSON.stringify({
            event: 'resposta_sem_proximo_passo',
            conversationId: ambiente.conversationId,
            perguntasDaCliente: levaDaCliente,
          })
        );
        mensagens.push({ role: 'assistant', content: resposta.content });
        mensagens.push({
          role: 'user',
          content: [
            {
              type: 'tool_result',
              tool_use_id: desfecho.id,
              content:
                'NAO ENVIEI. Releia a ultima leva da cliente e conte as perguntas: cada uma ' +
                'precisa aparecer na sua resposta, inclusive a que voce nao pode responder com ' +
                'promessa (essa voce responde dizendo o que determina a resposta e levando para ' +
                'a avaliacao). E a sua resposta terminou sem nada para ela fazer: nem pergunta, ' +
                'nem horario. Se ainda falta saber alguma coisa do cabelo dela, pergunte. Se nao ' +
                'falta, consulte a agenda com consultar_horarios e termine oferecendo UM horario ' +
                'concreto. E se ela perguntou de pagamento, parcelamento, cartao, pix, sinal ou ' +
                'desconto: isso NUNCA se inventa. Ou a resposta esta escrita nos dados do salao, ' +
                'ou voce manda a pergunta para a dona em ownerQuestion, no MESMO atender. ' +
                'Depois chame atender de novo com as mensagens completas.',
            },
          ],
        });
        continue;
      }

      return { decisao, usage, agendou };
    }

    mensagens.push({ role: 'assistant', content: resposta.content });

    const resultados: Anthropic.ToolResultBlockParam[] = [];

    for (const chamada of chamadas) {
      let texto: string;

      if (chamada.name === 'consultar_horarios') {
        consultouNesteTurno = true;
        const args = chamada.input as {
          servicoId: string;
          aPartirDe: string;
          dias: number;
          aPartirDaHora?: string;
        };
        // A busca devolve os primeiros horarios livres a partir do inicio. 24/09:
        // comecando a meia-noite, "sabado as 10h" vinha 08:00..09:45 e a
        // atendente disse a cliente que 10h nao tinha -- com o sabado vazio.
        const hora = /^([01]\d|2[0-3]):[0-5]\d$/.test(args.aPartirDaHora ?? '')
          ? (args.aPartirDaHora as string)
          : '00:00';
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
            searchFrom: `${args.aPartirDe}T${hora}:00-03:00`,
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
                '\n\nEsta lista são só os PRIMEIROS horários livres a partir do início da busca, não a agenda inteira. ' +
                'Horário que não aparece aqui NÃO quer dizer ocupado: se a cliente pediu outro, consulte de novo com aPartirDaHora nele antes de dizer que não tem.' +
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
                // Sem o telefone, a agenda do salao mostra um primeiro nome e
                // nada mais. Quem atende precisa saber para quem ligar.
                contactRef: ambiente.clientePhone,
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

      // O CUSTO DO TURNO VIRA LINHA NO BANCO.
      //
      // Ate aqui o `usage` era calculado, logado no console e jogado fora. Preco
      // de assinatura decidido sobre um numero que ninguem mede e chute, e o
      // console some. Gravar falha nao pode derrubar o atendimento da cliente:
      // por isso vai em try proprio.
      try {
        await rpc(supabaseUrl, serviceKey, 'agent_record_usage', {
          p_tenant_id: item.tenant_id,
          p_conversation_id: item.conversation_id,
          p_modelo: MODELO,
          p_esforco: ESFORCO,
          p_voltas: usage.voltas ?? 1,
          p_input: usage.input_tokens ?? 0,
          p_output: usage.output_tokens ?? 0,
          p_cache_write: usage.cache_creation_input_tokens ?? 0,
          p_cache_read: usage.cache_read_input_tokens ?? 0,
          p_desfecho: decisao ? (decisao.action ?? null) : (motivoFalha ?? 'SEM_DECISAO'),
        });
      } catch (erroDoMedidor) {
        console.error(
          JSON.stringify({ event: 'agent_usage_not_recorded', erro: String(erroDoMedidor) })
        );
      }

      if (!decisao) {
        throw new Error(motivoFalha ?? 'SEM_DECISAO');
      }

      const textos = (decisao.messages ?? [])
        .map((t) => (typeof t === 'string' ? t.trim() : ''))
        .filter((t) => t.length > 0)
        .slice(0, 3)
        // O escape do JSON escrito como letra. 16/09: a cliente leu
        // "Luzes \\u00e9 uma fam\\u00edlia tamb\\u00e9m". O porque esta em
        // resposta-limpa.ts.
        .map((t) => semEscapes(t))
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

      // PRECO SEM LASTRO NAO SAI DAQUI.
      //
      // Irmao da trava de cima, e pelo mesmo motivo: o prompt manda nao
      // inventar preco, e prompt falha calado. Aqui a pergunta nao e se o
      // modelo acha que sabe o preco, e se o numero que ele escreveu existe em
      // algum lugar dos dados desta conversa. O porque de cada fonte esta em
      // preco-com-lastro.ts.
      //
      // O desfecho reaproveita o que ja existe: vira ASK_OWNER, e a regra logo
      // abaixo rebaixa para HANDOFF quando nao ha pergunta para a dona. Perder
      // a resposta inteira por causa de um numero e caro; mandar o numero
      // errado e mais caro, porque a cliente cobra ele na cadeira.
      const soltos =
        decisao.action === 'REPLY'
          ? precosSemLastro(textos, precosDoNegocio(contexto.stable, contexto.volatile))
          : [];

      // ULTIMA LINHA CONTRA A CHAMADA QUEBRADA.
      //
      // O laco ja pediu a chamada limpa uma vez. Se ainda assim sobrou
      // marcacao, aqui ela nao passa: campo sujo e apagado antes de virar
      // linha no banco, e `messages` sujo nao e enviado de jeito nenhum --
      // vai para uma pessoa. O painel da dona recebendo tag de XML ja
      // aconteceu duas vezes; a cliente recebendo, nenhuma, e fica assim.
      const corrompidos = camposCorrompidos(decisao);
      if (corrompidos.length > 0) {
        console.error(
          JSON.stringify({
            event: 'decisao_corrompida_apos_retentativa',
            conversationId: item.conversation_id,
            campos: corrompidos,
            // Sem o texto cru nao da para saber COMO ele quebra, e o pedido de
            // refazer ja provou que sozinho nao resolve.
            amostra: corrompidos
              .map(
                (campo) =>
                  campo +
                  '=' +
                  String((decisao as Record<string, unknown>)[campo] ?? '').slice(0, 200)
              )
              .join(' | '),
          })
        );
        // Nao apaga: tira a tag e fica com o portugues que sobrou. O painel da
        // dona perdeu tres frases inteiras em 15/09 por causa do apagar.
        if (corrompidos.includes('ownerQuestion')) {
          decisao.ownerQuestion = semEscapes(semMarcacao(decisao.ownerQuestion));
        }
        if (corrompidos.includes('contextSummary')) {
          decisao.contextSummary = semEscapes(semMarcacao(decisao.contextSummary));
        }
        if (corrompidos.includes('reason')) {
          decisao.reason = semMarcacao(decisao.reason) || 'resposta do modelo veio quebrada';
        }
      }

      let acao = decisao.action;
      if (corrompidos.includes('messages')) acao = 'HANDOFF';
      if (soltos.length > 0) {
        console.error(
          JSON.stringify({
            event: 'preco_sem_lastro',
            conversationId: item.conversation_id,
            valores: soltos.map((s) => s.trecho),
            textos,
          })
        );
        acao = 'ASK_OWNER';
      }
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
          precoSemLastro: soltos.length > 0 ? soltos.map((s) => s.trecho) : undefined,
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
        // A FINALIZACAO DO SALAO SAI DEPOIS DO "MARCADO" DELA. Texto e arte
        // sao do dono, preenchidos no banco, e nao passam pelo modelo. Falhar
        // aqui nao desfaz o agendamento: a cliente ja ouviu que esta marcado.
        if (agendou?.appointmentId) {
          try {
            await rpc(supabaseUrl, serviceKey, 'enviar_finalizacao_do_agendamento', {
              p_conversation_id: item.conversation_id,
              p_appointment_id: agendou.appointmentId,
            });
          } catch (erro) {
            console.error('FINALIZACAO_FALHOU', agendou.appointmentId, String(erro));
          }
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
        // So pergunta de verdade vai para o dono. 24/09: o campo vinha com
        // resumo ("Ana quer escova sexta 15h, oferecido sabado") e cada um
        // virava um aviso no WhatsApp do dono sem nada para ele responder.
        const perguntaJunto = (decisao.ownerQuestion ?? '').trim();
        if (perguntaJunto.length >= 3 && perguntaJunto.includes('?')) {
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
        // SILENCIO NAO E RESPOSTA. 24/09/2026, teste com cliente-robo: a
        // cliente gravida perguntou se podia hidratacao, a atendente foi
        // perguntar ao dono e ela nao recebeu nada. Uma linha fixa, sem
        // modelo, uma vez por mensagem dela.
        try {
          await rpc(supabaseUrl, serviceKey, 'enqueue_outbound_message', {
            p_tenant_id: item.tenant_id,
            p_conversation_id: item.conversation_id,
            p_body_text: 'Vou confirmar isso aqui no salão e já te respondo, tá?',
            p_actor: 'AGENT',
            p_idempotency_key: `aguarde:${item.last_inbound_message_id}`,
          });
        } catch (erroAviso) {
          console.error('AVISO_DE_ESPERA_FALHOU', item.conversation_id, String(erroAviso));
        }
      }

      // So marca depois de agir. Se o enfileiramento estourar, a mensagem fica
      // sem decisao e volta na proxima rodada.
      await rpc(supabaseUrl, serviceKey, 'mark_agent_decision', {
        p_tenant_id: item.tenant_id,
        p_message_id: item.last_inbound_message_id,
        p_decision: acao,
        // O painel da equipe precisa saber que a decisao foi trocada por uma
        // trava, e por qual: "estacionada, sem motivo" e o tipo de linha que
        // ninguem investiga.
        p_reason: mentiuAgendamento
          ? 'BLOQUEADO: afirmou agendamento sem ter reservado. ' + (decisao.reason ?? '')
          : soltos.length > 0
            ? 'BLOQUEADO: falou preço sem lastro nos dados (' +
              soltos.map((s) => s.trecho).join(', ') +
              '). ' +
              (decisao.reason ?? '')
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
        bloqueadas: mentiuAgendamento || soltos.length > 0 ? textos : undefined,
        precoSemLastro: soltos.length > 0 ? soltos.map((s) => s.trecho) : undefined,
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
