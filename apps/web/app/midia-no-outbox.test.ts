import { readFile } from 'node:fs/promises';

import { PGlite } from '@electric-sql/pglite';
import { beforeAll, describe, expect, it } from 'vitest';

// 23/09/2026. O ENVIO DE FOTO ESTAVA QUEBRADO EM DOIS PONTOS, E NENHUM DOS DOIS
// TINHA COMO APARECER: `select kind, count(*) from app.outbox_messages group by
// 1` devolvia TEXT e mais nada, em 102 linhas. Caminho que nunca roda nao falha.
//
//   Buraco 1: `outbox_messages_kind_check` so aceitava ('TEXT','TEMPLATE'), e a
//             funcao grava 'MEDIA' desde 27/08. A primeira foto morreria no
//             insert, levando a mensagem junto. Corrigido na 20260923194500.
//   Buraco 2: `public.enqueue_outbound_message` tinha SEIS argumentos e nenhum
//             de midia, entao descartava `p_media_storage_path` antes de chamar
//             a interna -- que decide o `kind` justamente por ele. A foto nao
//             falhava: virava texto. Corrigido na 20260923214500.
//
// ESTE TESTE RODA O SQL DE VERDADE, num Postgres em memoria (PGlite). Nao e
// leitura de arquivo procurando palavra: as migrations sao executadas e a
// funcao e chamada como a Edge Function chama. Se alguem tirar os tres
// argumentos de midia da fachada de novo, ou apertar a trava do `kind`, o teste
// cai aqui em vez de a cliente descobrir por uma foto que virou legenda solta.
//
// O QUE E MAQUETE E O QUE E REAL. Maquete: `tenants`, `units`, `profiles`,
// `channel_connections` (so o id, que e o que as chaves estrangeiras pedem) e
// os quatro stubs de funcao que a porta chama (interruptor, conversa-do-dono,
// acorda-worker, guarda de sessao da tela). Real, lido dos arquivos de
// migration: as tabelas do CRM, a tabela `outbox_messages` com TODAS as suas
// travas, e as tres funcoes sob teste.

const MIGRACOES = new URL('../../../supabase/migrations/', import.meta.url);

const CRM = '20260813114500_crm_inbox_campaigns_base.sql';
const OUTBOX = '20260820133000_b3_outbox_envio_whatsapp.sql';
const MIDIA = '20260827184045_anexos_e_audio_na_saida.sql';
const TRAVA_DO_KIND = '20260923194500_o_lembrete_da_vespera_nao_dependia_de_cnpj.sql';
const FACHADA = '20260923214500_a_fachada_descartava_a_foto_antes_de_chegar_na_porta.sql';

const TENANT = '11111111-1111-4111-8111-111111111111';
const OUTRO_TENANT = '22222222-2222-4222-8222-222222222222';
const CONTATO = '33333333-3333-4333-8333-333333333333';
const CONVERSA = '44444444-4444-4444-8444-444444444444';
const CONEXAO = '55555555-5555-4555-8555-555555555555';

async function lerMigracao(nome: string): Promise<string> {
  return readFile(new URL(nome, MIGRACOES), 'utf8');
}

// Corta um arquivo de migration em comandos. O ponto e virga dentro de corpo de
// funcao (`$function$ ... $$`), de string ou de comentario nao corta nada --
// que e exatamente onde este repositorio guarda a maior parte do seu SQL.
function separarComandos(sql: string): string[] {
  const comandos: string[] = [];
  let inicio = 0;
  let i = 0;
  let tag: string | null = null;

  while (i < sql.length) {
    if (tag !== null) {
      if (sql.startsWith(tag, i)) {
        i += tag.length;
        tag = null;
        continue;
      }
      i += 1;
      continue;
    }

    if (sql.startsWith('--', i)) {
      const fim = sql.indexOf('\n', i);
      i = fim === -1 ? sql.length : fim + 1;
      continue;
    }

    if (sql.startsWith('/*', i)) {
      const fim = sql.indexOf('*/', i + 2);
      i = fim === -1 ? sql.length : fim + 2;
      continue;
    }

    if (sql[i] === "'") {
      i += 1;
      while (i < sql.length && sql[i] !== "'") i += 1;
      i += 1;
      continue;
    }

    if (sql[i] === '$') {
      const abertura = /^\$[A-Za-z_][A-Za-z0-9_]*\$|^\$\$/.exec(sql.slice(i));
      if (abertura) {
        tag = abertura[0];
        i += tag.length;
        continue;
      }
    }

    if (sql[i] === ';') {
      comandos.push(sql.slice(inicio, i + 1));
      i += 1;
      inicio = i;
      continue;
    }

    i += 1;
  }

  const resto = sql.slice(inicio).trim();
  if (resto.length > 0) comandos.push(resto);
  return comandos;
}

// O comando sem os comentarios da frente -- e por eles que estes arquivos
// comecam, sempre.
function corpo(comando: string): string {
  return comando
    .split('\n')
    .filter((linha) => !linha.trim().startsWith('--'))
    .join('\n')
    .trim();
}

function escolher(sql: string, padrao: RegExp): string[] {
  const escolhidos = separarComandos(sql).filter((comando) => padrao.test(corpo(comando)));
  if (escolhidos.length === 0) {
    throw new Error(`nenhum comando casou com ${padrao} -- a migration mudou de forma?`);
  }
  return escolhidos;
}

// As pecas que a porta encosta e que nao valem ser reconstruidas aqui.
// `app.disparos` nao existe em producao: e o caderninho onde o tick_worker de
// mentira anota que foi acordado, para o teste poder cobrar isso.
const MAQUETE = `
create schema if not exists app;
create schema if not exists private;

create role anon;
create role authenticated;
create role service_role;

create type app.tenant_role as enum ('OWNER', 'ADMIN', 'OPERATOR', 'VIEWER');

create table app.tenants (id uuid primary key);
create table app.units (id uuid primary key);
create table app.profiles (id uuid primary key);
create table app.channel_connections (id uuid primary key);
create table app.disparos (fila text, worker text);

create function app.agent_automation_enabled(p_tenant_id uuid)
  returns boolean language sql as $$ select true $$;

create function app.conversa_e_do_dono(p_conversation_id uuid)
  returns boolean language sql as $$ select false $$;

create function app.tick_worker(p_fila text, p_worker text, p_payload jsonb, p_timeout integer)
  returns void language sql as $$
  insert into app.disparos (fila, worker) values (p_fila, p_worker);
$$;

create function private.require_site_tenant(
  p_site_project_id text, p_email text, p_tenant_id uuid, p_papeis app.tenant_role[]
) returns void language sql as $$ select $$;
`;

// Uma conversa com mensagem da cliente agora: sem isso a janela de 24h recusa
// tudo antes de chegar na midia, e o teste passaria a testar outra coisa.
const CONVERSA_ABERTA = `
insert into app.tenants (id) values ('${TENANT}'), ('${OUTRO_TENANT}');
insert into app.channel_connections (id) values ('${CONEXAO}');
insert into app.crm_contacts (id, tenant_id, display_name)
  values ('${CONTATO}', '${TENANT}', 'Rayana');
insert into app.crm_contact_channels (tenant_id, contact_id, channel_connection_id, provider, address_normalized)
  values ('${TENANT}', '${CONTATO}', '${CONEXAO}', 'WHATSAPP', '5516900000001');
insert into app.crm_conversations (id, tenant_id, contact_id, channel_connection_id, last_inbound_at, last_message_at)
  values ('${CONVERSA}', '${TENANT}', '${CONTATO}', '${CONEXAO}', now(), now());
`;

async function bancoDeTeste({ comATravaCorrigida = true } = {}): Promise<PGlite> {
  const db = await PGlite.create();
  await db.exec(MAQUETE);

  const crm = await lerMigracao(CRM);
  const outbox = await lerMigracao(OUTBOX);

  for (const comando of [
    ...escolher(crm, /^create type app\./i),
    ...escolher(
      crm,
      /^create table app\.(crm_contacts|crm_contact_channels|crm_conversations|crm_messages)\b/i
    ),
    ...escolher(outbox, /^alter table app\.crm_conversations\s+add column/i),
    ...escolher(outbox, /^do \$\$[\s\S]*outbox_status/i),
    ...escolher(outbox, /^create table if not exists app\.outbox_messages\b/i),
    ...escolher(await lerMigracao(MIDIA), /^alter table app\.outbox_messages\s+add column/i),
  ]) {
    await db.exec(comando);
  }

  // O conserto da trava do `kind`, da 194500. Opcional de proposito: e assim
  // que o teste consegue mostrar o estado de ontem, com a fachada ja certa e a
  // trava ainda apertada.
  if (comATravaCorrigida) {
    for (const comando of escolher(
      await lerMigracao(TRAVA_DO_KIND),
      /^alter table app\.outbox_messages\b/i
    )) {
      await db.exec(comando);
    }
  }

  // A migration desta tarefa, inteira, do jeito que a Eduarda vai empurrar.
  await db.exec(await lerMigracao(FACHADA));
  await db.exec(CONVERSA_ABERTA);
  return db;
}

// `noUncheckedIndexedAccess` esta ligado neste repositorio, e com razao: uma
// consulta que nao devolve linha tem que estourar dizendo isso, e nao falhar
// tres linhas depois lendo propriedade de undefined.
function primeira<T>(linhas: readonly T[]): T {
  const [linha] = linhas;
  if (linha === undefined) throw new Error('a consulta nao devolveu nenhuma linha');
  return linha;
}

type Resultado = { ok: boolean; reason?: string; outboxId?: string; duplicate?: boolean };

// Chama a fachada pelo NOME dos parametros, que e como o PostgREST chama: o
// corpo JSON da Edge Function vira `p_tenant_id => ...`. Chamada posicional
// passaria por cima justamente do defeito que estamos testando.
async function enfileirar(
  db: PGlite,
  argumentos: Record<string, string | null>
): Promise<Resultado> {
  const nomes = Object.keys(argumentos);
  const chamada = nomes.map((nome, i) => `${nome} => $${i + 1}`).join(', ');
  const { rows } = await db.query<{ saida: Resultado }>(
    `select public.enqueue_outbound_message(${chamada}) as saida`,
    nomes.map((nome) => argumentos[nome])
  );
  return primeira(rows).saida;
}

const FOTO = {
  p_tenant_id: TENANT,
  p_conversation_id: CONVERSA,
  p_body_text: 'olha como ficou',
  p_actor: 'AGENT',
  p_idempotency_key: 'eddy:foto-do-resultado:0',
  p_media_storage_path: `${TENANT}/8f0c5f2e-0f0a-4c5e-9a9c-2c9a0a1b2c3d.jpg`,
  p_media_mime_type: 'image/jpeg',
  p_media_filename: 'resultado.jpg',
};

describe('midia atravessa a fachada e chega no outbox', () => {
  let db: PGlite;

  beforeAll(async () => {
    db = await bancoDeTeste();
  });

  it('a foto chega com kind=MEDIA e o caminho preenchido', async () => {
    const saida = await enfileirar(db, FOTO);
    expect(saida.ok).toBe(true);

    const { rows } = await db.query<{
      kind: string;
      media_storage_path: string | null;
      media_mime_type: string | null;
      media_filename: string | null;
      body_text: string | null;
    }>(
      `select kind, media_storage_path, media_mime_type, media_filename, body_text
         from app.outbox_messages where id = $1`,
      [saida.outboxId ?? null]
    );

    expect(primeira(rows)).toEqual({
      kind: 'MEDIA',
      media_storage_path: FOTO.p_media_storage_path,
      media_mime_type: 'image/jpeg',
      media_filename: 'resultado.jpg',
      body_text: 'olha como ficou',
    });
  });

  it('a conversa registra a mesma mensagem como MEDIA, com o caminho', async () => {
    const { rows } = await db.query<{
      message_type: string;
      metadata_minimized: Record<string, string>;
    }>(
      `select m.message_type, m.metadata_minimized
         from app.crm_messages m
         join app.outbox_messages o on o.message_id = m.id
        where o.media_storage_path is not null`
    );

    expect(primeira(rows).message_type).toBe('MEDIA');
    expect(primeira(rows).metadata_minimized.mediaStoragePath).toBe(FOTO.p_media_storage_path);
  });

  // O envio de foto nao pode herdar a espera de ate um minuto que a 20260923104500
  // tirou do texto.
  it('acorda o worker de envio na hora, como o texto', async () => {
    const { rows } = await db.query<{ fila: string; worker: string }>(
      `select fila, worker from app.disparos`
    );
    expect(rows).toContainEqual({ fila: 'ENVIO', worker: 'whatsapp-sender' });
  });

  // Audio nao tem legenda, e exigir corpo aqui impediria metade da conversa de
  // um salao. Quem garante isso e `outbox_kind_payload_check`, reescrito na 194500.
  it('audio sem legenda entra sem corpo', async () => {
    const saida = await enfileirar(db, {
      ...FOTO,
      p_body_text: null,
      p_idempotency_key: 'eddy:audio-sem-legenda:0',
      p_media_storage_path: `${TENANT}/2b7c1d90-1a2b-4c3d-8e4f-5a6b7c8d9e0f.ogg`,
      p_media_mime_type: 'audio/ogg',
      p_media_filename: null,
    });
    expect(saida.ok).toBe(true);

    const { rows } = await db.query<{ kind: string; body_text: string | null }>(
      `select kind, body_text from app.outbox_messages where id = $1`,
      [saida.outboxId ?? null]
    );
    expect(primeira(rows)).toEqual({ kind: 'MEDIA', body_text: null });
  });

  it('texto continua saindo como TEXT, sem os argumentos de midia', async () => {
    const saida = await enfileirar(db, {
      p_tenant_id: TENANT,
      p_conversation_id: CONVERSA,
      p_body_text: 'oi, tudo bem?',
      p_actor: 'AGENT',
      p_idempotency_key: 'eddy:so-texto:0',
    });
    expect(saida.ok).toBe(true);

    const { rows } = await db.query<{ kind: string; media_storage_path: string | null }>(
      `select kind, media_storage_path from app.outbox_messages where id = $1`,
      [saida.outboxId ?? null]
    );
    expect(primeira(rows)).toEqual({ kind: 'TEXT', media_storage_path: null });
  });

  // A armadilha da correcao, e o motivo de a migration derrubar a fachada
  // antiga antes de criar a nova: com as duas vivas, a chamada de cinco ou seis
  // argumentos que o `whatsapp-agent` faz a cada resposta viraria "function
  // name is not unique" -- trocar o buraco da foto por um apagao no texto.
  it('existe UMA fachada so, e ela carrega os tres argumentos de midia', async () => {
    const { rows } = await db.query<{ args: string }>(
      `select pg_get_function_identity_arguments(p.oid) as args
         from pg_proc p join pg_namespace n on n.oid = p.pronamespace
        where n.nspname = 'public' and p.proname = 'enqueue_outbound_message'`
    );

    expect(rows).toHaveLength(1);
    expect(primeira(rows).args).toContain('p_media_storage_path text');
    expect(primeira(rows).args).toContain('p_media_mime_type text');
    expect(primeira(rows).args).toContain('p_media_filename text');
  });

  // O worker baixa o arquivo com a chave de servico, para quem policy de balde
  // nao existe. Caminho de outro salao tem que morrer aqui.
  it('recusa anexo que nao esta na pasta do proprio salao', async () => {
    const saida = await enfileirar(db, {
      ...FOTO,
      p_idempotency_key: 'eddy:foto-de-outro-salao:0',
      p_media_storage_path: `${OUTRO_TENANT}/roubada.jpg`,
    });

    expect(saida).toMatchObject({ ok: false, reason: 'MEDIA_PATH_FORBIDDEN' });
    const { rows } = await db.query<{ quantas: number }>(
      `select count(*)::int as quantas from app.outbox_messages
        where media_storage_path like $1`,
      [`${OUTRO_TENANT}/%`]
    );
    expect(primeira(rows).quantas).toBe(0);
  });

  // A tela da dona nunca passou pela fachada -- ela chama `app.` direto. A
  // guarda do caminho desceu para la, entao este caminho tem que continuar
  // igual, inclusive na recusa.
  it('a porta da tela continua enfileirando midia, com a mesma recusa', async () => {
    const enviar = async (caminho: string, chave: string) => {
      const { rows } = await db.query<{ saida: Resultado }>(
        `select public.site_send_manual_message(
           'owner-console-v1', 'dona@salao.com', $1::uuid, $2::uuid, $3, $4, $5, $6, $7) as saida`,
        [TENANT, CONVERSA, 'olha o antes', chave, caminho, 'image/jpeg', 'antes.jpg']
      );
      return primeira(rows).saida;
    };

    const aceita = await enviar(`${TENANT}/antes.jpg`, 'tela:foto-antes:0');
    expect(aceita.ok).toBe(true);
    const { rows } = await db.query<{ kind: string; media_storage_path: string }>(
      `select kind, media_storage_path from app.outbox_messages where id = $1`,
      [aceita.outboxId ?? null]
    );
    expect(primeira(rows)).toEqual({ kind: 'MEDIA', media_storage_path: `${TENANT}/antes.jpg` });

    const recusada = await enviar(`${OUTRO_TENANT}/antes.jpg`, 'tela:foto-de-fora:0');
    expect(recusada).toMatchObject({ ok: false, reason: 'MEDIA_PATH_FORBIDDEN' });
  });

  it('a mesma chave nao manda a foto duas vezes', async () => {
    const repetida = await enfileirar(db, FOTO);
    expect(repetida).toMatchObject({ ok: true, duplicate: true });

    const { rows } = await db.query<{ quantas: number }>(
      `select count(*)::int as quantas from app.outbox_messages where idempotency_key = $1`,
      [FOTO.p_idempotency_key]
    );
    expect(primeira(rows).quantas).toBe(1);
  });
});

// O outro buraco, o da 194500, isolado: fachada certa e trava velha. Serve de
// alarme se alguem um dia reescrever `outbox_messages_kind_check` copiando a
// versao antiga de algum arquivo.
describe('a trava do kind sem o conserto da 194500', () => {
  it('derruba a foto no insert, e leva a mensagem junto', async () => {
    const db = await bancoDeTeste({ comATravaCorrigida: false });

    // Sao duas travas velhas, e qualquer uma basta para matar a foto: a do
    // `kind` nao conhecia 'MEDIA', e a de payload exigia corpo de TEXT ou nome
    // de TEMPLATE. Qual das duas o Postgres denuncia primeiro e detalhe dele.
    await expect(enfileirar(db, FOTO)).rejects.toThrow(/outbox_(messages_kind|kind_payload)_check/);

    // A transacao inteira volta atras: nao sobra nem a linha da conversa.
    const { rows } = await db.query<{ quantas: number }>(
      `select count(*)::int as quantas from app.crm_messages`
    );
    expect(primeira(rows).quantas).toBe(0);
  });
});
