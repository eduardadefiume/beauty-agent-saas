-- Permissões de arquivo e a leitura que o classificador usa.

-- Convenção de caminho: <tenant_id>/<arquivo>. A primeira pasta é o crachá —
-- é ela que as políticas conferem. Sem isso, uma dona autenticada poderia
-- subir arquivo na pasta de outro salão só chutando o caminho.
create or replace function app.storage_folder_is_my_tenant(p_name text)
returns boolean
language plpgsql
stable
security definer
set search_path = app, storage, pg_catalog
as $$
declare
  v_pasta text := (storage.foldername(p_name))[1];
begin
  -- Pasta que não é uuid não pertence a tenant nenhum. Testar antes evita que
  -- um caminho inventado derrube a política com erro de conversão.
  if v_pasta is null or v_pasta !~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
    return false;
  end if;
  return app.email_belongs_to_tenant(auth.jwt() ->> 'email', v_pasta::uuid);
end;
$$;

drop policy if exists conhecimento_le on storage.objects;
drop policy if exists conhecimento_envia on storage.objects;
drop policy if exists conhecimento_atualiza on storage.objects;
drop policy if exists conhecimento_apaga on storage.objects;

create policy conhecimento_le on storage.objects
  for select to authenticated
  using (bucket_id = 'conhecimento' and app.storage_folder_is_my_tenant(name));

create policy conhecimento_envia on storage.objects
  for insert to authenticated
  with check (bucket_id = 'conhecimento' and app.storage_folder_is_my_tenant(name));

create policy conhecimento_atualiza on storage.objects
  for update to authenticated
  using (bucket_id = 'conhecimento' and app.storage_folder_is_my_tenant(name))
  with check (bucket_id = 'conhecimento' and app.storage_folder_is_my_tenant(name));

create policy conhecimento_apaga on storage.objects
  for delete to authenticated
  using (bucket_id = 'conhecimento' and app.storage_folder_is_my_tenant(name));

-- Leitura para o classificador. Só o texto e os caminhos das fotos: quem monta
-- a chamada com imagem é a Edge Function, que assina as URLs na hora.
--
-- Opção sem descrição E sem foto fica de fora. Não há como classificar contra
-- uma régua vazia, e mandá-la assim mesmo só faria o modelo inventar uma
-- fronteira que a dona nunca definiu — que é exatamente o erro que este
-- módulo existe para evitar.
create or replace function public.knowledge_for_classifier(p_tenant_id uuid)
returns jsonb
language sql
stable
security definer
set search_path to ''
as $function$
  select coalesce(jsonb_agg(d order by d->>'name'), '[]'::jsonb)
    from (
      select jsonb_build_object(
               'dimensionId', dim.id,
               'name', dim.name,
               'whatToLookAt', dim.what_to_look_at,
               'options', opts.lista
             ) as d
        from app.knowledge_dimensions dim
        join lateral (
          select jsonb_agg(jsonb_build_object(
                   'optionId', o.id,
                   'label', o.label,
                   'description', o.description,
                   'photos', coalesce((
                     select jsonb_agg(f.storage_path order by f.position)
                       from app.knowledge_reference_photos f
                      where f.option_id = o.id
                   ), '[]'::jsonb)
                 ) order by o.position) as lista
            from app.knowledge_options o
           where o.dimension_id = dim.id
             and o.status = 'ACTIVE'
             and (
               coalesce(trim(o.description), '') <> ''
               or exists (select 1 from app.knowledge_reference_photos f where f.option_id = o.id)
             )
        ) opts on opts.lista is not null
       where dim.tenant_id = p_tenant_id and dim.status = 'ACTIVE'
    ) pronto;
$function$;

revoke all on function public.knowledge_for_classifier(uuid) from public, anon, authenticated;
grant execute on function public.knowledge_for_classifier(uuid) to service_role;
