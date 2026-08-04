export interface ExternalIntegrationHealth {
  readonly status: 'MOCK' | 'SANDBOX_CONNECTED' | 'CONTROLLED_PRODUCTION' | 'PRODUCTION';
  readonly checkedAt: string;
}
