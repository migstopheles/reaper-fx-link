-- @noindex
-- Link groups and their persistence.
--
-- Groups are stored in the REAPER project itself (project "ext state"), so they are saved,
-- loaded and shared along with the .rpp file. Each group links instances of one plugin:
--
--   {
--     id       = 1,
--     name     = "Gtr doubles",
--     sync     = true,                -- keep members in sync continuously
--     syncState = false,              -- also sync internal (non-parameter) plugin state
--     ident    = "<plugin identifier>",
--     plugin   = "Pro-Q 4",           -- display name of the plugin
--     members  = { "{FX-GUID}", ... },
--     excluded = { [12] = true, ... } -- parameter indices that are never synced/copied
--   }

local Model = {}
Model.__index = Model

local EXT_NAME = 'FXLink'
local EXT_KEY = 'groups'

local function serialize(value)
  local kind = type(value)

  if kind == 'table' then
    local parts = {}
    for k, v in pairs(value) do
      local key = type(k) == 'string' and ('[%q]'):format(k) or ('[%d]'):format(k)
      parts[#parts + 1] = key .. '=' .. serialize(v)
    end
    table.sort(parts)
    return '{' .. table.concat(parts, ',') .. '}'
  elseif kind == 'string' then
    return ('%q'):format(value)
  elseif kind == 'number' then
    return math.type(value) == 'integer' and tostring(value) or ('%.17g'):format(value)
  elseif kind == 'boolean' then
    return tostring(value)
  end

  error('cannot serialize a ' .. kind)
end

local function deserialize(text)
  -- An empty environment means the stored text can only build plain data, not call anything.
  local chunk = load('return ' .. text, 'FXLink data', 't', {})
  if not chunk then return nil end

  local ok, result = pcall(chunk)
  return ok and type(result) == 'table' and result or nil
end

local function sanitizeGroup(raw, fallbackId)
  local group = {
    id = math.tointeger(raw.id) or fallbackId,
    name = type(raw.name) == 'string' and raw.name or ('Group ' .. fallbackId),
    sync = raw.sync ~= false,
    syncState = raw.syncState == true,
    ident = type(raw.ident) == 'string' and raw.ident or nil,
    plugin = type(raw.plugin) == 'string' and raw.plugin or nil,
    members = {},
    excluded = {},
    rev = 0, -- runtime only: bumped whenever membership/exclusions change
  }

  for _, guid in ipairs(type(raw.members) == 'table' and raw.members or {}) do
    if type(guid) == 'string' then group.members[#group.members + 1] = guid end
  end

  for param, flag in pairs(type(raw.excluded) == 'table' and raw.excluded or {}) do
    if math.tointeger(param) and flag then group.excluded[math.tointeger(param)] = true end
  end

  return group
end

function Model.load(R, proj, path)
  local self = setmetatable({ R = R, proj = proj, path = path, groups = {}, nextId = 1 }, Model)

  local _, stored = R.GetProjExtState(proj, EXT_NAME, EXT_KEY)
  local data = stored ~= '' and deserialize(stored) or nil

  for i, raw in ipairs(data and type(data.groups) == 'table' and data.groups or {}) do
    if type(raw) == 'table' then
      local group = sanitizeGroup(raw, i)
      self.groups[#self.groups + 1] = group
      self.nextId = math.max(self.nextId, group.id + 1)
    end
  end

  return self
end

function Model:save()
  local groups = {}

  for _, g in ipairs(self.groups) do
    groups[#groups + 1] = {
      id = g.id, name = g.name, sync = g.sync, syncState = g.syncState, ident = g.ident, plugin = g.plugin,
      members = g.members, excluded = g.excluded,
    }
  end

  self.R.SetProjExtState(self.proj, EXT_NAME, EXT_KEY, serialize({ version = 1, groups = groups }))
end

-- Call after changing membership or exclusions: invalidates the engine's caches and saves.
function Model:changed(group)
  group.rev = group.rev + 1
  self:save()
end

function Model:createGroup(name)
  local group = sanitizeGroup({ id = self.nextId, name = name }, self.nextId)
  self.nextId = self.nextId + 1
  self.groups[#self.groups + 1] = group
  self:save()
  return group
end

function Model:deleteGroup(group)
  for i, g in ipairs(self.groups) do
    if g == group then
      table.remove(self.groups, i)
      self:save()
      return
    end
  end
end

function Model:findGroupOf(guid)
  for _, g in ipairs(self.groups) do
    for _, member in ipairs(g.members) do
      if member == guid then return g end
    end
  end
end

function Model:addMember(group, guid)
  group.members[#group.members + 1] = guid
  self:changed(group)
end

function Model:removeMember(group, guid)
  for i, member in ipairs(group.members) do
    if member == guid then
      table.remove(group.members, i)
      break
    end
  end

  if #group.members == 0 then
    group.ident, group.plugin = nil, nil
  end

  self:changed(group)
end

function Model:setExcluded(group, params, excluded)
  for _, param in ipairs(params) do group.excluded[param] = excluded or nil end
  self:changed(group)
end

Model._serialize = serialize
Model._deserialize = deserialize

return Model
