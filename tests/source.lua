-- The source pane, removal advice, refresh events and idle behaviour (ported from the view cases of
-- worktrees.mjs; coverage map in the port commit). Idle checks are behaviour checks: they count
-- hub.ui.invalidate calls and view renders; the hub cannot see the plugin's rex.after timers.
local W = load_fixture(H.args.file:match('^(.*)/[^/]*$') .. '/support/fixture.lua')
local lab = H.args.lab
local S = H.args.tests_session
local repo = W.repo('source')
local alice = agent('alice')

write_profiles({profiles = {{id = 'sleep', name = 'Sleep', kind = 'accessory', command = {'/bin/sleep', '600'}}}})

local function sview(s)
  rex.call('session.attach', {session_id = s, event_scope = 'session'})
  return rex.call('session.view', {session_id = s})
end
-- pane opens a new window in session s with one pane that runs argv in cwd; returns its block.
local function pane(s, label, argv, cwd)
  local before = {}
  for _, w in ipairs(sview(s).windows or {}) do before[w.window_id] = true end
  rex.call('session.new_window', {session_id = s, window_label = label, layout = {block = {flavor = 'com.superlogical.terminal.shell',
    label = label, options = {command = argv, cwd = cwd, login = false, exit = {on_completion = false}}}}})
  for _, w in ipairs(sview(s).windows or {}) do
    if not before[w.window_id] then
      for _, layer in ipairs(w.layers or {}) do for _, b in ipairs(layer.blocks or {}) do return b.block_id end end
    end
  end
  error('no new window', 0)
end
-- osc7 reports dir with OSC 7 (percent-encoded, as a shell does), then waits for the gate file.
local function osc7(dir, gate)
  local encoded = dir:gsub('([^%w%-%._~/])', function(c) return string.format('%%%02X', string.byte(c)) end)
  return {'/bin/sh', '-c', 'printf "\\033]7;file://localhost%s\\007" "$1"; while [ ! -f "$2" ]; do sleep 0.1; done', 'sh', encoded, gate or (lab .. '/never')}
end
local function form_repo(block)
  user:command('new_worktree', {session = S, block = block})
  local form = user:view('/forms/new-worktree', nil, S)
  local value
  for _, f in ipairs(node(form:render(), 'new_worktree').fields) do if f.id == 'repo' then value = f.value end end
  rex.call('block.close', {session_id = form.session, block_id = form.block})
  return value
end
local function panel_from(block)
  user:command('worktrees', {session = S, block = block})
  return user:view('/panels/worktrees', nil, S)
end
local function detail(panel, path)
  for _, it in ipairs(node(panel:render(), 'worktrees').items) do if it.id == path then return it.detail end end
  return ''
end

-- A tree that alice creates; the catalog records the repository.
local tree = W.settle(function() return alice:call('worktree.create', {repo = repo, branch = 'src/one', key = 'src-one'}) end)
-- A source repository that the catalog does not know, with characters that OSC 7 encodes.
local source_repo = lab .. '/repos/source only # % repo'
W.run({'git', 'clone', '--quiet', repo, source_repo})
source_repo = W.real(source_repo)

test('New Worktree defaults to the source pane repository from OSC 7', function()
  local b = pane(S, 'osc7', osc7(source_repo), lab)
  wait('the pane reports its directory', function()
    local r = rex.call('com.superlogical.terminal.pwd', {session_id = S, block_id = b, args = {}})
    return r and r.pwd and r.pwd ~= ''
  end)
  expect(form_repo(b)).to_be(source_repo)
end)

test('without OSC 7 the process directory is the source', function()
  local b = pane(S, 'plain', {'/bin/sleep', '600'}, source_repo)
  expect(form_repo(b)).to_be(source_repo)
end)

test('a source pane outside Git falls back to the recorded repositories', function()
  local b = pane(S, 'outside', {'/bin/sleep', '600'}, lab)
  expect(form_repo(b)).to_be(repo)
end)

test('the panel scans the source-only repository; renders after the scan start no new scan', function()
  local b = pane(S, 'osc7-panel', osc7(source_repo), lab)
  local panel = panel_from(b)
  wait('the source-only row is clean', function()
    local first = node(panel:render(), 'worktrees').items[1]
    return first and first.id == source_repo and first.detail:find('clean', 1, true)
  end, 20)
  rex.sleep(0.5)
  local count = invalidates()
  for _ = 1, 3 do panel:render(); rex.sleep(0.1) end
  expect(invalidates(), 'renders invalidate nothing (behaviour check, not a timer count)').to_be(count)
end)

test('removal advice: ignored files, then a worker (hub.changed), then clear; advice holds no lock', function()
  local b = pane(S, 'advice-src', {'/bin/sleep', '600'}, repo)
  user:command('remove_worktree', {session = S, block = b})
  local picker = user:view('/forms/remove-worktree', nil, S)
  picker:render()
  W.write(tree.path .. '/ignored.tmp', 'keep')
  W.write(tree.path .. '/.gitignore', 'ignored.tmp\n.gitignore\n')
  picker:action('remove_pick', 'select', {item_id = tree.path})
  local form = user:view(W.route('/forms/remove-worktree', tree.path), nil, S)
  local function check()
    local c = node(form:render(), 'check')
    return c and c.text or ''
  end
  -- The first render starts the check; it never reserves the path.
  wait('ignored-file advice', function() return check():find('ignored files', 1, true) end, 20)
  W.run({'rm', tree.path .. '/ignored.tmp', tree.path .. '/.gitignore'})
  local w = alice:hub('hub.spawn', {profile = 'sleep', key = 'advice-worker', cwd = tree.path})
  -- A worker change (hub.changed) refreshes the advice without focus.
  wait('worker advice', function() return check():find(w.spawn_id, 1, true) end, 20)
  alice:hub('hub.stop', {spawn_id = w.spawn_id})
  wait('clear advice', function() return check() == '' end, 20)
  -- No lock: the owner removes the tree at once, then creates it again for the next tests.
  expect(W.settle(function() return alice:call('worktree.remove', {path = tree.path, key = 'advice-rm'}) end).removed).to_be(true)
  tree = W.settle(function() return alice:call('worktree.create', {repo = repo, branch = 'src/one', key = 'src-one-again'}) end)
  rex.call('block.close', {session_id = form.session, block_id = form.block})
end)

test('an idle panel invalidates nothing; content seen and a render start no refresh loop', function()
  local b = pane(S, 'idle-src', {'/bin/sleep', '600'}, repo)
  local panel = panel_from(b)
  wait('the tree row is clean', function() return detail(panel, tree.path):find('clean', 1, true) end, 20)
  rex.sleep(0.5)
  local count = invalidates()
  rex.sleep(1)
  expect(invalidates(), 'idle').to_be(count)
  panel:seen('content')
  panel:render()
  rex.sleep(1)
  expect(invalidates(), 'content seen and a render').to_be(count)
end)

test('focus refreshes the panel; a worker change refreshes it without focus', function()
  local b = pane(S, 'focus-src', {'/bin/sleep', '600'}, repo)
  local panel = panel_from(b)
  W.write(tree.path .. '/focus-change', 'keep')
  panel:seen('focus')
  wait('focus shows dirty', function() return detail(panel, tree.path):find('dirty', 1, true) end, 20)
  W.run({'rm', tree.path .. '/focus-change'})
  local w = alice:hub('hub.spawn', {profile = 'sleep', key = 'event-worker', title = 'Event worker', cwd = tree.path})
  wait('the worker change shows the worker and clean', function()
    local d = detail(panel, tree.path)
    return d:find('clean', 1, true) and d:find('Event worker', 1, true)
  end, 20)
  alice:hub('hub.stop', {spawn_id = w.spawn_id})
end)

test('a directory event in another session refreshes the panel; so does its process exit', function()
  local b = pane(S, 'event-src', {'/bin/sleep', '600'}, repo)
  local panel = panel_from(b)
  wait('clean first', function() return detail(panel, tree.path):find('clean', 1, true) end, 20)
  W.write(tree.path .. '/event-change', 'keep')
  local other = session('event-pane')
  local gate = lab .. '/event-gate'
  pane(other, 'event', osc7(tree.path, gate), tree.path)
  wait('the foreign directory event shows dirty', function() return detail(panel, tree.path):find('dirty', 1, true) end, 20)
  W.run({'rm', tree.path .. '/event-change'})
  W.write(gate, 'go')
  wait('the foreign process exit shows clean', function() return detail(panel, tree.path):find('clean', 1, true) end, 20)
  close_session(other)
  expect(invalidates() > 0, 'scan changes invalidate the view').to_be(true)
end)

test('list with a repository shows a worker whose directory is inside the tree', function()
  W.run({'mkdir', '-p', tree.path .. '/subdir'})
  local w = alice:hub('hub.spawn', {profile = 'sleep', key = 'sub-worker', cwd = tree.path .. '/subdir'})
  local found
  wait('the worker in the list', function()
    for _, t in ipairs(alice:call('worktree.list', {repo = repo}).worktrees or {}) do
      if t.path == tree.path and t.workers[1] then found = t.workers[1] end
    end
    return found
  end, 20)
  expect(found.spawn_id).to_be(w.spawn_id)
  alice:hub('hub.stop', {spawn_id = w.spawn_id})
  W.run({'rmdir', tree.path .. '/subdir'})
end)
