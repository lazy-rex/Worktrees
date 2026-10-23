-- The identity of a tree (sandbox, tests/support/sandbox.lua): a remove records the Git directory
-- with its device, inode and birth time, and a retry compares it. BSD stat (macOS) runs first and
-- its output is kept as it is. GNU stat (Linux) fails on -f; then stat -c gives the same fields.
-- An unknown birth time ('-') is 0.
local tests_dir = H.args.file:match('^(.*)/[^/]*$')
local load_sandbox = load_fixture(tests_dir .. '/support/sandbox.lua')
local base = getfenv(1)
local tree = '/sandbox/worktrees/r/t'
local gitdir = '/r/.git/worktrees/t'
local gnu_refusal = "stat: cannot read file system information for '%d:%i:%B': No such file or directory\n"

-- sandbox: the recorded repository /r with the linked tree /sandbox/worktrees/r/t. stat answers
-- -f with bsd and -c with gnu: a text is the output, false is a failure. s.stats lists the stat
-- calls. The lock check reads the pending remove (s.recorded) and refuses, so the remove ends there.
local function sandbox(bsd, gnu)
  local s = load_sandbox(tests_dir .. '/..', base)
  assert_true(s.loaded, 'the plugin loads: ' .. tostring(s.load_error))
  local function ok(stdout) return {ok = true, stdout = stdout, stderr = ''} end
  s.stats = {}
  s.exec_hook = function(argv)
    if argv[1] == 'git' and argv[2] == '--git-dir' and argv[4] == 'worktree' and argv[5] == 'list' then
      return ok(table.concat({'worktree /r', 'HEAD 0', 'branch refs/heads/main', '', 'worktree ' .. tree, 'HEAD 0', 'branch refs/heads/t', ''}, '\0') .. '\0')
    end
    if argv[1] == 'git' and argv[2] == '-C' and argv[4] == 'rev-parse' then
      if argv[5] == '--show-toplevel' then return ok(argv[3] .. '\n') end
      if argv[5] == '--absolute-git-dir' then return ok(gitdir .. '\n') end
      return ok('/r/.git\n')
    end
    if argv[1] == 'stat' then
      s.stats[#s.stats + 1] = table.concat(argv, ' ')
      local answer = argv[2] == '-f' and bsd or argv[2] == '-c' and gnu or false
      if answer then return ok(answer) end
      return {ok = false, stdout = '', stderr = argv[2] == '-f' and gnu_refusal or 'stat: failed\n'}
    end
    if argv[1] == 'test' then return ok('') end
  end
  s.hub_answers['hub.cwd.lock'] = function()
    for _, op in pairs(s:pending()) do s.recorded = op.identity end
    return {locked = false, workers = {}}
  end
  s:set_catalog({repos = {['/r/.git'] = '/r'}, pending = {}})
  return s
end
local function remove(s) return s:perform('worktree.remove', {path = tree, key = 'r'}, s.agent) end

test('macOS: the identity is the BSD stat output, unchanged; GNU stat does not run (sandbox)', function()
  local s = sandbox('16777230:1234:1729000000\n', '1:1:1\n')
  expect(remove(s).error.code).to_be('refused')
  expect(s.recorded).to_be(gitdir .. '\n16777230:1234:1729000000\n')
  -- A remove reads the identity twice: when it records the operation, and when it compares it.
  expect(s.stats).to_equal({'stat -f %d:%i:%B ' .. gitdir, 'stat -f %d:%i:%B ' .. gitdir})
end)

test('Linux: BSD stat fails, so GNU stat -c gives device, inode and birth time (sandbox)', function()
  local s = sandbox(false, '2049:5678:1729000000\n')
  expect(remove(s).error.code).to_be('refused')
  expect(s.recorded).to_be(gitdir .. '\n2049:5678:1729000000\n')
  local bsd, gnu = 'stat -f %d:%i:%B ' .. gitdir, 'stat -c %d:%i:%W ' .. gitdir
  expect(s.stats).to_equal({bsd, gnu, bsd, gnu})
end)

test("Linux: an unknown birth time ('-' or 0) is 0 (sandbox)", function()
  for _, unknown in ipairs({'-', '0'}) do
    local s = sandbox(false, '2049:5678:' .. unknown .. '\n')
    expect(remove(s).error.code).to_be('refused')
    expect(s.recorded, unknown).to_be(gitdir .. '\n2049:5678:0\n')
  end
end)

test('both stat forms fail: the remove fails with the GNU error and records nothing (sandbox)', function()
  local s = sandbox(false, false)
  local e = remove(s).error
  expect(e.code).to_be('git_error')
  expect(e.message).to_match('stat: failed')
  expect(s:pending()).to_equal({})
  expect(s.recorded).to_be(nil)
end)

test('a retry compares the recorded identity: the same one goes on, a changed birth time is a conflict (sandbox)', function()
  for _, case in ipairs({{gitdir .. '\n2049:5678:1729000000\n', 'refused'}, {gitdir .. '\n2049:5678:1\n', 'conflict'}}) do
    local s = sandbox(false, '2049:5678:1729000000\n')
    -- A pending remove in phase prepared, as a stop after the admission leaves it.
    s:set_catalog({repos = {['/r/.git'] = '/r'}, pending = {['5:alice1:r'] = {kind = 'remove', fingerprint = 'remove/' .. #tree .. ':' .. tree,
      repo = '/r', common = '/r/.git', actor = 'alice', path = tree, branch = 't', identity = case[1], phase = 'prepared'}}})
    local e = remove(s).error
    expect(e.code, case[2]).to_be(case[2])
    if case[2] == 'conflict' then expect(e.message).to_match('identity changed') end
  end
end)
