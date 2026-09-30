// google-agenda — sincroniza sozinho as agendas do Google conectadas.
//
// Roda como worker (AGENDA, de 15 em 15 minutos). Para cada conexao ativa:
// renova o token quando precisa, le os proximos 60 dias e entrega os eventos
// crus ao banco. QUEM DECIDE o que cada evento vira (dia de trabalho,
// bloqueio, ignorado) e app.agenda_gravar_sincronizacao, no banco -- aqui so
// se traduz o formato do Google.
//
// Antes (ate 26/09/2026) a sincronizacao so acontecia no botao
// "Sincronizar agora" do site, e a chave do Google so existia na Vercel.

import 'jsr:@supabase/functions-js/edge-runtime.d.ts';

const TOKEN_URL = 'https://oauth2.googleapis.com/token';
const JANELA_DIAS = 60;

type Conexao = {
  id: string;
  tenantId: string;
  calendarId: string;
  accessToken: string | null;
  refreshToken: string | null;
  tokenExpiresAt: string | null;
};

type EventoGoogle = {
  id: string;
  status?: string;
  summary?: string;
  transparency?: string;
  visibility?: string;
  start?: { dateTime?: string; date?: string };
  end?: { dateTime?: string; date?: string };
  extendedProperties?: { private?: Record<string, string> };
};

function json(status: number, corpo: unknown): Response {
  return new Response(JSON.stringify(corpo), {
    status,
    headers: { 'Content-Type': 'application/json' },
  });
}

async function rpc(url: string, key: string, nome: string, args: unknown): Promise<unknown> {
  const r = await fetch(`${url}/rest/v1/rpc/${nome}`, {
    method: 'POST',
    headers: { apikey: key, Authorization: `Bearer ${key}`, 'Content-Type': 'application/json' },
    body: JSON.stringify(args),
  });
  const texto = await r.text();
  if (!r.ok) throw new Error(`${nome} ${r.status}: ${texto.slice(0, 300)}`);
  return texto ? JSON.parse(texto) : null;
}

async function autorizado(req: Request, url: string, key: string): Promise<boolean> {
  const token = req.headers.get('x-worker-token');
  if (!token) return false;
  try {
    return (await rpc(url, key, 'verify_worker_token', { p_token: token })) === true;
  } catch {
    return false;
  }
}

// O formato que o banco entende. Evento cancelado nao entra; evento que o
// proprio sistema escreveu na agenda (agendamento de cliente) tambem nao:
// ele ja existe como agendamento, e contar de novo ocuparia o horario duas
// vezes.
export function traduzir(ev: EventoGoogle) {
  if (ev.status === 'cancelled') return null;
  if (ev.extendedProperties?.private?.origem === 'eddigital') return null;
  const diaInteiro = !!ev.start?.date && !ev.start?.dateTime;
  return {
    id: ev.id,
    titulo: ev.summary ?? '',
    inicio: ev.start?.dateTime ?? null,
    fim: ev.end?.dateTime ?? null,
    dia: ev.start?.date ?? null,
    dia_inteiro: diaInteiro,
    livre: ev.transparency === 'transparent',
    particular: ev.visibility === 'private' || ev.visibility === 'confidential',
  };
}

// Renova o token quando falta pouco para vencer. Devolve o token bom e, se
// renovou, o novo e quando vence -- quem chama grava no banco.
async function tokenValido(
  c: { accessToken: string | null; refreshToken: string | null; tokenExpiresAt: string | null },
  clientId: string,
  clientSecret: string
): Promise<{ token: string; novoToken: string | null; novoVence: string | null }> {
  const vence = c.tokenExpiresAt ? Date.parse(c.tokenExpiresAt) : 0;
  if (c.accessToken && vence - Date.now() >= 5 * 60_000) {
    return { token: c.accessToken, novoToken: null, novoVence: null };
  }
  if (!c.refreshToken) throw new Error('REFRESH_TOKEN_MISSING');
  const r = await fetch(TOKEN_URL, {
    method: 'POST',
    headers: { 'content-type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({
      refresh_token: c.refreshToken,
      client_id: clientId,
      client_secret: clientSecret,
      grant_type: 'refresh_token',
    }),
  });
  const dados = (await r.json().catch(() => ({}))) as {
    access_token?: string;
    expires_in?: number;
    error?: string;
  };
  if (!r.ok || !dados.access_token) throw new Error(dados.error ?? 'TOKEN_REFRESH_FAILED');
  return {
    token: dados.access_token,
    novoToken: dados.access_token,
    novoVence: new Date(Date.now() + (dados.expires_in ?? 3600) * 1000).toISOString(),
  };
}

type Gravacao = {
  id: string;
  deveExistir: boolean;
  googleEventId: string;
  jaGravado: boolean;
  appointmentId: string;
  conexao: {
    id: string;
    calendarId: string;
    accessToken: string | null;
    refreshToken: string | null;
    tokenExpiresAt: string | null;
  };
  evento: { titulo: string; inicio: string; fim: string; fuso: string; descricao: string };
};

// G4: o agendamento vira evento na agenda de quem atende. O id do evento e
// derivado do agendamento, entao gravar de novo nunca duplica: o Google
// responde 409 e a gente atualiza o que ja existe.
async function gravarUma(g: Gravacao, token: string): Promise<boolean> {
  const base = `https://www.googleapis.com/calendar/v3/calendars/${encodeURIComponent(
    g.conexao.calendarId || 'primary'
  )}/events`;
  const auth = { authorization: `Bearer ${token}`, 'content-type': 'application/json' };

  if (!g.deveExistir) {
    const r = await fetch(`${base}/${encodeURIComponent(g.googleEventId)}?sendUpdates=none`, {
      method: 'DELETE',
      headers: auth,
    });
    // 404/410: ja nao existia (ou o dono apagou na mao). O que se queria esta feito.
    if (!r.ok && r.status !== 404 && r.status !== 410) {
      throw new Error(`GOOGLE_DELETE_${r.status}`);
    }
    return false;
  }

  const corpo = {
    id: g.googleEventId,
    summary: g.evento.titulo,
    description: g.evento.descricao,
    start: { dateTime: g.evento.inicio, timeZone: g.evento.fuso },
    end: { dateTime: g.evento.fim, timeZone: g.evento.fuso },
    status: 'confirmed',
    extendedProperties: { private: { origem: 'eddigital', agendamento: g.appointmentId } },
  };

  let r = await fetch(`${base}?sendUpdates=none`, {
    method: 'POST',
    headers: auth,
    body: JSON.stringify(corpo),
  });
  if (r.status === 409) {
    // Ja existe (gravado antes, ou apagado e ainda na lixeira): atualiza.
    r = await fetch(`${base}/${encodeURIComponent(g.googleEventId)}?sendUpdates=none`, {
      method: 'PUT',
      headers: auth,
      body: JSON.stringify(corpo),
    });
  }
  if (!r.ok) {
    const e = (await r.json().catch(() => ({}))) as { error?: { status?: string } };
    throw new Error(`GOOGLE_${r.status}_${e.error?.status ?? ''}`);
  }
  return true;
}

Deno.serve(async (req) => {
  const supabaseUrl = Deno.env.get('SUPABASE_URL');
  const serviceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
  const clientId = Deno.env.get('GOOGLE_CALENDAR_CLIENT_ID');
  const clientSecret = Deno.env.get('GOOGLE_CALENDAR_CLIENT_SECRET');
  if (!supabaseUrl || !serviceKey) return json(500, { ok: false, reason: 'SUPABASE_ENV_MISSING' });
  if (!(await autorizado(req, supabaseUrl, serviceKey))) {
    return json(401, { ok: false, reason: 'WORKER_TOKEN_INVALID' });
  }
  if (!clientId || !clientSecret) {
    return json(500, { ok: false, reason: 'GOOGLE_ENV_MISSING' });
  }

  // Diagnostico da chave, sem tocar em conexao nenhuma: troca um refresh
  // token inventado. Chave boa -> o Google recusa o TOKEN (invalid_grant);
  // chave ruim -> recusa o CLIENTE (invalid_client). Foi o que faltou em
  // 26/09 para separar "chave errada" de "conexao morta".
  const corpo = (await req.json().catch(() => ({}))) as { acao?: string };
  if (corpo.acao === 'testar_chave') {
    const r = await fetch(TOKEN_URL, {
      method: 'POST',
      headers: { 'content-type': 'application/x-www-form-urlencoded' },
      body: new URLSearchParams({
        refresh_token: 'diagnostico-token-inexistente',
        client_id: clientId,
        client_secret: clientSecret,
        grant_type: 'refresh_token',
      }),
    });
    const dados = (await r.json().catch(() => ({}))) as { error?: string };
    return json(200, {
      ok: true,
      acao: 'testar_chave',
      respostaDoGoogle: dados.error ?? `HTTP_${r.status}`,
      chaveValida: dados.error === 'invalid_grant',
      clientIdTermina: clientId.slice(-30),
    });
  }

  if (corpo.acao === 'gravar') {
    const fila = ((await rpc(supabaseUrl, serviceKey, 'agenda_gravacoes_pendentes', {
      p_limite: 20,
    })) ?? []) as Gravacao[];
    const tokens = new Map<string, Awaited<ReturnType<typeof tokenValido>>>();
    const feitos = [];
    for (const g of fila) {
      let renovado: Awaited<ReturnType<typeof tokenValido>> | undefined;
      try {
        renovado = tokens.get(g.conexao.id);
        const primeiraVez = !renovado;
        if (!renovado) {
          renovado = await tokenValido(g.conexao, clientId, clientSecret);
          tokens.set(g.conexao.id, renovado);
        }
        const existe = await gravarUma(g, renovado.token);
        await rpc(supabaseUrl, serviceKey, 'agenda_gravacao_feita', {
          p_id: g.id,
          p_google_event_id: g.googleEventId,
          p_existe: existe,
          p_erro: null,
          p_new_access_token: primeiraVez ? renovado.novoToken : null,
          p_new_expires_at: primeiraVez ? renovado.novoVence : null,
        });
        feitos.push({ id: g.id, existe });
      } catch (erro) {
        const motivo = String(erro instanceof Error ? erro.message : erro).slice(0, 200);
        await rpc(supabaseUrl, serviceKey, 'agenda_gravacao_feita', {
          p_id: g.id,
          p_google_event_id: null,
          p_existe: false,
          p_erro: motivo,
          p_new_access_token: null,
          p_new_expires_at: null,
        }).catch(() => {});
        feitos.push({ id: g.id, erro: motivo });
      }
    }
    return json(200, { ok: true, acao: 'gravar', fila: fila.length, feitos });
  }

  const conexoes = ((await rpc(supabaseUrl, serviceKey, 'agenda_conexoes_para_sincronizar', {
    p_limite: 20,
  })) ?? []) as Conexao[];

  const inicio = new Date();
  const fim = new Date(inicio.getTime() + JANELA_DIAS * 86_400_000);
  const resultados = [];

  for (const c of conexoes) {
    let novoToken: string | null = null;
    let novoVence: string | null = null;
    try {
      let token = c.accessToken;
      const vence = c.tokenExpiresAt ? Date.parse(c.tokenExpiresAt) : 0;
      if (!token || vence - Date.now() < 5 * 60_000) {
        if (!c.refreshToken) throw new Error('REFRESH_TOKEN_MISSING');
        const r = await fetch(TOKEN_URL, {
          method: 'POST',
          headers: { 'content-type': 'application/x-www-form-urlencoded' },
          body: new URLSearchParams({
            refresh_token: c.refreshToken,
            client_id: clientId,
            client_secret: clientSecret,
            grant_type: 'refresh_token',
          }),
        });
        const dados = (await r.json().catch(() => ({}))) as {
          access_token?: string;
          expires_in?: number;
          error?: string;
        };
        if (!r.ok || !dados.access_token) throw new Error(dados.error ?? 'TOKEN_REFRESH_FAILED');
        token = dados.access_token;
        novoToken = dados.access_token;
        novoVence = new Date(Date.now() + (dados.expires_in ?? 3600) * 1000).toISOString();
      }

      const eventos: ReturnType<typeof traduzir>[] = [];
      let pagina: string | undefined;
      for (let i = 0; i < 5; i++) {
        const u = new URL(
          `https://www.googleapis.com/calendar/v3/calendars/${encodeURIComponent(c.calendarId || 'primary')}/events`
        );
        u.searchParams.set('timeMin', inicio.toISOString());
        u.searchParams.set('timeMax', fim.toISOString());
        u.searchParams.set('singleEvents', 'true');
        u.searchParams.set('orderBy', 'startTime');
        u.searchParams.set('maxResults', '250');
        if (pagina) u.searchParams.set('pageToken', pagina);
        const r = await fetch(u.toString(), { headers: { authorization: `Bearer ${token}` } });
        const dados = (await r.json().catch(() => ({}))) as {
          items?: EventoGoogle[];
          nextPageToken?: string;
          error?: { message?: string; status?: string };
        };
        if (!r.ok)
          throw new Error(dados.error?.status ?? dados.error?.message ?? `GOOGLE_${r.status}`);
        for (const ev of dados.items ?? []) {
          const t = traduzir(ev);
          if (t) eventos.push(t);
        }
        pagina = dados.nextPageToken;
        if (!pagina) break;
      }

      const gravado = await rpc(supabaseUrl, serviceKey, 'agenda_gravar_sincronizacao', {
        p_connection_id: c.id,
        p_window_start: inicio.toISOString(),
        p_window_end: fim.toISOString(),
        p_eventos: eventos,
        p_new_access_token: novoToken,
        p_new_expires_at: novoVence,
        p_erro: null,
      });
      resultados.push({ conexao: c.id, eventos: eventos.length, gravado });
    } catch (erro) {
      const motivo = String(erro instanceof Error ? erro.message : erro).slice(0, 200);
      try {
        await rpc(supabaseUrl, serviceKey, 'agenda_gravar_sincronizacao', {
          p_connection_id: c.id,
          p_window_start: inicio.toISOString(),
          p_window_end: fim.toISOString(),
          p_eventos: [],
          p_new_access_token: null,
          p_new_expires_at: null,
          p_erro: motivo,
        });
      } catch (erroGravar) {
        console.error('AGENDA_ERRO_NAO_GRAVADO', c.id, String(erroGravar));
      }
      resultados.push({ conexao: c.id, erro: motivo });
    }
  }

  return json(200, { ok: true, conexoes: conexoes.length, resultados });
});
