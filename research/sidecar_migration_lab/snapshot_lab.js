/*
 * EXPERIMENTAL SYNTHETIC LAB ONLY — NOT AN APPLICATION MIGRATION OR BACKUP.
 *
 * Copies raw values to an unrelated, fresh IndexedDB name without upgrading
 * the source. A snapshot match is only an observation, NOT a writer fence,
 * cutover permission, rollback guarantee, or sanitised export. In particular,
 * raw private markers are copied. Do not use with real profiles or diaries.
 */
(() => {
  'use strict';
  if (location.hostname !== '127.0.0.1' || !['http:', 'https:'].includes(location.protocol) ||
      !isSecureContext || !window.indexedDB || !window.crypto || !crypto.subtle) {
    throw new Error('LAB_REQUIRES_SECURE_LOOPBACK');
  }
  const LEGACY = /^fitness_lab_legacy_[a-f0-9]{32}$/;
  const SIDECAR = /^fitness_lab_sidecar_[a-f0-9]{32}$/;
  const CANDIDATE = 'fitness_synthetic_candidate';
  const META_KEY = 'synthetic_snapshot';
  const MAX_ENTRIES = 1000, MAX_STRING = 100000, MAX_BUFFER = 1000000;
  const MAX_ARRAY = 512, MAX_DEPTH = 16, MAX_CANONICAL = 4000000;

  class Refusal extends Error {
    constructor(code) { super(code); this.name = 'SyntheticLabRefusal'; this.code = code; }
  }
  function sourceArgs(name, version) {
    if (!((LEGACY.test(name) && version === 1) || (name === CANDIDATE && version === 2))) {
      throw new Refusal('SOURCE_NAME_OR_VERSION_FORBIDDEN');
    }
  }
  function sidecarArg(name) {
    if (typeof name !== 'string' || !SIDECAR.test(name)) throw new Refusal('SIDECAR_NAME_FORBIDDEN');
  }
  const hex = bytes => Array.from(bytes, value => value.toString(16).padStart(2, '0')).join('');
  function numberBits(number) {
    // A JavaScript number's representation, not a claim about physical disk bytes.
    const buffer = new ArrayBuffer(8);
    new DataView(buffer).setFloat64(0, number, false);
    return hex(new Uint8Array(buffer));
  }
  function encode(value, stack, depth) {
    if (depth > MAX_DEPTH) throw new Refusal('VALUE_TOO_DEEP');
    if (value === null) return ['null'];
    if (typeof value === 'boolean') return ['bool', value];
    if (typeof value === 'number') return ['number-f64', numberBits(value)];
    if (typeof value === 'string') {
      if (value.length > MAX_STRING) throw new Refusal('STRING_TOO_LARGE');
      return ['string', value];
    }
    if (value instanceof ArrayBuffer) {
      if (value.byteLength > MAX_BUFFER) throw new Refusal('BUFFER_TOO_LARGE');
      return ['array-buffer', hex(new Uint8Array(value))];
    }
    if (Array.isArray(value)) {
      if (value.length > MAX_ARRAY || stack.has(value)) throw new Refusal('ARRAY_UNSUPPORTED');
      stack.add(value);
      const result = [];
      for (let i = 0; i < value.length; i++) {
        if (!Object.prototype.hasOwnProperty.call(value, i)) throw new Refusal('SPARSE_ARRAY_UNSUPPORTED');
        result.push(encode(value[i], stack, depth + 1));
      }
      stack.delete(value);
      return ['array', result];
    }
    // The Hive web backend used here stores other values as encoded ArrayBuffers.
    // Unknown structured-clone types are intentionally rejected, not coerced.
    throw new Refusal('VALUE_TYPE_UNSUPPORTED');
  }
  function keyEncoding(key) {
    if (typeof key === 'string') {
      if (key.length > MAX_STRING) throw new Refusal('KEY_TOO_LARGE');
      return ['key-string', key];
    }
    if (typeof key === 'number' && Number.isFinite(key)) return ['key-number', numberBits(key)];
    throw new Refusal('KEY_TYPE_UNSUPPORTED');
  }
  async function fingerprint(keys, values) {
    if (!Array.isArray(keys) || !Array.isArray(values) || keys.length !== values.length || keys.length > MAX_ENTRIES) {
      throw new Refusal('SNAPSHOT_TOO_LARGE_OR_INVALID');
    }
    const items = keys.map((key, index) => [keyEncoding(key), encode(values[index], new Set(), 0)]);
    const canonical = JSON.stringify(['fitness-sidecar-lab-v1', items]);
    if (canonical.length > MAX_CANONICAL) throw new Refusal('CANONICAL_TOO_LARGE');
    return hex(new Uint8Array(await crypto.subtle.digest('SHA-256', new TextEncoder().encode(canonical))));
  }
  function noIndexStore(db, name, tx) {
    const store = tx.objectStore(name);
    return store.keyPath === null && !store.autoIncrement && store.indexNames.length === 0;
  }
  function sourceSchema(db) {
    if (db.objectStoreNames.length !== 1 || !db.objectStoreNames.contains('box')) return false;
    const tx = db.transaction('box', 'readonly');
    return noIndexStore(db, 'box', tx);
  }
  function sidecarSchema(db) {
    if (db.objectStoreNames.length !== 2 || !db.objectStoreNames.contains('data') ||
        !db.objectStoreNames.contains('meta')) return false;
    const tx = db.transaction(['data', 'meta'], 'readonly');
    return noIndexStore(db, 'data', tx) && noIndexStore(db, 'meta', tx);
  }
  function open(name, version, kind, createSidecar = false) {
    return new Promise((resolve, reject) => {
      let request, done = false, upgradeRefused = false;
      const finish = (error, db) => {
        if (done) { if (db) db.close(); return; }
        done = true; clearTimeout(timer);
        if (error) { if (db) db.close(); reject(error); } else resolve(db);
      };
      const timer = setTimeout(() => finish(new Refusal('OPEN_TIMED_OUT_NO_FORCE')), 15000);
      try { request = indexedDB.open(name, version); }
      catch (_) { finish(new Refusal('OPEN_FAILED')); return; }
      request.onupgradeneeded = event => {
        if (done || kind !== 'sidecar' || !createSidecar || event.oldVersion !== 0) {
          upgradeRefused = true;
          try { request.transaction.abort(); } catch (_) {}
          return;
        }
        try {
          const db = request.result;
          if (db.objectStoreNames.length !== 0) throw new Error('unexpected');
          db.createObjectStore('data');
          db.createObjectStore('meta');
        } catch (_) {
          upgradeRefused = true;
          try { request.transaction.abort(); } catch (_) {}
        }
      };
      request.onerror = event => {
        event.preventDefault();
        const name = request.error && request.error.name;
        finish(new Refusal(upgradeRefused ? 'MISSING_OR_UPGRADE_REFUSED' :
          name === 'VersionError' ? 'VERSION_MISMATCH_REFUSED' : 'OPEN_FAILED'));
      };
      request.onsuccess = () => {
        const db = request.result;
        if (done) { db.close(); return; }
        try {
          if (db.version !== version || !(kind === 'source' ? sourceSchema(db) : sidecarSchema(db))) {
            throw new Refusal('SCHEMA_REFUSED');
          }
          finish(null, db);
        } catch (error) { finish(error instanceof Refusal ? error : new Refusal('SCHEMA_REFUSED'), db); }
      };
    });
  }
  function readBoth(db, dataName, includeMeta) {
    return new Promise((resolve, reject) => {
      let tx, keysRequest, valuesRequest, metaRequest;
      try {
        tx = db.transaction(includeMeta ? [dataName, 'meta'] : [dataName], 'readonly');
        const store = tx.objectStore(dataName);
        // Both requests are synchronously placed in the SAME readonly transaction.
        keysRequest = store.getAllKeys();
        valuesRequest = store.getAll();
        if (includeMeta) metaRequest = tx.objectStore('meta').get(META_KEY);
      } catch (_) { reject(new Refusal('READ_SETUP_FAILED')); return; }
      tx.oncomplete = () => resolve({
        keys: keysRequest.result, values: valuesRequest.result,
        meta: includeMeta ? metaRequest.result : undefined,
      });
      tx.onabort = () => reject(new Refusal('READ_ABORTED'));
      tx.onerror = () => {}; // terminal decision is made by oncomplete/onabort
    });
  }
  async function captureSource(name, version) {
    sourceArgs(name, version);
    const db = await open(name, version, 'source');
    try {
      const content = await readBoth(db, 'box', false);
      content.digest = await fingerprint(content.keys, content.values);
      return content;
    } finally { db.close(); }
  }
  async function captureSidecar(name) {
    sidecarArg(name);
    const db = await open(name, 1, 'sidecar', false);
    try {
      const content = await readBoth(db, 'data', true);
      content.digest = await fingerprint(content.keys, content.values);
      return content;
    } finally { db.close(); }
  }
  async function stage(name, version, sidecar, options = {}) {
    sourceArgs(name, version); sidecarArg(sidecar);
    if (!options || Object.keys(options).some(k => k !== 'injectAbortAfterFirstSuccess') ||
        (options.injectAbortAfterFirstSuccess !== undefined && options.injectAbortAfterFirstSuccess !== true)) {
      throw new Refusal('OPTION_REFUSED');
    }
    const snapshot = await captureSource(name, version); // source is read-only
    const db = await open(sidecar, 1, 'sidecar', true);
    try {
      await new Promise((resolve, reject) => {
        let tx, reason = 'STAGING_ABORTED', firstWrite = true, dataCountDone = false, metaCountDone = false;
        try {
          tx = db.transaction(['data', 'meta'], 'readwrite');
          const data = tx.objectStore('data'), meta = tx.objectStore('meta');
          const dataCount = data.count(), metaCount = meta.count();
          const abort = why => { reason = why; try { tx.abort(); } catch (_) {} };
          const observe = request => {
            if (firstWrite) {
              firstWrite = false;
              request.addEventListener('success', () => {
                if (options.injectAbortAfterFirstSuccess === true) abort('INJECTED_ABORT_AFTER_REQUEST_SUCCESS');
              });
            }
          };
          const proceed = () => {
            if (!dataCountDone || !metaCountDone) return;
            if (dataCount.result !== 0 || metaCount.result !== 0) return abort('SIDECAR_NOT_EMPTY');
            try {
              for (let i = 0; i < snapshot.keys.length; i++) observe(data.add(snapshot.values[i], snapshot.keys[i]));
              observe(meta.add({kind: 'SYNTHETIC_STAGE_ONLY', sourceName: name, sourceVersion: version,
                count: snapshot.keys.length, digest: snapshot.digest}, META_KEY));
            } catch (_) { abort('STAGE_SETUP_FAILED'); }
          };
          dataCount.onsuccess = () => { dataCountDone = true; proceed(); };
          metaCount.onsuccess = () => { metaCountDone = true; proceed(); };
        } catch (_) { reject(new Refusal('STAGE_SETUP_FAILED')); return; }
        tx.oncomplete = () => resolve();
        tx.onabort = () => reject(new Refusal(reason));
        tx.onerror = () => {}; // request success alone is NEVER counted as commit
      });
      return {state: 'STAGED_ONLY_NO_ACTIVATION', count: snapshot.keys.length, digest: snapshot.digest};
    } finally { db.close(); }
  }
  async function compare(name, version, sidecar) {
    sourceArgs(name, version); sidecarArg(sidecar);
    // Separate databases cannot be read atomically. Even MATCH is advisory only.
    const source = await captureSource(name, version);
    const target = await captureSidecar(sidecar);
    const meta = target.meta;
    const metadataMatches = !!meta && meta.kind === 'SYNTHETIC_STAGE_ONLY' &&
      meta.sourceName === name && meta.sourceVersion === version &&
      meta.count === target.keys.length && meta.digest === target.digest;
    const equal = metadataMatches && source.keys.length === target.keys.length && source.digest === target.digest;
    return {state: equal ? 'MATCH_ONLY_NO_ACTIVATION' : 'MISMATCH_NO_ACTIVATION',
      sourceCount: source.keys.length, sidecarCount: target.keys.length,
      sourceDigest: source.digest, sidecarDigest: target.digest, metadataMatches};
  }
  // No activate/cutover/delete/source-write API exists in this prototype.
  window.FitnessSidecarLab = Object.freeze({captureSource, captureSidecar, stage, compare});
})();
