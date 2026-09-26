// google-agenda-conectar — o link que conecta o Google Agenda sem o site.
//
// Duas passagens pelo mesmo endereco:
//   1. ?c=<codigo do convite>  -> confere o convite e manda a pessoa ao Google
//   2. ?code=...&state=<codigo> -> o Google devolveu: troca pelos tokens e
//                                  grava a conexao (app.agenda_usar_convite)
//
// Nao ha login aqui: quem prova de qual salao e a agenda e o codigo do
// convite (aleatorio, uso unico, 24h), mandado pelo WhatsApp ao dono. Por isso
// verify_jwt = false no config.toml -- quem abre o link e um navegador.
//
// O endereco de retorno (redirect_uri) e esta mesma funcao, no projeto em que
// ela roda. Ele precisa estar cadastrado no Google Cloud, em "URIs de
// redirecionamento autorizados" do cliente OAuth, um por projeto (DEV e
// PRODUCAO).
//
// Resposta em texto puro: o dominio padrao das edge functions nao serve HTML.

import 'jsr:@supabase/functions-js/edge-runtime.d.ts';

const GOOGLE_AUTH_URL = 'https://accounts.google.com/o/oauth2/v2/auth';
const TOKEN_URL = 'https://oauth2.googleapis.com/token';
const USERINFO_URL = 'https://www.googleapis.com/oauth2/v2/userinfo';
// Leitura (dias de trabalho, compromissos) e escrita de eventos (G4: o
// agendamento aparece na agenda da profissional).
const ESCOPOS = [
  'https://www.googleapis.com/auth/calendar.readonly',
  'https://www.googleapis.com/auth/calendar.events',
  'https://www.googleapis.com/auth/userinfo.email',
  'openid',
].join(' ');
const CODIGO = /^[0-9a-f]{32}$/;

const MOTIVOS: Record<string, string> = {
  NAO_EXISTE: 'Este link não é válido. Peça um novo ao Eddy pelo WhatsApp.',
  JA_USADO: 'Este link já foi usado. Se precisar conectar de novo, peça um novo ao Eddy.',
  EXPIRADO: 'Este link venceu (vale 24 horas). Peça um novo ao Eddy pelo WhatsApp.',
};

function texto(status: number, mensagem: string): Response {
  return new Response(mensagem, {
    status,
    headers: { 'Content-Type': 'text/plain; charset=utf-8', 'Cache-Control': 'no-store' },
  });
}

async function rpc(url: string, key: string, nome: string, args: unknown): Promise<unknown> {
  const r = await fetch(`${url}/rest/v1/rpc/${nome}`, {
    method: 'POST',
    headers: { apikey: key, Authorization: `Bearer ${key}`, 'Content-Type': 'application/json' },
    body: JSON.stringify(args),
  });
  const corpo = await r.text();
  if (!r.ok) throw new Error(`${nome} ${r.status}: ${corpo.slice(0, 200)}`);
  return corpo ? JSON.parse(corpo) : null;
}

Deno.serve(async (req) => {
  const supabaseUrl = Deno.env.get('SUPABASE_URL');
  const serviceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
  const clientId = Deno.env.get('GOOGLE_CALENDAR_CLIENT_ID');
  const clientSecret = Deno.env.get('GOOGLE_CALENDAR_CLIENT_SECRET');
  if (!supabaseUrl || !serviceKey || !clientId || !clientSecret) {
    return texto(500, 'A conexão com o Google ainda não está configurada. Avise o suporte.');
  }
  if (req.method !== 'GET') return texto(405, 'Método não permitido.');

  const url = new URL(req.url);
  const redirectUri = `${supabaseUrl}/functions/v1/google-agenda-conectar`;

  // Passagem 2: voltou do Google.
  const state = url.searchParams.get('state');
  if (state !== null) {
    if (!CODIGO.test(state)) return texto(400, MOTIVOS.NAO_EXISTE);
    const erroGoogle = url.searchParams.get('error');
    if (erroGoogle) {
      return texto(
        400,
        erroGoogle === 'access_denied'
          ? 'Você não autorizou o acesso à agenda. Se mudar de ideia, abra o link de novo.'
          : `O Google recusou a conexão (${erroGoogle}). Peça um novo link ao Eddy.`
      );
    }
    const code = url.searchParams.get('code');
    if (!code) return texto(400, MOTIVOS.NAO_EXISTE);

    const r = await fetch(TOKEN_URL, {
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
    const tokens = (await r.json().catch(() => ({}))) as {
      access_token?: string;
      refresh_token?: string;
      expires_in?: number;
      scope?: string;
      error?: string;
    };
    if (!r.ok || !tokens.access_token) {
      console.error(JSON.stringify({ event: 'troca_falhou', erro: tokens.error ?? r.status }));
      return texto(502, 'Não consegui concluir a conexão com o Google. Peça um novo link ao Eddy.');
    }

    // Sem permissao de escrita o agendamento nao vai para a agenda: melhor
    // avisar agora do que descobrir depois.
    const escopo = tokens.scope ?? '';
    const escreve = escopo.includes('calendar.events');
    const le = escopo.includes('calendar.readonly') || escopo.includes('calendar.events');

    let conta: string | null = null;
    try {
      const u = await fetch(USERINFO_URL, {
        headers: { authorization: `Bearer ${tokens.access_token}` },
      });
      if (u.ok) conta = ((await u.json()) as { email?: string }).email ?? null;
    } catch {
      // So o rotulo da conexao; ela funciona sem o e-mail.
    }

    let gravado: { ok?: boolean; motivo?: string };
    try {
      gravado = (await rpc(supabaseUrl, serviceKey, 'agenda_usar_convite', {
        p_codigo: state,
        p_conta_google: conta,
        p_access_token: tokens.access_token,
        p_refresh_token: tokens.refresh_token ?? null,
        p_expira_em: new Date(Date.now() + (tokens.expires_in ?? 3600) * 1000).toISOString(),
        p_scope: escopo || null,
      })) as { ok?: boolean; motivo?: string };
    } catch (erro) {
      console.error(JSON.stringify({ event: 'gravar_falhou', erro: String(erro).slice(0, 200) }));
      return texto(500, 'O Google autorizou, mas não consegui salvar. Peça um novo link ao Eddy.');
    }
    if (!gravado?.ok) {
      return texto(400, MOTIVOS[gravado?.motivo ?? ''] ?? MOTIVOS.NAO_EXISTE);
    }

    const avisos: string[] = [];
    if (!le)
      avisos.push('Você não liberou a leitura da agenda: não vou enxergar seus compromissos.');
    if (!escreve)
      avisos.push(
        'Você não liberou a criação de eventos: os agendamentos não vão aparecer na sua agenda.'
      );
    if (!tokens.refresh_token)
      avisos.push('O Google não mandou a chave de longo prazo: a conexão pode cair em 1 hora.');

    return texto(
      200,
      [
        `Pronto! Sua agenda do Google${conta ? ` (${conta})` : ''} está conectada.`,
        ...avisos,
        'Pode fechar esta página e voltar ao WhatsApp.',
      ].join('\n\n')
    );
  }

  // Passagem 1: abriu o link do convite.
  const convite = url.searchParams.get('c') ?? '';
  if (!CODIGO.test(convite)) return texto(400, MOTIVOS.NAO_EXISTE);
  let conferido: { ok?: boolean; motivo?: string };
  try {
    conferido = (await rpc(supabaseUrl, serviceKey, 'agenda_conferir_convite', {
      p_codigo: convite,
    })) as { ok?: boolean; motivo?: string };
  } catch (erro) {
    console.error(JSON.stringify({ event: 'conferir_falhou', erro: String(erro).slice(0, 200) }));
    return texto(500, 'Não consegui abrir o link agora. Tente de novo em alguns minutos.');
  }
  if (!conferido?.ok) return texto(400, MOTIVOS[conferido?.motivo ?? ''] ?? MOTIVOS.NAO_EXISTE);

  const destino = new URL(GOOGLE_AUTH_URL);
  destino.searchParams.set('client_id', clientId);
  destino.searchParams.set('redirect_uri', redirectUri);
  destino.searchParams.set('response_type', 'code');
  destino.searchParams.set('scope', ESCOPOS);
  destino.searchParams.set('access_type', 'offline');
  // consent: sem ele o Google nao manda refresh_token numa segunda conexao.
  destino.searchParams.set('prompt', 'consent');
  destino.searchParams.set('include_granted_scopes', 'true');
  destino.searchParams.set('state', convite);
  return new Response(null, { status: 302, headers: { Location: destino.toString() } });
});
