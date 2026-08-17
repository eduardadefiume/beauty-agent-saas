import { describe, expect, it } from 'vitest';
import {
  sha256Hex,
  verifyMetaSignature,
  verifyWebhookToken,
} from './signature';

const encoder = new TextEncoder();

function toHex(bytes: ArrayBuffer): string {
  return Array.from(new Uint8Array(bytes))
    .map((part) => part.toString(16).padStart(2, '0'))
    .join('');
}

function asArrayBuffer(value: Uint8Array): ArrayBuffer {
  return value.buffer.slice(value.byteOffset, value.byteOffset + value.byteLength) as ArrayBuffer;
}

async function signedHeader(body: Uint8Array, appSecret: string): Promise<string> {
  const key = await crypto.subtle.importKey(
    'raw',
    encoder.encode(appSecret),
    { name: 'HMAC', hash: 'SHA-256' },
    false,
    ['sign']
  );
  const signature = await crypto.subtle.sign('HMAC', key, asArrayBuffer(body));
  return `sha256=${toHex(signature)}`;
}

describe('Meta webhook signature', () => {
  const appSecret = 'server-side-secret-only';
  const body = encoder.encode('{"object":"whatsapp_business_account"}');

  it('aceita HMAC-SHA256 válido do corpo bruto', async () => {
    await expect(verifyMetaSignature(body, appSecret, await signedHeader(body, appSecret))).resolves.toBe(true);
  });

  it('rejeita assinatura válida para outro corpo', async () => {
    const forgedBody = encoder.encode('{"object":"different"}');
    await expect(verifyMetaSignature(forgedBody, appSecret, await signedHeader(body, appSecret))).resolves.toBe(false);
  });

  it('rejeita cabeçalho malformado', async () => {
    await expect(verifyMetaSignature(body, appSecret, 'sha256=not-a-signature')).resolves.toBe(false);
  });

  it('calcula o hash SHA-256 sem serializar novamente o corpo', async () => {
    await expect(sha256Hex(encoder.encode('abc'))).resolves.toBe(
      'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad'
    );
  });
});

describe('Meta webhook verification token', () => {
  const token = 'verify-token-with-at-least-24-characters';

  it('aceita token configurado idêntico', () => {
    expect(verifyWebhookToken(token, token)).toBe(true);
  });

  it('rejeita token diferente, ausente ou curto', () => {
    expect(verifyWebhookToken('other-token-with-at-least-24-characters', token)).toBe(false);
    expect(verifyWebhookToken(null, token)).toBe(false);
    expect(verifyWebhookToken('short', 'short')).toBe(false);
  });
});
