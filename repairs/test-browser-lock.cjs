const {chromium}=require('playwright');
const assert=require('node:assert/strict');
(async()=>{
 const browser=await chromium.launch({headless:true});
 try{
 for(const [label,owner,program,code,expectGate] of [
 ['unlinked workspace',null,null,null,false],
 ['linked without login','TEST_OWNER','Test Program',null,true],
 ['linked wrong coach','TEST_OWNER','Test Program','TEST_OTHER',true],
 ['linked valid coach','TEST_OWNER','Test Program','TEST_OWNER',false],
 ['legacy linked without owner',null,'Test Program',null,true]
 ]){
 const ctx=await browser.newContext();
 await ctx.addInitScript(({owner,program,code})=>{
 if(owner)localStorage.setItem('pss-workspace-coach-v1',owner);
 if(program)localStorage.setItem('pss-workspace-program-v1',program);
 if(code)localStorage.setItem('pss-coach',code);
 },{owner,program,code});
 await ctx.route('**/*',async route=>{
 const u=new URL(route.request().url());
 if(u.hostname==='127.0.0.1')return route.continue();
 if(u.pathname.endsWith('/hooporia_coach'))return route.fulfill({json:{school:'Test Program',schools:['Test Program']}});
 if(u.pathname.endsWith('/studio_list'))return route.fulfill({json:{school:'Test Program',players:[],can_edit_settings:false}});
 return route.abort();
 });
 const page=await ctx.newPage();
 await page.goto('http://127.0.0.1:8765/index.html');
 if(expectGate){
 await page.locator('#gate').waitFor({state:'visible'});
 assert.equal(await page.evaluate(()=>!!window.PSS),false,label+' must not initialize');
 assert.equal(await page.locator('main').isVisible(),false);
 if(owner){await page.locator('#gateCode').fill('TEST_OTHER');await page.locator('#gateOpen').click();assert.equal(await page.locator('main').isVisible(),false);assert.equal(await page.evaluate(()=>!!window.PSS),false);}
 }else{await page.waitForFunction(()=>!!window.PSS);assert.equal(await page.locator('main').isVisible(),true);}
 console.log('PASS',label);
 await ctx.close();
 }
 }finally{await browser.close();}
})().catch(e=>{console.error(e);process.exitCode=1});
