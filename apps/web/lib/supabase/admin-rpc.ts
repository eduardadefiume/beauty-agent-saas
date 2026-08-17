/**
 * Chamada de RPC do Supabase com a chave secreta, restrita ao servidor.
 *
 * Motivo de existir (F0-02): `resolve_login_email` é `SECURITY DEFINER` e
 * converte um CPF no e-mail de login da pessoa. Enquanto ela ficou acessível ao
 * papel `anon`, qualquer um podia chamá-la direto no PostgREST com a chave
 * publicável e usá-la como oráculo de CPF para e-mail — sem autenticação e sem
 * limite de tentativas.
 *
 * As rotas que precisam dessa RPC (`/api/auth/login` e `/api/auth/signup`) são
 * Route Handlers e rodam no servidor, então podem usar a chave secreta. Com
 * isso a RPC deixa de precisar de qualquer permissão para papéis públicos.
 *
 * Nunca importe este módulo de um Client Component: a chave secreta ignora RLS.
 */

const SECRET_KEY_ENV = 'SUPABASE_SECRET_KEY';

export type AdminRpcResult<T> =
  { ok: true; data: T } | { ok: false; reason: 'NOT_CONFIGURED' | 'REQUEST_FAILED' };

/**
 * Invoca uma função do schema `public` via PostgREST usando a chave secreta.
 *
 * Devolve `NOT_CONFIGURED` quando a variável de ambiente não existe, para que a
 * rota chamadora decida o que fazer em vez de falhar de forma opaca. O valor é
 * lido dentro da função (e não no topo do módulo) para que o build não dependa
 * da variável estar presente.
 */
export async function callAdminRpc<T>(
  functionName: string,
  args: Record<string, unknown>
): Promise<AdminRpcResult<T>> {
  const supabaseUrl = process.env.NEXT_PUBLIC_SUPABASE_URL;
  const secretKey = process.env[SECRET_KEY_ENV];

  if (!supabaseUrl || !secretKey) {
    console.error(
      JSON.stringify({
        event: 'admin_rpc_not_configured',
        functionName,
        hasUrl: Boolean(supabaseUrl),
        hasSecretKey: Boolean(secretKey),
      })
    );
    return { ok: false, reason: 'NOT_CONFIGURED' };
  }

  const headers: Record<string, string> = {
    apikey: secretKey,
    'content-type': 'application/json',
  };

  // Chaves no formato novo (`sb_secret_...`) são enviadas apenas em `apikey`;
  // as legadas (JWT de service_role) também precisam do cabeçalho Authorization.
  if (!secretKey.startsWith('sb_secret_')) {
    headers.authorization = `Bearer ${secretKey}`;
  }

  let response: Response;
  try {
    response = await fetch(`${supabaseUrl}/rest/v1/rpc/${functionName}`, {
      method: 'POST',
      headers,
      body: JSON.stringify(args),
      cache: 'no-store',
    });
  } catch (error) {
    console.error(
      JSON.stringify({
        event: 'admin_rpc_transport_error',
        functionName,
        message: error instanceof Error ? error.message : 'unknown',
      })
    );
    return { ok: false, reason: 'REQUEST_FAILED' };
  }

  if (!response.ok) {
    console.error(
      JSON.stringify({ event: 'admin_rpc_failed', functionName, status: response.status })
    );
    return { ok: false, reason: 'REQUEST_FAILED' };
  }

  const data = (await response.json().catch(() => null)) as T;
  return { ok: true, data };
}
