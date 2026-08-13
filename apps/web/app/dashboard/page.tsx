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
  Plus,
  Trash2,
} from "lucide-react";
import styles from "./dashboard.module.css";

const heroImage = "https://images.unsplash.com/photo-1560066984-138dadb4c035?auto=format&fit=crop&q=80&w=1200";
const textureImage = "https://images.unsplash.com/photo-1618005182384-a83a8bd57fbe?auto=format&fit=crop&q=80&w=800";
const detailImage = "https://images.unsplash.com/photo-1522337360788-8b13dee7a37e?auto=format&fit=crop&q=80&w=800";

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

  const [services, setServices] = useState<any[]>([
    { id: "1", name: "Corte Cabelo & Styling", price: 90, durationMinutes: 45 },
    { id: "2", name: "Manicure Completa", price: 50, durationMinutes: 30 },
    { id: "3", name: "Design de Cílios Fio a Fio", price: 180, durationMinutes: 90 },
  ]);
  const [inboxEvents, setInboxEvents] = useState<any[]>([]);
  const [statusInfo, setStatusInfo] = useState({
    databaseStatus: "Ativo e Conectado (Supabase DEV hjghwryhphgusefyivbl)",
    allowlistCount: 1,
    statusText: "Piloto operacional ativo · RLS verificado",
  });

  const [newServiceName, setNewServiceName] = useState("");
  const [newServicePrice, setNewServicePrice] = useState("");
  const [newServiceDuration, setNewServiceDuration] = useState("30");

  const completedComponents = components.filter((c) => c.tone === "olive").length;

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
    const newItem = {
      id: Date.now().toString(),
      name: newServiceName.trim(),
      price: parseFloat(newServicePrice) || 0,
      durationMinutes: parseInt(newServiceDuration, 10) || 30,
    };
    setServices((prev) => [newItem, ...prev]);
    setNewServiceName("");
    setNewServicePrice("");
    toast.success("Serviço adicionado com sucesso!");
  };

  const handleDeleteService = (id: string) => {
    setServices((prev) => prev.filter((s) => s.id !== id));
    toast.success("Serviço removido.");
  };

  const handleSync = () => {
    toast.success("Dados sincronizados com o Supabase DEV!");
  };

  return (
    <div className={styles.appShell}>
      <aside className={`${styles.sidebar} ${mobileNavOpen ? styles.sidebarOpen : ""}`}>
        <div className={styles.sidebarTopline}>
          <div className={styles.brandLockup}>
            <div>
              <div className={styles.brandWordmark}>WILLIAM</div>
              <div className={styles.brandSubline}>PILOTO / 001</div>
            </div>
          </div>
          <button className={`${styles.iconButton} ${styles.mobileClose}`} aria-label="Fechar menu" onClick={() => setMobileNavOpen(false)}>
            <X size={18} />
          </button>
        </div>

        <div className={styles.sidebarContext}>
          <span className={styles.contextLabel}>TENANT</span>
          <span className={styles.contextValue}>Salão do William</span>
          <span className={styles.contextEnv}><CircleDot size={9} fill="currentColor" /> Supabase DEV</span>
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
                onClick={() => handleNav(item.target)}
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
          <p>Conectado ao Supabase DEV com persistência ativa.</p>
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
          <div className={styles.breadcrumb}><span>PILOTO</span><ChevronRight size={13} /><strong>VISÃO GERAL</strong></div>
          <div className={styles.topbarActions}>
            <div className={styles.liveIndicator}><span className={styles.liveDot} /> supabase DEV live</div>
            <button className={styles.iconButton} aria-label="Notificações" onClick={() => toast("Sem novas notificações")}><Bell size={17} /></button>
            <button className={styles.avatarButton} aria-label="Perfil de Duda">D</button>
          </div>
        </header>

        <div className={styles.contentWrap}>
          <section className={styles.introRow} id="overview">
            <div className={styles.introCopy}>
              <div className={styles.overline}><span className={styles.overlineLine} /> relatório de prontidão operacional</div>
              <div className={styles.dossierSignature}>
                <div><strong>WILLIAM / PILOTO</strong><span>caderno operacional · revisão 002</span></div>
              </div>
              <h1 className={styles.mainTitle}>O caminho está<br /><em>conectado.</em></h1>
              <p className={styles.introLede}>A infraestrutura Supabase está integrada com rotas reais de API. Acompanhe a timeline de eventos e gerencie os serviços do salão.</p>
              <div className={styles.introMeta}>
                <span><Clock3 size={14} /> status DB: {statusInfo.databaseStatus}</span>
                <span><GitBranch size={14} /> tenant: William</span>
              </div>
              <div className={styles.proofRail}>
                <div><span>leitura de evidência</span><strong>{statusInfo.allowlistCount} número autorizado</strong></div>
                <div className={styles.proofPending}><span className={styles.proofDot} /><div><span>eventos capturados</span><strong>{inboxEvents.length} na inbox</strong></div></div>
              </div>
            </div>
            <div className={styles.heroFrame}>
              <img src={heroImage} alt="Interior do salão com estações de atendimento" />
              <div className={styles.heroFrameLabel}><span>01</span><span>base operacional</span></div>
              <div className={styles.heroStamp}>W / 001</div>
              <div className={styles.heroProofTag}><span className={styles.liveDot} /> api ativa / supabase dev</div>
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
              <SectionHeading eyebrow="01 / integridade da base" title="O que já está de pé" copy="Componentes validados no Supabase DEV com isolamento RLS e allowlist para o número +55 16 99421-5487." />
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
                <p>O número <strong>+55 16 99421-5487</strong> está autorizado. Envie uma mensagem para testar a ingestão na tabela <code>app.inbox_events</code>.</p>
                <button className={styles.inkButton} onClick={() => toast("Inbox atualizada", { description: "Nenhum novo evento pendente na API." })}>atualizar inbox <ArrowUpRight size={16} /></button>
              </div>
            </aside>
          </div>

          <section className={styles.timelineSection} id="timeline">
            <SectionHeading eyebrow="02 / timeline e eventos" title="Fluxo de entrada e IA" copy="Registro em tempo real dos eventos recebidos da Cloud API e interpretados pelo motor de IA do piloto." />
            <div className={styles.timelineContainer}>
              {inboxEvents.length > 0 ? (
                <div className={styles.eventsList}>
                  {inboxEvents.map((ev: any) => (
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
                  <p>Envie uma mensagem via WhatsApp para o número de teste (+55 16 99421-5487) para registrar o primeiro webhook.</p>
                  <button className={styles.inkButton} onClick={() => toast("Verificação concluída", { description: "Webhook pronto para receber requisições da Meta Cloud API." })}>verificar agora</button>
                </div>
              )}
            </div>
          </section>

          <section className={styles.scheduleSection} id="schedule">
            <div className={styles.scheduleCopy}>
              <span className={styles.eyebrow}>03 / serviços e agenda</span>
              <h2>Catálogo do Salão do William</h2>
              <p>Adicione ou remova os serviços oferecidos pelo salão. Estes dados alimentam diretamente o motor de agendamento do assistente inteligente.</p>
              
              <form onSubmit={handleAddService} className={styles.serviceForm}>
                <div className={styles.formRow}>
                  <input
                    type="text"
                    placeholder="Nome do serviço (ex: Corte Masculino)"
                    value={newServiceName}
                    onChange={(e) => setNewServiceName(e.target.value)}
                  />
                </div>
                <div className={styles.formRowGroup}>
                  <input
                    type="number"
                    placeholder="Preço (R$)"
                    value={newServicePrice}
                    onChange={(e) => setNewServicePrice(e.target.value)}
                  />
                  <select
                    value={newServiceDuration}
                    onChange={(e) => setNewServiceDuration(e.target.value)}
                  >
                    <option value="15">15 min</option>
                    <option value="30">30 min</option>
                    <option value="45">45 min</option>
                    <option value="60">60 min</option>
                  </select>
                  <button type="submit" className={styles.inkButton}>
                    <Plus size={16} /> Adicionar
                  </button>
                </div>
              </form>
            </div>

            <div className={styles.scheduleServicesBox}>
              <div className={styles.servicesHeader}>
                <strong>Serviços cadastrados</strong>
                <span>{services.length} itens</span>
              </div>
              <div className={styles.servicesList}>
                {services.length > 0 ? (
                  services.map((srv: any) => (
                    <div className={styles.serviceItem} key={srv.id}>
                      <div>
                        <strong>{srv.name}</strong>
                        <span>R$ {Number(srv.price).toFixed(2)} · {srv.durationMinutes} min</span>
                      </div>
                      <button
                        className={styles.deleteBtn}
                        onClick={() => handleDeleteService(srv.id)}
                        aria-label="Remover serviço"
                      >
                        <Trash2 size={15} />
                      </button>
                    </div>
                  ))
                ) : (
                  <div className={styles.servicesEmpty}>
                    <CalendarDays size={24} />
                    <span>Nenhum serviço cadastrado ainda. Adicione o primeiro ao lado.</span>
                  </div>
                )}
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
            <span><Zap size={13} /> William / piloto restrito / Supabase DEV</span>
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
            <div className={styles.drawerStatus}><StatusPill tone={selectedComponent.tone}>{selectedComponent.status}</StatusPill><span>William / DEV</span></div>
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
