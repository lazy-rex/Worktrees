-- The plugin in a sandbox: worktrees.lua loaded with a stub rex (the pattern of the Tunnels plugin
-- tests). The stub runs no process except the answers below and reaches no Rex server or hub.
-- Usage:
--   local s = load_fixture(dir .. '/support/sandbox.lua')(plugin_dir, getfenv(1))
--   s.hub_errors['hub.workers'] = '<error text>'   -- that hub action fails with this text
--   local reply = s:perform('hub.changed', {what = 'workers'})
--   local reply = s:perform('worktree.list', {}, s.agent)   -- an agent call (hub.identify finds it)
--   s.workers = {...}; s:tick()   -- hub.workers answers s.workers; tick runs the armed timers
-- s.exec_hook(argv) answers a command (nil: the default answer; nil and an error: the process did
-- not start); s.start_hook(argv, opts) answers
-- a process start (rex.exec.start). s.catalog is the catalog record of the hub.store version: the
-- first start imports it into SQL. s:pending() and s:repos() read the SQL records.
-- s.loaded and s.load_error report the load; s:perform answers the plugin's client.reply.
-- s.on_hub[action] = fn runs fn when the plugin calls that hub action. s.hub_answers[action] = fn(args) gives the result of that hub action. s.calls[action] counts the hub actions; s.timers holds the rex.after callbacks not yet run.
-- s.rex_answers[method] = fn(args) gives the result of a Rex call (not client.perform).
-- opts.keep keeps the SQL tables (a restart of the plugin). A hub_answers function may return nil
-- and an error text: that call fails. s.sql(name, args) runs a hub.sql action (name: exec, query, ...).
-- s.order lists the hub actions in call order. s.pcalls counts the pcall calls of the plugin (s.load_pcalls: during the load).
return function(plugin_dir, base, opts)
  opts = opts or {}
  local s = {handlers = {}, hub_errors = {}, calls = {}, order = {}, pcalls = 0, timers = {}, workers = {}, on_hub = {}, hub_answers = {}, rex_answers = {},
    agent = {principal = {kind = 'peer', pid = 4242}}}
  -- hub.sql runs on the plugin's database in the lab (the harness sql and sql_write), one statement
  -- at a time: a batch without a transaction is not atomic here. A transaction keeps its writes
  -- until the commit (s.tx_writes), so a rollback, or a failure before the commit, writes nothing; a
  -- query in it does not see them. sandbox() empties the tables first, so the import copies
  -- s.catalog at the first start.
  local tables = {'repos', 'pending', 'ops', 'reservations', 'meta', 'staging'}
  if not opts.keep then for _, t in ipairs(tables) do base.sql_write('DELETE FROM ' .. t) end end
  s.transactions = 0
  local function sandbox_sql(action, a)
    if action == 'begin' then
      s.transactions = s.transactions + 1
      s.tx_writes = {}
      return {tx = 'sandbox-' .. s.transactions}
    end
    if action == 'commit' then
      local list = s.tx_writes or {}
      s.tx_writes = nil
      for _, st in ipairs(list) do base.sql_write(st.sql, st.params) end
      return {}
    end
    if action == 'rollback' then s.tx_writes = nil; return {} end
    if action == 'replay' then return {found = false} end
    if (action == 'exec' or action == 'batch') and a.tx then
      if not s.tx_writes then error('tx_expired: no open transaction') end
      local results = {}
      for i, st in ipairs(a.statements or {{sql = a.sql, params = a.params}}) do
        s.tx_writes[#s.tx_writes + 1] = st
        results[i] = {changes = 1, id = 0}
      end
      if action == 'exec' then return results[1] end
      return {results = results}
    end
    if action == 'exec' then return base.sql_write(a.sql, a.params) end
    if action == 'batch' then
      local results = {}
      for i, st in ipairs(a.statements) do results[i] = base.sql_write(st.sql, st.params) end
      return {results = results}
    end
    if action == 'query' then
      -- sql() keys each row by column name; the SDK reads columns and rows in column order.
      local list, columns, seen = base.sql(a.sql, a.params), {}, {}
      for _, row in ipairs(list) do
        for name in pairs(row) do if not seen[name] then seen[name] = true; columns[#columns + 1] = name end end
      end
      local out = {}
      for i, row in ipairs(list) do
        out[i] = {}
        for j, name in ipairs(columns) do out[i][j] = row[name] == nil and {null = true} or row[name] end
      end
      return {columns = columns, rows = out, complete = true}
    end
    error('sandbox hub.sql: ' .. action)
  end
  s.sql = sandbox_sql
  local function exec(argv)
    if s.exec_hook then
      local r, err = s.exec_hook(argv)
      if r then return r end
      if err then return nil, err end -- the process did not start
    end
    if argv[1] == 'mkdir' then return {ok = true, stdout = '', stderr = ''} end
    if argv[1] == 'realpath' then return {ok = true, stdout = argv[2] .. '\n', stderr = ''} end
    error('the sandbox runs no process: ' .. tostring(argv[1]))
  end
  local stub = {
    args = {hub_client_id = 'hub', instance_id = 'instance', plugin_session = 'plugin', worktrees_root = '/sandbox/worktrees'},
    json = rex.json,
    on = function(name, fn) s.handlers[name] = fn end,
    after = function(_, fn) s.timers[#s.timers + 1] = fn end, -- A timer runs only in s:tick().
    exec = setmetatable({start = function(argv, opts)
      if s.start_hook then return s.start_hook(argv, opts) end
      error('the sandbox starts no process')
    end}, {__call = function(_, argv) return exec(argv) end}),
    call = function(method, args)
      if method == 'client.perform' then
        s.calls[args.action] = (s.calls[args.action] or 0) + 1
        s.order[#s.order + 1] = args.action
        if s.on_hub[args.action] then s.on_hub[args.action]() end
        if s.hub_errors[args.action] then return nil, s.hub_errors[args.action] end
        if s.hub_answers[args.action] then
          local result, err = s.hub_answers[args.action](args.args)
          if result == nil then return nil, err end
          return {result = result}
        end
        if args.action:sub(1, 8) == 'hub.sql.' then
          local ok, result = pcall(sandbox_sql, args.action:sub(9), args.args)
          if not ok then return nil, tostring(result) end
          return {result = result}
        end
        if args.action == 'hub.store.get' then return {result = {records = {catalog = {rev = '1', value = s.catalog or {repos = {}, pending = {}}}}}} end
        if args.action == 'hub.workers' then return {result = {workers = s.workers}} end
        if args.action == 'hub.identify' then return {result = {found = true, agent = 'alice', session_id = 'session'}} end
        return {result = {}}
      end
      if method == 'client.reply' then s.reply = args end
      if s.rex_answers[method] then return s.rex_answers[method](args) end
      return {}
    end,
  }
  local env = setmetatable({rex = stub, pcall = function(...) s.pcalls = s.pcalls + 1; return pcall(...) end,
    os = setmetatable({exit = function(code) s.exited = code end}, {__index = os})}, {__index = base})
  -- The SDK (require('lazyrex')) loads with the same stub, from the directory that the hub gets.
  local sdk = assert(loadfile(assert(base.H.args.sdk, 'H.args.sdk is required') .. '/lazyrex.lua'))
  setfenv(sdk, env)
  local lazyrex = sdk()
  env.require = function(name) if name == 'lazyrex' then return lazyrex end return base.require(name) end
  local chunk = assert(loadfile(plugin_dir .. '/worktrees.lua'))
  setfenv(chunk, env)
  s.loaded, s.load_error = pcall(chunk)
  s.load_pcalls = s.pcalls
  -- The SDK registers the plugin and migrates in its first timer. The hub does that before any call,
  -- so the sandbox runs it now and clears the counts. s.exited is set if the registration failed.
  if s.loaded then table.remove(s.timers, 1)(); s.calls, s.order = {}, {} end
  function s:perform(action, args, requester)
    self.reply = nil
    -- The hub sends each view call with the user (the SDK refuses one without it).
    if action:sub(1, 5) == 'view.' and type(args) == 'table' and args.user == nil then args.user = 'user' end
    self.handlers.client_perform_requested({}, {requester = requester or {client_id = 'hub'}, action = action, call_id = 'c', args = args})
    return self.reply
  end
  -- find_local finds a table local of the plugin by name (and check, if given): an upvalue of a
  -- closure that the SDK holds, also through the SDK's tables. It skips the environment and the stub.
  function s:find_local(name, check)
    local seen = {[base] = true, [env] = true, [stub] = true}
    local function walk(v)
      if seen[v] then return nil end
      seen[v] = true
      if type(v) == 'function' then
        for i = 1, 255 do
          local n, x = debug.getupvalue(v, i)
          if not n then break end
          if n == name and type(x) == 'table' and (not check or check(x)) then return x end
          if type(x) == 'function' or type(x) == 'table' then local found = walk(x); if found then return found end end
        end
      else
        for _, x in pairs(v) do
          if type(x) == 'function' or type(x) == 'table' then local found = walk(x); if found then return found end end
        end
      end
    end
    return walk(self.handlers.client_perform_requested)
  end
  -- pending gives the pending operations {id = op}; repos gives the recorded repositories {common = repo}.
  function s:pending()
    local out = {}
    for _, r in ipairs(base.sql('SELECT id, op FROM pending')) do out[r.id] = rex.json.decode(r.op) end
    return out
  end
  function s:repos()
    local out = {}
    for _, r in ipairs(base.sql('SELECT common, repo FROM repos')) do out[r.common] = r.repo end
    return out
  end
  -- tick runs the timers armed so far; a timer that a callback arms waits for the next tick.
  function s:tick()
    local due = self.timers
    self.timers = {}
    for _, fn in ipairs(due) do fn() end
    return #due
  end
  return s
end
