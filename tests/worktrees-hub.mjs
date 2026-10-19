// Run with HUB_BIN, VIEW_BIN, and an explicit isolated REX_SERVER. Evidence stays in the printed temporary directory.
import {connectControl} from '../../LazyRex/lib/rex-client.mjs';
import {labSocket} from '../../LazyRex/lab/lab.mjs';
import {fileURLToPath} from 'node:url';
import {spawn,execFileSync} from 'node:child_process';
import {mkdtemp,realpath,mkdir,writeFile,readFile,rm,access} from 'node:fs/promises';
import {once} from 'node:events';
import assert from 'node:assert/strict';
const socket=await labSocket();
const hubBinary=process.env.HUB_BIN, viewBinary=process.env.VIEW_BIN;
assert(hubBinary&&viewBinary,'Set HUB_BIN and VIEW_BIN to matching lab binaries');
const clientModule=fileURLToPath(new URL('../../LazyRex/lib/rex-client.mjs',import.meta.url));
const delay=ms=>new Promise(r=>setTimeout(r,ms));
const until=async(fn,label,ms=30000)=>{const start=Date.now();for(;;){const value=await fn();if(value)return value;if(Date.now()-start>ms)throw Error('Timeout: '+label);await delay(100);}};
const dir=await realpath(await mkdtemp('/tmp/lazyrex-worktrees-integrated-'));
const repo=dir+'/repo',root=dir+'/trees';
await mkdir(repo);await mkdir(root);
const git=(...args)=>execFileSync('git',args,{encoding:'utf8'}).trim();
if(process.env.GIT_SOURCE){git('clone','--shared','--no-checkout',process.env.GIT_SOURCE,repo);}else{git('init','-q',repo);await writeFile(repo+'/tracked','one\n');git('-C',repo,'add','.');git('-C',repo,'-c','user.name=Lab','-c','user.email=lab@example.invalid','commit','-qm','initial');}
const plugin=await readFile(new URL('../../Worktrees/worktrees.lua',import.meta.url),'utf8');
await writeFile(dir+'/worktrees.lua',`rex.args.worktrees_root = ${JSON.stringify(root)}\n`+plugin);
await writeFile(dir+'/profiles.json',JSON.stringify({profiles:[{id:'sleep',name:'Sleep',kind:'accessory',command:['/bin/sleep','600']}]}));
await writeFile(dir+'/hub.json',JSON.stringify({server:'unix://'+socket,state:dir+'/state',view:viewBinary,home:'worktrees',profiles:dir+'/profiles.json',agents:[{id:'lab',name:'Lab'}],plugins:[{name:'worktrees',path:dir+'/worktrees.lua',events:'all'}]}));
const client=await connectControl(socket);
const initialSessions=new Set((await client.call('session.list')).sessions.map(s=>s.session_id));
assert(!(await client.call('client.list')).clients.some(c=>c.info?.label==='lazyrex-hub'&&c.connection_state==='connected'),'Use a lab without another running hub');
let child;const logs=[];
async function start(){child=spawn(hubBinary,['-config',dir+'/hub.json'],{env:{...process.env,REX_SERVER:'unix://'+socket,REX_SESSION:'',REX_BLOCK:''}});child.stdout.on('data',b=>logs.push(b.toString()));child.stderr.on('data',b=>logs.push(b.toString()));await until(async()=>{if(child.exitCode!==null)throw Error(logs.join(''));return(await client.call('client.list')).clients.find(c=>c.info?.label==='lazyrex-hub'&&c.connection_state==='connected');},'hub');}
async function stop(){if(child&&child.exitCode===null&&child.signalCode===null){const done=once(child,'exit');child.kill('SIGTERM');await done;}}
const driver=`
import {connectControl} from ${JSON.stringify(clientModule)};
import {writeFile,readFile,rm,access} from 'node:fs/promises';
import assert from 'node:assert/strict';
const dir=${JSON.stringify(dir)},repo=${JSON.stringify(repo)},socket=${JSON.stringify(socket)};
const delay=ms=>new Promise(r=>setTimeout(r,ms));
const until=async(fn,label,ms=60000)=>{const t=Date.now();for(;;){const v=await fn();if(v)return v;if(Date.now()-t>ms)throw Error('Timeout '+label);await delay(100);}};
const c=await connectControl(socket);let hubId,pluginId;
const perform=async(id,action,args={})=>(await c.call('client.perform',{client_id:id,action,args,timeout_ms:10000})).result;
async function connect(){await until(async()=>{const list=(await c.call('client.list')).clients;hubId=list.filter(x=>x.info?.label==='lazyrex-hub'&&x.connection_state==='connected').at(-1)?.client_id;pluginId=list.filter(x=>x.info?.label==='lazyrex-plugin:worktrees'&&x.connection_state==='connected').at(-1)?.client_id;if(!hubId)return false;try{pluginId=(await perform(hubId,'hub.tools')).tools.find(t=>t.action==='worktree.create')?.client_id;if(!pluginId)return false;await perform(hubId,'hub.join',{agent:'lab'});await perform(pluginId,'worktree.list',{});return true;}catch{return false;}},'clients');}
const tool=async(action,args)=>{let result;await until(async()=>{result=await perform(pluginId,'worktree.'+action,args);return result.status!=='running';},action);return result;};
const hub=(action,args={})=>perform(hubId,'hub.'+action,args);
try{
await connect();
const args={key:'integrated-create',repo,branch:'feature/integration'};
const started=Date.now();const first=await tool('create',args);const createMs=Date.now()-started;assert.equal(first.created,true);assert.deepEqual(await tool('create',args),first);
const spawned=await hub('spawn',{profile:'sleep',key:'worker',cwd:first.path});
const worker=await until(async()=>{const w=(await hub('workers')).workers.find(x=>x.spawn_id===spawned.spawn_id);return w?.block_id&&w;},'worker');
assert.equal(worker.cwd,first.path);
await assert.rejects(tool('remove',{key:'busy',path:first.path}),/worker or terminal pane/);
await hub('stop',{spawn_id:worker.spawn_id,key:'stop'});
await until(async()=>!(await hub('workers')).workers.some(x=>x.spawn_id===worker.spawn_id&&x.state!=='closed'),'worker closed');
await writeFile(first.path+'/local','keep');await assert.rejects(tool('remove',{key:'dirty',path:first.path}),/changes or ignored/);assert.equal(await readFile(first.path+'/local','utf8'),'keep');await rm(first.path+'/local');
await writeFile(dir+'/restart','ready');await until(async()=>{try{await access(dir+'/resumed');return true;}catch{return false;}},'restart');
await connect();assert.deepEqual(await tool('create',args),first);
const removed=await tool('remove',{key:'clean-remove',path:first.path});assert.equal(removed.removed,true);assert.deepEqual(await tool('remove',{key:'clean-remove',path:first.path}),removed);
await assert.rejects(access(first.path));
await writeFile(dir+'/result.json',JSON.stringify({ok:true,createMs,first,worker,removed}));
}catch(e){await writeFile(dir+'/result.json',JSON.stringify({ok:false,error:e.stack}));}finally{c.close();}
`;
await writeFile(dir+'/driver.mjs',driver);
let session;
try{
await start();
session=(await client.call('session.create',{label:'worktrees-integrated-agent'})).session_id;
await client.call('session.attach',{session_id:session,event_scope:'session'});
await client.call('session.new_window',{session_id:session,layout:{block:{flavor:'com.superlogical.terminal.shell',options:{command:[process.execPath,dir+'/driver.mjs'],cwd:dir,login:false,exit:{on_completion:false}}}}});
await until(async()=>{try{const result=JSON.parse(await readFile(dir+'/result.json','utf8'));throw Error(result.error||'Driver ended early');}catch(e){if(e.code!=='ENOENT')throw e;}try{await access(dir+'/restart');return true;}catch{return false;}},'restart requested',90000);
console.log('PASS before restart: real hub create/retry, spawn cwd, worker refusal, dirty refusal');
await stop();await start();await writeFile(dir+'/resumed','ready');
const result=await until(async()=>{try{return JSON.parse(await readFile(dir+'/result.json','utf8'));}catch(e){if(e.code==='ENOENT')return false;throw e;}},'driver result',90000);
assert.equal(result.ok,true,result.error);console.log('PASS after restart: durable result retry, clean removal, removal retry');console.log(JSON.stringify(result));
}finally{
await stop();await writeFile(dir+'/hub.log',logs.join(''));
if(session)await client.call('session.destroy',{session_id:session}).catch(()=>{});
for(const s of (await client.call('session.list')).sessions){if(!initialSessions.has(s.session_id)&&s.label==='LazyRex'){await client.call('session.attach',{session_id:s.session_id,event_scope:'session'});await client.call('session.destroy',{session_id:s.session_id});}}
client.close();console.log('Evidence: '+dir);
}
