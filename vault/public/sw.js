/*
 * Service worker — APP SHELL ONLY.
 *
 * NEVER cache file ciphertext or decrypted content. A cache that survives
 * logout is a data leak: the next person to open the browser would be able to
 * read documents without the passphrase.
 *
 * Concretely, this worker refuses to cache:
 *   - anything under /api/            (metadata, presigned URLs, metrics)
 *   - anything from r2.cloudflarestorage.com  (the ciphertext itself)
 *   - any non-GET request
 *
 * What it does cache is the shell: HTML, CSS and JS, so the app opens offline
 * and looks like an installed application rather than a dead tab.
 */

const CACHE = 'vault-shell-v1';

const SHELL = ['/', '/status', '/manifest.webmanifest', '/icon-192.png', '/icon-512.png'];

self.addEventListener('install', (event) => {
  event.waitUntil(
    caches
      .open(CACHE)
      // Individual failures must not abort the whole install.
      .then((cache) => Promise.allSettled(SHELL.map((url) => cache.add(url))))
      .then(() => self.skipWaiting()),
  );
});

self.addEventListener('activate', (event) => {
  event.waitUntil(
    caches
      .keys()
      .then((keys) => Promise.all(keys.filter((k) => k !== CACHE).map((k) => caches.delete(k))))
      .then(() => self.clients.claim()),
  );
});

/** Anything that could carry user data must never be cached. */
function isCacheable(request) {
  if (request.method !== 'GET') return false;

  const url = new URL(request.url);

  // Same-origin only. In particular this excludes R2, where the ciphertext
  // lives.
  if (url.origin !== self.location.origin) return false;

  // API responses carry file metadata and presigned URLs. Presigned URLs expire
  // in 60 seconds, so a cached one is useless as well as unsafe.
  if (url.pathname.startsWith('/api/')) return false;

  return true;
}

self.addEventListener('fetch', (event) => {
  const { request } = event;

  if (!isCacheable(request)) {
    // Straight to the network, nothing stored.
    return;
  }

  // Network-first so a deployed update is picked up immediately, falling back to
  // the cached shell when offline.
  event.respondWith(
    fetch(request)
      .then((response) => {
        if (response.ok) {
          const copy = response.clone();
          void caches.open(CACHE).then((cache) => cache.put(request, copy));
        }
        return response;
      })
      .catch(() => caches.match(request).then((cached) => cached || caches.match('/'))),
  );
});

/** Let the page clear the shell cache on logout, belt and braces. */
self.addEventListener('message', (event) => {
  if (event.data === 'clear-cache') {
    void caches.delete(CACHE);
  }
});
