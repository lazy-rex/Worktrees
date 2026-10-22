-- The import of the hub.store records into SQL with the real hub (docs/sdk-port.md, section 3;
-- docs/testing.md, "Hub restart"). Each source has one record whose JSON inside a SQL parameter is
-- larger than one request (64 KiB): its page is several batches in one transaction. A case
-- stops the plugin, empties its tables (the state before a first start), arms a commit injection
-- for one source, and starts the plugin: its start-up import stops at that source. A crash restart
-- then gives a new plugin process, which goes on from the progress row and copies every record
-- exactly once.
local W = load_fixture(H.args.file:match('^(.*)/[^/]*$') .. '/support/fixture.lua')
local alice = agent('alice')
local json = rex.json
local part = W.part
local tables = {'repos', 'pending', 'ops', 'reservations', 'meta', 'staging'}

-- q(n) is n double quotes: each one is 2 bytes in the record JSON and 4 bytes in a request.
local function q(n) return string.rep('"', n) end
local pending_id = part('alice') .. part('p1')
local open_key = 'open/' .. part('alice') .. part('worktree-open/old')
local discard_key = 'discard/' .. part('alice') .. part('d1')
local op_key = part('alice') .. part('done')
local pending_op = {kind = 'remove', phase = 'prepared', path = H.args.lab .. '/worktrees/x/none', fingerprint = 'remove/x', actor = 'alice', note = q(16000)}
local intent = {fingerprint = 'f', actor = 'alice', phase = 'ready', request = {
  profile = 'task', key = 'worktree-open/old', cwd = '/tmp', args = {task = q(16000), note = q(1000)}}}

-- The records of the hub.store version, in the plugin's namespace (one write each: one request
-- is at most 64 KiB).
write({{key = 'catalog', value = {repos = {['/r/.git'] = '/r'}, pending = {[pending_id] = pending_op}}}})
write({{key = open_key, value = intent}})
write({{key = discard_key, value = {fingerprint = q(16000), id = pending_id}}})
put_operation{key = op_key, fingerprint = 'create/x', result = {path = '/r/done', note = q(16000)}}
-- A key of 25000 quotes: 50000 bytes in a request, with each statement and the progress row.
local big_key = part('alice') .. part(q(25000))
put_operation{key = big_key, fingerprint = 'create/x', result = {path = '/r/t', note = q(6000)}}

local function meta(name)
  local r = sql('SELECT value FROM meta WHERE name = ?', {name})[1]
  return r and r.value
end
local function count(t) return sql('SELECT count(*) AS n FROM ' .. t)[1].n end
local function reservation(key)
  local r = sql('SELECT record FROM reservations WHERE key = ?', {key})[1]
  return r and json.decode(r.record)
end
-- copied(source) checks the rows of one source: each value exactly, each record once.
local copied = {
  function()
    expect(sql('SELECT repo FROM repos WHERE common = ?', {'/r/.git'})[1].repo).to_be('/r')
    local op = json.decode(sql('SELECT op FROM pending WHERE id = ?', {pending_id})[1].op)
    expect(op.note).to_be(pending_op.note)
    expect(op.path).to_be(pending_op.path)
    expect(count('repos')).to_be(1)
    expect(count('pending')).to_be(1)
  end,
  function()
    local r = reservation(open_key)
    expect(r.request.args.task).to_be(intent.request.args.task)
    expect(r.request.args.note).to_be(intent.request.args.note)
    expect(r.request.key).to_be('worktree-open/old')
  end,
  function()
    local r = reservation(discard_key)
    expect(r.fingerprint).to_be(q(16000))
    expect(r.id).to_be(pending_id)
    expect(count('reservations')).to_be(2)
  end,
  function()
    local r = sql('SELECT fingerprint, result FROM ops WHERE key = ?', {op_key})
    expect(#r).to_be(1)
    expect(r[1].fingerprint).to_be('create/x')
    expect(json.decode(r[1].result).note).to_be(q(16000))
    local b = sql('SELECT fingerprint, result FROM ops WHERE key = ?', {big_key})
    expect(#b).to_be(1)
    expect(json.decode(b[1].result).note).to_be(q(6000))
    expect(count('ops')).to_be(2)
  end,
}
local function absent(source)
  if source == 1 then expect(count('repos') + count('pending')).to_be(0)
  elseif source == 2 then expect(reservation(open_key)).to_be(nil)
  elseif source == 3 then expect(reservation(discard_key)).to_be(nil)
  else expect(count('ops')).to_be(0) end
end

-- fresh_start stops the plugin, empties its tables, runs arm() and starts the plugin again.
local function fresh_start(arm)
  H.hub('hub.admin.stop', {plugin = 'worktrees'})
  for _, t in ipairs(tables) do sql_write('DELETE FROM ' .. t) end
  local id = arm and arm()
  H.hub('hub.admin.start', {plugin = 'worktrees'})
  local deadline = os.time() + 20
  while not H.hub('hub.test.status', {}).plugins.worktrees.registered do
    if os.time() >= deadline then error('the plugin did not register', 2) end
    rex.sleep(0.1)
  end
  return id
end
local function wait_consumed(id)
  local deadline = os.time() + 20
  while (injection(id).consumed or 0) < 1 do
    if os.time() >= deadline then error('the injection did not match', 2) end
    rex.sleep(0.1)
  end
end
-- complete restarts the hub (a crash), so a new plugin process imports, and checks every record.
local function complete()
  hub:restart({crash = true})
  alice:call('worktree.list', {}) -- an error here fails the case
  expect(meta('kv_import')).to_be('done')
  for _, check in ipairs(copied) do check() end
  expect(count('staging'), 'no staging row stays').to_be(0)
end

test('records larger than one request import exactly after a crash restart', function()
  fresh_start()
  complete()
end)

-- The table that each source writes, and the matching commits to let pass before it. An
-- injection with times = always also fails each retry of the running process (a view or an event
-- starts the import again), so the state stays at the transition until the restart, which ends
-- every injection. The hub uses the first live injection that matches.
local transitions = {{'pending', 0}, {'reservations', 0}, {'reservations', 1}, {'ops', 0}}
for source, t in ipairs(transitions) do
  test('a failed commit of source ' .. source .. ' rolls back the page; the next process goes on from there', function()
    local id = fresh_start(function() return inject{match = {sql_commit_writes = t[1]}, skip = t[2], times = 'always', fail = 'injected crash'} end)
    wait_consumed(id)
    -- The commit of that page failed: the earlier sources are copied, that page wrote nothing.
    expect(meta('kv_import')).to_be(nil)
    expect(meta('kv_import_progress')).to_be(source > 1 and (source .. ':') or nil)
    for i = 1, source - 1 do copied[i]() end
    for i = source, #copied do absent(i) end
    expect(count('staging'), 'the failed page left no staging row').to_be(0)
    complete()
    -- The new process did not read the sources before the progress row again.
    if source > 1 then expect(#calls('hub.store.get'), 'the catalog is not read again').to_be(0) end
  end)
  test('a lost reply of the commit of source ' .. source .. ': the next process starts after that page', function()
    local id = fresh_start(function()
      local lost = inject{match = {sql_commit_writes = t[1]}, skip = t[2], fail = 'injected lost reply', after = true}
      -- The next source's page fails in this process (after the lost one: skip 0).
      if transitions[source + 1] then inject{match = {sql_commit_writes = transitions[source + 1][1]}, times = 'always', fail = 'injected crash'} end
      return lost
    end)
    wait_consumed(id)
    -- The page committed with its progress row, and the reply was lost.
    expect(meta('kv_import_progress')).to_be((source + 1) .. ':')
    for i = 1, source do copied[i]() end
    for i = source + 1, #copied do absent(i) end
    complete()
    if source == #copied then expect(#calls('hub.store.ops_scan'), 'the import ended with that page').to_be(0) end
  end)
end
