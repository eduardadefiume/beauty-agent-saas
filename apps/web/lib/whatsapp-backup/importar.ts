// O CAMINHO INTEIRO, DO ARQUIVO ATÉ O SALÃO
//
// Junta as três partes que existem separadas de propósito (abrir, ler, mandar)
// e coloca cada uma atrás de um passo com nome, porque o dono precisa saber
// onde parou quando parar. "Deu erro" no meio de um arquivo de 300 MB não
// ajuda ninguém.

import { abrirBackup, chaveDeTexto } from './crypt15';
import { type Andamento, type ConversaParaEnviar, enviarConversas } from './enviar';
import { type BancoLido, type ConversaDoBackup, extrairConversas } from './msgstore';

export type Passo = 'ABRINDO' | 'LENDO' | 'MANDANDO' | 'PRONTO';

export type EstadoDaImportacao = {
  passo: Passo;
  andamento: Andamento | null;
  conversas: number;
  mensagens: number;
};

async function carregarSqlite(): Promise<(bytes: Uint8Array) => BancoLido> {
  const initSqlJs = (await import('sql.js')).default;
  try {
    const SQL = await initSqlJs({ locateFile: () => '/sql-wasm.wasm' });
    return (bytes) => new SQL.Database(bytes) as unknown as BancoLido;
  } catch (e) {
    // O wasm é copiado de node_modules no build. Se faltar, o erro nativo fala
    // de WebAssembly e não diz nada a quem está tentando importar um backup.
    throw new Error(
      `O leitor de banco não carregou neste navegador (${e instanceof Error ? e.message : 'erro desconhecido'}). O arquivo continua intacto no seu computador — nada foi perdido.`
    );
  }
}

export async function importarBackup(
  arquivo: Uint8Array,
  chaveDigitada: string,
  enviarLote: (lote: ConversaParaEnviar[]) => Promise<void>,
  aoAndar: (estado: EstadoDaImportacao) => void
): Promise<EstadoDaImportacao> {
  const chave = chaveDeTexto(chaveDigitada);

  aoAndar({ passo: 'ABRINDO', andamento: null, conversas: 0, mensagens: 0 });
  const sqlite = await abrirBackup(arquivo, chave);

  aoAndar({ passo: 'LENDO', andamento: null, conversas: 0, mensagens: 0 });
  const abrir = await carregarSqlite();
  const conversas: ConversaDoBackup[] = extrairConversas(abrir(sqlite));

  const andamento = await enviarConversas(conversas, enviarLote, (a) =>
    aoAndar({ passo: 'MANDANDO', andamento: a, conversas: 0, mensagens: 0 })
  );

  const fim: EstadoDaImportacao = {
    passo: 'PRONTO',
    andamento,
    conversas: andamento.conversasEnviadas,
    mensagens: andamento.mensagensEnviadas,
  };
  aoAndar(fim);
  return fim;
}
