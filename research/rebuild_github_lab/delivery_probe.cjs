#!/usr/bin/env node
'use strict';
/* Synthetic-only, local (non-isolated) browser probe for HANDOFF/EXECUTION BRIEF §5.3.
 * NOT the run_isolated.sh harness: this runs in an ordinary Windows profile,
 * no network namespace, no real diary or account. Reports are honest about it.
 */
const fs = require('node:fs');
const path = require('node:path');
const http = require('node:http');
const crypto = require('node:crypto');
const playwright = require('playwright');
const sha = b => crypto.createHash('sha256').update(b).digest('hex');

const [engine, buildArg, outArg] = process.argv.slice(2);
if (!['chromium', 'firefox'].includes(engine) || !buildArg || !outArg) {
  console.error('usage: delivery_probe.cjs <chromium|firefox> <build/web> <new-report.json>');
  process.exit(2);
}
const build = path.resolve(buildArg), output = path.resolve(outArg);
if (!fs.existsSync(build) || fs.existsSync(output) || !fs.existsSync(path.dirname(output))) {
  console.error('build must exist and the report must be new in an existing directory');
  process.exit(2);
}
const files = new Map();
(function walk(dir) {
  for (const ent of fs.readdirSync(dir, { withFileTypes: true })) {
    const full = path.join(dir, ent.name);
    if (ent.isDirectory()) walk(full);
    else if (ent.isFile()) files.set(path.relative(build, full).split(path.sep).join('/'), fs.readFileSync(full));
  }
})(build);
const mime = n => n.endsWith('.html') ? 'text/html; charset=utf-8' : n.endsWith('.js') ? 'text/javascript; charset=utf-8'
  : n.endsWith('.json') ? 'application/json' : n.endsWith('.wasm') ? 'application/wasm'
  : n.endsWith('.png') ? 'image/png' : n.endsWith('.ttf') ? 'font/ttf'
  : n.endsWith('.otf') ? 'font/otf' : 'application/octet-stream';

const checks = [], risks = [], errors = [];
const check = (name, condition, values = {}) => {
  checks.push({ name, status: condition ? 'PASS' : 'FAIL', values });
  if (!condition) throw Error(name);
};
const sleep = ms => new Promise(r => setTimeout(r, ms));
async function until(fn, timeout = 45000) {
  const end = Date.now() + timeout;
  while (Date.now() < end) { const r = await fn(); if (r) return r; await sleep(150); }
  throw Error('timed out waiting for a synthetic condition');
}

const report = {
  status: 'INCOMPLETE_NOT_A_RELEASE', scenario: 'delivery fallback (no navigator.share / canShare false)',
  engine, isolation: 'NOT isolated: ordinary local profile, no network namespace',
  probeSha256: sha(fs.readFileSync(__filename)), buildFiles: files.size,
  browserVersion: null, checks, risks, errors,
  limitations: [
    'Local Playwright probe, not the isolated run_isolated.sh harness (bash/ip/unshare unavailable here).',
    'Synthetic water in a disposable browser profile only; no real diary, account or cloud.',
    'A stubbed navigator.share/canShare is not proof of an operating-system share sheet.',
    'Firefox and Chromium only; Safari/iOS and Android are not covered.'
  ]
};

(async () => {
  const server = http.createServer((req, res) => {
    let name;
    try { name = decodeURIComponent(new URL(req.url, 'http://127.0.0.1').pathname).slice(1) || 'index.html'; }
    catch (_) { res.writeHead(400); return res.end(); }
    if (name.startsWith('.') || name.includes('..') || name.includes('\\')) { res.writeHead(404); return res.end(); }
    const bytes = files.get(name);
    if (!bytes) { res.writeHead(404); return res.end(); }
    res.writeHead(200, { 'content-type': mime(name), 'cache-control': 'no-store' });
    res.end(bytes);
  });
  let browser;
  try {
    await new Promise((resolve, reject) => { server.once('error', reject); server.listen(0, '127.0.0.1', resolve); });
    const origin = `http://127.0.0.1:${server.address().port}`;
    const launch = { headless: true };
    if (engine === 'chromium') launch.args = ['--enable-unsafe-swiftshader', '--no-proxy-server'];
    browser = await playwright[engine].launch(launch);
    report.browserVersion = browser.version();

    async function freshPage(breakShare) {
      const context = await browser.newContext({ viewport: { width: 390, height: 844 }, locale: 'ru-RU', timezoneId: 'UTC', acceptDownloads: true });
      await context.addInitScript(({ breakShare }) => {
        window.__shareCalls = [];
        if (breakShare) {
          delete Navigator.prototype.share;
          Object.defineProperty(navigator, 'canShare', { configurable: true, value: () => false });
        } else {
          Object.defineProperty(navigator, 'canShare', { configurable: true, value: () => true });
          Object.defineProperty(navigator, 'share', {
            configurable: true,
            value: async data => { window.__shareCalls.push({ files: (data.files || []).map(f => f.name || 'unnamed') }); }
          });
        }
      }, { breakShare });
      const page = await context.newPage();
      page.setDefaultTimeout(20000);
      page.on('pageerror', e => errors.push(String(e).slice(0, 400)));
      await page.goto(origin + '/', { waitUntil: 'load', timeout: 60000 });
      const enable = page.getByRole('button', { name: 'Enable accessibility' });
      const waterButton = page.getByRole('button', { name: 'Вода +250 мл', exact: true });
      await until(async () => {
        if (await waterButton.count()) return true;
        if (await enable.count()) await enable.first().evaluate(e => e.click());
        return false;
      }, 100000);
      return { context, page };
    }
    async function addWater(page) {
      await page.getByRole('button', { name: 'Вода +250 мл', exact: true }).first().evaluate(e => e.click());
      await until(async () => (await page.locator('body').ariaSnapshot()).includes('250'), 25000);
    }
    async function openBackupPanel(page) {
      await page.getByRole('button', { name: 'Ещё: настройки и данные' }).first().evaluate(e => e.click());
      const target = page.getByRole('button', { name: /Резервная копия.*Экспорт и восстановление/ });
      for (let i = 0; i < 14 && !(await target.count()); i++) { await page.mouse.wheel(0, 600); await sleep(220); }
      await target.first().evaluate(e => e.click());
      await page.getByRole('button', { name: 'Экспорт JSON', exact: true }).first().waitFor({ state: 'attached', timeout: 20000 });
    }
    function readEnvelope(bytes) {
      const parsed = JSON.parse(bytes.toString('utf8'));
      const waterKey = Object.keys(parsed.data || {}).find(k => k.startsWith('water_intake_'));
      return { app: parsed.app, waterKey, water: waterKey ? parsed.data[waterKey] : null, bytes: bytes.length };
    }

    // A: share unavailable -> a REAL browser download must contain synthetic water.
    const a = await freshPage(true);
    await addWater(a.page);
    await openBackupPanel(a.page);
    const dlWait = a.page.waitForEvent('download', { timeout: 30000 });
    await a.page.getByRole('button', { name: 'Экспорт JSON', exact: true }).first().evaluate(e => e.click());
    const download = await dlWait;
    const dlBytes = fs.readFileSync(await download.path());
    const env = readEnvelope(dlBytes);
    check('no Web Share still produces a browser download', !!download.suggestedFilename(), { file: download.suggestedFilename() });
    check('downloaded envelope is a fitness_tracker JSON with synthetic water',
      env.app === 'fitness_tracker' && env.water === 250, env);
    await a.context.close();

    // B: share works -> share sheet is used first, no second silent download.
    const b = await freshPage(false);
    await addWater(b.page);
    await openBackupPanel(b.page);
    let downloaded = false;
    b.page.on('download', () => { downloaded = true; });
    await b.page.getByRole('button', { name: 'Экспорт JSON', exact: true }).first().evaluate(e => e.click());
    await until(() => b.page.evaluate(() => window.__shareCalls.length > 0), 20000);
    await sleep(1500);
    const calls = await b.page.evaluate(() => window.__shareCalls);
    check('working share is used first and does not trigger a second download', calls.length === 1 && !downloaded, { calls, downloaded });
    await b.context.close();

    report.status = 'PASS_NOT_A_RELEASE';
  } catch (e) {
    errors.push(String(e && e.stack || e).slice(0, 1500));
    report.status = 'INCOMPLETE_NOT_A_RELEASE';
  } finally {
    if (browser) await browser.close();
    await new Promise(resolve => server.close(resolve));
    fs.writeFileSync(output, JSON.stringify(report, null, 2) + '\n');
    console.log(report.status, `checks=${checks.filter(c => c.status === 'PASS').length}/${checks.length}`, `errors=${errors.length}`);
    if (report.status !== 'PASS_NOT_A_RELEASE') process.exitCode = 1;
  }
})();
