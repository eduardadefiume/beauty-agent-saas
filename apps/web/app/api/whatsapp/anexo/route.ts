import { createSupabaseServerClient } from '../../../../lib/supabase/server';

export const dynamic = 'force-dynamic';

// Sobe um anexo para o balde privado `anexos` e devolve o caminho.
//
// POR QUE PASSA PELO SERVIDOR. O navegador poderia subir direto para o
// Storage com a sessão dele — as políticas do balde permitiriam. Passar por
// aqui existe por dois motivos que o navegador não consegue garantir sozinho:
// o caminho é montado no servidor a partir do tenant pedido (o navegador não
// escolhe em que pasta escreve), e o tipo e o tamanho são conferidos antes de
// o arquivo ocupar espaço.
//
// O caminho é sempre <tenantId>/<uuid>.<ext>. A primeira pasta é o crachá que
// as políticas do balde conferem, e é a mesma coisa que a RPC de envio exige
// antes de aceitar a mídia.

const JSON_HEADERS = {
  'content-type': 'application/json; charset=utf-8',
  'cache-control': 'no-store',
};

// Espelha o que o balde aceita. Repetir aqui é o que faz um arquivo recusado
// morrer antes de subir, em vez de subir e falhar na hora de enviar.
const MIMES = new Map<string, string>([
  ['image/jpeg', 'jpg'],
  ['image/png', 'png'],
  ['image/webp', 'webp'],
  ['video/mp4', 'mp4'],
  ['video/3gpp', '3gp'],
  ['audio/aac', 'aac'],
  ['audio/mp4', 'm4a'],
  ['audio/mpeg', 'mp3'],
  ['audio/amr', 'amr'],
  ['audio/ogg', 'ogg'],
  ['audio/webm', 'weba'],
  ['application/pdf', 'pdf'],
]);

const TETO_BYTES = 16 * 1024 * 1024;

function json(status: number, body: unknown): Response {
  return new Response(JSON.stringify(body), { status, headers: JSON_HEADERS });
}

export async function POST(request: Request): Promise<Response> {
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

  // O nome do arquivo NUNCA entra no caminho. Nome vindo do navegador carrega
  // acento, espaço, barra e o que mais o sistema de origem deixou passar — e
  // barra dentro do nome viraria pasta, furando o crachá do tenant.
  const caminho = `${tenantId}/${crypto.randomUUID()}.${extensao}`;

  const { error } = await supabase.storage
    .from('anexos')
    .upload(caminho, arquivo, { contentType: arquivo.type, upsert: false });

  if (error) {
    return json(502, { error: 'UPLOAD_FAILED', detail: error.message });
  }

  return json(200, {
    data: {
      storagePath: caminho,
      mimeType: arquivo.type,
      // O nome original volta só como rótulo — é o que a cliente vê quando o
      // anexo é documento, e o que aparece na conversa.
      filename: arquivo.name.slice(0, 200),
      size: arquivo.size,
    },
  });
}
