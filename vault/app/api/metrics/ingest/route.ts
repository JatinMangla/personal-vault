/**
 * POST /api/metrics/ingest — Component D.
 *
 * Receives metrics pushed outbound from the Oracle VM. The box has no inbound
 * ports and must keep it that way, so it pushes here rather than being polled.
 *
 * THIS IS A WRITE-ONLY ENDPOINT. It must never return stored data. A successful
 * response says "accepted" and nothing more; anyone who obtains the shared
 * secret can write a sample, and must not thereby gain a way to read the
 * archive back.
 *
 * Authentication is HMAC-SHA256 over the exact raw body, with a timestamp
 * inside the signed payload. Anything older than 5 minutes is rejected, so a
 * captured request cannot be replayed later.
 */

import { NextResponse } from 'next/server';
import { createHmac, timingSafeEqual } from 'node:crypto';
import { serviceClient } from '@/lib/supabase-server';
import type { MetricsPayload } from '@/lib/supabase-types';
import { checkRateLimit } from '@/lib/rate-limit';

export const runtime = 'nodejs';
export const dynamic = 'force-dynamic';

/** Reject anything signed more than this long ago. */
const MAX_SKEW_SECONDS = 300;

/**
 * Constant-time comparison of two hex digests.
 *
 * A plain `===` on a signature leaks its correct prefix through timing, which
 * lets an attacker recover it byte by byte.
 */
function signaturesMatch(expected: string, received: string): boolean {
  const a = Buffer.from(expected, 'hex');
  const b = Buffer.from(received, 'hex');
  // timingSafeEqual throws on a length mismatch, so check length first — that
  // comparison leaks only the length, which is fixed and public anyway.
  if (a.length !== b.length || a.length === 0) return false;
  return timingSafeEqual(a, b);
}

export async function POST(request: Request) {
  const secret = process.env.METRICS_INGEST_SECRET;
  if (!secret) {
    // Never fall back to accepting unsigned data.
    return NextResponse.json({ error: 'Ingest is not configured' }, { status: 503 });
  }

  // Loose limit keyed to the route: the legitimate collector sends 4 requests
  // an hour, so this only bites on a flood.
  const limit = checkRateLimit('metrics-ingest', 60, 60_000);
  if (!limit.allowed) {
    return NextResponse.json(
      { error: 'Too many requests' },
      { status: 429, headers: { 'Retry-After': String(limit.retryAfterSeconds) } },
    );
  }

  // Read the RAW body. The signature covers exactly these bytes, so parsing
  // first and re-serialising would change them and break verification.
  const rawBody = await request.text();

  const signatureHeader = request.headers.get('x-signature') ?? '';
  const received = signatureHeader.startsWith('sha256=')
    ? signatureHeader.slice('sha256='.length)
    : signatureHeader;

  if (!received) {
    return NextResponse.json({ error: 'Missing signature' }, { status: 401 });
  }

  const expected = createHmac('sha256', secret).update(rawBody).digest('hex');
  if (!signaturesMatch(expected, received)) {
    return NextResponse.json({ error: 'Invalid signature' }, { status: 401 });
  }

  let payload: MetricsPayload;
  try {
    payload = JSON.parse(rawBody) as MetricsPayload;
  } catch {
    return NextResponse.json({ error: 'Invalid JSON body' }, { status: 400 });
  }

  // Replay protection. The timestamp is inside the signed body, so it cannot be
  // altered without invalidating the signature.
  const timestamp = Number(payload.timestamp);
  if (!Number.isFinite(timestamp)) {
    return NextResponse.json({ error: 'Missing timestamp' }, { status: 400 });
  }

  const skew = Math.abs(Math.floor(Date.now() / 1000) - timestamp);
  if (skew > MAX_SKEW_SECONDS) {
    return NextResponse.json(
      { error: 'Timestamp outside the accepted window' },
      { status: 401 },
    );
  }

  if (!payload.storage || !payload.system) {
    return NextResponse.json({ error: 'Malformed metrics payload' }, { status: 400 });
  }

  // Service role, because this row belongs to no user and the collector has no
  // Supabase session. RLS grants no insert to anyone else, so a browser holding
  // the anon key cannot forge a sample.
  const supabase = serviceClient();

  const { error } = await supabase.from('metrics_samples').insert({
    collected_at: payload.collected_at ?? new Date(timestamp * 1000).toISOString(),
    host: payload.host ?? 'unknown',
    payload,
  });

  if (error) {
    return NextResponse.json({ error: 'Failed to store sample' }, { status: 500 });
  }

  // Deliberately minimal. No stored data, no row count, no ids.
  return NextResponse.json({ accepted: true }, { status: 201 });
}

/**
 * Anything other than POST is rejected explicitly, so a stray GET cannot be
 * mistaken for a read API on a write-only endpoint.
 */
export async function GET() {
  return NextResponse.json({ error: 'Method not allowed' }, { status: 405 });
}
