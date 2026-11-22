#!/usr/bin/env node
'use strict';
/*
 * Read-only source / sidecar staging experiment. Disposable data only.
 * No production database, cloud, real account, migration, or application cutover.
 * The raw v1 model is NOT the archived +14 Flutter client.
 */
const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const http = require('node:http');
const crypto = require('node:crypto');
const child = require('node:child_process');
const sha = value => crypto.createHash('sha256').update(value).digest('hex');
function refuse(reason) { console.error('REFUSED BEFORE BROWSER:', reason); process.exit(2); }
const [engine, buildArg, outArg] = process.argv.slice(2);
if (!['chromium', 'firefox'].includes(engine) || !buildArg || !outArg || process.argv.length !== 5 || process.getuid() === 0) {
  refuse('expected unprivileged browser, sealed synthetic build, and new report');
}
const output = path.resolve(outArg);
if (fs.existsSync(output) || !fs.existsSync(path.dirname(output))) refuse('new report and existing parent required');
const interfaces = os.networkInterfaces(), names = Object.keys(interfaces).sort();
let main4, main6, all4, all6;
try {
  const ip = args => child.execFileSync('ip', args, {encoding:'utf8'}).trim();
  main4 = ip(['-o','-4','route','show','table','main']);
  main6 = ip(['-o','-6','route','show','table','main']);
  all4 = ip(['-o','-4','route','show','table','all']).split('\n').filter(Boolean);
  all6 = ip(['-o','-6','route','show','table','all']).split('\n').filter(Boolean);
} catch (_) { refuse('cannot check routes'); }
const addressesSafe = (interfaces.lo || []).every(x => x.internal &&
  ((x.family === 'IPv4' && x.address === '127.0.0.1') || (x.family === 'IPv6' && x.address === '::1')));
const routes4Safe = all4.every(x => /^(local 127\.0\.0\.(0\/8|1)|broadcast 127\.255\.255\.255) dev lo table local\b/.test(x));
const routes6Safe = all6.every(x => /^local ::1 dev lo table local\b/.test(x));
if (names.length !== 1 || names[0] !== 'lo' || !addressesSafe || main4 || main6 || !routes4Safe || !routes6Safe) {
  refuse('isolated loopback-only network namespace required');
}
const root = fs.realpathSync(buildArg), files = new Map();
function walk(dir) {
  for (const ent of fs.readdirSync(dir, {withFileTypes:true})) {
    const full = path.join(dir, ent.name), rel = path.relative(root, full).split(path.sep).join('/');
    if (ent.isSymbolicLink()) refuse('symlink in build');
    if (ent.isDirectory()) walk(full); else if (ent.isFile()) files.set(rel, fs.readFileSync(full)); else refuse('nonregular build file');
  }
}
walk(root);
const manifestBytes = files.get('candidate-shell-manifest.json');
if (!manifestBytes) refuse('unsealed build');
let manifest; try { manifest = JSON.parse(manifestBytes.toString('utf8')); } catch (_) { refuse('bad manifest'); }
if (manifest.schema !== 1 || !/^[0-9a-f]{24}$/.test(manifest.id) || !manifest.files ||
    Object.entries(manifest.files).some(([name, digest]) => !files.has(name) || sha(files.get(name)) !== digest)) refuse('manifest mismatch');
const worker = files.get('fitness_worker.js'), guard = files.get('fitness_tab_guard.js');
if (!guard || !worker || !guard.includes(Buffer.from(`const SHELL_ID = '${manifest.id}';`)) ||
    !guard.includes(Buffer.from('fitness_synthetic_candidate')) ||
    !worker.includes(Buffer.from(`const MANIFEST_SHA256 = '${sha(manifestBytes)}';`))) refuse('unexpected worker or guard');
const labPath = path.join(__dirname, 'snapshot_lab.js'), labCode = fs.readFileSync(labPath);
const playwright = require('playwright');
const delay = ms => new Promise(resolve => setTimeout(resolve, ms));
async function until(fn, timeout=45000) {
  const end = Date.now() + timeout;
  while (Date.now() < end) { const result = await fn(); if (result) return result; await delay(150); }
  throw Error('Timed out waiting for synthetic condition');
}
const mime = name => name.endsWith('.html') ? 'text/html; charset=utf-8' : name.endsWith('.js') ? 'text/javascript; charset=utf-8' :
  name.endsWith('.json') ? 'application/json' : name.endsWith('.wasm') ? 'application/wasm' : name.endsWith('.png') ? 'image/png' :
  name.endsWith('.ttf') ? 'font/ttf' : name.endsWith('.otf') ? 'font/otf' : 'application/octet-stream';
const fresh = prefix => prefix + crypto.randomBytes(16).toString('hex');

async function modelSuite(page) {
  return page.evaluate(async () => {
    const checks = [], risks = [], lab = window.FitnessSidecarLab;
    const check = (name, condition, values={}) => {
      checks.push({name, status:condition?'PASS':'FAIL', values});
      if (!condition) throw Error(name);
    };
    const risk = (name, condition, values={}) => {
      risks.push({name, status:condition?'RISK_REPRODUCED':'UNEXPECTED', values});
      if (!condition) throw Error(name);
    };
    const id = () => crypto.randomUUID().replaceAll('-', '');
    const sourceName = () => 'fitness_lab_legacy_' + id();
    const targetName = () => 'fitness_lab_sidecar_' + id();
    const code = async promise => { try { await promise; return 'UNEXPECTED_SUCCESS'; } catch (e) { return e && (e.code || e.name); } };
    const dbExists = async name => (await indexedDB.databases()).some(x => x.name === name);
    const opened = (name, version) => new Promise((resolve,reject) => {
      const req = indexedDB.open(name,version);
      req.onupgradeneeded = () => { try { req.transaction.abort(); } catch (_) {} };
      req.onerror = e => { e.preventDefault(); reject(req.error); };
      req.onsuccess = () => resolve(req.result);
    });
    const make = (name, version, shape='box') => new Promise((resolve,reject) => {
      const req = indexedDB.open(name,version);
      req.onupgradeneeded = () => {
        const box = req.result.createObjectStore(shape);
        if (shape !== 'box') return box.put('fake-schema-marker', 'marker');
        box.put(250, 'water_intake_2026-10-25');
        box.put(JSON.stringify([{name:'Синтетическая овсянка',grams:150,kcal:180}]), 'food_entries_2026-10-25');
        box.put(Uint8Array.from([0,144,169,1,255,0,42]).buffer, 'hive_encoded_bytes');
        box.put('PRIVATE_SYNTHETIC_ONLY', '_ai_consent_synthetic');
        box.put(-0, 'negative_zero');
        box.put([1.25,2.5,3], 'synthetic_list');
        box.put(null, 'synthetic_null');
        box.put('numeric-key-value', 7);
      };
      req.onerror = () => reject(req.error);
      req.onsuccess = () => { req.result.close(); resolve(); };
    });
    const get = async (name,version,store,key) => {
      const db=await opened(name,version);
      try { return await new Promise((resolve,reject)=>{
        const tx=db.transaction(store,'readonly'),r=tx.objectStore(store).get(key);
        tx.oncomplete=()=>resolve(r.result); tx.onabort=()=>reject(tx.error||Error('fixture get aborted'));
      }); } finally { db.close(); }
    };
    const put = async (name,version,store,key,value) => {
      const db=await opened(name,version);
      try { await new Promise((resolve,reject)=>{
        const tx=db.transaction(store,'readwrite');tx.objectStore(store).put(value,key);
        tx.oncomplete=resolve;tx.onabort=()=>reject(tx.error||Error('fixture put aborted'));
      }); } finally { db.close(); }
    };
    let watched = null, sourceReadwrite = 0, forbiddenOpen = 0;
    const originalOpen = IDBFactory.prototype.open;
    IDBFactory.prototype.open = function(name,...args) {
      if (name === 'fitness_v2') forbiddenOpen++;
      return originalOpen.call(this,name,...args);
    };
    const originalTransaction = IDBDatabase.prototype.transaction;
    IDBDatabase.prototype.transaction = function(stores,mode,...rest) {
      if (watched === this.name && mode !== 'readonly') sourceReadwrite++;
      return originalTransaction.call(this,stores,mode,...rest);
    };
    const audited = async (name,fn) => { watched=name; try { return await fn(); } finally { watched=null; } };
    try {
      check('laboratory exposes no activation, deletion or source-write operation',
        !!lab && Object.keys(lab).sort().join(',') === 'captureSidecar,captureSource,compare,stage');
      check('real diary name is refused before any database open',
        (await code(lab.stage('fitness_v2',1,targetName()))) === 'SOURCE_NAME_OR_VERSION_FORBIDDEN' && forbiddenOpen===0);
      check('arbitrary destination name is refused before any database open',
        (await code(lab.stage(sourceName(),1,'fitness_v2'))) === 'SIDECAR_NAME_FORBIDDEN' && forbiddenOpen===0);
      check('browser can enumerate disposable databases for absent-fixture assertions',
        typeof indexedDB.databases === 'function');

      const missing=sourceName(), missingTarget=targetName();
      check('missing source is refused without creating source or destination',
        (await code(lab.stage(missing,1,missingTarget))) === 'MISSING_OR_UPGRADE_REFUSED' &&
        !await dbExists(missing) && !await dbExists(missingTarget));

      const bad=sourceName(),badTarget=targetName(); await make(bad,1,'unexpected');
      check('unexpected source schema is refused without damaging its marker or creating destination',
        (await code(lab.stage(bad,1,badTarget))) === 'SCHEMA_REFUSED' &&
        await get(bad,1,'unexpected','marker') === 'fake-schema-marker' && !await dbExists(badTarget));

      const high=sourceName(),highTarget=targetName(); await make(high,2);
      check('a higher source version is refused without a downgrade or target creation',
        (await code(lab.stage(high,1,highTarget))) === 'VERSION_MISMATCH_REFUSED' &&
        await get(high,2,'box','water_intake_2026-10-25') === 250 && !await dbExists(highTarget));

      const unsupported=sourceName(),unsupportedTarget=targetName(); await make(unsupported,1);
      await put(unsupported,1,'box','unsupported-date',new Date('2001-01-01T00:00:00Z'));
      check('unsupported structured-clone type fails before a sidecar is created',
        (await code(lab.stage(unsupported,1,unsupportedTarget))) === 'VALUE_TYPE_UNSUPPORTED' &&
        !await dbExists(unsupportedTarget) && (await get(unsupported,1,'box','unsupported-date')) instanceof Date);

      const src=sourceName(),dst=targetName(); await make(src,1);
      window.__labOpenOldV1 = await opened(src,1); // deliberately keep a nonparticipating old connection open
      const stage=await audited(src,()=>lab.stage(src,1,dst));
      const matched=await audited(src,()=>lab.compare(src,1,dst));
      const before=await audited(src,()=>lab.captureSource(src,1));
      check('a staged sidecar is copied while the old v1 connection remains open',
        stage.state==='STAGED_ONLY_NO_ACTIVATION' && window.__labOpenOldV1.version===1 &&
        matched.state==='MATCH_ONLY_NO_ACTIVATION' && matched.metadataMatches && stage.count===8);
      check('source was read only and the old v1 opener still sees its original value',
        sourceReadwrite===0 && await get(src,1,'box','water_intake_2026-10-25')===250);
      const sourceBytes=await get(src,1,'box','hive_encoded_bytes');
      const targetBytes=await get(dst,1,'data','hive_encoded_bytes');
      const equalBytes=JSON.stringify(Array.from(new Uint8Array(sourceBytes)))===JSON.stringify(Array.from(new Uint8Array(targetBytes)));
      const sourceFood=await get(src,1,'box','food_entries_2026-10-25');
      const targetFood=await get(dst,1,'data','food_entries_2026-10-25');
      check('water, food text, binary bytes, list, null and integer key survive raw copying',
        equalBytes && sourceFood===targetFood && await get(dst,1,'data','water_intake_2026-10-25')===250 &&
        JSON.stringify(await get(dst,1,'data','synthetic_list'))==='[1.25,2.5,3]' &&
        await get(dst,1,'data','synthetic_null')===null && await get(dst,1,'data',7)==='numeric-key-value' &&
        Object.is(await get(src,1,'box','negative_zero'),await get(dst,1,'data','negative_zero')));
      risk('raw staging includes a fake private marker and is not a privacy-filtered export',
        await get(dst,1,'data','_ai_consent_synthetic')==='PRIVATE_SYNTHETIC_ONLY');

      check('restaging an occupied sidecar is refused without overwriting it',
        (await code(audited(src,()=>lab.stage(src,1,dst))))==='SIDECAR_NOT_EMPTY' &&
        (await audited(src,()=>lab.compare(src,1,dst))).state==='MATCH_ONLY_NO_ACTIVATION');
      const abortDst=targetName();
      check('an injected abort follows request success and reports no commit',
        (await code(audited(src,()=>lab.stage(src,1,abortDst,{injectAbortAfterFirstSuccess:true}))))===
          'INJECTED_ABORT_AFTER_REQUEST_SUCCESS');
      const aborted=await lab.captureSidecar(abortDst);
      check('aborted transaction leaves both sidecar records and metadata empty; source is unchanged',
        aborted.keys.length===0 && aborted.meta===undefined &&
        (await audited(src,()=>lab.captureSource(src,1))).digest===before.digest);
      check('retry into the still-empty aborted sidecar succeeds',
        (await audited(src,()=>lab.stage(src,1,abortDst))).state==='STAGED_ONLY_NO_ACTIVATION' &&
        (await audited(src,()=>lab.compare(src,1,abortDst))).state==='MATCH_ONLY_NO_ACTIVATION');

      const raceDst=targetName();
      const race=await Promise.allSettled([lab.stage(src,1,raceDst),lab.stage(src,1,raceDst)]);
      const won=race.filter(x=>x.status==='fulfilled').length;
      const blocked=race.filter(x=>x.status==='rejected' && x.reason.code==='SIDECAR_NOT_EMPTY').length;
      check('two concurrent stagers cannot overwrite one another',
        won===1 && blocked===1 && (await lab.compare(src,1,raceDst)).state==='MATCH_ONLY_NO_ACTIVATION',
        {successfulStagers:won,refusedStagers:blocked});

      await put(src,1,'box','water_intake_2026-10-25',500);
      const mismatch=await audited(src,()=>lab.compare(src,1,dst));
      check('a subsequent old-source write is detected and does not alter the staged sidecar',
        mismatch.state==='MISMATCH_NO_ACTIVATION' && mismatch.metadataMatches &&
        await get(src,1,'box','water_intake_2026-10-25')===500 &&
        await get(dst,1,'data','water_intake_2026-10-25')===250);

      const abaSrc=sourceName(),abaDst=targetName(); await make(abaSrc,1); await lab.stage(abaSrc,1,abaDst);
      await put(abaSrc,1,'box','water_intake_2026-10-25',500);
      await put(abaSrc,1,'box','water_intake_2026-10-25',250);
      const aba=await lab.compare(abaSrc,1,abaDst);
      risk('two committed writes returning to the same value are invisible to a snapshot comparison',
        aba.state==='MATCH_ONLY_NO_ACTIVATION',{committedWrites:2});
      await put(abaDst,1,'data','water_intake_2026-10-25',999);
      const tampered=await lab.compare(abaSrc,1,abaDst);
      check('sidecar tampering is detected without changing the source',
        tampered.state==='MISMATCH_NO_ACTIVATION' && !tampered.metadataMatches &&
        await get(abaSrc,1,'box','water_intake_2026-10-25')===250);
      check('all audited laboratory source transactions were readonly',sourceReadwrite===0);
      window.__labOpenOldV1.close();
      return {checks,risks,lockFixture:{source:abaSrc}};
    } catch(e) {
      try { if (window.__labOpenOldV1) window.__labOpenOldV1.close(); } catch (_) {}
      return {checks,risks,error:{name:e.name||'Error',message:String(e.message||e).slice(0,500)}};
    }
  });
}

async function run() {
  const checks=[], risks=[], contexts=[], loaded=[], pending=[];
  let origin, browser, latestPage, blocked=0, server;
  const report={
    status:'INCOMPLETE_NOT_A_RELEASE',engine,sourceSha256:sha(fs.readFileSync(__filename)),
    snapshotLabSha256:sha(labCode),candidateId:manifest.id,candidateManifestSha256:sha(manifestBytes),
    candidateMainSha256:manifest.files['main.dart.js'],candidateGuardSha256:manifest.files['fitness_tab_guard.js'],
    nodeVersion:process.version,browserVersion:null,
    networkIsolation:{uid:process.getuid(),interfaces:names,routes4:0,routes6:0,allRoutesLoopbackOnly:true},
    checks,risks,loaded,
    limitations:[
      'Lab-only research, NOT a release, migration, rollback mechanism, or real backup.',
      'The v1 source and old writer are raw IndexedDB fixtures, not the exact archived +14 application.',
      'The candidate portion uses the separately named synthetic v2 database and a disposable browser profile.',
      'A match between sequential reads cannot fence nonparticipating writers and can miss ABA changes or future writes.',
      'Raw staging copies private fields; it is not a privacy-filtered export and must never be used on real data.',
      'Unknown structured-clone types are rejected; byte values and a few selected synthetic values do not cover all Hive data.',
      'No production cutover, all record types, real diary, cloud, auth, multiple devices, real quota, power failure, Safari/iOS, or Android was tested.'
    ],
  };
  const check=(name,condition,values={})=>{checks.push({name,status:condition?'PASS':'FAIL',values});if(!condition)throw Error(name);};
  const risk=(name,condition,values={})=>{risks.push({name,status:condition?'RISK_REPRODUCED':'UNEXPECTED',values});if(!condition)throw Error(name);};
  server=http.createServer((req,res)=>{
    if(req.method!=='GET'){res.writeHead(405);return res.end();}
    let url;try{url=decodeURIComponent(new URL(req.url,'http://127.0.0.1').pathname);}catch(_){res.writeHead(400);return res.end();}
    if(url==='/__lab_legacy__/blank.html'){
      res.writeHead(200,{'content-type':'text/html; charset=utf-8','cache-control':'no-store'});
      return res.end('<!doctype html><title>Disposable synthetic sidecar lab</title>');
    }
    if(url==='/__lab_legacy__/snapshot_lab.js'){
      res.writeHead(200,{'content-type':'text/javascript; charset=utf-8','cache-control':'no-store'});return res.end(labCode);
    }
    let name=url.slice(1);if(!name)name='index.html';
    if(name.startsWith('.')||name.includes('..')||name.includes('\\')){res.writeHead(404);return res.end();}
    const data=files.get(name);if(!data){res.writeHead(404);return res.end();}
    res.writeHead(200,{'content-type':mime(name),'cache-control':'no-store','x-content-type-options':'nosniff'});res.end(data);
  });
  async function context(){
    const c=await browser.newContext({viewport:{width:390,height:844},locale:'en-US',timezoneId:'UTC'});contexts.push(c);
    await c.route('**/*',route=>{
      let allowed=false;try{allowed=new URL(route.request().url()).origin===origin;}catch(_){}
      if(!allowed){blocked++;return route.abort();}return route.continue();
    });return c;
  }
  async function blank(c){
    const p=await c.newPage();latestPage=p;p.setDefaultTimeout(15000);
    await p.goto(origin+'/__lab_legacy__/blank.html',{waitUntil:'load'});
    await p.addScriptTag({url:origin+'/__lab_legacy__/snapshot_lab.js'});
    return p;
  }
  async function ready(p){
    await until(async()=>{
      const enable=p.getByRole('button',{name:'Enable accessibility'});
      if(await enable.count())await enable.first().evaluate(e=>e.click());
      return await p.getByRole('button',{name:'Вода +250 мл',exact:true}).count();
    },100000);
  }
  const click=locator=>locator.first().evaluate(e=>e.click());
  const read=(p,dbName,version,store,key)=>p.evaluate(async({dbName,version,store,key})=>{
    const db=await new Promise((resolve,reject)=>{const r=indexedDB.open(dbName,version);
      r.onupgradeneeded=()=>r.transaction.abort();r.onerror=()=>reject(r.error);r.onsuccess=()=>resolve(r.result);});
    try {return await new Promise((resolve,reject)=>{const tx=db.transaction(store,'readonly'),r=tx.objectStore(store).get(key);
      tx.oncomplete=()=>resolve(r.result===undefined?null:r.result);tx.onabort=()=>reject(tx.error||Error('read aborted'));});}
    finally{db.close();}
  },{dbName,version,store,key});
  try {
    await new Promise((resolve,reject)=>{server.once('error',reject);server.listen(0,'127.0.0.1',resolve);});
    origin=`http://127.0.0.1:${server.address().port}`;
    const opts={headless:true};if(engine==='chromium')opts.args=['--enable-unsafe-swiftshader','--disable-background-networking','--no-proxy-server'];
    browser=await playwright[engine].launch(opts);report.browserVersion=browser.version();

    const mc=await context(), mp=await blank(mc);
    const model=await modelSuite(mp);checks.push(...model.checks);risks.push(...model.risks);
    if(model.error)throw Error('model: '+model.error.message);
    const old=await blank(mc), lockName='fitness-lab-sidecar-lock-'+crypto.randomBytes(8).toString('hex');
    const lockStarted=await mp.evaluate(async lockName=>{
      if(!navigator.locks)return false;
      let notify;const acquired=new Promise(resolve=>notify=resolve);
      window.__labLockLifetime=navigator.locks.request(lockName,{mode:'exclusive'},async lock=>{
        notify(!!lock);await new Promise(resolve=>{window.__labReleaseLock=resolve;});
      });
      return acquired;
    },lockName);
    check('cooperating laboratory lock can be held',lockStarted);
    const lockHeld=await mp.evaluate(async name=>(await navigator.locks.query()).held.some(x=>x.name===name),lockName);
    const lateWrite=await old.evaluate(async src=>{
      const db=await new Promise((resolve,reject)=>{const r=indexedDB.open(src,1);r.onerror=()=>reject(r.error);
        r.onupgradeneeded=()=>r.transaction.abort();r.onsuccess=()=>resolve(r.result);});
      try {await new Promise((resolve,reject)=>{const tx=db.transaction('box','readwrite');
        tx.objectStore('box').put(750,'water_intake_2026-10-25');tx.oncomplete=resolve;tx.onabort=()=>reject(tx.error);});return true;}
      finally{db.close();}
    },model.lockFixture.source);
    const lockHeldAfter=await mp.evaluate(async name=>(await navigator.locks.query()).held.some(x=>x.name===name),lockName);
    risk('a nonparticipating old writer commits while a laboratory Web Lock is held',lockHeld&&lateWrite&&lockHeldAfter);
    await mp.evaluate(()=>window.__labReleaseLock());await mc.close();

    // Real application code, but ONLY the reconstructed synthetic candidate on a fresh profile.
    const ac=await context(), app=await ac.newPage();latestPage=app;app.setDefaultTimeout(15000);
    await app.addInitScript(()=>{window.flutterWebSemanticsEnabled=true;});
    app.on('response',response=>{
      let url;try{url=new URL(response.url());}catch(_){return;}
      if(url.pathname!=='/main.dart.js')return;
      const item={fromServiceWorker:response.fromServiceWorker(),sha256:null};loaded.push(item);
      pending.push(response.body().then(bytes=>{item.sha256=sha(bytes);},()=>{item.error='body unavailable';}));
    });
    await app.goto(origin+'/',{waitUntil:'load',timeout:40000});await ready(app);
    const monitor=await blank(ac);latestPage=app;
    const key=await monitor.evaluate(()=>{const d=new Date(),two=n=>String(n).padStart(2,'0');
      return `water_intake_${d.getFullYear()}-${two(d.getMonth()+1)}-${two(d.getDate())}`;});
    const foodKey=key.replace('water_intake_','food_entries_');
    const source='fitness_synthetic_candidate', dest=fresh('fitness_lab_sidecar_');
    await click(app.getByRole('button',{name:'Вода +250 мл',exact:true}));
    await until(async()=>await read(monitor,source,2,'box',key)===250,30000);
    await click(app.getByRole('button',{name:'Добавить еду',exact:true}));
    await click(app.getByRole('button',{name:'Завтрак нет записей',exact:true}));
    await click(app.getByRole('button',{name:'Свой продукт',exact:true}));
    for(const [label,value] of [
      ['Название продукта','Синтетическая овсянка'],['Вес порции','150'],['Ккал','120'],
      ['Б (г)','4'],['Ж (г)','2'],['У (г)','20']
    ]){
      const field=app.getByRole('textbox',{name:label,exact:true});
      await field.click({timeout:15000});await delay(250);await app.keyboard.press('Control+A');
      await app.keyboard.insertText(value);await delay(350);
      await until(async()=>await app.getByRole('textbox',{name:label,exact:true}).inputValue()===value,10000);
    }
    await click(app.getByRole('button',{name:'Добавить в дневник',exact:true}));
    const foodRaw=await until(async()=>await read(monitor,source,2,'box',foodKey),30000);
    const food=JSON.parse(foodRaw);
    check('synthetic candidate UI committed one fictional food and 250 ml',
      Array.isArray(food)&&food.length===1&&food[0].name==='Синтетическая овсянка'&&food[0].amountGrams===150&&
      food[0].caloriesPer100g===120&&await read(monitor,source,2,'box',key)===250);
    // Seed one explicitly fake private marker; this tests raw-copy privacy, not real user data.
    await monitor.evaluate(async({source})=>{
      const db=await new Promise((resolve,reject)=>{const r=indexedDB.open(source,2);r.onerror=()=>reject(r.error);
        r.onupgradeneeded=()=>r.transaction.abort();r.onsuccess=()=>resolve(r.result);});
      try {await new Promise((resolve,reject)=>{const tx=db.transaction('box','readwrite');
        tx.objectStore('box').put('PRIVATE_SYNTHETIC_CANDIDATE','_ai_consent_synthetic');
        tx.oncomplete=resolve;tx.onabort=()=>reject(tx.error);});}finally{db.close();}
    },{source});
    const result=await monitor.evaluate(async({source,dest})=>{
      const orig=IDBDatabase.prototype.transaction;let sourceWriteTransactions=0;
      IDBDatabase.prototype.transaction=function(stores,mode,...rest){
        if(this.name===source&&mode!=='readonly')sourceWriteTransactions++;
        return orig.call(this,stores,mode,...rest);
      };
      try {
        const staged=await window.FitnessSidecarLab.stage(source,2,dest);
        const compared=await window.FitnessSidecarLab.compare(source,2,dest);
        return {staged,compared,sourceWriteTransactions};
      } finally { IDBDatabase.prototype.transaction=orig; }
    },{source,dest});
    check('real synthetic-candidate Hive data stages without any source write transaction',
      result.staged.state==='STAGED_ONLY_NO_ACTIVATION' && result.compared.state==='MATCH_ONLY_NO_ACTIVATION' &&
      result.staged.count>=3 && result.sourceWriteTransactions===0,{records:result.staged.count});
    check('staged candidate values preserve the exact synthetic water and food payload',
      await read(monitor,dest,1,'data',key)===250 && await read(monitor,dest,1,'data',foodKey)===foodRaw);
    risk('the candidate sidecar also contains the fake private marker',
      await read(monitor,dest,1,'data','_ai_consent_synthetic')==='PRIVATE_SYNTHETIC_CANDIDATE');
    // After the synthetic food dialog closes, a participating writer changes water.
    await until(async()=>await app.getByRole('button',{name:'Вода +250 мл',exact:true}).count(),30000);
    await click(app.getByRole('button',{name:'Вода +250 мл',exact:true}));
    await until(async()=>await read(monitor,source,2,'box',key)===500,30000);
    const changed=await monitor.evaluate(async({source,dest})=>window.FitnessSidecarLab.compare(source,2,dest),{source,dest});
    check('a later synthetic application write makes the staged snapshot mismatch',
      changed.state==='MISMATCH_NO_ACTIVATION' && changed.metadataMatches &&
      await read(monitor,dest,1,'data',key)===250 && await read(monitor,source,2,'box',key)===500);
    const oldResult=await monitor.evaluate(source=>new Promise(resolve=>{
      const r=indexedDB.open(source,1);r.onerror=e=>{e.preventDefault();resolve(r.error&&r.error.name);};
      r.onsuccess=()=>{r.result.close();resolve('unexpected-success');};
    }),source);
    risk('sidecar staging does not repair the existing candidate v2 rollback incompatibility',oldResult==='VersionError');
    await Promise.all(pending);
    check('every loaded candidate main script matches the sealed synthetic build',
      loaded.length>0&&loaded.every(x=>x.sha256===manifest.files['main.dart.js']));
    report.status='PASS_WITH_REPRODUCED_RISKS_NOT_A_RELEASE';
  } catch(error){
    report.error={name:error.name||'Error',message:String(error.message||error).slice(0,700)};
    if(latestPage&&!latestPage.isClosed()){
      try{report.syntheticUiAtFailure=(await latestPage.locator('body').ariaSnapshot({timeout:3000})).slice(0,4000);}catch(_){}
    }
    report.status='FAIL_OR_INCOMPLETE_NOT_A_RELEASE';
  } finally {
    report.blockedExternalPageRequests=blocked;
    for(const c of contexts){try{await c.close();}catch(_){}}
    try{if(browser)await browser.close();}catch(_){}
    await new Promise(resolve=>{server.close(resolve);if(server.closeAllConnections)server.closeAllConnections();});
    try{await Promise.all(pending);}catch(_){}
  }
  fs.writeFileSync(output,JSON.stringify(report,null,2)+'\n',{encoding:'utf8',flag:'wx',mode:0o600});
  console.log(JSON.stringify({engine,status:report.status,passes:checks.filter(x=>x.status==='PASS').length,
    risks:risks.length,output},null,2));
  if(report.status!=='PASS_WITH_REPRODUCED_RISKS_NOT_A_RELEASE')process.exitCode=1;
}
run().catch(error=>{console.error('Probe failed:',error.name);process.exitCode=1;});
