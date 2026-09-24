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
      'Grava o tempo de espera do produto num serviço. Durante a pausa a cliente fica e a profissional sai — é o que permite encaixar outra cliente no meio. Pergunte SEMPRE as duas coisas: quantos minutos, e se a pausa está dentro do tempo total ou soma a mais.',
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
        confianca: { type: 'number', description: 'Mesma régua do `anotar`.' },
      },
      required: ['servico', 'minutos', 'dentroDoTotal', 'confianca'],
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
        servicoId: { type: 'string', description: 'O id do serviço, como veio na pendência.' },
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
    name: 'desativar_servico',
    description:
      'Tira do catálogo um serviço que o salão não faz. Só depois de ele confirmar. O serviço não é apagado, fica inativo.',
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
            'true se ele PEDIU lembrete de véspera. Ainda não está disponível — grave o pedido e diga a ele que você avisa quando liberar, sem prometer data.',
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
    name: 'arquivar_fotos',
    description:
      'Grava fotos que ele mandou no lugar certo da régua do salão, para a atendente reconhecer isso na foto da cliente. Use depois que ele disser o que as fotos são ("essas são ruivo", "isso é um pixie"). Várias fotos seguidas antes da legenda são um lote: mande todos os ids juntos. Se a leitura da foto deixou dúvida entre tom e corte, pergunte a ele antes. Só diga que guardou depois de receber "Arquivei".',
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
      'Grava uma regra que muda como a atendente fala com as clientes: o que o salão NÃO faz ("não faço pixie"), uma condição ("luzes só com teste de mecha"), um jeito de falar. Escreva a regra como instrução clara para a atendente e mande as palavras dele junto. Entra em rascunho: só vale para cliente depois que ele publicar.',
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
  let criados = 0;
  let aprendidas = 0;
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
        resultados.push({
          conversationId: item.conversation_id,
          action: 'HANDOFF',
          motivo: 'DONO_DESCONHECIDO',
        });
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
          familiasDeTom?: { nome: string; fotos: number }[];
          regua?: { dimensao: string; opcoes: string[] }[];
        };
        if ((ctxFotos.fotosSemDestino ?? []).length > 0) {
          const familias = (ctxFotos.familiasDeTom ?? [])
            .map((f) => `${f.nome} (${f.fotos} foto${f.fotos === 1 ? '' : 's'})`)
            .join(', ');
          const regua = (ctxFotos.regua ?? [])
            .map((d) => `- ${d.dimensao}: ${d.opcoes.join(', ')}`)
            .join('\n');
          fotosERegua =
            '\n\nFOTOS QUE ELE MANDOU E AINDA NÃO TÊM LUGAR (use o id em `arquivar_fotos`; várias seguidas antes de uma legenda costumam ser um lote só):\n' +
            JSON.stringify(ctxFotos.fotosSemDestino) +
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

      const mensagens: Anthropic.MessageParam[] = [
        {
          role: 'user',
          content:
            'Esta conversa com o dono (JSON). A última mensagem do histórico é a que está esperando resposta.\n\n' +
            JSON.stringify({
              dono: contexto.dono,
              negocio: contexto.negocio,
              history: contexto.history,
            }) +
            '\n\nO QUE AINDA FALTA NO CADASTRO DELE (a chave entre colchetes é obrigatória em `anotar`, e você nunca inventa uma):\n' +
            (pauta || '(nada — o cadastro está completo)') +
            '\n\nAS HABILIDADES QUE ESTE SALÃO TEM (é desta lista que você escolhe em `criar_servico`, escrita exatamente assim; você nunca inventa uma):\n' +
            (listaHabilidades ||
              '(nenhuma habilidade com gente ativa — não dá para criar serviço agora)') +
            fotosERegua,
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
          } else if (chamada.name === 'definir_pausa') {
            const args = chamada.input as {
              servico: string;
              minutos: number;
              dentroDoTotal: boolean;
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
                })) as {
                  ok?: boolean;
                  reason?: string;
                  servico?: string;
                  pausaMinutos?: number;
                  atendimentoMinutos?: number;
                  totalMinutos?: number;
                  comoResolver?: string;
                  totalAtual?: number;
                } | null;

                if (r?.ok) {
                  criados += 1;
                  texto =
                    `Gravei a pausa de ${r.pausaMinutos} min em "${r.servico}": ` +
                    `${r.atendimentoMinutos} min de atendimento + ${r.pausaMinutos} de pausa, ` +
                    `total ${r.totalMinutos} min. Durante a pausa a profissional fica livre para outra cliente.`;
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
                  texto =
                    `Gravei: o agente vai ${partes.join(', ')}. ` +
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
                    p_data: args.data,
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
                  somenteRegras?: boolean;
                  regrasPublicadas?: number;
                } | null;

                if (r?.ok && r.somenteRegras) {
                  publicacoes += 1;
                  texto =
                    `Publicado: ${r.regrasPublicadas ?? 0} regra(s) nova(s) da atendente ja valem para as clientes. ` +
                    'Diga isso a ele em uma linha.';
                } else if (r?.ok) {
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
        .map((t) => (typeof t === 'string' ? semEscapes(t).trim() : ''))
        .filter((t) => t.length > 0)
        .slice(0, 3)
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
