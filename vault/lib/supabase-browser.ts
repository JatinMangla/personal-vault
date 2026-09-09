/**
 * Browser Supabase client.
 *
 * Safe to import from client components. Uses the anon key, so Row Level
 * Security applies to everything it does — which is exactly why every table in
 * the schema must have RLS enabled and real policies.
 *
 * Deliberately separate from supabase-server.ts: that module imports
 * `next/headers`, which cannot exist in a client bundle. Keeping them apart
 * makes the client/server boundary a build error rather than a review item.
 */

import { createBrowserClient } from '@supabase/ssr';

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

export function browserClient() {
  return createBrowserClient(publicUrl(), anonKey());
}
