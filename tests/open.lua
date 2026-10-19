-- worktree.open: the agent tool and the view (menu Open items, the Start agent form, the shell
-- after New Worktree) use one handler. Each flow runs on both paths.
local W = load_fixture(H.args.file:match('^(.*)/[^/]*$') .. '/support/fixture.lua')
local repo = W.repo('open')
local alice, bob = agent('alice'), agent('bob')

write_profiles({profiles = {
  {id = 'task', name = 'Task', kind = 'accessory', command = {'/bin/sh', '-c', 'exec sleep 600', 'task', '${task}', '${note}'},
    args = {{name = 'task', label = 'Task', required = true}, {name = 'note', label = 'Note', default = 'none'}}},
}})

local function create(who, branch, key)
  return W.settle(function() return who:call('worktree.create', {repo = repo, branch = branch, key = key}) end)
end
local function open(who, args)
  return W.settle(function() return who:call('worktree.open', args) end, 'worktree.open finishes')
end
local function worker(spawn_id)
  for _, w in ipairs(H.hub('hub.workers', {}).workers or {}) do if w.spawn_id == spawn_id then return w end end
end
local function workers_in(path)
  local n = 0
  for _, w in ipairs(H.hub('hub.workers', {}).workers or {}) do if w.cwd == path then n = n + 1 end end
  return n
end
local function session_count()
  return #(rex.call('session.list', {}).sessions or {})
end

local tree = create(alice, 'open/one', 'open-one')

test('tool: open in a tab; the agent owns the worker; a replay returns the first spawn', function()
  local first = open(alice, {path = tree.path, key = 'tab-1'})
  expect(first.status).to_be('open')
  expect(first.path).to_be(tree.path)
  local w = worker(first.spawn_id)
  expect(w.parent).to_be('alice')
  expect(w.cwd).to_be(tree.path)
  expect(w.profile).to_be('shell')
  expect(open(alice, {path = tree.path, key = 'tab-1'}).spawn_id).to_be(first.spawn_id)
  expect(workers_in(tree.path)).to_be(1)
  -- Any agent may stop any worker (LazyRex 9bc00c8): bob stops alice's worker (parent alice, above).
  expect(bob:hub('hub.stop', {spawn_id = first.spawn_id}).status).to_be('closed')
  -- A replay after the worker closed returns the closed spawn; it starts nothing.
  local again = open(alice, {path = tree.path, key = 'tab-1'})
  expect(again.spawn_id).to_be(first.spawn_id)
  expect(again.status).to_be('closed')
  expect(workers_in(tree.path)).to_be(0)
end)

test('tool: a changed request with the same key conflicts before any session or spawn', function()
  local first = open(alice, {path = tree.path, key = 'same', where = 'tab'})
  local sessions = session_count()
  local other = create(alice, 'open/other', 'open-other')
  for _, changed in ipairs({
    {path = other.path, key = 'same'},
    {path = tree.path, key = 'same', where = 'session'},
    {path = tree.path, key = 'same', profile = 'task', args = {task = 'x'}},
    {path = tree.path, key = 'same', title = 'Other'},
    {path = tree.path, key = 'same', args = {task = 'x'}},
  }) do
    expect_error(function() alice:call('worktree.open', changed) end, 'operation_conflict')
  end
  expect(session_count()).to_be(sessions)
  expect(open(alice, {path = tree.path, key = 'same', where = 'tab'}).spawn_id).to_be(first.spawn_id)
  alice:hub('hub.stop', {spawn_id = first.spawn_id})
end)

test('tool: the same key from two agents makes two spawns', function()
  local a = open(alice, {path = tree.path, key = 'shared'})
  local b = open(bob, {path = tree.path, key = 'shared'})
  expect(a.spawn_id).not_to_be(b.spawn_id)
  expect(worker(b.spawn_id).parent).to_be('bob')
  alice:hub('hub.stop', {spawn_id = a.spawn_id})
  bob:hub('hub.stop', {spawn_id = b.spawn_id})
end)

test('tool: open in a new session, with a profile and its args', function()
  local sessions = session_count()
  local r = open(alice, {path = tree.path, key = 'session-1', where = 'session', profile = 'task', args = {task = 'review'}})
  expect(r.status).to_be('open')
  expect(session_count()).to_be(sessions + 1)
  local w = worker(r.spawn_id)
  expect(w.profile).to_be('task')
  expect(w.cwd).to_be(tree.path)
  expect(w.session_id).to_be(r.session_id)
  -- The replay keeps the session: no second session.
  expect(open(alice, {path = tree.path, key = 'session-1', where = 'session', profile = 'task', args = {task = 'review'}}).session_id).to_be(r.session_id)
  expect(session_count()).to_be(sessions + 1)
  alice:hub('hub.stop', {spawn_id = r.spawn_id})
end)

test('tool: invalid requests are refused and save nothing', function()
  expect_error(function() alice:call('worktree.open', {path = tree.path, key = 'bad-1', profile = 'missing'}) end, 'Unknown profile')
  expect_error(function() alice:call('worktree.open', {path = tree.path, key = 'bad-2', profile = 'task'}) end, 'needs the argument task')
  expect_error(function() alice:call('worktree.open', {path = tree.path, key = 'bad-3', profile = 'task', args = {task = 'x', other = 'y'}}) end, 'no argument other')
  expect_error(function() alice:call('worktree.open', {path = W.root .. '/open/none', key = 'bad-4'}) end, 'not available')
  expect_error(function() alice:call('worktree.open', {path = 'relative', key = 'bad-5'}) end, 'absolute')
  -- A refused request saves no intent, so the same key works after the cause is fixed.
  local r = open(alice, {path = tree.path, key = 'bad-1'})
  expect(r.status).to_be('open')
  alice:hub('hub.stop', {spawn_id = r.spawn_id})
end)

test('tool: a replay keeps the first request after the tree and the profile change', function()
  local gone = create(alice, 'open/gone', 'open-gone')
  local r = open(alice, {path = gone.path, key = 'kept', profile = 'task', args = {task = 'keep'}})
  alice:hub('hub.stop', {spawn_id = r.spawn_id})
  W.settle(function() return alice:call('worktree.remove', {path = gone.path, key = 'gone-remove'}) end)
  write_profiles({profiles = {}})
  local again = open(alice, {path = gone.path, key = 'kept', profile = 'task', args = {task = 'keep'}})
  expect(again.spawn_id).to_be(r.spawn_id)
  write_profiles({profiles = {
    {id = 'task', name = 'Task', kind = 'accessory', command = {'/bin/sh', '-c', 'exec sleep 600', 'task', '${task}', '${note}'},
      args = {{name = 'task', label = 'Task', required = true}, {name = 'note', label = 'Note', default = 'none'}}},
  }})
end)

-- The view path. The tree menu opens from the panel.
local function menu(path)
  user:command('worktrees')
  local panel = user:view('/panels/worktrees')
  panel:render()
  local op = panel:action('worktrees', 'select', {item_id = path})
  expect(op.status).to_be('succeeded')
  local m = user:view(W.route('/forms/worktree', path))
  m:render()
  return m
end

-- A hub retry of the same view operation (a lost hub.spawn reply) needs the faults harness
-- (LazyRex branch faults); until then the tool tests prove the intent replay.
test('view: Open in new tab and Open in new session start a user shell', function()
  local before = workers_in(tree.path)
  local m = menu(tree.path)
  local op = m:action('worktree_menu', 'run', {item_id = 'open_tab'}, 'view-open-tab')
  expect(op.status).to_be('succeeded')
  expect(workers_in(tree.path)).to_be(before + 1)
  local sessions = session_count()
  m = menu(tree.path)
  op = m:action('worktree_menu', 'run', {item_id = 'open_session'}, 'view-open-session')
  expect(op.status).to_be('succeeded')
  expect(session_count()).to_be(sessions + 1)
  expect(workers_in(tree.path)).to_be(before + 2)
  local users = 0
  for _, w in ipairs(H.hub('hub.workers', {}).workers or {}) do
    if w.cwd == tree.path and w.parent == 'user' then users = users + 1; expect(w.title).to_be('open/one') end
  end
  expect(users).to_be(2)
  -- The intent records keep the keys of older versions (worktree-open/<operation key>).
  expect(W.intent('user', 'worktree-open/view-open-tab').phase).to_be('ready')
  expect(W.intent('user', 'worktree-open/view-open-session').request.placement.focus).to_be(nil)
end)

test('view: the Start agent form starts the chosen profile with its args', function()
  local before = workers_in(tree.path)
  local m = menu(tree.path)
  m:action('worktree_menu', 'run', {item_id = 'agent'})
  local profiles = user:view(W.route('/forms/worktree-agent', tree.path))
  profiles:render()
  profiles:action('profiles', 'select', {item_id = 'task'})
  local form = user:view(W.route('/forms/worktree-agent/task', tree.path))
  form:render()
  local op = form:action('start_agent', 'submit', {values = {placement = 'tab', ['arg/task'] = 'from the form', ['arg/note'] = ''}}, 'view-agent')
  expect(op.status).to_be('succeeded')
  expect(workers_in(tree.path)).to_be(before + 1)
  local found
  for _, w in ipairs(H.hub('hub.workers', {}).workers or {}) do
    if w.cwd == tree.path and w.profile == 'task' and w.parent == 'user' then found = w end
  end
  expect(found ~= nil, 'a user task worker').to_be(true)
end)

test('view: New Worktree creates the tree and opens one shell; the agent sequence does the same', function()
  user:command('new_worktree')
  local form = user:view('/forms/new-worktree')
  form:render()
  local op = form:action('new_worktree', 'submit', {values = {repo = repo, branch = 'open/form', base = ''}}, 'view-create')
  expect(op.status).to_be('succeeded')
  local path = W.root .. '/open/open/form'
  expect(workers_in(path)).to_be(1)
  -- The shell after New Worktree keeps the key of older versions: worktree-open/created/<key>.
  expect(W.intent('user', 'worktree-open/created/view-create').request.cwd).to_be(path)
  -- The agent sequence that reproduces the form: create, then open in a tab.
  local made = create(alice, 'open/agent-form', 'agent-form')
  expect(made.created).to_be(true)
  local opened = open(alice, {path = made.path, key = 'agent-form-open'})
  expect(worker(opened.spawn_id).cwd).to_be(made.path)
end)

test('tool: after an identity migration a replay finds the first spawn', function()
  local carol = agent('carol')
  local first = open(carol, {path = tree.path, key = 'mig'})
  expect(carol:report({kind = 'claude', conversation_id = 'conv-open'}).identity).to_be('claude:conv-open')
  local again = open(carol, {path = tree.path, key = 'mig'})
  expect(again.spawn_id).to_be(first.spawn_id)
  -- The spawn keeps its recorded parent (LazyRex 7e91929); the new identity owns it through the alias.
  expect(worker(first.spawn_id).parent).to_be('carol')
  -- A changed request with the legacy key still conflicts.
  expect_error(function() carol:call('worktree.open', {path = tree.path, key = 'mig', where = 'session'}) end, 'operation_conflict')
  -- Any agent may stop any worker (LazyRex 9bc00c8), also one whose parent is carol (above).
  expect(agent('alice'):hub('hub.stop', {spawn_id = first.spawn_id}).status).to_be('closed')
end)

test('tool: a key that both IDs used is refused after the migration', function()
  local dave = agent('dave')
  local bob2 = agent('bob', {title = 'bob-mig'})
  expect(bob2:report({kind = 'claude', conversation_id = 'conv-both'}).identity).to_be('claude:conv-both')
  local mine = open(bob2, {path = tree.path, key = 'both'})
  local legacy = open(dave, {path = tree.path, key = 'both'})
  expect(legacy.spawn_id).not_to_be(mine.spawn_id)
  expect(dave:report({kind = 'claude', conversation_id = 'conv-both'}).identity).to_be('claude:conv-both')
  local e = expect_error(function() dave:call('worktree.open', {path = tree.path, key = 'both'}) end)
  expect(e.message).to_match('used by')
  expect(workers_in(tree.path) >= 2).to_be(true)
  dave:hub('hub.stop', {spawn_id = mine.spawn_id})
  dave:hub('hub.stop', {spawn_id = legacy.spawn_id})
end)
