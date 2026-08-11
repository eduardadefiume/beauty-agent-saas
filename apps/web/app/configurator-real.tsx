'use client';

import { useEffect, useMemo, useState } from 'react';
import { createSupabaseBrowserClient } from '../lib/supabase/browser';
import SchedulingSimulator from './scheduling-simulator';
import './configurator-real.css';

type Workspace = {
  tenantId: string;
  tenantName: string;
  status: 'DRAFT' | 'PUBLISHED';
  revision: number;
};
type Slot = { weekday: number; startsAt: string; endsAt: string };
type Skill = {
  name: string;
  /** Vazio = competência simples, sem variação (ex.: Finalização). */
  qualifierLabel: string;
  qualifierAllowCustom: boolean;
  qualifierOptions: string[];
};
/** Uma pessoa/etapa cobrindo uma opção específica do qualificador de uma competência. */
type SkillQualifierChoice = { skillName: string; optionLabel?: string; customValue?: string };
/** Turno de disponibilidade Dinâmica: data específica (não recorrente), marcada no calendário. */
type DynamicShift = { shiftDate: string; startsAt: string; endsAt: string };
type Member = {
  name: string;
  availabilityMode: 'FIXED' | 'HYBRID' | 'DYNAMIC';
  skillNames: string[];
  skillQualifiers: SkillQualifierChoice[];
  availability: Slot[];
  dynamicShifts: DynamicShift[];
};
/**
 * Janela extra de horário válida só para uma cliente específica (reconhecida
 * por telefone ou, na falta dele, pelo nome) — soma ao expediente normal em
 * vez de substituí-lo. Hoje cadastrada à mão; quando o WhatsApp estiver
 * conectado, a ideia é a lista de contatos alimentar clientPhoneDigits em
 * vez de reinventar o modelo.
 */
type ClientException = {
  clientName: string;
  clientPhoneDigits: string;
  weekday: number;
  startsAt: string;
  endsAt: string;
  note: string;
};
type ResourceType = { name: string; resources: Array<{ name: string; capacity: number }> };
type Step = {
  name: string;
  position: number;
  durationMinutes: number;
  kind: 'ACTIVE' | 'PASSIVE';
  skillNames: string[];
  skillQualifiers: SkillQualifierChoice[];
  resourceRequirements: Array<{
    resourceTypeName: string;
    quantity: number;
    retainUntilServiceEnd: boolean;
  }>;
};
type Service = {
  name: string;
  basePriceMinor: number | null;
  variations: Array<{ name: string; priceMinor: number | null }>;
  steps: Step[];
};
type Config = {
  unit: { name: string; timezone: string };
  finalMessageTemplate: string;
  operatingHours: Array<Slot & { latestEndTime: string }>;
  clientExceptions: ClientException[];
  skills: Skill[];
  teamMembers: Member[];
  resourceTypes: ResourceType[];
  services: Service[];
};
type Loaded = {
  unit: Config['unit'] & { id: string };
  draft: { revision: number; status: 'DRAFT' | 'PUBLISHED' };
  configuration: Record<string, unknown>;
  readiness: Array<{ code: string }>;
};
type Obj = Record<string, unknown>;

const DAYS = ['Dom', 'Seg', 'Ter', 'Qua', 'Qui', 'Sex', 'Sáb'];
const EMPTY: Config = {
  unit: { name: 'Unidade principal', timezone: 'America/Sao_Paulo' },
  finalMessageTemplate: '',
  operatingHours: [],
  clientExceptions: [],
  skills: [],
  teamMembers: [],
  resourceTypes: [],
  services: [],
};
const ISSUE: Record<string, string> = {
  OPERATING_HOURS_MISSING: 'Cadastre os horários de funcionamento.',
  LATEST_END_MISSING: 'Defina o último término em cada dia aberto.',
  NO_ACTIVE_MEMBER: 'Cadastre ao menos um profissional.',
  MEMBER_AVAILABILITY_INVALID: 'Complete a disponibilidade da equipe.',
  NO_BOOKABLE_SERVICE: 'Cadastre ao menos um serviço.',
  SERVICE_HAS_NO_STEPS: 'Todo serviço precisa de etapas.',
  STEP_HAS_NO_QUALIFIED_MEMBER:
    'Nenhum profissional cobre a competência (ou a variação exigida) de alguma etapa ativa.',
  STEP_SKILL_QUALIFIER_MISSING:
    'Alguma etapa exige uma competência com variação (ex.: tom, tipo) mas não escolheu qual.',
  RESOURCE_CAPACITY_MISSING: 'Aumente a capacidade dos recursos exigidos.',
  FINAL_MESSAGE_MISSING: 'Defina a mensagem final.',
};

type ModuleKey =
  | 'negocio'
  | 'equipe'
  | 'servicos'
  | 'agenda'
  | 'recursos'
  | 'politicas'
  | 'conhecimento'
  | 'comunicacao'
  | 'whatsapp'
  | 'agente'
  | 'clientes'
  | 'promocoes'
  | 'simulacao'
  | 'publicar';

const MODULES: Array<{ key: ModuleKey; label: string; ready: boolean; soonNote?: string }> = [
  { key: 'negocio', label: 'Negócio', ready: true },
  { key: 'equipe', label: 'Equipe', ready: true },
  { key: 'servicos', label: 'Serviços', ready: true },
  { key: 'agenda', label: 'Agenda', ready: true },
  { key: 'recursos', label: 'Recursos', ready: true },
  {
    key: 'politicas',
    label: 'Políticas de sinal',
    ready: false,
    soonNote:
      'Suspenso por decisão sua nesta fase do piloto: William e Jack não cobram sinal. Ativamos aqui quando isso mudar.',
  },
  {
    key: 'conhecimento',
    label: 'Conhecimento (fotos)',
    ready: false,
    soonNote:
      'Classificar cabelo por foto com IA ainda depende de um motor de análise de imagem que não foi construído. As variações de comprimento e volume por texto já podem ser cadastradas em Serviços.',
  },
  {
    key: 'comunicacao',
    label: 'Comunicação',
    ready: false,
    soonNote:
      'Modelos de mensagem por evento (confirmação, sinal, remarcação, lembrete, ausência) ainda não têm cadastro próprio — hoje só existe a mensagem final única, em Negócio.',
  },
  {
    key: 'whatsapp',
    label: 'WhatsApp',
    ready: false,
    soonNote:
      'A conexão técnica com a Meta já existe em modo piloto restrito, mas o painel para você acompanhar conversas e status ainda não foi construído.',
  },
  {
    key: 'agente',
    label: 'Agente (fala com você)',
    ready: false,
    soonNote:
      'O módulo para você conversar direto com a IA — avisar atraso, remanejar clientes, consultar agenda — ainda não foi modelado.',
  },
  {
    key: 'clientes',
    label: 'Clientes',
    ready: false,
    soonNote:
      'Cadastro de clientes com histórico, preferências e consentimento ainda não tem tabela própria no banco.',
  },
  {
    key: 'promocoes',
    label: 'Promoções',
    ready: false,
    soonNote:
      'Segmentação e campanhas ainda não foram modeladas — são a última prioridade do plano, depois do motor de agenda estar validado.',
  },
  { key: 'simulacao', label: 'Simulação', ready: true },
  { key: 'publicar', label: 'Publicar', ready: true },
];
const DEFAULT_MODULE = MODULES[0] as (typeof MODULES)[number];

async function api(body: Obj) {
  const response = await fetch('/api/configuration', {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify(body),
  });
  const result = (await response.json()) as { error?: string; data?: unknown };
  if (!response.ok) throw new Error(result.error ?? 'Operação não concluída.');
  return result.data;
}

const rows = (value: unknown) => (Array.isArray(value) ? (value as Obj[]) : []);
const clock = (value: unknown, fallback = '09:00') =>
  typeof value === 'string' ? value.slice(0, 5) : fallback;

function normalize(data: Loaded): Config {
  const raw = data.configuration;
  const skills = rows(raw.skills);
  const skillNames = new Map(skills.map((item) => [String(item.id), String(item.name)]));
  const qualifierOptionLabels = new Map<string, string>();
  for (const item of skills) {
    for (const option of rows(item.qualifierOptions)) {
      qualifierOptionLabels.set(String(option.id), String(option.label));
    }
  }
  const toQualifierChoice = (
    skillId: unknown,
    qualifier: { qualifier_option_id?: unknown; custom_value?: unknown } | null | undefined
  ): SkillQualifierChoice | null => {
    const skillName = skillNames.get(String(skillId));
    if (!skillName || !qualifier) return null;
    const optionLabel = qualifier.qualifier_option_id
      ? qualifierOptionLabels.get(String(qualifier.qualifier_option_id))
      : undefined;
    const customValue = qualifier.custom_value ? String(qualifier.custom_value) : undefined;
    if (optionLabel) return { skillName, optionLabel };
    if (customValue) return { skillName, customValue };
    return null;
  };
  const types = rows(raw.resourceTypes);
  const typeNames = new Map(types.map((item) => [String(item.id), String(item.name)]));
  const limits = new Map(
    rows(raw.serviceLimits).map((item) => [
      Number(item.weekday),
      clock(item.latest_end_time, '18:00'),
    ])
  );
  return {
    unit: { name: data.unit.name, timezone: data.unit.timezone },
    finalMessageTemplate: String(raw.finalMessageTemplate ?? ''),
    operatingHours: rows(raw.operatingHours).map((item) => ({
      weekday: Number(item.weekday),
      startsAt: clock(item.starts_at),
      endsAt: clock(item.ends_at, '18:00'),
      latestEndTime: limits.get(Number(item.weekday)) ?? clock(item.ends_at, '18:00'),
    })),
    clientExceptions: rows(raw.clientExceptions).map((item) => ({
      clientName: String(item.client_name ?? ''),
      clientPhoneDigits: item.client_phone_digits ? String(item.client_phone_digits) : '',
      weekday: Number(item.weekday),
      startsAt: clock(item.starts_at),
      endsAt: clock(item.ends_at, '18:00'),
      note: item.note ? String(item.note) : '',
    })),
    skills: skills.map((item) => ({
      name: String(item.name),
      qualifierLabel: item.qualifier_label ? String(item.qualifier_label) : '',
      qualifierAllowCustom: Boolean(item.qualifier_allow_custom),
      qualifierOptions: rows(item.qualifierOptions).map((option) => String(option.label)),
    })),
    teamMembers: rows(raw.teamMembers).map((item) => ({
      name: String(item.name),
      availabilityMode: String(item.availability_mode ?? 'FIXED') as Member['availabilityMode'],
      skillNames: (Array.isArray(item.skillIds) ? item.skillIds : [])
        .map((id) => skillNames.get(String(id)))
        .filter(Boolean) as string[],
      skillQualifiers: rows(item.skillQualifiers)
        .map((q) =>
          toQualifierChoice(q.skill_id, {
            qualifier_option_id: q.qualifier_option_id,
            custom_value: q.custom_value,
          })
        )
        .filter((q): q is SkillQualifierChoice => q !== null),
      availability: rows(item.availability).map((slot) => ({
        weekday: Number(slot.weekday),
        startsAt: clock(slot.starts_at),
        endsAt: clock(slot.ends_at, '18:00'),
      })),
      dynamicShifts: rows(item.dynamicShifts).map((shift) => ({
        shiftDate: String(shift.shift_date),
        startsAt: clock(shift.starts_at),
        endsAt: clock(shift.ends_at, '18:00'),
      })),
    })),
    resourceTypes: types.map((item) => ({
      name: String(item.name),
      resources: rows(item.resources).map((resource) => ({
        name: String(resource.name),
        capacity: Number(resource.capacity ?? 1),
      })),
    })),
    services: rows(raw.services).map((item) => ({
      name: String(item.name),
      basePriceMinor: item.base_price_minor == null ? null : Number(item.base_price_minor),
      variations: rows(item.variations).map((variation) => ({
        name: String(variation.name),
        priceMinor: variation.price_minor == null ? null : Number(variation.price_minor),
      })),
      steps: rows(item.steps).map((step) => ({
        name: String(step.name),
        position: Number(step.position),
        durationMinutes: Number(step.duration_minutes),
        kind: String(step.kind ?? 'ACTIVE') as Step['kind'],
        skillNames: rows(step.skillRequirements)
          .map((requirement) => skillNames.get(String(requirement.skill_id)))
          .filter(Boolean) as string[],
        skillQualifiers: rows(step.skillRequirements)
          .map((requirement) =>
            toQualifierChoice(
              requirement.skill_id,
              requirement.qualifier as { qualifier_option_id?: unknown; custom_value?: unknown } | null
            )
          )
          .filter((q): q is SkillQualifierChoice => q !== null),
        resourceRequirements: rows(step.resourceRequirements)
          .map((requirement) => ({
            resourceTypeName: typeNames.get(String(requirement.resource_type_id)) ?? '',
            quantity: Number(requirement.quantity ?? 1),
            retainUntilServiceEnd: Boolean(requirement.retain_until_service_end),
          }))
          .filter((requirement) => requirement.resourceTypeName),
      })),
    })),
  };
}

const MONTH_NAMES = [
  'Janeiro',
  'Fevereiro',
  'Março',
  'Abril',
  'Maio',
  'Junho',
  'Julho',
  'Agosto',
  'Setembro',
  'Outubro',
  'Novembro',
  'Dezembro',
];
const WEEKDAY_LETTERS = ['D', 'S', 'T', 'Q', 'Q', 'S', 'S'];

function pad2(value: number): string {
  return String(value).padStart(2, '0');
}

function formatDatePtBr(dateIso: string): string {
  const [year, month, day] = dateIso.split('-');
  return `${day}/${month}/${year}`;
}

/**
 * Calendário de disponibilidade Dinâmica: em vez da pessoa preencher uma
 * faixa semanal recorrente, marca dia a dia (mês a mês) quando ela vai
 * trabalhar — igual ao pedido da Duda: "geralmente deixo de outra cor
 * (amarelo)". Cada dia marcado vira um turno em app.member_dynamic_shifts,
 * que o motor de agenda usa para pessoas em modo Dinâmica/Híbrida.
 */
function DynamicShiftCalendar({
  shifts,
  editable,
  onAddShift,
  onUpdateShift,
  onRemoveShift,
}: {
  shifts: DynamicShift[];
  editable: boolean;
  onAddShift: (dateIso: string) => void;
  onUpdateShift: (dateIso: string, field: 'startsAt' | 'endsAt', value: string) => void;
  onRemoveShift: (dateIso: string) => void;
}) {
  const today = new Date();
  const [viewYear, setViewYear] = useState(today.getFullYear());
  const [viewMonth, setViewMonth] = useState(today.getMonth());

  const shiftsByDate = useMemo(() => {
    const map = new Map<string, DynamicShift>();
    for (const shift of shifts) map.set(shift.shiftDate, shift);
    return map;
  }, [shifts]);

  const daysInMonth = new Date(viewYear, viewMonth + 1, 0).getDate();
  const startWeekday = new Date(viewYear, viewMonth, 1).getDay();
  const todayIso = `${today.getFullYear()}-${pad2(today.getMonth() + 1)}-${pad2(today.getDate())}`;

  const cells: Array<{ dateIso: string; day: number } | null> = [];
  for (let i = 0; i < startWeekday; i += 1) cells.push(null);
  for (let day = 1; day <= daysInMonth; day += 1) {
    cells.push({ dateIso: `${viewYear}-${pad2(viewMonth + 1)}-${pad2(day)}`, day });
  }

  function changeMonth(delta: number) {
    let nextMonth = viewMonth + delta;
    let nextYear = viewYear;
    if (nextMonth < 0) {
      nextMonth = 11;
      nextYear -= 1;
    } else if (nextMonth > 11) {
      nextMonth = 0;
      nextYear += 1;
    }
    setViewMonth(nextMonth);
    setViewYear(nextYear);
  }

  const sortedShifts = useMemo(
    () => [...shifts].sort((left, right) => left.shiftDate.localeCompare(right.shiftDate)),
    [shifts]
  );

  return (
    <div className="dynamic-calendar">
      <div className="dynamic-calendar-header">
        <button type="button" className="ghost" onClick={() => changeMonth(-1)}>
          ‹
        </button>
        <strong>
          {MONTH_NAMES[viewMonth]} de {viewYear}
        </strong>
        <button type="button" className="ghost" onClick={() => changeMonth(1)}>
          ›
        </button>
      </div>
      <div className="dynamic-calendar-grid">
        {WEEKDAY_LETTERS.map((letter, i) => (
          <span className="dynamic-calendar-weekday" key={`weekday-${i}`}>
            {letter}
          </span>
        ))}
        {cells.map((cell, i) => {
          if (!cell) return <span className="dynamic-calendar-cell empty" key={`empty-${i}`} />;
          const shift = shiftsByDate.get(cell.dateIso);
          return (
            <button
              type="button"
              key={cell.dateIso}
              disabled={!editable}
              className={
                'dynamic-calendar-cell' +
                (shift ? ' working' : '') +
                (cell.dateIso === todayIso ? ' today' : '')
              }
              onClick={() => (shift ? onRemoveShift(cell.dateIso) : onAddShift(cell.dateIso))}
              title={
                shift
                  ? `${formatDatePtBr(cell.dateIso)}: vai trabalhar das ${shift.startsAt} às ${shift.endsAt} — clique para desmarcar`
                  : `Marcar ${formatDatePtBr(cell.dateIso)} como dia de trabalho`
              }
            >
              {cell.day}
            </button>
          );
        })}
      </div>
      {sortedShifts.length > 0 && (
        <div className="dynamic-calendar-list">
          <p className="hint small">Dias marcados em amarelo — ajuste o horário de cada um:</p>
          {sortedShifts.map((shift) => (
            <div className="row slot" key={shift.shiftDate}>
              <span className="dynamic-calendar-date">{formatDatePtBr(shift.shiftDate)}</span>
              <input
                type="time"
                disabled={!editable}
                value={shift.startsAt}
                onChange={(e) => onUpdateShift(shift.shiftDate, 'startsAt', e.target.value)}
              />
              <input
                type="time"
                disabled={!editable}
                value={shift.endsAt}
                onChange={(e) => onUpdateShift(shift.shiftDate, 'endsAt', e.target.value)}
              />
              <button
                className="danger"
                disabled={!editable}
                onClick={() => onRemoveShift(shift.shiftDate)}
              >
                Remover
              </button>
            </div>
          ))}
        </div>
      )}
    </div>
  );
}

export default function Configurator({ user }: { user: { displayName: string; email: string } }) {
  const [workspaces, setWorkspaces] = useState<Workspace[]>([]);
  const [tenantId, setTenantId] = useState('');
  const [unitId, setUnitId] = useState('');
  const [config, setConfig] = useState<Config>(EMPTY);
  const [revision, setRevision] = useState(0);
  const [status, setStatus] = useState<Workspace['status']>('DRAFT');
  const [readiness, setReadiness] = useState<Array<{ code: string }>>([]);
  const [loading, setLoading] = useState(true);
  const [dirty, setDirty] = useState(false);
  const [busy, setBusy] = useState(false);
  const [notice, setNotice] = useState('');
  const [module, setModule] = useState<ModuleKey>('negocio');

  useEffect(() => {
    void api({ action: 'list' })
      .then((raw) => {
        const items = raw as Workspace[];
        setWorkspaces(items);
        setTenantId(items[0]?.tenantId ?? '');
        if (!items.length) setLoading(false);
      })
      .catch((error) => {
        setNotice(error instanceof Error ? error.message : 'Falha ao carregar.');
        setLoading(false);
      });
  }, []);
  useEffect(() => {
    if (!tenantId) return;
    void api({ action: 'load', tenantId })
      .then((raw) => {
        const loaded = raw as Loaded;
        setConfig(normalize(loaded));
        setRevision(loaded.draft.revision);
        setStatus(loaded.draft.status);
        setReadiness(loaded.readiness);
        setUnitId(loaded.unit.id);
        setDirty(false);
        setNotice('');
      })
      .catch((error) => setNotice(error instanceof Error ? error.message : 'Falha ao carregar.'))
      .finally(() => setLoading(false));
  }, [tenantId]);

  function selectTenant(nextTenantId: string) {
    if (dirty && !window.confirm('Você tem alterações não salvas nesta empresa. Trocar de empresa agora vai descartá-las. Trocar mesmo assim?')) {
      return;
    }
    setLoading(true);
    setTenantId(nextTenantId);
  }

  useEffect(() => {
    if (!dirty) return;
    const warnBeforeLeaving = (event: BeforeUnloadEvent) => {
      event.preventDefault();
    };
    window.addEventListener('beforeunload', warnBeforeLeaving);
    return () => window.removeEventListener('beforeunload', warnBeforeLeaving);
  }, [dirty]);

  function change(mutator: (draft: Config) => void) {
    setConfig((current) => {
      const draft = structuredClone(current);
      mutator(draft);
      return draft;
    });
    setDirty(true);
    setNotice('');
  }
  async function save() {
    setBusy(true);
    try {
      const loaded = (await api({
        action: 'save',
        tenantId,
        expectedRevision: revision,
        payload: config,
      })) as Loaded;
      setConfig(normalize(loaded));
      setRevision(loaded.draft.revision);
      setReadiness(loaded.readiness);
      setDirty(false);
      setNotice('Alterações salvas.');
    } catch (error) {
      setNotice(error instanceof Error ? error.message : 'Falha ao salvar.');
    } finally {
      setBusy(false);
    }
  }
  async function publish() {
    setBusy(true);
    try {
      const result = (await api({ action: 'publish', tenantId, expectedRevision: revision })) as {
        versionNumber: number;
      };
      setStatus('PUBLISHED');
      setNotice(
        `Versão ${result.versionNumber} publicada. A partir de agora esses dados valem para o atendimento.`
      );
    } catch (error) {
      setNotice(error instanceof Error ? error.message : 'Falha ao publicar.');
    } finally {
      setBusy(false);
    }
  }
  async function signOut() {
    const supabase = createSupabaseBrowserClient();
    await supabase.auth.signOut();
    window.location.href = '/login';
  }

  const editable = status === 'DRAFT';
  const activeModule = useMemo(
    () => MODULES.find((item) => item.key === module) ?? DEFAULT_MODULE,
    [module]
  );

  return (
    <main className="shell">
      <header className="topbar">
        <div className="brand">
          <span className="eyebrow">Configurador do seu negócio</span>
          <h1>{config.unit.name || 'Sua empresa'}</h1>
        </div>
        <div className="who">
          <label>
            Empresa
            <select value={tenantId} onChange={(event) => selectTenant(event.target.value)}>
              {workspaces.map((item) => (
                <option key={item.tenantId} value={item.tenantId}>
                  {item.tenantName}
                </option>
              ))}
            </select>
          </label>
          <div className="badge-row">
            <b className={status === 'PUBLISHED' ? 'published' : ''}>
              {status === 'PUBLISHED' ? 'No ar' : 'Rascunho'}
            </b>
            {editable && (
              <button
                className={`save-now ${dirty ? 'save-now-pending' : ''}`}
                disabled={busy || !dirty}
                onClick={() => void save()}
                title="Salva o que você editou em qualquer módulo — não precisa ir em Publicar para isso."
              >
                {busy ? 'Salvando…' : dirty ? 'Salvar alterações' : 'Tudo salvo'}
              </button>
            )}
          </div>
          <div className="account">
            <strong>{user.displayName}</strong>
            <button className="linklike" onClick={() => void signOut()}>
              Sair
            </button>
          </div>
        </div>
      </header>

      {notice && (
        <div className="notice" role="status">
          {notice}
        </div>
      )}

      <div className="layout">
        <nav className="sidenav">
          {MODULES.map((item) => (
            <button
              key={item.key}
              className={`navitem ${item.key === module ? 'active' : ''} ${item.ready ? '' : 'soon'}`}
              onClick={() => setModule(item.key)}
            >
              <span>{item.label}</span>
              {!item.ready && <em>em breve</em>}
            </button>
          ))}
        </nav>

        <section className="content">
          {loading ? (
            <div className="loading">Carregando os dados da sua empresa…</div>
          ) : !activeModule.ready ? (
            <article className="card soon-card">
              <h2>{activeModule.label}</h2>
              <p>{activeModule.soonNote}</p>
            </article>
          ) : (
            <>
              {module === 'negocio' && (
                <article className="card">
                  <h2>Negócio</h2>
                  <p className="hint">
                    Nome da unidade e a mensagem que a cliente recebe ao final do atendimento.
                  </p>
                  <div className="grid two">
                    <label>
                      Nome do negócio
                      <input
                        disabled={!editable}
                        value={config.unit.name}
                        onChange={(e) =>
                          change((draft) => {
                            draft.unit.name = e.target.value;
                          })
                        }
                      />
                    </label>
                    <label>
                      Fuso horário
                      <input
                        disabled={!editable}
                        value={config.unit.timezone}
                        onChange={(e) =>
                          change((draft) => {
                            draft.unit.timezone = e.target.value;
                          })
                        }
                      />
                    </label>
                  </div>
                  <label>
                    Mensagem final para a cliente
                    <textarea
                      rows={3}
                      disabled={!editable}
                      value={config.finalMessageTemplate}
                      onChange={(e) =>
                        change((draft) => {
                          draft.finalMessageTemplate = e.target.value;
                        })
                      }
                    />
                  </label>
                </article>
              )}

              {module === 'agenda' && (
                <article className="card">
                  <div className="title">
                    <h2>Agenda</h2>
                    <button
                      disabled={!editable}
                      onClick={() =>
                        change((draft) =>
                          draft.operatingHours.push({
                            weekday: 1,
                            startsAt: '09:00',
                            endsAt: '18:00',
                            latestEndTime: '18:00',
                          })
                        )
                      }
                    >
                      Adicionar dia
                    </button>
                  </div>
                  <p className="hint">
                    Horário de funcionamento por dia da semana e o horário mais tarde em que
                    qualquer atendimento pode terminar.
                  </p>
                  {config.operatingHours.length === 0 && (
                    <p className="empty">Nenhum horário cadastrado ainda.</p>
                  )}
                  {config.operatingHours.map((hour, index) => (
                    <div className="row hour" key={index}>
                      <select
                        disabled={!editable}
                        value={hour.weekday}
                        onChange={(e) =>
                          change((draft) => {
                            const target = draft.operatingHours[index];
                            if (target) target.weekday = Number(e.target.value);
                          })
                        }
                      >
                        {DAYS.map((day, dayIndex) => (
                          <option value={dayIndex} key={day}>
                            {day}
                          </option>
                        ))}
                      </select>
                      <label className="inline">
                        <span>Abre</span>
                        <input
                          type="time"
                          disabled={!editable}
                          value={hour.startsAt}
                          onChange={(e) =>
                            change((draft) => {
                              const target = draft.operatingHours[index];
                              if (target) target.startsAt = e.target.value;
                            })
                          }
                        />
                      </label>
                      <label className="inline">
                        <span>Fecha</span>
                        <input
                          type="time"
                          disabled={!editable}
                          value={hour.endsAt}
                          onChange={(e) =>
                            change((draft) => {
                              const target = draft.operatingHours[index];
                              if (target) target.endsAt = e.target.value;
                            })
                          }
                        />
                      </label>
                      <label className="inline">
                        <span>Último término</span>
                        <input
                          type="time"
                          disabled={!editable}
                          value={hour.latestEndTime}
                          onChange={(e) =>
                            change((draft) => {
                              const target = draft.operatingHours[index];
                              if (target) target.latestEndTime = e.target.value;
                            })
                          }
                        />
                      </label>
                      <button
                        className="danger"
                        disabled={!editable}
                        onClick={() => change((draft) => draft.operatingHours.splice(index, 1))}
                      >
                        Remover
                      </button>
                    </div>
                  ))}

                  <div className="title minor">
                    <h3>Exceções por cliente</h3>
                    <button
                      disabled={!editable}
                      onClick={() =>
                        change((draft) =>
                          draft.clientExceptions.push({
                            clientName: '',
                            clientPhoneDigits: '',
                            weekday: 6,
                            startsAt: '08:00',
                            endsAt: '12:00',
                            note: '',
                          })
                        )
                      }
                    >
                      Adicionar exceção
                    </button>
                  </div>
                  <p className="hint">
                    Alguma cliente só consegue vir fora do expediente normal (ex.: só sábado de
                    manhã, só depois das 19h numa terça)? Cadastre aqui — vale só para ela, o
                    resto da clientela continua vendo o expediente normal. Hoje o telefone é
                    digitado à mão; quando o WhatsApp estiver conectado, dá pra puxar da lista de
                    contatos.
                  </p>
                  {config.clientExceptions.length === 0 && (
                    <p className="empty">Nenhuma exceção cadastrada ainda.</p>
                  )}
                  {config.clientExceptions.map((exception, index) => (
                    <article className="nested" key={index}>
                      <div className="grid two">
                        <label>
                          Nome da cliente
                          <input
                            disabled={!editable}
                            value={exception.clientName}
                            placeholder="Ex.: Maria Silva"
                            onChange={(e) =>
                              change((draft) => {
                                const target = draft.clientExceptions[index];
                                if (target) target.clientName = e.target.value;
                              })
                            }
                          />
                        </label>
                        <label>
                          Telefone (opcional, com DDD)
                          <input
                            disabled={!editable}
                            value={exception.clientPhoneDigits}
                            placeholder="Ex.: 11987654321"
                            onChange={(e) =>
                              change((draft) => {
                                const target = draft.clientExceptions[index];
                                if (target)
                                  target.clientPhoneDigits = e.target.value.replace(/\D/g, '');
                              })
                            }
                          />
                        </label>
                      </div>
                      <div className="row hour">
                        <select
                          disabled={!editable}
                          value={exception.weekday}
                          onChange={(e) =>
                            change((draft) => {
                              const target = draft.clientExceptions[index];
                              if (target) target.weekday = Number(e.target.value);
                            })
                          }
                        >
                          {DAYS.map((day, dayIndex) => (
                            <option value={dayIndex} key={day}>
                              {day}
                            </option>
                          ))}
                        </select>
                        <label className="inline">
                          <span>De</span>
                          <input
                            type="time"
                            disabled={!editable}
                            value={exception.startsAt}
                            onChange={(e) =>
                              change((draft) => {
                                const target = draft.clientExceptions[index];
                                if (target) target.startsAt = e.target.value;
                              })
                            }
                          />
                        </label>
                        <label className="inline">
                          <span>Até</span>
                          <input
                            type="time"
                            disabled={!editable}
                            value={exception.endsAt}
                            onChange={(e) =>
                              change((draft) => {
                                const target = draft.clientExceptions[index];
                                if (target) target.endsAt = e.target.value;
                              })
                            }
                          />
                        </label>
                        <button
                          className="danger"
                          disabled={!editable}
                          onClick={() =>
                            change((draft) => draft.clientExceptions.splice(index, 1))
                          }
                        >
                          Remover
                        </button>
                      </div>
                      <label>
                        Nota (opcional, só pra você lembrar o motivo)
                        <input
                          disabled={!editable}
                          value={exception.note}
                          placeholder="Ex.: mora longe, só consegue vir de manhã cedo"
                          onChange={(e) =>
                            change((draft) => {
                              const target = draft.clientExceptions[index];
                              if (target) target.note = e.target.value;
                            })
                          }
                        />
                      </label>
                    </article>
                  ))}
                </article>
              )}

              {module === 'equipe' && (
                <article className="card">
                  <div className="title">
                    <h2>Equipe</h2>
                  </div>
                  <p className="hint">
                    Competências que sua equipe pode ter, e depois cada profissional com sua agenda
                    própria.
                  </p>
                  <div className="title minor">
                    <h3>Competências</h3>
                    <button
                      disabled={!editable}
                      onClick={() =>
                        change((draft) =>
                          draft.skills.push({
                            name: '',
                            qualifierLabel: '',
                            qualifierAllowCustom: false,
                            qualifierOptions: [],
                          })
                        )
                      }
                    >
                      Adicionar competência
                    </button>
                  </div>
                  <p className="hint small">
                    Se a competência tem variações que nem toda a equipe cobre — ex.: nem toda
                    colorista faz tom vermelho, o Gloss Express muda o tempo de ação conforme o
                    tom — marque &ldquo;Tem variação&rdquo; e cadastre as opções. Assim o agente só
                    marca quem realmente sabe fazer aquele caso específico, não qualquer coisa da
                    competência.
                  </p>
                  {config.skills.length === 0 && (
                    <p className="empty">Nenhuma competência cadastrada ainda.</p>
                  )}
                  {config.skills.map((skill, index) => (
                    <article className="nested" key={index}>
                      <div className="grid two">
                        <label>
                          Competência
                          <input
                            disabled={!editable}
                            placeholder="Ex.: Coloração"
                            value={skill.name}
                            onChange={(e) =>
                              change((draft) => {
                                const target = draft.skills[index];
                                if (target) target.name = e.target.value;
                              })
                            }
                          />
                        </label>
                        <label className="check">
                          <input
                            type="checkbox"
                            disabled={!editable}
                            checked={Boolean(skill.qualifierLabel)}
                            onChange={(e) =>
                              change((draft) => {
                                const target = draft.skills[index];
                                if (!target) return;
                                target.qualifierLabel = e.target.checked
                                  ? target.qualifierLabel || 'Tipo'
                                  : '';
                                if (!e.target.checked) {
                                  target.qualifierOptions = [];
                                  target.qualifierAllowCustom = false;
                                }
                              })
                            }
                          />
                          Tem variação (ex.: tom, tipo)
                        </label>
                      </div>
                      {skill.qualifierLabel && (
                        <article className="nested">
                          <label>
                            Nome da pergunta
                            <input
                              disabled={!editable}
                              placeholder="Ex.: Tom, Tipo de corte"
                              value={skill.qualifierLabel}
                              onChange={(e) =>
                                change((draft) => {
                                  const target = draft.skills[index];
                                  if (target) target.qualifierLabel = e.target.value;
                                })
                              }
                            />
                          </label>
                          <div className="title minor">
                            <h5>Opções</h5>
                            <button
                              disabled={!editable}
                              onClick={() =>
                                change((draft) => draft.skills[index]?.qualifierOptions.push(''))
                              }
                            >
                              Adicionar opção
                            </button>
                          </div>
                          {skill.qualifierOptions.length === 0 && (
                            <p className="empty small">
                              Nenhuma opção ainda — ex.: &ldquo;Castanho/Preto&rdquo;,
                              &ldquo;Vermelho&rdquo;.
                            </p>
                          )}
                          {skill.qualifierOptions.map((option, optionIndex) => (
                            <div className="row" key={optionIndex}>
                              <input
                                disabled={!editable}
                                placeholder="Ex.: Castanho/Preto"
                                value={option}
                                onChange={(e) =>
                                  change((draft) => {
                                    const target = draft.skills[index];
                                    if (target) target.qualifierOptions[optionIndex] = e.target.value;
                                  })
                                }
                              />
                              <button
                                className="danger"
                                disabled={!editable}
                                onClick={() =>
                                  change((draft) => draft.skills[index]?.qualifierOptions.splice(optionIndex, 1))
                                }
                              >
                                ×
                              </button>
                            </div>
                          ))}
                          <label className="check">
                            <input
                              type="checkbox"
                              disabled={!editable}
                              checked={skill.qualifierAllowCustom}
                              onChange={(e) =>
                                change((draft) => {
                                  const target = draft.skills[index];
                                  if (target) target.qualifierAllowCustom = e.target.checked;
                                })
                              }
                            />
                            Permitir &ldquo;Outro&rdquo; (a pessoa escreve qual)
                          </label>
                        </article>
                      )}
                      <button
                        className="danger ghost"
                        disabled={!editable}
                        onClick={() => change((draft) => draft.skills.splice(index, 1))}
                      >
                        Remover {skill.name || 'esta competência'}
                      </button>
                    </article>
                  ))}

                  <div className="title minor">
                    <h3>Profissionais</h3>
                    {config.teamMembers.length > 0 && (
                      <button
                        disabled={!editable}
                        onClick={() =>
                          change((draft) =>
                            draft.teamMembers.push({
                              name: '',
                              availabilityMode: 'FIXED',
                              skillNames: [],
                              skillQualifiers: [],
                              availability: [],
                              dynamicShifts: [],
                            })
                          )
                        }
                      >
                        Adicionar pessoa
                      </button>
                    )}
                  </div>
                  {config.teamMembers.length === 0 && (
                    <article className="nested solo-question">
                      <p>
                        <strong>Você tem equipe ou trabalha sozinha(o) nesse negócio?</strong>
                      </p>
                      <div className="row">
                        <button
                          disabled={!editable}
                          onClick={() =>
                            change((draft) =>
                              draft.teamMembers.push({
                                name: '',
                                availabilityMode: 'FIXED',
                                skillNames: [],
                                skillQualifiers: [],
                                availability: [],
                                dynamicShifts: [],
                              })
                            )
                          }
                        >
                          Trabalho sozinha(o)
                        </button>
                        <button
                          className="ghost"
                          disabled={!editable}
                          onClick={() =>
                            change((draft) =>
                              draft.teamMembers.push({
                                name: '',
                                availabilityMode: 'FIXED',
                                skillNames: [],
                                skillQualifiers: [],
                                availability: [],
                                dynamicShifts: [],
                              })
                            )
                          }
                        >
                          Tenho equipe
                        </button>
                      </div>
                      <p className="hint small">
                        Escolhendo qualquer uma das opções, cadastre-se (ou cadastre a primeira
                        pessoa) abaixo — dá pra adicionar mais gente a qualquer momento, mesmo
                        depois de marcar &ldquo;sozinha(o)&rdquo;.
                      </p>
                    </article>
                  )}
                  {config.teamMembers.length === 1 && (
                    <p className="hint small">
                      Você trabalha sozinha(o) por enquanto — pode adicionar mais gente na equipe
                      quando quiser.
                    </p>
                  )}
                  {config.teamMembers.map((member, memberIndex) => (
                    <article className="nested" key={memberIndex}>
                      <div className="grid two">
                        <label>
                          Nome
                          <input
                            disabled={!editable}
                            value={member.name}
                            onChange={(e) =>
                              change((draft) => {
                                const target = draft.teamMembers[memberIndex];
                                if (target) target.name = e.target.value;
                              })
                            }
                          />
                        </label>
                        <label>
                          Tipo de agenda
                          <select
                            disabled={!editable}
                            value={member.availabilityMode}
                            onChange={(e) =>
                              change((draft) => {
                                const target = draft.teamMembers[memberIndex];
                                if (target)
                                  target.availabilityMode = e.target
                                    .value as Member['availabilityMode'];
                              })
                            }
                          >
                            <option value="FIXED">Fixa — mesma agenda toda semana</option>
                            <option value="HYBRID">Híbrida — mistura fixo e combinado</option>
                            <option value="DYNAMIC">Dinâmica — só entra quando confirmar</option>
                          </select>
                        </label>
                      </div>
                      <fieldset>
                        <legend>Competências desta pessoa</legend>
                        {config.skills.filter((s) => s.name).length === 0 && (
                          <p className="empty small">Cadastre competências acima primeiro.</p>
                        )}
                        {config.skills
                          .filter((s) => s.name)
                          .map((skill) => {
                            if (!skill.qualifierLabel) {
                              return (
                                <label className="check" key={skill.name}>
                                  <input
                                    type="checkbox"
                                    disabled={!editable}
                                    checked={member.skillNames.includes(skill.name)}
                                    onChange={(e) =>
                                      change((draft) => {
                                        const target = draft.teamMembers[memberIndex];
                                        if (!target) return;
                                        target.skillNames = e.target.checked
                                          ? [...target.skillNames, skill.name]
                                          : target.skillNames.filter((name) => name !== skill.name);
                                      })
                                    }
                                  />
                                  {skill.name}
                                </label>
                              );
                            }
                            const coveredOptions = new Set(
                              member.skillQualifiers
                                .filter((q) => q.skillName === skill.name && q.optionLabel)
                                .map((q) => q.optionLabel)
                            );
                            const customCoverage = member.skillQualifiers.find(
                              (q) => q.skillName === skill.name && q.customValue !== undefined
                            );
                            return (
                              <article className="nested" key={skill.name}>
                                <strong>
                                  {skill.name} — {skill.qualifierLabel}
                                </strong>
                                <p className="hint small">
                                  Marque quais {skill.qualifierLabel.toLowerCase()} esta pessoa
                                  sabe fazer nesta competência.
                                </p>
                                {skill.qualifierOptions.map((option) => (
                                  <label className="check" key={option}>
                                    <input
                                      type="checkbox"
                                      disabled={!editable}
                                      checked={coveredOptions.has(option)}
                                      onChange={(e) =>
                                        change((draft) => {
                                          const target = draft.teamMembers[memberIndex];
                                          if (!target) return;
                                          if (e.target.checked) {
                                            target.skillQualifiers.push({
                                              skillName: skill.name,
                                              optionLabel: option,
                                            });
                                            if (!target.skillNames.includes(skill.name)) {
                                              target.skillNames.push(skill.name);
                                            }
                                          } else {
                                            target.skillQualifiers = target.skillQualifiers.filter(
                                              (q) => !(q.skillName === skill.name && q.optionLabel === option)
                                            );
                                            const stillCovers = target.skillQualifiers.some(
                                              (q) => q.skillName === skill.name
                                            );
                                            if (!stillCovers) {
                                              target.skillNames = target.skillNames.filter(
                                                (name) => name !== skill.name
                                              );
                                            }
                                          }
                                        })
                                      }
                                    />
                                    {option}
                                  </label>
                                ))}
                                {skill.qualifierAllowCustom && (
                                  <label>
                                    Outro (qual?)
                                    <input
                                      disabled={!editable}
                                      value={customCoverage?.customValue ?? ''}
                                      placeholder="Ex.: Arco-íris"
                                      onChange={(e) =>
                                        change((draft) => {
                                          const target = draft.teamMembers[memberIndex];
                                          if (!target) return;
                                          const value = e.target.value;
                                          target.skillQualifiers = target.skillQualifiers.filter(
                                            (q) => !(q.skillName === skill.name && q.customValue !== undefined)
                                          );
                                          if (value.trim()) {
                                            target.skillQualifiers.push({
                                              skillName: skill.name,
                                              customValue: value,
                                            });
                                            if (!target.skillNames.includes(skill.name)) {
                                              target.skillNames.push(skill.name);
                                            }
                                          } else {
                                            const stillCovers = target.skillQualifiers.some(
                                              (q) => q.skillName === skill.name
                                            );
                                            if (!stillCovers) {
                                              target.skillNames = target.skillNames.filter(
                                                (name) => name !== skill.name
                                              );
                                            }
                                          }
                                        })
                                      }
                                    />
                                  </label>
                                )}
                              </article>
                            );
                          })}
                      </fieldset>
                      {member.availabilityMode !== 'DYNAMIC' && (
                        <>
                          <div className="title minor">
                            <h4>Faixas de disponibilidade</h4>
                            <button
                              disabled={!editable}
                              onClick={() =>
                                change((draft) => {
                                  const target = draft.teamMembers[memberIndex];
                                  if (target)
                                    target.availability.push({
                                      weekday: 1,
                                      startsAt: '09:00',
                                      endsAt: '18:00',
                                    });
                                })
                              }
                            >
                              Adicionar faixa
                            </button>
                          </div>
                          {member.availability.map((slot, slotIndex) => (
                            <div className="row slot" key={slotIndex}>
                              <select
                                disabled={!editable}
                                value={slot.weekday}
                                onChange={(e) =>
                                  change((draft) => {
                                    const target =
                                      draft.teamMembers[memberIndex]?.availability[slotIndex];
                                    if (target) target.weekday = Number(e.target.value);
                                  })
                                }
                              >
                                {DAYS.map((day, i) => (
                                  <option value={i} key={day}>
                                    {day}
                                  </option>
                                ))}
                              </select>
                              <input
                                type="time"
                                disabled={!editable}
                                value={slot.startsAt}
                                onChange={(e) =>
                                  change((draft) => {
                                    const target =
                                      draft.teamMembers[memberIndex]?.availability[slotIndex];
                                    if (target) target.startsAt = e.target.value;
                                  })
                                }
                              />
                              <input
                                type="time"
                                disabled={!editable}
                                value={slot.endsAt}
                                onChange={(e) =>
                                  change((draft) => {
                                    const target =
                                      draft.teamMembers[memberIndex]?.availability[slotIndex];
                                    if (target) target.endsAt = e.target.value;
                                  })
                                }
                              />
                              <button
                                className="danger"
                                disabled={!editable}
                                onClick={() =>
                                  change((draft) =>
                                    draft.teamMembers[memberIndex]?.availability.splice(slotIndex, 1)
                                  )
                                }
                              >
                                Remover
                              </button>
                            </div>
                          ))}
                        </>
                      )}
                      {member.availabilityMode !== 'FIXED' && (
                        <div className="title minor">
                          <h4>Calendário de disponibilidade Dinâmica</h4>
                        </div>
                      )}
                      {member.availabilityMode !== 'FIXED' && (
                        <>
                          <p className="hint small">
                            Clique nos dias em que {member.name || 'esta pessoa'} vai trabalhar —
                            eles ficam marcados em amarelo, igual você já faz na sua agenda.
                          </p>
                          <DynamicShiftCalendar
                            shifts={member.dynamicShifts}
                            editable={editable}
                            onAddShift={(dateIso) =>
                              change((draft) => {
                                const target = draft.teamMembers[memberIndex];
                                if (!target) return;
                                if (target.dynamicShifts.some((s) => s.shiftDate === dateIso)) return;
                                target.dynamicShifts.push({
                                  shiftDate: dateIso,
                                  startsAt: '09:00',
                                  endsAt: '18:00',
                                });
                              })
                            }
                            onUpdateShift={(dateIso, field, value) =>
                              change((draft) => {
                                const target = draft.teamMembers[memberIndex]?.dynamicShifts.find(
                                  (s) => s.shiftDate === dateIso
                                );
                                if (target) target[field] = value;
                              })
                            }
                            onRemoveShift={(dateIso) =>
                              change((draft) => {
                                const target = draft.teamMembers[memberIndex];
                                if (!target) return;
                                target.dynamicShifts = target.dynamicShifts.filter(
                                  (s) => s.shiftDate !== dateIso
                                );
                              })
                            }
                          />
                        </>
                      )}
                      <button
                        className="danger ghost"
                        disabled={!editable}
                        onClick={() => change((draft) => draft.teamMembers.splice(memberIndex, 1))}
                      >
                        Remover {member.name || 'esta pessoa'}
                      </button>
                    </article>
                  ))}
                </article>
              )}

              {module === 'recursos' && (
                <article className="card">
                  <div className="title">
                    <h2>Recursos</h2>
                    <button
                      disabled={!editable}
                      onClick={() =>
                        change((draft) => draft.resourceTypes.push({ name: '', resources: [] }))
                      }
                    >
                      Adicionar tipo
                    </button>
                  </div>
                  <p className="hint">
                    Cadeiras, macas, salas ou qualquer item físico que limita quantos atendimentos
                    acontecem ao mesmo tempo.
                  </p>
                  {config.resourceTypes.length === 0 && (
                    <p className="empty">Nenhum recurso cadastrado ainda.</p>
                  )}
                  {config.resourceTypes.map((type, typeIndex) => (
                    <article className="nested" key={typeIndex}>
                      <label>
                        Tipo de recurso
                        <input
                          disabled={!editable}
                          value={type.name}
                          placeholder="Ex.: Cadeira"
                          onChange={(e) =>
                            change((draft) => {
                              const target = draft.resourceTypes[typeIndex];
                              if (target) target.name = e.target.value;
                            })
                          }
                        />
                      </label>
                      <div className="title minor">
                        <h4>Itens disponíveis</h4>
                        <button
                          disabled={!editable}
                          onClick={() =>
                            change((draft) =>
                              draft.resourceTypes[typeIndex]?.resources.push({
                                name: '',
                                capacity: 1,
                              })
                            )
                          }
                        >
                          Adicionar item
                        </button>
                      </div>
                      {type.resources.map((resource, resourceIndex) => (
                        <div className="row resource" key={resourceIndex}>
                          <input
                            disabled={!editable}
                            value={resource.name}
                            placeholder="Nome"
                            onChange={(e) =>
                              change((draft) => {
                                const target =
                                  draft.resourceTypes[typeIndex]?.resources[resourceIndex];
                                if (target) target.name = e.target.value;
                              })
                            }
                          />
                          <label className="inline">
                            <span>Capacidade</span>
                            <input
                              type="number"
                              min={1}
                              disabled={!editable}
                              value={resource.capacity}
                              onChange={(e) =>
                                change((draft) => {
                                  const target =
                                    draft.resourceTypes[typeIndex]?.resources[resourceIndex];
                                  if (target) target.capacity = Number(e.target.value);
                                })
                              }
                            />
                          </label>
                          <button
                            className="danger"
                            disabled={!editable}
                            onClick={() =>
                              change((draft) =>
                                draft.resourceTypes[typeIndex]?.resources.splice(resourceIndex, 1)
                              )
                            }
                          >
                            Remover
                          </button>
                        </div>
                      ))}
                      <button
                        className="danger ghost"
                        disabled={!editable}
                        onClick={() => change((draft) => draft.resourceTypes.splice(typeIndex, 1))}
                      >
                        Remover tipo
                      </button>
                    </article>
                  ))}
                </article>
              )}

              {module === 'servicos' && (
                <article className="card">
                  <div className="title">
                    <h2>Serviços</h2>
                    <button
                      disabled={!editable}
                      onClick={() =>
                        change((draft) =>
                          draft.services.push({
                            name: '',
                            basePriceMinor: null,
                            variations: [],
                            steps: [],
                          })
                        )
                      }
                    >
                      Adicionar serviço
                    </button>
                  </div>
                  <p className="hint">
                    Cada serviço pode ter variações (ex.: por comprimento ou volume de cabelo) e
                    etapas internas com duração, competência e recurso exigidos.
                  </p>
                  {config.services.length === 0 && (
                    <p className="empty">Nenhum serviço cadastrado ainda.</p>
                  )}
                  {config.services.map((service, serviceIndex) => (
                    <article className="nested" key={serviceIndex}>
                      <div className="grid two">
                        <label>
                          Serviço
                          <input
                            disabled={!editable}
                            value={service.name}
                            placeholder="Ex.: Progressiva sem formol"
                            onChange={(e) =>
                              change((draft) => {
                                const target = draft.services[serviceIndex];
                                if (target) target.name = e.target.value;
                              })
                            }
                          />
                        </label>
                        <label>
                          Preço base (R$, em centavos)
                          <input
                            type="number"
                            min={0}
                            disabled={!editable}
                            value={service.basePriceMinor ?? ''}
                            onChange={(e) =>
                              change((draft) => {
                                const target = draft.services[serviceIndex];
                                if (target)
                                  target.basePriceMinor =
                                    e.target.value === '' ? null : Number(e.target.value);
                              })
                            }
                          />
                        </label>
                      </div>

                      <div className="title minor">
                        <h4>Variações (comprimento, volume, técnica…)</h4>
                        <button
                          disabled={!editable}
                          onClick={() =>
                            change((draft) =>
                              draft.services[serviceIndex]?.variations.push({
                                name: '',
                                priceMinor: null,
                              })
                            )
                          }
                        >
                          Adicionar variação
                        </button>
                      </div>
                      <p className="hint small">
                        Cada variação é livre: cadastre &ldquo;Cabelo longo&rdquo;, &ldquo;Volume
                        muito&rdquo; ou qualquer critério seu, com o preço correspondente.
                      </p>
                      {service.variations.map((variation, variationIndex) => (
                        <div className="row variation" key={variationIndex}>
                          <input
                            disabled={!editable}
                            value={variation.name}
                            placeholder="Ex.: Cabelo longo"
                            onChange={(e) =>
                              change((draft) => {
                                const target =
                                  draft.services[serviceIndex]?.variations[variationIndex];
                                if (target) target.name = e.target.value;
                              })
                            }
                          />
                          <input
                            type="number"
                            min={0}
                            disabled={!editable}
                            value={variation.priceMinor ?? ''}
                            placeholder="Centavos"
                            onChange={(e) =>
                              change((draft) => {
                                const target =
                                  draft.services[serviceIndex]?.variations[variationIndex];
                                if (target)
                                  target.priceMinor =
                                    e.target.value === '' ? null : Number(e.target.value);
                              })
                            }
                          />
                          <button
                            className="danger"
                            disabled={!editable}
                            onClick={() =>
                              change((draft) =>
                                draft.services[serviceIndex]?.variations.splice(variationIndex, 1)
                              )
                            }
                          >
                            Remover
                          </button>
                        </div>
                      ))}

                      <div className="title minor">
                        <h4>Etapas do atendimento</h4>
                        <button
                          disabled={!editable}
                          onClick={() =>
                            change((draft) => {
                              const target = draft.services[serviceIndex];
                              if (target)
                                target.steps.push({
                                  name: '',
                                  position: target.steps.length + 1,
                                  durationMinutes: 30,
                                  kind: 'ACTIVE',
                                  skillNames: [],
                                  skillQualifiers: [],
                                  resourceRequirements: [],
                                });
                            })
                          }
                        >
                          Adicionar etapa
                        </button>
                      </div>
                      {service.steps.map((step, stepIndex) => (
                        <div className="step" key={stepIndex}>
                          <div className="grid three">
                            <label>
                              Etapa
                              <input
                                disabled={!editable}
                                value={step.name}
                                placeholder="Ex.: Lavagem"
                                onChange={(e) =>
                                  change((draft) => {
                                    const target = draft.services[serviceIndex]?.steps[stepIndex];
                                    if (target) target.name = e.target.value;
                                  })
                                }
                              />
                            </label>
                            <label>
                              Duração (min)
                              <input
                                type="number"
                                min={1}
                                disabled={!editable}
                                value={step.durationMinutes}
                                onChange={(e) =>
                                  change((draft) => {
                                    const target = draft.services[serviceIndex]?.steps[stepIndex];
                                    if (target) target.durationMinutes = Number(e.target.value);
                                  })
                                }
                              />
                            </label>
                            <label>
                              Natureza
                              <select
                                disabled={!editable}
                                value={step.kind}
                                onChange={(e) =>
                                  change((draft) => {
                                    const target = draft.services[serviceIndex]?.steps[stepIndex];
                                    if (target) target.kind = e.target.value as Step['kind'];
                                  })
                                }
                              >
                                <option value="ACTIVE">Ativa — ocupa o profissional</option>
                                <option value="PASSIVE">Passiva — ex.: pausa/espera</option>
                              </select>
                            </label>
                          </div>
                          <fieldset>
                            <legend>Quem pode fazer</legend>
                            {config.skills.filter((s) => s.name).length === 0 && (
                              <p className="empty small">Cadastre competências em Equipe primeiro.</p>
                            )}
                            {config.skills
                              .filter((s) => s.name)
                              .map((skill) => {
                                if (!skill.qualifierLabel) {
                                  return (
                                    <label className="check" key={skill.name}>
                                      <input
                                        type="checkbox"
                                        disabled={!editable}
                                        checked={step.skillNames.includes(skill.name)}
                                        onChange={(e) =>
                                          change((draft) => {
                                            const target = draft.services[serviceIndex]?.steps[stepIndex];
                                            if (!target) return;
                                            target.skillNames = e.target.checked
                                              ? [...target.skillNames, skill.name]
                                              : target.skillNames.filter((name) => name !== skill.name);
                                          })
                                        }
                                      />
                                      {skill.name}
                                    </label>
                                  );
                                }
                                const currentChoice = step.skillQualifiers.find(
                                  (q) => q.skillName === skill.name
                                );
                                const selectValue =
                                  currentChoice?.optionLabel ?? (currentChoice?.customValue !== undefined ? '__custom__' : '');
                                return (
                                  <div className="row slot" key={skill.name}>
                                    <span>
                                      {skill.name} — {skill.qualifierLabel}
                                    </span>
                                    <select
                                      disabled={!editable}
                                      value={selectValue}
                                      onChange={(e) =>
                                        change((draft) => {
                                          const target = draft.services[serviceIndex]?.steps[stepIndex];
                                          if (!target) return;
                                          target.skillQualifiers = target.skillQualifiers.filter(
                                            (q) => q.skillName !== skill.name
                                          );
                                          target.skillNames = target.skillNames.filter(
                                            (name) => name !== skill.name
                                          );
                                          if (e.target.value === '') return;
                                          if (e.target.value === '__custom__') {
                                            target.skillQualifiers.push({ skillName: skill.name, customValue: '' });
                                          } else {
                                            target.skillQualifiers.push({
                                              skillName: skill.name,
                                              optionLabel: e.target.value,
                                            });
                                          }
                                          target.skillNames.push(skill.name);
                                        })
                                      }
                                    >
                                      <option value="">Não exige esta competência</option>
                                      {skill.qualifierOptions.map((option) => (
                                        <option key={option} value={option}>
                                          {option}
                                        </option>
                                      ))}
                                      {skill.qualifierAllowCustom && (
                                        <option value="__custom__">Outro (escrever)</option>
                                      )}
                                    </select>
                                    {currentChoice?.customValue !== undefined && (
                                      <input
                                        disabled={!editable}
                                        placeholder="Qual?"
                                        value={currentChoice.customValue}
                                        onChange={(e) =>
                                          change((draft) => {
                                            const target = draft.services[serviceIndex]?.steps[stepIndex];
                                            const choice = target?.skillQualifiers.find(
                                              (q) => q.skillName === skill.name
                                            );
                                            if (choice) choice.customValue = e.target.value;
                                          })
                                        }
                                      />
                                    )}
                                  </div>
                                );
                              })}
                          </fieldset>
                          <div className="title minor">
                            <h5>Recursos exigidos</h5>
                            <button
                              disabled={!editable || !config.resourceTypes.length}
                              onClick={() =>
                                change((draft) => {
                                  const stepTarget = draft.services[serviceIndex]?.steps[stepIndex];
                                  const firstType = draft.resourceTypes[0];
                                  if (stepTarget && firstType)
                                    stepTarget.resourceRequirements.push({
                                      resourceTypeName: firstType.name,
                                      quantity: 1,
                                      retainUntilServiceEnd: false,
                                    });
                                })
                              }
                            >
                              Adicionar recurso
                            </button>
                          </div>
                          {step.resourceRequirements.map((requirement, requirementIndex) => (
                            <div className="row requirement" key={requirementIndex}>
                              <select
                                disabled={!editable}
                                value={requirement.resourceTypeName}
                                onChange={(e) =>
                                  change((draft) => {
                                    const target =
                                      draft.services[serviceIndex]?.steps[stepIndex]
                                        ?.resourceRequirements[requirementIndex];
                                    if (target) target.resourceTypeName = e.target.value;
                                  })
                                }
                              >
                                {config.resourceTypes
                                  .filter((item) => item.name)
                                  .map((item) => (
                                    <option key={item.name}>{item.name}</option>
                                  ))}
                              </select>
                              <input
                                type="number"
                                min={1}
                                disabled={!editable}
                                value={requirement.quantity}
                                onChange={(e) =>
                                  change((draft) => {
                                    const target =
                                      draft.services[serviceIndex]?.steps[stepIndex]
                                        ?.resourceRequirements[requirementIndex];
                                    if (target) target.quantity = Number(e.target.value);
                                  })
                                }
                              />
                              <label className="check">
                                <input
                                  type="checkbox"
                                  disabled={!editable}
                                  checked={requirement.retainUntilServiceEnd}
                                  onChange={(e) =>
                                    change((draft) => {
                                      const target =
                                        draft.services[serviceIndex]?.steps[stepIndex]
                                          ?.resourceRequirements[requirementIndex];
                                      if (target) target.retainUntilServiceEnd = e.target.checked;
                                    })
                                  }
                                />
                                Reter até o fim do serviço
                              </label>
                              <button
                                className="danger"
                                disabled={!editable}
                                onClick={() =>
                                  change((draft) =>
                                    draft.services[serviceIndex]?.steps[
                                      stepIndex
                                    ]?.resourceRequirements.splice(requirementIndex, 1)
                                  )
                                }
                              >
                                Remover
                              </button>
                            </div>
                          ))}
                          <button
                            className="danger ghost"
                            disabled={!editable}
                            onClick={() =>
                              change((draft) => {
                                const target = draft.services[serviceIndex];
                                if (!target) return;
                                target.steps.splice(stepIndex, 1);
                                target.steps.forEach((item, index) => {
                                  item.position = index + 1;
                                });
                              })
                            }
                          >
                            Remover etapa
                          </button>
                        </div>
                      ))}
                      <button
                        className="danger ghost"
                        disabled={!editable}
                        onClick={() => change((draft) => draft.services.splice(serviceIndex, 1))}
                      >
                        Remover {service.name || 'este serviço'}
                      </button>
                    </article>
                  ))}
                </article>
              )}

              {module === 'simulacao' && (
                unitId ? (
                  <SchedulingSimulator tenantId={tenantId} unitId={unitId} />
                ) : (
                  <article className="card">
                    <h2>Simulação</h2>
                    <p className="empty">Carregando…</p>
                  </article>
                )
              )}

              {module === 'publicar' && (
                <article className="card publish">
                  <h2>Publicar</h2>
                  <p className="hint">
                    Publicar congela esta configuração como a versão vigente do atendimento. Depois
                    de publicada, ela não pode mais ser editada — só uma nova versão substitui a
                    anterior.
                  </p>
                  {readiness.length ? (
                    <ul>
                      {readiness.map((item, index) => (
                        <li key={`${item.code}-${index}`}>{ISSUE[item.code] ?? item.code}</li>
                      ))}
                    </ul>
                  ) : (
                    <p className="ready">Tudo pronto para publicar.</p>
                  )}
                  <p className="scope">
                    Sinal de pagamento está desativado nesta fase. Google Agenda e WhatsApp para
                    clientes reais serão liberados depois dos testes do motor de disponibilidade.
                  </p>
                  <div className="actions">
                    <button
                      className="secondary"
                      disabled={!editable || busy || !dirty}
                      onClick={() => void save()}
                    >
                      {busy ? 'Processando…' : 'Salvar alterações'}
                    </button>
                    <button
                      className="primary"
                      disabled={!editable || busy || dirty || readiness.length > 0}
                      onClick={() => void publish()}
                    >
                      Publicar versão
                    </button>
                  </div>
                </article>
              )}
            </>
          )}
        </section>
      </div>
      <footer>Acesso exclusivo do proprietário · nenhuma função simulada</footer>
    </main>
  );
}
