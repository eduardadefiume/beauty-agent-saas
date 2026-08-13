export type TenantWorkspace = {
  tenantId: string;
  tenantName: string;
  tenantSlug: string;
  unitId: string;
  unitName: string;
  timezone: string;
  status: string;
};

type SupabaseRpcClient = {
  auth: { getUser: () => Promise<{ data: { user: { email?: string | null } | null } }> };
  rpc: (name: string, args: Record<string, string>) => PromiseLike<{ data: unknown; error: { message: string } | null }>;
};

const SITE_PROJECT_ID = process.env.SITE_PROJECT_ID ?? 'owner-console-v1';

export function selectTenantWorkspace(
  workspaces: TenantWorkspace[],
  requestedTenantId: string | null
): TenantWorkspace | null {
  if (workspaces.length === 0) return null;
  return workspaces.find((workspace) => workspace.tenantId === requestedTenantId) ?? workspaces[0] ?? null;
}

function isTenantWorkspace(value: unknown): value is TenantWorkspace {
  if (!value || typeof value !== 'object') return false;
  const workspace = value as Record<string, unknown>;
  return ['tenantId', 'tenantName', 'tenantSlug', 'unitId', 'unitName', 'timezone'].every(
    (key) => typeof workspace[key] === 'string' && workspace[key].trim().length > 0
  ) && typeof workspace.status === 'string';
}

export async function resolveDashboardTenantContext(
  supabase: SupabaseRpcClient,
  requestedTenantId: string | null
): Promise<{ userEmail: string; workspaces: TenantWorkspace[]; activeWorkspace: TenantWorkspace | null }> {
  const {
    data: { user },
  } = await supabase.auth.getUser();

  const userEmail = user?.email?.trim().toLowerCase();
  if (!userEmail) throw new Error('AUTHENTICATION_REQUIRED');

  const { data, error } = await supabase.rpc('site_list_tenants', {
    target_site_project_id: SITE_PROJECT_ID,
    target_email: userEmail,
  });

  if (error) throw new Error('TENANT_CONTEXT_UNAVAILABLE');

  const workspaces = Array.isArray(data) ? data.filter(isTenantWorkspace) : [];
  return {
    userEmail,
    workspaces,
    activeWorkspace: selectTenantWorkspace(workspaces, requestedTenantId),
  };
}
