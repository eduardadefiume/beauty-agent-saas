import initSqlJs from 'sql.js';
import { beforeAll, describe, expect, it } from 'vitest';
import { abrirBackup, chaveDeTexto } from '../lib/whatsapp-backup/crypt15';
import { CHAVE_DO_FIXTURE, bytesDoFixture } from '../lib/whatsapp-backup/fixture-crypt15';
import {
  type BancoLido,
  type ConversaDoBackup,
  MsgstoreDesconhecido,
  extrairConversas,
} from '../lib/whatsapp-backup/msgstore';

// O que este teste tranca: transformar o msgstore.db em conversa.
//
// É a parte que erra em silêncio. Se `from_me` for lido ao contrário, o sistema
// aprende a voz da cliente como se fosse a do dono, e o agente sai falando como
// quem pergunta preço. Se o carimbo de tempo for lido como segundo quando é
// milissegundo, toda a ficha vira 1970. Nenhum dos dois dá erro na tela.
//
// O banco do teste é o mesmo que a wa-crypt-tools cifrou: ele passa pelo
// descriptografador de verdade antes de chegar aqui.

let SQL: Awaited<ReturnType<typeof initSqlJs>>;

beforeAll(async () => {
  SQL = await initSqlJs();
});

async function doFixture(): Promise<ConversaDoBackup[]> {
  const sqlite = await abrirBackup(bytesDoFixture(), chaveDeTexto(CHAVE_DO_FIXTURE));
  return extrairConversas(new SQL.Database(sqlite) as unknown as BancoLido);
}

describe('o esquema atual do WhatsApp', () => {
  it('separa as conversas por pessoa e mantém a ordem da conversa', async () => {
    const conversas = await doFixture();
    const andreia = conversas.find((c) => c.telefone === '5516999990001');

    expect(andreia).toBeDefined();
    expect(andreia?.falas.map((f) => f.texto)).toEqual([
      'oi, quanto ta a progressiva?',
      'oi linda! depende do comprimento',
      'meu cabelo hoje',
      'da pra fazer sim, mas antes preciso ver a raiz',
    ]);
  });

  it('sabe quem é o dono e quem é a cliente', async () => {
    const conversas = await doFixture();
    const andreia = conversas.find((c) => c.telefone === '5516999990001');
    expect(andreia?.falas.map((f) => f.quem)).toEqual(['CLIENTE', 'DONO', 'CLIENTE', 'DONO']);
  });

  it('lê o carimbo de tempo em milissegundo, não em 1970', async () => {
    const conversas = await doFixture();
    const primeira = conversas.find((c) => c.telefone === '5516999990001')?.falas[0];
    expect(primeira?.enviadaEm).toBe(new Date(1610000000000).toISOString());
  });

  it('traz o arquivo da foto que a cliente mandou', async () => {
    const conversas = await doFixture();
    const comFoto = conversas
      .find((c) => c.telefone === '5516999990001')
      ?.falas.find((f) => f.midia != null);
    expect(comFoto?.midia).toBe('Media/WhatsApp Images/IMG-1.jpg');
    expect(comFoto?.texto).toBe('meu cabelo hoje');
  });

  it('não deixa grupo virar cliente com telefone', async () => {
    const conversas = await doFixture();
    const grupo = conversas.find((c) => c.ehGrupo);
    expect(grupo?.nome).toBe('Equipe do salao');
    // Amarrar o id do grupo como telefone acabaria colando a conversa do time
    // na ficha de alguma cliente.
    expect(grupo?.telefone).toBeNull();
  });

  it('joga fora a mensagem de sistema, que não é voz de ninguém', async () => {
    const conversas = await doFixture();
    const todas = conversas.flatMap((c) => c.falas);
    expect(todas.every((f) => f.texto != null || f.midia != null)).toBe(true);
    expect(todas).toHaveLength(7);
  });
});

describe('o esquema antigo, de quem tem backup de celular velho', () => {
  function bancoAntigo(): BancoLido {
    const banco = new SQL.Database();
    banco.run(`
      create table messages (_id integer primary key, key_remote_jid text, key_from_me integer,
                             data text, timestamp integer, media_wa_type integer, media_name text);
      insert into messages values (1,'5516988880001@s.whatsapp.net',0,'faz cronograma capilar?',1500000000,0,null);
      insert into messages values (2,'5516988880001@s.whatsapp.net',1,'faço sim, sao 3 sessoes',1500000060,0,null);
      insert into messages values (3,'5516988880001@s.whatsapp.net',0,null,1500000120,1,'IMG-9.jpg');
    `);
    return banco as unknown as BancoLido;
  }

  it('lê a tabela antiga com o telefone escrito na própria linha', () => {
    const [conversa] = extrairConversas(bancoAntigo());
    expect(conversa?.telefone).toBe('5516988880001');
    expect(conversa?.falas.map((f) => f.quem)).toEqual(['CLIENTE', 'DONO', 'CLIENTE']);
    expect(conversa?.falas[2]?.midia).toBe('IMG-9.jpg');
  });

  it('entende carimbo em segundo, que é como o esquema antigo grava', () => {
    const [conversa] = extrairConversas(bancoAntigo());
    expect(conversa?.falas[0]?.enviadaEm).toBe(new Date(1500000000 * 1000).toISOString());
  });
});

describe('quando não é um msgstore', () => {
  it('diz qual arquivo é o certo em vez de devolver lista vazia', () => {
    const banco = new SQL.Database();
    banco.run('create table wa_contacts (_id integer primary key, jid text)');
    // Lista vazia seria pior que erro: pareceria "backup sem conversa nenhuma".
    expect(() => extrairConversas(banco as unknown as BancoLido)).toThrow(MsgstoreDesconhecido);
  });
});
