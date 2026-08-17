import { createSupabaseServerClient } from '../../../../lib/supabase/server';
import { callAdminRpc } from '../../../../lib/supabase/admin-rpc';
import {
  isValidCpf,
  isValidPassword,
  isValidPhone,
  isValidPostalCode,
  isLikelyEmail,
  onlyDigits,
} from '../../../../lib/validation';

export const dynamic = 'force-dynamic';

const JSON_HEADERS = {
  'content-type': 'application/json; charset=utf-8',
  'cache-control': 'no-store',
};

function json(status: number, body: unknown): Response {
  return new Response(JSON.stringify(body), { status, headers: JSON_HEADERS });
}

export async function POST(request: Request): Promise<Response> {
  let input: Record<string, unknown>;
  try {
    input = (await request.json()) as Record<string, unknown>;
  } catch {
    return json(400, { error: 'INVALID_JSON' });
  }

  const fullName = String(input.fullName ?? '').trim();
  const birthDate = String(input.birthDate ?? '').trim();
  const phone = String(input.phone ?? '');
  const cpf = String(input.cpf ?? '');
  const email = String(input.email ?? '').trim();
  const password = String(input.password ?? '');
  const addressStreet = String(input.addressStreet ?? '').trim();
  const addressNeighborhood = String(input.addressNeighborhood ?? '').trim();
  const addressPostalCode = String(input.addressPostalCode ?? '');
  const establishmentName = String(input.establishmentName ?? '').trim();

  const problems: string[] = [];
  if (fullName.length < 2) problems.push('Nome completo é obrigatório.');
  if (!/^\d{4}-\d{2}-\d{2}$/.test(birthDate)) problems.push('Data de nascimento inválida.');
  if (!isValidPhone(phone)) problems.push('Telefone inválido, use DDD + número.');
  if (!isValidCpf(cpf)) problems.push('CPF inválido.');
  if (!isLikelyEmail(email)) problems.push('E-mail inválido.');
  if (!isValidPassword(password)) problems.push('Senha precisa ter ao menos 8 caracteres.');
  if (addressStreet.length < 3) problems.push('Endereço (rua) é obrigatório.');
  if (addressNeighborhood.length < 2) problems.push('Bairro é obrigatório.');
  if (!isValidPostalCode(addressPostalCode)) problems.push('CEP inválido.');
  if (establishmentName.length < 2) problems.push('Nome do estabelecimento é obrigatório.');

  if (problems.length > 0) {
    return json(422, { error: problems.join(' ') });
  }

  // O CPF é único no sistema — checar aqui evita mandar e-mail de
  // confirmação para quem nem vai conseguir concluir o cadastro depois
  // (a checagem definitiva, contra corrida, é a constraint no banco).
  const cpfCheck = await checkCpfAvailability(onlyDigits(cpf));
  if (cpfCheck === false) {
    return json(409, { error: 'Este CPF já está cadastrado.' });
  }

  const origin = new URL(request.url).origin;
  const supabase = await createSupabaseServerClient();
  const { data: signUpData, error: signUpError } = await supabase.auth.signUp({
    email,
    password,
    options: {
      emailRedirectTo: `${origin}/auth/callback`,
      // Guardado em user_metadata: o /auth/callback lê isso na primeira
      // confirmação de e-mail para criar o estabelecimento — não existe
      // sessão ainda agora para chamar essa RPC diretamente daqui.
      data: {
        full_name: fullName,
        birth_date: birthDate,
        phone_digits: onlyDigits(phone),
        cpf_digits: onlyDigits(cpf),
        address_street: addressStreet,
        address_neighborhood: addressNeighborhood,
        address_postal_code: onlyDigits(addressPostalCode),
        establishment_name: establishmentName,
      },
    },
  });

  if (signUpError) {
    return json(422, { error: 'Não foi possível concluir o cadastro. Tente novamente.' });
  }
  if (!signUpData.user || signUpData.user.identities?.length === 0) {
    // E-mail já cadastrado — Supabase não avisa isso explicitamente (evita
    // vazar quais e-mails existem), então respondemos de forma genérica.
    return json(409, {
      error: 'Este e-mail já está cadastrado. Tente entrar ou redefinir a senha.',
    });
  }

  return json(200, {
    data: { message: 'Cadastro criado. Verifique seu e-mail para confirmar e poder entrar.' },
  });
}

// Usa a chave secreta, não a publicável: `resolve_login_email` transforma um CPF
// no e-mail de login, e não pode ficar acessível ao papel `anon` (F0-02).
async function checkCpfAvailability(cpfDigits: string): Promise<boolean | null> {
  const result = await callAdminRpc<string | null>('resolve_login_email', {
    target_cpf_digits: cpfDigits,
  });
  return result.ok ? result.data === null : null;
}
