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
local function pending(key) return ((W.catalog() or {}).pending or {})[id(key)] end
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
  with_injection({match = {sql_commit_writes = 'pending'}, skip = 2, fail = 'crash before the block ID'}, 1, function()
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
  local start = W.now()
  expect(alice:call('worktree.create', args).status).to_be('running')
  expect(pending('slow-create').block ~= nil, 'the retry saved the block ID').to_be(true)
  user:command('worktrees')
  expect(user:view('/panels/worktrees'):render().title).to_be('Worktrees')
  expect(W.now() - start < 2, 'a tool call and a render answer within 2 s while Git runs').to_be(true)
  W.write(gate, 'go')
  local slow = settle(function() return alice:call('worktree.create', args) end)
  expect(slow.created).to_be(true)
  expect(worktrees_with('restart/slow')).to_be(1)
  W.run({'rm', repo .. '/.git/hooks/post-checkout'})
  settle(function() return alice:call('worktree.remove', {key = 'slow-remove', path = slow.path}) end)
end)

test('create: Git finished, the result did not commit, then a crash; the retry creates one tree', function()
  local args = {key = 'recover-create', repo = repo, branch = 'restart/create'}
  with_injection({match = {sql_commit_writes = 'ops'}, fail = 'crash before the result'}, 1, function()
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
  with_injection({match = {sql_commit_writes = 'ops'}, fail = 'crash before the result'}, 1, function()
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
  -- The panel renders the repository after the restarts. The first test's panel is still in the
  -- tests window; its renderer attached again after each restart, so the palette replaces it.
  local earlier = {}
  for _, v in ipairs(H.views()) do if v.route == '/panels/worktrees' then earlier[v.view_id] = true end end
  expect(next(earlier) ~= nil, 'the earlier panel is still open').to_be(true)
  user:command('worktrees')
  local panel = user:view('/panels/worktrees')
  expect(earlier[panel.id], 'a new panel replaced the earlier one').to_be(nil)
  local tree = panel:render()
  local shows = false
  for _, it in ipairs(node(tree, 'worktrees').items) do if (it.detail or ''):find(repo, 1, true) or it.id == repo then shows = true end end
  expect(shows, 'the panel lists the repository').to_be(true)
end)

-- created_at is the admission time of a pending operation (RFC 3339 UTC). The first call of a
-- remove admits it and starts its status check, so the call returns running. After a crash restart
-- the check is gone: the first same-key retry starts it again and returns running too. The time
-- stays the same through both.
test('a pending remove keeps its admission time across a retry and a crash restart', function()
  local t = create('age-create', 'age/one')
  local function listed()
    for _, e in ipairs(alice:call('worktree.list', {}).operations or {}) do if e.id == id('age-remove') then return e end end
  end
  expect(alice:call('worktree.remove', {path = t.path, key = 'age-remove'}).status).to_be('running')
  local at = listed().created_at
  expect(at).to_match('^%d%d%d%d%-%d%d%-%d%dT%d%d:%d%d:%d%dZ$')
  hub:restart({crash = true})
  expect(listed().created_at).to_be(at)
  expect(alice:call('worktree.remove', {path = t.path, key = 'age-remove'}).status).to_be('running')
  expect(listed().created_at).to_be(at)
  expect(settle(function() return alice:call('worktree.remove', {path = t.path, key = 'age-remove'}) end).removed).to_be(true)
  expect(listed()).to_be(nil)
end)
