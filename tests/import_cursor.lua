-- The import with a page cursor near the largest key that hub.store keeps (real hub;
-- docs/sdk-port.md, section 3). A key of 32122 quotes is 64244 bytes in a request: the largest key
-- that put_operation stored, with fingerprint f and the result {} (observed on Rex
-- 0.0.1792158932-g88fd41, hub/sql-r2 f6f1a03). hub.store.ops_scan ends a page at 512 KiB of
-- records, so 7 results of 29000 quotes and that key fill one page, and the next page starts
-- after that key: the plugin sends it as the cursor (after) and keeps it in the progress row.
local alice = agent('alice')
local json = rex.json
local function part(v) return #v .. ':' .. v end
local function q(n) return string.rep('"', n) end
local big = part('alice') .. part(q(32122))
local before, after = {}, part('alice') .. part('zzzz')
for i = 1, 7 do before[i] = part('alice') .. part('f' .. i) end
for _, key in ipairs(before) do put_operation{key = key, fingerprint = 'f', result = {note = q(29000)}} end
put_operation{key = big, fingerprint = 'f', result = {}}
put_operation{key = after, fingerprint = 'f', result = {note = q(29000)}}

test('a cursor of 64244 bytes pages the saved results; every key and value is copied exactly', function()
  H.hub('hub.admin.stop', {plugin = 'worktrees'})
  for _, t in ipairs({'repos', 'pending', 'ops', 'reservations', 'meta', 'staging'}) do sql_write('DELETE FROM ' .. t) end
  H.hub('hub.admin.start', {plugin = 'worktrees'})
  local deadline = os.time() + 20
  while not H.hub('hub.test.status', {}).plugins.worktrees.registered do
    if os.time() >= deadline then error('the plugin did not register') end
    rex.sleep(0.1)
  end
  alice:call('worktree.list', {}) -- an error here fails the case
  expect(sql("SELECT value FROM meta WHERE name = 'kv_import'")[1].value).to_be('done')
  -- The second ops page started after the large key.
  local cursors = 0
  for _, c in ipairs(calls('hub.store.ops_scan')) do if c.args.after == big then cursors = cursors + 1 end end
  expect(cursors >= 1, 'a page after the large key').to_be(true)
  -- The key is not a parameter of this check: it reads the long key from the table.
  local r = sql('SELECT key, fingerprint, result FROM ops WHERE length(key) > 30000')
  expect(#r).to_be(1)
  expect(r[1].key == big, 'the key is unchanged').to_be(true)
  expect(r[1].fingerprint).to_be('f')
  expect(r[1].result).to_be('{}')
  for _, key in ipairs({before[1], before[7], after}) do
    local row = sql('SELECT result FROM ops WHERE key = ?', {key})[1]
    expect(json.decode(row.result).note).to_be(q(29000))
  end
  expect(sql('SELECT count(*) AS n FROM ops')[1].n).to_be(9)
  expect(sql('SELECT count(*) AS n FROM staging')[1].n).to_be(0)
end)
