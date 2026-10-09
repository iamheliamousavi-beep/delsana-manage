// Service-role Supabase client shared by the Edge Functions.
//
// The client is deliberately untyped (`any`): this repository has no
// `supabase gen types typescript` step, and hand-written table types would
// drift away from setup.sql. The SQL layer is the contract; the queries here
// are all simple `select/insert/update/delete` on known tables.

import { createClient } from 'npm:@supabase/supabase-js@2';

// deno-lint-ignore no-explicit-any
export type Admin = any;

export function createAdminClient(): Admin {
  const url = Deno.env.get('SUPABASE_URL');
  const key = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
  if (!url || !key) throw new Error('SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY are not set');
  // deno-lint-ignore no-explicit-any
  return createClient<any>(url, key, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
}

/**
 * Client that acts as the browser caller: it carries the caller's own access
 * token, so `auth.getUser()` resolves who is calling a JWT-protected function
 * (`send-invoice`, `test-notify`).
 */
export function createUserClient(authorization: string): Admin {
  const url = Deno.env.get('SUPABASE_URL');
  const key = Deno.env.get('SUPABASE_ANON_KEY');
  if (!url || !key) throw new Error('SUPABASE_URL / SUPABASE_ANON_KEY are not set');
  // deno-lint-ignore no-explicit-any
  return createClient<any>(url, key, {
    global: { headers: { Authorization: authorization } },
    auth: { persistSession: false, autoRefreshToken: false },
  });
}
