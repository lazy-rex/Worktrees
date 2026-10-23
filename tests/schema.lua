-- The base step (docs/plugin-sdk.md, "A base step"): the plugin's entries up to version 6 make the
-- same schema as the steps 1 to 6 that v0.4.0 shipped (sqlite_master: type, name and the SQL with
-- its white space normalized). The test runs the entries that the plugin gives app.db.migrate (the
-- sandbox records them), so it passes with the old steps and with the base.
local tests_dir = H.args.file:match('^(.*)/[^/]*$')
local s = load_fixture(tests_dir .. '/support/sandbox.lua')(tests_dir .. '/..', getfenv(1), {keep = true})

-- The steps 1 to 6 of v0.4.0 and of the 4.2 pin (worktrees.lua at 0f6cb11), one schema version each.
local shipped = {
  'CREATE TABLE repos (common TEXT PRIMARY KEY, repo TEXT NOT NULL)',
  'CREATE TABLE pending (id TEXT PRIMARY KEY, op TEXT NOT NULL)',
  'CREATE TABLE ops (key TEXT PRIMARY KEY, fingerprint TEXT NOT NULL, result TEXT NOT NULL)',
  'CREATE TABLE reservations (key TEXT PRIMARY KEY, record TEXT NOT NULL)',
  'CREATE TABLE meta (name TEXT PRIMARY KEY, value TEXT NOT NULL)',
  'CREATE TABLE staging (slot INTEGER PRIMARY KEY, value TEXT NOT NULL)',
}

local function version() return tonumber(sql('PRAGMA user_version')[1].user_version) end
-- schema gives the plugin's schema objects (not SQLite's or the hub's lazyrex_* objects), one line each.
local function schema(skip)
  local lines = {}
  for _, r in ipairs(sql("SELECT type, name, sql FROM sqlite_master WHERE name NOT LIKE 'sqlite!_%' ESCAPE '!' AND lower(name) NOT LIKE 'lazyrex!_%' ESCAPE '!' ORDER BY type, name")) do
    if r.name ~= skip then lines[#lines + 1] = r.type .. ' ' .. r.name .. ' ' .. tostring(r.sql):gsub('%s+', ' ') end
  end
  return table.concat(lines, '\n')
end
-- empty drops the plugin's tables and sets version 0: a new database.
local function empty()
  for _, r in ipairs(sql("SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite!_%' ESCAPE '!' AND lower(name) NOT LIKE 'lazyrex!_%' ESCAPE '!'")) do
    sql_write('DROP TABLE "' .. r.name .. '"')
  end
  sql_write('PRAGMA user_version = 0')
  expect(schema(), 'the database is empty').to_be('')
end
local d = {exec = function(q, ...) return sql_write(q, {...}) end}

test('the entries up to version 6 make the schema of the shipped steps 1 to 6', function()
  expect(s.loaded, s.load_error).to_be(true)
  expect(#s.migrations).to_be(1)
  local list = s.migrations[1]
  local first = list.base or 1
  expect(first <= 6, 'the base is at most the last version of v0.4.0').to_be(true)
  expect(first + #list - 1 >= 6, 'the entries reach version 6').to_be(true)
  local plugin_schema, shipped_schema, without_meta
  H.hub('hub.admin.stop', {plugin = 'worktrees'})
  local ok, err = pcall(function()
    empty()
    for _, step in ipairs(shipped) do sql_write(step) end
    shipped_schema, without_meta = schema(), schema('meta')
    empty()
    for i, step in ipairs(list) do
      if first + i - 1 <= 6 then
        if type(step) == 'function' then step(d) else sql_write(step) end
      end
    end
    plugin_schema = schema()
    empty()
  end)
  H.hub('hub.admin.start', {plugin = 'worktrees'})
  assert(ok, err)
  expect(plugin_schema).to_be(shipped_schema)
  -- The plugin starts on the new database: the SDK runs the entries up to version 7 (meta goes).
  wait('the plugin registered', function() return H.hub('hub.test.status', {}).plugins.worktrees.registered end, 20)
  local w = agent('alice')
  w:call('worktree.list', {})
  expect(version()).to_be(7)
  expect(schema()).to_be(without_meta)
end)
