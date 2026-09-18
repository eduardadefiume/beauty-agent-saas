create table if not exists app.agent_usage (
  id                uuid primary key default gen_random_uuid(),
  tenant_id         uuid not null references app.tenants(id) on delete cascade,
  conversation_id   uuid,
  modelo            text not null,
  esforco           text,
  voltas            integer not null default 1,
  input_tokens              integer not null default 0,
  output_tokens             integer not null default 0,
  cache_write_tokens        integer not null default 0,
  cache_read_tokens         integer not null default 0,
  custo_microdolares        bigint  not null default 0,
  desfecho          text,
  occurred_at       timestamptz not null default statement_timestamp()
);

create index if not exists agent_usage_por_salao_idx
  on app.agent_usage (tenant_id, occurred_at desc);

comment on table app.agent_usage is
  'O custo de cada resposta do agente, em microdolares. Existe porque preco de assinatura decidido sem medir e chute.';
comment on column app.agent_usage.custo_microdolares is
  'Custo total do turno em milionesimos de dolar, calculado com a tabela de precos vigente na hora do registro.';

-- A tabela de precos fica no banco, e nao no codigo da funcao: quando a
-- Anthropic mexer no preco, corrigir uma linha aqui reprecifica o historico
-- inteiro sem redeploy.
create table if not exists app.model_prices (
  modelo              text primary key,
  input_por_mtok      numeric(10,4) not null,
  output_por_mtok     numeric(10,4) not null,
  cache_write_por_mtok numeric(10,4) not null,
  cache_read_por_mtok numeric(10,4) not null,
  atualizado_em       timestamptz not null default statement_timestamp()
);

-- Precos de tabela da Anthropic. Escrita de cache com TTL de 1h custa 2x o
-- input; leitura custa 0,1x.
insert into app.model_prices (modelo, input_por_mtok, output_por_mtok, cache_write_por_mtok, cache_read_por_mtok)
values
  ('claude-sonnet-5', 2.00, 10.00, 4.00, 0.20),
  ('claude-haiku-4-5', 1.00, 5.00, 2.00, 0.10),
  ('claude-opus-5', 5.00, 25.00, 10.00, 0.50)
on conflict (modelo) do update
  set input_por_mtok = excluded.input_por_mtok,
      output_por_mtok = excluded.output_por_mtok,
      cache_write_por_mtok = excluded.cache_write_por_mtok,
      cache_read_por_mtok = excluded.cache_read_por_mtok,
      atualizado_em = statement_timestamp();

create or replace function public.agent_record_usage(
  p_tenant_id       uuid,
  p_conversation_id uuid,
  p_modelo          text,
  p_esforco         text,
  p_voltas          integer,
  p_input           integer,
  p_output          integer,
  p_cache_write     integer,
  p_cache_read      integer,
  p_desfecho        text
)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_p app.model_prices%rowtype;
  v_micro bigint;
begin
  select * into v_p from app.model_prices where modelo = p_modelo;

  -- Modelo sem preco cadastrado nao pode virar custo zero em silencio: o turno
  -- e gravado assim mesmo, e o zero fica visivel como "falta cadastrar".
  v_micro := case when v_p.modelo is null then 0 else round(
      coalesce(p_input,0)       * v_p.input_por_mtok
    + coalesce(p_output,0)      * v_p.output_por_mtok
    + coalesce(p_cache_write,0) * v_p.cache_write_por_mtok
    + coalesce(p_cache_read,0)  * v_p.cache_read_por_mtok
  ) end;

  insert into app.agent_usage
    (tenant_id, conversation_id, modelo, esforco, voltas,
     input_tokens, output_tokens, cache_write_tokens, cache_read_tokens,
     custo_microdolares, desfecho)
  values
    (p_tenant_id, p_conversation_id, p_modelo, p_esforco, greatest(coalesce(p_voltas,1),1),
     coalesce(p_input,0), coalesce(p_output,0), coalesce(p_cache_write,0), coalesce(p_cache_read,0),
     v_micro, p_desfecho);

  return jsonb_build_object('ok', true, 'microdolares', v_micro,
                            'semPreco', v_p.modelo is null);
end;
$function$;

revoke all on function public.agent_record_usage(uuid,uuid,text,text,integer,integer,integer,integer,integer,text)
  from public, anon, authenticated;
grant execute on function public.agent_record_usage(uuid,uuid,text,text,integer,integer,integer,integer,integer,text)
  to service_role;

-- O que a Duda precisa ver: quanto custou cada salao, e onde o dinheiro foi.
create or replace function public.site_agent_cost(
  target_site_project_id text,
  target_email           text,
  target_tenant_id       uuid,
  target_dias            integer default 30
)
returns jsonb
language plpgsql
stable
security definer
set search_path to ''
as $function$
declare
  v_desde timestamptz := statement_timestamp() - (greatest(coalesce(target_dias,30),1) || ' days')::interval;
begin
  perform private.require_site_tenant(
    target_site_project_id, target_email, target_tenant_id,
    array['OWNER']::app.tenant_role[]
  );

  return jsonb_build_object(
    'resumo', (
      select jsonb_build_object(
        'turnos', count(*),
        'conversas', count(distinct conversation_id),
        'dolares', round(coalesce(sum(custo_microdolares),0) / 1000000.0, 4),
        'porTurno', case when count(*) = 0 then 0
                    else round(coalesce(sum(custo_microdolares),0) / 1000000.0 / count(*), 5) end,
        'porConversa', case when count(distinct conversation_id) = 0 then 0
                      else round(coalesce(sum(custo_microdolares),0) / 1000000.0
                                 / count(distinct conversation_id), 5) end,
        'voltaMedia', round(coalesce(avg(voltas),0), 2))
        from app.agent_usage
       where tenant_id = target_tenant_id and occurred_at >= v_desde
    ),
    -- Onde o dinheiro foi. Sem isso o total nao diz o que fazer com ele.
    'ondeFoi', (
      select jsonb_build_object(
        'escritaDeCache', round(coalesce(sum(cache_write_tokens * p.cache_write_por_mtok),0)/1000000.0, 4),
        'leituraDeCache', round(coalesce(sum(cache_read_tokens  * p.cache_read_por_mtok),0)/1000000.0, 4),
        'entradaSemCache', round(coalesce(sum(input_tokens      * p.input_por_mtok),0)/1000000.0, 4),
        'saida',          round(coalesce(sum(output_tokens     * p.output_por_mtok),0)/1000000.0, 4))
        from app.agent_usage u join app.model_prices p on p.modelo = u.modelo
       where u.tenant_id = target_tenant_id and u.occurred_at >= v_desde
    ),
    'porDia', coalesce((
      select jsonb_agg(jsonb_build_object(
               'dia', d, 'turnos', n,
               'dolares', round(micro/1000000.0, 4)) order by d desc)
        from (select date_trunc('day', occurred_at)::date d, count(*) n,
                     sum(custo_microdolares) micro
                from app.agent_usage
               where tenant_id = target_tenant_id and occurred_at >= v_desde
               group by 1) x
    ), '[]'::jsonb)
  );
end;
$function$;

grant execute on function public.site_agent_cost(text, text, uuid, integer) to service_role;