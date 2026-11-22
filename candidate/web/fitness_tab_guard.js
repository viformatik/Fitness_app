/*
 * RECONSTRUCTED SYNTHETIC EXPERIMENT. Not an application migration or release.
 * Only disposable data on 127.0.0.1 in an isolated network namespace.
 * The v2 fence intentionally makes an ordinary v1 rollback fail.
 */
(() => {
  'use strict';
  const SHELL_ID = '__SYNTHETIC_SHELL_ID__'; // replaced in the built copy only
  const databaseName = 'fitness_synthetic_candidate';
  const lockName = 'fitness-synthetic-candidate-writer-v2';
  const loading = document.getElementById('loading');
  if (!loading) return;
  let retired = false, launched = false, acquired = false, keeper = null;
  window.fitnessSyntheticFenceReady = false;

  function render(title, detail, retry = true) {
    loading.replaceChildren();
    loading.classList.add('guard-message');
    loading.setAttribute('role', 'alert');
    loading.setAttribute('aria-label', title);
    const heading = document.createElement('strong'); heading.textContent = title;
    const text = document.createElement('p'); text.textContent = detail;
    loading.append(heading, text);
    if (retry) {
      const button = document.createElement('button'); button.type = 'button';
      button.textContent = 'Проверить снова';
      button.addEventListener('click', () => location.reload());
      loading.append(button);
    }
  }
  function unsupported() {
    render('Защита тестовых вкладок недоступна',
      'Для теста нужны Web Locks, IndexedDB и service worker. Открытие без защиты не предусмотрено.');
  }
  function stopPage() {
    if (retired) return;
    retired = true;
    window.fitnessGuardRetired = true;
    window.fitnessSyntheticFenceReady = false;
    const failure = () => new DOMException('Тестовую вкладку нужно открыть заново', 'AbortError');
    const wrap = (prototype, method, applies) => {
      if (!prototype || typeof prototype[method] !== 'function') return;
      try {
        const original = prototype[method];
        prototype[method] = function (...args) {
          if (retired && applies(this, args)) throw failure();
          return original.apply(this, args);
        };
      } catch (_) { /* Fail closed visually if native properties are immutable. */ }
    };
    const isDiary = db => { try { return db.name === databaseName; } catch (_) { return true; } };
    wrap(window.IDBFactory && IDBFactory.prototype, 'open', (_, args) => args[0] === databaseName);
    wrap(window.IDBFactory && IDBFactory.prototype, 'deleteDatabase', (_, args) => args[0] === databaseName);
    wrap(window.IDBDatabase && IDBDatabase.prototype, 'transaction', db => isDiary(db));
    for (const method of ['put', 'add', 'delete', 'clear']) {
      wrap(window.IDBObjectStore && IDBObjectStore.prototype, method, store => isDiary(store.transaction.db));
    }
    for (const method of ['update', 'delete']) {
      wrap(window.IDBCursor && IDBCursor.prototype, method, cursor => {
        const source = cursor.source; return isDiary((source.objectStore || source).transaction.db);
      });
    }
    for (const method of ['setItem', 'removeItem', 'clear']) wrap(window.Storage && Storage.prototype, method, () => true);
    wrap(window.XMLHttpRequest && XMLHttpRequest.prototype, 'send', () => true);
    if (typeof window.fetch === 'function') {
      try { const original = window.fetch; window.fetch = (...args) => retired ? Promise.reject(failure()) : original(...args); }
      catch (_) { /* visual cover still applies */ }
    }
    if (!loading.isConnected) document.body.append(loading);
    render('Работа тестовой вкладки остановлена',
      'Закройте другие тестовые вкладки и откройте эту снова. Не очищайте данные браузера.');
  }
  addEventListener('pagehide', event => { if (event.persisted) stopPage(); }, true);
  addEventListener('pageshow', event => {
    if (!event.persisted) return;
    stopPage(); event.stopImmediatePropagation(); location.reload();
  }, true);

  const delay = ms => new Promise(resolve => setTimeout(resolve, ms));
  function status(worker) {
    return new Promise(resolve => {
      if (!worker || typeof MessageChannel !== 'function') return resolve(null);
      const channel = new MessageChannel(); let finished = false;
      const done = value => { if (finished) return; finished = true; clearTimeout(timer); channel.port1.close(); resolve(value); };
      const timer = setTimeout(() => done(null), 4000);
      channel.port1.onmessage = event => done(event.data);
      try { worker.postMessage({type: 'FITNESS_SYNTHETIC_SHELL_STATUS'}, [channel.port2]); } catch (_) { done(null); }
    });
  }
  async function verifyShell() {
    let registration = await navigator.serviceWorker.getRegistration();
    if (!registration) registration = await navigator.serviceWorker.register('fitness_worker.js', {updateViaCache: 'none'});
    else {
      navigator.serviceWorker.register('fitness_worker.js', {updateViaCache: 'none'}).catch(() => {});
      registration.update().catch(() => {});
    }
    const deadline = Date.now() + 90000;
    let installer = registration.installing || registration.waiting;
    while (!retired && Date.now() < deadline) {
      installer ||= registration.installing || registration.waiting;
      const controller = navigator.serviceWorker.controller;
      if (controller) {
        const result = await status(controller);
        if (result && result.id === SHELL_ID) {
          if (result.ok === true && Number.isInteger(result.files) && result.files > 0 &&
              navigator.serviceWorker.controller === controller) return;
          throw Error('Synthetic cached shell failed verification');
        }
      }
      if (installer && installer.state === 'redundant') throw Error('Synthetic worker installation failed');
      await delay(250);
    }
    throw Error('Synthetic shell not verified');
  }
  function validStore(db, tx) {
    if (db.objectStoreNames.length !== 1 || !db.objectStoreNames.contains('box')) return false;
    const store = tx.objectStore('box');
    return store.keyPath === null && !store.autoIncrement && store.indexNames.length === 0;
  }
  function acquireVersionFence() {
    return new Promise((resolve, reject) => {
      let request;
      try { request = indexedDB.open(databaseName, 2); } catch (error) { reject(error); return; }
      request.onblocked = () => {
        if (!retired) render('Другая тестовая вкладка ещё использует дневник',
          'Завершите сохранение и закройте другую вкладку. Закрытие не будет принудительным.');
      };
      request.onupgradeneeded = event => {
        const db = request.result, tx = request.transaction;
        try {
          if (retired) throw Error('Retired during upgrade');
          if (event.oldVersion === 0) {
            if (db.objectStoreNames.length) throw Error('Unexpected new schema');
            db.createObjectStore('box');
          } else if (event.oldVersion !== 1 || !validStore(db, tx)) throw Error('Unexpected old schema');
        } catch (_) { try { tx.abort(); } catch (_) {} }
      };
      request.onerror = event => { event.preventDefault(); reject(request.error || Error('Synthetic open failed')); };
      request.onsuccess = () => {
        const db = request.result;
        try {
          if (retired || db.version !== 2 || !validStore(db, db.transaction('box', 'readonly'))) throw Error('Unexpected schema');
          keeper = db;
          db.onversionchange = () => stopPage(); // keep connection until page closes
          db.onclose = () => stopPage();
          resolve();
        } catch (error) { db.close(); reject(error); }
      };
    });
  }
  function loadFlutter() {
    if (retired || launched || !keeper) return;
    launched = true; window.fitnessSyntheticFenceReady = true;
    render('Тестовая версия Fitness Smart', 'Открываем вымышленный дневник…', false);
    const script = document.createElement('script'); script.src = 'flutter_bootstrap.js'; script.async = true;
    script.onerror = () => { if (!retired) render('Тест не загрузился', 'Повторите запуск. Не очищайте данные браузера.'); };
    document.body.append(script);
  }
  async function start() {
    if (location.hostname !== '127.0.0.1' || !['http:', 'https:'].includes(location.protocol) || SHELL_ID.startsWith('__')) {
      render('Только изолированный синтетический тест', 'Эта сборка не предназначена для рабочего сайта и реальных записей.', false);
      return;
    }
    let locks; try { locks = navigator.locks; } catch (_) { unsupported(); return; }
    if (!isSecureContext || !locks || typeof locks.request !== 'function' || !window.indexedDB || !('serviceWorker' in navigator)) {
      unsupported(); return;
    }
    try {
      await locks.request(lockName, {mode: 'exclusive', ifAvailable: true}, async lock => {
        if (!lock) {
          render('Тестовый дневник уже открыт', 'Закройте другие тестовые вкладки. Блокировка не передаётся принудительно.');
          return;
        }
        acquired = true;
        render('Проверяем офлайн-оболочку', 'Только вымышленные данные. Подождите.', false);
        try { await verifyShell(); }
        catch (_) { if (!retired) render('Тестовая офлайн-оболочка не готова', 'Оболочка не установлена или повреждена. База не менялась.'); return; }
        if (retired) return;
        render('Проверяем тестовое хранилище', 'Ожидаем безопасного доступа.', false);
        try { await acquireVersionFence(); }
        catch (_) { if (!retired) render('Не удалось безопасно открыть тестовый дневник', 'Проверьте хранилище. Не очищайте данные браузера.'); return; }
        if (retired) return;
        loadFlutter();
        await new Promise(() => {}); // lifetime lock: never steal or force transfer
      });
    } catch (_) { if (!retired) { if (acquired || launched) stopPage(); else unsupported(); } }
  }
  start();
})();
