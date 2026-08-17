import { createSupabaseServerClient } from '../../../../lib/supabase/server';
import { callAdminRpc } from '../../../../lib/supabase/admin-rpc';
import { isValidCpf, onlyDigits, isLikelyEmail } from '../../../../lib/validation';

export const dynamic = 'force-dynamic';

const JSON_HEADERS = {
  'content-type': 'application/json; charset=utf-8',
  'cache-control': 'no-store',
};
const GENERIC_ERROR = 'E-mail/CPF ou senha inválidos, ou e-mail ainda não confirmado.';

function json(status: number, body: unknown): Response {
  return new Response(JSON.stringify(body), { status, headers: JSON_HEADERS });
}

// Usa a chave secreta, não a publicável: `resolve_login_email` transforma um CPF
// no e-mail de login, e não pode ficar acessível ao papel `anon` (F0-02).
async function resolveEmailFromCpf(cpfDigits: string): Promise<string | null> {
  const result = await callAdminRpc<string | null>('resolve_login_email', {
    target_cpf_digits: cpfDigits,
  });
  return result.ok ? (result.data ?? null) : null;
}

export async function POST(request: Request): Promise<Response> {
  let input: Record<string, unknown>;
  try {
    input = (await request.json()) as Record<string, unknown>;
  } catch {
    return json(400, { error: 'INVALID_JSON' });
  }

  const identifier = String(input.identifier ?? '').trim();
  const password = String(input.password ?? '');

  if (!identifier || !password) {
    return json(422, { error: GENERIC_ERROR });
  }

  let email: string | null = null;
  if (isLikelyEmail(identifier)) {
    email = identifier;
  } else if (isValidCpf(identifier)) {
    email = await resolveEmailFromCpf(onlyDigits(identifier));
  }

  if (!email) {
    return json(401, { error: GENERIC_ERROR });
  }

  const supabase = await createSupabaseServerClient();
  const { error } = await supabase.auth.signInWithPassword({ email, password });

  if (error) {
    return json(401, { error: GENERIC_ERROR });
  }

  return json(200, { data: { ok: true } });
}
