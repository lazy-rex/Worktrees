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

-- part and intent name records as the plugin does: part(s) = #s .. ':' .. s.
function W.part(s) return tostring(#s) .. ':' .. s end
function W.intent(actor, spawn_key) return store('open/' .. W.part(actor) .. W.part(spawn_key)).value end

-- route encodes a selected path as the plugin does (route_with_path).
function W.route(base, path)
  return base .. '?path=' .. path:gsub('([^%w%-%._~])', function(c) return string.format('%%%02X', string.byte(c)) end)
end

return W
