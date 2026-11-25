/* Replace the Studio block from `const PUBQ=` through (but not including)
   `function cvStatus()`. Requires the companion SQL repair. */
const PUBQ=new Map();let pubBusy=false,pubErr=false;
const CLOUD={ok:null,busy:false,again:false,last:0,n:0,error:'',bound:null};let appLoaded=false;
const tms=x=>{const v=Date.parse(x||'');return isNaN(v)?0:v};
const msg=(en,es)=>LANG==='es'?es:en;
// A browser's existing IndexedDB is one workspace. Never implicitly move it.
const BIND_KEY='pss-workspace-program-v1';
function boundProgram(){try{return localStorage.getItem(BIND_KEY)}catch(e){return null}}
function claimWorkspace(program){
  if(!appLoaded||!program)return false;
  const prior=boundProgram();if(prior)return prior===program;
  if(!window.confirm(msg(`Connect this browser's local studio to ${program}? Only approve if all local players belong to this program.`, `¿Conectar el estudio local de este navegador con ${program}? Confirma solo si todos los jugadores locales pertenecen a este programa.`)))return false;
  try{localStorage.setItem(BIND_KEY,program);return boundProgram()===program}catch(e){return false}
}
function cloudArgs(){let code='';try{code=localStorage.getItem('pss-coach')||''}catch(e){}
  const prog=cvProgram();return appLoaded&&code&&COACH&&COACH.code===code&&prog&&boundProgram()===prog?{p_code:code,p_school:prog}:null}
const sameContext=a=>{const b=cloudArgs();return !!(a&&b&&a.p_code===b.p_code&&a.p_school===b.p_school)};
async function cloudCall(fn,body){const r=await sbRpc(fn,body);if(!r.ok)throw new Error('request failed');return r.json()}
function requireWrite(v){if(v!==true)throw new Error('write not confirmed')}
// Durable removal requests contain only IDs and program, never photographs or codes.
const DEL_KEY='pss-pending-removals-v1';
function pendingDeletes(){try{return JSON.parse(localStorage.getItem(DEL_KEY)||'{}')||{}}catch(e){return {}}}
function rememberDelete(id){const a=cloudArgs();const school=a?a.p_school:boundProgram();if(!school)return;const d=pendingDeletes();d[JSON.stringify([school,id])]=true;localStorage.setItem(DEL_KEY,JSON.stringify(d))}
function clearDelete(key){const d=pendingDeletes();delete d[key];localStorage.setItem(DEL_KEY,JSON.stringify(d))}
function queuePublish(){requestCloudSync()}
function syncQueue(id){if(id&&!PLAYERS.some(x=>x.id===id)){try{rememberDelete(id)}catch(e){CLOUD.error='local storage unavailable'}}requestCloudSync()}
function requestCloudSync(){if(!cloudArgs())return;cloudSync()}
let setT=0;
function settingsChanged(){try{localStorage.setItem('pss-set-at',new Date().toISOString())}catch(e){}clearTimeout(setT);setT=setTimeout(requestCloudSync,1200)}
function settingsAt(){try{return localStorage.getItem('pss-set-at')||''}catch(e){return ''}}
async function putSettings(a){if(!sameContext(a))throw new Error('workspace changed');let at=settingsAt();if(!at){at=new Date().toISOString();localStorage.setItem('pss-set-at',at)}requireWrite(await cloudCall('studio_settings_put',Object.assign({p_data:S,p_at:at},a)))}
async function publishConfirmed(p,a){
  if(!sameContext(a))throw new Error('workspace changed');
  if(!canExport(p,true))return;
  const b=await exportBlob(p,'portrait');const [image,thumb]=await Promise.all([jpegOf(b,1080,.86),jpegOf(b,360,.8)]);
  if(!sameContext(a))throw new Error('workspace changed');
  const d=await cloudCall('spotlight_publish_checked',Object.assign({p_key:p.id,p_name:p.name,p_team:p.team||'',p_category:p.category||'',p_thumb:thumb,p_image:image,p_at:p.updatedAt},a));
  if(!d||d.ok!==true||d.school!==a.p_school)throw new Error('card not confirmed');
  const m=pubMap();m[p.id]={school:a.p_school,at:p.updatedAt||''};pubSave(m);
}
async function cloudSync(){
  const a=cloudArgs();if(!a)return;if(CLOUD.busy){CLOUD.again=true;return}
  CLOUD.busy=true;CLOUD.ok=null;CLOUD.error='';pubBusy=true;pubErr=false;ccShow();let changed=false;
  try{
    const L=await cloudCall('studio_list',a);if(!L||L.school!==a.p_school||!Array.isArray(L.players)||!sameContext(a))throw new Error('workspace not confirmed');
    // Reconcile explicit deletions before reads; retries are safe and scoped.
    for(const key of Object.keys(pendingDeletes())){const [school,id]=JSON.parse(key);if(school!==a.p_school)continue;if(!sameContext(a))throw new Error('workspace changed');requireWrite(await cloudCall('studio_del',Object.assign({p_id:id},a)));clearDelete(key)}
    const current=await cloudCall('studio_list',a);if(!current||current.school!==a.p_school||!sameContext(a))throw new Error('workspace changed');
    const remote=new Map(current.players.map(x=>[x.id,x]));
    for(const x of current.players){
      if(!sameContext(a))throw new Error('workspace changed');const loc=PLAYERS.find(p=>p.id===x.id);
      // Preserve local copies on a remote deletion; exclude them from upload.
      if(x.deleted)continue;
      if(!loc||tms(loc.updatedAt)<tms(x.at)){const g=await cloudCall('studio_get',Object.assign({p_id:x.id},a));const c=g&&cleanPlayer(g);if(!sameContext(a))throw new Error('workspace changed');if(!c)throw new Error('player read failed');
        const latest=PLAYERS.find(p=>p.id===c.id);if(latest&&tms(latest.updatedAt)>tms(c.updatedAt))continue;
        await DB.put(c);const i=PLAYERS.findIndex(p=>p.id===c.id);if(i>=0)PLAYERS[i]=c;else PLAYERS.push(c);changed=true;}
    }
    let failures=0;
    for(const p of [...PLAYERS]){
      const x=remote.get(p.id);if(x&&x.deleted)continue;
      try{if(!sameContext(a))throw new Error('workspace changed');
        if(!x||tms(p.updatedAt)>tms(x.at)){requireWrite(await cloudCall('studio_put',Object.assign({p_id:p.id,p_data:p,p_at:p.updatedAt},a)))}
        // Only publish a confirmed server revision; server validates the timestamp and consent.
        if(canExport(p,true))await publishConfirmed(p,a);
      }catch(e){failures++;pubErr=true;}
    }
    // Program settings belong to full-program editors only. Limited editors can read them.
    const setAt=settingsAt();if(current.settings_at&&tms(current.settings_at)>tms(setAt)){
      const g=await cloudCall('studio_settings_get',a);if(g&&g.data&&sameContext(a)){S=cleanSettings(Object.assign({},g.data,{lang:S.lang}));await DB.set('settings',S);localStorage.setItem('pss-set-at',g.at);loadSettingsForm();applyLang();changed=true}}
    else if(current.can_edit_settings===true&&(!current.settings_at||tms(setAt)>tms(current.settings_at)))await putSettings(a);
    const verified=await cloudCall('studio_list',a);if(!verified||verified.school!==a.p_school||!sameContext(a))throw new Error('verification failed');
    CLOUD.n=verified.players.filter(x=>!x.deleted).length;
    CLOUD.ok=failures===0;CLOUD.error=failures?msg('Some records were not synchronized; retry.','Algunos registros no se sincronizaron; vuelve a intentar.'):'';
  }catch(e){CLOUD.ok=false;CLOUD.error=msg('Sync incomplete; local records retained.','Sincronización incompleta; registros locales conservados.');pubErr=true;}
  finally{CLOUD.busy=false;pubBusy=false;CLOUD.last=Date.now();if(changed){procCache.clear();galleryDirty=true;if(VIEW==='players')renderGallery();refreshAll()}ccShow();if(CLOUD.again){CLOUD.again=false;cloudSync()}}
}
let syncBusy=false; // legacy status reference
window.addEventListener('online',requestCloudSync);
document.addEventListener('visibilitychange',()=>{if(!document.hidden&&Date.now()-CLOUD.last>30000)requestCloudSync()});
