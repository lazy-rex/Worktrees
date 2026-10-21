-- The panel shows the stopped operations (Discard widgets) in operation ID order (sandbox,
-- tests/support/sandbox.lua). The catalog arrives as JSON at each render, so the table order
-- does not give a stable widget order.
local tests_dir = H.args.file:match('^(.*)/[^/]*$')
local load_sandbox = load_fixture(tests_dir .. '/support/sandbox.lua')
local base = getfenv(1)

local function pending_ids(tree)
  local ids = {}
  for _, n in ipairs(tree.nodes or {}) do
    if n.id:sub(1, 8) == 'pending/' then ids[#ids + 1] = n.id:sub(9) end
  end
  return ids
end

test('the Discard widgets come in operation ID order on each render', function()
  local s = load_sandbox(tests_dir .. '/..', base)
  assert_true(s.loaded, 'the plugin loads: ' .. tostring(s.load_error))
  s:tick()
  -- The catalog decoded from JSON, as the hub store gives it; the keys are written in reverse order.
  local want, fields = {}, {}
  for i = 1, 12 do want[i] = string.format('5:alice5:op-%02d', i) end
  for i = 12, 1, -1 do
    fields[#fields + 1] = string.format('%q:{"kind":"create","phase":"prepared","path":"/sandbox/worktrees/r/%02d"}', want[i], i)
  end
  s.catalog = rex.json.decode('{"repos":{},"pending":{' .. table.concat(fields, ',') .. '}}')
  for _ = 1, 3 do
    local reply = s:perform('view.render', {route = '/panels/worktrees'})
    assert_true(reply and reply.result ~= nil, 'the panel renders: ' .. show(reply and reply.error))
    expect(pending_ids(reply.result.tree or reply.result)).to_equal(want)
  end
end)
