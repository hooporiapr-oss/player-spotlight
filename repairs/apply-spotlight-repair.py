#!/usr/bin/env python3
"""Apply candidate to exact audited Studio blob; never edits input or contacts production."""
import pathlib, hashlib, sys
if len(sys.argv)!=3: raise SystemExit('Usage: python apply-spotlight-repair.py original/index.html repaired/index.html')
source=pathlib.Path(sys.argv[1]); out=pathlib.Path(sys.argv[2]); raw=source.read_bytes()
sha=hashlib.sha1(b'blob '+str(len(raw)).encode()+b'\0'+raw).hexdigest()
if sha!='058e3ffb8aff5ee05f573e72de3fc55e9d892b67': raise SystemExit('Wrong input revision: '+sha)
s=raw.decode('utf-8')
def replace(old,new):
 global s
 if s.count(old)!=1: raise SystemExit('Anchor mismatch: '+old[:100])
 s=s.replace(old,new,1)
a=s.index('const PUBQ=new Map();'); b=s.index('function cvStatus()',a)
s=s[:a]+pathlib.Path(__file__).with_name('spotlight-sync-repair.js').read_text()+ '\n'+s[b:]
replace("$('#cvSchool').onchange=e=>{try{localStorage.setItem('pss-cv-school',e.target.value)}catch(x){}queuePublish(PLAYERS);cloudSync()};", "$('#cvSchool').onchange=e=>{const old=boundProgram();if(old&&old!==e.target.value){e.target.value=old;toast(msg('Use a separate browser profile for another program.','Usa otro perfil del navegador para otro programa.'),true);return}try{localStorage.setItem('pss-cv-school',e.target.value)}catch(x){}ccShow()};")
# Existing boot and checkCoach invoke sync, but unbound workspace stays offline until deliberate Settings save.
replace("ccShow('ok');queuePublish(PLAYERS);cloudSync();toast(t('tSaved'))", "if(!claimWorkspace(cvProgram())){ccShow('ok');toast(msg('Local workspace not connected.','Estudio local no conectado.'),true);return}ccShow('ok');requestCloudSync();toast(t('tSaved'))")
replace("const on=CLOUD.ok===false?' · '+t('clNoSql'):CLOUD.busy||syncBusy?' · '+t('clSync'):CLOUD.ok?' · '+t('clOk',{n:PLAYERS.length}):'';", "const on=!cloudArgs()?' · '+msg('Local only — confirm program in Settings','Solo local — confirma el programa en Ajustes'):CLOUD.busy?' · '+t('clSync'):CLOUD.ok===false?' · '+CLOUD.error:CLOUD.ok?' · '+t('clOk',{n:CLOUD.n}):'';")
# Never trust legacy publication count as server state.
replace("el.textContent=pubBusy?t('cvSending'):pubErr?t('cvFail'):t(n===1?'cvIn1':'cvIn',{n,prog:prog||'—'})}", "el.textContent=!cloudArgs()?msg('Local only','Solo local'):pubBusy?t('cvSending'):pubErr?t('cvFail'):msg('Cards are verified during synchronization.','Las tarjetas se verifican durante la sincronización.')}")
a=s.index('function unpublish(ids)'); b=s.index('async function checkCoach',a)
s=s[:a]+"function unpublish(ids){/* deletion is handled by durable studio_del; no physical card deletion */}\n"+s[b:]
replace("toast(t('tRestored',{n:players.length})+(damaged?t('tRestoreSkip',{m:damaged}):''))});", "toast(t('tRestored',{n:players.length})+(damaged?t('tRestoreSkip',{m:damaged}):''));requestCloudSync()});")
# Prevent destructive restore/wipe of linked local workspace; use merge for imports.
replace("if(!how)return;\n  let next;", "if(!how)return;if(how==='replace'&&boundProgram()){toast(msg('Use Merge to protect the linked workspace.','Usa Combinar para proteger el estudio conectado.'),true);return}\n  let next;")
replace("$('#sWipe').onclick=async()=>{const ok=", "$('#sWipe').onclick=async()=>{if(boundProgram()){toast(msg('Linked workspace cannot be wiped.','No se puede borrar el estudio conectado.'),true);return}const ok=")
if source.resolve()==out.resolve(): raise SystemExit('Choose a different output path')
out.parent.mkdir(parents=True,exist_ok=True);out.write_text(s)
print('Candidate generated:',out)
