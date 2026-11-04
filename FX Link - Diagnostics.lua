-- @noindex
-- FX Link diagnostics: records what REAPER sees while you turn a knob on a linked plugin.
-- Close the FX Link window before running this, so it doesn't sync while we observe.

local R = reaper

if not R.ImGui_GetBuiltinPath then
  R.ShowMessageBox('ReaImGui is required.', 'FX Link diagnostics', 0)
  return
end

local scriptDir = debug.getinfo(1, 'S').source:match('^@?(.*[\\/])') or ''
package.path = R.ImGui_GetBuiltinPath() .. '/?.lua;' .. scriptDir .. '?.lua;' .. package.path

local ImGui = require 'imgui' '0.10'
local Model = require 'fxlink.model'
local Engine = require 'fxlink.engine'

local WATCH_SECONDS = 10
local reportPath = R.GetResourcePath() .. '/FX-Link-diagnostics.txt'
local lines = {}
local function log(fmt, ...) lines[#lines + 1] = select('#', ...) > 0 and fmt:format(...) or fmt end

local proj, path = R.EnumProjects(-1)
local model = Model.load(R, proj, path)
local engine = Engine.new(R, model)

log('REAPER %s, ReaImGui %s', R.GetAppVersion(), select(1, R.ImGui_GetVersion()))

local fxLinkRunning = R.GetExtState('FXLink', 'running') == '1'
log('FX Link running: %s', tostring(fxLinkRunning))
log('Groups in project: %d', #model.groups)

local group, members
for _, g in ipairs(model.groups) do
  local resolved = engine:resolveMembers(g)
  log('  group "%s" sync=%s members=%d resolved=%d excluded=%d', g.name, tostring(g.sync), #g.members,
      #resolved, (function() local n = 0 for _ in pairs(g.excluded) do n = n + 1 end return n end)())
  if not group and #resolved >= 2 then group, members = g, resolved end
end

local function paramName(m, p) local _, n = R.TrackFX_GetParamName(m.track, m.fx, p) return n end
local function chunkOf(m)
  local key = engine:chunkKey(m)
  if not key then return nil end
  local ok, c = R.TrackFX_GetNamedConfigParm(m.track, m.fx, key)
  return ok and c or nil
end

local state, startTime, snapshot, chunkBefore, changes, touchedLog, lastTouched = 'error', nil, {}, nil, {}, {}, nil
local summary = {}

if fxLinkRunning then
  summary[#summary + 1] = 'Warning: FX Link is running and may sync while this records. Close it for clean results.'
end

if not group then
  log('No group with two resolved instances found.')
  summary[#summary + 1] = 'No FX Link group with two instances found in this project.'
else
  for i, m in ipairs(members) do
    local info = engine:describe(m.guid)
    local _, fxType = R.TrackFX_GetNamedConfigParm(m.track, m.fx, 'fx_type')
    local _, ident = R.TrackFX_GetNamedConfigParm(m.track, m.fx, 'fx_ident')
    local chunk = chunkOf(m)
    log('Instance %d: %s | %s | type=%s | params=%d | chunk=%s bytes | ident=%s', i, info.trackLabel,
        info.fxName, fxType, R.TrackFX_GetNumParams(m.track, m.fx), chunk and #chunk or 'n/a', ident)
  end

  local cache = engine:syncedParams(group, members)
  log('Parameters FX Link would sync: %d', #cache.list)

  local m1 = members[1]
  local count = R.TrackFX_GetNumParams(m1.track, m1.fx)
  log('First parameters of instance 1 (index: name = normalized / formatted):')
  for p = 0, math.min(count, 60) - 1 do
    local _, formatted = R.TrackFX_GetFormattedParamValue(m1.track, m1.fx, p)
    log('  %d: %s = %.4f / %s', p, paramName(m1, p), R.TrackFX_GetParamNormalized(m1.track, m1.fx, p), formatted)
  end
  if count > 60 then log('  ... (%d more)', count - 60) end

  for i, m in ipairs(members) do
    snapshot[i] = {}
    for p = 0, R.TrackFX_GetNumParams(m.track, m.fx) - 1 do
      snapshot[i][p] = R.TrackFX_GetParamNormalized(m.track, m.fx, p)
    end
  end
  chunkBefore = chunkOf(m1)
  state = 'watch'
  startTime = R.time_precise()
end

local function watchTick()
  local now = R.time_precise() - startTime

  for i, m in ipairs(members) do
    for p = 0, R.TrackFX_GetNumParams(m.track, m.fx) - 1 do
      local v = R.TrackFX_GetParamNormalized(m.track, m.fx, p)
      if math.abs(v - (snapshot[i][p] or v)) > 1e-6 and #changes < 200 then
        changes[#changes + 1] = ('  t=%.2fs instance %d param %d (%s): %.4f -> %.4f'):format(
          now, i, p, paramName(m, p), snapshot[i][p], v)
      end
      snapshot[i][p] = v
    end
  end

  local ok, t, item, _, fx, p = R.GetTouchedOrFocusedFX(0)
  local key = ok and ('track=%d item=%d fx=%d param=%d'):format(t, item, fx, p) or 'none'
  if key ~= lastTouched then
    touchedLog[#touchedLog + 1] = ('  t=%.2fs last touched: %s'):format(now, key)
    lastTouched = key
  end

  if now >= WATCH_SECONDS then
    log('')
    log('Parameter changes seen while watching (%d):', #changes)
    for _, c in ipairs(changes) do log(c) end
    log('Last-touched changes:')
    for _, c in ipairs(touchedLog) do log(c) end

    local chunkAfter = chunkOf(members[1])
    log('Instance 1 state chunk changed: %s (before %s bytes, after %s bytes)',
        tostring(chunkBefore ~= chunkAfter), chunkBefore and #chunkBefore or 'n/a', chunkAfter and #chunkAfter or 'n/a')

    -- Write test: can REAPER set a parameter on instance 2? (Restored immediately afterwards.)
    local m2 = members[2]
    local probe = 0
    for _, p in ipairs(engine:syncedParams(group, members).list) do probe = p break end
    local old = R.TrackFX_GetParamNormalized(m2.track, m2.fx, probe)
    local target = old < 0.5 and old + 0.25 or old - 0.25
    R.TrackFX_SetParamNormalized(m2.track, m2.fx, probe, target)
    local readBack = R.TrackFX_GetParamNormalized(m2.track, m2.fx, probe)
    R.TrackFX_SetParamNormalized(m2.track, m2.fx, probe, old)
    log('Write test on instance 2 param %d (%s): wrote %.4f, read back %.4f (restored to %.4f)',
        probe, paramName(m2, probe), target, readBack, old)

    local f = io.open(reportPath, 'w')
    f:write(table.concat(lines, '\n'), '\n')
    f:close()

    summary[#summary + 1] = ('Seen %d parameter change(s); state chunk changed: %s.'):format(#changes, tostring(chunkBefore ~= chunkAfter))
    summary[#summary + 1] = 'Report saved to: ' .. reportPath
    state = 'done'
  end
end

local ctx = ImGui.CreateContext('FX Link diagnostics')

local function loop()
  if state == 'watch' then watchTick() end

  ImGui.SetNextWindowSize(ctx, 520, 160, ImGui.Cond_FirstUseEver)
  local visible, open = ImGui.Begin(ctx, 'FX Link diagnostics', true)
  if visible then
    if state == 'watch' then
      local left = WATCH_SECONDS - (R.time_precise() - startTime)
      if fxLinkRunning then
        ImGui.TextColored(ctx, 0xFFB347FF, 'FX Link is running: close it for clean results.')
      end
      ImGui.TextWrapped(ctx, ('Recording... turn one knob on the FIRST instance (%s) back and forth now.')
                               :format(engine:describe(members[1].guid).trackLabel))
      ImGui.Text(ctx, ('%.0f seconds left'):format(math.max(0, left)))
    else
      for _, s in ipairs(summary) do ImGui.TextWrapped(ctx, s) end
      ImGui.TextDisabled(ctx, 'You can close this window.')
    end
    ImGui.End(ctx)
  end
  if open then R.defer(loop) end
end

R.defer(loop)
