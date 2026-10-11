-- SALÃO VAZIO CONSEGUE CRIAR SERVIÇO.
--
-- 11/10/2026, PRODUÇÃO, S-William: o combinado é o dono chegar sem nada e o
-- Eddy cadastrar cada serviço e valor que ele disser. O salão dele tem 0
-- pessoas na equipe e 0 habilidades -- e app.onboarding_criar_servico exige
-- uma habilidade ligada a alguém da equipe. Resultado: num salão vazio o Eddy
-- NÃO CONSEGUIA criar serviço nenhum, nem querendo. Em 10/10 o William citou
-- coloração, progressiva, selante, luzes, corte e escova, e nada foi gravado.
--
-- Agora, no salão de uma pessoa só (ou sem ninguém), criar serviço prepara o
-- que falta: o dono entra como quem atende e a habilidade é criada para ele.
-- No salão com equipe, nada muda: habilidade desconhecida continua recusada
-- (o Eddy pergunta quem faz). Duração que ele não disse vira 60 min e uma
-- pendência "quanto tempo leva X?" -- o serviço é gravado na hora, não se perde.

create table if not exists app.servico_duracao_a_confirmar (
  tenant_id    uuid not null references app.tenants(id) on delete cascade,
  servico_nome text not null,
  criado_em    timestamptz not null default statement_timestamp(),
  primary key (tenant_id, servico_nome)
);

alter table app.servico_duracao_a_confirmar enable row level security;

create or replace function app.preparar_habilidade_do_servico(p_tenant_id uuid, p_habilidade text)
returns text
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_hab      text := nullif(trim(coalesce(p_habilidade, '')), '');
  v_rascunho uuid;
  v_equipe   integer;
  v_dono     text;
begin
  if v_hab is null then
    return null;
  end if;
  begin
    v_rascunho := app.start_new_draft_from_published(p_tenant_id, 'eddy@whatsapp', null);
  exception when others then
    return v_hab;
  end;
  select count(*) into v_equipe
    from app.team_members m
   where m.tenant_id = p_tenant_id and m.configuration_draft_id = v_rascunho and m.status = 'ACTIVE';
  -- Salão com mais de uma pessoa: quem faz o quê é pergunta para o dono.
  if v_equipe > 1 then
    return v_hab;
  end if;
  if v_equipe = 0 then
    select nullif(trim(o.display_name), '') into v_dono
      from app.owner_whatsapp o
     where o.tenant_id = p_tenant_id and o.status = 'ACTIVE'
     order by o.display_name nulls last
     limit 1;
    perform app.onboarding_criar_membro_equipe(p_tenant_id, coalesce(v_dono, 'Responsável'), 'PROFESSIONAL', 'IGUAL_AO_SALAO');
  end if;
  if not exists (
    select 1 from app.skills k
      join app.member_skills ms on ms.tenant_id = k.tenant_id and ms.configuration_draft_id = k.configuration_draft_id and ms.skill_id = k.id
     where k.tenant_id = p_tenant_id and k.configuration_draft_id = v_rascunho
       and k.status = 'ACTIVE' and lower(k.name) = lower(v_hab)
  ) then
    perform app.onboarding_criar_habilidade(p_tenant_id, v_hab, null);
  end if;
  return v_hab;
end;
$function$;

-- Duas costuras em onboarding_criar_servico, por âncora (como 20260924144025).
do $do$
declare
  v_def  text := pg_get_functiondef('app.onboarding_criar_servico(uuid, text, text, integer, numeric)'::regprocedure);
  v_novo text := v_def;
  v_ant  text;
begin
  if position('preparar_habilidade_do_servico' in v_def) > 0 then
    return;
  end if;

  -- 1. Antes de recusar por habilidade: no salão de uma pessoa, prepara.
  v_ant := v_novo;
  v_novo := regexp_replace(v_novo, 'if\s+v_hab\s+is\s+null\s+then',
    E'v_hab := coalesce(app.preparar_habilidade_do_servico(p_tenant_id, coalesce(v_hab, v_nome)), v_hab);\n  if v_hab is null then');
  if v_novo = v_ant then raise exception 'ancora da habilidade sumiu'; end if;

  -- 2. Duração não dita não impede de gravar: 60 min e pendência.
  v_ant := v_novo;
  v_novo := regexp_replace(v_novo, 'if\s+p_duracao_min\s+is\s+null\s+or\s+p_duracao_min\s+<\s+5',
    'if p_duracao_min < 5');
  if v_novo = v_ant then raise exception 'ancora da duracao sumiu'; end if;
  v_ant := v_novo;
  v_novo := regexp_replace(v_novo, 'p_duracao_min,\s*p_duracao_min,\s*p_duracao_min,',
    'coalesce(p_duracao_min, 60), coalesce(p_duracao_min, 60), coalesce(p_duracao_min, 60),');
  if v_novo = v_ant then raise exception 'ancora dos minutos sumiu'; end if;
  v_ant := v_novo;
  v_novo := regexp_replace(v_novo, 'returning\s+id\s+into\s+v_servico;',
    E'returning id into v_servico;\n\n  if p_duracao_min is null then\n    insert into app.servico_duracao_a_confirmar (tenant_id, servico_nome)\n    values (p_tenant_id, v_nome) on conflict do nothing;\n  end if;');
  if v_novo = v_ant then raise exception 'ancora do servico criado sumiu'; end if;

  execute v_novo;
end;
$do$;

-- A pendência da duração: some quando ele responde (eddy_definir_duracao
-- muda os minutos) ou quando a resposta é registrada pela chave.
do $do$
declare
  v_def  text := pg_get_functiondef('app.onboarding_pendencies(uuid)'::regprocedure);
  v_novo text;
begin
  if position('SERVICO_DURACAO:' in v_def) > 0 then
    return;
  end if;
  v_novo := replace(v_def, $a$  select 'SERVICOS'::text,
         'SERVICO_PRECO:'$a$, $b$  select 'SERVICOS'::text,
         'SERVICO_DURACAO:' || s.id::text,
         'Quanto tempo leva ' || s.name || '?',
         'Ele não disse a duração; a agenda está reservando 60 minutos.',
         11
    from servicos s
    join app.servico_duracao_a_confirmar q
      on q.tenant_id = p_tenant_id and lower(q.servico_nome) = lower(s.name)
   where s.minutos = 60
     and ('SERVICO_DURACAO:' || s.id::text) not in (select pendency_key from respondidas)

  union all

  select 'SERVICOS'::text,
         'SERVICO_PRECO:'$b$);
  if v_novo = v_def then
    raise exception 'ancora de onboarding_pendencies sumiu';
  end if;
  execute v_novo;
end;
$do$;

revoke all on function app.preparar_habilidade_do_servico(uuid, text) from public, anon, authenticated;
