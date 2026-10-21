-- Source snapshots (sandbox, tests/support/sandbox.lua): the panel keeps at most 16, evicts the
-- least recently rendered one first, and evicts one that no panel rendered in the previous or the
-- current refresh generation. The snapshot that an agent list pages through only loses its panel
-- mark. An evicted snapshot starts no queued job and changes nothing when an active job ends.
local tests_dir = H.args.file:match('^(.*)/[^/]*$')
local load_sandbox = load_fixture(tests_dir .. '/support/sandbox.lua')
local base = getfenv(1)

-- sandbox: each source /sNN is a repository. trees[top] is its number of linked trees (0: a bare
-- main entry, so no scan job). lists[top] counts git worktree list for it.
local function sandbox(trees)
  local s = load_sandbox(tests_dir .. '/..', base)
  assert_true(s.loaded, 'the plugin loads: ' .. tostring(s.load_error))
  s:tick()
  s.trees, s.lists, s.started = trees or {}, {}, {}
  local function ok(stdout) return {ok = true, stdout = stdout, stderr = ''} end
  s.exec_hook = function(argv)
    if argv[1] == 'git' and argv[2] == '-C' and argv[4] == 'rev-parse' then
      if argv[5] == '--show-toplevel' then return ok(argv[3] .. '\n') end
      return ok(argv[3] .. '/.git\n')
    end
    if argv[1] == 'git' and argv[2] == '--git-dir' and argv[4] == 'worktree' and argv[5] == 'list' then
      local top = argv[3]:gsub('/%.git$', '')
      s.lists[top] = (s.lists[top] or 0) + 1
      local n = s.trees[top] or 0
      if n == 0 then return ok(table.concat({'worktree ' .. top, 'bare', ''}, '\0') .. '\0') end
      local fields = {'worktree ' .. top, 'bare', ''}
      for i = 1, n do
        for _, f in ipairs({'worktree ' .. top .. '/t' .. i, 'HEAD 0', 'branch refs/heads/t' .. i, ''}) do fields[#fields + 1] = f end
      end
      return ok(table.concat(fields, '\0') .. '\0')
    end
    if argv[1] == 'test' then return ok('') end
  end
  s.start_hook = function(argv)
    local h = {path = argv[4]}
    function h:running() return not self.result end
    function h:wait() if self.result then return self.result end return nil, 'timeout' end
    function h:kill() end
    s.started[#s.started + 1] = h
    return h
  end
  s.rex_answers['com.superlogical.terminal.pwd'] = function() return {pwd = s.pwd} end
  return s
end
local function render(s, top)
  s.pwd = top
  local reply = s:perform('view.render', {route = '/panels/worktrees', context = {session_id = 'S1', source_block_id = 'B1'}})
  assert_true(reply and reply.result ~= nil, 'the panel renders: ' .. show(reply and reply.error))
  return reply.result.tree or reply.result
end
local function refresh(s)
  local reply = s:perform('view.action', {route = '/panels/worktrees', node_id = 'refresh', action = 'refresh', input = {}})
  assert_true(reply and reply.result ~= nil, 'the refresh runs: ' .. show(reply and reply.error))
end
local function top(i) return string.format('/s%02d', i) end
-- snapshots returns the plugin's snapshots table (debug.getupvalue, as scans.lua reads scans).
local function snapshots(s)
  local seen = {}
  local function find(fn)
    if seen[fn] then return nil end
    seen[fn] = true
    for i = 1, 255 do
      local name, v = debug.getupvalue(fn, i)
      if not name then return nil end
      if name == 'snapshots' and type(v) == 'table' then return v end
      if type(v) == 'function' then
        local found = find(v)
        if found then return found end
      end
    end
  end
  return assert(find(s.handlers.client_perform_requested), 'the snapshots table')
end
local function ui_count(s)
  local n = 0
  for key, c in pairs(snapshots(s)) do if key ~= '' and c.ui then n = n + 1 end end
  return n
end
local function has_row(tree, path)
  for _, n in ipairs(tree.nodes or {}) do
    if n.id == 'worktrees' then for _, it in ipairs(n.items or {}) do if it.id == path then return true end end end
  end
  return false
end

test('17 sources in one generation: 16 stay, and the least recently rendered one goes', function()
  local s = sandbox()
  for i = 1, 16 do render(s, top(i)) end
  render(s, top(1)) -- /s01 is now the most recent; /s02 is the least recent
  render(s, top(17))
  expect(ui_count(s)).to_be(16)
  expect(snapshots(s)[top(2)], 'the least recently rendered source').to_be(nil)
  expect(snapshots(s)[top(1)] ~= nil, 'a recent source stays').to_be(true)
end)

test('a source that no panel renders is refreshed once more, then evicted; a revisit lists it again', function()
  local s = sandbox({[top(1)] = 0, [top(2)] = 0})
  render(s, top(1))
  render(s, top(2))
  local a = snapshots(s)[top(1)]
  local rendered, touched = a.rendered, a.touched
  refresh(s)
  -- The refresh replaces the snapshot and keeps its render fields.
  expect(snapshots(s)[top(1)] ~= a, 'a new snapshot').to_be(true)
  expect(snapshots(s)[top(1)].rendered).to_be(rendered)
  expect(snapshots(s)[top(1)].touched).to_be(touched)
  local after = s.lists[top(1)]
  for _ = 1, 3 do render(s, top(2)); refresh(s) end
  expect(s.lists[top(1)] - after <= 1, 'listed at most once after its last render').to_be(true)
  expect(snapshots(s)[top(1)], 'evicted').to_be(nil)
  expect(snapshots(s)[top(2)] ~= nil, 'the rendered source stays').to_be(true)
  local before = s.lists[top(1)]
  s.trees[top(1)] = 1
  local tree = render(s, top(1))
  expect(s.lists[top(1)] > before, 'the revisit lists it again (repo_info lists too)').to_be(true)
  expect(has_row(tree, top(1) .. '/t1'), 'its rows are shown').to_be(true)
end)

test('the snapshot that an agent list uses only loses its panel mark: 16 panel snapshots plus that one', function()
  local s = sandbox()
  render(s, top(1))
  expect(s:perform('worktree.list', {repo = top(1)}, s.agent).result ~= nil).to_be(true)
  for i = 2, 17 do render(s, top(i)) end
  local kept = snapshots(s)[top(1)]
  expect(kept ~= nil, 'the requested snapshot stays').to_be(true)
  expect(kept.ui, 'without the panel mark').to_be(nil)
  expect(ui_count(s)).to_be(16)
end)

test('eviction with queued jobs starts none of them; an active job of an evicted snapshot changes nothing shown', function()
  local s = sandbox({[top(1)] = 20, [top(2)] = 3})
  render(s, top(2))
  s:tick() -- the 3 status jobs of /s02 start
  expect(#s.started).to_be(3)
  render(s, top(1)) -- 20 queued jobs; none started yet
  for i = 3, 18 do render(s, top(i)) end
  expect(snapshots(s)[top(1)], '/s01 evicted').to_be(nil)
  expect(snapshots(s)[top(2)], '/s02 evicted').to_be(nil)
  local invalidations = s.calls['hub.ui.invalidate'] or 0
  for _, h in ipairs(s.started) do h.result = {ok = true, stdout = '', stderr = ''} end
  for _ = 1, 10 do s:tick() end
  for _, h in ipairs(s.started) do
    expect(h.path:sub(1, 5) ~= top(1) .. '/', 'no status for a queued job of /s01: ' .. h.path).to_be(true)
  end
  expect(s.calls['hub.ui.invalidate'] or 0, 'no invalidation for the evicted snapshot').to_be(invalidations)
  expect(snapshots(s)[top(2)], 'not reinserted').to_be(nil)
end)
