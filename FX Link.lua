-- @description FX Link: copy settings between plugin instances, or keep them in sync
-- @author migstopheles
-- @version 0.1.0
-- @changelog
--   Initial release
-- @provides
--   [main] FX Link - Diagnostics.lua
--   fxlink/*.lua
-- @link Repository https://github.com/migstopheles/reaper-fx-link
-- @about
--   # FX Link
--
--   Link instances of the same plugin, e.g. on double-tracked parts panned hard left/right.
--   With Sync on, changing any linked instance changes all of them. Or copy settings one-off.
--
--   - Works with VST, VST3, CLAP, JSFX and AU plugins
--   - Two-way sync of parameters, including automation and presets
--   - Optional sync of internal state, for plugins whose knobs are not parameters
--   - Per-group parameter exclusions (e.g. keep each side's pan)
--   - Groups are saved in the project
--
--   Requires REAPER 7 and the ReaImGui extension (0.10 or newer, available via ReaPack).
--   Sync runs while the FX Link window is open.

local R = reaper

if not R.ImGui_GetBuiltinPath then
  R.ShowMessageBox('FX Link needs the ReaImGui extension.\n\n' ..
                   'Install it (e.g. via ReaPack: Extensions > ReaPack > Browse packages > ReaImGui) ' ..
                   'and restart REAPER.', 'FX Link', 0)
  return
end

local scriptDir = debug.getinfo(1, 'S').source:match('^@?(.*[\\/])') or ''
package.path = R.ImGui_GetBuiltinPath() .. '/?.lua;' .. scriptDir .. '?.lua;' .. package.path

local ImGui = require 'imgui' '0.10'
local Model = require 'fxlink.model'
local Engine = require 'fxlink.engine'
local UI = require 'fxlink.ui'

local ctx = ImGui.CreateContext('FX Link')
local ui = UI.new(ImGui, ctx)
local model, engine

-- Groups belong to a project: reload them when you switch project tabs or open another project.
local function syncWithCurrentProject()
  local proj, path = R.EnumProjects(-1)
  if not model or model.proj ~= proj or model.path ~= path then
    model = Model.load(R, proj, path)
    engine = Engine.new(R, model)
  end
end

-- Show the action as "on" in toolbars/menus while the script runs.
local _, _, sectionId, commandId = R.get_action_context()
local function setToggleState(state)
  if commandId and commandId > 0 then
    R.SetToggleCommandState(sectionId, commandId, state)
    R.RefreshToolbar2(sectionId, commandId)
  end
end
setToggleState(1)
R.SetExtState('FXLink', 'running', '1', false)
R.atexit(function()
  setToggleState(0)
  R.DeleteExtState('FXLink', 'running', false)
end)

local function loop()
  syncWithCurrentProject()
  engine:tick()

  ImGui.SetNextWindowSize(ctx, 600, 480, ImGui.Cond_FirstUseEver)
  local visible, open = ImGui.Begin(ctx, 'FX Link', true)
  if visible then
    ui:draw(model, engine)
    ImGui.End(ctx)
  end

  if open then R.defer(loop) end
end

R.defer(loop)
