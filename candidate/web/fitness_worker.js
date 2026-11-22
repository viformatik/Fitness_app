'use strict';
/* Reconstructed synthetic loopback worker. Not a production offline shell. */
const SHELL_ID = '__SYNTHETIC_SHELL_ID__';
const MANIFEST_SHA256 = '__SYNTHETIC_MANIFEST_SHA256__';
const CACHE_NAME = 'fitness-synthetic-fence-' + SHELL_ID;
const MANIFEST = 'candidate-shell-manifest.json';
const REQUIRED = [
  'index.html', 'fitness_tab_guard.js', 'flutter_bootstrap.js', 'main.dart.js',
  'version.json', 'manifest.json', 'icons/Icon-192.png', 'assets/FontManifest.json',
  'assets/fonts/fallback/Roboto-Regular.ttf', 'canvaskit/canvaskit.js', 'canvaskit/canvaskit.wasm',
];
const digest = async bytes => Array.from(new Uint8Array(await crypto.subtle.digest('SHA-256', bytes)))
  .map(value => value.toString(16).padStart(2, '0')).join('');
function appUrl(name) {
  if (typeof name !== 'string' || !/^[A-Za-z0-9._/-]+$/.test(name) || name.startsWith('/') ||
      name.split('/').some(part => !part || part === '.' || part === '..')) throw Error('Invalid synthetic asset path');
  const scope = new URL(self.registration.scope), url = new URL(name, scope);
  if (url.origin !== scope.origin || !url.pathname.startsWith(scope.pathname) || url.search || url.hash) {
    throw Error('Synthetic asset outside scope');
  }
  return url.href;
}
async function readManifest(response) {
  if (!response || !response.ok) throw Error('Synthetic manifest missing');
  const bytes = await response.arrayBuffer();
  if (await digest(bytes) !== MANIFEST_SHA256) throw Error('Synthetic manifest hash mismatch');
  const manifest = JSON.parse(new TextDecoder().decode(bytes));
  if (!manifest || manifest.schema !== 1 || manifest.id !== SHELL_ID || !manifest.files ||
      typeof manifest.files !== 'object' || Array.isArray(manifest.files)) throw Error('Bad synthetic manifest');
  const entries = Object.entries(manifest.files);
  if (entries.length < REQUIRED.length || entries.length > 3000 ||
      REQUIRED.some(name => !Object.prototype.hasOwnProperty.call(manifest.files, name))) throw Error('Incomplete synthetic manifest');
  for (const [name, hash] of entries) { appUrl(name); if (!/^[0-9a-f]{64}$/.test(hash)) throw Error('Invalid hash'); }
  return entries;
}
async function verifyResponse(response, expected) {
  if (!response || !response.ok || response.type !== 'basic') throw Error('Synthetic asset missing');
  if (await digest(await response.clone().arrayBuffer()) !== expected) throw Error('Synthetic asset hash mismatch');
}
async function verifyCachedShell() {
  const cache = await caches.open(CACHE_NAME);
  const entries = await readManifest(await cache.match(appUrl(MANIFEST)));
  for (const [name, hash] of entries) await verifyResponse(await cache.match(appUrl(name)), hash);
  return entries.length;
}
self.addEventListener('install', event => {
  event.waitUntil((async () => {
    if (self.location.hostname !== '127.0.0.1' || SHELL_ID.startsWith('__') || MANIFEST_SHA256.startsWith('__')) {
      throw Error('Unstamped or non-loopback synthetic worker');
    }
    const existed = (await caches.keys()).includes(CACHE_NAME);
    const cache = await caches.open(CACHE_NAME);
    try {
      const response = await fetch(new Request(appUrl(MANIFEST), {cache: 'no-store'}));
      const entries = await readManifest(response.clone());
      for (const [name, hash] of entries) {
        const url = appUrl(name), asset = await fetch(new Request(url, {cache: 'no-store'}));
        await verifyResponse(asset, hash);
        await cache.put(url, asset); // exact checked response, not a second fetch
      }
      await cache.put(appUrl(MANIFEST), response);
      await verifyCachedShell();
    } catch (error) {
      // A same-ID cache might still be used by an active worker. Installation
      // must never delete that existing cache on failure.
      if (!existed) await caches.delete(CACHE_NAME);
      throw error;
    }
    await self.skipWaiting();
  })());
});
self.addEventListener('activate', event => {
  // Do not silently delete any previous synthetic shell during reconstruction.
  // Unbounded cache growth/quota remains an unresolved limitation.
  event.waitUntil(self.clients.claim());
});
self.addEventListener('message', event => {
  if (!event.data || event.data.type !== 'FITNESS_SYNTHETIC_SHELL_STATUS' || !event.ports || !event.ports[0]) return;
  const port = event.ports[0];
  event.waitUntil((async () => {
    try { port.postMessage({ok: true, id: SHELL_ID, files: await verifyCachedShell()}); }
    catch (_) { port.postMessage({ok: false, id: SHELL_ID, files: 0}); }
    finally { port.close(); }
  })());
});
self.addEventListener('fetch', event => {
  const request = event.request, url = new URL(request.url), scope = new URL(self.registration.scope);
  if (request.method !== 'GET' || url.origin !== scope.origin || !url.pathname.startsWith(scope.pathname)) return;
  const relative = url.pathname.slice(scope.pathname.length);
  if (relative.startsWith('__lab_legacy__/')) return;
  if (request.mode !== 'navigate' && url.search) return;
  event.respondWith((async () => {
    const cache = await caches.open(CACHE_NAME);
    const target = request.mode === 'navigate' ? appUrl('index.html') : url.href;
    return (await cache.match(target)) || new Response('Тестовая оболочка недоступна.', {
      status: 503, headers: {'Content-Type': 'text/plain; charset=utf-8'},
    });
  })());
});
