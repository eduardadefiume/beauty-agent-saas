-- O DIA DE HOJE EM PORTUGUES, E O SABADO QUE JA PASSOU.
--
-- 26/09/2026 (um sabado, 15h), teste no DEV com cliente simulada:
--   cliente: "Queria saber o preço de uma escova e se tem horário sábado de manhã"
--   atendente: "Sábado de manhã não tenho mais vaga, mas tenho às 8h da manhã de
--               hoje já passou... deixa eu ver: tenho hoje às 15:15, pode ser?"
--
-- Dois erros de uma vez:
--   1. Ela buscou HOJE. A cliente que escreve "sabado de manha" num sabado a
--      tarde fala do proximo sabado -- a manha de hoje ja acabou.
--   2. Ela escreveu o raciocinio para a cliente ("ja passou... deixa eu ver").
--
-- E o contexto ajudava a confundir: `today` vinha como "Saturday 26/09/2026",
-- com o dia da semana em ingles, numa conversa inteira em portugues.

-- 1. `today` com o dia da semana em portugues.
do $patch$
declare
  v_def   text := pg_get_functiondef('app.build_agent_context(uuid,integer)'::regprocedure);
  v_velho text := $v$trim(to_char(statement_timestamp() at time zone 'America/Sao_Paulo', 'Day'))$v$;
  v_novo  text := $v$(array['domingo','segunda-feira','terça-feira','quarta-feira','quinta-feira','sexta-feira','sábado'])[extract(dow from statement_timestamp() at time zone 'America/Sao_Paulo')::int + 1]$v$;
begin
  if position(v_velho in v_def) = 0 then
    raise exception 'build_agent_context: trecho do dia da semana nao encontrado';
  end if;
  execute replace(v_def, v_velho, v_novo);
end
$patch$;

-- 2. A regra da atendente.
insert into app.agent_prompt_blocks (code, agent, title, body, position, status)
select 'DIA_QUE_JA_PASSOU', 'CLIENTE',
       'O dia que ela pediu pode ser o próximo',
       'Antes de consultar a agenda, olhe `now` e `today`. Se a cliente pede um dia da semana ' ||
       'que é HOJE e um período que JÁ PASSOU ("sábado de manhã" num sábado à tarde), ela está ' ||
       'falando do PRÓXIMO: consulte a partir da semana que vem, nesse dia e nesse período. ' ||
       'Se não der para saber qual dos dois ela quer, pergunte: "Você diz o sábado que vem, dia ' ||
       'X, de manhã?". Nunca ofereça um horário que já passou.' || chr(10) ||
       'E o que você pensa para chegar na resposta NÃO vai para a cliente: nada de "deixa eu ' ||
       'ver", "já passou...", "hmm". Ela lê só a conclusão, escrita uma vez, limpa.',
       101, 'ACTIVE'
where not exists (
  select 1 from app.agent_prompt_blocks b where b.code = 'DIA_QUE_JA_PASSOU'
);
