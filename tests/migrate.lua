-- The schema: step 7 drops the meta table (the state of the removed hub.store import). A fresh
-- database and a database at schema 6 (the version before step 7) end with the same tables and
-- version. The upgrade keeps every record: the recorded repositories, the pending operations, the
-- saved operation results, the reservations and the staging table.
local W = load_fixture(H.args.file:match('^(.*)/[^/]*$') .. '/support/fixture.lua')
local alice = agent('alice')
local json = rex.json
local part = W.part

local function version() return tonumber(sql('PRAGMA user_version')[1].user_version) end
local function tables()
  local names = {}
  for _, r in ipairs(sql("SELECT name FROM sqlite_schema WHERE type = 'table' AND name NOT LIKE 'lazyrex_%' AND name NOT LIKE 'sqlite_%' ORDER BY name")) do names[#names + 1] = r.name end
  return table.concat(names, ',')
end
local current = 'ops,pending,repos,reservations,staging'

-- restart stops the plugin, runs fn while it is stopped, and starts it again.
local function restart(fn)
  H.hub('hub.admin.stop', {plugin = 'worktrees'})
  fn()
  H.hub('hub.admin.start', {plugin = 'worktrees'})
  local deadline = os.time() + 20
  while not H.hub('hub.test.status', {}).plugins.worktrees.registered do
    if os.time() >= deadline then error('the plugin did not register', 2) end
    rex.sleep(0.1)
  end
end

test('a fresh database has schema 7 and no meta table', function()
  alice:call('worktree.list', {})
  expect(version()).to_be(7)
  expect(tables()).to_be(current)
end)

test('a database at schema 6 goes to schema 7: meta goes, and every record stays', function()
  local pending_id = part('alice') .. part('p1')
  local op_key = part('alice') .. part('done')
  local open_key = 'open/' .. part('alice') .. part('worktree-open/o1')
  local discard_key = 'discard/' .. part('alice') .. part('d1')
  local before
  local pending_op = {kind = 'remove', phase = 'prepared', path = H.args.lab .. '/worktrees/x/none', fingerprint = 'remove/x',
    actor = 'alice', created_at = '2026-10-22T00:00:00Z'}
  restart(function()
    sql_write('CREATE TABLE meta (name TEXT PRIMARY KEY, value TEXT NOT NULL)')
    sql_write("INSERT INTO meta (name, value) VALUES ('kv_import', 'done')")
    sql_write('PRAGMA user_version = 6')
    sql_write('INSERT INTO repos (common, repo) VALUES (?, ?)', {'/r/.git', '/r'})
    sql_write('INSERT INTO pending (id, op) VALUES (?, ?)', {pending_id, json.encode(pending_op)})
    sql_write('INSERT INTO ops (key, fingerprint, result) VALUES (?, ?, ?)', {op_key, 'create/x', json.encode({path = '/r/done'})})
    sql_write('INSERT INTO reservations (key, record) VALUES (?, ?)', {open_key, json.encode({fingerprint = 'f', actor = 'alice', phase = 'ready'})})
    sql_write('INSERT INTO reservations (key, record) VALUES (?, ?)', {discard_key, json.encode({fingerprint = 'g', id = pending_id})})
    expect(version(), 'the schema before the start').to_be(6)
    expect(tables(), 'the tables before the start').to_be('meta,' .. current)
    before = W.records()
  end)
  local list = alice:call('worktree.list', {})
  expect(version()).to_be(7)
  expect(tables()).to_be(current)
  expect(W.records(), 'every record stays').to_be(before)
  expect(sql('SELECT count(*) AS n FROM staging')[1].n).to_be(0)
  -- The plugin reads the kept records: the pending operation is listed.
  local found = false
  for _, op in ipairs(list.operations or {}) do if op.id == pending_id then found = true end end
  expect(found, 'worktree.list lists the kept pending operation').to_be(true)
end)
