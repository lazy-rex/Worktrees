-- The plugin contract on the real hub (ported from worktrees.mjs; coverage map in the port
-- commit). The exports reach the agent face; only the hub may forward a call or call view.*; a
-- caller outside every pane is refused; the plugin declares no tab.

local exports = {'worktree.create', 'worktree.list', 'worktree.remove', 'worktree.open', 'worktree.discard'}

local function client(label)
  local r = rex.call('target.resolve', {kinds = {'client'}, queries = {label}})
  local x = r and r.results and r.results[1]
  if not x or x.status ~= 'resolved' then error('cannot resolve client ' .. label, 0) end
  return x.target.client_id
end

local alice = agent('alice')

test('the agent face lists every export, and the plugin registered with its label', function()
  local face = rex.call('client.inspect', {client_id = client('lazyrex')})
  local names = {}
  for _, a in ipairs(face.actions) do names[a.name] = a end
  for _, e in ipairs(exports) do expect(names[e] ~= nil, e).to_be(true) end
  expect(names['view.render'], 'view actions are not exported').to_be(nil)
  expect(names['hub.forward'], 'hub.forward is not exported').to_be(nil)
  local plugin = rex.call('client.inspect', {client_id = client('lazyrex-plugin:worktrees')})
  local own = {}
  for _, a in ipairs(plugin.actions) do own[#own + 1] = a.name end
  for _, e in ipairs(exports) do expect(own).to_contain(e) end
end)

test('the export schemas require a key for every change', function()
  local plugin = rex.call('client.inspect', {client_id = client('lazyrex-plugin:worktrees')})
  local required = {}
  for _, a in ipairs(plugin.actions) do required[a.name] = a.args and a.args.required or {} end
  expect(required['worktree.create']).to_equal({'repo', 'branch', 'key'})
  expect(required['worktree.remove']).to_equal({'path', 'key'})
  expect(required['worktree.open']).to_equal({'path', 'key'})
  -- discard names its target with exactly one of operation or id (the plugin checks it).
  expect(required['worktree.discard']).to_equal({'key'})
end)

test('only the hub may call hub.forward or view.*', function()
  local args = {action = 'worktree.list', args = {}, requester_pid = alice.pid}
  expect_error(function() alice:direct('hub.forward', args) end, 'Only the hub')
  expect_error(function() H.perform(client('lazyrex-plugin:worktrees'), 'hub.forward', args) end, 'Only the hub')
  expect_error(function() alice:direct('view.render', {route = '/panels/worktrees', user = 'user'}) end, 'Only the hub')
  expect_error(function() user:plugin_view('action', {route = '/panels/worktrees', user = 'user', node_id = 'refresh', action = 'refresh'}) end, 'Only the hub')
end)

test('the agent face refuses an action that the plugin does not export', function()
  expect_error(function() alice:call('view.render', {route = '/panels/worktrees', user = 'user'}) end, 'view.render')
end)

test('a caller outside every pane is refused', function()
  expect_error(function() H.perform(client('lazyrex-plugin:worktrees'), 'worktree.list', {}) end, 'does not recognize')
end)

test('the plugin declares no tab', function()
  expect(tabs()).to_equal({})
end)

test('the plugin installs no repeating timer (scans arm one-shot rex.after timers only)', function()
  local f = assert(io.open(H.args.file:match('^(.*)/tests/[^/]*$') .. '/worktrees.lua', 'r'))
  local source = f:read('*a')
  f:close()
  expect(source:find('rex.every', 1, true)).to_be(nil)
end)
