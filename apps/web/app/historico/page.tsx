'use client';

// Tela de Histórico: o arquivo das conversas do WhatsApp do dono.
//
// O QUE ELA É. Um backup consultável. O dono exporta as conversas dele do
// WhatsApp e sobe aqui; o sistema lê, guarda mensagem por mensagem, e amarra
// cada conversa à cliente do CRM. Depois disso ninguém precisa reimportar nada
// para consultar o que foi dito.
//
// A AMARRA COM A CLIENTE NÃO É ENFEITE. É ela que faz o pedido de exclusão
// alcançar o histórico: quando a cliente pede para apagar os dados dela, o
// pedido tem que chegar até aqui. Conversa sem amarra aparece marcada na tela
// justamente para alguém amarrar na mão -- é o que impede guardar dado que
// ninguém consegue apagar depois.
//
// QUEM É O DONO DENTRO DO ARQUIVO. O WhatsApp não marca "eu" e "ela": marca o
// NOME de quem escreveu. Em conversa equilibrada a contagem empata, e aí o
// leitor não chuta. O dono responde uma vez como o nome dele aparece, e vale
// para todos os arquivos.

import { useCallback, useEffect, useRef, useState } from 'react';
import { BackupIlegivel } from '../../lib/whatsapp-backup/crypt15';
import { type EstadoDaImportacao, importarBackup } from '../../lib/whatsapp-backup/importar';
import styles from './historico.module.css';

type Conversa = {
  id: string;
  nome: string;
  telefone: string | null;
  arquivo: string;
  status: 'PENDENTE' | 'LENDO' | 'PRONTO' | 'FALHOU';
  mensagens: number;
  comMidia: number;
  de: string | null;
  ate: string | null;
  erro: string | null;
  contactId: string | null;
  clienteNoCrm: string | null;
  origem: 'EXPORT_TXT' | 'COEXISTENCE' | 'BACKUP_CRYPT15';
};

type Resumo = {
  conversas: number;
  prontas: number;
  naFila: number;
  falhas: number;
  semAmarra: number;
  daMeta: number;
  mensagens: number;
};

// O andamento da importação pela Meta. As três fases chegam em pedaços, fora de
// ordem, ao longo de horas — sem isso na tela o dono clica em importar, não vê
// nada e conclui que não funcionou, justamente enquanto está funcionando.
type Coexistencia = {
  entregas: number;
  mensagensLidas: number;
  contatosLidos: number;
  fase: number | null;
  progresso: number | null;
  ultimaEm: string | null;
  guardadasSemLer: number;
  ultimoErro: string | null;
} | null;

type Autorizacao = {
  autorizadoPor: string;
  quando: string;
  base: string;
  nota: string | null;
} | null;

type Estado = {
  autorizacao: Autorizacao;
  resumo: Resumo;
  coexistencia: Coexistencia;
  conversas: Conversa[];
};

type Fala = {
  position: number;
  quem: 'DONO' | 'CLIENTE' | 'SISTEMA';
  autor: string | null;
  texto: string | null;
  quando: string | null;
  midia: string | null;
};

type Workspace = { tenantId: string; tenantName: string; timezone: string };

const ROTULO: Record<Conversa['status'], string> = {
  PENDENTE: 'na fila',
  LENDO: 'lendo agora',
  PRONTO: 'no arquivo',
  FALHOU: 'não deu',
};

function dia(iso: string | null): string {
  if (!iso) return '—';
  return new Date(iso).toLocaleDateString('pt-BR');
}

// O nome do contato como o WhatsApp escreve no arquivo exportado.
// "Conversa do WhatsApp com Andreia.txt" -> "Andreia".
export function nomeNoArquivo(filename: string): string {
  const semExtensao = filename.replace(/\.txt$/i, '');
  const m = /(?:conversa(?:\s+do\s+whatsapp)?\s+com\s+|whatsapp\s+chat\s+with\s+)(.+)$/i.exec(
    semExtensao
  );
  return (m?.[1] ?? semExtensao).trim();
}

export default function TelaDeHistorico() {
  const [workspace, setWorkspace] = useState<Workspace | null>(null);
  const [estado, setEstado] = useState<Estado | null>(null);
  const [carregando, setCarregando] = useState(true);
  const [erro, setErro] = useState<string | null>(null);
  const [aviso, setAviso] = useState<string | null>(null);
  const [subindo, setSubindo] = useState(false);
  const [nomeDoDono, setNomeDoDono] = useState('');
  const [aberta, setAberta] = useState<string | null>(null);
  const [falas, setFalas] = useState<Fala[]>([]);
  const tenantRef = useRef<string | null>(null);
  // A chave de 64 dígitos do dono. Ela existe só neste estado, enquanto a
  // aba está aberta: não vai para o servidor, não vai para o localStorage, e
  // some quando ele fecha a página.
  const [chaveDoBackup, setChaveDoBackup] = useState('');
  const [backup, setBackup] = useState<File | null>(null);
  const [importacao, setImportacao] = useState<EstadoDaImportacao | null>(null);

  useEffect(() => {
    const controller = new AbortController();
    const pedido = new URLSearchParams(window.location.search).get('tenantId');
    fetch(`/api/dashboard-context${pedido ? `?tenantId=${encodeURIComponent(pedido)}` : ''}`, {
      signal: controller.signal,
    })
      .then(async (r) => {
        const body = await r.json();
        if (!r.ok) throw new Error(r.status === 401 ? 'AUTH' : (body.error ?? 'CONTEXTO'));
        return body;
      })
      .then((body) => {
        const w = body.activeWorkspace as Workspace;
        tenantRef.current = w.tenantId;
        setWorkspace(w);
      })
      .catch((e: unknown) => {
        if (e instanceof DOMException && e.name === 'AbortError') return;
        if (e instanceof Error && e.message === 'AUTH') {
          window.location.assign('/login');
          return;
        }
        setErro('Não foi possível resolver o negócio desta sessão.');
        setCarregando(false);
      });
    return () => controller.abort();
  }, []);

  const chamar = useCallback(async (corpo: Record<string, unknown>) => {
    const tenantId = tenantRef.current;
    if (!tenantId) throw new Error('SEM_TENANT');
    const r = await fetch('/api/historico', {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ ...corpo, tenantId }),
    });
    const body = await r.json();
    if (!r.ok) throw new Error(String(body.error ?? 'FALHA'));
    return body.data as Record<string, unknown>;
  }, []);

  const buscar = useCallback(async () => {
    try {
      setEstado((await chamar({ action: 'waArchives' })) as unknown as Estado);
      setErro(null);
    } catch {
      setErro('Não foi possível carregar o arquivo de conversas.');
    } finally {
      setCarregando(false);
    }
  }, [chamar]);

  useEffect(() => {
    if (!workspace) return;
    void buscar();
  }, [workspace, buscar]);

  // Enquanto houver arquivo na fila, a tela volta a olhar: a leitura acontece
  // por fora, de cinco em cinco minutos, e ficar apertando F5 não é resposta.
  useEffect(() => {
    const chegando =
      estado != null &&
      (estado.resumo.naFila > 0 ||
        (estado.coexistencia != null &&
          estado.coexistencia.entregas > 0 &&
          (estado.coexistencia.fase ?? 0) < 2));
    if (!chegando) return;
    const t = setInterval(() => void buscar(), 20000);
    return () => clearInterval(t);
  }, [estado, buscar]);

  async function subir(arquivos: FileList) {
    const tenantId = tenantRef.current;
    if (!tenantId) return;
    setSubindo(true);
    setErro(null);
    setAviso(null);
    let enviados = 0;

    try {
      for (const arquivo of Array.from(arquivos)) {
        const formulario = new FormData();
        formulario.set('tenantId', tenantId);
        formulario.set('file', arquivo);
        const r = await fetch('/api/historico/arquivo', { method: 'POST', body: formulario });
        const body = await r.json();
        if (!r.ok) {
          throw new Error(
            body.error === 'UNSUPPORTED_MEDIA_TYPE'
              ? `"${arquivo.name}" não é um .txt de conversa exportada.`
              : body.error === 'FILE_TOO_LARGE'
                ? `"${arquivo.name}" passa de 64 MB.`
                : `Não consegui subir "${arquivo.name}".`
          );
        }
        const caminho = (body.data as { storagePath: string }).storagePath;
        const registro = (await chamar({
          action: 'waArchiveAdd',
          storagePath: caminho,
          filename: arquivo.name,
          contactLabel: nomeNoArquivo(arquivo.name),
        })) as { ok?: boolean; reason?: string };
        if (!registro?.ok) throw new Error(registro?.reason ?? 'REGISTRO_RECUSADO');
        enviados += 1;
      }
      setAviso(
        `${enviados} ${enviados === 1 ? 'conversa entrou' : 'conversas entraram'} na fila. A leitura acontece por fora e a tela se atualiza sozinha.`
      );
      await buscar();
    } catch (e: unknown) {
      setErro(e instanceof Error ? e.message : 'Não consegui subir os arquivos.');
    } finally {
      setSubindo(false);
    }
  }

  async function abrirOBackup() {
    const arquivo = backup;
    if (!arquivo) return;
    setErro(null);
    setAviso(null);
    setImportacao({ passo: 'ABRINDO', andamento: null, conversas: 0, mensagens: 0 });

    try {
      const bytes = new Uint8Array(await arquivo.arrayBuffer());
      const fim = await importarBackup(
        bytes,
        chaveDoBackup,
        async (lote) => {
          const r = (await chamar({ action: 'waBackupAbsorb', conversas: lote })) as {
            ok?: boolean;
            reason?: string;
          };
          if (!r?.ok) throw new Error(r?.reason ?? 'LOTE_RECUSADO');
        },
        setImportacao
      );
      setAviso(
        `${fim.conversas} ${fim.conversas === 1 ? 'conversa' : 'conversas'} e ${fim.mensagens} mensagens vieram do backup do aparelho.`
      );
      // A chave sai da memória assim que deixa de ser necessária.
      setChaveDoBackup('');
      setBackup(null);
      await buscar();
    } catch (e: unknown) {
      setErro(
        e instanceof BackupIlegivel
          ? e.message
          : e instanceof Error
            ? e.message
            : 'Não consegui abrir o backup.'
      );
    } finally {
      setImportacao(null);
    }
  }

  async function gravarNomeDoDono() {
    const nome = nomeDoDono.trim();
    if (nome.length === 0) return;
    try {
      const r = (await chamar({ action: 'waSetOwnerLabel', ownerLabel: nome })) as {
        arquivosParaReler?: number;
      };
      setAviso(
        (r?.arquivosParaReler ?? 0) > 0
          ? `Nome gravado. ${r.arquivosParaReler} ${r.arquivosParaReler === 1 ? 'conversa vai ser relida' : 'conversas vão ser relidas'} para marcar quem é quem.`
          : 'Nome gravado. As próximas conversas já entram com a marca certa.'
      );
      setNomeDoDono('');
      await buscar();
    } catch {
      setErro('Não consegui gravar o nome.');
    }
  }

  async function abrir(id: string) {
    if (aberta === id) {
      setAberta(null);
      setFalas([]);
      return;
    }
    try {
      const r = (await chamar({ action: 'waArchiveRead', archiveId: id, limit: 200 })) as {
        mensagens?: Fala[];
      };
      setFalas(r?.mensagens ?? []);
      setAberta(id);
    } catch {
      setErro('Não consegui abrir essa conversa.');
    }
  }

  async function esquecer(conversa: Conversa) {
    if (!conversa.contactId) return;
    if (
      !window.confirm(
        `Apagar TODO o histórico importado de ${conversa.clienteNoCrm ?? conversa.nome}? ` +
          'É o que se faz quando a cliente pede para apagar os dados dela. Não tem volta.'
      )
    ) {
      return;
    }
    try {
      const r = (await chamar({
        action: 'forgetContactHistory',
        contactId: conversa.contactId,
      })) as { arquivosApagados?: number };
      setAviso(`Apagado: ${r?.arquivosApagados ?? 0} conversa(s) desta cliente saíram do arquivo.`);
      setAberta(null);
      await buscar();
    } catch {
      setErro('Não consegui apagar. Nada foi alterado.');
    }
  }

  if (carregando) {
    return (
      <main className={styles.estado} aria-busy="true">
        <section className={styles.estadoCard}>
          <span className={styles.eyebrow}>histórico</span>
          <h1>Abrindo o arquivo.</h1>
        </section>
      </main>
    );
  }

  const resumo = estado?.resumo;
  const autorizacao = estado?.autorizacao ?? null;
  const coexistencia = estado?.coexistencia ?? null;

  return (
    <main className={styles.shell}>
      <header className={styles.topo}>
        <div>
          <a className={styles.voltar} href="/dashboard">
            ← Voltar à operação
          </a>
          <span className={styles.eyebrow}>histórico · {workspace?.tenantName ?? ''}</span>
          <h1>O que já foi conversado no WhatsApp</h1>
        </div>
      </header>

      {erro && <p className={styles.aviso}>{erro}</p>}
      {aviso && <p className={styles.recado}>{aviso}</p>}

      {!autorizacao && (
        <p className={styles.aviso}>
          Não há autorização registrada para trazer o histórico deste negócio. Sem ela o sistema
          recusa qualquer arquivo, e isso é de propósito.
        </p>
      )}

      {autorizacao && (
        <p className={styles.explicacao}>
          Autorizado por <strong>{autorizacao.autorizadoPor}</strong> em {dia(autorizacao.quando)}.
          O salão é o controlador deste histórico — ele já detinha essas conversas no aparelho dele.
          A cliente continua podendo pedir a exclusão do que é dela, e o pedido alcança este
          arquivo: é para isso que serve o botão de apagar em cada conversa.
        </p>
      )}

      {resumo && (
        <section className={styles.contadores}>
          {[
            ['conversas', resumo.conversas],
            ['no arquivo', resumo.prontas],
            ['na fila', resumo.naFila],
            ['mensagens', resumo.mensagens],
            ['sem cliente amarrada', resumo.semAmarra],
            ['vindas da Meta', resumo.daMeta],
          ].map(([rotulo, valor]) => (
            <div key={String(rotulo)} className={styles.contador}>
              <strong>{String(valor)}</strong>
              <span>{rotulo}</span>
            </div>
          ))}
        </section>
      )}

      {coexistencia && coexistencia.entregas > 0 && (
        <section className={styles.bloco}>
          <h2>O histórico está chegando pela Meta</h2>
          <p className={styles.nota}>
            {coexistencia.fase == null
              ? 'A Meta já mandou a agenda de contatos. As conversas vêm em seguida.'
              : `Fase ${coexistencia.fase} de 2${
                  coexistencia.progresso == null ? '' : ` · ${coexistencia.progresso}%`
                }. A fase 0 é o dia de hoje, a 1 vai até 90 dias, a 2 até 180. Elas chegam em pedaços e fora de ordem — a ordem certa aparece na conversa, não aqui.`}
          </p>
          <p className={styles.nota}>
            {coexistencia.entregas} entrega{coexistencia.entregas === 1 ? '' : 's'} recebida
            {coexistencia.entregas === 1 ? '' : 's'} · {coexistencia.mensagensLidas} mensagens ·{' '}
            {coexistencia.contatosLidos} contatos com nome
            {coexistencia.ultimaEm ? ` · última em ${dia(coexistencia.ultimaEm)}` : ''}
          </p>
          {coexistencia.ultimoErro && (
            <p className={styles.aviso}>
              Uma entrega chegou e não foi entendida: {coexistencia.ultimoErro}. Ela ficou guardada
              inteira, do jeito que veio — nada foi perdido, e dá para reler depois de corrigir a
              leitura.
            </p>
          )}
        </section>
      )}

      <section className={styles.bloco}>
        <h2>O que veio antes: o backup do aparelho</h2>
        <p className={styles.nota}>
          A Meta entrega os últimos 180 dias. O que é mais antigo que isso, e os grupos, só existem
          no backup que o WhatsApp grava no celular:{' '}
          <code>Android/media/com.whatsapp/WhatsApp/Databases/msgstore.db.crypt15</code>. Copie esse
          arquivo para o computador e escolha ele aqui.
        </p>
        <p className={styles.nota}>
          A chave de 64 dígitos está em{' '}
          <strong>Ajustes › Conversas › Backup › Backup criptografado</strong>, no celular.{' '}
          <strong>Ela não sai deste computador.</strong> O arquivo é aberto aqui no navegador e só
          as mensagens já lidas viajam — a chave abre qualquer backup do WhatsApp deste número, e
          por isso ela não tem por que existir do lado do sistema.
        </p>

        <div className={styles.linhaDeCampo}>
          <input
            type="file"
            accept=".crypt15"
            disabled={importacao != null || !autorizacao}
            onChange={(e) => setBackup(e.target.files?.[0] ?? null)}
          />
        </div>
        <div className={styles.linhaDeCampo}>
          <input
            type="password"
            placeholder="a chave de 64 dígitos"
            autoComplete="off"
            spellCheck={false}
            value={chaveDoBackup}
            disabled={importacao != null}
            onChange={(e) => setChaveDoBackup(e.target.value)}
          />
          <button
            className={styles.principal}
            disabled={importacao != null || !backup || !autorizacao}
            onClick={() => void abrirOBackup()}
          >
            {importacao ? 'Abrindo…' : 'Importar o backup'}
          </button>
        </div>

        {importacao && (
          <p className={styles.nota}>
            {importacao.passo === 'ABRINDO' && 'Abrindo o arquivo com a sua chave…'}
            {importacao.passo === 'LENDO' && 'Lendo as conversas do banco do WhatsApp…'}
            {importacao.passo === 'MANDANDO' &&
              `Mandando: ${importacao.andamento?.mensagensEnviadas ?? 0} de ${importacao.andamento?.totalDeMensagens ?? 0} mensagens.`}
          </p>
        )}
      </section>

      <section className={styles.bloco}>
        <h2>Como o seu nome aparece nas conversas</h2>
        <p className={styles.nota}>
          O WhatsApp não marca “eu” e “ela”: marca o nome de quem escreveu. Em conversa equilibrada
          a contagem empata e o sistema não chuta — fica tudo como cliente. Responda uma vez e vale
          para todos os arquivos.
        </p>
        <div className={styles.linhaDeCampo}>
          <input
            value={nomeDoDono}
            placeholder="ex.: William"
            onChange={(e) => setNomeDoDono(e.target.value)}
          />
          <button
            className={styles.principal}
            disabled={nomeDoDono.trim().length === 0}
            onClick={() => void gravarNomeDoDono()}
          >
            Gravar
          </button>
        </div>
      </section>

      <section className={styles.bloco}>
        <h2>Mandar conversas</h2>
        <p className={styles.nota}>
          No WhatsApp: abra a conversa → menu → <strong>Exportar conversa</strong> →{' '}
          <strong>Sem mídia</strong>. Dá um arquivo .txt. Pode mandar vários de uma vez. Com mídia o
          WhatsApp gera um .zip, e por enquanto ele não entra — as fotos ficam registradas pelo nome
          e a imagem em si é o próximo passo.
        </p>
        <label className={`${styles.ghost} ${subindo ? styles.ocupado : ''}`}>
          {subindo ? 'Subindo…' : 'Escolher arquivos .txt'}
          <input
            type="file"
            accept=".txt,text/plain"
            multiple
            hidden
            disabled={subindo || !autorizacao}
            onChange={(e) => {
              const arquivos = e.target.files;
              e.target.value = '';
              if (arquivos && arquivos.length > 0) void subir(arquivos);
            }}
          />
        </label>
      </section>

      {(estado?.conversas ?? []).length === 0 ? (
        <p className={styles.vazio}>Nenhuma conversa no arquivo ainda.</p>
      ) : (
        <section className={styles.bloco}>
          <h2>No arquivo</h2>
          {(estado?.conversas ?? []).map((c) => (
            <div key={c.id} className={styles.conversa}>
              <div className={styles.conversaTopo}>
                <div>
                  <strong>{c.nome}</strong>
                  <span>
                    {c.origem === 'COEXISTENCE'
                      ? 'veio da Meta'
                      : c.origem === 'BACKUP_CRYPT15'
                        ? 'veio do backup do aparelho'
                        : 'veio do arquivo'}{' '}
                    · {ROTULO[c.status]}
                    {c.status === 'PRONTO' &&
                      ` · ${c.mensagens} mensagens · ${dia(c.de)} a ${dia(c.ate)}`}
                    {c.comMidia > 0 && ` · ${c.comMidia} com foto`}
                  </span>
                  {c.contactId ? (
                    <span className={styles.amarrada}>
                      amarrada em {c.clienteNoCrm ?? 'uma cliente'}
                    </span>
                  ) : (
                    <span className={styles.solta}>
                      sem cliente amarrada — o pedido de exclusão dela não alcança este arquivo
                    </span>
                  )}
                  {c.erro && <span className={styles.solta}>{c.erro}</span>}
                </div>
                <div className={styles.acoes}>
                  {c.status === 'PRONTO' && (
                    <button className={styles.ghost} onClick={() => void abrir(c.id)}>
                      {aberta === c.id ? 'Fechar' : 'Ver'}
                    </button>
                  )}
                  {c.contactId && (
                    <button className={styles.ghostPerigo} onClick={() => void esquecer(c)}>
                      Apagar os dados dela
                    </button>
                  )}
                </div>
              </div>

              {aberta === c.id && (
                <div className={styles.conversaCorpo}>
                  {falas.map((f) => (
                    <div
                      key={f.position}
                      className={`${styles.balao} ${
                        f.quem === 'DONO'
                          ? styles.doDono
                          : f.quem === 'CLIENTE'
                            ? styles.daCliente
                            : styles.doSistema
                      }`}
                    >
                      {f.midia && <span className={styles.selo}>foto: {f.midia}</span>}
                      <p>{f.texto}</p>
                    </div>
                  ))}
                </div>
              )}
            </div>
          ))}
        </section>
      )}
    </main>
  );
}
