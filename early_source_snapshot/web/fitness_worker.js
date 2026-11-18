'use strict';

// Bump this name with every release. Only application assets are cached; diary
// data stays in the browser's Hive/IndexedDB, never in the HTTP cache.
const CACHE_NAME = 'fitness-smart-shell-3.0.0-14';
const CACHE_PREFIX = 'fitness-smart-shell-';
const CORE_FILES = [
  './',
  './index.html',
  './flutter_bootstrap.js',
  './fitness_tab_guard.js',
  './main.dart.js',
  './version.json',
  './manifest.json',
  './icons/Icon-192.png',
  './icons/Icon-512.png',
  './assets/AssetManifest.bin',
  './assets/AssetManifest.bin.json',
  './assets/FontManifest.json',
  './assets/fonts/MaterialIcons-Regular.otf',
  './assets/packages/cupertino_icons/assets/CupertinoIcons.ttf',
  './assets/shaders/ink_sparkle.frag',
  './assets/shaders/stretch_effect.frag',
  './canvaskit/canvaskit.js',
  './canvaskit/canvaskit.wasm',
  './canvaskit/chromium/canvaskit.js',
  './canvaskit/chromium/canvaskit.wasm',
];

// Flutter's font manifest can include SDK fallback or bundled family fonts in
// addition to icons. The initial page may fetch them before this worker gains
// control, so fetch-and-cache every declared font during installation rather
// than relying on the runtime fetch handler. If anything is missing, keep the
// previous complete offline shell instead of activating an unreadable one.
async function manifestFontFiles() {
  const manifestUrl = new URL('assets/FontManifest.json', self.registration.scope);
  const response = await fetch(manifestUrl, {cache: 'no-store'});
  if (!response.ok) throw new Error('Font manifest unavailable');
  const families = await response.json();
  if (!Array.isArray(families) || families.length === 0) throw new Error('Invalid font manifest');
  const assetsRoot = new URL('assets/', self.registration.scope).href;
  const files = [];
  let hasRequiredRoboto = false;
  for (const family of families) {
    if (!family || !Array.isArray(family.fonts) || family.fonts.length === 0) {
      throw new Error('Invalid font family');
    }
    for (const font of family.fonts) {
      if (!font || typeof font.asset !== 'string' ||
          font.asset.startsWith('/') || font.asset.includes('\\') ||
          font.asset.split('/').some((part) => !part || part === '.' || part === '..')) {
        throw new Error('Invalid font asset');
      }
      const url = new URL(font.asset, assetsRoot);
      if (!url.href.startsWith(assetsRoot) || url.search || url.hash) {
        throw new Error('Font asset outside app assets');
      }
      if (family.family === 'Roboto' && font.asset === 'fonts/fallback/Roboto-Regular.ttf') {
        hasRequiredRoboto = true;
      }
      files.push(url.href);
    }
  }
  if (!hasRequiredRoboto) throw new Error('Required offline Roboto font missing');
  return files;
}

self.addEventListener('install', (event) => {
  event.waitUntil((async () => {
    const cache = await caches.open(CACHE_NAME);
    try {
      // An incomplete download must not replace a working offline version.
      const fonts = await manifestFontFiles();
      const core = CORE_FILES.map((file) => new URL(file, self.registration.scope).href);
      // A previous release may have cached the manifest or an asset in the
      // browser HTTP cache. Never seed the new shell with those old bytes.
      const fresh = [...new Set([...core, ...fonts])]
        .map((url) => new Request(url, {cache: 'no-store'}));
      await cache.addAll(fresh);
    } catch (error) {
      await caches.delete(CACHE_NAME);
      throw error;
    }
    await self.skipWaiting();
  })());
});

self.addEventListener('activate', (event) => {
  event.waitUntil((async () => {
    const names = await caches.keys();
    await Promise.all(names
      .filter((name) => name.startsWith(CACHE_PREFIX) && name !== CACHE_NAME)
      .map((name) => caches.delete(name)));
    await self.clients.claim();
  })());
});

self.addEventListener('fetch', (event) => {
  const request = event.request;
  const url = new URL(request.url);
  const scope = new URL(self.registration.scope);
  if (request.method !== 'GET' || url.origin !== scope.origin ||
      !url.pathname.startsWith(scope.pathname)) return;

  const relative = url.pathname.slice(scope.pathname.length);
  if (request.mode === 'navigate') {
    // Never store navigation URLs: auth links can contain private query data.
    event.respondWith((async () => {
      try {
        return await fetch(request);
      } catch (_) {
        const cache = await caches.open(CACHE_NAME);
        return (await cache.match(new URL('index.html', scope).href)) ||
          (await cache.match(scope.href)) ||
          new Response('Нет сети. Сначала откройте приложение с интернетом.', {
            status: 503, headers: {'Content-Type': 'text/plain; charset=utf-8'},
          });
      }
    })());
    return;
  }

  // No API requests, user content, cross-origin responses, or query strings.
  const appFile = /^(?:index\.html|main\.dart\.js|flutter_bootstrap\.js|fitness_tab_guard\.js|version\.json|manifest\.json|favicon\.png|flutter\.js)$/.test(relative) ||
    /^(?:assets|canvaskit|icons)\//.test(relative);
  if (!appFile || url.search) return;

  event.respondWith((async () => {
    const cache = await caches.open(CACHE_NAME);
    try {
      // Bypass a prior release's browser HTTP cache as well as Cache Storage;
      // otherwise a long-lived FontManifest can hide newly bundled fonts.
      const response = await fetch(new Request(request, {cache: 'no-store'}));
      if (response.ok && response.type === 'basic') {
        await cache.put(request, response.clone());
      }
      return response;
    } catch (_) {
      return (await cache.match(request)) || Response.error();
    }
  })());
});
