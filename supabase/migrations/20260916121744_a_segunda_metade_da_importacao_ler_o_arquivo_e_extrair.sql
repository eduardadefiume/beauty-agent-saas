-- A SEGUNDA METADE DA IMPORTACAO: LER O ARQUIVO E EXTRAIR.
--
-- A etapa 6 importava e parava. `wa_archive_messages` recebia mensagem por
-- mensagem, e `wa_archive_findings` -- a tabela onde o aprendizado deveria
-- morar -- ficava vazia, porque NADA escrevia nela. Nenhuma funcao, nenhum
-- worker, nenhuma linha de codigo no repositorio inteiro.
--
-- Entao a resposta honesta para "voce teve acesso as conversas e nao criou
-- porque?" tem duas partes, e esta e a segunda: mesmo que as 551 conversas
-- estivessem importadas, ninguem estava lendo.
--
-- O QUE MUDA NOS TIPOS DE ACHADO. A lista tinha nove, e todos descrevem um
-- MOMENTO: a pergunta da cliente, a resposta do dono, a objecao, o preco
-- citado. Faltava justamente o tipo que custou caro esta semana -- a
-- SEQUENCIA: o que vem antes, quanto tempo depois, o que combina com o que.
-- Regra que so descreve momento deixa o modelo inventar a ordem, e foi o que
-- ele fez quando disse "progressiva primeiro" para quem queria luzes.
--
-- CADA ACHADO NASCE COM O TRECHO LITERAL. A coluna ja existia e o comentario
-- dela ja dizia o porque: "sem ele, um padrao extraido e palpite sem
-- endereco". Aqui isso vira obrigacao de quem escreve, e nao boa intencao.
--
-- E NENHUM ACHADO VIRA REGRA SOZINHO. O minerador escreve em
-- `wa_archive_findings`, que e material de leitura -- o dono confirma o que
-- vale antes de virar policy. A licao de ontem foi cara: o agente supondo
-- coisa e a cliente corrigindo.

alter table app.wa_archives
  add column if not exists mined_at      timestamptz,
  add column if not exists mine_attempts integer not null default 0,
  add column if not exists mine_error    text;

comment on column app.wa_archives.mined_at is
  'Quando a leitura de padroes terminou. Nulo quer dizer que o arquivo foi importado mas ninguem leu ainda.';

alter table app.wa_archive_findings drop constraint if exists wa_archive_findings_kind_check;
alter table app.wa_archive_findings add constraint wa_archive_findings_kind_check
  check (kind in (
    'PERGUNTA_DA_CLIENTE', 'RESPOSTA_DO_DONO', 'OBJECAO',
    'QUEBRA_DE_OBJECAO', 'EXPLICACAO_TECNICA', 'CONDUCAO_PARA_AGENDA',
    'PRECO_CITADO', 'REGRA_IMPLICITA', 'TOM_DE_VOZ',
    'SEQUENCIA'));

-- ---------------------------------------------------------------------------
-- A fila da leitura
-- ---------------------------------------------------------------------------
create or replace function app.wa_mine_claim(p_limit integer default 2)
returns table(archive_id uuid, tenant_id uuid, contact_label text, mensagens integer)
language plpgsql
security definer
set search_path to ''
as $function$
begin
  return query
  with escolhidos as (
    select a.id
      from app.wa_archives a
     where a.status = 'PRONTO'
       and a.mined_at is null
       and a.mine_attempts < 3
       and a.message_count > 0
     order by a.message_count desc, a.created_at
     limit greatest(1, least(coalesce(p_limit, 2), 5))
     for update skip locked
  ),
  marcados as (
    update app.wa_archives a
       set mine_attempts = a.mine_attempts + 1,
           updated_at = statement_timestamp()
      from escolhidos e
     where a.id = e.id
    returning a.id, a.tenant_id, a.contact_label, a.message_count
  )
  select m.id, m.tenant_id, m.contact_label, m.message_count from marcados m;
end;
$function$;

-- A conversa inteira, na ordem, com quem falou cada linha.
create or replace function app.wa_mine_conversa(
  p_archive_id uuid,
  p_limit integer default 600
)
returns jsonb
language sql
stable
security definer
set search_path to ''
as $function$
  select coalesce(jsonb_agg(jsonb_build_object('quem', t.quem, 'texto', t.texto, 'quando', t.sent_at) order by t.position), '[]'::jsonb)
    from (
      select m.position, m.quem::text, m.texto, m.sent_at
        from app.wa_archive_messages m
       where m.archive_id = p_archive_id
         and coalesce(trim(m.texto), '') <> ''
       order by m.position
       limit greatest(1, least(coalesce(p_limit, 600), 2000))
    ) t;
$function$;

-- ---------------------------------------------------------------------------
-- O que a leitura achou
--
-- `trecho` e obrigatorio aqui, e nao na tabela: achado sem endereco no
-- arquivo nao entra. Quem le a tela tem que poder conferir a frase original.
-- ---------------------------------------------------------------------------
create or replace function app.wa_mine_write(p_archive_id uuid, p_findings jsonb)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_tenant uuid;
  v_gravados integer := 0;
  v_recusados integer := 0;
  item jsonb;
begin
  select a.tenant_id into v_tenant from app.wa_archives a where a.id = p_archive_id;
  if v_tenant is null then
    return jsonb_build_object('ok', false, 'reason', 'ARQUIVO_NAO_EXISTE');
  end if;

  if jsonb_typeof(p_findings) <> 'array' then
    return jsonb_build_object('ok', false, 'reason', 'FORMATO_INVALIDO');
  end if;

  for item in select * from jsonb_array_elements(p_findings)
  loop
    if coalesce(trim(item->>'trecho'), '') = ''
       or coalesce(trim(item->>'titulo'), '') = ''
       or coalesce(trim(item->>'conteudo'), '') = '' then
      v_recusados := v_recusados + 1;
      continue;
    end if;

    begin
      insert into app.wa_archive_findings
        (tenant_id, archive_id, kind, titulo, conteudo, trecho, ocorrencias, confidence)
      values (
        v_tenant, p_archive_id, item->>'kind',
        left(trim(item->>'titulo'), 200),
        left(trim(item->>'conteudo'), 4000),
        left(trim(item->>'trecho'), 1000),
        greatest(1, coalesce((item->>'ocorrencias')::integer, 1)),
        case when item ? 'confianca' then least(1, greatest(0, (item->>'confianca')::numeric)) end
      );
      v_gravados := v_gravados + 1;
    exception when others then
      -- kind fora da lista, numero ilegivel: recusa a linha, nao o lote.
      v_recusados := v_recusados + 1;
    end;
  end loop;

  return jsonb_build_object('ok', true, 'gravados', v_gravados, 'recusados', v_recusados);
end;
$function$;

create or replace function app.wa_mine_finish(p_archive_id uuid, p_error text default null)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $function$
begin
  if p_error is not null then
    update app.wa_archives
       set mine_error = left(p_error, 500), updated_at = statement_timestamp()
     where id = p_archive_id;
    return jsonb_build_object('ok', true, 'status', 'ERRO_REGISTRADO');
  end if;

  update app.wa_archives
     set mined_at = statement_timestamp(), mine_error = null, updated_at = statement_timestamp()
   where id = p_archive_id;

  return jsonb_build_object('ok', true,
    'achados', (select count(*) from app.wa_archive_findings f where f.archive_id = p_archive_id));
end;
$function$;

-- ---------------------------------------------------------------------------
-- As portas. A licao de ontem: funcao em `app` sem porta em `public` e funcao
-- que o worker nao alcanca, e isso so aparece na primeira chamada.
-- ---------------------------------------------------------------------------
create or replace function public.wa_mine_claim(p_limit integer default 2)
returns table(archive_id uuid, tenant_id uuid, contact_label text, mensagens integer)
language sql security definer set search_path to ''
as $function$ select * from app.wa_mine_claim(p_limit); $function$;

create or replace function public.wa_mine_conversa(p_archive_id uuid, p_limit integer default 600)
returns jsonb language sql stable security definer set search_path to ''
as $function$ select app.wa_mine_conversa(p_archive_id, p_limit); $function$;

create or replace function public.wa_mine_write(p_archive_id uuid, p_findings jsonb)
returns jsonb language sql security definer set search_path to ''
as $function$ select app.wa_mine_write(p_archive_id, p_findings); $function$;

create or replace function public.wa_mine_finish(p_archive_id uuid, p_error text default null)
returns jsonb language sql security definer set search_path to ''
as $function$ select app.wa_mine_finish(p_archive_id, p_error); $function$;

revoke all on function app.wa_mine_claim(integer) from public, anon, authenticated;
revoke all on function app.wa_mine_conversa(uuid, integer) from public, anon, authenticated;
revoke all on function app.wa_mine_write(uuid, jsonb) from public, anon, authenticated;
revoke all on function app.wa_mine_finish(uuid, text) from public, anon, authenticated;
revoke all on function public.wa_mine_claim(integer) from public, anon, authenticated;
revoke all on function public.wa_mine_conversa(uuid, integer) from public, anon, authenticated;
revoke all on function public.wa_mine_write(uuid, jsonb) from public, anon, authenticated;
revoke all on function public.wa_mine_finish(uuid, text) from public, anon, authenticated;

grant execute on function public.wa_mine_claim(integer) to service_role;
grant execute on function public.wa_mine_conversa(uuid, integer) to service_role;
grant execute on function public.wa_mine_write(uuid, jsonb) to service_role;
grant execute on function public.wa_mine_finish(uuid, text) to service_role;

-- O minerador entra na lista de workers. A lista e fechada de proposito, e
-- esquecer disso ontem deixou o Eddy mudo por meia hora.
alter table app.worker_runs drop constraint worker_runs_worker_check;
alter table app.worker_runs add constraint worker_runs_worker_check
  check (worker = any (array['AGENTE','ENVIO','MIDIA','TOM','HISTORICO','EDDY','MINERADOR']));

alter table app.worker_heartbeat drop constraint worker_heartbeat_worker_check;
alter table app.worker_heartbeat add constraint worker_heartbeat_worker_check
  check (worker = any (array['AGENTE','ENVIO','MIDIA','TOM','HISTORICO','EDDY','MINERADOR']));

notify pgrst, 'reload schema';
