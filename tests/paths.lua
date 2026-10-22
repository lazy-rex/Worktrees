-- Tree paths (decision "New worktree paths carry a short repository ID"): a new tree goes in
-- <root>/<name>-<id>/<branch>, with a 6-hex ID from the common Git directory path. A linked tree of
-- the branch inside the root is the requested tree, also at an older path. The main tree is never
-- reused. A listed tree with a missing directory is refused.
local W = load_fixture(H.args.file:match('^(.*)/[^/]*$') .. '/support/fixture.lua')
local alice = agent('alice')

local function create(repo, branch, key)
  return W.settle(function() return alice:call('worktree.create', {repo = repo, branch = branch, key = key}) end)
end
local function exists(path) return W.try({'test', '-e', path}).ok end
-- adds counts the git worktree add processes in the lab (GIT_TRACE, set in the manifest test.env).
local function adds()
  local f = io.open(H.args.lab .. '/git-trace.log', 'r')
  if not f then return 0 end
  local n = 0
  for l in f:lines() do if l:find('trace: built-in: git worktree add', 1, true) then n = n + 1 end end
  f:close()
  return n
end
-- repo_at makes a repository with one commit in dir and returns its real path.
local function repo_at(dir)
  W.run({'mkdir', '-p', dir})
  W.run({'git', 'init', '-q', '-b', 'main', dir})
  W.write(dir .. '/file.txt', 'one\n')
  W.git(dir, 'add', 'file.txt')
  W.git(dir, 'commit', '-q', '-m', 'one')
  return W.real(dir)
end
local function pending_count()
  local n = 0
  for _ in pairs(W.catalog().pending or {}) do n = n + 1 end
  return n
end

test('the repository ID: a fixed test vector', function()
  expect(W.repo_id('/repo/.git')).to_be('ffa677')
  expect(W.repo_id('/Users/lab/one/app/.git')).to_be('7477a4')
end)

test('two repositories with the same directory name and the same branch get different trees', function()
  local one = repo_at(H.args.lab .. '/repos/one/app')
  local two = repo_at(H.args.lab .. '/repos/two/app')
  local a, b = create(one, 'x', 'one-x'), create(two, 'x', 'two-x')
  expect(a.created).to_be(true)
  expect(b.created).to_be(true)
  expect(a.path).to_be(W.tree_path(one, 'x'))
  expect(b.path).to_be(W.tree_path(two, 'x'))
  expect(a.path ~= b.path, 'different paths').to_be(true)
  expect(a.path).to_contain(W.root .. '/app-')
  expect(W.git(a.path, 'rev-parse', '--path-format=absolute', '--git-common-dir')).to_contain('/one/app/.git')
  expect(W.git(b.path, 'rev-parse', '--path-format=absolute', '--git-common-dir')).to_contain('/two/app/.git')
end)

test('a linked tree of the branch at the old path layout is found; Git starts no worktree add', function()
  local repo = W.repo('legacy')
  local old = W.root .. '/legacy/old'
  W.run({'mkdir', '-p', W.root .. '/legacy'})
  W.git(repo, 'worktree', 'add', '-q', '-b', 'old', old)
  local before = adds()
  local r = create(repo, 'old', 'legacy-old')
  expect(r).to_equal({path = old, repo = repo, branch = 'old', created = false})
  expect(adds(), 'no git worktree add').to_be(before)
  expect(exists(W.tree_path(repo, 'old')), 'no tree at the new path').to_be(false)
end)

test('the main tree is never reused, also inside the root', function()
  local inside = repo_at(W.root .. '/inside')
  local new = W.tree_path(inside, 'main')
  local err = expect_error(function() create(inside, 'main', 'inside-main') end, 'git_error')
  expect(err.message).to_contain('main')
  expect(exists(new), 'no tree at the new path').to_be(false)
  expect(W.git(inside, 'branch', '--show-current')).to_be('main')
end)

test('a listed tree with a missing directory is refused, also when it is locked; no tree appears', function()
  local repo = W.repo('stale')
  W.run({'mkdir', '-p', W.root .. '/stale'})
  for _, branch in ipairs({'gone', 'held'}) do
    local old = W.root .. '/stale/' .. branch
    W.git(repo, 'worktree', 'add', '-q', '-b', branch, old)
    if branch == 'held' then W.git(repo, 'worktree', 'lock', old) end
    W.run({'rm', '-rf', old})
    local rev, pending, before = W.records(), pending_count(), adds()
    local err = expect_error(function() create(repo, branch, 'stale-' .. branch) end, 'refused')
    expect(err.message).to_contain(old)
    expect(err.message).to_contain('missing')
    expect(adds(), 'no git worktree add').to_be(before)
    expect(pending_count(), 'no pending operation').to_be(pending)
    expect(W.records(), 'no catalog write').to_be(rev)
    expect(exists(old), 'no tree at the old path').to_be(false)
    expect(exists(W.tree_path(repo, branch)), 'no tree at the new path').to_be(false)
  end
end)
