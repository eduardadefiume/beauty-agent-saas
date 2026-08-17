const encoder = new TextEncoder();

function toHex(bytes: ArrayBuffer): string {
  return Array.from(new Uint8Array(bytes))
    .map((part) => part.toString(16).padStart(2, '0'))
    .join('');
}

function asArrayBuffer(value: Uint8Array): ArrayBuffer {
  return value.buffer.slice(value.byteOffset, value.byteOffset + value.byteLength) as ArrayBuffer;
}

export function constantTimeEqual(left: string, right: string): boolean {
  if (left.length !== right.length) return false;

  let difference = 0;
  for (let index = 0; index < left.length; index += 1) {
    difference |= left.charCodeAt(index) ^ right.charCodeAt(index);
  }
  return difference === 0;
}

export function verifyWebhookToken(received: string | null, expected: string): boolean {
  return received !== null && expected.length >= 24 && constantTimeEqual(received, expected);
}

export async function sha256Hex(bytes: Uint8Array): Promise<string> {
  return toHex(await crypto.subtle.digest('SHA-256', asArrayBuffer(bytes)));
}

export async function verifyMetaSignature(
  rawBody: Uint8Array,
  appSecret: string,
  signatureHeader: string | null
): Promise<boolean> {
  if (!signatureHeader || !/^sha256=[a-f0-9]{64}$/i.test(signatureHeader)) return false;

  const key = await crypto.subtle.importKey(
    'raw',
    encoder.encode(appSecret),
    { name: 'HMAC', hash: 'SHA-256' },
    false,
    ['sign']
  );
  const signature = await crypto.subtle.sign('HMAC', key, asArrayBuffer(rawBody));
  const expected = `sha256=${toHex(signature)}`;

  return constantTimeEqual(expected, signatureHeader.trim().toLowerCase());
}
