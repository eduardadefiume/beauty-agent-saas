import { createSupabaseServerClient } from '../../../../lib/supabase/server';
import { isValidCpf, onlyDigits, isLikelyEmail } from '../../../../lib/validation';

export const dynamic = 'force-dynamic';

const JSON_HEADERS = { 'content-type': 'application/json; charset=utf-8', 'cache-control': 'no-store' };
const GENERIC_ERROR = 'E-mail/CPF ou senha inválidos, ou e-mail ainda não confirmado.';

function json(status: number, body: unknown): Response {
  return new Response(JSON.stringify(body), { status, headers: JSON_HEADERS });
}

async function resolveEmailFromCpf(cpfDigits: string): Promise<string | null> {
  const supabaseUrl = process.env.NEXT_PUBLIC_SUPABASE_URL;
  const anonKey = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY;
  if (!supabaseUrl || !anonKey) return null;

  const response = await fetch(`${supabaseUrl}/rest/v1/rpc/resolve_login_email`, {
    method: 'POST',
    headers: { apikey: anonKey, authorization: `Bearer ${anonKey}`, 'content-type': 'application/json' },
    body: JSON.stringify({ target_cpf_digits: cpfDigits }),
  });
  if (!response.ok) return null;
  const value = (await response.json().catch(() => null)) as string | null;
  return value ?? null;
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
