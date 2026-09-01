-- O que este teste tranca: as quatro regras de coloração que NÃO podem depender
-- de o modelo lembrar. Cada uma delas, se falhar, estraga o cabelo de alguém e
-- só aparece depois de a cliente já estar na cadeira.
--
--   1. Tinta não clareia tinta. Um único nível de clareamento em cabelo já
--      colorido exige descoloração.
--   2. Escurecer cabelo descolorido sem pré-pigmentar entrega cor que esverdeia
--      e sai na segunda lavagem.
--   3. Clarear e não matizar entrega o fundo exposto -- laranja, amarelo.
--   4. Ruivo é a exceção: ele VIVE do fundo quente, matizar é tirar o que ia
--      sustentar a cor.
--
-- E duas de honestidade, que não são de química:
--
--   5. Enquanto o dono não responde, o plano diz que o número é sugestão.
--   6. Família sem foto é avisada como família sem foto. Depois que a Duda
--      corrigiu o desenho -- "não é número que vai dizer qual a família da cor
--      e sim foto" --, a faixa passou a sair das fotos, e o aviso útil deixou
--      de ser "falta confirmar" e virou "falta foto".

begin;

insert into app.tenants (id, display_name, slug)
values ('e4000000-0000-0000-0000-000000000001', 'G4 Color Plan', 'g4-color-plan');

select app.seed_color_model('e4000000-0000-0000-0000-000000000001');

do $$
declare
  v_tenant  uuid := 'e4000000-0000-0000-0000-000000000001';
  v_loiro   uuid;
  v_ruivo   uuid;
  v_castanho uuid;
  v_plano   jsonb;
begin
  select id into v_loiro    from app.tone_families where tenant_id = v_tenant and name = 'Loiro';
  select id into v_ruivo    from app.tone_families where tenant_id = v_tenant and name = 'Ruivo';
  select id into v_castanho from app.tone_families where tenant_id = v_tenant and name = 'Castanho';

  if v_loiro is null or v_ruivo is null or v_castanho is null then
    raise exception 'SEED_COLOR_MODEL_NAO_CRIOU_AS_FAMILIAS';
  end if;

  -- 1. Tinta não clareia tinta: 1 nível só, mas em cabelo colorido, descolore.
  v_plano := app.color_plan(v_tenant, 5::smallint, 'COLORIDO', 6::smallint, v_loiro, false);
  if not (v_plano->'etapas') @> '[{"etapa":"DESCOLORACAO"}]'::jsonb then
    raise exception 'TINTA_SOBRE_TINTA_DEVERIA_EXIGIR_DESCOLORACAO: %', v_plano;
  end if;

  -- ...e o mesmo clareamento em cabelo virgem não descolore.
  v_plano := app.color_plan(v_tenant, 5::smallint, 'VIRGEM', 6::smallint, v_loiro, false);
  if jsonb_array_length(v_plano->'etapas') <> 0 then
    raise exception 'UM_NIVEL_EM_CABELO_VIRGEM_NAO_PRECISA_DE_ETAPA: %', v_plano;
  end if;

  -- 2. Escurecer descolorido pede pré-pigmentação.
  v_plano := app.color_plan(v_tenant, 9::smallint, 'DESCOLORIDO', 5::smallint, v_castanho, false);
  if not (v_plano->'etapas') @> '[{"etapa":"PRE_PIGMENTACAO"}]'::jsonb then
    raise exception 'ESCURECER_DESCOLORIDO_DEVERIA_EXIGIR_PRE_PIGMENTACAO: %', v_plano;
  end if;

  -- 3. Clarear muito pede matização, e o plano nomeia o fundo que aparece.
  v_plano := app.color_plan(v_tenant, 5::smallint, 'VIRGEM', 9::smallint, v_loiro, false);
  if not (v_plano->'etapas') @> '[{"etapa":"MATIZACAO"}]'::jsonb then
    raise exception 'CLAREAR_QUATRO_NIVEIS_DEVERIA_EXIGIR_MATIZACAO: %', v_plano;
  end if;
  if v_plano->>'fundoQueAparece' <> 'amarelo' then
    raise exception 'O_FUNDO_DO_NIVEL_9_E_AMARELO, veio: %', v_plano->>'fundoQueAparece';
  end if;
  if (v_plano->>'testeDeMecha')::boolean is not true then
    raise exception 'DESCOLORACAO_SEMPRE_PEDE_TESTE_DE_MECHA: %', v_plano;
  end if;

  -- 4. Ruivo não matiza: o fundo quente é aliado dele.
  v_plano := app.color_plan(v_tenant, 5::smallint, 'VIRGEM', 8::smallint, v_ruivo, false);
  if (v_plano->'etapas') @> '[{"etapa":"MATIZACAO"}]'::jsonb then
    raise exception 'RUIVO_NAO_MATIZA_O_PROPRIO_FUNDO: %', v_plano;
  end if;
  if not (v_plano->'etapas') @> '[{"etapa":"DESCOLORACAO"}]'::jsonb then
    raise exception 'RUIVO_TRES_NIVEIS_ACIMA_AINDA_DESCOLORE: %', v_plano;
  end if;

  -- 5. Honestidade: sem resposta do dono, o número é sugestão e o plano diz.
  v_plano := app.color_plan(v_tenant, 5::smallint, 'VIRGEM', 9::smallint, v_loiro, false);
  if not (v_plano->'aindaSugerido') ? 'MINUTOS_POR_NIVEL' then
    raise exception 'PLANO_DEVERIA_ADMITIR_QUE_O_NUMERO_E_SUGESTAO: %', v_plano;
  end if;

  update app.color_policies
     set answer_value = 45, answered_at = now(), answered_by = 'teste'
   where tenant_id = v_tenant and key = 'MINUTOS_POR_NIVEL';

  v_plano := app.color_plan(v_tenant, 5::smallint, 'VIRGEM', 9::smallint, v_loiro, false);
  if (v_plano->'aindaSugerido') ? 'MINUTOS_POR_NIVEL' then
    raise exception 'DEPOIS_DE_RESPONDIDO_NAO_E_MAIS_SUGESTAO: %', v_plano;
  end if;
  -- 4 níveis x 45 min de clareamento + 30 min de matização (ainda sugerido).
  if (v_plano->>'tempoAMaisMinutos')::integer <> 210 then
    raise exception 'A_RESPOSTA_DO_DONO_TEM_QUE_ENTRAR_NA_CONTA, veio: %',
      v_plano->>'tempoAMaisMinutos';
  end if;

  -- 6. Sem foto, o plano avisa que não aprendeu o que este salão chama assim.
  v_plano := app.color_plan(v_tenant, 5::smallint, 'VIRGEM', 9::smallint, v_loiro, false);
  if not (v_plano->'avisos')::text like '%não tem nenhuma foto%' then
    raise exception 'FAMILIA_SEM_FOTO_TEM_QUE_AVISAR: %', v_plano->'avisos';
  end if;
  if (v_plano->'faixaDaFamilia'->>'veioDasFotos')::boolean then
    raise exception 'SEM_FOTO_A_FAIXA_NAO_PODE_DIZER_QUE_VEIO_DELAS: %', v_plano;
  end if;

  -- ...e com foto lida, a faixa passa a ser a das fotos, não a semente.
  insert into app.tone_family_photos
    (tenant_id, family_id, storage_path, estimated_level, level_source)
  values (v_tenant, v_loiro, v_tenant::text || '/cor/g4.jpg', 8, 'LIDO_NA_FOTO');

  v_plano := app.color_plan(v_tenant, 5::smallint, 'VIRGEM', 9::smallint, v_loiro, false);
  if not (v_plano->'faixaDaFamilia'->>'veioDasFotos')::boolean then
    raise exception 'COM_FOTO_A_FAIXA_TEM_QUE_VIR_DELAS: %', v_plano;
  end if;
  if (v_plano->'faixaDaFamilia'->>'de')::integer <> 8 then
    raise exception 'A_FAIXA_E_O_QUE_AS_FOTOS_DIZEM, veio: %', v_plano->'faixaDaFamilia';
  end if;

  -- E correção de gente não é sobrescrita pelo motor.
  update app.tone_family_photos set estimated_level = 9, level_source = 'PESSOA'
   where family_id = v_loiro;
  if (public.record_tone_photo_level(
        (select id from app.tone_family_photos where family_id = v_loiro),
        7::smallint, null)->>'ok')::boolean then
    raise exception 'O_MOTOR_NAO_PODE_PASSAR_POR_CIMA_DA_CORRECAO_DE_GENTE';
  end if;

  -- Guardas de entrada: altura fora da escala e estado inventado não passam.
  if (app.color_plan(v_tenant, 0::smallint, 'VIRGEM', 9::smallint, v_loiro, false)->>'ok')::boolean then
    raise exception 'ALTURA_DE_TOM_ZERO_NAO_EXISTE';
  end if;
  if (app.color_plan(v_tenant, 5::smallint, 'INVENTADO', 9::smallint, v_loiro, false)->>'ok')::boolean then
    raise exception 'ESTADO_DO_FIO_INVENTADO_NAO_PODE_PASSAR';
  end if;

  -- Isolamento: família de outro salão não vale aqui.
  if (app.color_plan(v_tenant, 5::smallint, 'VIRGEM', 9::smallint,
                     '00000000-0000-0000-0000-000000000000', false)->>'ok')::boolean then
    raise exception 'FAMILIA_DE_FORA_DO_SALAO_NAO_PODE_PASSAR';
  end if;
end;
$$;

rollback;

select 'G4_COLOR_PLAN_INTEGRATION_OK' as result;
