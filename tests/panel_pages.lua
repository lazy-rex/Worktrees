-- Panel pages (sandbox, tests/support/sandbox.lua): each rendered view encodes to at most 48 KiB,
-- the status included. The panel shows the entries that fit, and More… opens
-- /forms/worktrees-more?start=<n> with the next ones, until every entry was shown once. Long and
-- escaped text is cut; a verbose row keeps its action; only an exact ID that does not fit gives a
-- placeholder without an action.
local tests_dir = H.args.file:match('^(.*)/[^/]*$')
local load_sandbox = load_fixture(tests_dir .. '/support/sandbox.lua')
local base = getfenv(1)
local view_bytes = 49152

-- noisy repeats characters that JSON escapes (a quote, a backslash, a control byte) and a
-- 2-byte character, to n bytes.
local function noisy(n) return (string.rep('"\\\1é', math.ceil(n / 5))):sub(1, n) end
-- sandbox: the recorded repository /r with n linked trees whose branch names are long and escaped,
-- a long worker title in each tree, and the pending operations ops ({id = op}).
local function sandbox(n, ops)
  local s = load_sandbox(tests_dir .. '/..', base)
  assert_true(s.loaded, 'the plugin loads: ' .. tostring(s.load_error))
  local function ok(stdout) return {ok = true, stdout = stdout, stderr = ''} end
  s.exec_hook = function(argv)
    if argv[1] == 'git' and argv[2] == '--git-dir' and argv[4] == 'worktree' and argv[5] == 'list' then
      local fields = {'worktree /r', 'bare', ''}
      for i = 1, n do
        local branch = string.format('b%03d-', i) .. noisy(1000)
        for _, f in ipairs({string.format('worktree /sandbox/worktrees/r/t%03d', i), 'HEAD 0', 'branch refs/heads/' .. branch, ''}) do fields[#fields + 1] = f end
      end
      return ok(table.concat(fields, '\0') .. '\0')
    end
  end
  -- No scan runs: every git status stays queued, so each row is 'checking'.
  s.start_hook = function() return nil, 'no fork' end
  for i = 1, n do
    s.workers[#s.workers + 1] = {spawn_id = 'spawn-' .. i, cwd = string.format('/sandbox/worktrees/r/t%03d', i), state = 'running', title = noisy(3000)}
  end
  s:set_catalog({repos = {['/r/.git'] = '/r'}, pending = ops or {}})
  s:tick()
  return s
end
local function render(s, route)
  local reply = s:perform('view.render', {route = route})
  return reply.result, reply.error, reply.result and #rex.json.encode(reply.result) or 0
end
-- walk follows More… from the panel and returns the entry IDs in order and the page count.
local function walk(s)
  local ids, pages, route = {}, 0, '/panels/worktrees'
  while route do
    local result, err, bytes = render(s, route)
    assert_true(result ~= nil, route .. ': ' .. show(err))
    pages = pages + 1
    assert_true(pages <= 100, 'the pages end')
    expect(bytes <= view_bytes, route .. ' encodes to at most 48 KiB, got ' .. bytes).to_be(true)
    route = nil
    local shown = 0
    for _, node in ipairs(result.tree.nodes) do
      if node.id == 'worktrees' then
        for _, it in ipairs(node.items) do ids[#ids + 1] = it; shown = shown + 1 end
      elseif node.id:sub(1, 8) == 'pending/' or node.id:sub(1, 18) == 'pending-oversized/' then
        ids[#ids + 1] = node; shown = shown + 1
      elseif node.id:sub(1, 5) == 'more/' then
        route = '/forms/worktrees-more?start=' .. node.id:sub(6)
      end
    end
    expect(shown >= 1, route and ('a page advances: ' .. route) or 'the last page has an entry').to_be(true)
  end
  return ids, pages
end
local function pending_ops(n, long_path)
  local ops = {}
  for i = 1, n do
    ops[string.format('5:alice5:k-%02d', i)] = {kind = 'remove', phase = 'prepared', path = '/sandbox/worktrees/r/' .. (long_path and noisy(900) or 'p') .. i}
  end
  return ops
end

test('400 verbose rows and 30 long pending operations: every page is within 48 KiB, and each entry shows once', function()
  local s = sandbox(400, pending_ops(30, true))
  local entries, pages = walk(s)
  expect(#entries, 'the main row, 400 linked rows and 30 operations').to_be(431)
  expect(pages > 1, 'more than one page').to_be(true)
  local seen = {}
  for _, e in ipairs(entries) do
    expect(seen[e.id], 'shown once: ' .. e.id).to_be(nil)
    seen[e.id] = true
    -- A verbose row and a long operation keep their actions after compaction.
    expect(e.action and e.action.enabled, 'an action: ' .. e.id).to_be(true)
  end
  for i = 1, 400 do expect(seen[string.format('/sandbox/worktrees/r/t%03d', i)], 'row ' .. i).to_be(true) end
end)

test('an operation ID that does not fit gives a placeholder without an action; the next page still advances', function()
  local ops = pending_ops(3, false)
  ops['5:alice' .. #noisy(20000) .. ':' .. noisy(20000)] = {kind = 'create', phase = 'prepared', path = '/sandbox/worktrees/r/big'}
  local s = sandbox(200, ops)
  local entries = walk(s)
  expect(#entries, 'the main row, 200 linked rows and 4 operations').to_be(205)
  local placeholders = 0
  for _, e in ipairs(entries) do
    if e.id:sub(1, 18) == 'pending-oversized/' then
      placeholders = placeholders + 1
      expect(e.action, 'no action').to_be(nil)
      expect(e.text).to_contain('worktree.discard')
    end
  end
  expect(placeholders).to_be(1)
end)

test('a More page with a malformed or out-of-range start', function()
  local s = sandbox(3)
  for _, start in ipairs({'0', '-1', 'x', '1234567', ''}) do
    local _, err = render(s, '/forms/worktrees-more?start=' .. start)
    expect(err and err.code, 'start=' .. start).to_be('invalid_input')
  end
  local _, err = render(s, '/forms/worktrees-more')
  expect(err and err.code, 'no start').to_be('invalid_input')
  local result = render(s, '/forms/worktrees-more?start=99')
  expect(result.tree.nodes[1].id).to_be('end')
  expect(result.tree.nodes[1].text).to_contain('No more entries')
end)

test('the final check covers every route, with the form status: a view over 48 KiB fails with too_large', function()
  -- The Remove Worktree picker lists every removable tree; 400 verbose rows do not fit.
  local s = sandbox(400)
  local result, err = render(s, '/forms/remove-worktree')
  expect(result, 'no reply that is too large').to_be(nil)
  expect(err and err.code).to_be('too_large')
end)

-- boundary finds the length L whose entry fits 8 KiB only without the optional text: make(L) gives
-- the minimal entry and the entry with the shortest kept text.
local function boundary(make)
  for len = 8300, 6000, -1 do
    local minimal, short = make(len)
    if #rex.json.encode(minimal) <= 8192 and #rex.json.encode(short) > 8192 then return len end
  end
  error('no boundary length', 0)
end

test('boundary: an operation whose exact ID and action fit only with empty text keeps Discard', function()
  local discard = {name = 'discard', label = 'Discard stopped operation', enabled = true, tool = 'worktree.discard'}
  local function id_of(len) return '5:alice' .. len .. ':' .. string.rep('k', len) end
  local len = boundary(function(n)
    return {id = 'pending/' .. id_of(n), type = 'widget', text = '', action = discard},
      {id = 'pending/' .. id_of(n), type = 'widget', text = 'create (prepared)', action = discard}
  end)
  local s = sandbox(0, {[id_of(len)] = {kind = 'create', phase = 'prepared', path = '/sandbox/worktrees/r/edge'}})
  local found
  for _, e in ipairs(walk(s)) do if e.id == 'pending/' .. id_of(len) then found = e end end
  expect(found ~= nil, 'the exact pending ID').to_be(true)
  expect(found.action and found.action.enabled, 'Discard kept').to_be(true)
  expect(found.text).to_be('')
end)

test('boundary: a tree row whose exact path and action fit only with an empty label keeps its action', function()
  local select = {name = 'select', label = 'Actions…', enabled = true, user_only = 'navigation'}
  local branch = string.rep('b', 100)
  local function path_of(len) return '/sandbox/worktrees/r/' .. string.rep('a', len) end
  local len = boundary(function(n)
    return {id = path_of(n), label = '', detail = '', action = select},
      {id = path_of(n), label = string.rep('b', 61) .. '…', detail = '', action = select}
  end)
  local s = sandbox(0)
  s.exec_hook = function(argv)
    if argv[1] == 'git' and argv[2] == '--git-dir' and argv[4] == 'worktree' and argv[5] == 'list' then
      local fields = {'worktree /r', 'bare', '', 'worktree ' .. path_of(len), 'HEAD 0', 'branch refs/heads/' .. branch, ''}
      return {ok = true, stdout = table.concat(fields, '\0') .. '\0', stderr = ''}
    end
  end
  s:perform('view.action', {route = '/panels/worktrees', node_id = 'refresh', action = 'refresh', input = {}})
  local found
  for _, e in ipairs(walk(s)) do if e.id == path_of(len) then found = e end end
  expect(found ~= nil, 'the exact path').to_be(true)
  expect(found.action and found.action.enabled, 'select kept').to_be(true)
  expect(found.label).to_be('')
end)

-- The lab: a real panel of 300 trees arrives; More… walks the pages; on a More page, select opens
-- the tree menu and Discard ends a stopped operation.
local W = load_fixture(tests_dir .. '/support/fixture.lua')
local alice = agent('alice')

test('lab: a panel of 300 trees arrives; More… pages, select and Discard work on a More page', function()
  local repo = W.repo('pages')
  W.settle(function() return alice:call('worktree.create', {repo = repo, branch = 'first', key = 'pages-first'}) end)
  local long = string.rep('x', 200)
  for i = 1, 300 do W.git(repo, 'worktree', 'add', '-q', '-b', string.format('p%03d-%s', i, long), string.format('%s/pages-lab/t%03d', W.root, i)) end
  local state = W.catalog()
  local id = W.part('alice') .. W.part('pages-stopped')
  state.pending[id] = {kind = 'create', fingerprint = 'synthetic', repo = repo, common = W.real(repo .. '/.git'),
    path = W.root .. '/pages-lab/stopped', branch = 'stopped', phase = 'prepared', actor = 'alice'}
  W.set_catalog(state)
  user:command('worktrees')
  local panel = user:view('/panels/worktrees')
  expect(panel:action('refresh', 'refresh', {}).status).to_be('succeeded')
  -- The view arrives with the rows of the 300 trees, over several pages.
  local function more_of(tree)
    for _, n in ipairs(tree.nodes) do if n.id:sub(1, 5) == 'more/' then return n.id end end
  end
  local tree = wait('the panel with its first rows', function()
    local t = panel:render()
    local list = node(t, 'worktrees')
    return list and #list.items > 10 and more_of(t) and t
  end, 60)
  local view, pages, discarded = panel, 1, false
  local more = more_of(tree)
  while more do
    local op = view:action(more, 'more', {})
    expect(op.status, 'More… ' .. more).to_be('succeeded')
    view = user:view(op.result.form)
    tree = view:render()
    pages = pages + 1
    assert_true(pages <= 50, 'the pages end')
    if node(tree, 'pending/' .. id) then
      local op2 = view:action('pending/' .. id, 'discard', {})
      expect(op2.status).to_be('succeeded')
      discarded = true
    end
    more = more_of(tree)
  end
  expect(pages > 1, 'more than one page').to_be(true)
  -- Select on a More page opens the tree menu (it replaces the form, so it comes last).
  user:command('worktrees')
  panel = user:view('/panels/worktrees')
  local op = panel:action(more_of(panel:render()), 'more', {})
  view = user:view(op.result.form)
  local first = node(view:render(), 'worktrees').items[1].id
  local opened = view:action('worktrees', 'select', {item_id = first})
  expect(opened.status).to_be('succeeded')
  expect(opened.result.form).to_be(W.route('/forms/worktree', first))
  user:view(opened.result.form):render()
  expect(discarded, 'Discard on a More page').to_be(true)
  expect(W.catalog().pending[id], 'the operation is discarded').to_be(nil)
end)
