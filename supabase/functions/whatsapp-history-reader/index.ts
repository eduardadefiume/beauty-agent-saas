import 'jsr:@supabase/functions-js/edge-runtime.d.ts';
import { decidirQuemEQuem, separarMensagens } from './parser.ts';

// Lê o histórico exportado do WhatsApp e grava mensagem por mensagem.
//
// POR QUE É WORKER E NÃO REQUISIÇÃO. Uma conversa de dois anos tem milhares de
// linhas. O dono manda o arquivo e vai viver a vida dele; a fila no banco
// acorda de dois em dois minutos e vai lendo. Mesmo desenho do leitor de
// altura de tom.
//
// Entender o formato do export mora em `parser.ts`, separado justamente para
// poder ser testado no CI: é a parte que, se errar, faz o arquivo inteiro
// nascer torto sem ninguém perceber olhando a tela.

const JSON_HEADERS = {
  'content-type': 'application/json; charset=utf-8',
  'cache-control': 'no-store',
};

const BALDE = 'clientes';
const TETO_BYTES = 64 * 1024 * 1024;
// Em pedacos de 400: um arquivo de cinco mil mensagens num payload so seria
// pedido grande demais, e uma falha no meio perderia a leitura inteira.
const PEDACO = 400;

function json(status: number, body: unknown): Response {
  return new Response(JSON.stringify(body), { status, headers: JSON_HEADERS });
}

async function rpc(url: string, chave: string, fn: string, body: unknown): Promise<unknown> {
  const r = await fetch(`${url}/rest/v1/rpc/${fn}`, {
    method: 'POST',
    headers: {
      apikey: chave,
      authorization: `Bearer ${chave}`,
      'content-type': 'application/json',
    },
    body: JSON.stringify(body),
  });
  if (!r.ok) throw new Error(`RPC ${fn}: ${r.status} ${(await r.text()).slice(0, 300)}`);
  return await r.json();
}

Deno.serve(async (request: Request) => {
  if (request.method !== 'POST') return json(405, { error: 'METHOD_NOT_ALLOWED' });

  const supabaseUrl = Deno.env.get('SUPABASE_URL') ?? '';
  const chave = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '';
  if (!supabaseUrl || !chave) return json(503, { error: 'SERVICE_NOT_CONFIGURED' });

  let limite = 3;
  try {
    const corpo = (await request.json()) as { limit?: unknown };
    if (typeof corpo.limit === 'number') limite = corpo.limit;
  } catch {
    // Sem corpo é o caso normal: o pg_cron chama sem nada.
  }

  // Pegar a fila fica dentro de um try de proposito. Na primeira versao nao
  // ficava, e as funcoes do worker tinham nascido no schema `app`, que o
  // PostgREST nao expoe -- o 404 virava lance sem dono e o worker devolvia
  // `500 Internal Server Error` sem texto nenhum. Worker que falha mudo custa
  // uma tarde para diagnosticar.
  let fila: {
    archive_id: string;
    tenant_id: string;
    storage_path: string;
    filename: string;
    contact_label: string;
    owner_label: string | null;
  }[];
  try {
    fila = (await rpc(supabaseUrl, chave, 'wa_archive_claim', { p_limit: limite })) as typeof fila;
  } catch (erro) {
    return json(502, {
      error: 'FILA_INDISPONIVEL',
      detail: erro instanceof Error ? erro.message.slice(0, 300) : 'desconhecido',
    });
  }

  if (!Array.isArray(fila) || fila.length === 0) {
    return json(200, { data: { lidos: 0, fila: 0 } });
  }

  const resultados: unknown[] = [];

  for (const item of fila) {
    try {
      const caminho = item.storage_path.split('/').map(encodeURIComponent).join('/');
      const arquivo = await fetch(`${supabaseUrl}/storage/v1/object/${BALDE}/${caminho}`, {
        headers: { apikey: chave, authorization: `Bearer ${chave}` },
      });
      if (!arquivo.ok) throw new Error(`BALDE_${arquivo.status}`);

      const bytes = new Uint8Array(await arquivo.arrayBuffer());
      if (bytes.byteLength === 0) throw new Error('ARQUIVO_VAZIO');
      if (bytes.byteLength > TETO_BYTES) throw new Error('ARQUIVO_ACIMA_DO_TETO');

      const bruto = new TextDecoder('utf-8').decode(bytes);
      // O nome do dono vem do banco, respondido por ele uma vez. Quando ainda
      // nao respondeu, `null` faz o parser deduzir por contagem -- e empatar em
      // vez de chutar.
      const linhas = decidirQuemEQuem(separarMensagens(bruto), item.owner_label ?? null);

      if (linhas.length === 0) throw new Error('NENHUMA_MENSAGEM_RECONHECIDA');

      for (let i = 0; i < linhas.length; i += PEDACO) {
        await rpc(supabaseUrl, chave, 'wa_archive_write_chunk', {
          p_archive_id: item.archive_id,
          p_messages: linhas.slice(i, i + PEDACO),
        });
      }

      const fim = await rpc(supabaseUrl, chave, 'wa_archive_finish', {
        p_archive_id: item.archive_id,
      });
      resultados.push({ arquivo: item.filename, ...(fim as Record<string, unknown>) });
    } catch (erro) {
      const mensagem = erro instanceof Error ? erro.message : 'FALHA_NA_LEITURA';
      await rpc(supabaseUrl, chave, 'wa_archive_finish', {
        p_archive_id: item.archive_id,
        p_error: mensagem,
      }).catch(() => undefined);
      resultados.push({ arquivo: item.filename, erro: mensagem });
    }
  }

  return json(200, { data: { lidos: fila.length, resultados } });
});
