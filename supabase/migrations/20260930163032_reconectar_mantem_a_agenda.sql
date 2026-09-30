-- RECONECTAR O GOOGLE NAO TROCA A AGENDA ESCOLHIDA.
--
-- 30/09/2026, teste "token vencido": o dono reconecta pelo link do Eddy e a
-- conexao voltava a apontar para a agenda PRINCIPAL da conta, perdendo a
-- agenda que ele tinha escolhido (ex.: "Salao"). Agora a reconexao so troca
-- as chaves; a agenda fica (se for a mesma conta Google).
-- Usa o convite: grava a conexao (tokens cifrados) e queima o codigo. Tudo
-- na mesma transacao -- o `for update` impede dois usos do mesmo link.
create or replace function app.agenda_usar_convite(
  p_codigo        text,
  p_conta_google  text,
  p_access_token  text,
  p_refresh_token text,
  p_expira_em     timestamptz,
  p_scope         text
)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $fn$
declare
  v_convite record;
  v_unit_id uuid;
  v_id      uuid;
begin
  select * into v_convite from app.google_agenda_convites c where c.codigo = p_codigo for update;
  if not found then
    return jsonb_build_object('ok', false, 'motivo', 'NAO_EXISTE');
  end if;
  if v_convite.usado_em is not null then
    return jsonb_build_object('ok', false, 'motivo', 'JA_USADO');
  end if;
  if v_convite.expira_em < statement_timestamp() then
    return jsonb_build_object('ok', false, 'motivo', 'EXPIRADO');
  end if;
  if p_access_token is null or length(p_access_token) = 0 then
    return jsonb_build_object('ok', false, 'motivo', 'SEM_TOKEN');
  end if;

  select u.id into v_unit_id from app.units u where u.tenant_id = v_convite.tenant_id limit 1;
  if v_unit_id is null then
    return jsonb_build_object('ok', false, 'motivo', 'SALAO_SEM_UNIDADE');
  end if;

  insert into app.calendar_connections (
    tenant_id, unit_id, member_name, provider, external_account_email, calendar_id,
    access_token, refresh_token, token_expires_at, scope, status, last_error, tokens_encrypted
  ) values (
    v_convite.tenant_id, v_unit_id, v_convite.member_name, 'GOOGLE', p_conta_google, 'primary',
    private.encrypt_calendar_token(p_access_token),
    private.encrypt_calendar_token(p_refresh_token),
    p_expira_em, p_scope, 'ACTIVE', null, true
  )
  on conflict (tenant_id, unit_id, provider, member_name) do update
    set external_account_email = excluded.external_account_email,
        -- Reconectar com a MESMA conta mantem a agenda escolhida (30/09: a
        -- reconexao trocava "Salao" pela principal). Conta diferente: a
        -- agenda antiga nao existe nela, entao vai para a principal.
        calendar_id = case
          when app.calendar_connections.external_account_email is not distinct from excluded.external_account_email
            then coalesce(app.calendar_connections.calendar_id, excluded.calendar_id)
          else excluded.calendar_id end,
        access_token = excluded.access_token,
        refresh_token = coalesce(excluded.refresh_token, app.calendar_connections.refresh_token),
        token_expires_at = excluded.token_expires_at,
        scope = excluded.scope,
        status = 'ACTIVE',
        last_error = null,
        tokens_encrypted = true,
        dono_avisado_em = null,
        updated_at = statement_timestamp()
  returning id into v_id;

  update app.google_agenda_convites
     set usado_em = statement_timestamp(), connection_id = v_id, conta_google = p_conta_google
   where id = v_convite.id;

  return jsonb_build_object('ok', true, 'connectionId', v_id, 'tenantId', v_convite.tenant_id,
                            'memberName', v_convite.member_name);
end;
$fn$;