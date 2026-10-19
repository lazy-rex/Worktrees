-- Who may remove a worktree: the user removes any managed tree; an agent removes only a tree that
-- it created, while the tree at that path is the same tree. Ownership commits with the create
-- result and goes with a successful removal.
local W = load_fixture(H.args.file:match('^(.*)/[^/]*$') .. '/support/fixture.lua')
local repo = W.repo('owner')
local alice, bob = agent('alice'), agent('bob')

local function create(who, branch, key)
  return W.settle(function() return who:call('worktree.create', {repo = repo, branch = branch, key = key}) end)
end
local function remove(who, path, key)
  return W.settle(function() return who:call('worktree.remove', {path = path, key = key}) end)
end
local function owners() return (store('catalog').value or {}).owners or {} end
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

test('the creator removes its tree; the owner record goes with the tree', function()
  local t = create(alice, 'own/one', 'own-one')
  expect(t.created).to_be(true)
  expect(owners()[t.path].agent).to_be('alice')
  expect(remove(alice, t.path, 'own-one-rm').removed).to_be(true)
  expect(owners()[t.path]).to_be(nil)
  expect(exists(t.path)).to_be(false)
  -- The branch stays.
  expect(W.git(repo, 'branch', '--list', 'own/one')).to_match('own/one')
end)

test('another agent is refused; the user removes any tree through the form', function()
  local t = create(alice, 'own/two', 'own-two')
  expect_error(function() bob:call('worktree.remove', {path = t.path, key = 'bob-rm'}) end, 'only a worktree that it created')
  -- A refusal saves no operation and no pending entry: the same key can run later.
  expect(store('catalog').value.pending['3:bob6:bob-rm']).to_be(nil)
  local op = user_remove(t.path, 'user-rm-two')
  expect(op.status).to_be('succeeded')
  expect(exists(t.path)).to_be(false)
  expect(owners()[t.path]).to_be(nil)
end)

test('a create of an existing tree grants nothing', function()
  local t = create(alice, 'own/three', 'own-three')
  local again = create(bob, 'own/three', 'bob-three')
  expect(again.created).to_be(false)
  expect(owners()[t.path].agent).to_be('alice')
  expect_error(function() bob:call('worktree.remove', {path = t.path, key = 'bob-three-rm'}) end, 'only a worktree that it created')
  expect(remove(alice, t.path, 'own-three-rm').removed).to_be(true)
end)

test('a tree replaced outside the plugin is not the agent tree', function()
  local t = create(alice, 'own/four', 'own-four')
  W.git(repo, 'worktree', 'remove', t.path)
  W.git(repo, 'worktree', 'add', t.path, 'own/four')
  expect(owners()[t.path].agent).to_be('alice')
  expect_error(function() alice:call('worktree.remove', {path = t.path, key = 'own-four-rm'}) end, 'only a worktree that it created')
  expect(user_remove(t.path, 'user-rm-four').status).to_be('succeeded')
  expect(exists(t.path)).to_be(false)
end)

test('a replay of an old create after the removal does not restore ownership', function()
  local t = create(alice, 'own/five', 'own-five')
  expect(remove(alice, t.path, 'own-five-rm').removed).to_be(true)
  local replay = create(alice, 'own/five', 'own-five')
  expect(replay.created).to_be(true)
  expect(replay.path).to_be(t.path)
  expect(owners()[t.path]).to_be(nil)
  expect(exists(t.path)).to_be(false)
end)

test('a pending create from an older version (no actor) grants no ownership', function()
  local branch, key = 'own/legacy', 'legacy-op'
  local path = W.root .. '/owner/' .. branch
  local common = W.real(repo .. '/.git')
  local state = store('catalog').value
  state.pending[W.part('alice') .. W.part(key)] = {kind = 'create', fingerprint = 'create/' .. W.part(repo) .. W.part(branch) .. W.part(''),
    repo = repo, common = common, path = path, branch = branch, commit = W.git(repo, 'rev-parse', 'HEAD'), created = true, phase = 'prepared'}
  write({{key = 'catalog', value = state}})
  local t = create(alice, branch, key)
  expect(t.created).to_be(true)
  expect(exists(path)).to_be(true)
  expect(owners()[path]).to_be(nil)
  expect_error(function() alice:call('worktree.remove', {path = path, key = 'legacy-rm'}) end, 'only a worktree that it created')
  expect(user_remove(path, 'user-rm-legacy').status).to_be('succeeded')
end)

test('after an identity migration the agent removes the trees of its legacy ID', function()
  local carol = agent('carol')
  local t = create(carol, 'own/six', 'own-six')
  expect(owners()[t.path].agent).to_be('carol')
  expect(carol:report({kind = 'claude', conversation_id = 'conv-owner'}).identity).to_be('claude:conv-owner')
  -- An old key of the legacy ID finds its saved result.
  expect(create(carol, 'own/six', 'own-six').path).to_be(t.path)
  expect(remove(carol, t.path, 'own-six-rm').removed).to_be(true)
  -- A new create belongs to the new identity.
  local n = create(carol, 'own/seven', 'own-seven')
  expect(owners()[n.path].agent).to_be('claude:conv-owner')
  expect_error(function() alice:call('worktree.remove', {path = n.path, key = 'alice-seven'}) end, 'only a worktree that it created')
  expect(remove(carol, n.path, 'own-seven-rm').removed).to_be(true)
end)
