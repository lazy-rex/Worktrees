-- Ignored files and worktree.remove (decision "LazyRex worktree remove refuses ignored files unless
-- accept ignored is set", the user, 2026-10-22). By default ignored files refuse removal. With
-- accept_ignored = true the plugin runs plain git worktree remove (no --force): Git deletes the
-- ignored files with the tree and still refuses changes and untracked files (observed on Git 2.54.0).
-- accept_ignored = true is part of the request content; omitted or false keeps the earlier one.
local W = load_fixture(H.args.file:match('^(.*)/[^/]*$') .. '/support/fixture.lua')
local repo = W.repo('ignored')
W.write(repo .. '/.gitignore', 'log/\n')
W.git(repo, 'add', '.gitignore')
W.git(repo, 'commit', '-q', '-m', 'ignore log')
local alice = agent('alice')

local function create(branch)
  return W.settle(function() return alice:call('worktree.create', {repo = repo, branch = branch, key = 'c-' .. branch}) end).path
end
local function remove(path, key, accept)
  return W.settle(function() return alice:call('worktree.remove', {path = path, key = key, accept_ignored = accept}) end)
end
local function exists(path) return W.try({'test', '-e', path}).ok end
local function with_log(path)
  W.run({'mkdir', '-p', path .. '/log'})
  W.write(path .. '/log/dev.log', 'old log\n')
end

test('ignored files refuse removal by default; the refusal names accept_ignored and keeps the files', function()
  local path = create('ign/strict')
  with_log(path)
  local err = expect_error(function() remove(path, 'strict') end, 'refused')
  expect(tostring(err.message)).to_match('ignored files')
  expect(tostring(err.message)).to_match('accept_ignored = true')
  expect(tostring(err.message)).to_match('Also delete ignored files')
  -- false is the default.
  expect_error(function() remove(path, 'strict-false', false) end, 'ignored files')
  expect(W.run({'cat', path .. '/log/dev.log'})).to_be('old log')
end)

test('accept_ignored deletes a tree with only ignored files; the branch stays; the key replays', function()
  local path = create('ign/accept')
  with_log(path)
  local removed = remove(path, 'accept', true)
  expect(removed.removed).to_be(true)
  expect(exists(path)).to_be(false)
  expect(W.git(repo, 'branch', '--list', 'ign/accept')).to_match('ign/accept')
  expect(remove(path, 'accept', true)).to_equal(removed)
end)

test('accept_ignored still refuses an untracked file and a tracked change, and keeps them', function()
  local path = create('ign/dirty')
  with_log(path)
  W.write(path .. '/new.txt', 'work\n')
  expect_error(function() remove(path, 'dirty-untracked', true) end, 'changes or untracked files')
  expect(W.run({'cat', path .. '/new.txt'})).to_be('work')
  W.run({'rm', path .. '/new.txt'})
  W.write(path .. '/file.txt', 'changed\n')
  expect_error(function() remove(path, 'dirty-tracked', true) end, 'changes or untracked files')
  expect(W.run({'cat', path .. '/file.txt'})).to_be('changed')
  expect(W.run({'cat', path .. '/log/dev.log'})).to_be('old log')
end)

test('accept_ignored is part of the key: a changed value conflicts; false and omitted are the same request', function()
  local path = create('ign/key')
  with_log(path)
  expect_error(function() remove(path, 'key-1') end, 'ignored files')
  expect_error(function() remove(path, 'key-1', true) end, 'operation_conflict')
  -- The saved refusal replays for false as for omitted.
  expect_error(function() remove(path, 'key-1', false) end, 'ignored files')
  expect_error(function() alice:call('worktree.remove', {path = path, key = 'key-2', accept_ignored = 'yes'}) end, 'must be boolean')
  -- A saved result of an earlier version (the fingerprint without the option) replays.
  local id = W.part('alice') .. W.part('key-old')
  W.put_op(id, 'remove/' .. W.part(path), {path = path, removed = true})
  expect(remove(path, 'key-old').removed).to_be(true)
  expect(remove(path, 'key-old', false).removed).to_be(true)
  expect_error(function() remove(path, 'key-old', true) end, 'operation_conflict')
  expect(exists(path)).to_be(true)
end)

test('a pending remove with accept_ignored keeps it across a crash restart', function()
  local path = create('ign/restart')
  with_log(path)
  local args = {path = path, key = 'restart', accept_ignored = true}
  expect(alice:call('worktree.remove', args).status).to_be('running')
  local op = (W.catalog().pending or {})[W.part('alice') .. W.part('restart')]
  expect(op.accept_ignored).to_be(true)
  hub:restart({crash = true})
  expect(W.settle(function() return alice:call('worktree.remove', args) end).removed).to_be(true)
  expect(exists(path)).to_be(false)
end)

test('the Remove form: the advice says that ignored files are deleted only with the checkbox; on, it removes the tree', function()
  local path = create('ign/form')
  with_log(path)
  user:command('remove_worktree')
  local picker = user:view('/forms/remove-worktree')
  picker:render()
  expect(picker:action('remove_pick', 'select', {item_id = path}).status).to_be('succeeded')
  local form = user:view(W.route('/forms/remove-worktree', path))
  local tree = form:render()
  local fields = node(tree, 'remove_worktree').fields
  expect(fields[2].id).to_be('accept_ignored')
  expect(fields[2].label).to_be('Also delete ignored files')
  expect(fields[2].value).to_be(false)
  local text = wait('the removal check ends', function()
    local check = node(form:render(), 'check')
    local t = check and check.text or ''
    return t ~= '' and not t:find('Checking', 1, true) and t
  end, 20)
  expect(text).to_match('Also delete ignored files is on')
  -- Off: refused, the files stay.
  local off = form:action('remove_worktree', 'submit', {values = {path = path, accept_ignored = false}}, 'form-off')
  expect(off.status).to_be('failed')
  expect(exists(path .. '/log/dev.log')).to_be(true)
  -- On: removed.
  local on = form:action('remove_worktree', 'submit', {values = {path = path, accept_ignored = true}}, 'form-on')
  expect(on.status).to_be('succeeded')
  expect(exists(path)).to_be(false)
end)
