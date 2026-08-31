"use client";

import { useEffect, useState } from "react";
import { toast } from "sonner";
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
} from "lucide-react";
import styles from "./dashboard.module.css";

type TenantWorkspace = {
  tenantId: string;
  tenantName: string;
  tenantSlug: string;
  unitId: string;
  unitName: string;
  timezone: string;
  status: string;
};

type InboxEventRecord = {
  id: string;
  eventType: string;
  status: 'PROCESSED' | 'PENDING' | 'FAILED';
  senderContact: string;
  payload: unknown;
  receivedAt: string;
};

const heroImage = "https://images.unsplash.com/photo-1560066984-138dadb4c035?auto=format&fit=crop&q=80&w=1200";
const textureImage = "https://images.unsplash.com/photo-1618005182384-a83a8bd57fbe?auto=format&fit=crop&q=80&w=800";
const detailImage = "https://images.unsplash.com/photo-1522337360788-8b13dee7a37e?auto=format&fit=crop&q=80&w=800";

type NavItem = {
  label: string;
  icon: typeof LayoutDashboard;
  target: string;
  // Quando presente, o item leva para outra página em vez de rolar até uma
  // seção desta.
  href?: string;
};

const navItems: NavItem[] = [
  { label: "Visão geral", icon: LayoutDashboard, target: "overview" },
  { label: "Integrações", icon: Network, target: "integrations" },
  { label: "Timeline e Logs", icon: Radio, target: "timeline" },
  // Único item que sai do dashboard: o console de WhatsApp é uma tela própria,
  // porque atualiza sozinha e tem o botão de parada de emergência.
  { label: "WhatsApp ao vivo", icon: Inbox, target: "whatsapp", href: "/whatsapp" },
  // Também sai do dashboard: a ficha da cliente é operação, não configuração,
  // e por isso não vive no configurador (que congela quando o negócio está
  // publicado).
  { label: "Clientes", icon: Users, target: "clientes", href: "/clientes" },
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
    detail: "Isolamento por tenant no modelo operacional",
    status: "Em validação",
    tone: "olive",
    icon: Database,
    evidence: "A operação deve carregar somente o tenant autorizado pela sessão. A prova final depende dos testes negativos de RLS no Supabase.",
  },
  {
    name: "Credenciais & segredos",
    detail: "Canais externos são configurados por negócio",
    status: "Pendente de canal",
    tone: "amber",
    icon: ShieldCheck,
    evidence: "Nenhuma credencial é compartilhada entre tenants. A conexão WhatsApp só pode ser exibida após a vinculação do canal do próprio negócio.",
  },
  {
    name: "Consentimento e contatos",
    detail: "Base CRM e evidências por finalidade",
    status: "Em implantação",
    tone: "amber",
    icon: Users,
    evidence: "Contatos, canais e consentimentos serão segregados por tenant. Nenhum contato de outro negócio pode aparecer nesta área.",
  },
  {
    name: "Webhook WhatsApp",
    detail: "Eventos aparecerão após a conexão do canal",
    status: "Aguardando conexão",
    tone: "amber",
    icon: Radio,
    evidence: "A inbox só exibirá mensagens do canal associado ao negócio atual, após a validação do webhook e das políticas de acesso.",
  },
];

const milestones = [
  { number: "01", label: "Fundação", caption: "39 migrações", state: "done" },
  { number: "02", label: "Conexão", caption: "Meta + OpenAI", state: "done" },
  { number: "03", label: "Contexto", caption: "tenant resolvido", state: "current" },
  { number: "04", label: "Primeira mensagem", caption: "canal a conectar", state: "next" },
  { number: "05", label: "Agenda real", caption: "Configuração ativa", state: "next" },
];

function StatusPill({ tone, children }: { tone: "olive" | "amber" | "ink"; children: React.ReactNode }) {
  const className = tone === "amber" ? `${styles.statusPill} ${styles.statusPillAmber}` : `${styles.statusPill} ${styles.statusPillOlive}`;
  return <span className={className}>{children}</span>;
}

function SectionHeading({ eyebrow, title, copy, id }: { eyebrow: string; title: string; copy: string; id?: string }) {
  return (
    <div className={styles.sectionHeading} id={id}>
      <span className={styles.eyebrow}>{eyebrow}</span>
      <h2>{title}</h2>
      <p>{copy}</p>
    </div>
  );
}

export default function DashboardPilotoWilliamPage() {
  const [activeNav, setActiveNav] = useState("overview");
  const [selectedComponent, setSelectedComponent] = useState<ComponentRecord | null>(null);
  const [mobileNavOpen, setMobileNavOpen] = useState(false);
  const [workspace, setWorkspace] = useState<TenantWorkspace | null>(null);
  const [workspaceError, setWorkspaceError] = useState<string | null>(null);
  const [workspaceLoading, setWorkspaceLoading] = useState(true);

  const inboxEvents: InboxEventRecord[] = [];
  const [statusInfo, setStatusInfo] = useState({
    databaseStatus: "Contexto do negócio em carregamento",
    allowlistCount: 0,
    statusText: "Aguardando contexto autenticado",
  });

  const completedComponents = components.filter((c) => c.tone === "olive").length;

  useEffect(() => {
    const controller = new AbortController();
    const requestedTenantId = new URLSearchParams(window.location.search).get("tenantId");
    const query = requestedTenantId ? `?tenantId=${encodeURIComponent(requestedTenantId)}` : "";

    fetch(`/api/dashboard-context${query}`, { signal: controller.signal })
      .then(async (response) => {
        const body = await response.json();
        if (!response.ok) {
          throw new Error(response.status === 401 ? "AUTHENTICATION_REQUIRED" : (body.error ?? "TENANT_CONTEXT_UNAVAILABLE"));
        }
        return body;
      })
      .then((body) => {
        const activeWorkspace = body.activeWorkspace as TenantWorkspace;
        setWorkspace(activeWorkspace);
        setStatusInfo({
          databaseStatus: `Tenant autorizado · ${activeWorkspace.timezone}`,
          allowlistCount: 0,
          statusText: `${activeWorkspace.status === "PUBLISHED" ? "Operação publicada" : "Configuração em rascunho"} · isolamento por tenant`,
        });
      })
      .catch((error: unknown) => {
        if (error instanceof DOMException && error.name === "AbortError") return;
        if (error instanceof Error && error.message === "AUTHENTICATION_REQUIRED") {
          window.location.assign("/login");
          return;
        }
        setWorkspaceError("Não foi possível resolver o negócio autorizado para esta sessão.");
      })
      .finally(() => setWorkspaceLoading(false));

    return () => controller.abort();
  }, []);

  if (workspaceLoading) {
    return (
      <main className={styles.accessState} aria-busy="true">
        <section className={styles.accessCard}>
          <span className={styles.accessEyebrow}>operação do negócio</span>
          <h1>Validando seu contexto.</h1>
          <p>Estamos confirmando o negócio autorizado para esta sessão antes de abrir os dados operacionais.</p>
        </section>
      </main>
    );
  }

  if (!workspace) {
    return (
      <main className={styles.accessState}>
        <section className={styles.accessCard}>
          <span className={styles.accessEyebrow}>operação indisponível</span>
          <h1>Não foi possível abrir este negócio.</h1>
          <p>{workspaceError ?? "Esta sessão não possui um negócio autorizado para a área operacional."}</p>
          <button className={styles.accessButton} onClick={() => window.location.assign("/")}>
            Voltar ao configurador
            <ArrowUpRight size={15} />
          </button>
        </section>
      </main>
    );
  }

  const handleNav = (target: string, href?: string) => {
    if (href) {
      window.location.assign(href);
      return;
    }
    setActiveNav(target);
    setMobileNavOpen(false);
    document.getElementById(target)?.scrollIntoView({ behavior: "smooth", block: "start" });
  };

  const handleSync = () => {
    toast.success("Contexto operacional atualizado.");
  };

  const tenantName = workspace?.tenantName ?? (workspaceLoading ? "Carregando negócio" : "Negócio não disponível");
  const unitName = workspace?.unitName ?? "Unidade não disponível";

  return (
    <div className={styles.appShell}>
      <aside className={`${styles.sidebar} ${mobileNavOpen ? styles.sidebarOpen : ""}`}>
        <div className={styles.sidebarTopline}>
          <div className={styles.brandLockup}>
            <div>
              <div className={styles.brandWordmark}>{tenantName.toUpperCase()}</div>
              <div className={styles.brandSubline}>OPERAÇÃO / 001</div>
            </div>
          </div>
          <button className={`${styles.iconButton} ${styles.mobileClose}`} aria-label="Fechar menu" onClick={() => setMobileNavOpen(false)}>
            <X size={18} />
          </button>
        </div>

        <div className={styles.sidebarContext}>
          <span className={styles.contextLabel}>TENANT</span>
          <span className={styles.contextValue}>{unitName}</span>
          <span className={styles.contextEnv}><CircleDot size={9} fill="currentColor" /> contexto autorizado</span>
        </div>

        <nav className={styles.sidebarNav} aria-label="Navegação principal">
          <span className={styles.navLabel}>CADERNO</span>
          {navItems.map((item) => {
            const Icon = item.icon;
            const active = activeNav === item.target;
            return (
              <button
                key={item.target}
                className={`${styles.navItem} ${active ? styles.navItemActive : ""}`}
                onClick={() => handleNav(item.target, item.href)}
                aria-current={active ? "page" : undefined}
              >
                <Icon size={17} strokeWidth={active ? 2.2 : 1.7} />
                <span>{item.label}</span>
                {active && <ChevronRight className={styles.navChevron} size={15} />}
              </button>
            );
          })}
        </nav>

        <div className={styles.sidebarRule} />
        <div className={styles.sidebarFooterNote}>
          <span className={styles.navLabel}>DADOS REAIS</span>
          <p>{workspaceError ?? "Dados separados por negócio e sessão autenticada."}</p>
          <div className={styles.miniSignal}><span /><span /><span /></div>
        </div>
        <div className={styles.sidebarFooter}>
          <button className={styles.sidebarFooterLink} onClick={handleSync}>
            <Activity size={15} /> Sincronizar dados
          </button>
          <span className={styles.versionStamp}>v0.2 / FULL</span>
        </div>
      </aside>

      {mobileNavOpen && <button className={styles.sidebarScrim} aria-label="Fechar navegação" onClick={() => setMobileNavOpen(false)} />}

      <main className={styles.mainCanvas}>
        <header className={styles.topbar}>
          <button className={`${styles.iconButton} ${styles.mobileMenu}`} aria-label="Abrir menu" onClick={() => setMobileNavOpen(true)}>
            <Menu size={20} />
          </button>
          <div className={styles.breadcrumb}><span>OPERAÇÃO</span><ChevronRight size={13} /><strong>VISÃO GERAL</strong></div>
          <div className={styles.topbarActions}>
            <div className={styles.liveIndicator}><span className={styles.liveDot} /> tenant autorizado</div>
            <button className={styles.iconButton} aria-label="Notificações" onClick={() => toast("Sem novas notificações")}><Bell size={17} /></button>
            <button className={styles.avatarButton} aria-label="Perfil de Duda">D</button>
          </div>
        </header>

        <div className={styles.contentWrap}>
          <section className={styles.introRow} id="overview">
            <div className={styles.introCopy}>
              <div className={styles.overline}><span className={styles.overlineLine} /> relatório de prontidão operacional</div>
              <div className={styles.dossierSignature}>
                <div><strong>{tenantName.toUpperCase()} / OPERAÇÃO</strong><span>caderno operacional · contexto autenticado</span></div>
              </div>
              <h1 className={styles.mainTitle}>O caminho está<br /><em>conectado.</em></h1>
              <p className={styles.introLede}>Acompanhe a inbox, os agendamentos, as confirmações e a configuração do seu próprio negócio — sem acesso a dados de outros tenants.</p>
              <div className={styles.introMeta}>
                <span><Clock3 size={14} /> status DB: {statusInfo.databaseStatus}</span>
                <span><GitBranch size={14} /> tenant: {workspace?.tenantSlug ?? "indisponível"}</span>
              </div>
              <div className={styles.proofRail}>
                <div><span>leitura de evidência</span><strong>{statusInfo.allowlistCount} número autorizado</strong></div>
                <div className={styles.proofPending}><span className={styles.proofDot} /><div><span>eventos capturados</span><strong>{inboxEvents.length} na inbox</strong></div></div>
              </div>
            </div>
            <div className={styles.heroFrame}>
              <img src={heroImage} alt="Interior do salão com estações de atendimento" />
              <div className={styles.heroFrameLabel}><span>01</span><span>base operacional</span></div>
              <div className={styles.heroStamp}>OP / 001</div>
              <div className={styles.heroProofTag}><span className={styles.liveDot} /> operação / tenant</div>
            </div>
          </section>

          <section className={styles.statusStrip} aria-label="Resumo do estado atual">
            <div className={styles.statusPrimary}>
              <div className={styles.statusIcon}><ScanLine size={21} /></div>
              <div><span className={styles.eyebrow}>estado atual</span><strong>{statusInfo.statusText}</strong></div>
            </div>
            <div className={styles.statusStat}><span className={styles.statLabel}>COMPONENTES</span><strong>{completedComponents}<small> / 4</small></strong></div>
            <div className={styles.statusStat}><span className={styles.statLabel}>EVENTOS INBOX</span><strong>{inboxEvents.length}</strong><span className={styles.statFoot}>app.inbox_events</span></div>
            <button className={styles.statusAction} onClick={() => handleNav("timeline")}>ver timeline <ArrowUpRight size={16} /></button>
          </section>

          <section className={styles.milestoneSection} aria-labelledby="milestones-title">
            <div className={styles.milestoneHead}>
              <div><span className={styles.eyebrow}>linha de avanço</span><h2 id="milestones-title">Cinco movimentos até a agenda</h2></div>
              <div className={styles.milestoneCounter}><strong>03</strong><span>marcos atravessados</span></div>
            </div>
            <div className={styles.milestoneTrack}>
              <div className={styles.trackLine} />
              {milestones.map((milestone) => {
                const stateClass = milestone.state === "done" ? styles.milestoneDone : milestone.state === "current" ? styles.milestoneCurrent : "";
                return (
                  <div className={`${styles.milestone} ${stateClass}`} key={milestone.number}>
                    <div className={styles.milestoneDot}>{milestone.state === "done" ? <Check size={13} /> : milestone.number}</div>
                    <span className={styles.milestoneNumber}>{milestone.number}</span>
                    <strong>{milestone.label}</strong>
                    <span>{milestone.caption}</span>
                  </div>
                );
              })}
            </div>
          </section>

          <div className={styles.sectionGrid} id="integrations">
            <section className={styles.componentsPanel}>
              <SectionHeading eyebrow="01 / integridade da base" title="O que já está de pé" copy="Base operacional estruturada para o seu negócio, com isolamento por tenant e evidências de ativação por módulo." />
              <div className={styles.componentList}>
                {components.map((component, index) => {
                  const Icon = component.icon;
                  const iconToneClass = component.tone === "amber" ? styles.componentIconAmber : styles.componentIconOlive;
                  return (
                    <button className={styles.componentRow} key={component.name} onClick={() => setSelectedComponent(component)}>
                      <span className={styles.componentIndex}>0{index + 1}</span>
                      <span className={`${styles.componentIcon} ${iconToneClass}`}><Icon size={17} /></span>
                      <span className={styles.componentCopy}><strong>{component.name}</strong><small>{component.detail}</small></span>
                      <StatusPill tone={component.tone}>{component.status}</StatusPill>
                      <ChevronRight className={styles.componentArrow} size={17} />
                    </button>
                  );
                })}
              </div>
            </section>

            <aside className={styles.evidenceCard} id="evidence">
              <div className={styles.evidenceImage}><img src={detailImage} alt="Detalhe de estação de trabalho do salão" /><span className={styles.imageCaption}>matéria / precisão / cuidado</span></div>
              <div className={styles.evidenceContent}>
                <div className={styles.evidenceTopline}><span className={styles.eyebrow}>próxima prova</span><span className={styles.evidenceIndex}>02 / 04</span></div>
                <h3>Uma mensagem.<br /><em>Um evento real.</em></h3>
                <p>Conecte o número WhatsApp do seu negócio para iniciar a ingestão segura das conversas na inbox operacional.</p>
                <button className={styles.inkButton} onClick={() => window.location.assign("/whatsapp")}>abrir conversas ao vivo <ArrowUpRight size={16} /></button>
              </div>
            </aside>
          </div>

          <section className={styles.timelineSection} id="timeline">
              <SectionHeading eyebrow="02 / timeline e eventos" title="Fluxo de entrada e IA" copy="Registro dos eventos recebidos pelo canal WhatsApp vinculado exclusivamente ao seu negócio." />
            <div className={styles.timelineContainer}>
              {inboxEvents.length > 0 ? (
                <div className={styles.eventsList}>
                  {inboxEvents.map((ev) => (
                    <div className={styles.eventCard} key={ev.id}>
                      <div className={styles.eventHead}>
                        <span className={styles.eventType}>{ev.eventType}</span>
                        <StatusPill tone={ev.status === 'PROCESSED' ? 'olive' : 'amber'}>{ev.status}</StatusPill>
                      </div>
                      <p className={styles.eventSender}>Remetente: <strong>{ev.senderContact}</strong></p>
                      <pre className={styles.eventPayload}>{JSON.stringify(ev.payload, null, 2)}</pre>
                      <span className={styles.eventTime}>{new Date(ev.receivedAt).toLocaleString()}</span>
                    </div>
                  ))}
                </div>
              ) : (
                <div className={styles.timelineEmptyBox}>
                  <Radio size={32} strokeWidth={1.5} />
                  <strong>Nenhum evento na inbox ainda</strong>
                  <p>Assim que o canal WhatsApp deste negócio estiver conectado, as novas conversas aparecerão aqui.</p>
                  <button className={styles.inkButton} onClick={() => toast("Verificação concluída", { description: "Webhook pronto para receber requisições da Meta Cloud API." })}>verificar agora</button>
                </div>
              )}
            </div>
          </section>

          <section className={styles.scheduleSection} id="schedule">
            <div className={styles.scheduleCopy}>
              <span className={styles.eyebrow}>03 / serviços e agenda</span>
              <h2>Catálogo de {tenantName}</h2>
              <p>O catálogo é configurado e persistido no configurador do negócio. A leitura operacional neste painel será conectada somente quando o contrato de agenda estiver disponível.</p>
              <a href="/" className={styles.inkButton}>abrir configurador <ArrowUpRight size={16} /></a>
            </div>

            <div className={styles.scheduleServicesBox}>
              <div className={styles.servicesHeader}>
                <strong>Sincronização do catálogo</strong>
                <span>não conectada</span>
              </div>
              <div className={styles.servicesList}>
                <div className={styles.servicesEmpty}>
                  <CalendarDays size={24} />
                  <span>Nenhum serviço é mostrado aqui até existir uma leitura autenticada do catálogo. Use o configurador para criar, editar ou inativar serviços.</span>
                </div>
              </div>
            </div>
          </section>

          <section className={styles.bottomGrid}>
            <div className={styles.quotePanel}>
              <img src={textureImage} alt="Textura editorial com linhas topográficas" />
              <div className={styles.quoteOverlay}>
                <Sparkles size={16} />
                <blockquote>“Configuração concluída não equivale a fluxo real testado.”</blockquote>
                <span>princípio de evidência / piloto 001</span>
              </div>
            </div>
            <div>
              <div className={styles.nextActionsHead}>
                <div><span className={styles.eyebrow}>caderno de campo</span><h2>Próximas decisões</h2></div>
                <MoreHorizontal size={18} />
              </div>
              <button className={styles.actionRow} onClick={() => toast("Decisão 01", { description: "Envie uma primeira mensagem ao número do bot para gerar o evento real." })}>
                <span className={styles.actionNumber}>01</span>
                <span><strong>Enviar a primeira mensagem</strong><small>Validar webhook e inbox_events</small></span>
                <ArrowUpRight size={16} />
              </button>
              <button className={styles.actionRow} onClick={() => handleNav("schedule")}>
                <span className={styles.actionNumber}>02</span>
                <span><strong>Gerenciar serviços da agenda</strong><small>Alimentar os dados do salão</small></span>
                <ArrowUpRight size={16} />
              </button>
              <button className={styles.actionRow} onClick={() => toast("Domínio eddigital.ia.br", { description: "Pronto para publicação via Vercel." })}>
                <span className={styles.actionNumber}>03</span>
                <span><strong>Vincular domínio eddigital.ia.br</strong><small>Publicar via painel de configurações</small></span>
                <ArrowUpRight size={16} />
              </button>
            </div>
          </section>

          <footer className={styles.pageFooter}>
            <span><Zap size={13} /> {tenantName} / operação autenticada</span>
            <span>domínio alvo: eddigital.ia.br</span>
            <span className={styles.footerSeal}>pronto para publicar</span>
          </footer>
        </div>
      </main>

      {selectedComponent && (
        <div className={styles.drawerBackdrop} onClick={() => setSelectedComponent(null)}>
          <aside className={styles.evidenceDrawer} onClick={(event) => event.stopPropagation()}>
            <div className={styles.drawerHead}>
              <div><span className={styles.eyebrow}>evidência do componente</span><h2>{selectedComponent.name}</h2></div>
              <button className={styles.iconButton} aria-label="Fechar evidência" onClick={() => setSelectedComponent(null)}><X size={18} /></button>
            </div>
            <div className={styles.drawerStatus}><StatusPill tone={selectedComponent.tone}>{selectedComponent.status}</StatusPill><span>{tenantName} / operação</span></div>
            <p className={styles.drawerDetail}>{selectedComponent.detail}</p>
            <div className={styles.drawerNote}><FileCheck2 size={17} /><p>{selectedComponent.evidence}</p></div>
            <div className={styles.drawerMeta}><span><Terminal size={14} /> fonte registrada no Supabase</span><span><Inbox size={14} /> persistência ativa</span></div>
            <button className={`${styles.inkButton} ${styles.drawerButton}`} onClick={() => setSelectedComponent(null)}>fechar</button>
          </aside>
        </div>
      )}
    </div>
  );
}
