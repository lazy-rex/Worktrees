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
-- s.on_hub[action] = fn runs fn when the plugin calls that hub action. s.calls[action] counts the hub actions; s.timers holds the rex.after callbacks not yet run.
return function(plugin_dir, base)
  local s = {handlers = {}, hub_errors = {}, calls = {}, timers = {}, workers = {}, on_hub = {},
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
        if s.on_hub[args.action] then s.on_hub[args.action]() end
        if s.hub_errors[args.action] then return nil, s.hub_errors[args.action] end
        if args.action == 'hub.store.get' then return {result = {records = {catalog = {rev = '1', value = s.catalog or {repos = {}, pending = {}}}}}} end
        if args.action == 'hub.workers' then return {result = {workers = s.workers}} end
        if args.action == 'hub.identify' then return {result = {found = true, agent = 'alice', session_id = 'session'}} end
        return {result = {}}
      end
      if method == 'client.reply' then s.reply = args end
      return {}
    end,
  }
  local env = setmetatable({rex = stub}, {__index = base})
  local chunk = assert(loadfile(plugin_dir .. '/worktrees.lua'))
  setfenv(chunk, env)
  s.loaded, s.load_error = pcall(chunk)
  function s:perform(action, args, requester)
    self.reply = nil
    self.handlers.client_perform_requested({}, {requester = requester or {client_id = 'hub'}, action = action, call_id = 'c', args = args})
    return self.reply
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
