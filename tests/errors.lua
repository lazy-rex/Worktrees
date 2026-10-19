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


-- hub(): an error text without a code, or with unavailable, disconnected or timeout, stays
-- unavailable, so the hub retries it. No lab fault makes an error without a code, so these tests
-- run the plugin in a sandbox (tests/support/sandbox.lua). The texts have the shape that Rex
-- 0.0.1792158932-g88fd41 gave in the lab for a hub error.
local tests_dir = H.args.file:match('^(.*)/[^/]*$')
local load_sandbox = load_fixture(tests_dir .. '/support/sandbox.lua')
local base = getfenv(1)
local function hub_text(message, status, code)
  return 'stream response "control-15" failed: ' .. message .. (code and (' (status=' .. status .. ' code=' .. code .. ')') or '')
end
local function workers_error(text)
  local s = load_sandbox(tests_dir .. '/..', base)
  assert_true(s.loaded, 'the plugin loads: ' .. tostring(s.load_error))
  s.hub_errors['hub.workers'] = text
  local reply = s:perform('hub.changed', {what = 'workers'})
  assert_true(reply and reply.error, 'hub.changed fails')
  return reply.error
end

test('a hub error without a code, or with timeout, disconnected or unavailable, stays unavailable (sandbox)', function()
  for _, text in ipairs({hub_text('connection reset'), hub_text('deadline', 504, 'timeout'),
      hub_text('gone', 503, 'disconnected'), hub_text('busy', 503, 'unavailable')}) do
    local e = workers_error(text)
    expect(e.code, text).to_be('unavailable')
    expect(e.message, text).to_be(text)
  end
end)

test('a hub error with another code keeps that code and the message without the transport prefix (sandbox)', function()
  local e = workers_error(hub_text('no such agent', 404, 'not_found'))
  expect(e.code).to_be('not_found')
  expect(e.message).to_be('no such agent')
end)
