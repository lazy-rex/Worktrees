-- The import of the hub.store records into SQL (sandbox, tests/support/sandbox.lua; docs/sdk-port.md,
-- section 3). The first start copies, in pages: the catalog record, the open/ and discard/
-- records, then every saved operation result. Each page is one write with its progress row, in
-- requests of at most 64 KiB. Only the row kv_import = done ends the import, and until then every
-- read of the records fails with unavailable.
local tests_dir = H.args.file:match('^(.*)/[^/]*$')
local load_sandbox = load_fixture(tests_dir .. '/support/sandbox.lua')
local base = getfenv(1)
local json = rex.json

local function part(v) return #v .. ':' .. v end
local function meta(name)
  local r = sql('SELECT value FROM meta WHERE name = ?', {name})[1]
  return r and r.value
end
local function count(t) return sql('SELECT count(*) AS n FROM ' .. t)[1].n end

-- kv is a hub.store version's state: the catalog record, records by key (open/, discard/), and saved
-- operations {key = {fingerprint, result}}. The stubs page a scan by limit records, in key order.
local function stub_store(s, kv, limit)
  limit = limit or 500
  s.catalog = kv.catalog
  local function page(keys, after)
    table.sort(keys)
    local out = {}
    for _, k in ipairs(keys) do
      if (not after or k > after) and #out < limit + 1 then out[#out + 1] = k end
    end
    local next
    if #out > limit then out[#out] = nil; next = out[#out] end
    return out, next
  end
  s.hub_answers['hub.store.scan'] = function(a)
    local keys = {}
    for k in pairs(kv.records or {}) do if k:sub(1, #a.prefix) == a.prefix then keys[#keys + 1] = k end end
    local list, next = page(keys, a.after)
    local records = {}
    for _, k in ipairs(list) do records[k] = {rev = '1', value = kv.records[k]} end
    return {records = records, next = next}
  end
  s.hub_answers['hub.store.ops_scan'] = function(a)
    local keys = {}
    for k in pairs(kv.ops or {}) do keys[#keys + 1] = k end
    local list, next = page(keys, a.after)
    local ops = {}
    for i, k in ipairs(list) do ops[i] = {key = k, fingerprint = kv.ops[k].fingerprint, result = kv.ops[k].result} end
    return {ops = ops, next = next}
  end
end
local function sandbox(kv, limit, opts)
  local s = load_sandbox(tests_dir .. '/..', base, opts)
  assert_true(s.loaded, 'the plugin loads: ' .. tostring(s.load_error))
  expect(s.exited, 'the SDK registered the plugin').to_be(nil)
  s.exec_hook = function(argv)
    if argv[1] == 'git' then return {ok = true, stdout = '', stderr = ''} end
  end
  stub_store(s, kv, limit)
  return s
end
local function list(s) return s:perform('worktree.list', {}, s.agent) end

local id = part('alice') .. part('k1')
local function kv_state()
  return {
    catalog = {repos = {['/r/.git'] = '/r'}, owners = {['/x'] = {agent = 'alice'}},
      pending = {[id] = {kind = 'remove', phase = 'prepared', path = '/sandbox/worktrees/r/t', fingerprint = 'remove/' .. part('/sandbox/worktrees/r/t'), actor = 'alice'}}},
    records = {
      ['open/' .. part('alice') .. part('worktree-open/o1')] = {fingerprint = 'f-open', phase = 'ready', request = {profile = 'shell'}},
      ['open/' .. part('bob') .. part('worktree-open/o2')] = {fingerprint = 'f-open2', phase = 'ready', request = {profile = 'shell'}},
      ['discard/' .. part('alice') .. part('d1')] = {fingerprint = 'discard-v1/x', id = id},
    },
    ops = {
      [part('alice') .. part('done')] = {fingerprint = 'create/' .. part('/r') .. part('done') .. part(''), result = {path = '/sandbox/worktrees/r/done', repo = '/r', branch = 'done', created = true}},
      [part('bob') .. part('gone')] = {fingerprint = 'forget/' .. part('/q'), result = {forgotten = true, repo = '/q', unattributed_count = 0}},
    },
  }
end

test('the first start copies every source; the catalog keeps no owners', function()
  local s = sandbox(kv_state(), 1)
  s:tick()
  expect(meta('kv_import')).to_be('done')
  expect(s:repos()['/r/.git']).to_be('/r')
  expect(s:pending()[id].phase).to_be('prepared')
  expect(count('reservations')).to_be(3)
  expect(count('ops')).to_be(2)
  local discard = json.decode(sql('SELECT record FROM reservations WHERE key = ?', {'discard/' .. part('alice') .. part('d1')})[1].record)
  expect(discard.id).to_be(id)
  -- A second start (a restart) finds the done row and reads no hub.store record.
  local again = sandbox(kv_state(), 1, {keep = true})
  again:tick()
  expect(again.calls['hub.store.get'] or 0).to_be(0)
  expect(again.calls['hub.store.ops_scan'] or 0).to_be(0)
end)

test('a failed page stops the import; reads fail with unavailable; the next start goes on from the progress row', function()
  local s = sandbox(kv_state(), 1)
  -- The open/ source has two pages (limit 1): from the second scan on, the scans fail until the
  -- test ends that, so the second page commits nothing.
  local scans = {n = 0, down = true}
  s.on_hub['hub.store.scan'] = function()
    scans.n = scans.n + 1
    s.hub_errors['hub.store.scan'] = scans.n >= 2 and scans.down and 'stream response "c" failed: store down (status=503 code=unavailable)' or nil
  end
  s:tick()
  expect(meta('kv_import')).to_be(nil)
  -- Keys sort as bytes: open/3:bob... comes before open/5:alice....
  expect(meta('kv_import_progress')).to_be('2:' .. 'open/' .. part('bob') .. part('worktree-open/o2'))
  expect(count('reservations'), 'the first open/ page').to_be(1)
  -- No read of the records before the done row: an action and a panel render fail.
  local reply = list(s)
  expect(reply.error and reply.error.code).to_be('unavailable')
  local render = s:perform('view.render', {route = '/panels/worktrees'})
  expect(render.error and render.error.code).to_be('unavailable')
  -- The next action's start resumes after the first open/ record (the scan error is gone).
  scans.down = false
  local gets = s.calls['hub.store.get'] or 0
  expect(list(s).result ~= nil, 'the list answers after the import').to_be(true)
  expect(s.calls['hub.store.get'] or 0, 'the catalog page is not read again').to_be(gets)
  expect(meta('kv_import')).to_be('done')
  expect(count('reservations')).to_be(3)
  expect(count('ops')).to_be(2)
end)

test('a page whose commit reply was lost is not copied again: the retry starts after its progress row', function()
  local s = sandbox(kv_state(), 1)
  -- The batch of the first ops page commits, and its reply is lost.
  local lost = {done = false}
  s.hub_answers['hub.sql.batch'] = function(a)
    local result = s.sql('batch', a)
    if not lost.done and a.statements[1].sql:find('INTO ops', 1, true) then
      lost.done = true
      return nil, 'stream response "c" failed: lost (status=504 code=timeout)'
    end
    return result
  end
  s:tick()
  expect(lost.done).to_be(true)
  expect(meta('kv_import')).to_be(nil)
  expect(list(s).result ~= nil).to_be(true)
  expect(meta('kv_import')).to_be('done')
  expect(count('ops'), 'each saved result once').to_be(2)
end)

test('a large catalog splits into requests of at most 64 KiB; only the last one moves the cursor', function()
  local kv = kv_state()
  for i = 1, 40 do
    kv.catalog.pending[part('alice') .. part('big-' .. i)] = {kind = 'remove', phase = 'prepared', path = '/sandbox/worktrees/r/big-' .. i,
      fingerprint = 'f', actor = 'alice', note = string.rep('x', 4000)}
  end
  local s = sandbox(kv)
  local sizes = {}
  s.hub_answers['hub.sql.batch'] = function(a)
    local text = json.encode(a.statements)
    local bytes = #json.encode({client_id = 'hub', action = 'hub.sql.batch', args = a, timeout_ms = 10000})
    sizes[#sizes + 1] = {bytes = bytes, progress = text:find('kv_import_progress', 1, true) ~= nil}
    return s.sql('batch', a)
  end
  s:tick()
  expect(meta('kv_import')).to_be('done')
  expect(#sizes > 4, 'several batches').to_be(true)
  -- The catalog page: every batch but its last has no progress row.
  local first_progress
  for i, b in ipairs(sizes) do
    expect(b.bytes <= 65536, 'batch ' .. i .. ' is within the limit: ' .. b.bytes).to_be(true)
    if b.progress and not first_progress then first_progress = i end
  end
  expect(first_progress > 1, 'the progress row comes with the last batch of the catalog page').to_be(true)
  expect(count('pending')).to_be(41)
end)

test('after the import, empty tables stay empty at a restart (Forget is not undone)', function()
  local s = sandbox(kv_state())
  s:tick()
  sql_write('DELETE FROM repos')
  local again = sandbox(kv_state(), nil, {keep = true})
  again:tick()
  expect(next(again:repos()), 'no repository again').to_be(nil)
end)

test('an imported result that no pending operation names replays for its key; no Git block starts', function()
  local s = sandbox(kv_state())
  s:tick()
  local blocks = {n = 0}
  s.rex_answers['session.new_block'] = function() blocks.n = blocks.n + 1; return {block_id = 'b'} end
  local reply = s:perform('worktree.create', {repo = '/r', branch = 'done', key = 'done'}, s.agent)
  expect(reply.result and reply.result.created, show(reply.error)).to_be(true)
  expect(reply.result.path).to_be('/sandbox/worktrees/r/done')
  expect(blocks.n, 'no Git block for a replay').to_be(0)
end)

-- A record whose JSON inside a SQL parameter is larger than one request (16000 quotes: 64000
-- bytes) goes in pieces; its page is several batches in one transaction.
local big_key = 'open/' .. part('alice') .. part('worktree-open/big')
local function big_state()
  local kv = kv_state()
  kv.records[big_key] = {fingerprint = 'f-big', actor = 'alice', phase = 'ready',
    request = {profile = 'task', args = {task = string.rep('"', 16000), note = string.rep('"', 1000) .. 'é'}}}
  return kv
end
local function big_copied()
  local r = json.decode(sql('SELECT record FROM reservations WHERE key = ?', {big_key})[1].record)
  expect(r.request.args.task).to_be(string.rep('"', 16000))
  expect(r.request.args.note).to_be(string.rep('"', 1000) .. 'é')
end

test('each hub.sql request of the import is at most 64 KiB; a large record is copied exactly', function()
  local s = sandbox(big_state())
  local sizes = {max = 0}
  for _, action in ipairs({'hub.sql.batch', 'hub.sql.exec'}) do
    s.hub_answers[action] = function(a)
      local n = #json.encode({client_id = 'hub', action = action, args = a, timeout_ms = 10000})
      if n > sizes.max then sizes.max = n end
      return s.sql(action:sub(9), a)
    end
  end
  s:tick()
  expect(meta('kv_import')).to_be('done')
  expect(sizes.max <= 65536, 'the largest request: ' .. sizes.max).to_be(true)
  expect(s.transactions > 0, 'the page of the large record is one transaction').to_be(true)
  big_copied()
  expect(count('reservations')).to_be(4)
end)

test('a failure between the batches of a page rolls the page back; the retry copies it exactly', function()
  local s = sandbox(big_state())
  -- The second batch in a transaction fails once.
  local state = {n = 0, failed = false}
  s.hub_answers['hub.sql.batch'] = function(a)
    if a.tx and not state.failed then
      state.n = state.n + 1
      if state.n == 2 then state.failed = true; return nil, 'stream response "c" failed: lost (status=503 code=unavailable)' end
    end
    return s.sql('batch', a)
  end
  s:tick()
  expect(state.failed).to_be(true)
  expect(meta('kv_import')).to_be(nil)
  -- The page of open/ (with the large record) wrote nothing: the progress row is still at the start of open/.
  expect(meta('kv_import_progress')).to_be('2:')
  expect(count('reservations')).to_be(0)
  expect(count('staging'), 'no staging row stays').to_be(0)
  expect(list(s).result ~= nil, 'the list answers after the retry').to_be(true)
  expect(meta('kv_import')).to_be('done')
  big_copied()
  expect(count('reservations')).to_be(4)
end)

-- A saved result of an older version with a key of 25000 quotes (50000 bytes in a request): the
-- key goes unchanged into its row and into the progress row, and no request is over 64 KiB.
test('a key of 25000 quotes imports unchanged; it is the progress cursor of the next page', function()
  local kv = kv_state()
  local big = part('alice') .. part(string.rep('"', 25000))
  kv.ops[big] = {fingerprint = 'create/x', result = {path = '/r/t', note = string.rep('"', 6000)}}
  local s = sandbox(kv, 1)
  local state = {max = 0, failed = false}
  for _, action in ipairs({'hub.sql.batch', 'hub.sql.exec', 'hub.sql.query'}) do
    s.hub_answers[action] = function(a)
      local n = #json.encode({client_id = 'hub', action = action, args = a, timeout_ms = 10000})
      if n > state.max then state.max = n end
      return s.sql(action:sub(9), a)
    end
  end
  -- The ops page after the large key fails once: the progress row keeps that key.
  local scan = s.hub_answers['hub.store.ops_scan']
  s.hub_answers['hub.store.ops_scan'] = function(a)
    if a.after == big and not state.failed then
      state.failed = true
      return nil, 'stream response "c" failed: store down (status=503 code=unavailable)'
    end
    return scan(a)
  end
  s:tick()
  expect(meta('kv_import')).to_be(nil)
  expect(meta('kv_import_progress')).to_be('4:' .. big)
  expect(list(s).result ~= nil, 'the list answers after the retry').to_be(true)
  expect(meta('kv_import')).to_be('done')
  local r = sql('SELECT result FROM ops WHERE key = ?', {big})
  expect(#r).to_be(1)
  expect(json.decode(r[1].result).note).to_be(string.rep('"', 6000))
  expect(count('ops')).to_be(3)
  expect(count('staging'), 'no staging row stays').to_be(0)
  expect(state.max <= 65536, 'the largest request: ' .. state.max).to_be(true)
end)
