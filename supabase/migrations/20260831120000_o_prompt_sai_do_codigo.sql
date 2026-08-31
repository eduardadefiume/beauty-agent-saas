-- O prompt sai do código.
--
-- POR QUE. Em duas horas de teste ao vivo foram mais de dez correções, e quase
-- todas eram TEXTO: uma frase de voz, uma regra de comportamento, um exemplo.
-- Cada uma delas custava um deploy de 60 KB da edge function. Duas coisas
-- ruins saíram disso: a lentidão do ciclo, e a divergência entre o arquivo do
-- repositório e o que estava publicado, porque o payload de deploy era montado
-- à mão toda vez.
--
-- A LINHA, que já valia para as regras do salão, agora vale para o prompt:
--   Em código fica o MOTOR. O laço de decisão, as ferramentas, as travas que
--   não podem depender de o modelo se comportar (não afirmar agendamento que
--   não existe, não usar travessão, não mandar mensagem vazia).
--   Em dados fica o TEXTO. O que o agente é, como ele fala, o que ele nunca
--   faz. Isso muda toda semana e não deveria exigir deploy.
--
-- POR QUE GLOBAL, SEM tenant_id. Esta tabela é o PRODUTO, não o salão. Vale
-- igual para o William, para o studio de cílios e para a manicure. O que é de
-- cada negócio continua em `app.agent_policies`, que é por tenant. Misturar as
-- duas seria desfazer a separação que a gente levou o dia inteiro para
-- construir.
--
-- POR QUE EM BLOCOS e não um texto só. Para a tela conseguir listar, ligar e
-- desligar bloco a bloco, e para o histórico mostrar qual regra mudou quando o
-- comportamento mudar. Um textão de 8 KB num textarea é ilegível e ninguém
-- consegue revisar.
--
-- A ORDEM É DETERMINÍSTICA de propósito: o prompt entra no prefixo cacheado da
-- API. Se a concatenação mudar de ordem entre duas chamadas, o cache é perdido
-- em silêncio e o custo por mensagem sobe sem ninguém perceber.

create table if not exists app.agent_prompt_blocks (
  id         uuid primary key default gen_random_uuid(),

  -- Identificador estável para eu conseguir editar um bloco por nome, sem
  -- depender de posição nem de uuid.
  code       text not null unique check (code ~ '^[A-Z0-9_]{3,60}$'),

  -- Só para a tela e para o commit: nunca vai para o modelo.
  title      text not null check (length(trim(title)) between 3 and 120),

  body       text not null check (length(trim(body)) between 3 and 6000),

  position   integer not null,
  status     text not null default 'ACTIVE' check (status in ('ACTIVE', 'DRAFT')),

  created_at timestamptz not null default statement_timestamp(),
  updated_at timestamptz not null default statement_timestamp()
);

comment on table app.agent_prompt_blocks is
  'O prompt do agente, em blocos, fora do codigo. E GLOBAL: isto e o produto. O que muda de salao para salao vive em app.agent_policies, por tenant.';

create index if not exists agent_prompt_blocks_ordem_idx
  on app.agent_prompt_blocks (position) where status = 'ACTIVE';

create or replace function app.agent_prompt()
returns text
language sql
stable
security definer
set search_path to ''
as $function$
  select string_agg(b.body, E'\n\n' order by b.position, b.code)
    from app.agent_prompt_blocks b
   where b.status = 'ACTIVE';
$function$;

comment on function app.agent_prompt() is
  'O prompt inteiro, montado na ordem. A ordem e deterministica porque este texto entra no prefixo cacheado da API: ordem instavel derruba o cache em silencio.';

create or replace function public.agent_prompt()
returns text
language sql
stable
security definer
set search_path to ''
as $function$
  select app.agent_prompt();
$function$;

revoke all on function app.agent_prompt() from public, anon, authenticated;
revoke all on function public.agent_prompt() from public, anon, authenticated;
grant execute on function app.agent_prompt() to service_role;
grant execute on function public.agent_prompt() to service_role;
