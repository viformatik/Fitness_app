#!/usr/bin/env node
'use strict';
/*
 * Exact archived +14 in a fresh synthetic browser context versus a synthetic
 * atomic IndexedDB writer. The archived build itself is NOT in the repo.
 * LAB ONLY: requires a non-root, loopback-only network namespace; never run
 * against a real browser profile, account, diary or production database.
 */
const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const http = require('node:http');
const crypto = require('node:crypto');
const child = require('node:child_process');
const sha = b => crypto.createHash('sha256').update(b).digest('hex');
function refuse(message) { console.error('REFUSED BEFORE BROWSER:', message); process.exit(2); }
const [engine, rootArg, outputArg] = process.argv.slice(2);
if (!['chromium', 'firefox'].includes(engine) || !rootArg || !outputArg || process.argv.length !== 5) {
  refuse('expected chromium|firefox, extracted fixture directory, new report path');
}
const output = path.resolve(outputArg);
if (fs.existsSync(output) || !fs.existsSync(path.dirname(output))) refuse('report must be new and parent must exist');
if (process.getuid() === 0) refuse('non-root UID required');
const detail = os.networkInterfaces(), interfaces = Object.keys(detail).sort();
let main4, main6, all4, all6;
try {
  const ip = args => child.execFileSync('ip', args, {encoding: 'utf8'}).trim();
  main4 = ip(['-o', '-4', 'route', 'show', 'table', 'main']);
  main6 = ip(['-o', '-6', 'route', 'show', 'table', 'main']);
  all4 = ip(['-o', '-4', 'route', 'show', 'table', 'all']).split('\n').filter(Boolean);
  all6 = ip(['-o', '-6', 'route', 'show', 'table', 'all']).split('\n').filter(Boolean);
} catch (_) { refuse('cannot verify network routes'); }
const safeAddress = (detail.lo || []).every(x => x.internal &&
  ((x.family === 'IPv4' && x.address === '127.0.0.1') || (x.family === 'IPv6' && x.address === '::1')));
const safe4 = all4.every(x => /^(local 127\.0\.0\.(0\/8|1)|broadcast 127\.255\.255\.255) dev lo table local\b/.test(x));
const safe6 = all6.every(x => /^local ::1 dev lo table local\b/.test(x));
if (interfaces.length !== 1 || interfaces[0] !== 'lo' || !safeAddress || main4 || main6 || !safe4 || !safe6) {
  refuse('requires loopback-only namespace with only loopback routes');
}
const manifestBytes = fs.readFileSync(path.join(__dirname, 'v14_fixture_manifest.json'));
if (sha(manifestBytes) !== '211dd5c74938f4b1e0b105aef08f050112e7832a210e79d8b25b79eead34c0c2') {
  refuse('fixture manifest hash mismatch');
}
const manifest = JSON.parse(manifestBytes.toString('utf8'));
const root = fs.realpathSync(rootArg);
if (!fs.statSync(root).isDirectory()) refuse('fixture is not a directory');
const files = new Map();
function walk(dir) {
  for (const ent of fs.readdirSync(dir, {withFileTypes: true})) {
    const full = path.join(dir, ent.name), rel = path.relative(root, full).split(path.sep).join('/');
    if (ent.isSymbolicLink()) refuse('fixture contains a symbolic link');
    if (ent.isDirectory()) walk(full);
    else if (ent.isFile()) files.set(rel, fs.readFileSync(full));
    else refuse('fixture has a non-regular file');
  }
}
walk(root);
const expected = Object.keys(manifest.files).sort(), found = [...files.keys()].sort();
if (JSON.stringify(expected) !== JSON.stringify(found) ||
    expected.some(name => sha(files.get(name)) !== manifest.files[name])) {
  refuse('fixture files do not exactly match all pinned hashes');
}
const playwright = require('playwright');
const runId = crypto.randomBytes(8).toString('hex');
const fixtureDb = `fitness_synthetic_mixed_${runId}`;
const sourceSha256 = sha(fs.readFileSync(__filename));
const networkIsolation = {uid: process.getuid(), interfaces, routes4: 0, routes6: 0, allRoutesLoopbackOnly: true};
const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
const mime = name => name.endsWith('.html') ? 'text/html; charset=utf-8' :
  name.endsWith('.js') ? 'text/javascript; charset=utf-8' : name.endsWith('.json') ? 'application/json' :
  name.endsWith('.wasm') ? 'application/wasm' : name.endsWith('.png') ? 'image/png' :
  name.endsWith('.ttf') ? 'font/ttf' : name.endsWith('.otf') ? 'font/otf' : 'application/octet-stream';
async function until(fn, timeout = 45000) {
  const deadline = Date.now() + timeout;
  while (Date.now() < deadline) { const value = await fn(); if (value) return value; await sleep(150); }
  throw Error('Timed out waiting for synthetic state');
}

async function run() {
  const checks = [], risks = [], loaded = [], pending = [];
  let browser, context, origin, blocked = 0;
  const report = {
    status: 'INCOMPLETE_NOT_A_RELEASE', engine, sourceSha256, nodeVersion: process.version,
    fixtureArchiveSha256: manifest.archiveSha256, pinnedFixtureFiles: expected.length,
    mainSha256: manifest.files['main.dart.js'], workerSha256: manifest.files['fitness_worker.js'],
    networkIsolation, browserVersion: null, checks, risks, loaded,
    limitations: [
      'Exact archived +14 app is used only in an isolated fresh context. Database-name redirection, write tracing and accessibility are injected for observation.',
      'The second writer is a miniature raw IndexedDB readwrite transaction, not the real new client or a complete Hive implementation.',
      'External routes are absent and page requests are blocked except random loopback. This specific test does not cut the loopback server or test an offline restart.',
      'One selected order only. No real diary, accounts, production, crash, physical offline, Safari/iOS, Android, cloud sync, multiple devices or backup/restore.',
      'The reproduced risk does not identify a safe migration, fix or release readiness.',
    ],
  };
  const check = (name, condition, values = {}) => {
    checks.push({name, status: condition ? 'PASS' : 'FAIL', values});
    if (!condition) throw Error(name);
  };
  const risk = (name, condition, values = {}) => {
    risks.push({name, status: condition ? 'RISK_REPRODUCED' : 'UNEXPECTED', values});
    if (!condition) throw Error('Expected risk not reproduced: ' + name);
  };
  const server = http.createServer((req, res) => {
    if (req.method !== 'GET') { res.writeHead(405); return res.end(); }
    let pathname;
    try { pathname = decodeURIComponent(new URL(req.url, 'http://127.0.0.1').pathname); }
    catch (_) { res.writeHead(400); return res.end(); }
    if (pathname === '/') pathname = '/index.html';
    const name = pathname.slice(1), data = files.get(name);
    if (!data || name.startsWith('.')) { res.writeHead(404); return res.end(); }
    res.writeHead(200, {'content-type': mime(name), 'cache-control': 'no-store', 'x-content-type-options': 'nosniff'});
    res.end(data);
  });
  try {
    await new Promise((resolve, reject) => { server.once('error', reject); server.listen(0, '127.0.0.1', resolve); });
    origin = `http://127.0.0.1:${server.address().port}`;
    const opts = {headless: true};
    if (engine === 'chromium') opts.args = ['--enable-unsafe-swiftshader', '--disable-background-networking', '--no-proxy-server'];
    browser = await playwright[engine].launch(opts); report.browserVersion = browser.version();
    context = await browser.newContext({viewport: {width: 390, height: 844}, locale: 'en-US', timezoneId: 'UTC'});
    await context.route('**/*', route => {
      let allowed = false;
      try { allowed = new URL(route.request().url()).origin === origin; } catch (_) {}
      if (!allowed) { blocked++; return route.abort(); }
      return route.continue();
    });
    async function newOldPage(label) {
      const p = await context.newPage();
      p.on('response', response => {
        if (new URL(response.url()).pathname !== '/main.dart.js') return;
        const item = {page: label, sha256: null, fromServiceWorker: response.fromServiceWorker()};
        loaded.push(item);
        pending.push(response.body().then(body => { item.sha256 = sha(body); }, () => { item.error = 'body unavailable'; }));
      });
      await p.addInitScript(({dbName, runId}) => {
        window.flutterWebSemanticsEnabled = true;
        window.__syntheticWaterWrites = [];
        window.__syntheticTargetOpen = 0;
        const open = IDBFactory.prototype.open;
        IDBFactory.prototype.open = function(name, version) {
          let safe = name;
          if (name === 'fitness_v2') { safe = dbName; window.__syntheticTargetOpen++; }
          else if (name !== dbName) safe = `synthetic_other_${runId}_${String(name)}`;
          return open.call(this, safe, version);
        };
        const put = IDBObjectStore.prototype.put;
        IDBObjectStore.prototype.put = function(value, key) {
          const request = put.apply(this, arguments);
          if (this.transaction.db.name === dbName && this.name === 'box' &&
              typeof key === 'string' && key.startsWith('water_intake_')) {
            const item = {value, requestSuccess: false, completed: false, aborted: false};
            window.__syntheticWaterWrites.push(item);
            request.addEventListener('success', () => { item.requestSuccess = true; });
            this.transaction.addEventListener('complete', () => { item.completed = true; });
            this.transaction.addEventListener('abort', () => { item.aborted = true; });
          }
          return request;
        };
      }, {dbName: fixtureDb, runId});
      await p.goto(origin + '/', {waitUntil: 'load'});
      await until(async () => {
        const enable = p.getByRole('button', {name: 'Enable accessibility'});
        if (await enable.count()) await enable.first().evaluate(element => element.click());
        return (await p.getByRole('button', {name: 'Вода +250 мл', exact: true}).count()) > 0;
      }, 70000);
      return p;
    }
    const water = async p => {
      const tree = await p.locator('body').ariaSnapshot();
      const m = tree.match(/ВОДА\s+([0-9][0-9\s\u00a0\u202f]*)\s*мл/);
      return m ? Number(m[1].replace(/[\s\u00a0\u202f]/g, '')) : null;
    };
    const click = p => p.getByRole('button', {name: 'Вода +250 мл', exact: true}).first().evaluate(element => element.click());
    const dayKey = await (async () => {
      const p = await newOldPage('old-tab');
      const key = await p.evaluate(() => {
        const d = new Date(), two = n => String(n).padStart(2, '0');
        return `water_intake_${d.getFullYear()}-${two(d.getMonth() + 1)}-${two(d.getDate())}`;
      });
      return {p, key};
    })();
    const old = dayKey.p, key = dayKey.key;
    check('old page uses redirected disposable database', (await old.evaluate(() => window.__syntheticTargetOpen)) > 0);
    check('old page starts with zero synthetic water', await water(old) === 0);
    await click(old);
    await until(async () => await water(old) === 250);
    await until(async () => old.evaluate(() => window.__syntheticWaterWrites.some(x => x.value === 250 && x.completed && !x.aborted)));
    await old.evaluate(() => { window.__syntheticWaterWrites = []; });
    const other = await newOldPage('atomic-observer-tab');
    await until(async () => await water(other) === 250);
    check('both old app tabs show the seeded synthetic 250', await water(old) === 250 && await water(other) === 250);

    const raw = async (p, mode) => p.evaluate(async ({dbName, key, mode}) => {
      const db = await new Promise((resolve, reject) => {
        const req = indexedDB.open(dbName, 1);
        req.onupgradeneeded = () => req.transaction.abort();
        req.onerror = () => reject(req.error);
        req.onsuccess = () => resolve(req.result);
      });
      try {
        return await new Promise((resolve, reject) => {
          const tx = db.transaction('box', mode === 'add' ? 'readwrite' : 'readonly');
          const store = tx.objectStore('box'), req = store.get(key);
          let before = null;
          req.onsuccess = () => {
            before = req.result;
            if (mode === 'add') {
              if (typeof before !== 'number') { tx.abort(); return; }
              store.put(before + 250, key);
            }
          };
          tx.oncomplete = () => resolve({before, after: mode === 'add' ? before + 250 : before});
          tx.onerror = () => reject(tx.error);
          tx.onabort = () => reject(tx.error || new Error('synthetic transaction aborted'));
        });
      } finally { db.close(); }
    }, {dbName: fixtureDb, key, mode});
    const atomic = await raw(other, 'add');
    const afterAtomic = (await raw(other, 'read')).after;
    check('synthetic atomic transaction writes the stored value 250 to 500',
          atomic.before === 250 && atomic.after === 500 && afterAtomic === 500,
          {before: atomic.before, after: afterAtomic});
    check('exact +14 old tab still displays its stale 250 after the other writer', await water(old) === 250);
    await click(old);
    await until(async () => await water(old) === 500);
    const oldTrace = await until(async () => old.evaluate(() =>
      window.__syntheticWaterWrites.find(x => x.value === 500 && x.requestSuccess && x.completed && !x.aborted)));
    const afterOld = (await raw(other, 'read')).after;
    risk('unmodified +14 stale action overwrites the synthetic atomic increment',
         afterOld === 500 && oldTrace.completed,
         {seed: 250, syntheticAtomicAdd: 250, oldUiAdd: 250, expected: 750, actual: afterOld, oldWriteCommitted: oldTrace.completed});
    const reopened = await newOldPage('reopened-old-tab');
    await until(async () => await water(reopened) === 500);
    check('reopened +14 UI and stored synthetic value both show 500',
          await water(reopened) === 500 && (await raw(reopened, 'read')).after === 500);
    await Promise.all(pending);
    check('all three loaded main scripts match the pinned archived +14',
          ['old-tab', 'atomic-observer-tab', 'reopened-old-tab'].every(label =>
            loaded.some(x => x.page === label && x.sha256 === manifest.files['main.dart.js'])));
    report.blockedExternalPageRequests = blocked;
    report.status = 'PASS_WITH_REPRODUCED_RISK_NOT_A_RELEASE';
  } catch (error) {
    report.error = {name: error.name || 'Error', message: String(error.message || error).slice(0, 700)};
    report.blockedExternalPageRequests = blocked;
    report.status = 'FAIL_OR_INCOMPLETE_NOT_A_RELEASE';
  } finally {
    try { if (context) await context.close(); } catch (_) {}
    try { if (browser) await browser.close(); } catch (_) {}
    await new Promise(resolve => server.close(resolve));
  }
  fs.writeFileSync(output, JSON.stringify(report, null, 2) + '\n', {encoding: 'utf8', flag: 'wx', mode: 0o600});
  console.log(JSON.stringify({engine, status: report.status, browserVersion: report.browserVersion,
    passes: checks.filter(x => x.status === 'PASS').length, risks: risks.length, output}, null, 2));
  if (report.status !== 'PASS_WITH_REPRODUCED_RISK_NOT_A_RELEASE') process.exitCode = 1;
}
run().catch(error => { console.error('Probe failed:', error.name); process.exitCode = 1; });
