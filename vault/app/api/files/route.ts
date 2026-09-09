/**
 * /api/files — the encrypted metadata index.
 *
 * GET    list the caller's files (ciphertext metadata; the browser decrypts)
 * POST   record a file after its ciphertext has landed in R2
 * DELETE remove a file row and then its R2 object
 *
 * Everything stored here that could identify a document is encrypted
 * client-side. What is in the clear is only what quota enforcement and
 * ownership need: a user id, a byte count, timestamps.
 */

import { NextResponse } from 'next/server';
import { serverClient } from '@/lib/supabase-server';
import { deleteObject, STORAGE_QUOTA_BYTES } from '@/lib/storage';
import { checkRateLimit } from '@/lib/rate-limit';

export const runtime = 'nodejs';
export const dynamic = 'force-dynamic';

export async function GET() {
  const supabase = await serverClient();

  const {
    data: { user },
    error: authError,
  } = await supabase.auth.getUser();

  if (authError || !user) {
    return NextResponse.json({ error: 'Not authenticated' }, { status: 401 });
  }

  // RLS scopes this to the caller. The whole index is returned in one request:
  // for a personal vault of a few thousand files the ciphertext metadata is
  // small enough to decrypt in memory, which is what makes client-side search
  // viable without ever giving the server plaintext.
  const { data, error } = await supabase
    .from('files')
    .select('id, object_key, encrypted_metadata, encrypted_manifest, size_bytes, created_at, updated_at')
    .order('created_at', { ascending: false });

  if (error) {
    return NextResponse.json({ error: 'Failed to list files' }, { status: 500 });
  }

  const { data: usedBytes } = await supabase.rpc('user_storage_bytes');

  return NextResponse.json(
    {
      files: data ?? [],
      quota: { used: typeof usedBytes === 'number' ? usedBytes : 0, limit: STORAGE_QUOTA_BYTES },
    },
    { headers: { 'Cache-Control': 'no-store' } },
  );
}

interface CreateFileBody {
  objectKey?: unknown;
  encryptedMetadata?: unknown;
  encryptedManifest?: unknown;
  filenameHash?: unknown;
  sizeBytes?: unknown;
}

export async function POST(request: Request) {
  const supabase = await serverClient();

  const {
    data: { user },
    error: authError,
  } = await supabase.auth.getUser();

  if (authError || !user) {
    return NextResponse.json({ error: 'Not authenticated' }, { status: 401 });
  }

  const limit = checkRateLimit(`files-post:${user.id}`, 60, 60_000);
  if (!limit.allowed) {
    return NextResponse.json(
      { error: 'Too many requests' },
      { status: 429, headers: { 'Retry-After': String(limit.retryAfterSeconds) } },
    );
  }

  let body: CreateFileBody;
  try {
    body = (await request.json()) as CreateFileBody;
  } catch {
    return NextResponse.json({ error: 'Invalid JSON body' }, { status: 400 });
  }

  const { objectKey, encryptedMetadata, encryptedManifest, filenameHash, sizeBytes } = body;

  if (typeof objectKey !== 'string' || !objectKey.startsWith(`${user.id}/`)) {
    return NextResponse.json(
      { error: 'objectKey must be within the user namespace' },
      { status: 403 },
    );
  }
  if (typeof encryptedMetadata !== 'string' || !encryptedMetadata) {
    return NextResponse.json({ error: 'encryptedMetadata is required' }, { status: 400 });
  }
  if (typeof encryptedManifest !== 'string' || !encryptedManifest) {
    return NextResponse.json({ error: 'encryptedManifest is required' }, { status: 400 });
  }
  if (typeof sizeBytes !== 'number' || !Number.isFinite(sizeBytes) || sizeBytes < 0) {
    return NextResponse.json({ error: 'sizeBytes must be a non-negative number' }, { status: 400 });
  }

  const { data, error } = await supabase
    .from('files')
    .insert({
      user_id: user.id,
      object_key: objectKey,
      encrypted_metadata: encryptedMetadata,
      encrypted_manifest: encryptedManifest,
      filename_hash: typeof filenameHash === 'string' ? filenameHash : null,
      size_bytes: sizeBytes,
    })
    .select('id, object_key, created_at')
    .single();

  if (error) {
    // The unique constraint on object_key makes a retry idempotent-ish rather
    // than producing a duplicate row.
    const status = error.code === '23505' ? 409 : 500;
    return NextResponse.json({ error: 'Failed to record file' }, { status });
  }

  return NextResponse.json({ file: data }, { status: 201 });
}

export async function DELETE(request: Request) {
  const supabase = await serverClient();

  const {
    data: { user },
    error: authError,
  } = await supabase.auth.getUser();

  if (authError || !user) {
    return NextResponse.json({ error: 'Not authenticated' }, { status: 401 });
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

  // Delete the row first. RLS ensures only the owner's row can match, so a
  // zero-row result means the caller does not own it.
  const { data: deleted, error } = await supabase
    .from('files')
    .delete()
    .eq('object_key', objectKey)
    .select('id');

  if (error) {
    return NextResponse.json({ error: 'Failed to delete file record' }, { status: 500 });
  }
  if (!deleted || deleted.length === 0) {
    return NextResponse.json({ error: 'File not found' }, { status: 404 });
  }

  // Then the blob. Row first, blob second, on purpose: a failure here leaves an
  // orphaned object that costs a little quota, whereas the reverse order would
  // leave a row pointing at nothing, which shows up as a broken file.
  try {
    await deleteObject(objectKey, user.id);
  } catch {
    return NextResponse.json(
      { warning: 'Metadata deleted; the stored object could not be removed and is orphaned' },
      { status: 200 },
    );
  }

  return NextResponse.json({ deleted: true });
}
