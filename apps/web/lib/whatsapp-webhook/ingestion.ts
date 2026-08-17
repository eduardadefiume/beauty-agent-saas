import { createSupabaseAdminClient } from '../supabase/admin';
import type { NormalizedWhatsAppWebhook } from './normalizer';

export type WebhookIngestionResult = {
  knownChannel: boolean;
  accepted: number;
  duplicates: number;
  ignored: number;
};

function isIngestionResult(value: unknown): value is WebhookIngestionResult {
  if (!value || typeof value !== 'object') return false;
  const candidate = value as Record<string, unknown>;
  return (
    typeof candidate.knownChannel === 'boolean' &&
    typeof candidate.accepted === 'number' &&
    typeof candidate.duplicates === 'number' &&
    typeof candidate.ignored === 'number'
  );
}

export async function ingestVerifiedWhatsAppWebhook(
  normalized: NormalizedWhatsAppWebhook,
  payloadSha256: string,
  correlationId: string
): Promise<WebhookIngestionResult> {
  const supabase = createSupabaseAdminClient();
  const { data, error } = await supabase.rpc('ingest_g3_whatsapp_webhook', {
    p_waba_id: normalized.wabaId,
    p_phone_number_id: normalized.phoneNumberId,
    p_payload_sha256: payloadSha256,
    p_correlation_id: correlationId,
    p_events: normalized.events,
  });

  if (error || !isIngestionResult(data)) {
    throw new Error('WHATSAPP_WEBHOOK_INGESTION_FAILED');
  }

  return data;
}
