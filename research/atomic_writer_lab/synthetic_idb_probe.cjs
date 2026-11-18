#!/usr/bin/env node
'use strict';
/*
 * Synthetic IndexedDB / Web Locks probe, not Fitness Smart application code.
 * Refuses to start a browser unless it is an unprivileged process in a network
 * namespace with only lo and no main IPv4/IPv6 routes. Uses fresh Playwright
 * contexts, a random local HTTP origin, and invented numeric values only.
 *
 * Usage via run_isolated.sh; never provide a user's profile, diary or account.
 */
const fs = require('node:fs');
const os = require('node:os');
const http = require('node:http');
const crypto = require('node:crypto');
const child = require('node:child_process');
const path = require('node:path');

function refuse(message) {
  console.error('REFUSED BEFORE BROWSER:', message);
  process.exit(2);
}

const [engine, outputArg] = process.argv.slice(2);
if (!['chromium', 'firefox'].includes(engine) || !outputArg || process.argv.length !== 4) {
  refuse('expected chromium|firefox and a new report path');
}
const output = path.resolve(outputArg);
if (fs.existsSync(output) || !fs.existsSync(path.dirname(output))) {
  refuse('report must not exist and its parent must exist');
}
if (process.getuid() === 0) refuse('a non-root UID is required');
const interfaceDetails = os.networkInterfaces();
const interfaces = Object.keys(interfaceDetails).sort();
let routes4, routes6, all4, all6;
try {
  const ip = args => child.execFileSync('ip', args, {encoding: 'utf8'}).trim();
  routes4 = ip(['-o', '-4', 'route', 'show', 'table', 'main']);
  routes6 = ip(['-o', '-6', 'route', 'show', 'table', 'main']);
  all4 = ip(['-o', '-4', 'route', 'show', 'table', 'all']).split('\n').filter(Boolean);
  all6 = ip(['-o', '-6', 'route', 'show', 'table', 'all']).split('\n').filter(Boolean);
} catch (_) {
  refuse('cannot verify the route tables');
}
const safeAddresses = (interfaceDetails.lo || []).every(x => x.internal &&
  ((x.family === 'IPv4' && x.address === '127.0.0.1') || (x.family === 'IPv6' && x.address === '::1')));
const safeAll4 = all4.every(x => /^(local 127\.0\.0\.(0\/8|1)|broadcast 127\.255\.255\.255) dev lo table local\b/.test(x));
const safeAll6 = all6.every(x => /^local ::1 dev lo table local\b/.test(x));
if (interfaces.length !== 1 || interfaces[0] !== 'lo' || !safeAddresses || routes4 || routes6 || !safeAll4 || !safeAll6) {
  refuse('requires a private loopback-only namespace with only loopback routes');
}
const networkIsolation = {uid: process.getuid(), interfaces, routes4: 0, routes6: 0, allRoutesLoopbackOnly: true};
const playwright = require('playwright');
const sourceSha256 = crypto.createHash('sha256').update(fs.readFileSync(__filename)).digest('hex');
const runId = crypto.randomBytes(8).toString('hex');

const html = String.raw`<!doctype html><html><head><meta charset="utf-8"><title>Disposable synthetic IDB lab</title></head><body>
<script>
(() => {
  const STORE = 'values';
  const KEY = 'fabricated_water';
  function open(name, version = 1) {
    return new Promise((resolve, reject) => {
      const req = indexedDB.open(name, version);
      req.onupgradeneeded = () => {
        if (!req.result.objectStoreNames.contains(STORE)) req.result.createObjectStore(STORE);
      };
      req.onsuccess = () => resolve(req.result);
      req.onerror = () => reject(req.error);
    });
  }
  async function read(name, version = 1) {
    const db = await open(name, version);
    try {
      return await new Promise((resolve, reject) => {
        const tx = db.transaction(STORE, 'readonly');
        const req = tx.objectStore(STORE).get(KEY);
        let value;
        req.onsuccess = () => { value = req.result; };
        tx.oncomplete = () => resolve(value);
        tx.onerror = () => reject(tx.error);
        tx.onabort = () => reject(tx.error || new Error('read aborted'));
      });
    } finally { db.close(); }
  }
  async function put(name, value, version = 1) {
    const db = await open(name, version);
    try {
      await new Promise((resolve, reject) => {
        const tx = db.transaction(STORE, 'readwrite');
        tx.objectStore(STORE).put(value, KEY);
        tx.oncomplete = resolve;
        tx.onerror = () => reject(tx.error);
        tx.onabort = () => reject(tx.error || new Error('write aborted'));
      });
    } finally { db.close(); }
  }
  async function atomicAdd(name, delta, version = 1) {
    const db = await open(name, version);
    try {
      await new Promise((resolve, reject) => {
        const tx = db.transaction(STORE, 'readwrite');
        const store = tx.objectStore(STORE);
        const req = store.get(KEY);
        req.onsuccess = () => {
          if (typeof req.result !== 'number') { tx.abort(); return; }
          store.put(req.result + delta, KEY);
        };
        tx.oncomplete = resolve;
        tx.onerror = () => reject(tx.error);
        tx.onabort = () => reject(tx.error || new Error('increment aborted'));
      });
    } finally { db.close(); }
  }
  window.lab = {open, read, put, atomicAdd};
})();
</script></body></html>`;

function add(results, name, ok, details, risk = false) {
  results.push({name, status: ok ? (risk ? 'RISK_REPRODUCED' : 'PASS') : 'FAIL', details});
}

async function run() {
  const results = [];
  const blocked = [];
  const server = http.createServer((req, res) => {
    if (req.method !== 'GET' || req.url !== '/') { res.writeHead(404); res.end(); return; }
    res.writeHead(200, {
      'content-type': 'text/html; charset=utf-8',
      'cache-control': 'no-store',
      'content-security-policy': "default-src 'none'; script-src 'unsafe-inline'; connect-src 'self'; base-uri 'none'",
      'x-content-type-options': 'nosniff',
    });
    res.end(html);
  });
  let browser, context, origin;
  const report = {
    status: 'INCOMPLETE_NOT_A_RELEASE', engine, sourceSha256,
    nodeVersion: process.version, networkIsolation, browserVersion: null,
    tests: results, blockedExternalRequests: 0,
    limitations: [
      'Synthetic miniature IndexedDB and Web Locks clients only: not the real +14 application, new application, Hive or the user diary.',
      'Fresh non-persistent Playwright context on a random loopback origin inside a network namespace; no cloud, accounts or real data.',
      'Only selected schedules were tested. No crash, power loss, real offline mode, Safari/iOS, Android, multi-device, Auth, sync, migration or backup/restore.',
      'Atomic transactions and separate databases are demonstrations, not a proposed production patch or proof of a safe rollback or merge.',
      'Two final values alone do not encode whether they arose from one copied operation or two independent operations; additional trusted provenance could change what is knowable.',
    ],
  };
  try {
    await new Promise((resolve, reject) => {
      server.once('error', reject);
      server.listen(0, '127.0.0.1', resolve);
    });
    origin = `http://127.0.0.1:${server.address().port}`;
    const options = {headless: true};
    if (engine === 'chromium') options.args = ['--disable-background-networking'];
    browser = await playwright[engine].launch(options);
    report.browserVersion = browser.version();
    context = await browser.newContext();
    await context.route('**/*', route => {
      let allowed = false;
      try { allowed = new URL(route.request().url()).origin === origin; } catch (_) {}
      if (!allowed) { blocked.push('external'); return route.abort(); }
      return route.continue();
    });
    const [a, b, c] = await Promise.all([context.newPage(), context.newPage(), context.newPage()]);
    await Promise.all([a, b, c].map(p => p.goto(origin + '/', {waitUntil: 'load'})));
    add(results, 'fresh loopback test pages loaded',
        (await Promise.all([a, b, c].map(p => p.evaluate(() => !!window.lab && isSecureContext)))).every(Boolean),
        {pages: 3, secureContextOnLoopback: true});

    // Two updated writers each read and write within one readwrite transaction.
    const atomicResults = [];
    for (let i = 0; i < 10; i++) {
      const db = `synthetic_atomic_${runId}_${i}`;
      await a.evaluate(db => window.lab.put(db, 250), db);
      await Promise.all([a, b].map(p => p.evaluate(db => window.lab.atomicAdd(db, 250), db)));
      atomicResults.push(await c.evaluate(db => window.lab.read(db), db));
    }
    add(results, 'two synthetic atomic writers preserve both increments in ten sampled rounds',
        atomicResults.length === 10 && atomicResults.every(x => x === 750),
        {seed: 250, increments: [250, 250], observed: atomicResults, expected: 750});

    // One unmodified-style client reads outside the eventual write transaction.
    const mixed = `synthetic_mixed_${runId}`;
    await a.evaluate(db => window.lab.put(db, 250), mixed);
    const stale = await a.evaluate(db => window.lab.read(db), mixed);
    await b.evaluate(db => window.lab.atomicAdd(db, 250), mixed);
    const afterNew = await c.evaluate(db => window.lab.read(db), mixed);
    await a.evaluate(({db, value}) => window.lab.put(db, value + 250), {db: mixed, value: stale});
    const afterLegacy = await c.evaluate(db => window.lab.read(db), mixed);
    add(results, 'stale synthetic legacy-style write can erase an atomic writer action',
        stale === 250 && afterNew === 500 && afterLegacy === 500,
        {initial: 250, legacySnapshot: stale, afterNew, afterLegacy, expectedForThreeActions: 750}, true);

    // Native Web Locks only coordinate participants that ask for the same lock.
    const lockSupported = await a.evaluate(() => !!navigator.locks && typeof navigator.locks.query === 'function');
    if (!lockSupported) {
      results.push({name: 'Web Locks behavior', status: 'SKIP', details: 'Web Locks query API unavailable'});
    } else {
      const lockName = `synthetic_lock_${runId}`;
      const lockDb = `synthetic_lock_db_${runId}`;
      await a.evaluate(db => window.lab.put(db, 250), lockDb);
      await a.evaluate(async name => {
        let started;
        const ready = new Promise(resolve => { started = resolve; });
        window.__holdDone = navigator.locks.request(name, async () => {
          await new Promise(resolve => { window.__releaseHold = resolve; started(); });
        });
        await ready;
      }, lockName);
      await b.evaluate(name => {
        window.__contenderAcquired = false;
        window.__contenderDone = navigator.locks.request(name, () => { window.__contenderAcquired = true; });
      }, lockName);
      await a.waitForFunction(async name => {
        const q = await navigator.locks.query();
        return q.held.some(x => x.name === name) && q.pending.some(x => x.name === name);
      }, lockName, {timeout: 8000});
      const queuedBefore = !(await b.evaluate(() => window.__contenderAcquired));
      await c.evaluate(db => window.lab.put(db, 500), lockDb); // no lock requested
      const rawDuringLock = await c.evaluate(db => window.lab.read(db), lockDb);
      const queuedAfterWrite = !(await b.evaluate(() => window.__contenderAcquired));
      await a.evaluate(() => window.__releaseHold());
      await Promise.all([a.evaluate(() => window.__holdDone), b.evaluate(() => window.__contenderDone)]);
      const acquiredAfter = await b.evaluate(() => window.__contenderAcquired);
      add(results, 'lock-aware contender waits and then acquires after release',
          queuedBefore && queuedAfterWrite && acquiredAfter,
          {queuedBefore, queuedAfterWrite, acquiredAfter});
      add(results, 'uncooperative synthetic writer modifies IndexedDB while Web Lock is held',
          rawDuringLock === 500 && queuedAfterWrite,
          {valueWhileLocked: rawDuringLock, lockAwareContenderStillWaiting: queuedAfterWrite}, true);
    }

    // Observe a version upgrade blocked by an open v1 connection, then rollback.
    const upgradeDb = `synthetic_upgrade_${runId}`;
    await a.evaluate(async db => { await window.lab.put(db, 250); window.__v1 = await window.lab.open(db, 1); }, upgradeDb);
    await b.evaluate(db => {
      window.__sawBlocked = false;
      window.__upgradeDone = new Promise((resolve, reject) => {
        const req = indexedDB.open(db, 2);
        req.onblocked = () => { window.__sawBlocked = true; };
        req.onerror = () => reject(req.error);
        req.onsuccess = () => { const version = req.result.version; req.result.close(); resolve(version); };
      });
    }, upgradeDb);
    await b.waitForFunction(() => window.__sawBlocked, null, {timeout: 8000});
    await a.evaluate(() => window.__v1.close());
    const upgraded = await b.evaluate(() => window.__upgradeDone);
    const preserved = await c.evaluate(db => window.lab.read(db, 2), upgradeDb);
    const legacyOpen = await a.evaluate(async db => {
      try { const handle = await window.lab.open(db, 1); handle.close(); return 'opened'; }
      catch (error) { return error.name; }
    }, upgradeDb);
    add(results, 'v2 waits for open v1 connection and keeps synthetic value',
        upgraded === 2 && preserved === 250, {blockedObserved: true, upgraded, preserved});
    add(results, 'explicit synthetic v1 reopen after v2 returns VersionError',
        legacyOpen === 'VersionError', {legacyOpen}, true);

    // Distinct DBs can avoid a version collision but equal values hide history.
    const h1a = `synthetic_fork_a_${runId}`;
    const h1b = `synthetic_fork_b_${runId}`;
    const h2a = `synthetic_copy_a_${runId}`;
    const h2b = `synthetic_copy_b_${runId}`;
    await a.evaluate(async dbs => {
      await window.lab.put(dbs.h1a, 250, 1);
      await window.lab.put(dbs.h1b, 250, 2);
      await window.lab.put(dbs.h2a, 250, 1);
    }, {h1a, h1b, h2a});
    await Promise.all([
      a.evaluate(db => window.lab.atomicAdd(db, 250, 1), h1a),
      b.evaluate(db => window.lab.atomicAdd(db, 250, 2), h1b),
    ]);
    await a.evaluate(db => window.lab.atomicAdd(db, 250, 1), h2a);
    const copied = await a.evaluate(db => window.lab.read(db, 1), h2a);
    await b.evaluate(({db, value}) => window.lab.put(db, value, 2), {db: h2b, value: copied});
    const h1 = await Promise.all([a.evaluate(db => window.lab.read(db, 1), h1a), b.evaluate(db => window.lab.read(db, 2), h1b)]);
    const h2 = await Promise.all([a.evaluate(db => window.lab.read(db, 1), h2a), b.evaluate(db => window.lab.read(db, 2), h2b)]);
    add(results, 'separate synthetic database names allow v1 and v2 opens',
        h1[0] === 500 && h1[1] === 500, {v1Value: h1[0], v2Value: h1[1]});
    add(results, 'same final pair can come from two increments or one copied increment',
        h1.join(',') === '500,500' && h2.join(',') === '500,500',
        {twoIndependentIncrements: {values: h1, intendedTotal: 750},
         oneIncrementThenCopy: {values: h2, intendedTotal: 500}}, true);

    report.blockedExternalRequests = blocked.length;
    const failed = results.filter(x => x.status === 'FAIL').length;
    const skipped = results.filter(x => x.status === 'SKIP').length;
    report.status = failed ? 'FAIL_NOT_A_RELEASE' : skipped ? 'PARTIAL_SKIPS_NOT_A_RELEASE' : 'PASS_WITH_REPRODUCED_RISKS_NOT_A_RELEASE';
  } catch (error) {
    report.error = {name: error.name || 'Error', message: String(error.message || error).slice(0, 1000)};
    report.status = 'FAIL_OR_INCOMPLETE_NOT_A_RELEASE';
  } finally {
    try { if (context) await context.close(); } catch (_) {}
    try { if (browser) await browser.close(); } catch (_) {}
    await new Promise(resolve => server.close(resolve));
  }
  // 'wx' never overwrites a prior report or follows an existing final symlink.
  fs.writeFileSync(output, JSON.stringify(report, null, 2) + '\n', {encoding: 'utf8', flag: 'wx', mode: 0o600});
  console.log(JSON.stringify({engine, status: report.status, browserVersion: report.browserVersion,
    counts: results.reduce((acc, x) => (acc[x.status] = (acc[x.status] || 0) + 1, acc), {}), output}, null, 2));
  if (!report.status.startsWith('PASS_WITH_REPRODUCED_RISKS')) process.exitCode = 1;
}
run().catch(error => { console.error('Probe failed:', error.name); process.exitCode = 1; });
