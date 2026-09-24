-- O EDDY ARQUIVA A FOTO NA REGUA.
--
-- 24/09/2026. Desde 20260924121119 a foto que o dono manda fica guardada em
-- app.midias_do_dono, lida como aula e sem destino. Falta a mao que liga a
-- legenda que vem DEPOIS ("essas 6 sao ruivo") as fotos certas e grava cada
-- uma no lugar em que a atendente vai procurar:
--
--   tom   -> app.tone_family_photos       (o tone-photo-reader estima a altura
--                                          de tom sozinho, pelo read_at nulo)
--   corte, comprimento, curvatura...
--         -> app.knowledge_reference_photos (opcao da regua)
--
-- Duas funcoes:
--   eddy_regua_e_fotos    o que o Eddy precisa ver para decidir: as fotos sem
--                         destino desta conversa e os nomes exatos da regua
--   eddy_arquivar_fotos   grava, marca o destino e devolve o que fez
--
-- A foto so e arquivada no salao da propria conversa: o arquivo mora na pasta
-- desse salao, e referencia-la de outro salao seria vazar a pasta.

create or replace function app.eddy_regua_e_fotos(p_tenant_id uuid, p_conversation_id uuid)
returns jsonb
language sql
stable
security definer
set search_path to ''
as $fn$
  select jsonb_build_object(
    'fotosSemDestino', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', f.id,
               'recebidaEm', to_char(f.created_at at time zone 'America/Sao_Paulo', 'DD/MM HH24:MI'),
               'assunto', f.assunto,
               'certeza', f.certeza,
               'leitura', left(f.leitura, 300),
               'arquivoGuardado', f.storage_path is not null)
             order by f.created_at)
        from app.midias_do_dono f
       where f.tenant_id = p_tenant_id
         and f.conversation_id = p_conversation_id
         and f.destino is null
         and f.created_at > statement_timestamp() - interval '7 days'
    ), '[]'::jsonb),
    'familiasDeTom', coalesce((
      select jsonb_agg(jsonb_build_object(
               'nome', tf.name,
               'fotos', (select count(*) from app.tone_family_photos p where p.family_id = tf.id))
             order by tf.position, tf.name)
        from app.tone_families tf
       where tf.tenant_id = p_tenant_id and tf.status = 'ACTIVE'
    ), '[]'::jsonb),
    'regua', coalesce((
      select jsonb_agg(jsonb_build_object(
               'dimensao', d.name,
               'opcoes', coalesce((
                 select jsonb_agg(o.label order by o.position, o.label)
                   from app.knowledge_options o
                  where o.dimension_id = d.id and o.status = 'ACTIVE'
               ), '[]'::jsonb))
             order by d.position, d.name)
        from app.knowledge_dimensions d
       where d.tenant_id = p_tenant_id and d.status = 'ACTIVE'
    ), '[]'::jsonb)
  );
$fn$;

revoke all on function app.eddy_regua_e_fotos(uuid, uuid) from public, anon, authenticated;

create or replace function public.eddy_regua_e_fotos(p_tenant_id uuid, p_conversation_id uuid)
returns jsonb language sql stable security definer set search_path to ''
as $$ select app.eddy_regua_e_fotos(p_tenant_id, p_conversation_id); $$;

revoke all on function public.eddy_regua_e_fotos(uuid, uuid) from public, anon, authenticated;
grant execute on function public.eddy_regua_e_fotos(uuid, uuid) to service_role;

-- p_destino:
--   FAMILIA_DE_TOM  p_alvo = nome da familia ("Ruivo")
--   OPCAO_DA_REGUA  p_alvo = nome da opcao ("Pixie (joãozinho)"); p_dimensao
--                   desambigua e e obrigatoria para criar opcao nova
--   CONHECIMENTO    a foto ja virou conhecimento solto; so marca
--   DESCARTADA      o dono disse que nao servia
create or replace function app.eddy_arquivar_fotos(
  p_tenant_id       uuid,
  p_conversation_id uuid,
  p_fotos           uuid[],
  p_destino         text,
  p_alvo            text default null,
  p_dimensao        text default null,
  p_criar_opcao     boolean default false
)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $fn$
declare
  v_alvo_id uuid;
  v_dim_id  uuid;
  v_foto    app.midias_do_dono;
  v_feitas  integer := 0;
  v_sem_arquivo integer := 0;
  v_criou   boolean := false;
  v_pos     integer;
begin
  if p_destino not in ('FAMILIA_DE_TOM', 'OPCAO_DA_REGUA', 'CONHECIMENTO', 'DESCARTADA') then
    return jsonb_build_object('ok', false, 'reason', 'DESTINO_INVALIDO');
  end if;
  if coalesce(array_length(p_fotos, 1), 0) = 0 then
    return jsonb_build_object('ok', false, 'reason', 'NENHUMA_FOTO');
  end if;

  -- Toda foto pedida tem que ser deste salao, desta conversa e ainda sem
  -- destino. Uma que nao for derruba o pedido inteiro: arquivar metade e
  -- dizer ao dono que arquivou tudo e o erro que este sistema ja cometeu.
  if exists (
    select 1 from unnest(p_fotos) as pedida(id)
     where not exists (
       select 1 from app.midias_do_dono f
        where f.id = pedida.id
          and f.tenant_id = p_tenant_id
          and f.conversation_id = p_conversation_id
          and f.destino is null)
  ) then
    return jsonb_build_object('ok', false, 'reason', 'FOTO_NAO_ENCONTRADA_OU_JA_ARQUIVADA');
  end if;

  if p_destino = 'FAMILIA_DE_TOM' then
    select tf.id into v_alvo_id
      from app.tone_families tf
     where tf.tenant_id = p_tenant_id and tf.status = 'ACTIVE'
       and lower(tf.name) = lower(trim(coalesce(p_alvo, '')));
    if v_alvo_id is null then
      return jsonb_build_object('ok', false, 'reason', 'FAMILIA_NAO_EXISTE',
        'familias', (select jsonb_agg(tf.name order by tf.position) from app.tone_families tf
                      where tf.tenant_id = p_tenant_id and tf.status = 'ACTIVE'));
    end if;

  elsif p_destino = 'OPCAO_DA_REGUA' then
    if nullif(trim(coalesce(p_dimensao, '')), '') is not null then
      select d.id into v_dim_id
        from app.knowledge_dimensions d
       where d.tenant_id = p_tenant_id and d.status = 'ACTIVE'
         and lower(d.name) = lower(trim(p_dimensao));
      if v_dim_id is null then
        return jsonb_build_object('ok', false, 'reason', 'DIMENSAO_NAO_EXISTE');
      end if;
    end if;

    select o.id, o.dimension_id into v_alvo_id, v_dim_id
      from app.knowledge_options o
      join app.knowledge_dimensions d on d.id = o.dimension_id
     where o.tenant_id = p_tenant_id and o.status = 'ACTIVE' and d.status = 'ACTIVE'
       and lower(o.label) = lower(trim(coalesce(p_alvo, '')))
       and (v_dim_id is null or o.dimension_id = v_dim_id)
     order by d.position
     limit 1;

    if v_alvo_id is null then
      if not p_criar_opcao or v_dim_id is null or length(trim(coalesce(p_alvo, ''))) < 2 then
        return jsonb_build_object('ok', false, 'reason', 'OPCAO_NAO_EXISTE',
          'dica', 'Confirme o nome com o dono. Para criar uma opcao nova, mande a dimensao e criarOpcao.');
      end if;
      select coalesce(max(o.position), 0) + 10 into v_pos
        from app.knowledge_options o where o.dimension_id = v_dim_id;
      insert into app.knowledge_options (tenant_id, dimension_id, label, position, origin)
      values (p_tenant_id, v_dim_id, left(trim(p_alvo), 80), v_pos, 'SALAO')
      returning id into v_alvo_id;
      v_criou := true;
    end if;
  end if;

  for v_foto in
    select f.* from app.midias_do_dono f where f.id = any(p_fotos) order by f.created_at
  loop
    if p_destino = 'FAMILIA_DE_TOM' and v_foto.storage_path is not null then
      insert into app.tone_family_photos (tenant_id, family_id, storage_path, caption, position)
      values (p_tenant_id, v_alvo_id, v_foto.storage_path, left(v_foto.leitura, 500),
              (select coalesce(max(p.position), 0) + 1 from app.tone_family_photos p where p.family_id = v_alvo_id))
      on conflict (tenant_id, storage_path) do nothing;
    elsif p_destino = 'OPCAO_DA_REGUA' and v_foto.storage_path is not null then
      insert into app.knowledge_reference_photos (tenant_id, option_id, storage_path, caption, position)
      values (p_tenant_id, v_alvo_id, v_foto.storage_path, left(v_foto.leitura, 500),
              (select coalesce(max(p.position), 0) + 1 from app.knowledge_reference_photos p where p.option_id = v_alvo_id))
      on conflict (tenant_id, storage_path) do nothing;
    end if;

    if v_foto.storage_path is null and p_destino in ('FAMILIA_DE_TOM', 'OPCAO_DA_REGUA') then
      v_sem_arquivo := v_sem_arquivo + 1;
    end if;

    update app.midias_do_dono
       set destino = p_destino, destino_id = v_alvo_id, destinado_em = statement_timestamp()
     where id = v_foto.id;
    v_feitas := v_feitas + 1;
  end loop;

  return jsonb_build_object('ok', true, 'arquivadas', v_feitas, 'semArquivo', v_sem_arquivo,
                            'destino', p_destino, 'alvo', p_alvo, 'opcaoCriada', v_criou);
end;
$fn$;

revoke all on function app.eddy_arquivar_fotos(uuid, uuid, uuid[], text, text, text, boolean) from public, anon, authenticated;

create or replace function public.eddy_arquivar_fotos(
  p_tenant_id uuid, p_conversation_id uuid, p_fotos uuid[], p_destino text,
  p_alvo text default null, p_dimensao text default null, p_criar_opcao boolean default false
) returns jsonb language sql security definer set search_path to ''
as $$ select app.eddy_arquivar_fotos(p_tenant_id, p_conversation_id, p_fotos, p_destino, p_alvo, p_dimensao, p_criar_opcao); $$;

revoke all on function public.eddy_arquivar_fotos(uuid, uuid, uuid[], text, text, text, boolean) from public, anon, authenticated;
grant execute on function public.eddy_arquivar_fotos(uuid, uuid, uuid[], text, text, text, boolean) to service_role;
