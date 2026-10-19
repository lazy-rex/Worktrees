-- Recovery (ported from worktrees.mjs 319-367). Each case leaves the store in the state that a
-- crash at that point leaves (an injected batch failure), checks that state, then retries the same
-- key. These tests do not restart the plugin or the hub: hub:restart() is not on LazyRex main yet,
-- so the coverage map keeps the restart rows open.
local W = load_fixture(H.args.file:match('^(.*)/[^/]*$') .. '/support/fixture.lua')
local lab = H.args.lab
local repo = W.repo('recovery')
local alice = agent('alice')

local function id(key) return W.part('alice') .. W.part(key) end
local function pending(key) return ((store('catalog').value or {}).pending or {})[id(key)] end
-- worktrees_with counts the worktrees of a branch (git worktree list --porcelain).
local function worktrees_with(branch)
  local text, n, pos = W.git(repo, 'worktree', 'list', '--porcelain') .. '\n', 0, 1
  while true do
    local _, e = text:find('branch refs/heads/' .. branch .. '\n', pos, true)
    if not e then return n end
    n, pos = n + 1, e + 1
  end
end
local function settle(fn) return W.settle(fn, 'the operation', 30) end

test('a slow Git process does not block tools or rendering; the retry creates one tree', function()
  local gate = lab .. '/release-hook'
  W.write(repo .. '/.git/hooks/post-checkout', "#!/bin/sh\nwhile [ ! -f '" .. gate .. "' ]; do sleep 0.1; done\n")
  W.run({'chmod', '755', repo .. '/.git/hooks/post-checkout'})
  local args = {key = 'slow-create', repo = repo, branch = 'recovery/slow'}
  expect(alice:call('worktree.create', args).status).to_be('running')
  wait('Git runs in its block', function() local op = pending('slow-create'); return op and op.block end)
  local start = os.time()
  expect(alice:call('worktree.create', args).status).to_be('running')
  user:command('worktrees')
  user:view('/panels/worktrees'):render()
  expect(os.time() - start <= 2, 'a tool call and a render answer while Git runs').to_be(true)
  W.write(gate, 'go')
  local slow = settle(function() return alice:call('worktree.create', args) end)
  expect(slow.created).to_be(true)
  expect(worktrees_with('recovery/slow')).to_be(1)
  W.run({'rm', repo .. '/.git/hooks/post-checkout'})
  settle(function() return alice:call('worktree.remove', {key = 'slow-remove', path = slow.path}) end)
end)

test('create: Git finished, the result did not commit; the retry after the block is gone creates one tree', function()
  local args = {key = 'recover-create', repo = repo, branch = 'recovery/create'}
  with_injection({match = {op_key = id('recover-create')}, fail = 'crash before the result'}, 1, function()
    expect_error(function() settle(function() return alice:call('worktree.create', args) end) end, 'crash before the result')
  end)
  -- The state a crash leaves: the operation is pending in phase sending, with its Git block.
  local op = pending('recover-create')
  expect(op.phase).to_be('sending')
  expect(op.block ~= nil).to_be(true)
  expect(worktrees_with('recovery/create')).to_be(1)
  rex.call('block.close', {session_id = op.session, block_id = op.block})
  local recovered = settle(function() return alice:call('worktree.create', args) end)
  expect(recovered.created).to_be(true)
  expect(worktrees_with('recovery/create')).to_be(1)
  expect(pending('recover-create')).to_be(nil)
end)

test('remove: Git finished, the result did not commit; the lock stays until the retry', function()
  local made = settle(function() return alice:call('worktree.create', {key = 'to-remove', repo = repo, branch = 'recovery/remove'}) end)
  local args = {key = 'recover-remove', path = made.path}
  with_injection({match = {op_key = id('recover-remove')}, fail = 'crash before the result'}, 1, function()
    expect_error(function() settle(function() return alice:call('worktree.remove', args) end) end, 'crash before the result')
  end)
  local op = pending('recover-remove')
  expect(op.phase).to_be('sending')
  expect(W.try({'test', '-e', made.path}).ok).to_be(false)
  -- The pending operation still owns the path: a create of the same path is refused.
  expect_error(function() alice:call('worktree.create', {key = 'other-create', repo = repo, branch = 'recovery/remove'}) end, 'Another operation owns this path')
  rex.call('block.close', {session_id = op.session, block_id = op.block})
  expect(settle(function() return alice:call('worktree.remove', args) end).removed).to_be(true)
  expect(pending('recover-remove')).to_be(nil)
end)
