-- Run from WSL:  scripts/test.sh

local Mock = require 'tests.mock_reaper'
local Model = require 'fxlink.model'
local Engine = require 'fxlink.engine'

local passed, failed = 0, 0

local function test(name, fn)
  local ok, err = pcall(fn)
  if ok then
    passed = passed + 1
    print('  ok    ' .. name)
  else
    failed = failed + 1
    print('  FAIL  ' .. name .. '\n        ' .. tostring(err))
  end
end

local function near(actual, expected, message)
  if math.abs(actual - expected) > 1e-9 then
    error(('%s: expected %s, got %s'):format(message or 'value', expected, actual), 2)
  end
end

local function eq(actual, expected, message)
  if actual ~= expected then
    error(('%s: expected %s, got %s'):format(message or 'value', tostring(expected), tostring(actual)), 2)
  end
end

-- Two tracks with one instance each, linked in a syncing group.
local function setup(spec)
  local R = Mock.new()
  local left, right = R.addTrack('Gtr L'), R.addTrack('Gtr R')
  spec = spec or { name = 'Pro-Q', params = 8 }
  local a, b = R.addFX(left, spec), R.addFX(right, spec)
  local model = Model.load(R, 'proj', 'p.rpp')
  local engine = Engine.new(R, model)
  local group = model:createGroup('Doubles')
  assert(engine:addMember(group, left, 0))
  assert(engine:addMember(group, right, 0))
  engine:tick() -- first tick takes the baseline
  return R, engine, model, group, a, b, left, right
end

print('model')

test('entry-point scripts compile', function()
  for _, file in ipairs({ 'FX Link.lua', 'FX Link - Diagnostics.lua' }) do
    local chunk, err = loadfile(PROJECT_ROOT .. file)
    assert(chunk, err)
  end
end)

test('serialization round-trips awkward names and exclusions', function()
  local R = Mock.new()
  local model = Model.load(R, 'proj', 'p.rpp')
  local g = model:createGroup('Quote " pipe | newline\n backslash \\ ]]')
  g.members = { '{A}', '{B}' }
  model:setExcluded(g, { 3, 7 }, true)
  g.sync = false
  model:save()

  local loaded = Model.load(R, 'proj', 'p.rpp')
  local h = loaded.groups[1]
  eq(h.name, g.name, 'name')
  eq(h.sync, false, 'sync')
  eq(#h.members, 2, 'members')
  eq(h.excluded[3] and h.excluded[7] and not h.excluded[1], true, 'excluded')
  eq(loaded.nextId, 2, 'nextId')
end)

test('corrupt or malicious stored data is ignored safely', function()
  for _, stored in ipairs({ 'garbage{{', 'os.exit(1)', '{groups="x"}', '{groups={{members={1,true,"{G}"}}}}' }) do
    local R = Mock.new()
    R.extState['FXLink/groups'] = stored
    local model = Model.load(R, 'proj', 'p.rpp')
    for _, g in ipairs(model.groups) do
      for _, m in ipairs(g.members) do eq(type(m), 'string', 'member type') end
    end
  end
end)

print('sync')

test('changing either instance updates the other (two-way)', function()
  local R, engine, _, _, a, b = setup()
  R.userSet(a, 2, 0.9)
  engine:tick()
  near(b.values[2], 0.9, 'b follows a')

  R.userSet(b, 5, 0.1)
  engine:tick()
  near(a.values[5], 0.1, 'a follows b')
end)

test('excluded parameters stay independent', function()
  local R, engine, model, group, a, b = setup()
  model:setExcluded(group, { 1 }, true)
  engine:tick()
  R.userSet(a, 1, 0.0)
  R.userSet(b, 1, 1.0)
  engine:tick()
  engine:tick()
  near(a.values[1], 0.0, 'a keeps its value')
  near(b.values[1], 1.0, 'b keeps its value')
end)

test('read-only (meter) parameters are never synced', function()
  local R, engine, _, _, a, b = setup({ name = 'Comp', params = 4, readonly = { [3] = true } })
  local writes = R.writes
  R.userSet(a, 3, 0.77)
  engine:tick()
  near(b.values[3], 0.5, 'meter untouched')
  eq(R.writes, writes, 'no writes')
end)

test('stepped parameters do not ping-pong between instances', function()
  local R, engine, _, _, a, b = setup({ name = 'Amp', params = 4, quantize = { [0] = 4 } })
  R.userSet(a, 0, 0.6) -- a's own value; b can only hold quarters
  engine:tick()
  near(b.values[0], 0.5, 'b snapped')
  local writes = R.writes
  for _ = 1, 10 do engine:tick() end
  eq(R.writes, writes, 'no further writes')
  near(a.values[0], 0.6, 'a unchanged')
end)

test('when both change at once, the instance you touched wins', function()
  local R, engine, _, _, a, b = setup()
  R.userSet(a, 4, 0.2)
  R.userSet(b, 4, 0.8)
  R.touch(b, 4)
  engine:tick()
  near(a.values[4], 0.8, 'a takes b')
  near(b.values[4], 0.8, 'b keeps')
end)

test('the parameter you touched stays REAPER\'s "last touched" after syncing', function()
  local R, engine, _, group, a = setup()
  R.userSet(a, 3, 0.25)
  R.touch(a, 3)
  engine:tick()
  local t = R.touched
  eq(t.track.fx[t.fx + 1], a, 'last touched FX')
  eq(t.param, 3, 'last touched param')

  R.touch(a, 5)
  assert(engine:copyFrom(group, a.guid))
  t = R.touched
  eq(t.track.fx[t.fx + 1], a, 'after copy: FX')
  eq(t.param, 5, 'after copy: param')
end)

test('a group with sync off does not sync', function()
  local R, engine, model, group, a, b = setup()
  group.sync = false
  model:changed(group)
  R.userSet(a, 0, 0.123)
  engine:tick()
  near(b.values[0], 0.5, 'b unchanged')
end)

test('three instances stay in sync', function()
  local R, engine, _, group, a, b = setup()
  local third = R.addTrack('Gtr C')
  local c = R.addFX(third, { name = 'Pro-Q', params = 8 })
  assert(engine:addMember(group, third, 0))
  engine:tick()
  R.userSet(c, 6, 0.42)
  engine:tick()
  near(a.values[6], 0.42, 'a')
  near(b.values[6], 0.42, 'b')
end)

test('reports parameters that differ when sync starts', function()
  local R, engine, model, group, a = setup()
  group.sync = false
  model:changed(group)
  engine:tick()
  R.userSet(a, 0, 0.1)
  R.userSet(a, 1, 0.2)
  group.sync = true
  model:changed(group)
  engine:tick()
  eq(engine:divergedCount(group), 2, 'diverged')
  near(R.tracks[2].fx[1].values[0], 0.5, 'changes made while off are not replayed')
  R.userSet(a, 0, 0.3) -- touching one re-syncs it
  engine:tick()
  eq(engine:divergedCount(group), 1, 'after sync')
end)

print('membership')

test('a new member adopts the group\'s full state, including hidden state', function()
  local R = Mock.new()
  local t1, t2 = R.addTrack('L'), R.addTrack('R')
  local a = R.addFX(t1, { name = 'Synth', params = 4, hidden = 'wavetable-A' })
  local b = R.addFX(t2, { name = 'Synth', params = 4, hidden = 'wavetable-B' })
  local model = Model.load(R, 'proj', 'p.rpp')
  local engine = Engine.new(R, model)
  local group = model:createGroup('g')
  R.userSet(a, 0, 0.9)
  assert(engine:addMember(group, t1, 0))
  local ok, message = engine:addMember(group, t2, 0)
  assert(ok, message)
  eq(b.hidden, 'wavetable-A', 'hidden state copied')
  near(b.values[0], 0.9, 'param copied')
  eq(R.undoBlocks[#R.undoBlocks], 'FX Link: copy plugin settings', 'undo point')
end)

test('copy keeps excluded parameters on the target', function()
  local R, engine, model, group, a, b = setup()
  model:setExcluded(group, { 2 }, true)
  R.userSet(a, 2, 0.0)
  R.userSet(a, 3, 0.0)
  R.userSet(b, 2, 1.0)
  local ok, message = engine:copyFrom(group, a.guid)
  assert(ok, message)
  near(b.values[3], 0.0, 'copied')
  near(b.values[2], 1.0, 'excluded kept')
  assert(message:find('full state'), message)
end)

test('copy falls back to parameters for formats without state chunks', function()
  local R, engine, _, group, a, b = setup({ name = 'JS: Saturator', type = 'JS', params = 4 })
  R.userSet(a, 1, 0.25)
  local ok, message = engine:copyFrom(group, a.guid)
  assert(ok, message)
  near(b.values[1], 0.25, 'copied')
  assert(message:find('parameters'), message)
end)

test('after a copy, a target that snaps values does not push them back to the source', function()
  local R, engine, _, group, a, b = setup({ name = 'Amp', type = 'JS', params = 4, quantize = { [0] = 4 } })
  R.userSet(a, 0, 0.6)
  assert(engine:copyFrom(group, a.guid))
  near(b.values[0], 0.5, 'b snapped')
  for _ = 1, 5 do engine:tick() end
  near(a.values[0], 0.6, 'source untouched')
end)

test('refuses a different plugin or an FX that is already linked', function()
  local R, engine, model, group, _, _, left = setup()
  local other = R.addTrack('Bass')
  R.addFX(other, { name = 'Other plugin' })
  local ok = engine:addMember(group, other, 0)
  eq(ok, false, 'different plugin')

  local second = model:createGroup('second')
  ok = engine:addMember(second, left, 0)
  eq(ok, false, 'already linked')
end)

test('follows FX that are reordered or moved to another track', function()
  local R, engine, _, _, a, b, left, right = setup()
  R.addFX(right, { name = 'EQ' })
  R.moveFX(right, 0, right, 1) -- b is now second on its track
  local elsewhere = R.addTrack('Elsewhere')
  R.moveFX(left, 0, elsewhere, 0)
  R.advance(1)
  R.userSet(a, 0, 0.66)
  engine:tick()
  near(b.values[0], 0.66, 'still synced')
end)

test('a deleted member is reported missing and the rest keep syncing', function()
  local R = Mock.new()
  local t1, t2, t3 = R.addTrack('1'), R.addTrack('2'), R.addTrack('3')
  local a = R.addFX(t1, { name = 'P' })
  R.addFX(t2, { name = 'P' })
  local c = R.addFX(t3, { name = 'P' })
  local model = Model.load(R, 'proj', 'p.rpp')
  local engine = Engine.new(R, model)
  local group = model:createGroup('g')
  for _, t in ipairs({ t1, t2, t3 }) do assert(engine:addMember(group, t, 0)) end
  engine:tick()
  R.deleteTrack(t2)
  R.advance(1)
  R.userSet(a, 0, 0.3)
  engine:tick()
  near(c.values[0], 0.3, 'c synced')
  eq(engine:describe(group.members[2]), nil, 'missing')
end)

print('internal state sync')

-- Like setup(), with "Also sync internal state" on and the first instance's window focused.
local function setupState()
  local R, engine, model, group, a, b, left, right = setup({ name = 'Genome', params = 6, hidden = 'amp:clean' })
  group.syncState = true
  model:save()
  R.focus(a)
  engine:tick() -- remembers the focused instance's state
  return R, engine, model, group, a, b, left, right
end

local function settle(R, engine)
  for _ = 1, 3 do
    R.advance(0.31)
    engine:tick()
  end
end

test('non-parameter edits in the focused instance reach the others once they settle', function()
  local R, engine, _, _, a, b = setupState()
  a.hidden = 'amp:crunch'
  R.advance(0.31)
  engine:tick()
  eq(b.hidden, 'amp:clean', 'not pushed while still changing')
  R.advance(0.31)
  engine:tick()
  eq(b.hidden, 'amp:crunch', 'pushed after settling')
end)

test('polls the focused instance at most every 0.3 s', function()
  local R, engine = setupState()
  R.chunkReads = 0
  for _ = 1, 10 do engine:tick() end -- no time passes
  eq(R.chunkReads, 0, 'no polls before the interval')
  R.advance(0.31)
  engine:tick()
  eq(R.chunkReads, 1, 'one poll')
end)

test('edits are pushed even if the window is closed right away', function()
  local R, engine, _, _, a, b = setupState()
  a.hidden = 'amp:lead'
  R.advance(0.31)
  engine:tick()
  R.focused = nil
  engine:tick()
  eq(b.hidden, 'amp:lead', 'pushed on focus loss')
end)

test('pushed state never bounces back, and unfocused changes are ignored', function()
  local R, engine, _, _, a, b = setupState()
  a.hidden = 'amp:crunch'
  settle(R, engine)
  eq(b.hidden, 'amp:crunch', 'pushed')
  local writes = R.chunkWrites
  R.focus(b)
  settle(R, engine)
  eq(R.chunkWrites, writes, 'focusing the other instance pushes nothing')
  a.hidden = 'changed-by-something-else'
  settle(R, engine)
  eq(b.hidden, 'amp:crunch', 'unfocused instance not used as a source')
end)

test('state push keeps excluded parameters and syncs nothing back', function()
  local R, engine, model, group, a, b = setupState()
  model:setExcluded(group, { 2 }, true)
  engine:tick()
  R.userSet(b, 2, 0.9)
  a.hidden = 'amp:fuzz'
  R.userSet(a, 1, 0.1) -- (a parameter change too)
  settle(R, engine)
  eq(b.hidden, 'amp:fuzz', 'state pushed')
  near(b.values[2], 0.9, 'excluded kept')
  near(a.values[2], 0.5, 'excluded not sent back')
  near(b.values[1], 0.1, 'parameter synced')
end)

test('internal state is not synced unless enabled', function()
  local R, engine, model, group, a, b = setupState()
  group.syncState = false
  model:save()
  a.hidden = 'amp:crunch'
  settle(R, engine)
  eq(b.hidden, 'amp:clean', 'not pushed')
end)

print('performance')

test('large plugins: touched param syncs at once, the rest within a few ticks', function()
  local R, engine, _, _, a, b = setup({ name = 'Kontakt', params = 5000 })
  R.reads = 0
  engine:tick()
  assert(R.reads <= 4200, 'reads per tick bounded, got ' .. R.reads)

  R.userSet(a, 4321, 0.01)
  R.touch(a, 4321)
  engine:tick()
  near(b.values[4321], 0.01, 'touched param immediate')

  R.userSet(a, 17, 0.99) -- e.g. automation, not touched
  for _ = 1, 3 do engine:tick() end
  near(b.values[17], 0.99, 'background scan caught it')
end)

print(('\n%d passed, %d failed'):format(passed, failed))
if failed > 0 then error('tests failed') end
