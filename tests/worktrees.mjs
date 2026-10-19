// Real Lua and Git with a controlled hub. This tests plugin recovery, not SQLite durability.
import {connectControl} from '../../LazyRex/lib/rex-client.mjs';
import {labSocket, until} from '../../LazyRex/lab/lab.mjs';
import {spawn, execFileSync} from 'node:child_process';
import {mkdtemp, mkdir, writeFile, readFile, realpath, rm, symlink, chmod} from 'node:fs/promises';
import {once} from 'node:events';
import {fileURLToPath} from 'node:url';
import assert from 'node:assert/strict';

const socket=await labSocket();
const dir=await realpath(await mkdtemp('/tmp/lazyrex-worktrees-test-'));
const root=dir+'/trees', repo=dir+'/source/repo with spaces';
await mkdir(repo,{recursive:true});
const git=(...args)=>execFileSync('git',args,{encoding:'utf8',env:{...process.env,GIT_CONFIG_GLOBAL:'/dev/null',GIT_CONFIG_SYSTEM:'/dev/null'}}).trim();
git('init','-q',repo);
await writeFile(repo+'/tracked.txt','initial\n');
await writeFile(repo+'/.gitignore','ignored.tmp\n');
git('-C',repo,'add','.');
git('-C',repo,'-c','user.name=Lab','-c','user.email=lab@example.invalid','commit','-qm','initial');
const control=await connectControl(socket), hub=await connectControl(socket);
const session=(await control.call('session.create',{label:'worktrees-test'})).session_id;
await control.call('session.attach',{session_id:session,event_scope:'session'});
const records=new Map(), operations=new Map(), locks=new Map();
let rev=0, workers=[], child, pluginId, crashAt='', declaredTabs, failures=[];
const spawns=new Map();
let adviceChecks=0;
let loseSpawnReply=false, spawnState='open';
let timerArms=0,timerFires=0,invalidations=0,failInvalidations=0,foreign;
const source=await readFile(new URL('../../Worktrees/worktrees.lua',import.meta.url),'utf8');
await writeFile(dir+'/instrumented.lua',`local original_after = rex.after
rex.after = function(seconds, callback)
  print('LAB timer arm')
  return original_after(seconds, function(ctx)
    print('LAB timer fire')
    return callback(ctx)
  end)
end
rex.every = function() error('A worktree plugin must not install a repeating timer') end
`+source);
const copy=v=>structuredClone(v);
const under=(cwd,path)=>cwd===path || cwd.startsWith(path+'/');
function batch(args) {
  const old=args.op && operations.get(args.op.key);
  if(old) return old.fingerprint===args.op.fingerprint ? {op_exists:copy(old)} : {conflict:{kind:'operation'}};
  const ops=Array.isArray(args.ops)?args.ops:[];
  for(const op of ops) if(op.if_rev!== (records.get(op.key)?.rev??'0')) return {conflict:{kind:'revision',key:op.key}};
  const revs={};
  for(const op of ops) { revs[op.key]=String(++rev); records.set(op.key,{rev:revs[op.key],value:copy(op.value)}); }
  if(args.op) operations.set(args.op.key,copy(args.op));
  return {revs};
}
async function startPlugin(){
  pluginId=undefined;
  child=spawn(process.env.REX_BIN||'rex',['-S',`unix://${socket}`,'--autostart=false','do',dir+'/instrumented.lua','--all',`plugin_session=${session}`,`hub_client_id=${hubId}`,'instance_id=worktrees-test',`worktrees_root=${root}`],
    {env:{...process.env,REX_SERVER:`unix://${socket}`,REX_SESSION:'',REX_BLOCK:'',REX_CLIENT:''}});
  let output='';
  child.stdout.on('data',data=>{output+=data;let index;while((index=output.indexOf('\n'))>=0){const line=output.slice(0,index);output=output.slice(index+1);if(line==='LAB timer arm')timerArms++;else if(line==='LAB timer fire')timerFires++;else console.log(line);}});
  child.stderr.pipe(process.stderr);
  await until(async()=>{
    if(child.exitCode!==null || child.signalCode!==null) throw new Error('Plugin exited before registration');
    return (await control.call('client.list')).clients.some(c=>c.client_id===pluginId && c.info?.label==='lazyrex-plugin:worktrees');
  },'worktrees registration');
}
async function stopPlugin(){
  if(child && child.exitCode===null && child.signalCode===null){ const done=once(child,'exit'); child.kill('SIGTERM'); await done; }
}
const label=`worktrees-hub-test-${process.pid}`;
await hub.call('client.keymap',{actions:['register','identify','store.get','store.op','store.batch','ui.tabs','ui.invalidate','workers','cwd.check','spawn','cwd.lock','cwd.unlock'].map(n=>({name:`hub.${n}`,kind:'client',title:n}))});
await hub.call('client.set_label',{label});
const hubId=(await control.call('client.list')).clients.find(c=>c.info?.label===label).client_id;
hub.events.on('event',async frame=>{
  if(frame.payload?.type!=='client_perform_requested') return;
  const ev=frame.payload.payload;
  if(process.env.WORKTREE_TRACE)console.log('HUB',ev.action,JSON.stringify(ev.args));
  try{
    let result;
    if(ev.action==='hub.register'){
      assert.equal(ev.args.plugin,'worktrees');
      assert.deepEqual(ev.args.exports,['worktree.create','worktree.list','worktree.remove']);
      assert(ev.args.commands.some(c=>c.id==='worktrees'&&c.surface==='panel'&&c.landing&&c.route==='/panels/worktrees'));
      assert(ev.args.commands.some(c=>c.id==='new_worktree'&&c.route==='/forms/new-worktree'));
      assert(ev.args.commands.some(c=>c.id==='remove_worktree'&&c.route==='/forms/remove-worktree'));
      pluginId=ev.requester.client_id;result={namespace:'worktrees',generation:'1'};
    } else {
      assert.equal(ev.requester.client_id,pluginId);
      const a=ev.args;
      if(ev.action==='hub.identify'){assert.equal(a.pid,process.pid);result={found:true,agent:'alice'};}
      else if(ev.action==='hub.ui.tabs'){ declaredTabs=copy(a.tabs);result={}; }
      else if(ev.action==='hub.workers') result={workers};
      else if(ev.action==='hub.cwd.check'){
        adviceChecks++;
        const blocking=workers.filter(w=>!w.cwd||under(w.cwd,a.path));
        result={path:a.path,available:blocking.length===0,workers:blocking,panes:[]};
      }
      else if(ev.action==='hub.spawn'){
        const old=spawns.get(a.key);
        if(old) assert.deepEqual(a,old,'spawn retry preserves its request');
        else spawns.set(a.key,copy(a));
        if(loseSpawnReply){
          loseSpawnReply=false;
          await hub.call('client.reply',{call_id:ev.call_id,error:{code:'unavailable',message:'lost spawn reply'}});
          return;
        }
        result={status:spawnState,spawn_id:'lab-'+a.key,session_id:a.placement.session,error:spawnState==='failed'?'lab launch failure':undefined};
      }
      else if(ev.action==='hub.ui.invalidate'){invalidations++;if(failInvalidations){failInvalidations--;await hub.call('client.reply',{call_id:ev.call_id,error:{code:'unavailable',message:'Lab invalidation failure'}});return;}result={};}
      else if(ev.action==='hub.store.get') result={records:Object.fromEntries(a.keys.map(k=>[k,copy(records.get(k)??{rev:'0'})]))};
      else if(ev.action==='hub.store.op') result=operations.has(a.key)?{found:true,...copy(operations.get(a.key))}:{found:false};
      else if(ev.action==='hub.store.batch'){
        if(crashAt==='after-spawn' && a.ops?.some(o=>Object.values(o.value?.pending??{}).some(p=>p.phase==='sending'&&p.block))){crashAt='';child.kill('SIGKILL');return;}
        if(a.op && crashAt==='before-result'){ crashAt='';child.kill('SIGKILL');return; }
        result=batch(a);
        if(a.op && crashAt==='after-result'){ crashAt='';child.kill('SIGKILL');return; }
      } else if(ev.action==='hub.cwd.lock'){
        const blocking=workers.filter(w=>!w.cwd||under(w.cwd,a.path));
        if(blocking.length) result={locked:false,workers:blocking};
        else { const held=locks.get(a.path);assert(!held||held===a.key);locks.set(a.path,a.key);result={locked:true}; }
      } else if(ev.action==='hub.cwd.unlock'){
        const held=locks.get(a.path);assert(!held||held===a.key);locks.delete(a.path);result={locked:false};
      } else throw new Error('Unexpected '+ev.action);
    }
    await hub.call('client.reply',{call_id:ev.call_id,result});
  }catch(error){failures.push(error);console.error(error);await hub.call('client.reply',{call_id:ev.call_id,error:{code:'internal',message:error.message}}).catch(()=>{});}
});
const call=async(name,args={})=>(await control.call('client.perform',{client_id:pluginId,action:`worktree.${name}`,args,timeout_ms:30000})).result;
const onceCall=call;
const complete=async(name,args)=>{
  let result;
  await until(async()=>{ result=await onceCall(name,args);return result.status!=='running';},name+' completion',60000);
  return result;
};
const create=(key,branch,extra={})=>complete('create',{key,repo,branch,...extra});
const remove=args=>complete('remove',args);
const listReady=async(args,predicate)=>{
  let result;
  await until(async()=>{result=await call('list',args);return predicate(result.worktrees);},'worktree list',60000);
  return result;
};
try{
  console.log('Rex',JSON.stringify(await control.call('server.version')));
  await startPlugin();
  assert.equal(Array.isArray(declaredTabs) ? declaredTabs.length : Object.keys(declaredTabs).length,0,'worktrees declares no tab');
  const first=await create('first','feature/one');
  assert.deepEqual(first,{path:root+'/repo with spaces/feature/one',repo,branch:'feature/one',created:true});
  assert.deepEqual(await create('first','feature/one'),first);
  assert.equal((await create('existing','feature/one')).created,false);
  assert.equal((await create('existing-base','feature/one',{base:'missing-base'})).created,false);
  await assert.rejects(create('first','feature/two'),/different content/);
  await assert.rejects(create('invalid','../escape'),/Invalid Git branch/);
  assert.equal(git('-C',first.path,'branch','--show-current'),'feature/one');
  let list=await listReady({},rows=>rows.some(t=>t.path===first.path&&t.state==='clean'));
  assert.equal(list.worktrees.find(t=>t.path===first.path).state,'clean');
  const viewCall=async(action,args={})=>(await hub.call('client.perform',{client_id:pluginId,action,args:{route:'/panels/worktrees',user:'user',...args},timeout_ms:10000})).result;
  const treeState=async()=>{const view=await viewCall('view.render');return view.tree.nodes.find(n=>n.id==='worktrees').items.find(t=>t.id===first.path)?.detail;};
  // A source repository need not be in the plugin catalog. Read its OSC 7 path, not focus or cwd.
  const sourceRepo=dir+'/source only # % repo';
  git('clone','--quiet',repo,sourceRepo);
  const sourceBlock=(await control.call('session.new_block',{session_id:session,flavor:'com.superlogical.terminal.shell',options:{
    command:[process.execPath,'-e',"process.stdout.write('\\x1b]7;'+require('node:url').pathToFileURL(process.argv[1]).href+'\\x07');setInterval(()=>{},1000)",sourceRepo],
    cwd:dir,login:false}})).block_id;
  const sourceContext={session_id:session,source_block_id:sourceBlock};
  await until(async()=> (await control.call('com.superlogical.terminal.pwd',{session_id:session,block_id:sourceBlock,args:{}})).pwd,'source OSC 7');
  const newForm=await viewCall('view.render',{route:'/forms/new-worktree',context:sourceContext});
  assert.equal(newForm.tree.nodes.find(n=>n.id==='new_worktree').fields.find(f=>f.id==='repo').value,sourceRepo);
  const noSource=await viewCall('view.render',{route:'/forms/new-worktree',context:{session_id:session}});
  assert.equal(noSource.tree.nodes.find(n=>n.id==='new_worktree').fields.find(f=>f.id==='repo').value,repo,'missing source falls back to recorded repos');
  const sourcePanel=()=>viewCall('view.render',{context:sourceContext});
  await until(async()=> (await sourcePanel()).tree.nodes.find(n=>n.id==='worktrees').items[0]?.detail.includes('clean'),'source-only scan completes');
  await until(()=>timerArms===timerFires,'source scan retires');
  const sourceIdle=timerArms;
  for(let i=0;i<3;i++){await sourcePanel();await new Promise(r=>setTimeout(r,100));}
  assert.equal(timerArms,sourceIdle,'source-only UI cache does not restart a scan on render');
  await control.call('block.close',{session_id:session,block_id:sourceBlock});
  const plainBlock=(await control.call('session.new_block',{session_id:session,flavor:'com.superlogical.terminal.shell',options:{
    command:['/bin/sleep','120'],cwd:sourceRepo,login:false}})).block_id;
  const plainForm=await viewCall('view.render',{route:'/forms/new-worktree',context:{session_id:session,source_block_id:plainBlock}});
  assert.equal(plainForm.tree.nodes.find(n=>n.id==='new_worktree').fields.find(f=>f.id==='repo').value,sourceRepo,'process cwd supplies the default when OSC 7 is absent');
  await control.call('block.close',{session_id:session,block_id:plainBlock});

  // Forms use the same guarded mutations and durable keys as agent operations.
  const formArgs={route:'/forms/new-worktree',node_id:'new_worktree',action:'submit',operation_key:'form-create',
    context:{session_id:session},input:{values:{repo,branch:'forms/roundtrip',base:''}}};
  let formCreated;
  await until(async()=>{formCreated=await viewCall('view.action',formArgs);return formCreated.status!=='running';},'form create');
  assert.equal(formCreated.close_form,true);
  assert.equal(formCreated.created,true);
  assert.equal(spawns.size,1);
  assert.equal([...spawns.values()][0].cwd,formCreated.path);
  assert.equal([...spawns.values()][0].profile,'shell');
  assert.deepEqual(await viewCall('view.action',formArgs),formCreated);
  assert.equal(spawns.size,1,'form retry reuses the shell spawn');
  await assert.rejects(viewCall('view.action',{...formArgs,input:{values:{repo,branch:'forms/changed'}}}),/different content/);
  await assert.rejects(viewCall('view.action',{...formArgs,user:'alice'}),/Only the user/);
  const lostArgs={...formArgs,operation_key:'form-lost-spawn'};
  loseSpawnReply=true;
  await assert.rejects(viewCall('view.action',lostArgs),error=>error.rex?.code==='unavailable'&&error.message.includes('lost spawn reply'),'an uncertain spawn must not become a terminal open_failed');
  const spawnCount=spawns.size;
  assert.equal((await viewCall('view.action',lostArgs)).close_form,true);
  assert.equal(spawns.size,spawnCount,'a lost spawn reply retries the original key');
  const menuOpen={route:'/forms/worktree?path='+encodeURIComponent(first.path),node_id:'worktree_menu',action:'run',operation_key:'menu-pending',context:{session_id:session},input:{item_id:'open_tab'}};
  spawnState='pending';
  assert.equal((await viewCall('view.action',menuOpen)).status,'running','menu Open waits for pending spawn');
  spawnState='open';
  assert.equal((await viewCall('view.action',menuOpen)).close_form,true);
  spawnState='failed';
  await assert.rejects(viewCall('view.action',{...menuOpen,operation_key:'menu-failed'}),/lab launch failure/);
  spawnState='open';
  git('-C',formCreated.path,'-c','user.name=Lab','-c','user.email=lab@example.invalid','commit','--allow-empty','-qm','source worktree commit');
  const sourceHead=git('-C',formCreated.path,'rev-parse','HEAD');
  assert.notEqual(sourceHead,git('-C',repo,'rev-parse','HEAD'));
  const linked=await create('from-linked','forms/from-linked',{repo:formCreated.path});
  assert.equal(git('-C',linked.path,'rev-parse','HEAD'),sourceHead,'default HEAD follows the selected source worktree');
  await remove({key:'remove-linked',path:linked.path});

  const removeRoute='/forms/remove-worktree?path='+encodeURIComponent(formCreated.path);
  const advice=async()=>{
    const view=await viewCall('view.render',{route:removeRoute,context:{session_id:session}});
    const field=view.tree.nodes.find(n=>n.id==='remove_worktree')?.fields.find(f=>f.id==='path');
    assert.equal(field?.value,formCreated.path,'route decodes the exact selected path');
    return view.tree.nodes.find(n=>n.id==='check')?.text||'';
  };
  await writeFile(formCreated.path+'/ignored.tmp','preserve this file');
  assert.match(await advice(),/Checking/,'first render starts an advisory scan');
  await until(async()=>/ignored files/.test(await advice()),'ignored-file removal advice');
  assert.equal(locks.size,0,'advice does not reserve the path');
  assert.equal(adviceChecks,1,'completed advice is cached');
  await rm(formCreated.path+'/ignored.tmp');
  workers=[{spawn_id:'advice-worker',cwd:formCreated.path,state:'running'}];
  await viewCall('hub.changed',{what:'workers'});
  await until(async()=>/advice-worker/.test(await advice()),'worker removal advice');
  assert.equal(locks.size,0);
  workers=[];
  await viewCall('hub.changed',{what:'workers'});
  await until(async()=> (await advice())==='','clean removal advice');
  const formRemove={route:removeRoute,node_id:'remove_worktree',action:'submit',operation_key:'form-remove',input:{values:{path:formCreated.path}}};
  let formRemoved;
  await until(async()=>{formRemoved=await viewCall('view.action',formRemove);return formRemoved.status!=='running';},'form removal');
  assert.equal(formRemoved.removed,true);
  assert.equal(formRemoved.close_form,true);
  assert.deepEqual(await viewCall('view.action',formRemove),formRemoved);
  console.log('PASS: source pwd/process defaults, source-only cache, form retry, shell spawn replay, asynchronous removal advice');
  await until(async()=>timerArms===timerFires&&(await treeState()).includes('clean'),'scans finish without a list poll');
  const idleArms=timerArms,idleInvalidations=invalidations;
  await new Promise(r=>setTimeout(r,500));
  assert.equal(timerArms,idleArms,'an idle plugin arms no scan timer');
  await viewCall('view.seen',{reason:'content'});
  await viewCall('view.render');
  await new Promise(r=>setTimeout(r,500));
  assert.equal(timerArms,idleArms,'snapshot acknowledgement does not restart scans');
  assert.equal(invalidations,idleInvalidations,'render and acknowledgement do not form a refresh loop');

  failInvalidations=2;
  await writeFile(first.path+'/focus-change','keep');
  await viewCall('view.seen',{reason:'focus'});
  await until(async()=>(await treeState()).includes('dirty'),'focus refreshes the view');
  await rm(first.path+'/focus-change');
  workers=[{spawn_id:'event-worker',title:'Event worker',state:'running',cwd:first.path}];
  await viewCall('hub.changed',{what:'workers'});
  await until(async()=>(await treeState()).includes('clean'),'worker changes refresh the view');

  await until(()=>timerArms===timerFires,'failed invalidations do not strand a scan');
  assert.equal(failInvalidations,0,'both notification failures were exercised');
  const unchangedArms=timerArms;
  workers[0].status={state:'working'};
  await viewCall('hub.changed',{what:'workers'});
  assert.equal(timerArms,unchangedArms,'worker program status does not start Git scans');

  // An OSC 7 directory event in another session refreshes the cached view.
  await writeFile(first.path+'/event-change','keep');
  foreign=(await control.call('session.create',{label:'worktree-event-pane'})).session_id;
  await control.call('session.attach',{session_id:foreign,event_scope:'session'});
  const pane=(await control.call('session.new_block',{session_id:foreign,flavor:'com.superlogical.terminal.shell',options:{command:[process.execPath,'-e',"process.stdout.write('\\x1b]7;file://localhost'+encodeURI(process.argv[1])+'\\x07');setInterval(()=>{},1000)",first.path],cwd:first.path,login:false,exit:{on_completion:false}}})).block_id;
  await until(async()=>(await treeState()).includes('dirty'),'foreign directory event refreshes the view');
  await rm(first.path+'/event-change');
  execFileSync(process.env.REX_BIN||'rex',['-S',`unix://${socket}`,'--autostart=false','send-key','-s',foreign,'-b',pane,'ctrl+c']);
  await until(async()=>(await treeState()).includes('clean'),'foreign child exit refreshes the view');
  await control.call('session.destroy',{session_id:foreign});
  await until(()=>timerArms===timerFires,'event scans retire their last timer');
  assert(invalidations>idleInvalidations,'scan changes invalidate the hub view');
  workers=[{spawn_id:'pending',title:'Pending worker',state:'starting',cwd:first.path+'/subdir'}];
  list=await listReady({repo},rows=>rows.some(t=>t.path===first.path&&t.workers.length));
  assert.equal(list.worktrees.find(t=>t.path===first.path).workers[0].spawn_id,'pending');
  await assert.rejects(remove({key:'busy',path:first.path}),/worker or terminal pane uses/);
  assert.equal(locks.size,0);
  workers=[];
  await writeFile(first.path+'/local.txt','keep me');
  await assert.rejects(remove({key:'dirty',path:first.path}),/changes or ignored/);
  assert.equal(await readFile(first.path+'/local.txt','utf8'),'keep me');
  await rm(first.path+'/local.txt');
  await writeFile(first.path+'/ignored.tmp','keep ignored');
  await assert.rejects(remove({key:'ignored',path:first.path}),/changes or ignored/);
  assert.equal(locks.size,0);
  await rm(first.path+'/ignored.tmp');
  const removed=await remove({key:'remove',path:first.path});
  assert.equal(removed.removed,true);
  assert.deepEqual(await remove({key:'remove',path:first.path}),removed);
  assert.equal(locks.size,0);
  assert(git('-C',repo,'show-ref','refs/heads/feature/one'));
  await assert.rejects(remove({key:'main',path:repo}),/managed root/);
  await mkdir(root+'/repo with spaces',{recursive:true});
  await symlink(dir,root+'/repo with spaces/escape');
  await assert.rejects(create('symlink-parent','escape/child'),/symbolic link/);
  const discard=id=>hub.call('client.perform',{client_id:pluginId,action:'view.action',args:{route:'/panels/worktrees',user:'user',node_id:'pending/'+id,action:'discard'},timeout_ms:10000});
  await assert.rejects(hub.call('client.perform',{client_id:pluginId,action:'view.action',args:{route:'/panels/worktrees',user:'alice',node_id:'pending/5:alice14:symlink-parent',action:'discard'}}),/Only the user/);
  assert.equal((await discard('5:alice14:symlink-parent')).result.discarded,true);
  assert.equal((await create('symlink-parent','escape/child')).status,'discarded');
  await assert.rejects(remove({key:'relative',path:'-bad'}),/must be absolute/);
  // An absent block after an unknown spawn is not proof that no block can arrive.
  const savedCatalog=records.get('catalog');
  const unknownId='5:alice7:unknown';
  savedCatalog.value.pending[unknownId]={kind:'create',phase:'sending',session,path:root+'/unknown',repo,common:repo+'/.git',label:'never-sent',fingerprint:'synthetic'};
  await assert.rejects(discard(unknownId),/late Rex reply/);
  const gone=(await control.call('session.create',{label:'worktree-lost-session'})).session_id;
  await control.call('session.attach',{session_id:gone,event_scope:'session'});
  await control.call('session.destroy',{session_id:gone});
  savedCatalog.value.pending[unknownId].session=gone;
  assert.equal((await discard(unknownId)).result.discarded,true);

  // Rex keeps a slow Git process alive when the plugin crashes before it records the block ID.
  const gate=dir+'/release-hook';
  await writeFile(repo+'/.git/hooks/post-checkout',`#!/bin/sh\nwhile [ ! -f '${gate}' ]; do sleep 0.1; done\n`);
  await chmod(repo+'/.git/hooks/post-checkout',0o755);
  crashAt='after-spawn';
  const lost=create('slow-create','recovery/slow');lost.catch(()=>{});
  await until(()=>child.exitCode!==null||child.signalCode!==null,'crash after spawn');
  const operationBlocks=(await control.call('session.list_blocks',{session_id:session})).blocks.filter(b=>b.label===records.get('catalog').value.pending['5:alice11:slow-create'].label);
  assert.equal(operationBlocks.length,1);
  await startPlugin();
  const start=Date.now();
  assert.equal((await call('create',{key:'slow-create',repo,branch:'recovery/slow'})).status,'running');
  const waitingView=(await hub.call('client.perform',{client_id:pluginId,action:'view.render',args:{route:'/panels/worktrees',user:'user'},timeout_ms:1000})).result;
  assert.equal(waitingView.tree.title,'Worktrees');
  assert(Date.now()-start<2000,'a slow Git hook does not block tools or rendering');
  await writeFile(gate,'go');
  const slow=await create('slow-create','recovery/slow');
  assert.equal(slow.created,true);
  assert.equal(git('-C',repo,'worktree','list','--porcelain').split('branch refs/heads/recovery/slow').length-1,1);
  await remove({key:'slow-remove',path:slow.path});
  await rm(repo+'/.git/hooks/post-checkout');
  await assert.rejects(lost);

  // Kill the plugin after Git creates the tree, before the result is committed.
  crashAt='before-result';
  await assert.rejects(create('recover-create','recovery/create'));
  await until(()=>child.exitCode!==null||child.signalCode!==null,'plugin crash');
  const missingBlock=records.get('catalog').value.pending['5:alice14:recover-create'].block;
  await control.call('block.close',{session_id:session,block_id:missingBlock});
  await startPlugin();
  const recovered=await create('recover-create','recovery/create');
  assert.equal(recovered.created,true);
  assert.equal(git('-C',repo,'worktree','list','--porcelain').split('branch refs/heads/recovery/create').length-1,1);

  // Kill after Git removes the tree, before the result is committed. Keep the lock.
  crashAt='before-result';
  await assert.rejects(remove({key:'recover-remove',path:recovered.path}));
  await until(()=>child.exitCode!==null||child.signalCode!==null,'remove crash');
  assert.equal(locks.size,1);
  const removedBlock=records.get('catalog').value.pending['5:alice14:recover-remove'].block;
  await control.call('block.close',{session_id:session,block_id:removedBlock});
  await startPlugin();
  assert.equal((await remove({key:'recover-remove',path:recovered.path})).removed,true);
  assert.equal(locks.size,0);

  const last=await create('unlock-create','recovery/unlock');
  crashAt='after-result';
  await assert.rejects(remove({key:'recover-unlock',path:last.path}));
  await until(()=>child.exitCode!==null||child.signalCode!==null,'unlock crash');
  assert.equal(locks.size,1);
  await startPlugin();
  assert.equal(locks.size,0,'startup finishes a recorded unlock');
  assert.equal((await remove({key:'recover-unlock',path:last.path})).removed,true);
  const view=(await hub.call('client.perform',{client_id:pluginId,action:'view.render',args:{route:'/panels/worktrees',user:'user'},timeout_ms:30000})).result;
  assert.equal(view.tree.title,'Worktrees');
  assert(view.tree.nodes.find(n=>n.id==='worktrees').items.some(i=>i.detail.includes(repo)));
  const forwardedArgs={action:'worktree.list',args:{repo},requester_pid:process.pid};
  await assert.rejects(control.call('client.perform',{client_id:pluginId,action:'hub.forward',args:forwardedArgs}),/Only the hub/);
  const forwarded=(await hub.call('client.perform',{client_id:pluginId,action:'hub.forward',args:forwardedArgs,timeout_ms:30000})).result;
  assert(forwarded && typeof forwarded==='object');
  await assert.rejects(hub.call('client.perform',{client_id:pluginId,action:'hub.forward',args:{...forwardedArgs,action:'view.render'}}),/not exported/);
  assert.equal(failures.length,0);
  console.log('PASS: event refresh across sessions, no idle timers or view loop, real Git operations, guards, and four crash boundaries');
}finally{
  await stopPlugin();
  if(foreign) await control.call('session.destroy',{session_id:foreign}).catch(()=>{});
  await control.call('session.destroy',{session_id:session});
  control.close();hub.close();
  // All repositories and trees in this fixture are owned by this test.
  await rm(dir,{recursive:true,force:true});
}
