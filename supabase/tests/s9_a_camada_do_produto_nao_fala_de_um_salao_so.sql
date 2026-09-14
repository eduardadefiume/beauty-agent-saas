-- S9: a camada de cima e do PRODUTO, e produto nao tem dono.
--
-- A divisao que acabei de arrumar so se sustenta se ninguem, depois, escorregar
-- de volta: colar num bloco global o preco de um salao, o nome de uma pessoa,
-- ou repetir em `agent_policies` uma regra que ja esta la em cima. Os tres
-- escorregoes sao faceis de cometer e invisiveis ate o segundo cliente -- e ai
-- o agente do salao B responde citando o valor do salao A.
--
-- Este teste tranca as tres metades:
--   1. nenhum bloco global cita valor em reais. Preco vem do catalogo, da arte
--      ou das `policies` daquele salao, nunca do prompt do produto;
--   2. nenhum bloco global cita nome proprio de quem testou o piloto;
--   3. nenhuma regra de salao repete, palavra por palavra, o titulo de uma
--      regra de oficio. Regra em duas camadas e regra sem dono: quando as duas
--      discordarem, ninguem sabe qual manda.
--
-- Roda contra o DEV, nao escreve nada.

begin;

do $$
declare
  v_n integer;
  v_lista text;
begin
  -- 1. Valor em reais na camada que todos os saloes compartilham.
  select count(*), string_agg(b.code, ', ')
    into v_n, v_lista
    from app.agent_prompt_blocks b
   where b.status = 'ACTIVE'
     and b.body ~ 'R\$\s*[0-9]';
  if v_n > 0 then
    raise exception
      'bloco do produto com valor em reais (%). Preco e do salao, nao do prompt: use [valor]', v_lista;
  end if;

  -- 2. Nome proprio de quem testou o piloto. Canario, nao regra geral: sao os
  --    nomes que de fato vazaram para o prompt uma vez, e o jeito mais barato
  --    de perceber que vazou de novo.
  select count(*), string_agg(b.code, ', ')
    into v_n, v_lista
    from app.agent_prompt_blocks b
   where b.status = 'ACTIVE'
     and b.body ~* '(william|duda|eduarda)';
  if v_n > 0 then
    raise exception
      'bloco do produto citando nome de pessoa do piloto (%). Use [primeiro nome]', v_lista;
  end if;

  -- 3. A mesma regra viva nas duas camadas.
  select count(*), string_agg(distinct p.title, ' | ')
    into v_n, v_lista
    from app.agent_policies p
    join app.agent_prompt_blocks b
      on b.status = 'ACTIVE'
     and lower(b.title) = lower(p.title)
   where p.status = 'ACTIVE';
  if v_n > 0 then
    raise exception
      'regra viva nas duas camadas (%): ou e do oficio, ou e do salao, nunca as duas', v_lista;
  end if;

  -- E o outro lado da mesma moeda: o que sobrou em `policies` tem que ser
  -- pouco. Se um dia voltar a inchar, e sinal de que regra de oficio esta
  -- entrando pela tela do dono de novo.
  select count(*) into v_n
    from app.agent_policies p
   where p.status = 'ACTIVE';
  if v_n = 0 then
    raise exception 'nenhuma regra de salao ativa: a divisao comeu o que era do dono';
  end if;
end $$;

select 'S9 OK: a camada do produto nao cita valor nem nome de salao nenhum, e nada vive nas duas' as resultado;

rollback;
