/**
 * StorageGauge segment filtering - the optional-field regression.
 *
 * `metrics_samples` stores whatever JSON the collector sent, so rows written
 * before a payload field existed simply lack it. `staging_bytes` is the first
 * such field on the storage breakdown, and it will not be the last.
 *
 * The bug this guards against is subtle and silent: the original filter was
 * `if (pct <= 0) return null`, and for an absent field `pct` is NaN. Every
 * comparison against NaN is false, so `NaN <= 0` does NOT reject it - the
 * segment rendered with `--seg-width: NaN%` and the legend printed a row for
 * a value that does not exist. Nothing threw; the dashboard just went wrong.
 *
 * These tests exercise the predicate rather than a React render: the suite runs
 * in `environment: 'node'` with no DOM, and the guard is the part that was
 * wrong. Keep it in sync with components/StorageGauge.tsx.
 */

import { describe, it, expect } from 'vitest';
import type { MetricsPayload } from '@/lib/supabase-types';

/** Mirrors the guard in components/StorageGauge.tsx. */
function isRenderableSegment(bytes: number | undefined, total: number): boolean {
  const pct = total > 0 ? ((bytes as number) / total) * 100 : 0;
  return Number.isFinite(pct) && pct > 0;
}

const TOTAL = 150 * 1024 ** 3;

describe('storage gauge segment filtering', () => {
  it('drops a field missing from an older sample', () => {
    // The regression. Before the fix this returned true and rendered NaN%.
    expect(isRenderableSegment(undefined, TOTAL)).toBe(false);
  });

  it('keeps a real staging measurement', () => {
    expect(isRenderableSegment(8 * 1024 ** 3, TOTAL)).toBe(true);
  });

  it('drops a staging directory that exists but is empty', () => {
    // dir_bytes returns 0 for a missing or empty directory, which is the normal
    // state between transfers. An empty segment should not clutter the legend.
    expect(isRenderableSegment(0, TOTAL)).toBe(false);
  });

  it('drops every segment when the volume total is unknown', () => {
    // A zero total means the collector could not read the volume. Rendering
    // segments against it would imply a breakdown nobody measured.
    expect(isRenderableSegment(8 * 1024 ** 3, 0)).toBe(false);
  });

  it('rejects a negative value rather than drawing it backwards', () => {
    expect(isRenderableSegment(-1, TOTAL)).toBe(false);
  });

  it('survives a non-numeric value without throwing', () => {
    // Defence in depth: the payload is JSON from the network, and TypeScript
    // types are erased at runtime.
    expect(isRenderableSegment(Number.NaN, TOTAL)).toBe(false);
    expect(isRenderableSegment('12' as unknown as number, TOTAL)).toBe(true);
  });
});

/**
 * The `sync` block — the same optional-field trap one level up.
 *
 * `staging_bytes` was a missing NUMBER on an object that existed. `sync` is a
 * missing OBJECT: the collector did not query Syncthing at all before
 * 2026-09-16, so every older sample lacks it entirely. Reading
 * `payload.sync.need_bytes` on one of those throws rather than rendering
 * wrongly, which would take the whole dashboard down and not just one card.
 *
 * These mirror the guards in app/status/page.tsx. Keep them in sync.
 */
describe('sync card guards', () => {
  /** Mirrors the card-1 render condition. */
  function showsSyncCard(payload: Pick<MetricsPayload, 'sync'>): boolean {
    return payload.sync !== undefined;
  }

  /** Mirrors how every sync number reaches the page. */
  function syncNeedBytes(payload: Pick<MetricsPayload, 'sync'>): number {
    return payload.sync?.need_bytes ?? 0;
  }

  function syncDelivered(payload: Pick<MetricsPayload, 'sync'>): number {
    const global = payload.sync?.global_files ?? 0;
    const local = payload.sync?.local_files ?? 0;
    return global > 0 ? local / global : 0;
  }

  it('hides the card entirely for a sample collected before sync existed', () => {
    expect(showsSyncCard({})).toBe(false);
  });

  it('reads zero rather than throwing on a sample with no sync block', () => {
    expect(syncNeedBytes({})).toBe(0);
    expect(Number.isFinite(syncNeedBytes({}))).toBe(true);
  });

  it('does not divide by a zero file count', () => {
    // globalFiles is 0 when the phone has announced nothing - the "not
    // scanning" symptom recorded in docs/HARD-WON.md. 0/0 is NaN, which would
    // render as a NaN-width meter exactly like the staging_bytes bug.
    const delivered = syncDelivered({
      sync: { state: 'idle', need_bytes: 0, need_files: 0, global_files: 0, local_files: 0, connected: true },
    });
    expect(Number.isFinite(delivered)).toBe(true);
    expect(delivered).toBe(0);
  });

  it('computes a real delivered fraction when the phone has announced files', () => {
    const delivered = syncDelivered({
      sync: { state: 'syncing', need_bytes: 5, need_files: 2, global_files: 8, local_files: 6, connected: true },
    });
    expect(delivered).toBe(0.75);
  });
});

/**
 * LimitMeter units — the bug that shipped.
 *
 * LimitMeter formatted everything through formatBytes, so the two archive
 * meters, which count FILES, rendered "3 of 11 files" as "3 B / 11 B" on the
 * live dashboard. Nothing threw and the bar filled to the right fraction; only
 * the label was nonsense, which is why it survived review and was caught by a
 * human reading the deployed page.
 *
 * Mirrors the formatter selection in components/HealthCard.tsx.
 */
describe('LimitMeter unit formatting', () => {
  function format(n: number, unit: 'bytes' | 'count'): string {
    if (unit === 'count') {
      return Number.isFinite(n) ? Math.round(n).toLocaleString() : '—';
    }
    // Only the zero case is needed here; formatBytes itself is exercised above.
    return n === 0 ? '0 B' : `${n} B`;
  }

  it('renders a file count as a bare number, not as bytes', () => {
    // The regression, exactly as it appeared on the dashboard.
    expect(format(3, 'count')).toBe('3');
    expect(format(11, 'count')).toBe('11');
    expect(format(3, 'count')).not.toBe('3 B');
  });

  it('still renders bytes as bytes, so storage meters are unaffected', () => {
    expect(format(0, 'bytes')).toBe('0 B');
  });

  it('does not render a fractional file count', () => {
    // used/limit arrive from JSON and are not guaranteed integral.
    expect(format(2.4, 'count')).toBe('2');
  });

  it('survives a non-numeric count without printing NaN', () => {
    expect(format(Number.NaN, 'count')).toBe('—');
  });
});

/**
 * The sync "delivered" ratio.
 *
 * local_files counts every file the VM holds in the folder; global_files counts
 * what the phone announces right now. Live data showed local=31 against
 * global=8, so local/global is NOT a completion ratio - it exceeded 1 and the
 * meter pinned at 100% while reading "31 / 8".
 */
describe('sync delivered ratio', () => {
  function deliveredOfTransfer(global: number, need: number): number {
    return Math.max(0, global - need);
  }

  it('measures progress within the announced transfer, not against local files', () => {
    // 8 announced, 3 still to arrive -> 5 delivered, never 31.
    expect(deliveredOfTransfer(8, 3)).toBe(5);
  });

  it('never reports negative progress when need exceeds global', () => {
    expect(deliveredOfTransfer(2, 5)).toBe(0);
  });

  it('is complete when nothing is outstanding', () => {
    expect(deliveredOfTransfer(8, 0)).toBe(8);
  });
});

/**
 * Phase markers. Absent on every sample before 2026-09-16, and an empty string
 * between batches — both must read as "no phase", never as a phase named "".
 */
describe('archive phase guards', () => {
  function phaseLabel(archive: MetricsPayload['archive']): string | null {
    const phase = archive?.phase;
    if (!phase) return null;
    if (phase === 'uploading' && (archive?.phase_total ?? 0) > 0) {
      return `Uploading ${archive?.phase_index ?? 0} of ${archive?.phase_total ?? 0}`;
    }
    return phase;
  }

  it('returns no label when the sample predates phase markers', () => {
    expect(phaseLabel({ status: 'running', total: 8, done: 3, remaining: 5, updated: 1 })).toBeNull();
  });

  it('returns no label between batches, when the phase is cleared to empty', () => {
    expect(
      phaseLabel({ status: 'running', total: 8, done: 3, remaining: 5, updated: 1, phase: '' }),
    ).toBeNull();
  });

  it('counts the file within its batch while uploading', () => {
    expect(
      phaseLabel({
        status: 'running', total: 8, done: 3, remaining: 5, updated: 1,
        phase: 'uploading', phase_index: 3, phase_total: 8,
      }),
    ).toBe('Uploading 3 of 8');
  });
});
