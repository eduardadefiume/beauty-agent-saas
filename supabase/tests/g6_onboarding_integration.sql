-- G6: o onboarding por conversa, do que falta ao que foi escrito.
--
-- O que este teste tranca é a lista branca. O resto do sistema pode errar e
-- alguém conserta; se a lista branca vazar, uma transcrição ruim vira preço
-- errado que o agente promete para a cliente.
--
-- Roda em transação e termina em rollback: nada do que ele escreve sobrevive.

begin;

do $$
declare
  v_tenant  uuid;
  v_draft   uuid;
  v_servico uuid;
  v_outro   uuid;
  v_sessao  uuid;
  v_turno   uuid;
  v_r       jsonb;
  v_n       integer;
  v_preco   integer;
begin
  insert into app.tenants (slug, display_name)
  values ('g6-salao-de-teste', 'Salão de teste G6') returning id into v_tenant;
  insert into app.tenants (slug, display_name)
  values ('g6-outro-salao', 'Outro salão G6') returning id into v_outro;

  insert into app.configuration_drafts (tenant_id, revision, status)
  values (v_tenant, 1, 'DRAFT') returning id into v_draft;

  insert into app.services (tenant_id, configuration_draft_id, name, kind, currency, bookable, status)
  values (v_tenant, v_draft, 'Corte', 'SERVICE', 'BRL', true, 'ACTIVE')
  returning id into v_servico;

  perform app.seed_tenant_knowledge(v_tenant);

  -- 1. Serviço sem preço aparece na pauta, com a pergunta já escrita.
  select count(*) into v_n from app.onboarding_pendencies(v_tenant)
   where chave = 'SERVICO_PRECO:' || v_servico::text
     and pergunta = 'Quanto custa Corte?';
  if v_n <> 1 then
    raise exception 'G6.1 servico sem preco nao entrou na pauta';
  end if;

  insert into app.onboarding_sessions (tenant_id) values (v_tenant) returning id into v_sessao;
  insert into app.onboarding_turns (session_id, tenant_id, quem, texto)
  values (v_sessao, v_tenant, 'DONO', 'corte é 60') returning id into v_turno;

  -- 2. Confiança alta escreve, no rascunho.
  v_r := app.onboarding_record_answer(v_sessao, v_turno,
           'SERVICO_PRECO:' || v_servico::text, 'SERVICOS', 'Corte custa R$ 60',
           null, 60, 0.95);
  if v_r->>'status' <> 'APLICADO' then
    raise exception 'G6.2 confianca alta nao escreveu (%)', v_r;
  end if;
  select base_price_minor into v_preco from app.services where id = v_servico;
  if v_preco <> 6000 then
    raise exception 'G6.3 preco gravado errado (%)', v_preco;
  end if;

  -- 3. Confiança baixa NÃO escreve: fica marcada como incerta.
  v_r := app.onboarding_record_answer(v_sessao, v_turno,
           'SERVICO_PRECO:' || v_servico::text, 'SERVICOS', 'Corte talvez 90',
           null, 90, 0.5);
  if v_r->>'status' <> 'PROPOSTO' then
    raise exception 'G6.4 confianca baixa escreveu (%)', v_r;
  end if;
  select base_price_minor into v_preco from app.services where id = v_servico;
  if v_preco <> 6000 then
    raise exception 'G6.5 proposta mexeu no banco (%)', v_preco;
  end if;

  -- 4. A lista branca recusa o que não é destino conhecido.
  if (app.onboarding_write(v_tenant, 'CLIENTE_TELEFONE:x', 'y', null)->>'reason')
     <> 'DESTINO_FORA_DA_LISTA_BRANCA' then
    raise exception 'G6.6 destino desconhecido nao foi recusado';
  end if;

  -- 5. E recusa alcançar serviço de OUTRO salão, mesmo com confiança máxima.
  --    Este é o caso que mais importa: id inventado pelo modelo.
  v_r := app.onboarding_record_answer(v_sessao, v_turno,
           'SERVICO_PRECO:00000000-0000-0000-0000-000000000009', 'SERVICOS',
           'Servico inventado', null, 80, 0.99);
  if v_r->>'status' <> 'RECUSADO' then
    raise exception 'G6.7 servico inventado foi aceito (%)', v_r;
  end if;

  -- 6. Desfazer devolve o valor anterior, que aqui era vazio.
  v_r := app.onboarding_undo((
    select id from app.onboarding_answers
     where session_id = v_sessao and status = 'APLICADO' order by created_at limit 1));
  if v_r->>'status' <> 'DESFEITO' then
    raise exception 'G6.8 desfazer falhou (%)', v_r;
  end if;
  select base_price_minor into v_preco from app.services where id = v_servico;
  if v_preco is not null then
    raise exception 'G6.9 desfazer nao devolveu o vazio (%)', v_preco;
  end if;

  -- 7. Regra nova nasce ativa; desfazer arquiva, não apaga o rastro.
  v_r := app.onboarding_record_answer(v_sessao, v_turno, 'REGRA:PAGAMENTO', 'REGRAS',
           'Cartao parcela em 3', 'Cartão a gente parcela em 3 sem juros.', null, 0.9);
  if v_r->>'status' <> 'APLICADO' then
    raise exception 'G6.10 regra nao foi escrita (%)', v_r;
  end if;
  perform app.onboarding_undo((v_r->>'id')::uuid);
  select count(*) into v_n from app.agent_policies
   where tenant_id = v_tenant and topic::text = 'PAGAMENTO' and status = 'ACTIVE';
  if v_n <> 0 then
    raise exception 'G6.11 desfazer deixou a regra valendo';
  end if;

  raise notice 'G6 ok';
end $$;

rollback;

select 'G6_ONBOARDING_INTEGRATION_OK' as result;
