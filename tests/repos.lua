-- A recorded repository that fails (deleted or moved) gives one unavailable row with the Git error.
-- The other repositories are listed as usual, in worktree.list and in the panel. The catalog keeps
-- the repository: when it returns, the next refresh lists its trees again.
local W = load_fixture(H.args.file:match('^(.*)/[^/]*$') .. '/support/fixture.lua')
local alice = agent('alice')

local function create(repo, branch, key)
  return W.settle(function() return alice:call('worktree.create', {repo = repo, branch = branch, key = key}) end)
end
local healthy, gone = W.repo('healthy'), W.repo('gone')
local kept = create(healthy, 'kept', 'kept').path
local lost = create(gone, 'lost', 'lost').path

-- rows waits for a finished scan of every recorded repository and returns its rows by path.
local function rows()
  return wait('a finished scan', function()
    local r = alice:call('worktree.list', {})
    if r.refreshing then return nil end
    local by_path = {}
    for _, t in ipairs(r.worktrees or {}) do by_path[t.path] = t end
    return by_path
  end, 30)
end

test('a moved repository gives one unavailable row; the other repository is listed; the panel shows both', function()
  W.run({'mv', gone, gone .. '.away'})
  local by_path = rows()
  expect(by_path[kept] and by_path[kept].state).to_be('clean')
  expect(by_path[healthy] and by_path[healthy].state).to_be('clean')
  local row = by_path[gone]
  expect(row and row.state).to_be('unavailable')
  expect(row.error).to_match('not a git repository')
  expect(by_path[lost], 'no row for a tree of the failed repository').to_be(nil)
  user:command('worktrees')
  local panel = user:view('/panels/worktrees')
  local items = wait('the panel lists both repositories', function()
    local list = node(panel:render(), 'worktrees')
    local by_id = {}
    for _, item in ipairs(list and list.items or {}) do by_id[item.id] = item end
    return by_id[kept] and by_id[gone] and by_id
  end, 20)
  expect(items[gone].detail).to_match('unavailable')
  expect(items[gone].detail).to_match('not a git repository')
  expect(node(panel:render(), 'refresh_error'), 'no refresh error for one repository').to_be(nil)
end)

test('the repository returns: the next refresh lists its trees again', function()
  W.run({'mv', gone .. '.away', gone})
  -- A list can return the finished scan from before the move (a retry reads the scan that a
  -- previous call or the panel started), so poll for a finished scan with the restored rows.
  -- A bounded loop, not wait(): wait() catches an error and polls again. Here any error of a
  -- call ends the test.
  local by_path
  local deadline = os.time() + 30
  repeat
    local r = alice:call('worktree.list', {})
    local got = {}
    for _, t in ipairs(r.worktrees or {}) do got[t.path] = t end
    if not r.refreshing and got[gone] and got[gone].state ~= 'unavailable' then by_path = got
    else
      assert_true(os.time() < deadline, 'the restored rows within 30 s')
      rex.sleep(0.2)
    end
  until by_path
  expect(by_path[gone].state).to_be('clean')
  expect(by_path[lost] and by_path[lost].state).to_be('clean')
  expect(by_path[kept] and by_path[kept].state).to_be('clean')
end)
