-- Parity fixture (LazyRex docs/testing.md, "Agent parity"): renders the forms that open only from
-- another view (the tree menu, the remove confirmation and the Start agent forms).
local W = load_fixture(FIXTURE:match('^(.*)/[^/]*$') .. '/support/fixture.lua')
local repo = W.repo('parity')
local alice = agent('alice')
local tree = W.settle(function() return alice:call('worktree.create', {repo = repo, branch = 'parity/one', key = 'parity'}) end)

local function opens(view, node, action, input, route)
  local op = view:action(node, action, input)
  if op.status ~= 'succeeded' or op.effects == 'failed' then error(route .. ' did not open: ' .. show(op), 0) end
  local v = user:view(route)
  v:render()
  return v
end

user:command('worktrees')
local panel = user:view('/panels/worktrees')
panel:render()
local menu_route = W.route('/forms/worktree', tree.path)
local menu = opens(panel, 'worktrees', 'select', {item_id = tree.path}, menu_route)
opens(menu, 'worktree_menu', 'run', {item_id = 'remove'}, W.route('/forms/remove-worktree', tree.path))
user:command('worktrees')
menu = opens(user:view('/panels/worktrees'), 'worktrees', 'select', {item_id = tree.path}, menu_route)
local agent_route = W.route('/forms/worktree-agent', tree.path)
local profiles = opens(menu, 'worktree_menu', 'run', {item_id = 'agent'}, agent_route)
opens(profiles, 'profiles', 'select', {item_id = 'shell'}, W.route('/forms/worktree-agent/shell', tree.path))
