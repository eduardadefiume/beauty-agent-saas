// LER O msgstore.db
//
// Aberto o backup, o que sobra é um SQLite com o esquema do WhatsApp. Ele mudou
// de forma no meio do caminho, e os dois formatos existem no mundo real:
//
//   antigo:  uma tabela `messages`, com o telefone escrito em cada linha
//   atual:   `message` + `chat` + `jid`, com o telefone normalizado à parte
//
// O dono pode ter trocado de celular no meio dos dois anos de histórico, e o
// backup que ele tem à mão pode ser de qualquer um dos dois. Ler só o atual
// funcionaria no meu teste e falharia calado no aparelho dele.
//
// O que sai daqui é a mesma forma que o resto da etapa 6 já usa: conversa com
// falas, cada fala sabendo se foi o dono ou a cliente. Assim o arquivo do
// backup, o .txt exportado e o histórico da Meta acabam no mesmo lugar.

export type FalaDoBackup = {
  posicao: number;
  quem: 'DONO' | 'CLIENTE';
  texto: string | null;
  enviadaEm: string | null;
  midia: string | null;
};

export type ConversaDoBackup = {
  chaveExterna: string;
  nome: string;
  telefone: string | null;
  ehGrupo: boolean;
  falas: FalaDoBackup[];
};

// O contrato do sql.js, só a parte usada. Tipar contra isto deixa a extração
// testável sem carregar o wasm.
export type BancoLido = {
  exec: (sql: string) => Array<{ columns: string[]; values: unknown[][] }>;
};

function temTabela(banco: BancoLido, nome: string): boolean {
  const r = banco.exec(`select 1 from sqlite_master where type='table' and name='${nome}' limit 1`);
  return r.length > 0 && (r[0]?.values.length ?? 0) > 0;
}

function linhas(banco: BancoLido, sql: string): Array<Record<string, string | number | null>> {
  const resultado = banco.exec(sql);
  const bloco = resultado[0];
  if (!bloco) return [];
  return bloco.values.map((valores) => {
    const linha: Record<string, string | number | null> = {};
    bloco.columns.forEach((coluna, i) => {
      const v = valores[i];
      linha[coluna] = v == null ? null : (v as string | number);
    });
    return linha;
  });
}

// O WhatsApp grava em milissegundos; alguns backups antigos, em segundos. Um
// número de 10 dígitos é segundo, de 13 é milissegundo — e uma data de 1970 na
// ficha da cliente seria erro visível só muito depois.
function quando(valor: string | number | null): string | null {
  if (valor == null) return null;
  const n = typeof valor === 'number' ? valor : Number(valor);
  if (!Number.isFinite(n) || n <= 0) return null;
  const ms = n < 100_000_000_000 ? n * 1000 : n;
  const data = new Date(ms);
  return Number.isNaN(data.getTime()) ? null : data.toISOString();
}

function digitos(jid: string): string | null {
  const so = jid.split('@')[0]?.replace(/[^0-9]/g, '') ?? '';
  return so.length >= 8 ? so : null;
}

function ehGrupo(jid: string): boolean {
  return jid.includes('@g.us') || jid.includes('@broadcast');
}

// Mensagem de sistema ("as mensagens são criptografadas", "fulano entrou"), e
// mensagem apagada, não são voz de ninguém. Entram como nada e só sujariam a
// leitura do padrão de atendimento.
function valeGuardar(texto: string | null, midia: string | null): boolean {
  return (texto != null && texto.trim() !== '') || midia != null;
}

const TIPOS_DE_SISTEMA = new Set([7, 8, 10, 11, 15, 19]);

function montar(
  chave: string,
  nome: string | null,
  mensagens: Array<{
    doDono: boolean;
    texto: string | null;
    quando: string | null;
    midia: string | null;
    tipo: number | null;
  }>
): ConversaDoBackup | null {
  const falas: FalaDoBackup[] = [];

  for (const m of mensagens) {
    if (m.tipo != null && TIPOS_DE_SISTEMA.has(m.tipo)) continue;
    const texto = m.texto == null || m.texto.trim() === '' ? null : m.texto;
    if (!valeGuardar(texto, m.midia)) continue;
    falas.push({
      posicao: falas.length,
      quem: m.doDono ? 'DONO' : 'CLIENTE',
      texto,
      enviadaEm: m.quando,
      midia: m.midia,
    });
  }

  if (falas.length === 0) return null;

  const grupo = ehGrupo(chave);
  return {
    chaveExterna: chave,
    nome: nome && nome.trim() !== '' ? nome : (digitos(chave) ?? chave),
    // Grupo não tem telefone de cliente. Deixar o id do grupo aqui faria a
    // conversa ser amarrada na cliente errada mais tarde.
    telefone: grupo ? null : digitos(chave),
    ehGrupo: grupo,
    falas,
  };
}

function lerEsquemaAtual(banco: BancoLido): ConversaDoBackup[] {
  const midiaPorMensagem = new Map<number, string>();
  if (temTabela(banco, 'message_media')) {
    for (const l of linhas(
      banco,
      'select message_row_id, file_path from message_media where file_path is not null'
    )) {
      midiaPorMensagem.set(Number(l.message_row_id), String(l.file_path));
    }
  }

  const temAssunto = banco
    .exec('pragma table_info(chat)')[0]
    ?.values.some((v) => v[1] === 'subject');

  const registros = linhas(
    banco,
    `select m._id as id, j.raw_string as jid, ${temAssunto ? 'c.subject' : 'null'} as assunto,
            m.from_me as do_dono, m.text_data as texto, m.timestamp as quando,
            m.message_type as tipo
       from message m
       join chat c on c._id = m.chat_row_id
       join jid  j on j._id = c.jid_row_id
      order by m.chat_row_id, m.timestamp, m._id`
  );

  const porConversa = new Map<
    string,
    { assunto: string | null; itens: Parameters<typeof montar>[2] }
  >();

  for (const l of registros) {
    const jid = String(l.jid ?? '');
    if (jid === '') continue;
    let alvo = porConversa.get(jid);
    if (!alvo) {
      alvo = { assunto: l.assunto == null ? null : String(l.assunto), itens: [] };
      porConversa.set(jid, alvo);
    }
    alvo.itens.push({
      doDono: Number(l.do_dono) === 1,
      texto: l.texto == null ? null : String(l.texto),
      quando: quando(l.quando ?? null),
      midia: midiaPorMensagem.get(Number(l.id)) ?? null,
      tipo: l.tipo == null ? null : Number(l.tipo),
    });
  }

  const saida: ConversaDoBackup[] = [];
  for (const [jid, { assunto, itens }] of porConversa) {
    const conversa = montar(jid, assunto, itens);
    if (conversa) saida.push(conversa);
  }
  return saida;
}

function lerEsquemaAntigo(banco: BancoLido): ConversaDoBackup[] {
  const colunas = new Set(
    banco.exec('pragma table_info(messages)')[0]?.values.map((v) => String(v[1])) ?? []
  );
  const colunaDeMidia = colunas.has('media_name')
    ? 'media_name'
    : colunas.has('media_caption')
      ? 'media_caption'
      : 'null';
  const colunaDeTipo = colunas.has('media_wa_type') ? 'media_wa_type' : 'null';

  const registros = linhas(
    banco,
    `select key_remote_jid as jid, key_from_me as do_dono, data as texto,
            timestamp as quando, ${colunaDeMidia} as midia, ${colunaDeTipo} as tipo
       from messages
      order by key_remote_jid, timestamp, _id`
  );

  const porConversa = new Map<string, Parameters<typeof montar>[2]>();
  for (const l of registros) {
    const jid = String(l.jid ?? '');
    if (jid === '') continue;
    const itens = porConversa.get(jid) ?? [];
    itens.push({
      doDono: Number(l.do_dono) === 1,
      texto: l.texto == null ? null : String(l.texto),
      quando: quando(l.quando ?? null),
      midia: l.midia == null ? null : String(l.midia),
      // No esquema antigo `media_wa_type` 0 é texto; os avisos de sistema não
      // usam a mesma numeração do esquema atual, então aqui o tipo não filtra.
      tipo: null,
    });
    porConversa.set(jid, itens);
  }

  const saida: ConversaDoBackup[] = [];
  for (const [jid, itens] of porConversa) {
    const conversa = montar(jid, null, itens);
    if (conversa) saida.push(conversa);
  }
  return saida;
}

export class MsgstoreDesconhecido extends Error {
  constructor() {
    super(
      'Este banco não tem as tabelas de mensagem do WhatsApp. Confira se o arquivo é o msgstore.db.crypt15 e não outro backup (o wa.db, por exemplo, guarda só os contatos).'
    );
    this.name = 'MsgstoreDesconhecido';
  }
}

export function extrairConversas(banco: BancoLido): ConversaDoBackup[] {
  if (temTabela(banco, 'message') && temTabela(banco, 'chat') && temTabela(banco, 'jid')) {
    return lerEsquemaAtual(banco);
  }
  if (temTabela(banco, 'messages')) {
    return lerEsquemaAntigo(banco);
  }
  throw new MsgstoreDesconhecido();
}
