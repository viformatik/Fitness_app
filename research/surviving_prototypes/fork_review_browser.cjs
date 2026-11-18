// Two real archived Flutter builds, test-only IndexedDB name substitution,
// disposable profiles, no cloud, no service worker, and synthetic water only.
// This is NOT a production release, general backup, or safe full rollback.
const fs = require('node:fs');
const path = require('node:path');
const http = require('node:http');
const crypto = require('node:crypto');
const playwright = require('playwright');
const ROOT = path.resolve(__dirname, '..');
const old14 = '/home/user/.cache/fitness-tab-upgrade-old';
const old22 = '/home/user/.cache/fitness-vercel-preview22/.vercel/output/static';
const prototype = path.join(__dirname, 'fork_review_prototype');
const fork = path.join(__dirname, 'shadow_fork_prototype/fork.js');
const guard = path.join(__dirname, 'guarded_fork_prototype/guard.js');
const SOURCE = 'fitness_shadow_source_fixture';
const TARGET = 'fitness_shadow_target_fixture';
const KEY = 'water_intake_2026-10-25';
const output = process.env.FITNESS_FORK_REVIEW_REPORT;
const engine = process.env.FITNESS_TEST_BROWSER || 'chromium';
if (!output || fs.existsSync(output) || !['chromium','firefox'].includes(engine)) {
  throw Error('Choose a new FITNESS_FORK_REVIEW_REPORT and supported FITNESS_TEST_BROWSER');
}
const sha = value => crypto.createHash('sha256').update(value).digest('hex');
const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
const click = locator => locator.first().evaluate(element => element.click());

(async () => {
  const checks=[], failures=[], pageErrors=[], blockedHosts=[], loaded={};
  let server, browser, context, origin;
  const check = (condition, name, detail='', status='PASS') => {
    checks.push({name, status:condition ? status : 'FAIL', ...(detail ? {detail} : {})});
    if (!condition) throw Error(name + (detail ? ': ' + detail : ''));
  };
  const risk = (condition,name,detail='') => check(condition,name,detail,'RISK_REPRODUCED');
  async function until(fn,label,timeout=45000) {
    const end=Date.now()+timeout;
    while(Date.now()<end){const value=await fn();if(value)return value;await sleep(150);}
    throw Error('Timed out: '+label);
  }
  async function newContext() {
    const c=await browser.newContext({serviceWorkers:'block',locale:'en-US',viewport:{width:390,height:844}});
    await c.route('**/*',route=>{
      const url=new URL(route.request().url());
      if(url.origin===origin)return route.continue();
      blockedHosts.push(url.hostname);return route.abort('blockedbyclient');
    });
    return c;
  }
  async function newLab(c,noLocks=false) {
    const p=await c.newPage();
    p.on('pageerror',e=>pageErrors.push('lab: '+e.message.slice(0,250)));
    if(noLocks)await p.addInitScript(()=>Object.defineProperty(navigator,'locks',{configurable:true,value:undefined}));
    await p.goto(origin+'/',{waitUntil:'load',timeout:90000});
    return p;
  }
  async function openApp(c,version) {
    const p=await c.newPage();
    p.on('pageerror',e=>pageErrors.push(version+': '+e.message.slice(0,250)));
    p.on('response',async response=>{
      if(new URL(response.url()).pathname===`/app${version}/main.dart.js` && response.status()===200){
        try{loaded[version]=sha(await response.body());}catch(_){}
      }
    });
    await p.addInitScript(name=>{
      window.flutterWebSemanticsEnabled=true;
      const native=IDBFactory.prototype.open;
      IDBFactory.prototype.open=function(database,version){
        if(database==='fitness_v2')return native.call(this,name,version);
        return native.apply(this,arguments);
      };
    },SOURCE);
    await p.goto(origin+`/app${version}/`,{waitUntil:'load',timeout:90000});
    await until(async()=>{
      const a=p.getByRole('button',{name:'Enable accessibility'});
      if(await a.count())await click(a);
      return !!(await p.getByRole('button',{name:'Вода +250 мл',exact:true}).count());
    },'archived +'+version+' dashboard',90000);
    return p;
  }
  async function displayedWater(p) {
    const snapshot=await p.locator('body').ariaSnapshot();
    const match=snapshot.match(/ВОДА\s+([0-9][0-9\s\u00a0\u202f]*)\s*мл/);
    return match ? Number(match[1].replace(/[\s\u00a0\u202f]/g,'')) : null;
  }
  async function addWater(p,expected) {
    await click(p.getByRole('button',{name:'Вода +250 мл',exact:true}));
    await until(async()=>await displayedWater(p)===expected,'water indicator '+expected,18000);
    await sleep(700);
  }
  async function readRaw(p,name,key,store='box') {
    return p.evaluate(async({name,key,store})=>{
      if(!(await indexedDB.databases()).some(row=>row.name===name&&row.version===1))throw Error('fixture missing');
      const db=await new Promise((resolve,reject)=>{const r=indexedDB.open(name,1);r.onsuccess=()=>resolve(r.result);r.onerror=()=>reject(r.error)});
      try{return await new Promise((resolve,reject)=>{
        const tx=db.transaction(store,'readonly'),r=tx.objectStore(store).get(key);
        tx.oncomplete=()=>resolve(r.result===undefined?null:r.result);tx.onabort=()=>reject(tx.error);
      });}finally{db.close();}
    },{name,key,store});
  }
  async function waterKey(p) {
    return p.evaluate(async name=>{
      const db=await new Promise((resolve,reject)=>{const r=indexedDB.open(name,1);r.onsuccess=()=>resolve(r.result);r.onerror=()=>reject(r.error)});
      try{return await new Promise((resolve,reject)=>{
        const tx=db.transaction('box','readonly'),r=tx.objectStore('box').getAllKeys();
        tx.oncomplete=()=>{const keys=r.result.filter(k=>typeof k==='string'&&/^water_intake_\d{4}-\d{2}-\d{2}$/.test(k));
          if(keys.length!==1)reject(Error('expected one synthetic water key'));else resolve(keys[0]);};
        tx.onabort=()=>reject(tx.error);
      });}finally{db.close();}
    },SOURCE);
  }
  async function sourcePut(p,key,value) {
    return p.evaluate(async({name,key,value})=>{
      const db=await new Promise((resolve,reject)=>{const r=indexedDB.open(name,1);r.onsuccess=()=>resolve(r.result);r.onerror=()=>reject(r.error)});
      try{await new Promise((resolve,reject)=>{const tx=db.transaction('box','readwrite');
        tx.objectStore('box').put(value,key);tx.oncomplete=resolve;tx.onabort=()=>reject(tx.error);});}finally{db.close();}
    },{name:SOURCE,key,value});
  }
  async function metaIds(p,prefix) {
    return p.evaluate(async({name,prefix})=>{
      const db=await new Promise((resolve,reject)=>{const r=indexedDB.open(name,1);r.onsuccess=()=>resolve(r.result);r.onerror=()=>reject(r.error)});
      try{return await new Promise((resolve,reject)=>{const tx=db.transaction('meta','readonly');const r=tx.objectStore('meta').getAllKeys();
        tx.oncomplete=()=>resolve(r.result.filter(k=>typeof k==='string'&&k.startsWith(prefix)));tx.onabort=()=>reject(tx.error);});}finally{db.close();}
    },{name:TARGET,prefix});
  }
  const status=p=>p.evaluate(async()=>(await window.syntheticGuardedFork.status()).state);
  const inspect=p=>p.evaluate(()=>window.syntheticForkLab.inspect());
  const forkDb=p=>p.evaluate(()=>window.syntheticForkLab.createFork());
  const preview=(p,key)=>p.evaluate(key=>window.syntheticForkReview.preview(key),key);
  const guardedPut=(p,key,expected,next)=>p.evaluate(({key,expected,next})=>window.syntheticGuardedFork.put(key,expected,next),{key,expected,next});
  const archive=(p,id)=>p.evaluate(id=>window.syntheticForkReview.readArchive(id),id);
  const resolveChoice=(p,view,selection,value,confirmed,flags={})=>p.evaluate(({view,selection,value,confirmed,flags})=>
    window.syntheticForkReview.resolve(view,selection,value,confirmed,flags),{view,selection,value,confirmed,flags});
  const project=(p,view,confirmed,flags={})=>p.evaluate(({view,confirmed,flags})=>
    window.syntheticForkReview.projectWaterToLegacy(view,confirmed,flags),{view,confirmed,flags});
  async function seed(p) {
    await p.evaluate(async({name,key})=>{
      if((await indexedDB.databases()).some(row=>row.name===name))throw Error('refuse existing fixture');
      const db=await new Promise((resolve,reject)=>{const r=indexedDB.open(name,1);
        r.onupgradeneeded=()=>r.result.createObjectStore('box');r.onsuccess=()=>resolve(r.result);r.onerror=()=>reject(r.error);});
      try{await new Promise((resolve,reject)=>{const tx=db.transaction('box','readwrite'),s=tx.objectStore('box');
        s.put(true,'_migration_v1');s.put(250,key);tx.oncomplete=resolve;tx.onabort=()=>reject(tx.error);});}finally{db.close();}
    },{name:SOURCE,key:KEY});
    await forkDb(p);
  }
  async function fresh() {
    if(context)await context.close();
    context=await newContext();
    return newLab(context);
  }
  try {
    const artifacts={
      '14/index.html':[old14,'index.html','372da5582453a954bd327d53074aa0c2695e7c5dc655fd9521ab6631ea22cd05'],
      '14/main.dart.js':[old14,'main.dart.js','fbe81cc44f9d747592ebe7c2a687fe137c46a853d5f680c04bc442a3db489c11'],
      '14/version.json':[old14,'version.json','52ecc8aa6294dfcdf190c4fd7082f326a4deba8d5cd158413e52bad3f57aba0d'],
      '22/index.html':[old22,'index.html','a24df9956b39ce596fe5caee21abbdf9c7d9cc1073923a4d4b114f8a43ce57d0'],
      '22/main.dart.js':[old22,'main.dart.js','8bda98f617b4b51db3cfe9ef22b8abafe779b41ce7bff5837ef68dd95113fd33'],
      '22/version.json':[old22,'version.json','1d8560a123143f1378256b60fa69986213570d172992890a926d13b9a7903ee8'],
    };
    for(const [label,[dir,file,expected]] of Object.entries(artifacts)){
      if(sha(fs.readFileSync(path.join(dir,file)))!==expected)throw Error('Artifact mismatch: '+label);
    }
    check(true,'архивы +14 и +22 проверены по SHA-256 до запуска');
    server=http.createServer((req,res)=>{
      try{
        const request=decodeURIComponent(new URL(req.url,'http://127.0.0.1').pathname);let file,data;
        const matched=request.match(/^\/app(14|22)\/(.*)$/);
        if(matched){
          const base=matched[1]==='14'?old14:old22, relative=matched[2]||'index.html';
          file=path.resolve(base,relative);
          if(!file.startsWith(base+path.sep)||!fs.statSync(file).isFile())throw Error('not found');
          data=fs.readFileSync(file);
          if(relative==='index.html'){
            const html=data.toString('utf8');
            if(!html.includes('<base href="/">'))throw Error('unexpected base');
            data=Buffer.from(html.replace('<base href="/">',`<base href="/app${matched[1]}/">`));
          }
        }else{
          const relative=request==='/'?'index.html':request.slice(1);
          if(!['index.html','fork.js','guard.js','review.js','ui.js'].includes(relative))throw Error('not found');
          file=relative==='fork.js'?fork:relative==='guard.js'?guard:path.join(prototype,relative);
          data=fs.readFileSync(file);
        }
        const ext=path.extname(file),type=ext==='.js'?'text/javascript':ext==='.html'?'text/html; charset=utf-8':
          ext==='.json'?'application/json':ext==='.wasm'?'application/wasm':'application/octet-stream';
        res.writeHead(200,{'Content-Type':type,'Cache-Control':'no-store'});res.end(data);
      }catch(_){res.writeHead(404);res.end();}
    });
    await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));
    origin=`http://127.0.0.1:${server.address().port}`;
    browser=engine==='chromium'?await playwright.chromium.launch({headless:true,args:[
      '--no-sandbox','--enable-unsafe-swiftshader','--lang=en-US','--disable-background-networking','--no-proxy-server',
      '--host-resolver-rules=MAP * ~NOTFOUND, EXCLUDE 127.0.0.1',
    ]}):await playwright.firefox.launch({headless:true,firefoxUserPrefs:{
      'network.proxy.type':1,'network.proxy.http':'127.0.0.1','network.proxy.http_port':9,
      'network.proxy.ssl':'127.0.0.1','network.proxy.ssl_port':9,
      'network.proxy.no_proxies_on':'localhost, 127.0.0.1, [::1]','network.trr.mode':5,
    }});

    // Actual +14 keeps an old in-memory copy while the new experimental branch
    // records an independent addition. Equal totals are an explicit conflict.
    let lab=await fresh();
    const old=await openApp(context,'14');
    await addWater(old,250);
    const key=await waterKey(lab);
    check(await readRaw(lab,SOURCE,key)===250,'архивная +14 действительно записала 250 мл в отдельную тестовую БД');
    await forkDb(lab);
    check((await guardedPut(lab,key,250,500)).status==='committed' && await readRaw(lab,SOURCE,key)===250 &&
      await readRaw(lab,TARGET,key)===500,'новая ветвь сохраняет изменение, не перезаписывая исходную');
    await addWater(old,500);
    const blocked=await guardedPut(lab,key,500,750);
    check(blocked.status==='blocked' && blocked.reason==='legacy_diverged' && await status(lab)==='review_required',
      'независимое изменение +14 блокирует следующую участвующую запись');
    let view=await preview(lab,key);
    check(view.baseline===250 && view.legacy===500 && view.current===500,
      'сравнение показывает исходные 250 и обе независимые версии по 500 мл');
    const without=await resolveChoice(lab,view,'manual',750,false);
    check(without.status==='blocked' && without.reason==='confirmation_required' && await readRaw(lab,TARGET,key)===500,
      'без подтверждения итог не сохраняется');
    // Exercise the explicit confirmation UI instead of only invoking the API.
    await lab.locator('#key').fill(key);
    await lab.getByRole('button',{name:'Показать сравнение'}).click();
    await until(async()=>(await lab.locator('#comparison').innerText()).includes('Новая ветвь: 500 мл'),'UI comparison');
    const text=await lab.locator('#comparison').innerText();
    check(text.includes('Исходный снимок: 250 мл') && text.includes('Старая ветвь: 500 мл') && text.includes('Новая ветвь: 500 мл'),
      'интерфейс показывает три точных значения, а не текст кнопки');
    await lab.locator('input[name="choice"][value="manual"]').check();
    await lab.locator('#manual').fill('750');
    await lab.getByRole('button',{name:'Применить выбор к тестовой новой ветви'}).click();
    check((await lab.locator('#status').innerText()).includes('подтвердите') && await readRaw(lab,TARGET,key)===500,
      'интерфейс не применяет выбранный итог без галочки подтверждения');
    await lab.locator('#confirm').check();
    await lab.getByRole('button',{name:'Применить выбор к тестовой новой ветви'}).click();
    await until(async()=>(await lab.locator('#status').innerText()).includes('Выбор сохранён'),'UI committed');
    const ids=await metaIds(lab,'review:');
    const saved=ids.length===1?await archive(lab,ids[0]):null;
    check(await readRaw(lab,SOURCE,key)===500 && await readRaw(lab,TARGET,key)===750 && saved?.legacy===500 &&
      saved?.baseline===250 && saved?.previousCurrent===500 && saved?.selected===750 && saved?.selection==='manual',
      'подтверждённый итог сохранён в новой ветви, обе предыдущие версии сохранены в её архиве');
    check(await status(lab)==='open' && !(await inspect(lab)).legacyChanged,
      'после явного выбора согласован исходный снимок; старая ветвь не переписана');
    await lab.reload({waitUntil:'load'});
    check((await archive(lab,ids[0]))?.selected===750 && await readRaw(lab,TARGET,key)===750,
      'выбор и синтетический архив переживают перезапуск страницы');

    // One-key projection simulates a rollback only. The still-open old page
    // has a stale value; an additional +250 produces an indistinguishable 750.
    view=await preview(lab,key);
    check((await project(lab,view,false)).reason==='confirmation_required' && await readRaw(lab,SOURCE,key)===500,
      'перенос одной записи в старую ветвь требует отдельного подтверждения');
    const moved=await project(lab,view,true);
    check(moved.status==='projected' && await readRaw(lab,SOURCE,key)===750 &&
      (await archive(lab,moved.id))?.legacy===500 && await displayedWater(old)===500,
      'одна запись перенесена в старую ветвь, а её прежнее значение сохранено в тестовом архиве');
    await addWater(old,750);
    const after=(await inspect(lab));
    risk(await readRaw(lab,SOURCE,key)===750 && await readRaw(lab,TARGET,key)===750 && !after.legacyChanged,
      'старая вкладка после переноса может незаметно потерять независимое действие',
      'После выбранных 750 мл старая вкладка с 500 мл добавила 250 мл: ожидаемо 1000 мл, но обе ветви содержат 750 мл. По равным значениям действие не обнаружить.');
    await old.close();
    const legacyReload=await openApp(context,'14');
    check(await displayedWater(legacyReload)===750 && await readRaw(lab,SOURCE,key)===750,
      'архивная +14 читает перенесённое значение v1 после закрытия старой вкладки');
    await legacyReload.close();

    // Fresh +22, close the old tab before one-key projection, then reopen it.
    lab=await fresh();
    const oldPreview=await openApp(context,'22'); await addWater(oldPreview,250);
    const key22=await waterKey(lab);await forkDb(lab);
    check((await guardedPut(lab,key22,250,500)).status==='committed',
      'отдельная ветвь с архивной +22 создана и изменена');
    await oldPreview.close();
    view=await preview(lab,key22);
    const moved22=await project(lab,view,true);
    const reopened22=await openApp(context,'22');
    check(moved22.status==='projected' && await readRaw(lab,SOURCE,key22)===500 && await displayedWater(reopened22)===500,
      'после закрытия +22 перенос одной воды доступен при её повторном открытии без повышения версии БД');
    check((await lab.evaluate(async name=>(await indexedDB.databases()).find(d=>d.name===name)?.version,SOURCE))===1,
      'в обоих сценариях схема исходной тестовой БД остаётся v1');
    await reopened22.close();

    // Stale preview and artificial abort must not change the selected branch.
    lab=await fresh();await seed(lab);await guardedPut(lab,KEY,250,500);await sourcePut(lab,KEY,500);
    await guardedPut(lab,KEY,500,750);view=await preview(lab,KEY);await sourcePut(lab,KEY,600);
    const stale=await resolveChoice(lab,view,'manual',750,true);
    check(stale.status==='blocked' && stale.reason==='stale_preview' && await readRaw(lab,TARGET,KEY)===500 &&
      (await metaIds(lab,'review:')).length===0,'изменение старой ветви после просмотра отклоняет устаревший выбор');
    view=await preview(lab,KEY);
    const aborted=await resolveChoice(lab,view,'manual',750,true,{abortTarget:true});
    check(aborted.status==='not_committed' && await readRaw(lab,TARGET,KEY)===500 &&
      await readRaw(lab,TARGET,KEY,'baseline')===250 && (await metaIds(lab,'review:')).length===0 &&
      await status(lab)==='review_required','искусственный abort отменяет итог, базу и архив одной транзакцией');
    const concurrent=await lab.evaluate(async view=>window.syntheticForkReview.resolve(view,'manual',750,true,{
      afterTargetCommit:async()=>{
        const db=await new Promise((resolve,reject)=>{const r=indexedDB.open('fitness_shadow_source_fixture',1);r.onsuccess=()=>resolve(r.result);r.onerror=()=>reject(r.error)});
        try{await new Promise((resolve,reject)=>{const tx=db.transaction('box','readwrite');tx.objectStore('box').put(800,view.key);
          tx.oncomplete=resolve;tx.onabort=()=>reject(tx.error);});}finally{db.close();}
      }}),view);
    check(concurrent.status==='committed_review' && await status(lab)==='review_required' &&
      await readRaw(lab,SOURCE,KEY)===800 && await readRaw(lab,TARGET,KEY)===750 &&
      (await archive(lab,concurrent.id))?.legacy===600,'изменение между транзакциями сохраняет обе ветви и оставляет требование проверки');

    // Termination after target commit: do not replay; retain an archive and a
    // pending marker across reload, then explicitly review and acknowledge.
    lab=await fresh();await seed(lab);await guardedPut(lab,KEY,250,500);await sourcePut(lab,KEY,500);
    await guardedPut(lab,KEY,500,750);view=await preview(lab,KEY);
    const interrupted=await resolveChoice(lab,view,'manual',750,true,{haltAfterTargetCommit:true});
    check(interrupted.status==='committed_pending' && await status(lab)==='pending_verification' &&
      await readRaw(lab,TARGET,KEY)===750,'после фиксации без проверки остаётся устойчивая метка неопределённости');
    await lab.reload({waitUntil:'load'});
    const resumed=await lab.evaluate(()=>window.syntheticForkReview.markInterruptedForReview());
    check(resumed.status==='review_required' && resumed.id===interrupted.id && await status(lab)==='review_required' &&
      (await archive(lab,resumed.id))?.selected===750,'перезапуск требует ручной проверки и не повторяет запись');
    view=await preview(lab,KEY);
    const noAck=await lab.evaluate(view=>window.syntheticForkReview.acknowledge(view,false),view);
    const ack=await lab.evaluate(view=>window.syntheticForkReview.acknowledge(view,true),view);
    check(noAck.reason==='confirmation_required' && ack.status==='acknowledged' && await status(lab)==='open' &&
      await readRaw(lab,TARGET,KEY)===750,'явное подтверждение после просмотра снимает метку без изменения сохранённого итога');

    // Old source changed between durable intent and source CAS.
    lab=await fresh();await seed(lab);await guardedPut(lab,KEY,250,500);view=await preview(lab,KEY);
    const oldRace=await lab.evaluate(async view=>window.syntheticForkReview.projectWaterToLegacy(view,true,{
      afterIntent:async()=>{
        const db=await new Promise((resolve,reject)=>{const r=indexedDB.open('fitness_shadow_source_fixture',1);r.onsuccess=()=>resolve(r.result);r.onerror=()=>reject(r.error)});
        try{await new Promise((resolve,reject)=>{const tx=db.transaction('box','readwrite');tx.objectStore('box').put(300,view.key);
          tx.oncomplete=resolve;tx.onabort=()=>reject(tx.error);});}finally{db.close();}
      }}),view);
    check(oldRace.status==='not_projected' && oldRace.reason==='stale_preview' && await readRaw(lab,SOURCE,KEY)===300 &&
      await readRaw(lab,TARGET,KEY)===500 && await status(lab)==='review_required' && (await archive(lab,oldRace.id))?.legacy===250,
      'изменение старой ветви после подготовки отменяет перенос и оставляет обе версии');

    // A source transaction abort cannot be reported as a completed projection.
    lab=await fresh();await seed(lab);await guardedPut(lab,KEY,250,500);view=await preview(lab,KEY);
    const abortSource=await project(lab,view,true,{abortSource:true});
    check(abortSource.status==='not_projected' && await readRaw(lab,SOURCE,KEY)===250 &&
      await readRaw(lab,TARGET,KEY)===500 && await status(lab)==='review_required' &&
      (await archive(lab,abortSource.id))?.selected===500,'искусственная отмена исходной транзакции не выдаётся за перенос');

    // Crash after source commit: two databases cannot share a commit. The
    // durable intent makes uncertainty visible and requires a new comparison.
    lab=await fresh();await seed(lab);await guardedPut(lab,KEY,250,500);view=await preview(lab,KEY);
    const crash=await project(lab,view,true,{haltAfterSourceCommit:true});
    check(crash.status==='projected_pending' && await readRaw(lab,SOURCE,KEY)===500 &&
      await readRaw(lab,TARGET,KEY,'baseline')===250 && await status(lab)==='pending_verification',
      'прерывание между базами оставляет видимую неопределённость, а не автоматический повтор');
    await lab.reload({waitUntil:'load'});await lab.evaluate(()=>window.syntheticForkReview.markInterruptedForReview());
    view=await preview(lab,KEY);
    check(view.legacy===500 && view.current===500 && view.baseline===250 && await status(lab)==='review_required',
      'после прерывания равные итоговые значения снова требуют проверки');
    const chosen=await resolveChoice(lab,view,'current',null,true);
    check(chosen.status==='committed' && await readRaw(lab,SOURCE,KEY)===500 &&
      await readRaw(lab,TARGET,KEY,'baseline')===500 && (await archive(lab,crash.id))?.legacy===250,
      'ручной выбор после прерывания согласует базу, сохраняя предыдущее значение в архиве');

    // Mutation after the final inspection is still a fundamental two-DB race.
    lab=await fresh();await seed(lab);await guardedPut(lab,KEY,250,500);await sourcePut(lab,KEY,500);
    await guardedPut(lab,KEY,500,750);view=await preview(lab,KEY);
    const late=await lab.evaluate(async view=>window.syntheticForkReview.resolve(view,'manual',750,true,{
      afterInspection:async()=>{
        const db=await new Promise((resolve,reject)=>{const r=indexedDB.open('fitness_shadow_source_fixture',1);r.onsuccess=()=>resolve(r.result);r.onerror=()=>reject(r.error)});
        try{await new Promise((resolve,reject)=>{const tx=db.transaction('box','readwrite');tx.objectStore('box').put(800,view.key);
          tx.oncomplete=resolve;tx.onabort=()=>reject(tx.error);});}finally{db.close();}
      }}),view);
    risk(late.status==='committed' && await status(lab)==='open' && (await inspect(lab)).legacyChanged,
      'запись после последней проверки временно остаётся незамеченной',
      'Снимок и транзакция другой IndexedDB не атомарны; обе версии остались раздельно, но отметка open не доказывает отсутствия позднего изменения.');
    const next=await guardedPut(lab,KEY,750,1000);
    check(next.status==='blocked' && next.reason==='legacy_diverged' && await status(lab)==='review_required',
      'следующая участвующая запись обнаруживает позднее расхождение и блокируется');

    // No Locks and unsupported keys are rejected, not silently treated as safe.
    const unsupported=await newLab(context,true);
    view=await preview(unsupported,KEY);
    check((await resolveChoice(unsupported,view,'current',null,true)).reason==='no_lock',
      'без Web Locks ручной выбор не применяется молча');
    const bad=await lab.evaluate(async()=>{try{await window.syntheticForkReview.preview('food_entries_2026-10-25');return false;}catch(_){return true;}});
    check(bad,'стенд явно отказывает другим документам вместо неподтверждённого универсального переноса');
    check(loaded['14']==='fbe81cc44f9d747592ebe7c2a687fe137c46a853d5f680c04bc442a3db489c11' &&
      loaded['22']==='8bda98f617b4b51db3cfe9ef22b8abafe779b41ce7bff5837ef68dd95113fd33',
      'проверены SHA фактически загруженных main.dart.js обеих архивных версий');
    check(pageErrors.length===0,'необработанных ошибок страниц не зарегистрировано',pageErrors.join('; '));
  }catch(error){failures.push(String(error.stack||error));}
  finally{
    if(context)await context.close().catch(()=>{});
    if(browser)await browser.close().catch(()=>{});
    if(server)await new Promise(resolve=>server.close(resolve));
    const files=['checks/fork_review_browser.cjs','checks/fork_review_prototype/index.html','checks/fork_review_prototype/ui.js',
      'checks/fork_review_prototype/review.js','checks/shadow_fork_prototype/fork.js','checks/guarded_fork_prototype/guard.js'];
    const report={status:failures.length?'FAIL_DIAGNOSTIC':'PARTIAL_SYNTHETIC_KNOWN_RISKS_NOT_A_RELEASE',
      browser:{engine,version:browser?.version()??null},checks,failures,pageErrors,blockedHosts:[...new Set(blockedHosts)],loadedMainSha256:loaded,
      sourceSha256:Object.fromEntries(files.map(file=>[file,sha(fs.readFileSync(path.join(ROOT,file)))])),
      limitations:[
        'Only one synthetic integer water key is resolved or projected; no food, profile, workouts, privacy settings, account or general migration is covered.',
        'The Flutter compiled JS is exact +14/+22, but the HTML base path and IndexedDB database name are changed in the test harness. The branch and review UI are not the current app.',
        'Two databases have no shared transaction. A legacy writer after the last check, or an ABA/same-value write, may go unnoticed. A stale old tab after projection reproduced a lost independent increment.',
        'The archived old app cannot read new-only documents until explicitly projected. One-key projection is NOT an ordinary or complete rollback; old clients still use their previous Hive commit semantics.',
        'Service workers and all non-loopback requests are blocked; this is not an offline shell, live cloud, real backup, production profile, crash durability, quota, or physical Android test.',
        'Review archives retain synthetic values; secure deletion, privacy lifecycle, large documents, recovery export and account isolation are not implemented.',
        'Playback in Linux browser engines is not a substitute for physical Android or Safari/iOS.'
      ]};
    try{fs.writeFileSync(output,JSON.stringify(report,null,2)+'\n',{flag:'wx'});}catch(error){console.error('Could not write new report:',error);process.exitCode=1;}
    console.log(JSON.stringify(report,null,2));if(failures.length)process.exitCode=1;
  }
})();
