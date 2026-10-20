-- The plugin's git status never writes the index of a tree (git --no-optional-locks status). A plain
-- git status writes a refreshed index when the stat data of a tracked file changed, and holds
-- index.lock while it writes: a git commit or git add of the user in that tree then fails with
-- "index.lock: File exists" (Git: git-status, "Background refresh"). Observed on Git 2.54.0: a
-- plain git status after a touch gave the index a new inode; with --no-optional-locks, no change.
local W = load_fixture(H.args.file:match('^(.*)/[^/]*$') .. '/support/fixture.lua')
local repo = W.repo('locks')
local alice = agent('alice')

local function create(branch, key)
  return W.settle(function() return alice:call('worktree.create', {repo = repo, branch = branch, key = key}) end)
end
local function bytes(path)
  local f = assert(io.open(path, 'rb'))
  local value = f:read('*a')
  f:close()
  return value
end
-- stale waits until the earlier scans end (the create starts one), then makes the index stat data
-- of file.txt stale without a content change. It returns the path of the tree's index and its
-- bytes after the change.
local function stale(tree)
  -- A first page starts a scan when none runs, so wait for each list on its own.
  for _, args in ipairs({{}, {repo = repo}}) do
    wait('the earlier scans end', function() return not alice:call('worktree.list', args).refreshing end, 30)
  end
  local index = W.run({'git', '-C', tree, 'rev-parse', '--path-format=absolute', '--git-path', 'index'})
  -- One second later, so that the new mtime differs from the one in the index.
  rex.sleep(1.1)
  W.run({'touch', tree .. '/file.txt'})
  return index, bytes(index)
end

test('the scan does not write the index; the tree is clean', function()
  local tree = create('locks/scan', 'scan').path
  local index, before = stale(tree)
  local row
  wait('the scan of the tree ends', function()
    local r = alice:call('worktree.list', {repo = repo})
    for _, t in ipairs(r.worktrees or {}) do if t.path == tree then row = t end end
    return not r.refreshing and row and row.state ~= 'checking'
  end, 30)
  expect(row.state).to_be('clean')
  expect(bytes(index) == before, 'the index is unchanged').to_be(true)
end)

test('the status check of a removal does not write the index; the removal is refused for an untracked file', function()
  local tree = create('locks/remove', 'remove').path
  W.write(tree .. '/untracked.txt', 'x\n')
  local index, before = stale(tree)
  local err = expect_error(function()
    W.settle(function() return alice:call('worktree.remove', {path = tree, key = 'remove-1'}) end)
  end, 'refused')
  expect(tostring(err.message)).to_match('changes or ignored files')
  expect(bytes(index) == before, 'the index is unchanged').to_be(true)
end)

test('the removal advice does not write the index; it shows the untracked file', function()
  local tree = create('locks/advice', 'advice').path
  W.write(tree .. '/untracked.txt', 'x\n')
  local index, before = stale(tree)
  user:command('remove_worktree')
  user:view('/forms/remove-worktree'):render()
  local op = user:view('/forms/remove-worktree'):action('remove_pick', 'select', {item_id = tree})
  expect(op.status).to_be('succeeded')
  local form = user:view(W.route('/forms/remove-worktree', tree))
  form:seen('focus')
  local text
  wait('the removal check ends', function()
    local check = node(form:render(), 'check')
    text = check and check.text or ''
    return text ~= '' and not text:find('Checking', 1, true)
  end, 20)
  expect(text).to_match('changes or ignored files')
  expect(bytes(index) == before, 'the index is unchanged').to_be(true)
end)
