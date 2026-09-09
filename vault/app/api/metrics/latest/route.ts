/**
 * GET /api/metrics/latest — the dashboard's read side.
 *
 * Returns the most recent sample plus a 30-day history for the growth
 * projection. Requires an authenticated session; RLS on metrics_samples grants
 * select to authenticated users only.
 */

import { NextResponse } from 'next/server';
import { serverClient } from '@/lib/supabase-server';
import type { MetricsSampleRow } from '@/lib/supabase-types';

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

  const { data: latest, error: latestError } = await supabase
    .from('metrics_samples')
    .select('id, collected_at, host, payload')
    .order('collected_at', { ascending: false })
    .limit(1)
    .maybeSingle();

  if (latestError) {
    return NextResponse.json({ error: 'Failed to read metrics' }, { status: 500 });
  }

  // History for the projection. One row per ~6 hours over 30 days is plenty for
  // a linear fit and keeps the response small on a phone connection; fetching
  // all ~2,900 samples would be wasteful.
  const thirtyDaysAgo = new Date(Date.now() - 30 * 24 * 60 * 60 * 1000).toISOString();

  const { data: history } = await supabase
    .from('metrics_samples')
    .select('collected_at, payload')
    .gte('collected_at', thirtyDaysAgo)
    .order('collected_at', { ascending: true })
    .limit(2000);

  // Reduce to what the projection actually needs, rather than shipping whole
  // payloads for every historical point.
  const series = (history ?? []).map((row) => {
    const r = row as Pick<MetricsSampleRow, 'collected_at' | 'payload'>;
    return {
      t: new Date(r.collected_at).getTime(),
      blockUsed: r.payload?.storage?.block_used ?? 0,
      repoBytes: r.payload?.backup?.repo_bytes ?? 0,
    };
  });

  // Thin to roughly 120 points, evenly spaced.
  const step = Math.max(1, Math.ceil(series.length / 120));
  const thinned = series.filter((_, i) => i % step === 0);

  return NextResponse.json(
    {
      latest: latest ?? null,
      // Explicit rather than implied by `latest === null`: the UI must
      // distinguish "collector never ran" from "collector stopped".
      hasData: Boolean(latest),
      series: thinned,
      serverTime: Date.now(),
    },
    { headers: { 'Cache-Control': 'no-store' } },
  );
}
