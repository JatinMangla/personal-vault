import { defineConfig, devices } from '@playwright/test';

/**
 * Playwright config for the responsive audit.
 *
 * WebKit is included deliberately: nearly every rule the audit enforces exists
 * because of an iOS Safari behaviour, and Chromium will not reproduce those.
 * Testing only Chromium would pass a suite whose entire purpose is iOS.
 */
export default defineConfig({
  testDir: './__tests__',
  testMatch: '**/*.spec.ts',
  fullyParallel: true,
  forbidOnly: !!process.env.CI,
  retries: process.env.CI ? 1 : 0,
  reporter: process.env.CI ? [['github'], ['list']] : 'list',

  use: {
    baseURL: 'http://127.0.0.1:3000',
    trace: 'on-first-retry',
  },

  projects: [
    { name: 'chromium', use: { ...devices['Desktop Chrome'] } },
    { name: 'webkit', use: { ...devices['Desktop Safari'] } },
  ],

  // Build and serve the real production output. Dev-mode styling and hydration
  // differ enough that a dev-server pass would not prove the deployed app works.
  webServer: {
    command: 'npm run build && npm run start',
    url: 'http://127.0.0.1:3000',
    reuseExistingServer: !process.env.CI,
    timeout: 180_000,
  },
});
