/**
 * POST /api/presign-upload
 *
 * Authenticates the user, checks the quota, and mints a 60-second presigned PUT.
 * The browser then uploads ciphertext DIRECTLY to R2 — bytes never pass through
 * this function.
 *
 * This route sees: a size, a content type, and a filename hash. It never sees
 * the filename, the file contents, or the encryption key.
 */

import { NextResponse } from 'next/server';
import { serverClient } from '@/lib/supabase-server';
import {
  presignUpload,
  R2_QUOTA_BYTES,
  MAX_SINGLE_UPLOAD_BYTES,
  PRESIGN_TTL_SECONDS,
} from '@/lib/r2';
import { checkRateLimit } from '@/lib/rate-limit';

export const runtime = 'nodejs';
// Never cache a presigned URL: each one is single-purpose and expires in 60s.
export const dynamic = 'force-dynamic';

interface PresignUploadBody {
  objectKey?: unknown;
  size?: unknown;
  filenameHash?: unknown;
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

  // Rate limit per user, not per IP: mobile networks share addresses, and the
  // thing worth limiting is one account minting URLs in a loop.
  const limit = checkRateLimit(`presign-upload:${user.id}`, 60, 60_000);
  if (!limit.allowed) {
    return NextResponse.json(
      { error: 'Too many requests' },
      { status: 429, headers: { 'Retry-After': String(limit.retryAfterSeconds) } },
    );
  }

  let body: PresignUploadBody;
  try {
    body = (await request.json()) as PresignUploadBody;
  } catch {
    return NextResponse.json({ error: 'Invalid JSON body' }, { status: 400 });
  }

  const { objectKey, size } = body;

  if (typeof objectKey !== 'string' || !objectKey) {
    return NextResponse.json({ error: 'objectKey is required' }, { status: 400 });
  }
  if (typeof size !== 'number' || !Number.isFinite(size) || size < 0) {
    return NextResponse.json({ error: 'size must be a non-negative number' }, { status: 400 });
  }
  if (size > MAX_SINGLE_UPLOAD_BYTES) {
    return NextResponse.json(
      {
        error: `Single upload limit is ${MAX_SINGLE_UPLOAD_BYTES} bytes; use multipart above this`,
      },
      { status: 413 },
    );
  }

  // Quota check. user_storage_bytes() is a security-definer function pinned to
  // auth.uid(), so it cannot be used to read another user's total.
  const { data: usedBytes, error: quotaError } = await supabase.rpc('user_storage_bytes');

  if (quotaError) {
    return NextResponse.json({ error: 'Could not verify storage quota' }, { status: 500 });
  }

  const currentlyUsed = typeof usedBytes === 'number' ? usedBytes : 0;
  if (currentlyUsed + size > R2_QUOTA_BYTES) {
    return NextResponse.json(
      {
        error: 'Storage quota exceeded',
        used: currentlyUsed,
        limit: R2_QUOTA_BYTES,
        requested: size,
      },
      { status: 507 },
    );
  }

  try {
    // presignUpload re-validates that the key sits inside this user's namespace,
    // so a forged objectKey cannot target another user's object.
    const url = await presignUpload(objectKey, user.id, size);

    return NextResponse.json(
      { url, objectKey, expiresIn: PRESIGN_TTL_SECONDS },
      { headers: { 'Cache-Control': 'no-store' } },
    );
  } catch (err) {
    const message = err instanceof Error ? err.message : 'Failed to create upload URL';
    // Ownership violations are a client error, not a server fault.
    const status = message.includes('outside the user namespace') ? 403 : 500;
    return NextResponse.json({ error: message }, { status });
  }
}
