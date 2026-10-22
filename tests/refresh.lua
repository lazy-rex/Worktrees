-- Read tracking: the hub renders a view again for a SQL commit only when the commit changed a
-- table that the render read. State outside SQL needs app.refresh. The panel's tree states are such
-- state: a scan job that ends calls app.refresh. This file checks that the panel shows a tree as
-- checking and then as clean by itself. The test makes no SQL write, focus, action or render
-- request between the two: it reads the hub's last tree of the view (View:get, hub.view.get).
local W = load_fixture(H.args.file:match('^(.*)/[^/]*$') .. '/support/fixture.lua')
local lab = H.args.lab
local repo = W.repo('refresh')
local alice = agent('alice')

-- row gives the detail text of the panel row of path in the hub's last tree, or nil.
local function row(view, path)
  for _, n in ipairs(view:get().tree.nodes or {}) do
    for _, item in ipairs(n.items or {}) do
      if item.id == path then return item.detail or '' end
    end
  end
end

test('the panel shows a tree as checking, then as clean when its git status ends, with no render request', function()
  local t = W.settle(function() return alice:call('worktree.create', {repo = repo, branch = 'refresh/one', key = 'refresh-one'}) end)
  -- A slow git status: Git runs the core.fsmonitor hook for each status in this repository, and
  -- the hook waits until the gate file exists (then it fails, and Git scans the tree itself).
  local gate, hook = lab .. '/scan-gate', lab .. '/fsmonitor-gate.sh'
  W.write(hook, "#!/bin/sh\nwhile [ ! -f '" .. gate .. "' ]; do sleep 0.1; done\nexit 1\n")
  W.run({'chmod', '755', hook})
  W.git(repo, 'config', 'core.fsmonitor', hook)
  local panel = user:panel('worktrees')
  -- A first worktree.list page starts a new scan (before the observation), which waits at the gate.
  alice:call('worktree.list', {})
  wait('the tree shows checking', function()
    local d = row(panel, t.path)
    return d and d:find('\nchecking', 1, true) ~= nil
  end, 20)
  local before = panel:get().revision
  W.write(gate, '')
  -- Only the end of the scan job (app.refresh) can render the panel again now.
  local detail = wait('the tree shows clean', function()
    local d = row(panel, t.path)
    return d and d:find('\nclean', 1, true) ~= nil and d
  end, 30)
  expect(detail:find(t.path, 1, true) == 1, detail).to_be(true)
  expect(panel:get().revision ~= before, 'a new render arrived').to_be(true)
  W.git(repo, 'config', '--unset', 'core.fsmonitor')
end)
