import type { Metadata, Viewport } from 'next';
import { connection } from 'next/server';
import './globals.css';
import { VaultKeyProvider } from '@/components/VaultKeyProvider';
import { BottomNav } from '@/components/BottomNav';

export const metadata: Metadata = {
  title: 'Personal Vault',
  description: 'End-to-end encrypted document vault and system health dashboard',
  manifest: '/manifest.webmanifest',
  appleWebApp: {
    capable: true,
    title: 'Vault',
    // black-translucent lets the app paint under the status bar, which is what
    // makes an installed PWA look native rather than letterboxed.
    statusBarStyle: 'black-translucent',
  },
  // Keep the vault out of search indexes.
  robots: { index: false, follow: false },
  icons: {
    icon: [
      { url: '/icon-192.png', sizes: '192x192', type: 'image/png' },
      { url: '/icon-512.png', sizes: '512x512', type: 'image/png' },
    ],
    // iOS ignores the manifest icons for the home-screen icon and uses this.
    apple: [{ url: '/apple-touch-icon.png', sizes: '180x180', type: 'image/png' }],
  },
};

export const viewport: Viewport = {
  width: 'device-width',
  initialScale: 1,
  // viewport-fit=cover is required for env(safe-area-inset-*) to report real
  // values. Without it the bottom nav sits under the home indicator.
  viewportFit: 'cover',
  // Deliberately NOT disabling user scaling: pinch-zoom is an accessibility
  // requirement. The 16px input rule is what prevents unwanted auto-zoom, not
  // a maximum-scale lock.
  themeColor: [
    { media: '(prefers-color-scheme: dark)', color: '#0f1115' },
    { media: '(prefers-color-scheme: light)', color: '#f6f7f9' },
  ],
};

/**
 * Force dynamic rendering.
 *
 * The CSP nonce in proxy.ts is generated per request, and Next can only stamp
 * it onto its inline hydration scripts while rendering a real request. A
 * statically prerendered page is built once with no request, so its scripts
 * carry no nonce, the CSP blocks them, and the page hangs at "Loading..."
 * forever (React error #412) - which is exactly what shipped to production.
 *
 * Doing this in the root layout covers every page at once. The cost is no
 * static caching, which is irrelevant for a single-user vault of tiny pages.
 */
export default async function RootLayout({ children }: { children: React.ReactNode }) {
  // Wait for an incoming request, so a nonce exists to apply.
  await connection();

  return (
    <html lang="en">
      <body>
        <VaultKeyProvider>
          <div className="app-shell">
            <BottomNav />
            <main className="app-main">{children}</main>
          </div>
        </VaultKeyProvider>
      </body>
    </html>
  );
}
