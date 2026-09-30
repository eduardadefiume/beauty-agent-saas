-- TITULO NA AGENDA: LACUNA VAZIA LEVA JUNTO O PEDACO QUE DEPENDE DELA.
--
-- 30/09/2026, teste de todos os modelos com todos os casos: servico sem
-- preco saia "Avaliacao - R$" e agendamento sem profissional saia
-- "Ana (com )". Agora a lacuna vazia vira uma marca; parentese que tem uma
-- marca some inteiro, "R$" antes de uma marca some, e so entao a marca sai.
-- Sinal que cobre o valor inteiro sai "100 PAGO", nao "100 DEU 100 FICOU 0".
create or replace function app.agenda_aplicar_modelo(p_modelo text, p_caixa_alta boolean, p_v jsonb)
returns text language plpgsql immutable set search_path to ''
as $fn$
declare
  v_vazio  constant text := chr(1);
  v_valor  text := app.agenda_reais_curto((p_v ->> 'valorCentavos')::integer);
  v_sinal  integer := (p_v ->> 'sinalPagoCentavos')::integer;
  v_pag    text;
  v_t      text;
begin
  v_pag := case
    when v_valor is null then null
    when v_sinal is not null and v_sinal >= (p_v ->> 'valorCentavos')::integer then v_valor || ' PAGO'
    when v_sinal is not null and v_sinal > 0 then
      v_valor || ' DEU ' || app.agenda_reais_curto(v_sinal) || ' FICOU '
      || app.agenda_reais_curto(greatest((p_v ->> 'valorCentavos')::integer - v_sinal, 0))
    else v_valor end;
  v_t := coalesce(nullif(trim(p_modelo), ''), '{nome} {telefone} - {servico}');
  v_t := replace(v_t, '{nome}', coalesce(nullif(p_v ->> 'nome', ''), v_vazio));
  v_t := replace(v_t, '{telefone}', coalesce(nullif(p_v ->> 'telefone', ''), v_vazio));
  v_t := replace(v_t, '{servico}', coalesce(nullif(p_v ->> 'servico', ''), v_vazio));
  v_t := replace(v_t, '{valor}', coalesce(v_valor, v_vazio));
  v_t := replace(v_t, '{pagamento}', coalesce(v_pag, v_vazio));
  v_t := replace(v_t, '{profissional}', coalesce(nullif(p_v ->> 'profissional', ''), v_vazio));
  v_t := regexp_replace(v_t, '\([^()]*' || v_vazio || '[^()]*\)', '', 'g');
  v_t := regexp_replace(v_t, 'R\$\s*' || v_vazio, '', 'g');
  v_t := replace(v_t, v_vazio, '');
  v_t := regexp_replace(v_t, '\s{2,}', ' ', 'g');
  v_t := regexp_replace(v_t, '(\s*-\s*){2,}', ' - ', 'g');
  v_t := regexp_replace(v_t, '^\s*-\s*|\s*-\s*$', '', 'g');
  v_t := trim(v_t);
  return case when p_caixa_alta then upper(v_t) else v_t end;
end;
$fn$;