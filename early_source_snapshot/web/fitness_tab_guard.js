/*
 * Fitness Smart web startup guard.
 *
 * A Hive box keeps a synchronous in-memory copy of IndexedDB. Serializing
 * individual writes is therefore insufficient: a second open box may write
 * an old snapshot. Cooperating pages must hold the same Web Lock for their
 * entire lifetime, before Flutter or Hive is loaded. Never steal the lock.
 *
 * The aborted IndexedDB upgrade detects an already-open version-1 connection,
 * including the current legacy client. It does not change the schema or data.
 * It is only a startup check: an uncooperative old page opened later can still
 * race. See TAB_SAFETY.md before enabling this in a production release.
 */
(() => {
  'use strict';

  const lockName = 'fitness-smart-diary-writer-v1';
  const databaseName = 'fitness_v2';
  const loading = document.getElementById('loading');
  if (!loading) return; // Never start Flutter if the safety UI is absent.

  let launched = false;
  let retired = false;
  let acquired = false;
  let fenceInstalled = false;

  function render(title, detail, options = {}) {
    loading.replaceChildren();
    loading.setAttribute('aria-label', title);
    loading.setAttribute('role', options.alert ? 'alert' : 'status');
    loading.classList.add('guard-message');

    const heading = document.createElement('strong');
    heading.textContent = title;
    const paragraph = document.createElement('p');
    paragraph.textContent = detail;
    loading.append(heading, paragraph);

    if (options.retry) {
      const button = document.createElement('button');
      button.type = 'button';
      button.textContent = 'Проверить снова';
      button.addEventListener('click', () => window.location.reload());
      loading.append(button);
    }
    if (options.unsafeContinue) {
      const button = document.createElement('button');
      button.type = 'button';
      button.className = 'guard-secondary';
      button.textContent = 'Открыть без защиты';
      button.addEventListener('click', async () => {
        const ok = window.confirm(
          'Без поддержки блокировок одновременная работа вкладок может потерять данные. ' +
          'Вы закрыли все другие вкладки и установленное приложение на этом устройстве?'
        );
        if (!ok || retired || launched) return;
        button.disabled = true;
        await startWithoutLock();
      });
      loading.append(button);
    }
  }

  function busyMessage() {
    render(
      'Дневник уже открыт',
      'Закройте другие вкладки Fitness Smart и установленное приложение на этом устройстве, ' +
      'в том числе вкладки со старой версией. Затем нажмите «Проверить снова». ' +
      'Старые версии не поддерживают эту защиту.',
      {retry: true, alert: true}
    );
  }

  function storageMessage() {
    render(
      'Не удалось безопасно открыть дневник',
      'Локальное хранилище недоступно или имеет неожиданную версию. ' +
      'Не очищайте данные браузера. Закройте другие вкладки, проверьте место и повторите.',
      {retry: true, alert: true}
    );
  }

  function unsupportedMessage() {
    render(
      'Защита вкладок недоступна',
      'Обновите браузер и откройте сайт по защищённому адресу. Без защиты используйте ' +
      'только одну вкладку: одновременные изменения могут потеряться. Старая версия ' +
      'не понимает эту блокировку.',
      {retry: true, unsafeContinue: true, alert: true}
    );
  }

  function lostMessage() {
    render(
      'Работа этой вкладки остановлена',
      'Блокировка была потеряна или страница была восстановлена браузером. ' +
      'Закройте остальные вкладки и нажмите «Проверить снова». ' +
      'Несохранённый текст может потребовать повторного ввода.',
      {retry: true, alert: true}
    );
  }

  function failure() {
    return new DOMException('Дневник требует повторного открытия', 'AbortError');
  }

  // Called only after this document can no longer safely use its in-memory
  // snapshot (bfcache restoration or an unexpectedly lost Web Lock). Existing
  // requests may already have reached a server; CAS remains necessary. This
  // is not a defense against uncooperative old pages or arbitrary JS tampering.
  function fenceRetiredPage() {
    retired = true;
    // Prevent a late flutter-first-frame event from uncovering a retired UI.
    window.fitnessGuardRetired = true;
    if (fenceInstalled) return;
    fenceInstalled = true;
    const wrap = (prototype, name, test) => {
      if (!prototype || typeof prototype[name] !== 'function') return;
      try {
        const original = prototype[name];
        prototype[name] = function (...args) {
          if (retired && test(this, args)) throw failure();
          return original.apply(this, args);
        };
      } catch (_) {
        // The page will be reloaded or remains covered. Some browsers may
        // make native methods non-writable: this fence is defense in depth.
      }
    };
    const any = () => true;
    const isDiary = db => {
      try { return db && db.name === databaseName; } catch (_) { return true; }
    };
    wrap(window.IDBFactory && IDBFactory.prototype, 'open', (_, args) => args[0] === databaseName);
    wrap(window.IDBFactory && IDBFactory.prototype, 'deleteDatabase', (_, args) => args[0] === databaseName);
    wrap(window.IDBDatabase && IDBDatabase.prototype, 'transaction', db => isDiary(db));
    for (const name of ['put', 'add', 'delete', 'clear']) {
      wrap(window.IDBObjectStore && IDBObjectStore.prototype, name, store => isDiary(store.transaction.db));
    }
    for (const name of ['update', 'delete']) {
      wrap(window.IDBCursor && IDBCursor.prototype, name, cursor => {
        const source = cursor.source;
        return isDiary((source.objectStore || source).transaction.db);
      });
    }
    wrap(window.Storage && Storage.prototype, 'setItem', any);
    wrap(window.Storage && Storage.prototype, 'removeItem', any);
    wrap(window.Storage && Storage.prototype, 'clear', any);
    wrap(window.XMLHttpRequest && XMLHttpRequest.prototype, 'send', any);
    if (typeof window.fetch === 'function') {
      try {
        const originalFetch = window.fetch;
        window.fetch = function (...args) {
          return retired ? Promise.reject(failure()) : originalFetch.apply(this, args);
        };
      } catch (_) {}
    }
  }

  // Do not release the lock on pagehide: an unfinished IndexedDB transaction
  // may still be committing. If the browser restores a cached page, discard
  // its old Hive snapshot and acquire a fresh lock on a full reload. Fence
  // before other pagehide listeners can schedule additional writes.
  window.addEventListener('pagehide', event => {
    if (!event.persisted) return;
    fenceRetiredPage();
    // If navigation is interrupted, never leave a usable-looking stale UI.
    if (!loading.isConnected) document.body.append(loading);
    lostMessage();
  }, true);
  window.addEventListener('pageshow', event => {
    if (!event.persisted) return;
    fenceRetiredPage();
    event.stopImmediatePropagation();
    // Avoid exposing the old Flutter canvas during the navigation.
    if (!loading.isConnected) document.body.append(loading);
    lostMessage();
    window.location.reload();
  }, true);

  // Request version 2 solely to learn whether a version-1 connection remains
  // open. Aborting synchronously in onupgradeneeded rolls the version change
  // back; no object store or record is created, changed or deleted. If an old
  // client holds the database open, wait for it to close. This probe can miss
  // a legacy client opened later, one which closes on versionchange, or one
  // that has not opened Hive yet. It is not a permanent old-client lock.
  function checkExistingConnections() {
    return new Promise((resolve, reject) => {
      if (!window.indexedDB) return reject(new Error('IndexedDB unavailable'));
      let request;
      try { request = indexedDB.open(databaseName, 2); }
      catch (error) { reject(error); return; }
      let abortedUpgrade = false;
      request.onblocked = () => {
        if (retired) return;
        render(
          'Другая вкладка ещё использует дневник',
          'Сохраните изменения и закройте другие вкладки Fitness Smart и установленное ' +
          'приложение на этом устройстве, в том числе старые версии. Дневник откроется ' +
          'после закрытия подключения. Если этого не произошло, проверьте снова.',
          {retry: true, alert: true}
        );
      };
      request.onupgradeneeded = event => {
        // Hive 2.2.3 opens this box at version 1. Refuse unknown layouts.
        abortedUpgrade = event.oldVersion === 0 || event.oldVersion === 1;
        try { request.transaction.abort(); }
        catch (error) { reject(error); }
      };
      request.onerror = event => {
        event.preventDefault();
        if (abortedUpgrade && request.error && request.error.name === 'AbortError') resolve();
        else reject(request.error || new Error('Unexpected IndexedDB error'));
      };
      request.onsuccess = () => {
        // Existing version 2 (or another unexpected state): do not open it.
        request.result.close();
        reject(new Error('Unexpected IndexedDB version'));
      };
    });
  }

  function loadFlutter() {
    if (retired || launched) return;
    launched = true;
    render('Fitness Smart', 'Открываем дневник…');
    const script = document.createElement('script');
    script.src = 'flutter_bootstrap.js';
    script.async = true;
    script.onerror = () => {
      if (retired) return;
      render(
        'Приложение не загрузилось',
        'Проверьте подключение или повторите запуск. Не очищайте данные браузера.',
        {retry: true, alert: true}
      );
    };
    document.body.append(script);
  }

  async function startWithoutLock() {
    try {
      render('Проверяем хранилище', 'Подождите, пока завершится проверка.');
      await checkExistingConnections();
      loadFlutter();
    } catch (_) {
      if (!retired) storageMessage();
    }
  }

  async function startWithLock() {
    let lockManager;
    try { lockManager = navigator.locks; }
    catch (_) { unsupportedMessage(); return; }
    if (!window.isSecureContext || !lockManager ||
        typeof lockManager.request !== 'function') {
      unsupportedMessage();
      return;
    }
    try {
      await lockManager.request(lockName, {mode: 'exclusive', ifAvailable: true}, async lock => {
        if (!lock) { busyMessage(); return; }
        acquired = true;
        try { await checkExistingConnections(); }
        catch (_) { if (!retired) storageMessage(); return; }
        if (retired) return;
        loadFlutter();
        // Intentionally hold until document destruction. No heartbeat, timeout,
        // automatic transfer, or forced steal can make a stale page safe.
        await new Promise(() => {});
      });
    } catch (_) {
      if (retired) return;
      if (acquired || launched) {
        fenceRetiredPage();
        if (!loading.isConnected) document.body.append(loading);
        lostMessage();
      } else {
        unsupportedMessage();
      }
    }
  }

  startWithLock();
})();
