-- A small in-memory imitation of the parts of the REAPER API that FX Link uses, for tests.

local Mock = {}

function Mock.new()
  local R = { clock = 0, reads = 0, writes = 0, undoBlocks = {}, extState = {}, touched = nil, focused = nil }
  local master = { name = 'MASTER', number = -1, fx = {} }
  local tracks = {}
  local valid = {} -- live tracks, for ValidatePtr2

  valid[master] = true
  R.tracks, R.master = tracks, master

  -- Test helpers -------------------------------------------------------------------------

  -- spec: { name, ident, type = 'VST3', params = n, hidden = any, quantize = { [p] = steps },
  --         readonly = { [p] = true } }
  function R.addTrack(name)
    local track = { name = name, fx = {} }
    tracks[#tracks + 1] = track
    track.number = #tracks
    valid[track] = true
    return track
  end

  local guidCounter = 0
  function R.addFX(track, spec)
    guidCounter = guidCounter + 1
    local fx = {
      guid = ('{GUID-%04d}'):format(guidCounter),
      name = spec.name or 'Plugin',
      ident = spec.ident or spec.name or 'Plugin',
      type = spec.type or 'VST3',
      values = {},
      quantize = spec.quantize or {},
      readonly = spec.readonly or {},
      hidden = spec.hidden,
    }
    for p = 0, (spec.params or 4) - 1 do fx.values[p] = spec.default or 0.5 end
    track.fx[#track.fx + 1] = fx
    return fx
  end

  function R.deleteTrack(track)
    for i, t in ipairs(tracks) do
      if t == track then table.remove(tracks, i) break end
    end
    valid[track] = nil
    for i, t in ipairs(tracks) do t.number = i end
  end

  function R.moveFX(fromTrack, fromIndex, toTrack, toIndex)
    local fx = table.remove(fromTrack.fx, fromIndex + 1)
    table.insert(toTrack.fx, toIndex + 1, fx)
  end

  function R.advance(seconds) R.clock = R.clock + seconds end

  -- Simulates the user/automation moving a parameter of an FX.
  function R.userSet(fx, param, value) fx.values[param] = value end

  local function locate(fx)
    for _, track in ipairs({ master, table.unpack(tracks) }) do
      for i, f in ipairs(track.fx) do
        if f == fx then return track, i - 1 end
      end
    end
  end

  function R.touch(fx, param)
    local track, index = locate(fx)
    R.touched = { track = track, fx = index, param = param }
  end

  function R.focus(fx)
    local track, index = locate(fx)
    R.focused = { track = track, fx = index }
  end

  -- API ----------------------------------------------------------------------------------

  local function get(track, index) return track.fx[index + 1] end

  local function quantized(fx, param, value)
    local steps = fx.quantize[param]
    if not steps then return value end
    return math.floor(value * steps + 0.5) / steps
  end

  function R.time_precise() return R.clock end
  function R.GetMasterTrack() return master end
  function R.CountTracks() return #tracks end
  function R.GetTrack(_, i) return tracks[i + 1] end
  function R.ValidatePtr2(_, ptr) return valid[ptr] == true end
  function R.GetTrackName(track) return true, track.name end
  function R.GetMediaTrackInfo_Value(track, key)
    assert(key == 'IP_TRACKNUMBER')
    return track.number + 0.0
  end

  function R.TrackFX_GetCount(track) return #track.fx end
  function R.TrackFX_GetFXGUID(track, i) local fx = get(track, i) return fx and fx.guid end
  function R.TrackFX_GetFXName(track, i) return true, get(track, i).name end
  function R.TrackFX_GetNumParams(track, i) return #get(track, i).values + 1 end
  function R.TrackFX_GetParamName(_, _, p) return true, 'Param ' .. p end

  function R.TrackFX_GetParamNormalized(track, i, p)
    R.reads = R.reads + 1
    return get(track, i).values[p]
  end

  function R.TrackFX_SetParamNormalized(track, i, p, value)
    local fx = get(track, i)
    R.writes = R.writes + 1
    if not fx.readonly[p] then fx.values[p] = quantized(fx, p, value) end
    R.touched = { track = track, fx = i, param = p } -- like REAPER, any API write counts as a touch
    if R.undoBlocks[#R.undoBlocks] == 'open' then R.undoTouched = R.touched end
    return true
  end

  local function encodeChunk(fx)
    local parts = {}
    for p = 0, #fx.values do parts[#parts + 1] = tostring(fx.values[p]) end
    return tostring(fx.hidden) .. ';' .. table.concat(parts, ',')
  end

  function R.TrackFX_GetNamedConfigParm(track, i, name)
    local fx = get(track, i)
    if name == 'fx_type' then return true, fx.type end
    if name == 'fx_ident' then return true, fx.ident end
    if name == 'fx_name' then return true, fx.name end
    if name == 'vst_chunk' and fx.type:match('^VST') then
      R.chunkReads = (R.chunkReads or 0) + 1
      return true, encodeChunk(fx)
    end
    local p = name:match('^param%.(%d+)%.automatable$')
    if p then return true, fx.readonly[tonumber(p)] and '0' or '1.0' end
    return false, ''
  end

  function R.TrackFX_SetNamedConfigParm(track, i, name, value)
    local fx = get(track, i)
    if name ~= 'vst_chunk' or not fx.type:match('^VST') then return false end
    R.chunkWrites = (R.chunkWrites or 0) + 1
    local hidden, list = value:match('^(.-);(.*)$')
    fx.hidden = hidden
    local p = 0
    for v in list:gmatch('[^,]+') do fx.values[p] = tonumber(v) p = p + 1 end
    return true
  end

  function R.GetTouchedOrFocusedFX(mode)
    local t = mode == 0 and R.touched or R.focused
    if not t then return false end
    local trackIdx = t.track == master and -1 or t.track.number - 1
    return true, trackIdx, -1, -1, t.fx, t.param or 0
  end

  function R.Undo_BeginBlock2() R.undoBlocks[#R.undoBlocks + 1] = 'open' R.undoTouched = nil end
  function R.Undo_EndBlock2(_, desc)
    R.undoBlocks[#R.undoBlocks] = desc
    -- Like REAPER: closing an undo block marks the last FX changed inside it as last touched.
    if R.undoTouched then R.touched = R.undoTouched end
  end
  function R.PreventUIRefresh() end

  function R.GetProjExtState(_, ext, key) local v = R.extState[ext .. '/' .. key] return v and 1 or 0, v or '' end
  function R.SetProjExtState(_, ext, key, value) R.extState[ext .. '/' .. key] = value return 1 end

  return R
end

return Mock
