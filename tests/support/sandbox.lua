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
-- a process start (rex.exec.start). s.catalog is the value of the catalog record.
-- s.loaded and s.load_error report the load; s:perform answers the plugin's client.reply.
-- s.on_hub[action] = fn runs fn when the plugin calls that hub action. s.hub_answers[action] = fn(args) gives the result of that hub action. s.calls[action] counts the hub actions; s.timers holds the rex.after callbacks not yet run.
-- s.rex_answers[method] = fn(args) gives the result of a Rex call (not client.perform).
-- s.order lists the hub actions in call order. s.pcalls counts the pcall calls of the plugin (s.load_pcalls: during the load).
return function(plugin_dir, base)
  local s = {handlers = {}, hub_errors = {}, calls = {}, order = {}, pcalls = 0, timers = {}, workers = {}, on_hub = {}, hub_answers = {}, rex_answers = {},
    agent = {principal = {kind = 'peer', pid = 4242}}}
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
        if s.hub_answers[args.action] then return {result = s.hub_answers[args.action](args.args)} end
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
  local env = setmetatable({rex = stub, pcall = function(...) s.pcalls = s.pcalls + 1; return pcall(...) end}, {__index = base})
  -- The SDK (require('lazyrex')) loads with the same stub, from the directory that the hub gets.
  local sdk = assert(loadfile(assert(base.H.args.sdk, 'H.args.sdk is required') .. '/lazyrex.lua'))
  setfenv(sdk, env)
  local lazyrex = sdk()
  env.require = function(name) if name == 'lazyrex' then return lazyrex end return base.require(name) end
  local chunk = assert(loadfile(plugin_dir .. '/worktrees.lua'))
  setfenv(chunk, env)
  s.loaded, s.load_error = pcall(chunk)
  s.load_pcalls = s.pcalls
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
  -- tick runs the timers armed so far; a timer that a callback arms waits for the next tick.
  function s:tick()
    local due = self.timers
    self.timers = {}
    for _, fn in ipairs(due) do fn() end
    return #due
  end
  return s
end
