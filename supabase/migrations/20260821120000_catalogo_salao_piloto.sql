-- Catálogo do salão-piloto: serviços reais, equipe real, horário real.
--
-- POR QUE ISTO EXISTE. Até aqui o piloto tinha um serviço chamado "Coloração
-- QA", sem preço, com uma "Colorista QA" atendendo das 00:00 às 23:45 sete dias
-- por semana. Dava para provar que o encanamento funciona, mas não dava para
-- olhar uma resposta do agente e dizer se ela presta. Este cadastro é o dado
-- que torna o teste do agente uma informação, e não uma formalidade.
--
-- FONTE. Ditado pela Duda a partir do que ela lembra do salão do William, para
-- teste. Não é o cadastro definitivo do cliente — quando o William sentar para
-- cadastrar o dele, este aqui sai.
--
-- POR QUE COMO MIGRAÇÃO. Mesmo precedente de
-- 20260818180000_move_whatsapp_channel_to_pilot_tenant.sql: é dado de tenant,
-- mas é dado que precisa ser reproduzível e revisável. Roda no rascunho aberto
-- (revisão 12) e é idempotente — limpa o rascunho antes de escrever, então
-- rodar duas vezes dá o mesmo resultado.
--
-- O QUE NÃO ESTÁ AQUI, E POR QUÊ:
--
--   PREÇO. A Duda não passou preço nenhum, e preço de salão não se adivinha.
--   base_price_minor fica nulo de propósito: app.build_agent_context devolve
--   nulo como nulo, e o prompt do agente manda dizer "vou confirmar com a
--   equipe" em vez de estimar. Errar preço na primeira semana queima a
--   confiança da cliente e a do dono.
--
--   TOLERÂNCIA DE ALMOÇO. A Duda disse que se um procedimento passar 10 ou 15
--   minutos do meio-dia não tem problema. Não existe campo para isso hoje: o
--   horário é uma lista de faixas, e uma faixa que termina 12:00 termina 12:00.
--   Cadastrar 12:15 seria pior, porque permitiria COMEÇAR um serviço 12:10.
--   Fica registrado como lacuna, não como algo resolvido.
--
--   JANELA DE PROCESSAMENTO. minimum/maximum_duration_minutes ficam iguais a
--   duration_minutes. Os campos existem para tolerância química ("a pausa pode
--   ir de 50 a 70 minutos"), mas a Duda passou tempos exatos e inventar
--   tolerância de química de alisamento não é papel de quem escreve o código.

do $$
declare
  v_tenant   uuid := '4b2a8e37-1716-41c4-9201-eefce890638d';  -- Piloto Eduarda
  v_draft    uuid := '00ba4dc0-4367-4296-a8ce-25f51212cb81';  -- rascunho aberto, revisão 12
  v_tipo_cadeira uuid;
  v_servico  uuid;
  v_etapa    uuid;
  v_spec     jsonb;
  v_item     jsonb;
  v_passo    jsonb;
  v_pos      integer;
  v_dia      integer;
  v_sabado   date;
  v_skill    record;
  v_membro   record;
begin
  -- ---------------------------------------------------------------------------
  -- Limpeza do rascunho. Ordem inversa das dependências.
  -- ---------------------------------------------------------------------------
  delete from app.service_step_resource_requirements where tenant_id = v_tenant and configuration_draft_id = v_draft;
  delete from app.service_step_skill_requirements     where tenant_id = v_tenant and configuration_draft_id = v_draft;
  delete from app.service_steps                       where tenant_id = v_tenant and configuration_draft_id = v_draft;
  delete from app.service_variations                  where tenant_id = v_tenant and configuration_draft_id = v_draft;
  delete from app.services                            where tenant_id = v_tenant and configuration_draft_id = v_draft;
  delete from app.member_dynamic_shifts               where tenant_id = v_tenant and configuration_draft_id = v_draft;
  delete from app.member_availability                 where tenant_id = v_tenant and configuration_draft_id = v_draft;
  delete from app.member_skills                       where tenant_id = v_tenant and configuration_draft_id = v_draft;
  delete from app.team_members                        where tenant_id = v_tenant and configuration_draft_id = v_draft;
  delete from app.skills                              where tenant_id = v_tenant and configuration_draft_id = v_draft;
  delete from app.resources                           where tenant_id = v_tenant and configuration_draft_id = v_draft;
  delete from app.resource_types                      where tenant_id = v_tenant and configuration_draft_id = v_draft;
  delete from app.unit_service_limits                 where tenant_id = v_tenant and configuration_draft_id = v_draft;
  delete from app.operating_hours                     where tenant_id = v_tenant and configuration_draft_id = v_draft;

  update app.configuration_drafts
     set final_message_template = 'Prontinho, seu horário está anotado. Qualquer coisa é só chamar por aqui!',
         updated_at = statement_timestamp()
   where id = v_draft;

  -- ---------------------------------------------------------------------------
  -- Horário do salão. Segunda a sexta 09:00-12:00 e 13:00-19:00;
  -- sábado 08:00-12:00 e 13:00-18:00; domingo fechado (ausência de linha).
  -- Convenção de weekday: 0 = domingo .. 6 = sábado (packages/scheduling-engine).
  -- ---------------------------------------------------------------------------
  for v_dia in 1..5 loop
    insert into app.operating_hours (tenant_id, configuration_draft_id, weekday, starts_at, ends_at)
    values (v_tenant, v_draft, v_dia, '09:00', '12:00'),
           (v_tenant, v_draft, v_dia, '13:00', '19:00');
    -- latest_end_time: o mais tarde que um serviço pode TERMINAR naquele dia.
    insert into app.unit_service_limits (tenant_id, configuration_draft_id, weekday, latest_end_time)
    values (v_tenant, v_draft, v_dia, '19:00');
  end loop;

  insert into app.operating_hours (tenant_id, configuration_draft_id, weekday, starts_at, ends_at)
  values (v_tenant, v_draft, 6, '08:00', '12:00'),
         (v_tenant, v_draft, 6, '13:00', '18:00');
  insert into app.unit_service_limits (tenant_id, configuration_draft_id, weekday, latest_end_time)
  values (v_tenant, v_draft, 6, '18:00');

  -- ---------------------------------------------------------------------------
  -- Competências. Sete, porque é o que separa quem pode fazer o quê neste
  -- salão -- não mais, para não virar burocracia de cadastro.
  -- ---------------------------------------------------------------------------
  insert into app.skills (tenant_id, configuration_draft_id, name)
  values (v_tenant, v_draft, 'Lavagem e apoio'),
         (v_tenant, v_draft, 'Alisamento e escova'),
         (v_tenant, v_draft, 'Coloração'),
         (v_tenant, v_draft, 'Mechas e descoloração'),
         (v_tenant, v_draft, 'Tratamento e hidratação'),
         (v_tenant, v_draft, 'Corte'),
         (v_tenant, v_draft, 'Penteado e maquiagem');

  -- ---------------------------------------------------------------------------
  -- Equipe.
  --
  --   Eduarda  -- dona, agenda fixa igual à do salão, faz tudo.
  --   Karen    -- auxiliar fixa, mesma agenda do salão, lavagem e apoio.
  --   Duda     -- híbrida: só sábado, e só nos sábados que ela marca.
  --
  -- Sobre a Duda: HYBRID exige member_availability (a readiness cobra), então
  -- ela tem a FAIXA de sábado cadastrada -- é a forma do dia dela. Quais
  -- sábados ela de fato vem está em member_dynamic_shifts. Quem for compor a
  -- disponibilidade dela precisa tratar os turnos como a autoridade sobre as
  -- DATAS e a faixa semanal só como a autoridade sobre as HORAS. Trocar isso
  -- deixaria a Duda agendável em todo sábado do ano.
  -- ---------------------------------------------------------------------------
  insert into app.team_members (tenant_id, configuration_draft_id, name, member_type, availability_mode)
  values (v_tenant, v_draft, 'Eduarda', 'PROFESSIONAL', 'FIXED'),
         (v_tenant, v_draft, 'Karen',   'ASSISTANT',    'FIXED'),
         (v_tenant, v_draft, 'Duda',    'PROFESSIONAL', 'HYBRID');

  for v_membro in
    select m.id, m.name from app.team_members m
     where m.tenant_id = v_tenant and m.configuration_draft_id = v_draft
  loop
    for v_skill in
      select s.id, s.name from app.skills s
       where s.tenant_id = v_tenant and s.configuration_draft_id = v_draft
    loop
      if v_membro.name = 'Eduarda'
         or (v_membro.name = 'Karen' and v_skill.name = 'Lavagem e apoio')
         or (v_membro.name = 'Duda'  and v_skill.name <> 'Mechas e descoloração')
      then
        insert into app.member_skills (tenant_id, configuration_draft_id, member_id, skill_id)
        values (v_tenant, v_draft, v_membro.id, v_skill.id);
      end if;
    end loop;

    if v_membro.name in ('Eduarda', 'Karen') then
      for v_dia in 1..5 loop
        insert into app.member_availability (tenant_id, configuration_draft_id, member_id, weekday, starts_at, ends_at)
        values (v_tenant, v_draft, v_membro.id, v_dia, '09:00', '12:00'),
               (v_tenant, v_draft, v_membro.id, v_dia, '13:00', '19:00');
      end loop;
    end if;

    -- Todo mundo trabalha no sábado; a Duda, só nos sábados dela.
    insert into app.member_availability (tenant_id, configuration_draft_id, member_id, weekday, starts_at, ends_at)
    values (v_tenant, v_draft, v_membro.id, 6, '08:00', '12:00'),
           (v_tenant, v_draft, v_membro.id, 6, '13:00', '18:00');

    if v_membro.name = 'Duda' then
      foreach v_sabado in array array[
        date '2026-08-29',
        date '2026-09-12', date '2026-09-19',
        date '2026-10-03', date '2026-10-17', date '2026-10-31',
        date '2026-11-14', date '2026-11-28'
      ] loop
        insert into app.member_dynamic_shifts (tenant_id, configuration_draft_id, member_id, shift_date, starts_at, ends_at)
        values (v_tenant, v_draft, v_membro.id, v_sabado, '08:00', '12:00'),
               (v_tenant, v_draft, v_membro.id, v_sabado, '13:00', '18:00');
      end loop;
    end if;
  end loop;

  -- ---------------------------------------------------------------------------
  -- Cadeiras.
  --
  -- Existem por causa do teste de mechas: ele ocupa uma cadeira por uma hora e
  -- não ocupa ninguém da equipe. Sem o conceito de recurso, o motor não teria
  -- como dizer "cabe" ou "não cabe" para um procedimento que não consome
  -- profissional.
  -- ---------------------------------------------------------------------------
  insert into app.resource_types (tenant_id, configuration_draft_id, name, description)
  values (v_tenant, v_draft, 'Cadeira', 'Cadeira de atendimento do salão.')
  returning id into v_tipo_cadeira;

  insert into app.resources (tenant_id, configuration_draft_id, resource_type_id, name, capacity)
  values (v_tenant, v_draft, v_tipo_cadeira, 'Cadeira 1', 1),
         (v_tenant, v_draft, v_tipo_cadeira, 'Cadeira 2', 1),
         (v_tenant, v_draft, v_tipo_cadeira, 'Cadeira 3', 1),
         (v_tenant, v_draft, v_tipo_cadeira, 'Cadeira 4', 1);

  -- ---------------------------------------------------------------------------
  -- Serviços.
  --
  -- Descrito como jsonb e percorrido em laço porque a lista é longa e repetitiva
  -- -- vinte e seis serviços escritos à mão em INSERT viram vinte e seis
  -- oportunidades de errar uma etapa em silêncio.
  --
  -- Nomes duplicados de propósito: "Progressiva japonesa", "3D" e "4D" são o
  -- mesmo procedimento da progressiva com formol, mas a cliente pede pelo nome
  -- que conhece. Se o agente só souber "progressiva com formol", ele não
  -- entende quem escreve "quanto tempo leva a japonesa?".
  --
  -- "passiva": etapa de pausa. Marcada PASSIVE e releases_member, porque durante
  -- a pausa a cliente está ocupada mas a profissional não -- é o que permite
  -- encaixar outra cliente no meio.
  -- ---------------------------------------------------------------------------
  v_spec := $spec$
  [
    {"nome":"Progressiva sem formol","desc":"Alisamento sem formol, cabelo médio. Também vendido como Fio terapia.",
     "etapas":[{"n":"Lavagem","m":5,"c":"CLEANSE","s":"Lavagem e apoio"},
               {"n":"Pré-secagem","m":15,"c":"DRY","s":"Lavagem e apoio"},
               {"n":"Aplicação do produto","m":15,"c":"APPLY","s":"Alisamento e escova"},
               {"n":"Pausa","m":60,"c":"PROCESS","passiva":true},
               {"n":"Enxágue","m":5,"c":"RINSE","s":"Lavagem e apoio"},
               {"n":"Escova","m":20,"c":"STYLE","s":"Alisamento e escova"},
               {"n":"Chapinha","m":90,"c":"FINISH","s":"Alisamento e escova"}]},

    {"nome":"Fio terapia","desc":"Mesmo procedimento da progressiva sem formol, cabelo médio.",
     "etapas":[{"n":"Lavagem","m":5,"c":"CLEANSE","s":"Lavagem e apoio"},
               {"n":"Pré-secagem","m":15,"c":"DRY","s":"Lavagem e apoio"},
               {"n":"Aplicação do produto","m":15,"c":"APPLY","s":"Alisamento e escova"},
               {"n":"Pausa","m":60,"c":"PROCESS","passiva":true},
               {"n":"Enxágue","m":5,"c":"RINSE","s":"Lavagem e apoio"},
               {"n":"Escova","m":20,"c":"STYLE","s":"Alisamento e escova"},
               {"n":"Chapinha","m":90,"c":"FINISH","s":"Alisamento e escova"}]},

    {"nome":"Progressiva com formol","desc":"Alisamento com formol, cabelo médio.",
     "etapas":[{"n":"Lavagem","m":5,"c":"CLEANSE","s":"Lavagem e apoio"},
               {"n":"Pré-secagem","m":15,"c":"DRY","s":"Lavagem e apoio"},
               {"n":"Aplicação do produto","m":15,"c":"APPLY","s":"Alisamento e escova"},
               {"n":"Escova","m":20,"c":"STYLE","s":"Alisamento e escova"},
               {"n":"Chapinha","m":90,"c":"FINISH","s":"Alisamento e escova"}]},

    {"nome":"Progressiva japonesa","desc":"Mesmo procedimento da progressiva com formol, cabelo médio.",
     "etapas":[{"n":"Lavagem","m":5,"c":"CLEANSE","s":"Lavagem e apoio"},
               {"n":"Pré-secagem","m":15,"c":"DRY","s":"Lavagem e apoio"},
               {"n":"Aplicação do produto","m":15,"c":"APPLY","s":"Alisamento e escova"},
               {"n":"Escova","m":20,"c":"STYLE","s":"Alisamento e escova"},
               {"n":"Chapinha","m":90,"c":"FINISH","s":"Alisamento e escova"}]},

    {"nome":"Progressiva 3D","desc":"Mesmo procedimento da progressiva com formol, cabelo médio.",
     "etapas":[{"n":"Lavagem","m":5,"c":"CLEANSE","s":"Lavagem e apoio"},
               {"n":"Pré-secagem","m":15,"c":"DRY","s":"Lavagem e apoio"},
               {"n":"Aplicação do produto","m":15,"c":"APPLY","s":"Alisamento e escova"},
               {"n":"Escova","m":20,"c":"STYLE","s":"Alisamento e escova"},
               {"n":"Chapinha","m":90,"c":"FINISH","s":"Alisamento e escova"}]},

    {"nome":"Progressiva 4D","desc":"Mesmo procedimento da progressiva com formol, cabelo médio.",
     "etapas":[{"n":"Lavagem","m":5,"c":"CLEANSE","s":"Lavagem e apoio"},
               {"n":"Pré-secagem","m":15,"c":"DRY","s":"Lavagem e apoio"},
               {"n":"Aplicação do produto","m":15,"c":"APPLY","s":"Alisamento e escova"},
               {"n":"Escova","m":20,"c":"STYLE","s":"Alisamento e escova"},
               {"n":"Chapinha","m":90,"c":"FINISH","s":"Alisamento e escova"}]},

    {"nome":"Violet","desc":"Progressiva para cabelo loiro, cabelo médio.",
     "etapas":[{"n":"Lavagem","m":5,"c":"CLEANSE","s":"Lavagem e apoio"},
               {"n":"Pré-secagem","m":15,"c":"DRY","s":"Lavagem e apoio"},
               {"n":"Aplicação do produto","m":15,"c":"APPLY","s":"Alisamento e escova"},
               {"n":"Pausa","m":20,"c":"PROCESS","passiva":true},
               {"n":"Escova","m":30,"c":"STYLE","s":"Alisamento e escova"},
               {"n":"Chapinha","m":90,"c":"FINISH","s":"Alisamento e escova"}]},

    {"nome":"Selante sem formol","desc":"Selagem sem formol, cabelo médio.",
     "etapas":[{"n":"Lavagem","m":5,"c":"CLEANSE","s":"Lavagem e apoio"},
               {"n":"Pré-secagem","m":10,"c":"DRY","s":"Lavagem e apoio"},
               {"n":"Aplicação do produto","m":10,"c":"APPLY","s":"Alisamento e escova"},
               {"n":"Pausa","m":40,"c":"PROCESS","passiva":true},
               {"n":"Enxágue","m":5,"c":"RINSE","s":"Lavagem e apoio"},
               {"n":"Escova","m":20,"c":"STYLE","s":"Alisamento e escova"},
               {"n":"Chapinha","m":60,"c":"FINISH","s":"Alisamento e escova"}]},

    {"nome":"Selante com formol","desc":"Selagem com formol, cabelo médio.",
     "etapas":[{"n":"Lavagem","m":5,"c":"CLEANSE","s":"Lavagem e apoio"},
               {"n":"Pré-secagem","m":10,"c":"DRY","s":"Lavagem e apoio"},
               {"n":"Aplicação do produto","m":10,"c":"APPLY","s":"Alisamento e escova"},
               {"n":"Escova","m":20,"c":"STYLE","s":"Alisamento e escova"},
               {"n":"Chapinha","m":60,"c":"FINISH","s":"Alisamento e escova"}]},

    {"nome":"Botox capilar","desc":"Cabelo médio.",
     "etapas":[{"n":"Lavagem","m":5,"c":"CLEANSE","s":"Lavagem e apoio"},
               {"n":"Pré-secagem","m":10,"c":"DRY","s":"Lavagem e apoio"},
               {"n":"Aplicação do produto","m":10,"c":"APPLY","s":"Alisamento e escova"},
               {"n":"Pausa","m":30,"c":"PROCESS","passiva":true},
               {"n":"Enxágue","m":5,"c":"RINSE","s":"Lavagem e apoio"},
               {"n":"Escova","m":20,"c":"STYLE","s":"Alisamento e escova"},
               {"n":"Chapinha","m":60,"c":"FINISH","s":"Alisamento e escova"}]},

    {"nome":"Coloração","desc":null,
     "etapas":[{"n":"Aplicação do produto","m":20,"c":"APPLY","s":"Coloração"},
               {"n":"Pausa","m":40,"c":"PROCESS","passiva":true},
               {"n":"Enxágue","m":10,"c":"RINSE","s":"Lavagem e apoio"},
               {"n":"Escova","m":40,"c":"STYLE","s":"Alisamento e escova"}]},

    {"nome":"Gloss castanha","desc":null,
     "etapas":[{"n":"Aplicação do produto","m":15,"c":"APPLY","s":"Coloração"},
               {"n":"Pausa","m":15,"c":"PROCESS","passiva":true},
               {"n":"Enxágue","m":15,"c":"RINSE","s":"Lavagem e apoio"},
               {"n":"Escova","m":40,"c":"STYLE","s":"Alisamento e escova"}]},

    {"nome":"Gloss loira","desc":null,
     "etapas":[{"n":"Aplicação do produto","m":15,"c":"APPLY","s":"Coloração"},
               {"n":"Pausa","m":15,"c":"PROCESS","passiva":true},
               {"n":"Enxágue","m":15,"c":"RINSE","s":"Lavagem e apoio"},
               {"n":"Escova","m":40,"c":"STYLE","s":"Alisamento e escova"}]},

    {"nome":"Hidratação","desc":"Hidratação comum.",
     "etapas":[{"n":"Lavagem","m":5,"c":"CLEANSE","s":"Lavagem e apoio"},
               {"n":"Aplicação do produto","m":10,"c":"APPLY","s":"Tratamento e hidratação"},
               {"n":"Pausa","m":15,"c":"PROCESS","passiva":true},
               {"n":"Escova","m":30,"c":"STYLE","s":"Alisamento e escova"}]},

    {"nome":"Hidratação detox","desc":null,
     "etapas":[{"n":"Lavagem","m":5,"c":"CLEANSE","s":"Lavagem e apoio"},
               {"n":"Aplicação do produto","m":10,"c":"APPLY","s":"Tratamento e hidratação"},
               {"n":"Pausa","m":20,"c":"PROCESS","passiva":true},
               {"n":"Escova","m":30,"c":"STYLE","s":"Alisamento e escova"}]},

    {"nome":"Hidratação Joico","desc":"Tratamento em três passos, com pausa entre cada um.",
     "etapas":[{"n":"Lavagem","m":5,"c":"CLEANSE","s":"Lavagem e apoio"},
               {"n":"Aplicação do passo 2","m":5,"c":"APPLY","s":"Tratamento e hidratação"},
               {"n":"Pausa do passo 2","m":10,"c":"PROCESS","passiva":true},
               {"n":"Aplicação do passo 3","m":5,"c":"APPLY","s":"Tratamento e hidratação"},
               {"n":"Pausa do passo 3","m":10,"c":"PROCESS","passiva":true},
               {"n":"Aplicação do passo 4","m":5,"c":"APPLY","s":"Tratamento e hidratação"},
               {"n":"Pausa do passo 4","m":10,"c":"PROCESS","passiva":true},
               {"n":"Escova","m":30,"c":"STYLE","s":"Alisamento e escova"}]},

    {"nome":"Corte","desc":null,
     "etapas":[{"n":"Lavagem","m":5,"c":"CLEANSE","s":"Lavagem e apoio"},
               {"n":"Corte","m":30,"c":"OTHER","s":"Corte"},
               {"n":"Escova","m":30,"c":"STYLE","s":"Alisamento e escova"}]},

    {"nome":"Corte junto com alisamento — cabelo médio ou longo","desc":"Encaixe no mesmo atendimento do alisamento.",
     "etapas":[{"n":"Corte","m":15,"c":"OTHER","s":"Corte"}]},

    {"nome":"Corte junto com alisamento — cabelo muito curto (antes)","desc":"Cabelo muito curto: corta antes do alisamento.",
     "etapas":[{"n":"Corte","m":20,"c":"OTHER","s":"Corte"}]},

    {"nome":"Corte junto com alisamento — cabelo curto (no fim)","desc":"Cabelo curto razoável: corta no fim do alisamento.",
     "etapas":[{"n":"Corte","m":20,"c":"OTHER","s":"Corte"}]},

    {"nome":"Mechas morena iluminada","desc":"Cerca de 4 horas.",
     "etapas":[{"n":"Mechas","m":240,"c":"APPLY","s":"Mechas e descoloração"}]},

    {"nome":"Mechas loiras — teste no mesmo dia","desc":"Cerca de 5 horas. O teste de mecha é feito no próprio dia, antes do procedimento.",
     "teste":{"dias":1,"weekdays":[1,2,3,4,5]},
     "etapas":[{"n":"Mechas","m":300,"c":"APPLY","s":"Mechas e descoloração"}]},

    {"nome":"Mechas loiras — teste na semana","desc":"Cerca de 6 horas. Para procedimento no sábado, o teste de mecha é feito de quarta a sexta.",
     "teste":{"dias":3,"weekdays":[3,4,5]},
     "etapas":[{"n":"Mechas","m":360,"c":"APPLY","s":"Mechas e descoloração"}]},

    {"nome":"Teste de mecha","desc":"Uma hora. Ocupa só uma cadeira, não ocupa ninguém da equipe — pode ser em qualquer horário que a cliente puder.",
     "etapas":[{"n":"Teste de mecha","m":60,"c":"PROCESS","passiva":true,"cadeira":true}]},

    {"nome":"Penteado","desc":"Cerca de 1h30.",
     "etapas":[{"n":"Penteado","m":90,"c":"STYLE","s":"Penteado e maquiagem"}]},

    {"nome":"Maquiagem","desc":"Cerca de 1 hora.",
     "etapas":[{"n":"Maquiagem","m":60,"c":"STYLE","s":"Penteado e maquiagem"}]}
  ]
  $spec$::jsonb;

  for v_item in select * from jsonb_array_elements(v_spec) loop
    insert into app.services (
      tenant_id, configuration_draft_id, name, description, kind,
      base_price_minor, currency, bookable, status,
      requires_strand_test, strand_test_lead_days,
      strand_test_duration_minutes, strand_test_preferred_weekdays
    )
    values (
      v_tenant, v_draft, v_item->>'nome', v_item->>'desc',
      case when jsonb_array_length(v_item->'etapas') > 1 then 'COMPOSITE' else 'SIMPLE' end::app.service_kind,
      null, 'BRL', true, 'ACTIVE',
      (v_item ? 'teste'),
      coalesce((v_item->'teste'->>'dias')::smallint, 7),
      60,
      coalesce((
        select array_agg(value::smallint order by value::smallint)
          from jsonb_array_elements_text(v_item->'teste'->'weekdays')
      ), array[4,5]::smallint[])
    )
    returning id into v_servico;

    v_pos := 0;
    for v_passo in select * from jsonb_array_elements(v_item->'etapas') loop
      v_pos := v_pos + 1;

      insert into app.service_steps (
        tenant_id, configuration_draft_id, service_id, name, position,
        duration_minutes, minimum_duration_minutes, maximum_duration_minutes,
        kind, technical_category, customer_presence_required, releases_member
      )
      values (
        v_tenant, v_draft, v_servico, v_passo->>'n', v_pos,
        (v_passo->>'m')::integer, (v_passo->>'m')::smallint, (v_passo->>'m')::smallint,
        case when coalesce((v_passo->>'passiva')::boolean, false) then 'PASSIVE' else 'ACTIVE' end::app.step_kind,
        (v_passo->>'c')::app.technical_step_category,
        true,
        coalesce((v_passo->>'passiva')::boolean, false)
      )
      returning id into v_etapa;

      if v_passo ? 's' then
        insert into app.service_step_skill_requirements (tenant_id, configuration_draft_id, step_id, skill_id, quantity)
        select v_tenant, v_draft, v_etapa, s.id, 1
          from app.skills s
         where s.tenant_id = v_tenant and s.configuration_draft_id = v_draft
           and s.name = v_passo->>'s';
      end if;

      if coalesce((v_passo->>'cadeira')::boolean, false) then
        insert into app.service_step_resource_requirements (tenant_id, configuration_draft_id, step_id, resource_type_id, quantity)
        values (v_tenant, v_draft, v_etapa, v_tipo_cadeira, 1);
      end if;
    end loop;
  end loop;
end $$;
