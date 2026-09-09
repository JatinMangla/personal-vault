import { defineConfig } from 'vitest/config';

export default defineConfig({
  test: {
    // Node 20 exposes a spec-compliant globalThis.crypto (Web Crypto), which is
    // the same primitive the browser uses. Testing against it rather than a
    // shim means the crypto core is exercised as it actually ships.
    environment: 'node',
    include: ['__tests__/**/*.test.ts'],
    // The chunked round-trip cases build multi-megabyte buffers.
    testTimeout: 60_000,
  },
});
