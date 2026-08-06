import { readFile } from 'node:fs/promises';
import { describe, expect, it } from 'vitest';

async function read(relativePath: string): Promise<string> {
  return readFile(new URL(relativePath, import.meta.url), 'utf8');
}

describe('owner console — auth boundary', () => {
  it('the home page requires a real Supabase session and redirects otherwise', async () => {
    const source = await read('./page.tsx');
    expect(source).toMatch(/auth\.getUser\(\)/);
    expect(source).toMatch(/redirect\(['"]\/login['"]\)/);
  });

  it('the configuration API verifies the session before calling the Edge Function', async () => {
    const source = await read('./api/configuration/route.ts');
    expect(source).toMatch(/auth\.getSession\(\)/);
    expect(source).toMatch(/AUTHENTICATION_REQUIRED/);
    expect(source).toMatch(/authorization.*Bearer.*access_token/s);
    // No leftover trust in a client-supplied identity or a static shared secret —
    // both were the old ChatGPT Sites trust model this app replaces.
    expect(source).not.toMatch(/userEmail|SITE_CONFIGURATOR_TOKEN|oai-authenticated/);
  });

  it('the configurator UI talks only to the real backend, no demo state', async () => {
    const source = await read('./configurator-real.tsx');
    for (const capability of [
      'operatingHours',
      'teamMembers',
      'resourceTypes',
      'variations',
      'steps',
      'readiness',
      'publish',
    ]) {
      expect(source).toMatch(new RegExp(capability));
    }
    expect(source).toMatch(/fetch\("\/api\/configuration"/);
    expect(source).not.toMatch(
      /localStorage|sessionStorage|signin-with-chatgpt|signout-with-chatgpt/
    );
  });

  it('the login page uses passwordless magic-link sign-in, not a password field', async () => {
    const source = await read('./login/page.tsx');
    expect(source).toMatch(/signInWithOtp/);
    expect(source).not.toMatch(/type=["']password["']/);
  });
});
