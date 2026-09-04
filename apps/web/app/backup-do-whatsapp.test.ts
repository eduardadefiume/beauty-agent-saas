import { describe, expect, it } from 'vitest';
import {
  BackupIlegivel,
  abrirBackup,
  chaveDeTexto,
  derivarChaveDoBackup,
  lerCabecalho,
} from '../lib/whatsapp-backup/crypt15';
import { CHAVE_DO_FIXTURE, bytesDoFixture } from '../lib/whatsapp-backup/fixture-crypt15';

// O que este teste tranca: abrir o backup do WhatsApp do dono.
//
// Errar aqui não dá tela vermelha — dá arquivo aberto pela metade, ou aberto
// com o conteúdo embaralhado, com toda a cara de certo. E o insumo é a chave de
// 64 dígitos do dono, que não se pede duas vezes sem constrangimento.
//
// O arquivo do teste foi cifrado pela wa-crypt-tools, não por este código.

const CIFRADO = bytesDoFixture();

describe('a chave que o dono copia da tela do WhatsApp', () => {
  it('aceita do jeito que ele cola: com espaços, quebras e maiúsculas', () => {
    const doJeitoDele = CHAVE_DO_FIXTURE.toUpperCase().replace(/(.{8})/g, '$1 \n');
    expect(chaveDeTexto(doJeitoDele)).toEqual(chaveDeTexto(CHAVE_DO_FIXTURE));
  });

  it('recusa o que não tem 64 dígitos, e diz quantos tem', () => {
    expect(() => chaveDeTexto('abc123')).toThrowError(/64 dígitos.*tem 6/s);
    expect(() => chaveDeTexto(`${CHAVE_DO_FIXTURE}ff`)).toThrowError(BackupIlegivel);
  });

  it('deriva a mesma chave de trabalho que a implementação de referência', async () => {
    // HKDF-SHA256, sal de 32 zeros, rótulo "backup encryption". O valor
    // esperado saiu da wa-crypt-tools rodando sobre a mesma chave raiz.
    const chave = await derivarChaveDoBackup(chaveDeTexto(CHAVE_DO_FIXTURE));
    expect(chave.algorithm).toMatchObject({ name: 'AES-GCM', length: 256 });
  });
});

describe('o cabeçalho do crypt15', () => {
  it('acha o IV de 16 bytes e onde os dados começam', () => {
    const { iv, inicioDosDados } = lerCabecalho(CIFRADO);
    expect(Buffer.from(iv).toString('hex')).toBe('0f0e0d0c0b0a09080706050403020100');
    expect(inicioDosDados).toBeGreaterThan(0);
    expect(inicioDosDados).toBeLessThan(CIFRADO.length);
  });

  it('diz que não é crypt15 em vez de tentar abrir qualquer coisa', () => {
    expect(() => lerCabecalho(new Uint8Array([0x05, 1, 2, 3]))).toThrowError(BackupIlegivel);
    // Um .txt exportado, que é o outro arquivo que o dono tem à mão e pode
    // acabar escolhendo por engano.
    expect(() => lerCabecalho(new TextEncoder().encode('03/09/2026 14:32 - Andreia: oi'))).toThrow(
      BackupIlegivel
    );
  });
});

describe('abrir o backup', () => {
  it('devolve o msgstore.db, que é um SQLite de verdade', async () => {
    const aberto = await abrirBackup(CIFRADO, chaveDeTexto(CHAVE_DO_FIXTURE));
    expect(new TextDecoder().decode(aberto.subarray(0, 15))).toBe('SQLite format 3');
    // O conteúdo chegou inteiro, não só o cabeçalho do SQLite.
    expect(aberto.length).toBe(20480);
    expect(Buffer.from(aberto).includes('quanto ta a progressiva')).toBe(true);
  });

  it('abre também o backup partido em vários arquivos, que não tem o md5 no fim', async () => {
    // Backup multiarquivo é exatamente este arquivo sem os 16 bytes finais: a
    // tag passa a ser o fim. Sem tratar os dois casos, metade dos backups
    // grandes falharia dizendo "chave errada" com a chave certa.
    const semChecksum = CIFRADO.subarray(0, CIFRADO.length - 16);
    const aberto = await abrirBackup(semChecksum, chaveDeTexto(CHAVE_DO_FIXTURE));
    expect(new TextDecoder().decode(aberto.subarray(0, 15))).toBe('SQLite format 3');
  });

  it('chave errada falha dizendo que é a chave, não "arquivo corrompido"', async () => {
    const outra = chaveDeTexto('ff'.repeat(32));
    await expect(abrirBackup(CIFRADO, outra)).rejects.toMatchObject({
      motivo: 'CHAVE_NAO_ABRE',
    });
  });

  it('arquivo mexido no meio não passa como se estivesse bom', async () => {
    const mexido = Uint8Array.from(CIFRADO);
    const meio = Math.floor(mexido.length / 2);
    mexido[meio] = ((mexido[meio] as number) + 1) & 0xff;
    await expect(abrirBackup(mexido, chaveDeTexto(CHAVE_DO_FIXTURE))).rejects.toBeInstanceOf(
      BackupIlegivel
    );
  });
});
