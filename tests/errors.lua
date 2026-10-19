-- A hub refusal is a final failure with the hub's code and message. It must not become
-- "unavailable": the hub retries such a view operation, and an operation that never ends holds
-- every later operation of this plugin in the hub's queue.
local W = load_fixture(H.args.file:match('^(.*)/[^/]*$') .. '/support/fixture.lua')
local repo = W.repo('errors')
local alice = agent('alice')

local function create(branch, key)
  return W.settle(function() return alice:call('worktree.create', {repo = repo, branch = branch, key = key}) end)
end
local function menu(path)
  user:command('worktrees')
  local panel = user:view('/panels/worktrees')
  panel:render()
  expect(panel:action('worktrees', 'select', {item_id = path}).status).to_be('succeeded')
  local m = user:view(W.route('/forms/worktree', path))
  m:render()
  return m
end

-- The plugin knows the tree from its last scan; the directory goes away outside Git, so the
-- plugin's checks pass and hub.spawn refuses the directory.
local gone = create('errors/gone', 'gone')
local kept = create('errors/kept', 'kept')
local gone_tool = create('errors/gone-tool', 'gone-tool')
wait('the scan lists the three trees', function()
  local n = 0
  for _, t in ipairs(alice:call('worktree.list', {}).worktrees or {}) do
    if (t.path == gone.path or t.path == kept.path or t.path == gone_tool.path) and t.state == 'clean' then n = n + 1 end
  end
  return n == 3
end, 20)

test('tool: a refused spawn is the hub code, not unavailable', function()
  W.run({'rm', '-rf', gone_tool.path})
  local e = expect_error(function() alice:call('worktree.open', {path = gone_tool.path, key = 'refused-tool'}) end)
  expect(e.code).not_to_be('unavailable')
  expect(tostring(e)).to_match('not an existing directory')
end)

test('view: a refused spawn fails the operation with the hub code; the next operation runs', function()
  local m = menu(gone.path)
  W.run({'rm', '-rf', gone.path})
  local op = m:action('worktree_menu', 'run', {item_id = 'open_tab'}, 'refused-open')
  expect(op.status).to_be('failed')
  expect(op.error.code).to_be('refused')
  expect(op.error.message).to_match('not an existing directory')
  local next_op = menu(kept.path):action('worktree_menu', 'run', {item_id = 'open_tab'}, 'next-open')
  expect(next_op.status).to_be('succeeded')
end)

