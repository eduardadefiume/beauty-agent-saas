/*
 * Caderno de Operações — página do dashboard do Piloto William.
 * A tela transforma configuração técnica em evidência legível: estado antes de ornamento,
 * assimetria controlada, calor editorial e honestidade sobre o que ainda não foi testado.
 */
import { useMemo, useState } from "react";
import { toast } from "sonner";
import {
  Activity,
  ArrowUpRight,
  Bell,
  CalendarDays,
  Check,
  ChevronRight,
  CircleAlert,
  CircleDot,
  Clock3,
  Database,
  ExternalLink,
  FileCheck2,
  GitBranch,
  Headset,
  Inbox,
  LayoutDashboard,
  Menu,
  MessageCircle,
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
} from "lucide-react";

const heroImage = "/manus-storage/william-pilot-hero_f9077983.jpg";
const textureImage = "/manus-storage/william-pilot-texture_e895a12e.jpg";
const detailImage = "/manus-storage/william-pilot-detail_c7cd650e.jpg";
const brandMark = "/manus-storage/william-pilot-mark_4c4daad9.png";

const navItems = [
  { label: "Visão geral", icon: LayoutDashboard, target: "overview" },
  { label: "Integrações", icon: Network, target: "integrations" },
  { label: "Agenda", icon: CalendarDays, target: "schedule" },
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
    evidence: "Schema app / private / api criado no Supabase DEV. As políticas de RLS são a base do isolamento por tenant_id.",
  },
  {
    name: "Credenciais & segredos",
    detail: "Meta Cloud API + OpenAI configurados",
    status: "Configurado",
    tone: "olive",
    icon: ShieldCheck,
    evidence: "WHATSAPP_VERIFY_TOKEN, WHATSAPP_ACCESS_TOKEN e OPENAI_API_KEY foram configurados nas Edge Functions.",
  },
  {
    name: "Allowlist do piloto",
    detail: "+55 16 99421-5487 · status ACTIVE",
    status: "Ativo",
    tone: "olive",
    icon: Users,
    evidence: "O número de teste está autorizado para o tenant William e pode disparar a primeira mensagem controlada.",
  },
  {
    name: "Webhook WhatsApp",
    detail: "Endpoint apontado para a Edge Function",
    status: "Aguardando prova",
    tone: "amber",
    icon: Radio,
    evidence: "A configuração do webhook e a subscrição do campo messages estão concluídas. Ainda não há evento real em app.inbox_events.",
  },
];

const milestones = [
  { number: "01", label: "Fundação", caption: "39 migrações", state: "done" },
  { number: "02", label: "Conexão", caption: "Meta + OpenAI", state: "done" },
  { number: "03", label: "Allowlist", caption: "William autorizado", state: "done" },
  { number: "04", label: "Primeira mensagem", caption: "0 eventos recebidos", state: "current" },
  { number: "05", label: "Agenda real", caption: "Serviços pendentes", state: "next" },
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

  const completedComponents = useMemo(() => components.filter((component) => component.tone === "olive").length, []);

  const handleNav = (target: string) => {
    setActiveNav(target);
    setMobileNavOpen(false);
    document.getElementById(target)?.scrollIntoView({ behavior: "smooth", block: "start" });
  };

  const showPending = (label: string) => {
    toast(`${label} ainda não está conectado`, {
      description: "O painel mostra a configuração atual sem simular uma integração de produção.",
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
          <span className="nav-label">LEITURA DO ESTADO</span>
          <p>Configuração concluída não equivale a fluxo real testado.</p>
          <div className="mini-signal"><span /><span /><span /></div>
        </div>
        <div className="sidebar-footer">
          <button className="sidebar-footer-link" onClick={() => showPending("Sincronização ao vivo")}>
            <Activity size={15} /> Atualização manual
          </button>
          <span className="version-stamp">v0.1 / DEV</span>
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
            <div className="live-indicator"><span className="live-dot" /> ambiente DEV</div>
            <button className="icon-button" aria-label="Notificações" onClick={() => showPending("Notificações")}><Bell size={17} /></button>
            <button className="avatar-button" aria-label="Perfil de Duda">D</button>
          </div>
        </header>

        <div className="content-wrap">
          <section className="intro-row" id="overview">
            <div className="intro-copy">
              <div className="overline"><span className="overline-line" /> relatório de prontidão operacional</div>
              <div className="dossier-signature">
                <img src={brandMark} alt="" />
                <div><strong>WILLIAM / PILOTO</strong><span>caderno operacional · revisão 001</span></div>
              </div>
              <h1>O caminho está<br /><em>configurado.</em></h1>
              <p className="intro-lede">A fundação do piloto está em pé. Agora falta provar a primeira mensagem e dar forma à agenda real do William.</p>
              <div className="intro-meta">
                <span><Clock3 size={14} /> última verificação · 13 ago 2026</span>
                <span><GitBranch size={14} /> branch · dev</span>
              </div>
              <div className="proof-rail">
                <div><span>leitura de evidência</span><strong>3 bases atravessadas</strong></div>
                <div className="proof-pending"><span className="proof-dot" /><div><span>próxima prova</span><strong>0 eventos reais</strong></div></div>
              </div>
            </div>
            <div className="hero-frame">
              <img src={heroImage} alt="Interior do salão com estações de atendimento" />
              <div className="hero-frame-label"><span>01</span><span>base operacional</span></div>
              <div className="hero-stamp"><img src={brandMark} alt="" /> W / 001</div>
              <div className="hero-proof-tag"><span className="live-dot" /> configuração validada / prova pendente</div>
            </div>
          </section>

          <section className="status-strip" aria-label="Resumo do estado atual">
            <div className="status-primary">
              <div className="status-icon"><ScanLine size={21} /></div>
              <div><span className="eyebrow">estado atual</span><strong>Pronto para teste controlado</strong></div>
            </div>
            <div className="status-stat"><span className="stat-label">COMPONENTES CONFIGURADOS</span><strong>{completedComponents}<small> / 4</small></strong></div>
            <div className="status-stat"><span className="stat-label">EVENTOS REAIS</span><strong>0</strong><span className="stat-foot">app.inbox_events</span></div>
            <button className="status-action" onClick={() => handleNav("evidence")}>ver evidências <ArrowUpRight size={16} /></button>
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
              <SectionHeading eyebrow="01 / integridade da base" title="O que já está de pé" copy="Cada item abaixo tem uma configuração identificável. Abra para ver a evidência e a fronteira do que ainda precisa ser provado." />
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
                <p>O número <strong>+55 16 99421-5487</strong> já está na allowlist. Envie uma mensagem para o número do bot e confirme a entrada em <code>app.inbox_events</code>.</p>
                <button className="ink-button" onClick={() => toast("Aguardando a primeira mensagem", { description: "Quando o WhatsApp receber o evento, ele aparecerá aqui como evidência real." })}>registrar intenção de teste <ArrowUpRight size={16} /></button>
              </div>
            </aside>
          </div>

          <section className="schedule-section" id="schedule">
            <div className="schedule-copy">
              <span className="eyebrow">02 / agenda real</span>
              <h2>O próximo bloco ainda está em branco.</h2>
              <p>O motor de agendamento depende de serviços, duração e disponibilidade profissional. Nada foi inventado aqui: estes dados precisam vir do William antes da publicação do fluxo.</p>
              <button className="text-button" onClick={() => showPending("Configuração da agenda")}>configurar quando houver dados <ChevronRight size={16} /></button>
            </div>
            <div className="schedule-blank">
              <div className="blank-grid" />
              <CalendarDays size={28} strokeWidth={1.2} />
              <span>serviços e horários<br /><strong>aguardando definição</strong></span>
              <div className="blank-corner">— / —</div>
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
              <button className="action-row" onClick={() => showPending("Serviços do William")}><span className="action-number">02</span><span><strong>Definir serviços e duração</strong><small>Alimentar a agenda do piloto</small></span><ArrowUpRight size={16} /></button>
              <button className="action-row" onClick={() => showPending("Disponibilidade profissional")}><span className="action-number">03</span><span><strong>Registrar disponibilidade</strong><small>Fechar a regra de oferta de horários</small></span><ArrowUpRight size={16} /></button>
            </div>
          </section>

          <footer className="page-footer"><span><Zap size={13} /> William / piloto restrito / Supabase DEV</span><span>fonte: relatorio-final-piloto-william.md</span><span className="footer-seal">não publicar sem evidência</span></footer>
        </div>
      </main>

      {selectedComponent && (
        <div className="drawer-backdrop" onClick={() => setSelectedComponent(null)}>
          <aside className="evidence-drawer" onClick={(event) => event.stopPropagation()}>
            <div className="drawer-head"><div><span className="eyebrow">evidência do componente</span><h2>{selectedComponent.name}</h2></div><button className="icon-button" aria-label="Fechar evidência" onClick={() => setSelectedComponent(null)}><X size={18} /></button></div>
            <div className="drawer-status"><StatusPill tone={selectedComponent.tone}>{selectedComponent.status}</StatusPill><span>William / DEV</span></div>
            <p className="drawer-detail">{selectedComponent.detail}</p>
            <div className="drawer-note"><FileCheck2 size={17} /><p>{selectedComponent.evidence}</p></div>
            <div className="drawer-meta"><span><Terminal size={14} /> fonte registrada no relatório</span><span><Inbox size={14} /> sem sincronização ao vivo</span></div>
            <button className="ink-button drawer-button" onClick={() => toast("Evidência copiada", { description: "A ação é visual neste protótipo; exportação ainda não está conectada." })}>copiar referência <ExternalLink size={15} /></button>
          </aside>
        </div>
      )}
    </div>
  );
}
