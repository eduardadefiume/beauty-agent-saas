-- TESTE DE MECHA: A REGRA É DE CADA SALÃO, O PADRÃO É GLOBAL.
--
-- Duda (01/10): "globalmente é feito teste e luzes no mesmo dia, então quando
-- grava luzes o teste é no mesmo dia, a não ser que a cliente queira marcar
-- só teste de mechas". O teste já está DENTRO do tempo do procedimento
-- ("se demora 5 horas é com o teste de mechas já"). Na conversa: perguntar se
-- ela quer só o teste ou o procedimento; se for o procedimento, ou se ela não
-- sabe se o cabelo aguenta, explicar que o teste mostra isso e que, passando,
-- o procedimento segue no mesmo dia; dizer os valores e seguir até fechar.
-- "Cada salão tem uma forma de falar e um padrão de regras e isso tem que ser
-- perguntado ao dono quando ele estiver configurando."
--
-- 01/10, DEV: sem isso a atendente marcou TESTE DE MECHA quando a Luana pediu
-- luzes, e ofereceu "teste às 9h e, se aprovar, as luzes na sequência".

create table if not exists app.teste_mecha_config (
  tenant_id uuid primary key references app.tenants(id),
  -- MESMO_DIA: teste no começo, dentro do tempo do procedimento (padrão global).
  -- ANTES: teste marcado à parte, dias_antes antes do procedimento.
  -- SEM_TESTE: o salão não faz teste.
  modo text not null default 'MESMO_DIA' check (modo in ('MESMO_DIA', 'ANTES', 'SEM_TESTE')),
  dias_antes integer check (dias_antes is null or dias_antes between 1 and 60),
  jeito_de_falar text,
  respondido boolean not null default false,
  atualizado_em timestamptz not null default statement_timestamp()
);
alter table app.teste_mecha_config enable row level security;
revoke all on app.teste_mecha_config from public, anon, authenticated;

-- O que vale para o salão (padrão global quando o dono ainda não respondeu).
create or replace function app.teste_mecha_resumo(p_tenant_id uuid)
returns jsonb
language sql
stable security definer
set search_path to ''
as $$
  with c as (select * from app.teste_mecha_config where tenant_id = p_tenant_id),
  teste as (
    select sv ->> 'name' nome, (sv ->> 'base_price_minor')::int preco
      from app.configuration_versions v
      cross join lateral jsonb_array_elements(coalesce(v.snapshot -> 'services', '[]'::jsonb)) sv
     where v.tenant_id = p_tenant_id
       and translate(lower(sv ->> 'name'), 'áàâãéêíóôõúç', 'aaaaeeiooouc') ~ 'teste de mecha'
     order by v.version_number desc limit 1)
  select jsonb_build_object(
    'modo', coalesce((select modo from c), 'MESMO_DIA'),
    'diasAntes', (select dias_antes from c),
    'jeitoDeFalar', (select jeito_de_falar from c),
    'respondido', coalesce((select respondido from c), false),
    'servicoDoTeste', (select nome from teste),
    'valorDoTeste', (select 'R$ ' || app.agenda_reais_curto(preco) from teste where preco is not null));
$$;
revoke all on function app.teste_mecha_resumo(uuid) from public, anon, authenticated;

-- O dono responde pelo Eddy.
create or replace function app.eddy_definir_teste_mecha(p_tenant_id uuid, p_modo text, p_dias_antes integer, p_jeito_de_falar text)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $$
declare
  v_modo text := upper(trim(coalesce(p_modo, '')));
begin
  if v_modo not in ('MESMO_DIA', 'ANTES', 'SEM_TESTE') then
    return jsonb_build_object('ok', false, 'reason', 'MODO_INVALIDO');
  end if;
  if v_modo = 'ANTES' and (p_dias_antes is null or p_dias_antes not between 1 and 60) then
    return jsonb_build_object('ok', false, 'reason', 'FALTA_QUANTOS_DIAS_ANTES');
  end if;
  insert into app.teste_mecha_config (tenant_id, modo, dias_antes, jeito_de_falar, respondido, atualizado_em)
  values (p_tenant_id, v_modo, case when v_modo = 'ANTES' then p_dias_antes end,
          nullif(trim(coalesce(p_jeito_de_falar, '')), ''), true, statement_timestamp())
  on conflict (tenant_id) do update
    set modo = excluded.modo, dias_antes = excluded.dias_antes,
        jeito_de_falar = coalesce(excluded.jeito_de_falar, app.teste_mecha_config.jeito_de_falar),
        respondido = true, atualizado_em = statement_timestamp();
  return jsonb_build_object('ok', true, 'agora', app.teste_mecha_resumo(p_tenant_id));
end;
$$;
revoke all on function app.eddy_definir_teste_mecha(uuid, text, integer, text) from public, anon, authenticated;

create or replace function public.teste_mecha_resumo(p_tenant_id uuid)
returns jsonb language sql stable security definer set search_path to ''
as $$ select app.teste_mecha_resumo(p_tenant_id); $$;
create or replace function public.eddy_definir_teste_mecha(p_tenant_id uuid, p_modo text, p_dias_antes integer, p_jeito_de_falar text)
returns jsonb language sql security definer set search_path to ''
as $$ select app.eddy_definir_teste_mecha(p_tenant_id, p_modo, p_dias_antes, p_jeito_de_falar); $$;
revoke all on function public.teste_mecha_resumo(uuid) from public, anon, authenticated;
revoke all on function public.eddy_definir_teste_mecha(uuid, text, integer, text) from public, anon, authenticated;
grant execute on function public.teste_mecha_resumo(uuid) to service_role;
grant execute on function public.eddy_definir_teste_mecha(uuid, text, integer, text) to service_role;

-- A regra global dizia "o teste é o caminho do agendamento" e a atendente
-- entendeu "marque o teste". O caminho é o procedimento, com o teste do jeito
-- do salão (bloco TESTE DE MECHA NESTE SALÃO, montado a cada turno).
update app.agent_prompt_blocks
   set body = replace(body,
         'É por isso que sem teste não tem resposta, e é por isso que o teste é o caminho do agendamento, nunca um obstáculo.',
         'É por isso que sem teste não tem resposta. O teste não é um obstáculo nem um agendamento à parte: ele vem junto do procedimento, do jeito que o salão faz (veja TESTE DE MECHA NESTE SALÃO). Marque o procedimento; só marque o teste sozinho se ela quiser só o teste.'),
       updated_at = statement_timestamp()
 where code = 'OFICIO_O_QUE_O_TESTE_RESPONDE' and agent = 'CLIENTE';
