-- Startup (sandbox, tests/support/sandbox.lua): the startup work runs after the main chunk, so the
-- main chunk runs no pcall. start() completes or fails with the catalog error and stays incomplete.
-- Each handler calls it first: a failed startup read fails the action with that error, and the
-- handler does nothing. The SDK identifies an agent (hub.identify, a read) before the handler runs. After a successful read, each pending cleanup runs once, then one refresh.
local tests_dir = H.args.file:match('^(.*)/[^/]*$')
local load_sandbox = load_fixture(tests_dir .. '/support/sandbox.lua')
local base = getfenv(1)
-- The hub error text has the shape that Rex gives (errors.lua): the code and the message are kept.
local store_down = 'stream response "c" failed: store down (status=503 code=busy)'
local id = '5:alice3:old'

-- sandbox loads the plugin with one remove operation in phase cleanup. Its unlock and its catalog
-- write are hub actions (s.calls, s.order). reads.fail is the number of hub.store.get calls that
-- fail from now on (a table field: the callback writes no captured local).
local function sandbox()
  local s = load_sandbox(tests_dir .. '/..', base)
  assert_true(s.loaded, 'the plugin loads: ' .. tostring(s.load_error))
  s.catalog = {repos = {}, pending = {[id] = {kind = 'remove', phase = 'cleanup', path = '/sandbox/worktrees/r/t', fingerprint = 'f'}}}
  s.hub_answers['hub.store.batch'] = function(args) s.catalog = args.ops[1].value; return {revs = {catalog = '2'}} end
  s.reads = {fail = 0}
  s.on_hub['hub.store.get'] = function()
    s.hub_errors['hub.store.get'] = s.reads.fail > 0 and store_down or nil
    if s.reads.fail > 0 then s.reads.fail = s.reads.fail - 1 end
  end
  return s
end
local function count(s, action) return s.calls[action] or 0 end
local function index(s, action)
  for i, name in ipairs(s.order) do if name == action then return i end end
end
local function list(s) return s:perform('worktree.list', {}, s.agent) end
local function expect_store_down(reply)
  expect(reply.error and reply.error.code).to_be('busy')
  expect(reply.error.message).to_be('store down')
end

test('the main chunk runs no pcall; the startup timer runs the cleanup, then one refresh', function()
  local s = sandbox()
  expect(s.load_pcalls, 'no pcall during the load').to_be(0)
  expect(count(s, 'hub.store.get'), 'no catalog read during the load').to_be(0)
  s:tick()
  expect(count(s, 'hub.cwd.unlock')).to_be(1)
  expect(s.catalog.pending[id], 'the cleanup deleted the operation').to_be(nil)
  expect(count(s, 'hub.workers'), 'one refresh').to_be(1)
  expect(list(s).result ~= nil).to_be(true)
  expect(count(s, 'hub.cwd.unlock'), 'no second cleanup').to_be(1)
end)

test('an action before the startup timer runs after the cleanup; the timer then does nothing', function()
  local s = sandbox()
  local reply = list(s)
  expect(reply.result ~= nil, 'the list answers').to_be(true)
  expect(count(s, 'hub.cwd.unlock')).to_be(1)
  expect(index(s, 'hub.identify') < index(s, 'hub.cwd.unlock'), 'the SDK identifies the caller, then the handler starts').to_be(true)
  local unlocks, gets = count(s, 'hub.cwd.unlock'), count(s, 'hub.store.get')
  s:tick()
  expect(count(s, 'hub.cwd.unlock')).to_be(unlocks)
  expect(count(s, 'hub.store.get'), 'the timer reads nothing').to_be(gets)
end)

test('a failed timer attempt stays incomplete: the next action retries and cleans up before its dispatch', function()
  local s = sandbox()
  s.reads.fail = 1
  s:tick()
  expect(count(s, 'hub.cwd.unlock'), 'no cleanup without the catalog').to_be(0)
  expect(s.catalog.pending[id] ~= nil).to_be(true)
  local reply = list(s)
  expect(reply.result ~= nil, 'the retry succeeds').to_be(true)
  expect(count(s, 'hub.cwd.unlock')).to_be(1)
  expect(index(s, 'hub.identify') < index(s, 'hub.cwd.unlock'), 'the SDK identifies the caller, then the handler starts').to_be(true)
  expect(s.catalog.pending[id]).to_be(nil)
  list(s)
  expect(count(s, 'hub.cwd.unlock'), 'no second cleanup').to_be(1)
end)

test('a failed startup read fails the action with its code and message, and nothing dispatches', function()
  local s = sandbox()
  s.reads.fail = 1
  expect_store_down(list(s))
  expect(count(s, 'hub.identify'), 'only the SDK identified the caller').to_be(1)
  expect(count(s, 'hub.workers'), 'no refresh').to_be(0)
  expect(count(s, 'hub.cwd.unlock')).to_be(0)
  -- The timer is the next start; its read succeeds.
  s:tick()
  expect(count(s, 'hub.cwd.unlock')).to_be(1)
  expect(list(s).result ~= nil).to_be(true)
end)

test('persistent read failures fail every action without cleanup; after recovery the cleanup runs once', function()
  local s = sandbox()
  s.reads.fail = 100
  s:tick()
  expect_store_down(list(s))
  expect_store_down(s:perform('hub.changed', {what = 'workers'}))
  expect_store_down(list(s))
  expect(count(s, 'hub.cwd.unlock')).to_be(0)
  expect(count(s, 'hub.identify'), 'one for each list; hub.changed has no caller').to_be(2)
  expect(#s.timers, 'a failed notification arms no refresh').to_be(0)
  s.reads.fail = 0
  expect(list(s).result ~= nil).to_be(true)
  list(s)
  expect(count(s, 'hub.cwd.unlock')).to_be(1)
end)

test('an initial refresh failure does not repeat the cleanup; the next list refreshes', function()
  local s = sandbox()
  s.hub_errors['hub.workers'] = 'workers down'
  s:tick()
  expect(count(s, 'hub.cwd.unlock')).to_be(1)
  s.hub_errors['hub.workers'] = nil
  local reply = list(s)
  expect(reply.result ~= nil).to_be(true)
  expect(count(s, 'hub.workers') >= 2, 'the list refreshed').to_be(true)
  expect(count(s, 'hub.cwd.unlock'), 'no second cleanup').to_be(1)
end)

test('a failed cleanup keeps the operation in phase cleanup; startup completes', function()
  local s = sandbox()
  s.hub_errors['hub.cwd.unlock'] = 'unlock down'
  s:tick()
  expect(count(s, 'hub.cwd.unlock')).to_be(1)
  expect(s.catalog.pending[id] and s.catalog.pending[id].phase).to_be('cleanup')
  expect(count(s, 'hub.store.batch'), 'no catalog write').to_be(0)
  s.hub_errors['hub.cwd.unlock'] = nil
  expect(list(s).result ~= nil).to_be(true)
  expect(count(s, 'hub.cwd.unlock'), 'a complete start does not clean up again').to_be(1)
end)
