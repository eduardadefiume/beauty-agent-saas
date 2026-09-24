-- DONO SEM E-MAIL NAO E NUMERO DESCONHECIDO.
--
-- 24/09/2026, teste com dono-robo. O numero estava em owner_whatsapp, ativo,
-- mas sem email_normalized -- e publicar exige o e-mail para achar o acesso de
-- dono no painel. onboarding_publicar devolvia NAO_E_O_DONO, o Eddy leu
-- "numero nao reconhecido como dono deste salao" e passou para a equipe com
-- o diagnostico errado. O dono do salao S-William foi cadastrado do mesmo
-- jeito e travaria no mesmo ponto.
--
-- Agora sao dois motivos: NAO_E_O_DONO (o numero nao esta no salao) e
-- DONO_SEM_EMAIL (esta, mas falta ligar o e-mail de acesso).

do $mig$
declare
  v_def text := pg_get_functiondef('app.onboarding_publicar(uuid, text, text)'::regprocedure);
  c_ancora constant text := E'  if v_email is null then\n    return jsonb_build_object(''ok'', false, ''reason'', ''NAO_E_O_DONO'');\n  end if;\n';
begin
  if position(c_ancora in v_def) = 0 then
    raise exception 'ancora de onboarding_publicar sumiu';
  end if;
  execute replace(v_def, c_ancora,
    E'  if v_email is null then\n'
    || E'    if exists (\n'
    || E'      select 1 from app.owner_whatsapp o\n'
    || E'       where o.tenant_id = p_tenant_id and o.status = ''ACTIVE''\n'
    || E'         and right(regexp_replace(o.phone_digits, ''[^0-9]'', '''', ''g''), 8) = right(v_fone, 8)\n'
    || E'    ) then\n'
    || E'      return jsonb_build_object(''ok'', false, ''reason'', ''DONO_SEM_EMAIL'');\n'
    || E'    end if;\n'
    || E'    return jsonb_build_object(''ok'', false, ''reason'', ''NAO_E_O_DONO'');\n'
    || E'  end if;\n');
end
$mig$;
