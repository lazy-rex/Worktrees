-- The schema stays at version 6 in this release: a rollback to v0.3.0 must find its tables and a
-- finished import (expand, then contract: the meta table goes one release after the code that read
-- it). A start of this version changes no table and no record, also not the meta row
-- kv_import = done.
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
local function meta() return json.encode(sql('SELECT name, value FROM meta ORDER BY name')) end
local current = 'meta,ops,pending,repos,reservations,staging'

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

test('a fresh database has schema 6 and the tables of v0.3.0', function()
  alice:call('worktree.list', {})
  expect(version()).to_be(6)
  expect(tables()).to_be(current)
end)

test('a start keeps schema 6, the meta rows of the finished import and every record', function()
  local pending_id = part('alice') .. part('p1')
  local pending_op = {kind = 'remove', phase = 'prepared', path = H.args.lab .. '/worktrees/x/none', fingerprint = 'remove/x',
    actor = 'alice', created_at = '2026-10-22T00:00:00Z'}
  local before, before_meta
  restart(function()
    -- The rows that v0.3.0 left after its import.
    sql_write("INSERT OR REPLACE INTO meta (name, value) VALUES ('kv_import', 'done')")
    sql_write("INSERT OR REPLACE INTO meta (name, value) VALUES ('kv_import_progress', '5:')")
    sql_write('INSERT INTO repos (common, repo) VALUES (?, ?)', {'/r/.git', '/r'})
    sql_write('INSERT INTO pending (id, op) VALUES (?, ?)', {pending_id, json.encode(pending_op)})
    sql_write('INSERT INTO ops (key, fingerprint, result) VALUES (?, ?, ?)', {part('alice') .. part('done'), 'create/x', json.encode({path = '/r/done'})})
    sql_write('INSERT INTO reservations (key, record) VALUES (?, ?)', {'discard/' .. part('alice') .. part('d1'), json.encode({fingerprint = 'g', id = pending_id})})
    expect(version(), 'the schema before the start').to_be(6)
    before, before_meta = W.records(), meta()
  end)
  local list = alice:call('worktree.list', {})
  expect(version()).to_be(6)
  expect(tables()).to_be(current)
  expect(meta(), 'the meta rows stay').to_be(before_meta)
  expect(sql("SELECT value FROM meta WHERE name = 'kv_import'")[1].value).to_be('done')
  expect(W.records(), 'every record stays').to_be(before)
  local found = false
  for _, op in ipairs(list.operations or {}) do if op.id == pending_id then found = true end end
  expect(found, 'worktree.list lists the kept pending operation').to_be(true)
end)
