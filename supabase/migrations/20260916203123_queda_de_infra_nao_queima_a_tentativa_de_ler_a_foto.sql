-- QUEDA DE INFRAESTRUTURA NÃO PODE QUEIMAR A COTA DE TENTATIVAS.
--
-- 16/09, 16:59. A cliente mandou a foto do cabelo com a legenda "Atualmente
-- ele está assim". O leitor tentou três vezes em três minutos e as três
-- bateram na mesma parede:
--
--   "Your credit balance is too low to access the Anthropic API."
--
-- `media_attempts` chegou a 3, que é o teto, e o leitor desistiu PARA SEMPRE
-- daquela foto. Quando o crédito voltou, ninguém tentou de novo: a foto ficou
-- ilegível por decisão de um contador, não por defeito da imagem.
--
-- O teto existe por um motivo bom: imagem corrompida, formato que o modelo não
-- lê, arquivo que sumiu do storage. Repetir isso mil vezes é torneira aberta.
-- Mas uma queda de crédito, um 429 ou um 500 não dizem nada sobre a imagem --
-- dizem sobre o mundo naquele minuto.
--
-- Então a tentativa só conta quando o erro é sobre a IMAGEM. Erro de
-- infraestrutura fica gravado (para aparecer no alerta) e devolve a tentativa.

create or replace function app.erro_de_infraestrutura(p_erro text)
returns boolean
language sql
immutable
as $function$
  select coalesce(p_erro, '') ~* (
    'credit balance'                       -- acabou o crédito da API
    '|rate.?limit|429'                     -- limite de chamadas
    '|overloaded|529'                      -- modelo sobrecarregado
    '|\m5[0-9][0-9]\M'                     -- 500, 502, 503 ...
    '|timeout|timed out|ETIMEDOUT'         -- a chamada não voltou
    '|ECONNRESET|ECONNREFUSED|EAI_AGAIN'   -- a rede caiu
    '|fetch failed|network error'
    '|authentication_error|invalid x-api-key'  -- a chave está errada: culpa nossa, não da imagem
  );
$function$;

comment on function app.erro_de_infraestrutura(text) is
  'O erro fala do mundo, não do arquivo. Erro assim não gasta tentativa de leitura nem conta como falha definitiva.';

-- A única mudança: `media_attempts` só sobe quando o erro é sobre a imagem.
create or replace function app.record_media_understanding(
  p_message_id   uuid,
  p_understanding text,
  p_error        text default null,
  p_kind         text default null
)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_msg     record;
  v_arte_id uuid;
  v_ficha   uuid;
  v_leu     boolean := coalesce(trim(p_understanding), '') <> '';
  v_infra   boolean := not v_leu and app.erro_de_infraestrutura(p_error);
begin
  update app.crm_messages
     set media_attempts = case when v_infra then media_attempts else media_attempts + 1 end,
         media_understanding = case
           when v_leu then left(p_understanding, 4000)
           else media_understanding end,
         media_understood_at = case
           when v_leu then statement_timestamp()
           else media_understood_at end,
         media_error = p_error
   where id = p_message_id
  returning tenant_id, conversation_id, direction, media_understanding, metadata_minimized
       into v_msg;

  if not found then
    return jsonb_build_object('ok', false, 'reason', 'MESSAGE_NOT_FOUND');
  end if;

  if p_kind = 'FOTO_DE_CABELO'
     and v_msg.direction = 'INBOUND'
     and coalesce(trim(v_msg.media_understanding), '') <> '' then

    update app.client_profiles p
       set hair_photo_seen_at = statement_timestamp(),
           updated_at         = statement_timestamp()
      from app.crm_conversations c
     where c.tenant_id = v_msg.tenant_id
       and c.id        = v_msg.conversation_id
       and p.tenant_id = v_msg.tenant_id
       and p.contact_id = c.contact_id
    returning p.id into v_ficha;
  end if;

  return jsonb_build_object(
    'ok', true,
    'tentativaDevolvida', v_infra,
    'fotoDeCabeloNaFicha', v_ficha
  );
end;
$function$;

create or replace function public.record_media_understanding(
  p_message_id uuid, p_understanding text, p_error text default null, p_kind text default null
)
returns jsonb
language sql security definer set search_path to ''
as $function$ select app.record_media_understanding(p_message_id, p_understanding, p_error, p_kind); $function$;

revoke all on function public.record_media_understanding(uuid, text, text, text) from public, anon, authenticated;
grant execute on function public.record_media_understanding(uuid, text, text, text) to service_role;

-- E as fotos que a queda de hoje deixou para trás voltam para a fila. Só as
-- que morreram por infraestrutura: imagem que o modelo não leu continua
-- desistida.
update app.crm_messages
   set media_attempts = 0
 where message_type = 'MEDIA'
   and media_understanding is null
   and media_attempts >= 3
   and app.erro_de_infraestrutura(media_error)
   and occurred_at > statement_timestamp() - interval '2 days';