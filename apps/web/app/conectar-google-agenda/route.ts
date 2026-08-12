import { NextResponse } from 'next/server';
import { createSupabaseServerClient } from '../../lib/supabase/server';
import { canonicalSiteUrl } from '../../lib/site-url';

export const dynamic = 'force-dynamic';

const GOOGLE_OAUTH_URL = 'https://accounts.google.com/o/oauth2/v2/auth';
const SCOPES = [
  'https://www.googleapis.com/auth/calendar.readonly',
  'https://www.googleapis.com/auth/userinfo.email',
  'openid',
].join(' ');

// Ponto de partida da conexão com o Google Agenda: monta a URL de
// autorização e redireciona. O client secret não entra aqui — só o client
// id, que não é segredo (ele aparece na própria URL que o navegador visita).
export async function GET(request: Request): Promise<Response> {
  const supabase = await createSupabaseServerClient();
  const {
    data: { session },
  } = await supabase.auth.getSession();

  if (!session) {
    return NextResponse.redirect(new URL('/login', request.url));
  }

  const url = new URL(request.url);
  const tenantId = url.searchParams.get('tenantId');
  if (!tenantId) {
    return NextResponse.redirect(new URL('/?calendarError=TENANT_REQUIRED', request.url));
  }

  const clientId = process.env.GOOGLE_CALENDAR_CLIENT_ID;
  if (!clientId) {
    return NextResponse.redirect(new URL('/?calendarError=NOT_CONFIGURED', request.url));
  }

  // Fixo no domínio de produção: precisa bater exatamente com o
  // redirect_uri cadastrado no Google (veja lib/site-url.ts).
  const redirectUri = new URL('/auth/google-calendar/callback', canonicalSiteUrl()).toString();

  const authUrl = new URL(GOOGLE_OAUTH_URL);
  authUrl.searchParams.set('client_id', clientId);
  authUrl.searchParams.set('redirect_uri', redirectUri);
  authUrl.searchParams.set('response_type', 'code');
  authUrl.searchParams.set('scope', SCOPES);
  authUrl.searchParams.set('access_type', 'offline');
  authUrl.searchParams.set('prompt', 'consent');
  authUrl.searchParams.set('state', tenantId);

  return NextResponse.redirect(authUrl);
}
