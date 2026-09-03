-- Salvar a configuração estava impossível para qualquer salão que fecha para
-- o almoço, e isso é quase todo salão.
--
-- O SINTOMA. A Duda colocou preço no botox, clicou em salvar e a tela devolveu
-- `duplicate key value violates unique constraint
-- "unit_service_limits_tenant_id_configuration_draft_id_weekda_key"`. Saiu da
-- página e o preço não estava lá. Nem o preço, nem nada: a gravação inteira
-- volta atrás.
--
-- A CAUSA. `app.operating_hours` aceita vários turnos por dia -- a chave única
-- inclui `starts_at` e `ends_at`, justamente para caber 9h-12h e 13h-19h. Já
-- `app.unit_service_limits` aceita UMA linha por dia: a chave é
-- (tenant, rascunho, weekday) e nada mais.
--
-- Mas a gravação insere um limite POR TURNO, dentro do mesmo laço que grava os
-- horários. No primeiro salão que cadastrou almoço, o segundo turno de segunda
-- bateu na chave única e derrubou a transação toda.
--
-- O piloto tem dois turnos em todos os seis dias que abre. Ou seja: desde que
-- o horário de almoço entrou, nenhuma alteração de configuração conseguiu ser
-- salva. O erro aparecia na tela, mas como uma linha de banco no meio do
-- cabeçalho, fácil de ler como enfeite.
--
-- A CORREÇÃO. `latest_end_time` quer dizer "a hora mais tarde em que um
-- serviço pode terminar naquele dia". Com dois turnos, essa hora é a maior
-- das duas. Então o segundo turno não é um conflito: é uma informação que
-- atualiza a mesma linha.
--
-- POR QUE ESTA MIGRAÇÃO MEXE NO TEXTO DA FUNÇÃO EM VEZ DE REESCREVÊ-LA.
-- `site_replace_configuration_base` tem 450 linhas e nasceu de um `alter
-- function ... rename`, então o corpo dela não existe inteiro em nenhum
-- arquivo deste repositório. Recopiar 450 linhas na mão para mudar uma
-- cláusula é o tipo de coisa em que um erro de digitação quebra a gravação de
-- configuração para todo mundo e ninguém percebe. Aqui a mudança é o que se lê
-- abaixo, literal, e a migração ESTOURA se o trecho antigo não estiver
-- exatamente como esperado.

do $migracao$
declare
  v_def    text;
  v_velho  text;
  v_novo   text;
  v_quantas integer;
begin
  select pg_get_functiondef(p.oid) into v_def
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'site_replace_configuration_base';

  if v_def is null then
    raise exception 'site_replace_configuration_base nao existe';
  end if;

  v_velho :=
    E'      coalesce(nullif(hour_item->>\'latestEndTime\', \'\')::time, (hour_item->>\'endsAt\')::time)\n    );';

  v_novo :=
    E'      coalesce(nullif(hour_item->>\'latestEndTime\', \'\')::time, (hour_item->>\'endsAt\')::time)\n'
    '    )\n'
    '    on conflict (tenant_id, configuration_draft_id, weekday) do update\n'
    '      set latest_end_time = greatest(unit_service_limits.latest_end_time, excluded.latest_end_time),\n'
    '          updated_at = statement_timestamp();';

  -- Já corrigida: nada a fazer. Deixa a migração poder rodar duas vezes.
  if position(v_novo in v_def) > 0 then
    return;
  end if;

  v_quantas := (length(v_def) - length(replace(v_def, v_velho, ''))) / length(v_velho);
  if v_quantas <> 1 then
    raise exception
      'esperava exatamente 1 insert de unit_service_limits para corrigir, achei %', v_quantas;
  end if;

  execute replace(v_def, v_velho, v_novo);
end $migracao$;
