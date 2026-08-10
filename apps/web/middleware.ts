import { createServerClient } from '@supabase/ssr';
import { NextResponse, type NextRequest } from 'next/server';

// Causa real do "preciso pedir link toda vez": Server Components (como
// app/page.tsx) não podem gravar cookies — quando o Supabase precisa
// renovar o token de sessão durante um `getUser()` ali, a gravação do
// cookie renovado é silenciosamente descartada (ver o try/catch em
// lib/supabase/server.ts). Sem este middleware, a sessão nunca é
// persistida de volta no navegador, então depois que o access token
// expira (padrão: 1h) a sessão morre de vez, mesmo com refresh token
// válido, e força um novo link por e-mail.
//
// O middleware roda ANTES da Server Component, PODE gravar cookies na
// resposta, e é onde a renovação de fato precisa acontecer.
export async function middleware(request: NextRequest) {
  let response = NextResponse.next({ request });

  const supabaseUrl = process.env.NEXT_PUBLIC_SUPABASE_URL;
  const supabaseKey = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY;
  if (!supabaseUrl || !supabaseKey) {
    return response;
  }

  const supabase = createServerClient(supabaseUrl, supabaseKey, {
    cookies: {
      getAll() {
        return request.cookies.getAll();
      },
      setAll(cookiesToSet) {
        for (const { name, value } of cookiesToSet) {
          request.cookies.set(name, value);
        }
        response = NextResponse.next({ request });
        for (const { name, value, options } of cookiesToSet) {
          response.cookies.set(name, value, options);
        }
      },
    },
  });

  // Só o getUser() força a validação/renovação junto ao Supabase Auth —
  // getSession() apenas lê o que já está no cookie, sem renovar nada.
  await supabase.auth.getUser();

  return response;
}

export const config = {
  matcher: ['/((?!_next/static|_next/image|favicon.ico).*)'],
};
