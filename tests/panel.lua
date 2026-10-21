-- The panel and forms end to end on the real hub (ported from worktrees-panel-lab.mjs phases A-G
-- and the view cases of worktrees.mjs). Key presses and screen text are renderer rows in the
-- coverage map; these tests check the hub routes, effects, Rex focus and the plugin's trees.
local W = load_fixture(H.args.file:match('^(.*)/[^/]*$') .. '/support/fixture.lua')
local lab = H.args.lab
local S = H.args.tests_session
local repo = W.repo('panel')
local alice = agent('alice')

write_profiles({profiles = {{id = 'sleeper', name = 'Sleeper', kind = 'agent', command = {'/bin/sleep', '600'}}}})

local function sview(s)
  rex.call('session.attach', {session_id = s, event_scope = 'session'})
  return rex.call('session.view', {session_id = s})
end
-- tab opens a new window in session s with one pane that runs argv in cwd; returns window, block.
local function tab(s, label, argv, cwd)
  local before = {}
  for _, w in ipairs(sview(s).windows or {}) do before[w.window_id] = true end
  rex.call('session.new_window', {session_id = s, window_label = label, layout = {block = {flavor = 'com.superlogical.terminal.shell',
    label = label, options = {command = argv, cwd = cwd, login = false, exit = {on_completion = false}}}}})
  for _, w in ipairs(sview(s).windows or {}) do
    if not before[w.window_id] then
      for _, layer in ipairs(w.layers or {}) do for _, b in ipairs(layer.blocks or {}) do return w.window_id, b.block_id end end
    end
  end
  error('no new window', 0)
end
-- osc7 runs a pane that reports dir with OSC 7, then sleeps until killed.
local function osc7_argv(dir)
  local encoded = dir:gsub('([^%w%-%._~/])', function(c) return string.format('%%%02X', string.byte(c)) end)
  return {'/bin/sh', '-c', 'printf "\\033]7;file://localhost%s\\007" "$1"; exec sleep 600', 'sh', encoded}
end
local function view_in(window, route_prefix)
  for _, v in ipairs(H.views()) do
    if v.window_id == window and v.route and v.route:sub(1, #route_prefix) == route_prefix then return v end
  end
end
local function wait_view(window, route_prefix, what)
  local info = wait(what or ('a view ' .. route_prefix), function() return view_in(window, route_prefix) end, 20)
  -- One side pane at most: a new form or panel replaces the one in its window.
  local n = 0
  for _, v in ipairs(H.views()) do if v.window_id == window then n = n + 1 end end
  expect(n <= 1, 'one side view in the window, got ' .. n).to_be(true)
  return user:view(info.route, nil, info.session_id)
end
local function item(tree, node_id, id)
  local n = node(tree, node_id)
  for _, it in ipairs(n and n.items or {}) do if it.id == id then return it end end
end
local function spawn_windows(s, title)
  local out = {}
  for _, w in ipairs(sview(s).windows or {}) do
    for _, layer in ipairs(w.layers or {}) do
      for _, b in ipairs(layer.blocks or {}) do
        if (b.label or ''):sub(1, 14) == 'lazyrex-spawn:' and w.label == title then out[#out + 1] = w; break end
      end
    end
  end
  return out
end
local function form_value(tree, form_id, field_id)
  for _, f in ipairs(node(tree, form_id).fields) do if f.id == field_id then return f.value end end
end

-- The source tab: a shell pane in the repository (process cwd, no OSC 7).
local src_window, src = tab(S, 'src', {'/bin/sleep', '600'}, repo)

test('A: the palette has the three commands with their parity declarations', function()
  local commands = {}
  for _, c in ipairs(H.hub('hub.test.commands', {plugin = 'worktrees'}).commands or {}) do commands[c.id] = c end
  expect(commands.worktrees.route).to_be('/panels/worktrees')
  expect(commands.new_worktree.route).to_be('/forms/new-worktree')
  expect(commands.remove_worktree.route).to_be('/forms/remove-worktree')
  expect(tabs()).to_equal({})
end)

test('B: Worktrees… opens the panel in the source tab; the source repository comes first', function()
  user:command('worktrees', {session = S, block = src})
  local panel = wait_view(src_window, '/panels/worktrees', 'the panel in the source tab')
  local tree = wait('the source repository row is clean', function()
    local rendered = panel:render()
    local first = node(rendered, 'worktrees').items[1]
    return first and first.id == repo and first.detail:find('clean', 1, true) and rendered
  end, 20)
  -- No create has recorded the repository yet.
  expect(node(tree, 'new').text).to_be('Repository: ' .. repo .. ' (not recorded)')
  expect(node(tree, 'worktrees').items[1].label).to_be('main')
end)

local feat
test('C: New Worktree… from the panel keeps the source repository; the submit opens an active shell tab; the panel returns', function()
  local panel = wait_view(src_window, '/panels/worktrees')
  -- The palette runs in the panel's pane; the source stays the source pane.
  user:command('new_worktree', panel)
  local form = wait_view(src_window, '/forms/new-worktree', 'the form replaces the panel')
  local form_tree = form:render()
  expect(form_value(form_tree, 'new_worktree', 'repo')).to_be(repo)
  -- The plugin text that panel-lab read on the screen (112-113): the submit label.
  expect(node(form_tree, 'new_worktree').submit_action.label).to_be('Create worktree')
  local op = form:action('new_worktree', 'submit', {values = {repo = repo, branch = 'feat-a', base = ''}}, 'c-create')
  expect(op.status).to_be('succeeded')
  feat = W.tree_path(repo, 'feat-a')
  expect(W.try({'test', '-d', feat}).ok).to_be(true)
  local shell = wait('one shell tab', function() local w = spawn_windows(S, 'feat-a'); return #w == 1 and w[1] end, 20)
  wait('the shell tab is active (placement.focus)', function() return sview(S).active_window_id == shell.window_id end, 20)
  local back = wait_view(src_window, '/panels/worktrees', 'the panel returns')
  local row = wait('the panel lists feat-a', function() return item(back:render(), 'worktrees', feat) end, 20)
  -- The label that panel-lab read on the screen (126).
  expect(row.label).to_be('feat-a')
end)

test('D: Open in new tab makes the new tab active; Open in new session keeps the source focus; the panel returns', function()
  rex.call('session.focus_block', {session_id = S, block_id = src})
  local panel = wait_view(src_window, '/panels/worktrees')
  panel:render()
  expect(panel:action('worktrees', 'select', {item_id = feat}).status).to_be('succeeded')
  local menu = wait_view(src_window, '/forms/worktree?path=', 'the tree menu')
  expect(menu.route).to_be(W.route('/forms/worktree', feat))
  -- The menu item labels that panel-lab read on the screen (136, 147, 168, 187).
  local items = {}
  for _, it in ipairs(node(menu:render(), 'worktree_menu').items) do items[#items + 1] = it.label end
  expect(items).to_equal({'Open in new tab', 'Open in new session', 'Start agent…', 'Remove…'})
  local first = spawn_windows(S, 'feat-a')[1]
  expect(menu:action('worktree_menu', 'run', {item_id = 'open_tab'}, 'd-open-tab').status).to_be('succeeded')
  local second = wait('a second shell tab', function()
    for _, w in ipairs(spawn_windows(S, 'feat-a')) do if w.window_id ~= first.window_id then return w end end
  end, 20)
  wait('the second shell tab is active', function() return sview(S).active_window_id == second.window_id end, 20)

  rex.call('session.focus_block', {session_id = S, block_id = src})
  wait('the source tab is active', function() return sview(S).active_window_id == src_window end)
  panel = wait_view(src_window, '/panels/worktrees', 'the panel returns after Open')
  panel:render()
  panel:action('worktrees', 'select', {item_id = feat})
  menu = wait_view(src_window, '/forms/worktree?path=')
  menu:render()
  local sessions = {}
  for _, x in ipairs(rex.call('session.list', {}).sessions) do sessions[x.session_id] = true end
  expect(menu:action('worktree_menu', 'run', {item_id = 'open_session'}, 'd-open-session').status).to_be('succeeded')
  local other = wait('a new session named feat-a', function()
    for _, x in ipairs(rex.call('session.list', {}).sessions) do
      if not sessions[x.session_id] and x.label == 'feat-a' then return x.session_id end
    end
  end, 20)
  wait('a shell in the new session', function() return #spawn_windows(other, 'feat-a') == 1 end, 20)
  wait_view(src_window, '/panels/worktrees', 'the panel returns after Open in new session')
  expect(sview(S).active_window_id).to_be(src_window)
  close_session(other)
end)

test('E: Start agent… starts the chosen profile in the tree; the panel returns', function()
  local panel = wait_view(src_window, '/panels/worktrees')
  panel:render()
  panel:action('worktrees', 'select', {item_id = repo})
  local menu = wait_view(src_window, '/forms/worktree?path=')
  menu:render()
  expect(menu:action('worktree_menu', 'run', {item_id = 'agent'}).status).to_be('succeeded')
  local profiles = wait_view(src_window, '/forms/worktree-agent?path=', 'the profile list')
  local labels = {}
  for _, it in ipairs(node(profiles:render(), 'profiles').items) do labels[#labels + 1] = it.label end
  expect(labels).to_contain('Sleeper')
  profiles:action('profiles', 'select', {item_id = 'sleeper'})
  local form = wait_view(src_window, '/forms/worktree-agent/sleeper?path=', 'the profile form')
  expect(node(form:render(), 'start_agent').submit_action.label).to_be('Start')
  expect(form:action('start_agent', 'submit', {values = {placement = 'tab'}}, 'e-start').status).to_be('succeeded')
  local found
  for _, w in ipairs(H.hub('hub.workers', {}).workers or {}) do
    if w.profile == 'sleeper' and w.cwd == repo then found = w end
  end
  expect(found ~= nil, 'a sleeper worker in the main tree').to_be(true)
  wait_view(src_window, '/panels/worktrees', 'the panel returns after Start')
end)

test('F: the remove confirmation refuses while shells run; Cancel returns to the panel', function()
  local panel = wait_view(src_window, '/panels/worktrees')
  panel:render()
  panel:action('worktrees', 'select', {item_id = feat})
  local menu = wait_view(src_window, '/forms/worktree?path=')
  menu:render()
  expect(menu:action('worktree_menu', 'run', {item_id = 'remove'}).status).to_be('succeeded')
  local confirm = wait_view(src_window, '/forms/remove-worktree?path=', 'the remove confirmation')
  wait('the refusal advice', function()
    local check = node(confirm:render(), 'check')
    return check and check.text:find('Removal will be refused', 1, true)
  end, 20)
  -- Cancel ($cancel, Esc) is renderer mechanics: the renderer exits (view/menu.go cancelForm), so
  -- its pane closes. The test closes the form's pane; the hub then restores the panel.
  expect(node(confirm:render(), 'cancel').action.name).to_be('$cancel')
  local info = view_in(src_window, '/forms/remove-worktree?path=')
  rex.call('block.close', {session_id = info.session_id, block_id = info.block_id})
  wait_view(src_window, '/panels/worktrees', 'the panel after Cancel')
end)

test('G: after the shells close, Remove Worktree… (picker, then confirm) removes the tree and keeps the branch', function()
  for _, w in ipairs(spawn_windows(S, 'feat-a')) do
    for _, layer in ipairs(w.layers or {}) do for _, b in ipairs(layer.blocks or {}) do rex.call('block.close', {session_id = S, block_id = b.block_id}) end end
  end
  wait('the shell tabs close', function() return #spawn_windows(S, 'feat-a') == 0 end, 20)
  user:command('remove_worktree', {session = S, block = src})
  local picker = wait_view(src_window, '/forms/remove-worktree', 'the remove picker')
  local pick = item(picker:render(), 'remove_pick', feat)
  expect(pick ~= nil).to_be(true)
  -- The label that panel-lab read on the screen (204).
  expect(pick.label).to_be('feat-a')
  picker:action('remove_pick', 'select', {item_id = feat})
  local confirm = wait_view(src_window, '/forms/remove-worktree?path=', 'the remove confirmation')
  confirm:seen('focus')
  wait('the advice is ready and clear', function()
    local tree = confirm:render()
    return node(tree, 'check') == nil and node(tree, 'help').text:find('never forces', 1, true)
  end, 20)
  expect(node(confirm:render(), 'remove_worktree').submit_action.label).to_be('Remove worktree')
  expect(confirm:action('remove_worktree', 'submit', {values = {path = feat}}, 'g-remove').status).to_be('succeeded')
  expect(W.try({'test', '-e', feat}).ok).to_be(false)
  expect(W.git(repo, 'worktree', 'list')).not_to_contain(feat)
  expect(W.git(repo, 'branch', '--list', 'feat-a')).to_match('feat%-a')
  wait_view(src_window, '/panels/worktrees', 'the panel returns after Remove')
end)
