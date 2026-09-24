-- SERVICO COM PRECO NA VARIACAO TEM PRECO.
--
-- 24/09/2026, teste com dono-robo. "Escova curta 70, media 90, longa 120"
-- virou o servico Escova sem preco base e com tres variacoes com preco -- o
-- jeito certo. Mas owner_setup_state contava o servico como "sem preco" e a
-- pendencia PRECOS nunca saia: o roteiro ficava preso e a publicacao tambem.

do $mig$
declare
  v_def text := pg_get_functiondef('app.owner_setup_state(uuid)'::regprocedure);
  c_de constant text := E'          and s.base_price_minor is null)                                      as servicos_sem_preco,';
  c_para constant text := E'          and s.base_price_minor is null\n'
    || E'          and not exists (select 1 from app.service_variations v\n'
    || E'                           where v.service_id = s.id and v.status = ''ACTIVE''\n'
    || E'                             and v.price_minor is not null))           as servicos_sem_preco,';
begin
  if position(c_de in v_def) = 0 then
    raise exception 'ancora servicos_sem_preco sumiu';
  end if;
  execute replace(v_def, c_de, c_para);
end
$mig$;
