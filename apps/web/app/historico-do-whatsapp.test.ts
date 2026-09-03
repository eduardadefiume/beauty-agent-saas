import { describe, expect, it } from 'vitest';
import {
  decidirQuemEQuem,
  separarMensagens,
} from '../../../supabase/functions/whatsapp-history-reader/parser';
import { nomeNoArquivo } from './historico/page';

// O que este teste tranca: entender o arquivo que o WhatsApp exporta.
//
// É a parte mais arriscada da etapa 6, e a que erra em silêncio. Se o parser
// picar uma explicação de cinco linhas em cinco mensagens, ou trocar quem é o
// dono por quem é a cliente, o arquivo nasce torto e a tela mostra ele torto
// com toda a cara de certo. Não existe como perceber olhando.
//
// Os dois formatos existem de verdade: Android pt-BR e iOS escrevem diferente,
// e o dono pode ter trocado de celular no meio dos dois anos de histórico.

const ANDROID = [
  '03/09/2026 14:32 - As mensagens são criptografadas de ponta a ponta.',
  '03/09/2026 14:33 - Andreia: oi, quanto ta a progressiva?',
  '03/09/2026 14:35 - William: Oi Andreia! Depende do comprimento.',
  'No seu caso, que é longo, fica 380.',
  'Mas preciso ver o cabelo antes.',
  '03/09/2026 14:36 - Andreia: nossa, caro',
  '03/09/2026 14:38 - William: É que uso produto sem formol, dura mais.',
  '03/09/2026 14:40 - Andreia: IMG-20260903-WA0007.jpg (arquivo anexado)',
  '03/09/2026 14:41 - William: Tenho quinta às 14h, pode ser?',
].join('\n');

const IOS = [
  '[03/09/2026 14:33:02] Andreia: oi, quanto ta a progressiva?',
  '[03/09/2026 14:35:10] William: Oi Andreia! Depende do comprimento.',
  '[03/09/2026 14:40:00] Andreia: <Mídia oculta>',
].join('\n');

describe('entender o export do WhatsApp', () => {
  it('lê o formato do Android e não perde mensagem', () => {
    const linhas = separarMensagens(ANDROID);
    expect(linhas).toHaveLength(7);
  });

  it('mensagem de várias linhas continua sendo UMA mensagem', () => {
    const linhas = separarMensagens(ANDROID);
    const explicacao = linhas[2];
    if (!explicacao) throw new Error('a explicação do dono sumiu');
    expect(explicacao.texto).toContain('Depende do comprimento');
    expect(explicacao.texto).toContain('fica 380');
    expect(explicacao.texto).toContain('preciso ver o cabelo antes');
  });

  it('aviso do próprio WhatsApp não vira fala de ninguém', () => {
    const linhas = decidirQuemEQuem(separarMensagens(ANDROID), null);
    const primeira = linhas[0];
    if (!primeira) throw new Error('a primeira linha sumiu');
    expect(primeira.autor).toBeNull();
    expect(primeira.quem).toBe('SISTEMA');
  });

  it('quando o dono diz o nome dele, cada fala vai para o lado certo', () => {
    const linhas = decidirQuemEQuem(separarMensagens(ANDROID), 'William');
    const doDono = linhas.filter((l) => l.quem === 'DONO');
    const daCliente = linhas.filter((l) => l.quem === 'CLIENTE');
    expect(doDono.every((l) => l.autor === 'William')).toBe(true);
    expect(daCliente.every((l) => l.autor === 'Andreia')).toBe(true);
    expect(doDono).toHaveLength(3);
    expect(daCliente).toHaveLength(3);
  });

  it('sem o nome, quem fala mais é o dono', () => {
    // O dono responde duas vezes seguidas, como acontece quando ele explica.
    const desempatado = separarMensagens(
      [
        '03/09/2026 10:00 - Andreia: oi',
        '03/09/2026 10:01 - William: Oi!',
        '03/09/2026 10:02 - William: Me manda uma foto do cabelo?',
      ].join('\n')
    );
    const linhas = decidirQuemEQuem(desempatado, null);
    expect(linhas.filter((l) => l.quem === 'DONO')).toHaveLength(2);
    expect(linhas.filter((l) => l.quem === 'CLIENTE')).toHaveLength(1);
  });

  // Este é o caso que fez o desenho mudar. Numa conversa equilibrada -- que é
  // a conversa normal de um salão -- a contagem empata, e aí o leitor NÃO pode
  // chutar: marca tudo como cliente e espera o dono dizer o nome dele. Marca
  // trocada contaminaria justamente a voz que se quer aprender.
  it('empate não chuta quem é o dono: fica tudo como cliente', () => {
    const empate = separarMensagens(
      ['03/09/2026 10:00 - A: oi', '03/09/2026 10:01 - B: oi'].join('\n')
    );
    const linhas = decidirQuemEQuem(empate, null);
    expect(linhas.every((l) => l.quem === 'CLIENTE')).toBe(true);
  });

  it('o empate do exemplo real também não é chutado', () => {
    // William e Andreia falam 3 vezes cada neste arquivo.
    const linhas = decidirQuemEQuem(separarMensagens(ANDROID), null);
    expect(linhas.filter((l) => l.quem === 'DONO')).toHaveLength(0);
  });

  it('o nome do arquivo da foto que ela mandou é preservado', () => {
    const linhas = separarMensagens(ANDROID);
    const comFoto = linhas.find((l) => l.midia !== null);
    expect(comFoto?.midia).toBe('IMG-20260903-WA0007.jpg');
  });

  it('mídia que não veio no export fica marcada como oculta, não some', () => {
    const linhas = separarMensagens(IOS);
    const oculta = linhas[2];
    if (!oculta) throw new Error('a linha de mídia oculta sumiu');
    expect(oculta.midia).toBe('<oculta>');
  });

  it('lê o formato do iOS igual ao do Android', () => {
    const linhas = decidirQuemEQuem(separarMensagens(IOS), 'William');
    expect(linhas).toHaveLength(3);
    expect(linhas[1]?.quem).toBe('DONO');
    expect(linhas[0]?.quem).toBe('CLIENTE');
  });

  it('a data vira horário de São Paulo, não UTC', () => {
    const linhas = separarMensagens(ANDROID);
    expect(linhas[1]?.sentAt).toBe('2026-09-03T14:33:00-03:00');
  });

  it('data impossível não derruba a mensagem: entra sem data', () => {
    const linhas = separarMensagens('45/13/2026 99:99 - William: mesmo assim eu falei isto');
    expect(linhas).toHaveLength(1);
    expect(linhas[0]?.sentAt).toBeNull();
    expect(linhas[0]?.texto).toBe('mesmo assim eu falei isto');
  });

  it('arquivo vazio não vira mensagem nenhuma', () => {
    expect(separarMensagens('')).toHaveLength(0);
    expect(separarMensagens('\n\n\n')).toHaveLength(0);
  });

  it('a posição é sequencial, porque é ela que ordena a conversa', () => {
    const linhas = separarMensagens(ANDROID);
    expect(linhas.map((l) => l.position)).toEqual([0, 1, 2, 3, 4, 5, 6]);
  });
});

// O nome do contato sai do nome do arquivo, e é ele que vai procurar a cliente
// no CRM. Errar aqui é subir cinquenta conversas todas chamadas
// "Conversa do WhatsApp com" e nenhuma amarrada em ninguém.
describe('tirar o nome do contato do nome do arquivo', () => {
  it('lê o formato que o WhatsApp em português gera', () => {
    expect(nomeNoArquivo('Conversa do WhatsApp com Andreia Silva.txt')).toBe('Andreia Silva');
  });

  it('lê o formato em inglês, que aparece em celular com idioma trocado', () => {
    expect(nomeNoArquivo('WhatsApp Chat with Andreia Silva.txt')).toBe('Andreia Silva');
  });

  it('lê a variação curta, sem "do WhatsApp"', () => {
    expect(nomeNoArquivo('Conversa com Jack.txt')).toBe('Jack');
  });

  it('arquivo renomeado à mão vira o próprio nome, sem inventar', () => {
    expect(nomeNoArquivo('andreia.txt')).toBe('andreia');
  });

  it('número no lugar do nome também passa, porque é como muita gente salva', () => {
    expect(nomeNoArquivo('Conversa do WhatsApp com +55 16 98106-4232.txt')).toBe(
      '+55 16 98106-4232'
    );
  });
});
