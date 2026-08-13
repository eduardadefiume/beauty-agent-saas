import { describe, expect, it } from 'vitest';
import {
  parseTenantWorkspaces,
  selectTenantWorkspace,
  type TenantWorkspace,
} from './dashboard-tenant-context';

const workspaces: TenantWorkspace[] = [
  {
    tenantId: 'tenant-a',
    tenantName: 'Studio A',
    tenantSlug: 'studio-a',
    unitId: 'unit-a',
    unitName: 'Unidade A',
    timezone: 'America/Sao_Paulo',
    status: 'DRAFT',
  },
  {
    tenantId: 'tenant-b',
    tenantName: 'Salao B',
    tenantSlug: 'salao-b',
    unitId: 'unit-b',
    unitName: 'Unidade B',
    timezone: 'America/Sao_Paulo',
    status: 'PUBLISHED',
  },
];

describe('selectTenantWorkspace', () => {
  it('seleciona somente o tenant explicitamente solicitado', () => {
    expect(selectTenantWorkspace(workspaces, 'tenant-b')?.tenantName).toBe('Salao B');
  });

  it('não usa dados de outro tenant como fallback quando há tenant explícito', () => {
    expect(selectTenantWorkspace(workspaces, 'tenant-inexistente')).toBeNull();
    expect(selectTenantWorkspace([], 'tenant-a')).toBeNull();
  });

  it('aceita somente registros de workspace completos retornados pelo gateway', () => {
    const items = parseTenantWorkspaces([...workspaces, { tenantId: 'incompleto', tenantName: 'Sem unidade' }]);
    expect(items).toEqual(workspaces);
  });
});
