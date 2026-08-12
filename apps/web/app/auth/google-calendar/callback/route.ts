import { NextResponse } from 'next/server';
import { createSupabaseServerClient } from '../../../../lib/supabase/server';
import { canonicalSiteUrl } from '../../../../lib/site-url';

export const dynamic = 'force-dynamic';

const TOKEN_URL = 'https://oauth2.googleapis.com/token';
const USERINFO_URL = 'https://www.googleapis.com/oauth2/v2/userinfo';

type TokenResponse = {
  access_token?: string;
  refresh_token?: string;
  expires_in?: number;
  scope?: string;
  error?: string;
};

// Troca o código do Google por tokens (aqui sim entra o client secret,
// server-to-server, nunca no navegador) e grava a conexão via
// owner-console-api. O motivo de gravar por essa rota, e não direto do
// navegador, é justamente esse: o token não pode passar pelo lado do
// cliente em nenhum momento.
export async function GET(request: Request): Promise<Response> {
  const url = new URL(request.url);
  const code = url.searchParams.get('code');
  const tenantId = url.searchParams.get('state');
  const googleError = url.searchParams.get('error');

  if (googleError) {
    return NextResponse.redirect(new URL(`/?calendarError=${encodeURIComponent(googleError)}`, request.url));
  }
  if (!code || !tenantId) {
    return NextResponse.redirect(new URL('/?calendarError=INVALID_CALLBACK', request.url));
  }

  const supabase = await createSupabaseServerClient();
  const {
    data: { session },
  } = await supabase.auth.getSession();
  if (!session?.access_token) {
    return NextResponse.redirect(new URL('/login', request.url));
  }

  const clientId = process.env.GOOGLE_CALENDAR_CLIENT_ID;
  const clientSecret = process.env.GOOGLE_CALENDAR_CLIENT_SECRET;
  const configApiEndpoint = process.env.SUPABASE_CONFIGURATOR_URL;
  if (!clientId || !clientSecret || !configApiEndpoint) {
    return NextResponse.redirect(new URL('/?calendarError=NOT_CONFIGURED', request.url));
  }

  // Fixo no domínio de produção, não na origem da requisição: precisa bater
  // exatamente com o redirect_uri cadastrado no Google, e isso muda a cada
  // deploy de preview da Vercel (veja lib/site-url.ts).
  const redirectUri = new URL('/auth/google-calendar/callback', canonicalSiteUrl()).toString();

  try {
    const tokenResponse = await fetch(TOKEN_URL, {
      method: 'POST',
      headers: { 'content-type': 'application/x-www-form-urlencoded' },
      body: new URLSearchParams({
        code,
        client_id: clientId,
        client_secret: clientSecret,
        redirect_uri: redirectUri,
        grant_type: 'authorization_code',
      }),
    });
    const tokenData = (await tokenResponse.json()) as TokenResponse;

    if (!tokenResponse.ok || !tokenData.access_token) {
      return NextResponse.redirect(
        new URL(`/?calendarError=${encodeURIComponent(tokenData.error ?? 'TOKEN_EXCHANGE_FAILED')}`, request.url)
      );
    }

    let externalAccountEmail: string | null = null;
    try {
      const userinfoResponse = await fetch(USERINFO_URL, {
        headers: { authorization: `Bearer ${tokenData.access_token}` },
      });
      if (userinfoResponse.ok) {
        const userinfo = (await userinfoResponse.json()) as { email?: string };
        externalAccountEmail = userinfo.email ?? null;
      }
    } catch {
      // Não crítico: a conexão funciona sem o e-mail exibido, só perde o rótulo.
    }

    const tokenExpiresAt = tokenData.expires_in
      ? new Date(Date.now() + tokenData.expires_in * 1000).toISOString()
      : null;

    const saveResponse = await fetch(configApiEndpoint, {
      method: 'POST',
      headers: {
        'content-type': 'application/json',
        authorization: `Bearer ${session.access_token}`,
      },
      body: JSON.stringify({
        action: 'saveCalendarConnection',
        tenantId,
        provider: 'GOOGLE',
        memberName: null,
        externalAccountEmail,
        calendarId: 'primary',
        accessToken: tokenData.access_token,
        refreshToken: tokenData.refresh_token ?? null,
        tokenExpiresAt,
        scope: tokenData.scope ?? null,
      }),
    });

    if (!saveResponse.ok) {
      return NextResponse.redirect(new URL('/?calendarError=SAVE_FAILED', request.url));
    }

    return NextResponse.redirect(new URL('/?calendarConnected=1', request.url));
  } catch {
    return NextResponse.redirect(new URL('/?calendarError=UNEXPECTED', request.url));
  }
}
