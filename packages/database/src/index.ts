import { createClient, type SupabaseClient } from '@supabase/supabase-js';

export interface UserDatabaseClientOptions {
  readonly url: string;
  readonly publishableKey: string;
  readonly accessToken: string;
}

export function createUserDatabaseClient(options: UserDatabaseClientOptions): SupabaseClient {
  return createClient(options.url, options.publishableKey, {
    accessToken: async () => options.accessToken,
    auth: { persistSession: false, autoRefreshToken: false },
  });
}
