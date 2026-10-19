-- worktree.list fits every client (a Rex control message is 64 KiB; the harness test client takes
-- 48 KiB): pages of worktrees (16 KiB) and operations (24 KiB), the other fields within 4 KiB, all
-- of it within 44 KiB. Each test uses its own
-- repository and passes repo, so the tests do not see each other's trees.
local W = load_fixture(H.args.file:match('^(.*)/[^/]*$') .. '/support/fixture.lua')
local alice = agent('alice')

write_profiles({profiles = {{id = 'sleep', name = 'Sleep', kind = 'accessory', command = {'/bin/sleep', '600'}}}})

local function create(repo, branch, key)
  return W.settle(function() return alice:call('worktree.create', {repo = repo, branch = branch, key = key}) end)
end
-- add makes n more trees with Git itself (fast); the plugin lists them from its recorded repository.
local function add(repo, name, branches)
  local script = {}
  for _, b in ipairs(branches) do
    script[#script + 1] = string.format("git -C '%s' worktree add -q -b '%s' '%s/%s/%s' >/dev/null", repo, b:gsub("'", "'\\''"), W.root, name, b:gsub("'", "'\\''"))
  end
  W.run({'/bin/sh', '-c', table.concat(script, ' && ')})
end
-- pages reads every worktrees page of repo and checks the page rules.
local function pages(repo)
  local seen, order, count, after, last = {}, {}, 0, nil, nil
  repeat
    local r = alice:call('worktree.list', {repo = repo, worktrees_after = after})
    last = r
    count = count + 1
    local trees = r.worktrees or {}
    expect(#trees > 0 or r.worktrees_next == nil, 'no empty page before the end').to_be(true)
    expect(#trees <= 50).to_be(true)
    expect(#rex.json.encode(trees) <= 16384, 'the worktrees page is within 16 KiB').to_be(true)
    for _, t in ipairs(trees) do
      expect(seen[t.path], 'no duplicate ' .. t.path).to_be(nil)
      if order[#order] then expect(t.path > order[#order], 'sorted by path').to_be(true) end
      seen[t.path] = t
      order[#order + 1] = t.path
    end
    after = r.worktrees_next
  until after == nil
  return seen, order, count, last
end
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

test('an empty list leaves out worktrees and worktrees_next', function()
  local r = alice:call('worktree.list', {})
  expect(r.worktrees).to_be(nil)
  expect(r.worktrees_next).to_be(nil)
  expect(r.root).to_be(W.root)
end)

local many = W.repo('list-many')
local many_order

test('61 trees in 2 pages, sorted by path, no duplicate or skipped tree; paging writes nothing', function()
  create(many, 'b-00', 'many-00')
  local branches = {}
  for i = 1, 60 do branches[i] = string.format('b-%02d', i) end
  add(many, 'list-many', branches)
  wait('the scan lists every tree', function()
    local seen = pages(many)
    local n = 0
    for _ in pairs(seen) do n = n + 1 end
    return n == 62
  end, 60)
  local rev = store('catalog').rev
  local seen, order, count = pages(many)
  expect(count).to_be(2)
  expect(#order).to_be(62)
  -- The same set as Git: the main tree and 61 linked trees.
  -- (string.gmatch is not used: in Rex Lua it once stopped with a Go nil pointer error.)
  local text, pos, listed = W.git(many, 'worktree', 'list', '--porcelain') .. '\n', 1, 0
  while true do
    local s, e = text:find('worktree ', pos, true)
    if not s then break end
    local nl = text:find('\n', e, true)
    local path = text:sub(e + 1, nl - 1)
    expect(seen[path] ~= nil, 'listed ' .. path).to_be(true)
    listed, pos = listed + 1, nl + 1
  end
  expect(listed).to_be(62)
  expect(store('catalog').rev, 'paging writes nothing').to_be(rev)
  many_order = order
end)

test('a cursor whose tree is gone is still a position', function()
  local cursor = many_order[50]
  W.git(many, 'worktree', 'remove', cursor)
  local r = alice:call('worktree.list', {repo = many, worktrees_after = cursor})
  expect(r.worktrees[1].path).to_be(many_order[51])
end)

test('long escaped text in both lists: every page is within budget; the reply has margin', function()
  local long = W.repo('list-long')
  create(long, 'q/first', 'long-first')
  -- Quotes double when JSON escapes them: about 1 KB an entry.
  local branches = {}
  for i = 1, 30 do branches[i] = 'q/' .. string.rep('"', 200) .. i end
  add(long, 'list-long', branches)
  wait('the scan lists every long tree', function()
    local seen = pages(long)
    local n = 0
    for _ in pairs(seen) do n = n + 1 end
    return n == 32
  end, 60)
  -- Pending operations with escaped text fill the operations page (24 KiB).
  local state = store('catalog').value
  local text = string.rep('"\\\t', 400)
  for i = 1, 15 do
    local key = string.format('long-op-%02d', i)
    state.pending[W.part('alice') .. W.part(key)] = {kind = 'remove', phase = 'prepared', path = W.root .. '/' .. text .. i,
      branch = 'op', repo = long, common = W.real(long .. '/.git'), actor = 'alice', fingerprint = 'synthetic/' .. key}
  end
  write({{key = 'catalog', value = state}})
  local _, order, count, first = pages(long)
  expect(#order).to_be(32)
  expect(count >= 2, 'the long trees need more than one page').to_be(true)
  local r = alice:call('worktree.list', {repo = long})
  expect(#r.worktrees > 0 and #r.operations > 0, 'both lists are populated').to_be(true)
  expect(r.worktrees_next ~= nil and r.operations_next ~= nil, 'both lists continue').to_be(true)
  -- The reply came through the agent face (the MCP and rex -C lazyrex path).
  local size = #rex.json.encode(r)
  print('LIST reply bytes ' .. size .. ', margin to 49152 (test client): ' .. (49152 - size) .. ', to 65536: ' .. (65536 - size))
  expect(size <= 45056, 'the reply is within 44 KiB').to_be(true)
  local p = store('catalog').value
  p.pending = {}
  write({{key = 'catalog', value = p}})
end)

test('a tree with too many workers is compact: workers_count, and hub.workers lists them', function()
  local busy = W.repo('list-busy')
  local tree = create(busy, 'busy', 'busy-create')
  local q = string.rep('"', 200)
  local dir = tree.path .. '/' .. q .. '/' .. q .. '/' .. q .. '/' .. q
  W.run({'mkdir', '-p', dir})
  local spawned = {}
  -- Each spawn makes a hub.changed for the plugin; a burst can fill its request queue (16), so
  -- the spawns are spaced and a busy reply while waiting is retried.
  for i = 1, 16 do
    spawned[i] = alice:hub('hub.spawn', {profile = 'sleep', key = 'busy-' .. i, cwd = dir}).spawn_id
    rex.sleep(0.3)
  end
  -- The full entry does not fit after the main tree, so the page ends there; on the next (empty)
  -- page it does not fit either, so it is compact. A busy reply while waiting is retried.
  local entry
  wait('the compact entry', function()
    local ok, seen = pcall(pages, busy)
    if not ok then
      if tostring(seen.message or seen):find('is busy', 1, true) then return nil end
      error(seen, 0)
    end
    entry = seen[tree.path]
    -- The finished scan: dirty is known only after git status.
    return entry and entry.compact and entry.state ~= 'checking'
  end, 60)
  expect(entry.workers_count).to_be(16)
  expect(entry.workers).to_be(nil)
  expect(entry.branch).to_be('busy')
  expect(entry.dirty, 'a compact entry keeps dirty').to_be(false)
  expect(entry.state).to_be('clean')
  local listed = 0
  for _, w in ipairs(H.hub('hub.workers', {}).workers or {}) do if w.cwd == dir then listed = listed + 1 end end
  expect(listed).to_be(16)
  for _, id in ipairs(spawned) do alice:hub('hub.stop', {spawn_id = id}); rex.sleep(0.3) end
  -- The stops make a burst of hub.changed too: wait until the plugin answers again.
  wait('the plugin answers', function()
    local ok, err = pcall(function() return alice:call('worktree.list', {repo = busy}) end)
    if ok then return true end
    if tostring(err.message or err):find('is busy', 1, true) then return nil end
    error(err, 0)
  end, 60)
end)

test('a long error is cut within 1024 bytes at a UTF-8 boundary', function()
  local bad = W.repo('list-bad')
  local tree = create(bad, 'bad', 'bad-create')
  -- git status in this tree fails with the value in its message. The x makes the 1021-byte cut
  -- point fall inside a 2-byte character.
  W.git(bad, 'config', 'extensions.worktreeConfig', 'true')
  W.git(tree.path, 'config', '--worktree', 'core.bare', 'x' .. string.rep('é', 700))
  local entry
  wait('the failed status', function()
    local r = alice:call('worktree.list', {repo = bad})
    for _, t in ipairs(r.worktrees or {}) do if t.path == tree.path and t.error then entry = t end end
    return entry
  end, 60)
  expect(#entry.error <= 1024, 'error within 1024 bytes').to_be(true)
  expect(entry.error:sub(-#'…')).to_be('…')
  expect(entry.error:find('bad boolean config value', 1, true) ~= nil).to_be(true)
  expect(valid_utf8(entry.error), 'the cut keeps whole characters').to_be(true)
  expect(#entry.error >= 1024 - 4, 'the cut keeps as much as fits').to_be(true)
end)
