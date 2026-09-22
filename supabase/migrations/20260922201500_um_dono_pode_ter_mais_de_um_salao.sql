-- UM DONO PODE TER MAIS DE UM SALAO.
--
-- 22/09/2026. `app.owner_whatsapp` nasceu com `primary key (phone_digits)`: o
-- telefone era unico no banco INTEIRO. Isso embutia uma regra de negocio que
-- ninguem decidiu -- "uma pessoa so pode ser dona de um salao" -- e ela nao e
-- verdade nem hoje: a Duda e dona do Piloto e precisa ser dona tambem do salao
-- de teste, e amanha existe o dono de duas unidades, ou a franqueada.
--
-- POR QUE A TROCA DE CHAVE, SOZINHA, SERIA UM TIRO NO PE. Quem resolvia o
-- salao a partir do numero era `app.owner_of_whatsapp(digits)`, que olhava SO
-- o telefone. Com dois salaos para o mesmo numero ela passa a achar duas
-- linhas -- e funcao `language sql` que retorna escalar devolve **a primeira,
-- em silencio**. O Eddy atenderia sobre o salao errado sem nenhum erro, sem
-- log, sem alerta. Trocar a chave sem consertar isso trocaria um limite
-- honesto por um bug mudo.
--
-- ONDE ESTAVA A RESPOSTA O TEMPO TODO: a conversa ja sabe de que salao ela e.
-- `crm_conversations.tenant_id` e preenchido pelo numero do salao que RECEBEU
-- a mensagem. Entao nao ha ambiguidade nenhuma a resolver -- havia uma
-- informacao sendo jogada fora. A partir daqui o dono e procurado DENTRO do
-- salao da conversa.

-- ---------------------------------------------------------------------------
-- 1. A CHAVE.
-- ---------------------------------------------------------------------------

alter table app.owner_whatsapp drop constraint owner_whatsapp_pkey;

alter table app.owner_whatsapp
  add constraint owner_whatsapp_pkey primary key (tenant_id, phone_digits);

comment on table app.owner_whatsapp is
  'O WhatsApp do dono, por salao. A chave e (tenant_id, phone_digits): o mesmo '
  'numero pode ser dono de mais de um salao. Quem diz de qual salao se fala e '
  'sempre a conversa, nunca o numero sozinho.';

-- ---------------------------------------------------------------------------
-- 2. A BUSCA PASSA A SER DENTRO DO SALAO.
--
-- Mesmo formato de resposta de antes, de proposito: o `eddy-agent` le
-- `dono.conhecido`, `dono.tenantId`, `dono.negocio`, `dono.nome` e
-- `dono.email`, e nao precisa mudar uma linha.
-- ---------------------------------------------------------------------------

create or replace function app.owner_of_whatsapp(p_digits text, p_tenant_id uuid)
returns jsonb
language sql
stable
security definer
set search_path to ''
as $function$
  select case when o.phone_digits is null then jsonb_build_object('conhecido', false)
              else jsonb_build_object(
                     'conhecido', true,
                     'tenantId',  o.tenant_id,
                     'negocio',   t.display_name,
                     'nome',      o.display_name,
                     'email',     o.email_normalized
                   )
         end
    from (select 1) um
    left join app.owner_whatsapp o
      on o.tenant_id = p_tenant_id
     and o.phone_digits = regexp_replace(coalesce(p_digits, ''), '[^0-9]', '', 'g')
     and o.status = 'ACTIVE'
    left join app.tenants t on t.id = o.tenant_id;
$function$;

revoke all on function app.owner_of_whatsapp(text, uuid) from public, anon, authenticated;
grant execute on function app.owner_of_whatsapp(text, uuid) to service_role;

comment on function app.owner_of_whatsapp(text, uuid) is
  'Diz se quem escreveu e o dono DAQUELE salao. Recebe o tenant porque o numero '
  'sozinho deixou de ser identificador desde 22/09/2026.';

-- ---------------------------------------------------------------------------
-- 3. O CONTEXTO DO EDDY PARA DE ADIVINHAR O SALAO.
--
-- Unica mudanca de verdade: `v_conversa.tenant_id` passa para a busca. O resto
-- do corpo e identico ao que ja rodava.
-- ---------------------------------------------------------------------------

create or replace function app.build_owner_context(
  p_conversation_id uuid,
  p_history_limit integer default 20
)
returns jsonb
language plpgsql
stable
security definer
set search_path to ''
as $function$
declare
  v_conversa  app.crm_conversations;
  v_digitos   text;
  v_dono      jsonb;
  v_historico jsonb;
begin
  select * into v_conversa from app.crm_conversations c where c.id = p_conversation_id;
  if v_conversa.id is null then
    return jsonb_build_object('ok', false, 'reason', 'CONVERSA_NAO_ENCONTRADA');
  end if;

  select ch.address_normalized into v_digitos
    from app.crm_contact_channels ch
   where ch.contact_id = v_conversa.contact_id and ch.provider = 'WHATSAPP'
   limit 1;

  -- O salao sai da conversa, nao do numero. Se a mesma pessoa for dona de tres
  -- salaos, ela e reconhecida em cada um pelo numero que ela procurou.
  v_dono := app.owner_of_whatsapp(v_digitos, v_conversa.tenant_id);

  select coalesce(jsonb_agg(x order by x->>'at'), '[]'::jsonb) into v_historico
    from (
      select jsonb_build_object(
               'at', m.occurred_at, 'direction', m.direction,
               'text', coalesce(m.body_text, ''),
               'leituraDaMidia', m.media_understanding
             ) as x
        from app.crm_messages m
       where m.conversation_id = p_conversation_id
       order by m.occurred_at desc
       limit greatest(coalesce(p_history_limit, 20), 1)
    ) ult;

  return jsonb_build_object(
    'ok', true,
    'conversationId', p_conversation_id,
    'now', statement_timestamp(),
    'today', to_char(statement_timestamp() at time zone 'America/Sao_Paulo', 'YYYY-MM-DD'),
    'dono', v_dono,
    'negocio', case when coalesce((v_dono->>'conhecido')::boolean, false)
                    then app.owner_setup_state((v_dono->>'tenantId')::uuid)
                    else null end,
    'history', v_historico
  );
end;
$function$;

-- ---------------------------------------------------------------------------
-- 4. A VERSAO ANTIGA SAI DE CENA.
--
-- Ela ficou insegura no instante em que a chave mudou, e `build_owner_context`
-- era a unica que a chamava. Deixar uma funcao que devolve "algum" salao
-- parado no banco e deixar uma armadilha armada para a proxima sessao.
-- ---------------------------------------------------------------------------

drop function if exists app.owner_of_whatsapp(text);
