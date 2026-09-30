-- NO GOOGLE, QUEM FAZ OU A FRENTE?
--
-- 30/09, Duda: no modo um só, o evento do William dizia "Quem faz: Karen".
-- "Pra outros donos pode fazer sentido, pro William não: ele sabe que se não
-- for ele será a Karen ou a assistente." Vira escolha do dono; o padrão
-- continua mostrando quem faz (é o que a maioria dos donos quer ver).
alter table app.agent_scope
  add column if not exists agenda_mostra_quem_faz boolean not null default true;

create or replace function app.agenda_valores_do_agendamento(p_appointment_id uuid)
 returns jsonb
 language sql
 stable security definer
 set search_path to ''
as $function$
  select jsonb_build_object(
    'nome', coalesce(split_part(nullif(trim(a.customer_label), ''), ' ', 1), 'Cliente'),
    'telefone', case
      when length(d.dig) >= 12 and left(d.dig, 2) = '55'
        then substr(d.dig, 3, 2) || '-' || substr(d.dig, 5, length(d.dig) - 8) || '-' || right(d.dig, 4)
      when length(d.dig) >= 10
        then substr(d.dig, 1, 2) || '-' || substr(d.dig, 3, length(d.dig) - 6) || '-' || right(d.dig, 4)
      else coalesce(nullif(d.dig, ''), '') end,
    'servico', coalesce(s.nome, 'Atendimento'),
    'valorCentavos', p.preco,
    'sinalPagoCentavos', (select dp.amount_cents from app.appointment_deposits dp
                           where dp.appointment_id = a.id and dp.status = 'CONFIRMED' limit 1),
    'profissional', case when coalesce(sc.equipe_como_um_so, false)
                              and not coalesce(sc.agenda_mostra_quem_faz, true)
                              and sc.equipe_frente is not null
                         then sc.equipe_frente else q.nomes end,
    'profissionalReal', q.nomes)
  from app.appointments a
  cross join lateral (select regexp_replace(coalesce(a.external_contact_ref, ''), '[^0-9]', '', 'g') dig) d
  left join lateral (
    select x.equipe_como_um_so, x.equipe_frente, x.agenda_mostra_quem_faz
      from app.agent_scope x where x.tenant_id = a.tenant_id limit 1) sc on true
  left join lateral (
    select sv ->> 'name' nome, sv
      from app.configuration_versions v
      cross join lateral jsonb_array_elements(coalesce(v.snapshot -> 'services', '[]'::jsonb)) sv
     where v.id = a.configuration_version_id and sv ->> 'id' = a.service_id::text
     limit 1) s on true
  left join lateral (
    select coalesce(
             case when a.variation_id is null then null else (
               select (va ->> 'price_minor')::integer
                 from jsonb_array_elements(coalesce(s.sv -> 'variations', '[]'::jsonb)) va
                where va ->> 'id' = a.variation_id::text limit 1) end,
             (s.sv ->> 'base_price_minor')::integer) preco) p on true
  left join lateral (
    select string_agg(distinct tm.name, ' e ') nomes
      from jsonb_array_elements(coalesce(a.plan -> 'steps', '[]'::jsonb)) passo
      join app.team_members tm on tm.id::text = passo ->> 'memberId') q on true
  where a.id = p_appointment_id;
$function$;

drop function if exists app.eddy_definir_modo_da_equipe(uuid, boolean, text);

create or replace function app.eddy_definir_modo_da_equipe(
  p_tenant_id uuid, p_um_so boolean, p_frente text default null, p_mostrar_quem_faz boolean default null)
 returns jsonb
 language plpgsql
 security definer
 set search_path to ''
as $function$
declare
  v_rascunho uuid;
  v_frente   text;
  v_antes    boolean;
  v_depois   boolean;
  v_n        integer := 0;
begin
  select d.id into v_rascunho from app.configuration_drafts d
   where d.tenant_id = p_tenant_id order by d.revision desc limit 1;

  if p_um_so then
    if nullif(trim(p_frente), '') is null then
      -- Sem nome: a frente e o dono.
      select tm.name into v_frente
        from app.team_members tm
        join app.owner_whatsapp o on o.tenant_id = tm.tenant_id and o.status = 'ACTIVE'
       where tm.tenant_id = p_tenant_id and tm.configuration_draft_id = v_rascunho and tm.status = 'ACTIVE'
         and app.agenda_nome_comparavel(tm.name) = app.agenda_nome_comparavel(o.display_name)
       limit 1;
    else
      select tm.name into v_frente
        from app.team_members tm
       where tm.tenant_id = p_tenant_id and tm.configuration_draft_id = v_rascunho and tm.status = 'ACTIVE'
         and app.agenda_nome_comparavel(tm.name) = app.agenda_nome_comparavel(trim(p_frente))
       limit 1;
    end if;
    if v_frente is null then
      return jsonb_build_object('ok', false, 'reason', 'FRENTE_NAO_ESTA_NA_EQUIPE',
        'equipe', (select to_jsonb(array_agg(tm.name order by tm.name)) from app.team_members tm
                    where tm.tenant_id = p_tenant_id and tm.configuration_draft_id = v_rascunho and tm.status = 'ACTIVE'));
    end if;
  end if;

  select s.agenda_mostra_quem_faz into v_antes from app.agent_scope s where s.tenant_id = p_tenant_id limit 1;

  update app.agent_scope
     set equipe_como_um_so = p_um_so,
         equipe_frente = case when p_um_so then v_frente else null end,
         agenda_mostra_quem_faz = case when not p_um_so then true
                                       else coalesce(p_mostrar_quem_faz, agenda_mostra_quem_faz) end,
         updated_at = statement_timestamp()
   where tenant_id = p_tenant_id
  returning agenda_mostra_quem_faz into v_depois;
  if not found then
    return jsonb_build_object('ok', false, 'reason', 'SALAO_SEM_ESCOPO');
  end if;

  -- O nome no Google mudou: o que já está marcado dali para frente é reescrito.
  if v_antes is distinct from v_depois then
    perform app.agenda_enfileirar(a.id) from app.appointments a
     where a.tenant_id = p_tenant_id and a.ends_at > statement_timestamp()
       and a.status in ('CONFIRMED', 'COMPLETED');
    get diagnostics v_n = row_count;
  end if;

  return jsonb_build_object('ok', true, 'umSo', p_um_so, 'frente', v_frente,
                            'googleMostraQuemFaz', v_depois,
                            'agendamentosReescritos', v_n,
                            'vale', 'na hora, sem publicar');
end;
$function$;

revoke all on function app.agenda_valores_do_agendamento(uuid) from public, anon, authenticated;
revoke all on function app.eddy_definir_modo_da_equipe(uuid, boolean, text, boolean) from public, anon, authenticated;