-- The Rex Lua runtime can lose a closure's write to a captured local after a pcall caught an error
-- (coordinator notice, 2026-10-19; observed on Rex 0.0.1792158932-g88fd41, lab). H.wait calls
-- pcall(fn) and polls again after an error, so a wait callback must not write a test local: the
-- tests take the value that wait returns, or keep state in a table field. This file keeps the
-- catch sequence that lost a write in the runner, and checks the two safe forms after it.
-- A transient error on the first call of a callback, as a lost reply would give.
local function flaky()
  local first = {true}
  return function() if first[1] then first[1] = false; error('transient', 0) end end
end
-- Earlier catches in nested functions; the reproduction needed them.
local function nested_catches()
  for _ = 1, 2 do
    local r
    local fail_once = flaky()
    wait('a nested value', function() fail_once(); r = 'set'; return true end, 5)
  end
end

test('after earlier catches, a wait callback that writes a test local loses the write; the safe forms keep it', function()
  nested_catches()
  local captured
  local fail_once = flaky()
  wait('the captured value', function() fail_once(); captured = 'set'; return true end, 5)
  -- The defect, as this build shows it. When Rex fixes it, this check fails: remove the check, and
  -- keep the safe forms.
  expect(captured, 'the write to the captured local is lost (Rex defect)').to_be(nil)
  local fail_returned = flaky()
  local returned = wait('the returned value', function() fail_returned(); return 'set' end, 5)
  expect(returned).to_be('set')
  local box = {}
  local fail_box = flaky()
  wait('the table field', function() fail_box(); box.value = 'set'; return true end, 5)
  expect(box.value).to_be('set')
end)
