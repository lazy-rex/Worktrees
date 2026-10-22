-- Forget repository: the catalog stops recording a repository. Nothing on disk changes. Refusals:
-- an unfinished operation, a worker inside the repository or a tree that Git lists. When Git cannot
-- list the repository, the other workers are unattributed and need a confirmation.
local W = load_fixture(H.args.file:match('^(.*)/[^/]*$') .. '/support/fixture.lua')
local S = H.args.tests_session
local alice = agent('alice')
write_profiles({profiles = {{id = 'sleep', name = 'Sleep', kind = 'accessory', command = {'/bin/sleep', '600'}}}})

local function create(repo, branch, key)
  return W.settle(function() return alice:call('worktree.create', {repo = repo, branch = branch, key = key}) end)
end
local function forget(repo, key, accept)
  return alice:call('worktree.forget', {repo = repo, key = key, accept_unattributed = accept})
end
local function recorded(repo)
  for _, value in pairs(W.catalog().repos or {}) do if value == repo then return true end end
  return false
end
-- rows waits for a finished scan of the recorded repositories and returns its rows by path.
local function rows()
  return wait('a finished scan', function()
    local r = alice:call('worktree.list', {})
    if r.refreshing then return nil end
    local by_path = {}
    for _, t in ipairs(r.worktrees or {}) do by_path[t.path] = t end
    return by_path
  end, 30)
end
-- sleeper starts a worker with its directory in path and returns its spawn ID.
local function sleeper(path, key)
  local r = W.settle(function() return alice:call('worktree.open', {path = path, profile = 'sleep', key = key}) end)
  return r.spawn_id
end
local function stop(spawn_id)
  for _, w in ipairs(H.hub('hub.workers', {}).workers or {}) do
    if w.spawn_id == spawn_id then rex.call('block.close', {session_id = w.session_id, block_id = w.block_id}) end
  end
  wait('the worker is gone', function()
    for _, w in ipairs(H.hub('hub.workers', {}).workers or {}) do if w.spawn_id == spawn_id then return nil end end
    return true
  end, 20)
end
local function trees(repo) return W.git(repo, 'worktree', 'list', '--porcelain') end
-- open_forget opens the Forget form from the panel row of repo and its menu.
local function open_forget(repo)
  rows()
  user:command('worktrees')
  local panel = user:view('/panels/worktrees')
  wait('the row of ' .. repo, function()
    for _, it in ipairs(node(panel:render(), 'worktrees').items) do if it.id == repo then return true end end
  end, 20)
  expect(panel:action('worktrees', 'select', {item_id = repo}).status).to_be('succeeded')
  local menu = user:view(W.route('/forms/worktree', repo))
  local forget_item
  for _, it in ipairs(node(menu:render(), 'worktree_menu').items) do if it.id == 'forget' then forget_item = it end end
  expect(forget_item and forget_item.action.enabled, 'Forget repository… is enabled').to_be(true)
  expect(menu:action('worktree_menu', 'run', {item_id = 'forget'}).status).to_be('succeeded')
  return user:view(W.route('/forms/forget-repository', repo))
end

local healthy = W.repo('healthy')
local kept = create(healthy, 'kept', 'kept').path

test('a healthy repository: refused for a worker in its tree and for an unfinished operation; then forgotten, and nothing on disk changes', function()
  local worker = sleeper(kept, 'w-kept')
  local err = expect_error(function() forget(healthy, 'f-healthy') end, 'refused')
  expect(err.message).to_contain(worker)
  stop(worker)
  local main_worker = sleeper(healthy, 'w-main')
  expect_error(function() forget(healthy, 'f-healthy') end, 'refused')
  stop(main_worker)
  local state = W.catalog()
  local id = W.part('alice') .. W.part('stopped')
  state.pending[id] = {kind = 'create', fingerprint = 'synthetic', repo = healthy, common = W.real(healthy .. '/.git'),
    path = W.root .. '/healthy/stopped', branch = 'stopped', phase = 'prepared', actor = 'alice'}
  W.set_catalog(state)
  err = expect_error(function() forget(healthy, 'f-healthy') end, 'refused')
  expect(err.message).to_match('unfinished operation')
  state = W.catalog()
  state.pending[id] = nil
  W.set_catalog(state)

  local before = trees(healthy)
  local r = forget(healthy, 'f-healthy')
  expect(r.forgotten).to_be(true)
  expect(r.repo).to_be(healthy)
  expect(recorded(healthy)).to_be(false)
  expect(trees(healthy), 'git worktree list').to_be(before)
  expect(W.try({'test', '-d', kept}).ok).to_be(true)
  expect(W.git(healthy, 'branch', '--list', 'kept')).to_match('kept')
  local by_path = rows()
  expect(by_path[healthy], 'worktree.list omits the repository').to_be(nil)
  expect(by_path[kept]).to_be(nil)
  -- A same-key retry returns the saved result.
  expect(forget(healthy, 'f-healthy').forgotten).to_be(true)
  expect_error(function() forget(healthy, 'f-other') end, 'not_found')
end)

test('the source panel shows a forgotten repository, marked not recorded; other panels and worktree.list do not', function()
  -- A shell pane in the forgotten repository and one in another recorded repository.
  local other = W.repo('other')
  create(other, 'o', 'o')
  local function pane(cwd)
    local before = {}
    rex.call('session.attach', {session_id = S, event_scope = 'session'})
    for _, w in ipairs(rex.call('session.view', {session_id = S}).windows or {}) do before[w.window_id] = true end
    rex.call('session.new_window', {session_id = S, layout = {block = {flavor = 'com.superlogical.terminal.shell',
      options = {command = {'/bin/sleep', '600'}, cwd = cwd, login = false, exit = {on_completion = false}}}}})
    for _, w in ipairs(rex.call('session.view', {session_id = S}).windows or {}) do
      if not before[w.window_id] then for _, l in ipairs(w.layers or {}) do for _, b in ipairs(l.blocks or {}) do return b.block_id end end end
    end
  end
  local function panel_ids(block)
    user:command('worktrees', {session = S, block = block})
    local panel = user:view('/panels/worktrees', nil, S)
    return wait('the panel rows', function()
      local tree = panel:render()
      local ids = {}
      for _, it in ipairs(node(tree, 'worktrees').items) do ids[it.id] = true end
      return ids[W.real(other)] and {ids = ids, text = node(tree, 'new').text}
    end, 20)
  end
  local inside = panel_ids(pane(kept))
  expect(inside.ids[healthy] and inside.ids[kept], 'the source rows').to_be(true)
  expect(inside.text).to_be('Repository: ' .. kept .. ' (not recorded)')
  local outside = panel_ids(pane(W.real(other)))
  expect(outside.ids[healthy], 'no row in the panel of another repository').to_be(nil)
  expect(outside.ids[kept]).to_be(nil)
  expect(outside.text).to_be('Repository: ' .. W.real(other))
  expect(rows()[kept], 'worktree.list').to_be(nil)
end)

test('a later create records the repository again; the same-key Forget returns the saved result and changes nothing', function()
  create(healthy, 'again', 'again')
  expect(recorded(healthy)).to_be(true)
  local rev = W.records()
  expect(forget(healthy, 'f-healthy').forgotten).to_be(true)
  expect(recorded(healthy), 'the replay does not forget it again').to_be(true)
  expect(W.records()).to_be(rev)
end)

-- Two repositories with a linked tree each, then moved away: Git cannot list them.
local gone_a, gone_b = W.repo('gone-a'), W.repo('gone-b')
local lost_a = create(gone_a, 'lost', 'lost-a').path
local lost_b = create(gone_b, 'lost', 'lost-b').path
rows()
local lost_worker = sleeper(lost_a, 'w-lost')
W.run({'mv', gone_a, gone_a .. '.away'})
W.run({'mv', gone_b, gone_b .. '.away'})

test('an agent: an unavailable repository with unattributed workers needs a confirmation before any catalog write', function()
  local rev = W.records()
  local err = expect_error(function() forget(gone_a, 'f-gone-a') end, 'needs_confirmation')
  expect(err.message).to_contain(lost_worker)
  expect(err.message).to_contain(lost_a)
  expect(W.records(), 'no catalog write').to_be(rev)
  expect(recorded(gone_a)).to_be(true)
  -- The same key with the acceptance: needs_confirmation was not saved.
  local r = forget(gone_a, 'f-gone-a', true)
  expect(r.forgotten).to_be(true)
  expect(r.unattributed_count).to_be(1)
  expect(r.unattributed_workers[1]).to_contain(lost_worker)
  expect(recorded(gone_a)).to_be(false)
  -- The saved success replays with or without the flag.
  expect(forget(gone_a, 'f-gone-a').forgotten).to_be(true)
end)

test('the form: a changed worker set shows the form again; an unchanged set forgets the repository', function()
  local route = W.route('/forms/forget-repository', gone_b)
  local form = open_forget(gone_b)
  local function shown(tree)
    for _, f in ipairs(node(tree, 'forget_repository').fields) do if f.id == 'workers' then return f.value end end
  end
  local tree = form:render()
  expect(node(tree, 'about').text).to_contain(gone_b)
  expect(node(tree, 'unattributed').text).to_contain(lost_worker)
  local first = shown(tree)
  -- A new worker outside every recorded repository changes the set.
  local stray = W.repo('stray')
  local stray_worker = sleeper(stray, 'w-stray')
  local op = form:action('forget_repository', 'submit', {values = {repo = gone_b, workers = first}}, 'u-forget-1')
  expect(op.status).to_be('succeeded')
  expect(op.result.form).to_be(route)
  expect(recorded(gone_b), 'a changed set changes nothing').to_be(true)
  form = user:view(route)
  tree = form:render()
  expect(node(tree, 'unattributed').text).to_contain(stray_worker)
  local second = shown(tree)
  expect(second ~= first).to_be(true)
  op = form:action('forget_repository', 'submit', {values = {repo = gone_b, workers = second}}, 'u-forget-2')
  expect(op.status).to_be('succeeded')
  expect(op.result.close_form).to_be(true)
  expect(recorded(gone_b)).to_be(false)
  expect(rows()[gone_b], 'worktree.list').to_be(nil)
  -- The directories stay where they are.
  expect(W.try({'test', '-d', lost_b}).ok).to_be(true)
  expect(W.try({'test', '-d', gone_b .. '.away'}).ok).to_be(true)
  stop(stray_worker)
end)

test('a worker inside the recorded main path refuses also for an unavailable repository; the form shows the refusal', function()
  local moved = W.repo('moved')
  create(moved, 'm', 'm')
  local worker = sleeper(moved, 'w-moved')
  -- The worker keeps its directory; the main tree goes away under it.
  W.run({'mv', moved .. '/.git', moved .. '/.git.away'})
  local err = expect_error(function() forget(moved, 'f-moved', true) end, 'refused')
  expect(err.message).to_contain(worker)
  local form = open_forget(moved)
  expect(node(form:render(), 'check').text).to_match('Forget will be refused')
  expect(node(form:render(), 'check').text).to_contain(worker)
  expect(recorded(moved)).to_be(true)
  stop(worker)
  stop(lost_worker)
end)
