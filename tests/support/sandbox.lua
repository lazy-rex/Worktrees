-- The plugin in a sandbox: worktrees.lua loaded with a stub rex (the pattern of the Tunnels plugin
-- tests). The stub runs no process except the answers below and reaches no Rex server or hub.
-- Usage:
--   local s = load_fixture(dir .. '/support/sandbox.lua')(plugin_dir, getfenv(1))
--   s.hub_errors['hub.workers'] = '<error text>'   -- that hub action fails with this text
--   local reply = s:perform('hub.changed', {what = 'workers'})
-- s.loaded and s.load_error report the load; s:perform answers the plugin's client.reply.
return function(plugin_dir, base)
  local s = {handlers = {}, hub_errors = {}}
  local function exec(argv)
    if argv[1] == 'mkdir' then return {ok = true, stdout = '', stderr = ''} end
    if argv[1] == 'realpath' then return {ok = true, stdout = argv[2] .. '\n', stderr = ''} end
    error('the sandbox runs no process: ' .. tostring(argv[1]))
  end
  local stub = {
    args = {hub_client_id = 'hub', instance_id = 'instance', plugin_session = 'plugin', worktrees_root = '/sandbox/worktrees'},
    on = function(name, fn) s.handlers[name] = fn end,
    after = function() end, -- No timer runs: no scan.
    exec = setmetatable({start = function() error('the sandbox starts no process') end}, {__call = function(_, argv) return exec(argv) end}),
    call = function(method, args)
      if method == 'client.perform' then
        if s.hub_errors[args.action] then return nil, s.hub_errors[args.action] end
        if args.action == 'hub.store.get' then return {result = {records = {catalog = {rev = '1', value = {repos = {}, pending = {}}}}}} end
        if args.action == 'hub.workers' then return {result = {workers = {}}} end
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
  function s:perform(action, args)
    self.reply = nil
    self.handlers.client_perform_requested({}, {requester = {client_id = 'hub'}, action = action, call_id = 'c', args = args})
    return self.reply
  end
  return s
end
