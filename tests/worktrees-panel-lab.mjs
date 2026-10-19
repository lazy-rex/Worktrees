// Lab: the Worktrees panel and forms end to end (plugins/worktrees.lua), with the real hub, the real
// renderer and real Git. Lab only. Start the lab server with the palette config first:
//   echo 'pcall(require, "lazyrex_palette")' > $LAB/init.lua
//   LAB_CONFIG=$LAB/init.lua spikes/lab/server.sh $LAB
// Then: HUB_BIN=<hub> VIEW_BIN=<renderer> WT_LAB=$LAB node worktrees-panel-lab.mjs
// The test starts its own hub (no other hub may run in the lab) and stops it at the end.
// A: the palette has Worktrees…, New Worktree… and Remove Worktree….
// B: Worktrees… opens the panel in the side pane; the source pane's repository comes first.
// C: New Worktree… run while the panel has focus replaces the panel, keeps the source pane's
//    repository as the default; the submit creates the tree, opens a shell tab there
//    (the maintainer, 2026-10-17) and makes it the active tab (server focus, placement.focus), and the
//    panel comes back with the new tree.
// D: a panel row opens the tree menu; Open in new tab opens a second shell at the tree; Open in
//    new session opens a session named after the branch with a shell at the tree.
// E: Start agent… lists the profiles; a profile form starts it with cwd = the tree.
// F: Remove… shows the refusal advice while shells run in the tree; Esc goes back to the panel.
// G: after the shells close, Remove Worktree… (picker, then confirm) removes the tree and keeps
//    the branch.
import {connectControl} from '../../LazyRex/lib/rex-client.mjs';
import {labSocket} from '../../LazyRex/lab/lab.mjs';
import {execFileSync, spawn} from 'node:child_process';
import fs from 'node:fs';
import assert from 'node:assert/strict';
const LAB = process.env.WT_LAB || '/tmp/rexlab-worktrees-claude', SOCK = `unix://${LAB}/rex.sock`;
const HUB = process.env.HUB_BIN, VIEW = process.env.VIEW_BIN;
assert(HUB && VIEW, 'Set HUB_BIN and VIEW_BIN');
assert(LAB.startsWith('/tmp/'), 'The lab must be under /tmp');
const PLUGIN = new URL('../../Worktrees/worktrees.lua', import.meta.url).pathname;
const sleep = ms => new Promise(r => setTimeout(r, ms));
const waitFor = async (what, f, ms = 20000) => { for (let t = 0; t < ms; t += 200) { const v = await f(); if (v) return v; await sleep(200); } assert.fail(`timed out: ${what}`); };
const rex = (...a) => execFileSync('env', ['-u', 'REX_SESSION', '-u', 'REX_BLOCK', 'rex', '-S', SOCK, '--autostart=false', ...a], {encoding: 'utf8'});
const git = (...a) => execFileSync('git', a, {encoding: 'utf8'}).trim();

// A fresh hub state, repository and worktree root for each run.
const dir = fs.mkdtempSync(`${LAB}/panel-lab-`);
const repo = `${fs.realpathSync(dir)}/repo`, root = `${fs.realpathSync(dir)}/trees`; // Git and the plugin report real paths
fs.mkdirSync(root);
git('init', '-q', '-b', 'main', repo);
fs.writeFileSync(`${repo}/tracked`, 'one\n');
git('-C', repo, 'add', '.');
git('-C', repo, '-c', 'user.name=Lab', '-c', 'user.email=lab@example.invalid', 'commit', '-qm', 'initial');
fs.writeFileSync(`${dir}/worktrees.lua`, `rex.args.worktrees_root = ${JSON.stringify(root)}\n` + fs.readFileSync(PLUGIN, 'utf8'));
fs.writeFileSync(`${dir}/profiles.json`, JSON.stringify({profiles: [{id: 'sleeper', name: 'Sleeper', kind: 'agent', command: ['/bin/sleep', '600']}]}));
fs.writeFileSync(`${dir}/hub.json`, JSON.stringify({server: SOCK, state: `${dir}/state`, view: VIEW, palette_lua: `${LAB}/lazyrex_palette.lua`,
  profiles: `${dir}/profiles.json`, agents: [{id: 'user', name: 'User', status_record: ''}],
  plugins: [{name: 'worktrees', path: `${dir}/worktrees.lua`, events: 'all'}]}));

const c = await connectControl(await labSocket(SOCK)); // refuses a socket outside a temporary directory
const client = async label => (await c.call('client.list')).clients.filter(x => x.info?.label === label && x.connection_state === 'connected').at(-1)?.client_id;
assert(!(await client('lazyrex-hub')), 'Stop the other hub in this lab first');
const before = new Set((await c.call('session.list')).sessions.map(x => x.session_id));
const oldPlugins = new Set((await c.call('client.list')).clients.filter(x => x.info?.label === 'lazyrex-plugin:worktrees').map(x => x.client_id));
const hubProcess = spawn(HUB, ['-config', `${dir}/hub.json`], {cwd: '/tmp', stdio: ['ignore', fs.openSync(`${dir}/hub.log`, 'a'), fs.openSync(`${dir}/hub.log`, 'a')],
  env: {...process.env, REX_SERVER: SOCK, REX_SESSION: '', REX_BLOCK: ''}});
const sql = q => execFileSync('sqlite3', ['-readonly', `${dir}/state/hub.db`, q], {encoding: 'utf8'}).trim();
const attach = s => c.call('session.attach', {session_id: s, event_scope: 'session'}).catch(() => {});
const sview = async s => { await attach(s); return c.call('session.view', {session_id: s}); };
const blocks = async (s, w) => (await sview(s)).windows.find(x => x.window_id === w).layers.flatMap(l => l.blocks);
const side = async (s, w) => {
  const forms = (await blocks(s, w)).filter(b => b.label.startsWith('lazyrex-form:'));
  assert(forms.length <= 1, `one side pane at most, got ${forms.map(f => f.label)}`);
  return forms[0] && {...forms[0], view: forms[0].label.slice('lazyrex-form:'.length)};
};
const route = id => sql(`SELECT route FROM views WHERE view_id = '${id}'`);
const sideRoute = async (s, w) => { const f = await side(s, w); return f ? route(f.view) : ''; };
const text = (s, b) => { try { return rex('capture', '-s', s, '-b', b); } catch { return ''; } };
const flat = (s, b) => text(s, b).replace(/\s+/g, ''); // the renderer wraps long text, also inside words
const shows = (s, b, t) => flat(s, b).includes(t.replace(/\s+/g, ''));
const press = (s, b, ...keys) => { for (const k of keys) { rex('send-key', '-s', s, '-b', b, k); execFileSync('sleep', ['0.25']); } };
// The renderer underlines a focused control, and marks the rows of a focused list item with a bar
// (observed in the lab; buttons are always bold).
const focused = (s, b) => {
  const under = [...rex('capture', '-s', s, '-b', b, '--format', 'html').matchAll(/text-decoration-line: underline;[^"]*">([^<]*)</g)].map(m => m[1]).join(' ').replace(/\s+/g, ' ').trim();
  if (under) return under;
  return (text(s, b).split('\n').find(l => l.includes('\u258f')) ?? '').replace('\u258f', '').trim();
};
const tabTo = async (s, b, label) => {
  for (let i = 0; i < 30; i++) { if (focused(s, b).includes(label)) return; press(s, b, 'tab'); await sleep(150); }
  const styles = [...rex('capture', '-s', s, '-b', b, '--format', 'html').matchAll(/style="([^"]*)">([^<]*)</g)].filter(m => /\w/.test(m[2])).map(m => `${m[1]} => ${m[2].trim()}`);
  assert.fail(`no control ${label}; focused: ${focused(s, b)}\n${[...new Set(styles)].join('\n')}`);
};
const palette = async (s, b, cmd) => { await attach(s); return c.call('client.action', {action: `lazyrex_worktrees_${cmd}`, origin: 'palette', session_id: s, block_id: b}); };
const process_ = async (s, b) => c.call('com.superlogical.terminal.process', {session_id: s, block_id: b, args: {}});
const spawnWindows = async (s, label) => (await sview(s)).windows.filter(w => w.label === label && w.layers.flatMap(l => l.blocks).some(b => b.label.startsWith('lazyrex-spawn:')));

let S;
try {
  // A plugin of a stopped hub can stay connected for a moment: wait for a new one.
  await waitFor('the worktrees plugin', async () => (await c.call('client.list')).clients.some(x =>
    x.info?.label === 'lazyrex-plugin:worktrees' && x.connection_state === 'connected' && !oldPlugins.has(x.client_id)) && fs.existsSync(`${dir}/state/hub.db`), 30000);
  // A
  await waitFor('palette actions', () => /lazyrex_worktrees_new_worktree/.test(rex('actions')));
  const actions = rex('actions');
  for (const t of ['Worktrees…', 'New Worktree…', 'Remove Worktree…']) assert(actions.includes(`LazyRex: ${t}`), `palette has ${t}`);
  assert(!sql(`SELECT count(*) FROM ui_tabs WHERE plugin = 'worktrees'`).match(/^[1-9]/), 'Worktrees declares no tab');
  console.log('A ok: palette commands, no tab');

  // B
  S = (await c.call('session.create', {label: 'wt-panel-lab', initial_windows: [{window_label: 'main',
    layout: {block: {flavor: 'com.superlogical.terminal.shell', label: 'src', options: {cwd: repo}}}}]})).session_id;
  const v = await sview(S), W = v.windows[0].window_id, src = v.windows[0].focused_block_id;
  await waitFor('the source shell', async () => (await process_(S, src)).foreground?.cwd);
  await palette(S, src, 'worktrees');
  const panel = await waitFor('the panel', async () => (await sideRoute(S, W)) === '/panels/worktrees' && side(S, W));
  await waitFor('the source repository', () => shows(S, panel.block_id, `Repository: ${repo}`));
  assert(shows(S, panel.block_id, 'main'), 'the panel lists the main tree');
  console.log('B ok: panel with the source repository');

  // C: the palette runs from the panel's pane; the form must still default to the source pane's repository.
  await palette(S, panel.block_id, 'new_worktree');
  const form = await waitFor('the new form', async () => (await sideRoute(S, W)) === '/forms/new-worktree' && side(S, W));
  await waitFor('the form text', () => shows(S, form.block_id, 'Create worktree'));
  assert(shows(S, form.block_id, repo), 'the repository defaults to the source repository');
  await sleep(2000); // the hub focuses a new form again for about 1.75 s (forms.go)
  press(S, form.block_id, 'tab'); // the form opens on Repository; Branch is next
  rex('send', '-s', S, '-b', form.block_id, 'feat-a');
  await waitFor('the typed branch', () => shows(S, form.block_id, 'feat-a'));
  await tabTo(S, form.block_id, 'Create worktree');
  press(S, form.block_id, 'enter');
  const tree = await waitFor('the worktree', () => fs.existsSync(`${root}/repo/feat-a/tracked`) && fs.realpathSync(`${root}/repo/feat-a`), 30000);
  const [shellWin] = await waitFor('the shell tab', async () => (await spawnWindows(S, 'feat-a')).length === 1 && spawnWindows(S, 'feat-a'), 30000);
  const shellBlock = shellWin.layers.flatMap(l => l.blocks).find(b => b.label.startsWith('lazyrex-spawn:')).block_id;
  await waitFor('the shell cwd', async () => (await process_(S, shellBlock)).foreground?.cwd === tree);
  await waitFor('the shell tab is active (placement.focus)', async () => (await sview(S)).active_window_id === shellWin.window_id);
  const back = await waitFor('the panel returns', async () => (await sideRoute(S, W)) === '/panels/worktrees' && side(S, W), 30000);
  await waitFor('the panel lists feat-a', () => shows(S, back.block_id, 'feat-a')); // a long detail line is cut
  console.log('C ok: created', tree, 'with a shell tab; the panel came back');


  // D: the user goes back to the source tab and its panel.
  await c.call('session.focus_block', {session_id: S, block_id: back.block_id});
  await tabTo(S, back.block_id, 'feat-a');
  press(S, back.block_id, 'enter');
  const menu = await waitFor('the tree menu', async () => (await sideRoute(S, W)).startsWith('/forms/worktree?path=') && side(S, W));
  assert.equal(decodeURIComponent(route(menu.view).slice('/forms/worktree?path='.length)), tree, 'the menu route carries the tree path');
  await waitFor('menu items', () => shows(S, menu.block_id, 'Open in new tab'));
  await tabTo(S, menu.block_id, 'Open in new tab');
  press(S, menu.block_id, 'enter');
  await waitFor('a second shell tab', async () => (await spawnWindows(S, 'feat-a')).length === 2, 30000);
  const second = (await spawnWindows(S, 'feat-a')).find(w => w.window_id !== shellWin.window_id);
  await waitFor('the second shell tab is active', async () => (await sview(S)).active_window_id === second.window_id);
  await c.call('session.focus_block', {session_id: S, block_id: (await side(S, W)).block_id}); // the user goes back to the source tab
  const back2 = await waitFor('the panel returns after Open', async () => (await sideRoute(S, W)) === '/panels/worktrees' && side(S, W));
  await tabTo(S, back2.block_id, 'feat-a');
  press(S, back2.block_id, 'enter');
  const menuS = await waitFor('the tree menu again', async () => (await sideRoute(S, W)).startsWith('/forms/worktree?path=') && side(S, W));
  await waitFor('menu items', () => shows(S, menuS.block_id, 'Open in new session'));
  await tabTo(S, menuS.block_id, 'Open in new session');
  press(S, menuS.block_id, 'enter');
  const other = await waitFor('a new session with a shell at the tree', async () => {
    for (const x of (await c.call('session.list')).sessions) {
      if (before.has(x.session_id) || x.session_id === S || x.label !== 'feat-a') continue;
      const wins = (await sview(x.session_id)).windows || [];
      for (const w of wins) for (const b of w.layers.flatMap(l => l.blocks)) {
        if (b.label.startsWith('lazyrex-spawn:') && (await process_(x.session_id, b.block_id)).foreground?.cwd === tree) return x.session_id;
      }
    }
  }, 30000);
  await waitFor('the panel returns after Open in new session', async () => (await sideRoute(S, W)) === '/panels/worktrees');
  assert.equal((await sview(S)).active_window_id, W, 'Open in new session moves no focus in the source session');
  console.log('D ok: Open in new tab; Open in new session', other);

  // E
  const back3 = await side(S, W);
  await tabTo(S, back3.block_id, 'main');
  press(S, back3.block_id, 'enter');
  const menu2 = await waitFor('the main tree menu', async () => (await sideRoute(S, W)).startsWith('/forms/worktree?path=') && side(S, W));
  await waitFor('menu items', () => shows(S, menu2.block_id, 'Start agent'));
  await tabTo(S, menu2.block_id, 'Start agent');
  press(S, menu2.block_id, 'enter');
  const profiles = await waitFor('the profile list', async () => (await sideRoute(S, W)).startsWith('/forms/worktree-agent?path=') && side(S, W));
  await waitFor('the profiles', () => shows(S, profiles.block_id, 'Sleeper'));
  await tabTo(S, profiles.block_id, 'Sleeper');
  press(S, profiles.block_id, 'enter');
  const agentForm = await waitFor('the profile form', async () => (await sideRoute(S, W)).startsWith('/forms/worktree-agent/sleeper?path=') && side(S, W));
  await waitFor('the Start button', () => shows(S, agentForm.block_id, 'Start'));
  await tabTo(S, agentForm.block_id, 'Start');
  press(S, agentForm.block_id, 'enter');
  await waitFor('the agent spawn', () => sql(`SELECT count(*) FROM spawns WHERE profile = 'sleeper' AND cwd = '${fs.realpathSync(repo)}' AND status = 'open'`) === '1', 30000);
  console.log('E ok: Start agent in the main tree');

  // F
  const p3 = await waitFor('the panel returns after Start', async () => (await sideRoute(S, W)) === '/panels/worktrees' && side(S, W));
  await tabTo(S, p3.block_id, 'feat-a');
  press(S, p3.block_id, 'enter');
  const menu3 = await waitFor('the tree menu', async () => (await sideRoute(S, W)).startsWith('/forms/worktree?path=') && side(S, W));
  await waitFor('menu items', () => shows(S, menu3.block_id, 'Remove…'));
  await tabTo(S, menu3.block_id, 'Remove…');
  press(S, menu3.block_id, 'enter');
  const confirm = await waitFor('the remove confirm', async () => (await sideRoute(S, W)).startsWith('/forms/remove-worktree?path=') && side(S, W));
  await waitFor('the refusal advice', () => shows(S, confirm.block_id, 'Removal will be refused'), 20000);
  press(S, confirm.block_id, 'escape');
  const p4 = await waitFor('the panel after Esc', async () => (await sideRoute(S, W)) === '/panels/worktrees' && side(S, W));
  console.log('F ok: remove advice refuses while shells run; Esc returns to the panel');

  // G
  for (const w of await spawnWindows(S, 'feat-a')) {
    for (const b of w.layers.flatMap(l => l.blocks)) await c.call('block.close', {session_id: S, block_id: b.block_id});
  }
  await waitFor('the shell tabs close', async () => (await spawnWindows(S, 'feat-a')).length === 0);
  await c.call('session.destroy', {session_id: other}); // the shell of Open in new session
  await palette(S, src, 'remove_worktree');
  const picker = await waitFor('the remove picker', async () => (await sideRoute(S, W)) === '/forms/remove-worktree' && side(S, W));
  await waitFor('the picker lists feat-a', () => shows(S, picker.block_id, 'feat-a'));
  await tabTo(S, picker.block_id, 'feat-a');
  press(S, picker.block_id, 'enter');
  const confirm2 = await waitFor('the remove confirm', async () => (await sideRoute(S, W)).startsWith('/forms/remove-worktree?path=') && side(S, W));
  await waitFor('the advice is ready', () => shows(S, confirm2.block_id, 'never forces') && !shows(S, confirm2.block_id, 'Checking'));
  assert(!shows(S, confirm2.block_id, 'Removal will be refused'), 'no refusal after the shells closed: ' + text(S, confirm2.block_id));
  await tabTo(S, confirm2.block_id, 'Remove worktree');
  press(S, confirm2.block_id, 'enter');
  await waitFor('the tree is removed', () => !fs.existsSync(tree), 30000);
  assert(!git('-C', repo, 'worktree', 'list').includes(tree), 'git forgets the tree');
  assert.equal(git('-C', repo, 'branch', '--list', 'feat-a'), 'feat-a', 'the branch is kept');
  await waitFor('the panel returns after Remove', async () => (await sideRoute(S, W)) === '/panels/worktrees');
  console.log('G ok: removed through the picker; the branch is kept');
  console.log('worktrees-panel-lab: all phases passed');
} finally {
  // Clean up only what this run made: its sessions (the test session, spawn and hub sessions) and its hub.
  const mine = (await c.call('session.list')).sessions.filter(x => !before.has(x.session_id)); // every session made during the run
  for (const x of mine) await attach(x.session_id).then(() => c.call('session.destroy', {session_id: x.session_id})).catch(e => console.error('cleanup', x.session_id, e.message));
  hubProcess.kill('SIGTERM');
  await new Promise(r => hubProcess.exitCode !== null || hubProcess.signalCode !== null ? r() : hubProcess.once('exit', r));
  c.close?.();
}
