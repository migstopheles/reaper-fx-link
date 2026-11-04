-- @noindex
-- The sync engine: finds linked FX in the project, mirrors parameter changes between them,
-- and performs one-shot "copy everything" operations.
--
-- How two-way sync works: every tick we read each member's parameter values and compare them
-- with what we saw on that same member last tick. A difference means something changed that
-- instance (you, automation, a preset...), so the new value is written to the other members.
-- Tracking "last seen" per member (not per group) means a plugin rounding a value we wrote
-- (e.g. a stepped switch) is never mistaken for a new change, so instances can't ping-pong.

local Engine = {}
Engine.__index = Engine

local EPSILON = 1e-6

-- Max parameter reads per tick for the background scan. Plugins with thousands of parameters
-- are scanned over several ticks; the parameter you're touching is always synced immediately.
local SCAN_BUDGET = 4000

-- Don't rescan the whole project for a missing FX more often than this (seconds).
local RESCAN_INTERVAL = 0.5

-- Internal-state sync: minimum seconds between state polls of the focused instance. Polling also
-- slows down automatically for plugins whose state is expensive to fetch.
local STATE_POLL_INTERVAL = 0.3
local STATE_POLL_MAX_LOAD = 0.05 -- spend at most ~5% of the time fetching state

-- Plugin formats whose complete state REAPER can read and write, and the key to do it with.
local function chunkKeyFor(fxType)
  if fxType:match('^VST') then return 'vst_chunk' end
  if fxType:match('^CLAP') then return 'clap_chunk' end
end

function Engine.new(R, model)
  return setmetatable({
    R = R,
    model = model,
    locations = {},   -- guid -> { track, fx }
    lastSeen = {},    -- guid -> { [param] = value }
    caches = {},      -- group -> { key, list, set }
    cursors = {},     -- group -> next index into the param list for the background scan
    diverged = {},    -- group -> { [param] = true } for params that differ between members
    fresh = {},       -- group -> true when the next baseline must discard history
    automatable = {}, -- guid -> { [param] = bool }
    stateWatch = {},  -- group -> { guid, chunk, nextPoll, pending } for internal-state sync
    chunkKeys = {},   -- guid -> 'vst_chunk' | 'clap_chunk' | false
    lastRescan = -math.huge,
  }, Engine)
end

-- Locating FX ------------------------------------------------------------------------------

function Engine:eachTrack(fn)
  local R, proj = self.R, self.model.proj
  fn(R.GetMasterTrack(proj))
  for i = 0, R.CountTracks(proj) - 1 do fn(R.GetTrack(proj, i)) end
end

function Engine:rescan()
  local R = self.R
  self.locations = {}
  self.lastRescan = R.time_precise()

  self:eachTrack(function(track)
    for fx = 0, R.TrackFX_GetCount(track) - 1 do
      self.locations[R.TrackFX_GetFXGUID(track, fx)] = { track = track, fx = fx }
    end
  end)
end

-- Returns track, fxIndex for an FX GUID, or nil if it's not (or no longer) in the project.
function Engine:resolve(guid)
  local R = self.R
  local loc = self.locations[guid]

  -- FX can move (reordered, dragged to another track), so verify the cached location.
  if loc and R.ValidatePtr2(self.model.proj, loc.track, 'MediaTrack*')
         and R.TrackFX_GetFXGUID(loc.track, loc.fx) == guid then
    return loc.track, loc.fx
  end

  -- Missing FX trigger a full project scan, so throttle those (moved FX are found right away).
  if not loc and R.time_precise() - self.lastRescan < RESCAN_INTERVAL then return nil end

  self:rescan()
  loc = self.locations[guid]
  if loc then return loc.track, loc.fx end
end

function Engine:resolveMembers(group)
  local members = {}

  for _, guid in ipairs(group.members) do
    local track, fx = self:resolve(guid)
    if track then members[#members + 1] = { guid = guid, track = track, fx = fx } end
  end

  return members
end

-- Parameters -------------------------------------------------------------------------------

-- Some plugins expose read-only values (meters, gain reduction) as parameters. Those must never
-- be synced, so only automatable parameters take part.
function Engine:isAutomatable(member, param)
  local cache = self.automatable[member.guid]
  if not cache then
    cache = {}
    self.automatable[member.guid] = cache
  end

  if cache[param] == nil then
    local ok, value = self.R.TrackFX_GetNamedConfigParm(member.track, member.fx,
                                                         ('param.%d.automatable'):format(param))
    cache[param] = not ok or (tonumber(value) or 1) >= 0.5
  end

  return cache[param]
end

function Engine:paramCount(members)
  local count = math.huge
  for _, m in ipairs(members) do
    count = math.min(count, self.R.TrackFX_GetNumParams(m.track, m.fx))
  end
  return count == math.huge and 0 or count
end

-- The list of parameter indices that are synced for a group (cached until the group changes).
function Engine:syncedParams(group, members)
  local guids = {}
  for i, m in ipairs(members) do guids[i] = m.guid end
  local key = group.rev .. '|' .. table.concat(guids, ',')

  local cache = self.caches[group]
  if cache and cache.key == key then return cache, false end

  local list, set = {}, {}
  for param = 0, self:paramCount(members) - 1 do
    if not group.excluded[param] and self:isAutomatable(members[1], param) then
      list[#list + 1] = param
      set[param] = true
    end
  end

  cache = { key = key, list = list, set = set }
  self.caches[group] = cache
  self.cursors[group] = 1
  return cache, true
end

-- Records current values for anything we have no history for yet (new members, first run),
-- without changing anything, and counts parameters that differ between members.
-- With fresh = true, all history is discarded first (after a copy, or when sync is re-enabled).
function Engine:baseline(group, members, list, fresh)
  local R = self.R
  local diverged = {}

  for _, m in ipairs(members) do
    if fresh or not self.lastSeen[m.guid] then self.lastSeen[m.guid] = {} end
  end

  for _, param in ipairs(list) do
    local first
    for i, m in ipairs(members) do
      local value = R.TrackFX_GetParamNormalized(m.track, m.fx, param)
      local seen = self.lastSeen[m.guid]
      if seen[param] == nil then seen[param] = value end
      if i == 1 then
        first = value
      elseif math.abs(value - first) > EPSILON then
        diverged[param] = true
      end
    end
  end

  self.diverged[group] = diverged
end

-- Sync ---------------------------------------------------------------------------------------

function Engine:syncParam(group, members, param, preferredGuid)
  local R = self.R
  local values = {}
  local source, sourceValue

  for i, m in ipairs(members) do
    local value = R.TrackFX_GetParamNormalized(m.track, m.fx, param)
    values[i] = value

    local seen = self.lastSeen[m.guid]
    if not seen then
      seen = {}
      self.lastSeen[m.guid] = seen
    end

    local previous = seen[param]
    if previous == nil then
      seen[param] = value
    elseif math.abs(value - previous) > EPSILON then
      -- If several instances changed at once, the one you last touched wins.
      if not source or m.guid == preferredGuid then
        source, sourceValue = m, value
      end
    end
  end

  local diverged = self.diverged[group]

  if not source then
    local differs = false
    for i = 2, #values do
      if math.abs(values[i] - values[1]) > EPSILON then differs = true break end
    end
    diverged[param] = differs or nil
    return
  end

  for i, m in ipairs(members) do
    if m == source then
      self.lastSeen[m.guid][param] = sourceValue
    else
      if math.abs(values[i] - sourceValue) > EPSILON then
        R.TrackFX_SetParamNormalized(m.track, m.fx, param, sourceValue)
        self.wrote = true
      end
      -- Read back: the plugin may have snapped the value to a step it supports.
      self.lastSeen[m.guid][param] = R.TrackFX_GetParamNormalized(m.track, m.fx, param)
    end
  end

  diverged[param] = nil
end

-- Returns guid, param, track, fx of the last touched track FX parameter, if any.
function Engine:touchedParam()
  local R, proj = self.R, self.model.proj
  local ok, trackIdx, itemIdx, _, fx, param = R.GetTouchedOrFocusedFX(0)
  if not ok or itemIdx ~= -1 then return nil end

  local track = trackIdx == -1 and R.GetMasterTrack(proj) or R.GetTrack(proj, trackIdx)
  local guid = track and R.TrackFX_GetFXGUID(track, fx)
  if not guid then return nil end

  return guid, param, track, fx
end

-- REAPER treats every parameter write as a "touch", so our writes would hijack the last-touched
-- parameter (used by e.g. "create envelope for last touched parameter"). Re-touch the one the
-- user had touched by writing its current value back to it.
function Engine:restoreTouched(track, fx, param)
  local R = self.R
  if track and R.ValidatePtr2(self.model.proj, track, 'MediaTrack*') and R.TrackFX_GetFXGUID(track, fx) then
    R.TrackFX_SetParamNormalized(track, fx, param, R.TrackFX_GetParamNormalized(track, fx, param))
  end
end

function Engine:syncGroup(group, members, touchedGuid, touchedParam, budget)
  local cache, rebuilt = self:syncedParams(group, members)
  local list = cache.list
  if #list == 0 then return end

  if rebuilt then
    self:baseline(group, members, list, self.fresh[group])
    self.fresh[group] = nil
  end

  local touchedHere = false
  for _, m in ipairs(members) do
    if m.guid == touchedGuid then touchedHere = true break end
  end

  if touchedHere and cache.set[touchedParam] then
    self:syncParam(group, members, touchedParam, touchedGuid)
  end

  local count = math.min(#list, math.max(1, budget // #members))
  local cursor = self.cursors[group] or 1

  for _ = 1, count do
    if cursor > #list then cursor = 1 end
    self:syncParam(group, members, list[cursor], touchedHere and touchedGuid or nil)
    cursor = cursor + 1
  end

  self.cursors[group] = cursor
end

function Engine:tick()
  local active = {}

  for _, group in ipairs(self.model.groups) do
    local members = group.sync and self:resolveMembers(group) or {}
    if #members >= 2 then
      active[#active + 1] = { group = group, members = members }
    elseif not self.fresh[group] then
      -- Not syncing: whatever changes meanwhile must not be replayed when sync resumes.
      self:invalidate(group)
    end
  end

  if #active == 0 then return end

  local touchedGuid, touchedParam, touchedTrack, touchedFx = self:touchedParam()
  local budget = SCAN_BUDGET // #active
  self.wrote = false

  for _, entry in ipairs(active) do
    self:syncGroup(entry.group, entry.members, touchedGuid, touchedParam, budget)
  end

  local focusedGuid
  for _, entry in ipairs(active) do
    if entry.group.syncState then
      if focusedGuid == nil then
        local track, fx = self:focusedFX()
        focusedGuid = track and self.R.TrackFX_GetFXGUID(track, fx) or false
      end
      self:syncState(entry.group, entry.members, focusedGuid)
    else
      self.stateWatch[entry.group] = nil
    end
  end

  if self.wrote then self:restoreTouched(touchedTrack, touchedFx, touchedParam) end
end

function Engine:chunkKey(member)
  local key = self.chunkKeys[member.guid]
  if key == nil then
    local _, fxType = self.R.TrackFX_GetNamedConfigParm(member.track, member.fx, 'fx_type')
    key = chunkKeyFor(fxType or '') or false
    self.chunkKeys[member.guid] = key
  end
  return key
end

-- Internal-state sync, for plugins whose controls aren't exposed as host parameters.
--
-- Only the instance whose window is focused is watched: that's where knobs get turned, and it
-- means changes we push into the other instances can never bounce back. A change is pushed once
-- the state stops changing (i.e. you've stopped adjusting), so the other instances reload their
-- state once per edit rather than continuously during a drag.
function Engine:syncState(group, members, focusedGuid)
  local R = self.R
  local source
  for _, m in ipairs(members) do
    if m.guid == focusedGuid then source = m break end
  end

  local watch = self.stateWatch[group]
  if watch and (not source or source.guid ~= watch.guid) then
    -- Focus moved away (e.g. the window was closed right after an edit): don't lose that edit.
    self.stateWatch[group] = nil
    for _, m in ipairs(members) do
      if m.guid == watch.guid and self:chunkKey(m) then
        local key = self:chunkKey(m)
        local ok, chunk = R.TrackFX_GetNamedConfigParm(m.track, m.fx, key)
        if ok and chunk ~= '' and (watch.pending or chunk ~= watch.chunk) then
          self:pushState(group, members, m, key, chunk)
        end
      end
    end
    watch = nil
  end

  if not source then return end

  local key = self:chunkKey(source)
  if not key then return end

  local now = R.time_precise()
  if watch and now < watch.nextPoll then return end

  local ok, chunk = R.TrackFX_GetNamedConfigParm(source.track, source.fx, key)
  local cost = R.time_precise() - now
  if not ok or chunk == '' then return end

  local nextPoll = now + math.max(STATE_POLL_INTERVAL, cost / STATE_POLL_MAX_LOAD)

  if not watch then
    -- Newly focused instance: just remember its state.
    self.stateWatch[group] = { guid = source.guid, chunk = chunk, nextPoll = nextPoll, pending = false }
    return
  end

  watch.nextPoll = nextPoll

  if chunk ~= watch.chunk then
    watch.chunk = chunk
    watch.pending = true -- still changing; push once it settles
  elseif watch.pending then
    watch.pending = false
    self:pushState(group, members, source, key, chunk)
  end
end

function Engine:pushState(group, members, source, key, chunk)
  local R = self.R

  for _, m in ipairs(members) do
    if m ~= source and self:chunkKey(m) == key then
      local kept = {}
      for param in pairs(group.excluded) do
        kept[param] = R.TrackFX_GetParamNormalized(m.track, m.fx, param)
      end

      R.TrackFX_SetNamedConfigParm(m.track, m.fx, key, chunk)

      for param, value in pairs(kept) do
        R.TrackFX_SetParamNormalized(m.track, m.fx, param, value)
        self.wrote = true
      end
    end
  end
end

-- Forget what we've seen so the next sync takes a fresh baseline (e.g. after a copy).
function Engine:invalidate(group)
  self.caches[group] = nil
  self.diverged[group] = nil
  self.fresh[group] = true
end

function Engine:divergedCount(group)
  local count = 0
  for _ in pairs(self.diverged[group] or {}) do count = count + 1 end
  return count
end

-- Copy ---------------------------------------------------------------------------------------

-- Copies the complete state of one member to others (default: all other members).
-- VST/VST3/CLAP plugins get their full internal state copied (including settings that aren't
-- exposed as parameters); other formats get all parameters copied. Excluded parameters keep
-- their previous values on each target.
function Engine:copyFrom(group, sourceGuid, targetGuids)
  local R, proj = self.R, self.model.proj
  local srcTrack, srcFx = self:resolve(sourceGuid)
  if not srcTrack then return false, 'The source FX could not be found in this project.' end

  local source = { guid = sourceGuid, track = srcTrack, fx = srcFx }
  local _, fxType = R.TrackFX_GetNamedConfigParm(srcTrack, srcFx, 'fx_type')
  local chunkKey = chunkKeyFor(fxType or '')
  local chunk

  if chunkKey then
    local ok, value = R.TrackFX_GetNamedConfigParm(srcTrack, srcFx, chunkKey)
    if ok and value ~= '' then chunk = value end
  end

  targetGuids = targetGuids or group.members
  local copied, fullState = 0, 0
  local _, touchedParam, touchedTrack, touchedFx = self:touchedParam()

  R.Undo_BeginBlock2(proj)
  R.PreventUIRefresh(1)

  for _, guid in ipairs(targetGuids) do
    local track, fx = self:resolve(guid)

    if guid ~= sourceGuid and track then
      local kept = {}
      for param in pairs(group.excluded) do
        kept[param] = R.TrackFX_GetParamNormalized(track, fx, param)
      end

      if chunk and R.TrackFX_SetNamedConfigParm(track, fx, chunkKey, chunk) then
        fullState = fullState + 1
      end

      -- Copy parameters too: REAPER's own per-FX controls (wet/dry, bypass) aren't part of
      -- the plugin's state chunk, and this is the only option for non-VST/CLAP formats.
      local count = math.min(R.TrackFX_GetNumParams(srcTrack, srcFx), R.TrackFX_GetNumParams(track, fx))
      for param = 0, count - 1 do
        if not group.excluded[param] and self:isAutomatable(source, param) then
          local value = R.TrackFX_GetParamNormalized(srcTrack, srcFx, param)
          if math.abs(value - R.TrackFX_GetParamNormalized(track, fx, param)) > EPSILON then
            R.TrackFX_SetParamNormalized(track, fx, param, value)
          end
        end
      end

      for param, value in pairs(kept) do
        R.TrackFX_SetParamNormalized(track, fx, param, value)
      end

      copied = copied + 1
    end
  end

  R.PreventUIRefresh(-1)
  R.Undo_EndBlock2(proj, 'FX Link: copy plugin settings', -1)

  -- Must come after the undo block: closing it marks the changed FX as last touched.
  if touchedTrack then self:restoreTouched(touchedTrack, touchedFx, touchedParam) end

  self:invalidate(group)

  if copied == 0 then return false, 'No other instances to copy to.' end

  local what = fullState == copied and 'full state' or
               fullState == 0 and 'parameters' or 'full state where supported'
  return true, ('Copied %s to %d instance%s.'):format(what, copied, copied == 1 and '' or 's')
end

-- Membership ---------------------------------------------------------------------------------

function Engine:pluginIdentity(track, fx)
  local R = self.R
  local _, name = R.TrackFX_GetNamedConfigParm(track, fx, 'fx_name')
  local ok, ident = R.TrackFX_GetNamedConfigParm(track, fx, 'fx_ident')
  if not ok or ident == '' then ident = name end
  return ident, name
end

-- Adds an FX to a group. If the group is syncing and already has members, the new FX adopts
-- the group's settings (full copy from the first member).
function Engine:addMember(group, track, fx)
  local guid = self.R.TrackFX_GetFXGUID(track, fx)
  local owner = self.model:findGroupOf(guid)
  if owner then
    return false, owner == group and 'That FX is already in this group.'
                                  or ('That FX is already linked in "%s".'):format(owner.name)
  end

  local ident, name = self:pluginIdentity(track, fx)
  if group.ident and group.ident ~= ident then
    return false, ('Only %s instances can join this group (that FX is %s).'):format(group.plugin, name)
  end

  local existing = self:resolveMembers(group)[1]

  if not group.ident then
    group.ident, group.plugin = ident, name
  end

  self.model:addMember(group, guid)
  self.locations[guid] = { track = track, fx = fx }

  if group.sync and existing then
    local ok, message = self:copyFrom(group, existing.guid, { guid })
    if not ok then return false, message end
    return true, ('Added %s; it now matches the group.'):format(name)
  end

  return true, ('Added %s.'):format(name)
end

-- Info for the UI ----------------------------------------------------------------------------

function Engine:describe(guid)
  local R = self.R
  local track, fx = self:resolve(guid)
  if not track then return nil end

  local number = math.tointeger(R.GetMediaTrackInfo_Value(track, 'IP_TRACKNUMBER')) or 0
  local _, trackName = R.GetTrackName(track)
  local _, fxName = R.TrackFX_GetFXName(track, fx)

  return {
    track = track,
    fx = fx,
    trackLabel = number == -1 and 'MASTER' or ('%d: %s'):format(number, trackName),
    fxName = fxName,
  }
end

-- FX in the project that could be added to a group (same plugin, not linked anywhere yet).
function Engine:candidates(group)
  local R = self.R
  local result = {}

  self:eachTrack(function(track)
    for fx = 0, R.TrackFX_GetCount(track) - 1 do
      local guid = R.TrackFX_GetFXGUID(track, fx)
      if not self.model:findGroupOf(guid) and (not group.ident or self:pluginIdentity(track, fx) == group.ident) then
        local info = self:describe(guid)
        if info then
          result[#result + 1] = { track = track, fx = fx, label = info.trackLabel .. '  >  ' .. info.fxName }
        end
      end
    end
  end)

  return result
end

-- Parameter names of a group's plugin, for the exclusion list (cached per reference FX).
function Engine:paramNames(group)
  local R = self.R
  local reference = self:resolveMembers(group)[1]
  if not reference then return nil end

  self.names = self.names or {}
  local count = R.TrackFX_GetNumParams(reference.track, reference.fx)
  local cached = self.names[reference.guid]
  if cached and #cached == count then return cached end

  local names = {}
  for param = 0, count - 1 do
    local _, name = R.TrackFX_GetParamName(reference.track, reference.fx, param)
    names[#names + 1] = { index = param, name = name ~= '' and name or ('Parameter ' .. (param + 1)) }
  end

  self.names[reference.guid] = names
  return names
end

-- The FX whose window is currently focused. Returns track, fx or nil, reason.
function Engine:focusedFX()
  local R, proj = self.R, self.model.proj
  local ok, trackIdx, itemIdx, _, fx = R.GetTouchedOrFocusedFX(1)
  if not ok then return nil, 'Open a plugin window first (click into it so it has focus).' end
  if itemIdx ~= -1 then return nil, 'Item/take FX are not supported, only track FX.' end
  if fx >= 0x1000000 then return nil, 'Input FX and FX inside containers are not supported yet.' end

  local track = trackIdx == -1 and R.GetMasterTrack(proj) or R.GetTrack(proj, trackIdx)
  if not track then return nil, 'Could not find the focused FX.' end
  return track, fx
end

Engine.EPSILON = EPSILON
return Engine
