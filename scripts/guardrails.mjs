import { execFileSync } from 'node:child_process';
import { readFileSync, readdirSync } from 'node:fs';
import { join, relative } from 'node:path';

const ignoredDirectories = new Set(['.git', '.next', '.turbo', 'coverage', 'dist', 'node_modules']);

function listWorkspaceFiles(directory = '.') {
  return readdirSync(directory, { withFileTypes: true }).flatMap((entry) => {
    const path = join(directory, entry.name);

    if (entry.isDirectory()) {
      return ignoredDirectories.has(entry.name) ? [] : listWorkspaceFiles(path);
    }

    return [relative('.', path).replaceAll('\\', '/')];
  });
}

function listTrackedFiles() {
  try {
    return execFileSync('git', ['ls-files', '-z'], {
      encoding: 'utf8',
      stdio: ['ignore', 'pipe', 'ignore'],
    })
      .split('\0')
      .filter(Boolean);
  } catch {
    return listWorkspaceFiles();
  }
}

const trackedFiles = listTrackedFiles();

const ruleFiles = trackedFiles.filter(
  (path) =>
    path.startsWith('packages/domain/src/') || path.startsWith('packages/scheduling-engine/src/')
);

const textFiles = trackedFiles.filter(
  (path) =>
    !path.endsWith('pnpm-lock.yaml') &&
    /(?:\.(?:ts|tsx|js|mjs|json|ya?ml|toml|sql)|\.env\.example)$/.test(path)
);

const failures = [];
const pilotNamePattern = /\b(?:William|Jack)\b/i;

// Os quatro primeiros padrões são os originais. Os demais foram acrescentados
// depois que `.project-config.json` — que continha senha de banco TiDB,
// JWT_SECRET, duas chaves de API e um token git — passou pelo guardrail sem ser
// detectado: nenhum dos padrões antigos cobria DSN com senha nem chave opaca.
const secretPatterns = [
  /sb_secret_[A-Za-z0-9_-]{10,}/,
  /service_role\s*[:=]\s*["']?[^\s"']{10,}/i,
  /-----BEGIN (?:RSA |EC )?PRIVATE KEY-----/,
  /eyJ[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{20,}/,

  // DSN com credencial embutida: postgres://, mysql://, redis://, mongodb://...
  // Exige usuário E senha para não acusar `postgres://localhost:5432/db`.
  /\b[a-z][a-z0-9+.-]*:\/\/[^\s:/@"']+:[^\s:/@"']+@[^\s/"']+/i,

  // Segredo atribuído a uma chave cujo nome denuncia o conteúdo.
  // Deliberadamente SEM a flag /i e exigindo valor literal entre aspas: com /i o
  // padrão casava com identificadores comuns de código (`password = ...`,
  // `verifyTokenSecret = Deno.env.get(...)`), e sem as aspas casava com
  // referências a variáveis de ambiente, que não são segredo.
  // Valor precisa ter 16+ caracteres, o que descarta placeholders curtos e
  // atribuições vazias de arquivos .env.example.
  /\b[A-Z][A-Z0-9_]*(?:SECRET|PASSWORD|PASSWD|PRIVATE_KEY|ACCESS_TOKEN|API_KEY|APIKEY)[A-Z0-9_]*["']?\s*[:=]\s*["'](?!SUBSTITUA|REPLACE|CHANGEME|YOUR_)[A-Za-z0-9_\-+./]{16,}["']/,

  // Token de artefato do Manus/Cloudflare, no formato art_v2_...
  /\bart_v2_[A-Za-z0-9_]{8,}/,

  // Token pessoal do GitHub.
  /\bgh[pousr]_[A-Za-z0-9]{20,}/,
];

for (const path of ruleFiles) {
  if (pilotNamePattern.test(readFileSync(path, 'utf8'))) {
    failures.push(`${path}: nome de piloto encontrado em regra de produção`);
  }
}

// PORTA ANÔNIMA EM FUNÇÃO SECURITY DEFINER
//
// No PostgreSQL, `create function` concede EXECUTE ao papel PUBLIC por padrão, e
// `anon` -- a chave pública que vai no JavaScript do site -- herda de PUBLIC.
// Escrever `grant execute ... to service_role` no fim da migração não fecha
// nada: é uma concessão a mais sobre uma porta já aberta.
//
// Foi assim que 33 funções nasceram alcançáveis por qualquer pessoa na
// internet, uma de cada vez, cada uma copiando o formato da anterior. Nenhuma
// revisão pegou porque o defeito não está no que a migração escreve -- está no
// que ela deixa de escrever.
//
// A verificação vale para migrações a partir da varredura que fechou as 33. As
// anteriores foram corrigidas lá, e cobrá-las aqui só quebraria o CI sem
// ensinar nada.
const CORTE_PORTA_ANONIMA = '20260908';

// Exceções legítimas: funções que PRECISAM ser chamadas por quem está logado,
// e que por isso autorizam pela sessão (`auth.uid()` / `auth.jwt()`), nunca por
// parâmetro que o chamador manda.
const CHAMAVEIS_POR_USUARIO = new Set([
  'app.storage_folder_is_my_tenant',
  'public.complete_owner_signup',
  'api.check_configuration_readiness',
  'api.publish_configuration',
]);

// Migrações JÁ APLICADAS que a regra acusa, mas que o banco mostra fechadas.
//
// A regra olha um arquivo por vez, e o arquivo aplicado não pode mudar: ele é
// o espelho byte a byte de schema_migrations. Cada linha aqui foi conferida em
// produção em 24/09/2026 com has_function_privilege('anon'|'authenticated').
//
// Onze são `create or replace` de função que já existia fechada: o Postgres
// mantém o ACL em replace, então a porta nunca abriu. As três últimas nasceram
// abertas de verdade e foram fechadas por 20260924114619.
//
// Esta lista não cresce com migração nova: quem escreve SECURITY DEFINER daqui
// em diante põe o revoke no mesmo arquivo, que é o que a regra cobra.
const JA_CONFERIDAS_NO_BANCO = new Set([
  '20260916120835_a_clonagem_de_rascunho_deixa_de_ser_exclusiva_da_tela.sql:public.site_start_new_draft',
  '20260917144958_o_agente_nao_falha_calado.sql:app.record_agent_failure',
  '20260917144958_o_agente_nao_falha_calado.sql:app.clear_agent_failures',
  '20260918144449_o_eddy_aprende_a_criar_e_a_publicar.sql:app.onboarding_criar_servico',
  '20260918154546_a_pausa_da_atendente_nao_pode_calar_o_eddy.sql:app.enqueue_outbound_message',
  '20260922201500_um_dono_pode_ter_mais_de_um_salao.sql:app.build_owner_context',
  '20260923104500_a_resposta_sai_na_hora_e_nao_no_proximo_minuto.sql:app.enqueue_outbound_message',
  '20260923134500_cidade_sem_estado_nao_e_endereco.sql:app.owner_setup_state',
  '20260923154500_profissional_sem_disponibilidade_nao_atende_ninguem.sql:app.owner_setup_state',
  '20260923164500_o_compromisso_de_uma_pessoa_nao_fecha_a_agenda_do_salao.sql:public.schedule_list_calendar_shifts',
  '20260923184500_a_primeira_pergunta_e_o_que_voce_quer_que_eu_faca.sql:app.owner_setup_state',
  '20260924113425_o_que_o_dono_ensina_vira_regra_da_atendente.sql:app.onboarding_publicar',
  '20260924113425_o_que_o_dono_ensina_vira_regra_da_atendente.sql:app.onboarding_resumo_do_rascunho',
  '20260916203123_queda_de_infra_nao_queima_a_tentativa_de_ler_a_foto.sql:app.record_media_understanding',
  '20260917144958_o_agente_nao_falha_calado.sql:app.raise_agent_alert',
  '20260917144958_o_agente_nao_falha_calado.sql:app.aviso_de_espera',
  // 10/10/2026: migrações de 28/09 a 02/10 escritas sem o revoke no arquivo.
  // Conferidas em produção e no DEV com has_function_privilege('anon'|'authenticated'):
  // todas fechadas (ACL só postgres/service_role). O arquivo aplicado não pode mudar.
  '20260928161120_dono_so_de_whatsapp_publica.sql:app.onboarding_publicar',
  '20260928161120_dono_so_de_whatsapp_publica.sql:public.site_publish_configuration',
  '20260930125630_equipe_um_so_e_titulo_na_agenda.sql:app.agenda_gravacoes_pendentes',
  '20260930125630_equipe_um_so_e_titulo_na_agenda.sql:app.eddy_cadastro_resumido',
  '20260930162612_conexao_caida_na_gravacao_avisa_na_hora.sql:app.agenda_gravacao_feita',
  '20260930163032_reconectar_mantem_a_agenda.sql:app.agenda_usar_convite',
  '20260930194118_descricao_do_google_segue_a_frente.sql:app.agenda_gravacoes_pendentes',
  '20261001141028_reserva_usa_o_sinal_do_dono.sql:public.schedule_confirm_hold',
  '20261001165621_formol_so_para_alisamento.sql:app.client_profile_missing',
  '20261001171135_valor_a_partir_de_em_todo_lugar.sql:app.agenda_valores_do_agendamento',
  '20261001171135_valor_a_partir_de_em_todo_lugar.sql:app.appointment_label',
  '20261001171135_valor_a_partir_de_em_todo_lugar.sql:app.eddy_ver_agenda',
  '20261001171135_valor_a_partir_de_em_todo_lugar.sql:app.sinal_cartao',
  '20261001173938_sem_quimica_limpa_o_que_ficou_pendurado.sql:public.record_client_profile_facts',
  '20261001184141_sinal_comprovante_da_cliente.sql:app.sinal_avisar_dono',
  '20261001184141_sinal_comprovante_da_cliente.sql:app.sinal_comprovante_da_conversa',
  '20261001184141_sinal_comprovante_da_cliente.sql:app.sinal_conversa_da_cliente',
  '20261001184141_sinal_comprovante_da_cliente.sql:app.sinal_mandar_para_cliente',
  '20261001184141_sinal_comprovante_da_cliente.sql:app.sinal_o_que',
  '20261001184411_sinal_dono_confirma_lembrete_e_prazo.sql:app.sinal_dono_respondeu',
  '20261001184411_sinal_dono_confirma_lembrete_e_prazo.sql:app.sinal_pendentes_do_dono',
  '20261001184411_sinal_dono_confirma_lembrete_e_prazo.sql:app.sinal_rotina',
  '20261001185230_sinal_devolucao_e_pontes.sql:app.sinal_ao_cancelar',
  '20261001185230_sinal_devolucao_e_pontes.sql:app.sinal_do_cancelamento',
  '20261001185230_sinal_devolucao_e_pontes.sql:public.sinal_comprovante_da_conversa',
  '20261001185230_sinal_devolucao_e_pontes.sql:public.sinal_do_cancelamento',
  '20261001185230_sinal_devolucao_e_pontes.sql:public.sinal_dono_respondeu',
  '20261001185230_sinal_devolucao_e_pontes.sql:public.sinal_pendentes_do_dono',
  '20261001191500_sinal_ajustes_do_teste.sql:app.sinal_ao_cancelar',
  '20261001191500_sinal_ajustes_do_teste.sql:app.sinal_comprovante_da_conversa',
  '20261001191500_sinal_ajustes_do_teste.sql:app.sinal_do_cancelamento',
  '20261001191500_sinal_ajustes_do_teste.sql:app.sinal_dono_respondeu',
  '20261001191500_sinal_ajustes_do_teste.sql:app.sinal_rotina',
  '20261001192500_descricao_do_google_a_partir_de.sql:app.agenda_gravacoes_pendentes',
  '20261001212000_sinal_credito_ajustes.sql:app.sinal_credito_usa',
  '20261001212000_sinal_credito_ajustes.sql:app.sinal_devolver_credito',
  '20261001214500_sinal_texto_do_credito_ao_dono.sql:app.sinal_dono_respondeu',
  '20261002121500_teste_de_mecha_jeito_cai_quando_muda.sql:app.eddy_definir_teste_mecha',
]);

const migracoes = trackedFiles.filter(
  (path) => path.startsWith('supabase/migrations/') && path.endsWith('.sql')
);

// TABELA NOVA SEM RLS
//
// Mesmo defeito de forma da porta anônima: o padrão do PostgreSQL é permissivo,
// e a proteção depende de alguém lembrar de escrever uma linha. Vinte e nove
// tabelas nasceram sem RLS -- inclusive as que guardam o histórico de WhatsApp
// das clientes.
//
// Hoje isso não é exposição porque nenhuma delas concede privilégio a `anon` ou
// `authenticated`. Mas a segurança delas depende INTEIRAMENTE de ninguém nunca
// escrever um `grant`, e este repositório já provou que esquece exatamente esse
// tipo de linha. Com RLS ligada e sem política, um `grant` escrito por distração
// é inofensivo em vez de abrir a tabela inteira.
const CORTE_RLS = '20260908';

const rlsDispensada = new Set([
  // Tabelas de infraestrutura do próprio worker, sem dado de pessoa. Se alguma
  // um dia guardar dado de cliente, sai desta lista.
]);

for (const path of migracoes) {
  const nomeDoArquivo = path.split('/').pop() ?? '';
  const sql = readFileSync(path, 'utf8');

  if (nomeDoArquivo.slice(0, 8) >= CORTE_RLS) {
    for (const [, tabela] of sql.matchAll(
      /create\s+table\s+(?:if\s+not\s+exists\s+)?app\.([a-z0-9_]+)/gi
    )) {
      if (rlsDispensada.has(tabela)) continue;
      const liga = new RegExp(
        `alter\\s+table\\s+(?:only\\s+)?app\\.${tabela}\\s+enable\\s+row\\s+level\\s+security`,
        'i'
      );
      if (!liga.test(sql)) {
        failures.push(
          `${path}: app.${tabela} é criada sem ligar RLS. ` +
            'Sem isso, um `grant` escrito depois abre a tabela inteira. ' +
            `Acrescente: alter table app.${tabela} enable row level security;`
        );
      }
    }
  }

  if (nomeDoArquivo.slice(0, 8) < CORTE_PORTA_ANONIMA) continue;

  const criacoes = sql.matchAll(
    /create\s+(?:or\s+replace\s+)?function\s+(public|app|api)\.([a-z0-9_]+)\s*\(([\s\S]*?)\bas\s+\$/gi
  );

  for (const [, esquema, nome, corpo] of criacoes) {
    if (!/security\s+definer/i.test(corpo)) continue;

    const alvoCompleto = `${esquema}.${nome}`;
    if (CHAMAVEIS_POR_USUARIO.has(alvoCompleto)) continue;
    if (JA_CONFERIDAS_NO_BANCO.has(`${nomeDoArquivo}:${alvoCompleto}`)) continue;

    const revoga = new RegExp(
      `revoke[\\s\\S]{0,200}?on\\s+function\\s+${esquema}\\.${nome}\\b[\\s\\S]{0,300}?\\bfrom\\b[^;]*\\bpublic\\b`,
      'i'
    );

    if (!revoga.test(sql)) {
      failures.push(
        `${path}: ${alvoCompleto} é SECURITY DEFINER e a migração não revoga EXECUTE de public. ` +
          'Sem isso ela nasce chamável pelo papel anon. ' +
          'Acrescente: revoke all on function ' +
          alvoCompleto +
          '(...) from public, anon, authenticated;'
      );
    }
  }
}

for (const path of textFiles) {
  const content = readFileSync(path, 'utf8');
  if (secretPatterns.some((pattern) => pattern.test(content))) {
    failures.push(`${path}: possível segredo versionado`);
  }
}

if (failures.length > 0) {
  process.stderr.write(`${failures.join('\n')}\n`);
  process.exit(1);
}

process.stdout.write(
  'Guardrails aprovados: sem regra por nome de piloto, sem segredo detectado e ' +
    'sem função SECURITY DEFINER aberta ao papel anônimo e sem tabela nova sem RLS.\n'
);
