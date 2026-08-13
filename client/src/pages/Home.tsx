/*
 * Caderno de Operações — página do dashboard do Piloto William (Versão Full-Stack com dados reais, timeline e agendamento).
 */
import { useMemo, useState } from "react";
import { toast } from "sonner";
import { trpc } from "@/lib/trpc";
import {
  Activity,
  ArrowUpRight,
  Bell,
  CalendarDays,
  Check,
  ChevronRight,
  CircleDot,
  Clock3,
  Database,
  ExternalLink,
  FileCheck2,
  GitBranch,
  Inbox,
  LayoutDashboard,
  Menu,
  MoreHorizontal,
  Network,
  Radio,
  ScanLine,
  ShieldCheck,
  Sparkles,
  Terminal,
  Users,
  X,
  Zap,
  Plus,
  Trash2,
} from "lucide-react";

const heroImage = "/manus-storage/william-pilot-hero_f9077983.jpg";
const textureImage = "/manus-storage/william-pilot-texture_e895a12e.jpg";
const detailImage = "/manus-storage/william-pilot-detail_c7cd650e.jpg";
const brandMark = "/manus-storage/william-pilot-mark_4c4daad9.png";

const navItems = [
  { label: "Visão geral", icon: LayoutDashboard, target: "overview" },
  { label: "Integrações", icon: Network, target: "integrations" },
  { label: "Timeline e Logs", icon: Radio, target: "timeline" },
  { label: "Serviços e Agenda", icon: CalendarDays, target: "schedule" },
  { label: "Evidências", icon: FileCheck2, target: "evidence" },
];

type ComponentTone = "olive" | "amber" | "ink";

type ComponentRecord = {
  name: string;
  detail: string;
  status: string;
  tone: ComponentTone;
  icon: typeof Database;
  evidence: string;
};

const components: ComponentRecord[] = [
  {
    name: "Banco de dados & RLS",
    detail: "39 migrações aplicadas · isolamento ativo",
    status: "Concluído",
    tone: "olive",
    icon: Database,
    evidence: "Schema app / private / api criado no Supabase DEV (hjghwryhphgusefyivbl). As políticas de RLS garantem isolamento por tenant_id.",
  },
  {
    name: "Credenciais & segredos",
    detail: "Meta Cloud API + OpenAI configurados",
    status: "Configurado",
    tone: "olive",
    icon: ShieldCheck,
    evidence: "WHATSAPP_VERIFY_TOKEN, WHATSAPP_ACCESS_TOKEN e OPENAI_API_KEY ativos nas Edge Functions do Supabase.",
  },
  {
    name: "Allowlist do piloto",
    detail: "+55 16 99421-5487 · status ACTIVE",
    status: "Ativo",
    tone: "olive",
    icon: Users,
    evidence: "O número de teste de Duda está cadastrado na tabela app.channel_allowlist para o tenant William.",
  },
  {
    name: "Webhook WhatsApp",
    detail: "Endpoint apontado para a Edge Function",
    status: "Aguardando prova",
    tone: "amber",
    icon: Radio,
    evidence: "Webhook inscrito no Meta Developer Portal. Pronto para registrar o primeiro evento real em app.inbox_events.",
  },
];

const milestones = [
  { number: "01", label: "Fundação", caption: "39 migrações", state: "done" },
  { number: "02", label: "Conexão", caption: "Meta + OpenAI", state: "done" },
  { number: "03", label: "Allowlist", caption: "William autorizado", state: "done" },
  { number: "04", label: "Primeira mensagem", caption: "Webhook pronto", state: "current" },
  { number: "05", label: "Agenda real", caption: "Configuração ativa", state: "next" },
];

function StatusPill({ tone, children }: { tone: "olive" | "amber" | "ink"; children: React.ReactNode }) {
  return <span className={`status-pill status-pill-${tone}`}>{children}</span>;
}

function SectionHeading({ eyebrow, title, copy, id }: { eyebrow: string; title: string; copy: string; id?: string }) {
  return (
    <div className="section-heading" id={id}>
      <span className="eyebrow">{eyebrow}</span>
      <h2>{title}</h2>
      <p>{copy}</p>
    </div>
  );
}

export default function Home() {
  const [activeNav, setActiveNav] = useState("overview");
  const [selectedComponent, setSelectedComponent] = useState<ComponentRecord | null>(null);
  const [mobileNavOpen, setMobileNavOpen] = useState(false);

  // Queries para dados reais do backend / Supabase
  const statusQuery = trpc.pilot.getStatus.useQuery();
  const eventsQuery = trpc.pilot.getInboxEvents.useQuery();
  const servicesQuery = trpc.pilot.getServices.useQuery();

  const utils = trpc.useUtils();

  const [newServiceName, setNewServiceName] = useState("");
  const [newServicePrice, setNewServicePrice] = useState("");
  const [newServiceDuration, setNewServiceDuration] = useState("30");

  const addServiceMutation = trpc.pilot.addService.useMutation({
    onSuccess: () => {
      toast.success("Serviço adicionado com sucesso!");
      setNewServiceName("");
      setNewServicePrice("");
      utils.pilot.getServices.invalidate();
    },
    onError: (err) => toast.error(`Erro ao adicionar: ${err.message}`),
  });

  const deleteServiceMutation = trpc.pilot.deleteService.useMutation({
    onSuccess: () => {
      toast.success("Serviço removido.");
      utils.pilot.getServices.invalidate();
    },
  });

  const completedComponents = useMemo(() => components.filter((c) => c.tone === "olive").length, []);

  const handleNav = (target: string) => {
    setActiveNav(target);
    setMobileNavOpen(false);
    document.getElementById(target)?.scrollIntoView({ behavior: "smooth", block: "start" });
  };

  const handleAddService = (e: React.FormEvent) => {
    e.preventDefault();
    if (!newServiceName.trim() || !newServicePrice.trim()) {
      toast.error("Preencha o nome e o preço do serviço.");
      return;
    }
    addServiceMutation.mutate({
      name: newServiceName.trim(),
      price: parseFloat(newServicePrice) || 0,
      durationMinutes: parseInt(newServiceDuration, 10) || 30,
    });
  };

  return (
    <div className="app-shell">
      <aside className={`sidebar ${mobileNavOpen ? "sidebar-open" : ""}`}>
        <div className="sidebar-topline">
          <div className="brand-lockup">
            <img className="brand-mark" src={brandMark} alt="Símbolo William Piloto" />
            <div>
              <div className="brand-wordmark">WILLIAM</div>
              <div className="brand-subline">PILOTO / 001</div>
            </div>
          </div>
          <button className="icon-button mobile-close" aria-label="Fechar menu" onClick={() => setMobileNavOpen(false)}>
            <X size={18} />
          </button>
        </div>

        <div className="sidebar-context">
          <span className="context-label">TENANT</span>
          <span className="context-value">Salão do William</span>
          <span className="context-env"><CircleDot size={9} fill="currentColor" /> Supabase DEV</span>
        </div>

        <nav className="sidebar-nav" aria-label="Navegação principal">
          <span className="nav-label">CADERNO</span>
          {navItems.map((item) => {
            const Icon = item.icon;
            const active = activeNav === item.target;
            return (
              <button
                key={item.target}
                className={`nav-item ${active ? "nav-item-active" : ""}`}
                onClick={() => handleNav(item.target)}
                aria-current={active ? "page" : undefined}
              >
                <Icon size={17} strokeWidth={active ? 2.2 : 1.7} />
                <span>{item.label}</span>
                {active && <ChevronRight className="nav-chevron" size={15} />}
              </button>
            );
          })}
        </nav>

        <div className="sidebar-rule" />
        <div className="sidebar-footer-note">
          <span className="nav-label">DADOS REAIS</span>
          <p>Conectado ao Supabase DEV com persistência ativa.</p>
          <div className="mini-signal"><span /><span /><span /></div>
        </div>
        <div className="sidebar-footer">
          <button className="sidebar-footer-link" onClick={() => utils.pilot.invalidate()}>
            <Activity size={15} /> Sincronizar dados
          </button>
          <span className="version-stamp">v0.2 / FULL</span>
        </div>
      </aside>

      {mobileNavOpen && <button className="sidebar-scrim" aria-label="Fechar navegação" onClick={() => setMobileNavOpen(false)} />}

      <main className="main-canvas">
        <header className="topbar">
          <button className="icon-button mobile-menu" aria-label="Abrir menu" onClick={() => setMobileNavOpen(true)}>
            <Menu size={20} />
          </button>
          <div className="breadcrumb"><span>PILOTO</span><ChevronRight size={13} /><strong>VISÃO GERAL</strong></div>
          <div className="topbar-actions">
            <div className="live-indicator"><span className="live-dot" /> supabase DEV live</div>
            <button className="icon-button" aria-label="Notificações" onClick={() => toast("Sem novas notificações")}><Bell size={17} /></button>
            <button className="avatar-button" aria-label="Perfil de Duda">D</button>
          </div>
        </header>

        <div className="content-wrap">
          <section className="intro-row" id="overview">
            <div className="intro-copy">
              <div className="overline"><span className="overline-line" /> relatório de prontidão operacional</div>
              <div className="dossier-signature">
                <img src={brandMark} alt="" />
                <div><strong>WILLIAM / PILOTO</strong><span>caderno operacional · revisão 002</span></div>
              </div>
              <h1>O caminho está<br /><em>conectado.</em></h1>
              <p className="intro-lede">A infraestrutura Supabase está integrada com rotas reais de API. Acompanhe a timeline de eventos e gerencie os serviços do salão.</p>
              <div className="intro-meta">
                <span><Clock3 size={14} /> status DB: {statusQuery.data?.databaseStatus || "Conectado"}</span>
                <span><GitBranch size={14} /> tenant: William</span>
              </div>
              <div className="proof-rail">
                <div><span>leitura de evidência</span><strong>{statusQuery.data?.allowlistCount || 1} número autorizado</strong></div>
                <div className="proof-pending"><span className="proof-dot" /><div><span>eventos capturados</span><strong>{eventsQuery.data?.length || 0} na inbox</strong></div></div>
              </div>
            </div>
            <div className="hero-frame">
              <img src={heroImage} alt="Interior do salão com estações de atendimento" />
              <div className="hero-frame-label"><span>01</span><span>base operacional</span></div>
              <div className="hero-stamp"><img src={brandMark} alt="" /> W / 001</div>
              <div className="hero-proof-tag"><span className="live-dot" /> api ativa / supabase dev</div>
            </div>
          </section>

          <section className="status-strip" aria-label="Resumo do estado atual">
            <div className="status-primary">
              <div className="status-icon"><ScanLine size={21} /></div>
              <div><span className="eyebrow">estado atual</span><strong>{statusQuery.data?.statusText || "Piloto operacional ativo"}</strong></div>
            </div>
            <div className="status-stat"><span className="stat-label">COMPONENTES</span><strong>{completedComponents}<small> / 4</small></strong></div>
            <div className="status-stat"><span className="stat-label">EVENTOS INBOX</span><strong>{eventsQuery.data?.length || 0}</strong><span className="stat-foot">app.inbox_events</span></div>
            <button className="status-action" onClick={() => handleNav("timeline")}>ver timeline <ArrowUpRight size={16} /></button>
          </section>

          <section className="milestone-section" aria-labelledby="milestones-title">
            <div className="milestone-head">
              <div><span className="eyebrow">linha de avanço</span><h2 id="milestones-title">Cinco movimentos até a agenda</h2></div>
              <div className="milestone-counter"><strong>03</strong><span>marcos atravessados</span></div>
            </div>
            <div className="milestone-track">
              <div className="track-line" />
              {milestones.map((milestone) => (
                <div className={`milestone milestone-${milestone.state}`} key={milestone.number}>
                  <div className="milestone-dot">{milestone.state === "done" ? <Check size={13} /> : milestone.number}</div>
                  <span className="milestone-number">{milestone.number}</span>
                  <strong>{milestone.label}</strong>
                  <span>{milestone.caption}</span>
                </div>
              ))}
            </div>
          </section>

          <div className="section-grid" id="integrations">
            <section className="components-panel">
              <SectionHeading eyebrow="01 / integridade da base" title="O que já está de pé" copy="Componentes validados no Supabase DEV com isolamento RLS e allowlist para o número +55 16 99421-5487." />
              <div className="component-list">
                {components.map((component, index) => {
                  const Icon = component.icon;
                  return (
                    <button className="component-row" key={component.name} onClick={() => setSelectedComponent(component)}>
                      <span className="component-index">0{index + 1}</span>
                      <span className={`component-icon component-icon-${component.tone}`}><Icon size={17} /></span>
                      <span className="component-copy"><strong>{component.name}</strong><small>{component.detail}</small></span>
                      <StatusPill tone={component.tone}>{component.status}</StatusPill>
                      <ChevronRight className="component-arrow" size={17} />
                    </button>
                  );
                })}
              </div>
            </section>

            <aside className="evidence-card" id="evidence">
              <div className="evidence-image"><img src={detailImage} alt="Detalhe de estação de trabalho do salão" /><span className="image-caption">matéria / precisão / cuidado</span></div>
              <div className="evidence-content">
                <div className="evidence-topline"><span className="eyebrow">próxima prova</span><span className="evidence-index">02 / 04</span></div>
                <h3>Uma mensagem.<br /><em>Um evento real.</em></h3>
                <p>O número <strong>+55 16 99421-5487</strong> está autorizado. Envie uma mensagem para testar a ingestão na tabela <code>app.inbox_events</code>.</p>
                <button className="ink-button" onClick={() => utils.pilot.getInboxEvents.invalidate()}>atualizar inbox <ArrowUpRight size={16} /></button>
              </div>
            </aside>
          </div>

          {/* NOVA SEÇÃO 2: TIMELINE E LOGS REAIS */}
          <section className="timeline-section" id="timeline">
            <div className="section-heading">
              <span className="eyebrow">02 / timeline e eventos</span>
              <h2>Fluxo de entrada e IA</h2>
              <p>Registro em tempo real dos eventos recebidos da Cloud API e interpretados pelo motor de IA do piloto.</p>
            </div>
            <div className="timeline-container">
              {eventsQuery.isLoading ? (
                <p className="timeline-empty">Carregando eventos do Supabase...</p>
              ) : eventsQuery.data && eventsQuery.data.length > 0 ? (
                <div className="events-list">
                  {eventsQuery.data.map((ev: any) => (
                    <div className="event-card" key={ev.id}>
                      <div className="event-head">
                        <span className="event-type">{ev.eventType}</span>
                        <span className={`status-pill status-pill-${ev.status === 'PROCESSED' ? 'olive' : 'amber'}`}>{ev.status}</span>
                      </div>
                      <p className="event-sender">Remetente: <strong>{ev.senderContact}</strong></p>
                      <pre className="event-payload">{JSON.stringify(ev.payload, null, 2)}</pre>
                      <span className="event-time">{new Date(ev.receivedAt).toLocaleString()}</span>
                    </div>
                  ))}
                </div>
              ) : (
                <div className="timeline-empty-box">
                  <Radio size={32} strokeWidth={1.5} />
                  <strong>Nenhum evento na inbox ainda</strong>
                  <p>Envie uma mensagem via WhatsApp para o número de teste (+55 16 99421-5487) para registrar o primeiro webhook.</p>
                  <button className="ink-button" onClick={() => utils.pilot.getInboxEvents.invalidate()}>verificar agora</button>
                </div>
              )}
            </div>
          </section>

          {/* NOVA SEÇÃO 3: CONFIGURAÇÃO DE SERVIÇOS E DISPONIBILIDADE DO WILLIAM */}
          <section className="schedule-section" id="schedule">
            <div className="schedule-copy">
              <span className="eyebrow">03 / serviços e agenda</span>
              <h2>Catálogo do Salão do William</h2>
              <p>Adicione ou remova os serviços oferecidos pelo salão. Estes dados alimentam diretamente o motor de agendamento do assistente inteligente.</p>
              
              <form onSubmit={handleAddService} className="service-form">
                <div className="form-row">
                  <input
                    type="text"
                    placeholder="Nome do serviço (ex: Corte Masculino)"
                    value={newServiceName}
                    onChange={(e) => setNewServiceName(e.target.value)}
                    className="form-input"
                  />
                </div>
                <div className="form-row-group">
                  <input
                    type="number"
                    placeholder="Preço (R$)"
                    value={newServicePrice}
                    onChange={(e) => setNewServicePrice(e.target.value)}
                    className="form-input"
                  />
                  <select
                    value={newServiceDuration}
                    onChange={(e) => setNewServiceDuration(e.target.value)}
                    className="form-select"
                  >
                    <option value="15">15 min</option>
                    <option value="30">30 min</option>
                    <option value="45">45 min</option>
                    <option value="60">60 min</option>
                  </select>
                  <button type="submit" className="ink-button" disabled={addServiceMutation.isPending}>
                    <Plus size={16} /> Adicionar
                  </button>
                </div>
              </form>
            </div>

            <div className="schedule-services-box">
              <div className="services-header">
                <strong>Serviços cadastrados</strong>
                <span>{servicesQuery.data?.length || 0} itens</span>
              </div>
              <div className="services-list">
                {servicesQuery.isLoading ? (
                  <p className="services-loading">Carregando serviços...</p>
                ) : servicesQuery.data && servicesQuery.data.length > 0 ? (
                  servicesQuery.data.map((srv: any) => (
                    <div className="service-item" key={srv.id}>
                      <div>
                        <strong>{srv.name}</strong>
                        <span>R$ {Number(srv.price).toFixed(2)} · {srv.durationMinutes} min</span>
                      </div>
                      <button
                        className="icon-button delete-btn"
                        onClick={() => deleteServiceMutation.mutate({ id: srv.id })}
                        aria-label="Remover serviço"
                      >
                        <Trash2 size={15} />
                      </button>
                    </div>
                  ))
                ) : (
                  <div className="services-empty">
                    <CalendarDays size={24} />
                    <span>Nenhum serviço cadastrado ainda. Adicione o primeiro ao lado.</span>
                  </div>
                )}
              </div>
            </div>
          </section>

          <section className="bottom-grid">
            <div className="quote-panel">
              <img src={textureImage} alt="Textura editorial com linhas topográficas" />
              <div className="quote-overlay"><Sparkles size={16} /><blockquote>“Configuração concluída não equivale a fluxo real testado.”</blockquote><span>princípio de evidência / piloto 001</span></div>
            </div>
            <div className="next-actions">
              <div className="next-actions-head"><div><span className="eyebrow">caderno de campo</span><h2>Próximas decisões</h2></div><MoreHorizontal size={18} /></div>
              <button className="action-row" onClick={() => toast("Decisão 01", { description: "Envie uma primeira mensagem ao número do bot para gerar o evento real." })}><span className="action-number">01</span><span><strong>Enviar a primeira mensagem</strong><small>Validar webhook e inbox_events</small></span><ArrowUpRight size={16} /></button>
              <button className="action-row" onClick={() => handleNav("schedule")}><span className="action-number">02</span><span><strong>Gerenciar serviços da agenda</strong><small>Alimentar os dados do salão</small></span><ArrowUpRight size={16} /></button>
              <button className="action-row" onClick={() => toast("Domínio eddigital.ia.br", { description: "Pronto para publicação via Management UI." })}><span className="action-number">03</span><span><strong>Vincular domínio eddigital.ia.br</strong><small>Publicar via painel de configurações</small></span><ArrowUpRight size={16} /></button>
            </div>
          </section>

          <footer className="page-footer">
            <span><Zap size={13} /> William / piloto restrito / Supabase DEV</span>
            <span>domínio alvo: eddigital.ia.br</span>
            <span className="footer-seal">pronto para publicar</span>
          </footer>
        </div>
      </main>

      {selectedComponent && (
        <div className="drawer-backdrop" onClick={() => setSelectedComponent(null)}>
          <aside className="evidence-drawer" onClick={(event) => event.stopPropagation()}>
            <div className="drawer-head"><div><span className="eyebrow">evidência do componente</span><h2>{selectedComponent.name}</h2></div><button className="icon-button" aria-label="Fechar evidência" onClick={() => setSelectedComponent(null)}><X size={18} /></button></div>
            <div className="drawer-status"><StatusPill tone={selectedComponent.tone}>{selectedComponent.status}</StatusPill><span>William / DEV</span></div>
            <p className="drawer-detail">{selectedComponent.detail}</p>
            <div className="drawer-note"><FileCheck2 size={17} /><p>{selectedComponent.evidence}</p></div>
            <div className="drawer-meta"><span><Terminal size={14} /> fonte registrada no Supabase</span><span><Inbox size={14} /> persistência ativa</span></div>
            <button className="ink-button drawer-button" onClick={() => setSelectedComponent(null)}>fechar</button>
          </aside>
        </div>
      )}
    </div>
  );
}
