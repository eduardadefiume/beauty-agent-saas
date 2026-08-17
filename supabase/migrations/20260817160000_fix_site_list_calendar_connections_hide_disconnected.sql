-- Corrige listagem de conexoes de calendario no configurador.
--
-- Sintoma observado pela proprietaria: apos desconectar uma conexao quebrada, o
-- card continuava aparecendo na tela mesmo recarregando a pagina.
--
-- Causa: site_list_calendar_connections filtrava apenas por tenant_id e
-- devolvia tambem as linhas com status DISCONNECTED. A funcao irma
-- site_list_calendar_connections_for_sync ja filtrava por
-- status in ('ACTIVE','ERROR'); a de listagem nao acompanhou.
--
-- Correcao: excluir DISCONNECTED da listagem. A linha permanece no banco para
-- historico e auditoria, apenas deixa de ser apresentada como conexao existente.
-- Nenhuma outra coluna, ordenacao ou contrato de retorno muda.
--
-- Verificado apos aplicar, com o tenant do piloto que tinha duas linhas
-- (uma ACTIVE e uma DISCONNECTED): a funcao passou a devolver 1 item.

create or replace function public.site_list_calendar_connections(
  target_site_project_id text,
  target_email text,
  target_tenant_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $function$
begin
  perform private.require_site_tenant(target_site_project_id, target_email, target_tenant_id, null);

  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', c.id,
      'provider', c.provider,
      'memberName', c.member_name,
      'externalAccountEmail', c.external_account_email,
      'status', c.status,
      'lastSyncedAt', c.last_synced_at,
      'lastError', c.last_error,
      'createdAt', c.created_at
    ) order by c.created_at)
    from app.calendar_connections c
    where c.tenant_id = target_tenant_id
      and c.status <> 'DISCONNECTED'
  ), '[]'::jsonb);
end;
$function$;

-- CREATE OR REPLACE pode restaurar o grant padrao de EXECUTE a PUBLIC.
-- Reaplicar o fecho de F0-01b para nao reabrir a funcao ao papel anonimo.
-- Verificado apos aplicar: anon sem EXECUTE, e o total de funcoes de public
-- alcancaveis por anon permaneceu em zero.
revoke execute on function public.site_list_calendar_connections(text, text, uuid) from public;
revoke execute on function public.site_list_calendar_connections(text, text, uuid) from anon, authenticated;
