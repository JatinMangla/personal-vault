import { fileURLToPath } from 'node:url';
import { defineConfig } from 'vitest/config';

// The vault directory, without a trailing separator (`\` on Windows, `/` elsewhere).
const root = fileURLToPath(new URL('.', import.meta.url)).replace(/[\\/]$/, '');

export default defineConfig({
  resolve: {
    alias: {
      // tsconfig's `@/*` path, so route handlers can be imported as they ship.
      '@': root,
      // Next resolves `server-only` to this empty module under the react-server
      // condition; the default entry throws. Tests of server code need the
      // server resolution.
      'server-only': `${root}/node_modules/server-only/empty.js`,
    },
  },
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
