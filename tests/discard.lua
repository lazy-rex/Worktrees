-- worktree.discard and the panel's Discard stopped operation use one handler. An agent discards
-- only its own operations, by key; the user discards any, from the panel. The request key makes a
-- replay return the first result; another target with the same request key conflicts.
local W = load_fixture(H.args.file:match('^(.*)/[^/]*$') .. '/support/fixture.lua')
local repo = W.repo('discard')
local common = W.real(repo .. '/.git')
local alice, bob = agent('alice'), agent('bob')

-- stopped writes a pending create that never started Git (phase prepared), as a crash leaves it.
local function stopped(actor, key, extra)
  local state = store('catalog').value or {repos = {}, pending = {}}
  -- The fingerprint is a real create's, so the create key replays the discard result.
  local op = {kind = 'create', fingerprint = 'create/' .. W.part(repo) .. W.part(key) .. W.part(''), repo = repo, common = common,
    path = W.root .. '/discard/' .. key, branch = key, phase = 'prepared', actor = actor}
  for k, v in pairs(extra or {}) do op[k] = v end
  state.pending[W.part(actor) .. W.part(key)] = op
  write({{key = 'catalog', value = state}})
  return W.part(actor) .. W.part(key)
end
local function pending(id) return ((store('catalog').value or {}).pending or {})[id] end

local function panel_discard(id, key)
  user:command('worktrees')
  local panel = user:view('/panels/worktrees')
  local tree = panel:render()
  expect(node(tree, 'pending/' .. id) ~= nil, 'the panel lists the pending operation').to_be(true)
  return panel:action('pending/' .. id, 'discard', {}, key)
end

test('tool: an agent discards its own operation; a replay returns the first result', function()
  local id = stopped('alice', 'stuck-1')
  local r = alice:call('worktree.discard', {operation = 'stuck-1', key = 'd1'})
  expect(r.discarded).to_be(true)
  expect(pending(id)).to_be(nil)
  expect(alice:call('worktree.discard', {operation = 'stuck-1', key = 'd1'})).to_equal(r)
  -- A new request key for the same target returns the target's saved result.
  expect(alice:call('worktree.discard', {operation = 'stuck-1', key = 'd1-again'}).discarded).to_be(true)
  -- The discarded create key returns its saved result.
  expect(alice:call('worktree.create', {repo = repo, branch = 'stuck-1', key = 'stuck-1'}).status).to_be('discarded')
end)

test('tool: the same request key with another target conflicts', function()
  stopped('alice', 'stuck-2')
  stopped('alice', 'stuck-3')
  alice:call('worktree.discard', {operation = 'stuck-2', key = 'd2'})
  expect_error(function() alice:call('worktree.discard', {operation = 'stuck-3', key = 'd2'}) end, 'operation_conflict')
  expect(pending(W.part('alice') .. W.part('stuck-3')) ~= nil).to_be(true)
end)

test("tool: an agent cannot discard another agent's operation", function()
  local id = stopped('alice', 'stuck-4')
  expect_error(function() bob:call('worktree.discard', {operation = 'stuck-4', key = 'b1'}) end, 'not_found')
  expect(pending(id) ~= nil).to_be(true)
end)

test("view: the user discards any agent's operation from the panel", function()
  local id = stopped('bob', 'stuck-5')
  local op = panel_discard(id, 'panel-d1')
  expect(op.status).to_be('succeeded')
  expect(op.result.discarded).to_be(true)
  expect(pending(id)).to_be(nil)
  expect(bob:call('worktree.discard', {operation = 'stuck-5', key = 'b2'}).discarded).to_be(true)
end)

test('an unknown Git start is refused while its session lives; allowed after the session is gone', function()
  local live = session('discard-live')
  local id = stopped('alice', 'unknown', {phase = 'sending', session = live, label = 'never-sent'})
  expect_error(function() alice:call('worktree.discard', {operation = 'unknown', key = 'u1'}) end, 'late Rex reply')
  local op = panel_discard(id, 'panel-u1')
  expect(op.status).to_be('failed')
  expect(pending(id) ~= nil).to_be(true)
  close_session(live)
  -- A refusal saves nothing, so the same request key works now.
  expect(alice:call('worktree.discard', {operation = 'unknown', key = 'u1'}).discarded).to_be(true)
end)

test('a running Git process is refused', function()
  -- A post-checkout hook holds Git until the gate file exists.
  local gate = H.args.lab .. '/discard-gate'
  W.write(repo .. '/.git/hooks/post-checkout', "#!/bin/sh\nwhile [ ! -f '" .. gate .. "' ]; do sleep 0.1; done\n")
  W.run({'chmod', '755', repo .. '/.git/hooks/post-checkout'})
  local r = alice:call('worktree.create', {repo = repo, branch = 'slow', key = 'slow'})
  expect(r.status).to_be('running')
  wait('Git starts', function()
    local op = pending(W.part('alice') .. W.part('slow'))
    return op and op.block ~= nil
  end)
  expect_error(function() alice:call('worktree.discard', {operation = 'slow', key = 's1'}) end, 'running or starting')
  W.write(gate, 'go')
  local done = W.settle(function() return alice:call('worktree.create', {repo = repo, branch = 'slow', key = 'slow'}) end)
  expect(done.created).to_be(true)
  W.run({'rm', repo .. '/.git/hooks/post-checkout'})
end)

test('an interrupted discard keeps its target: another target conflicts, a retry completes it', function()
  local first = stopped('alice', 'cut-1')
  local second = stopped('alice', 'cut-2')
  -- The target's discard result fails to commit after the request key reserved the target.
  with_injection({match = {op_key = first}, fail = 'lost discard result'}, 1, function()
    expect_error(function() alice:call('worktree.discard', {operation = 'cut-1', key = 'cut-request'}) end, 'lost discard result')
  end)
  expect(pending(first) ~= nil).to_be(true)
  expect_error(function() alice:call('worktree.discard', {operation = 'cut-2', key = 'cut-request'}) end, 'operation_conflict')
  expect(pending(second) ~= nil).to_be(true)
  expect(alice:call('worktree.discard', {operation = 'cut-1', key = 'cut-request'}).discarded).to_be(true)
  expect(pending(first)).to_be(nil)
  expect(pending(second) ~= nil).to_be(true)
end)

test('a retry after an identity change discards the reserved target', function()
  local carol = agent('carol')
  local id = stopped('carol', 'moved')
  with_injection({match = {op_key = id}, fail = 'lost discard result'}, 1, function()
    expect_error(function() carol:call('worktree.discard', {operation = 'moved', key = 'moved-request'}) end, 'lost discard result')
  end)
  expect(carol:report({kind = 'claude', conversation_id = 'conv-discard'}).identity).to_be('claude:conv-discard')
  local r = carol:call('worktree.discard', {operation = 'moved', key = 'moved-request'})
  expect(r.discarded).to_be(true)
  expect(pending(id)).to_be(nil)
end)
