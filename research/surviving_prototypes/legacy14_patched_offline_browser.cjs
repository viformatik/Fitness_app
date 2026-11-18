// LAB ONLY: extend the older offline-fence prototype with a source-pinned,
// in-memory patch to the archived +14 Hive write boundary. The patched +14 is
// NOT the unmodified release. All data is synthetic on a fixed fixture DB and
// 127.0.0.1; the loopback socket is physically cut during offline tests.
// This is NOT a real user's rollback, backup, application code or deployment.
// Ordinary old cached shells remain incompatible with v2; never delete or
// upgrade a real diary on the basis of this experiment.
'use strict';
const fs = require('fs');
const path = require('path');
const http = require('http');
const crypto = require('crypto');
const playwright = require('playwright');
const oldRoot = '/home/user/.cache/fitness-tab-upgrade-old';
const newRoot = '/home/user/.cache/fitness-tab-preview23/.vercel/output/static';
const fixtureDb = 'fitness_legacy_offline_commit_only_fixture';
const engine = process.env.FITNESS_PATCHED_OFFLINE_BROWSER || 'chromium';
const reportPath = process.env.FITNESS_PATCHED_OFFLINE_REPORT;
if(!['chromium','firefox'].includes(engine)||!reportPath||fs.existsSync(reportPath))throw Error('Specify browser and a new report');
const patchHarness=path.join(__dirname,'legacy14_commit_patch_browser.cjs');
const patchHarnessSha='333c0ae589b6bdb16f0e60a0f29f3a16ea552afb8b17c734205217beecea0261';
const patchedMainSha='bc9e219026b0e31cb6a7a808c0caf84a8d668642c8c25c537f310457f73fe629';
const sha = data => crypto.createHash('sha256').update(data).digest('hex');
const sleep = ms => new Promise(resolve => setTimeout(resolve,ms));
const click = locator => locator.first().evaluate(element => element.click());
const mime = file => file.endsWith('.html') ? 'text/html; charset=utf-8' :
  file.endsWith('.js') ? 'text/javascript' : file.endsWith('.json') ? 'application/json' :
  file.endsWith('.wasm') ? 'application/wasm' : file.endsWith('.png') ? 'image/png' :
  file.endsWith('.ttf') ? 'font/ttf' : file.endsWith('.otf') ? 'font/otf' : 'application/octet-stream';

function files(root) {
  const result=new Map();
  function walk(dir) {
    for (const entry of fs.readdirSync(dir,{withFileTypes:true})) {
      const full=path.join(dir,entry.name), relative=path.relative(root,full).split(path.sep).join('/');
      if(entry.isSymbolicLink()) throw Error('Unexpected symlink in fixture assets');
      if(entry.isDirectory()) walk(full);
      else if(entry.isFile() && !relative.startsWith('.')) result.set('/'+relative,fs.readFileSync(full));
    }
  }
  walk(root);return result;
}

function guard(tag) {
  // The timeout only produces a fail-closed availability message; it never
  // assumes that a legacy connection has died or forces a lock transfer.
  return `(() => {
    'use strict';
    const tag=${JSON.stringify(tag)}, dbName='fitness_v2', lock='synthetic-v2-transition-diary';
    window.__v2Fixture={tag,phase:'starting'};
    const loading=document.getElementById('loading');
    const show=(phase,title)=>{window.__v2Fixture.phase=phase;loading.classList.add('guard-message');
      loading.setAttribute('role','alert');loading.setAttribute('aria-label',title);loading.textContent=title;};
    const identity=()=>new Promise(resolve=>{
      const c=navigator.serviceWorker.controller;if(!c)return resolve(false);
      const channel=new MessageChannel();let done=false;
      const finish=value=>{if(done)return;done=true;clearTimeout(timer);channel.port1.close();resolve(value);};
      const timer=setTimeout(()=>finish(false),250);
      channel.port1.onmessage=e=>finish(e.data?.tag===tag && navigator.serviceWorker.controller===c);
      try{c.postMessage({type:'SYNTHETIC_V2_FIXTURE_IDENTITY'},[channel.port2]);}catch(_){finish(false);}
    });
    const ensureOfflineShell=async()=>{
      if(!navigator.serviceWorker)return false;
      if(await identity())return true;
      try{await navigator.serviceWorker.register('fitness_worker.js',{updateViaCache:'none'});}catch(_){}
      const end=Date.now()+7000;
      while(Date.now()<end){if(await identity())return true;await new Promise(r=>setTimeout(r,150));}
      return false;
    };
    const openV2=()=>new Promise((resolve,reject)=>{
      let request;
      try{request=indexedDB.open(dbName,2);}catch(e){reject(e);return;}
      request.onblocked=()=>show('blocked','Другая вкладка ещё использует дневник');
      request.onupgradeneeded=e=>{
        try{
          if(e.oldVersion===0)request.result.createObjectStore('box');
          else if(e.oldVersion!==1 || !request.result.objectStoreNames.contains('box'))request.transaction.abort();
        }catch(_){request.transaction.abort();}
      };
      request.onerror=e=>{e.preventDefault();reject(request.error);};
      request.onsuccess=()=>{
        if(request.result.version!==2 || !request.result.objectStoreNames.contains('box')){
          request.result.close();reject(Error('unexpected schema'));return;
        }
        resolve(request.result);
      };
    });
    const launch=async()=>{
      if(!window.isSecureContext || !navigator.locks || !navigator.serviceWorker){
        show('unsupported','Защищённая офлайн-оболочка недоступна');return;
      }
      try{
        await navigator.locks.request(lock,{ifAvailable:true},async held=>{
          if(!held){show('busy','Дневник уже открыт');return;}
          show('shell','Проверяем офлайн-оболочку');
          if(!await ensureOfflineShell()){
            show('no-shell','Офлайн-оболочка не установлена; данные не изменены');return;
          }
          // Confirm the matching worker immediately before requesting an upgrade.
          if(!await identity()){show('no-shell','Офлайн-оболочка изменилась');return;}
          let db;
          try{db=await openV2();}catch(_){show('storage-error','Не удалось открыть хранилище');return;}
          window.__fixtureDb=db;
          const native=IDBFactory.prototype.open;
          IDBFactory.prototype.open=function(name,version){
            return native.call(this,name,name===dbName && version===1?2:version);
          };
          window.__v2Fixture.phase='loading';
          const script=document.createElement('script');script.src='flutter_bootstrap.js';document.body.append(script);
          await new Promise(()=>{});
        });
      }catch(_){show('lock-error','Защита вкладок недоступна');}
    };
    launch();
  })();`;
}

function worker(tag, assets) {
  const expected={};for(const [url,bytes] of assets)expected[url]=sha(bytes);
  expected['/']=expected['/index.html'];
  return `'use strict';
  const TAG=${JSON.stringify(tag)}, CACHE='synthetic-v2-shared-blobs-v1', FILES=${JSON.stringify(expected)};
  const key=hash=>new URL('/__synthetic_blob/'+hash,self.location.origin).href;
  const digest=async response=>Array.from(new Uint8Array(await crypto.subtle.digest('SHA-256',await response.clone().arrayBuffer())))
    .map(x=>x.toString(16).padStart(2,'0')).join('');
  self.addEventListener('install',event=>{
    // Request takeover synchronously. Activation still waits for the verified
    // cache to finish; a rejected install never replaces the old worker.
    self.skipWaiting();
    event.waitUntil((async()=>{
    const cache=await caches.open(CACHE);let current='';
    try{
      for(const [url,hash] of Object.entries(FILES)){
        current=url;
        const saved=await cache.match(key(hash));
        if(saved && await digest(saved)===hash)continue;
        const response=await fetch(new Request(new URL(url,self.location.origin),{cache:'no-store'}));
        if(!response.ok)throw Error('asset unavailable');
        if(await digest(response)!==hash)throw Error('asset checksum mismatch');
        await cache.put(key(hash),response);
      }
    }catch(error){
      const msg={type:'SYNTHETIC_INSTALL_FAILURE',tag:TAG,file:current,name:error?.name,message:String(error?.message||error)};
      for(const client of await self.clients.matchAll({includeUncontrolled:true}))client.postMessage(msg);
      // Other active versions share these verified blobs. Do not delete their
      // cache when this installation fails; safe garbage collection is unsolved.
      throw error;
    }
    })());
  });
  self.addEventListener('activate',event=>event.waitUntil(self.clients.claim()));
  self.addEventListener('message',event=>{
    if(event.data?.type==='SYNTHETIC_V2_FIXTURE_IDENTITY' && event.ports[0])event.ports[0].postMessage({tag:TAG});
  });
  self.addEventListener('fetch',event=>{
    const u=new URL(event.request.url);
    if(event.request.method!=='GET' || u.origin!==self.location.origin ||
       u.pathname.startsWith('/__pass14/') || u.pathname.startsWith('/__monitor/'))return;
    const url=event.request.mode==='navigate'?'/index.html':u.pathname;
    if(!(url in FILES))return;
    event.respondWith((async()=>{
      const c=await caches.open(CACHE),cached=await c.match(key(FILES[url]));
      return cached||new Response('Synthetic offline asset missing',{status:503});
    })());
  });`;
}

function buildAssets(base, tag, shellIndex, fontManifest, fallback, mainOverride = null) {
  const assets=files(base);
  if(mainOverride)assets.set('/main.dart.js',mainOverride);
  assets.delete('/fitness_worker.js');
  // Use the tested shell's layout, but never its partial +23 guard. The
  // adapted rollback explicitly uses a modified old program, not exact +14.
  if(!shellIndex.includes('src="fitness_tab_guard.js"'))throw Error('Unexpected candidate index');
  const index=shellIndex.replace('src="fitness_tab_guard.js"','src="fitness_transition_guard.js"');
  assets.set('/index.html',Buffer.from(index));
  assets.set('/fitness_transition_guard.js',Buffer.from(guard(tag)));
  // +14 lacked a cached text fallback; the adapted shell explicitly includes it.
  assets.set('/assets/FontManifest.json',fontManifest);
  assets.set('/assets/fonts/fallback/Roboto-Regular.ttf',fallback);
  // Match the real shell's required set rather than caching unused renderer
  // variants and debug symbols. This is only a prototype, not proof that all
  // features have their complete offline dependency set.
  const core=[
    '/index.html','/flutter_bootstrap.js','/fitness_transition_guard.js','/main.dart.js','/version.json','/manifest.json',
    '/icons/Icon-192.png','/icons/Icon-512.png','/assets/AssetManifest.bin','/assets/AssetManifest.bin.json',
    '/assets/FontManifest.json','/assets/fonts/MaterialIcons-Regular.otf','/assets/fonts/fallback/Roboto-Regular.ttf',
    '/assets/packages/cupertino_icons/assets/CupertinoIcons.ttf','/assets/shaders/ink_sparkle.frag',
    '/assets/shaders/stretch_effect.frag','/canvaskit/canvaskit.js','/canvaskit/canvaskit.wasm',
    '/canvaskit/chromium/canvaskit.js','/canvaskit/chromium/canvaskit.wasm',
  ];
  const cached=new Map(core.map(url=>{if(!assets.has(url))throw Error('Missing core '+url);return [url,assets.get(url)];}));
  return {assets, worker:Buffer.from(worker(tag,cached))};
}

(async()=>{
  const checks=[],risks=[],failures=[],limitations=[],captures=[],pending=[];
  let browser,server,browserVersion=null;
  const debug={requests:[],messages:[]};
  const check=(name,condition,detail='')=>{
    checks.push({name,status:condition?'PASS':'FAIL',...(detail?{detail}:{})});
    if(!condition)throw Error(name+(detail?': '+detail:''));
  };
  const risk=(name,condition,detail='')=>{
    const item={name,status:condition?'RISK_REPRODUCED':'UNEXPECTED',...(detail?{detail}:{})};checks.push(item);risks.push(item);
    if(!condition)throw Error('Expected risk not reproduced: '+name);
  };
  try{
    const pinned=[
      [path.join(oldRoot,'index.html'),'372da5582453a954bd327d53074aa0c2695e7c5dc655fd9521ab6631ea22cd05'],
      [path.join(oldRoot,'main.dart.js'),'fbe81cc44f9d747592ebe7c2a687fe137c46a853d5f680c04bc442a3db489c11'],
      [path.join(newRoot,'main.dart.js'),'8bda98f617b4b51db3cfe9ef22b8abafe779b41ce7bff5837ef68dd95113fd33'],
    ];
    for(const [file,digest] of pinned)if(!fs.existsSync(file)||sha(fs.readFileSync(file))!==digest)
      throw Error('Restore and checksum-verify the local +14 and +23 fixtures first');
    const old=files(oldRoot),newAssets=files(newRoot);
    const patchSource=fs.readFileSync(patchHarness,'utf8');
    if(sha(Buffer.from(patchSource))!==patchHarnessSha)throw Error('Unverified source patch harness');
    const original=patchSource.match(/const originalMethod = `([\s\S]*?)`;/)?.[1];
    const replacement=patchSource.match(/const patchedMethod = `([\s\S]*?)`;/)?.[1];
    const oldSource=old.get('/main.dart.js').toString('utf8');
    if(!original||!replacement)throw Error('Missing pinned replacement');
    const start=oldSource.indexOf(original);
    if(start<0||oldSource.indexOf(original,start+1)>=0)throw Error('Unexpected minified method');
    const patched=Buffer.from(oldSource.slice(0,start)+replacement+oldSource.slice(start+original.length));
    if(sha(patched)!==patchedMainSha)throw Error('Unexpected patched JS');
    const shellIndex=newAssets.get('/index.html').toString('utf8');
    const fontManifest=newAssets.get('/assets/FontManifest.json'),fallback=newAssets.get('/assets/fonts/fallback/Roboto-Regular.ttf');
    if(!fontManifest||!fallback)throw Error('Missing tested offline font');
    const newBuild=buildAssets(newRoot,'new',shellIndex,fontManifest,fallback);
    const compat14=buildAssets(oldRoot,'adapted14',shellIndex,fontManifest,fallback,patched);
    check('адаптированный откат использует экспериментально изменённую, а не точную архивную +14',
      sha(compat14.assets.get('/main.dart.js'))===patchedMainSha && patchedMainSha!==pinned[1][1]);
    let mode='old',failAsset=false,networkCut=false;
    server=http.createServer((req,res)=>{
      if(networkCut){req.socket.destroy();return;}
      try{
        const url=new URL(req.url,'http://127.0.0.1');let pathname=decodeURIComponent(url.pathname);
        debug.requests.push(mode+' '+pathname);if(debug.requests.length>160)debug.requests.shift();
        if(pathname==='/__monitor/index.html'){
          res.writeHead(200,{'Content-Type':'text/html','Cache-Control':'no-store'});
          return res.end('<!doctype html><title>Local monitor</title><script>navigator.serviceWorker.register("/__monitor/sw.js")</script>');
        }
        if(pathname==='/__monitor/sw.js'){
          res.writeHead(200,{'Content-Type':'text/javascript','Cache-Control':'no-store'});
          return res.end("self.addEventListener('install',e=>self.skipWaiting());self.addEventListener('activate',e=>e.waitUntil(self.clients.claim()));");
        }
        if(pathname.startsWith('/__pass14/')){
          const key='/'+pathname.slice('/__pass14/'.length);
          let data=old.get(key);
          if(key==='/index.html'){
            const html=data.toString('utf8');if(!html.includes('<base href="/">'))throw Error('bad base');
            data=Buffer.from(html.replace('<base href="/">','<base href="/__pass14/">'));
          }
          if(!data)throw Error('missing old asset');
          res.writeHead(200,{'Content-Type':mime(key),'Cache-Control':'no-store'});return res.end(data);
        }
        if(pathname==='/')pathname='/index.html';
        if(failAsset && mode==='new' && pathname==='/main.dart.js'){
          res.writeHead(503,{'Cache-Control':'no-store'});return res.end('synthetic installation failure');
        }
        let data;
        if(mode==='old')data=old.get(pathname);
        else {
          const build=mode==='new'?newBuild:compat14;
          data=pathname==='/fitness_worker.js'?build.worker:build.assets.get(pathname);
        }
        if(!data)throw Error('missing fixture asset');
        res.writeHead(200,{'Content-Type':mime(pathname),'Cache-Control':'no-store'});res.end(data);
      }catch(_){res.writeHead(404);res.end();}
    });
    await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));
    const origin=`http://127.0.0.1:${server.address().port}`;
    const opts=engine==='chromium'?{headless:true,args:['--no-sandbox','--enable-unsafe-swiftshader','--lang=en-US',
      '--disable-background-networking','--no-proxy-server','--host-resolver-rules=MAP * ~NOTFOUND, EXCLUDE 127.0.0.1']}:
      {headless:true,firefoxUserPrefs:{'network.proxy.type':1,'network.proxy.http':'127.0.0.1','network.proxy.http_port':9,
        'network.proxy.ssl':'127.0.0.1','network.proxy.ssl_port':9,'network.proxy.no_proxies_on':'localhost, 127.0.0.1, [::1]','network.trr.mode':5}};
    browser=await playwright[engine].launch(opts);browserVersion=browser.version();
    async function context(){
      const c=await browser.newContext({viewport:{width:390,height:844},locale:'en-US'});
      c.on('serviceworker',w=>w.on('console',m=>debug.messages.push('worker: '+m.text().slice(0,250))));
      await c.route('**/*',r=>new URL(r.request().url()).origin===origin?r.continue():r.abort('blockedbyclient'));
      return c;
    }
    async function page(c,observe=false,label='other'){
      const p=await c.newPage();p.__fixtureLabel=label;
      p.on('pageerror',e=>debug.messages.push('pageerror: '+e.message.slice(0,250)));
      p.on('console',m=>{if(m.type()==='error'||m.type()==='warning')debug.messages.push('console: '+m.text().slice(0,250));});
      p.on('response',response=>{
        if(!new URL(response.url()).pathname.endsWith('/main.dart.js'))return;
        const item={label:p.__fixtureLabel,status:response.status(),fromServiceWorker:response.fromServiceWorker(),sha256:null,error:null};
        captures.push(item);pending.push(response.body().then(bytes=>{item.sha256=sha(bytes);},error=>{item.error=String(error).slice(0,150);}));
      });
      await p.addInitScript(name=>{
        window.flutterWebSemanticsEnabled=true;
        window.__legacyCommitPatchTrace={started:0,committed:0,rejected:0};
        window.__offlineFault=false;window.__offlineFaultOutcome={requestSuccess:false,aborted:false,completed:false};
        const open=IDBFactory.prototype.open;
        IDBFactory.prototype.open=function(db,version){return db==='fitness_v2'?open.call(this,name,version):open.apply(this,arguments);};
        const put=IDBObjectStore.prototype.put;
        IDBObjectStore.prototype.put=function(value,key){
          const request=put.apply(this,arguments);
          if(window.__offlineFault && this.transaction.db.name===name && this.name==='box' &&
             typeof key==='string' && key.startsWith('water_intake_')){
            window.__offlineFault=false;const tx=this.transaction;
            tx.addEventListener('abort',()=>window.__offlineFaultOutcome.aborted=true);
            tx.addEventListener('complete',()=>window.__offlineFaultOutcome.completed=true);
            request.addEventListener('success',()=>{window.__offlineFaultOutcome.requestSuccess=true;tx.abort();});
          }
          return request;
        };
        navigator.serviceWorker?.addEventListener('message',event=>{
          if(event.data?.type==='SYNTHETIC_INSTALL_FAILURE')console.warn('SYNTHETIC_INSTALL_FAILURE '+JSON.stringify(event.data));
        });
      },fixtureDb);
      if(observe)await p.addInitScript(()=>{
        window.__legacyOpen='not-called';
        const native=IDBFactory.prototype.open;
        IDBFactory.prototype.open=function(name,version){
          const request=native.apply(this,arguments);
          if(name==='fitness_v2'&&version===1){
            window.__legacyOpen='queued';
            request.addEventListener('success',()=>{window.__legacyOpen='success';});
            request.addEventListener('error',()=>{window.__legacyOpen=request.error?.name||'error';});
          }
          return request;
        };
      });
      return p;
    }
    const until=async(fn,timeout=45000)=>{
      const end=Date.now()+timeout;while(Date.now()<end){const v=await fn();if(v)return v;await sleep(200);}
      throw Error('Timed out waiting for synthetic state');
    };
    const enable=async (p,timeout=60000)=>until(async()=>{
      const a=p.getByRole('button',{name:'Enable accessibility'});if(await a.count())await click(a);
      return !!(await p.getByRole('button',{name:'Вода +250 мл',exact:true}).count());
    },timeout);
    const water=async p=>{
      const match=(await p.locator('body').ariaSnapshot()).match(/ВОДА\s+([0-9][0-9\s\u00a0\u202f]*)\s*мл/);
      return match?Number(match[1].replace(/[\s\u00a0\u202f]/g,'')):null;
    };
    const add=async(p,value)=>{
      await click(p.getByRole('button',{name:'Вода +250 мл',exact:true}));
      await until(async()=>await water(p)===value,12000);await sleep(500);
    };
    const version=async p=>p.evaluate(async name=>(await indexedDB.databases()).find(db=>db.name===name)?.version,fixtureDb);
    const rawWater=async p=>p.evaluate(async()=>{
      const d=new Date(),two=n=>String(n).padStart(2,'0'),key=`water_intake_${d.getFullYear()}-${two(d.getMonth()+1)}-${two(d.getDate())}`;
      const db=window.__fixtureDb;
      if(!db)throw Error('fixture guard has no v2 connection');
      return new Promise((resolve,reject)=>{
        const tx=db.transaction('box','readonly'),req=tx.objectStore('box').get(key);let value;
        req.onsuccess=()=>value=req.result;tx.oncomplete=()=>resolve(value??null);tx.onabort=()=>reject(tx.error||Error('read abort'));
      });
    });
    const socketIsCut=async()=>new Promise(resolve=>{
      const req=http.get(origin+'/__socket_probe',response=>{response.resume();resolve(false);});
      req.on('error',()=>resolve(true));req.setTimeout(3000,()=>{req.destroy();resolve(false);});
    });
    const controllerTag=async p=>p.evaluate(()=>new Promise(resolve=>{
      const c=navigator.serviceWorker.controller;if(!c)return resolve(null);
      const channel=new MessageChannel();let done=false;
      const finish=v=>{if(done)return;done=true;clearTimeout(timer);channel.port1.close();resolve(v);};
      const timer=setTimeout(()=>finish(null),300);
      channel.port1.onmessage=e=>finish(e.data?.tag||null);
      try{c.postMessage({type:'SYNTHETIC_V2_FIXTURE_IDENTITY'},[channel.port2]);}catch(_){finish(null);}
    }));
    const requestUpdate=async p=>p.evaluate(async()=>{const r=await navigator.serviceWorker.getRegistration('/');if(!r)throw Error('no worker');await r.update();});
    const monitor=async c=>{
      const m=await page(c);await m.goto(origin+'/__monitor/index.html');
      await until(()=>m.evaluate(()=>navigator.serviceWorker.controller?.scriptURL.endsWith('/__monitor/sw.js')),30000);
      return m;
    };
    // Observe the root registration from a page controlled by a more-specific
    // worker, so observing it does not keep the old root controller alive.
    const rootStatus=async m=>m.evaluate(async()=>{
      const r=await navigator.serviceWorker.getRegistration('/');if(!r)return {};
      const activeTag=await new Promise(resolve=>{
        if(!r.active)return resolve(null);
        const channel=new MessageChannel(),timer=setTimeout(()=>resolve(null),350);
        channel.port1.onmessage=e=>{clearTimeout(timer);resolve(e.data?.tag||null);};
        r.active.postMessage({type:'SYNTHETIC_V2_FIXTURE_IDENTITY'},[channel.port2]);
      });
      return {activeTag,active:r.active?.state,waiting:r.waiting?.state,installing:r.installing?.state};
    });

    // 1. Real +14 -> verified v2 fixture -> adapted +14 rollback, all in the
    // same disposable profile and same origin. Exercise actual offline reload.
    let c;
    if(process.env.SYNTHETIC_FAILURE_ONLY!=='1'){
    c=await context();
    try{
      mode='old';failAsset=false;
      const before=await page(c,true,'initial-original');await before.goto(origin+'/');await enable(before);await add(before,250);
      await until(()=>before.evaluate(async()=>!!navigator.serviceWorker.controller && (await caches.keys()).includes('fitness-smart-shell-3.0.0-14')));
      await until(()=>captures.some(x=>x.label==='initial-original'&&x.sha256===pinned[1][1]));
      check('исходная +14 записала воду и установила прежнюю офлайн-оболочку',await version(before)===1 && await water(before)===250);
      check('фактически загружен точный архивный JS +14',captures.some(x=>x.label==='initial-original'&&x.sha256===pinned[1][1]));
      const observer=await monitor(c);
      mode='new';
      let next=await page(c);await next.goto(origin+'/');
      const phase=await until(()=>next.evaluate(()=>{
        const p=window.__v2Fixture?.phase;return p==='blocked'||p==='no-shell'?p:null;
      }),30000);
      check('при открытой +14 эксперимент не изменяет версию базы',await version(before)===1 && await water(before)===250,`phase=${phase}`);
      if(phase==='blocked')check('проверенная оболочка ожидает уже открытое соединение +14',await controllerTag(next)==='new');
      else check('до активации новой оболочки Flutter не запускается',
        !(await next.getByRole('button',{name:'Вода +250 мл',exact:true}).count()));
      await add(before,500);await before.close();
      if(phase==='no-shell'){
        // Some service-worker transitions stay waiting while an old controlled
        // page is alive. Close the failed attempt; never upgrade on timeout.
        await next.close();
        await until(async()=>(await rootStatus(observer)).activeTag==='new',60000);
        next=await page(c);await next.goto(origin+'/');
      }
      await enable(next);
      check('после закрытия +14 v2 читает обе синтетические записи',await version(next)===2 && await water(next)===500);
      await add(next,750);
      const late=await page(c,true);await late.goto(origin+'/__pass14/index.html');
      await until(()=>late.evaluate(()=>window.__legacyOpen==='VersionError'),30000);
      check('неадаптированная поздняя +14 не может перезаписать новую версию',
        !(await late.getByRole('button',{name:'Вода +250 мл',exact:true}).count()));
      await late.close();
      networkCut=true;
      check('локальный сервер действительно разрывает сокет перед офлайн-проверкой',await socketIsCut());
      await next.reload({waitUntil:'load',timeout:60000});await enable(next);
      check('новая версия открывает сохранённую v2 без сети через проверенный worker',
        await controllerTag(next)==='new' && await water(next)===750 && await version(next)===2);
      await add(next,1000);
      networkCut=false;mode='adapted14';
      await requestUpdate(next);
      await until(async()=>{const s=await rootStatus(observer);return s.activeTag==='adapted14'||s.waiting==='installed';},60000);
      await next.close();
      await until(async()=>(await rootStatus(observer)).activeTag==='adapted14',60000);
      const rollback=await page(c,false,'adapted-online');await rollback.goto(origin+'/');await enable(rollback);
      check('специально адаптированный откат читает v2 и синтетические записи',
        await rollback.evaluate(()=>window.__v2Fixture?.tag)==='adapted14' && await version(rollback)===2 && await water(rollback)===1000);
      await add(rollback,1250);
      check('перед обрывом синтетические 1250 мл сохранены в IndexedDB',await rawWater(rollback)===1250);
      networkCut=true;
      check('перед офлайн-откатом локальный сокет действительно разорван',await socketIsCut());
      rollback.__fixtureLabel='offline-adapted';
      await rollback.reload({waitUntil:'load',timeout:60000});await enable(rollback);
      await until(()=>captures.some(x=>x.label==='offline-adapted'&&x.sha256===patchedMainSha));
      check('адаптированная сборка работает после перезапуска без локальной сети',
        await controllerTag(rollback)==='adapted14' && await water(rollback)===1250 && await rawWater(rollback)===1250);
      check('offline JS фактически получен от worker и совпадает с изменённым патчем',
        captures.some(x=>x.label==='offline-adapted'&&x.status===200&&x.sha256===patchedMainSha&&x.fromServiceWorker));
      await rollback.evaluate(()=>{window.__offlineFault=true;});
      await click(rollback.getByRole('button',{name:'Вода +250 мл',exact:true}));
      await until(()=>rollback.evaluate(()=>window.__offlineFaultOutcome.aborted),15000);
      await until(async()=>await water(rollback)===1250 &&
        (await rollback.locator('body').ariaSnapshot()).includes('Изменение не сохранено'),15000);
      const fault=await rollback.evaluate(()=>({events:window.__offlineFaultOutcome,trace:window.__legacyCommitPatchTrace}));
      check('при офлайн-abort после успеха запроса экран и IndexedDB сохранили 1250 мл и показали ошибку',
        fault.events.requestSuccess && fault.events.aborted && !fault.events.completed && fault.trace.rejected>=1 &&
        await water(rollback)===1250 && await rawWater(rollback)===1250);
      rollback.__fixtureLabel='offline-after-abort';
      await rollback.reload({waitUntil:'load',timeout:60000});await enable(rollback);
      await until(()=>captures.some(x=>x.label==='offline-after-abort'&&x.sha256===patchedMainSha));
      check('после offline-перезапуска отменённая запись не возникла и патч снова взят из worker',
        await water(rollback)===1250 && await rawWater(rollback)===1250 &&
        captures.some(x=>x.label==='offline-after-abort'&&x.fromServiceWorker&&x.sha256===patchedMainSha));

      // An unadapted rollback can replace the worker. Its offline shell still
      // expects v1. It is unsafe even though the data remains in v2.
      networkCut=false;
      mode='old';
      await rollback.evaluate(()=>{
        window.__controllerChanged=false;
        navigator.serviceWorker.addEventListener('controllerchange',()=>{window.__controllerChanged=true;},{once:true});
      });
      await requestUpdate(rollback);
      await until(()=>rollback.evaluate(async()=>window.__controllerChanged ||
        (await navigator.serviceWorker.getRegistration('/'))?.waiting?.state==='installed'),45000);
      await rollback.close();
      // The monitor is controlled by its own more-specific worker, not the
      // root registration, so it does not keep the old root worker active.
      await until(async()=>{
        const s=await rootStatus(observer);
        return s.active==='activated' && !s.waiting && !s.installing && s.activeTag===null;
      },45000);
      networkCut=true;
      check('перед обычным откатом локальный сокет по-прежнему разрывается',await socketIsCut());
      const bad=await page(c,true,'ordinary-offline');await bad.goto(origin+'/',{waitUntil:'load',timeout:60000});
      await until(()=>bad.evaluate(()=>window.__legacyOpen==='VersionError'),30000);
      risk('обычный неадаптированный откат снова ломает офлайн-открытие v2',
        !(await bad.getByRole('button',{name:'Вода +250 мл',exact:true}).count()) && await version(bad)===2);
      networkCut=false;mode='adapted14';
      await bad.reload({waitUntil:'load',timeout:60000});await enable(bad);
      check('возврат совместимой оболочки восстанавливает доступ без удаления БД',
        await controllerTag(bad)==='adapted14' && await version(bad)===2 && await water(bad)===1250);
    }finally{await c.close();}
    }

    // 2. A failed install must not commit the IndexedDB upgrade. The old
    // worker and legacy data stay usable while offline in this test.
    mode='old';failAsset=false;networkCut=false;c=await context();
    try{
      const original=await page(c,true);await original.goto(origin+'/');await enable(original);await add(original,250);
      await until(()=>original.evaluate(async()=>!!navigator.serviceWorker.controller && (await caches.keys()).includes('fitness-smart-shell-3.0.0-14')));
      const observer=await monitor(c);
      await original.close();mode='new';failAsset=true;
      const failed=await page(c);await failed.goto(origin+'/');
      await until(()=>failed.evaluate(()=>window.__v2Fixture?.phase==='no-shell'),45000);
      check('неполная новая офлайн-оболочка не повышает версию базы',await version(failed)===1);
      const oldCache=await failed.evaluate(async()=>{
        const cache=await caches.open('fitness-smart-shell-3.0.0-14'),result={};
        for(const name of ['index.html','flutter_bootstrap.js','main.dart.js','assets/FontManifest.json']){
          const r=await cache.match(new URL(name,location.origin+'/').href);
          result[name]=r?Array.from(new Uint8Array(await crypto.subtle.digest('SHA-256',await r.arrayBuffer())))
            .map(x=>x.toString(16).padStart(2,'0')).join(''):null;
        }return result;
      });
      debug.oldCache=oldCache;
      networkCut=true;
      check('при неудачной установке локальный сервер действительно отрезан',await socketIsCut());
      await failed.close();
      const oldOffline=await page(c,true,'failed-install-offline');await oldOffline.goto(origin+'/',{waitUntil:'load',timeout:60000});
      try{await enable(oldOffline,12000);}catch(error){
        const info=await oldOffline.evaluate(()=>({fixture:window.__v2Fixture,legacy:window.__legacyOpen,
          loading:document.getElementById('loading')?.textContent,scripts:Array.from(document.scripts).map(s=>s.src)}));
        throw Error(String(error)+'; offline diagnostic='+JSON.stringify(info));
      }
      check('после неудачной установки старая +14 читает записи без сети',
        await version(oldOffline)===1 && await water(oldOffline)===250);
      networkCut=false;await oldOffline.close();failAsset=false;
      let retry=await page(c);await retry.goto(origin+'/');
      const retryPhase=await until(()=>retry.evaluate(()=>{
        const p=window.__v2Fixture?.phase;return p==='no-shell'||p==='loading'?p:null;
      }),30000);
      if(retryPhase==='no-shell'){
        await retry.close();await until(async()=>(await rootStatus(observer)).activeTag==='new',60000);
        retry=await page(c);await retry.goto(origin+'/');
      }
      await enable(retry);
      check('после восстановления загрузки можно открыть синтетическую v2 с прежними данными',
        await controllerTag(retry)==='new' && await version(retry)===2 && await water(retry)===250);
    }finally{await c.close();}
    limitations.push('This is a synthetic loopback prototype, not +23 application code or a release. The adapted old Flutter JS is MODIFIED in memory, and the database name and opening version are TEST-ONLY shims.');
    limitations.push('An unadapted v1 client, including the real old rollback, cannot open v2; an old worker can replace the compatible worker and break offline access. The compatible worker has to be installed first. Neither cache eviction nor runtime tampering nor the entire asset set is covered.');
    limitations.push('The water fault is injected, not real quota exhaustion, eviction, browser/OS crash or power loss. Data committed to IndexedDB is not proof of physical flush. Only one water action is rechecked offline.');
    limitations.push('No real user data, account, deployment, physical Android, Safari/iOS, all Hive operations, privacy/deletion, server synchronization, direct-IP service-worker network, independent real backup or restoration were tested. The candidate remains blocked.');
  }catch(error){failures.push(String(error.stack||error));}
  finally{
    if(browser)await browser.close();if(server)await new Promise(resolve=>server.close(resolve));
    await Promise.allSettled(pending);
    const result={status:failures.length?'FAIL':process.env.SYNTHETIC_FAILURE_ONLY==='1'?'PARTIAL_FOCUSED_ONLY':'PARTIAL_UNADAPTED_ROLLBACK',
      browser:{engine,version:browserVersion},sourceSha256:{
        'checks/legacy14_patched_offline_browser.cjs':sha(fs.readFileSync(__filename)),
        'checks/legacy14_commit_patch_browser.cjs':patchHarnessSha,
        'archived+14/main.dart.js':'fbe81cc44f9d747592ebe7c2a687fe137c46a853d5f680c04bc442a3db489c11',
        'IN_MEMORY_PATCHED+14/main.dart.js':patchedMainSha,
        'local+23/main.dart.js':'8bda98f617b4b51db3cfe9ef22b8abafe779b41ce7bff5837ef68dd95113fd33'},
      captures,checks,failures,limitations,...(failures.length?{diagnostics:debug}: {})};
    fs.writeFileSync(reportPath,JSON.stringify(result,null,2)+'\n',{flag:'wx'});console.log(JSON.stringify(result,null,2));
    if(failures.length)process.exitCode=1;
  }
})();
