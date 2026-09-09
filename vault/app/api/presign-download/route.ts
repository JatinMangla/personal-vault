/**
 * POST /api/presign-download
 *
 * Mints a 60-second signed GET. The browser fetches ciphertext directly from
 * Supabase Storage and decrypts it locally — bytes never pass through this
 * function.
 *
 * Ownership is checked twice: once against the database row (RLS scopes the
 * query to the caller) and once against the object key namespace inside
 * presignDownload. Either alone would be sufficient; both is cheap.
 */

import { NextResponse } from 'next/server';
import { serverClient } from '@/lib/supabase-server';
import { createSignedDownload, SIGNED_DOWNLOAD_TTL_SECONDS } from '@/lib/storage';
import { checkRateLimit } from '@/lib/rate-limit';

export const runtime = 'nodejs';
export const dynamic = 'force-dynamic';

export async function POST(request: Request) {
  const supabase = await serverClient();

  const {
    data: { user },
    error: authError,
  } = await supabase.auth.getUser();

  if (authError || !user) {
    return NextResponse.json({ error: 'Not authenticated' }, { status: 401 });
  }

  const limit = checkRateLimit(`presign-download:${user.id}`, 120, 60_000);
  if (!limit.allowed) {
    return NextResponse.json(
      { error: 'Too many requests' },
      { status: 429, headers: { 'Retry-After': String(limit.retryAfterSeconds) } },
    );
  }

  let objectKey: unknown;
  try {
    ({ objectKey } = (await request.json()) as { objectKey?: unknown });
  } catch {
    return NextResponse.json({ error: 'Invalid JSON body' }, { status: 400 });
  }

  if (typeof objectKey !== 'string' || !objectKey) {
    return NextResponse.json({ error: 'objectKey is required' }, { status: 400 });
  }

  // RLS restricts this query to the caller's rows, so a key belonging to
  // someone else simply returns nothing.
  const { data: row, error: lookupError } = await supabase
    .from('files')
    .select('object_key')
    .eq('object_key', objectKey)
    .maybeSingle();

  if (lookupError) {
    return NextResponse.json({ error: 'Lookup failed' }, { status: 500 });
  }
  if (!row) {
    // 404 rather than 403: do not confirm that an object key exists for
    // somebody else.
    return NextResponse.json({ error: 'File not found' }, { status: 404 });
  }

  try {
    const url = await createSignedDownload(objectKey, user.id);
    return NextResponse.json(
      { url, expiresIn: SIGNED_DOWNLOAD_TTL_SECONDS },
      { headers: { 'Cache-Control': 'no-store' } },
    );
  } catch (err) {
    const message = err instanceof Error ? err.message : 'Failed to create download URL';
    const status = message.includes('outside the user namespace') ? 403 : 500;
    return NextResponse.json({ error: message }, { status });
  }
}
