import { createSupabaseServerClient } from './supabase/server';

// Subir e exibir foto de referência — a parte que Cor e Conhecimento têm igual.
//
// As duas telas guardam foto no MESMO balde privado (`conhecimento`) e pelo
// mesmo motivo: é imagem que ensina o sistema a reconhecer cabelo, não conteúdo
// público. O que muda entre elas é só a pasta. Duplicar noventa linhas de
// upload para mudar uma palavra seria garantir que um dia as duas divirjam em
// teto de tamanho ou tipo aceito.
//
// POR QUE PASSA PELO SERVIDOR, e não direto do navegador para o Storage: o
// caminho é montado aqui a partir do tenant, então o navegador não escolhe em
// que pasta escreve; e o tipo e o tamanho são conferidos antes de o arquivo
// ocupar espaço.

const BALDE = 'conhecimento';

const JSON_HEADERS = {
  'content-type': 'application/json; charset=utf-8',
  'cache-control': 'no-store',
};

// Espelha o que o balde aceita. Repetir aqui é o que faz um arquivo recusado
// morrer antes de subir, em vez de subir e falhar depois.
const MIMES = new Map<string, string>([
  ['image/jpeg', 'jpg'],
  ['image/png', 'png'],
  ['image/webp', 'webp'],
]);

const TETO_BYTES = 8 * 1024 * 1024;

function json(status: number, body: unknown): Response {
  return new Response(JSON.stringify(body), { status, headers: JSON_HEADERS });
}

export async function subirFotoDeReferencia(request: Request, pasta: string): Promise<Response> {
  const supabase = await createSupabaseServerClient();
  const {
    data: { session },
  } = await supabase.auth.getSession();

  if (!session?.access_token) {
    return json(401, { error: 'AUTHENTICATION_REQUIRED' });
  }

  let formulario: FormData;
  try {
    formulario = await request.formData();
  } catch {
    return json(400, { error: 'INVALID_FORM' });
  }

  const tenantId = formulario.get('tenantId');
  const arquivo = formulario.get('file');

  if (typeof tenantId !== 'string' || !/^[0-9a-f-]{36}$/.test(tenantId)) {
    return json(400, { error: 'TENANT_REQUIRED' });
  }
  if (!(arquivo instanceof File)) {
    return json(400, { error: 'FILE_REQUIRED' });
  }

  const extensao = MIMES.get(arquivo.type);
  if (!extensao) {
    return json(415, { error: 'UNSUPPORTED_MEDIA_TYPE', mime: arquivo.type });
  }
  if (arquivo.size === 0) {
    return json(400, { error: 'EMPTY_FILE' });
  }
  if (arquivo.size > TETO_BYTES) {
    return json(413, { error: 'FILE_TOO_LARGE' });
  }

  // O nome do arquivo nunca entra no caminho: nome vindo do navegador carrega
  // acento, espaço e barra, e barra viraria pasta, furando o crachá do tenant.
  const caminho = `${tenantId}/${pasta}/${crypto.randomUUID()}.${extensao}`;

  const { error } = await supabase.storage
    .from(BALDE)
    .upload(caminho, arquivo, { contentType: arquivo.type, upsert: false });

  if (error) {
    return json(502, { error: 'UPLOAD_FAILED', detail: error.message });
  }

  return json(200, { data: { storagePath: caminho, mimeType: arquivo.type, size: arquivo.size } });
}

// Uma URL assinada e curta para exibir a foto na tela.
//
// Assinar com a sessão de quem pediu faz a própria política do balde barrar
// caminho de outro negócio — não é preciso conferir o tenant de novo aqui, e
// conferir de novo seria a segunda verdade que um dia diverge da primeira.
export async function assinarFotoDeReferencia(request: Request): Promise<Response> {
  const supabase = await createSupabaseServerClient();
  const {
    data: { session },
  } = await supabase.auth.getSession();

  if (!session?.access_token) {
    return json(401, { error: 'AUTHENTICATION_REQUIRED' });
  }

  const caminho = new URL(request.url).searchParams.get('path');
  if (!caminho) {
    return json(400, { error: 'PATH_REQUIRED' });
  }

  const { data, error } = await supabase.storage.from(BALDE).createSignedUrl(caminho, 60 * 10);

  if (error || !data?.signedUrl) {
    return json(404, { error: 'FOTO_INDISPONIVEL' });
  }

  return json(200, { data: { url: data.signedUrl } });
}
