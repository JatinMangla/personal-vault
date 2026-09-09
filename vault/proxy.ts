/**
 * Per-request CSP nonce.
 *
 * WHY THIS EXISTS. Next.js emits two inline <script> blocks on every page: the
 * React Flight payload that hydration needs. A strict `script-src 'self'`
 * blocks them, React never hydrates, and every page sits at "Loading..."
 * forever (React error #412). That is exactly what happened in production.
 *
 * The fix has to allow those two specific scripts without allowing inline
 * script in general:
 *
 *   - 'unsafe-inline' would work but re-opens the XSS hole the CSP exists to
 *     close, and the project spec forbids it outright.
 *   - Hashes cannot work: the Flight payload differs per page and per build.
 *   - Subresource Integrity does not help either — tested, and Next attaches
 *     `integrity` only to external scripts, never to the inline payload.
 *
 * So: a nonce. A fresh random value per request goes into the CSP header, and
 * Next stamps that same value onto the scripts it generates. An injected
 * script cannot guess it.
 *
 * COST, accepted deliberately: nonces require dynamic rendering, so pages are
 * no longer statically cached at the edge. For a single-user vault this is a
 * non-issue — the pages are tiny and Vercel's free tier allows 1M invocations
 * a month against an expected handful per day.
 *
 * The nonce MUST be unpredictable and unique per request. crypto.randomUUID()
 * is CSPRNG-backed; never swap it for Math.random() or a counter.
 */

import { NextResponse, type NextRequest } from 'next/server';

export function proxy(request: NextRequest) {
  const nonce = Buffer.from(crypto.randomUUID()).toString('base64');

  // `upgrade-insecure-requests` rewrites http:// subresource URLs to https://.
  // That is correct and wanted in production, but against a local test server
  // with no TLS it makes every asset fail with an SSL error - WebKit applies it
  // to 127.0.0.1 where Chromium exempts localhost. The symptom is baffling:
  // the page renders unstyled because the stylesheet never loads.
  // Vercel serves only over HTTPS, so dropping it locally costs nothing.
  const isLocalhost =
    request.nextUrl.hostname === 'localhost' || request.nextUrl.hostname === '127.0.0.1';

  // 'strict-dynamic' lets the nonced bootstrap load the rest of the chunks
  // without each needing its own nonce, which is what makes this workable with
  // a bundler that code-splits.
  //
  // style-src keeps 'unsafe-inline' rather than a nonce: React sets a handful
  // of dynamic style ATTRIBUTES (meter widths, gauge colours) that a nonce
  // cannot cover, and a style attribute cannot execute script. See
  // SECURITY-NOTES.md.
  //
  // connect-src allows Supabase only — the API, realtime, and Storage signed
  // upload/download URLs all live under *.supabase.co.
  const csp = [
    "default-src 'self'",
    `script-src 'self' 'nonce-${nonce}' 'strict-dynamic'`,
    "style-src 'self' 'unsafe-inline'",
    "img-src 'self' data: blob:",
    "font-src 'self'",
    "connect-src 'self' https://*.supabase.co wss://*.supabase.co",
    "media-src 'self' blob:",
    "object-src 'none'",
    "base-uri 'none'",
    "form-action 'self'",
    "frame-ancestors 'none'",
    "worker-src 'self'",
    "manifest-src 'self'",
    ...(isLocalhost ? [] : ['upgrade-insecure-requests']),
  ].join('; ');

  // Next reads the nonce back out of the request's CSP header when rendering,
  // so it must be set on the REQUEST, not only the response.
  const requestHeaders = new Headers(request.headers);
  requestHeaders.set('x-nonce', nonce);
  requestHeaders.set('Content-Security-Policy', csp);

  const response = NextResponse.next({ request: { headers: requestHeaders } });
  response.headers.set('Content-Security-Policy', csp);

  return response;
}

export const config = {
  matcher: [
    {
      // Static assets and API routes need no CSP: assets execute nothing, and
      // API responses are JSON. Excluding them also avoids paying for a proxy
      // invocation on every chunk request.
      source: '/((?!api|_next/static|_next/image|favicon.ico|icon-|apple-touch-icon|manifest.webmanifest|sw.js).*)',
      missing: [
        { type: 'header', key: 'next-router-prefetch' },
        { type: 'header', key: 'purpose', value: 'prefetch' },
      ],
    },
  ],
};
