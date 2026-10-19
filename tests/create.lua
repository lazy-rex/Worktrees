-- Create, list and remove with real Git and the real hub (ported from worktrees.mjs; coverage map
-- in the port commit). Workers and panes are real lab workers and panes.
local W = load_fixture(H.args.file:match('^(.*)/[^/]*$') .. '/support/fixture.lua')
local lab = H.args.lab
-- A repository name with spaces and an ignored file.
local repo_dir = lab .. '/repos/repo with spaces'
W.run({'mkdir', '-p', repo_dir})
W.run({'git', 'init', '-q', '-b', 'main', repo_dir})
W.write(repo_dir .. '/tracked.txt', 'initial\n')
W.write(repo_dir .. '/.gitignore', 'ignored.tmp\n')
W.git(repo_dir, 'add', '.')
W.git(repo_dir, 'commit', '-q', '-m', 'initial')
local repo = W.real(repo_dir)
local alice = agent('alice')

write_profiles({profiles = {{id = 'sleep', name = 'Sleep', kind = 'accessory', command = {'/bin/sleep', '600'}}}})

local function create(key, branch, extra)
  local args = {key = key, repo = repo, branch = branch}
  for k, v in pairs(extra or {}) do args[k] = v end
  return W.settle(function() return alice:call('worktree.create', args) end)
end
local function remove(key, path)
  return W.settle(function() return alice:call('worktree.remove', {key = key, path = path}) end)
end
local function list(args, predicate)
  local result
  wait('the worktree list', function()
    result = alice:call('worktree.list', args or {})
    return predicate(result.worktrees or {})
  end, 30)
  return result
end
local function row(rows, path) for _, t in ipairs(rows) do if t.path == path then return t end end end
-- advice opens the remove confirmation for path and returns its check text when the check ends:
-- '' when removal can go ahead. The plugin asks hub.cwd.check (workers, panes and locks).
local function advice(path)
  user:command('remove_worktree')
  user:view('/forms/remove-worktree'):render()
  local op = user:view('/forms/remove-worktree'):action('remove_pick', 'select', {item_id = path})
  expect(op.status).to_be('succeeded')
  local form = user:view(W.route('/forms/remove-worktree', path))
  -- Focus refreshes the advice, as the renderer reports it; the advice is cached until a refresh.
  form:seen('focus')
  local text
  wait('the removal check ends', function()
    local check = node(form:render(), 'check')
    text = check and check.text or ''
    return not text:find('Checking')
  end, 20)
  return text
end
local function locked(path) return advice(path) ~= '' end
local function exists(path) return W.try({'test', '-e', path}).ok end

local first

test('create returns the tree, replays its key, and finds an existing tree', function()
  first = create('first', 'feature/one')
  expect(first).to_equal({path = W.root .. '/repo with spaces/feature/one', repo = repo, branch = 'feature/one', created = true})
  expect(create('first', 'feature/one')).to_equal(first)
  expect(create('existing', 'feature/one').created).to_be(false)
  -- base applies only to a new branch, so a bad base does not matter for an existing tree.
  expect(create('existing-base', 'feature/one', {base = 'missing-base'}).created).to_be(false)
  expect_error(function() create('first', 'feature/two') end, 'different content')
  expect_error(function() create('invalid', '../escape') end, 'Invalid Git branch')
  expect(W.git(first.path, 'branch', '--show-current')).to_be('feature/one')
end)

test('list shows the tree as clean, then dirty', function()
  local l = list({}, function(rows) local t = row(rows, first.path); return t and t.state == 'clean' end)
  expect(row(l.worktrees, first.path).repo).to_be(repo)
  expect(l.root).to_be(W.root)
  W.write(first.path .. '/dirty.txt', 'x')
  list({repo = repo}, function(rows) local t = row(rows, first.path); return t and t.state == 'dirty' end)
  W.run({'rm', first.path .. '/dirty.txt'})
  list({repo = repo}, function(rows) local t = row(rows, first.path); return t and t.state == 'clean' end)
end)

test('the default base is HEAD of the selected worktree, not of the main tree', function()
  local linked_source = create('linked-source', 'forms/source')
  W.git(linked_source.path, 'commit', '--allow-empty', '-q', '-m', 'source worktree commit')
  local head = W.git(linked_source.path, 'rev-parse', 'HEAD')
  expect(head).not_to_be(W.git(repo, 'rev-parse', 'HEAD'))
  local linked = W.settle(function() return alice:call('worktree.create', {key = 'from-linked', repo = linked_source.path, branch = 'forms/from-linked'}) end)
  expect(W.git(linked.path, 'rev-parse', 'HEAD')).to_be(head)
  expect(remove('remove-linked', linked.path).removed).to_be(true)
  expect(remove('remove-linked-source', linked_source.path).removed).to_be(true)
end)

test('a worker in the tree blocks removal and shows in the list; no lock stays', function()
  local w = alice:hub('hub.spawn', {profile = 'sleep', key = 'busy-worker', cwd = first.path .. '/'})
  local l = list({repo = repo}, function(rows) local t = row(rows, first.path); return t and #t.workers > 0 end)
  expect(row(l.worktrees, first.path).workers[1].spawn_id).to_be(w.spawn_id)
  expect_error(function() remove('busy', first.path) end, 'worker or terminal pane uses')
  expect(advice(first.path):find('Worker: ' .. w.spawn_id, 1, true) ~= nil).to_be(true)
  alice:hub('hub.stop', {spawn_id = w.spawn_id})
  wait('the worker is gone', function() return not locked(first.path) end, 20)
end)

test('a terminal pane in the tree blocks removal', function()
  local s = session('create-pane')
  local b = rex.call('session.new_block', {session_id = s, flavor = 'com.superlogical.terminal.shell',
    options = {command = {'/bin/sleep', '600'}, cwd = first.path, login = false}})
  wait('the hub sees the pane', function() return advice(first.path):find('Terminal:') ~= nil end, 20)
  expect_error(function() remove('pane', first.path) end, 'worker or terminal pane uses')
  close_session(s)
  wait('the pane is gone', function() return not locked(first.path) end, 20)
end)

test('changes or ignored files refuse removal and keep the files', function()
  W.write(first.path .. '/local.txt', 'keep me')
  expect_error(function() remove('dirty', first.path) end, 'changes or ignored')
  expect(W.run({'cat', first.path .. '/local.txt'})).to_be('keep me')
  W.run({'rm', first.path .. '/local.txt'})
  W.write(first.path .. '/ignored.tmp', 'keep ignored')
  expect_error(function() remove('ignored', first.path) end, 'changes or ignored')
  W.run({'rm', first.path .. '/ignored.tmp'})
  -- The refusals hold no lock: the check is clear again.
  expect(advice(first.path)).to_be('')
end)

test('a clean tree is removed, the key replays, and the branch stays', function()
  local removed = remove('remove', first.path)
  expect(removed.removed).to_be(true)
  expect(remove('remove', first.path)).to_equal(removed)
  expect(exists(first.path)).to_be(false)
  expect(W.git(repo, 'show-ref', 'refs/heads/feature/one')).to_match('feature/one')
  -- No lock stays: the same path is created and removed again (removal takes the cwd lock).
  local again = create('again', 'feature/one')
  expect(again.created).to_be(true)
  expect(remove('again-remove', again.path).removed).to_be(true)
end)

test('the main repository, a relative path and a symbolic link parent are refused', function()
  expect_error(function() remove('main', repo) end, 'managed root')
  expect_error(function() remove('relative', '-bad') end, 'must be absolute')
  W.run({'mkdir', '-p', W.root .. '/repo with spaces'})
  W.run({'ln', '-s', lab, W.root .. '/repo with spaces/escape'})
  expect_error(function() create('symlink-parent', 'escape/child') end, 'symbolic link')
  -- The refused create stays pending until it is discarded; then its key returns the discard.
  local id = W.part('alice') .. W.part('symlink-parent')
  expect(store('catalog').value.pending[id] ~= nil).to_be(true)
  expect(alice:call('worktree.discard', {operation = 'symlink-parent', key = 'discard-symlink'}).discarded).to_be(true)
  expect(create('symlink-parent', 'escape/child').status).to_be('discarded')
  expect(exists(lab .. '/child')).to_be(false)
end)
