-- worktree.discard and the panel's Discard stopped operation use one handler. An agent discards
-- only its own operations, by key; the user discards any, from the panel. The request key makes a
-- replay return the first result; another target with the same request key conflicts.
local W = load_fixture(H.args.file:match('^(.*)/[^/]*$') .. '/support/fixture.lua')
local repo = W.repo('discard')
local common = W.real(repo .. '/.git')
local alice, bob = agent('alice'), agent('bob')

-- stopped writes a pending create that never started Git (phase prepared), as a crash leaves it.
local function stopped(actor, key, extra)
  local state = W.catalog() or {repos = {}, pending = {}}
  -- The fingerprint is a real create's, so the create key replays the discard result.
  local op = {kind = 'create', fingerprint = 'create/' .. W.part(repo) .. W.part(key) .. W.part(''), repo = repo, common = common,
    path = W.root .. '/discard/' .. key, branch = key, phase = 'prepared', actor = actor}
  for k, v in pairs(extra or {}) do op[k] = v end
  state.pending[W.part(actor) .. W.part(key)] = op
  W.set_catalog(state)
  return W.part(actor) .. W.part(key)
end
local function pending(id) return ((W.catalog() or {}).pending or {})[id] end

local function panel_discard(id, key)
  user:command('worktrees')
  local panel = user:view('/panels/worktrees')
  local tree = panel:render()
  expect(node(tree, 'pending/' .. id) ~= nil, 'the panel lists the pending operation').to_be(true)
  return panel:action('pending/' .. id, 'discard', {}, key)
end

test('tool: an agent discards its own operation; a replay returns the first result', function()
  local id = stopped('alice', 'stuck-1')
  local r = alice:call('worktree.discard', {operation = 'stuck-1', key = 'd1'})
  expect(r.discarded).to_be(true)
  expect(pending(id)).to_be(nil)
  expect(alice:call('worktree.discard', {operation = 'stuck-1', key = 'd1'})).to_equal(r)
  -- A new request key for the same target returns the target's saved result.
  expect(alice:call('worktree.discard', {operation = 'stuck-1', key = 'd1-again'}).discarded).to_be(true)
  -- The discarded create key returns its saved result.
  expect(alice:call('worktree.create', {repo = repo, branch = 'stuck-1', key = 'stuck-1'}).status).to_be('discarded')
end)

test('tool: the same request key with another target conflicts', function()
  stopped('alice', 'stuck-2')
  stopped('alice', 'stuck-3')
  alice:call('worktree.discard', {operation = 'stuck-2', key = 'd2'})
  expect_error(function() alice:call('worktree.discard', {operation = 'stuck-3', key = 'd2'}) end, 'operation_conflict')
  expect(pending(W.part('alice') .. W.part('stuck-3')) ~= nil).to_be(true)
end)

test("tool: an agent cannot discard another agent's operation", function()
  local id = stopped('alice', 'stuck-4')
  expect_error(function() bob:call('worktree.discard', {operation = 'stuck-4', key = 'b1'}) end, 'not_found')
  expect(pending(id) ~= nil).to_be(true)
end)

test("view: the user discards any agent's operation from the panel", function()
  local id = stopped('bob', 'stuck-5')
  local op = panel_discard(id, 'panel-d1')
  expect(op.status).to_be('succeeded')
  expect(op.result.discarded).to_be(true)
  expect(pending(id)).to_be(nil)
  expect(bob:call('worktree.discard', {operation = 'stuck-5', key = 'b2'}).discarded).to_be(true)
end)

test('an unknown Git start is refused while its session lives; allowed after the session is gone', function()
  local live = session('discard-live')
  local id = stopped('alice', 'unknown', {phase = 'sending', session = live, label = 'never-sent'})
  expect_error(function() alice:call('worktree.discard', {operation = 'unknown', key = 'u1'}) end, 'late Rex reply')
  local op = panel_discard(id, 'panel-u1')
  expect(op.status).to_be('failed')
  expect(pending(id) ~= nil).to_be(true)
  close_session(live)
  -- A refusal saves nothing, so the same request key works now.
  expect(alice:call('worktree.discard', {operation = 'unknown', key = 'u1'}).discarded).to_be(true)
end)

test('a running Git process is refused', function()
  -- A post-checkout hook holds Git until the gate file exists.
  local gate = H.args.lab .. '/discard-gate'
  W.write(repo .. '/.git/hooks/post-checkout', "#!/bin/sh\nwhile [ ! -f '" .. gate .. "' ]; do sleep 0.1; done\n")
  W.run({'chmod', '755', repo .. '/.git/hooks/post-checkout'})
  local r = alice:call('worktree.create', {repo = repo, branch = 'slow', key = 'slow'})
  expect(r.status).to_be('running')
  wait('Git starts', function()
    local op = pending(W.part('alice') .. W.part('slow'))
    return op and op.block ~= nil
  end)
  expect_error(function() alice:call('worktree.discard', {operation = 'slow', key = 's1'}) end, 'running or starting')
  W.write(gate, 'go')
  local done = W.settle(function() return alice:call('worktree.create', {repo = repo, branch = 'slow', key = 'slow'}) end)
  expect(done.created).to_be(true)
  W.run({'rm', repo .. '/.git/hooks/post-checkout'})
end)

test('an interrupted discard keeps its target: another target conflicts, a retry completes it', function()
  local first = stopped('alice', 'cut-1')
  local second = stopped('alice', 'cut-2')
  -- The target's discard result fails to commit after the request key reserved the target.
  with_injection({match = {sql_commit_writes = 'ops'}, fail = 'lost discard result'}, 1, function()
    expect_error(function() alice:call('worktree.discard', {operation = 'cut-1', key = 'cut-request'}) end, 'lost discard result')
  end)
  expect(pending(first) ~= nil).to_be(true)
  expect_error(function() alice:call('worktree.discard', {operation = 'cut-2', key = 'cut-request'}) end, 'operation_conflict')
  expect(pending(second) ~= nil).to_be(true)
  expect(alice:call('worktree.discard', {operation = 'cut-1', key = 'cut-request'}).discarded).to_be(true)
  expect(pending(first)).to_be(nil)
  expect(pending(second) ~= nil).to_be(true)
end)

test('a retry after an identity change discards the reserved target', function()
  local carol = agent('carol')
  local id = stopped('carol', 'moved')
  with_injection({match = {sql_commit_writes = 'ops'}, fail = 'lost discard result'}, 1, function()
    expect_error(function() carol:call('worktree.discard', {operation = 'moved', key = 'moved-request'}) end, 'lost discard result')
  end)
  expect(carol:report({kind = 'claude', conversation_id = 'conv-discard'}).identity).to_be('claude:conv-discard')
  local r = carol:call('worktree.discard', {operation = 'moved', key = 'moved-request'})
  expect(r.discarded).to_be(true)
  expect(pending(id)).to_be(nil)
end)

-- awaiting_cleanup writes a create whose result committed, with its cleanup still pending.
-- discarded = true: the saved result is a discard (the discard's result committed, its cleanup did not).
local function awaiting_cleanup(key, discarded)
  local id = W.part('alice') .. W.part(key)
  local path = W.root .. '/discard/' .. key
  local fingerprint = 'create/' .. W.part(repo) .. W.part(key) .. W.part('')
  local state = W.catalog() or {repos = {}, pending = {}}
  state.pending[id] = {kind = 'create', phase = 'cleanup', path = path, repo = repo, common = common,
    actor = 'alice', fingerprint = fingerprint}
  W.set_catalog(state)
  local result = discarded and {status = 'discarded', discarded = true, path = path} or {path = path, repo = repo, branch = key, created = true}
  W.put_op(id, fingerprint, result)
  return id, result
end

test('a discard that finishes a cleanup replays its complete result', function()
  local id = awaiting_cleanup('cleaned')
  local first = alice:call('worktree.discard', {operation = 'cleaned', key = 'cleanup'})
  expect(first.status).to_be('complete')
  expect(pending(id)).to_be(nil)
  expect(alice:call('worktree.discard', {operation = 'cleaned', key = 'cleanup'})).to_equal(first)
  -- The result comes from the target: another request for the same target gets the same answer.
  expect(alice:call('worktree.discard', {operation = 'cleaned', key = 'cleanup-other'})).to_equal(first)
end)

test('an interrupted cleanup discard completes on retry and replays', function()
  local id = awaiting_cleanup('cut-cleanup')
  -- The reservation writes no pending row, so the first write of pending is the cleanup.
  with_injection({match = {sql_commit_writes = 'pending'}, fail = 'lost cleanup'}, 1, function()
    expect_error(function() alice:call('worktree.discard', {operation = 'cut-cleanup', key = 'cut-cleanup-request'}) end, 'lost cleanup')
  end)
  expect(pending(id).phase).to_be('cleanup')
  local done = alice:call('worktree.discard', {operation = 'cut-cleanup', key = 'cut-cleanup-request'})
  expect(done.status).to_be('complete')
  expect(pending(id)).to_be(nil)
  expect(alice:call('worktree.discard', {operation = 'cut-cleanup', key = 'cut-cleanup-request'})).to_equal(done)
end)

test('another caller can finish the cleanup first: a create replay, then the discard retry', function()
  local id = awaiting_cleanup('other-cleanup')
  with_injection({match = {sql_commit_writes = 'pending'}, fail = 'lost cleanup'}, 1, function()
    expect_error(function() alice:call('worktree.discard', {operation = 'other-cleanup', key = 'other-request'}) end, 'lost cleanup')
  end)
  -- The create replay returns its saved result and finishes the cleanup (startup does the same).
  expect(alice:call('worktree.create', {repo = repo, branch = 'other-cleanup', key = 'other-cleanup'}).created).to_be(true)
  expect(pending(id)).to_be(nil)
  expect(alice:call('worktree.discard', {operation = 'other-cleanup', key = 'other-request'}).status).to_be('complete')
end)

test('a discard whose result committed but whose cleanup did not finishes the cleanup on replay', function()
  local id, result = awaiting_cleanup('discarded-cleanup', true)
  W.set_reservation('discard/' .. W.part('alice') .. W.part('done-request'),
    {fingerprint = 'discard-v1/' .. W.part('key') .. W.part('discarded-cleanup'), id = id})
  expect(alice:call('worktree.discard', {operation = 'discarded-cleanup', key = 'done-request'})).to_equal(result)
  expect(pending(id)).to_be(nil)
  expect(alice:call('worktree.create', {repo = repo, branch = 'discarded-cleanup', key = 'discarded-cleanup'}).status).to_be('discarded')
end)


-- Discard by id (the user's decision: an agent may discard any pending operation, as the user
-- can). The request key stays the caller's own.
local function id_of(actor, key) return W.part(actor) .. W.part(key) end
local function record(actor, key) return W.reservation('discard/' .. W.part(actor) .. W.part(key)) end

test("tool: an agent discards another agent's operation by id; a replay returns the first result", function()
  local id = stopped('alice', 'by-id-1')
  local r = bob:call('worktree.discard', {id = id, key = 'bob-by-id-1'})
  expect(r.discarded).to_be(true)
  expect(pending(id)).to_be(nil)
  expect(bob:call('worktree.discard', {id = id, key = 'bob-by-id-1'})).to_equal(r)
  -- The request record is bob's: alice's request keys are separate.
  expect(record('bob', 'bob-by-id-1').id).to_be(id)
  expect(record('alice', 'bob-by-id-1')).to_be(nil)
end)

test('an id that looks like a local key names an operation ID; operation still names a key of the caller', function()
  local alice_id = stopped('alice', 'look-1')
  -- bob has an operation whose key is the text of alice's operation ID.
  local bob_id = stopped('bob', alice_id)
  expect(bob:call('worktree.discard', {id = alice_id, key = 'look-by-id'}).discarded).to_be(true)
  expect(pending(alice_id)).to_be(nil)
  expect(pending(bob_id) ~= nil).to_be(true)
  expect(bob:call('worktree.discard', {operation = alice_id, key = 'look-by-key'}).discarded).to_be(true)
  expect(pending(bob_id)).to_be(nil)
end)

test('exactly one selector; the same request key with the other selector conflicts', function()
  local id = stopped('alice', 'sel-1')
  expect_error(function() alice:call('worktree.discard', {key = 'sel-none'}) end, 'exactly one')
  expect_error(function() alice:call('worktree.discard', {id = id, operation = 'sel-1', key = 'sel-both'}) end, 'exactly one')
  -- A refused selector writes nothing.
  expect(record('alice', 'sel-none')).to_be(nil)
  expect(record('alice', 'sel-both')).to_be(nil)
  expect(pending(id) ~= nil).to_be(true)
  -- The same target, first by key, then by id with the same request key: the content differs.
  expect(alice:call('worktree.discard', {operation = 'sel-1', key = 'sel-req'}).discarded).to_be(true)
  expect_error(function() alice:call('worktree.discard', {id = id, key = 'sel-req'}) end, 'operation_conflict')
end)

test("the guards refuse another agent's running or unknown operation", function()
  local live = session('discard-cross-live')
  local id = stopped('alice', 'cross-unknown', {phase = 'sending', session = live, label = 'never-sent'})
  expect_error(function() bob:call('worktree.discard', {id = id, key = 'cross-u1'}) end, 'late Rex reply')
  expect(pending(id) ~= nil).to_be(true)
  close_session(live)
  expect(bob:call('worktree.discard', {id = id, key = 'cross-u1'}).discarded).to_be(true)
  local gate = H.args.lab .. '/cross-gate'
  W.write(repo .. '/.git/hooks/post-checkout', "#!/bin/sh\nwhile [ ! -f '" .. gate .. "' ]; do sleep 0.1; done\n")
  W.run({'chmod', '755', repo .. '/.git/hooks/post-checkout'})
  expect(alice:call('worktree.create', {repo = repo, branch = 'cross-slow', key = 'cross-slow'}).status).to_be('running')
  local slow = id_of('alice', 'cross-slow')
  wait('Git starts', function() local op = pending(slow); return op and op.block ~= nil end)
  expect_error(function() bob:call('worktree.discard', {id = slow, key = 'cross-s1'}) end, 'running or starting')
  W.write(gate, 'go')
  expect(W.settle(function() return alice:call('worktree.create', {repo = repo, branch = 'cross-slow', key = 'cross-slow'}) end).created).to_be(true)
  W.run({'rm', repo .. '/.git/hooks/post-checkout'})
end)

test('an interrupted discard by id keeps its target: another id conflicts, a retry completes it', function()
  local first = stopped('alice', 'id-cut-1')
  local second = stopped('alice', 'id-cut-2')
  with_injection({match = {sql_commit_writes = 'ops'}, fail = 'lost discard result'}, 1, function()
    expect_error(function() bob:call('worktree.discard', {id = first, key = 'id-cut'}) end, 'lost discard result')
  end)
  expect(pending(first) ~= nil).to_be(true)
  expect_error(function() bob:call('worktree.discard', {id = second, key = 'id-cut'}) end, 'operation_conflict')
  expect(bob:call('worktree.discard', {id = first, key = 'id-cut'}).discarded).to_be(true)
  expect(pending(first)).to_be(nil)
  expect(pending(second) ~= nil).to_be(true)
end)

-- worktree.list operations: every pending operation, paged by id, read-only.
local function all_pages(who, args)
  local seen, order, pages, after = {}, {}, 0, nil
  repeat
    local a = {operations_after = after}
    for k, v in pairs(args or {}) do a[k] = v end
    local r = who:call('worktree.list', a)
    pages = pages + 1
    local ops = r.operations or {}
    expect(#ops > 0 or r.operations_next == nil, 'no empty page before the end').to_be(true)
    expect(#ops <= 50).to_be(true)
    expect(#rex.json.encode(ops) <= 32768, 'the page is within 32 KiB').to_be(true)
    for _, e in ipairs(ops) do
      expect(seen[e.id], 'no duplicate ' .. e.id).to_be(nil)
      if order[#order] then expect(e.id > order[#order], 'sorted by id').to_be(true) end
      seen[e.id] = e
      order[#order + 1] = e.id
    end
    after = r.operations_next
  until after == nil
  return seen, order, pages
end
local function clear_pending()
  -- A file filter can run this before any test has made the catalog.
  local state = W.catalog() or {repos = {}}
  state.pending = {}
  W.set_catalog(state)
end

test('list: operations shows every pending entry; a legacy entry has no actor; repo does not filter it', function()
  clear_pending()
  local mine = stopped('alice', 'list-1')
  local state = W.catalog()
  state.pending['legacy-id'] = {kind = 'create', phase = 'prepared', path = W.root .. '/discard/legacy', branch = 'legacy', repo = repo, common = common}
  W.set_catalog(state)
  local seen = all_pages(alice, {repo = repo})
  expect(seen[mine].actor).to_be('alice')
  expect(seen[mine].kind).to_be('create')
  expect(seen['legacy-id'].actor).to_be(nil)
  -- No admission time is invented for a record from an older version.
  expect(seen['legacy-id'].created_at).to_be(nil)
  expect(seen['legacy-id'].kind).to_be('create')
  -- repo filters only worktrees: another repository lists the same operations.
  local other = W.repo('discard-other')
  local again = all_pages(alice, {repo = other})
  expect(again[mine] ~= nil and again['legacy-id'] ~= nil).to_be(true)
  clear_pending()
end)

test('list: pages without changes; no duplicate or skipped id; a deleted cursor id is a position', function()
  clear_pending()
  local state = W.catalog()
  local want = {}
  for i = 1, 120 do
    local key = string.format('page-%03d', i)
    state.pending[id_of('alice', key)] = {kind = 'create', phase = 'prepared', path = W.root .. '/discard/' .. key, branch = key, repo = repo, common = common, actor = 'alice', fingerprint = 'synthetic/' .. key}
    want[id_of('alice', key)] = true
  end
  W.set_catalog(state)
  local rev = W.records()
  local seen, order, pages = all_pages(alice)
  expect(pages).to_be(3)
  for id in pairs(want) do expect(seen[id] ~= nil, 'listed ' .. id).to_be(true) end
  expect(#order).to_be(120)
  expect(W.records(), 'paging changes nothing').to_be(rev)
  -- A cursor whose entry was discarded still works as a position.
  local cursor = order[50]
  expect(alice:call('worktree.discard', {id = cursor, key = 'page-del'}).discarded).to_be(true)
  local r = alice:call('worktree.list', {operations_after = cursor})
  expect(r.operations[1].id).to_be(order[51])
  clear_pending()
end)

-- One control message carries at most 64 KiB, so each test writes a catalog below that.
test('list: the byte cap holds with long escaped text', function()
  clear_pending()
  local state = W.catalog()
  -- Quotes, backslashes and tabs grow when JSON escapes them: about 2.5 KB an entry here.
  local long = string.rep('"\\\t', 400)
  for i = 1, 15 do
    local key = string.format('long-%02d', i)
    state.pending[id_of('alice', key)] = {kind = 'remove', phase = 'prepared', path = W.root .. '/' .. long .. i, branch = 'long', repo = repo, common = common, actor = 'alice'}
  end
  W.set_catalog(state)
  local seen, order, pages = all_pages(alice)
  expect(#order).to_be(15)
  expect(pages).to_be(2)
  expect(seen[id_of('alice', 'long-01')].path).to_be(W.root .. '/' .. long .. '1')
  clear_pending()
end)

test('list: an entry too large for a page is compact, with its exact id; the next entry follows', function()
  clear_pending()
  local state = W.catalog()
  local huge = id_of('alice', 'huge')
  state.pending[huge] = {kind = 'remove', phase = 'prepared', path = W.root .. '/' .. string.rep('"', 8000) .. string.rep('a', 9000), branch = 'huge', repo = repo, common = common, actor = 'alice'}
  local small = id_of('alice', 'small')
  state.pending[small] = {kind = 'remove', phase = 'prepared', path = W.root .. '/small', branch = 'small', repo = repo, common = common, actor = 'alice'}
  W.set_catalog(state)
  local seen, order = all_pages(alice)
  expect(order).to_equal({huge, small})
  expect(seen[huge].compact).to_be(true)
  expect(seen[huge].path).to_be(nil)
  expect(seen[huge].kind).to_be('remove')
  expect(seen[small].path).to_be(W.root .. '/small')
  clear_pending()
end)

test('list: no pending operation leaves out operations and operations_next', function()
  clear_pending()
  local r = alice:call('worktree.list', {})
  expect(r.operations).to_be(nil)
  expect(r.operations_next).to_be(nil)
  -- The page after the last id is empty in the same way.
  local last = stopped('alice', 'only-one')
  local first = alice:call('worktree.list', {})
  expect(#first.operations).to_be(1)
  expect(first.operations_next).to_be(nil)
  local after = alice:call('worktree.list', {operations_after = last})
  expect(after.operations).to_be(nil)
  expect(after.operations_next).to_be(nil)
  clear_pending()
end)
