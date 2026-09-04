// ABRIR O BACKUP DO WHATSAPP DO DONO
//
// O `msgstore.db.crypt15` é o backup local que o WhatsApp grava no aparelho, em
// `Android/media/com.whatsapp/WhatsApp/Databases/`. Desde o Android 11 essa
// pasta é alcançável sem root: dá para pegar o arquivo pelo cabo, pelo
// gerenciador de arquivos ou pelo seletor do próprio navegador.
//
// Ele é cifrado com a chave de 64 dígitos que o WhatsApp mostra ao dono em
// Ajustes › Conversas › Backup › Backup criptografado. Essa chave é dele, e é a
// única coisa que abre o arquivo.
//
// POR QUE ISSO RODA NO NAVEGADOR, E NÃO NO SERVIDOR
//
// Porque mandar a chave de 64 dígitos para o servidor seria entregar ao SaaS o
// que abre TODO backup do WhatsApp daquele salão — não só este arquivo, e não só
// o que ele decidiu importar. O ganho de produto seria zero: as mensagens
// extraídas vão para o servidor de qualquer jeito. O risco é que seria enorme.
// Então o arquivo cifrado e a chave não saem do computador dele; só as
// mensagens já lidas viajam.
//
// O FORMATO
//
//   varint(tamanho do cabeçalho) ‖ cabeçalho ‖ cifrado ‖ tag(16) ‖ md5(16)
//
// O cabeçalho é um protobuf `BackupPrefix`; o IV de 16 bytes mora no campo 3
// (`e2ee_key_data`), campo 1 (`encryption_iv`). O conteúdo é AES-256-GCM e, uma
// vez aberto, ainda está comprimido em zlib — só depois disso aparece o SQLite.
//
// Backup em vários arquivos não tem o md5 no fim, e aí a tag são os últimos 16
// bytes. Em vez de adivinhar qual dos dois é pelo md5, aqui se tenta a forma
// comum e, se a tag não conferir, a outra. É a própria verificação do GCM que
// decide — chave errada falha nas duas, e falha dizendo isso.

const INFO_DA_CHAVE = 'backup encryption';

export class BackupIlegivel extends Error {
  readonly motivo: 'CHAVE_INVALIDA' | 'NAO_E_CRYPT15' | 'CHAVE_NAO_ABRE' | 'NAO_E_SQLITE';

  constructor(motivo: BackupIlegivel['motivo'], mensagem: string) {
    super(mensagem);
    this.name = 'BackupIlegivel';
    this.motivo = motivo;
  }
}

// A chave que o dono copia da tela do WhatsApp costuma vir com espaços, quebras
// de linha, e às vezes em maiúsculas. Nada disso é erro dele.
export function chaveDeTexto(texto: string): Uint8Array {
  const limpo = texto.replace(/[^0-9a-fA-F]/g, '').toLowerCase();
  if (limpo.length !== 64) {
    throw new BackupIlegivel(
      'CHAVE_INVALIDA',
      `A chave do backup tem 64 dígitos. Essa tem ${limpo.length}.`
    );
  }
  const bytes = new Uint8Array(32);
  for (let i = 0; i < 32; i += 1) bytes[i] = Number.parseInt(limpo.slice(i * 2, i * 2 + 2), 16);
  return bytes;
}

// A chave de 64 dígitos não cifra nada diretamente: ela é a raiz. A chave que
// abre o backup sai dela por HKDF-SHA256 com sal de 32 zeros e o rótulo
// "backup encryption" — o mesmo caminho que o WhatsApp usa para derivar também
// as chaves de metadados, que aqui não interessam.
export async function derivarChaveDoBackup(raiz: Uint8Array): Promise<CryptoKey> {
  const material = await crypto.subtle.importKey('raw', bufferDe(raiz), 'HKDF', false, [
    'deriveBits',
  ]);
  const bits = await crypto.subtle.deriveBits(
    {
      name: 'HKDF',
      hash: 'SHA-256',
      salt: new Uint8Array(32).buffer,
      info: new TextEncoder().encode(INFO_DA_CHAVE),
    },
    material,
    256
  );
  return crypto.subtle.importKey('raw', bits, 'AES-GCM', false, ['decrypt']);
}

export type Cabecalho = { iv: Uint8Array; inicioDosDados: number };

// Um leitor de protobuf do tamanho do problema: só precisa descer dois campos
// para achar o IV. Trazer uma biblioteca inteira para isso seria peso sem uso.
function acharCampo(bytes: Uint8Array, ate: number, campo: number, de = 0): Uint8Array | null {
  let i = de;
  while (i < ate) {
    let etiqueta = 0;
    let deslocamento = 0;
    for (;;) {
      if (i >= ate) return null;
      const b = bytes[i] as number;
      i += 1;
      etiqueta |= (b & 0x7f) << deslocamento;
      if ((b & 0x80) === 0) break;
      deslocamento += 7;
      if (deslocamento > 28) return null;
    }
    const numero = etiqueta >>> 3;
    const tipo = etiqueta & 0x07;

    if (tipo === 2) {
      let tamanho = 0;
      let d = 0;
      for (;;) {
        if (i >= ate) return null;
        const b = bytes[i] as number;
        i += 1;
        tamanho |= (b & 0x7f) << d;
        if ((b & 0x80) === 0) break;
        d += 7;
        if (d > 28) return null;
      }
      if (i + tamanho > ate) return null;
      if (numero === campo) return bytes.subarray(i, i + tamanho);
      i += tamanho;
    } else if (tipo === 0) {
      while (i < ate && ((bytes[i] as number) & 0x80) !== 0) i += 1;
      i += 1;
    } else if (tipo === 5) {
      i += 4;
    } else if (tipo === 1) {
      i += 8;
    } else {
      return null;
    }
  }
  return null;
}

export function lerCabecalho(arquivo: Uint8Array): Cabecalho {
  let tamanho = 0;
  let i = 0;
  let deslocamento = 0;
  for (;;) {
    if (i >= arquivo.length || deslocamento > 28) {
      throw new BackupIlegivel('NAO_E_CRYPT15', 'O arquivo acabou antes do cabeçalho terminar.');
    }
    const b = arquivo[i] as number;
    i += 1;
    tamanho |= (b & 0x7f) << deslocamento;
    if ((b & 0x80) === 0) break;
    deslocamento += 7;
  }

  const fim = i + tamanho;
  if (tamanho <= 0 || fim > arquivo.length) {
    throw new BackupIlegivel(
      'NAO_E_CRYPT15',
      'Isto não parece um msgstore.db.crypt15 — o cabeçalho não bate.'
    );
  }

  const e2ee = acharCampo(arquivo, fim, 3, i);
  const iv = e2ee ? acharCampo(e2ee, e2ee.length, 1) : null;

  if (!iv || iv.length !== 16) {
    throw new BackupIlegivel(
      'NAO_E_CRYPT15',
      iv
        ? 'O arquivo tem cabeçalho de crypt15 mas o IV não tem 16 bytes.'
        : 'Não achei o IV no cabeçalho. Se este arquivo é .crypt14 ou .crypt12, ele é de uma versão antiga do WhatsApp e este caminho não abre.'
    );
  }

  return { iv: new Uint8Array(iv), inicioDosDados: fim };
}

async function inflar(comprimido: ArrayBuffer): Promise<Uint8Array> {
  const fluxo = new Blob([comprimido]).stream().pipeThrough(new DecompressionStream('deflate'));
  const pedacos: Uint8Array[] = [];
  let total = 0;
  const leitor = fluxo.getReader();
  for (;;) {
    const { done, value } = await leitor.read();
    if (done) break;
    pedacos.push(value as Uint8Array);
    total += (value as Uint8Array).length;
  }
  const saida = new Uint8Array(total);
  let em = 0;
  for (const p of pedacos) {
    saida.set(p, em);
    em += p.length;
  }
  return saida;
}

const ASSINATURA_SQLITE = 'SQLite format 3';

// Devolve o msgstore.db já aberto e descomprimido, pronto para ser lido como
// SQLite. Erra com um motivo que dá para mostrar na tela: "a chave não abre" e
// "isto não é um crypt15" são problemas diferentes, e o dono precisa saber qual
// dos dois é o dele.
export async function abrirBackup(arquivo: Uint8Array, chaveRaiz: Uint8Array): Promise<Uint8Array> {
  const { iv, inicioDosDados } = lerCabecalho(arquivo);
  const chave = await derivarChaveDoBackup(chaveRaiz);
  const nonce = bufferDe(iv);
  const corpo = arquivo.subarray(inicioDosDados);

  if (corpo.length < 32) {
    throw new BackupIlegivel('NAO_E_CRYPT15', 'O arquivo é curto demais para ter conteúdo.');
  }

  // A forma comum primeiro: ...cifrado ‖ tag ‖ md5. Depois a de backup em
  // vários arquivos, que não tem o md5.
  const tentativas = [corpo.subarray(0, corpo.length - 16), corpo];
  let aberto: ArrayBuffer | null = null;

  for (const tentativa of tentativas) {
    try {
      aberto = await crypto.subtle.decrypt(
        { name: 'AES-GCM', iv: nonce },
        chave,
        bufferDe(tentativa)
      );
      break;
    } catch {
      aberto = null;
    }
  }

  if (!aberto) {
    throw new BackupIlegivel(
      'CHAVE_NAO_ABRE',
      'A chave não abre este arquivo. Confira se ela é a do mesmo aparelho e se o backup terminou de ser gravado.'
    );
  }

  const conteudo = await inflar(aberto);
  const assinatura = new TextDecoder('ascii', { fatal: false }).decode(
    conteudo.subarray(0, ASSINATURA_SQLITE.length)
  );

  if (assinatura !== ASSINATURA_SQLITE) {
    throw new BackupIlegivel(
      'NAO_E_SQLITE',
      'O arquivo abriu, mas o que saiu não é o banco de mensagens. Confira se é mesmo o msgstore.db.crypt15 e não outro backup do WhatsApp.'
    );
  }

  return conteudo;
}

function bufferDe(bytes: Uint8Array): ArrayBuffer {
  return bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength) as ArrayBuffer;
}
