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

-- settle repeats a call while it returns {status = 'running'} (a same-key retry).
function W.settle(fn, what)
  local result
  wait(what or 'the operation finishes', function()
    result = fn()
    return result.status ~= 'running'
  end)
  return result
end

-- route encodes a selected path as the plugin does (route_with_path).
function W.route(base, path)
  return base .. '?path=' .. path:gsub('([^%w%-%._~])', function(c) return string.format('%%%02X', string.byte(c)) end)
end

return W
