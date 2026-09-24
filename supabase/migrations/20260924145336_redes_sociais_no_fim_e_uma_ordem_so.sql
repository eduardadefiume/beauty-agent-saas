-- REDES SOCIAIS NO FIM, E UMA ORDEM SO.
--
-- 24/09/2026, teste com dono-robo. Com REDES_SOCIAIS logo depois do endereco
-- o Eddy pulou a pergunta tres vezes seguidas: depois do endereco foi para a
-- equipe, depois dos horarios foi para a disponibilidade. O modelo segue o
-- encadeamento natural (horario puxa quem trabalha em que horario), e o bloco
-- EDDY_UMA_COISA_POR_VEZ ainda mandava "comece pelo que destrava mais".
--
-- Redes sociais nao destravam nada, entao vao para o fim, depois do lembrete
-- e antes de ligar o WhatsApp: quando o resto acaba, ela e a proxima e nao
-- disputa com nada. E o bloco passa a apontar para o roteiro.

do $mig$
declare
  v_def text := pg_get_functiondef('app.owner_setup_state(uuid)'::regprocedure);
  c_de constant text := E'      select 12, jsonb_build_object(\n        ''campo'', ''REDES_SOCIAIS'',';
  c_para constant text := E'      select 66, jsonb_build_object(\n        ''campo'', ''REDES_SOCIAIS'',';
begin
  if position(c_de in v_def) = 0 then
    raise exception 'REDES_SOCIAIS nao esta na ordem 12';
  end if;
  execute replace(v_def, c_de, c_para);
end
$mig$;

update app.agent_prompt_blocks
   set body = $txt$UMA COISA POR VEZ
Você tem o roteiro do cadastro dele. Ele é SEU, não dele: serve para você saber o que perguntar em seguida, e não para ser despejado.

Pergunte UMA coisa por mensagem e espere. Cinco perguntas seguidas viram um formulário, e formulário é o que ele já não quis preencher sozinho.

A próxima pergunta é sempre a PRÓXIMA PERGUNTA do roteiro, mesmo que outra pareça puxar a conversa. Se ele mandar cinco coisas de uma vez, grave as cinco e agradeça, sem pedir de novo o que ele já disse.$txt$,
       updated_at = statement_timestamp()
 where agent = 'DONO' and code = 'EDDY_UMA_COISA_POR_VEZ' and status = 'ACTIVE';
