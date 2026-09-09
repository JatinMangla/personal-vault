/**
 * Health thresholds — the single source of truth for green/amber/red.
 *
 * Never hardcode a colour or a limit in a component. A component asks this
 * module what state a value is in and renders accordingly. Keeping the rules in
 * one place is what makes "the overall pill is the worst individual state"
 * a one-line computation rather than a pile of conditionals.
 */

export type HealthState = 'green' | 'amber' | 'red';

/** Worst-wins ordering. */
const SEVERITY: Record<HealthState, number> = { green: 0, amber: 1, red: 2 };

export function worstState(states: HealthState[]): HealthState {
  return states.reduce<HealthState>(
    (worst, s) => (SEVERITY[s] > SEVERITY[worst] ? s : worst),
    'green',
  );
}

/** Overall pill label. */
export function overallLabel(state: HealthState): 'Healthy' | 'Attention' | 'Critical' {
  return state === 'green' ? 'Healthy' : state === 'amber' ? 'Attention' : 'Critical';
}

// ---------------------------------------------------------------------------
// Capacity limits
// ---------------------------------------------------------------------------

const GB = 1024 ** 3;
const MB = 1024 ** 2;

export const LIMITS = {
  /** Oracle block volume, the media store. */
  blockVolumeBytes: 150 * GB,
  /** Supabase Storage free tier (file storage). */
  storageBytes: 1 * GB,
  /** Gozunga free tier, the restic repository. */
  gozungaBytes: 100 * GB,
  /** Supabase free tier Postgres. */
  supabaseBytes: 500 * MB,
  /** Instance RAM. */
  ramBytes: 12 * GB,
} as const;

// ---------------------------------------------------------------------------
// Percentage-based rules
// ---------------------------------------------------------------------------

interface PercentRule {
  /** Below this fraction: green. */
  amberAt: number;
  /** At or above this fraction: red. */
  redAt: number;
}

const PERCENT_RULES = {
  blockVolume: { amberAt: 0.70, redAt: 0.85 },
  bootVolume: { amberAt: 0.70, redAt: 0.85 },
  storage: { amberAt: 0.60, redAt: 0.85 },
  gozunga: { amberAt: 0.70, redAt: 0.90 },
  supabase: { amberAt: 0.50, redAt: 0.80 },
  ram: { amberAt: 0.80, redAt: 0.92 },
} as const satisfies Record<string, PercentRule>;

export type PercentMetric = keyof typeof PERCENT_RULES;

export function percentState(metric: PercentMetric, used: number, total: number): HealthState {
  // An unknown total is not "healthy" — it is unknown, and showing green for a
  // number nobody measured is exactly the failure the staleness rule exists for.
  if (!total || total <= 0) return 'amber';
  const fraction = used / total;
  const rule = PERCENT_RULES[metric];
  if (fraction >= rule.redAt) return 'red';
  if (fraction >= rule.amberAt) return 'amber';
  return 'green';
}

export function fractionOf(metric: PercentMetric, used: number, total: number): number {
  if (!total || total <= 0) return 0;
  return Math.min(1, Math.max(0, used / total));
}

// ---------------------------------------------------------------------------
// Age-based rules
// ---------------------------------------------------------------------------

const HOUR = 60 * 60 * 1000;
const DAY = 24 * HOUR;

/** Backup age: green under 26h, amber to 48h, red beyond. */
export function backupAgeState(lastBackupMs: number, now: number = Date.now()): HealthState {
  if (!lastBackupMs) return 'red';
  const age = now - lastBackupMs;
  if (age > 48 * HOUR) return 'red';
  if (age > 26 * HOUR) return 'amber';
  return 'green';
}

/** Restore drill age: green under 90d, amber to 180d, red beyond. */
export function restoreDrillState(lastDrillMs: number, now: number = Date.now()): HealthState {
  // Never having run a drill is the worst case, not a neutral one: the backup
  // is unverified.
  if (!lastDrillMs) return 'red';
  const age = now - lastDrillMs;
  if (age > 180 * DAY) return 'red';
  if (age > 90 * DAY) return 'amber';
  return 'green';
}

/**
 * Metrics staleness — itself a health signal.
 *
 * A dashboard that looks green because it is frozen is worse than no dashboard.
 * If the collector stops, this drives a loud red banner rather than letting
 * stale numbers sit there looking fine.
 */
export function stalenessState(lastSampleMs: number, now: number = Date.now()): HealthState {
  if (!lastSampleMs) return 'red';
  const age = now - lastSampleMs;
  if (age > 2 * HOUR) return 'red';
  if (age > 30 * 60 * 1000) return 'amber';
  return 'green';
}

/** Failed Immich jobs: 0 green, 1–10 amber, >10 red. */
export function failedJobsState(count: number): HealthState {
  if (count > 10) return 'red';
  if (count >= 1) return 'amber';
  return 'green';
}

/** Container health from `docker inspect`. */
export function containerState(status: string): HealthState {
  const s = (status || '').toLowerCase();
  if (s === 'healthy' || s === 'running') return 'green';
  if (s === 'starting') return 'amber';
  return 'red';
}

/** restic check result, written to a state file by the backup script. */
export function integrityState(status: string): HealthState {
  const s = (status || '').toLowerCase();
  if (s === 'ok') return 'green';
  if (s === 'unknown' || s === '') return 'amber';
  return 'red';
}

// ---------------------------------------------------------------------------
// Formatting
// ---------------------------------------------------------------------------

export function formatBytes(bytes: number): string {
  if (!Number.isFinite(bytes) || bytes < 0) return '—';
  if (bytes === 0) return '0 B';
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  const i = Math.min(units.length - 1, Math.floor(Math.log(bytes) / Math.log(1024)));
  const value = bytes / 1024 ** i;
  return `${value.toFixed(value >= 100 || i === 0 ? 0 : 1)} ${units[i]}`;
}

export function formatPercent(fraction: number): string {
  if (!Number.isFinite(fraction)) return '—';
  return `${Math.round(fraction * 100)}%`;
}

/** Relative time, e.g. "4 hours ago". More useful than a timestamp at a glance. */
export function formatRelative(ms: number, now: number = Date.now()): string {
  if (!ms) return 'never';
  const diff = now - ms;
  if (diff < 0) return 'in the future';

  const minutes = Math.floor(diff / 60000);
  if (minutes < 1) return 'just now';
  if (minutes < 60) return `${minutes} minute${minutes === 1 ? '' : 's'} ago`;

  const hours = Math.floor(minutes / 60);
  if (hours < 24) return `${hours} hour${hours === 1 ? '' : 's'} ago`;

  const days = Math.floor(hours / 24);
  if (days < 30) return `${days} day${days === 1 ? '' : 's'} ago`;

  const months = Math.floor(days / 30);
  if (months < 12) return `${months} month${months === 1 ? '' : 's'} ago`;

  const years = Math.floor(days / 365);
  return `${years} year${years === 1 ? '' : 's'} ago`;
}

export function formatDuration(seconds: number): string {
  if (!Number.isFinite(seconds) || seconds < 0) return '—';
  const days = Math.floor(seconds / 86400);
  const hours = Math.floor((seconds % 86400) / 3600);
  const minutes = Math.floor((seconds % 3600) / 60);
  if (days > 0) return `${days}d ${hours}h`;
  if (hours > 0) return `${hours}h ${minutes}m`;
  return `${minutes}m`;
}

// ---------------------------------------------------------------------------
// Growth projection
// ---------------------------------------------------------------------------

export interface Projection {
  /** Bytes per day, from a least-squares fit. Negative means shrinking. */
  bytesPerDay: number;
  bytesPerMonth: number;
  /** Days until the limit at the current rate, or null if not growing. */
  daysUntilFull: number | null;
}

/**
 * Least-squares linear fit over recent samples.
 *
 * Computed in the dashboard rather than the collector, so changing how the
 * projection works needs no VM redeploy.
 */
export function projectGrowth(
  samples: Array<{ t: number; bytes: number }>,
  limitBytes: number,
): Projection | null {
  if (samples.length < 2) return null;

  const ordered = [...samples].sort((a, b) => a.t - b.t);
  const t0 = ordered[0]!.t;

  // x in days since the first sample, y in bytes.
  const points = ordered.map((s) => ({ x: (s.t - t0) / DAY, y: s.bytes }));
  const n = points.length;
  const sumX = points.reduce((a, p) => a + p.x, 0);
  const sumY = points.reduce((a, p) => a + p.y, 0);
  const sumXY = points.reduce((a, p) => a + p.x * p.y, 0);
  const sumXX = points.reduce((a, p) => a + p.x * p.x, 0);

  const denominator = n * sumXX - sumX * sumX;
  // All samples at the same instant: no slope is defined.
  if (Math.abs(denominator) < 1e-9) return null;

  const bytesPerDay = (n * sumXY - sumX * sumY) / denominator;
  const latest = ordered[ordered.length - 1]!.bytes;
  const remaining = limitBytes - latest;

  const daysUntilFull =
    bytesPerDay > 0 && remaining > 0 ? Math.round(remaining / bytesPerDay) : null;

  return {
    bytesPerDay,
    bytesPerMonth: bytesPerDay * 30,
    daysUntilFull,
  };
}
