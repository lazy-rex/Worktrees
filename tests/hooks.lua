-- A Git hook that fails with a large output. The operation record keeps the end of the error text
-- within 4096 bytes of encoded JSON, so the record fits one control message (64 KiB). With the
-- whole screen text, the write of the record would fail ('control message too large') on each
-- retry, and the operation would stay in phase sending.
local W = load_fixture(H.args.file:match('^(.*)/[^/]*$') .. '/support/fixture.lua')
local alice = agent('alice')

local function valid_utf8(s)
  local i = 1
  while i <= #s do
    local c = s:byte(i)
    local n = c < 0x80 and 0 or (c >= 0xC2 and c < 0xE0) and 1 or (c >= 0xE0 and c < 0xF0) and 2 or (c >= 0xF0 and c < 0xF5) and 3 or nil
    if not n then return false end
    for k = 1, n do local d = s:byte(i + k); if not d or d < 0x80 or d >= 0xC0 then return false end end
    i = i + n + 1
  end
  return true
end
-- adds counts the git worktree add processes in the lab (GIT_TRACE, set in the manifest test.env).
local function adds()
  local f = io.open(H.args.lab .. '/git-trace.log', 'r')
  if not f then return 0 end
  local n = 0
  for l in f:lines() do if l:find('trace: built-in: git worktree add', 1, true) then n = n + 1 end end
  f:close()
  return n
end

test('a failed hook with 300 KB of output: the error is kept within 4 KiB; a retry returns it and starts no Git', function()
  local repo = W.repo('hooks')
  -- About 300 KB: each line has a 2-byte character, and characters that JSON escapes.
  W.write(repo .. '/.git/hooks/post-checkout', table.concat({'#!/bin/sh',
    'i=0',
    'while [ $i -lt 3000 ]; do printf \'line %d é "q" \\\\ xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx\\n\' $i; i=$((i+1)); done',
    'printf \'LAST é\\n\'', 'exit 1', ''}, '\n'))
  W.run({'chmod', '+x', repo .. '/.git/hooks/post-checkout'})
  local function create() return alice:call('worktree.create', {repo = repo, branch = 'loud', key = 'loud'}) end
  local err = expect_error(function() W.settle(create, 'the create', 60) end, 'git_error')
  local message = tostring(err.message)
  expect(#rex.json.encode(message) <= 4096, 'the error is within 4096 bytes of JSON').to_be(true)
  expect(#rex.json.encode(message) > 4096 - 16, 'the error keeps as much as fits').to_be(true)
  expect(message:sub(1, #'…')).to_be('…')
  expect(message:find('LAST é', 1, true) ~= nil, 'the end of the output').to_be(true)
  expect(message:find('"q" \\', 1, true) ~= nil, 'escaped characters').to_be(true)
  expect(valid_utf8(message), 'whole characters').to_be(true)
  expect(W.catalog().pending[W.part('alice') .. W.part('loud')], 'the operation is not pending').to_be(nil)
  local before = adds()
  expect(before).to_be(1)
  local again = expect_error(create, 'git_error')
  expect(again.message).to_be(message)
  expect(adds(), 'the retry starts no Git').to_be(before)
  -- The hook failure does not undo the worktree: Git created it (README, "Git hooks").
  expect(W.try({'test', '-d', W.tree_path(repo, 'loud')}).ok).to_be(true)
end)
