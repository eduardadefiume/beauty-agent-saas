-- O COMPROMISSO DE UMA PESSOA NAO FECHA A AGENDA DO SALAO INTEIRO.
--
-- 23/09/2026. `app.member_calendar_shifts` guarda `member_name` desde que
-- nasceu -- a sincronizacao com o Google escreve de quem e cada evento. Mas a
-- funcao que entrega esses eventos ao motor de agenda devolvia so o inicio e o
-- fim, jogando o nome fora. E do outro lado, em scheduling-api:
--
--     calendarShifts.flatMap((shift) =>
--       members.map((member) => ({ subjectId: member.id, ... })))
--
-- Cada evento virava ocupacao de TODA a equipe.
--
-- O QUE ISSO FAZ NUM SALAO DE VERDADE: a dona conecta o Google dela, tem
-- dentista na terca as 14h, e a Karen e a Duda somem da agenda naquele
-- horario. A cliente que queria a Karen as 14h ouve "nao tenho horario". O
-- salao perde o atendimento e ninguem descobre por que -- nao ha erro, ha um
-- "nao tenho" educado.
--
-- Hoje isso nao machucou ninguem porque as duas conexoes do piloto estao
-- DISCONNECTED e ERROR, e `member_calendar_shifts` tem zero linhas. Consertar
-- antes de religar e barato; depois seria um bug com cliente na frente.
--
-- A unica mudanca aqui e devolver `memberName`. Quem decide o que fazer com
-- ele e o motor, do outro lado.

create or replace function public.schedule_list_calendar_shifts(
  target_site_project_id text,
  target_email text,
  target_tenant_id uuid,
  target_unit_id uuid
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
      'startMs', floor(extract(epoch from lower(s.time_range)) * 1000),
      'endMs',   floor(extract(epoch from upper(s.time_range)) * 1000),
      -- Nulo aqui quer dizer "agenda do salao", e ai bloquear todo mundo e o
      -- certo: o salao fechou naquele horario. Nome preenchido quer dizer
      -- "agenda de uma pessoa", e ai so ela some.
      'memberName', s.member_name
    ) order by lower(s.time_range))
    from app.member_calendar_shifts s
    where s.tenant_id = target_tenant_id and s.unit_id = target_unit_id
  ), '[]'::jsonb);
end;
$function$;

comment on function public.schedule_list_calendar_shifts(text, text, uuid, uuid) is
  'Eventos vindos da agenda externa, COM o dono de cada um. Sem memberName o motor bloqueava a equipe inteira a cada compromisso pessoal.';
