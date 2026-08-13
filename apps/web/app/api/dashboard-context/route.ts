import { type NextRequest, NextResponse } from 'next/server';
import { resolveDashboardTenantContext } from '../../../lib/dashboard-tenant-context';
import { createSupabaseServerClient } from '../../../lib/supabase/server';

export const dynamic = 'force-dynamic';

export async function GET(request: NextRequest) {
  const requestedTenantId = request.nextUrl.searchParams.get('tenantId');

  try {
    const supabase = await createSupabaseServerClient();
    const context = await resolveDashboardTenantContext(supabase, requestedTenantId);

    if (!context.activeWorkspace) {
      return NextResponse.json(
        { error: 'TENANT_NOT_AVAILABLE', workspaces: [] },
        { status: 404, headers: { 'Cache-Control': 'no-store' } }
      );
    }

    return NextResponse.json(context, { headers: { 'Cache-Control': 'no-store' } });
  } catch (error) {
    const code = error instanceof Error ? error.message : 'DASHBOARD_CONTEXT_UNAVAILABLE';
    const status = code === 'AUTHENTICATION_REQUIRED' ? 401 : 503;
    return NextResponse.json({ error: code }, { status, headers: { 'Cache-Control': 'no-store' } });
  }
}
