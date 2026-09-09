/**
 * In-memory fixed-window rate limiter.
 *
 * Deliberately dependency-free and deliberately simple. This is a single-user
 * personal system; the job is to stop a runaway client or a stolen session from
 * minting presigned URLs in a loop, not to survive a distributed attack.
 *
 * KNOWN LIMITATION, stated rather than hidden: Vercel functions are per-instance
 * and short-lived, so this counter resets when an instance is recycled and is
 * not shared across concurrent instances. It therefore limits a single client
 * effectively but is not a global guarantee. The real protections against abuse
 * are elsewhere and do not depend on this:
 *
 *   - every route requires an authenticated Supabase session
 *   - presigned URLs live 60 seconds and are scoped to one object key
 *   - the R2 quota is checked against the database before any URL is minted
 *   - Vercel Hobby pauses a project that exceeds its limits rather than billing
 *
 * A durable limiter would need Redis or Supabase, which adds a dependency and a
 * round trip to every upload for a threat this system does not face. If the
 * vault ever becomes multi-user, revisit this.
 */

interface Bucket {
  count: number;
  /** Epoch ms when the current window ends. */
  resetAt: number;
}

const buckets = new Map<string, Bucket>();

/** Stop the map growing without bound in a long-lived instance. */
const MAX_TRACKED_KEYS = 10_000;

function sweep(now: number): void {
  for (const [key, bucket] of buckets) {
    if (bucket.resetAt <= now) buckets.delete(key);
  }
}

export interface RateLimitResult {
  allowed: boolean;
  remaining: number;
  retryAfterSeconds: number;
}

/**
 * Consume one unit against `key`.
 *
 * @param key       Identity to limit. Use a user id, not an IP — mobile
 *                  networks share addresses.
 * @param limit     Requests permitted per window.
 * @param windowMs  Window length in milliseconds.
 */
export function checkRateLimit(key: string, limit: number, windowMs: number): RateLimitResult {
  const now = Date.now();

  if (buckets.size > MAX_TRACKED_KEYS) sweep(now);

  const existing = buckets.get(key);

  if (!existing || existing.resetAt <= now) {
    buckets.set(key, { count: 1, resetAt: now + windowMs });
    return { allowed: true, remaining: limit - 1, retryAfterSeconds: 0 };
  }

  if (existing.count >= limit) {
    return {
      allowed: false,
      remaining: 0,
      retryAfterSeconds: Math.max(1, Math.ceil((existing.resetAt - now) / 1000)),
    };
  }

  existing.count += 1;
  return {
    allowed: true,
    remaining: limit - existing.count,
    retryAfterSeconds: 0,
  };
}

/** Test hook. Not used in application code. */
export function resetRateLimits(): void {
  buckets.clear();
}
