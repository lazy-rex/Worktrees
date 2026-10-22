-- The forms on app.form (sandbox, tests/support/sandbox.lua). The SDK finds a clicked item in the
-- nodes that it builds again at the click, so a list that changed after the render must not lose
-- the click.
local tests_dir = H.args.file:match('^(.*)/[^/]*$')
local load_sandbox = load_fixture(tests_dir .. '/support/sandbox.lua')
local base = getfenv(1)
local tree = '/sandbox/worktrees/r/t'

-- sandbox: the recorded repository /r; state.linked says whether Git lists the tree /sandbox/worktrees/r/t.
local function sandbox(state)
  local s = load_sandbox(tests_dir .. '/..', base)
  assert_true(s.loaded, 'the plugin loads: ' .. tostring(s.load_error))
  local function ok(stdout) return {ok = true, stdout = stdout, stderr = ''} end
  s.exec_hook = function(argv)
    if argv[1] == 'git' and argv[2] == '--git-dir' and argv[4] == 'worktree' and argv[5] == 'list' then
      local list = {'worktree /r', 'HEAD 0', 'branch refs/heads/main', ''}
      if state.linked then for _, l in ipairs({'worktree ' .. tree, 'HEAD 0', 'branch refs/heads/t', ''}) do list[#list + 1] = l end end
      return ok(table.concat(list, '\0') .. '\0')
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
  s.catalog = {repos = {['/r/.git'] = '/r'}, pending = {}}
  return s
end
local function node(t, id)
  for _, x in ipairs(t.nodes or {}) do if x.id == id then return x end end
end

test('Remove picker: a tree that left the list after the render still opens its confirmation', function()
  local state = {linked = true}
  local s = sandbox(state)
  s:tick()
  local reply = s:perform('view.render', {route = '/forms/remove-worktree'})
  local pick = node(reply.result.tree, 'remove_pick')
  expect(pick and pick.items[1].id, show(reply)).to_be(tree)
  -- A refresh before the click: Git no longer lists the tree.
  state.linked = false
  s:perform('view.action', {route = '/panels/worktrees', node_id = 'refresh', action = 'refresh', input = {}})
  s:tick()
  reply = s:perform('view.action', {route = '/forms/remove-worktree', node_id = 'remove_pick', action = 'select', input = {item_id = tree}, operation_key = 'pick'})
  expect(reply.result and reply.result.form, show(reply)).to_be('/forms/remove-worktree?path=%2Fsandbox%2Fworktrees%2Fr%2Ft')
  -- The confirmation checks the tree.
  reply = s:perform('view.render', {route = reply.result.form})
  expect(node(reply.result.tree, 'about').text).to_be('This worktree cannot be removed: ' .. tree)
end)

-- The SDK builds the title, the nodes and the fields again at the submit, before the submit code.
-- After a remove, the tree is gone: a same-key retry of the submit still reaches the saved result.
test('Remove confirmation: a same-key retry after the tree is gone replays the saved result', function()
  local state = {linked = false}
  local s = sandbox(state)
  s:tick()
  local function part(v) return #v .. ':' .. v end
  sql_write('INSERT INTO ops (key, fingerprint, result) VALUES (?, ?, ?)',
    {part('user') .. part('rm'), 'remove/' .. part(tree), rex.json.encode({path = tree, removed = true})})
  local route = '/forms/remove-worktree?path=%2Fsandbox%2Fworktrees%2Fr%2Ft'
  local reply = s:perform('view.action', {route = route, node_id = 'remove_worktree', action = 'submit', input = {values = {path = tree}}, operation_key = 'rm'})
  expect(reply.result and reply.result.removed, show(reply)).to_be(true)
  expect(reply.result.close_form).to_be(true)
end)
