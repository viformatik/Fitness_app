'use strict';

// Bump this name with every release. Only application assets are cached; diary
// data stays in the browser's Hive/IndexedDB, never in the HTTP cache.
const CACHE_NAME = 'fitness-smart-shell-3.0.0-14';
const CACHE_PREFIX = 'fitness-smart-shell-';
const CORE_FILES = [
  './',
  './index.html',
  './flutter_bootstrap.js',
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

self.addEventListener('install', (event) => {
  event.waitUntil((async () => {
    const cache = await caches.open(CACHE_NAME);
    try {
      // An incomplete download must not replace a working offline version.
      await cache.addAll(CORE_FILES);
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
  const appFile = /^(?:index\.html|main\.dart\.js|flutter_bootstrap\.js|version\.json|manifest\.json|favicon\.png|flutter\.js)$/.test(relative) ||
    /^(?:assets|canvaskit|icons)\//.test(relative);
  if (!appFile || url.search) return;

  event.respondWith((async () => {
    const cache = await caches.open(CACHE_NAME);
    try {
      // Network first prevents a cached old release from blocking updates.
      const response = await fetch(request);
      if (response.ok && response.type === 'basic') {
        await cache.put(request, response.clone());
      }
      return response;
    } catch (_) {
      return (await cache.match(request)) || Response.error();
    }
  })());
});
