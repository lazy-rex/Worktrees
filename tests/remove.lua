-- Who may remove a worktree (decision "Agents may act on anything", 2026-10-19): an agent
-- removes any managed tree, also one that another agent or the user created. The safety checks stay
-- for every caller: no forced removal, and a refusal for changes, ignored files, workers and panes.
local W = load_fixture(H.args.file:match('^(.*)/[^/]*$') .. '/support/fixture.lua')
local repo = W.repo('remove')
local alice, bob = agent('alice'), agent('bob')

local function create(who, branch, key)
  return W.settle(function() return who:call('worktree.create', {repo = repo, branch = branch, key = key}) end)
end
local function remove(who, path, key)
  return W.settle(function() return who:call('worktree.remove', {path = path, key = key}) end)
end
local function exists(path) return W.try({'test', '-e', path}).ok end

-- The view path: Remove Worktree… with the path, then submit.
local function user_remove(path, key)
  user:command('remove_worktree')
  local picker = user:view('/forms/remove-worktree')
  picker:render()
  local op = picker:action('remove_pick', 'select', {item_id = path})
  expect(op.status).to_be('succeeded')
  local form = user:view(W.route('/forms/remove-worktree', path))
  form:render()
  return form:action('remove_worktree', 'submit', {values = {path = path}}, key)
end

test("an agent removes another agent's tree; the branch stays", function()
  local t = create(alice, 'rm/one', 'rm-one')
  expect(t.created).to_be(true)
  expect(remove(bob, t.path, 'bob-rm-one').removed).to_be(true)
  expect(exists(t.path)).to_be(false)
  expect(W.git(repo, 'branch', '--list', 'rm/one')).to_match('rm/one')
end)

test("an agent removes the user's tree; the user removes an agent's tree through the form", function()
  user:command('new_worktree')
  local form = user:view('/forms/new-worktree')
  form:render()
  local op = form:action('new_worktree', 'submit', {values = {repo = repo, branch = 'rm/user', base = ''}}, 'user-create')
  expect(op.status).to_be('succeeded')
  local path = op.result.path
  -- The shell that New Worktree opened blocks removal; it closes first.
  for _, w in ipairs(H.hub('hub.workers', {}).workers or {}) do
    if w.cwd == path and w.state ~= 'closed' then
      rex.call('block.close', {session_id = w.session_id, block_id = w.block_id})
    end
  end
  wait('the shell is gone', function()
    for _, w in ipairs(H.hub('hub.workers', {}).workers or {}) do if w.cwd == path and w.state ~= 'closed' then return nil end end
    return true
  end, 20)
  expect(remove(alice, path, 'alice-rm-user').removed).to_be(true)
  local t = create(bob, 'rm/bob', 'rm-bob')
  expect(user_remove(t.path, 'user-rm-bob').status).to_be('succeeded')
  expect(exists(t.path)).to_be(false)
end)

test("the safety checks stay for another agent's tree", function()
  local t = create(alice, 'rm/safe', 'rm-safe')
  W.write(t.path .. '/local.txt', 'keep me')
  expect_error(function() remove(bob, t.path, 'bob-dirty') end, 'changes or untracked files')
  expect(W.run({'cat', t.path .. '/local.txt'})).to_be('keep me')
  W.run({'rm', t.path .. '/local.txt'})
  local w = alice:hub('hub.spawn', {profile = 'shell', key = 'rm-safe-worker', cwd = t.path})
  expect_error(function() remove(bob, t.path, 'bob-busy') end, 'worker or terminal pane uses')
  alice:hub('hub.stop', {spawn_id = w.spawn_id})
  wait('the worker is gone', function()
    local ok = pcall(function() return remove(bob, t.path, 'bob-safe') end)
    return ok
  end, 20)
  expect(exists(t.path)).to_be(false)
end)

test('a pending create from an older version (no actor) completes; any agent removes the tree', function()
  local branch, key = 'rm/old-op', 'old-op'
  local path = W.root .. '/remove/' .. branch
  local common = W.real(repo .. '/.git')
  local state = W.catalog()
  state.pending[W.part('alice') .. W.part(key)] = {kind = 'create', fingerprint = 'create/' .. W.part(repo) .. W.part(branch) .. W.part(''),
    repo = repo, common = common, path = path, branch = branch, commit = W.git(repo, 'rev-parse', 'HEAD'), created = true, phase = 'prepared'}
  W.set_catalog(state)
  local t = create(alice, branch, key)
  expect(t.created).to_be(true)
  expect(exists(path)).to_be(true)
  expect(remove(bob, path, 'bob-rm-old-op').removed).to_be(true)
end)

test('after an identity migration the agent replays the keys of its legacy ID', function()
  local carol = agent('carol')
  local t = create(carol, 'rm/six', 'rm-six')
  expect(carol:report({kind = 'claude', conversation_id = 'conv-remove'}).identity).to_be('claude:conv-remove')
  -- An old key of the legacy ID finds its saved result.
  expect(create(carol, 'rm/six', 'rm-six').path).to_be(t.path)
  local removed = remove(carol, t.path, 'rm-six-rm')
  expect(removed.removed).to_be(true)
  expect(remove(carol, t.path, 'rm-six-rm')).to_equal(removed)
end)
