-- RASCUNHO NOVO NAO PERDE O "A PARTIR DE".
--
-- 28/09/2026, achado pela diferenca rascunho x no ar: a Morena iluminada foi
-- publicada "a partir de R$ 430" na versao 2 e, da versao 3 em diante, estava
-- no ar como valor FECHADO. Ninguem mexeu nela: start_new_draft_from_published
-- copia cada servico para o rascunho novo, e a lista de colunas copiadas nao
-- tinha price_is_floor (criada depois). Cada mudanca pos-publicacao, em
-- qualquer servico, apagava o "a partir de" de todos. O mesmo com tres colunas
-- das etapas (technical_category, professional_confirmation_required,
-- product_record_required), que voltavam ao padrao.
--
-- O patch troca so as duas listas de colunas e confere que trocou: se a
-- funcao estiver diferente do esperado, a migracao falha em vez de passar
-- calada.

do $patch$
declare
  v_def text := pg_get_functiondef('app.start_new_draft_from_published'::regproc);
  v_novo text;
begin
  v_novo := replace(v_def,
    'requires_strand_test, strand_test_lead_days, strand_test_duration_minutes, strand_test_preferred_weekdays
    )',
    'requires_strand_test, strand_test_lead_days, strand_test_duration_minutes, strand_test_preferred_weekdays,
      price_is_floor
    )');
  v_novo := replace(v_novo,
    'rec.strand_test_duration_minutes, rec.strand_test_preferred_weekdays
    )',
    'rec.strand_test_duration_minutes, rec.strand_test_preferred_weekdays,
      rec.price_is_floor
    )');
  v_novo := replace(v_novo,
    'minimum_duration_minutes, maximum_duration_minutes
    )',
    'minimum_duration_minutes, maximum_duration_minutes,
      technical_category, professional_confirmation_required, product_record_required
    )');
  v_novo := replace(v_novo,
    'coalesce(rec.maximum_duration_minutes, rec.duration_minutes)
    )',
    'coalesce(rec.maximum_duration_minutes, rec.duration_minutes),
      rec.technical_category, rec.professional_confirmation_required, rec.product_record_required
    )');

  if (length(v_novo) - length(replace(v_novo, 'price_is_floor', ''))) / length('price_is_floor') <> 2
     or (length(v_novo) - length(replace(v_novo, 'product_record_required', ''))) / length('product_record_required') <> 2 then
    raise exception 'start_new_draft_from_published nao esta como esperado; patch nao aplicado';
  end if;

  execute v_novo;
end;
$patch$;
