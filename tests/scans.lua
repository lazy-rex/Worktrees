-- The scan queue (sandbox, tests/support/sandbox.lua): a refresh starts no process; the scan
-- timer starts at most 8 jobs in one tick and keeps at most 8 git status running, for all
-- snapshots together. A fake Git answers the plugin; a git status ends only when the test ends it.
local tests_dir = H.args.file:match('^(.*)/[^/]*$')
local load_sandbox = load_fixture(tests_dir .. '/support/sandbox.lua')
local base = getfenv(1)

-- sandbox loads the plugin with a fake Git. repos maps a repository to its number of trees (the
-- main tree and the linked trees /sandbox/worktrees/<name>/t-NN). recorded: the catalog repos.
local function sandbox(repos, recorded)
  local s = load_sandbox(tests_dir .. '/..', base)
  assert_true(s.loaded, 'the plugin loads: ' .. tostring(s.load_error))
  s:tick()
  -- fail_list: the number of the git worktree list call that fails (nil: none fails);
  -- no_start_list: the number of the call whose process does not start.
  local fake = {missing = {}, start_fail = {}, started = {}, tests = 0, lists = 0}
  s.fake = fake
  local function ok(stdout) return {ok = true, stdout = stdout, stderr = ''} end
  s.exec_hook = function(argv)
    if argv[1] == 'git' and argv[2] == '--git-dir' and argv[4] == 'worktree' and argv[5] == 'list' then
      local top = argv[3]:gsub('/%.git$', '')
      fake.lists = fake.lists + 1
      if fake.lists == fake.fail_list then return {ok = false, stdout = '', stderr = 'fatal: not a git repository'} end
      if fake.lists == fake.no_start_list then return nil, 'no fork' end
      local fields = {'worktree ' .. top, 'HEAD 0', 'branch refs/heads/main', ''}
      local name = top:match('([^/]+)$')
      for i = 1, repos[top] - 1 do
        local path = string.format('/sandbox/worktrees/%s/t-%02d', name, i)
        for _, f in ipairs({'worktree ' .. path, 'HEAD 0', string.format('branch refs/heads/t-%02d', i), ''}) do fields[#fields + 1] = f end
      end
      return ok(table.concat(fields, '\0') .. '\0')
    end
    if argv[1] == 'git' and argv[2] == '-C' and argv[4] == 'rev-parse' then
      if argv[5] == '--show-toplevel' then return ok(argv[3] .. '\n') end
      return ok(argv[3] .. '/.git\n')
    end
    if argv[1] == 'test' then
      fake.tests = fake.tests + 1
      return {ok = argv[2] == '-e' and not fake.missing[argv[3]], stdout = '', stderr = ''}
    end
  end
  s.start_hook = function(argv)
    local path = argv[4]
    if fake.start_fail[path] then return nil, 'no fork' end
    local h = {path = path}
    function h:running() return not self.result end
    function h:wait() if self.result then return self.result end return nil, 'timeout' end
    function h:kill() end
    fake.started[#fake.started + 1] = h
    return h
  end
  local catalog = {repos = {}, pending = {}}
  for _, top in ipairs(recorded) do catalog.repos[top .. '/.git'] = top end
  s.catalog = catalog
  return s
end
local function running(s)
  local n = 0
  for _, h in ipairs(s.fake.started) do if not h.result then n = n + 1 end end
  return n
end
local function finish(s)
  for _, h in ipairs(s.fake.started) do if not h.result then h.result = {ok = true, stdout = '', stderr = ''} end end
end
-- A first page starts a scan when none runs. A cursor ('/', before every path) reads the latest scan.
local function list(s, args) return s:perform('worktree.list', args or {}, s.agent).result end
-- drain ticks until no timer is left, ends every running status after each tick, checks the
-- limits of each tick, and returns the number of ticks.
local function drain(s)
  local ticks = 0
  while #s.timers > 0 do
    ticks = ticks + 1
    assert_true(ticks <= 200, 'the scans end')
    local before = #s.fake.started
    s:tick()
    expect(#s.fake.started - before <= 8, 'at most 8 starts in one tick').to_be(true)
    expect(running(s) <= 8, 'at most 8 git status run').to_be(true)
    finish(s)
  end
  return ticks
end

test('a refresh starts no process; two snapshots share the limits: 8 starts a tick, 8 running (sandbox)', function()
  local s = sandbox({['/r/a'] = 60, ['/r/b'] = 60}, {'/r/a'})
  expect(list(s).refreshing).to_be(true)
  expect(list(s, {repo = '/r/b'}).refreshing).to_be(true)
  expect(#s.fake.started, 'a refresh starts no git status').to_be(0)
  expect(s.fake.tests, 'a refresh checks no tree').to_be(0)
  s:tick()
  expect(#s.fake.started, 'the first tick: 8 starts for both snapshots together').to_be(8)
  s:tick()
  expect(#s.fake.started, 'no start while 8 run').to_be(8)
  finish(s)
  drain(s)
  expect(#s.fake.started).to_be(120)
  local names = {}
  for _, h in ipairs(s.fake.started) do names[h.path:match('^/sandbox/worktrees/([^/]+)/') or h.path] = true end
  expect(names.a and names.b, 'both snapshots scanned').to_be(true)
  -- /r/b first: a list of all repositories drops the /r/b snapshot (the panel does not use it).
  local b = list(s, {repo = '/r/b', worktrees_after = '/'})
  local all = list(s, {worktrees_after = '/'})
  expect(all.refreshing).to_be(false)
  expect(b.refreshing).to_be(false)
  for _, t in ipairs(all.worktrees) do expect(t.state, t.path).to_be('clean') end
end)

test('a missing tree and a failed start end their jobs; refreshing does not stay true (sandbox)', function()
  local s = sandbox({['/r/a'] = 10}, {'/r/a'})
  for i = 1, 3 do s.fake.missing[string.format('/sandbox/worktrees/a/t-%02d', i)] = true end
  for i = 4, 5 do s.fake.start_fail[string.format('/sandbox/worktrees/a/t-%02d', i)] = true end
  list(s)
  drain(s)
  local r = list(s, {worktrees_after = '/'})
  expect(r.refreshing).to_be(false)
  local states = {}
  for _, t in ipairs(r.worktrees) do states[t.path] = t end
  expect(states['/sandbox/worktrees/a/t-01'].state).to_be('missing')
  expect(states['/sandbox/worktrees/a/t-04'].state).to_be('unavailable')
  expect(states['/sandbox/worktrees/a/t-04'].error).to_be('no fork')
  expect(states['/sandbox/worktrees/a/t-06'].state).to_be('clean')
  expect(#s.fake.started).to_be(5)
end)

-- queued returns the number of jobs in the plugin's scan queue. A job that waits starts nothing,
-- so only the queue shows it: the test reads the plugin's own scans table (debug.getupvalue).
local function queued(s)
  local scans = s:find_local('scans', function(v) return v.queue ~= nil end)
  assert_true(scans, 'the plugin scan queue is found')
  return scans.last - scans.first + 1
end

test('a refresh that fails queues no job, also when it fails again; the next refresh scans its own trees (sandbox)', function()
  local s = sandbox({['/r/a'] = 4, ['/r/b'] = 4}, {'/r/a', '/r/b'})
  for i = 1, 3 do
    -- The second git worktree list does not start, after the trees of the first repository are
    -- listed. Only a Git listing error gives an unavailable row (repos.lua): this one fails the
    -- refresh.
    s.fake.lists, s.fake.no_start_list = 0, 2
    local reply = s:perform('worktree.list', {}, s.agent)
    expect(reply.error and reply.error.code).to_be('unavailable')
    expect(queued(s), 'queued jobs after failure ' .. i).to_be(0)
  end
  s.fake.no_start_list = nil
  list(s)
  expect(queued(s)).to_be(8)
  drain(s)
  expect(#s.fake.started).to_be(8)
end)

test('a Git listing error gives one unavailable row; the other repository is scanned (sandbox)', function()
  local s = sandbox({['/r/a'] = 4, ['/r/b'] = 4}, {'/r/a', '/r/b'})
  s.fake.lists, s.fake.fail_list = 0, 2
  expect(list(s).refreshing).to_be(true)
  expect(queued(s), 'the jobs of the listed repository').to_be(4)
  drain(s)
  local r = list(s, {worktrees_after = '/'})
  local unavailable = 0
  for _, t in ipairs(r.worktrees) do
    if t.state == 'unavailable' then
      unavailable = unavailable + 1
      expect(t.error).to_match('not a git repository')
      expect(t.path == '/r/a' or t.path == '/r/b').to_be(true)
    else expect(t.state).to_be('clean') end
  end
  expect(unavailable).to_be(1)
  expect(#r.worktrees).to_be(5)
end)

test('a stale restart queues a new scan; it keeps the limits and ends (sandbox)', function()
  local s = sandbox({['/r/a'] = 11}, {'/r/a'})
  list(s)
  s:tick()
  -- A focus during the scan marks the snapshot stale; its end starts a second scan.
  s:perform('view.seen', {reason = 'focus'})
  drain(s)
  expect(#s.fake.started, 'two scans of 11 trees').to_be(22)
  expect(list(s, {worktrees_after = '/'}).refreshing).to_be(false)
end)

test('Forget drops the snapshots of its repository: their queued jobs start nothing (sandbox)', function()
  local s = sandbox({['/r/a'] = 4, ['/r/b'] = 20}, {'/r/a', '/r/b'})
  s.hub_answers['hub.store.op'] = function() return {found = false} end
  s.hub_answers['hub.store.batch'] = function(args)
    s.catalog = args.ops[1].value
    return {revs = {catalog = '2'}}
  end
  -- The /r/b snapshot queues 20 jobs, then the snapshot of all repositories 24.
  expect(list(s, {repo = '/r/b'}).refreshing).to_be(true)
  expect(list(s).refreshing).to_be(true)
  expect(queued(s)).to_be(44)
  s:tick()
  expect(#s.fake.started, 'the first 8 jobs of /r/b').to_be(8)
  finish(s)
  local reply = s:perform('worktree.forget', {repo = '/r/b', key = 'f'}, s.agent)
  expect(reply.result and reply.result.forgotten, tostring(reply.error and reply.error.message)).to_be(true)
  expect(s.catalog.repos['/r/b/.git']).to_be(nil)
  drain(s)
  -- 8 of /r/b, the 24 jobs of all repositories (a row it drops still ends its job), then the
  -- restart of the stale snapshot: /r/a only. The other 12 jobs of /r/b start nothing.
  expect(#s.fake.started).to_be(8 + 24 + 4)
  local all = list(s, {worktrees_after = '/'})
  expect(all.refreshing).to_be(false)
  expect(#all.worktrees).to_be(4)
  for _, t in ipairs(all.worktrees) do expect(t.repo).to_be('/r/a') end
end)
