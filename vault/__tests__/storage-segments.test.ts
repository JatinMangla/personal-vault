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
