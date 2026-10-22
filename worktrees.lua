-- Worktree management. Git owns the trees. The hub owns operation records and cwd locks.
local app = require('lazyrex').plugin('worktrees')
local plugin_session = assert(app.session_id, 'plugin_session is required')
local fail, hub = app.fail, app.hub
-- Worktrees keeps its own operation records and saved results (hub.store), so no handler or event
-- uses an SDK transaction or a saved reply.
local raw = {tx = false, store = false}
local function text(value, name)
  if type(value) ~= 'string' or value == '' or value:find('%z') then fail('invalid_input', name .. ' must be nonempty text without NUL') end
  return value
end
local function part(value) return tostring(#value) .. ':' .. value end
local git_env = {GIT_DIR = false, GIT_WORK_TREE = false, GIT_COMMON_DIR = false,
  GIT_INDEX_FILE = false, GIT_CONFIG_COUNT = false, GIT_CONFIG_PARAMETERS = false}
local function run(argv, cwd)
  local result, err = rex.exec(argv, {cwd = cwd, env = git_env, timeout = 30})
  if not result then fail('unavailable', tostring(err or 'Command did not start')) end
  return result
end
local function checked(argv, cwd)
  local r = run(argv, cwd)
  if not r.ok then fail('git_error', r.stderr ~= '' and r.stderr or 'Command failed') end
  return r.stdout
end
local function line(value) return (value:gsub('\n$', '')) end
local function real(path) return line(checked({'realpath', path})) end
local function exists(path) return run({'test', '-e', path}).ok or run({'test', '-L', path}).ok end
local function within(path, root) return path:sub(1, #root + 1) == root .. '/' end
local root_arg = app.args.worktrees_root or ((os.getenv('HOME') or '') .. '/.lazyrex/worktrees')
if root_arg:sub(1, 1) ~= '/' then fail('invalid_input', 'The worktree root must be absolute') end
-- A lab passes an isolated root explicitly. The production default is ~/.lazyrex/worktrees.
checked({'mkdir', '-p', root_arg})
local root = real(root_arg)

local function git(common, args)
  local argv = {'git', '--git-dir', common}
  for _, value in ipairs(args) do argv[#argv + 1] = value end
  return run(argv)
end
local function git_ok(common, args)
  local r = git(common, args)
  if not r.ok then fail('git_error', r.stderr ~= '' and r.stderr or 'Git failed') end
  return r.stdout
end
local function trees(common)
  local rows, row = {}, nil
  for field in git_ok(common, {'worktree', 'list', '--porcelain', '-z'}):gmatch('([^%z]*)%z') do
    if field:sub(1, 9) == 'worktree ' then
      row = {path = field:sub(10)}
      rows[#rows + 1] = row
    elseif row and field:sub(1, 7) == 'branch ' then row.branch = field:sub(8):gsub('^refs/heads/', '')
    elseif row and field == 'detached' then row.detached = true
    elseif row and field == 'bare' then row.bare = true
    elseif row and field:sub(1, 6) == 'locked' then row.locked = true end
  end
  return rows
end
local function repo_info(path)
  text(path, 'repo')
  if path:sub(1, 1) ~= '/' then fail('invalid_input', 'repo must be an absolute directory') end
  local top = line(checked({'git', '-C', path, 'rev-parse', '--show-toplevel'}))
  local common = real(line(checked({'git', '-C', top, 'rev-parse', '--path-format=absolute', '--git-common-dir'})))
  local list = trees(common)
  if not list[1] then fail('invalid_input', 'The repository has no worktrees') end
  return {repo = real(list[1].path), common = common, top = real(top)}
end
-- repo_id is 6 hex digits from the common Git directory path: h = (h * 257 + byte) mod 4294967291,
-- from h = 0. The values stay below 2^53, so Lua 5.1 numbers are exact. An ID collision cannot
-- reuse a wrong tree: same_tree checks the repository and the branch.
local function repo_id(common)
  local h = 0
  for i = 1, #common do h = (h * 257 + common:byte(i)) % 4294967291 end
  return string.format('%06x', h % 16777216)
end
local function find_tree(common, path)
  for _, tree in ipairs(trees(common)) do if tree.path == path then return tree end end
end
-- The plugin runs git status in the background, so it never writes the index: a plain git status
-- writes a refreshed index under index.lock, and a git commit of the user in that tree then fails
-- (Git: git-status, "Background refresh").
local function status_command(path, ignored)
  local argv = {'git', '--no-optional-locks', '-C', path, 'status', '--porcelain=v1', '-z', '--untracked-files=all', '--ignore-submodules=none'}
  if ignored then argv[#argv + 1] = '--ignored' end
  return argv
end
local function identity(path)
  local dir = real(line(checked({'git', '-C', path, 'rev-parse', '--absolute-git-dir'})))
  -- Rex runs on macOS. Birth time and inode distinguish a replacement at the same path.
  return dir .. '\n' .. checked({'stat', '-f', '%d:%i:%B', dir})
end
local function catalog()
  local r = hub('hub.store.get', {keys = {'catalog'}}).records.catalog
  if not r or type(r.rev) ~= 'string' then fail('internal', 'Missing worktree catalog') end
  local state = r.value or {repos = {}, pending = {}}
  -- An older version kept owners (the agent that created a tree). No rule uses them (decision
  -- "Agents may act on anything", 2026-10-19): an agent may remove any tree. The next save drops them.
  state.owners = nil
  return state, r.rev
end
-- A caller is the user (the view path) or an agent (the SDK ctx). aliases are the agent ID and its
-- legacy IDs (ctx.aliases) after an identity migration, current first. An operation ID is part(actor)..part(key).
local user_caller = {agent = 'user', aliases = {'user'}, user = true}
local function agent_caller(ctx)
  local aliases, seen = {ctx.agent}, {[ctx.agent] = true}
  for _, id in ipairs(type(ctx.aliases) == 'table' and ctx.aliases or {}) do
    if type(id) == 'string' and id ~= '' and not seen[id] then aliases[#aliases + 1] = id; seen[id] = true end
  end
  return {agent = ctx.agent, aliases = aliases, session = ctx.session_id}
end
local function save(state, rev, op)
  local args = {ops = {{key = 'catalog', if_rev = rev, value = state}}}
  if op then args.op = op end
  local result = hub('hub.store.batch', args)
  if result.conflict then fail('conflict', 'The worktree catalog changed; retry with the same key') end
  if not result.revs and not result.op_exists then fail('internal', 'Invalid store result') end
  return result
end
local function rex_ok(method, args)
  local result, err = rex.call(method, args)
  if not result then fail('unavailable', type(err) == 'table' and err.message or tostring(err)) end
  return result
end
local function operation_blocks(op)
  local sessions = rex_ok('session.list', {}).sessions or {}
  local live = false
  for _, session in ipairs(sessions) do if session.session_id == op.session then live = true end end
  if not live then return {}, true end
  if op.session ~= plugin_session then rex_ok('session.attach', {session_id = op.session, event_scope = 'session'}) end
  return rex_ok('session.list_blocks', {session_id = op.session}).blocks or {}, false
end
local function cleanup_done(id)
  local state, rev = catalog()
  local op = state.pending[id]
  if not op or op.phase ~= 'cleanup' then return end
  if op.block then
    local blocks = operation_blocks(op)
    for _, block in ipairs(blocks) do
      if block.block_id == op.block then
        rex_ok('block.close', {session_id = op.session, block_id = op.block})
      end
    end
  end
  if op.kind == 'remove' then hub('hub.cwd.unlock', {path = op.path, key = id}) end
  state.pending[id] = nil
  save(state, rev)
end
-- Rex owns each Git mutation. Keep the block until the operation result commits.
local function mutation(id, op, args)
  if op.phase ~= 'sending' then
    op.phase = 'sending'
    op.session = plugin_session
    local state, rev = catalog()
    op.label = 'lazyrex-worktree:' .. app.instance_id .. ':' .. rev
    state.pending[id] = op
    save(state, rev)
    local command = {'/usr/bin/env'}
    for name in pairs(git_env) do command[#command + 1] = '-u'; command[#command + 1] = name end
    command[#command + 1] = 'git'; command[#command + 1] = '--git-dir'; command[#command + 1] = op.common
    for _, arg in ipairs(args) do command[#command + 1] = arg end
    local created = rex_ok('session.new_block', {session_id = op.session,
      flavor = 'com.superlogical.terminal.shell', label = op.label,
      options = {command = command, cwd = op.repo, login = false, exit = {on_completion = false}}})
    op.block = created.block_id
    state, rev = catalog()
    state.pending[id] = op
    save(state, rev)
  end
  local blocks, gone = operation_blocks(op)
  if gone then return {missing = true} end
  if op.block then
    local found = false
    for _, block in ipairs(blocks) do if block.block_id == op.block then found = true end end
    if not found then return {missing = true} end
  else
    for _, block in ipairs(blocks) do
      if block.label == op.label then
        if op.block then fail('conflict', 'Several Rex blocks match this operation') end
        op.block = block.block_id
      end
    end
    if not op.block then fail('unresolved', 'The Git process has an unknown start result; a late Rex reply can still create its block') end
    local state, rev = catalog()
    state.pending[id] = op
    save(state, rev)
  end
  local process = rex_ok('com.superlogical.terminal.process', {session_id = op.session, block_id = op.block, args = {}})
  if process.child or not process.last_exit then return nil end
  local message = process.last_exit.error or ('Git exited with code ' .. tostring(process.last_exit.exit_code))
  if process.last_exit.exit_code ~= 0 then
    local screen = rex.call('com.superlogical.terminal.format', {session_id = op.session, block_id = op.block, args = {format = 'text', trim = true, unwrap = true}})
    if screen and screen.content ~= '' then message = message .. '\n' .. screen.content end
  end
  return {ok = process.last_exit.exit_code == 0, stderr = message}
end
local function result_of(saved, fingerprint)
  if saved.fingerprint ~= fingerprint then fail('operation_conflict', 'This key has different content') end
  if saved.result.error then fail(saved.result.error.code, saved.result.error.message) end
  return saved.result
end
-- tail keeps the end of an error text within 4096 bytes of encoded JSON (the quotes, the marker
-- and every escape included), from a UTF-8 character boundary. A Git hook can print much more
-- (300 KB), and the operation record must fit one control message (64 KiB) with the catalog.
local error_bytes = 4096
local function tail(value)
  if type(value) ~= 'string' or #rex.json.encode(value) <= error_bytes then return value end
  -- The smallest start whose suffix fits: a later start never makes the suffix longer.
  local lo, hi = 1, #value
  while lo < hi do
    local mid = math.floor((lo + hi) / 2)
    if #rex.json.encode('…' .. value:sub(mid)) <= error_bytes then hi = mid else lo = mid + 1 end
  end
  while lo <= #value and value:byte(lo) >= 0x80 and value:byte(lo) < 0xC0 do lo = lo + 1 end
  return '…' .. value:sub(lo)
end
local function finish(id, op, result)
  local state, rev = catalog()
  if result.error then result.error.message = tail(result.error.message) end
  op.phase = 'cleanup'
  state.pending[id] = op
  save(state, rev, {key = id, fingerprint = op.fingerprint, result = result})
  cleanup_done(id)
  if result.error then fail(result.error.code, result.error.message) end
  return result
end
local function admit(id, op)
  local state, rev = catalog()
  for other, pending in pairs(state.pending) do
    if other ~= id and (pending.path == op.path or within(pending.path, op.path) or within(op.path, pending.path)) then
      fail('conflict', 'Another operation owns this path; retry that operation first')
    end
  end
  state.repos[op.common] = op.repo
  state.pending[id] = op
  save(state, rev)
end
local function prepare_parent(path)
  if not within(path, root) then fail('refused', 'The path is outside the worktree root') end
  local parent = path:match('^(.*)/[^/]+$')
  local current = root
  for segment in parent:sub(#root + 2):gmatch('[^/]+') do
    current = current .. '/' .. segment
    if exists(current) then
      if real(current) ~= current then fail('refused', 'A worktree parent is a symbolic link') end
    else checked({'mkdir', current}) end
  end
end
local function same_tree(op)
  if not exists(op.path) then return false end
  if real(op.path) ~= op.path then fail('conflict', 'The worktree path is a symbolic link') end
  local info = repo_info(op.path)
  local tree = find_tree(op.common, op.path)
  if info.top ~= op.path or info.common ~= op.common or not tree or tree.branch ~= op.branch then
    fail('conflict', 'The path does not contain the requested repository and branch')
  end
  return true
end
local checks = {}
local function check_status(id, path, ignored)
  if not checks[id] then
    local handle, err = rex.exec.start(status_command(path, ignored), {env = git_env, timeout = 30, detach = true})
    if not handle then fail('unavailable', tostring(err)) end
    checks[id] = handle
    return nil
  end
  if checks[id]:running() then return nil end
  local result, err = checks[id]:wait(0.001)
  if not result and err == 'timeout' then return nil end
  checks[id] = nil
  if not result then fail('unavailable', tostring(err)) end
  return result
end
local function create(caller, id, fingerprint, args, pending)
  local op = pending
  if not op then
    local info = repo_info(args.repo)
    local branch = text(args.branch, 'branch')
    if branch:sub(1, 1) == '-' or not run({'git', 'check-ref-format', 'refs/heads/' .. branch}).ok then
      fail('invalid_input', 'Invalid Git branch name')
    end
    local name = info.repo:match('([^/]+)$')
    if not name then fail('invalid_input', 'The repository needs a directory name') end
    -- A linked tree of the branch inside the root is the requested tree, also at an older path
    -- layout. The main tree is never one (decision "New worktree paths carry a short repository ID").
    local listed
    for i, tree in ipairs(trees(info.common)) do
      if i > 1 and not tree.bare and tree.branch == branch and within(tree.path, root) then listed = tree.path end
    end
    local path = listed or (root .. '/' .. name .. '-' .. repo_id(info.common) .. '/' .. branch)
    local branch_exists = git(info.common, {'show-ref', '--verify', '--quiet', 'refs/heads/' .. branch}).ok
    local base = branch_exists and ('refs/heads/' .. branch) or (args.base or 'HEAD')
    -- HEAD belongs to the selected worktree, not to the common Git directory's main tree.
    local commit = line(checked({'git', '-C', info.top, 'rev-parse', '--verify', '--end-of-options', base .. '^{commit}'}))
    op = {kind = 'create', fingerprint = fingerprint, repo = info.repo, common = info.common, actor = caller.agent,
      path = path, branch = branch, commit = commit, created = not exists(path), phase = 'prepared'}
    if listed and not same_tree(op) then
      fail('refused', 'Git lists a worktree of branch ' .. branch .. ' at ' .. listed .. ', but the directory is missing. ' ..
        'If the tree moved, run git worktree repair. If it is gone, run git worktree prune (a locked entry needs git worktree unlock first). Then retry.')
    end
    if not op.created then same_tree(op) end
    admit(id, op)
  end
  if op.phase == 'sending' then
    local r = mutation(id, op)
    if not r then return {status = 'running'} end
    if r.missing then
      if not same_tree(op) then fail('unresolved', 'The Git block is gone and the requested worktree is absent') end
      local check = check_status(id, op.path, false)
      if not check then return {status = 'running'} end
      if not check.ok or check.stdout ~= '' then fail('unresolved', 'The Git block is gone and the worktree is not proven clean') end
    elseif not r.ok then return finish(id, op, {error = {code = 'git_error', message = r.stderr}}) end
    if not same_tree(op) then fail('unresolved', 'Git exited, but the requested worktree is absent') end
  elseif not same_tree(op) then
    prepare_parent(op.path)
    local branch_exists = git(op.common, {'show-ref', '--verify', '--quiet', 'refs/heads/' .. op.branch}).ok
    local command = {'worktree', 'add'}
    if not branch_exists then command[#command + 1] = '-b'; command[#command + 1] = op.branch end
    command[#command + 1] = '--'; command[#command + 1] = op.path
    command[#command + 1] = branch_exists and op.branch or op.commit
    local r = mutation(id, op, command)
    if not r then return {status = 'running'} end
    if r.missing then fail('unresolved', 'The Git block disappeared; retry to reconcile the worktree') end
    if not r.ok or not same_tree(op) then return finish(id, op, {error = {code = 'git_error', message = r.stderr ~= '' and r.stderr or 'Git did not create the worktree'}}) end
  end
  return finish(id, op, {path = op.path, repo = op.repo, branch = op.branch, created = op.created})
end
local function remove(caller, id, fingerprint, args, pending)
  local op = pending
  if not op then
    local input = text(args.path, 'path')
    if input:sub(1, 1) ~= '/' then fail('invalid_input', 'path must be absolute') end
    local path = real(input)
    if not within(path, root) then fail('refused', 'Only worktrees beneath the managed root can be removed') end
    local info = repo_info(path)
    local tree = find_tree(info.common, path)
    if info.top ~= path or not tree or tree.bare or path == info.repo then fail('refused', 'Select a linked worktree, not the main repository') end
    op = {kind = 'remove', fingerprint = fingerprint, repo = info.repo, common = info.common, actor = caller.agent,
      path = path, branch = tree.branch or '', identity = identity(path), phase = 'prepared'}
    admit(id, op)
  end
  if op.phase == 'sending' then
    local r = mutation(id, op)
    if not r then return {status = 'running'} end
    if exists(op.path) or find_tree(op.common, op.path) then
      if r.missing then fail('unresolved', 'The Git block is gone and removal is not proven') end
      return finish(id, op, {error = {code = 'git_error', message = r.stderr ~= '' and r.stderr or 'Git refused removal'}})
    end
    return finish(id, op, {path = op.path, repo = op.repo, branch = op.branch, removed = true})
  end
  local tree = find_tree(op.common, op.path)
  if not exists(op.path) and not tree then return finish(id, op, {path = op.path, repo = op.repo, branch = op.branch, removed = true}) end
  if not exists(op.path) or not tree or identity(op.path) ~= op.identity then
    fail('conflict', 'The worktree identity changed; removal is unresolved')
  end
  local lock = hub('hub.cwd.lock', {path = op.path, key = id})
  if lock.locked ~= true then
    local details = {}
    for _, worker in ipairs(lock.workers or {}) do details[#details + 1] = (worker.spawn_id or '?') .. ' · ' .. (worker.cwd or 'unknown directory') end
    for _, pane in ipairs(lock.panes or {}) do details[#details + 1] = (pane.block_id or '?') .. ' · ' .. (pane.label or '') .. ' · ' .. (pane.cwd or '') end
    return finish(id, op, {error = {code = 'refused', message = 'A worker or terminal pane uses this worktree, or a worker has an unknown working directory.\n' .. table.concat(details, '\n')}})
  end
  local check = check_status(id, op.path, true)
  if not check then return {status = 'running'} end
  if not check.ok then return finish(id, op, {error = {code = 'git_error', message = check.stderr}}) end
  if check.stdout ~= '' then
    return finish(id, op, {error = {code = 'refused', message = 'The worktree has changes or ignored files; removal is refused'}})
  end
  local r = mutation(id, op, {'worktree', 'remove', '--', op.path})
  if not r then return {status = 'running'} end
  if exists(op.path) or find_tree(op.common, op.path) then
    if r.missing then fail('unresolved', 'The Git block is gone and removal is not proven') end
    return finish(id, op, {error = {code = 'git_error', message = r.stderr ~= '' and r.stderr or 'Git refused removal'}})
  end
  return finish(id, op, {path = op.path, repo = op.repo, branch = op.branch, removed = true})
end
-- An operation key belongs to its caller. After an identity migration, a key of a legacy ID
-- still finds its saved result or its pending operation; a new key uses the current ID.
local function mutate(caller, kind, args)
  local key = text(args.key, 'key')
  local fingerprint
  if kind == 'create' then
    fingerprint = 'create/' .. part(text(args.repo, 'repo')) .. part(text(args.branch, 'branch')) .. part(args.base == nil and '' or text(args.base, 'base'))
  else fingerprint = 'remove/' .. part(text(args.path, 'path')) end
  for _, alias in ipairs(caller.aliases) do
    local id = part(alias) .. part(key)
    local saved = hub('hub.store.op', {key = id})
    if saved.found then cleanup_done(id); return result_of(saved, fingerprint) end
  end
  local state = catalog()
  local id, pending = part(caller.agent) .. part(key), nil
  for _, alias in ipairs(caller.aliases) do
    local found = state.pending[part(alias) .. part(key)]
    if found then id, pending = part(alias) .. part(key), found; break end
  end
  if pending and pending.fingerprint ~= fingerprint then fail('operation_conflict', 'This key has different content') end
  if kind == 'create' then return create(caller, id, fingerprint, args, pending) end
  return remove(caller, id, fingerprint, args, pending)
end
-- discard ends a pending operation. Its result comes only from the target's own durable state, so
-- every caller and every retry gets the same answer, whoever finished the cleanup (a discard, a
-- create or remove replay, or startup):
-- - pending in phase cleanup: finish the cleanup first (close the block, unlock), then as below;
-- - a saved result that is a discard: that result;
-- - a saved result of any other kind: {status = 'complete'} (the operation ended by itself);
-- - no pending entry and no saved result: not_found.
local function discard(id)
  local state = catalog()
  local op = state.pending[id]
  if op and op.phase == 'cleanup' then cleanup_done(id); op = nil end
  if not op then
    local saved = hub('hub.store.op', {key = id})
    if not saved.found then fail('not_found', 'This operation is no longer pending') end
    if type(saved.result) == 'table' and saved.result.discarded then return saved.result end
    return {status = 'complete'}
  end
  if op.phase == 'sending' then
    local blocks, gone = operation_blocks(op)
    if not op.block and not gone then fail('refused', 'The spawn result is unknown. A late Rex reply can still start Git; destroy its session before discarding this intent') end
    for _, block in ipairs(blocks) do
      if block.block_id == op.block then
        local process = rex_ok('com.superlogical.terminal.process', {session_id = op.session, block_id = op.block, args = {}})
        if process.child or not process.last_exit then fail('refused', 'The Git process is running or starting') end
      end
    end
  end
  if checks[id] then checks[id]:kill(); checks[id] = nil end
  return finish(id, op, {status = 'discarded', discarded = true, path = op.path})
end
-- worktree.discard and the panel's Discard button. The target is selected by exactly one of:
-- - id: a full operation ID, any pending operation (decision "Agents may act on anything", 2026-10-19:
--   an agent may discard what the user can). The panel uses id.
-- - operation: an operation key of the caller, resolved through its aliases (its own operations).
-- The request key reserves its target before the target changes: a record
-- discard/<part(actor)><part(key)> = {fingerprint, id}. The request key is the caller's own. A retry
-- with the same key discards the reserved ID again, also after an alias change; another target or
-- the other selector with the same key conflicts, also after an interruption. discard() derives
-- the result from the target, so the record holds no result.
local function discard_request(caller, selector, key)
  local by_id, by_key = selector.id ~= nil, selector.operation ~= nil
  if by_id == by_key then fail('invalid_input', 'Name the operation with exactly one of operation or id') end
  local target = by_id and text(selector.id, 'id') or text(selector.operation, 'operation')
  key = text(key, 'key')
  local fingerprint = 'discard-v1/' .. part(by_id and 'id' or 'key') .. part(target)
  local record_keys = {}
  for _, alias in ipairs(caller.aliases) do record_keys[#record_keys + 1] = 'discard/' .. part(alias) .. part(key) end
  local function reserved()
    local records = hub('hub.store.get', {keys = record_keys}).records
    for _, record_key in ipairs(record_keys) do
      local r = records[record_key]
      if r and r.value ~= nil then
        if r.value.fingerprint ~= fingerprint then fail('operation_conflict', 'This key has different content') end
        return r.value.id
      end
    end
  end
  local id = reserved()
  if not id then
    id = target
    if by_key then
      local state = catalog()
      id = nil
      for _, alias in ipairs(caller.aliases) do
        local candidate = part(alias) .. part(target)
        if not id and (state.pending[candidate] or hub('hub.store.op', {key = candidate}).found) then id = candidate end
      end
      if not id then fail('not_found', 'You have no operation with this key') end
    end
    local saved = hub('hub.store.batch', {ops = {{key = record_keys[1], if_rev = '0', value = {fingerprint = fingerprint, id = id}}}})
    if saved.conflict then
      id = reserved()
      if not id then fail('conflict', 'The discard request changed; retry with the same key') end
    end
  end
  return discard(id)
end
local snapshots = {}
local snapshot = {worktrees = {}, root = root}
local refresh_error
local collect_scans, arm_scans
local scan_timer
local requested_repo
local worker_key
local advice_generation = 0
local removal_advice = {}
-- The scan queue, for all snapshots together. A refresh starts no process: it queues one job a tree
-- (an existence check, then git status). Only the scan timer runs jobs: at most 8 start in one
-- tick, and at most 8 git status processes run. So the process work of one tick has a limit; a
-- refresh (the tree lists, the items, the worker match) still grows with the number of trees.
-- scans.queue holds the jobs from first to last; scans.running the started ones.
local scan_starts, scan_running_limit = 8, 8
local scans = {queue = {}, first = 1, last = 0, running = {}}
-- scan_done counts a job as ended. It reports whether a shown snapshot changed: the current
-- snapshot of all repositories, or a repository snapshot that the panel uses.
local function scan_done(job)
  job.snapshot.outstanding = job.snapshot.outstanding - 1
  return snapshots[job.key] == job.snapshot and (job.key == '' or job.snapshot.ui == true)
end
local function workers_key(workers)
  local rows = {}
  for _, worker in ipairs(workers) do
    rows[#rows + 1] = part(worker.spawn_id or '') .. part(worker.cwd or '') .. part(worker.state or '') .. part(worker.title or '')
  end
  table.sort(rows)
  return table.concat(rows, '|')
end
local invalidate = app.refresh
-- listed gives the trees of one recorded repository, or nil and the Git error when Git cannot list
-- them (the repository was deleted or moved). Only that Git error is caught: any other error, for
-- example a process that does not start, fails the refresh.
local function listed(common)
  local ok, rows = pcall(trees, common)
  if ok then return rows end
  if type(rows) ~= 'table' or rows.code ~= 'git_error' then error(rows, 0) end
  return nil, rows.message
end
local function refresh(repo_arg)
  local cache_key = repo_arg or ''
  local previous = snapshots[cache_key]
  if previous and previous.refreshing then previous.stale = true; arm_scans(); return previous end
  local state = catalog()
  local repos = state.repos
  if repo_arg then local info = repo_info(repo_arg); repos = {[info.common] = info.repo} end
  local workers = hub('hub.workers').workers or {}
  if not repo_arg then worker_key = workers_key(workers) end
  local result = {worktrees = {}, root = root, refreshing = false, outstanding = 0, ui = previous and previous.ui,
    rendered = previous and previous.rendered, touched = previous and previous.touched}
  -- The jobs wait here until every repository is listed: a refresh that fails queues nothing.
  local jobs = {}
  for common, repo in pairs(repos) do
    local rows, err = listed(common)
    if not rows then
      -- One row for the repository; the catalog keeps it, so a later refresh lists it again.
      result.worktrees[#result.worktrees + 1] = {path = repo, repo = repo, branch = '(unavailable)', managed = false,
        workers = {}, state = 'unavailable', error = err}
    end
    for _, tree in ipairs(rows or {}) do
      local item = {path = tree.path, repo = repo, branch = tree.branch or '(detached)', managed = within(tree.path, root), workers = {}}
      if tree.bare then item.state = 'bare'
      else
        item.state = 'checking'
        jobs[#jobs + 1] = {key = cache_key, snapshot = result, item = item}
      end
      for _, worker in ipairs(workers) do
        if type(worker.cwd) == 'string' and (worker.cwd == tree.path or within(worker.cwd, tree.path)) then
          item.workers[#item.workers + 1] = {spawn_id = worker.spawn_id, title = worker.title, state = worker.state, cwd = worker.cwd}
        end
      end
      result.worktrees[#result.worktrees + 1] = item
    end
  end
  table.sort(result.worktrees, function(a, b) return a.path < b.path end)
  for _, job in ipairs(jobs) do
    scans.last = scans.last + 1
    scans.queue[scans.last] = job
  end
  result.outstanding = #jobs
  result.refreshing = result.outstanding > 0
  snapshots[cache_key] = result
  if result.refreshing then arm_scans() end
  if not repo_arg then snapshot = result; refresh_error = nil; pcall(invalidate) end
  return result
end
-- Source snapshots: the panel keeps one per source repository (ui). At most 16; the global snapshot
-- '' is outside the bound. A snapshot carries rendered (the advice_generation of its last render)
-- and touched (sources.clock at that render, for least-recently-rendered eviction). An evicted
-- snapshot leaves the table, so its queued jobs start nothing and its active jobs change no shown
-- snapshot. The snapshot that an agent list pages through (requested_repo) only loses ui; the scan
-- cleanup keeps it while it is requested. The state is in table fields.
local sources = {limit = 16, clock = 0}
local function evict_source(key)
  local cached = snapshots[key]
  if not cached then return end
  if key == requested_repo then cached.ui = nil else snapshots[key] = nil end
end
-- The reply of worktree.list fits every client: one Rex control message is 64 KiB (65536 bytes),
-- and the harness test client takes at most 48 KiB (49152 bytes). Budgets, as encoded JSON:
-- worktrees 16 KiB and operations 24 KiB a page, the other fields 4 KiB, all of it 44 KiB (45056).
local page_limit, worktrees_bytes, operations_bytes, meta_bytes, reply_bytes = 50, 16384, 24576, 4096, 45056
local function encoded(value) return #rex.json.encode(value) end
-- cut keeps text within limit bytes (default 1024), the ellipsis included, at a UTF-8 character boundary.
local function cut(value, limit)
  limit = limit or 1024
  if type(value) ~= 'string' or #value <= limit then return value end
  local n = limit - #'…'
  while n > 0 and value:byte(n + 1) >= 0x80 and value:byte(n + 1) < 0xC0 do n = n - 1 end
  return value:sub(1, n) .. '…'
end
-- page adds entries in order while the page holds fewer than 50 and the size stays within budget.
-- The size is checked before an entry is added. An entry that does not fit an empty page is
-- replaced by its compact forms in order; if none fits, the reply is too_large. It returns the
-- page and whether more entries follow. A page is never empty before the end.
local function page(keys, build, compacts, budget, what)
  local out, used = {}, 2
  for _, key in ipairs(keys) do
    if #out == page_limit then return out, true end
    local entry = build(key)
    local size = encoded(entry) + 1
    if used + size > budget then
      if #out > 0 then return out, true end
      for _, compact in ipairs(compacts) do
        entry = compact(entry)
        size = encoded(entry) + 1
        if used + size <= budget then break end
      end
      if used + size > budget then fail('too_large', 'The ' .. what .. ' ' .. key:sub(1, 64) .. '… is larger than one page') end
    end
    out[#out + 1] = entry
    used = used + size
  end
  return out, false
end
-- operations: the pending operations (the panel's pending entries), every repository, sorted by
-- ID, after the ID after (a position; it need not exist).
local function operations_page(after)
  if after ~= nil then text(after, 'operations_after') end
  local pending = catalog().pending
  local ids = {}
  for id in pairs(pending) do if after == nil or id > after then ids[#ids + 1] = id end end
  table.sort(ids)
  local out, more = page(ids, function(id)
    local op = pending[id]
    -- A pending row from an older version can have no actor: the field is left out.
    return {id = id, kind = op.kind, phase = op.phase, path = op.path, branch = op.branch, actor = op.actor}
  end, {function(e) return {id = e.id, kind = e.kind, phase = e.phase, compact = true} end}, operations_bytes, 'pending operation')
  return out, more and out[#out].id or nil
end
-- worktrees: the trees of the latest scan, sorted by path, after the path after (a position).
local function worktrees_page(trees_list, after)
  if after ~= nil then text(after, 'worktrees_after') end
  local by_path, paths = {}, {}
  for _, tree in ipairs(trees_list or {}) do
    if after == nil or tree.path > after then by_path[tree.path] = tree; paths[#paths + 1] = tree.path end
  end
  table.sort(paths)
  local out, more = page(paths, function(path)
    -- Every field of the scan row, so that no field of the reply disappears.
    local e = {}
    for k, v in pairs(by_path[path]) do e[k] = v end
    e.error = cut(e.error)
    return e
  end, {
    -- Too many workers: the count only (hub.workers lists them).
    function(e) e.workers_count, e.workers, e.compact = #(e.workers or {}), nil, true; return e end,
    function(e) e.error = nil; return e end,
  }, worktrees_bytes, 'worktree')
  return out, more and out[#out].path or nil
end
local function list_request(args)
  collect_scans()
  local key = args.repo or ''
  requested_repo = args.repo
  local cached = snapshots[key]
  -- A first page starts a fresh scan. Retries read the scan already in progress. A call with a
  -- cursor reads the cached scan (a change or another caller can refresh it between pages); it
  -- starts a scan only when no scan is cached.
  local paging = args.worktrees_after ~= nil or args.operations_after ~= nil
  if not cached or (not paging and not cached.refreshing and not cached.awaiting_read) then cached = refresh(args.repo) end
  cached.awaiting_read = cached.refreshing
  local result = {root = root, refreshing = cached.refreshing, error = cut(cached.error)}
  local trees_out, trees_next = worktrees_page(cached.worktrees, args.worktrees_after)
  local ops_out, ops_next = operations_page(args.operations_after)
  -- An empty list is left out (Rex Lua encodes an empty table as an object).
  result.worktrees_next, result.operations_next = trees_next, ops_next
  if encoded(result) > meta_bytes then fail('too_large', 'The reply fields without the lists are larger than 4 KiB') end
  if trees_out[1] then result.worktrees = trees_out end
  if ops_out[1] then result.operations = ops_out end
  if encoded(result) > reply_bytes then fail('too_large', 'The worktree.list reply is larger than 44 KiB') end
  return result
end
-- Keep a row selection in the route. Two windows must not share a last-selected path.
local function route_with_path(base, path)
  text(path, 'path')
  return base .. '?path=' .. path:gsub('([^%w%-%._~])', function(c) return string.format('%%%02X', string.byte(c)) end)
end
local function route_path(route)
  if type(route) ~= 'string' then return '', nil end
  local base, encoded = route:match('^([^?]+)%?path=(.*)$')
  if not base then return route, nil end
  -- A malformed escape must not silently select a different path.
  if encoded:gsub('%%[%x][%x]', ''):find('%%') then return base, nil end
  local path = encoded:gsub('%%(%x%x)', function(hex) return string.char(tonumber(hex, 16)) end)
  if path:sub(1, 1) ~= '/' or path:find('%z') then return base, nil end
  return base, path
end
local function recorded_repos()
  local state = catalog()
  local result, seen = {}, {}
  for _, repo in pairs(state.repos or {}) do
    if not seen[repo] then result[#result + 1] = repo; seen[repo] = true end
  end
  table.sort(result)
  return result
end
local function recorded(state, repo)
  for _, value in pairs(state.repos or {}) do if value == repo then return true end end
  return false
end
-- Forget repository removes a recorded repository from the catalog. Nothing on disk changes, and no
-- process stops: a worker in that repository keeps running, and only its row leaves the panel.
-- Unconditional refusals: an unfinished operation in the repository; a worker with an unknown
-- directory; a worker inside the recorded main path or inside a tree that Git lists now.
-- When Git cannot list the repository, its linked trees are unknown. So each other worker outside
-- every listable recorded repository is unattributed: the user or the agent must accept them.
local function worker_lines(rows)
  local out = {}
  for i, row in ipairs(rows) do
    if i > 20 then out[#out + 1] = '… and ' .. (#rows - 20) .. ' more'; break end
    out[#out + 1] = cut(row)
  end
  return table.concat(out, '\n')
end
local function inside(path, paths)
  for _, p in ipairs(paths) do if path == p or within(path, p) then return true end end
  return false
end
-- forget_check returns the catalog keys (Git common directories) of repo, the unattributed workers
-- as text rows, and the key of that worker set. It fails for a refusal.
local function forget_check(state, repo)
  local commons, own, unavailable = {}, {repo}, false
  for common, value in pairs(state.repos) do
    if value == repo then
      commons[#commons + 1] = common
      local rows = listed(common)
      if not rows then unavailable = true end
      for _, tree in ipairs(rows or {}) do own[#own + 1] = tree.path end
    end
  end
  if not commons[1] then fail('not_found', 'This repository is not recorded') end
  for _, op in pairs(state.pending) do
    for _, common in ipairs(commons) do
      if op.common == common then fail('refused', 'An unfinished operation uses this repository: ' .. tostring(op.kind) .. ' ' .. tostring(op.path)) end
    end
  end
  local others = {}
  if unavailable then
    for common, value in pairs(state.repos) do
      if value ~= repo then for _, tree in ipairs(listed(common) or {}) do others[#others + 1] = tree.path end end
    end
  end
  local known, unattributed, keys = {}, {}, {}
  for _, worker in ipairs(hub('hub.workers').workers or {}) do
    local cwd = type(worker.cwd) == 'string' and worker.cwd ~= '' and worker.cwd or nil
    local row = (worker.spawn_id or '?') .. ' · ' .. (cwd or 'unknown directory')
    if not cwd or inside(cwd, own) then known[#known + 1] = row
    elseif unavailable and not inside(cwd, others) then
      unattributed[#unattributed + 1] = row
      keys[#keys + 1] = part(worker.spawn_id or '') .. part(cwd)
    end
  end
  if known[1] then
    table.sort(known)
    fail('refused', 'A worker uses this repository, or a worker has an unknown working directory.\n' .. worker_lines(known))
  end
  table.sort(unattributed)
  table.sort(keys)
  return commons, unattributed, 'workers/' .. table.concat(keys)
end
-- forget_cached drops the cached snapshots of repo, and its rows from the snapshot of all
-- repositories. The panel of a pane in repo refreshes it again as its source (not recorded).
local function forget_cached(repo)
  for key, cached in pairs(snapshots) do
    if key ~= '' then
      for _, tree in ipairs(cached.worktrees or {}) do
        if tree.repo == repo then snapshots[key] = nil; break end
      end
    end
  end
  local kept = {}
  for _, tree in ipairs(snapshot.worktrees) do if tree.repo ~= repo then kept[#kept + 1] = tree end end
  snapshot.worktrees = kept
end
-- forget: worktree.forget and the Forget repository form. The fingerprint is the path only, so
-- accept_unattributed does not change the operation. Only a success is saved, with the catalog
-- change in one batch: a refusal or needs_confirmation keeps the key free for a later call. A
-- same-key retry returns the saved success and changes nothing, also after a create has recorded
-- the repository again. shown (the form only): the worker set key that the form showed; when the
-- set changed, forget returns {changed = true} and changes nothing.
local function forget(caller, args, shown)
  local repo, key = text(args.repo, 'repo'), text(args.key, 'key')
  if args.accept_unattributed ~= nil and type(args.accept_unattributed) ~= 'boolean' then
    fail('invalid_input', 'accept_unattributed must be a boolean')
  end
  local fingerprint = 'forget/' .. part(repo)
  for _, alias in ipairs(caller.aliases) do
    local saved = hub('hub.store.op', {key = part(alias) .. part(key)})
    if saved.found then return result_of(saved, fingerprint) end
  end
  local id = part(caller.agent) .. part(key)
  for _ = 1, 3 do
    local state, rev = catalog()
    for _, alias in ipairs(caller.aliases) do
      if state.pending[part(alias) .. part(key)] then fail('operation_conflict', 'This key has different content') end
    end
    local commons, unattributed, set_key = forget_check(state, repo)
    if shown ~= nil and shown ~= set_key then return {changed = true} end
    if unattributed[1] and args.accept_unattributed ~= true then
      fail('needs_confirmation', 'Git cannot list this repository, so these workers may use it. They keep running, but lose their row in the panel. To forget it, call again with accept_unattributed = true.\n' .. worker_lines(unattributed))
    end
    for _, common in ipairs(commons) do state.repos[common] = nil end
    local result = {forgotten = true, repo = repo, unattributed_count = #unattributed}
    if unattributed[1] then
      result.unattributed_workers = {}
      for i = 1, math.min(#unattributed, 20) do result.unattributed_workers[i] = cut(unattributed[i]) end
    end
    local saved = hub('hub.store.batch', {ops = {{key = 'catalog', if_rev = rev, value = state}},
      op = {key = id, fingerprint = fingerprint, result = result}})
    if saved.op_exists then return saved.op_exists.result end
    if saved.conflict and saved.conflict.kind == 'operation' then fail('operation_conflict', 'This key has different content') end
    if not saved.conflict then
      if not saved.revs then fail('internal', 'Invalid store result') end
      forget_cached(repo)
      return result
    end
  end
  fail('conflict', 'The worktree catalog changed; retry with the same key')
end
-- source_top gives the repository top of a pane directory, or nil outside a repository. Each panel
-- render asks for it, and repo_info runs Git (observed on Rex 0.0.1792158932-g88fd41, lab: a source
-- pane added about 100 ms and 3 Git processes to each render). So the result is kept per exact
-- directory until refresh_safe starts a new advice_generation. Outside a repository is kept only
-- when Git says so; any other failure is not kept. At most 64 directories: a new one past that
-- clears the table. The state is in table fields, not in upvalues that a closure writes.
local source_tops = {generation = -1, count = 0, by_pwd = {}}
local function source_top(pwd)
  if source_tops.generation ~= advice_generation then
    source_tops.generation, source_tops.count, source_tops.by_pwd = advice_generation, 0, {}
  end
  local kept = source_tops.by_pwd[pwd]
  if kept then return kept.top or nil end
  local ok, info = pcall(repo_info, pwd)
  local outside = not ok and type(info) == 'table' and info.code == 'git_error'
    and type(info.message) == 'string' and info.message:find('not a git repository', 1, true) ~= nil
  if not ok and not outside then error(info, 0) end
  if source_tops.count >= 64 then source_tops.count, source_tops.by_pwd = 0, {} end
  source_tops.by_pwd[pwd] = {top = ok and info.top or false}
  source_tops.count = source_tops.count + 1
  return ok and info.top or nil
end
local function repo_default(context)
  if type(context) ~= 'table' or type(context.source_block_id) ~= 'string'
    or context.source_block_id == '' or type(context.session_id) ~= 'string' or context.session_id == '' then return nil end
  local ok, repo = pcall(function()
    rex_ok('session.attach', {session_id = context.session_id, event_scope = 'session'})
    local result = rex_ok('com.superlogical.terminal.pwd', {
      session_id = context.session_id, block_id = context.source_block_id, args = {}})
    local pwd = result.pwd
    if type(pwd) ~= 'string' or pwd == '' then
      -- A shell or agent can omit OSC 7. Rex still reports its process directory.
      local process = rex_ok('com.superlogical.terminal.process', {
        session_id = context.session_id, block_id = context.source_block_id, args = {}})
      pwd = process.foreground and process.foreground.cwd
      if type(pwd) ~= 'string' or pwd == '' then pwd = process.child and process.child.cwd end
    end
    if type(pwd) ~= 'string' or pwd == '' then return nil end
    if pwd:sub(1, 7) == 'file://' then
      pwd = pwd:match('^file://[^/]*(/.*)$')
      if not pwd then return nil end
      if pwd:gsub('%%[%x][%x]', ''):find('%%') then return nil end
      pwd = pwd:gsub('%%(%x%x)', function(hex) return string.char(tonumber(hex, 16)) end)
    end
    if pwd:sub(1, 1) ~= '/' or pwd:find('%z') then return nil end
    return source_top(pwd)
  end)
  if ok then return repo end
  return nil
end
-- Advice never acquires a lock. Submit repeats every guard against the current state.
-- Defer metadata and pane reads out of render; scan Git status with the existing scan timer.
local function remove_advice(path)
  if type(path) ~= 'string' or path == '' then return {ok = false, reasons = {'Select a worktree'}} end
  local cached = removal_advice[path]
  if cached and (cached.generation == advice_generation or not cached.result) then return cached.result end
  cached = {generation = advice_generation}
  removal_advice[path] = cached
  rex.after(0, function()
    local ok, err = pcall(function()
      local canonical = real(text(path, 'path'))
      if not within(canonical, root) then fail('refused', 'Only worktrees beneath the managed root can be removed') end
      local info = repo_info(canonical)
      local tree = find_tree(info.common, canonical)
      if info.top ~= canonical or not tree or tree.bare or canonical == info.repo then
        fail('refused', 'Select a linked worktree, not the main repository')
      end
      if tree.locked then fail('refused', 'Git has locked this worktree') end
      local use = hub('hub.cwd.check', {path = canonical})
      local reasons = {}
      for _, worker in ipairs(use.workers or {}) do
        reasons[#reasons + 1] = 'Worker: ' .. (worker.spawn_id or '?') .. ' · ' .. (type(worker.cwd) == 'string' and worker.cwd ~= '' and worker.cwd or 'unknown directory')
      end
      for _, pane in ipairs(use.panes or {}) do
        reasons[#reasons + 1] = 'Terminal: ' .. (pane.label or pane.block_id or '?') .. ' · ' .. (pane.cwd or '')
      end
      if use.available ~= true then
        if #reasons == 0 then reasons[1] = 'The directory is in use or could not be checked' end
        cached.result = {ok = false, reasons = reasons}
        return
      end
      local handle, start_err = rex.exec.start(status_command(canonical, true), {env = git_env, timeout = 30, detach = true})
      if not handle then fail('unavailable', tostring(start_err)) end
      cached.handle = handle
      arm_scans()
    end)
    if not ok then cached.result = {ok = false, reasons = {type(err) == 'table' and err.message or tostring(err)}} end
    if cached.result then pcall(invalidate) end
  end)
  return nil
end
-- Rex has no exec completion callback. Arm a one-shot timer only while a status scan runs.
local function refresh_safe()
  advice_generation = advice_generation + 1
  local ok, err = pcall(refresh)
  if not ok then refresh_error = type(err) == 'table' and err.message or tostring(err); pcall(invalidate) end
  -- A source snapshot that no panel rendered in the previous or this generation is evicted;
  -- the others are refreshed. The keys are collected first: eviction changes the table.
  local keys = {}
  for key, cached in pairs(snapshots) do if key ~= '' and cached.ui then keys[#keys + 1] = key end end
  for _, key in ipairs(keys) do
    local cached = snapshots[key]
    if (cached.rendered or -1) < advice_generation - 1 then evict_source(key)
    else
      local refreshed, why = pcall(refresh, key)
      if not refreshed then cached.error = type(why) == 'table' and why.message or tostring(why); pcall(invalidate) end
    end
  end
end
-- A notification (hub.changed workers, view.seen focus, a terminal event) does no Git work in the
-- request queue, so each one is short. In the lab, a burst of 30 spawns or 30 stops did not fill
-- the queue (16 requests); a larger burst is not tested. Each one sets pending_refresh, and one
-- rex.after(0.2) tick refreshes. 0.2 s is a scheduling delay: the tick waits for queued work.
-- 'always' refreshes. 'workers' refreshes only when the worker set changed. 'always' wins
-- until the tick consumes it. The tick consumes the flag before its work, so a notification
-- during the work arms a new tick; an error goes to refresh_error, and the next notification
-- or list call tries again.
local pending_refresh, refresh_armed
local function notified_refresh()
  local kind = pending_refresh
  pending_refresh, refresh_armed = nil, false
  local ok, err = pcall(function()
    if kind == 'workers' then
      local current = workers_key(hub('hub.workers').workers or {})
      if current == worker_key then return end
      -- Remember the change even when a previous scan is still running. Otherwise a worker
      -- that starts and stops during that scan can leave stale removal advice.
      worker_key = current
    end
    refresh_safe()
  end)
  if not ok then refresh_error = type(err) == 'table' and err.message or tostring(err); pcall(invalidate) end
end
local function notify(kind)
  if kind == 'always' or not pending_refresh then pending_refresh = kind end
  if refresh_armed then return end
  rex.after(0.2, notified_refresh)
  refresh_armed = true
end
local function submit_worktree(args)
  local route = route_path(args.route)
  local kind, node
  if route == '/forms/new-worktree' then kind = 'create'; node = 'new_worktree'
  elseif route == '/forms/remove-worktree' then kind = 'remove'; node = 'remove_worktree'
  else return nil end
  if args.node_id ~= node or args.action ~= 'submit' then fail('invalid_input', 'Unknown worktree form action') end
  local values = type(args.input) == 'table' and args.input.values or nil
  if type(values) ~= 'table' then fail('invalid_input', 'Worktree form values are required') end
  -- The hub stores the input and operation key together. Every pending attempt uses both again.
  local request = {key = text(args.operation_key, 'operation_key')}
  if kind == 'create' then
    request.repo = values.repo
    request.branch = values.branch
    if values.base ~= '' then request.base = values.base end
  else request.path = values.path end
  local result = mutate(user_caller, kind, request)
  if result.status == 'running' then return result end
  refresh_safe()
  return {close_form = true, path = result.path, created = result.created, removed = result.removed}
end
collect_scans = function()
  local changed = false
  for _, advice in pairs(removal_advice) do
    if advice.handle and not advice.handle:running() then
      local result, err = advice.handle:wait(0.001)
      if result or err ~= 'timeout' then
        advice.handle = nil
        local reason
        if not result or not result.ok then reason = result and result.stderr or tostring(err)
        elseif result.stdout ~= '' then reason = 'The worktree has changes or ignored files; removal is refused' end
        advice.result = {ok = not reason, reasons = reason and {reason} or {}}
        changed = true
      end
    end
  end
  local running = {}
  for _, job in ipairs(scans.running) do
    local result, err, done = nil, nil, false
    if not job.handle:running() then
      result, err = job.handle:wait(0.001)
      done = result ~= nil or err ~= 'timeout'
    end
    if not done then running[#running + 1] = job
    else
      if result and result.ok then
        job.item.dirty = result.stdout ~= ''
        job.item.state = job.item.dirty and 'dirty' or 'clean'
      else job.item.state = 'unavailable'; job.item.error = result and result.stderr or tostring(err) end
      if scan_done(job) then changed = true end
    end
  end
  scans.running = running
  for key, cached in pairs(snapshots) do
    cached.refreshing = cached.outstanding > 0
    if not cached.refreshing and cached.stale then
      cached.stale = nil
      local ok, err = pcall(refresh, key ~= '' and key or nil)
      if not ok then cached.error = type(err) == 'table' and err.message or tostring(err) end
    elseif not cached.refreshing and key ~= '' and key ~= requested_repo and not cached.ui then snapshots[key] = nil end
  end
  if changed then pcall(invalidate) end
end
-- start_job checks that the tree exists and starts its git status. It returns true when the job
-- ended at once and a shown snapshot changed.
local function start_job(job)
  local ok, present = pcall(exists, job.item.path)
  local handle, err
  if ok and present then handle, err = rex.exec.start(status_command(job.item.path, false), {env = git_env, timeout = 30, detach = true}) end
  if handle then
    job.handle = handle
    scans.running[#scans.running + 1] = job
    return false
  end
  if not ok then job.item.state = 'unavailable'; job.item.error = type(present) == 'table' and present.message or tostring(present)
  elseif not present then job.item.state = 'missing'
  else job.item.state = 'unavailable'; job.item.error = tostring(err) end
  return scan_done(job)
end
-- start_scans runs queued jobs within the limits. Only the scan timer calls it, so a list request
-- or a refresh starts no process. A refresh queues its jobs only when it succeeds, and it does not
-- replace a snapshot that refreshes. But Forget drops the snapshots of its repository: a job of a
-- dropped snapshot starts nothing.
local function start_scans()
  local started, changed = 0, false
  while started < scan_starts and #scans.running < scan_running_limit and scans.first <= scans.last do
    local job = scans.queue[scans.first]
    scans.queue[scans.first] = nil
    scans.first = scans.first + 1
    if snapshots[job.key] ~= job.snapshot then job.snapshot.outstanding = job.snapshot.outstanding - 1
    else
      started = started + 1
      if start_job(job) then changed = true end
    end
  end
  if scans.first > scans.last then scans.queue, scans.first, scans.last = {}, 1, 0 end
  -- A snapshot whose last job ended here stops refreshing in the next collect_scans.
  if changed then pcall(invalidate) end
end
arm_scans = function()
  if scan_timer then return end
  scan_timer = rex.after(0.2, function()
    scan_timer = nil
    collect_scans()
    start_scans()
    collect_scans()
    if scans.first <= scans.last or #scans.running > 0 then arm_scans(); return end
    for _, advice in pairs(removal_advice) do
      if advice.handle then arm_scans(); break end
    end
  end)
end
local pane_directories = {}
local function managed(path)
  return type(path) == 'string' and (path == root or within(path, root))
end
app.on('terminal.pwd_changed', function(ev, ctx)
  local path = type(ev.pwd) == 'string' and ev.pwd:match('^file://[^/]*(/.*)$') or nil
  if path then path = path:gsub('%%(%x%x)', function(hex) return string.char(tonumber(hex, 16)) end) end
  local was_managed = pane_directories[ctx.block_id]
  local is_managed = managed(path)
  pane_directories[ctx.block_id] = path and is_managed
  if was_managed or is_managed then notify('always') end
end, raw)
-- A pane can predate this plugin, so its last directory event can be unavailable.
app.on('terminal.child_exited', function(ev, ctx)
  if pane_directories[ctx.block_id] ~= false then notify('always') end
end, raw)
app.on('block_closed', function(ev, ctx)
  local block = ev.block_id or ctx.block_id
  local was_managed = pane_directories[block]
  pane_directories[block] = nil
  if was_managed then notify('always') end
end, raw)

-- The Worktrees panel and forms (the maintainer, 2026-10-17: no tab; palette commands and a side panel).
-- A route carries a selected tree as a query: /forms/worktree?path=<percent-encoded path>.
-- trees_for gives the known trees: the source repository first, then the recorded repositories.
-- It also gives the main path of the source repository (nil when it has no rows).
local function trees_for(source_repo)
  local rows, seen, main = {}, {}, nil
  if source_repo then
    local cached = snapshots[source_repo]
    if not (cached and cached.ui) then
      -- A new source: evict the least recently rendered one when the bound is reached.
      local count, oldest = 0, nil
      for key, other in pairs(snapshots) do
        if key ~= '' and key ~= source_repo and other.ui then
          count = count + 1
          if not oldest or (other.touched or 0) < (snapshots[oldest].touched or 0) then oldest = key end
        end
      end
      if count >= sources.limit then evict_source(oldest) end
    end
    if not cached then local ok, r = pcall(refresh, source_repo); cached = ok and r or nil end
    if cached then
      -- Keep the scan for the panel; a scan end invalidates it.
      sources.clock = sources.clock + 1
      cached.ui, cached.rendered, cached.touched = true, advice_generation, sources.clock
    end
    for _, tree in ipairs(cached and cached.worktrees or {}) do rows[#rows + 1] = tree; seen[tree.path] = true; main = main or tree.repo end
  end
  for _, tree in ipairs(snapshot.worktrees) do
    if not seen[tree.path] then rows[#rows + 1] = tree; seen[tree.path] = true end
  end
  return rows, main
end
local function find_known(path)
  for _, tree in ipairs(snapshot.worktrees) do if tree.path == path then return tree end end
  for _, cached in pairs(snapshots) do
    for _, tree in ipairs(cached.worktrees or {}) do if tree.path == path then return tree end end
  end
  local ok, info = pcall(repo_info, path)
  if ok then
    local tree = find_tree(info.common, path)
    if tree then return {path = tree.path, repo = info.repo, branch = tree.branch or '(detached)', managed = within(tree.path, root), workers = {}} end
  end
end
local function removable(tree) return tree.managed and tree.path ~= tree.repo and tree.state ~= 'bare' end
local function tree_detail(tree)
  local names = {}
  for _, worker in ipairs(tree.workers or {}) do names[#names + 1] = worker.title or worker.spawn_id end
  return tree.path .. '\n' .. (tree.state or 'unknown') .. (#names > 0 and (' · Workers: ' .. table.concat(names, ', ')) or '')
    .. (type(tree.error) == 'string' and ('\n' .. cut(tree.error)) or '')
end
local function cancel_node()
  return {id = 'cancel', type = 'widget', text = '', action = {name = '$cancel', label = 'Cancel', enabled = true}}
end
-- Panel pages. A view reply that is too large never arrives: the hub keeps the old tree (hub
-- docs/rex-protocol.md, "Rex Lua runtime": one control message is 64 KiB). So a rendered view
-- encodes to at most 48 KiB ({tree = tree}, the status included), and each entry (a tree row or a
-- stopped operation) to at most 8 KiB. The panel shows the entries that fit; More… opens the form
-- /forms/worktrees-more?start=<n> with the next ones. Every text is cut; an entry that is still
-- too large loses its optional text, and only an entry whose exact ID does not fit becomes a
-- placeholder without an action.
local view_bytes, entry_bytes = 49152, 8192
local function select_action(enabled) return {name = 'select', label = 'Actions…', enabled = enabled, user_only = 'navigation'} end
local function tree_entry(tree, n)
  local item = {id = tree.path, label = cut(tree.branch), detail = cut(tree_detail(tree)), action = select_action(true)}
  if encoded(item) > entry_bytes then item.label, item.detail = cut(tree.branch, 64), '' end
  if encoded(item) > entry_bytes then item.label = '' end
  if encoded(item) > entry_bytes then
    item = {id = 'oversized/' .. n, label = '(path too long)', detail = 'The path of this worktree is too long for the panel. worktree.list lists it.', action = select_action(false)}
  end
  return {item = item, bytes = encoded(item)}
end
local function pending_entry(id, op, n)
  local discard_action = {name = 'discard', label = 'Discard stopped operation', enabled = true, tool = 'worktree.discard'}
  local node = {id = 'pending/' .. id, type = 'widget', text = cut(op.kind .. ': ' .. op.path .. '\nState: ' .. op.phase .. '.'), action = discard_action}
  if encoded(node) > entry_bytes then node.text = cut(op.kind .. ' (' .. op.phase .. ')', 64) end
  if encoded(node) > entry_bytes then node.text = '' end
  if encoded(node) > entry_bytes then
    node = {id = 'pending-oversized/' .. n, type = 'widget', text = 'A stopped operation has an ID too long for the panel. ' ..
      'An agent can discard it with worktree.discard and its full operation ID; its caller can also use its operation key.'}
  end
  return {node = node, bytes = encoded(node)}
end
-- panel_entries gives the source text and the entries: the tree rows (the source rows first), then
-- the stopped operations in operation ID order (the catalog arrives as JSON at each render, and its
-- table order is not stable).
local function panel_entries(context)
  local source = repo_default(context)
  local rows, main = trees_for(source)
  local entries = {}
  for _, tree in ipairs(rows) do entries[#entries + 1] = tree_entry(tree, #entries + 1) end
  local state = catalog()
  local ids = {}
  for id in pairs(state.pending) do ids[#ids + 1] = id end
  table.sort(ids)
  for _, id in ipairs(ids) do entries[#entries + 1] = pending_entry(id, state.pending[id], #entries + 1) end
  -- The source repository shows also when the catalog does not record it (after Forget, or before
  -- its first create): worktree.list and the panel of other panes do not show it.
  local source_text = source and cut('Repository: ' .. source .. ((main and not recorded(state, main)) and ' (not recorded)' or ''))
  return source_text, entries
end
-- page builds the nodes of entries[start..] that fit: head and tail are the fixed nodes before and
-- after the entries, and status the root status. The list node 'worktrees' gets the tree rows; the
-- stopped operations follow it. A More widget ends a page that does not hold the rest.
local function page(title, head, tail, status, entries, start)
  local function build(last)
    local items, nodes = {}, {}
    for _, n in ipairs(head) do nodes[#nodes + 1] = n end
    nodes[#nodes + 1] = {id = 'worktrees', type = 'list', label = 'Worktrees', items = items}
    for i = start, last do
      if entries[i].item then items[#items + 1] = entries[i].item else nodes[#nodes + 1] = entries[i].node end
    end
    if last < #entries then
      nodes[#nodes + 1] = {id = 'more/' .. (last + 1), type = 'widget', text = (#entries - last) .. ' more entries.',
        action = {name = 'more', label = 'More…', enabled = true, user_only = 'navigation'}}
    end
    for _, n in ipairs(tail) do nodes[#nodes + 1] = n end
    return {title = title, status = status, nodes = nodes}
  end
  -- The sizes of the entries add up. The fixed part is the page without entries: it has a More
  -- widget when entries remain; 32 bytes cover its longer numbers.
  local fixed = encoded({tree = build(start - 1)}) + 32
  local used, last = fixed, start - 1
  for i = start, #entries do
    if used + entries[i].bytes + 1 > view_bytes then break end
    used, last = used + entries[i].bytes + 1, i
  end
  local tree = build(last)
  -- The exact check: drop entries from the end while the page is too large.
  while last > start and encoded({tree = tree}) > view_bytes do last = last - 1; tree = build(last) end
  return tree
end
local function render_panel(context)
  local source_text, entries = panel_entries(context)
  local head = {
    {id = 'new', type = 'widget', text = source_text or 'The source pane is not in a Git repository.',
      action = {name = 'new', label = 'New Worktree…', enabled = true, user_only = 'navigation'}},
  }
  local tail = {
    {id = 'refresh', type = 'widget', text = cut('Managed root: ' .. root), action = {name = 'refresh', label = 'Refresh', enabled = true, tool = 'worktree.list'}},
  }
  if refresh_error then tail[#tail + 1] = {id = 'refresh_error', type = 'widget', text = cut(refresh_error)} end
  local status
  if refresh_error then status = {state = 'error', msg = 'Could not refresh worktrees'}
  elseif snapshot.refreshing then status = {state = 'working', msg = 'Checking worktrees'} end
  return page('Worktrees', head, tail, status, entries, 1)
end
-- more_start reads the start of a More page: 1 to 6 decimal digits, at least 1.
local function more_start(value)
  if type(value) ~= 'string' or not value:match('^%d+$') or #value > 6 or tonumber(value) < 1 then
    fail('invalid_input', 'start must be a positive number of at most 6 digits')
  end
  return tonumber(value)
end
local function render_more(context, start)
  local _, entries = panel_entries(context)
  if start > #entries then
    return {title = 'Worktrees', nodes = {{id = 'end', type = 'widget', text = 'No more entries. The list changed.'}, cancel_node()}}
  end
  local head = {{id = 'about', type = 'widget', text = 'Entries from ' .. start .. ' of ' .. #entries .. '.'}}
  -- ui_render adds the form status; the page reserves it.
  return page('Worktrees', head, {cancel_node()}, {state = 'blocked', kind = 'question', msg = 'Waiting for input'}, entries, start)
end
local function render_tree_menu(path)
  local tree = path and find_known(path)
  if not tree then fail('invalid_input', 'Unknown worktree') end
  local items = {
    {id = 'open_tab', label = 'Open in new tab', action = {name = 'run', enabled = true, tool = 'worktree.open'}},
    {id = 'open_session', label = 'Open in new session', action = {name = 'run', enabled = true, tool = 'worktree.open'}},
    {id = 'agent', label = 'Start agent…', action = {name = 'run', enabled = true, user_only = 'navigation'}},
    {id = 'remove', label = 'Remove…', action = {name = 'run', enabled = removable(tree), user_only = 'navigation'}},
  }
  -- The main tree row of a repository, also the unavailable row: Forget repository.
  if tree.path == tree.repo then
    items[#items + 1] = {id = 'forget', label = 'Forget repository…', action = {name = 'run', enabled = recorded(catalog(), tree.repo), user_only = 'navigation'}}
  end
  return {title = tree.branch, nodes = {
    {id = 'about', type = 'widget', text = tree_detail(tree)},
    {id = 'worktree_menu', type = 'list', items = items},
    cancel_node(),
  }}
end
-- The confirmation names the repository. It shows a refusal, or the unattributed workers. The
-- form keeps the key of the shown worker set, so the submit can see a change.
local function render_forget(path)
  if not path then fail('invalid_input', 'Select a repository') end
  local nodes = {{id = 'about', type = 'widget', text = 'Repository: ' .. path ..
    '\nForget removes it from the recorded repositories. Nothing on disk changes: no file, branch or worktree. A new worktree in it records it again.'}}
  local ok, commons, unattributed, set_key = pcall(forget_check, catalog(), path)
  if not ok then
    nodes[#nodes + 1] = {id = 'check', type = 'widget', text = 'Forget will be refused:\n' .. (type(commons) == 'table' and tostring(commons.message) or tostring(commons))}
    set_key = 'workers/'
  elseif unattributed[1] then
    nodes[#nodes + 1] = {id = 'unattributed', type = 'widget', text = 'These workers may use this repository; they keep running, but lose their row in the panel:\n' .. worker_lines(unattributed)}
  end
  local count = ok and #unattributed or 0
  nodes[#nodes + 1] = {id = 'forget_repository', type = 'form', fields = {
    {id = 'repo', label = 'Repository', kind = 'select', required = true, value = path, options = {{value = path, label = path}}},
    {id = 'workers', label = 'Unattributed workers', kind = 'select', required = true, value = set_key, options = {{value = set_key, label = tostring(count)}}}},
    submit_action = {name = 'submit', label = 'Forget repository', enabled = true, tool = 'worktree.forget'}}
  nodes[#nodes + 1] = cancel_node()
  return {title = 'Forget repository', nodes = nodes}
end
local function render_new(context)
  local source = repo_default(context)
  local options, seen = {}, {}
  if source then options[1] = {value = source, label = source}; seen[source] = true end
  for _, repo in ipairs(recorded_repos()) do
    if not seen[repo] then options[#options + 1] = {value = repo, label = repo}; seen[repo] = true end
  end
  local repo_field = #options > 0 and {id = 'repo', label = 'Repository', kind = 'select', required = true, value = options[1].value, options = options}
    or {id = 'repo', label = 'Repository (absolute path)', kind = 'text', required = true, value = ''}
  return {title = 'New worktree', nodes = {
    {id = 'new_worktree', type = 'form', fields = {repo_field,
      {id = 'branch', label = 'Branch', kind = 'text', required = true, value = ''},
      {id = 'base', label = 'Base (optional, for a new branch)', kind = 'text', value = ''}},
      submit_action = {name = 'submit', label = 'Create worktree', enabled = true, tool = 'worktree.create'}},
    {id = 'help', type = 'widget', text = 'The worktree goes in ' .. root .. '/<repo>-<id>/<branch>. The ID is 6 hex digits from the Git directory path. An existing tree of the branch in this root is used.'},
    cancel_node(),
  }}
end
-- Without a path, the remove form is a picker. With a path, it confirms that one tree, so the
-- advice always belongs to the tree that the submit removes.
local function render_remove(context, path)
  if not path then
    local items = {}
    for _, tree in ipairs(trees_for(repo_default(context))) do
      if removable(tree) then items[#items + 1] = {id = tree.path, label = tree.branch, detail = tree_detail(tree), action = {name = 'select', label = 'Choose', enabled = true, user_only = 'navigation'}} end
    end
    if #items == 0 then
      return {title = 'Remove worktree', nodes = {{id = 'none', type = 'widget', text = 'No managed worktree can be removed.'}, cancel_node()}}
    end
    return {title = 'Remove worktree', nodes = {{id = 'remove_pick', type = 'list', label = 'Choose a worktree', items = items}, cancel_node()}}
  end
  local tree = find_known(path)
  if not tree or not removable(tree) then fail('invalid_input', 'This worktree cannot be removed') end
  local nodes = {
    {id = 'about', type = 'widget', text = tree_detail(tree)},
    {id = 'remove_worktree', type = 'form', fields = {
      {id = 'path', label = 'Worktree', kind = 'select', required = true, value = path, options = {{value = path, label = tree.branch}}}},
      submit_action = {name = 'submit', label = 'Remove worktree', enabled = true, tool = 'worktree.remove'}}}
  local advice = remove_advice(path)
  if not advice then nodes[#nodes + 1] = {id = 'check', type = 'widget', text = 'Checking the worktree…'}
  elseif not advice.ok then nodes[#nodes + 1] = {id = 'check', type = 'widget', text = 'Removal will be refused:\n' .. table.concat(advice.reasons or {}, '\n')} end
  nodes[#nodes + 1] = {id = 'help', type = 'widget', text = 'Removal never forces and never deletes the branch.'}
  nodes[#nodes + 1] = cancel_node()
  return {title = 'Remove ' .. tree.branch, nodes = nodes}
end
-- Only these errors are definite. Every other error (unavailable, timeout, an unknown outcome)
-- goes back to view_ops unchanged, so it retries the same key.
local definite = {invalid_input = true, refused = true, not_found = true, open_failed = true}
-- Start agent: the hub owns profiles and spawns (hub.spawn). The plugin acts for the user.
local function profile_of(id)
  for _, profile in ipairs(hub('hub.profiles').profiles or {}) do if profile.id == id then return profile end end
  fail('invalid_input', 'Unknown profile')
end
local placement_field = {id = 'placement', label = 'Open in', kind = 'select', required = true, value = 'tab',
  options = {{value = 'tab', label = 'New tab in this session'}, {value = 'session', label = 'New session'}}}
local function render_profiles(path)
  local tree = path and find_known(path)
  if not tree then fail('invalid_input', 'Unknown worktree') end
  local items = {}
  for _, profile in ipairs(hub('hub.profiles').profiles or {}) do
    items[#items + 1] = {id = profile.id, label = profile.name or profile.id,
      detail = (profile.kind or '') .. ((profile.running or 0) > 0 and (' · ' .. profile.running .. ' running') or ''),
      action = {name = 'select', label = 'Choose', enabled = true, user_only = 'navigation'}}
  end
  return {title = 'Start agent in ' .. tree.branch, nodes = {{id = 'profiles', type = 'list', label = 'Profiles', items = items}, cancel_node()}}
end
local function render_agent(id, path)
  local tree = path and find_known(path)
  if not tree then fail('invalid_input', 'Unknown worktree') end
  local profile = profile_of(id)
  local fields = {placement_field}
  for _, arg in ipairs(profile.args or {}) do
    fields[#fields + 1] = {id = 'arg/' .. arg.name, label = arg.label or arg.name, kind = 'text', required = arg.required == true, value = arg.default or ''}
  end
  return {title = (profile.name or id) .. ' in ' .. tree.branch, nodes = {
    {id = 'start_agent', type = 'form', fields = fields, submit_action = {name = 'submit', label = 'Start', enabled = true, tool = 'worktree.open'}},
    {id = 'help', type = 'widget', text = 'Directory: ' .. tree.path},
    cancel_node(),
  }}
end
local function ui_render(args)
  local base, path = route_path(args.route or '')
  local context = args.context
  local tree
  if base == '/panels/worktrees' then tree = render_panel(context)
  elseif base:match('^/forms/worktrees%-more%?') or base == '/forms/worktrees-more' then
    tree = render_more(context, more_start(base:match('^/forms/worktrees%-more%?start=(.*)$')))
  elseif base == '/forms/worktree' then tree = render_tree_menu(path)
  elseif base == '/forms/new-worktree' then tree = render_new(context)
  elseif base == '/forms/remove-worktree' then tree = render_remove(context, path)
  elseif base == '/forms/forget-repository' then tree = render_forget(path)
  elseif base == '/forms/worktree-agent' then tree = render_profiles(path)
  elseif base:sub(1, 22) == '/forms/worktree-agent/' then tree = render_agent(base:sub(23), path)
  else fail('invalid_input', 'Unknown route') end
  if base:sub(1, 7) == '/forms/' then tree.status = {state = 'blocked', kind = 'question', msg = 'Waiting for input'} end
  -- The final size check, with the status (see Panel pages): a reply that is too large never arrives.
  local reply = {tree = tree}
  if encoded(reply) > view_bytes then fail('too_large', 'This view is larger than 48 KiB') end
  return reply
end

-- worktree.open, the menu's Open items, the Start agent form and the shell after New Worktree all
-- use open_request. req = {path, where, profile, title, args}. keys = {spawn, ensure}: the hub keys
-- (the user keeps the keys of older versions; hub.spawn keys are per caller). view = the user's
-- palette context ({session_id, window_id}); nil for an agent, which gets on_behalf instead.
-- branch_title: without a title, the tab gets the branch name (the menu's Open items). The
-- fingerprint keeps the title as given, so a replay does not depend on the current tree.
-- Order: validate; replay a saved intent; check the tree and the profile; save the intent; ensure
-- the session; save the request; spawn. A retry sends the saved request again, so a moved caller,
-- a removed tree or a changed profile cannot change it.
local function runes(value)
  local n = 0
  for i = 1, #value do local b = value:byte(i); if b < 128 or b >= 192 then n = n + 1 end end
  return n
end
local function open_fingerprint(req)
  local names = {}
  for name in pairs(req.args) do names[#names + 1] = name end
  table.sort(names)
  local value = 'open-v1/' .. part(req.path) .. part(req.where) .. part(req.profile) .. part(req.title or '') .. part(tostring(#names))
  for _, name in ipairs(names) do value = value .. part(name) .. part(req.args[name]) end
  return value
end
local function open_request(caller, req, keys, view, requester_pid, branch_title)
  local path = text(req.path, 'path')
  if path:sub(1, 1) ~= '/' then fail('invalid_input', 'path must be absolute') end
  local where = req.where == nil and 'tab' or req.where
  if where ~= 'tab' and where ~= 'session' then fail('invalid_input', "where must be 'tab' or 'session'") end
  local profile_id = text(req.profile == nil and 'shell' or req.profile, 'profile')
  if req.title ~= nil and (type(req.title) ~= 'string' or runes(req.title) > 60) then fail('invalid_input', 'title must be text of at most 60 characters') end
  local named = {}
  if req.args ~= nil then
    if type(req.args) ~= 'table' then fail('invalid_input', 'args must be an object of strings') end
    for name, value in pairs(req.args) do
      if type(name) ~= 'string' or type(value) ~= 'string' or #value > 16000 then fail('invalid_input', 'args must be an object of strings of at most 16000 bytes') end
      named[name] = value
    end
  end
  -- hub.spawn keys are at most 128 bytes, hub.session.ensure keys 1024. A shorter alias could join
  -- two operations, so refuse.
  if #keys.spawn > 128 or #keys.ensure > 1024 then fail('invalid_input', 'The operation key is too long') end
  req = {path = path, where = where, profile = profile_id, title = req.title, args = named}
  local fingerprint = open_fingerprint(req)
  -- One record per caller and spawn key. After an identity migration, the record of a legacy ID
  -- is the same operation: the hub moves that ID's spawns to the identity, so hub.spawn replays
  -- the first spawn (and refuses a key that both IDs used).
  local record_keys = {}
  for _, alias in ipairs(caller.aliases) do record_keys[#record_keys + 1] = 'open/' .. part(alias) .. part(keys.spawn) end
  local own_key, intent, rev
  local function load()
    local records = hub('hub.store.get', {keys = record_keys}).records
    own_key, intent, rev = record_keys[1], nil, '0'
    for _, key in ipairs(record_keys) do
      local r = records[key]
      if r and r.value ~= nil then
        if r.value.fingerprint ~= fingerprint then fail('operation_conflict', 'This key has different content') end
        own_key, intent, rev = key, r.value, r.rev
        return
      end
    end
  end
  local function put(value)
    local result = hub('hub.store.batch', {ops = {{key = own_key, if_rev = rev, value = value}}})
    if result.conflict then load(); return false end
    rev = result.revs and result.revs[own_key] or rev
    intent = value
    return true
  end
  load()
  if not intent then
    local tree = find_known(path)
    if not tree or tree.state == 'missing' or tree.state == 'bare' then fail('invalid_input', 'The worktree is not available') end
    local profile = profile_of(profile_id)
    local declared = {}
    for _, arg in ipairs(profile.args or {}) do
      declared[arg.name] = true
      if arg.required == true and (named[arg.name] == nil or named[arg.name] == '') and (arg.default == nil or arg.default == '') then
        fail('invalid_input', 'The profile needs the argument ' .. arg.name)
      end
    end
    for name in pairs(named) do if not declared[name] then fail('invalid_input', 'The profile has no argument ' .. name) end end
    local request = {profile = profile_id, key = keys.spawn, cwd = tree.path, title = req.title}
    if request.title == nil and branch_title then
      -- hub.spawn titles are at most 60 characters. Cut a long branch name at a character boundary.
      local title, n = tree.branch, 0
      for i = 1, #title do
        local b = title:byte(i)
        if b < 128 or b >= 192 then n = n + 1 end
        if n > 60 then title = title:sub(1, i - 1); break end
      end
      request.title = title
    end
    if next(named) then request.args = named end
    if where == 'tab' then
      if view then
        -- The user lands in the new tab, only while the source tab is still active (hub.spawn focus).
        request.placement = {session = view.session_id, focus = {source_window_id = view.window_id}}
      elseif caller.session then request.placement = {session = caller.session} end
    end
    local value = {fingerprint = fingerprint, actor = caller.agent, phase = where == 'session' and 'prepared' or 'ready',
      request = request, ensure = where == 'session' and {key = keys.ensure, name = tree.branch} or nil}
    if not put(value) and not intent then fail('conflict', 'The open intent changed; retry with the same key') end
  end
  if intent.phase == 'prepared' then
    -- A spawn into another session cannot select that session in the app, so it asks for no focus.
    local session = hub('hub.session.ensure', {key = intent.ensure.key, name = intent.ensure.name}).session_id
    local value = {fingerprint = intent.fingerprint, actor = intent.actor, phase = 'ready', request = intent.request, ensure = intent.ensure}
    value.request.placement = {session = session}
    if not put(value) then fail('conflict', 'The open intent changed; retry with the same key') end
  end
  local spawn = {}
  for name, value in pairs(intent.request) do spawn[name] = value end
  if caller.user then spawn['for'] = 'user' else spawn.on_behalf = requester_pid end
  local result = hub('hub.spawn', spawn)
  if result.status == 'failed' then fail('open_failed', 'The terminal did not start: ' .. tostring(result.error or 'unknown error')) end
  if result.status ~= 'pending' and result.status ~= 'open' and result.status ~= 'closed' then
    -- An unknown status is not proof of an open: keep the key for a retry.
    fail('unavailable', 'hub.spawn gave an unknown status: ' .. tostring(result.status))
  end
  return {status = result.status == 'pending' and 'running' or result.status, spawn_id = result.spawn_id,
    session_id = result.session_id, agent_id = result.agent_id, path = intent.request.cwd}
end
-- The view result of an open: running keeps the view operation running (the hub retries the same
-- key); open and closed close the form.
local function open_effect(result)
  if result.status == 'running' then return {status = 'running'} end
  return {close_form = true}
end
local function start_agent(args, id, path)
  local key = text(args.operation_key, 'operation_key')
  local values = type(args.input) == 'table' and type(args.input.values) == 'table' and args.input.values or {}
  local named = {}
  for name, value in pairs(values) do
    if type(name) == 'string' and name:sub(1, 4) == 'arg/' and type(value) == 'string' and value ~= '' then named[name:sub(5)] = value end
  end
  local where = values.placement == 'session' and 'session' or 'tab'
  return open_effect(open_request(user_caller, {path = path, where = where, profile = id, args = named},
    {spawn = 'worktree-agent/' .. key, ensure = 'agent/' .. key}, args.context))
end
local function open_menu(args, path, where, key)
  return open_request(user_caller, {path = path, where = where, profile = 'shell'},
    {spawn = 'worktree-open/' .. key, ensure = 'open/' .. key}, args.context, nil, true)
end
local function ui_action(args)
  local base, path = route_path(args.route or '')
  local input = type(args.input) == 'table' and args.input or {}
  local more_page = base == '/forms/worktrees-more' or base:match('^/forms/worktrees%-more%?') ~= nil
  if base == '/panels/worktrees' or more_page then
    if base == '/panels/worktrees' and args.node_id == 'new' and args.action == 'new' then return {form = '/forms/new-worktree'} end
    if args.node_id == 'worktrees' and args.action == 'select' and type(input.item_id) == 'string' then
      return {form = route_with_path('/forms/worktree', input.item_id)}
    end
    if base == '/panels/worktrees' and args.node_id == 'refresh' and args.action == 'refresh' then refresh_safe(); return {} end
    if args.action == 'more' and type(args.node_id) == 'string' and args.node_id:sub(1, 5) == 'more/' then
      return {form = '/forms/worktrees-more?start=' .. more_start(args.node_id:sub(6))}
    end
    if args.action == 'discard' and type(args.node_id) == 'string' and args.node_id:sub(1, 8) == 'pending/' then
      local result = discard_request(user_caller, {id = args.node_id:sub(9)}, args.operation_key); refresh_safe(); return result
    end
  elseif base == '/forms/worktree' and args.node_id == 'worktree_menu' and args.action == 'run' then
    if input.item_id == 'agent' then return {form = route_with_path('/forms/worktree-agent', path)} end
    if input.item_id == 'remove' then return {form = route_with_path('/forms/remove-worktree', path)} end
    if input.item_id == 'forget' then return {form = route_with_path('/forms/forget-repository', path)} end
    if input.item_id == 'open_tab' or input.item_id == 'open_session' then
      return open_effect(open_menu(args, path, input.item_id == 'open_session' and 'session' or 'tab', text(args.operation_key, 'operation_key')))
    end
  elseif base == '/forms/new-worktree' and args.node_id == 'new_worktree' and args.action == 'submit' then
    -- the maintainer (2026-10-17): after New Worktree, open a shell there in a new tab. A retry replays the
    -- same Git operation and the same spawn key.
    local result = submit_worktree(args)
    if result.status == 'running' or result.created == nil then return result end
    local ok, effect = pcall(function()
      return open_effect(open_menu(args, result.path, 'tab', 'created/' .. text(args.operation_key, 'operation_key')))
    end)
    if not ok then
      if type(effect) ~= 'table' or not definite[effect.code] then error(effect) end
      fail('open_failed', 'The worktree exists at ' .. result.path .. ', but its shell did not start: ' .. tostring(effect.message) .. ' Open it from the Worktrees panel.')
    end
    if effect.status == 'running' then return effect end
    return result
  elseif base == '/forms/remove-worktree' and not path and args.node_id == 'remove_pick' and args.action == 'select' and type(input.item_id) == 'string' then
    return {form = route_with_path('/forms/remove-worktree', input.item_id)}
  elseif base == '/forms/remove-worktree' and args.node_id == 'remove_worktree' and args.action == 'submit' then
    return submit_worktree(args)
  elseif base == '/forms/forget-repository' and args.node_id == 'forget_repository' and args.action == 'submit' then
    local values = type(args.input) == 'table' and args.input.values or nil
    if type(values) ~= 'table' then fail('invalid_input', 'Forget form values are required') end
    -- The submit accepts the workers that the form showed. A changed set shows the form again.
    local result = forget(user_caller, {repo = values.repo, key = text(args.operation_key, 'operation_key'), accept_unattributed = true},
      text(values.workers, 'workers'))
    if result.changed then return {form = route_with_path('/forms/forget-repository', values.repo)} end
    refresh_safe()
    return {close_form = true}
  elseif base == '/forms/worktree-agent' and args.node_id == 'profiles' and args.action == 'select' and type(input.item_id) == 'string' then
    return {form = route_with_path('/forms/worktree-agent/' .. input.item_id, path)}
  elseif base:sub(1, 22) == '/forms/worktree-agent/' and args.node_id == 'start_agent' and args.action == 'submit' then
    return start_agent(args, base:sub(23), path)
  end
  fail('invalid_input', 'Unknown view action')
end

local actions = {
  {name = 'worktree.create', title = 'Create a worktree',
    description = 'Create a worktree under ~/.lazyrex/worktrees/<repo>-<id>/<branch> (id: 6 hex digits from the Git directory path), or return the linked tree of the branch that already exists under that root, also at an older path. base applies to a new branch. Choose a key and preserve the request on retry. A running result requires a same-key retry to obtain the final result.',
    args = {type = 'object', properties = {repo = {type = 'string'}, branch = {type = 'string'}, base = {type = 'string'}, key = {type = 'string'}}, required = {'repo', 'branch', 'key'}, additionalProperties = false}},
  {name = 'worktree.list', title = 'List worktrees',
    description = 'List worktrees, dirty state, and workers. Omit repo for repositories recorded by this plugin. repo must be an absolute Git worktree directory; it filters only worktrees. worktrees: the latest scan, sorted by path, at most 50 entries and 16 KiB a page; an entry too large for a page has compact = true and workers_count instead of workers (hub.workers lists the workers). operations: every pending worktree operation (id, kind, phase, path, branch, actor if known), sorted by id, at most 50 entries and 24 KiB a page; an entry too large has compact = true. A list is absent when its page is empty. When worktrees_next or operations_next is present, call again with worktrees_after or operations_after set to it for the next page; a cursor is a position, and a list can change between pages. A call with a cursor reads the latest scan and starts a scan only if there is none. Paging changes nothing. error text is at most 1024 bytes.',
    args = {type = 'object', properties = {repo = {type = 'string'}, worktrees_after = {type = 'string', minLength = 1}, operations_after = {type = 'string', minLength = 1}}, additionalProperties = false}},
  {name = 'worktree.remove', title = 'Remove a worktree',
    description = 'Remove a managed linked worktree, also one that another agent or the user created. Refuse changes, ignored files, workers, and terminal panes in the tree. A running result requires a same-key retry. Never force removal or delete a branch. Preserve key and path on retry. A recorded refusal needs a new key after its cause is fixed.',
    args = {type = 'object', properties = {path = {type = 'string'}, key = {type = 'string'}}, required = {'path', 'key'}, additionalProperties = false}},
  {name = 'worktree.open', title = 'Open a worktree',
    description = 'Start a profile (default shell; hub.profiles lists them, for example an agent) with the worktree as its directory, in a new tab of your session (where=tab) or in a new session (where=session). After worktree.create, open a shell with this action, as the New Worktree form does. You own the worker (hub.stop). Choose a key; after an unknown outcome or a running result, retry with the same key and content.',
    args = {type = 'object', properties = {path = {type = 'string', minLength = 1}, where = {type = 'string', enum = {'tab', 'session'}},
      profile = {type = 'string', minLength = 1}, title = {type = 'string', maxLength = 60},
      args = {type = 'object', additionalProperties = {type = 'string', maxLength = 16000}}, key = {type = 'string', minLength = 1, maxLength = 114}},
      required = {'path', 'key'}, additionalProperties = false}},
  {name = 'worktree.discard', title = 'Discard a stopped worktree operation',
    description = 'Discard a pending worktree operation (create or remove) that stopped. Name it with exactly one of: id, the full operation ID of any pending operation (worktree.list operations); or operation, the key of your own operation. Refused while its Git process runs or its start is unknown. Result: status discarded, or status complete when the operation had already ended by itself (its own key returns its result). key is the key of this discard; retry with the same content after an unknown outcome.',
    args = {type = 'object', properties = {operation = {type = 'string', minLength = 1}, id = {type = 'string', minLength = 1}, key = {type = 'string', minLength = 1}},
      required = {'key'}, additionalProperties = false}},
  {name = 'worktree.forget', title = 'Forget a repository',
    description = 'Remove a recorded repository from worktree.list and the panel. Nothing on disk changes: no file, branch, worktree or process. repo is the recorded repository path (a worktree.list row whose path equals its repo). Refused while an unfinished operation uses the repository, while a worker is inside the repository path or a tree that Git lists, and while a worker has an unknown directory. When Git cannot list the repository, workers outside every listable recorded repository may use it: the call fails with needs_confirmation and lists them; call again with the same key and accept_unattributed = true. A later worktree.create records the repository again. Choose a key; a same-key retry returns the saved result. A refusal is not saved.',
    args = {type = 'object', properties = {repo = {type = 'string', minLength = 1}, key = {type = 'string', minLength = 1}, accept_unattributed = {type = 'boolean'}},
      required = {'repo', 'key'}, additionalProperties = false}},
}
-- The startup work runs after the main chunk and the SDK's registration (both rex.after(0), in
-- order), so the main chunk runs no pcall: on Rex 0.0.1792158932-g88fd41, a catch in the main
-- chunk splits module-level locals between the closures made before and after it (hub
-- docs/rex-protocol.md, "Rex Lua runtime"). start() either completes or raises the catalog error
-- and stays incomplete; each handler calls it first, so a failed startup read fails the action and
-- nothing dispatches. A completed operation can leave an unlock pending after a lost hub reply: each
-- cleanup has its own catch, and a failed one stays in phase cleanup (a same-key replay, a discard
-- or the next start ends it). The state is a table field, not an upvalue that a closure writes.
local startup = {complete = false, tabs = false}
local function start()
  if startup.complete then return end
  -- Worktrees has no tab (the maintainer, 2026-10-17): palette commands and a side panel. The hub
  -- accepts hub.ui.tabs only from a registered instance, so it waits for the SDK's registration.
  if not startup.tabs then hub('hub.ui.tabs', {tabs = {}}); startup.tabs = true end
  local state = catalog()
  for id, op in pairs(state.pending) do if op.phase == 'cleanup' then pcall(cleanup_done, id) end end
  startup.complete = true
  refresh_safe()
end
local function started(fn) return function(ctx, args) start(); return fn(ctx, args) end end

-- The SDK gives the key of an agent action as ctx.key.
local handlers = {
  ['worktree.create'] = function(ctx, args)
    args.key = ctx.key
    local result = mutate(agent_caller(ctx), 'create', args)
    if result.status ~= 'running' then refresh_safe() end
    return result
  end,
  ['worktree.list'] = function(ctx, args) return list_request(args) end,
  ['worktree.remove'] = function(ctx, args)
    args.key = ctx.key
    local result = mutate(agent_caller(ctx), 'remove', args)
    if result.status ~= 'running' then refresh_safe() end
    return result
  end,
  -- on_behalf (hub.spawn): the hub accepts the requester PID only while this forward is in flight.
  ['worktree.open'] = function(ctx, args)
    args.key = ctx.key
    local caller, key = agent_caller(ctx), text(ctx.key, 'key')
    return open_request(caller, args, {spawn = 'worktree-open/' .. key, ensure = 'agent-open/' .. part(caller.agent) .. part(key)}, nil, ctx.requester_pid)
  end,
  ['worktree.discard'] = function(ctx, args)
    local result = discard_request(agent_caller(ctx), {operation = args.operation, id = args.id}, ctx.key)
    refresh_safe()
    return result
  end,
  ['worktree.forget'] = function(ctx, args)
    args.key = ctx.key
    local result = forget(agent_caller(ctx), args)
    refresh_safe()
    return result
  end,
}
for _, a in ipairs(actions) do
  app.action(a.name, a.args, started(handlers[a.name]), {tx = false, store = false, title = a.title, description = a.description})
end

-- The panel and the forms are raw views: the panel pages and the forms build their own trees.
local views = {render = started(function(ctx, args) return ui_render(args).tree end),
  ['view.action'] = started(function(ctx, args) return ui_action(args) end)}
app.view('/panels/worktrees', views, raw)
app.view('/forms/*', views, raw)
app.on('hub.changed', started(function(args) if args.what == 'workers' then notify('workers') end end), raw)
app.on('view.seen', started(function(args) if args.reason == 'focus' then notify('always') end end), raw)
app.command({id = 'worktrees', title = 'Worktrees…', description = 'List worktrees, with the source repository first', keywords = {'git', 'branch'},
  surface = 'panel', landing = true, route = '/panels/worktrees', user_only = 'navigation'})
app.command({id = 'new_worktree', title = 'New Worktree…', description = 'Create a worktree for a branch', keywords = {'git', 'branch'}, route = '/forms/new-worktree', action = 'worktree.create'})
app.command({id = 'remove_worktree', title = 'Remove Worktree…', description = 'Remove a managed worktree', keywords = {'git', 'branch'}, route = '/forms/remove-worktree', action = 'worktree.remove'})
rex_ok('session.attach', {session_id = plugin_session, event_scope = 'session'})
-- The first start: after every closure and the SDK's registration. Its error waits for the next action.
rex.after(0, function() pcall(start) end)
