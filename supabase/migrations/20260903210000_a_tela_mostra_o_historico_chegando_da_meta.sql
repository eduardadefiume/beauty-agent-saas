-- A TELA PRECISA MOSTRAR O HISTORICO CHEGANDO
--
-- O Coexistence nao entrega os 180 dias de uma vez. Sao tres fases -- o dia de
-- hoje, depois ate 90 dias, depois ate 180 -- e cada fase chega em pedacos,
-- fora de ordem, ao longo de minutos ou horas. Sem uma tela que mostre isso, o
-- William clica em "importar", nao ve nada acontecer, e conclui que nao
-- funcionou -- no exato momento em que esta funcionando.
--
-- Entao a tela precisa de tres respostas: chegou alguma coisa? em que fase
-- estamos? alguma entrega deu erro de leitura e ficou guardada crua esperando?
--
-- `origem` em cada conversa e o outro pedaco: agora existem dois caminhos de
-- entrada (o arquivo .txt exportado e a Meta), e quem olha a lista precisa
-- saber de onde cada conversa veio antes de tirar conclusao sobre o que falta.

create or replace function public.site_wa_archives(
  target_site_project_id text,
  target_email           text,
  target_tenant_id       uuid
)
returns jsonb
language plpgsql
stable
security definer
set search_path to ''
as $function$
begin
  perform private.require_site_tenant(
    target_site_project_id, target_email, target_tenant_id,
    array['OWNER']::app.tenant_role[]
  );

  return jsonb_build_object(
    'autorizacao', (
      select jsonb_build_object(
               'autorizadoPor', a.authorized_by, 'quando', a.authorized_at,
               'base', a.legal_basis, 'nota', a.note)
        from app.data_authorizations a
       where a.tenant_id = target_tenant_id
         and a.scope = 'HISTORICO_WHATSAPP' and a.revoked_at is null
    ),
    'resumo', (
      select jsonb_build_object(
               'conversas', count(*),
               'prontas', count(*) filter (where status = 'PRONTO'),
               'naFila', count(*) filter (where status in ('PENDENTE', 'LENDO')),
               'falhas', count(*) filter (where status = 'FALHOU'),
               'semAmarra', count(*) filter (where contact_id is null),
               'daMeta', count(*) filter (where source = 'COEXISTENCE'),
               'mensagens', coalesce(sum(message_count), 0))
        from app.wa_archives where tenant_id = target_tenant_id
    ),
    -- O andamento da importacao pela Meta. `progresso` e o da entrega mais
    -- recente; `fase` a maior ja vista. Fase 2 com progresso 100 e o fim.
    'coexistencia', (
      select jsonb_build_object(
               'entregas', count(*),
               'mensagensLidas', coalesce(sum(d.mensagens_lidas), 0),
               'contatosLidos', coalesce(sum(d.contatos_lidos), 0),
               'fase', max(d.phase),
               'progresso', (select d2.progress from app.wa_coexistence_deliveries d2
                              where d2.tenant_id = target_tenant_id and d2.progress is not null
                              order by d2.received_at desc limit 1),
               'ultimaEm', max(d.received_at),
               'guardadasSemLer', count(*) filter (where d.parse_error is not null),
               'ultimoErro', (select d3.parse_error from app.wa_coexistence_deliveries d3
                               where d3.tenant_id = target_tenant_id
                                 and d3.parse_error is not null
                                 and d3.parse_error <> 'ECO_GUARDADO_SEM_INTERPRETAR'
                               order by d3.received_at desc limit 1))
        from app.wa_coexistence_deliveries d where d.tenant_id = target_tenant_id
    ),
    'conversas', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', a.id, 'nome', a.contact_label, 'telefone', a.phone_digits,
               'arquivo', a.source_filename, 'status', a.status,
               'origem', a.source,
               'mensagens', a.message_count, 'comMidia', a.media_count,
               'de', a.first_message_at, 'ate', a.last_message_at,
               'erro', a.read_error,
               'contactId', a.contact_id,
               'clienteNoCrm', (select c.display_name from app.crm_contacts c where c.id = a.contact_id)
             ) order by a.last_message_at desc nulls last, a.created_at desc)
        from app.wa_archives a where a.tenant_id = target_tenant_id
    ), '[]'::jsonb)
  );
end;
$function$;

grant execute on function public.site_wa_archives(text, text, uuid) to service_role;
