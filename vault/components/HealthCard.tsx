'use client';

/**
 * Small presentational pieces for the dashboard: status pills, labelled meters,
 * key/value rows and container dots.
 *
 * Every one takes a HealthState rather than a colour. Colours are decided in
 * lib/thresholds.ts and nowhere else.
 */

import type { CSSProperties, ReactNode } from 'react';
import { formatBytes, formatPercent, type HealthState } from '@/lib/thresholds';

export function StatusPill({ state, label }: { state: HealthState; label: string }) {
  return (
    <span className={`pill state-${state}`}>
      <span className="dot" aria-hidden="true" />
      {label}
    </span>
  );
}

export function HealthCard({
  title,
  state,
  children,
}: {
  title: string;
  state?: HealthState;
  children: ReactNode;
}) {
  return (
    <section className="card">
      <div className="card-title">
        <h2>{title}</h2>
        {state && <span className={`dot state-${state}`} aria-hidden="true" />}
      </div>
      {children}
    </section>
  );
}

/**
 * A labelled progress bar against a limit. The free-tier ledger is built from
 * these, which is what lets it render as cards on a phone instead of a table.
 */
export function LimitMeter({
  label,
  used,
  limit,
  state,
  note,
}: {
  label: string;
  used: number;
  limit: number;
  state: HealthState;
  note?: string;
}) {
  const fraction = limit > 0 ? Math.min(1, used / limit) : 0;

  return (
    <div className="mb-09">
      <div className="row-between mb-025">
        <span className="truncate">{label}</span>
        <span className={`faint flex-none state-${state}`}>
          {formatBytes(used)} / {formatBytes(limit)}
        </span>
      </div>
      <div
        className="meter"
        role="meter"
        aria-valuenow={Math.round(fraction * 100)}
        aria-valuemin={0}
        aria-valuemax={100}
        aria-label={`${label}: ${formatPercent(fraction)} used`}
      >
        <div
          className={`meter-fill ${state}`}
          style={{ '--fill': `${fraction * 100}%` } as CSSProperties}
        />
      </div>
      {note && <div className="faint mt-025">{note}</div>}
    </div>
  );
}

export function StatRow({
  label,
  value,
  state,
}: {
  label: string;
  value: ReactNode;
  state?: HealthState;
}) {
  return (
    <div className="stat-row">
      <span className="muted truncate">{label}</span>
      <span className={`flex-none${state ? ` state-${state}` : ''}`}>{value}</span>
    </div>
  );
}

/** Container health as four small dots. */
export function ContainerDots({
  containers,
}: {
  containers: Array<{ name: string; status: string; state: HealthState }>;
}) {
  return (
    <div className="container-grid">
      {containers.map((c) => (
        <div key={c.name} className="container-item">
          <span className={`dot state-${c.state}`} aria-hidden="true" />
          <span className="truncate">{c.name}</span>
          <span className="faint ml-auto flex-none">{c.status}</span>
        </div>
      ))}
    </div>
  );
}
