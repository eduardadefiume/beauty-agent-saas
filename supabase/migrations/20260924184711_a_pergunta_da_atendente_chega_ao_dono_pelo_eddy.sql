-- A PERGUNTA DA ATENDENTE CHEGA AO DONO PELO EDDY.
--
-- 24/09/2026, teste com clientes-robo. A cliente gravida perguntou se pode
-- fazer hidratacao. A atendente fez o certo -- nao sabia e perguntou ao dono
-- (ASK_OWNER) -- e o resto deu errado:
--
--   1. A pergunta foi DESCARTADA: so cabe uma pendente por conversa, e ja
--      havia outra (on conflict do nothing).
--   2. O dono nunca soube: a pergunta mora numa tabela que so a tela le. O
--      dono esta no WhatsApp, com o Eddy.
--   3. (no codigo da atendente) a cliente ficou em silencio total.
--
-- Aqui: pergunta nova numa conversa com pergunta aberta SOMA; toda pergunta
-- nova ou somada vai para a conversa do dono, pelo numero do salao, com um
-- codigo curto; e o Eddy ganha como ler as pendentes e gravar a resposta. A
-- volta para a cliente ja existia (list_conversations_awaiting_agent,
-- gatilho RESPOSTA_DO_DONO).
--
-- LIMITE CONHECIDO: o aviso e mensagem livre, entao so sai se o dono falou com
-- o numero do salao nas ultimas 24h. Fora disso fica no painel (como antes)
-- ate existir modelo aprovado pela Meta para o aviso.

alter table app.agent_owner_questions
  add column if not exists codigo text,
  add column if not exists avisado_em timestamptz,
  add column if not exists aviso_falhou text;

create or replace function app.record_owner_question(
  p_tenant_id uuid, p_conversation_id uuid, p_message_id uuid,
  p_question text, p_context_summary text default null
)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_id uuid;
  v_q text := left(trim(coalesce(p_question, '')), 500);
begin
  if length(v_q) < 3 then
    return jsonb_build_object('ok', false, 'reason', 'EMPTY_QUESTION');
  end if;

  -- Ja ha uma aberta nesta conversa: a nova SOMA a ela (e o dono e avisado de
  -- novo). Antes era descartada em silencio.
  update app.agent_owner_questions q
     set question = left(q.question || E'\n' || v_q, 1500),
         context_summary = coalesce(left(p_context_summary, 1000), q.context_summary),
         avisado_em = null,
         aviso_falhou = null
   where q.tenant_id = p_tenant_id and q.conversation_id = p_conversation_id
     and q.status = 'PENDING'
     and position(v_q in q.question) = 0
  returning q.id into v_id;
  if v_id is not null then
    return jsonb_build_object('ok', true, 'somada', true, 'questionId', v_id);
  end if;
  if exists (select 1 from app.agent_owner_questions q
              where q.tenant_id = p_tenant_id and q.conversation_id = p_conversation_id
                and q.status = 'PENDING') then
    return jsonb_build_object('ok', true, 'duplicate', true);
  end if;

  insert into app.agent_owner_questions (
    tenant_id, conversation_id, triggering_message_id, question, context_summary, codigo
  ) values (
    p_tenant_id, p_conversation_id, p_message_id, v_q, left(p_context_summary, 1000),
    upper(substr(md5(gen_random_uuid()::text), 1, 4))
  )
  returning id into v_id;
  return jsonb_build_object('ok', true, 'duplicate', false, 'questionId', v_id);
end;
$function$;

revoke all on function app.record_owner_question(uuid, uuid, uuid, text, text) from public, anon, authenticated;

create or replace function app.avisar_dono_da_pergunta()
returns trigger
language plpgsql
security definer
set search_path to ''
as $fn$
declare
  v_conversa uuid;
  v_cliente text;
  v_texto text;
  v_r jsonb;
begin
  if new.status <> 'PENDING' or new.avisado_em is not null then
    return null;
  end if;

  -- A conversa do dono com o numero do salao: e ali que o Eddy fala com ele.
  select c.id into v_conversa
    from app.crm_conversations c
    join app.owner_whatsapp o
      on o.tenant_id = c.tenant_id and o.status = 'ACTIVE'
     and right(regexp_replace(o.phone_digits, '[^0-9]', '', 'g'), 8)
         = right(regexp_replace(coalesce(c.external_conversation_ref, ''), '[^0-9]', '', 'g'), 8)
   where c.tenant_id = new.tenant_id
   order by c.last_inbound_at desc nulls last
   limit 1;

  if v_conversa is null then
    update app.agent_owner_questions set aviso_falhou = 'DONO_SEM_CONVERSA' where id = new.id;
    return null;
  end if;

  select coalesce(nullif(trim(p.preferred_name), ''), nullif(trim(ct.display_name), ''),
                  'final ' || right(c.external_conversation_ref, 4))
    into v_cliente
    from app.crm_conversations c
    join app.crm_contacts ct on ct.id = c.contact_id
    left join app.client_profiles p on p.tenant_id = c.tenant_id and p.contact_id = c.contact_id
   where c.id = new.conversation_id;

  v_texto := 'A atendente precisa de você. Cliente: ' || coalesce(v_cliente, '?') || E'\n\n'
          || new.question || E'\n\n'
          || 'Me responde aqui que eu passo para ela. (#' || coalesce(new.codigo, '?') || ')';

  v_r := app.enqueue_outbound_message(
    new.tenant_id, v_conversa, v_texto, 'SYSTEM'::app.outbound_actor,
    'pergunta:' || new.id::text || ':' || left(md5(new.question), 8),
    null, null, null, null);

  if coalesce((v_r->>'ok')::boolean, false) then
    update app.agent_owner_questions set avisado_em = statement_timestamp(), aviso_falhou = null
     where id = new.id;
  else
    update app.agent_owner_questions set aviso_falhou = coalesce(v_r->>'reason', 'ERRO')
     where id = new.id;
  end if;
  return null;
end;
$fn$;

revoke all on function app.avisar_dono_da_pergunta() from public, anon, authenticated;

drop trigger if exists agent_owner_questions_avisa_o_dono on app.agent_owner_questions;
create trigger agent_owner_questions_avisa_o_dono
  after insert or update of question on app.agent_owner_questions
  for each row execute function app.avisar_dono_da_pergunta();

-- O que o Eddy le: as perguntas abertas do salao dele.
create or replace function app.eddy_perguntas_pendentes(p_tenant_id uuid)
returns jsonb
language sql
stable
security definer
set search_path to ''
as $fn$
  select coalesce(jsonb_agg(jsonb_build_object(
           'codigo', q.codigo,
           'cliente', coalesce(nullif(trim(p.preferred_name), ''), nullif(trim(ct.display_name), ''),
                               'final ' || right(c.external_conversation_ref, 4)),
           'pergunta', q.question,
           'contexto', q.context_summary,
           'ha', to_char(statement_timestamp() - q.created_at, 'HH24"h"MI"min"'))
         order by q.created_at), '[]'::jsonb)
    from app.agent_owner_questions q
    join app.crm_conversations c on c.id = q.conversation_id
    join app.crm_contacts ct on ct.id = c.contact_id
    left join app.client_profiles p on p.tenant_id = c.tenant_id and p.contact_id = c.contact_id
   where q.tenant_id = p_tenant_id and q.status = 'PENDING';
$fn$;

revoke all on function app.eddy_perguntas_pendentes(uuid) from public, anon, authenticated;

create or replace function public.eddy_perguntas_pendentes(p_tenant_id uuid)
returns jsonb language sql stable security definer set search_path to ''
as $$ select app.eddy_perguntas_pendentes(p_tenant_id); $$;

revoke all on function public.eddy_perguntas_pendentes(uuid) from public, anon, authenticated;
grant execute on function public.eddy_perguntas_pendentes(uuid) to service_role;

-- O que o Eddy grava: a resposta do dono, pelo codigo.
create or replace function app.eddy_responder_pergunta(p_tenant_id uuid, p_codigo text, p_resposta text)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $fn$
declare
  v_id uuid;
begin
  if coalesce(trim(p_resposta), '') = '' then
    return jsonb_build_object('ok', false, 'reason', 'RESPOSTA_VAZIA');
  end if;

  update app.agent_owner_questions q
     set status = 'ANSWERED',
         answer = left(trim(p_resposta), 2000),
         answered_by_email = 'eddy@whatsapp',
         answered_at = statement_timestamp()
   where q.tenant_id = p_tenant_id and q.status = 'PENDING'
     and upper(q.codigo) = upper(trim(both '#' from trim(coalesce(p_codigo, ''))))
  returning q.id into v_id;

  if v_id is null then
    return jsonb_build_object('ok', false, 'reason', 'PERGUNTA_NAO_ESTA_ABERTA');
  end if;
  return jsonb_build_object('ok', true, 'questionId', v_id);
end;
$fn$;

revoke all on function app.eddy_responder_pergunta(uuid, text, text) from public, anon, authenticated;

create or replace function public.eddy_responder_pergunta(p_tenant_id uuid, p_codigo text, p_resposta text)
returns jsonb language sql security definer set search_path to ''
as $$ select app.eddy_responder_pergunta(p_tenant_id, p_codigo, p_resposta); $$;

revoke all on function public.eddy_responder_pergunta(uuid, text, text) from public, anon, authenticated;
grant execute on function public.eddy_responder_pergunta(uuid, text, text) to service_role;

insert into app.agent_prompt_blocks (code, title, body, position, status, agent)
select 'EDDY_PERGUNTAS_DA_ATENDENTE', 'Perguntas da atendente',
$txt$PERGUNTAS DA ATENDENTE
Quando a atendente não sabe responder uma cliente, a pergunta chega para o dono nesta conversa, com um código no fim (#AB12). Você recebe a lista das que estão abertas.

Se a mensagem dele responde uma delas, grave com `responder_pergunta_da_atendente`, com o código e a resposta nas palavras dele. A atendente volta para a cliente sozinha. Diga a ele em uma linha que passou ("Passei para a Paula: pode hidratação sim").

Se houver mais de uma aberta e você não tiver certeza de qual ele respondeu, pergunte qual. Não chute: a resposta vai para uma cliente de verdade.

Se a resposta dele for uma regra que vale para todas ("grávida pode hidratação, só não química"), grave a resposta E crie a regra com `criar_regra`, para a atendente não perguntar de novo.

Isso tem prioridade sobre o cadastro: tem uma cliente esperando.$txt$,
52, 'ACTIVE', 'DONO'
where not exists (
  select 1 from app.agent_prompt_blocks where agent = 'DONO' and code = 'EDDY_PERGUNTAS_DA_ATENDENTE'
);

-- A atendente: pergunta ao dono e so pergunta; o que ela nao sabe do salao
-- nao se inventa. (No teste: "temos estacionamento na rua sim" -- ninguem
-- nunca disse isso; e ownerQuestion cheio de resumo em vez de pergunta.)
update app.agent_prompt_blocks
   set body = body || E'\n\nFATO DO SALÃO QUE NÃO ESTÁ NOS SEUS DADOS (estacionamento, wi-fi, acessibilidade, se pode levar criança ou acompanhante, se tem café): você NÃO SABE. Nunca responda "sim" ou "não" por dedução. Diga que vai confirmar e mande a pergunta em ownerQuestion junto com o REPLY.',
       updated_at = statement_timestamp()
 where agent = 'CLIENTE' and code = 'NUNCA_INVENTE' and status = 'ACTIVE'
   and position('FATO DO SALÃO' in body) = 0;

update app.agent_prompt_blocks
   set body = replace(body,
         'QUANDO USAR ASK_OWNER (e não mandar nada para a cliente)',
         'QUANDO USAR ASK_OWNER (a cliente recebe sozinha um "vou confirmar e já te respondo"; você não escreve nada para ela)')
       || E'\n\n`ownerQuestion` é uma PERGUNTA que o dono responde, e mais nada. Resumo do atendimento, "cliente nova quer X", o que você já explicou: nada disso é pergunta e não vai ali. Sem pergunta de verdade, deixe vazio.',
       updated_at = statement_timestamp()
 where agent = 'CLIENTE' and code = 'ASK_OWNER_QUANDO' and status = 'ACTIVE'
   and position('é uma PERGUNTA que o dono responde' in body) = 0;
