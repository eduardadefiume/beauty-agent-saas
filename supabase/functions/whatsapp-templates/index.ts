// whatsapp-templates — cria e acompanha na Meta os modelos de mensagem que o
// sistema manda FORA da janela de 24h.
//
// Por que existe: o WhatsApp so deixa a empresa escrever primeiro com modelo
// aprovado. Texto livre so vale ate 24h depois da ultima mensagem da pessoa.
// Em 25/09 isso derrubava duas coisas: o lembrete da vespera (quem marcou com
// 5 dias de antecedencia nao recebia nada) e o aviso ao dono de que a
// atendente precisa dele (dono que nao falou com o Eddy no dia nao era
// avisado). Com modelo, as duas saem a qualquer hora -- pagas por mensagem.
//
// Duas acoes, as duas chamadas pelo worker (x-worker-token):
//   criar       -> submete os modelos que ainda nao existem na WABA
//   sincronizar -> le o status na Meta e grava em message_templates dos
//                  saloes informados; so APPROVED e usado no envio
//
// O corpo diz a WABA e o NOME do segredo com o token, porque cada conexao tem
// o seu (mesma regra do whatsapp-sender, ver `credential_ref`).

import 'jsr:@supabase/functions-js/edge-runtime.d.ts';

const GRAPH_VERSION = 'v21.0';
const NOME_DE_SEGREDO = /^[A-Z][A-Z0-9_]{2,63}$/;

type Modelo = {
  codigo: string;
  nome: string;
  texto: string;
  exemplo: string[];
};

// O texto e fixo e as lacunas sao {{n}}. A Meta recusa modelo que comeca ou
// termina em lacuna, e modelo com lacuna demais para o tamanho do texto. A
// ordem das lacunas e a mesma que o banco manda em template_params.
export const MODELOS: Modelo[] = [
  {
    codigo: 'LEMBRETE_VESPERA',
    nome: 'lembrete_vespera',
    texto:
      'Olá, {{1}}! Passando para lembrar do seu horário amanhã, {{2}}, às {{3}}, no {{4}}. ' +
      'Se precisar remarcar, é só responder esta mensagem.',
    exemplo: ['Marina', '26/09', '10:00', 'Studio Rogério Hair'],
  },
  {
    codigo: 'AVISO_AO_DONO',
    nome: 'aviso_ao_dono',
    // 25/09: "...Codigo {{4}}." foi recusado -- a Meta considera o ponto
    // final como "termina em lacuna". O texto fixo tem que fechar a frase.
    texto:
      'Olá! A atendente do {{1}} precisa de uma resposta sua sobre a cliente {{2}}. ' +
      'Pergunta: {{3}} (código {{4}}). Responda esta mensagem que eu passo a resposta para ela.',
    exemplo: ['Studio Rogério Hair', 'Paula', 'Gestante pode fazer hidratação?', '#4448'],
  },
];

function json(status: number, corpo: unknown): Response {
  return new Response(JSON.stringify(corpo), {
    status,
    headers: { 'Content-Type': 'application/json' },
  });
}

async function rpc(url: string, key: string, nome: string, args: unknown): Promise<unknown> {
  const r = await fetch(`${url}/rest/v1/rpc/${nome}`, {
    method: 'POST',
    headers: {
      apikey: key,
      Authorization: `Bearer ${key}`,
      'Content-Type': 'application/json',
    },
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

async function graph(
  metodo: 'GET' | 'POST',
  caminho: string,
  token: string,
  corpo?: unknown
): Promise<{ ok: boolean; status: number; dados: Record<string, unknown> }> {
  const r = await fetch(`https://graph.facebook.com/${GRAPH_VERSION}/${caminho}`, {
    method: metodo,
    headers: {
      Authorization: `Bearer ${token}`,
      'Content-Type': 'application/json',
    },
    body: corpo ? JSON.stringify(corpo) : undefined,
  });
  let dados: Record<string, unknown> = {};
  try {
    dados = (await r.json()) as Record<string, unknown>;
  } catch {
    dados = {};
  }
  return { ok: r.ok, status: r.status, dados };
}

Deno.serve(async (req) => {
  const supabaseUrl = Deno.env.get('SUPABASE_URL');
  const serviceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
  if (!supabaseUrl || !serviceKey) return json(500, { ok: false, reason: 'SUPABASE_ENV_MISSING' });
  if (!(await autorizado(req, supabaseUrl, serviceKey))) {
    return json(401, { ok: false, reason: 'WORKER_TOKEN_INVALID' });
  }

  let corpo: { acao?: string; wabaId?: string; segredo?: string; tenantIds?: string[] };
  try {
    corpo = await req.json();
  } catch {
    return json(400, { ok: false, reason: 'CORPO_INVALIDO' });
  }

  const wabaId = String(corpo.wabaId ?? '').trim();
  const segredo = String(corpo.segredo ?? 'WHATSAPP_ACCESS_TOKEN').trim();
  if (!/^\d{5,25}$/.test(wabaId)) return json(400, { ok: false, reason: 'WABA_INVALIDA' });
  if (!NOME_DE_SEGREDO.test(segredo)) return json(400, { ok: false, reason: 'SEGREDO_INVALIDO' });
  const token = Deno.env.get(segredo);
  if (!token) return json(500, { ok: false, reason: 'TOKEN_AUSENTE', segredo });

  if (corpo.acao === 'criar') {
    const resultados = [];
    for (const m of MODELOS) {
      const r = await graph('POST', `${wabaId}/message_templates`, token, {
        name: m.nome,
        language: 'pt_BR',
        category: 'UTILITY',
        components: [{ type: 'BODY', text: m.texto, example: { body_text: [m.exemplo] } }],
      });
      resultados.push({
        modelo: m.nome,
        ok: r.ok,
        httpStatus: r.status,
        id: r.dados.id ?? null,
        status: r.dados.status ?? null,
        categoria: r.dados.category ?? null,
        erro: r.ok ? null : ((r.dados.error as Record<string, unknown>) ?? r.dados),
      });
    }
    return json(200, { ok: true, acao: 'criar', resultados });
  }

  if (corpo.acao === 'sincronizar') {
    const r = await graph(
      'GET',
      `${wabaId}/message_templates?fields=name,status,language,category,rejected_reason&limit=200`,
      token
    );
    if (!r.ok)
      return json(502, { ok: false, reason: 'GRAPH_FALHOU', erro: r.dados.error ?? r.dados });

    const naMeta = (r.dados.data as Array<Record<string, string>>) ?? [];
    const tenantIds = Array.isArray(corpo.tenantIds) ? corpo.tenantIds : [];
    const resultados = [];
    for (const m of MODELOS) {
      const achado = naMeta.find((t) => t.name === m.nome && t.language === 'pt_BR');
      const status = achado?.status ?? 'NAO_EXISTE';
      const gravados = [];
      if (achado) {
        for (const tenantId of tenantIds) {
          try {
            await rpc(supabaseUrl, serviceKey, 'registrar_modelo_aprovado', {
              p_tenant_id: tenantId,
              p_code: m.codigo,
              p_template_name: m.nome,
              p_param_count: m.exemplo.length,
              p_language: 'pt_BR',
              p_category: achado.category ?? 'UTILITY',
              p_preview: m.texto,
              // A tabela so conhece quatro estados; o que a Meta tiver alem
              // disso (IN_APPEAL, PENDING_DELETION...) nao pode ser usado.
              p_status: ['APPROVED', 'REJECTED', 'PAUSED'].includes(status)
                ? status
                : status === 'DISABLED'
                  ? 'PAUSED'
                  : 'PENDING',
            });
            gravados.push(tenantId);
          } catch (erro) {
            gravados.push(`${tenantId}: ${String(erro).slice(0, 120)}`);
          }
        }
      }
      resultados.push({
        modelo: m.nome,
        status,
        categoria: achado?.category ?? null,
        motivoRecusa: achado?.rejected_reason ?? null,
        gravadoEm: gravados,
      });
    }
    return json(200, { ok: true, acao: 'sincronizar', resultados });
  }

  return json(400, { ok: false, reason: 'ACAO_DESCONHECIDA' });
});
