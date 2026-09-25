-- WORKER MODELOS: CRIA E ACOMPANHA OS MODELOS DA META.
--
-- A funcao whatsapp-templates (25/09/2026) submete os modelos
-- lembrete_vespera e aviso_ao_dono na WABA de cada numero real e grava o
-- status em message_templates dos saloes daquele numero. O envio so usa
-- modelo APPROVED; a Meta aprova em minutos ou horas, entao o status e
-- relido de 30 em 30 minutos, sem ninguem precisar lembrar.

alter table app.worker_runs drop constraint if exists worker_runs_worker_check;
alter table app.worker_runs add constraint worker_runs_worker_check
  check (worker = any (array['AGENTE','ENVIO','MIDIA','TOM','HISTORICO','EDDY','MINERADOR','MODELOS']));

alter table app.worker_heartbeat drop constraint if exists worker_heartbeat_worker_check;
alter table app.worker_heartbeat add constraint worker_heartbeat_worker_check
  check (worker = any (array['AGENTE','ENVIO','MIDIA','TOM','HISTORICO','EDDY','MINERADOR','MODELOS']));

-- Um numero real por chamada; o segredo sai de credential_ref, como no envio.
create or replace function app.modelos_da_meta(p_acao text)
returns text
language plpgsql
security definer
set search_path to ''
as $fn$
declare
  v_linha record;
begin
  if p_acao not in ('criar', 'sincronizar') then
    return 'ACAO_INVALIDA';
  end if;

  select cc.external_account_id as waba,
         coalesce(nullif(substring(cc.credential_ref from '^edge-secret:(.+)$'), ''),
                  'WHATSAPP_ACCESS_TOKEN') as segredo,
         jsonb_agg(distinct cc.tenant_id) as tenants
    into v_linha
    from app.channel_connections cc
   where not coalesce(cc.simulado, false)
     and cc.channel = 'WHATSAPP'
     and cc.external_account_id is not null
   group by 1, 2
   limit 1;

  if v_linha.waba is null then
    return 'SEM_NUMERO_REAL';
  end if;

  return app.tick_worker('MODELOS', 'whatsapp-templates',
    jsonb_build_object('acao', p_acao, 'wabaId', v_linha.waba,
                       'segredo', v_linha.segredo, 'tenantIds', v_linha.tenants),
    60000);
end;
$fn$;

revoke all on function app.modelos_da_meta(text) from public, anon, authenticated;

select cron.schedule('modelos-da-meta', '*/30 * * * *', $$ select app.modelos_da_meta('sincronizar'); $$);
