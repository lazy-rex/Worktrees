-- Long lists (sandbox, tests/support/sandbox.lua). Rex Lua fails table.concat of more than 2559
-- items with "registry overflow" (observed on Rex 0.0.1792158932-g88fd41; LazyRex
-- docs/rex-protocol.md). The SDK replaces table.concat with a concat that has no limit
-- (boot.lua; hub v0.4.1 and later), and the sandbox does the same. These lists can grow: a
-- tree row with its workers, the worker set of a refresh, the unattributed workers of Forget, the
-- workers of a refused remove, and the reasons of the removal advice (a view still has its 48 KiB guard).
local tests_dir = H.args.file:match('^(.*)/[^/]*$')
local load_sandbox = load_fixture(tests_dir .. '/support/sandbox.lua')
local base = getfenv(1)
local n = 3000
local tree = '/sandbox/worktrees/r/t'

-- sandbox: the recorded repository /r with the linked tree /sandbox/worktrees/r/t, and the
-- recorded repository /q, which Git cannot list.
local function sandbox()
  local s = load_sandbox(tests_dir .. '/..', base)
  assert_true(s.loaded, 'the plugin loads: ' .. tostring(s.load_error))
  local function ok(stdout) return {ok = true, stdout = stdout, stderr = ''} end
  s.exec_hook = function(argv)
    if argv[1] == 'git' and argv[2] == '--git-dir' and argv[4] == 'worktree' and argv[5] == 'list' then
      if argv[3] == '/q/.git' then return {ok = false, stdout = '', stderr = 'fatal: not a git repository'} end
      return ok(table.concat({'worktree /r', 'HEAD 0', 'branch refs/heads/main', '', 'worktree ' .. tree, 'HEAD 0', 'branch refs/heads/t', ''}, '\0') .. '\0')
    end
    if argv[1] == 'git' and argv[2] == '-C' and argv[4] == 'rev-parse' then
      if argv[5] == '--show-toplevel' then return ok(argv[3] .. '\n') end
      if argv[5] == '--absolute-git-dir' then return ok('/r/.git/worktrees/t\n') end
      return ok('/r/.git\n')
    end
    if argv[1] == 'stat' then return ok('1:2:3') end
    if argv[1] == 'test' then return ok('') end
  end
  s.start_hook = function() return nil, 'no fork' end
  s:set_catalog({repos = {['/r/.git'] = '/r', ['/q/.git'] = '/q'}, pending = {}})
  return s
end
local function workers(cwd)
  local list = {}
  for i = 1, n do list[i] = {spawn_id = 'w' .. i, cwd = cwd, state = 'running', title = 'w' .. i} end
  return list
end
local function node(tree_value, id)
  for _, x in ipairs(tree_value.nodes or {}) do if x.id == id then return x end end
end

test('a tree row with 3000 workers renders; its detail lists them in order', function()
  local s = sandbox()
  s.workers = workers(tree)
  s:tick()
  local reply = s:perform('view.render', {route = '/panels/worktrees'})
  assert_true(reply.result, 'the panel renders: ' .. show(reply.error))
  expect(node(reply.result.tree, 'refresh_error'), 'no refresh error').to_be(nil)
  local row
  for _, item in ipairs(node(reply.result.tree, 'worktrees').items) do if item.id == tree then row = item end end
  expect(row.detail:find(' · Workers: w1, w2, w3, ', 1, true) ~= nil, row.detail:sub(1, 200)).to_be(true)
end)

test('a worker change with 3000 workers refreshes without an error', function()
  local s = sandbox()
  s:tick()
  s.workers = workers('/elsewhere')
  s:perform('hub.changed', {what = 'workers'})
  s:tick()
  local reply = s:perform('view.render', {route = '/panels/worktrees'})
  assert_true(reply.result, 'the panel renders: ' .. show(reply.error))
  expect(node(reply.result.tree, 'refresh_error'), 'no refresh error').to_be(nil)
end)

test('Forget with 3000 unattributed workers asks for confirmation, then forgets', function()
  local s = sandbox()
  s:tick()
  s.workers = workers('/elsewhere')
  local reply = s:perform('worktree.forget', {repo = '/q', key = 'f'}, s.agent)
  expect(reply.error and reply.error.code, show(reply.error)).to_be('needs_confirmation')
  reply = s:perform('worktree.forget', {repo = '/q', key = 'f', accept_unattributed = true}, s.agent)
  assert_true(reply.result, 'forgotten: ' .. show(reply.error))
  expect(reply.result.unattributed_count).to_be(n)
end)

test('a remove that 3000 workers block is refused with their list', function()
  local s = sandbox()
  s:tick()
  local blockers = workers(tree)
  s.hub_answers['hub.cwd.lock'] = function() return {locked = false, workers = blockers} end
  local reply = s:perform('worktree.remove', {path = tree, key = 'r'}, s.agent)
  expect(reply.error and reply.error.code, show(reply.error)).to_be('refused')
  -- The error keeps the end of the list (4096 bytes), in order.
  expect(reply.error.message:sub(-#('w' .. (n - 1) .. ' · ' .. tree .. '\nw' .. n .. ' · ' .. tree))).to_be('w' .. (n - 1) .. ' · ' .. tree .. '\nw' .. n .. ' · ' .. tree)
end)

test('removal advice with 2600 workers joins every reason; the view guard refuses a view over 48 KiB', function()
  local route = '/forms/remove-worktree?path=' .. tree:gsub('/', '%%2F')
  local function advice(count)
    local s = sandbox()
    s:tick()
    local use = {}
    for i = 1, count do use[i] = {spawn_id = 'w' .. i, cwd = '/d'} end
    s.hub_answers['hub.cwd.check'] = function() return {available = false, workers = use} end
    s:perform('view.render', {route = route})
    s:tick()
    return s:perform('view.render', {route = route})
  end
  -- The reasons are joined (no registry overflow); 2600 of them do not fit one view.
  local reply = advice(2600)
  expect(reply.error and reply.error.code, show(reply.error)).to_be('too_large')
  -- 100 reasons fit: the text has each one, in order.
  reply = advice(100)
  assert_true(reply.result, 'the form renders: ' .. show(reply.error))
  local text = node(reply.result.tree, 'check').text
  local head = 'Removal will be refused:\nWorker: w1 · /d\nWorker: w2 · /d\n'
  expect(text:sub(1, #head)).to_be(head)
  expect(text:sub(-#'Worker: w99 · /d\nWorker: w100 · /d')).to_be('Worker: w99 · /d\nWorker: w100 · /d')
end)
