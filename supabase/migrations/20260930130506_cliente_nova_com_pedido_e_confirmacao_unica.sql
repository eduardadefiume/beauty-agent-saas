-- DEFEITOS 2 E 3 DA AGENDA REAL (30/09/2026, DEV).
--
-- 2. A cliente escreveu "Queria cortar com o William na quarta dia 7, as
--    14h. Tem?" e ouviu so "Oi! Tudo bem? / Qual o seu nome?". O bloco
--    CLIENTE_NOVA mandava perguntar o nome e PARAR, mesmo com o pedido feito.
--    Agora: quem so cumprimentou recebe a pergunta do nome; quem ja pediu
--    algo recebe a resposta, e o nome vem no fim da mesma mensagem.
update app.agent_prompt_blocks
   set body = 'CLIENTE NOVA SE RECEBE, NÃO SE INTERROGA
Depende do que ela escreveu:
  A) Só cumprimentou ("oi", "bom dia", "tudo bem?"): cumprimente, devolvendo a pergunta se ela perguntou como você está. Se `contact.displayName` não traz o nome dela, pergunte "Qual o seu nome?" e PARE nessa mensagem. Sabendo o nome, dê as boas-vindas com o nome e pergunte como pode ajudar.
  B) Já disse o que quer ou já perguntou alguma coisa (preço, horário, "tem quarta às 14h?"): o pedido dela NUNCA fica sem resposta por causa do nome. Cumprimente e já siga o atendimento do que ela pediu. Se não sabe o nome, pergunte no fim da mesma mensagem, de leve ("E qual o seu nome?").
O nome é obrigatório antes de reservar_horario: se ela aceitar um horário sem ter dito o nome, peça o nome e só marque depois.
Se `contact.displayName` já traz o nome, use e NÃO pergunte.
Assim que ela disser o nome, grave com anotar_na_ficha, no campo nome.
Pedir foto do cabelo de quem só deu bom dia é atropelar a pessoa: ela ainda não pediu nada.'
 where agent = 'CLIENTE' and code = 'CLIENTE_NOVA' and status = 'ACTIVE';

-- 3. Depois de marcar saiam duas confirmacoes seguidas: o "Marcado, Bianca!
--    Quarta 07/10 as 16h" da atendente e a mensagem de confirmacao que o
--    dono escreveu. A do dono e a oficial; quando ela existe, o "marcado" da
--    atendente nao sai. A atendente pergunta isto antes de enviar.
create or replace function app.agente_tem_finalizacao(p_appointment_id uuid)
returns boolean
language sql
stable
security definer
set search_path to ''
as $fn$
  select coalesce(nullif(trim(cv.snapshot ->> 'finalMessageTemplate'), '') is not null, false)
      or coalesce(sc.confirmacao_foto_caminho is not null, false)
    from app.appointments a
    left join app.configuration_versions cv on cv.id = a.configuration_version_id
    left join app.agent_scope sc on sc.tenant_id = a.tenant_id
   where a.id = p_appointment_id;
$fn$;

create or replace function public.agente_tem_finalizacao(p_appointment_id uuid)
returns boolean language sql stable security definer set search_path to ''
as $$ select app.agente_tem_finalizacao(p_appointment_id); $$;

revoke all on function app.agente_tem_finalizacao(uuid) from public, anon, authenticated;
revoke all on function public.agente_tem_finalizacao(uuid) from public, anon, authenticated;
grant execute on function public.agente_tem_finalizacao(uuid) to service_role;