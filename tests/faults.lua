-- Hub faults at the real boundaries (LazyRex lab faults, docs/testing.md "Faults"): a lost
-- hub.spawn reply, a pending and a failed spawn, transport errors, a held unlock and failed
-- invalidations. Ported from worktrees.mjs 194-206, 252-262 and 364-371; coverage map in the
-- commit. The hub restart rows stay open: the harness has no hub restart.
local W = load_fixture(H.args.file:match('^(.*)/[^/]*$') .. '/support/fixture.lua')
local repo = W.repo('faults')
local alice = agent('alice')

-- joiner: an agent profile whose process joins the hub only after the gate file exists, so a test
-- sees the pending state first (the pattern of the Profiles plugin tests). The joining process is
-- the harness test agent (a copy in the lab).
local bin = H.args.lab .. '/bin/lazyrex-hub'
W.run({'mkdir', '-p', H.args.lab .. '/bin'})
W.run({'cp', H.args.hub_bin, bin})
local gate = H.args.lab .. '/join-gate'
write_profiles({profiles = {
  {id = 'sleep', name = 'Sleep', kind = 'accessory', command = {'/bin/sleep', '600'}},
  {id = 'joiner', name = 'Joiner', kind = 'agent', command = {'/bin/sh', '-c',
    'while [ ! -e "$0" ]; do sleep 0.1; done; exec "$1" testagent -id "$LAZYREX_AGENT" -join "$LAZYREX_AGENT"', gate, bin}},
}})

local function create(branch, key)
  return W.settle(function() return alice:call('worktree.create', {repo = repo, branch = branch, key = key}) end)
end
local function workers_in(path)
  local n = 0
  for _, w in ipairs(H.hub('hub.workers', {}).workers or {}) do if w.cwd == path and w.state ~= 'closed' then n = n + 1 end end
  return n
end
local function menu(path)
  user:command('worktrees')
  local panel = user:view('/panels/worktrees')
  panel:render()
  expect(panel:action('worktrees', 'select', {item_id = path}).status).to_be('succeeded')
  local m = user:view(W.route('/forms/worktree', path))
  m:render()
  return m
end
local function id(key) return W.part('alice') .. W.part(key) end

local tree = create('faults/one', 'one')

test('tool: a lost hub.spawn reply is unavailable; the retry returns the same spawn', function()
  local f = fault({point = 'action', action = 'hub.spawn', when = 'after', mode = 'lose-reply', key = 'worktree-open/lost'})
  local known = {}
  for _, w in ipairs(H.hub('hub.workers', {}).workers or {}) do known[w.spawn_id] = true end
  local before = workers_in(tree.path)
  local e = expect_error(function() alice:call('worktree.open', {path = tree.path, key = 'lost'}) end)
  expect(e.code).to_be('unavailable')
  expect(fault_fired(f)).to_be(true)
  -- The spawn ran before the reply was lost.
  expect(workers_in(tree.path)).to_be(before + 1)
  local lost
  for _, w in ipairs(H.hub('hub.workers', {}).workers or {}) do
    if w.cwd == tree.path and not known[w.spawn_id] then lost = w.spawn_id end
  end
  local again = W.settle(function() return alice:call('worktree.open', {path = tree.path, key = 'lost'}) end)
  expect(workers_in(tree.path)).to_be(before + 1)
  expect(again.status).to_be('open')
  expect(again.spawn_id).to_be(lost)
end)

test('view: New Worktree with a lost hub.spawn reply; the hub retries the operation; one tree, one shell', function()
  local f = fault({point = 'action', action = 'hub.spawn', when = 'after', mode = 'lose-reply', key = 'worktree-open/created/view-lost'})
  user:command('new_worktree')
  local form = user:view('/forms/new-worktree')
  form:render()
  local op = form:action('new_worktree', 'submit', {values = {repo = repo, branch = 'faults/view-lost', base = ''}}, 'view-lost')
  expect(fault_fired(f)).to_be(true)
  expect(op.status).to_be('succeeded')
  expect(op.result.created).to_be(true)
  expect(workers_in(op.result.path)).to_be(1)
end)

test('transport error: an unavailable hub.spawn stays unavailable; the retry spawns once', function()
  local f = fault({point = 'action', action = 'hub.spawn', when = 'before', mode = 'fail', fail_code = 'unavailable', key = 'worktree-open/transport'})
  local before = workers_in(tree.path)
  local e = expect_error(function() alice:call('worktree.open', {path = tree.path, key = 'transport'}) end)
  expect(e.code).to_be('unavailable')
  expect(fault_fired(f)).to_be(true)
  expect(workers_in(tree.path)).to_be(before)
  W.settle(function() return alice:call('worktree.open', {path = tree.path, key = 'transport'}) end)
  expect(workers_in(tree.path)).to_be(before + 1)
end)

test('transport error on the view path: the hub retries Open; a definite hub failure ends the operation', function()
  local f = fault({point = 'action', action = 'hub.spawn', when = 'before', mode = 'fail', fail_code = 'unavailable', key = 'worktree-open/view-transport'})
  local before = workers_in(tree.path)
  local op = menu(tree.path):action('worktree_menu', 'run', {item_id = 'open_tab'}, 'view-transport')
  expect(fault_fired(f)).to_be(true)
  expect(op.status).to_be('succeeded')
  expect(workers_in(tree.path)).to_be(before + 1)
  -- A definite failure (code failed) is final: no retry, no spawn.
  local g = fault({point = 'action', action = 'hub.spawn', when = 'before', mode = 'fail', key = 'worktree-open/view-definite'})
  op = menu(tree.path):action('worktree_menu', 'run', {item_id = 'open_tab'}, 'view-definite')
  expect(fault_fired(g)).to_be(true)
  expect(op.status).to_be('failed')
  expect(op.error.code).to_be('failed')
  expect(workers_in(tree.path)).to_be(before + 1)
end)

test('a failed spawn is open_failed on both paths', function()
  local f = fault({point = 'spawn-create', mode = 'refuse', op = 'worktree-open/refused'})
  expect_error(function() W.settle(function() return alice:call('worktree.open', {path = tree.path, key = 'refused'}) end) end, 'open_failed')
  expect(fault_fired(f)).to_be(true)
  -- The replay returns the same failure.
  expect_error(function() alice:call('worktree.open', {path = tree.path, key = 'refused'}) end, 'open_failed')
  local g = fault({point = 'spawn-create', mode = 'refuse', op = 'worktree-open/view-refused'})
  local op = menu(tree.path):action('worktree_menu', 'run', {item_id = 'open_tab'}, 'view-refused')
  expect(fault_fired(g)).to_be(true)
  expect(op.status).to_be('failed')
  expect(op.error.code).to_be('open_failed')
end)

test('a pending spawn is running on both paths until it ends; its session going away fails it', function()
  -- Tool: the create request is dropped, so the spawn stays pending in its own session.
  local f = fault({point = 'spawn-create', mode = 'drop', op = 'worktree-open/pending'})
  local r = alice:call('worktree.open', {path = tree.path, key = 'pending', where = 'session'})
  expect(fault_fired(f)).to_be(true)
  expect(r.status).to_be('running')
  expect(alice:call('worktree.open', {path = tree.path, key = 'pending', where = 'session'}).status).to_be('running')
  close_session(r.session_id)
  wait('the pending spawn fails', function()
    local ok, e = pcall(function() return alice:call('worktree.open', {path = tree.path, key = 'pending', where = 'session'}) end)
    return not ok and tostring(e.message or e):find('session gone', 1, true)
  end, 30)
  -- View: Open in new session stays pending while the spawn is pending; the hub does not commit it.
  local g = fault({point = 'spawn-create', mode = 'drop', op = 'worktree-open/view-pending'})
  local m = menu(tree.path)
  local _, key = m:admit('action', {node_id = 'worktree_menu', action = 'run', input = {item_id = 'open_session'}, revision = m.revision, operation_key = 'view-pending'})
  wait('the spawn is pending', function() return fault_fired(g) end, 20)
  rex.sleep(1.5)
  expect(operation(key).status).to_be('pending')
  close_session(W.intent('user', 'worktree-open/view-pending').request.placement.session)
  local op = m:settle(key, 30)
  expect(op.status).to_be('failed')
  expect(op.error.code).to_be('open_failed')
end)

test('a failed unlock keeps the lock and the cleanup; the retry unlocks and returns the result', function()
  local made = create('faults/unlock', 'unlock-create')
  local f = fault({point = 'action', action = 'hub.cwd.unlock', when = 'before', mode = 'fail', fail_code = 'unavailable', key = id('unlock')})
  local e = expect_error(function() W.settle(function() return alice:call('worktree.remove', {path = made.path, key = 'unlock'}) end) end)
  expect(e.code).to_be('unavailable')
  expect(fault_fired(f)).to_be(true)
  -- The result committed; the cleanup is pending.
  local pending = W.catalog().pending[id('unlock')]
  expect(pending.phase).to_be('cleanup')
  expect(W.try({'test', '-e', made.path}).ok).to_be(false)
  -- The hub lock is held: a spawn into the path is refused by the lock.
  W.run({'mkdir', made.path})
  expect_error(function() alice:hub('hub.spawn', {profile = 'sleep', key = 'into-unlock', cwd = made.path}) end, 'is locked by')
  -- The retry finishes the unlock and returns the committed result.
  expect(alice:call('worktree.remove', {path = made.path, key = 'unlock'}).removed).to_be(true)
  expect(W.catalog().pending[id('unlock')]).to_be(nil)
  local w = alice:hub('hub.spawn', {profile = 'sleep', key = 'after-retry-unlock', cwd = made.path})
  alice:hub('hub.stop', {spawn_id = w.spawn_id})
  W.run({'rmdir', made.path})
end)

test('failed invalidations do not strand a scan: later changes still refresh the panel', function()
  user:command('worktrees')
  local panel = user:view('/panels/worktrees')
  local function detail()
    for _, it in ipairs(node(panel:render(), 'worktrees').items) do if it.id == tree.path then return it.detail end end
    return ''
  end
  wait('clean first', function() return detail():find('clean', 1, true) end, 20)
  local first = fault({point = 'action', action = 'hub.ui.invalidate', when = 'before', mode = 'fail', fail_code = 'unavailable', nth = 1})
  local second = fault({point = 'action', action = 'hub.ui.invalidate', when = 'before', mode = 'fail', fail_code = 'unavailable', nth = 2})
  W.write(tree.path .. '/inval-change', 'keep')
  panel:seen('focus')
  wait('focus shows dirty', function() return detail():find('dirty', 1, true) end, 20)
  wait('both invalidations failed', function() return fault_fired(first) and fault_fired(second) end, 20)
  W.run({'rm', tree.path .. '/inval-change'})
  panel:seen('focus')
  wait('a later change shows clean', function() return detail():find('clean', 1, true) end, 20)
end)

test('a pending agent spawn becomes open when its agent joins, on both paths', function()
  -- Tool: the create answer is lost, so the pane exists and the spawn stays pending until the join.
  local f = fault({point = 'spawn-create', mode = 'lose-answer', op = 'worktree-open/join'})
  local first = alice:call('worktree.open', {path = tree.path, key = 'join', profile = 'joiner'})
  expect(fault_fired(f)).to_be(true)
  expect(first.status).to_be('running')
  expect(alice:call('worktree.open', {path = tree.path, key = 'join', profile = 'joiner'}).status).to_be('running')
  W.run({'touch', gate})
  local opened = W.settle(function() return alice:call('worktree.open', {path = tree.path, key = 'join', profile = 'joiner'}) end, 'the join', 30)
  expect(opened.status).to_be('open')
  expect(opened.spawn_id).to_be(first.spawn_id)
  W.run({'rm', gate})
  -- View: the Start agent operation stays pending (running) until the join, then succeeds.
  local g = fault({point = 'spawn-create', mode = 'lose-answer', op = 'worktree-agent/view-join'})
  local m = menu(tree.path)
  m:action('worktree_menu', 'run', {item_id = 'agent'})
  local profiles = user:view(W.route('/forms/worktree-agent', tree.path))
  profiles:render()
  profiles:action('profiles', 'select', {item_id = 'joiner'})
  local form = user:view(W.route('/forms/worktree-agent/joiner', tree.path))
  form:render()
  local _, key = form:admit('action', {node_id = 'start_agent', action = 'submit', input = {values = {placement = 'tab'}}, revision = form.revision, operation_key = 'view-join'})
  wait('the spawn is pending', function() return fault_fired(g) end, 20)
  rex.sleep(1.5)
  expect(operation(key).status).to_be('pending')
  W.run({'touch', gate})
  local op = form:settle(key, 30)
  expect(op.status).to_be('succeeded')
  local found
  for _, w in ipairs(H.hub('hub.workers', {}).workers or {}) do
    if w.cwd == tree.path and w.profile == 'joiner' and w.parent == 'user' then found = w end
  end
  expect(found ~= nil and found.state ~= 'starting', 'an open user joiner worker').to_be(true)
  W.run({'rm', gate})
end)

test('view: a shell that an older version started (no open intent) replays its spawn after the upgrade', function()
  -- An older version called hub.spawn with key worktree-open/created/<operation key> and saved no
  -- open intent. The state: the first call spawns, its reply is lost, and the hub retries; a gate
  -- holds the retries while the test deletes the intent, as an older version left it.
  local spawn_key = 'worktree-open/created/old-ui'
  local lost = fault({point = 'action', action = 'hub.spawn', when = 'after', mode = 'lose-reply', key = spawn_key})
  local gate = fault({point = 'action', action = 'hub.spawn', when = 'before', mode = 'gate', key = spawn_key, nth = 2})
  user:command('new_worktree')
  local form = user:view('/forms/new-worktree')
  form:render()
  local _, key = form:admit('action', {node_id = 'new_worktree', action = 'submit',
    input = {values = {repo = repo, branch = 'faults/old-ui', base = ''}}, revision = form.revision, operation_key = 'old-ui'})
  wait('the retries reach the gate', function() return fault_fired(lost) and fault_fired(gate) end, 30)
  local path = W.tree_path(repo, 'faults/old-ui')
  expect(workers_in(path)).to_be(1)
  local first
  for _, w in ipairs(H.hub('hub.workers', {}).workers or {}) do if w.cwd == path then first = w.spawn_id end end
  local record = 'open/' .. W.part('user') .. W.part(spawn_key)
  expect(W.reservation(record) ~= nil, 'the new version saved an intent').to_be(true)
  W.set_reservation(record, nil)
  -- A retry without an intent goes through the new handler: it saves a new intent, then calls
  -- hub.spawn with the same key (refused by the gate until the release).
  wait('the new handler saves an intent again', function()
    local v = W.reservation(record)
    return v and v.phase == 'ready'
  end, 30)
  fault_release(gate)
  local op = form:settle(key, 30)
  expect(op.status).to_be('succeeded')
  expect(workers_in(path)).to_be(1)
  local now
  for _, w in ipairs(H.hub('hub.workers', {}).workers or {}) do if w.cwd == path then now = w.spawn_id end end
  expect(now).to_be(first)
  expect(W.intent('user', spawn_key).phase).to_be('ready')
end)
