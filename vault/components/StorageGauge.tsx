'use client';

/**
 * Radial gauge, plain SVG.
 *
 * No charting library. Six gauges do not justify the bundle size, and every
 * kilobyte is paid for on a phone connection.
 *
 * Dynamic values (arc length, segment widths) are passed as CSS custom
 * properties rather than inline style declarations, so the CSP can forbid
 * inline styles outright.
 */

import type { CSSProperties } from 'react';
import { formatBytes, formatPercent, type HealthState } from '@/lib/thresholds';

interface StorageGaugeProps {
  used: number;
  total: number;
  state: HealthState;
  label: string;
  /** Optional stacked breakdown rendered beneath the gauge. */
  segments?: Array<{ label: string; bytes: number; color: string }>;
}

const STATE_COLOR: Record<HealthState, string> = {
  green: 'var(--green)',
  amber: 'var(--amber)',
  red: 'var(--red)',
};

export function StorageGauge({ used, total, state, label, segments }: StorageGaugeProps) {
  const fraction = total > 0 ? Math.min(1, Math.max(0, used / total)) : 0;

  // 270° arc starting from the lower-left, leaving a gap at the bottom for the
  // caption. Radius 54 in a 140-box keeps the stroke clear of the edges.
  const radius = 54;
  const circumference = 2 * Math.PI * radius;
  const arcLength = circumference * 0.75;
  const filled = arcLength * fraction;

  return (
    <div>
      <svg
        viewBox="0 0 140 140"
        className="gauge-svg"
        role="img"
        aria-label={`${label}: ${formatBytes(used)} of ${formatBytes(total)} used, ${formatPercent(fraction)}`}
      >
        {/* Track */}
        <circle
          cx="70"
          cy="70"
          r={radius}
          fill="none"
          stroke="var(--border)"
          strokeWidth="12"
          strokeLinecap="round"
          strokeDasharray={`${arcLength} ${circumference}`}
          transform="rotate(135 70 70)"
        />
        {/* Fill. strokeDasharray is an SVG presentation attribute, not an inline
            style, so it is unaffected by style-src. */}
        <circle
          className="gauge-arc"
          cx="70"
          cy="70"
          r={radius}
          fill="none"
          stroke={STATE_COLOR[state]}
          strokeWidth="12"
          strokeLinecap="round"
          strokeDasharray={`${filled} ${circumference}`}
          transform="rotate(135 70 70)"
        />
        <text x="70" y="66" textAnchor="middle" fill="var(--text)" fontSize="22" fontWeight="650">
          {formatPercent(fraction)}
        </text>
        <text x="70" y="86" textAnchor="middle" fill="var(--text-dim)" fontSize="11">
          {formatBytes(used)}
        </text>
        <text x="70" y="100" textAnchor="middle" fill="var(--text-faint)" fontSize="10">
          of {formatBytes(total)}
        </text>
      </svg>

      {segments && segments.length > 0 && (
        <div className="mt-075">
          {/* Percentages are of the volume, not of the used portion, so the bar
              lines up with the gauge above it. */}
          <div className="stack-bar">
            {segments.map((seg) => {
              const pct = total > 0 ? (seg.bytes / total) * 100 : 0;
              if (pct <= 0) return null;
              return (
                <div
                  key={seg.label}
                  className="stack-seg"
                  style={
                    {
                      '--seg-width': `${pct}%`,
                      '--seg-color': seg.color,
                    } as CSSProperties
                  }
                  title={`${seg.label}: ${formatBytes(seg.bytes)}`}
                />
              );
            })}
          </div>
          <ul className="legend">
            {segments.map((seg) => (
              <li
                key={seg.label}
                className="row gap-05"
                style={{ '--seg-color': seg.color } as CSSProperties}
              >
                <span className="dot" aria-hidden="true" />
                <span className="muted truncate">{seg.label}</span>
                <span className="ml-auto">{formatBytes(seg.bytes)}</span>
              </li>
            ))}
          </ul>
        </div>
      )}
    </div>
  );
}
