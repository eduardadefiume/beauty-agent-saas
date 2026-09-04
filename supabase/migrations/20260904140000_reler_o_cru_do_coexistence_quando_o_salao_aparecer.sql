-- RELER O QUE CHEGOU ANTES DO SALÃO EXISTIR AQUI
--
-- `ingest_whatsapp_coexistence` guarda o payload cru ANTES de tentar entender.
-- Quando a Meta manda o histórico de um WABA que ainda não tem salão cadastrado
-- em `channel_connections`, a entrega fica gravada inteira, com
-- `parse_error = 'WABA_SEM_SALAO_CADASTRADO'`, e a Meta recebe 200.
--
-- Isso já evitava perder o histórico. Mas guardar sem poder reler é meio
-- caminho: os 180 dias ficariam ali como JSON e ninguém veria conversa nenhuma
-- na tela. Esta função é a outra metade -- ela relê o que está guardado assim
-- que o salão passa a existir.
--
-- Serve para os dois casos que vão acontecer de verdade: o número real ser
-- conectado antes de eu registrar a conexão aqui, e um erro meu de leitura ser
-- corrigido depois com o dado ainda intacto.

create or replace function public.coexistence_reprocessar(p_limite integer default 200)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_d      record;
  v_tenant uuid;
  v_r      jsonb;
  v_lidas  integer := 0;
  v_ainda  integer := 0;
begin
  for v_d in
    select d.id, d.waba_id, d.phone_number_id, d.field, d.value
      from app.wa_coexistence_deliveries d
     where d.parsed_at is null
       and d.parse_error is distinct from 'ECO_GUARDADO_SEM_INTERPRETAR'
     order by d.received_at
     limit greatest(p_limite, 1)
  loop
    select c.tenant_id into v_tenant
      from app.channel_connections c
     where c.channel = 'WHATSAPP'
       and (c.external_account_id = v_d.waba_id
            or (coalesce(v_d.phone_number_id, '') <> ''
                and c.external_sender_id = v_d.phone_number_id))
     limit 1;

    if v_tenant is null then
      v_ainda := v_ainda + 1;
      continue;
    end if;

    begin
      if v_d.field = 'history' then
        v_r := app.coexistence_absorb_history(v_tenant, v_d.value);
        update app.wa_coexistence_deliveries d
           set tenant_id = v_tenant, parsed_at = statement_timestamp(), parse_error = null,
               mensagens_lidas = coalesce((v_r->>'mensagens')::integer, 0)
         where d.id = v_d.id;
      elsif v_d.field = 'smb_app_state_sync' then
        v_r := app.coexistence_absorb_contacts(v_tenant, v_d.value);
        update app.wa_coexistence_deliveries d
           set tenant_id = v_tenant, parsed_at = statement_timestamp(), parse_error = null,
               contatos_lidos = coalesce((v_r->>'novos')::integer, 0)
                              + coalesce((v_r->>'renomeados')::integer, 0)
         where d.id = v_d.id;
      else
        continue;
      end if;
      v_lidas := v_lidas + 1;
    exception when others then
      update app.wa_coexistence_deliveries d
         set parse_error = left(sqlerrm, 500) where d.id = v_d.id;
    end;
  end loop;

  return jsonb_build_object('ok', true, 'relidas', v_lidas, 'aindaSemSalao', v_ainda);
end;
$function$;

revoke all on function public.coexistence_reprocessar(integer) from public, anon, authenticated;
grant execute on function public.coexistence_reprocessar(integer) to service_role;
