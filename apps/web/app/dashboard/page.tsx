import styles from './dashboard.module.css';

export default function DashboardPilotoWilliamPage() {
  return (
    <div className={styles.root}>
      <div className={styles.container}>
        <header className={styles.header}>
          <div>
            <div className={styles.eyebrow}>Caderno de Operações • Piloto William</div>
            <h1 className={styles.heading}>Painel de Acompanhamento do Piloto</h1>
          </div>
          <div className={styles.headerStatus}>
            <span className={styles.statusBadge}>
              <span className={styles.statusDot} />
              Supabase DEV Conectado
            </span>
            <span className={`${styles.version} ${styles.mono}`}>v1.0.0-beta</span>
          </div>
        </header>

        <section className={styles.stats}>
          <div className={styles.statCard}>
            <span className={`${styles.statLabel} ${styles.mono}`}>Tenant Ativo</span>
            <h2 className={styles.statTitle}>Salão do William</h2>
            <p className={styles.statDescription}>ID: b6f65c60-5ed8-4e9a-a196-ab73b43213d4</p>
          </div>
          <div className={styles.statCard}>
            <span className={`${styles.statLabel} ${styles.mono}`}>Número de Teste Allowlist</span>
            <h2 className={`${styles.statTitle} ${styles.statTitleSuccess} ${styles.mono}`}>
              +55 16 99421-5487
            </h2>
            <p className={styles.statDescription}>Status: Ativo na Meta Cloud API</p>
          </div>
          <div className={styles.statCard}>
            <span className={`${styles.statLabel} ${styles.mono}`}>Migrações Supabase</span>
            <h2 className={styles.statTitle}>39 / 39 Aplicadas</h2>
            <p className={styles.statDescription}>Esquemas app, private e api operacionais</p>
          </div>
        </section>

        <section className={styles.actions}>
          <h3 className={styles.sectionHeading}>Próximas Ações do Piloto &amp; Evidências</h3>
          <div className={styles.actionList}>
            <div className={styles.actionItem}>
              <span className={styles.actionIndex}>01</span>
              <div className={styles.actionCopy}>
                <strong className={styles.actionTitle}>Envio de Mensagem de Teste</strong>
                <p>
                  Envie uma mensagem via WhatsApp a partir do número +55 16 99421-5487 para o
                  número do bot cadastrado no Meta Developer Portal para disparar o webhook.
                </p>
              </div>
            </div>
            <div className={styles.actionItem}>
              <span className={styles.actionIndex}>02</span>
              <div className={styles.actionCopy}>
                <strong className={styles.actionTitle}>Verificação de Inbox Events</strong>
                <p>
                  Confirme a ingestão da mensagem na tabela{' '}
                  <code className={styles.code}>app.inbox_events</code> do Supabase DEV.
                </p>
              </div>
            </div>
            <div className={styles.actionItem}>
              <span className={styles.actionIndex}>03</span>
              <div className={styles.actionCopy}>
                <strong className={styles.actionTitle}>Motor de Agendamento</strong>
                <p>Validar a interpretação de intenção de agendamento pela IA nas Edge Functions.</p>
              </div>
            </div>
          </div>
        </section>

        <footer className={styles.footer}>
          Beauty AI Agent SaaS • Desenvolvido para Duda e William • Hospedagem Vercel &amp; Supabase
        </footer>
      </div>
    </div>
  );
}
