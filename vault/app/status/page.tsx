'use client';

/**
 * /status — Component D, the storage and health dashboard.
 *
 * Layout order is deliberate: the overall pill answers the only question that
 * matters at a glance on a phone, then storage, backup health, vault usage,
 * system, the free-tier ledger, and the projection.
 *
 * The staleness banner is the most important element on the page. A dashboard
 * that looks green because it is frozen is worse than no dashboard, so if the
 * collector stops reporting, that fact outranks every number below it.
 */

import { useCallback, useEffect, useState } from 'react';
import {
  LIMITS,
  backupAgeState,
  containerState,
  failedJobsState,
  formatBytes,
  formatDuration,
  formatRelative,
  integrityState,
  overallLabel,
  percentState,
  projectGrowth,
  restoreDrillState,
  stalenessState,
  worstState,
  type HealthState,
} from '@/lib/thresholds';
import type { MetricsPayload } from '@/lib/supabase-types';
import { StorageGauge } from '@/components/StorageGauge';
import { ContainerDots, HealthCard, LimitMeter, StatRow, StatusPill } from '@/components/HealthCard';

interface LatestResponse {
  latest: { collected_at: string; host: string; payload: MetricsPayload } | null;
  hasData: boolean;
  series: Array<{ t: number; blockUsed: number; repoBytes: number }>;
  serverTime: number;
}

export default function StatusPage() {
  const [data, setData] = useState<LatestResponse | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [loading, setLoading] = useState(true);

  const load = useCallback(async () => {
    try {
      const res = await fetch('/api/metrics/latest', { cache: 'no-store' });
      if (res.status === 401) {
        setError('Sign in to view the dashboard.');
        return;
      }
      if (!res.ok) throw new Error(`Request failed: ${res.status}`);
      setData((await res.json()) as LatestResponse);
      setError(null);
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Could not load metrics');
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    void load();
    // Refresh at half the collection interval so the page is never more than
    // one cycle behind what the server knows.
    const id = setInterval(() => void load(), 7 * 60 * 1000);
    return () => clearInterval(id);
  }, [load]);

  if (loading) {
    return (
      <>
        <h1>System status</h1>
        <p className="muted">Loading…</p>
      </>
    );
  }

  if (error) {
    return (
      <>
        <h1>System status</h1>
        <div className="banner banner-red" role="alert">{error}</div>
      </>
    );
  }

  // No sample has ever arrived. Distinct from "the collector stopped", and the
  // fix is different, so say so plainly.
  if (!data?.latest) {
    return (
      <>
        <h1>System status</h1>
        <div className="banner banner-red" role="alert">
          No metrics have ever been received. Check that <code>metrics-push.timer</code> is
          enabled on the Oracle VM and that <code>METRICS_INGEST_URL</code> and
          <code> METRICS_INGEST_SECRET</code> match on both ends.
        </div>
      </>
    );
  }

  const { payload } = data.latest;
  const lastSampleMs = new Date(data.latest.collected_at).getTime();
  const staleness = stalenessState(lastSampleMs);

  // --- Individual states ---------------------------------------------------

  const blockState = percentState('blockVolume', payload.storage.block_used, payload.storage.block_total);
  const bootState = percentState('bootVolume', payload.storage.boot_used, payload.storage.boot_total);
  const ramState = percentState('ram', payload.system.mem_used, payload.system.mem_total);
  const gozungaState = percentState('gozunga', payload.backup.repo_bytes, LIMITS.gozungaBytes);

  const backupState = backupAgeState(payload.backup.last_backup_ts * 1000);
  const drillState = restoreDrillState(payload.backup.last_drill_ts * 1000);
  const jobsState = failedJobsState(payload.immich.failed_jobs);
  const checkState = integrityState(payload.backup.last_check_status);

  const containers = [
    { name: 'server', status: payload.containers.server, state: containerState(payload.containers.server) },
    { name: 'ML', status: payload.containers.machine_learning, state: containerState(payload.containers.machine_learning) },
    { name: 'redis', status: payload.containers.redis, state: containerState(payload.containers.redis) },
    { name: 'postgres', status: payload.containers.database, state: containerState(payload.containers.database) },
  ];

  // Worst individual state wins, so one glance answers the question.
  const overall = worstState([
    staleness,
    blockState,
    bootState,
    ramState,
    gozungaState,
    backupState,
    drillState,
    jobsState,
    checkState,
    ...containers.map((c) => c.state),
  ]);

  // --- Projection ----------------------------------------------------------

  const projection = projectGrowth(
    (data.series ?? []).map((s) => ({ t: s.t, bytes: s.blockUsed })),
    LIMITS.blockVolumeBytes,
  );

  return (
    <>
      <div className="row between wrap gap-05">
        <h1 className="m-0">System status</h1>
        <StatusPill state={overall} label={overallLabel(overall)} />
      </div>

      {/*
        Staleness outranks everything. If the collector has stopped, every number
        below is a historical artefact and must not be read as current.
      */}
      {staleness !== 'green' && (
        <div
          className={`banner mt-1 banner-${staleness === 'red' ? 'red' : 'amber'}`}
          role="alert"
        >
          <strong>
            {staleness === 'red' ? 'Metrics are stale.' : 'Metrics are lagging.'}
          </strong>{' '}
          Last sample {formatRelative(lastSampleMs)}. The figures below are from that
          time and may not reflect the current state of the system.
        </div>
      )}

      <p className="faint mt-075">
        {payload.host} · updated {formatRelative(lastSampleMs)}
      </p>

      {/* 1. Media storage */}
      <HealthCard title="Media storage" state={blockState}>
        <StorageGauge
          used={payload.storage.block_used}
          total={payload.storage.block_total || LIMITS.blockVolumeBytes}
          state={blockState}
          label="Media volume"
          segments={[
            { label: 'Originals', bytes: payload.storage.originals_bytes, color: 'var(--accent)' },
            { label: 'Thumbnails', bytes: payload.storage.thumbs_bytes, color: 'var(--green)' },
            { label: 'Encoded video', bytes: payload.storage.encoded_video_bytes, color: 'var(--amber)' },
            { label: 'DB backups', bytes: payload.storage.backups_bytes, color: 'var(--text-faint)' },
          ]}
        />
        <div className="mt-1">
          <StatRow label="Photos" value={payload.immich.photo_count.toLocaleString()} />
          <StatRow label="Videos" value={payload.immich.video_count.toLocaleString()} />
          <StatRow label="Photo data" value={formatBytes(payload.immich.usage_photos)} />
          <StatRow label="Video data" value={formatBytes(payload.immich.usage_videos)} />
          <StatRow
            label="Failed Immich jobs"
            value={payload.immich.failed_jobs}
            state={jobsState}
          />
        </div>
      </HealthCard>

      {/* 2. Backup health */}
      <HealthCard title="Backup health" state={worstState([backupState, drillState, checkState])}>
        <StatRow
          label="Last successful backup"
          value={formatRelative(payload.backup.last_backup_ts * 1000)}
          state={backupState}
        />
        <StatRow label="Snapshots" value={payload.backup.snapshot_count} />
        <StatRow
          label="Last integrity check"
          value={payload.backup.last_check_status}
          state={checkState}
        />
        <StatRow
          label="Last restore drill"
          value={
            payload.backup.last_drill_ts
              ? `${payload.backup.last_drill_result} · ${formatRelative(payload.backup.last_drill_ts * 1000)}`
              : 'never run'
          }
          state={drillState}
        />
        <div className="mt-075">
          <LimitMeter
            label="Gozunga repository"
            used={payload.backup.repo_bytes}
            limit={LIMITS.gozungaBytes}
            state={gozungaState}
          />
        </div>
        {drillState === 'red' && (
          <p className="faint">
            A backup that has never been restored is a hypothesis. Run{' '}
            <code>ops/backup/restore-test.sh</code>.
          </p>
        )}
      </HealthCard>

      {/* 4. System */}
      <HealthCard title="System" state={worstState([ramState, bootState, ...containers.map((c) => c.state)])}>
        <LimitMeter
          label="RAM"
          used={payload.system.mem_used}
          limit={payload.system.mem_total || LIMITS.ramBytes}
          state={ramState}
        />
        <LimitMeter
          label="Boot volume"
          used={payload.storage.boot_used}
          limit={payload.storage.boot_total}
          state={bootState}
        />
        <StatRow
          label="Load (1 / 5 / 15 min)"
          value={`${payload.system.load1} / ${payload.system.load5} / ${payload.system.load15}`}
        />
        <StatRow label="Swap used" value={formatBytes(payload.system.swap_used)} />
        <StatRow label="Uptime" value={formatDuration(payload.system.uptime_seconds)} />
        <div className="mt-075">
          <h3>Containers</h3>
          <ContainerDots containers={containers} />
        </div>
      </HealthCard>

      {/* 5. Free-tier ledger — cards, never a table. See note below. */}
      <FreeTierLedger payload={payload} blockState={blockState} gozungaState={gozungaState} />

      {/* 6. Projection */}
      <HealthCard title="Projection">
        {projection && projection.daysUntilFull !== null ? (
          <>
            <p>
              At the current rate, media storage fills in approximately{' '}
              <strong>{projection.daysUntilFull.toLocaleString()} days</strong>.
            </p>
            <StatRow label="Growth" value={`${formatBytes(projection.bytesPerMonth)} / month`} />
          </>
        ) : projection ? (
          <p className="muted">
            Media storage is not growing measurably over the last 30 days.
          </p>
        ) : (
          <p className="muted">
            Not enough history yet — the projection needs at least two samples spanning
            some time.
          </p>
        )}
      </HealthCard>
    </>
  );
}

/**
 * The free-tier ledger — the $1/year budget made visible.
 *
 * Rendered as stacked meters rather than a table. A table here is the element
 * most likely to overflow horizontally at 360px, and horizontal scrolling on a
 * phone is a usability failure rather than a fix.
 */
function FreeTierLedger({
  payload,
  blockState,
  gozungaState,
}: {
  payload: MetricsPayload;
  blockState: HealthState;
  gozungaState: HealthState;
}) {
  const rows = [
    {
      label: 'Oracle block storage',
      used: payload.storage.block_used,
      limit: payload.storage.block_total || LIMITS.blockVolumeBytes,
      state: blockState,
      note: 'Keep at 0 VPU — raising the tier is billable',
    },
    {
      label: 'Gozunga backup',
      used: payload.backup.repo_bytes,
      limit: LIMITS.gozungaBytes,
      state: gozungaState,
      note: 'Photos and documents only, never video',
    },
  ];

  return (
    <HealthCard title="Free-tier ledger">
      {rows.map((row) => (
        <LimitMeter key={row.label} {...row} />
      ))}
      <p className="faint">
        Cloudflare R2 and Supabase usage appear on the Files tab and in the provider
        dashboards. Total projected cost: <strong>$0.00/year</strong>.
      </p>
    </HealthCard>
  );
}
