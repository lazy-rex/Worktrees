-- The source repository of a panel is kept per exact pane directory until the next refresh_safe
-- (an explicit Refresh, a processed focus or worker notification, a mutation). Outside a
-- repository is kept only when Git says so. At most 64 directories.
local W = load_fixture(H.args.file:match('^(.*)/[^/]*$') .. '/support/fixture.lua')
local tests_dir = H.args.file:match('^(.*)/[^/]*$')
local load_sandbox = load_fixture(tests_dir .. '/support/sandbox.lua')
local base = getfenv(1)
local S = H.args.tests_session

-- toplevels counts git rev-parse --show-toplevel in the lab (GIT_TRACE, set in the manifest
-- test.env). Only repo_info runs it. The trace has no directory, so a count is only a bound.
local function toplevels()
  local f = io.open(H.args.lab .. '/git-trace.log', 'r')
  if not f then return 0 end
  local n = 0
  for l in f:lines() do if l:find('trace: built-in: git rev-parse --show-toplevel', 1, true) then n = n + 1 end end
  f:close()
  return n
end
local function pane(cwd)
  local before = {}
  rex.call('session.attach', {session_id = S, event_scope = 'session'})
  for _, w in ipairs(rex.call('session.view', {session_id = S}).windows or {}) do before[w.window_id] = true end
  rex.call('session.new_window', {session_id = S, layout = {block = {flavor = 'com.superlogical.terminal.shell',
    options = {command = {'/bin/sleep', '600'}, cwd = cwd, login = false, exit = {on_completion = false}}}}})
  for _, w in ipairs(rex.call('session.view', {session_id = S}).windows or {}) do
    if not before[w.window_id] then for _, l in ipairs(w.layers or {}) do for _, b in ipairs(l.blocks or {}) do return b.block_id end end end
  end
end
-- panel opens the panel of a pane and returns the view after its first render.
local function panel(block)
  user:command('worktrees', {session = S, block = block})
  local v = user:view('/panels/worktrees', nil, S)
  return v
end
local function source_text(v) return node(v:render(), 'new').text end

test('lab: warm renders run no source lookup; a new directory resolves on its first render', function()
  local repo = W.repo('cache')
  local v = panel(pane(repo))
  expect(source_text(v)).to_be('Repository: ' .. repo .. ' (not recorded)')
  local before = toplevels()
  for _ = 1, 5 do expect(source_text(v)).to_contain(repo) end
  expect(toplevels(), 'no git rev-parse --show-toplevel in 5 warm renders').to_be(before)
  -- Another directory: no refresh between, and its first render shows its repository.
  local other = W.repo('cache-other')
  local o = panel(pane(other))
  expect(source_text(o)).to_be('Repository: ' .. other .. ' (not recorded)')
end)

test('lab: outside a repository is kept until Refresh, from the real Git text', function()
  local plain = H.args.lab .. '/plain'
  W.run({'mkdir', '-p', plain})
  plain = W.real(plain)
  local v = panel(pane(plain))
  expect(source_text(v)).to_be('The source pane is not in a Git repository.')
  local before = toplevels()
  expect(source_text(v)).to_be('The source pane is not in a Git repository.')
  expect(toplevels(), 'the negative result is kept').to_be(before)
  -- A repository appears in the same directory: the kept result stays until a refresh (README).
  W.run({'git', 'init', '-q', '-b', 'main', plain})
  expect(source_text(v)).to_be('The source pane is not in a Git repository.')
  expect(v:action('refresh', 'refresh', {}).status).to_be('succeeded')
  expect(source_text(v)).to_be('Repository: ' .. plain .. ' (not recorded)')
end)

-- The sandbox: the pane directory comes from s.pwd; Git answers by directory.
local function sandbox()
  local s = load_sandbox(tests_dir .. '/..', base)
  assert_true(s.loaded, 'the plugin loads: ' .. tostring(s.load_error))
  s:tick()
  s.lookups = {}
  s.rex_answers['com.superlogical.terminal.pwd'] = function() return {pwd = s.pwd} end
  s.exec_hook = function(argv)
    if argv[1] == 'git' and argv[2] == '-C' and argv[4] == 'rev-parse' and argv[5] == '--show-toplevel' then
      s.lookups[argv[3]] = (s.lookups[argv[3]] or 0) + 1
      if s.no_start then return nil, 'no fork' end
      return {ok = false, stdout = '', stderr = 'fatal: not a git repository (or any of the parent directories): .git'}
    end
  end
  return s
end
local function render(s, pwd)
  s.pwd = pwd
  local reply = s:perform('view.render', {route = '/panels/worktrees', context = {session_id = 'S1', source_block_id = 'B1'}})
  assert_true(reply and reply.result ~= nil, 'the panel renders: ' .. show(reply and reply.error))
  return reply.result
end

test('sandbox: outside a repository is kept; a process that does not start is not kept', function()
  local s = sandbox()
  render(s, '/plain')
  render(s, '/plain')
  expect(s.lookups['/plain'], 'kept after the first lookup').to_be(1)
  s.no_start = true
  render(s, '/flaky')
  render(s, '/flaky')
  expect(s.lookups['/flaky'], 'not kept').to_be(2)
end)

test('sandbox: the 65th directory clears the table; the panel Refresh clears it too', function()
  local s = sandbox()
  for i = 1, 64 do render(s, '/d' .. i) end
  render(s, '/d1')
  expect(s.lookups['/d1'], '64 directories are kept').to_be(1)
  render(s, '/d65')
  render(s, '/d1')
  expect(s.lookups['/d1'], 'the 65th cleared the table').to_be(2)
  s:perform('view.action', {route = '/panels/worktrees', node_id = 'refresh', action = 'refresh', input = {}})
  render(s, '/d1')
  expect(s.lookups['/d1'], 'a refresh starts a new generation').to_be(3)
end)
