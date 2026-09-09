/**
 * Server-side Supabase clients. SERVER ONLY.
 *
 * Two clients, kept distinct because confusing them is how RLS gets bypassed
 * by accident:
 *
 *   serverClient()  — anon key + the request's cookies; RLS applies as the user
 *   serviceClient() — service role key; BYPASSES RLS ENTIRELY
 *
 * The `server-only` import makes importing this from a client component a build
 * error rather than a silent credential leak.
 */

import 'server-only';

import { createServerClient } from '@supabase/ssr';
import { createClient } from '@supabase/supabase-js';
import { cookies } from 'next/headers';

function publicUrl(): string {
  const url = process.env.NEXT_PUBLIC_SUPABASE_URL;
  if (!url) throw new Error('Missing NEXT_PUBLIC_SUPABASE_URL');
  return url;
}

function anonKey(): string {
  const key = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY;
  if (!key) throw new Error('Missing NEXT_PUBLIC_SUPABASE_ANON_KEY');
  return key;
}

/**
 * Bound to the request's cookies, so queries run as the signed-in user and RLS
 * applies to them.
 */
export async function serverClient() {
  const cookieStore = await cookies();

  return createServerClient(publicUrl(), anonKey(), {
    cookies: {
      getAll() {
        return cookieStore.getAll();
      },
      setAll(cookiesToSet) {
        try {
          for (const { name, value, options } of cookiesToSet) {
            cookieStore.set(name, value, options);
          }
        } catch {
          // Called from a Server Component, where cookies are read-only.
          // Middleware refreshes the session instead, so this is safe to ignore.
        }
      },
    },
  });
}

/**
 * Service-role client. **BYPASSES ROW LEVEL SECURITY.**
 *
 * Used in exactly one place: /api/metrics/ingest, which authenticates by HMAC
 * rather than a user session and must write a row that no user owns.
 *
 * Never use this to serve user-scoped data — doing so silently disables every
 * access control in the database.
 */
export function serviceClient() {
  const key = process.env.SUPABASE_SERVICE_ROLE_KEY;
  if (!key) throw new Error('Missing SUPABASE_SERVICE_ROLE_KEY');

  return createClient(publicUrl(), key, {
    auth: { autoRefreshToken: false, persistSession: false },
  });
}
