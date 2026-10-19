-- Recovery across a real hub restart (hub:restart, docs/testing.md "Hub restart"). Each case puts
-- the store in the state that a crash at that point leaves (an injected batch or hub fault),
-- checks that state, restarts the hub (a crash: SIGKILL, unless the case says otherwise), and
-- retries the same key. Ported from worktrees.mjs 319-371 and worktrees-hub.mjs 53-56; coverage
-- map in the commit.
local W = load_fixture(H.args.file:match('^(.*)/[^/]*$') .. '/support/fixture.lua')
local lab = H.args.lab
local repo = W.repo('restart')
local alice = agent('alice')

write_profiles({profiles = {{id = 'sleep', name = 'Sleep', kind = 'accessory', command = {'/bin/sleep', '600'}}}})

local function id(key) return W.part('alice') .. W.part(key) end
local function pending(key) return ((store('catalog').value or {}).pending or {})[id(key)] end
local function settle(fn) return W.settle(fn, 'the operation', 30) end
local function create(key, branch) return settle(function() return alice:call('worktree.create', {key = key, repo = repo, branch = branch}) end) end
local function worktrees_with(branch)
  local text, n, pos = W.git(repo, 'worktree', 'list', '--porcelain') .. '\n', 0, 1
  while true do
    local _, e = text:find('branch refs/heads/' .. branch .. '\n', pos, true)
    if not e then return n end
    n, pos = n + 1, e + 1
  end
end
-- locked reports whether the hub lock covers path: hub.spawn checks the lock before the directory,
-- so the path is made again as an empty directory for the check.
local function locked(path, key)
  W.run({'mkdir', path})
  local ok, err = pcall(function() return alice:hub('hub.spawn', {profile = 'sleep', key = key, cwd = path}) end)
  if ok then alice:hub('hub.stop', {spawn_id = err.spawn_id}) end
  W.run({'rmdir', path})
  if ok then return false end
  if not tostring(err.message or err):find('is locked by', 1, true) then error(err, 0) end
  return true
end

test('a crash after Git starts, before its block ID is saved: the retry finds the block by its label', function()
  local gate = lab .. '/release-hook'
  W.write(repo .. '/.git/hooks/post-checkout', "#!/bin/sh\nwhile [ ! -f '" .. gate .. "' ]; do sleep 0.1; done\n")
  W.run({'chmod', '755', repo .. '/.git/hooks/post-checkout'})
  local args = {key = 'slow-create', repo = repo, branch = 'restart/slow'}
  -- Catalog batches of a create: admission, phase sending, then the block ID. The third fails.
  with_injection({match = {writes = 'catalog'}, skip = 2, fail = 'crash before the block ID'}, 1, function()
    expect_error(function() alice:call('worktree.create', args) end, 'crash before the block ID')
  end)
  local op = pending('slow-create')
  expect(op.phase).to_be('sending')
  expect(op.block).to_be(nil)
  local labeled = 0
  for _, b in ipairs(rex.call('session.list_blocks', {session_id = op.session}).blocks or {}) do
    if b.label == op.label then labeled = labeled + 1 end
  end
  expect(labeled).to_be(1)
  hub:restart({crash = true})
  local start = os.time()
  expect(alice:call('worktree.create', args).status).to_be('running')
  expect(pending('slow-create').block ~= nil, 'the retry saved the block ID').to_be(true)
  user:command('worktrees')
  expect(user:view('/panels/worktrees'):render().title).to_be('Worktrees')
  expect(os.time() - start <= 2, 'a tool call and a render answer while Git runs').to_be(true)
  W.write(gate, 'go')
  local slow = settle(function() return alice:call('worktree.create', args) end)
  expect(slow.created).to_be(true)
  expect(worktrees_with('restart/slow')).to_be(1)
  W.run({'rm', repo .. '/.git/hooks/post-checkout'})
  settle(function() return alice:call('worktree.remove', {key = 'slow-remove', path = slow.path}) end)
end)

test('create: Git finished, the result did not commit, then a crash; the retry creates one tree', function()
  local args = {key = 'recover-create', repo = repo, branch = 'restart/create'}
  with_injection({match = {op_key = id('recover-create')}, fail = 'crash before the result'}, 1, function()
    expect_error(function() settle(function() return alice:call('worktree.create', args) end) end, 'crash before the result')
  end)
  local op = pending('recover-create')
  expect(op.phase).to_be('sending')
  expect(worktrees_with('restart/create')).to_be(1)
  rex.call('block.close', {session_id = op.session, block_id = op.block})
  hub:restart({crash = true})
  local recovered = settle(function() return alice:call('worktree.create', args) end)
  expect(recovered.created).to_be(true)
  expect(worktrees_with('restart/create')).to_be(1)
  expect(pending('recover-create')).to_be(nil)
end)

test('remove: Git finished, the result did not commit, then a crash; the lock holds until the retry', function()
  local made = create('to-remove', 'restart/remove')
  local args = {key = 'recover-remove', path = made.path}
  with_injection({match = {op_key = id('recover-remove')}, fail = 'crash before the result'}, 1, function()
    expect_error(function() settle(function() return alice:call('worktree.remove', args) end) end, 'crash before the result')
  end)
  local op = pending('recover-remove')
  expect(op.phase).to_be('sending')
  expect(W.try({'test', '-e', made.path}).ok).to_be(false)
  expect(locked(made.path, 'lock-before')).to_be(true)
  rex.call('block.close', {session_id = op.session, block_id = op.block})
  hub:restart({crash = true})
  expect(locked(made.path, 'lock-after-restart')).to_be(true)
  expect(settle(function() return alice:call('worktree.remove', args) end).removed).to_be(true)
  expect(pending('recover-remove')).to_be(nil)
  expect(locked(made.path, 'lock-after-retry')).to_be(false)
end)

test('the result committed, the unlock did not: plugin startup unlocks without a retry', function()
  local made = create('unlock-create', 'restart/unlock')
  local f = fault({point = 'action', action = 'hub.cwd.unlock', when = 'before', mode = 'fail', fail_code = 'unavailable', key = id('recover-unlock')})
  expect_error(function() settle(function() return alice:call('worktree.remove', {key = 'recover-unlock', path = made.path}) end) end)
  expect(fault_fired(f)).to_be(true)
  expect(pending('recover-unlock').phase).to_be('cleanup')
  expect(locked(made.path, 'unlock-before')).to_be(true)
  hub:restart()
  wait('startup finishes the cleanup', function() return pending('recover-unlock') == nil end, 20)
  expect(locked(made.path, 'unlock-after-restart')).to_be(false)
  expect(alice:call('worktree.remove', {key = 'recover-unlock', path = made.path}).removed).to_be(true)
end)

test('saved results replay after a restart: create, open and remove', function()
  local first = create('durable-create', 'restart/durable')
  local opened = W.settle(function() return alice:call('worktree.open', {path = first.path, key = 'durable-open'}) end)
  hub:restart()
  expect(alice:call('worktree.create', {key = 'durable-create', repo = repo, branch = 'restart/durable'})).to_equal(first)
  expect(W.settle(function() return alice:call('worktree.open', {path = first.path, key = 'durable-open'}) end).spawn_id).to_be(opened.spawn_id)
  alice:hub('hub.stop', {spawn_id = opened.spawn_id})
  wait('the shell closed', function()
    for _, w in ipairs(H.hub('hub.workers', {}).workers or {}) do
      if w.spawn_id == opened.spawn_id and w.state ~= 'closed' then return nil end
    end
    return true
  end, 20)
  local removed = settle(function() return alice:call('worktree.remove', {key = 'durable-remove', path = first.path}) end)
  expect(removed.removed).to_be(true)
  hub:restart({crash = true})
  expect(alice:call('worktree.remove', {key = 'durable-remove', path = first.path})).to_equal(removed)
  expect(W.try({'test', '-e', first.path}).ok).to_be(false)
  -- The panel renders the repository after the restarts. It opens from a new window: the test
  -- renderer of the first test's panel does not attach again after a hub restart, and the hub
  -- does not replace a side panel whose renderer is not attached.
  local S = H.args.tests_session
  local before = {}
  for _, w in ipairs(rex.call('session.view', {session_id = S}).windows or {}) do before[w.window_id] = true end
  rex.call('session.new_window', {session_id = S, window_label = 'after-restart', layout = {block = {flavor = 'com.superlogical.terminal.shell',
    label = 'after-restart', options = {command = {'/bin/sleep', '600'}, cwd = repo, login = false}}}})
  local block
  for _, w in ipairs(rex.call('session.view', {session_id = S}).windows or {}) do
    if not before[w.window_id] then block = w.layers[1].blocks[1].block_id end
  end
  user:command('worktrees', {session = S, block = block})
  local tree = user:view('/panels/worktrees', nil, S):render()
  local shows = false
  for _, it in ipairs(node(tree, 'worktrees').items) do if (it.detail or ''):find(repo, 1, true) or it.id == repo then shows = true end end
  expect(shows, 'the panel lists the repository').to_be(true)
end)
