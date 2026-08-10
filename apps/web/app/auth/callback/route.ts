import { NextResponse } from 'next/server';
import { createSupabaseServerClient } from '../../../lib/supabase/server';

export const dynamic = 'force-dynamic';

const ALLOWED_NEXT_PATHS = new Set(['/', '/redefinir-senha']);

export async function GET(request: Request): Promise<Response> {
  const url = new URL(request.url);
  const code = url.searchParams.get('code');

  if (code) {
    const supabase = await createSupabaseServerClient();
    const { data } = await supabase.auth.exchangeCodeForSession(code);
    const metadata = data.user?.user_metadata as Record<string, unknown> | undefined;

    // Só quem veio do formulário de /cadastro tem esses campos em
    // user_metadata. Contas antigas (link mágico, sem cadastro completo)
    // não têm — nada a fazer aqui para elas, seu tenant já existe.
    if (metadata && typeof metadata.establishment_name === 'string') {
      await supabase.rpc('complete_owner_signup', {
        target_full_name: metadata.full_name,
        target_birth_date: metadata.birth_date,
        target_phone_digits: metadata.phone_digits,
        target_cpf_digits: metadata.cpf_digits,
        target_address_street: metadata.address_street,
        target_address_neighborhood: metadata.address_neighborhood,
        target_address_postal_code: metadata.address_postal_code,
        target_establishment_name: metadata.establishment_name,
      });
      // Erro aqui (ex.: corrida rara em CPF) não deve travar o login —
      // a própria RPC é idempotente; se falhar, a próxima tentativa de
      // login chama de novo. Não interrompe o redirecionamento.
    }
  }

  const requestedNext = url.searchParams.get('next') ?? '/';
  const next = ALLOWED_NEXT_PATHS.has(requestedNext) ? requestedNext : '/';

  return NextResponse.redirect(new URL(next, url.origin));
}
