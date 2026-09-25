-- O AVISO AO DONO SAI POR MODELO QUANDO A JANELA DE 24H ESTA FECHADA.
--
-- 25/09/2026: a pergunta da atendente so chegava ao dono se ele tivesse
-- falado com o Eddy nas ultimas 24h. Fora disso, enqueue_outbound_message
-- recusava (SERVICE_WINDOW_CLOSED) e a cliente ficava esperando uma resposta
-- que ninguem ia dar. O WhatsApp deixa a empresa escrever primeiro com modelo
-- aprovado: e o caminho oficial, pago por mensagem. O modelo `aviso_ao_dono`
-- e criado na Meta pela funcao whatsapp-templates.
--
-- Quando o dono responde o modelo, a janela abre e o Eddy volta a conversar
-- em texto livre.

do $mig$
declare
  v_def text := pg_get_functiondef('app.avisar_dono_da_pergunta()'::regprocedure);
  c_ancora constant text := E'  if coalesce((v_r->>''ok'')::boolean, false) then\n';
begin
  if position(c_ancora in v_def) = 0 then
    raise exception 'ancora de avisar_dono_da_pergunta sumiu';
  end if;
  execute replace(v_def, c_ancora,
       E'  -- Janela fechada: modelo aprovado. Lacuna de modelo nao aceita quebra\n'
    || E'  -- de linha nem espaco repetido, e tem limite de tamanho.\n'
    || E'  if coalesce(v_r->>''reason'', '''') = ''SERVICE_WINDOW_CLOSED'' then\n'
    || E'    v_r := app.enqueue_outbound_template(\n'
    || E'      new.tenant_id, v_conversa, ''AVISO_AO_DONO'',\n'
    || E'      jsonb_build_array(\n'
    || E'        (select t.display_name from app.tenants t where t.id = new.tenant_id),\n'
    || E'        coalesce(v_cliente, ''?''),\n'
    || E'        left(regexp_replace(new.question, ''\\s+'', '' '', ''g''), 700),\n'
    || E'        ''#'' || coalesce(new.codigo, ''?'')),\n'
    || E'      ''pergunta-modelo:'' || new.id::text || '':'' || left(md5(new.question), 8),\n'
    || E'      v_texto);\n'
    || E'  end if;\n\n'
    || c_ancora);
end
$mig$;

revoke all on function app.avisar_dono_da_pergunta() from public, anon, authenticated;
