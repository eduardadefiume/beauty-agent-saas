-- AVISO AO DONO NAO ENTERRA A MENSAGEM DELE.
--
-- 24/09/2026, teste com dono-robo, logo depois de 20260924184711. O dono
-- mandou uma mensagem ao Eddy e, segundos depois, dois avisos de pergunta da
-- atendente foram enfileirados na mesma conversa (actor SYSTEM). A fila do
-- Eddy olha a ULTIMA mensagem da conversa -- que passou a ser o aviso, de
-- saida -- e concluiu que nao havia nada para responder. O dono ficou sem
-- resposta.
--
-- Aviso automatico nao e resposta do Eddy: a fila passa a ignora-lo.

do $mig$
declare
  v_def text := pg_get_functiondef('app.list_owner_conversations_awaiting_eddy(integer, integer)'::regprocedure);
  c_ancora constant text := E'     where coalesce(m.metadata_minimized->>''deliveryStatus'', '''') <> ''CANCELLED''\n';
begin
  if position(c_ancora in v_def) = 0 then
    raise exception 'ancora de list_owner_conversations_awaiting_eddy sumiu';
  end if;
  execute replace(v_def, c_ancora,
    c_ancora
    || E'       and not (m.direction = ''OUTBOUND'' and m.metadata_minimized->>''actor'' = ''SYSTEM'')\n');
end
$mig$;
