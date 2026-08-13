export type TenantWorkspace = {
  tenantId: string;
  tenantName: string;
  tenantSlug: string;
  unitId: string;
  unitName: string;
  timezone: string;
  status: string;
};

export function selectTenantWorkspace(
  workspaces: TenantWorkspace[],
  requestedTenantId: string | null
): TenantWorkspace | null {
  if (requestedTenantId) {
    return workspaces.find((workspace) => workspace.tenantId === requestedTenantId) ?? null;
  }

  return workspaces[0] ?? null;
}

function isTenantWorkspace(value: unknown): value is TenantWorkspace {
  if (!value || typeof value !== 'object') return false;
  const workspace = value as Record<string, unknown>;
  return ['tenantId', 'tenantName', 'tenantSlug', 'unitId', 'unitName', 'timezone'].every(
    (key) => typeof workspace[key] === 'string' && workspace[key].trim().length > 0
  ) && typeof workspace.status === 'string';
}

export function parseTenantWorkspaces(data: unknown): TenantWorkspace[] {
  return Array.isArray(data) ? data.filter(isTenantWorkspace) : [];
}
