// whatsapp-sender — consome a fila de saida e entrega na Cloud API da Meta.
//
// Roda como worker: cada invocacao reserva um lote de mensagens PENDING, tenta
// entregar cada uma e registra o desfecho. Nao decide nada de negocio — a
// validacao da janela de 24h e a idempotencia ja aconteceram no enfileiramento,
// dentro do banco.
//
// Por que reservar antes de enviar: claim_outbox_batch marca SENDING numa
// transacao propria, com FOR UPDATE SKIP LOCKED. Duas invocacoes simultaneas
// pegam lotes disjuntos, entao a mesma mensagem nunca sai duas vezes.

import 'jsr:@supabase/functions-js/edge-runtime.d.ts';

// As RPCs sao chamadas pelo nome simples, sem Content-Profile: o PostgREST
// deste projeto expoe apenas public e graphql_public. A logica vive em app e
// public guarda fachadas finas -- mesmo padrao de public.ingest_whatsapp_webhook.
const GRAPH_VERSION = 'v21.0';

type Reservada = {
  id: string;
  tenant_id: string;
  sender_id: string | null;
  recipient_address: string;
  kind: string;
  body_text: string | null;
  attempts: number;
  media_storage_path: string | null;
  media_mime_type: string | null;
  media_filename: string | null;
  media_provider_id: string | null;
};

// A Meta agrupa midia em quatro tipos e cada um tem um campo proprio no corpo
// da mensagem. O tipo sai do MIME, e nao da extensao do arquivo: extensao e
// palpite de quem nomeou, MIME e o que o navegador mediu.
function tipoDaMidia(mime: string): 'image' | 'video' | 'audio' | 'document' {
  if (mime.startsWith('image/')) return 'image';
  if (mime.startsWith('video/')) return 'video';
  if (mime.startsWith('audio/')) return 'audio';
  return 'document';
}

// Baixa do balde privado com a chave de servico e sobe para a Meta.
//
// Nao mandamos por URL publica -- que a Meta aceita e seria mais simples --
// porque isso exporia a foto de uma cliente, nem que por minutos, e URL que ja
// foi publica nao volta a ser privada.
async function subirMidiaParaMeta(
  supabaseUrl: string,
  serviceKey: string,
  accessToken: string,
  senderId: string,
  caminho: string,
  mime: string,
  nomeArquivo: string
): Promise<string> {
  const arquivo = await fetch(
    `${supabaseUrl}/storage/v1/object/anexos/${caminho.split('/').map(encodeURIComponent).join('/')}`,
    { headers: { apikey: serviceKey, Authorization: `Bearer ${serviceKey}` } }
  );
  if (!arquivo.ok) {
    throw new Error(`balde ${arquivo.status} ao baixar ${caminho}`);
  }
  const bytes = await arquivo.blob();

  const formulario = new FormData();
  formulario.append('messaging_product', 'whatsapp');
  formulario.append('type', mime);
  formulario.append('file', new File([bytes], nomeArquivo, { type: mime }));

  const subida = await fetch(`https://graph.facebook.com/${GRAPH_VERSION}/${senderId}/media`, {
    method: 'POST',
    headers: { Authorization: `Bearer ${accessToken}` },
    body: formulario,
  });
  const corpo = await subida.text();
  if (!subida.ok) {
    throw new Error(`upload de midia ${subida.status}: ${corpo.slice(0, 400)}`);
  }
  const id = (JSON.parse(corpo) as { id?: string }).id;
  if (!id) throw new Error(`upload sem id: ${corpo.slice(0, 200)}`);
  return id;
}

function json(status: number, body: unknown): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'content-type': 'application/json; charset=utf-8' },
  });
}

async function rpc(url: string, key: string, fn: string, args: unknown): Promise<unknown> {
  const resposta = await fetch(`${url}/rest/v1/rpc/${fn}`, {
    method: 'POST',
    headers: {
      apikey: key,
      Authorization: `Bearer ${key}`,
      'content-type': 'application/json',
    },
    body: JSON.stringify(args),
  });
  if (!resposta.ok) {
    throw new Error(`RPC ${fn} falhou: ${resposta.status} ${await resposta.text()}`);
  }
  return await resposta.json();
}

// Segundo fator, alem do verify_jwt.
//
// verify_jwt so garante que o token e assinado por este projeto -- e a chave
// anon satisfaz isso e e publica, embutida no JavaScript do site. Sem este
// cheque, qualquer visitante poderia disparar o worker. O token vive no Vault:
// quem chama e quem confere leem da mesma fonte, e ele nunca precisa passar
// pela mao de ninguem.
async function autorizado(req: Request, url: string, key: string): Promise<boolean> {
  const token = req.headers.get('x-worker-token');
  if (!token) return false;
  try {
    return (await rpc(url, key, 'verify_worker_token', { p_token: token })) === true;
  } catch (erro) {
    console.error(JSON.stringify({ event: 'worker_token_check_failed', erro: String(erro) }));
    return false;
  }
}

Deno.serve(async (req) => {
  const supabaseUrl = Deno.env.get('SUPABASE_URL');
  const serviceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
  const accessToken = Deno.env.get('WHATSAPP_ACCESS_TOKEN');

  if (!supabaseUrl || !serviceKey) {
    return json(500, { ok: false, reason: 'SUPABASE_ENV_MISSING' });
  }
  if (!(await autorizado(req, supabaseUrl, serviceKey))) {
    return json(401, { ok: false, reason: 'WORKER_TOKEN_INVALID' });
  }
  if (!accessToken) {
    // Sem token nao ha o que tentar. Devolve cedo em vez de reservar mensagens
    // e falhar todas, o que so gastaria tentativas do recuo exponencial.
    return json(500, { ok: false, reason: 'WHATSAPP_ACCESS_TOKEN_MISSING' });
  }

  let reservadas: Reservada[];
  try {
    reservadas = (await rpc(supabaseUrl, serviceKey, 'claim_outbox_batch', {
      p_limit: 20,
    })) as Reservada[];
  } catch (erro) {
    return json(500, { ok: false, reason: 'CLAIM_FAILED', detail: String(erro) });
  }

  if (!Array.isArray(reservadas) || reservadas.length === 0) {
    return json(200, { ok: true, reservadas: 0, enviadas: 0, falhadas: 0 });
  }

  let enviadas = 0;
  let falhadas = 0;

  for (const item of reservadas) {
    let sucesso = false;
    let providerMessageId: string | null = null;
    let erroTexto: string | null = null;

    try {
      if (!item.sender_id) {
        throw new Error('conexao sem external_sender_id — canal nao configurado');
      }
      if (item.kind !== 'TEXT' && item.kind !== 'MEDIA') {
        throw new Error(`tipo ${item.kind} ainda nao suportado pelo worker`);
      }

      // Monta o corpo. Texto e um caso; midia sao quatro, e todos seguem a
      // mesma forma: { type: <tipo>, <tipo>: { id, caption? } }.
      let corpoDaMensagem: Record<string, unknown>;

      if (item.kind === 'TEXT') {
        corpoDaMensagem = {
          type: 'text',
          text: { preview_url: false, body: item.body_text ?? '' },
        };
      } else {
        if (!item.media_storage_path || !item.media_mime_type) {
          throw new Error('mensagem de midia sem caminho ou sem MIME');
        }

        // Reaproveita o id de uma tentativa anterior. Se a primeira subiu o
        // arquivo e falhou so no envio, subir de novo seria pagar duas vezes a
        // parte lenta -- e uma mensagem tem ate cinco tentativas.
        let mediaId = item.media_provider_id;
        if (!mediaId) {
          mediaId = await subirMidiaParaMeta(
            supabaseUrl,
            serviceKey,
            accessToken,
            item.sender_id,
            item.media_storage_path,
            item.media_mime_type,
            item.media_filename ?? 'arquivo'
          );
          // Grava antes de tentar enviar: se o envio falhar agora, a proxima
          // tentativa ja encontra o id.
          await rpc(supabaseUrl, serviceKey, 'mark_outbox_media_uploaded', {
            p_outbox_id: item.id,
            p_media_provider_id: mediaId,
          });
        }

        const tipo = tipoDaMidia(item.media_mime_type);
        const conteudo: Record<string, unknown> = { id: mediaId };
        // Audio nao aceita legenda na Meta, e documento usa `filename` em vez
        // de caption para o nome. Mandar campo que o tipo nao aceita derruba a
        // mensagem inteira com erro de validacao.
        const legenda = (item.body_text ?? '').trim();
        if (legenda.length > 0 && (tipo === 'image' || tipo === 'video' || tipo === 'document')) {
          conteudo.caption = legenda;
        }
        if (tipo === 'document' && item.media_filename) {
          conteudo.filename = item.media_filename;
        }

        corpoDaMensagem = { type: tipo, [tipo]: conteudo };
      }

      const resposta = await fetch(
        `https://graph.facebook.com/${GRAPH_VERSION}/${item.sender_id}/messages`,
        {
          method: 'POST',
          headers: {
            Authorization: `Bearer ${accessToken}`,
            'content-type': 'application/json',
          },
          body: JSON.stringify({
            messaging_product: 'whatsapp',
            recipient_type: 'individual',
            to: item.recipient_address,
            ...corpoDaMensagem,
          }),
        }
      );

      const corpo = await resposta.text();
      if (!resposta.ok) {
        throw new Error(`Graph ${resposta.status}: ${corpo.slice(0, 400)}`);
      }

      const dados = JSON.parse(corpo) as { messages?: Array<{ id?: string }> };
      providerMessageId = dados.messages?.[0]?.id ?? null;
      if (!providerMessageId) {
        throw new Error(`resposta sem id de mensagem: ${corpo.slice(0, 200)}`);
      }
      sucesso = true;
    } catch (erro) {
      erroTexto = String(erro);
    }

    try {
      await rpc(supabaseUrl, serviceKey, 'mark_outbox_result', {
        p_outbox_id: item.id,
        p_success: sucesso,
        p_provider_message_id: providerMessageId,
        p_error: erroTexto,
      });
    } catch (erro) {
      // Se o registro do desfecho falhar, a mensagem fica em SENDING. E melhor
      // ficar presa e visivel do que ser reenviada as cegas.
      console.error(
        JSON.stringify({ event: 'mark_result_failed', outboxId: item.id, erro: String(erro) })
      );
    }

    if (sucesso) enviadas++;
    else falhadas++;
  }

  console.log(
    JSON.stringify({
      event: 'outbox_drained',
      reservadas: reservadas.length,
      enviadas,
      falhadas,
    })
  );

  return json(200, { ok: true, reservadas: reservadas.length, enviadas, falhadas });
});
