-- CATÁLOGO VAZIO É A PRIMEIRA PERGUNTA DO ROTEIRO.
--
-- 10/10/2026, PRODUÇÃO, S-William: o combinado é o dono chegar sem nada e o
-- Eddy ir cadastrando serviço e valor conforme ele fala. O salão tinha 0
-- serviços, e a lista de pendências não tinha NENHUMA sobre serviço: ela só
-- pergunta o preço de serviço que já existe. Depois do sinal, a próxima
-- pergunta seria teste de mecha, foto de "Chocolate" e "o que é Chanel" --
-- o Eddy nunca chegaria a "quais serviços você faz e quanto custa".
--
-- E as mensagens de SISTEMA do WhatsApp (sem texto: troca de número, aviso de
-- segurança) entravam na fila e no vigia como se fossem alguém esperando
-- resposta: 10/10 12:52, alerta falso de "sem resposta" para o final 0621.

-- 1. Catálogo vazio: pendência de prioridade 5, antes de tudo.
do $do$
declare
  v_def  text := pg_get_functiondef('app.onboarding_pendencies(uuid)'::regprocedure);
  v_novo text;
begin
  if position('CATALOGO_VAZIO' in v_def) > 0 then
    return;
  end if;
  v_novo := replace(v_def, $a$  select 'SERVICOS'::text,$a$, $b$  select 'SERVICOS'::text,
         'CATALOGO_VAZIO',
         'Quais serviços você faz e quanto cobra em cada um? Pode mandar tudo de uma vez, escrito ou por áudio, do jeito que você fala pra cliente (ex.: corte R$ 80, escova R$ 50, progressiva a partir de R$ 250).',
         'O catálogo está vazio: sem serviço a atendente não tem o que oferecer nem marcar. Cada serviço que ele citar vira criar_servico, com o preço se ele disse; sem preço, crie e pergunte o preço depois.',
         5
   where not exists (
     select 1 from app.services s, config c
      where s.tenant_id = p_tenant_id
        and s.configuration_draft_id = c.id
        and s.status = 'ACTIVE')

  union all

  select 'SERVICOS'::text,$b$);
  if v_novo = v_def then
    raise exception 'ancora de onboarding_pendencies sumiu';
  end if;
  execute v_novo;
end;
$do$;

-- 2. Mensagem de sistema não espera resposta.
do $do$
declare
  v_def  text := pg_get_functiondef('app.recebidas_pendentes(interval, boolean)'::regprocedure);
  v_novo text;
begin
  if position('SYSTEM''' in v_def) > 0 and position('message_type' in v_def) > 0 then
    return;
  end if;
  v_novo := replace(v_def, $a$     where m.direction = 'INBOUND'
       and m.occurred_at > statement_timestamp() - p_desde$a$, $b$     where m.direction = 'INBOUND'
       and m.message_type <> 'SYSTEM'
       and m.occurred_at > statement_timestamp() - p_desde$b$);
  if v_novo = v_def then
    raise exception 'ancora de recebidas_pendentes sumiu';
  end if;
  execute v_novo;
end;
$do$;

do $do$
declare
  v_def  text := pg_get_functiondef('app.mensagens_sem_resposta(integer)'::regprocedure);
  v_novo text;
begin
  if position('message_type' in v_def) > 0 then
    return;
  end if;
  v_novo := replace(v_def, $a$     where m.occurred_at > statement_timestamp() - interval '7 days'
       and coalesce(m.metadata_minimized->>'deliveryStatus', '') <> 'CANCELLED'$a$, $b$     where m.occurred_at > statement_timestamp() - interval '7 days'
       and m.message_type <> 'SYSTEM'
       and coalesce(m.metadata_minimized->>'deliveryStatus', '') <> 'CANCELLED'$b$);
  if v_novo = v_def then
    raise exception 'ancora de mensagens_sem_resposta sumiu';
  end if;
  execute v_novo;
end;
$do$;
