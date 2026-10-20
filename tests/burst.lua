-- A notification (hub.changed workers, view.seen focus, a terminal event) does no Git work in the
-- plugin's request queue: each one sets a flag, and one later tick refreshes. This makes each
-- notification short; it does not make the queue (16 requests) unlimited. Observed in the lab:
-- after a burst of 30 spawns, and after 30 stops, the first worktree.list call answered.
local W = load_fixture(H.args.file:match('^(.*)/[^/]*$') .. '/support/fixture.lua')
local repo = W.repo('burst')
local alice = agent('alice')

write_profiles({profiles = {{id = 'sleep', name = 'Sleep', kind = 'accessory', command = {'/bin/sleep', '600'}}}})

local tree = W.settle(function() return alice:call('worktree.create', {repo = repo, branch = 'burst', key = 'burst-create'}) end)
-- More trees make each refresh slower (one git status a tree), as on a real workspace.
local add = {}
for i = 1, 30 do add[#add + 1] = string.format("git -C '%s' worktree add -q -b extra-%02d '%s/burst/extra-%02d' >/dev/null", repo, i, W.root, i) end
W.run({'/bin/sh', '-c', table.concat(add, ' && ')})
local function row(r) for _, t in ipairs(r.worktrees or {}) do if t.path == tree.path then return t end end end

-- The flag rules, in the sandbox (tests/support/sandbox.lua): its timers run only in s:tick(), so
-- the order of notifications and ticks is exact. A refresh of the recorded repositories ends
-- with one hub.ui.invalidate; a tick that does not refresh calls none.
local tests_dir = H.args.file:match('^(.*)/[^/]*$')
local load_sandbox = load_fixture(tests_dir .. '/support/sandbox.lua')
local base = getfenv(1)
local function sandbox()
  local s = load_sandbox(tests_dir .. '/..', base)
  assert_true(s.loaded, 'the plugin loads: ' .. tostring(s.load_error))
  s:tick()
  s.calls = {}
  return s
end
local function refreshes(s) return s.calls['hub.ui.invalidate'] or 0 end
local worker = {spawn_id = 'w1', cwd = '/sandbox/worktrees/t', state = 'running', title = 'W'}

test('20 worker notifications call no hub action and arm one tick; an unchanged worker set does not refresh (sandbox)', function()
  local s = sandbox()
  for _ = 1, 20 do expect(s:perform('hub.changed', {what = 'workers'}).result).to_equal({}) end
  expect(s.calls['hub.workers']).to_be(nil)
  expect(#s.timers).to_be(1)
  expect(s:tick()).to_be(1)
  expect(s.calls['hub.workers']).to_be(1)
  expect(refreshes(s)).to_be(0)
  expect(#s.timers, 'no timer after the tick').to_be(0)
end)

test('a changed worker set refreshes once in the tick (sandbox)', function()
  local s = sandbox()
  s.workers = {worker}
  s:perform('hub.changed', {what = 'workers'})
  s:perform('hub.changed', {what = 'workers'})
  s:tick()
  expect(refreshes(s)).to_be(1)
end)

test('focus then workers, and workers then focus: always wins; the tick refreshes with an unchanged worker set (sandbox)', function()
  for _, order in ipairs({{'focus', 'workers', 'workers'}, {'workers', 'focus', 'workers'}}) do
    local s = sandbox()
    for _, n in ipairs(order) do
      if n == 'focus' then s:perform('view.seen', {reason = 'focus'}) else s:perform('hub.changed', {what = 'workers'}) end
    end
    expect(#s.timers).to_be(1)
    s:tick()
    expect(refreshes(s), table.concat(order, ',')).to_be(1)
  end
end)

test('a notification during the tick arms a new tick (sandbox)', function()
  local s = sandbox()
  s:perform('hub.changed', {what = 'workers'})
  local once = true
  s.on_hub['hub.workers'] = function()
    if once then once = false; s:perform('view.seen', {reason = 'focus'}) end
  end
  s:tick()
  expect(refreshes(s), 'the unchanged worker set did not refresh').to_be(0)
  expect(#s.timers, 'the focus during the tick armed a new tick').to_be(1)
  s:tick()
  expect(refreshes(s), 'the new tick refreshed').to_be(1)
end)

test('an error in the tick leaves no stuck flag: the next notification arms a tick that refreshes (sandbox)', function()
  local s = sandbox()
  s.hub_errors['hub.workers'] = 'stream response "control-1" failed: gone'
  s:perform('hub.changed', {what = 'workers'})
  s:tick()
  expect(refreshes(s), 'the error invalidates the panel (refresh_error)').to_be(1)
  expect(#s.timers).to_be(0)
  s.hub_errors['hub.workers'] = nil
  s.workers = {worker}
  s:perform('hub.changed', {what = 'workers'})
  expect(#s.timers).to_be(1)
  s:tick()
  expect(refreshes(s)).to_be(2)
end)

test('a burst of 30 spawns and 30 stops: the first list call answers; the list reaches the final state', function()
  local spawned = {}
  for i = 1, 30 do spawned[i] = alice:hub('hub.spawn', {profile = 'sleep', key = 'burst-' .. i, cwd = tree.path}).spawn_id end
  -- No spacing and no busy retry: the first call must answer.
  alice:call('worktree.list', {repo = repo})
  wait('the list shows the 30 workers', function()
    local t = row(alice:call('worktree.list', {repo = repo}))
    return t and #(t.workers or {}) == 30
  end, 30)
  for _, id in ipairs(spawned) do alice:hub('hub.stop', {spawn_id = id}) end
  alice:call('worktree.list', {repo = repo})
  wait('the list shows no worker and a finished scan', function()
    local t = row(alice:call('worktree.list', {repo = repo}))
    return t and #(t.workers or {}) == 0 and t.state == 'clean'
  end, 30)
end)

-- busy_refusals counts the hub's calls to this plugin that Rex refused with a full queue. The hub
-- only logs a refused hub.changed, so a reply alone does not show a lost notification.
local function busy_refusals()
  local f = io.open(H.args.lab .. '/hub.log', 'r')
  if not f then return 0 end
  local n = 0
  for l in f:lines() do if l:find('"lazyrex-plugin:worktrees" is busy', 1, true) then n = n + 1 end end
  f:close()
  return n
end

test('with about 100 trees, a burst of 16 spawns and 16 stops: no call to the plugin is refused', function()
  local more = {}
  for i = 31, 100 do more[#more + 1] = string.format("git -C '%s' worktree add -q -b extra-%02d '%s/burst/extra-%02d' >/dev/null", repo, i, W.root, i) end
  W.run({'/bin/sh', '-c', table.concat(more, ' && ')})
  wait('the scan of 101 trees ends', function()
    local r = alice:call('worktree.list', {repo = repo})
    return not r.refreshing and r.worktrees_next ~= nil
  end, 60)
  local before = busy_refusals()
  local spawned = {}
  for i = 1, 16 do spawned[i] = alice:hub('hub.spawn', {profile = 'sleep', key = 'many-' .. i, cwd = tree.path}).spawn_id end
  alice:call('worktree.list', {repo = repo})
  for _, id in ipairs(spawned) do alice:hub('hub.stop', {spawn_id = id}) end
  alice:call('worktree.list', {repo = repo})
  rex.sleep(2)
  expect(busy_refusals() - before, 'refused calls to the plugin').to_be(0)
end)
