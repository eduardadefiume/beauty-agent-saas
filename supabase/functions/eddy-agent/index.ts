import 'jsr:@supabase/functions-js/edge-runtime.d.ts';
import Anthropic from 'npm:@anthropic-ai/sdk@0.120.0';

// `semEscapes` chega aqui com dois dias de atraso, e isso tem historia.
//
// Em 16/09 uma cliente leu "Luzes é uma família" no WhatsApp: o
// modelo escapou o proprio JSON e o escape foi para a tela. O conserto foi
// feito, testado, e aplicado SO na atendente das clientes -- a importacao
// daqui ficou com uma funcao das tres. Em 23/09, 11:07, a dona leu
// "que você passar" e "a duração pra fechar". O mesmo bug, sete
// dias depois, no agente ao lado.
//
// LICAO: conserto que mora num modulo compartilhado so vale para quem importa.
// Corrigir um agente e declarar o bug morto e contar metade.
import { camposCorrompidos, semEscapes } from '../whatsapp-agent/resposta-limpa.ts';
import { respostaAoSinal } from './sinal-do-dono.ts';
import { devolucaoDita } from './devolucao-dita.ts';
import { valorDaQuimicaDito } from './sinal-quimica-dito.ts';
import { temPergunta, umaPerguntaPorVez } from '../whatsapp-agent/uma-pergunta.ts';
import { comProximoPasso, padraoDaCor, semRefrao } from './proximo-passo.ts';

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
// 8, e a ultima volta so tem `atender`. 24/09/2026, teste com dono-robo: ele
// mandou onze servicos num audio, o Eddy gastou as quatro voltas criando e o
// turno morreu em SEM_DECISAO -- servicos gravados e o dono sem resposta.
// Lote grande e o normal de quem configura por audio.
// O que o dono costuma pedir e o Eddy ainda nao faz. Dito com clareza e com
// a alternativa, para ele nao prometer nem se calar.
// As perguntas do sinal, na ordem de app.sinal_resumo().falta.
const PERGUNTA_DO_SINAL: Record<string, string> = {
  VALORES:
    '"Em quais procedimentos você quer cobrar sinal, e quanto em cada? Ex.: luzes R$ 100, progressiva R$ 50, corte não cobra." -> definir_sinal_do_servico (uma chamada por procedimento); se ele falar de toda a química ("só química, 50"), configurar_sinal valorQuimicaReais',
  PERIODO:
    '"O sinal vale sempre, ou só num período? Ex.: só em dezembro." -> configurar_sinal (sempre = valeDe "" e valeAte "")',
  PRAZO:
    '"Depois de marcar, quanto tempo a cliente tem pra pagar o sinal? O normal é 24h. E se ela marcar com antecedência, tipo em novembro pra dezembro, quer dar mais tempo (ex.: 48h)?" -> configurar_sinal (prazoHoras e prazoMesAnteriorHoras). ' +
    'Diga também, numa linha, que o prazo nunca passa de 2h antes do horário e que, se não pagar no prazo, o horário é liberado e a cliente é avisada.',
  PIX: '"Qual a chave Pix que a cliente vai usar pra pagar o sinal, e em nome de quem aparece?" -> configurar_sinal (pixChave, pixTitular)',
  DEVOLUCAO:
    '"Se a cliente pagar o sinal e depois desmarcar, você devolve? Se sim, com quantas horas de antecedência ela tem que avisar?" -> configurar_sinal (devolve, devolveAteHoras)',
  LIGAR:
    'mostre o resumo do sinal em poucas linhas e pergunte "Posso ligar o sinal?" -> configurar_sinal ativo true',
};

const O_QUE_AINDA_NAO_FACO =
  'A AGENDA DO SALÃO você VÊ: quem vem, quantas marcaram, quanto vai entrar, quem está esperando sinal -- use `ver_agenda`. ' +
  'Nunca diga que não tem acesso à agenda. ' +
  'O QUE VOCÊ AINDA NÃO FAZ: ler os compromissos que ele pôs direto no Google (dentista, particular); esses só bloqueiam horário. ' +
  'SÓ SE ele perguntar em que dias uma profissional vem trabalhar: diga que isso você não lê do Google e que ele (ou ela) te manda as datas por aqui, ' +
  'e você marca cada uma com `marcar_dia_da_profissional`. Se ele não perguntou disso, não fale disso.';

// O EDDY NAO SABIA QUE DIA E HOJE.
//
// 25/09/2026: "a Carla vem dia 3 e dia 17 de outubro". O modelo chutou o ano,
// mandou 2025, o banco recusou (DATA_NO_PASSADO) e o Eddy disse ao dono que
// "3 e 17 de outubro ja passaram". Nenhuma linha do contexto dizia a data.
const FUSO = 'America/Sao_Paulo';
function hojeNoSalao(): string {
  return new Intl.DateTimeFormat('pt-BR', {
    timeZone: FUSO,
    weekday: 'long',
    day: '2-digit',
    month: '2-digit',
    year: 'numeric',
  }).format(new Date());
}
function hojeISO(): string {
  return new Intl.DateTimeFormat('en-CA', { timeZone: FUSO }).format(new Date());
}
// Cinto e suspensorio: data com ano ja vencido vira a proxima ocorrencia do
// mesmo dia e mes. Dono nao marca profissional no passado; ano errado e chute.
export function proximaOcorrencia(data: string, hoje = hojeISO()): string {
  const m = /^(\d{4})-(\d{2})-(\d{2})$/.exec(String(data ?? '').trim());
  if (!m || data >= hoje) return data;
  const anoHoje = Number(hoje.slice(0, 4));
  if (Number(m[1]) >= anoHoje) return data;
  const esteAno = `${anoHoje}-${m[2]}-${m[3]}`;
  return esteAno >= hoje ? esteAno : `${anoHoje + 1}-${m[2]}-${m[3]}`;
}

const MAX_VOLTAS = 8;

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
  palpiteModulo?: string;
  palpiteEscopo?: string;
};

// O ESCOPO QUE O MODELO FALA NAO E O ESCOPO QUE A TABELA GUARDA.
//
// O `atender` pede OFICIO/NEGOCIO/VOZ; `conhecimento_nao_classificado` so
// aceita DO_OFICIO/DESTE_NEGOCIO/UNIVERSAL, e `registrar_conhecimento_solto`
// transforma o que nao reconhece em null -- calado. Desde 23/09 todo palpite
// de escopo chegava ao banco como nulo. VOZ e o jeito de UMA dona falar: e
// deste negocio, nao do oficio.
function escopoDoBanco(escopo: string | undefined): string | null {
  if (escopo === 'OFICIO') return 'DO_OFICIO';
  if (escopo === 'NEGOCIO' || escopo === 'VOZ') return 'DESTE_NEGOCIO';
  return null;
}

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
        aPartirDe: {
          type: 'boolean',
          description:
            'true quando ele disse "a partir de", "começa em", "depende do cabelo". Sem isso a atendente crava o valor como final.',
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
    name: 'definir_pausa',
    description:
      'Grava o tempo de espera do produto num serviço. Pergunte SEMPRE três coisas: quantos minutos, se a pausa está dentro do tempo total ou soma a mais, e se nesse tempo a profissional fica livre para outra cliente. Chamar de novo com os mesmos minutos corrige só o "fica livre".',
    input_schema: {
      type: 'object',
      properties: {
        servico: { type: 'string', description: 'O nome do serviço, como está cadastrado.' },
        minutos: { type: 'number', description: 'Minutos de pausa.' },
        dentroDoTotal: {
          type: 'boolean',
          description:
            'true quando a pausa já está contada no tempo total que ele falou; false quando ela soma a mais. Não adivinhe: pergunte.',
        },
        profissionalLivre: {
          type: 'boolean',
          description:
            'true se nessa pausa a profissional pode atender outra cliente; false se ela fica acompanhando ("fico de olho", "não dá pra pegar outra"). Não adivinhe: pergunte.',
        },
        confianca: { type: 'number', description: 'Mesma régua do `anotar`.' },
      },
      required: ['servico', 'minutos', 'dentroDoTotal', 'profissionalLivre', 'confianca'],
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
          description:
            'O serviço: o id que veio na pendência OU o nome dele como está no cadastro ("Escova"). Serve também para MUDAR o preço de um serviço já publicado.',
        },
        precoReais: { type: 'number', description: 'Em reais, sem símbolo: 160, não "R$ 160,00".' },
        ehPiso: {
          type: 'boolean',
          description:
            'true quando ele disse "a partir de", "começa em", "varia". false quando é valor fechado. Na dúvida, pergunte a ele; não chute.',
        },
        confianca: {
          type: 'number',
          description: 'Mesma régua do `anotar`. Abaixo de 0,75 não grava.',
        },
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
        servicoId: {
          type: 'string',
          description:
            'O serviço: o id da pendência OU o nome como está no cadastro ("Progressiva").',
        },
        nome: {
          type: 'string',
          description:
            'Como o dono chamou essa variação: "raiz", "raiz com muito cabelo", "cabelo todo".',
        },
        precoReais: { type: 'number', description: 'O preço desta variação, em reais.' },
        confianca: { type: 'number', description: 'Abaixo de 0,75 não grava.' },
      },
      required: ['servicoId', 'nome', 'precoReais', 'confianca'],
      additionalProperties: false,
    },
  },
  {
    name: 'definir_duracao',
    description:
      'MUDA quanto tempo um serviço que já existe leva no total ("a progressiva agora demora 4h"). A pausa continua a mesma; o atendimento vira o resto. Para mudar a pausa use `definir_pausa`.',
    input_schema: {
      type: 'object',
      properties: {
        servico: { type: 'string', description: 'O nome do serviço como está no cadastro.' },
        minutosTotais: {
          type: 'number',
          description: 'O tempo total novo, em minutos (4h = 240).',
        },
        confianca: { type: 'number', description: 'Abaixo de 0,75 não grava.' },
      },
      required: ['servico', 'minutosTotais', 'confianca'],
      additionalProperties: false,
    },
  },
  {
    name: 'corrigir_foto',
    description:
      'Muda uma foto de família de tom e/ou grava o TOM que ele disse ("essa é castanho claro tom 6"). Serve para foto já arquivada (lista fotosJaArquivadas) e para foto sem lugar. A palavra dele vale mais que a leitura da foto: se ele disse o tom, grave o tom dele. Só diga que corrigiu depois de receber "Corrigido".',
    input_schema: {
      type: 'object',
      properties: {
        foto: {
          type: 'string',
          description: 'O id da foto, como veio em fotosJaArquivadas ou fotosSemDestino.',
        },
        familia: {
          type: 'string',
          description:
            'A família de tom, EXATAMENTE como está em familiasDeTom (ex.: "Preto", "Castanho").',
        },
        tom: {
          type: 'number',
          description: 'O tom (1 a 10) que ELE disse. Omita se ele não disse o número.',
        },
      },
      required: ['foto', 'familia'],
      additionalProperties: false,
    },
  },
  {
    name: 'desativar_servico',
    description:
      'Tira do catálogo um serviço que o salão não faz. O serviço não é apagado, fica inativo e volta se ele pedir. ' +
      'Pedido claro dele ("tira o botox", "não faço mais botox") JÁ É a confirmação: desative e diga "Tirei o Botox; se quiser de volta, é só falar." ' +
      'Só pergunte ANTES, sem desativar, quando a ideia de tirar foi sua e não dele. NUNCA desative e depois peça confirmação ("já tirei, mas confirma?").',
    input_schema: {
      type: 'object',
      properties: {
        nome: {
          type: 'string',
          description: 'O nome do serviço, exatamente como está no catálogo.',
        },
      },
      required: ['nome'],
      additionalProperties: false,
    },
  },
  {
    name: 'reativar_servico',
    description:
      'Volta para o catálogo um serviço que foi tirado, com o preço, o tempo e as etapas que ele tinha (nada foi apagado). ' +
      'Use quando ele pedir de volta ("volta o selante"). NÃO pergunte preço nem tempo antes: eles voltam sozinhos; diga quais são e, se ele quiser mudar, mude depois.',
    input_schema: {
      type: 'object',
      properties: {
        nome: { type: 'string', description: 'O nome do serviço tirado, como estava no catálogo.' },
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
    name: 'definir_o_que_o_agente_faz',
    description:
      'A PRIMEIRA coisa da conversa: grava o que o dono quer que o agente faça pelas clientes dele. Responder é sempre sim. Marcar horário é a escolha dele — e sinal e política de cancelamento só existem para quem marca.',
    input_schema: {
      type: 'object',
      properties: {
        marcaHorario: {
          type: 'boolean',
          description:
            'true se ele quer que o agente marque o horário na agenda; false se é só para responder.',
        },
        pedeSinal: {
          type: 'boolean',
          description:
            'true se ele quer pedir um sinal para confirmar o horário. Só com marcaHorario.',
        },
        politicaDeCancelamento: {
          type: 'boolean',
          description: 'true se ele quer regra de cancelamento. Só com marcaHorario.',
        },
        lembraDaVespera: {
          type: 'boolean',
          description:
            'true se ele já disse que quer lembrete de véspera. Os detalhes (hora, texto) vêm depois, com `definir_lembrete`.',
        },
        confianca: { type: 'number', description: 'Mesma régua do `anotar`.' },
      },
      required: ['marcaHorario', 'confianca'],
      additionalProperties: false,
    },
  },
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
            'O endereço: rua, número, bairro e cidade. SEM o estado, que vai no campo próprio. Deixe vazio se ele ainda não disse tudo.',
        },
        estado: {
          type: 'string',
          description:
            'A UF em duas letras: SP, MG, GO... Obrigatória quando houver endereço. Se ele disse só a cidade, PERGUNTE o estado — nunca deduza pela cidade: Jardinópolis existe em SP e em GO, e errar manda a cliente para outro lugar.',
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
        disponibilidade: {
          type: 'string',
          enum: ['IGUAL_AO_SALAO', 'DIAS_PROPRIOS', 'SEM_DIA_FIXO'],
          description:
            'Como ela trabalha. IGUAL_AO_SALAO é o caso comum e o padrão. DIAS_PROPRIOS quando ela tem a semana dela, diferente da do salão — aí use `definir_disponibilidade` com os dias. SEM_DIA_FIXO para quem aparece sem data certa: ela não é oferecida até você marcar as datas com `marcar_dia_da_profissional`.',
        },
        confianca: { type: 'number', description: 'Mesma régua do `anotar`.' },
      },
      required: ['nome', 'confianca'],
      additionalProperties: false,
    },
  },
  {
    name: 'definir_disponibilidade',
    description:
      'Diz como uma pessoa JÁ cadastrada trabalha. Use quando ela mudar, ou quando o cadastro pediu os dias dela. Sem isso a pessoa existe no sistema e nunca aparece como opção de horário para a cliente.',
    input_schema: {
      type: 'object',
      properties: {
        nome: { type: 'string', description: 'O nome dela, como está cadastrado.' },
        disponibilidade: {
          type: 'string',
          enum: ['IGUAL_AO_SALAO', 'DIAS_PROPRIOS', 'SEM_DIA_FIXO'],
          description: 'Igual à da ferramenta de cadastrar.',
        },
        dias: {
          type: 'array',
          description: 'Só para DIAS_PROPRIOS: a semana dela. Vazio nos outros casos.',
          items: {
            type: 'object',
            properties: {
              dia: { type: 'number', description: '0 domingo ... 6 sábado.' },
              abre: { type: 'string', description: 'HH:MM.' },
              fecha: { type: 'string', description: 'HH:MM.' },
            },
            required: ['dia', 'abre', 'fecha'],
            additionalProperties: false,
          },
        },
        confianca: { type: 'number', description: 'Mesma régua do `anotar`.' },
      },
      required: ['nome', 'disponibilidade', 'confianca'],
      additionalProperties: false,
    },
  },
  {
    name: 'marcar_dia_da_profissional',
    description:
      'Marca UMA data em que a profissional sem dia fixo vem trabalhar. Uma chamada por data. Se ele não disser a hora, ela herda o horário do salão naquele dia.',
    input_schema: {
      type: 'object',
      properties: {
        nome: { type: 'string', description: 'O nome dela, como está cadastrado.' },
        data: { type: 'string', description: 'A data, no formato AAAA-MM-DD.' },
        abre: { type: 'string', description: 'HH:MM. Deixe vazio para herdar o horário do salão.' },
        fecha: {
          type: 'string',
          description: 'HH:MM. Deixe vazio para herdar o horário do salão.',
        },
        confianca: { type: 'number', description: 'Mesma régua do `anotar`.' },
      },
      required: ['nome', 'data', 'confianca'],
      additionalProperties: false,
    },
  },
  {
    name: 'criar_habilidade',
    description:
      'Cria uma habilidade da equipe (corte, coloração, mechas...) e liga a quem a faz. ' +
      'TAMBÉM serve para dizer quem faz uma habilidade que JÁ EXISTE: "o William também faz cor e mechas" -> nome "Cor e mechas" (exatamente como está em AS HABILIDADES QUE ESTE SALÃO TEM) e quemFaz ["William"]. Não cria duplicada, só liga a pessoa. ' +
      'Nunca diga que isso "precisa da nossa equipe": é você que faz. Depois, como todo cadastro, vai para o rascunho e vale para as clientes quando publicar. ' +
      'A equipe tem que existir antes: sem ninguém cadastrado, esta ferramenta recusa e te devolve a pergunta certa.',
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
      'Põe no ar o que está no rascunho. Normalmente: chame `resumo`, conte a ele o que mudou e espere ele confirmar NESTA conversa. ' +
      'Exceção: se na MESMA mensagem ele pediu a mudança E mandou publicar ("a escova agora é 80, pode publicar"), e o rascunho não tem outra mudança além das que ele acabou de pedir, grave, publique e só depois conte o que foi ao ar; não peça confirmação de novo. ' +
      'Se o rascunho tiver mudança que ele não citou nesta mensagem, conte essa mudança e pergunte antes.',
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
    name: 'arquivar_fotos',
    description:
      'Grava fotos que ele mandou no lugar certo da régua do salão, para a atendente reconhecer isso na foto da cliente. Use depois que ele disser o que as fotos são ("essas são ruivo", "isso é um pixie"). Várias fotos seguidas antes da legenda são um lote: mande todos os ids juntos. Se a leitura da foto deixou dúvida entre tom e corte, pergunte a ele antes. Só diga que guardou depois de receber "Arquivei". Se ele disse a cor com outras palavras que a leitura da foto (ele: "castanho claro"; leitura: "mechas"), a palavra DELE decide; se as duas brigam, pergunte antes. Quando ele disser o número do tom, grave com `corrigir_foto` logo depois.',
    input_schema: {
      type: 'object',
      properties: {
        fotos: {
          type: 'array',
          items: { type: 'string' },
          description: 'Os ids das fotos, como vieram na lista de fotos sem lugar.',
        },
        destino: {
          type: 'string',
          enum: ['FAMILIA_DE_TOM', 'OPCAO_DA_REGUA', 'DESCARTADA'],
          description:
            'FAMILIA_DE_TOM: a foto mostra um tom (Ruivo, Loiro...). OPCAO_DA_REGUA: mostra um corte, comprimento, curvatura. DESCARTADA: ele disse que a foto não serve.',
        },
        alvo: {
          type: 'string',
          description:
            'O nome da família ou da opção, EXATAMENTE como está na lista (ex.: "Ruivo", "Pixie (joãozinho)"). Vazio em DESCARTADA.',
        },
        dimensao: {
          type: 'string',
          description:
            'Só em OPCAO_DA_REGUA: a dimensão da opção ("Corte"). Obrigatória para criar opção nova.',
        },
        criarOpcao: {
          type: 'boolean',
          description:
            'true só quando ele usou um nome que não está na régua ("corte borboleta") e confirmou que é um tipo novo.',
        },
      },
      required: ['fotos', 'destino'],
      additionalProperties: false,
    },
  },
  {
    name: 'criar_regra',
    description:
      'Grava uma regra que muda como a atendente fala com as clientes: o que o salão NÃO faz ("não faço pixie"), uma condição ("luzes só com teste de mecha"), um jeito de falar. TUDO que ele disser sobre um serviço e que não cabe em preço, variação, duração ou pausa vira regra aqui: o que está incluso ("luzes já com hidratação e reconstrução"), o que acontece depois ("se passar no teste de mecha, faz no mesmo dia"), preço que muda por volume de cabelo. Sem regra gravada, NÃO diga que anotou. Escreva a regra como instrução clara para a atendente e mande as palavras dele junto. Entra em rascunho: só vale para cliente depois que ele publicar.',
    input_schema: {
      type: 'object',
      properties: {
        assunto: {
          type: 'string',
          enum: [
            'PROCEDIMENTO',
            'PRECO',
            'AGENDAMENTO',
            'ATENDIMENTO',
            'VOZ',
            'AVALIACAO',
            'FOTOS',
            'PROMOCAO',
            'PAGAMENTO',
            'CANCELAMENTO',
            'ATRASO',
            'SINAL',
            'OUTRO',
          ],
          description: 'PROCEDIMENTO para o que o salão faz ou não faz.',
        },
        titulo: { type: 'string', description: 'Título curto: "Não fazemos pixie".' },
        regra: {
          type: 'string',
          description:
            'A instrução para a atendente: "O salão não faz corte pixie. Se a cliente pedir, diga com gentileza e ofereça o long bob."',
        },
        palavrasDoDono: { type: 'string', description: 'O que ele disse, como ele disse.' },
        confianca: {
          type: 'number',
          description: 'Mesma régua do `anotar`. Abaixo de 0,75 não grava.',
        },
      },
      required: ['assunto', 'titulo', 'regra', 'palavrasDoDono', 'confianca'],
      additionalProperties: false,
    },
  },
  {
    name: 'responder_pergunta_da_atendente',
    description:
      'Grava a resposta do dono a uma pergunta que a atendente fez sobre uma cliente (o código #XXXX vem na mensagem e na lista de perguntas abertas). A atendente volta para a cliente sozinha.',
    input_schema: {
      type: 'object',
      properties: {
        codigo: { type: 'string', description: 'O código da pergunta, ex.: AB12.' },
        resposta: { type: 'string', description: 'A resposta dele, nas palavras dele.' },
      },
      required: ['codigo', 'resposta'],
      additionalProperties: false,
    },
  },
  {
    name: 'marcar_a_partir_de',
    description:
      'Marca ou desmarca o preço de um serviço já cadastrado como "a partir de". Use quando ele disser isso de um serviço que já existe, ou quando o cadastro mostrar diferente do que ele disse.',
    input_schema: {
      type: 'object',
      properties: {
        servico: { type: 'string', description: 'O nome do serviço, como está no cadastro.' },
        aPartirDe: { type: 'boolean' },
      },
      required: ['servico', 'aPartirDe'],
      additionalProperties: false,
    },
  },
  {
    name: 'definir_redes',
    description:
      'Grava as redes sociais do salão, que a atendente passa para a cliente. Se ele disser que não tem, chame sem nenhum campo: "não tem" também é resposta.',
    input_schema: {
      type: 'object',
      properties: {
        instagram: { type: 'string', description: 'O @ ou o link do Instagram.' },
        facebook: { type: 'string' },
        tiktok: { type: 'string' },
        site: { type: 'string' },
      },
      additionalProperties: false,
    },
  },
  {
    name: 'definir_confirmacao',
    description:
      'Grava o que a cliente recebe logo depois de marcar: um texto dele (com as lacunas {nome}, {data}, {hora}, {servico}, {salao}, {endereco}) e/ou uma imagem que ele mandou (o id da foto sem lugar). Só depois de ele aprovar como ficou. O texto entra no rascunho e vale depois de publicar.',
    input_schema: {
      type: 'object',
      properties: {
        texto: { type: 'string', description: 'O texto final, já com as lacunas.' },
        foto: {
          type: 'string',
          description: 'O id da foto sem lugar que é a arte de confirmação.',
        },
      },
      additionalProperties: false,
    },
  },
  {
    name: 'definir_lembrete',
    description:
      'Liga ou desliga o lembrete de véspera e a hora em que ele sai (8 a 21). Se ele quiser um texto próprio, mande em textoDesejado com {nome}, {data} e {hora} no lugar do nome, da data e da hora da cliente (ex.: "Oi {nome}! Amanhã às {hora} te espero aqui"): cada cliente recebe os dela. NUNCA escreva uma hora fixa ("14h") no texto. O texto é o que a CLIENTE lê: recado que ele te dá ("ah, e avisa que tem interfone, é só digitar 2") vira frase para ela ("Temos interfone: quando chegar, é só digitar 2."), nunca "avisa que" nem "ah, e". Na confirmação, mostre a ele o texto exato que vai sair. O texto dele sai para a cliente que falou com o salão nas últimas 24h; para as outras, sai o modelo padrão aprovado no WhatsApp.',
    input_schema: {
      type: 'object',
      properties: {
        quer: { type: 'boolean' },
        hora: { type: 'integer', description: 'Hora cheia, de 8 a 21. Ex.: 18.' },
        textoDesejado: {
          type: 'string',
          description:
            'Só quando o texto muda: mande o texto INTEIRO novo, partindo do atual (está em O CADASTRO). Para mudar só a hora, NÃO mande: o texto atual fica.',
        },
        voltarAoPadrao: {
          type: 'boolean',
          description: 'true só quando ele pedir para largar o texto dele e usar o modelo padrão.',
        },
      },
      required: ['quer'],
      additionalProperties: false,
    },
  },
  {
    name: 'conectar_agenda',
    description:
      'Gera o link para conectar o Google Agenda (dele ou de alguém da equipe) e manda o link num balão separado, automático. Use quando ele pedir para conectar/ligar/sincronizar a agenda do Google, responder "conectar agenda", ou disser que a agenda caiu. NUNCA escreva link nenhum nas suas mensagens: o link sai sozinho, logo depois dos seus balões. Diga em poucas palavras o que fazer: abrir o link, entrar na conta Google onde está a agenda, permitir. O link vale 24 horas e uma vez só.',
    input_schema: {
      type: 'object',
      properties: {
        profissional: {
          type: 'string',
          description:
            'O nome de quem é a agenda, como está na equipe. Vazio quando a agenda é dele mesmo.',
        },
      },
      additionalProperties: false,
    },
  },
  {
    name: 'configurar_sinal',
    description:
      'Grava o que o DONO respondeu sobre o sinal (só os campos que ele respondeu agora). Vale na hora, sem publicar. ' +
      'Período: valeDe/valeAte (AAAA-MM-DD); "sempre" = os dois vazios (""). Prazo: prazoHoras (padrão 24) e, se ele quiser mais tempo quando a cliente marca num mês para o outro (ex.: novembro para dezembro), prazoMesAnteriorHoras; "não" = "". ' +
      'Pix: pixChave e pixTitular (nome que aparece no Pix). Devolução: devolve true/false e devolveAteHoras (com quantas horas de antecedência ela tem que avisar). ' +
      'Valor para TODA a química ("sinal só pra química, 50 reais"): valorQuimicaReais (vale para luzes, mechas, progressiva, coloração etc., os de hoje e os que ele cadastrar depois; 0 = tira). Valor de UM procedimento é definir_sinal_do_servico, que ganha da regra da química. ' +
      'ativo true SÓ quando ele disser para ligar (e só depois de ter valor e Pix).',
    input_schema: {
      type: 'object',
      properties: {
        ativo: { type: 'boolean' },
        valeDe: { type: 'string' },
        valeAte: { type: 'string' },
        prazoHoras: { type: 'integer' },
        prazoMesAnteriorHoras: { type: ['integer', 'string'] },
        valorQuimicaReais: { type: 'number', description: 'Sinal de toda a química, em reais.' },
        pixChave: { type: 'string' },
        pixTitular: { type: 'string' },
        devolve: { type: 'boolean' },
        devolveAteHoras: { type: 'integer' },
      },
      additionalProperties: false,
    },
  },
  {
    name: 'definir_sinal_do_servico',
    description:
      'Grava o valor do sinal de UM procedimento, como o dono disse (valor fixo em reais). Chame uma vez por procedimento. valorReais 0 = esse não cobra sinal. Vale na hora.',
    input_schema: {
      type: 'object',
      properties: {
        servico: { type: 'string', description: 'Nome do procedimento como está no cadastro.' },
        valorReais: { type: 'number', description: 'Ex.: 100 para R$ 100.' },
      },
      required: ['servico', 'valorReais'],
      additionalProperties: false,
    },
  },
  {
    name: 'ver_agenda',
    description:
      'Mostra a agenda do salão num período: cada atendimento (dia, hora, cliente, telefone, serviço, com quem, valor, se está confirmado ou esperando sinal), o total, o valor previsto, quantos foram desmarcados e quantas MARCAÇÕES foram FEITAS no período. ' +
      'Use sempre que ele perguntar da agenda, de clientes marcadas, movimento, faturamento previsto. Se valorPrevistoEMinimo vier true, o previsto é o MÍNIMO (tem serviço "a partir de"): diga "no mínimo R$ X", nunca um valor fechado. "Essa semana" = segunda a domingo da semana de HOJE; "hoje", "amanhã", "sábado", "mês que vem" contam a partir de HOJE. ' +
      '"Quantas marcaram essa semana" pode ser quem VEM na semana (totalAtendimentos) ou quem MARCOU na semana (marcacoesFeitasNoPeriodo): se os dois números forem diferentes, diga os dois numa frase. ' +
      'Responda curto: o número primeiro; a lista só se ele pedir ou se forem até 6.',
    input_schema: {
      type: 'object',
      properties: {
        de: { type: 'string', description: 'Primeiro dia, AAAA-MM-DD.' },
        ate: { type: 'string', description: 'Último dia (inclusive), AAAA-MM-DD. Máximo 2 meses.' },
      },
      required: ['de', 'ate'],
      additionalProperties: false,
    },
  },
  {
    name: 'confirmar_sinal',
    description:
      'Registra o que o dono disse sobre o Pix do sinal de uma cliente (lista em SINAIS ESPERANDO VOCÊ). pagou=true quando ele disser que caiu/recebeu/pagou: o horário dela é confirmado, vai para o Google e ela recebe a confirmação. pagou=false quando ele disser que não caiu: ela é avisada para conferir. Também vale quando ele diz sozinho "a Fulana pagou". NUNCA chame sem ele ter dito. Responda a ele com o texto que a ferramenta devolver.',
    input_schema: {
      type: 'object',
      properties: {
        referencia: {
          type: 'string',
          description: 'O código (ex.: S1234) ou o nome da cliente. Vazio se só tem um esperando.',
        },
        pagou: { type: 'boolean' },
      },
      required: ['pagou'],
      additionalProperties: false,
    },
  },
  {
    name: 'configurar_teste_de_mecha',
    description:
      'Grava como o salão faz o teste de mecha (para luzes, mechas, descoloração, química). Vale na hora para a atendente. ' +
      'MESMO_DIA: o teste é feito no começo do procedimento, no mesmo dia, dentro do tempo dele (o padrão). ' +
      'ANTES: o teste é marcado à parte, diasAntes dias antes. SEM_TESTE: o salão não faz teste. ' +
      'jeitoDeFalar: como o dono quer que a atendente explique o teste para a cliente, nas palavras dele. Só chame com o que ele disse.',
    input_schema: {
      type: 'object',
      properties: {
        modo: { type: 'string', enum: ['MESMO_DIA', 'ANTES', 'SEM_TESTE'] },
        diasAntes: {
          type: 'integer',
          description: 'Só para ANTES: quantos dias antes do procedimento.',
        },
        jeitoDeFalar: {
          type: 'string',
          description: 'Opcional: a explicação do teste nas palavras dele.',
        },
      },
      required: ['modo'],
      additionalProperties: false,
    },
  },
  {
    name: 'resolver_mexida_no_google',
    description:
      'Faz o que o dono decidiu sobre um horário de cliente que ele apagou ou mudou no Google (lista em HORÁRIOS QUE O DONO MEXEU NO GOOGLE). DESMARCAR: desmarca e manda à cliente uma mensagem educada pedindo desculpas. MUDAR (só quando ele moveu): passa a cliente para o novo horário e avisa ela. VOLTAR: foi sem querer; o evento volta ao Google como era e a cliente não fica sabendo de nada. Só chame depois que ele decidir.',
    input_schema: {
      type: 'object',
      properties: {
        codigo: { type: 'string', description: 'O código da mexida, ex.: 3F2A.' },
        acao: { type: 'string', enum: ['DESMARCAR', 'MUDAR', 'VOLTAR'] },
      },
      required: ['codigo', 'acao'],
      additionalProperties: false,
    },
  },
  {
    name: 'definir_modo_da_equipe',
    description:
      'Grava se, para a cliente, o salão é UM profissional só (ex.: tudo é "com o William", as assistentes fazem por ele, e a cliente nunca escolhe) ou PROFISSIONAIS SEPARADOS (cada um tem sua cliente e ela pode escolher com quem). Vale na hora, sem publicar. Chame depois que ele responder.',
    input_schema: {
      type: 'object',
      properties: {
        umSo: { type: 'boolean', description: 'true = um só; false = separados.' },
        frente: {
          type: 'string',
          description:
            'Só quando umSo: o nome de quem a cliente sempre "marca com", como está na equipe. Vazio = o próprio dono.',
        },
        mostrarQuemFazNoGoogle: {
          type: 'boolean',
          description:
            'Só quando umSo: true = no Google aparece quem faz de verdade (ex.: Karen); false = tudo no nome da frente. Omita se ele ainda não respondeu.',
        },
      },
      required: ['umSo'],
      additionalProperties: false,
    },
  },
  {
    name: 'definir_titulo_na_agenda',
    description:
      'Grava como o agendamento aparece no Google Agenda dele (o título do evento). Use as lacunas {nome} (primeiro nome da cliente), {telefone} (16-99425-8547), {servico}, {valor} (450), {pagamento} ("450 DEU 50 FICOU 400" se pagou sinal, "450" se não), {profissional} (quem faz). Só depois que ele escolher. Mostre a ele os dois exemplos que a ferramenta devolver (com e sem sinal).',
    input_schema: {
      type: 'object',
      properties: {
        modelo: {
          type: 'string',
          description: 'Ex.: "{nome} {telefone} - {servico} ({pagamento})".',
        },
        caixaAlta: { type: 'boolean', description: 'true = tudo em letra maiúscula.' },
      },
      required: ['modelo', 'caixaAlta'],
      additionalProperties: false,
    },
  },
  {
    name: 'responder_cor',
    description:
      'Grava a resposta dele a UMA das perguntasDeCor da pendência CORES (até quantos tons a tinta clareia, teste de mecha, tempo e preço de matização...). É o que a atendente usa para orçar cor. Chame uma vez por resposta, depois que ele confirmar o que você entendeu.',
    input_schema: {
      type: 'object',
      properties: {
        chave: { type: 'string', description: 'A chave da pergunta, exatamente como na lista.' },
        valor: {
          type: 'number',
          description:
            'NIVEIS: número de tons. MINUTOS: minutos. REAIS: reais, 0 se já está incluso. SIM_NAO: 1 sim, 0 não.',
        },
      },
      required: ['chave', 'valor'],
      additionalProperties: false,
    },
  },
  {
    name: 'aceitar_padrao_da_cor',
    description:
      'Grava DE UMA VEZ todas as perguntasDeCor que faltam com o padrão (sugestao de cada uma), menos as exceções que ele disser. Use quando ele aceitar o padrão da cor ("pode ser", "isso mesmo", "faço assim") ou aceitar com mudanças ("pode, mas a matização eu cobro 50" -> excecoes [{chave:"REAIS_MATIZACAO", valor:50}]). ' +
      'Unidades: NIVEIS número de tons; MINUTOS minutos; REAIS reais (0 = incluso); SIM_NAO 1/0.',
    input_schema: {
      type: 'object',
      properties: {
        excecoes: {
          type: 'array',
          items: {
            type: 'object',
            properties: { chave: { type: 'string' }, valor: { type: 'number' } },
            required: ['chave', 'valor'],
            additionalProperties: false,
          },
        },
      },
      additionalProperties: false,
    },
  },
  {
    name: 'definir_adicional_do_tom',
    description:
      'Grava quanto um TOM/COR custa a mais (e, se ele disser, quanto tempo leva a mais) sobre o preço do procedimento. Ex.: "o platinado eu cobro mais cem" -> tom "platinado", reais 100. "O resto é o preço normal" -> não precisa chamar para os outros. ' +
      'É isso que a atendente soma no orçamento de cor; NÃO use criar_regra nem guardar_conhecimento para adicional de tom. Vale na hora. Diga a ele em qual tom do sistema ficou (vem na resposta). reais 0 = sem adicional.',
    input_schema: {
      type: 'object',
      properties: {
        tom: {
          type: 'string',
          description: 'Como ele falou: platinado, loiro mel, morena iluminada, ruivo...',
        },
        reais: { type: 'number', description: 'Quanto a mais, em reais. 0 = sem adicional.' },
        minutos: { type: 'integer', description: 'Minutos a mais, só se ele disser.' },
      },
      required: ['tom', 'reais'],
      additionalProperties: false,
    },
  },
  {
    name: 'guardar_conhecimento',
    description:
      'Guarda, com as palavras dele, o que o dono ensinou e que NENHUMA outra ferramenta grava: uma regra solta ("não corto cabelo curto"), uma preferência, um jeito de falar com as clientes, o que uma foto mostra ("essa é um loiro iluminado"). Aprender é livre: não tem régua de confiança, e depois alguém transforma isto em serviço, preço ou regra. Use sempre que ele ensinar algo que não coube em outra ferramenta, em vez de só dizer que anotou. Só diga "anotei" depois de receber "Guardado".',
    input_schema: {
      type: 'object',
      properties: {
        palavras: {
          type: 'string',
          description:
            'O que ele disse, com as palavras dele. Se veio de foto ou áudio, escreva o que ele disse sobre a foto junto com o que a leitura da foto mostrou.',
        },
        assunto: {
          type: 'string',
          enum: [
            'IDENTIDADE',
            'HORARIOS',
            'EQUIPE',
            'AGENDA',
            'SERVICOS',
            'PRECO',
            'COR',
            'REGRAS',
            'OUTRO',
          ],
          description: 'De que assunto é. OUTRO só quando nenhum couber.',
        },
        escopo: {
          type: 'string',
          enum: ['OFICIO', 'NEGOCIO', 'VOZ', 'INDEFINIDO'],
          description:
            'OFICIO: vale para qualquer salão. NEGOCIO: é escolha deste salão. VOZ: é o jeito desta dona falar.',
        },
        porqueNaoCoube: {
          type: 'string',
          description: 'Uma frase: por que nenhuma outra ferramenta gravava isto.',
        },
      },
      required: ['palavras', 'assunto', 'escopo', 'porqueNaoCoube'],
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
        // O PALPITE DE CLASSIFICAÇÃO, E POR QUE ELE É SEU E NÃO DE UM HUMANO.
        //
        // Quando você faz HANDOFF, o que o dono disse é guardado com as
        // palavras dele. Guardar sem dizer DE QUE ASSUNTO É empurra o trabalho
        // de ler tudo de novo para uma pessoa, e foi assim que estes campos
        // ficaram nulos desde que nasceram. Você acabou de ler a frase: o
        // palpite custa nada agora e economiza a leitura depois.
        //
        // Palpite errado não quebra nada: isto é fila de revisão, não cadastro.
        palpiteModulo: {
          type: 'string',
          enum: [
            'IDENTIDADE',
            'HORARIOS',
            'EQUIPE',
            'AGENDA',
            'SERVICOS',
            'PRECO',
            'COR',
            'REGRAS',
            'OUTRO',
          ],
          description:
            'De que assunto era o pedido dele. Use OUTRO só quando nenhum couber. Em REPLY, mande OUTRO.',
        },
        palpiteEscopo: {
          type: 'string',
          enum: ['OFICIO', 'NEGOCIO', 'VOZ', 'INDEFINIDO'],
          description:
            'OFICIO: vale para qualquer salão de beleza. NEGOCIO: é uma escolha deste salão. VOZ: é o jeito desta dona falar. Em REPLY, mande INDEFINIDO.',
        },
      },
      required: ['action', 'messages', 'reason', 'palpiteModulo', 'palpiteEscopo'],
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

// 28/09/2026: o servico pelo nome OU pelo id. As ferramentas de preco e de
// variacao pediam o id da lista de PENDENCIAS -- e servico ja publicado nao e
// pendencia. "A escova subiu, agora e 80" virava um laco de "confirma?".
async function resolverServico(
  url: string,
  key: string,
  tenantId: string,
  texto: string
): Promise<{ id: string | null; motivo: string }> {
  const r = (await rpc(url, key, 'eddy_resolver_servico', {
    p_tenant_id: tenantId,
    p_texto: texto ?? '',
  })) as { ok?: boolean; id?: string; reason?: string; servicos?: string[] } | null;
  if (r?.ok && r.id) return { id: r.id, motivo: '' };
  const lista = (r?.servicos ?? []).join(', ');
  return {
    id: null,
    motivo:
      r?.reason === 'AMBIGUO'
        ? `"${texto}" bate com mais de um servico (${lista}); pergunte qual`
        : `nao achei "${texto}" no cadastro (${lista})`,
  };
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
    regras =
      ((await rpc(supabaseUrl, serviceKey, 'agent_prompt', { p_agent: 'DONO' })) as string) ?? '';
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
  // Gravado pelo código antes do modelo (devolução, valor da química): conta
  // como gravação DESTE turno para a trava do "anotei".
  let gravadasPeloCodigo = 0;
  let criados = 0;
  let aprendidas = 0;
  let publicacoes = 0;
  let falhas = 0;

  for (const item of fila) {
    // O link do Google Agenda sai num balao proprio, montado aqui: 32 letras
    // hexadecimais copiadas pelo modelo sao 32 chances de um link quebrado.
    let linkDaAgenda: string | null = null;
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
        resultados.push({
          conversationId: item.conversation_id,
          action: 'HANDOFF',
          motivo: 'DONO_DESCONHECIDO',
        });
        continue;
      }

      const tenantId = contexto.dono.tenantId;

      // O SINAL ESPERANDO O DONO (ver sinal-do-dono.ts). "sim"/"não" curto logo
      // depois do aviso do comprovante confirma direto, sem o modelo.
      let sinaisEsperando: Array<Record<string, unknown>> = [];
      try {
        sinaisEsperando =
          ((await rpc(supabaseUrl, serviceKey, 'sinal_pendentes_do_dono', {
            p_tenant_id: tenantId,
          })) as Array<Record<string, unknown>>) ?? [];
      } catch (erro) {
        console.error(JSON.stringify({ event: 'sinal_pendentes_falhou', erro: String(erro) }));
      }
      {
        const hist = (contexto.history ?? []) as Array<{ direction?: string; text?: string }>;
        let i = hist.length - 1;
        while (i >= 0 && hist[i].direction === 'INBOUND') i--;
        const leva = hist
          .slice(i + 1)
          .map((h) => h.text ?? '')
          .join(' ');
        const ultimaDoEddy = i >= 0 ? (hist[i].text ?? '') : '';
        const atalho = respostaAoSinal(leva, ultimaDoEddy, sinaisEsperando.length);
        if (atalho) {
          const r = (await rpc(supabaseUrl, serviceKey, 'sinal_dono_respondeu', {
            p_tenant_id: tenantId,
            p_referencia: atalho.referencia,
            p_pagou: atalho.pagou,
          })) as { ok?: boolean; texto?: string; esperando?: Array<Record<string, unknown>> };
          const lista = (r?.esperando ?? [])
            .map((e) => `#${e.codigo} ${e.cliente} — ${e.oQue} (${e.valor})`)
            .join('\n');
          const texto =
            (r?.texto ?? 'Não consegui registrar agora.') +
            (r?.ok === false && lista ? '\n' + lista + '\nMe responde com o código.' : '');
          await rpc(supabaseUrl, serviceKey, 'enqueue_outbound_message', {
            p_tenant_id: item.tenant_id,
            p_conversation_id: item.conversation_id,
            p_body_text: texto,
            p_actor: 'AGENT',
            p_idempotency_key: `eddy:${item.last_inbound_message_id}:0`,
          });
          await rpc(supabaseUrl, serviceKey, 'mark_agent_decision', {
            p_tenant_id: item.tenant_id,
            p_message_id: item.last_inbound_message_id,
            p_decision: 'REPLY',
            p_reason: `Sinal: dono respondeu ${atalho.pagou ? 'que caiu' : 'que não caiu'} (atalho, sem modelo).`,
          });
          respondidas++;
          resultados.push({
            conversationId: item.conversation_id,
            action: 'REPLY',
            messages: [texto],
            sinal: r,
          });
          continue;
        }
      }
      const pendencias = (await rpc(supabaseUrl, serviceKey, 'onboarding_pendencies', {
        p_tenant_id: tenantId,
      })) as Pendencia[];

      // O ROTEIRO MANDA; A PAUTA ENTRA POR ETAPA.
      //
      // 24/09/2026, teste com dono-robo: a pauta tinha ~40 itens em toda
      // mensagem (20 definicoes da regua, 9 perguntas de cor, fotos de familia,
      // regras) e o Eddy seguia o que via em destaque, pulando o roteiro --
      // perguntou equipe antes de redes sociais duas vezes. Agora a proxima
      // pergunta vem do roteiro (owner_setup_state.falta, ja ordenado), e da
      // pauta so entra o que e da etapa em curso. O refinamento da regua
      // ("o que e Curto para voce?") so aparece com o cadastro basico pronto.
      const roteiro =
        (contexto.negocio as { falta?: Array<{ campo: string; perguntaSugerida: string }> } | null)
          ?.falta ?? [];
      const etapa = roteiro[0]?.campo ?? null;
      const basicoPronto = roteiro.every((f) => f.campo === 'PUBLICAR' || f.campo === 'WHATSAPP');
      const pautaDaEtapa = (Array.isArray(pendencias) ? pendencias : []).filter((p) => {
        if (basicoPronto) return true;
        if (p.modulo === 'CONHECIMENTO') return false;
        if (p.modulo === 'COR') return etapa === 'CORES';
        if (p.modulo === 'REGRAS') return etapa === 'REGRAS';
        return true;
      });
      const pauta = pautaDaEtapa
        .slice(0, basicoPronto ? 10 : 20)
        .map((p) => `- [${p.chave}] (${p.modulo}) ${p.pergunta} — hoje: ${p.contexto}`)
        .join('\n');
      // A PERGUNTA DO ROTEIRO NAO VIRA REFRAO. 28/09/2026, teste com dono-robo:
      // depois de publicar, o dono mandou 6 mudancas seguidas (preco, pausa,
      // servico novo) e o Eddy fechou TODAS as respostas com "e sobre cor:
      // prefere foto ou audio?". A etapa CORES fica aberta ate as perguntas
      // de cor serem respondidas, entao ela era sempre a "proxima". Se ele ja
      // perguntou nas duas ultimas rodadas e o dono esta em outro assunto,
      // a pergunta espera o dono terminar.
      const SINAL_DA_ETAPA: Record<string, RegExp> = {
        CORES: /\bcor(es)?\b|mechas|colora/i,
        REGRAS: /\bregra/i,
        LEMBRETE: /lembr/i,
        MENSAGEM_DE_CONFIRMACAO: /confirma(ção|cao)|recebe para fechar/i,
        REDES_SOCIAIS: /instagram|redes/i,
        PUBLICAR: /publi/i,
        WHATSAPP: /whatsapp/i,
      };
      const sinalDaEtapa = etapa ? SINAL_DA_ETAPA[etapa] : undefined;
      let jaPerguntouAgora = false;
      let adiado = false;
      if (sinalDaEtapa) {
        const hist = (contexto.history ?? []) as Array<{ direction?: string; text?: string }>;
        let i = hist.length - 1;
        while (i >= 0 && hist[i].direction === 'INBOUND') i--; // a leva de agora
        const levaAgora = hist
          .slice(i + 1)
          .map((h) => h.text ?? '')
          .join(' ');
        let rodadas = 0;
        let perguntou = false;
        // 28/09 (R6): com 2 rodadas a pergunta voltava na 3a, no meio de uma
        // sequencia de mudancas. Agora, feita uma vez, ela so volta quando o
        // dono sinaliza que terminou ou puxa o assunto.
        while (i >= 0 && rodadas < 12) {
          if (hist[i].direction === 'OUTBOUND') {
            if (sinalDaEtapa.test(hist[i].text ?? '')) perguntou = true;
            if (i === 0 || hist[i - 1].direction !== 'OUTBOUND') rodadas++;
          }
          i--;
        }
        // 30/09: "Pode publicar. O que falta no cadastro?" ficou sem resposta:
        // o assunto adiado foi filtrado. Perguntar o que falta tambem e voltar.
        const donoTerminou =
          /\b(o que (mais )?falta|falta (algo|alguma coisa|o que|mais)|que mais (precisa|falta)|proximo passo|o que mais|so isso|é isso|e isso|pode seguir|segue|seguimos|vamos (pra|para)|terminei|acabou|mais nada|tudo certo|nao tenho mais|não tenho mais|era isso|por enquanto e so|por enquanto é só)\b/i.test(
            levaAgora.normalize('NFD').replace(/[\u0300-\u036f]/g, '')
          );
        jaPerguntouAgora = perguntou && !sinalDaEtapa.test(levaAgora) && !donoTerminou;
        // O DONO ADIOU. 30/09: "a parte de cor te mando depois" e, em cada
        // resposta seguinte, "voltando pro cadastro: quando quiser fechar cor
        // e mechas...". Adiado fica adiado ate ELE voltar ao assunto (ou a
        // conversa andar tanto que o adiamento sai do historico).
        const ADIA =
          /\b(depois|mais tarde|outra hora|amanh|semana que vem|agora n[aã]o|outro dia|te mando|mando (quando|depois))\b/i;
        adiado =
          !donoTerminou &&
          !sinalDaEtapa.test(levaAgora) &&
          hist.some(
            (h) =>
              h.direction === 'INBOUND' &&
              // 02/10: "foto depois te mando" é adiar a cor (as fotos são de
              // tom). Só aqui: no filtro de refrão, "fotos" apagava respostas.
              (sinalDaEtapa.test(h.text ?? '') ||
                (etapa === 'CORES' && /\bfotos?\b/i.test(h.text ?? ''))) &&
              ADIA.test(h.text ?? '')
          );
        if (adiado) jaPerguntouAgora = true;
      }
      // O SINAL: o que o dono ja decidiu e a proxima pergunta. 01/10, Duda:
      // "essas perguntas voce tem que fazer ao dono" -- o dono responde, nao nos.
      // Lido ANTES do roteiro: 01/10, o dono respondeu os valores do sinal e o
      // Eddy largou o sinal no meio para perguntar de cor e mechas.
      // A DEVOLUÇÃO DO SINAL COMO ELE DISSE (ver devolucao-dita.ts). Gravada
      // antes do modelo: o contexto deste turno já sai com a regra certa.
      const devolucaoDoTurno = (() => {
        const hist = (contexto.history ?? []) as Array<{ direction?: string; text?: string }>;
        let i = hist.length - 1;
        while (i >= 0 && hist[i].direction === 'INBOUND') i--;
        return devolucaoDita(
          hist
            .slice(i + 1)
            .map((h) => h.text ?? '')
            .join(' . ')
        );
      })();
      gravadasPeloCodigo = 0;
      // O VALOR DO SINAL DA QUÍMICA COMO ELE DISSE (ver sinal-quimica-dito.ts).
      const quimicaDoTurno = (() => {
        const hist = (contexto.history ?? []) as Array<{ direction?: string; text?: string }>;
        let i = hist.length - 1;
        while (i >= 0 && hist[i].direction === 'INBOUND') i--;
        return valorDaQuimicaDito(
          hist
            .slice(i + 1)
            .map((h) => h.text ?? '')
            .join(' . '),
          i >= 0 ? (hist[i].text ?? '') : ''
        );
      })();
      if (quimicaDoTurno != null) {
        try {
          const r = (await rpc(supabaseUrl, serviceKey, 'eddy_definir_sinal', {
            p_tenant_id: tenantId,
            p_campos: { valorQuimicaReais: quimicaDoTurno },
          })) as { ok?: boolean } | null;
          if (r?.ok) {
            anotadas++;
            gravadasPeloCodigo++;
          }
        } catch (erro) {
          console.error(JSON.stringify({ event: 'quimica_dita_falhou', erro: String(erro) }));
        }
      }
      if (devolucaoDoTurno) {
        try {
          await rpc(supabaseUrl, serviceKey, 'eddy_definir_sinal', {
            p_tenant_id: tenantId,
            p_campos: {
              devolve: devolucaoDoTurno.devolve,
              ...(devolucaoDoTurno.ateHoras != null
                ? { devolveAteHoras: devolucaoDoTurno.ateHoras }
                : {}),
            },
          });
          anotadas++;
          gravadasPeloCodigo++;
        } catch (erro) {
          console.error(JSON.stringify({ event: 'devolucao_dita_falhou', erro: String(erro) }));
        }
      }
      let sinalResumo: {
        ativo?: boolean;
        falta?: string[];
        valores?: Record<string, string>;
      } | null = null;
      try {
        sinalResumo = (await rpc(supabaseUrl, serviceKey, 'sinal_resumo', {
          p_tenant_id: tenantId,
        })) as typeof sinalResumo;
      } catch {
        // sem o resumo o Eddy so nao conduz o sinal neste turno
      }
      const histDoDono = ((contexto.history ?? []) as Array<{ direction?: string; text?: string }>)
        .filter((h) => h.direction === 'INBOUND')
        .slice(-4)
        .map((h) => h.text ?? '')
        .join(' ');
      const sinalEmAndamento =
        !!sinalResumo &&
        (sinalResumo.falta ?? []).length > 0 &&
        (Object.keys(sinalResumo.valores ?? {}).length > 0 || /\bsina(l|is)\b/i.test(histDoDono));
      if (sinalEmAndamento) jaPerguntouAgora = true;

      // MUDANCA DEPOIS DE PUBLICAR. 28/09/2026: o dono mudou o preco da escova
      // com o salao ja publicado e o Eddy disse "Prontinho". Estava gravado,
      // mas no rascunho: a atendente seguia cobrando o preco antigo e o dono
      // achava que ja valia.
      const jaPublicado = (contexto.negocio as { publicado?: boolean } | null)?.publicado === true;
      const avisoDePublicado = jaPublicado
        ? '\n\nO SALÃO JÁ ESTÁ PUBLICADO. Serviço, preço, duração, pausa, variação, equipe, horário e regra que você gravar agora ficam no rascunho e a atendente só passa a usar depois de publicar de novo. ' +
          'O lembrete de véspera (`definir_lembrete`) NÃO passa pelo rascunho: vale na hora, então não diga que ele fica no rascunho. ' +
          'Ao confirmar uma mudança, diga isso numa linha e pergunte se publica agora ou se ele ainda tem mais mudanças (aí publica no fim, de uma vez). ' +
          'Nunca diga "já está valendo" antes de `publicar` dar certo.'
        : '';
      const textoDoRoteiro = roteiro.length
        ? (jaPerguntouAgora
            ? (sinalEmAndamento
                ? `PAUSADO: [${roteiro[0].campo}]. Ele está configurando o SINAL agora: NÃO fale deste assunto nesta resposta.\n`
                : adiado
                  ? `ASSUNTO ADIADO PELO DONO: [${roteiro[0].campo}]. Ele disse que manda depois. NÃO lembre, NÃO cobre e NÃO mencione esse assunto até ele voltar a ele. Se o cadastro precisar de algo, é outro assunto.\n`
                  : `PRÓXIMA PERGUNTA (JÁ FEITA HÁ POUCO — NÃO REPITA NESTA RESPOSTA): [${roteiro[0].campo}] ${roteiro[0].perguntaSugerida}\n`) +
              'Ele está em outro assunto. Resolva só o que ele mandou e, no fim, pergunte se tem mais alguma mudança. ' +
              'Volte a esta pergunta quando ele disser que terminou.\n'
            : `PRÓXIMA PERGUNTA: [${roteiro[0].campo}] ${roteiro[0].perguntaSugerida}\n`) +
          (roteiro.length > 1
            ? `Depois, nesta ordem: ${roteiro
                .slice(1)
                .map((f) => f.campo)
                .join(', ')}`
            : 'Depois dela o cadastro básico está completo.')
        : '(cadastro básico completo)';

      // O CADASTRO COMO ESTA AGORA. 24/09/2026: o dono pediu para conferir a
      // pausa das mechas e o Eddy confirmou de memoria o contrario do que
      // estava gravado. Sem o cadastro na mesa, "confirmado" e chute.
      let cadastroAgora = '';
      try {
        cadastroAgora = JSON.stringify(
          await rpc(supabaseUrl, serviceKey, 'eddy_cadastro_resumido', { p_tenant_id: tenantId })
        );
      } catch {
        cadastroAgora = '(indisponível neste turno: não confirme nada do cadastro)';
      }

      // O QUE O DONO MEXEU NO GOOGLE e ainda nao decidiu. So entra quando ha.
      let mexidasAbertas = '';
      try {
        const ms = (await rpc(supabaseUrl, serviceKey, 'eddy_mexidas_abertas', {
          p_tenant_id: tenantId,
        })) as unknown[];
        if (Array.isArray(ms) && ms.length > 0) {
          mexidasAbertas =
            '\n\nHORÁRIOS QUE O DONO MEXEU NO GOOGLE E AINDA NÃO DECIDIU (a cliente não sabe de nada até ele decidir; use `resolver_mexida_no_google` com o código quando ele responder. ' +
            'Se ele disser "desmarca" -> DESMARCAR; "avisa ela"/"muda" (quando moveu) -> MUDAR; "foi sem querer"/"volta" -> VOLTAR. Se não der para saber qual, pergunte):\n' +
            JSON.stringify(ms);
        }
      } catch {
        // sem a lista, o Eddy so nao ve; nada se perde
      }

      let blocoDoSinal = '';
      if (sinalResumo) {
        const proxima = (sinalResumo.falta ?? [])[0];
        blocoDoSinal =
          '\n\nSINAL PARA AGENDAR (o que o dono já decidiu; quem decide é ELE, nunca você): ' +
          JSON.stringify(sinalResumo) +
          (proxima
            ? sinalEmAndamento
              ? '\nELE ESTÁ CONFIGURANDO O SINAL AGORA. Depois de gravar o que ele respondeu, a próxima pergunta é: ' +
                PERGUNTA_DO_SINAL[proxima] +
                '. Ela vem ANTES de qualquer outra pergunta do cadastro. Uma pergunta por vez.'
              : '\nSe ele quer cobrar sinal (escolheu pedir sinal, ou falou de sinal agora), a próxima pergunta é: ' +
                PERGUNTA_DO_SINAL[proxima] +
                '. Uma pergunta por vez.'
            : '');
      }

      // O TESTE DE MECHA DESTE SALÃO. Regra da Duda (01/10): padrão global é o
      // teste no começo do procedimento, no mesmo dia, dentro do tempo dele;
      // "cada salão tem uma forma de falar e um padrão de regras e isso tem que
      // ser perguntado ao dono quando ele estiver configurando". A pergunta vem
      // logo depois do sinal (regras de agendamento), uma vez só.
      let blocoDoTeste = '';
      try {
        const teste = (await rpc(supabaseUrl, serviceKey, 'teste_mecha_resumo', {
          p_tenant_id: tenantId,
        })) as {
          modo?: string;
          diasAntes?: number | null;
          respondido?: boolean;
          jeitoDeFalar?: string | null;
          servicoDoTeste?: string | null;
          fazMechas?: boolean;
        } | null;
        // 02/10: só perguntava se houvesse o serviço "Teste de mecha" já
        // PUBLICADO -- no cadastro do zero nunca perguntou. Vale para quem faz
        // luzes/mechas (rascunho ou publicado) ou já tem o teste cadastrado.
        if (teste?.servicoDoTeste || teste?.fazMechas) {
          const sinalPronto = !sinalEmAndamento && (sinalResumo?.falta ?? []).length === 0;
          blocoDoTeste = teste.respondido
            ? '\n\nTESTE DE MECHA (o dono já decidiu): ' +
              JSON.stringify(teste) +
              '. Se ele quiser mudar, use configurar_teste_de_mecha.'
            : '\n\nTESTE DE MECHA: AINDA NÃO PERGUNTADO AO DONO. ' +
              (sinalPronto
                ? 'É a PRÓXIMA pergunta, antes das outras do cadastro (só espere se ele estiver no meio de outro assunto). '
                : 'Pergunte depois que o sinal estiver configurado. ') +
              'Pergunte assim, com suas palavras: "Como funciona o teste de mecha no seu salão? O mais comum é fazer ' +
              'no começo do procedimento, no mesmo dia, já dentro do tempo das luzes: se o cabelo aguentar, segue na hora. ' +
              'Você faz assim, faz o teste uns dias antes, ou não faz teste?" Com a resposta, chame configurar_teste_de_mecha. ' +
              'Depois, UMA pergunta: se ele tem um jeito próprio de explicar o teste para a cliente (se sim, grave em jeitoDeFalar).' +
              (teste.servicoDoTeste
                ? ''
                : ' O salão ainda NÃO tem o teste cadastrado como serviço: se ele faz o teste uns dias antes, ou cobra o teste à parte, pergunte o valor e o tempo e cadastre o serviço "Teste de mecha" (criar_servico) — sem ele a atendente não consegue marcar só o teste.');
        }
      } catch {
        // sem o resumo, o Eddy só não pergunta agora
      }

      // AS PERGUNTAS DA ATENDENTE QUE ESPERAM O DONO. So entram quando ha
      // alguma: nao custam token no dia a dia.
      let perguntasAbertas = '';
      try {
        const ps = (await rpc(supabaseUrl, serviceKey, 'eddy_perguntas_pendentes', {
          p_tenant_id: tenantId,
        })) as unknown[];
        if (Array.isArray(ps) && ps.length > 0) {
          perguntasAbertas =
            '\n\nPERGUNTAS DA ATENDENTE ESPERANDO O DONO (tem cliente aguardando; use `responder_pergunta_da_atendente`):\n' +
            JSON.stringify(ps);
        }
      } catch {
        perguntasAbertas = '';
      }

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

      // AS FOTOS QUE ELE MANDOU E A REGUA ONDE ELAS CABEM.
      //
      // 24/09: a dona mandou uma colagem de ruivos e escreveu depois "isso aqui
      // sao tons de ruivo". O Eddy leu a leitura da foto no historico e disse
      // "anotado" -- mas nao tinha na mesa nem o id da foto nem o nome exato da
      // familia, entao nao havia como arquivar. Aqui entram os dois: as fotos
      // ainda sem destino (com id) e os nomes da regua, escritos como estao no
      // banco. So vai a lista quando ha foto pendente: regua sem foto para
      // arquivar e token pago a toa.
      let fotosERegua = '';
      try {
        const ctxFotos = (await rpc(supabaseUrl, serviceKey, 'eddy_regua_e_fotos', {
          p_tenant_id: tenantId,
          p_conversation_id: item.conversation_id,
        })) as {
          fotosSemDestino?: unknown[];
          fotosJaArquivadas?: unknown[];
          familiasDeTom?: { nome: string; tons?: string; fotos: number }[];
          regua?: { dimensao: string; opcoes: string[] }[];
        };
        // 28/09/2026: o bloco so entrava com foto SEM lugar. Com todas
        // arquivadas, "a do preto natural e tom 1, poe em Preto" nao tinha
        // como ser feito: ele nao via a foto nem o id. Agora entra sempre que
        // houver foto desta conversa, arquivada ou nao.
        const semLugar = ctxFotos.fotosSemDestino ?? [];
        const arquivadas = ctxFotos.fotosJaArquivadas ?? [];
        if (semLugar.length > 0 || arquivadas.length > 0) {
          const familias = (ctxFotos.familiasDeTom ?? [])
            .map(
              (f) =>
                `${f.nome}${f.tons ? ` (tons ${f.tons})` : ''} - ${f.fotos} foto${f.fotos === 1 ? '' : 's'}`
            )
            .join(', ');
          const regua = (ctxFotos.regua ?? [])
            .map((d) => `- ${d.dimensao}: ${d.opcoes.join(', ')}`)
            .join('\n');
          fotosERegua =
            (semLugar.length > 0
              ? '\n\nFOTOS QUE ELE MANDOU E AINDA NÃO TÊM LUGAR (use o id em `arquivar_fotos`; várias seguidas antes de uma legenda costumam ser um lote só):\n' +
                JSON.stringify(semLugar)
              : '') +
            (arquivadas.length > 0
              ? '\n\nFOTOS DELE QUE JÁ ESTÃO ARQUIVADAS (para mudar de família ou gravar o tom que ele disse, use o id em `corrigir_foto`):\n' +
                JSON.stringify(arquivadas)
              : '') +
            '\n\nFAMÍLIAS DE TOM DESTE SALÃO (escreva o nome exatamente assim):\n' +
            (familias || '(nenhuma)') +
            '\n\nRÉGUA DESTE SALÃO (dimensão: opções, escritas exatamente assim):\n' +
            (regua || '(vazia)');
        }
      } catch (erro) {
        console.error(
          JSON.stringify({ event: 'eddy_fotos_indisponiveis', erro: String(erro).slice(0, 200) })
        );
      }

      // TODAS AS MENSAGENS DELE DESDE A SUA ULTIMA RESPOSTA, NO FIM.
      //
      // 25/09/2026, teste real da Duda. Ela mandou um audio ("a Duda marca os
      // dias dela no Google Agenda, consegue entrar la?") e, 30 segundos
      // depois, um texto com a lista de servicos. A transcricao estava no
      // contexto, inteira. O Eddy respondeu so o texto e o audio sumiu. A
      // linha de abertura dizia "a ultima mensagem do historico e a que esta
      // esperando resposta" -- e ele obedeceu: a ultima era o texto.
      //
      // Dono manda em rajada: audio, texto, foto, outro audio. Cada uma e uma
      // pergunta ou uma informacao. Aqui elas vao numeradas, na ordem, e sao
      // a ultima coisa que ele le.
      const historico = (contexto.history ?? []) as Array<{
        direction?: string;
        text?: string;
        leituraDaMidia?: string | null;
      }>;
      const leva: string[] = [];
      for (let i = historico.length - 1; i >= 0; i--) {
        const h = historico[i];
        if (h.direction !== 'INBOUND') break;
        const texto = (h.text ?? '').trim();
        const midia = (h.leituraDaMidia ?? '').trim();
        const tipo = midia ? (/áudio/i.test(midia) ? 'ÁUDIO' : 'MÍDIA') : 'TEXTO';
        leva.unshift(`[${tipo}] ${[texto, midia].filter(Boolean).join(' — ')}`);
      }
      // O que o Eddy disse na rodada anterior (os baloes logo antes desta
      // leva). A trava do publicar confere se cada mudanca foi dita por um dos
      // dois: pelo dono agora, ou pelo Eddy quando perguntou "publico?".
      const faladoAntes: string[] = [];
      {
        let i = historico.length - 1;
        while (i >= 0 && historico[i].direction === 'INBOUND') i--;
        while (i >= 0 && historico[i].direction === 'OUTBOUND') {
          faladoAntes.unshift(historico[i].text ?? '');
          i--;
        }
      }
      const semAcento = (t: string) =>
        t
          .toLowerCase()
          .normalize('NFD')
          .replace(/[\u0300-\u036f]/g, '');
      const conversaDaPublicacao = semAcento([...leva, ...faladoAntes].join(' '));
      // FOTO DE TABELA DE PRECOS. 28/09/2026, caso E14: o dono mandou "essa e
      // minha tabela atual" e o Eddy decidiu sozinho que era "uma foto
      // antiga", nao gravou nada e sumiu com os 4 servicos que so a tabela
      // tinha. Quem diz se a tabela vale e o dono; o Eddy compara e pergunta.
      const temTabela = leva.some((m) => /tabela|R\$\s?\d/i.test(m) && m.startsWith('[MÍDIA]'));
      const regraDaTabela = temTabela
        ? '\n\nUMA DELAS É FOTO DE TABELA DE PREÇOS. Compare item a item com O CADASTRO COMO ESTÁ AGORA e responda em três grupos: ' +
          '(1) iguais ao cadastro — só diga que batem; ' +
          '(2) diferentes — diga os dois valores ("na foto R$ 120, no cadastro R$ 130") e pergunte qual vale, UMA pergunta para todos; ' +
          '(3) serviços que só a foto tem — liste e pergunte se cria (e quanto tempo leva cada). "A partir de" na foto vira `aPartirDe`. ' +
          'Nunca decida sozinho que a foto é antiga ou nova (mesmo que ele diga "atual", o cadastro pode ter um valor que ele te deu depois), ' +
          'nunca ignore um item e não grave nada do grupo 2 antes de ele responder.'
        : '';
      const blocoDaLeva =
        leva.length === 0
          ? ''
          : '\n\nAS MENSAGENS DELE QUE ESTÃO ESPERANDO A SUA RESPOSTA (' +
            leva.length +
            ', na ordem em que ele mandou):\n' +
            leva.map((m, i) => `${i + 1}. ${m}`).join('\n') +
            '\n\nResponda TODAS. Áudio é mensagem como texto: o que ele falou no áudio exige resposta tanto quanto o que ele escreveu. ' +
            'Grave o que cada uma trouxe e, na resposta, trate cada uma (mesmo que em uma linha) antes da próxima pergunta do roteiro. ' +
            'Se alguma pede uma coisa que você NÃO faz, diga isso com clareza e diga o que dá para fazer no lugar. Nunca pule em silêncio.' +
            regraDaTabela +
            '\n' +
            O_QUE_AINDA_NAO_FACO;

      const mensagens: Anthropic.MessageParam[] = [
        {
          role: 'user',
          content:
            'HOJE: ' +
            hojeNoSalao() +
            '. Data sem ano que ele disser é a PRÓXIMA vez que esse dia chega a partir de hoje.\n\n' +
            'Esta conversa com o dono (JSON). As mensagens dele que esperam resposta estão listadas no fim.\n\n' +
            JSON.stringify({
              dono: contexto.dono,
              negocio: contexto.negocio,
              history: contexto.history,
            }) +
            '\n\nO ROTEIRO DO CADASTRO (a primeira é a sua próxima pergunta; se ele já respondeu outra coisa, grave e volte a ela):\n' +
            textoDoRoteiro +
            // O padrão da cor numa mensagem só (proximo-passo.ts).
            (roteiro[0]?.campo === 'CORES'
              ? (() => {
                  const padrao = padraoDaCor(
                    (
                      roteiro[0] as {
                        perguntasDeCor?: Array<{
                          chave?: string;
                          sugestao?: number;
                          pergunta?: string;
                        }>;
                      }
                    ).perguntasDeCor ?? []
                  );
                  return padrao
                    ? '\nCOR: depois que ele contar como trabalha com cor (foto ou áudio), NÃO faça as perguntasDeCor uma a uma: mande exatamente este padrão e, quando ele aceitar (ou aceitar com mudanças), chame aceitar_padrao_da_cor. Nunca suponha um valor que ele não confirmou. Padrão: ' +
                        padrao +
                        '\n'
                    : '';
                })()
              : '') +
            avisoDePublicado +
            '\n\nO CADASTRO COMO ESTÁ AGORA (lido do banco neste turno; é daqui que você confirma qualquer coisa; dias: 0=domingo … 6=sábado):\n' +
            cadastroAgora +
            '\nSe algo que VOCÊ disse antes nesta conversa contradiz o cadastro acima, o cadastro vale: diga "corrigindo o que eu te falei: ..." e não repita o erro. ' +
            'Quem está "SEM DIA FIXO" não trabalha em nenhum dia da semana por padrão: só nos dias marcados que aparecem ali.' +
            '\n\nAJUSTES QUE FALTAM (olhe modoDaEquipe e tituloNaAgenda no cadastro). Quando o roteiro acima estiver vazio, ou logo depois de ele conectar a agenda, ' +
            'faça UMA destas perguntas por vez (nunca as duas juntas, nunca junto com outra pergunta):\n' +
            '- modoDaEquipe "AINDA NÃO PERGUNTADO": "Pra cliente, é tudo com você (a equipe faz por você e ela nunca escolhe), ou cada profissional tem a sua cliente e ela pode escolher com quem?" -> definir_modo_da_equipe. Se for tudo com ele, na mesma conversa pergunte: "E na sua agenda do Google, quer ver quem vai fazer cada horário (ex.: Karen), ou tudo no seu nome?" -> definir_modo_da_equipe de novo com mostrarQuemFazNoGoogle.\n' +
            '- tituloNaAgenda "AINDA NÃO ESCOLHIDO": pergunte como ele quer ver o agendamento no Google Agenda e mostre estes modelos NUMERADOS, cada um com o exemplo, e diga que pode ser do jeito dele:\n' +
            '  1) CAROL 16-99425-8547 - LUZES (450 DEU 50 FICOU 400)  [nome, telefone, procedimento e o que pagou de sinal; sem sinal fica (450)]\n' +
            '  2) CAROL 16-99425-8547 - LUZES\n' +
            '  3) Carol - Luzes\n' +
            '  4) Carol 16-99425-8547 - Luzes - R$ 450\n' +
            '  5) Luzes - Carol (com Duda)  [mostra quem da equipe faz]\n' +
            '  6) 16-99425-8547 - Carol - Luzes (450 DEU 50 FICOU 400)\n' +
            '  e se prefere tudo em MAIÚSCULO ou normal. Modelos: 1={nome} {telefone} - {servico} ({pagamento}); 2={nome} {telefone} - {servico}; 3={nome} - {servico}; ' +
            '4={nome} {telefone} - {servico} - R$ {valor}; 5={servico} - {nome} (com {profissional}); 6={telefone} - {nome} - {servico} ({pagamento}). -> definir_titulo_na_agenda.' +
            '\n\nDETALHES QUE `anotar` ACEITA NESTA ETAPA (a chave entre colchetes é obrigatória em `anotar`, e você nunca inventa uma):\n' +
            (pauta || '(nenhum nesta etapa)') +
            '\n\nAS HABILIDADES QUE ESTE SALÃO TEM (é desta lista que você escolhe em `criar_servico`, escrita exatamente assim; você nunca inventa uma):\n' +
            (listaHabilidades ||
              '(nenhuma habilidade com gente ativa — não dá para criar serviço agora)') +
            fotosERegua +
            mexidasAbertas +
            blocoDoSinal +
            blocoDoTeste +
            (sinaisEsperando.length > 0
              ? '\n\nSINAIS ESPERANDO VOCÊ (comprovante de cliente que o dono ainda não conferiu): ' +
                JSON.stringify(sinaisEsperando) +
                '\nQuando ele disser que caiu ou que não caiu, chame confirmar_sinal. Nunca confirme sem ele dizer.'
              : '') +
            perguntasAbertas +
            blocoDaLeva,
        },
      ];

      let sessaoId: string | null = null;
      let turnoId: string | null = null;
      // A trava do publicar, e ela e tecnica, nao so instrucao no prompt: sem
      // ter chamado `resumo` nesta conversa, `publicar` e recusado aqui mesmo,
      // antes de chegar ao banco. Prompt convence; codigo garante.
      let viuOResumo = false;
      // 28/09/2026: o que ESTE turno gravou de preco e de foto. A trava do
      // "anotei" so via se ALGO tinha sido gravado; "Anotei: progressiva R$199,
      // com muito volume R$450" passou porque a progressiva foi gravada e o
      // 450 nao foi para lugar nenhum. Agora cada valor dito e conferido.
      const precosGravados = new Set<number>();
      let mexeuEmFoto = false;
      let jaCobreiOValor = false;
      let jaCobreiAFoto = false;
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
      // Toda escrita conta: criar, anotar, aprender. 24/09/2026: a trava so
      // olhava `criados`, e "cor gravada certinho" (que teria de passar por
      // `responder_cor`, contada em `anotadas`) nao tinha como ser pega.
      const gravacoes = () => criados + anotadas + aprendidas;
      const gravacoesAoEntrar = gravacoes() - gravadasPeloCodigo;
      let jaCobreiAMentira = false;
      let jaCobreiOErroTecnico = false;
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
          system: [
            { type: 'text', text: regras, cache_control: { type: 'ephemeral', ttl: CACHE_TTL } },
          ],
          // Na ultima volta so sobra responder: o que faltou gravar ele diz
          // que faltou, em vez de o dono ficar sem resposta.
          tools:
            volta === MAX_VOLTAS - 1
              ? FERRAMENTAS.filter((f) => f.name === 'atender')
              : FERRAMENTAS,
          tool_choice: { type: 'any' },
          messages: mensagens,
        });

        const u = (resposta.usage ?? {}) as unknown as Record<string, number>;
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
          // Com as flexoes: "cor gravada certinho" passou em 24/09 porque a
          // lista tinha "gravado" e nao "gravada".
          const prometeuTerGravado =
            /\b((anot|grav|registr|cadastr|salv|guard|atualiz|arquiv)(ei|ado|ada|ados|adas|ou|amos)|corrig(i|ido|ida|idos|idas|imos))\b/i;
          const falaQueGravou = (escolha.messages ?? []).some((m) =>
            prometeuTerGravado.test(String(m ?? ''))
          );

          if (
            falaQueGravou &&
            gravacoes() === gravacoesAoEntrar &&
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
                  'Escolha: chame a ferramenta que grava isso agora (cor e `responder_cor`, uma ' +
                  'vez por resposta; regra e `criar_regra`; redes, confirmacao e lembrete tem ' +
                  'ferramenta propria; nome e endereco `registrar_identidade`; servico ' +
                  '`criar_servico`; preco `definir_preco`) -- ou, se faltar informacao, chame ' +
                  '`atender` de novo e apenas PERGUNTE, sem dizer que anotou.',
              })),
            });
            continue;
          }

          // A TRAVA DO VALOR. 28/09/2026: "Anotei: progressiva R$199, com muito
          // volume R$450" -- a progressiva foi gravada, o 450 nao, e a trava de
          // cima nao pegou porque ALGO tinha sido gravado. Cada R$ que ele diz
          // ter anotado tem que estar gravado: neste turno ou ja no cadastro.
          const frasesDeGravacao = (escolha.messages ?? [])
            .map((m) => String(m ?? ''))
            .filter((m) => prometeuTerGravado.test(m));
          const valoresDitos = frasesDeGravacao.flatMap((m) =>
            [...m.matchAll(/R\$\s?(\d{1,5}(?:[.,]\d{1,2})?)/g)].map((x) =>
              Number(x[1].replace(',', '.'))
            )
          );
          if (valoresDitos.length > 0 && !jaCobreiOValor && volta < MAX_VOLTAS - 1) {
            let noCadastro: number[] = [];
            try {
              noCadastro = (
                ((await rpc(supabaseUrl, serviceKey, 'eddy_valores_gravados', {
                  p_tenant_id: tenantId,
                })) as number[] | null) ?? []
              ).map(Number);
            } catch {
              noCadastro = [];
            }
            const faltando = [...new Set(valoresDitos)].filter(
              (v) => !precosGravados.has(v) && !noCadastro.some((c) => Math.abs(c - v) < 0.005)
            );
            if (faltando.length > 0) {
              jaCobreiOValor = true;
              mensagens.push({ role: 'assistant', content: resposta.content });
              mensagens.push({
                role: 'user',
                content: chamadas.map((c) => ({
                  type: 'tool_result' as const,
                  tool_use_id: c.id,
                  content:
                    `NAO ENVIEI. Voce escreveu que anotou R$ ${faltando.join(', R$ ')}, e esse valor nao ` +
                    'esta gravado em lugar nenhum. Grave antes: preco de servico com `definir_preco`, ' +
                    'segundo preco do mesmo servico (por volume, tamanho) com `criar_variacao`, condicao ' +
                    'com `criar_regra`, sinal de um procedimento com `definir_sinal_do_servico`, sinal de ' +
                    'toda a quimica com `configurar_sinal` valorQuimicaReais. Se nao tiver como gravar, diga a ele que esse valor AINDA NAO ' +
                    'ficou registrado.',
                })),
              });
              continue;
            }
          }

          // A TRAVA DA FOTO. 28/09/2026: "Corrigido: aquela primeira foto nao e
          // mais Iluminado" -- e ela continuou em Iluminado.
          const falaDeFoto =
            /\b(foto|fotos|fam[ií]lia)\b/i.test(frasesDeGravacao.join(' ')) ||
            /\b(corrig|mov|mud)(i|ido|ida|ei)\b.*\b(foto|fam[ií]lia)\b/i.test(
              (escolha.messages ?? []).join(' ')
            );
          if (falaDeFoto && !mexeuEmFoto && !jaCobreiAFoto && volta < MAX_VOLTAS - 1) {
            jaCobreiAFoto = true;
            mensagens.push({ role: 'assistant', content: resposta.content });
            mensagens.push({
              role: 'user',
              content: chamadas.map((c) => ({
                type: 'tool_result' as const,
                tool_use_id: c.id,
                content:
                  'NAO ENVIEI. Voce disse que arquivou ou corrigiu foto, e nenhuma foto foi arquivada ' +
                  'ou corrigida neste turno. Use `arquivar_fotos` (foto sem lugar) ou `corrigir_foto` ' +
                  '(foto ja arquivada, ou para gravar o tom que ele disse) antes de dizer isso.',
              })),
            });
            continue;
          }

          // A TRAVA DO "DEU PROBLEMA PRA GRAVAR".
          //
          // 23/09/2026, conversa real. Em 45 minutos ele escreveu para a dona:
          //   "tive um problema pra gravar o botox"
          //   "so confirmando de novo porque nao gravou direito"
          //   "deu um probleminha, o sistema recusou o formato"
          //
          // O manual dele JA dizia, e a regra estava no ar: "nunca diga ao dono
          // que houve erro, falha ou problema no sistema. Nao e assunto dele."
          // Instrucao em portugues nao segurou -- porque, do ponto de vista do
          // modelo, contar o problema e ser honesto. Ele nao esta desobedecendo
          // por mal.
          //
          // O que o dono precisa e da PERGUNTA. Quem tem que saber do erro e a
          // Eduarda, e para isso existe o alerta -- que disparou certo, as
          // 14:14, com o motivo inteiro. A dona nao precisava ter lido nada
          // disso.
          const contouProblemaDeSistema =
            /\b(o sistema (recusou|deu|n[aã]o)|n[aã]o gravou|problema (pra|para) gravar|probleminha|deu (um )?erro|recusou o formato|n[aã]o consegui gravar|tive um problema)\b/i;
          const vazouErro = (escolha.messages ?? []).some((m) =>
            contouProblemaDeSistema.test(String(m ?? ''))
          );

          if (vazouErro && !jaCobreiOErroTecnico && volta < MAX_VOLTAS - 1) {
            jaCobreiOErroTecnico = true;
            mensagens.push({ role: 'assistant', content: resposta.content });
            mensagens.push({
              role: 'user',
              content: chamadas.map((c) => ({
                type: 'tool_result' as const,
                tool_use_id: c.id,
                content:
                  'NAO ENVIEI. Voce contou ao dono que houve problema no sistema. Isso nao e assunto ' +
                  'dele: ele nao pode consertar, e saber disso so tira a confianca dele no produto. ' +
                  'Quem precisa saber do erro e a equipe da EDDigital, e o alerta ja e automatico. ' +
                  'Reescreva `atender` com a PERGUNTA limpa, como se fosse a primeira vez que voce ' +
                  'esta perguntando -- sem "de novo", sem "confirmando outra vez", sem citar falha. ' +
                  'Se voce ja perguntou isso duas vezes e nao conseguiu gravar, entao pare de ' +
                  'perguntar: encerre com HANDOFF.',
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
            // PAUSA TAMBEM NAO.
            //
            // 23/09, 16:13 a 17:14: dezessete recusas PAUSA_FORA_DE_FAIXA
            // seguidas. A lista de pendencias oferece a chave SERVICO_PAUSA, o
            // modelo seguia a chave pelo `anotar` e mandava a pausa como frase
            // ("30 min, da pra atender outra"), sem numero -- e a porta do banco
            // so aceita minutos. `definir_pausa` e a porta certa desde 23/09, mas
            // enquanto a pendencia apontar para ca, a trava tem que ser aqui.
            if (args.chave?.startsWith('SERVICO_PAUSA:')) {
              devolucoes.push({
                type: 'tool_result',
                tool_use_id: chamada.id,
                content:
                  'NAO gravei. Pausa de servico nao se grava pelo `anotar`. Use `definir_pausa` ' +
                  'com o nome do servico, os minutos em numero, e dentroDoTotal (pergunte a ele ' +
                  'se a pausa ja esta no tempo total ou soma a mais). "Sem pausa" nao precisa gravar.',
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
              aPartirDe?: boolean;
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
                  if (typeof args.precoReais === 'number')
                    precosGravados.add(Number(args.precoReais));
                  let piso = '';
                  if (args.aPartirDe === true) {
                    const p = (await rpc(supabaseUrl, serviceKey, 'eddy_marcar_piso', {
                      p_tenant_id: tenantId,
                      p_servico: r.servico ?? args.nome,
                      p_piso: true,
                    })) as { ok?: boolean } | null;
                    piso = p?.ok
                      ? ' Preco marcado como "a partir de".'
                      : ' ATENCAO: NAO consegui marcar "a partir de"; nao diga que marcou.';
                  }
                  texto =
                    `Criei "${r.servico}" no rascunho, com a habilidade ${r.habilidade}.${piso} ` +
                    'Nenhuma cliente ve isso ate ele publicar. Confirme com ele antes de criar o proximo.';
                } else if (r?.reason === 'HABILIDADE_NAO_EXISTE_NESTE_SALAO') {
                  const nomes = (r.habilidades ?? []).map((h) => h.nome).join(', ');
                  texto =
                    `NAO criei: "${args.habilidade}" nao e uma habilidade deste salao. ` +
                    `As que existem sao: ${nomes}. Pergunte a ele qual delas corresponde -- nao escolha a mais parecida.`;
                } else if (r?.reason === 'SERVICO_JA_EXISTE') {
                  texto = `NAO criei: ja existe um servico chamado "${args.nome}" no cadastro dele. Confirme se ele quer mudar o que ja existe.`;
                } else if (r?.reason === 'NOME_FORA_DE_FAIXA') {
                  // 02/10: "Pé" foi recusado e o Eddy criou "Pé (Pedicure)" por
                  // conta própria. O nome é do dono: nunca inventar outro.
                  texto = `NAO criei: o nome "${args.nome}" ficou fora do tamanho aceito. Nao invente outro nome nem conte do sistema: pergunte a ele como quer que o servico apareca para as clientes.`;
                } else {
                  texto = `NAO criei: ${r?.reason ?? 'motivo desconhecido'}. Confirme com ele antes de insistir.`;
                }
              } catch (erro) {
                texto = `Nao deu para criar agora (${String(erro).slice(0, 120)}). Siga a conversa.`;
              }
            }
          } else if (chamada.name === 'definir_pausa') {
            const args = chamada.input as {
              servico: string;
              minutos: number;
              dentroDoTotal: boolean;
              profissionalLivre?: boolean;
              confianca: number;
            };
            if (typeof args.confianca !== 'number' || args.confianca < 0.75) {
              texto = 'NAO gravei: confianca abaixo de 0,75. Confirme a pausa com ele.';
            } else {
              try {
                const r = (await rpc(supabaseUrl, serviceKey, 'onboarding_definir_pausa', {
                  p_tenant_id: tenantId,
                  p_servico: args.servico,
                  p_minutos: Math.round(args.minutos),
                  p_dentro_do_total: args.dentroDoTotal !== false,
                  p_libera: args.profissionalLivre !== false,
                })) as {
                  ok?: boolean;
                  reason?: string;
                  servico?: string;
                  pausaMinutos?: number;
                  atendimentoMinutos?: number;
                  totalMinutos?: number;
                  comoResolver?: string;
                  totalAtual?: number;
                  liberaProfissional?: boolean;
                  corrigida?: boolean;
                } | null;

                if (r?.ok) {
                  criados += 1;
                  // O cadastro do prompt foi lido antes desta mudanca: o total
                  // que vale e o de agora (28/09: ele disse "110 min" num
                  // servico de 150).
                  let comoFicou = '';
                  try {
                    const cad = (await rpc(supabaseUrl, serviceKey, 'eddy_cadastro_resumido', {
                      p_tenant_id: tenantId,
                    })) as { servicos?: string[] } | null;
                    const alvo = (r.servico ?? args.servico).toLowerCase();
                    const linha = (cad?.servicos ?? []).find((l) =>
                      l.toLowerCase().startsWith(alvo)
                    );
                    if (linha)
                      comoFicou = ` Como ficou (use ESTE total, nao some de cabeca): ${linha}.`;
                  } catch {
                    // sem a linha, o texto abaixo ainda diz o que foi gravado
                  }
                  const livre = r.liberaProfissional !== false;
                  texto = r.corrigida
                    ? `Corrigi a pausa de ${r.pausaMinutos} min em "${r.servico}": agora a profissional ${livre ? 'FICA livre' : 'NAO fica livre'} para outra cliente.` +
                      comoFicou
                    : `Gravei a pausa de ${r.pausaMinutos} min em "${r.servico}": ` +
                      `${r.atendimentoMinutos} min de atendimento + ${r.pausaMinutos} de pausa, ` +
                      `total ${r.totalMinutos} min. Durante a pausa a profissional ${livre ? 'fica livre para outra cliente' : 'NAO fica livre: a agenda nao encaixa ninguem nesse tempo'}.` +
                      comoFicou;
                } else if (r?.reason === 'PAUSA_MAIOR_QUE_O_SERVICO') {
                  texto = `NAO gravei: o servico tem ${r.totalAtual} min no total e a pausa pedida e maior. ${r.comoResolver}`;
                } else if (r?.reason === 'SERVICO_JA_TEM_PAUSA') {
                  texto = `NAO gravei: "${args.servico}" ja tem pausa cadastrada. Confirme com ele se mudou.`;
                } else if (r?.reason === 'SERVICO_NAO_EXISTE') {
                  texto = `NAO gravei: nao achei o servico "${args.servico}". Crie com \`criar_servico\` antes.`;
                } else if (r?.reason === 'SERVICO_TEM_ETAPAS_DEMAIS') {
                  texto = `NAO gravei: ${r.comoResolver}`;
                } else {
                  texto = `NAO gravei: ${r?.reason ?? 'motivo desconhecido'}.`;
                }
              } catch (erro) {
                texto = `Nao deu para gravar agora (${String(erro).slice(0, 120)}). Siga a conversa.`;
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
                const alvo = await resolverServico(
                  supabaseUrl,
                  serviceKey,
                  tenantId,
                  args.servicoId
                );
                if (!alvo.id) throw new Error(alvo.motivo);
                const r = (await rpc(supabaseUrl, serviceKey, 'onboarding_definir_preco', {
                  p_tenant_id: tenantId,
                  p_service_id: alvo.id,
                  p_preco_reais: args.precoReais,
                  p_e_piso: args.ehPiso === true,
                })) as { ok?: boolean; reason?: string; servico?: string; ehPiso?: boolean } | null;
                if (r?.ok) {
                  anotadas += 1;
                  precosGravados.add(Number(args.precoReais));
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
                const alvo = await resolverServico(
                  supabaseUrl,
                  serviceKey,
                  tenantId,
                  args.servicoId
                );
                if (!alvo.id) throw new Error(alvo.motivo);
                const r = (await rpc(supabaseUrl, serviceKey, 'onboarding_criar_variacao', {
                  p_tenant_id: tenantId,
                  p_service_id: alvo.id,
                  p_nome: args.nome,
                  p_preco_reais: args.precoReais,
                })) as { ok?: boolean; reason?: string; nome?: string } | null;
                if (r?.ok) {
                  anotadas += 1;
                  precosGravados.add(Number(args.precoReais));
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
          } else if (chamada.name === 'definir_duracao') {
            const args = chamada.input as {
              servico: string;
              minutosTotais: number;
              confianca: number;
            };
            if (typeof args.confianca !== 'number' || args.confianca < 0.75) {
              texto = 'NAO gravei: confianca abaixo de 0,75. Confirme o tempo com ele.';
            } else {
              try {
                const r = (await rpc(supabaseUrl, serviceKey, 'eddy_definir_duracao', {
                  p_tenant_id: tenantId,
                  p_servico: args.servico,
                  p_minutos: Math.round(args.minutosTotais),
                })) as {
                  ok?: boolean;
                  reason?: string;
                  servico?: string;
                  totalAntes?: number;
                  totalMinutos?: number;
                  pausaMinutos?: number;
                } | null;
                if (r?.ok) {
                  anotadas += 1;
                  texto =
                    `Gravado: ${r.servico} passa de ${r.totalAntes} para ${r.totalMinutos} min no total` +
                    (r.pausaMinutos ? ` (pausa de ${r.pausaMinutos} min continua dentro).` : '.') +
                    ' Vale para as clientes quando ele publicar.';
                } else if (r?.reason === 'SERVICO_NAO_EXISTE') {
                  texto = `NAO gravei: nao achei o servico "${args.servico}" no cadastro. Confirme o nome com ele.`;
                } else if (r?.reason === 'DURACAO_MENOR_QUE_A_PAUSA') {
                  texto = `NAO gravei: o total ficou menor que a pausa (${r.pausaMinutos} min). Pergunte a ele.`;
                } else {
                  texto = `NAO gravei: ${r?.reason ?? 'motivo desconhecido'}.`;
                }
              } catch (erro) {
                texto = `Nao deu para gravar a duracao agora (${String(erro).slice(0, 120)}).`;
              }
            }
          } else if (chamada.name === 'corrigir_foto') {
            const args = chamada.input as { foto: string; familia: string; tom?: number };
            try {
              const r = (await rpc(supabaseUrl, serviceKey, 'eddy_corrigir_foto', {
                p_tenant_id: tenantId,
                p_conversation_id: item.conversation_id,
                p_foto: args.foto,
                p_familia: args.familia,
                p_tom: typeof args.tom === 'number' ? Math.round(args.tom) : null,
              })) as {
                ok?: boolean;
                reason?: string;
                familia?: string;
                tom?: number;
                familias?: string[];
              } | null;
              if (r?.ok) {
                criados += 1;
                mexeuEmFoto = true;
                texto =
                  `Corrigido: a foto agora esta em "${r.familia}"` +
                  (r.tom ? `, tom ${r.tom} (dito por ele).` : '.');
              } else if (r?.reason === 'FAMILIA_NAO_EXISTE') {
                texto = `NAO corrigi: "${args.familia}" nao e familia deste salao. As que existem: ${(r.familias ?? []).join(', ')}.`;
              } else {
                texto = `NAO corrigi: ${r?.reason ?? 'motivo desconhecido'}. Nao diga que corrigiu.`;
              }
            } catch (erro) {
              texto = `Nao deu para corrigir a foto agora (${String(erro).slice(0, 120)}). Nao diga que corrigiu.`;
            }
          } else if (chamada.name === 'desativar_servico') {
            const args = chamada.input as { nome: string };
            try {
              const r = (await rpc(
                supabaseUrl,
                serviceKey,
                'onboarding_desativar_servico_por_nome',
                {
                  p_tenant_id: tenantId,
                  p_nome: args.nome,
                }
              )) as { ok?: boolean; reason?: string; servico?: string; procurado?: string } | null;
              if (r?.ok) {
                texto = `Tirei "${r.servico}" do catalogo. Ele continua salvo e volta com \`reativar_servico\` se ele pedir. Diga que tirou; NAO peca confirmacao do que ja fez.`;
                anotadas++;
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
          } else if (chamada.name === 'reativar_servico') {
            const args = chamada.input as { nome: string };
            try {
              const r = (await rpc(supabaseUrl, serviceKey, 'eddy_reativar_servico', {
                p_tenant_id: tenantId,
                p_nome: args.nome,
              })) as {
                ok?: boolean;
                reason?: string;
                servico?: string;
                precoCentavos?: number | null;
                minutosTotais?: number | null;
                procurado?: string;
              } | null;
              if (r?.ok) {
                const preco =
                  r.precoCentavos != null
                    ? `R$ ${(r.precoCentavos / 100).toFixed(0)}`
                    : 'sem preco';
                texto = `Voltou "${r.servico}" ao catalogo: ${preco}, ${r.minutosTotais ?? '?'} min, como era antes. Esta no rascunho.`;
                anotadas++;
              } else if (r?.reason === 'JA_ESTA_NO_CATALOGO') {
                texto = `"${r.procurado}" ja esta no catalogo, ativo. Nada a voltar.`;
              } else if (r?.reason === 'NAO_HA_SERVICO_TIRADO_COM_ESSE_NOME') {
                texto = `Nao ha servico tirado com o nome "${r.procurado}". Confira o nome com ele ou crie com \`criar_servico\`.`;
              } else if (r?.reason === 'NOME_AMBIGUO') {
                texto = `Mais de um servico tirado com o nome "${r.procurado}". Pergunte qual.`;
              } else {
                texto = `NAO voltou: ${r?.reason ?? 'motivo desconhecido'}.`;
              }
            } catch (erro) {
              texto = `Nao deu para voltar o servico agora (${String(erro).slice(0, 120)}).`;
            }
          } else if (chamada.name === 'definir_o_que_o_agente_faz') {
            const args = chamada.input as {
              marcaHorario: boolean;
              pedeSinal?: boolean;
              politicaDeCancelamento?: boolean;
              lembraDaVespera?: boolean;
              confianca: number;
            };
            if (typeof args.confianca !== 'number' || args.confianca < 0.75) {
              texto =
                'NAO gravei: confianca abaixo de 0,75. Pergunte a ele de novo, com as duas opcoes.';
            } else {
              try {
                const r = (await rpc(
                  supabaseUrl,
                  serviceKey,
                  'onboarding_definir_o_que_o_agente_faz',
                  {
                    p_tenant_id: tenantId,
                    p_marca_horario: args.marcaHorario === true,
                    p_pede_sinal: args.pedeSinal === true,
                    p_cancelamento: args.politicaDeCancelamento === true,
                    p_lembra_vespera: args.lembraDaVespera === true,
                  }
                )) as {
                  ok?: boolean;
                  reason?: string;
                  marcaHorario?: boolean;
                  pedeSinal?: boolean;
                  politicaDeCancelamento?: boolean;
                  lembreteAindaNaoDisponivel?: boolean;
                  comoResolver?: string;
                } | null;

                if (r?.ok) {
                  criados += 1;
                  const partes = ['responder duvida de preco, horario e o que o salao faz'];
                  if (r.marcaHorario) partes.push('marcar horario na agenda');
                  if (r.pedeSinal) partes.push('pedir sinal para confirmar');
                  if (r.politicaDeCancelamento) partes.push('aplicar a regra de cancelamento');
                  // 02/10: o Eddy disse ao William "anotado: você vai marcar
                  // horário na agenda" -- quem marca é a atendente, não ele.
                  texto =
                    `Gravei: a atendente do salão (não o dono) vai ${partes.join(', ')}. ` +
                    'Ao confirmar para ele, diga que A ATENDENTE vai fazer isso pelas clientes (ex.: "a atendente vai responder e marcar o horário delas direto na sua agenda"); nunca diga que ele vai marcar. ' +
                    (r.marcaHorario
                      ? 'Como ele vai marcar, voce VAI precisar saber como cada profissional trabalha e quanto tempo cada servico leva, incluindo pausa.'
                      : 'Como ele NAO vai marcar, nao pergunte disponibilidade por profissional nem tempo de pausa: nao serve para nada neste salao.') +
                    (r.lembreteAindaNaoDisponivel
                      ? ' Ele pediu lembrete de vespera: diga que ainda nao esta liberado, que voce avisa quando estiver, e NAO prometa data.'
                      : '');
                } else if (r?.reason === 'SINAL_E_CANCELAMENTO_PRECISAM_DE_AGENDA') {
                  texto = `NAO gravei: ${r.comoResolver}`;
                } else {
                  texto = `NAO gravei: ${r?.reason ?? 'motivo desconhecido'}.`;
                }
              } catch (erro) {
                texto = `Nao deu para gravar agora (${String(erro).slice(0, 120)}). Siga a conversa.`;
              }
            }
          } else if (chamada.name === 'registrar_identidade') {
            const args = chamada.input as {
              nome: string;
              endereco?: string;
              estado?: string;
              confianca: number;
            };
            if (typeof args.confianca !== 'number' || args.confianca < 0.75) {
              texto = 'NAO gravei: confianca abaixo de 0,75. Pergunte o nome e o endereco de novo.';
            } else {
              try {
                const r = (await rpc(supabaseUrl, serviceKey, 'onboarding_registrar_identidade', {
                  p_tenant_id: tenantId,
                  p_nome: args.nome,
                  p_endereco: typeof args.endereco === 'string' ? args.endereco : null,
                  p_uf: typeof args.estado === 'string' ? args.estado : null,
                })) as {
                  ok?: boolean;
                  reason?: string;
                  salao?: string;
                  endereco?: string;
                  uf?: string;
                  recebi?: string;
                } | null;

                if (r?.ok) {
                  criados += 1;
                  texto = r.endereco
                    ? `Gravei: salao "${r.salao}", endereco "${r.endereco}", ${r.uf}.`
                    : `Gravei o nome "${r.salao}". Falta o endereco -- pergunte rua, numero, bairro, cidade e estado.`;
                } else if (r?.reason === 'ENDERECO_CURTO_DEMAIS') {
                  texto =
                    'NAO gravei o endereco: veio curto demais. Cliente sai para a rua com ele. Peca rua, numero, bairro, cidade e estado.';
                } else if (r?.reason === 'FALTA_O_ESTADO') {
                  texto =
                    'NAO gravei: falta o estado. Pergunte a ele a UF, e NAO deduza pela cidade -- ' +
                    'ha cidades com o mesmo nome em estados diferentes.';
                } else if (r?.reason === 'ESTADO_INVALIDO') {
                  texto = `NAO gravei: "${r.recebi}" nao e uma UF. Peca as duas letras do estado (SP, MG, GO...).`;
                } else {
                  texto = `NAO gravei: ${r?.reason ?? 'motivo desconhecido'}.`;
                }
              } catch (erro) {
                texto = `Nao deu para gravar agora (${String(erro).slice(0, 120)}). Siga a conversa.`;
              }
            }
          } else if (chamada.name === 'criar_membro_equipe') {
            const args = chamada.input as {
              nome: string;
              tipo?: string;
              disponibilidade?: string;
              confianca: number;
            };
            if (typeof args.confianca !== 'number' || args.confianca < 0.75) {
              texto = 'NAO cadastrei: confianca abaixo de 0,75. Confirme o nome com ele.';
            } else {
              try {
                const r = (await rpc(supabaseUrl, serviceKey, 'onboarding_criar_membro_equipe', {
                  p_tenant_id: tenantId,
                  p_nome: args.nome,
                  p_tipo: args.tipo === 'ASSISTANT' ? 'ASSISTANT' : 'PROFESSIONAL',
                  p_disponibilidade: args.disponibilidade ?? 'IGUAL_AO_SALAO',
                })) as {
                  ok?: boolean;
                  reason?: string;
                  pessoa?: string;
                  disponibilidade?: { ok?: boolean; reason?: string; pergunteAntes?: string };
                } | null;

                if (r?.ok) {
                  criados += 1;
                  const d = r.disponibilidade;
                  if (d?.ok) {
                    texto =
                      args.disponibilidade === 'SEM_DIA_FIXO'
                        ? `Cadastrei ${r.pessoa} sem dia fixo. Ela so aparece como opcao nas datas que voce marcar -- ` +
                          'pergunte a ele quais datas ela ja tem e use `marcar_dia_da_profissional` em cada uma.'
                        : `Cadastrei ${r.pessoa} na equipe, trabalhando no horario do salao.`;
                  } else {
                    // A pessoa ficou criada e a disponibilidade nao. Dizer so
                    // "cadastrei" deixaria uma profissional que nunca aparece.
                    texto =
                      `Cadastrei ${r.pessoa}, MAS a disponibilidade dela nao ficou (${d?.reason ?? '?'}). ` +
                      `Enquanto isso ninguem consegue marcar com ela. ` +
                      (d?.pergunteAntes
                        ? `Pergunte: "${d.pergunteAntes}"`
                        : 'Resolva com `definir_disponibilidade`.');
                  }
                } else if (r?.reason === 'PESSOA_JA_EXISTE') {
                  texto = `NAO cadastrei: ${args.nome} ja esta na equipe.`;
                } else {
                  texto = `NAO cadastrei: ${r?.reason ?? 'motivo desconhecido'}.`;
                }
              } catch (erro) {
                texto = `Nao deu para cadastrar agora (${String(erro).slice(0, 120)}). Siga a conversa.`;
              }
            }
          } else if (chamada.name === 'definir_disponibilidade') {
            const args = chamada.input as {
              nome: string;
              disponibilidade: string;
              dias?: { dia: number; abre: string; fecha: string }[];
              confianca: number;
            };
            if (typeof args.confianca !== 'number' || args.confianca < 0.75) {
              texto = 'NAO gravei: confianca abaixo de 0,75. Confirme com ele como ela trabalha.';
            } else {
              try {
                const r = (await rpc(
                  supabaseUrl,
                  serviceKey,
                  'onboarding_definir_disponibilidade',
                  {
                    p_tenant_id: tenantId,
                    p_nome: args.nome,
                    p_disponibilidade: args.disponibilidade,
                    p_dias: Array.isArray(args.dias) && args.dias.length ? args.dias : null,
                  }
                )) as {
                  ok?: boolean;
                  reason?: string;
                  pessoa?: string;
                  diasGravados?: number;
                  precisaMarcarDatas?: boolean;
                  pergunteAntes?: string;
                } | null;

                if (r?.ok) {
                  criados += 1;
                  texto = r.precisaMarcarDatas
                    ? `${r.pessoa} ficou sem dia fixo. Ela so aparece nas datas que voce marcar -- pergunte quais ela ja tem.`
                    : `Gravei a disponibilidade de ${r.pessoa}: ${r.diasGravados} dia(s) na semana.`;
                } else if (r?.reason === 'SALAO_SEM_HORARIO') {
                  texto = `NAO gravei: o salao ainda nao tem horario. Pergunte antes: "${r.pergunteAntes}"`;
                } else if (r?.reason === 'FALTAM_OS_DIAS_DELA') {
                  texto =
                    'NAO gravei: voce disse que ela tem dias proprios e nao mandou quais. Pergunte os dias e horarios dela.';
                } else if (r?.reason === 'PESSOA_NAO_ESTA_NA_EQUIPE') {
                  texto = `NAO gravei: ${args.nome} nao esta na equipe. Cadastre com \`criar_membro_equipe\` antes.`;
                } else {
                  texto = `NAO gravei: ${r?.reason ?? 'motivo desconhecido'}.`;
                }
              } catch (erro) {
                texto = `Nao deu para gravar agora (${String(erro).slice(0, 120)}). Siga a conversa.`;
              }
            }
          } else if (chamada.name === 'marcar_dia_da_profissional') {
            const args = chamada.input as {
              nome: string;
              data: string;
              abre?: string;
              fecha?: string;
              confianca: number;
            };
            if (typeof args.confianca !== 'number' || args.confianca < 0.75) {
              texto = 'NAO marquei: confianca abaixo de 0,75. Confirme a data com ele.';
            } else {
              try {
                const r = (await rpc(
                  supabaseUrl,
                  serviceKey,
                  'onboarding_marcar_dia_da_profissional',
                  {
                    p_tenant_id: tenantId,
                    p_nome: args.nome,
                    p_data: proximaOcorrencia(args.data),
                    p_abre: typeof args.abre === 'string' && args.abre ? args.abre : null,
                    p_fecha: typeof args.fecha === 'string' && args.fecha ? args.fecha : null,
                  }
                )) as {
                  ok?: boolean;
                  reason?: string;
                  pessoa?: string;
                  data?: string;
                  abre?: string;
                  fecha?: string;
                  comoResolver?: string;
                } | null;

                if (r?.ok) {
                  criados += 1;
                  texto = `Marquei ${r.pessoa} no dia ${r.data}, das ${String(r.abre).slice(0, 5)} as ${String(r.fecha).slice(0, 5)}.`;
                } else if (r?.reason === 'PESSOA_TEM_HORARIO_FIXO') {
                  texto = `NAO marquei: ${args.nome} esta cadastrada com horario fixo. ${r.comoResolver}`;
                } else if (r?.reason === 'DATA_NO_PASSADO') {
                  texto = 'NAO marquei: essa data ja passou. Confirme o dia com ele.';
                } else if (r?.reason === 'SEM_HORA_E_SALAO_FECHADO_NESSE_DIA') {
                  texto = `NAO marquei: o salao nao abre nesse dia da semana. ${r.comoResolver}`;
                } else {
                  texto = `NAO marquei: ${r?.reason ?? 'motivo desconhecido'}.`;
                }
              } catch (erro) {
                texto = `Nao deu para marcar agora (${String(erro).slice(0, 120)}). Siga a conversa.`;
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
                  p_quem_faz:
                    Array.isArray(args.quemFaz) && args.quemFaz.length ? args.quemFaz : null,
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
                  texto =
                    'NAO gravei: tem dia com a hora de fechar antes da de abrir. Confirme com ele.';
                } else if (r?.reason === 'DIAS_NAO_INFORMADOS') {
                  texto = 'NAO gravei: voce nao mandou dia nenhum. Pergunte que dias o salao abre.';
                } else {
                  texto = `NAO gravei: ${r?.reason ?? 'motivo desconhecido'}.`;
                }
              } catch (erro) {
                texto = `Nao deu para gravar agora (${String(erro).slice(0, 120)}). Siga a conversa.`;
              }
            }
          } else if (chamada.name === 'arquivar_fotos') {
            // A FOTO VAI PARA ONDE A ATENDENTE PROCURA.
            //
            // Sem regua de confianca aqui: quem disse o que a foto e foi o dono,
            // com as palavras dele. A duvida (tom ou corte?) se resolve ANTES,
            // perguntando -- o prompt manda, e o banco recusa foto que nao e
            // desta conversa ou que ja foi arquivada.
            const args = chamada.input as {
              fotos?: string[];
              destino?: string;
              alvo?: string;
              dimensao?: string;
              criarOpcao?: boolean;
            };
            try {
              const r = (await rpc(supabaseUrl, serviceKey, 'eddy_arquivar_fotos', {
                p_tenant_id: tenantId,
                p_conversation_id: item.conversation_id,
                p_fotos: Array.isArray(args.fotos) ? args.fotos : [],
                p_destino: args.destino ?? '',
                p_alvo: args.alvo ?? null,
                p_dimensao: args.dimensao ?? null,
                p_criar_opcao: args.criarOpcao === true,
              })) as {
                ok?: boolean;
                reason?: string;
                arquivadas?: number;
                semArquivo?: number;
                opcaoCriada?: boolean;
                familias?: string[];
              } | null;
              if (r?.ok) {
                criados += r.arquivadas ?? 0;
                mexeuEmFoto = true;
                texto =
                  args.destino === 'DESCARTADA'
                    ? `Descartei ${r.arquivadas} foto(s).`
                    : `Arquivei ${r.arquivadas} foto(s) em "${args.alvo}"` +
                      (r.opcaoCriada ? ' (opcao nova criada na regua)' : '') +
                      '. A atendente passa a usar como referencia.' +
                      (r.semArquivo
                        ? ` Atencao: ${r.semArquivo} delas nao tinha arquivo guardado; so a leitura ficou.`
                        : '');
              } else if (r?.reason === 'FAMILIA_NAO_EXISTE') {
                texto = `NAO arquivei: "${args.alvo}" nao e uma familia deste salao. As que existem: ${(r.familias ?? []).join(', ')}. Pergunte a ele qual e.`;
              } else if (r?.reason === 'OPCAO_NAO_EXISTE') {
                texto = `NAO arquivei: "${args.alvo}" nao esta na regua. Confirme o nome com ele; se for um tipo novo, chame de novo com a dimensao e criarOpcao=true.`;
              } else if (r?.reason === 'FOTO_NAO_ENCONTRADA_OU_JA_ARQUIVADA') {
                texto =
                  'NAO arquivei: alguma dessas fotos nao esta na lista de fotos sem lugar (ou ja foi arquivada). Use so os ids da lista.';
              } else {
                texto = `NAO arquivei: ${r?.reason ?? 'motivo desconhecido'}. Nao diga que guardou.`;
              }
            } catch (erro) {
              texto = `Nao deu para arquivar agora (${String(erro).slice(0, 120)}). Nao diga que guardou.`;
            }
          } else if (chamada.name === 'criar_regra') {
            const args = chamada.input as {
              assunto: string;
              titulo: string;
              regra: string;
              palavrasDoDono?: string;
              confianca: number;
            };
            if (typeof args.confianca !== 'number' || args.confianca < 0.75) {
              texto = 'NAO gravei: confianca abaixo de 0,75. Confirme a regra com ele antes.';
            } else {
              try {
                const r = (await rpc(supabaseUrl, serviceKey, 'eddy_criar_regra', {
                  p_tenant_id: tenantId,
                  p_assunto: args.assunto,
                  p_titulo: args.titulo,
                  p_regra: args.regra,
                  p_palavras: args.palavrasDoDono ?? null,
                  p_conversation_id: item.conversation_id,
                })) as { ok?: boolean; reason?: string; textoAtual?: string } | null;
                if (r?.ok) {
                  anotadas += 1;
                  texto = `Regra "${args.titulo}" guardada em rascunho. Vale para as clientes quando ele publicar.`;
                } else if (r?.reason === 'REGRA_JA_ESTA_NO_AR') {
                  texto = `NAO gravei: ja existe uma regra "${args.titulo}" valendo, que diz: "${r.textoAtual}". Pergunte se ele quer mudar; a mudanca de regra no ar e feita na tela Agente.`;
                } else {
                  texto = `NAO gravei a regra: ${r?.reason ?? 'motivo desconhecido'}.`;
                }
              } catch (erro) {
                texto = `Nao deu para gravar a regra agora (${String(erro).slice(0, 120)}).`;
              }
            }
          } else if (chamada.name === 'responder_pergunta_da_atendente') {
            const a = chamada.input as { codigo: string; resposta: string };
            try {
              const r = (await rpc(supabaseUrl, serviceKey, 'eddy_responder_pergunta', {
                p_tenant_id: tenantId,
                p_codigo: a.codigo,
                p_resposta: a.resposta,
              })) as { ok?: boolean; reason?: string } | null;
              if (r?.ok) {
                anotadas += 1;
                texto = `Resposta gravada para #${a.codigo}. A atendente responde a cliente em instantes.`;
              } else {
                texto = `NAO gravei: ${r?.reason ?? 'motivo desconhecido'}. Confira o codigo com ele.`;
              }
            } catch (erro) {
              texto = `Nao deu para gravar agora (${String(erro).slice(0, 120)}). Nao diga que passou.`;
            }
          } else if (chamada.name === 'marcar_a_partir_de') {
            const a = chamada.input as { servico: string; aPartirDe: boolean };
            try {
              const r = (await rpc(supabaseUrl, serviceKey, 'eddy_marcar_piso', {
                p_tenant_id: tenantId,
                p_servico: a.servico,
                p_piso: a.aPartirDe === true,
              })) as { ok?: boolean; reason?: string } | null;
              if (r?.ok) {
                anotadas += 1;
                texto = `Gravado: "${a.servico}" ${a.aPartirDe ? 'e "a partir de"' : 'tem valor fechado'}.`;
              } else {
                texto = `NAO gravei: ${r?.reason ?? 'motivo desconhecido'}. Nao diga que marcou.`;
              }
            } catch (erro) {
              texto = `Nao deu para gravar agora (${String(erro).slice(0, 120)}). Nao diga que marcou.`;
            }
          } else if (
            chamada.name === 'definir_redes' ||
            chamada.name === 'definir_confirmacao' ||
            chamada.name === 'definir_lembrete'
          ) {
            const a = chamada.input as Record<string, unknown>;
            const [funcao, params] =
              chamada.name === 'definir_redes'
                ? [
                    'eddy_definir_redes',
                    {
                      p_instagram: a.instagram ?? null,
                      p_facebook: a.facebook ?? null,
                      p_tiktok: a.tiktok ?? null,
                      p_site: a.site ?? null,
                    },
                  ]
                : chamada.name === 'definir_confirmacao'
                  ? [
                      'eddy_definir_confirmacao',
                      {
                        p_texto: a.texto ?? null,
                        p_foto: a.foto ?? null,
                        p_conversation_id: item.conversation_id,
                      },
                    ]
                  : [
                      'eddy_definir_lembrete',
                      {
                        p_quer: a.quer,
                        p_hora: a.hora ?? null,
                        p_texto_desejado: a.textoDesejado ?? null,
                        p_voltar_ao_padrao: a.voltarAoPadrao === true,
                      },
                    ];
            try {
              const r = (await rpc(supabaseUrl, serviceKey, funcao, {
                p_tenant_id: tenantId,
                ...params,
              })) as { ok?: boolean; reason?: string } | null;
              if (r?.ok) {
                anotadas += 1;
                texto = `Gravado: ${JSON.stringify(r)}`;
              } else {
                texto = `NAO gravei: ${r?.reason ?? 'motivo desconhecido'}. Nao diga que anotou.`;
              }
            } catch (erro) {
              texto = `Nao deu para gravar agora (${String(erro).slice(0, 120)}). Nao diga que anotou.`;
            }
          } else if (chamada.name === 'aceitar_padrao_da_cor') {
            const a = (chamada.input ?? {}) as {
              excecoes?: Array<{ chave: string; valor: number }>;
            };
            try {
              const ctx = (await rpc(supabaseUrl, serviceKey, 'build_owner_context', {
                p_conversation_id: item.conversation_id,
                p_history_limit: 1,
              })) as {
                negocio?: {
                  falta?: Array<{
                    campo?: string;
                    perguntasDeCor?: Array<{ chave?: string; sugestao?: number }>;
                  }>;
                };
              } | null;
              const cores = (ctx?.negocio?.falta ?? []).find((f) => f.campo === 'CORES');
              const pendentes = cores?.perguntasDeCor ?? [];
              const excecao = new Map((a.excecoes ?? []).map((e) => [e.chave, Number(e.valor)]));
              const desconhecidas = [...excecao.keys()].filter(
                (k) => !pendentes.some((p) => p.chave === k)
              );
              let gravadas = 0;
              const falhas: string[] = [];
              for (const p of pendentes) {
                if (!p.chave || typeof p.sugestao !== 'number') continue;
                const valor = excecao.has(p.chave) ? (excecao.get(p.chave) as number) : p.sugestao;
                const r = (await rpc(supabaseUrl, serviceKey, 'eddy_responder_cor', {
                  p_tenant_id: tenantId,
                  p_chave: p.chave,
                  p_valor: valor,
                  p_conversation_id: item.conversation_id,
                })) as { ok?: boolean; reason?: string } | null;
                if (r?.ok) gravadas++;
                else falhas.push(`${p.chave}: ${r?.reason ?? '?'}`);
              }
              if (gravadas > 0) anotadas++;
              texto =
                (gravadas > 0
                  ? `Gravadas ${gravadas} respostas de cor (padrão + exceções). `
                  : 'Nada gravado. ') +
                (falhas.length
                  ? `Falharam: ${falhas.join('; ')}. Não diga que gravou essas. `
                  : '') +
                (desconhecidas.length
                  ? `Estas exceções não são perguntas pendentes e NÃO foram gravadas: ${desconhecidas.join(', ')}. `
                  : '');
            } catch (erro) {
              texto = `Não deu para gravar agora (${String(erro).slice(0, 120)}). Não diga que anotou.`;
            }
          } else if (chamada.name === 'definir_adicional_do_tom') {
            const a = chamada.input as { tom: string; reais: number; minutos?: number };
            try {
              const r = (await rpc(supabaseUrl, serviceKey, 'eddy_definir_adicional_do_tom', {
                p_tenant_id: tenantId,
                p_tom: a.tom,
                p_reais: Number(a.reais ?? 0),
                p_minutos: a.minutos ?? null,
              })) as { ok?: boolean; reason?: string; tom?: string; tons?: unknown } | null;
              if (r?.ok) {
                anotadas++;
                texto =
                  `Gravado no tom "${r.tom}" e JÁ VALE no orçamento da atendente. Como ficaram os tons: ` +
                  JSON.stringify(r.tons) +
                  `. Confirme com ele numa linha que "${a.tom}" ficou como ${r.tom}.`;
              } else if (r?.reason === 'TOM_NAO_EXISTE') {
                texto = `NÃO gravei: não achei "${a.tom}" entre os tons (${JSON.stringify(r.tons)}). Pergunte a qual deles corresponde.`;
              } else {
                texto = `NÃO gravei: ${r?.reason ?? 'motivo desconhecido'}. Não diga que anotou.`;
              }
            } catch (erro) {
              texto = `Não deu para gravar agora (${String(erro).slice(0, 120)}). Não diga que anotou.`;
            }
          } else if (chamada.name === 'configurar_teste_de_mecha') {
            const a = chamada.input as { modo: string; diasAntes?: number; jeitoDeFalar?: string };
            try {
              const r = (await rpc(supabaseUrl, serviceKey, 'eddy_definir_teste_mecha', {
                p_tenant_id: tenantId,
                p_modo: a.modo,
                p_dias_antes: a.diasAntes ?? null,
                p_jeito_de_falar: a.jeitoDeFalar ?? null,
              })) as { ok?: boolean; reason?: string; agora?: unknown } | null;
              if (r?.ok) {
                anotadas++;
                texto =
                  'Gravado e JÁ VALE para a atendente (não passa por publicar). Como ficou: ' +
                  JSON.stringify(r.agora) +
                  (a.jeitoDeFalar
                    ? ''
                    : ' Agora pergunte UMA vez se ele tem um jeito próprio de explicar o teste para a cliente.');
              } else if (r?.reason === 'FALTA_QUANTOS_DIAS_ANTES') {
                texto =
                  'NÃO gravei: falta saber quantos dias antes do procedimento ele faz o teste. Pergunte.';
              } else {
                texto = `NÃO gravei: ${r?.reason ?? 'motivo desconhecido'}. Não diga que anotou.`;
              }
            } catch (erro) {
              texto = `Não deu para gravar agora (${String(erro).slice(0, 120)}). Não diga que anotou.`;
            }
          } else if (chamada.name === 'configurar_sinal') {
            try {
              // O modelo não desmente o dono na devolução (devolucao-dita.ts).
              const campos = { ...((chamada.input ?? {}) as Record<string, unknown>) };
              if (quimicaDoTurno != null) campos.valorQuimicaReais = quimicaDoTurno;
              if (devolucaoDoTurno) {
                campos.devolve = devolucaoDoTurno.devolve;
                if (devolucaoDoTurno.ateHoras != null)
                  campos.devolveAteHoras = devolucaoDoTurno.ateHoras;
                else delete campos.devolveAteHoras;
              }
              const r = (await rpc(supabaseUrl, serviceKey, 'eddy_definir_sinal', {
                p_tenant_id: tenantId,
                p_campos: campos,
              })) as { ok?: boolean; reason?: string; sinal?: { falta?: string[] } } | null;
              if (r?.ok) {
                anotadas++;
                texto =
                  'Gravado e JÁ VALE (não passa por publicar). Como ficou: ' +
                  JSON.stringify(r.sinal) +
                  ((r.sinal?.falta ?? []).length
                    ? ` Próxima pergunta do sinal (faça agora, antes de qualquer outro assunto): ${PERGUNTA_DO_SINAL[(r.sinal?.falta ?? [])[0]] ?? (r.sinal?.falta ?? [])[0]}.`
                    : ' O sinal está completo e ligado.');
              } else if (r?.reason === 'FALTA_VALOR_OU_PIX') {
                texto =
                  'NÃO liguei (o resto do que ele disse ficou gravado): falta o valor do sinal ou a chave Pix. Como ficou: ' +
                  JSON.stringify((r as { sinal?: unknown }).sinal ?? null) +
                  ' Pergunte o que falta.';
              } else {
                texto = `NÃO gravei: ${r?.reason ?? 'motivo desconhecido'}. Não diga que anotou.`;
              }
            } catch (erro) {
              texto = `Não deu para gravar agora (${String(erro).slice(0, 120)}). Não diga que anotou.`;
            }
          } else if (chamada.name === 'definir_sinal_do_servico') {
            const a = chamada.input as { servico: string; valorReais: number };
            try {
              const r = (await rpc(supabaseUrl, serviceKey, 'eddy_definir_sinal_valor', {
                p_tenant_id: tenantId,
                p_servico: a.servico,
                p_valor_centavos: Math.round(Number(a.valorReais ?? 0) * 100),
              })) as {
                ok?: boolean;
                reason?: string;
                servico?: string;
                valor?: string;
                cobra?: boolean;
                preco?: string;
                servicos?: string[];
                sinal?: { falta?: string[] };
              } | null;
              if (r?.ok) {
                anotadas++;
                texto =
                  (r.cobra
                    ? `Gravado: sinal de ${r.valor} em ${r.servico}. Vale na hora.`
                    : `Gravado: ${r.servico} não cobra sinal.`) +
                  ' Quando gravar todos que ele disse, a próxima pergunta do sinal (antes de qualquer outro assunto) é: ' +
                  (PERGUNTA_DO_SINAL[(r.sinal?.falta ?? []).find((f) => f !== 'VALORES') ?? ''] ??
                    'nenhuma, o sinal está completo');
              } else if (r?.reason === 'SERVICO_NAO_EXISTE') {
                texto =
                  `NÃO gravei: não tem "${a.servico}" no cadastro. ` +
                  ((r.servicos ?? []).length
                    ? `Os procedimentos são: ${(r.servicos ?? []).join(', ')}. Pergunte qual é. `
                    : 'O salão ainda não tem nenhum procedimento cadastrado. ') +
                  'Se ele falou de química em geral (luzes, progressiva, coloração...), grave com configurar_sinal valorQuimicaReais, que vale para todos os químicos, inclusive os que ele cadastrar depois. Não diga que guardou sem gravar.';
              } else if (r?.reason === 'SINAL_MAIOR_QUE_O_PRECO') {
                texto = `NÃO gravei: o sinal ficaria maior que o preço (${r.preco}). Confira com ele.`;
              } else {
                texto = `NÃO gravei: ${r?.reason ?? 'motivo desconhecido'}. Não diga que anotou.`;
              }
            } catch (erro) {
              texto = `Não deu para gravar agora (${String(erro).slice(0, 120)}). Não diga que anotou.`;
            }
          } else if (chamada.name === 'confirmar_sinal') {
            const a = chamada.input as { referencia?: string; pagou: boolean };
            try {
              const r = (await rpc(supabaseUrl, serviceKey, 'sinal_dono_respondeu', {
                p_tenant_id: tenantId,
                p_referencia: a.referencia ?? '',
                p_pagou: !!a.pagou,
              })) as { ok?: boolean; texto?: string; esperando?: unknown };
              texto = r?.ok
                ? `Feito. Diga a ele: ${r.texto}`
                : `Não registrei: ${r?.texto ?? 'motivo desconhecido'} Esperando: ${JSON.stringify(r?.esperando ?? [])}. Pergunte qual.`;
            } catch (erro) {
              texto = `Não deu para registrar agora (${String(erro).slice(0, 120)}). Não diga que confirmou.`;
            }
          } else if (chamada.name === 'ver_agenda') {
            const a = chamada.input as { de: string; ate: string };
            try {
              const r = (await rpc(supabaseUrl, serviceKey, 'eddy_ver_agenda', {
                p_tenant_id: tenantId,
                p_de: a.de,
                p_ate: a.ate,
              })) as { ok?: boolean; reason?: string } | null;
              texto = r?.ok
                ? 'Agenda (só o que passou pelo sistema; compromisso pessoal dele no Google não entra): ' +
                  JSON.stringify(r)
                : `Não consegui ver a agenda: ${r?.reason ?? 'motivo desconhecido'}. Não invente números.`;
            } catch (erro) {
              texto = `Não consegui ver a agenda agora (${String(erro).slice(0, 120)}). Não invente números.`;
            }
          } else if (chamada.name === 'resolver_mexida_no_google') {
            const a = chamada.input as { codigo: string; acao: string };
            try {
              const r = (await rpc(supabaseUrl, serviceKey, 'eddy_resolver_mexida', {
                p_tenant_id: tenantId,
                p_codigo: a.codigo,
                p_acao: a.acao,
              })) as {
                ok?: boolean;
                reason?: string;
                feito?: string;
                mensagemParaCliente?: string;
                clienteAvisada?: boolean;
                sinalPagoParaDevolver?: number | null;
                explicacao?: string;
              } | null;
              if (r?.ok) {
                anotadas++;
                texto =
                  `Feito: ${r.feito}.` +
                  (r.mensagemParaCliente ? ` A cliente recebeu: "${r.mensagemParaCliente}"` : '') +
                  (r.clienteAvisada === false
                    ? ' ATENÇÃO: não achei a conversa dela, então ela NÃO foi avisada; diga isso a ele.'
                    : '') +
                  (r.sinalPagoParaDevolver
                    ? ` Ela tinha pagado sinal de R$ ${(r.sinalPagoParaDevolver / 100).toFixed(2).replace('.', ',')}: lembre ele de devolver.`
                    : '');
              } else if (r?.reason === 'CHOCA_COM_OUTRA_CLIENTE') {
                texto =
                  'NÃO mudei: nesse novo horário a mesma profissional já tem outra cliente. Conte a ele e pergunte o que prefere (outro horário, ou VOLTAR como era).';
              } else {
                texto = `NÃO fiz: ${r?.reason ?? 'motivo desconhecido'}. Não diga que fez.`;
              }
            } catch (erro) {
              texto = `Não deu agora (${String(erro).slice(0, 120)}). Não diga que fez.`;
            }
          } else if (chamada.name === 'definir_modo_da_equipe') {
            const a = chamada.input as {
              umSo: boolean;
              frente?: string;
              mostrarQuemFazNoGoogle?: boolean;
            };
            try {
              const r = (await rpc(supabaseUrl, serviceKey, 'eddy_definir_modo_da_equipe', {
                p_tenant_id: tenantId,
                p_um_so: a.umSo === true,
                p_frente: a.frente ?? null,
                p_mostrar_quem_faz:
                  typeof a.mostrarQuemFazNoGoogle === 'boolean' ? a.mostrarQuemFazNoGoogle : null,
              })) as {
                ok?: boolean;
                reason?: string;
                frente?: string;
                equipe?: string[];
                googleMostraQuemFaz?: boolean;
                agendamentosReescritos?: number;
              } | null;
              if (r?.ok) {
                anotadas++;
                texto = a.umSo
                  ? `Gravado e JÁ VALE (isto não passa por publicar: não ofereça publicar por causa disto): para a cliente é tudo com ${r.frente}. A atendente oferece o horário de quem estiver livre, sempre como "com ${r.frente}". ` +
                    (typeof a.mostrarQuemFazNoGoogle === 'boolean'
                      ? r.googleMostraQuemFaz
                        ? 'No Google aparece quem faz de verdade.'
                        : `No Google fica tudo no nome de ${r.frente}.`
                      : 'Falta perguntar se no Google ele quer ver quem faz ou tudo no nome dele.') +
                    (r.agendamentosReescritos
                      ? ` Os ${r.agendamentosReescritos} horários já marcados foram atualizados no Google.`
                      : '')
                  : 'Gravado e JÁ VALE (isto não passa por publicar: não ofereça publicar por causa disto): profissionais separados. A atendente diz com quem é cada horário e respeita quando a cliente pede alguém.';
              } else if (r?.reason === 'FRENTE_NAO_ESTA_NA_EQUIPE') {
                texto = `NAO gravei: esse nome não está na equipe (${(r.equipe ?? []).join(', ')}). Pergunte quem é.`;
              } else {
                texto = `NAO gravei: ${r?.reason ?? 'motivo desconhecido'}. Não diga que anotou.`;
              }
            } catch (erro) {
              texto = `Nao deu para gravar agora (${String(erro).slice(0, 120)}). Não diga que anotou.`;
            }
          } else if (chamada.name === 'definir_titulo_na_agenda') {
            const a = chamada.input as { modelo: string; caixaAlta: boolean };
            try {
              const r = (await rpc(supabaseUrl, serviceKey, 'eddy_definir_titulo_agenda', {
                p_tenant_id: tenantId,
                p_modelo: a.modelo,
                p_caixa_alta: a.caixaAlta === true,
              })) as {
                ok?: boolean;
                reason?: string;
                comSinal?: string;
                semSinal?: string;
                agendamentosReescritos?: number;
              } | null;
              if (r?.ok) {
                anotadas++;
                texto =
                  `Gravado e JÁ VALE (isto não passa por publicar: não ofereça publicar por causa disto). Mostre a ele exatamente assim: com sinal pago "${r.comSinal}"; sem sinal "${r.semSinal}".` +
                  (r.agendamentosReescritos
                    ? ` Os ${r.agendamentosReescritos} agendamento(s) já marcados vão ser reescritos no Google nesse formato.`
                    : '');
              } else if (r?.reason === 'LACUNA_DESCONHECIDA') {
                texto =
                  'NAO gravei: use só {nome} {telefone} {servico} {valor} {pagamento} {profissional}.';
              } else {
                texto = `NAO gravei: ${r?.reason ?? 'motivo desconhecido'}. Não diga que anotou.`;
              }
            } catch (erro) {
              texto = `Nao deu para gravar agora (${String(erro).slice(0, 120)}). Não diga que anotou.`;
            }
          } else if (chamada.name === 'conectar_agenda') {
            const a = chamada.input as { profissional?: string };
            try {
              const r = (await rpc(supabaseUrl, serviceKey, 'eddy_conectar_agenda', {
                p_tenant_id: tenantId,
                p_profissional: a.profissional ?? null,
              })) as {
                ok?: boolean;
                reason?: string;
                codigo?: string;
                agendaDe?: string;
                ehDoDono?: boolean;
                jaConectadas?: unknown[];
                equipe?: string[];
                procurado?: string;
              } | null;
              if (r?.ok && r.codigo) {
                linkDaAgenda = `${supabaseUrl}/functions/v1/google-agenda-conectar?c=${r.codigo}`;
                texto =
                  `Link gerado para a agenda de ${r.ehDoDono ? 'dele' : r.agendaDe}. Ele sai sozinho num balao logo depois dos seus; NAO escreva link. ` +
                  `Ja conectadas: ${JSON.stringify(r.jaConectadas ?? [])} (se a mesma pessoa ja estava funcionando, diga que o link troca a conexao antiga). ` +
                  'Explique curto: abrir o link, entrar na conta Google onde esta a agenda, permitir. Vale 24h, uma vez so. ' +
                  'Depois de conectar: a cada 15 minutos o sistema le a agenda; compromisso marcado la fecha o horario para as clientes, e evento com "trabalha" + o nome de alguem da equipe vira dia de trabalho dessa pessoa.';
                anotadas++;
              } else if (r?.reason === 'PROFISSIONAL_NAO_ESTA_NA_EQUIPE') {
                texto = `"${r.procurado}" nao esta na equipe (${(r.equipe ?? []).join(', ')}). Pergunte de quem e a agenda. Nenhum link foi gerado.`;
              } else {
                texto = `NAO gerei o link: ${r?.reason ?? 'motivo desconhecido'}. Nao diga que mandou.`;
              }
            } catch (erro) {
              texto = `Nao deu para gerar o link agora (${String(erro).slice(0, 120)}). Nao diga que mandou.`;
            }
          } else if (chamada.name === 'responder_cor') {
            const args = chamada.input as { chave: string; valor: number };
            try {
              const r = (await rpc(supabaseUrl, serviceKey, 'eddy_responder_cor', {
                p_tenant_id: tenantId,
                p_chave: args.chave,
                p_valor: args.valor,
                p_conversation_id: item.conversation_id,
              })) as { ok?: boolean; reason?: string; restantes?: number } | null;
              if (r?.ok) {
                anotadas += 1;
                texto = `Gravado: ${args.chave} = ${args.valor}. Faltam ${r.restantes ?? '?'} perguntas de cor.`;
              } else {
                texto = `NAO gravei ${args.chave}: ${r?.reason ?? 'motivo desconhecido'}. Nao diga que anotou.`;
              }
            } catch (erro) {
              texto = `Nao deu para gravar agora (${String(erro).slice(0, 120)}). Nao diga que anotou.`;
            }
          } else if (chamada.name === 'guardar_conhecimento') {
            // APRENDER E LIVRE, E ATE 24/09 SO ACONTECIA QUANDO ELE DESISTIA.
            //
            // O unico caminho para `conhecimento_nao_classificado` era o
            // HANDOFF. Tudo o que o dono ensinou e nao cabia numa ferramenta
            // fechada -- "nao corto curto", "essa foto e um iluminado" -- virou
            // "anotei" sem linha nenhuma no banco. Sem regua de confianca: isto
            // e fila de revisao, nao cadastro, e errar aqui nao chega a cliente.
            const args = chamada.input as {
              palavras: string;
              assunto?: string;
              escopo?: string;
              porqueNaoCoube?: string;
            };
            try {
              const r = (await rpc(supabaseUrl, serviceKey, 'registrar_conhecimento_solto', {
                p_tenant_id: tenantId,
                p_conversation_id: item.conversation_id,
                p_palavras: args.palavras ?? '',
                p_modulo: args.assunto && args.assunto !== 'OUTRO' ? args.assunto : null,
                p_escopo: escopoDoBanco(args.escopo),
                p_porque: args.porqueNaoCoube ?? '',
              })) as { ok?: boolean; reason?: string } | null;
              if (r?.ok) {
                aprendidas += 1;
                texto =
                  'Guardado com as palavras dele. Nenhuma cliente ve isto ainda: vira regra, servico ou preco quando for revisado.';
              } else if (r?.reason === 'PALAVRAS_VAZIAS') {
                texto = 'NAO guardei: veio vazio. Mande o que ele disse, com as palavras dele.';
              } else {
                texto = `NAO guardei: ${r?.reason ?? 'motivo desconhecido'}. Nao diga que anotou.`;
              }
            } catch (erro) {
              texto = `Nao deu para guardar agora (${String(erro).slice(0, 120)}). Nao diga que anotou.`;
            }
          } else if (chamada.name === 'resumo') {
            try {
              const r = (await rpc(supabaseUrl, serviceKey, 'onboarding_resumo_pela_conversa', {
                p_conversation_id: item.conversation_id,
              })) as Record<string, unknown> | null;
              viuOResumo = true;
              let muda: unknown = null;
              try {
                muda = await rpc(supabaseUrl, serviceKey, 'eddy_o_que_muda_ao_publicar', {
                  p_tenant_id: tenantId,
                });
              } catch {
                muda = null;
              }
              texto =
                'O QUE MUDA SE PUBLICAR (rascunho x o que esta no ar; e ISTO que voce conta a ele, item por item):\n' +
                JSON.stringify(muda) +
                '\n\nO rascunho inteiro, para consulta:\n' +
                JSON.stringify(r);
            } catch (erro) {
              texto = `Nao consegui ler o rascunho agora (${String(erro).slice(0, 120)}). Nao fale em publicar sem isso.`;
            }
          } else if (chamada.name === 'publicar') {
            const args = chamada.input as { confirmacaoDoDono: string };
            let travaDaPublicacao: string | null = null;
            if (!viuOResumo) {
              texto =
                'NAO publiquei: voce ainda nao chamou `resumo` nesta conversa. ' +
                'Chame o resumo, conte a ele o que mudou, espere ele confirmar, e so entao publique.';
            } else if (!args.confirmacaoDoDono || args.confirmacaoDoDono.trim().length < 2) {
              texto = 'NAO publiquei: faltou a confirmacao dele, com as palavras dele.';
            } else if (
              (travaDaPublicacao = await (async (): Promise<string | null> => {
                // 28/09/2026: "fioterapia 290, publica" levou junto o penteado
                // que ele tinha mudado antes e nao citou. Cada mudanca que vai
                // ao ar precisa ter sido dita agora -- pelo dono nesta mensagem
                // ou pelo Eddy na pergunta "publico?".
                try {
                  const itens = (await rpc(supabaseUrl, serviceKey, 'eddy_o_que_muda_ao_publicar', {
                    p_tenant_id: tenantId,
                  })) as Array<{ servico: string | null; mudanca: string }> | null;
                  const calados = (itens ?? []).filter((m) => {
                    if (m.servico) return !conversaDaPublicacao.includes(semAcento(m.servico));
                    if (/^hor/i.test(m.mudanca)) return !/horari/.test(conversaDaPublicacao);
                    return !/regra/.test(conversaDaPublicacao);
                  });
                  if (calados.length === 0) return null;
                  return (
                    'NAO publiquei: o rascunho tambem leva isto, que ele nao citou e voce nao contou: ' +
                    calados
                      .map((m) => `${m.servico ? m.servico + ': ' : ''}${m.mudanca}`)
                      .join('; ') +
                    '. Conte a ele TUDO o que vai ao ar (inclusive o que ele pediu agora) e pergunte se publica.'
                  );
                } catch {
                  return null;
                }
              })()) !== null
            ) {
              texto = travaDaPublicacao ?? '';
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
                  somenteRegras?: boolean;
                  regrasPublicadas?: number;
                  semEmail?: boolean;
                } | null;

                if (r?.ok && r.somenteRegras) {
                  publicacoes += 1;
                  texto =
                    `Publicado: ${r.regrasPublicadas ?? 0} regra(s) nova(s) da atendente ja valem para as clientes. ` +
                    'Diga isso a ele em uma linha.';
                } else if (r?.ok) {
                  publicacoes += 1;
                  // 24/09/2026: disse "a atendente ja responde" com ela
                  // desligada. Quem diz se ela esta no ar e o banco.
                  let ligada = false;
                  try {
                    ligada =
                      (await rpc(supabaseUrl, serviceKey, 'eddy_atendente_ligada', {
                        p_tenant_id: tenantId,
                      })) === true;
                  } catch {
                    ligada = false;
                  }
                  texto =
                    `Publicado. A configuracao no ar agora e a versao ${r.versao?.versionNumber ?? '?'}. ` +
                    (ligada
                      ? 'A atendente do salao esta LIGADA: ja responde as clientes com isso. Diga isso a ele em uma linha.'
                      : r.semEmail === true
                        ? // Dono so de WhatsApp: nao tem acesso ao app, entao
                          // "liga na tela Agente" seria mandar ele onde nao entra.
                          'A atendente do salao esta DESLIGADA: NAO diga que ela ja responde. Diga que esta publicado e que quem liga a atendente e a equipe da EDDigital. NAO fale de app nem de tela: ele nao tem acesso ao app. NAO prometa avisar quando ela for ligada: voce nao fica sabendo.'
                        : 'A atendente do salao esta DESLIGADA: NAO diga que ela ja responde. Diga que esta publicado e que ela comeca a atender quando for ligada na tela Agente do app (ou pela equipe da EDDigital). NAO prometa avisar quando ela for ligada: voce nao fica sabendo.');
                } else if (r?.reason === 'FALTA_COISA') {
                  const faltas = (r.pendencias ?? []).map((p) => `- ${p.oQueFalta}`).join('\n');
                  texto =
                    'NAO publiquei porque falta coisa. Leia isto para ele, do jeito que esta:\n' +
                    faltas;
                } else if (r?.reason === 'NADA_PARA_PUBLICAR') {
                  texto = 'NAO publiquei: nao ha nada mudado no rascunho. Diga isso a ele.';
                } else if (r?.reason === 'DONO_SEM_EMAIL') {
                  texto =
                    'NAO publiquei: o cadastro esta pronto, mas o numero dele ainda nao esta ligado ao ' +
                    'e-mail de acesso ao painel, e publicar exige isso. Responda com REPLY (NUNCA HANDOFF), ' +
                    'em uma linha: esta tudo pronto e a equipe da EDDigital libera o acesso dele e publica. ' +
                    'NAO diga que o numero nao e reconhecido: ele e.';
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

      // A trava da pergunta repetida, no codigo. So o aviso no prompt nao
      // segurou: no reteste de 28/09 ele leu "NAO REPITA" e repetiu, porque a
      // mesma pergunta vem tambem dentro do `negocio`. Se ela ja foi feita nas
      // duas ultimas rodadas e o dono falou de outra coisa, o balao que e a
      // pergunta do roteiro (mais da metade das palavras dela) nao sai.
      const palavras = (t: string) =>
        t
          .toLowerCase()
          .normalize('NFD')
          .replace(/[\u0300-\u036f]/g, '')
          .match(/[a-z]{4,}/g) ?? [];
      const daPergunta = new Set(
        jaPerguntouAgora && roteiro[0] ? palavras(roteiro[0].perguntaSugerida) : []
      );
      const repeteARoteiro = (t: string) => {
        if (daPergunta.size === 0 || !t.trim().endsWith('?')) return false;
        const p = palavras(t);
        return p.length > 0 && p.filter((w) => daPergunta.has(w)).length / p.length >= 0.5;
      };
      // Lembrete reescrito tambem nao sai: com a pergunta ja feita (ou adiada)
      // e o dono em outro assunto, balao curto que fala do assunto da etapa e
      // cobranca. A pergunta so volta quando ele puxar o assunto ou terminar.
      const lembraAEtapa = (t: string) =>
        jaPerguntouAgora && !!sinalDaEtapa && sinalDaEtapa.test(t) && t.length <= 240;
      // Uma pergunta por vez (ver uma-pergunta.ts): garantido no código. E
      // nunca termina sem próximo passo quando o cadastro tem pendência
      // (ver proximo-passo.ts).
      const levaDoDono = (() => {
        const hist = (contexto.history ?? []) as Array<{ direction?: string; text?: string }>;
        let i = hist.length - 1;
        while (i >= 0 && hist[i].direction === 'INBOUND') i--;
        return hist
          .slice(i + 1)
          .map((h) => h.text ?? '')
          .join(' . ');
      })();
      const umaSo = umaPerguntaPorVez(
        semRefrao(
          (decisao.messages ?? [])
            .map((t) => (typeof t === 'string' ? semEscapes(t).trim() : ''))
            .filter((t) => t.length > 0),
          (t) => repeteARoteiro(t) || lembraAEtapa(t)
        )
      );
      // O roteiro lido no começo do turno pode ter ficado velho: se ele acabou
      // de responder a pendência, ela não volta. Relê do banco só quando a
      // resposta ficou sem pergunta.
      let proximaDoRoteiro = '';
      let subPerguntas: string[] = [];
      if (
        decisao.action === 'REPLY' &&
        !adiado &&
        !sinalEmAndamento &&
        roteiro.length > 0 &&
        !umaSo.some((t) => temPergunta(t))
      ) {
        try {
          const agora = (await rpc(supabaseUrl, serviceKey, 'build_owner_context', {
            p_conversation_id: item.conversation_id,
            p_history_limit: 1,
          })) as {
            negocio?: {
              falta?: Array<{
                perguntaSugerida?: string;
                perguntasDeCor?: Array<{
                  chave?: string;
                  unidade?: string;
                  sugestao?: number;
                  pergunta?: string;
                }>;
              }>;
            };
          } | null;
          proximaDoRoteiro = agora?.negocio?.falta?.[0]?.perguntaSugerida ?? '';
          const padrao = padraoDaCor(agora?.negocio?.falta?.[0]?.perguntasDeCor ?? []);
          subPerguntas = padrao ? [padrao] : [];
        } catch {
          proximaDoRoteiro = '';
        }
      }
      const textos = comProximoPasso(umaSo, {
        proxima: proximaDoRoteiro,
        alternativas: subPerguntas,
        jaFeitas: ((contexto.history ?? []) as Array<{ direction?: string; text?: string }>)
          .filter((h) => h.direction === 'OUTBOUND')
          .map((h) => h.text ?? ''),
        leva: levaDoDono,
        bloqueado: adiado || sinalEmAndamento,
      })
        // No maximo 3 baloes, mas sem perder nada: 28/09, caso E14, o 4o
        // balao (os servicos que so a tabela tinha) era cortado calado.
        .reduce<string[]>((acc, t) => {
          if (acc.length < 3) acc.push(t);
          else acc[2] = `${acc[2]}\n\n${t}`;
          return acc;
        }, [])
        .map((t) => t.replace(/\s*—\s*/g, ' - ').replace(/\s*–\s*/g, ' - '));

      let acao = decisao.action;
      if (camposCorrompidos(decisao).includes('messages')) acao = 'HANDOFF';
      if (acao === 'REPLY' && textos.length === 0) acao = 'HANDOFF';

      if (dryRun) {
        resultados.push({
          conversationId: item.conversation_id,
          action: acao,
          messages: textos,
          uso,
          dryRun: true,
        });
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
      // O link vai logo depois do balao que fala dele: 29/09, ele saiu depois
      // de um recado sobre outro assunto e o dono leria fora de ordem.
      const comLink = (lista: string[], link: string): string[] => {
        const limpos = lista
          .map((t) => t.replace(/https?:\/\/\S+/g, '').trim())
          .filter((t) => t.length > 0);
        const onde = limpos.findIndex((t) => /\blink\b/i.test(t));
        const pos = onde === -1 ? limpos.length : onde + 1;
        return [...limpos.slice(0, pos), link, ...limpos.slice(pos)];
      };
      const saidas =
        acao === 'REPLY'
          ? linkDaAgenda
            ? comLink(textos, linkDaAgenda)
            : textos
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
            // 23/09/2026: estes dois iam `null` fixo desde que a tabela
            // nasceu. Guardar a frase do dono sem dizer de que assunto e
            // empurra para uma pessoa a leitura que o modelo ja fez.
            // 'OUTRO'/'INDEFINIDO' viram null: palpite vazio e ausencia de
            // palpite, nao um palpite chamado "outro".
            p_modulo:
              decisao.palpiteModulo && decisao.palpiteModulo !== 'OUTRO'
                ? decisao.palpiteModulo
                : null,
            p_escopo: escopoDoBanco(decisao.palpiteEscopo),
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

      resultados.push({
        conversationId: item.conversation_id,
        action: acao,
        messages: saidas,
        uso,
      });
    } catch (erro) {
      falhas++;
      const detalhe = String(erro);
      console.error(
        JSON.stringify({
          event: 'eddy_turn_failed',
          conversationId: item.conversation_id,
          erro: detalhe,
        })
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
      resultados.push({
        conversationId: item.conversation_id,
        action: 'ERROR',
        detail: detalhe.slice(0, 300),
      });
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
      aprendidas,
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
    aprendidas,
    criados,
    publicacoes,
    falhas,
    dryRun,
    resultados,
  });
});
