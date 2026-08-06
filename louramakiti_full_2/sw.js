// Louramakiti service worker — caches the app shell only.
// Data requests (Supabase) are never cached: always go to the network
// so listings stay fresh; the page itself handles the offline banner.

const CACHE_NAME = 'louramakiti-shell-v7';
const SHELL_FILES = [
  './',
  './index.html',
  './manifest.json',
  './logo.png',
  './icon-192.png',
  './icon-512.png',
  'https://cdn.jsdelivr.net/npm/dexie@4/+esm',
  'https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2/+esm'
];

self.addEventListener('install', (event) => {
  event.waitUntil(
    caches.open(CACHE_NAME).then((cache) => cache.addAll(SHELL_FILES))
  );
  // No self.skipWaiting() here on purpose — the new worker now WAITS
  // until the page's "Actualiser" button explicitly tells it to take
  // over (via the SKIP_WAITING message below). Calling it unconditionally
  // here used to make the update apply itself instantly and silently,
  // which meant the update banner never had a real chance to show.
});

self.addEventListener('activate', (event) => {
  event.waitUntil(
    caches.keys().then((keys) =>
      Promise.all(keys.filter((k) => k !== CACHE_NAME).map((k) => caches.delete(k)))
    )
  );
  self.clients.claim();
});

// Lets the page's "Actualiser" button (shown when an update is detected)
// force this waiting worker to activate immediately instead of the user
// needing to clear site data or reinstall the app.
self.addEventListener('message', (event) => {
  if (event.data && event.data.type === 'SKIP_WAITING') {
    self.skipWaiting();
  }
});

self.addEventListener('fetch', (event) => {
  const url = new URL(event.request.url);

  // CDN library files (Dexie, the Supabase client itself) — cache-first,
  // since these are static code, not data. This is what keeps Mon Cahier's
  // IndexedDB layer (and the app in general) functional even if the app
  // is opened while genuinely offline, days after the library was last
  // fetched, rather than depending on the browser's own opaque HTTP cache.
  if (url.hostname === 'cdn.jsdelivr.net') {
    event.respondWith(
      caches.match(event.request).then((cached) => cached || fetch(event.request))
    );
    return;
  }

  // Never intercept actual API/data calls (Supabase project API, or any
  // other host) — those must always hit the network so data stays live.
  if (url.origin !== self.location.origin) return;

  // App shell: cache-first, falling back to network, falling back to
  // the cached index.html for any offline navigation.
  event.respondWith(
    caches.match(event.request).then((cached) => {
      if (cached) return cached;
      return fetch(event.request).catch(() => caches.match('./index.html'));
    })
  );
});
