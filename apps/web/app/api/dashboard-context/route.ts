import { type NextRequest, NextResponse } from 'next/server';
import {
  parseTenantWorkspaces,
  selectTenantWorkspace,
} from '../../../lib/dashboard-tenant-context';
import { createSupabaseServerClient } from '../../../lib/supabase/server';

export const dynamic = 'force-dynamic';

const NO_STORE_HEADERS = { 'Cache-Control': 'no-store' };

function errorResponse(status: number, error: string) {
  return NextResponse.json({ error }, { status, headers: NO_STORE_HEADERS });
}

function gatewayData(body: unknown): unknown {
  if (!body || typeof body !== 'object' || !('data' in body)) return null;
  return (body as { data: unknown }).data;
}

function gatewayError(body: unknown): string {
  if (!body || typeof body !== 'object' || typeof (body as { error?: unknown }).error !== 'string') {
    return 'TENANT_CONTEXT_UNAVAILABLE';
  }
  return (body as { error: string }).error;
}

export async function GET(request: NextRequest) {
  const requestedTenantId = request.nextUrl.searchParams.get('tenantId');

  try {
    const supabase = await createSupabaseServerClient();
    const {
      data: { session },
    } = await supabase.auth.getSession();

    if (!session?.access_token) return errorResponse(401, 'AUTHENTICATION_REQUIRED');

    const endpoint = process.env.SUPABASE_CONFIGURATOR_URL;
    if (!endpoint) return errorResponse(503, 'CONFIGURATOR_NOT_AVAILABLE');

    const upstream = await fetch(endpoint, {
      method: 'POST',
      headers: {
        'content-type': 'application/json',
        authorization: `Bearer ${session.access_token}`,
      },
      body: JSON.stringify({ action: 'list' }),
      cache: 'no-store',
    });
    const body: unknown = await upstream.json().catch(() => null);

    if (!upstream.ok) {
      const status = upstream.status === 401 || upstream.status === 403 ? upstream.status : 503;
      return errorResponse(status, gatewayError(body));
    }

    const workspaces = parseTenantWorkspaces(gatewayData(body));
    const activeWorkspace = selectTenantWorkspace(workspaces, requestedTenantId);
    if (!activeWorkspace) {
      return NextResponse.json(
        { error: 'TENANT_NOT_AVAILABLE', workspaces: [] },
        { status: 404, headers: NO_STORE_HEADERS }
      );
    }

    return NextResponse.json({ workspaces, activeWorkspace }, { headers: NO_STORE_HEADERS });
  } catch {
    return errorResponse(503, 'TENANT_CONTEXT_UNAVAILABLE');
  }
}
