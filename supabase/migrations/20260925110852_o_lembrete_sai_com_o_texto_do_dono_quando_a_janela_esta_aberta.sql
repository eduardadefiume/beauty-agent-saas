-- O LEMBRETE DA VESPERA SAI -- COM O TEXTO DO DONO -- QUANDO A JANELA ESTA ABERTA.
--
-- 25/09/2026, teste com clientes-robo no Studio Rogerio. A Marina marcou
-- escova para sabado 10h. Conferindo o lembrete antes das 19h da vespera:
--
-- 1. NENHUM salao tem modelo da Meta registrado (message_templates vazia), e o
--    lembrete so sabia sair por modelo. Resultado: PULADO com
--    MODELO_NAO_REGISTRADO -- e a linha de appointment_reminders e definitiva.
--    O lembrete nunca saiu para ninguem.
-- 2. O texto que o dono escolheu no Eddy (lembrete_texto_desejado) nunca era
--    usado para nada.
-- 3. O texto foi gravado com "Te espero as 14h" -- hora fixa. Se um dia
--    virasse modelo, toda cliente receberia 14h.
--
-- O WhatsApp permite texto livre ate 24h depois da ultima mensagem da
-- cliente. Quem marca pelo WhatsApp muitas vezes ainda esta nessa janela na
-- vespera. Entao: primeiro tenta o texto livre (com o texto do dono, se ele
-- tiver {hora}; senao o padrao). So quando a janela esta fechada cai no
-- modelo, como antes.
--
-- E o Eddy passa a recusar texto com hora escrita: pede {hora}.

do $mig$
declare
  v_def text := pg_get_functiondef('app.agendar_lembretes_da_vespera(integer)'::regprocedure);
  c_decl constant text := E'  v_pulados      integer := 0;\n';
  c_inicio constant text := E'      v_resultado := app.enqueue_outbound_template(\n';
  c_fim constant text := E'v_linha.salao)\n      );\n';
begin
  if position(c_decl in v_def) = 0 or position(c_inicio in v_def) = 0
     or position(c_fim in v_def) = 0 then
    raise exception 'ancora de agendar_lembretes_da_vespera sumiu';
  end if;

  v_def := replace(v_def, c_decl, c_decl
    || E'  v_texto        text;\n'
    || E'  v_texto_dono   text;\n');

  v_def := replace(v_def, c_inicio,
       E'      -- Dentro da janela de 24h: texto livre, com o texto do dono.\n'
    || E'      select nullif(trim(coalesce(sc.lembrete_texto_desejado, '''')), '''')\n'
    || E'        into v_texto_dono\n'
    || E'        from app.agent_scope sc where sc.tenant_id = v_linha.tenant_id;\n'
    || E'      v_texto := case when v_texto_dono like ''%{hora}%'' then v_texto_dono\n'
    || E'                      else ''Oi {nome}! Passando para lembrar do seu horário amanhã, {data}, às {hora}, no {salao}. Se precisar remarcar, é só me avisar por aqui.''\n'
    || E'                 end;\n'
    || E'      v_texto := replace(v_texto, ''{nome}'', v_nome);\n'
    || E'      v_texto := replace(v_texto, ''{data}'', to_char(v_local, ''DD/MM''));\n'
    || E'      v_texto := replace(v_texto, ''{hora}'', to_char(v_local, ''HH24:MI''));\n'
    || E'      v_texto := replace(v_texto, ''{salao}'', v_linha.salao);\n'
    || E'      v_resultado := app.enqueue_outbound_message(\n'
    || E'        v_linha.tenant_id, v_conversa, v_texto, ''AGENT'',\n'
    || E'        ''lembrete:'' || v_linha.id::text, null, null, null, null);\n'
    || E'\n'
    || E'      -- Janela fechada: so modelo aprovado reabre a conversa.\n'
    || E'      if coalesce(v_resultado ->> ''reason'', '''') = ''SERVICE_WINDOW_CLOSED'' then\n'
    || c_inicio);

  v_def := replace(v_def, c_fim, c_fim || E'      end if;\n');

  execute v_def;
end
$mig$;

do $mig$
declare
  v_def text := pg_get_functiondef('app.eddy_definir_lembrete(uuid, boolean, integer, text)'::regprocedure);
  c_ancora constant text := E'  update app.agent_scope\n     set lembra_da_vespera = p_quer,\n';
begin
  if position(c_ancora in v_def) = 0 then
    raise exception 'ancora de eddy_definir_lembrete sumiu';
  end if;
  execute replace(v_def, c_ancora,
       E'  -- Hora escrita no texto vale para uma cliente so. Cada uma recebe a dela.\n'
    || E'  if v_texto is not null and v_texto not like ''%{hora}%''\n'
    || E'     and v_texto ~* ''(\\m\\d{1,2}\\s*h\\M|\\m\\d{1,2}h\\d{2}\\M|\\m\\d{1,2}:\\d{2}\\M)'' then\n'
    || E'    return jsonb_build_object(''ok'', false, ''reason'', ''TEXTO_COM_HORA_FIXA'',\n'
    || E'      ''comoResolver'', ''Troque a hora escrita por {hora}. Pode usar tambem {nome}, {data} e {salao}: cada cliente recebe os dela.'');\n'
    || E'  end if;\n\n'
    || c_ancora);
end
$mig$;

revoke all on function app.agendar_lembretes_da_vespera(integer) from public, anon, authenticated;
revoke all on function app.eddy_definir_lembrete(uuid, boolean, integer, text) from public, anon, authenticated;
