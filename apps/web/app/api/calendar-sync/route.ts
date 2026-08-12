import { NextResponse } from 'next/server';
import { createSupabaseServerClient } from '../../../lib/supabase/server';

export const dynamic = 'force-dynamic';

const TOKEN_URL = 'https://oauth2.googleapis.com/token';
const SYNC_WINDOW_DAYS = 60;

type ConnectionForSync = {
  id: string;
  unitId: string;
  provider: 'GOOGLE' | 'MICROSOFT';
  memberName: string | null;
  calendarId: string;
  accessToken: string | null;
  refreshToken: string | null;
  tokenExpiresAt: string | null;
};

type GoogleEvent = {
  id: string;
  status?: string;
  summary?: string;
  start?: { dateTime?: string; date?: string };
  end?: { dateTime?: string; date?: string };
};

// Sincronização real dos eventos do Google Agenda: chamada pelo botão
// "Sincronizar agora" na aba Agenda. Fica de fora do proxy genérico
// /api/configuration de propósito (lê e usa o access_token, que não pode
// nunca chegar no navegador) — o mesmo cuidado que o callback OAuth já
// tem. Hoje só suporta Google; Microsoft/Outlook usaria o mesmo desenho,
// trocando a chamada da API.
export async function POST(request: Request): Promise<Response> {
  const supabase = await createSupabaseServerClient();
  const {
    data: { session },
  } = await supabase.auth.getSession();
  if (!session) {
    return NextResponse.json({ error: 'UNAUTHENTICATED' }, { status: 401 });
  }

  let body: { tenantId?: unknown };
  try {
    body = await request.json();
  } catch {
    return NextResponse.json({ error: 'INVALID_JSON' }, { status: 400 });
  }
  const tenantId = body.tenantId;
  if (typeof tenantId !== 'string') {
    return NextResponse.json({ error: 'TENANT_REQUIRED' }, { status: 400 });
  }

  const configApiEndpoint = process.env.SUPABASE_CONFIGURATOR_URL;
  const clientId = process.env.GOOGLE_CALENDAR_CLIENT_ID;
  const clientSecret = process.env.GOOGLE_CALENDAR_CLIENT_SECRET;
  if (!configApiEndpoint || !clientId || !clientSecret) {
    return NextResponse.json({ error: 'NOT_CONFIGURED' }, { status: 503 });
  }

  async function callConfigApi(action: string, payload: Record<string, unknown>) {
    const response = await fetch(configApiEndpoint as string, {
      method: 'POST',
      headers: { 'content-type': 'application/json', authorization: `Bearer ${session!.access_token}` },
      body: JSON.stringify({ action, tenantId, ...payload }),
    });
    const json = (await response.json().catch(() => ({}))) as { data?: unknown; error?: string };
    if (!response.ok) throw new Error(json.error ?? 'REQUEST_FAILED');
    return json.data;
  }

  const connections = (await callConfigApi('listCalendarConnectionsForSync', {})) as ConnectionForSync[];
  const googleConnections = connections.filter((connection) => connection.provider === 'GOOGLE');

  if (googleConnections.length === 0) {
    return NextResponse.json({ error: 'NO_CONNECTION' }, { status: 404 });
  }

  const windowStart = new Date();
  const windowEnd = new Date(windowStart.getTime() + SYNC_WINDOW_DAYS * 86_400_000);

  const results = await Promise.all(
    googleConnections.map(async (connection) => {
      try {
        let accessToken = connection.accessToken;
        let newAccessToken: string | null = null;
        let newTokenExpiresAt: string | null = null;

        const expiresAt = connection.tokenExpiresAt ? Date.parse(connection.tokenExpiresAt) : 0;
        const needsRefresh = !accessToken || expiresAt - Date.now() < 5 * 60_000;

        if (needsRefresh) {
          if (!connection.refreshToken) {
            throw new Error('REFRESH_TOKEN_MISSING');
          }
          const tokenResponse = await fetch(TOKEN_URL, {
            method: 'POST',
            headers: { 'content-type': 'application/x-www-form-urlencoded' },
            body: new URLSearchParams({
              refresh_token: connection.refreshToken,
              client_id: clientId as string,
              client_secret: clientSecret as string,
              grant_type: 'refresh_token',
            }),
          });
          const tokenData = (await tokenResponse.json()) as {
            access_token?: string;
            expires_in?: number;
            error?: string;
          };
          if (!tokenResponse.ok || !tokenData.access_token) {
            throw new Error(tokenData.error ?? 'TOKEN_REFRESH_FAILED');
          }
          accessToken = tokenData.access_token;
          newAccessToken = tokenData.access_token;
          newTokenExpiresAt = tokenData.expires_in
            ? new Date(Date.now() + tokenData.expires_in * 1000).toISOString()
            : null;
        }

        const eventsUrl = new URL(
          `https://www.googleapis.com/calendar/v3/calendars/${encodeURIComponent(connection.calendarId)}/events`
        );
        eventsUrl.searchParams.set('timeMin', windowStart.toISOString());
        eventsUrl.searchParams.set('timeMax', windowEnd.toISOString());
        eventsUrl.searchParams.set('singleEvents', 'true');
        eventsUrl.searchParams.set('orderBy', 'startTime');
        eventsUrl.searchParams.set('maxResults', '250');

        const eventsResponse = await fetch(eventsUrl.toString(), {
          headers: { authorization: `Bearer ${accessToken}` },
        });
        if (!eventsResponse.ok) {
          const failure = (await eventsResponse.json().catch(() => ({}))) as { error?: { message?: string } };
          throw new Error(failure.error?.message ?? 'GOOGLE_EVENTS_FETCH_FAILED');
        }
        const eventsData = (await eventsResponse.json()) as { items?: GoogleEvent[] };

        // Só eventos com horário definido (dateTime) entram como bloqueio —
        // eventos de dia inteiro (só "date", sem hora) ficam de fora por
        // enquanto: bloquear o dia inteiro por um evento de dia inteiro
        // (ex.: aniversário, feriado marcado) seria bloqueio agressivo
        // demais sem a Duda poder ver/ajustar isso na tela ainda.
        const events = (eventsData.items ?? [])
          .filter((event) => event.status !== 'cancelled' && event.start?.dateTime && event.end?.dateTime)
          .map((event) => ({
            externalEventId: event.id,
            startsAt: event.start!.dateTime,
            endsAt: event.end!.dateTime,
            title: event.summary ?? null,
          }));

        const recordResult = (await callConfigApi('recordCalendarShiftSync', {
          connectionId: connection.id,
          windowStart: windowStart.toISOString(),
          windowEnd: windowEnd.toISOString(),
          events,
          newAccessToken,
          newTokenExpiresAt,
        })) as { ok: boolean; eventsSynced?: number };

        return { connectionId: connection.id, ok: recordResult.ok, eventsSynced: recordResult.eventsSynced ?? 0 };
      } catch (caught) {
        const message = caught instanceof Error ? caught.message : 'SYNC_FAILED';
        await callConfigApi('recordCalendarShiftSync', {
          connectionId: connection.id,
          windowStart: windowStart.toISOString(),
          windowEnd: windowEnd.toISOString(),
          events: [],
          syncError: message,
        }).catch(() => null);
        return { connectionId: connection.id, ok: false, error: message };
      }
    })
  );

  return NextResponse.json({ data: { results } });
}
