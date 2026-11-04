-- @noindex
-- The FX Link window (ReaImGui).

local UI = {}
UI.__index = UI

local COLOR_OK = 0x7FD08AFF
local COLOR_ERROR = 0xFF7A6BFF
local COLOR_WARN = 0xFFB347FF
local STATUS_SECONDS = 6

local HELP = [[
1. Open a plugin's window, then click "New group from focused FX".
2. Open another instance of the same plugin and click "Add focused FX"
   (or pick it from the "Add FX..." list). It takes on the group's settings.
3. With Sync on, changing any instance changes all of them.
   With Sync off, use "Copy to others" for one-off copies.

Exclude parameters you want to set per instance (e.g. pan or width).
Groups are saved in the project. Sync runs while this window is open.]]

function UI.new(ImGui, ctx)
  local self = setmetatable({ ImGui = ImGui, ctx = ctx, filters = {}, status = nil }, UI)
  self.clipper = ImGui.CreateListClipper(ctx)
  ImGui.Attach(ctx, self.clipper)
  return self
end

function UI:report(ok, message)
  if message then
    self.status = { ok = ok, message = message, time = reaper.time_precise() }
  end
end

function UI:helpMarker(text)
  local ImGui, ctx = self.ImGui, self.ctx
  ImGui.SameLine(ctx)
  ImGui.TextDisabled(ctx, '(?)')
  if ImGui.IsItemHovered(ctx) then ImGui.SetTooltip(ctx, text) end
end

function UI:draw(model, engine)
  local ImGui, ctx = self.ImGui, self.ctx

  if ImGui.Button(ctx, 'New group from focused FX') then
    local track, fx = engine:focusedFX()
    if not track then
      self:report(false, fx)
    else
      local group = model:createGroup('Group ' .. model.nextId)
      local ok, message = engine:addMember(group, track, fx)
      if ok then group.name = group.plugin; model:save() else model:deleteGroup(group) end
      self:report(ok, ok and ('Created a group for %s. Now add another instance.'):format(group.plugin) or message)
    end
  end

  ImGui.SameLine(ctx)
  if ImGui.Button(ctx, 'New empty group') then model:createGroup('Group ' .. model.nextId) end
  self:helpMarker(HELP)

  if self.status and reaper.time_precise() - self.status.time < STATUS_SECONDS then
    ImGui.TextColored(ctx, self.status.ok and COLOR_OK or COLOR_ERROR, self.status.message)
  else
    ImGui.TextDisabled(ctx, 'Sync runs while this window is open.')
  end

  ImGui.Separator(ctx)

  if #model.groups == 0 then
    ImGui.Spacing(ctx)
    ImGui.TextWrapped(ctx, HELP)
    return
  end

  -- Iterate over a copy: buttons below may delete groups.
  local groups = { table.unpack(model.groups) }
  for _, group in ipairs(groups) do
    ImGui.PushID(ctx, tostring(group.id))
    self:drawGroup(model, engine, group)
    ImGui.PopID(ctx)
    ImGui.Spacing(ctx)
  end
end

function UI:drawGroup(model, engine, group)
  local ImGui, ctx = self.ImGui, self.ctx

  ImGui.SeparatorText(ctx, group.plugin or 'Empty group')

  local changed, sync = ImGui.Checkbox(ctx, 'Sync', group.sync)
  if changed then
    group.sync = sync
    model:changed(group)
    engine:invalidate(group)
  end

  ImGui.SameLine(ctx)
  ImGui.SetNextItemWidth(ctx, 220)
  local renamed, name = ImGui.InputTextWithHint(ctx, '##name', 'Group name', group.name)
  if renamed then
    group.name = name
    model:save()
  end

  ImGui.SameLine(ctx)
  if ImGui.SmallButton(ctx, 'Delete group') then
    model:deleteGroup(group)
    engine:invalidate(group)
    self:report(true, 'Group deleted. The plugins themselves are unchanged.')
    return
  end

  ImGui.BeginDisabled(ctx, not group.sync)
  local stateChanged, syncState = ImGui.Checkbox(ctx, 'Also sync internal state', group.syncState)
  if stateChanged then
    group.syncState = syncState
    model:save()
  end
  if ImGui.IsItemHovered(ctx, ImGui.HoveredFlags_AllowWhenDisabled) then
    ImGui.SetTooltip(ctx,
      'For plugins whose knobs are not exposed as automatable parameters (e.g. Two Notes Genome,\n' ..
      'many amp sims). Edits made in the focused plugin window are copied to the other instances\n' ..
      'about half a second after you stop adjusting. Reloading a plugin\'s state can cause a short\n' ..
      'audio glitch on the other instances. VST, VST3 and CLAP only.')
  end
  ImGui.EndDisabled(ctx)

  local diverged = group.sync and engine:divergedCount(group) or 0
  if diverged > 0 then
    ImGui.TextColored(ctx, COLOR_WARN,
      ('%d parameter%s differ between instances. Click "Copy to others" on the one to keep.')
        :format(diverged, diverged == 1 and '' or 's'))
  end

  self:drawMembers(model, engine, group)
  self:drawAddControls(engine, group)
  self:drawExclusions(model, engine, group)
end

function UI:drawMembers(model, engine, group)
  local ImGui, ctx = self.ImGui, self.ctx

  if #group.members == 0 then
    ImGui.TextDisabled(ctx, 'No instances yet.')
    return
  end

  local flags = ImGui.TableFlags_RowBg | ImGui.TableFlags_BordersInnerV
  if not ImGui.BeginTable(ctx, 'members', 3, flags) then return end

  ImGui.TableSetupColumn(ctx, 'Track', ImGui.TableColumnFlags_WidthStretch, 1)
  ImGui.TableSetupColumn(ctx, 'FX', ImGui.TableColumnFlags_WidthStretch, 1.4)
  ImGui.TableSetupColumn(ctx, '', ImGui.TableColumnFlags_WidthFixed)
  ImGui.TableHeadersRow(ctx)

  local members = { table.unpack(group.members) }
  for _, guid in ipairs(members) do
    local info = engine:describe(guid)
    ImGui.PushID(ctx, guid)
    ImGui.TableNextRow(ctx)

    ImGui.TableNextColumn(ctx)
    ImGui.AlignTextToFramePadding(ctx)
    if info then ImGui.Text(ctx, info.trackLabel) else ImGui.TextDisabled(ctx, 'Missing') end

    ImGui.TableNextColumn(ctx)
    if info then
      ImGui.Text(ctx, info.fxName)
    else
      ImGui.TextDisabled(ctx, 'FX was deleted or moved to another project')
    end

    ImGui.TableNextColumn(ctx)
    ImGui.BeginDisabled(ctx, not info)
    if ImGui.SmallButton(ctx, 'Open') then reaper.TrackFX_Show(info.track, info.fx, 3) end
    ImGui.SameLine(ctx)
    ImGui.BeginDisabled(ctx, #group.members < 2)
    if ImGui.SmallButton(ctx, 'Copy to others') then
      self:report(engine:copyFrom(group, guid))
    end
    if ImGui.IsItemHovered(ctx, ImGui.HoveredFlags_AllowWhenDisabled) then
      ImGui.SetTooltip(ctx, 'Copy all settings of this instance to the other instances in the group\n' ..
                            '(excluded parameters are left alone). Can be undone.')
    end
    ImGui.EndDisabled(ctx)
    ImGui.EndDisabled(ctx)
    ImGui.SameLine(ctx)
    if ImGui.SmallButton(ctx, 'Remove') then
      model:removeMember(group, guid)
      self:report(true, 'Removed from group. The plugin itself is unchanged.')
    end

    ImGui.PopID(ctx)
  end

  ImGui.EndTable(ctx)
end

function UI:drawAddControls(engine, group)
  local ImGui, ctx = self.ImGui, self.ctx

  if ImGui.Button(ctx, 'Add focused FX') then
    local track, fx = engine:focusedFX()
    if track then
      self:report(engine:addMember(group, track, fx))
    else
      self:report(false, fx)
    end
  end

  ImGui.SameLine(ctx)
  ImGui.SetNextItemWidth(ctx, 280)
  if ImGui.BeginCombo(ctx, '##add', 'Add FX from project...') then
    local candidates = engine:candidates(group)
    if #candidates == 0 then
      ImGui.TextDisabled(ctx, group.ident and ('No other unlinked %s instances.'):format(group.plugin)
                                           or 'No unlinked FX in this project.')
    end
    for i, c in ipairs(candidates) do
      ImGui.PushID(ctx, tostring(i))
      if ImGui.Selectable(ctx, c.label) then
        self:report(engine:addMember(group, c.track, c.fx))
      end
      ImGui.PopID(ctx)
    end
    ImGui.EndCombo(ctx)
  end
end

function UI:drawExclusions(model, engine, group)
  local ImGui, ctx = self.ImGui, self.ctx

  local count = 0
  for _ in pairs(group.excluded) do count = count + 1 end

  if not ImGui.TreeNode(ctx, ('Excluded parameters (%d)###excluded'):format(count)) then return end

  local names = engine:paramNames(group)
  if not names then
    ImGui.TextDisabled(ctx, 'Add an instance first.')
    ImGui.TreePop(ctx)
    return
  end

  ImGui.SetNextItemWidth(ctx, 220)
  local _, filter = ImGui.InputTextWithHint(ctx, '##filter', 'Search parameters', self.filters[group] or '')
  self.filters[group] = filter

  local needle = filter:lower()
  local shown = {}
  for _, p in ipairs(names) do
    if needle == '' or p.name:lower():find(needle, 1, true) then shown[#shown + 1] = p end
  end

  local shownIndices = {}
  for i, p in ipairs(shown) do shownIndices[i] = p.index end

  ImGui.SameLine(ctx)
  if ImGui.SmallButton(ctx, 'Exclude shown') then model:setExcluded(group, shownIndices, true) end
  ImGui.SameLine(ctx)
  if ImGui.SmallButton(ctx, 'Include shown') then model:setExcluded(group, shownIndices, false) end

  if ImGui.BeginChild(ctx, 'params', 0, 200, ImGui.ChildFlags_Borders) then
    -- Only draw visible rows: some plugins have thousands of parameters.
    ImGui.ListClipper_Begin(self.clipper, #shown)
    while ImGui.ListClipper_Step(self.clipper) do
      local first, last = ImGui.ListClipper_GetDisplayRange(self.clipper)
      for row = first + 1, last do
        local p = shown[row]
        local toggled, excluded = ImGui.Checkbox(ctx, ('%d: %s##%d'):format(p.index + 1, p.name, p.index),
                                                 group.excluded[p.index] == true)
        if toggled then model:setExcluded(group, { p.index }, excluded) end
      end
    end
    ImGui.ListClipper_End(self.clipper)
    ImGui.EndChild(ctx)
  end

  ImGui.TreePop(ctx)
end

return UI
