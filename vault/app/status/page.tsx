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

/**
 * The drain's current step, in words the operator reads rather than the token
 * the script writes.
 *
 * Returns null for both "this sample predates phase markers" and "no batch is
 * running": tg-upload.sh clears the phase to an empty string on exit, precisely
 * so a killed run cannot leave `uploading` on the dashboard forever. Neither
 * case is a phase, and `!phase` catches both — a truthiness check, not a
 * comparison against undefined, because '' must fall through it too.
 */
function phaseLabel(archive: MetricsPayload['archive']): string | null {
  const phase = archive?.phase;
  if (!phase) return null;

  const file = archive?.phase_file ?? '';
  const index = archive?.phase_index ?? 0;
  const total = archive?.phase_total ?? 0;

  switch (phase) {
    case 'hashing':
      return total > 0 ? `Hashing ${total} file(s)` : 'Hashing the batch';
    case 'uploading':
      return total > 0
        ? `Uploading ${index} of ${total}${file ? ` · ${file}` : ''}`
        : 'Uploading to Telegram';
    case 'downloading':
      return 'Downloading the channel to verify';
    case 'rejoining':
      return file ? `Rejoining parts of ${file}` : 'Rejoining parts';
    case 'verifying':
      return file ? `Verifying ${file}` : 'Verifying hashes';
    case 'clearing':
      return 'Clearing staging';
    default:
      // An unrecognised phase is still information: a newer script writing a
      // phase this page has not learned yet should show the raw token rather
      // than silently nothing.
      return phase;
  }
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
    // one cycle behind what the server knows. The collector pushes every
    // minute (ops/systemd/metrics-push.timer), so 30 s.
    //
    // This is as live as the architecture allows: the VM has no inbound ports
    // and Vercel cannot reach it over Tailscale, so the page can only ever show
    // what was last pushed. Near-live, never realtime.
    const id = setInterval(() => void load(), 30 * 1000);
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
  const backupRepoState = percentState('backupRepo', payload.backup.repo_bytes, LIMITS.backupRepoBytes);

  const backupState = backupAgeState(payload.backup.last_backup_ts * 1000);
  const drillState = restoreDrillState(payload.backup.last_drill_ts * 1000);
  const jobsState = failedJobsState(payload.immich.failed_jobs);
  const checkState = integrityState(payload.backup.last_check_status);

  // Syncthing's own folder state. `error` is the one that needs attention - a
  // missing .stfolder marker parks the folder there and nothing transfers.
  // `unknown` means the collector could not read the API key at all, which is
  // also not healthy: it is the ProtectHome trap, and showing green for a
  // number nobody could measure is the failure the staleness rule exists for.
  const syncState: HealthState = !payload.sync
    ? 'green'
    : payload.sync.state === 'error'
      ? 'red'
      : payload.sync.state === 'unknown'
        ? 'amber'
        : 'green';

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
    backupRepoState,
    backupState,
    drillState,
    jobsState,
    checkState,
    syncState,
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
            // ?? 0 because samples predating the drain loop have no such field.
            // The gauge guards against NaN too, but coalescing here keeps the
            // "undefined means nothing staged" decision at the call site.
            { label: 'Staging', bytes: payload.storage.staging_bytes ?? 0, color: 'var(--accent-dim)' },
          ]}
        />
        {payload.immich.api_ok === false && (
          <div className="banner banner-amber" role="alert">
            <strong>Immich statistics unavailable.</strong> The counts below read
            zero because the API could not be read, not because the library is
            empty{payload.immich.api_warning ? ` (${payload.immich.api_warning})` : ''}.
            Storage figures are computed locally and remain accurate.
          </div>
        )}
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
            label="Backup repository"
            used={payload.backup.repo_bytes}
            limit={LIMITS.backupRepoBytes}
            state={backupRepoState}
          />
        </div>
        {drillState === 'red' && (
          <p className="faint">
            A backup that has never been restored is a hypothesis. Run{' '}
            <code>ops/backup/restore-test.sh</code>.
          </p>
        )}
      </HealthCard>

      {/* 3a. Card -> VM, the Syncthing half.
          Rendered only when a sample carries the block. `sync` is a missing
          OBJECT on older samples, not a missing number: the collector did not
          query Syncthing at all before 2026-09-16, so this must be guarded one
          level higher than staging_bytes was. */}
      {payload.sync && (
        <HealthCard title="Card → VM (Syncthing)" state={syncState}>
          <StatRow
            label="Transfer state"
            value={payload.sync.state}
            state={syncState}
          />
          <StatRow
            label="Phone"
            value={payload.sync.connected ? 'connected' : 'not connected'}
            state={payload.sync.connected ? 'green' : 'amber'}
          />
          <StatRow
            label="Files announced"
            value={(payload.sync.global_files ?? 0).toLocaleString()}
          />
          <StatRow
            label="Received"
            value={(payload.sync.local_files ?? 0).toLocaleString()}
          />
          {(payload.sync.need_files ?? 0) > 0 && (
            <StatRow
              label="Still to arrive"
              value={`${(payload.sync.need_files ?? 0).toLocaleString()} file(s) · ${formatBytes(payload.sync.need_bytes ?? 0)}`}
              state="amber"
            />
          )}
          {(payload.sync.global_files ?? 0) > 0 && (
            <div className="mt-075">
              <LimitMeter
                label="Delivered"
                used={payload.sync.local_files ?? 0}
                limit={payload.sync.global_files ?? 0}
                state={(payload.sync.need_files ?? 0) > 0 ? 'amber' : 'green'}
              />
            </div>
          )}
          {(payload.sync.need_bytes ?? 0) > 0 && (
            /* 12 MB/s is the midpoint of the 10-16 MB/s measured on a DIRECT
               Tailscale link (2026-09-15). It was 1.3 MB/s while the connection
               relayed through DERP, so if this ever reads wildly optimistic,
               check `tailscale status` for "relay" rather than "direct". */
            <StatRow
              label="Est. time left"
              value={formatDuration((payload.sync.need_bytes ?? 0) / 12_000_000)}
            />
          )}
          <StatRow label="In staging" value={formatBytes(payload.storage.staging_bytes ?? 0)} />
          <div className="mt-075">
            <LimitMeter
              label="Boot volume"
              used={payload.storage.boot_used}
              limit={payload.storage.boot_total}
              state={bootState}
              note="Check #2 scratch must never land here"
            />
          </div>
          {!payload.sync.connected && (
            <p className="faint">
              Either the phone is disconnected, or Syncthing could not be reached.
              An unreachable Syncthing reports the same thing as a disconnected
              phone — claiming a connection nothing verified would be worse.
            </p>
          )}
          {payload.sync.state === 'unknown' && (
            <p className="faint">
              The collector could not read the Syncthing API key. Check that{' '}
              <code>metrics-push.service</code> has{' '}
              <code>ProtectHome=read-only</code> and not <code>true</code>.
            </p>
          )}
          {payload.sync.connected && (payload.sync.global_files ?? 0) === 0 && (
            <p className="faint">
              The phone is connected but has announced no files — the card is
              probably not being scanned. Check the folder on the phone.
            </p>
          )}
        </HealthCard>
      )}

      {/* 3b. VM -> Telegram, the drain half.
          Same optional-object guard: samples predating the drain have no
          archive block at all. */}
      {payload.archive && payload.archive.total > 0 && (
        <HealthCard
          title="VM → Telegram (archive)"
          state={payload.archive.status === 'incomplete' ? 'amber' : 'green'}
        >
          {/* The current step, in plain words. `status` alone cannot tell
              hashing from uploading from the 20-minute Check #2 download, which
              is what made the old single card hard to read. */}
          {phaseLabel(payload.archive) && (
            <StatRow label="Now" value={phaseLabel(payload.archive)} state="amber" />
          )}
          <StatRow label="Files on the card" value={payload.archive.total.toLocaleString()} />
          <StatRow
            label="In Telegram"
            value={payload.archive.done.toLocaleString()}
          />
          <StatRow
            label="Remaining"
            value={payload.archive.remaining.toLocaleString()}
            state={payload.archive.remaining > 0 ? 'amber' : 'green'}
          />
          <div className="mt-075">
            <LimitMeter
              label="Drained"
              used={payload.archive.done}
              limit={payload.archive.total}
              state={payload.archive.remaining > 0 ? 'amber' : 'green'}
            />
          </div>
          {(payload.archive.bytes ?? 0) > 0 && (
            <StatRow
              label="Archived to Telegram"
              value={
                (payload.archive.bytes_unknown ?? 0) > 0
                  ? `${formatBytes(payload.archive.bytes ?? 0)}+`
                  : formatBytes(payload.archive.bytes ?? 0)
              }
            />
          )}
          {payload.archive.remaining > 0 && (payload.archive.bytes ?? 0) > 0 && payload.archive.done > 0 && (
            /* Remaining transfer time, from the average size actually archived
               rather than a guess. Same 12 MB/s caveat as the card above. */
            <StatRow
              label="Est. transfer left"
              value={formatDuration(
                (payload.archive.remaining *
                  ((payload.archive.bytes ?? 0) / payload.archive.done)) /
                  12_000_000,
              )}
            />
          )}
          <div className="mt-075">
            <LimitMeter
              label="Media volume"
              used={payload.storage.block_used}
              limit={payload.storage.block_total || LIMITS.blockVolumeBytes}
              state={blockState}
              note="Holds staging and the Check #2 round trip"
            />
          </div>
          <StatRow
            label="Drain state"
            value={payload.archive.status}
            state={payload.archive.status === 'incomplete' ? 'amber' : 'green'}
          />
          {payload.archive.updated > 0 && (
            <StatRow
              label="Last progress"
              value={formatRelative(payload.archive.updated * 1000)}
            />
          )}
          {(payload.archive.bytes_unknown ?? 0) > 0 && (
            <p className="faint">
              {payload.archive.bytes_unknown} file(s) were archived before sizes
              were recorded, so the total above is a lower bound.
            </p>
          )}
          {payload.archive.phase === 'downloading' && (
            <p className="faint">
              Check #2 downloads the whole channel back to verify this batch, so
              this step takes longer as the archive grows.
            </p>
          )}
          {payload.archive.status === 'incomplete' && (
            <p className="faint">
              The drain stopped with files still unarchived — Syncthing may have
              stalled, or the card was disconnected. Reconnect it and run{' '}
              <code>tg-archive start</code> again.
            </p>
          )}
        </HealthCard>
      )}

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
      <FreeTierLedger payload={payload} blockState={blockState} backupRepoState={backupRepoState} />

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
  backupRepoState,
}: {
  payload: MetricsPayload;
  blockState: HealthState;
  backupRepoState: HealthState;
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
      label: 'Oracle Object Storage backup',
      used: payload.backup.repo_bytes,
      limit: LIMITS.backupRepoBytes,
      state: backupRepoState,
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
