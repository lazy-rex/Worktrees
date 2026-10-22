-- The forms on app.form (real hub). The SDK runs the fields of a form again at the submit and checks
-- a select value against its options then (unless check = false), so a field whose options change
-- between the render and the submit must not refuse the value that the form showed.
local W = load_fixture(H.args.file:match('^(.*)/[^/]*$') .. '/support/fixture.lua')

-- The lab starts with no recorded repository: the form shows a text field. Another caller records a
-- repository before the submit, so the fields at the submit are a select without the typed one.
test('New Worktree: a repository recorded between the render and the submit does not refuse the typed one', function()
  local wanted = W.repo('wanted')
  local other = W.repo('other')
  user:command('new_worktree')
  local form = user:view('/forms/new-worktree')
  form:render()
  W.settle(function() return agent('alice'):call('worktree.create', {repo = other, branch = 'other', key = 'other'}) end)
  local op = form:action('new_worktree', 'submit', {values = {repo = wanted, branch = 'wanted', base = ''}}, 'wanted')
  expect(op.status).to_be('succeeded')
  expect(W.git(wanted, 'worktree', 'list', '--porcelain'):find('branch refs/heads/wanted', 1, true) ~= nil, 'the tree exists').to_be(true)
end)

-- The backend check stays: a path that is not a repository is refused by the create.
test('New Worktree: a value outside the options is still checked by the create', function()
  user:command('new_worktree')
  local form = user:view('/forms/new-worktree')
  local op = form:action('new_worktree', 'submit', {values = {repo = H.args.lab .. '/not-a-repo', branch = 'x', base = ''}}, 'not-a-repo')
  expect(op.status).to_be('failed')
end)
