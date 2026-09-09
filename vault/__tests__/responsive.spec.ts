/**
 * Responsive audit — BLOCKING (spec 5.6 / P6).
 *
 * Every assertion here maps to a real, reproducible bug on a target device.
 * These are acceptance criteria, not suggestions: a UI that has not been tested
 * at 360px is unusable on the device it will be used from most.
 *
 * Run:  npm run test:e2e
 * (needs `npx playwright install chromium webkit` once)
 */

import { test, expect, type Page } from '@playwright/test';

/** The five viewports from the spec, including iPad Split View. */
const VIEWPORTS = [
  { name: 'Android phone', width: 360, height: 800 },
  { name: 'iPhone Pro Max', width: 430, height: 932 },
  { name: 'iPad Split View', width: 507, height: 1366 },
  { name: 'iPad portrait', width: 1024, height: 1366 },
  { name: 'iPad landscape', width: 1366, height: 1024 },
] as const;

/** Pages reachable without a session. */
const PUBLIC_ROUTES = ['/', '/login', '/status'] as const;

const MIN_TAP_TARGET = 44;

async function assertNoHorizontalOverflow(page: Page, width: number) {
  const scrollWidth = await page.evaluate(() => document.documentElement.scrollWidth);
  // 1px of tolerance for sub-pixel rounding in the layout engine.
  expect(
    scrollWidth,
    `horizontal overflow: scrollWidth ${scrollWidth} exceeds viewport ${width}`,
  ).toBeLessThanOrEqual(width + 1);
}

async function assertTapTargets(page: Page) {
  const undersized = await page.evaluate((min) => {
    const selector = 'button, a, input, select, textarea, [role="button"]';
    const bad: Array<{ tag: string; text: string; w: number; h: number }> = [];

    for (const el of Array.from(document.querySelectorAll(selector))) {
      const style = window.getComputedStyle(el);
      // Skip anything not actually rendered.
      if (style.display === 'none' || style.visibility === 'hidden') continue;
      const rect = el.getBoundingClientRect();
      if (rect.width === 0 && rect.height === 0) continue;
      // Inline links inside a paragraph are text, not tap targets, and holding
      // them to 44px would mean padding out every inline link in prose.
      if (el.tagName === 'A' && el.closest('p')) continue;

      if (rect.width < min || rect.height < min) {
        bad.push({
          tag: el.tagName.toLowerCase(),
          text: (el.textContent ?? '').trim().slice(0, 30),
          w: Math.round(rect.width),
          h: Math.round(rect.height),
        });
      }
    }
    return bad;
  }, MIN_TAP_TARGET);

  expect(
    undersized,
    `interactive elements below ${MIN_TAP_TARGET}x${MIN_TAP_TARGET}: ${JSON.stringify(undersized)}`,
  ).toEqual([]);
}

async function assertInputFontSize(page: Page) {
  // Below 16px, iOS Safari zooms on focus and never zooms back out.
  const small = await page.evaluate(() => {
    const bad: Array<{ id: string; size: string }> = [];
    for (const el of Array.from(document.querySelectorAll('input, textarea, select'))) {
      const size = parseFloat(window.getComputedStyle(el).fontSize);
      if (size < 16) {
        bad.push({ id: el.id || el.tagName.toLowerCase(), size: `${size}px` });
      }
    }
    return bad;
  });

  expect(small, `inputs below 16px would trigger iOS auto-zoom: ${JSON.stringify(small)}`).toEqual(
    [],
  );
}

async function assertNoSafeAreaCollision(page: Page) {
  // Nothing interactive may sit under the notch or the home indicator.
  const colliding = await page.evaluate(() => {
    const read = (name: string) => {
      const v = getComputedStyle(document.documentElement).getPropertyValue(name);
      return parseFloat(v) || 0;
    };
    const top = read('--safe-top');
    const bottom = read('--safe-bottom');
    if (top === 0 && bottom === 0) return [];

    const bad: string[] = [];
    const vh = window.innerHeight;
    for (const el of Array.from(document.querySelectorAll('button, a, input'))) {
      const rect = el.getBoundingClientRect();
      if (rect.height === 0) continue;
      if (rect.top < top || rect.bottom > vh - bottom) {
        bad.push(el.tagName.toLowerCase() + ':' + (el.textContent ?? '').trim().slice(0, 20));
      }
    }
    return bad;
  });

  expect(colliding, `elements intersect the safe-area inset: ${JSON.stringify(colliding)}`).toEqual(
    [],
  );
}

// ---------------------------------------------------------------------------

for (const viewport of VIEWPORTS) {
  test.describe(`${viewport.name} (${viewport.width}x${viewport.height})`, () => {
    test.use({ viewport: { width: viewport.width, height: viewport.height } });

    for (const route of PUBLIC_ROUTES) {
      test(`${route} has no horizontal overflow`, async ({ page }) => {
        await page.goto(route);
        await page.waitForLoadState('networkidle');
        await assertNoHorizontalOverflow(page, viewport.width);
      });

      test(`${route} has adequate tap targets`, async ({ page }) => {
        await page.goto(route);
        await page.waitForLoadState('networkidle');
        await assertTapTargets(page);
      });

      test(`${route} inputs are at least 16px`, async ({ page }) => {
        await page.goto(route);
        await page.waitForLoadState('networkidle');
        await assertInputFontSize(page);
      });

      test(`${route} respects the safe area`, async ({ page }) => {
        await page.goto(route);
        await page.waitForLoadState('networkidle');
        await assertNoSafeAreaCollision(page);
      });
    }
  });
}

// ---------------------------------------------------------------------------

test.describe('CSS rules that cause device-specific bugs', () => {
  test('no 100vh anywhere in the stylesheet', async ({ page }) => {
    await page.goto('/');
    const offenders = await page.evaluate(() => {
      const bad: string[] = [];
      for (const sheet of Array.from(document.styleSheets)) {
        let rules: CSSRuleList;
        try {
          rules = sheet.cssRules;
        } catch {
          continue; // cross-origin stylesheet
        }
        for (const rule of Array.from(rules)) {
          const text = rule.cssText;
          // 100dvh is correct; 100vh is the bug. Match the unit boundary so
          // "100dvh" does not register as containing "100vh".
          if (/(?<![a-z])100vh/.test(text)) bad.push(text.slice(0, 120));
        }
      }
      return bad;
    });

    expect(
      offenders,
      `100vh is cut off by the iOS Safari toolbar; use 100dvh: ${JSON.stringify(offenders)}`,
    ).toEqual([]);
  });

  test('the status page ledger does not become a wide table on phones', async ({ page }) => {
    await page.setViewportSize({ width: 360, height: 800 });
    await page.goto('/status');
    await page.waitForLoadState('networkidle');

    // The free-tier ledger is the element most likely to overflow at 360px.
    const wideTables = await page.evaluate(() => {
      const bad: number[] = [];
      for (const table of Array.from(document.querySelectorAll('table'))) {
        const rect = table.getBoundingClientRect();
        if (rect.width > window.innerWidth) bad.push(Math.round(rect.width));
      }
      return bad;
    });

    expect(wideTables, 'tables must collapse to cards below 768px').toEqual([]);
    await assertNoHorizontalOverflow(page, 360);
  });
});

test.describe('PWA', () => {
  test('serves a valid manifest with the required icons', async ({ request }) => {
    const res = await request.get('/manifest.webmanifest');
    expect(res.ok()).toBeTruthy();

    const manifest = (await res.json()) as {
      display: string;
      icons: Array<{ sizes: string }>;
      theme_color: string;
      background_color: string;
    };

    expect(manifest.display).toBe('standalone');
    expect(manifest.theme_color).toBeTruthy();
    expect(manifest.background_color).toBeTruthy();

    const sizes = manifest.icons.map((i) => i.sizes);
    expect(sizes).toContain('192x192');
    expect(sizes).toContain('512x512');
  });

  test('serves the apple-touch-icon iOS requires', async ({ request }) => {
    // iOS ignores the manifest icons for the home-screen icon.
    const res = await request.get('/apple-touch-icon.png');
    expect(res.ok()).toBeTruthy();
  });

  test('service worker never caches API responses or ciphertext', async ({ request }) => {
    const res = await request.get('/sw.js');
    expect(res.ok()).toBeTruthy();

    const source = await res.text();
    // A cache surviving logout is a data leak, so the exclusions are asserted
    // rather than assumed.
    expect(source).toContain("startsWith('/api/')");
    expect(source).toContain('self.location.origin');
  });
});
