-- Shared setup for the Worktrees tests. Every repository and worktree is in the lab directory:
-- the manifest sets worktrees_root to ${LAB}/worktrees (test.args).
local W = {}
local lab = H.args.lab

-- run runs argv (rex.exec) and returns its output; a failure is an error.
function W.run(argv, cwd)
  local r, err = rex.exec(argv, {cwd = cwd, timeout = 30})
  if not r then error('command did not start: ' .. table.concat(argv, ' ') .. ': ' .. tostring(err), 2) end
  if not r.ok then error('command failed: ' .. table.concat(argv, ' ') .. '\n' .. tostring(r.stderr) .. tostring(r.stdout), 2) end
  return (r.stdout:gsub('\n$', ''))
end
-- try runs argv and returns the result without an error on failure.
function W.try(argv, cwd) return rex.exec(argv, {cwd = cwd, timeout = 30}) end

function W.real(path) return W.run({'realpath', path}) end
-- now returns the wall clock in seconds with millisecond resolution. Rex Lua has only os.time
-- (whole seconds). The process start adds to a measured interval, so a bound stays strict.
function W.now() return tonumber(W.run({'perl', '-MTime::HiRes=time', '-e', 'printf("%.3f", time)'})) end

-- git runs Git with a fixed identity; the lab HOME has no Git config.
function W.git(dir, ...)
  local argv = {'git', '-C', dir, '-c', 'user.name=Lab', '-c', 'user.email=lab@example.invalid'}
  for _, a in ipairs({...}) do argv[#argv + 1] = a end
  return W.run(argv)
end

function W.write(path, text)
  local f = assert(io.open(path, 'w'))
  f:write(text)
  f:close()
end

W.run({'mkdir', '-p', lab .. '/worktrees'})
W.root = W.real(lab .. '/worktrees')

-- repo makes a new repository with one commit and returns its real path.
function W.repo(name)
  local dir = lab .. '/repos/' .. name
  W.run({'mkdir', '-p', dir})
  W.run({'git', 'init', '-q', '-b', 'main', dir})
  W.write(dir .. '/file.txt', 'one\n')
  W.git(dir, 'add', 'file.txt')
  W.git(dir, 'commit', '-q', '-m', 'one')
  return W.real(dir)
end

-- settle repeats a call while it returns {status = 'running'} (a same-key retry). An error stops it.
function W.settle(fn, what, timeout)
  local deadline = os.time() + (timeout or 20)
  while true do
    local result = fn()
    if result.status ~= 'running' then return result end
    if os.time() >= deadline then error('timed out waiting for ' .. (what or 'the operation'), 2) end
    rex.sleep(0.1)
  end
end

-- repo_id and tree_path compute a new tree path as the plugin does: <root>/<name>-<id>/<branch>,
-- with the ID from the common Git directory path (create.lua checks a fixed test vector).
function W.repo_id(common)
  local h = 0
  for i = 1, #common do h = (h * 257 + common:byte(i)) % 4294967291 end
  return string.format('%06x', h % 16777216)
end
function W.tree_path(repo, branch)
  local common = W.real(W.run({'git', '-C', repo, 'rev-parse', '--path-format=absolute', '--git-common-dir'}))
  return W.root .. '/' .. repo:match('([^/]+)$') .. '-' .. W.repo_id(common) .. '/' .. branch
end

-- part and intent name records as the plugin does: part(s) = #s .. ':' .. s.
function W.part(s) return tostring(#s) .. ':' .. s end

-- The plugin's SQL records (worktrees.lua, the schema). catalog gives {repos, pending}: the
-- recorded repositories and the pending operations; set_catalog replaces both tables with it, as
-- another writer would. reservation gives the record of a discard/ or open/ key (nil if none);
-- set_reservation writes it (nil deletes it). records gives a text of every table, to show that a
-- call changed nothing.
function W.catalog()
  local state = {repos = {}, pending = {}}
  for _, r in ipairs(sql('SELECT common, repo FROM repos')) do state.repos[r.common] = r.repo end
  for _, r in ipairs(sql('SELECT id, op FROM pending')) do state.pending[r.id] = rex.json.decode(r.op) end
  return state
end
function W.set_catalog(state)
  sql_write('DELETE FROM repos')
  sql_write('DELETE FROM pending')
  for common, repo in pairs(state.repos or {}) do sql_write('INSERT INTO repos (common, repo) VALUES (?, ?)', {common, repo}) end
  for id, op in pairs(state.pending or {}) do sql_write('INSERT INTO pending (id, op) VALUES (?, ?)', {id, rex.json.encode(op)}) end
end
function W.reservation(key)
  local r = sql('SELECT record FROM reservations WHERE key = ?', {key})[1]
  return r and rex.json.decode(r.record) or nil
end
function W.set_reservation(key, record)
  if record == nil then sql_write('DELETE FROM reservations WHERE key = ?', {key})
  else sql_write('INSERT OR REPLACE INTO reservations (key, record) VALUES (?, ?)', {key, rex.json.encode(record)}) end
end
-- put_op saves an operation result, as the plugin's finish does.
function W.put_op(key, fingerprint, result)
  sql_write('INSERT INTO ops (key, fingerprint, result) VALUES (?, ?, ?)', {key, fingerprint, rex.json.encode(result)})
end
function W.records()
  local parts = {}
  for _, t in ipairs({'repos', 'pending', 'ops', 'reservations'}) do
    parts[#parts + 1] = t .. '=' .. rex.json.encode(sql('SELECT * FROM ' .. t .. ' ORDER BY 1'))
  end
  return table.concat(parts, '\n')
end
function W.intent(actor, spawn_key) return W.reservation('open/' .. W.part(actor) .. W.part(spawn_key)) end

-- route encodes a selected path as the plugin does (route_with_path).
function W.route(base, path)
  return base .. '?path=' .. path:gsub('([^%w%-%._~])', function(c) return string.format('%%%02X', string.byte(c)) end)
end

return W
