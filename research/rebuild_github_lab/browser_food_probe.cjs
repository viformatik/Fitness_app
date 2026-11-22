#!/usr/bin/env node
'use strict';
/* Extended water/food/marker probe for the reconstructed candidate.
 * Disposable data and loopback-only namespace only. The v1 writer below is
 * a raw IDB fixture, NOT the exact archived Flutter application.
 */
const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const http = require('node:http');
const crypto = require('node:crypto');
const child = require('node:child_process');
const sha = b => crypto.createHash('sha256').update(b).digest('hex');
function refuse(reason) { console.error('REFUSED BEFORE BROWSER:', reason); process.exit(2); }
const [engine, buildArg, outArg] = process.argv.slice(2);
if (!['chromium', 'firefox'].includes(engine) || !buildArg || !outArg || process.argv.length !== 5 || process.getuid() === 0) {
  refuse('expected unprivileged browser, sealed synthetic build and new report');
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
const playwright = require('playwright'), dbName = 'fitness_synthetic_candidate';
const delay = ms => new Promise(resolve => setTimeout(resolve, ms));
async function until(fn, timeout=45000) {
  const end = Date.now() + timeout;
  while (Date.now() < end) { const result = await fn(); if (result) return result; await delay(150); }
  throw Error('Timed out waiting for synthetic condition');
}
const mime = name => name.endsWith('.html') ? 'text/html; charset=utf-8' : name.endsWith('.js') ? 'text/javascript; charset=utf-8' :
  name.endsWith('.json') ? 'application/json' : name.endsWith('.wasm') ? 'application/wasm' : name.endsWith('.png') ? 'image/png' :
  name.endsWith('.ttf') ? 'font/ttf' : name.endsWith('.otf') ? 'font/otf' : 'application/octet-stream';
async function run() {
  const checks=[], risks=[], contexts=[], loaded=[], pending=[];
  let origin, browser, latestPage, serverDown=false, blocked=0;
  const report = {
    status:'INCOMPLETE_NOT_A_RELEASE', engine, sourceSha256:sha(fs.readFileSync(__filename)),
    candidateId:manifest.id, candidateManifestSha256:sha(manifestBytes), candidateMainSha256:manifest.files['main.dart.js'],
    candidateGuardSha256:manifest.files['fitness_tab_guard.js'], candidateWorkerSha256:sha(worker),
    candidateFiles:Object.keys(manifest.files).length, nodeVersion:process.version, browserVersion:null,
    networkIsolation:{uid:process.getuid(),interfaces:names,routes4:0,routes6:0,allRoutesLoopbackOnly:true},
    checks, risks, loaded,
    limitations:[
      'This is a new reconstructed synthetic candidate, not the previously lost candidate or a production build.',
      'The old v1 writer is a raw IndexedDB fixture, not the exact archived +14 Flutter application.',
      'Only disposable profiles, a synthetic database, synthetic water, one synthetic food and two fake private markers are tested; no real diary or account is accessed.',
      'The injected abort is not real quota exhaustion, process termination, power loss or hardware failure.',
      'A single synthetic JSON restore does not prove every type of record, privacy field or real backup recovery.',
      'An ordinary old v1 rollback is incompatible. Safari/iOS, Android, cloud sync and multiple devices are not covered.'
    ],
  };
  const check=(name,condition,values={})=>{checks.push({name,status:condition?'PASS':'FAIL',values}); if(!condition)throw Error(name);};
  const risk=(name,condition,values={})=>{risks.push({name,status:condition?'RISK_REPRODUCED':'UNEXPECTED',values}); if(!condition)throw Error(name);};
  const server=http.createServer((req,res)=>{
    if(req.method!=='GET'){res.writeHead(405);return res.end();}
    let url; try{url=decodeURIComponent(new URL(req.url,'http://127.0.0.1').pathname);}catch(_){res.writeHead(400);return res.end();}
    if(url==='/__lab_legacy__/blank.html'){
      res.writeHead(200,{'content-type':'text/html; charset=utf-8','cache-control':'no-store'});
      return res.end('<!doctype html><title>Disposable synthetic fixture</title>');
    }
    let name=url.slice(1); if(!name)name='index.html';
    if(name.startsWith('.')||name.includes('..')||name.includes('\\')){res.writeHead(404);return res.end();}
    const bytes=files.get(name); if(!bytes){res.writeHead(404);return res.end();}
    res.writeHead(200,{'content-type':mime(name),'cache-control':'no-store','x-content-type-options':'nosniff'});res.end(bytes);
  });
  async function context(){
    const c=await browser.newContext({viewport:{width:390,height:844},locale:'en-US',timezoneId:'UTC',acceptDownloads:true});contexts.push(c);
    await c.route('**/*',route=>{
      let allowed=false;try{allowed=new URL(route.request().url()).origin===origin;}catch(_){}
      if(!allowed){blocked++;return route.abort();}return route.continue();
    });return c;
  }
  async function page(c,label,opts={}){
    const p=await c.newPage();latestPage=p;p.setDefaultTimeout(12000);
    p.on('response',response=>{
      let url;try{url=new URL(response.url());}catch(_){return;}
      if(url.pathname!=='/main.dart.js')return;
      const item={page:label,fromServiceWorker:response.fromServiceWorker(),sha256:null};loaded.push(item);
      pending.push(response.body().then(bytes=>{item.sha256=sha(bytes);},()=>{item.error='response body unavailable';}));
    });
    await p.addInitScript(({dbName,noLocks,injectAbort})=>{
      window.flutterWebSemanticsEnabled=true;window.__opens=[];window.__writes=[];window.__abortNext=false;
      if(noLocks)Object.defineProperty(navigator,'locks',{configurable:true,value:undefined});
      const open=IDBFactory.prototype.open;
      IDBFactory.prototype.open=function(name,version){
        window.__opens.push({name:String(name),version:version===undefined?null:version});
        return version===undefined?open.call(this,name):open.call(this,name,version);
      };
      const put=IDBObjectStore.prototype.put;
      IDBObjectStore.prototype.put=function(value,key){
        const request=put.apply(this,arguments);
        if(this.transaction.db.name===dbName && this.name==='box' && typeof key==='string' && key.startsWith('water_intake_')){
          const tx=this.transaction,item={value,requestSuccess:false,committed:false,aborted:false,injected:false};window.__writes.push(item);
          request.addEventListener('success',()=>{item.requestSuccess=true;if(injectAbort&&window.__abortNext){
            window.__abortNext=false;item.injected=true;try{tx.abort();}catch(_){}
          }});
          tx.addEventListener('complete',()=>{item.committed=true;});tx.addEventListener('abort',()=>{item.aborted=true;});
        }
        return request;
      };
    },{dbName,noLocks:!!opts.noLocks,injectAbort:!!opts.injectAbort});return p;
  }
  async function ready(p){
    await until(async()=>{
      const enable=p.getByRole('button',{name:'Enable accessibility'});
      if(await enable.count())await enable.first().evaluate(e=>e.click());
      return await p.getByRole('button',{name:'Вода +250 мл',exact:true}).count();
    },100000);
  }
  async function boot(p){await p.goto(origin+'/',{waitUntil:'load',timeout:40000});await ready(p);}
  const water=async p=>{
    const text=await p.locator('body').ariaSnapshot(),m=text.match(/ВОДА\s+([0-9][0-9\s\u00a0\u202f]*)\s*мл/);
    return m?Number(m[1].replace(/[\s\u00a0\u202f]/g,'')):null;
  };
  const waterKey=p=>p.evaluate(()=>{const d=new Date(),two=n=>String(n).padStart(2,'0');return `water_intake_${d.getFullYear()}-${two(d.getMonth()+1)}-${two(d.getDate())}`;});
  const clickWater=p=>p.getByRole('button',{name:'Вода +250 мл',exact:true}).first().evaluate(e=>e.click());
  const read=(p,key,version=2,store='box')=>p.evaluate(async({dbName,key,version,store})=>{
    const db=await new Promise((resolve,reject)=>{
      const request=indexedDB.open(dbName,version),timer=setTimeout(()=>reject(Error('synthetic read timeout')),10000);
      request.onupgradeneeded=()=>request.transaction.abort();
      request.onerror=()=>{clearTimeout(timer);reject(request.error);};request.onsuccess=()=>{clearTimeout(timer);resolve(request.result);};
    });
    try{return await new Promise((resolve,reject)=>{
      const tx=db.transaction(store,'readonly'),request=tx.objectStore(store).get(key);let value;
      request.onsuccess=()=>{value=request.result;};tx.oncomplete=()=>resolve(value===undefined?null:value);tx.onabort=()=>reject(tx.error||Error('aborted'));
    });}finally{db.close();}
  },{dbName,key,version,store});
  const click=locator=>locator.first().evaluate(e=>e.click());
  async function backupPanel(p){
    await click(p.getByRole('button',{name:'Ещё: настройки и данные'}));
    const target=p.getByRole('button',{name:/Резервная копия.*Экспорт и восстановление/});
    for(let i=0;i<12 && !(await target.count());i++){await p.mouse.wheel(0,550);await delay(250);}
    await target.first().waitFor({state:'attached',timeout:15000});await click(target);
    await p.getByRole('button',{name:'Экспорт JSON',exact:true}).waitFor({state:'attached',timeout:15000});
  }
  try {
    await new Promise((resolve,reject)=>{server.once('error',reject);server.listen(0,'127.0.0.1',resolve);});
    origin=`http://127.0.0.1:${server.address().port}`;
    const opts={headless:true};if(engine==='chromium')opts.args=['--enable-unsafe-swiftshader','--disable-background-networking','--no-proxy-server'];
    browser=await playwright[engine].launch(opts);report.browserVersion=browser.version();

    let c=await context(), p=await page(c,'no-locks',{noLocks:true});
    await p.goto(origin+'/',{waitUntil:'load'});
    await p.getByText('Защита тестовых вкладок недоступна',{exact:true}).waitFor({state:'attached'});
    check('without Web Locks neither Flutter nor the synthetic diary is opened',
      !loaded.some(x=>x.page==='no-locks') && await p.evaluate(()=>window.__opens.length===0));
    check('no unsafe-continue control is offered',!(await p.getByText('Открыть без защиты').count()));await c.close();

    c=await context();p=await page(c,'bad-schema');
    await p.goto(origin+'/__lab_legacy__/blank.html');
    await p.evaluate(dbName=>new Promise((resolve,reject)=>{
      const r=indexedDB.open(dbName,1);r.onupgradeneeded=()=>r.result.createObjectStore('unexpected').put('fixture','marker');
      r.onerror=()=>reject(r.error);r.onsuccess=()=>{r.result.close();resolve();};
    }),dbName);
    await p.goto(origin+'/',{waitUntil:'load'});
    await p.getByText('Не удалось безопасно открыть тестовый дневник',{exact:true}).waitFor({state:'attached',timeout:100000});
    check('an unexpected v1 schema is not upgraded or changed',
      !loaded.some(x=>x.page==='bad-schema') && await read(p,'marker',1,'unexpected')==='fixture');await c.close();

    // Old connection is a raw v1 test fixture, not a historical application.
    const source=await context(), old=await page(source,'raw-v1');
    await old.goto(origin+'/__lab_legacy__/blank.html');const key=await waterKey(old);
    const foodKey=key.replace('water_intake_', 'food_entries_');
    const markerKey='_ai_consent_synthetic', sourceMarker='FIXTURE_SOURCE_PRIVATE', targetMarker='FIXTURE_TARGET_PRIVATE';
    await old.evaluate(({dbName,key,markerKey,sourceMarker})=>new Promise((resolve,reject)=>{
      const r=indexedDB.open(dbName,1);
      r.onupgradeneeded=()=>{const box=r.result.createObjectStore('box');box.put(250,key);box.put(sourceMarker,markerKey);};
      r.onerror=()=>reject(r.error);r.onsuccess=()=>{window.__oldDb=r.result;window.__oldDb.onversionchange=()=>{window.__sawVersionChange=true;};resolve();};
    }),{dbName,key,markerKey,sourceMarker});
    let candidate=await page(source,'candidate-initial',{injectAbort:true});
    await candidate.goto(origin+'/',{waitUntil:'load'});
    await candidate.getByText('Другая тестовая вкладка ещё использует дневник',{exact:true}).waitFor({state:'attached',timeout:100000});
    check('candidate waits while the raw v1 fixture keeps its connection',
      !loaded.some(x=>x.page==='candidate-initial') && await old.evaluate(()=>window.__sawVersionChange===true));
    await old.evaluate(key=>new Promise((resolve,reject)=>{
      const tx=window.__oldDb.transaction('box','readwrite');tx.objectStore('box').put(500,key);
      tx.oncomplete=resolve;tx.onabort=()=>reject(tx.error||Error('fixture write abort'));
    }),key);
    await old.evaluate(()=>window.__oldDb.close());await ready(candidate);
    check('candidate reads the raw v1 fixture last committed value after the fence',await water(candidate)===500 && await read(candidate,key)===500);
    check('source profile contains its synthetic private marker before export',await read(candidate,markerKey)===sourceMarker);
    await clickWater(candidate);
    await until(()=>candidate.evaluate(()=>window.__writes.some(x=>x.value===750&&x.committed)),25000);
    await until(async()=>await water(candidate)===750,25000);
    check('candidate adds and commits synthetic water',await water(candidate)===750 && await read(candidate,key)===750);

    const second=await page(source,'candidate-second',{injectAbort:true});
    await second.goto(origin+'/',{waitUntil:'load'});
    await second.getByText('Тестовый дневник уже открыт',{exact:true}).waitFor({state:'attached',timeout:20000});
    check('a second participating page cannot start Flutter while the lock is held',!loaded.some(x=>x.page==='candidate-second'));
    await candidate.close();
    await until(()=>old.evaluate(async()=>(await navigator.locks.query()).held.every(x=>x.name!=='fitness-synthetic-candidate-writer-v2')),20000);
    await second.reload({waitUntil:'load'});await ready(second);candidate=second;latestPage=second;
    check('after lock transfer the candidate reopens the committed value',await water(candidate)===750 && await read(candidate,key)===750);

    await candidate.evaluate(()=>{window.__abortNext=true;});await clickWater(candidate);
    await until(()=>candidate.evaluate(()=>window.__writes.some(x=>x.value===1000&&x.requestSuccess&&x.injected&&x.aborted)),25000);
    await until(async()=>(await candidate.locator('body').ariaSnapshot()).includes('Изменение не сохранено'),25000);
    await until(async()=>await water(candidate)===750,25000);
    check('abort after request success keeps committed water and shows a warning',await read(candidate,key)===750 && await water(candidate)===750);
    await clickWater(candidate);
    await until(()=>candidate.evaluate(()=>window.__writes.some(x=>x.value===1000&&x.committed)),25000);
    await until(async()=>await water(candidate)===1000,25000);
    check('a deliberate retry commits once after the injected abort',await read(candidate,key)===1000 && await water(candidate)===1000);

    // Add one known fictional product through the mobile UI, not by IDB injection.
    check('source has no synthetic food before the UI action',await read(candidate,foodKey)===null);
    await click(candidate.getByRole('button',{name:'Добавить еду',exact:true}));
    await click(candidate.getByRole('button',{name:'Завтрак нет записей',exact:true}));
    await click(candidate.getByRole('button',{name:'Свой продукт',exact:true}));
    for(const [label,value] of [
      ['Название продукта','Синтетическая овсянка'],['Вес порции','150'],['Ккал','120'],
      ['Б (г)','4'],['Ж (г)','2'],['У (г)','20']
    ]){
      const field=candidate.getByRole('textbox',{name:label,exact:true});
      await field.click({timeout:15000});await delay(250);
      await candidate.keyboard.press('Control+A');await candidate.keyboard.insertText(value);await delay(350);
      await until(async()=>await candidate.getByRole('textbox',{name:label,exact:true}).inputValue()===value,10000);
    }
    await click(candidate.getByRole('button',{name:'Добавить в дневник',exact:true}));
    const foodRaw=await until(async()=>await read(candidate,foodKey),30000);
    const foodRows=JSON.parse(foodRaw), food=foodRows[0];
    check('UI commits one synthetic food with exact portion and per-100g macros',
      Array.isArray(foodRows) && foodRows.length===1 && food.name==='Синтетическая овсянка' &&
      food.amountGrams===150 && food.caloriesPer100g===120 && food.proteinPer100g===4 &&
      food.fatPer100g===2 && food.carbsPer100g===20 && food.mealType===0,
      {grams:food?.amountGrams,kcalPer100g:food?.caloriesPer100g});
    const afterFood=await candidate.locator('body').ariaSnapshot();
    check('UI shows the fictional 150 g food and 180 kcal',afterFood.includes('Синтетическая овсянка') && afterFood.includes('180 ккал'));

    // Warm an independent empty profile, then export a synthetic JSON through UI.
    const target=await context(), warm=await page(target,'restore-warm');await boot(warm);
    check('restore profile starts without water or food',await read(warm,key)===null && await read(warm,foodKey)===null && await water(warm)===null);
    await warm.close();
    // Seed the destination-only fake marker before its offline app starts.
    const targetSeed=await page(target,'target-seed');await targetSeed.goto(origin+'/__lab_legacy__/blank.html');
    await targetSeed.evaluate(({dbName,markerKey,targetMarker})=>new Promise((resolve,reject)=>{
      const r=indexedDB.open(dbName,2);r.onerror=()=>reject(r.error);
      r.onupgradeneeded=()=>r.transaction.abort();
      r.onsuccess=()=>{const db=r.result,tx=db.transaction('box','readwrite');
        tx.objectStore('box').put(targetMarker,markerKey);
        tx.oncomplete=()=>{db.close();resolve();};tx.onabort=()=>{db.close();reject(tx.error||Error('fixture marker abort'));};};
    }),{dbName,markerKey,targetMarker});
    check('destination contains a different synthetic private marker before import',await read(targetSeed,markerKey)===targetMarker);
    await targetSeed.close();latestPage=candidate;
    await backupPanel(candidate);
    const downloadPromise=candidate.waitForEvent('download',{timeout:30000});
    await click(candidate.getByRole('button',{name:'Экспорт JSON',exact:true}));
    const download=await downloadPromise, backupBytes=fs.readFileSync(await download.path());
    const backup=JSON.parse(backupBytes.toString('utf8'));
    check('UI JSON export contains synthetic committed water',backup.app==='fitness_tracker' && backup.data && backup.data[key]===1000,
      {syntheticWater:backup.data && backup.data[key],bytes:backupBytes.length});
    check('UI JSON export preserves the exact synthetic food payload',backup.data && backup.data[foodKey]===foodRaw);
    check('source marker is still stored but excluded from the exported JSON',
      await read(candidate,markerKey)===sourceMarker && !backupBytes.includes(Buffer.from(sourceMarker)) &&
      backup.data && !Object.prototype.hasOwnProperty.call(backup.data,markerKey));
    await boot(candidate);
    await new Promise(resolve=>{server.close(resolve);if(server.closeAllConnections)server.closeAllConnections();});serverDown=true;
    const unreachable=await new Promise(resolve=>{
      const r=http.get(origin+'/',()=>resolve(false));r.on('error',()=>resolve(true));r.setTimeout(2000,()=>{r.destroy();resolve(true);});
    });check('the loopback HTTP server is actually stopped',unreachable);
    await candidate.reload({waitUntil:'load',timeout:40000});await ready(candidate);
    check('candidate reopens offline and retains synthetic water',await water(candidate)===1000 && await read(candidate,key)===1000);
    check('candidate reopens offline with the exact synthetic food payload',
      await read(candidate,foodKey)===foodRaw && (await candidate.locator('body').ariaSnapshot()).includes('Синтетическая овсянка'));
    await Promise.all(pending);
    check('offline candidate main script comes from the service worker',loaded.some(x=>x.page==='candidate-second' && x.fromServiceWorker && x.sha256===manifest.files['main.dart.js']));
    const versionError=await old.evaluate(dbName=>new Promise(resolve=>{
      const r=indexedDB.open(dbName,1);r.onerror=e=>{e.preventDefault();resolve(r.error&&r.error.name);};
      r.onsuccess=()=>{r.result.close();resolve('unexpected-success');};
    }),dbName);
    risk('an ordinary v1 opener cannot open the synthetic v2 database offline',versionError==='VersionError',{error:versionError});

    const restore=await page(target,'restore-offline');await boot(restore);await backupPanel(restore);
    const chooserPromise=restore.waitForEvent('filechooser',{timeout:20000});
    await click(restore.getByRole('button',{name:'Импорт JSON / CSV',exact:true}));
    const chooser=await chooserPromise;await chooser.setFiles({name:'synthetic_backup.json',mimeType:'application/json',buffer:backupBytes});
    const replace=restore.getByRole('button',{name:'Заменить',exact:true});await replace.waitFor({state:'attached',timeout:20000});await click(replace);
    await until(async()=>await read(restore,key)===1000 && await read(restore,foodKey)===foodRaw,30000);
    check('offline UI import restores the exact water into a separate profile',await read(restore,key)===1000);
    check('offline UI import restores the exact synthetic food payload',await read(restore,foodKey)===foodRaw);
    check('offline import preserves the destination-only synthetic private marker',await read(restore,markerKey)===targetMarker);
    await Promise.all(pending);
    check('every executed candidate main script matches the sealed build',
      loaded.length>0 && loaded.every(x=>x.sha256===manifest.files['main.dart.js']));
    report.status='PASS_WITH_ROLLBACK_RISK_NOT_A_RELEASE';
  } catch(error){
    report.error={name:error.name||'Error',message:String(error.message||error).slice(0,700)};
    if(latestPage&&!latestPage.isClosed()){
      try{report.syntheticUiAtFailure=(await latestPage.locator('body').ariaSnapshot({timeout:3000})).slice(0,6000);}catch(_){}
      try{report.syntheticLoadingText=(await latestPage.locator('#loading').innerText({timeout:2000})).slice(0,1500);}catch(_){}
    }
    report.status='FAIL_OR_INCOMPLETE_NOT_A_RELEASE';
  } finally {
    report.blockedExternalPageRequests=blocked;
    for(const c of contexts){try{await c.close();}catch(_){}}
    try{if(browser)await browser.close();}catch(_){}
    if(!serverDown)await new Promise(resolve=>{server.close(resolve);if(server.closeAllConnections)server.closeAllConnections();});
    try{await Promise.all(pending);}catch(_){}
  }
  fs.writeFileSync(output,JSON.stringify(report,null,2)+'\n',{encoding:'utf8',flag:'wx',mode:0o600});
  console.log(JSON.stringify({engine,status:report.status,passes:checks.filter(x=>x.status==='PASS').length,risks:risks.length,output},null,2));
  if(report.status!=='PASS_WITH_ROLLBACK_RISK_NOT_A_RELEASE')process.exitCode=1;
}
run().catch(error=>{console.error('Probe failed:',error.name);process.exitCode=1;});
