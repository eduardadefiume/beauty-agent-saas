export default function DashboardPilotoWilliamPage() {
  return (
    <div className="min-h-screen bg-[#FBF9F5] text-[#2C2A29] font-sans antialiased p-6 md:p-12">
      <div className="max-w-6xl mx-auto space-y-8">
        <header className="border-b border-[#E6E2D8] pb-6 flex flex-col md:flex-row md:items-center md:justify-between gap-4">
          <div>
            <div className="text-xs uppercase tracking-widest text-[#78716C] font-mono mb-1">Caderno de Operações • Piloto William</div>
            <h1 className="text-3xl font-serif font-bold text-[#1C1A19]">Painel de Acompanhamento do Piloto</h1>
          </div>
          <div className="flex items-center gap-3">
            <span className="inline-flex items-center gap-1.5 px-3 py-1 rounded-full text-xs font-medium bg-[#E3EFE1] text-[#275020] border border-[#C6E2C1]">
              <span className="w-2 h-2 rounded-full bg-[#3B7A32] animate-pulse"></span>
              Supabase DEV Conectado
            </span>
            <span className="px-3 py-1 rounded-full text-xs font-mono bg-[#EFECE6] text-[#57534E]">v1.0.0-beta</span>
          </div>
        </header>

        <section className="grid grid-cols-1 md:grid-cols-3 gap-6">
          <div className="bg-white p-6 rounded-xl border border-[#E6E2D8] shadow-sm space-y-2">
            <span className="text-xs font-mono text-[#78716C]">Tenant Ativo</span>
            <h2 className="text-xl font-bold text-[#1C1A19]">Salão do William</h2>
            <p className="text-sm text-[#57534E]">ID: b6f65c60-5ed8-4e9a-a196-ab73b43213d4</p>
          </div>
          <div className="bg-white p-6 rounded-xl border border-[#E6E2D8] shadow-sm space-y-2">
            <span className="text-xs font-mono text-[#78716C]">Número de Teste Allowlist</span>
            <h2 className="text-xl font-bold text-[#275020] font-mono">+55 16 99421-5487</h2>
            <p className="text-sm text-[#57534E]">Status: Ativo na Meta Cloud API</p>
          </div>
          <div className="bg-white p-6 rounded-xl border border-[#E6E2D8] shadow-sm space-y-2">
            <span className="text-xs font-mono text-[#78716C]">Migrações Supabase</span>
            <h2 className="text-xl font-bold text-[#1C1A19]">39 / 39 Aplicadas</h2>
            <p className="text-sm text-[#57534E]">Esquemas app, private e api operacionais</p>
          </div>
        </section>

        <section className="bg-white p-8 rounded-xl border border-[#E6E2D8] shadow-sm space-y-6">
          <h3 className="text-xl font-serif font-bold text-[#1C1A19]">Próximas Ações do Piloto & Evidências</h3>
          <div className="space-y-4 text-sm text-[#57534E]">
            <div className="p-4 rounded-lg bg-[#FAF8F5] border border-[#EFECE6] flex items-start gap-3">
              <span className="font-mono font-bold text-[#1C1A19]">01</span>
              <div>
                <strong className="text-[#1C1A19]">Envio de Mensagem de Teste</strong>
                <p>Envie uma mensagem via WhatsApp a partir do número +55 16 99421-5487 para o número do bot cadastrado no Meta Developer Portal para disparar o webhook.</p>
              </div>
            </div>
            <div className="p-4 rounded-lg bg-[#FAF8F5] border border-[#EFECE6] flex items-start gap-3">
              <span className="font-mono font-bold text-[#1C1A19]">02</span>
              <div>
                <strong className="text-[#1C1A19]">Verificação de Inbox Events</strong>
                <p>Confirme a ingestão da mensagem na tabela <code className="bg-[#EFECE6] px-1.5 py-0.5 rounded text-xs">app.inbox_events</code> do Supabase DEV.</p>
              </div>
            </div>
            <div className="p-4 rounded-lg bg-[#FAF8F5] border border-[#EFECE6] flex items-start gap-3">
              <span className="font-mono font-bold text-[#1C1A19]">03</span>
              <div>
                <strong className="text-[#1C1A19]">Motor de Agendamento</strong>
                <p>Validar a interpretação de intenção de agendamento pela IA nas Edge Functions.</p>
              </div>
            </div>
          </div>
        </section>

        <footer className="text-center text-xs text-[#78716C] pt-6 border-t border-[#E6E2D8]">
          Beauty AI Agent SaaS • Desenvolvido para Duda e William • Hospedagem Vercel & Supabase
        </footer>
      </div>
    </div>
  );
}
