local _, ns = ...
local Core = ns.Core

-- luacheck: push ignore 113
local C_QuestLog = C_QuestLog
local C_Timer = C_Timer
local CreateColor = CreateColor
local CreateFrame = CreateFrame
local GetTime = GetTime
local InCombatLockdown = InCombatLockdown
local IsShiftKeyDown = IsShiftKeyDown
local wipe = wipe
local UIParent = UIParent
local hooksecurefunc = hooksecurefunc
-- luacheck: pop

local FLAT = "Interface\\Buttons\\WHITE8x8"
local ICON_SIZE = 16     -- quest icons
local TOGGLE_SIZE = 14   -- minimize buttons of titles
local INDENT = 20        -- names and objectives start here (the icons' column)
local DASH_WIDTH = 10    -- the "-" before an objective
local BLOCK_GAP = 8      -- between two quests
local LINE_GAP = 2       -- between two objectives
local SECTION_GAP = 12   -- above a section title
local ZONE_GAP = 10      -- above a zone's name (after the quests of the zone before)
local ZONE_HEIGHT = 16   -- a zone's name, with its line under it
local ZONE_SPACE = 6     -- between a zone's line and its first quest
local ZONE_ICON = 12     -- the minimize button before a zone's name
local BAR_HEIGHT = 10
local LINE_ALPHA = 0.5   -- the line after a zone's name, at its strongest
local DIM_ALPHA = 0.35   -- finished objectives with "Dim"
local STRIKE_ALPHA = 0.6
local STRIKE_TIME = 0.35 -- seconds for the strike to cross a finished objective
local UPDATE_DELAY = 0.1 -- changes come in bursts: drawn once, a moment after
local QUIET_START = 4    -- seconds after loading without animations (the game fills the tracker)
local EDIT_MODE_HEIGHT = 80

local COLORS = {
  title = { 0.75, 0.61, 0 },    -- achievement and recipe names (the game's)
  line = { 0.8, 0.8, 0.8 },
  done = { 0.6, 0.6, 0.6 },
  failed = { 1, 0.2, 0.2 },
  ready = { 0.9, 0.9, 0.9 },
}

----
-- Tracker
--
-- The objective tracker, the addon's own: the game's is hidden and this one
-- draws the tracked quests, achievements and recipes (read in Data.lua), in
-- sections ("Quests"...) that can be minimized. Quests can be grouped by
-- zone. Clicks work like in the game's tracker:
-- - a name: follow the quest (open the achievement, the recipe); Shift:
--   stop tracking it; right click: a menu (with the quest on the map)
-- - a quest's icon: follow it (its arrow on the map and around you)

local frame = Core.frame       -- the tracker: its place, size and fade
local content = Core.content   -- what it shows (scrolls past the highest height)
local fonts = Core.fonts
local function Profile() return Core.db.profile end

-- Minimized sections ("all", "quests", "achievements", "recipes"), per character
local function CollapsedSections()
  Core.db.char.collapsedSections = Core.db.char.collapsedSections or {}
  return Core.db.char.collapsedSections
end

local editing = false -- Edit Mode is open
local enabledAt       -- when the addon started (no animations right after)

----
-- Gliding: what's already shown moves to its new place smoothly (a quest
-- coming in or leaving, a zone opening...) instead of jumping there

local GLIDE_TIME = 0.28
local gliding = {}      -- frame -> true while it moves
local glideAllowed = false -- (set on each build: not right after loading, not with animations off)
local AfterGlide        -- runs once everything is in place (the item buttons follow)
local glider = CreateFrame("Frame")
glider:Hide()

local function EaseOut(k) return 1 - (1 - k) * (1 - k) end

glider:SetScript("OnUpdate", function ()
  local now = GetTime()
  for object in pairs(gliding) do
    local k = math.min(1, (now - object.glideStart) / GLIDE_TIME)
    object.placedY = object.glideFrom + (object.targetY - object.glideFrom) * EaseOut(k)
    object:ClearAllPoints()
    object:SetPoint("TOPLEFT", content, "TOPLEFT", object.slideX or 0, -object.placedY)
    if k >= 1 then gliding[object] = nil end
  end
  if next(gliding) == nil then
    glider:Hide()
    if AfterGlide then AfterGlide() end
  end
end)

-- Puts a frame `y` from the top of the content, gliding if it was shown
local function Glide(object, y)
  object.targetY = y
  if not glideAllowed or object.placedY == nil or math.abs(object.placedY - y) < 0.5 then
    if not gliding[object] then
      object.placedY = y
      object:ClearAllPoints()
      object:SetPoint("TOPLEFT", content, "TOPLEFT", object.slideX or 0, -y)
    end
    if not glideAllowed then gliding[object] = nil end
    return
  end
  object.glideFrom, object.glideStart = object.placedY, GetTime()
  gliding[object] = true
  glider:Show()
end

----
-- Pools: frames are kept by what they show (a quest keeps its frame while
-- it's shown, so its animations carry on) and reused when it goes

local function Pool(create, release)
  return { used = {}, previous = {}, free = {}, create = create, release = release }
end

local function Begin(pool)
  pool.previous, pool.used = pool.used, pool.previous
  wipe(pool.used)
end

local function Acquire(pool, key, ...)
  local object = pool.previous[key]
  if object then
    pool.previous[key] = nil
  else
    object = table.remove(pool.free) or pool.create(...)
  end
  pool.used[key] = object
  object:Show()
  return object
end

local function Finish(pool)
  for key, object in pairs(pool.previous) do
    pool.previous[key] = nil
    gliding[object] = nil
    local function Release()
      object:Hide()
      if pool.release then pool.release(object) end
      object.placedY = nil
      table.insert(pool.free, object)
    end
    -- (some leave with an animation first: a quest turned in)
    if not (pool.leave and pool.leave(object, Release)) then Release() end
  end
end

----
-- Titles: the tracker's ("Objectives") and each section's, with a minimize
-- button on the right

local function UpdateHeaderColor(header)
  local r, g, b = Core:TitleColor()
  if header.hover then r, g, b = Core.Lighter(r, g, b) end
  header.text:SetTextColor(r, g, b)
  Core.ColorIcon(header.toggle, header.hover)
end

local headers = Pool(function ()
  local header = CreateFrame("Button", nil, content)
  header:RegisterForClicks("LeftButtonUp")
  header.text = header:CreateFontString(nil, "OVERLAY")
  header.text:SetFontObject(fonts.header)
  header.text:SetPoint("LEFT", 0, 0)
  header.text:SetWordWrap(false)
  header.toggle = CreateFrame("Frame", nil, header)
  header.toggle:SetSize(TOGGLE_SIZE + 2, TOGGLE_SIZE + 2)
  header.toggle:SetPoint("RIGHT", 0, 0)
  Core.CreateIcon(header.toggle, TOGGLE_SIZE)
  header:SetScript("OnClick", function (self)
    local collapsed = CollapsedSections()
    collapsed[self.key] = not collapsed[self.key] or nil
    Core:Changed("layout")
  end)
  header:SetScript("OnEnter", function (self) self.hover = true; UpdateHeaderColor(self) end)
  header:SetScript("OnLeave", function (self) self.hover = false; UpdateHeaderColor(self) end)
  return header
end)

local function PlaceHeader(key, text, y)
  local header = Acquire(headers, key)
  header.key = key
  local height = Profile().headerFontSize + 6
  Glide(header, y)
  header:SetSize(content:GetWidth(), height)
  header.text:SetWidth(content:GetWidth() - TOGGLE_SIZE - 6)
  header.text:SetText(text)
  Core.SetIcon(header.toggle, CollapsedSections()[key] and "expand" or "collapse")
  UpdateHeaderColor(header)
  return header, height
end

----
-- Zone separators: each zone's name above its quests, with the minimize
-- button right before it ("- Westfall") and a thin line under it fading out
-- to the right. Minimized zones are listed under the last quest, dimmer,
-- with a plus and how many quests they hide ("+ Redridge (3)").

local function UpdateZoneColor(label)
  local r, g, b = Core:TitleColor()
  local alpha = label.collapsed and 0.6 or 0.85
  if label.hover then
    r, g, b = Core.Lighter(r, g, b)
    alpha = 1
  end
  label.text:SetTextColor(r, g, b, alpha)
  label.gftIcon:SetVertexColor(r, g, b, 1)
  label.line:SetGradient("HORIZONTAL", CreateColor(r, g, b, LINE_ALPHA), CreateColor(r, g, b, 0))
end

local zones = Pool(function ()
  local label = CreateFrame("Button", nil, content)
  label:RegisterForClicks("LeftButtonUp")
  label.icon = CreateFrame("Frame", nil, label)
  label.icon:SetSize(ZONE_ICON, ZONE_ICON)
  label.icon:SetPoint("LEFT", label, "LEFT", 2, 1)
  Core.CreateIcon(label.icon, ZONE_ICON)
  -- (the label colors the icon itself)
  label.gftIcon = label.icon.gftIcon
  label.text = label:CreateFontString(nil, "OVERLAY")
  label.text:SetFontObject(fonts.line)
  label.text:SetPoint("LEFT", label.icon, "RIGHT", 3, 0)
  label.text:SetWordWrap(false)
  label.line = label:CreateTexture(nil, "ARTWORK")
  label.line:SetTexture(FLAT)
  Core.PixelHeight(label.line, 1)
  label.line:SetPoint("BOTTOMLEFT", label, "BOTTOMLEFT", 0, 0)
  label.line:SetPoint("BOTTOMRIGHT", label, "BOTTOMRIGHT", 0, 0)
  label:SetScript("OnClick", function (self) Core.SetZoneCollapsed(self.zone, not self.collapsed) end)
  label:SetScript("OnEnter", function (self) self.hover = true; UpdateZoneColor(self) end)
  label:SetScript("OnLeave", function (self) self.hover = false; UpdateZoneColor(self) end)
  return label
end)

-- A zone's separator, `y` from the top: returns the room it takes (with the
-- space under it, before its first quest)
local function PlaceZone(entry, y, collapsed)
  local label = Acquire(zones, entry.key)
  label.zone, label.collapsed = entry.zone, collapsed
  local height = math.max(ZONE_HEIGHT, Profile().lineFontSize + 4)
  Glide(label, y)
  label:SetSize(content:GetWidth(), height)
  Core.SetIcon(label.icon, collapsed and "expand" or "collapse")
  -- (the line only under open zones: the minimized ones are a plain list)
  label.line:SetShown(not collapsed)
  label.text:SetWidth(content:GetWidth() - ZONE_ICON - 8)
  if collapsed then
    label.text:SetText(entry.zone.." |cff999999("..entry.count..")|r")
  else
    label.text:SetText(entry.zone)
  end
  UpdateZoneColor(label)
  return collapsed and height or height + ZONE_SPACE
end

----
-- Quests, achievements and recipes: a name and the lines under it

local function SetCheck(texture)
  if texture.SetAtlas and pcall(texture.SetAtlas, texture, "ui-questtracker-tracker-check")
    and texture.GetAtlas and texture:GetAtlas() then
    return
  end
  texture:SetTexture("Interface\\RaidFrame\\ReadyCheck-Ready")
end

local function CreateLine(block)
  local line = CreateFrame("Frame", nil, block)
  line.dash = line:CreateFontString(nil, "OVERLAY")
  line.dash:SetFontObject(fonts.line)
  line.dash:SetPoint("TOPLEFT", 0, 0)
  line.dash:SetText("-")
  line.check = line:CreateTexture(nil, "OVERLAY")
  line.check:SetSize(12, 12)
  SetCheck(line.check)
  line.text = line:CreateFontString(nil, "OVERLAY")
  line.text:SetFontObject(fonts.line)
  line.text:SetPoint("TOPLEFT", DASH_WIDTH, 0)
  line.text:SetJustifyH("LEFT")
  line.text:SetWordWrap(true)
  line.strike = line:CreateTexture(nil, "OVERLAY", nil, 7)
  line.strike:SetTexture(FLAT)
  Core.PixelHeight(line.strike, 1)
  line.strike:Hide()
  return line
end

local function Bar(line)
  if line.bar then return line.bar end
  local bar = CreateFrame("StatusBar", nil, line)
  bar:SetStatusBarTexture(FLAT)
  bar:SetMinMaxValues(0, 100)
  bar.background = bar:CreateTexture(nil, "BACKGROUND")
  bar.background:SetAllPoints()
  bar.background:SetColorTexture(0, 0, 0, 0.5)
  bar.label = bar:CreateFontString(nil, "OVERLAY")
  bar.label:SetFontObject(fonts.zone)
  bar.label:SetPoint("CENTER")
  line.bar = bar
  return bar
end

local function UpdateTitleColor(block)
  local entry = block.entry
  local r, g, b
  if entry.kind == "quest" then
    r, g, b = Core.QuestColor(entry.id, entry.level)
  else
    r, g, b = Core:Color(Profile().questNameColor)
    if not r then r, g, b = COLORS.title[1], COLORS.title[2], COLORS.title[3] end
  end
  if block.hover then
    r, g, b = Core.Lighter(r, g, b, 0.4)
  elseif entry.super then
    r, g, b = Core.Lighter(r, g, b, 0.25)
  end
  block.title:SetTextColor(r, g, b)
end

local function UpdatePoi(block)
  local poi = block.poi
  Core.SetIcon(poi, block.entry.complete and "questComplete" or "questProgress")
  Core.ColorIcon(poi, block.entry.super)
  -- A quest ready to turn in: its "?" pulses gently until it's turned in
  Core.AnimateIcon(poi, "pulse", block.entry.complete and Core:Animates())
end

local ClickEntry, ClickPoi, Focus -- below

local blocks = Pool(function ()
  local block = CreateFrame("Button", nil, content)
  block:RegisterForClicks("LeftButtonUp", "RightButtonUp")
  block.title = block:CreateFontString(nil, "OVERLAY")
  block.title:SetFontObject(fonts.header)
  block.title:SetPoint("TOPLEFT", INDENT, 0)
  block.title:SetJustifyH("LEFT")
  block.title:SetWordWrap(true)
  block.poi = CreateFrame("Button", nil, block)
  block.poi:SetSize(ICON_SIZE + 2, ICON_SIZE + 2)
  block.poi:RegisterForClicks("LeftButtonUp")
  Core.CreateIcon(block.poi, ICON_SIZE)
  block.poi:SetScript("OnClick", function () ClickPoi(block) end)
  block.poi:SetScript("OnEnter", function (self) self.gftHover = true; Core.ColorIcon(self, block.entry.super) end)
  block.poi:SetScript("OnLeave", function (self) self.gftHover = false; Core.ColorIcon(self, block.entry.super) end)
  block.lines = Pool(function () return CreateLine(block) end, function (line)
    line.strike:Hide()
    line.gftAnimating = nil
    line:SetAlpha(1)
  end)
  block:SetScript("OnClick", function (self, button) ClickEntry(self, button) end)
  block:SetScript("OnEnter", function (self) self.hover = true; UpdateTitleColor(self) end)
  block:SetScript("OnLeave", function (self) self.hover = false; UpdateTitleColor(self) end)
  return block
end, function (block)
  Focus(block, false)
  block.id, block.entry = nil, nil
  block:SetAlpha(1)
  block.gftFading = nil
  Core.ResetIcon(block.poi)
  block.slideX = nil
end)

-- The strike across a finished objective, drawn from left to right when it
-- has just been finished
local striking = {} -- strike -> start time
local striker = CreateFrame("Frame")
striker:Hide()
striker:SetScript("OnUpdate", function ()
  local now = GetTime()
  for strike, start in pairs(striking) do
    local k = math.min(1, (now - start) / STRIKE_TIME)
    k = k * k * (3 - 2 * k)
    strike:SetWidth(math.max(0.1, strike.fullWidth * k))
    if k >= 1 then striking[strike] = nil end
  end
  if next(striking) == nil then striker:Hide() end
end)

-- One line, `y` from the block's top: returns its height
local function PlaceLine(block, data, y, width, justDone)
  local line = Acquire(block.lines, data.key)
  line.data = data
  local profile = Profile()
  line:ClearAllPoints()
  line:SetPoint("TOPLEFT", block, "TOPLEFT", INDENT, -y)
  local textWidth = width - INDENT - DASH_WIDTH
  line.text:SetWidth(textWidth)
  line.text:SetText(data.text)
  local textHeight = math.max(profile.lineFontSize, line.text:GetStringHeight() or 0)

  local color = (data.failed and COLORS.failed) or (data.done and COLORS.done)
    or (data.ready and COLORS.ready) or COLORS.line
  line.text:SetTextColor(color[1], color[2], color[3])
  line.dash:SetTextColor(color[1], color[2], color[3])
  line.dash:SetShown(not data.done and not data.plain)
  line.check:SetShown(data.done and true or false)
  if data.done then
    line.check:ClearAllPoints()
    line.check:SetPoint("CENTER", line, "TOPLEFT", 3, -profile.lineFontSize / 2)
  end

  -- Strike
  local strikeWidth = math.min(line.text:GetStringWidth() or 0, textWidth)
  if data.done and profile.strikeCompleted and strikeWidth > 0 then
    local strike = line.strike
    strike:ClearAllPoints()
    strike:SetPoint("LEFT", line.text, "LEFT", 0, 0)
    strike:SetVertexColor(1, 1, 1, STRIKE_ALPHA)
    strike.fullWidth = strikeWidth
    if justDone and Core:Animates() then
      strike:SetWidth(0.1)
      striking[strike] = GetTime()
      striker:Show()
    elseif not striking[strike] then
      strike:SetWidth(strikeWidth)
    end
    strike:Show()
  else
    striking[line.strike] = nil
    line.strike:Hide()
  end

  -- Progress bar
  local height = textHeight
  if data.bar then
    local bar = Bar(line)
    bar:ClearAllPoints()
    bar:SetPoint("TOPLEFT", line, "TOPLEFT", DASH_WIDTH, -(textHeight + 3))
    bar:SetSize(math.min(textWidth, 180), BAR_HEIGHT)
    bar:SetValue(data.bar)
    bar.label:SetText(math.floor(data.bar).."%")
    if profile.glassBars then
      bar:SetStatusBarColor(Core:TitleColor())
    else
      bar:SetStatusBarColor(0.26, 0.65, 0.3)
    end
    bar:Show()
    height = height + 3 + BAR_HEIGHT
  elseif line.bar then
    line.bar:Hide()
  end

  line:SetSize(width - INDENT, height)
  if not line.gftAnimating then
    line:SetAlpha(data.done and profile.completedObjectives == "dim" and DIM_ALPHA or 1)
  end
  return height
end

----
-- The quest you follow stands out: a soft band of the title color behind
-- it fading out to the right, a thin line along its left side, and a light
-- breathing slowly around its icon. They come in softly when you start
-- following it (the line grows from its middle).

local FOCUS_IN = 0.35
local focusing = {} -- block -> start time of its focus coming in
local focuser = CreateFrame("Frame")
focuser:Hide()
focuser:SetScript("OnUpdate", function ()
  local now = GetTime()
  for block, start in pairs(focusing) do
    local k = math.min(1, (now - start) / FOCUS_IN)
    local e = k * k * (3 - 2 * k)
    block.focusBand:SetAlpha(e)
    block.focusLine:SetHeight(math.max(0.1, block.focusHeight * e))
    if k >= 1 then focusing[block] = nil end
  end
  if next(focusing) == nil then focuser:Hide() end
end)

local function FocusParts(block)
  if block.focusBand then return end
  block.focusBand = block:CreateTexture(nil, "BACKGROUND")
  block.focusBand:SetTexture(FLAT)
  block.focusLine = block:CreateTexture(nil, "ARTWORK")
  block.focusLine:SetTexture(FLAT)
  block.focusLine:SetWidth(2)
  block.focusHalo = Core.Smooth(block:CreateTexture(nil, "ARTWORK"))
  block.focusHalo:SetTexture(Core.ASSETS.."circleSoft")
  block.focusHalo:SetBlendMode("ADD")
  block.focusHalo:SetSize(ICON_SIZE * 2.6, ICON_SIZE * 2.6)
  block.focusHalo:SetPoint("CENTER", block.poi, "CENTER")
  -- (the halo breathes: brighter, then fainter, over and over)
  local breath = block.focusHalo:CreateAnimationGroup()
  breath:SetLooping("BOUNCE")
  local alpha = breath:CreateAnimation("Alpha")
  alpha:SetFromAlpha(0.35)
  alpha:SetToAlpha(0.8)
  alpha:SetDuration(1.1)
  alpha:SetSmoothing("IN_OUT")
  block.focusBreath = breath
end

function Focus(block, on, height)
  if not on then
    if block.focusBand then
      focusing[block] = nil
      block.focusBand:Hide()
      block.focusLine:Hide()
      block.focusHalo:Hide()
      block.focusBreath:Stop()
    end
    block.focused = false
    return
  end
  FocusParts(block)
  local r, g, b = Core:TitleColor()
  block.focusBand:ClearAllPoints()
  block.focusBand:SetPoint("TOPLEFT", block, "TOPLEFT", -6, 3)
  block.focusBand:SetPoint("BOTTOMRIGHT", block, "BOTTOMRIGHT", 4, -3)
  block.focusBand:SetGradient("HORIZONTAL", CreateColor(r, g, b, 0.16), CreateColor(r, g, b, 0))
  block.focusHeight = height + 6
  block.focusLine:ClearAllPoints()
  block.focusLine:SetPoint("LEFT", block, "LEFT", -6, 0)
  block.focusLine:SetVertexColor(r, g, b, 0.9)
  block.focusHalo:SetVertexColor(r, g, b)
  block.focusBand:Show()
  block.focusLine:Show()
  block.focusHalo:SetShown(block.poi:IsShown())
  if not block.focusBreath:IsPlaying() then block.focusBreath:Play() end
  -- Just started following it: its focus comes in
  if not block.focused and Core:Animates() then
    block.focusBand:SetAlpha(0)
    block.focusLine:SetHeight(0.1)
    focusing[block] = GetTime()
    focuser:Show()
  elseif not focusing[block] then
    block.focusBand:SetAlpha(1)
    block.focusLine:SetHeight(block.focusHeight)
  end
  block.focused = true
end

-- A quest (or achievement, recipe), `y` from the top: returns its height
local function PlaceBlock(entry, y, changes)
  local block = Acquire(blocks, entry.key)
  block.entry, block.id = entry, entry.id
  local width = content:GetWidth()
  Glide(block, y)
  block.title:SetWidth(width - INDENT)
  block.title:SetText(entry.title)
  UpdateTitleColor(block)
  local titleHeight = math.max(Profile().headerFontSize, block.title:GetStringHeight() or 0)

  if entry.kind == "quest" then
    block.poi.questID = entry.id
    block.poi:ClearAllPoints()
    block.poi:SetPoint("CENTER", block, "TOPLEFT", ICON_SIZE / 2 + 1, -Profile().headerFontSize / 2)
    block.poi:Show()
    UpdatePoi(block)
  else
    Core.ResetIcon(block.poi)
    block.poi:Hide()
  end

  local height = titleHeight
  Begin(block.lines)
  for _, data in ipairs(entry.lines) do
    height = height + LINE_GAP
    local justDone = changes and changes.done and changes.done[data.key]
    height = height + PlaceLine(block, data, height, width, justDone)
  end
  Finish(block.lines)
  block:SetSize(width, height)
  Focus(block, entry.super, height)
  return height, block
end

----
-- Building: what's tracked, compared with what was shown before (for the
-- animations), then laid out

local shown = {}    -- key -> what it showed: { lines = { key -> { text, done } }, complete }
local tracked = {}  -- what was tracked at the last build (key -> true)
local shownSections = {}
local itemBlocks = {}
local WatchCriteria -- below
local ScrollTo -- below
local scrollOffset = 0 -- how far it's scrolled down
local contentHeight -- the whole content's height (more than shows when it scrolls)

local function Snapshot(entry)
  local lines = {}
  for _, data in ipairs(entry.lines) do lines[data.key] = { text = data.text, done = data.done } end
  return { lines = lines, complete = entry.complete }
end

-- What changed on an entry since the last build
local function Changes(entry, before)
  if not before then return nil end
  local changes = { done = {}, progress = {} }
  for _, data in ipairs(entry.lines) do
    local old = before.lines[data.key]
    if old then
      if data.done and not old.done then
        changes.done[data.key] = true
      elseif not data.done and old.text ~= data.text then
        changes.progress[data.key] = true
      end
    end
  end
  changes.completed = entry.complete and not before.complete
  return changes
end

local function Quiet()
  return not enabledAt or GetTime() - enabledAt < QUIET_START or not Core:Animates()
end

local function Build()
  local profile = Profile()
  frame:SetWidth(profile.width)
  Core.SizeContent(profile.width, contentHeight or 1)
  local sections = {
    Core.DungeonSection(),
    Core.QuestSection(),
    Core.AchievementSection(),
    Core.RecipeSection(),
  }

  -- Everything tracked, shown or not (a minimized zone or section): what
  -- shows again later isn't new
  local nowTracked = {}
  for _, questID in ipairs(Core.ShownQuestIDs()) do nowTracked["q"..questID] = true end
  for _, section in ipairs(sections) do
    for _, entry in ipairs(section.entries) do
      if entry.kind ~= "zone" and entry.kind ~= "collapsedZone" then nowTracked[entry.key] = true end
    end
  end

  Begin(headers)
  Begin(zones)
  Begin(blocks)
  wipe(itemBlocks)

  local quiet = Quiet()
  glideAllowed = not quiet and not editing
  local now = GetTime()
  local opened = Core.openedZone and now - Core.openedZone.when < 2 and Core.openedZone.zone
  local events = {} -- animations to start once everything is in place
  local newShown = {}
  local newSections = {}

  local total = 0
  for _, section in ipairs(sections) do total = total + #section.entries end

  local y = 0
  local dungeonShown = false
  local collapsed = CollapsedSections()
  if total > 0 or editing then
    if not profile.hideMainHeader then
      local _, height = PlaceHeader("all", _G.OBJECTIVES_TRACKER_LABEL or "Objectives", y)
      y = y + height
    end
    if not collapsed.all then
      local first = true
      for _, section in ipairs(sections) do
        if section.key == "dungeon" and #section.entries > 0 then
          -- The dungeon: a card of its own, no title (DungeonCard.lua)
          newSections.dungeon = true
          if not first or not profile.hideMainHeader then y = y + (first and 4 or SECTION_GAP) end
          y = y + Core.PlaceDungeonCard(section.entries[1], y, not shownSections.dungeon and not quiet)
          -- (more room after the card than between sections)
          y = y + 8
          dungeonShown = true
          first = false
        elseif #section.entries > 0 then
          newSections[section.key] = true
          if not profile.hideSectionHeaders then
            if not first or not profile.hideMainHeader then y = y + (first and 4 or SECTION_GAP) end
            local header, height = PlaceHeader(section.key, section.title, y)
            y = y + height
            if not shownSections[section.key] and not quiet then
              table.insert(events, { "sectionAdded", header })
            end
          end
          first = false
          if not collapsed[section.key] then
            local previous -- the kind of the entry before
            for _, entry in ipairs(section.entries) do
              local kind = entry.kind
              if kind == "zone" or kind == "collapsedZone" then
                -- (minimized zones' rows follow each other closely)
                if previous then
                  y = y + ((previous == "collapsedZone" and kind == "collapsedZone") and 4 or ZONE_GAP)
                end
                y = y + PlaceZone(entry, y, kind == "collapsedZone")
              else
                -- (right under its zone's name: the room is already there)
                if previous and previous ~= "zone" then y = y + BLOCK_GAP end
                local before = shown[entry.key]
                local changes = Changes(entry, before)
                local height, block = PlaceBlock(entry, y, changes)
                y = y + height
                newShown[entry.key] = Snapshot(entry)
                if entry.item then table.insert(itemBlocks, block) end

                if not quiet then
                  if not before then
                    local isNew = not tracked[entry.key]
                    local back = entry.kind == "quest" and (
                      (Core.rewatched[entry.id] and now - Core.rewatched[entry.id] < 5)
                      or (opened and entry.zone == opened))
                    if isNew and not back then
                      table.insert(events, { "questAdded", block })
                    else
                      table.insert(events, { "questBack", block })
                    end
                  elseif changes then
                    for key in pairs(changes.done) do
                      table.insert(events, { "lineDone", block.lines.used[key] })
                    end
                    for key in pairs(changes.progress) do
                      table.insert(events, { "lineProgress", block.lines.used[key] })
                    end
                    if changes.completed then table.insert(events, { "questComplete", block }) end
                  end
                end
              end
              previous = kind
            end
          end
        end
      end
    end
  end

  Finish(headers)
  Finish(zones)
  Finish(blocks)
  if not dungeonShown then Core.HideDungeonCard() end

  shown, tracked, shownSections = newShown, nowTracked, newSections
  -- Past the highest height (Options), the rest scrolls
  contentHeight = y
  Core.SizeContent(profile.width, y)
  local maxHeight = profile.maxHeight or 0
  local visible = (maxHeight > 0 and y > maxHeight) and maxHeight or y
  -- In Edit Mode the box shows the whole height the tracker can take
  local height = math.max(visible, 1)
  if editing then height = math.max(maxHeight > 0 and maxHeight or visible, EDIT_MODE_HEIGHT) end
  frame:SetHeight(height)
  Core.contentHeight = visible
  Core.background:Update(visible)
  ScrollTo(scrollOffset)
  Core.PlaceItems(itemBlocks)
  -- (and again once what glides is in its new place)
  AfterGlide = function () Core.PlaceItems(itemBlocks) end
  local achievements = 0
  for _, section in ipairs(sections) do
    if section.key == "achievements" then achievements = section.count end
  end
  WatchCriteria(achievements > 0)

  for _, event in ipairs(events) do
    if event[2] then Core:Changed(event[1], event[2]) end
  end
end

----
-- Scrolling: the mouse wheel over the tracker, when there's more than fits

local SCROLL_STEP = 40

function ScrollTo(offset)
  local visible = Core.contentHeight or 0
  local most = math.max(0, (contentHeight or 0) - visible)
  scrollOffset = math.max(0, math.min(most, offset or 0))
  Core.scroll:SetVerticalScroll(scrollOffset)
  -- The wheel is only taken while there's something to scroll (else it
  -- would stop zooming the camera with the mouse over the tracker)
  frame:EnableMouseWheel(most > 0)
end

frame:SetScript("OnMouseWheel", function (_, delta)
  ScrollTo(scrollOffset - delta * SCROLL_STEP)
  -- The item buttons follow (they can't move in a fight: hidden until it ends)
  Core.PlaceItems(itemBlocks)
end)

local scheduled = false
-- Something holding the layout for a moment (an abandoned quest turning to
-- dust in its place): the next build waits for it
local holdUntil = 0
function Core.HoldLayout(seconds)
  holdUntil = math.max(holdUntil, GetTime() + seconds)
end

local function Schedule()
  if scheduled or Core.trackerOn == false then return end
  scheduled = true
  local function Run()
    local wait = holdUntil - GetTime()
    if wait > 0 then
      C_Timer.After(wait, Run)
      return
    end
    scheduled = false
    local ok, problem = pcall(Build)
    if not ok then _G.geterrorhandler()(problem) end
  end
  C_Timer.After(UPDATE_DELAY, Run)
end
Core.Refresh = Schedule

---
-- The block of a quest, if it's shown
function Core.FindBlock(questID)
  return blocks.used["q"..questID]
end

---
-- A title shown (for /qm testanim)
function Core.FirstHeader()
  return headers.used.quests or headers.used.achievements or headers.used.recipes or headers.used.all
end

---
-- Every block shown (for the dust, Dust.lua)
function Core.ShownBlocks()
  return blocks.used
end

----
-- Clicks

local function Untrack(entry)
  if entry.kind == "quest" then
    -- (with every quest showing, it's hidden from the tracker too)
    if Profile().allQuests then Core.HideQuest(entry.id) end
    C_QuestLog.RemoveQuestWatch(entry.id)
  elseif entry.kind == "achievement" then
    local tracking, enum = _G.C_ContentTracking, _G.Enum
    if tracking and tracking.StopTracking and enum and enum.ContentTrackingType then
      tracking.StopTracking(enum.ContentTrackingType.Achievement, entry.id, enum.ContentTrackingStopType.Manual)
    elseif _G.RemoveTrackedAchievement then
      _G.RemoveTrackedAchievement(entry.id)
    end
  elseif entry.kind == "recipe" then
    _G.C_TradeSkillUI.SetRecipeTracked(entry.id, false, entry.recraft)
  end
end

local function Open(entry)
  if entry.kind == "quest" then
    if entry.autoComplete and _G.ShowQuestComplete then
      pcall(_G.ShowQuestComplete, entry.id)
    elseif Core.BookOn() then
      -- (read in the tracker's own window: never the map, see QuestText.lua)
      Core.ShowQuestText(entry.id)
    elseif _G.C_SuperTrack and _G.C_SuperTrack.SetSuperTrackedQuestID then
      -- (the quest book off: followed; the game's map is never opened)
      _G.C_SuperTrack.SetSuperTrackedQuestID(entry.id)
    end
  elseif entry.kind == "achievement" then
    if not _G.AchievementFrame and _G.AchievementFrame_LoadUI then _G.AchievementFrame_LoadUI() end
    if _G.OpenAchievementFrameToAchievement then
      pcall(_G.OpenAchievementFrameToAchievement, entry.id)
    elseif _G.AchievementFrame_SelectAchievement then
      pcall(_G.ShowUIPanel, _G.AchievementFrame)
      pcall(_G.AchievementFrame_SelectAchievement, entry.id)
    end
  elseif entry.kind == "recipe" then
    local TradeSkill = _G.C_TradeSkillUI
    if TradeSkill.OpenRecipe then pcall(TradeSkill.OpenRecipe, entry.id) end
  end
end

local function Link(entry)
  local link
  if entry.kind == "quest" then
    link = _G.GetQuestLink and _G.GetQuestLink(entry.id)
  elseif entry.kind == "achievement" then
    link = _G.GetAchievementLink and _G.GetAchievementLink(entry.id)
  elseif entry.kind == "recipe" then
    local TradeSkill = _G.C_TradeSkillUI
    link = TradeSkill.GetRecipeLink and TradeSkill.GetRecipeLink(entry.id)
  end
  if not link then return false end
  local insert = (_G.ChatFrameUtil and _G.ChatFrameUtil.InsertLink) or _G.ChatEdit_InsertLink
  return insert and insert(link) or false
end

local function Follow(questID)
  local SuperTrack = _G.C_SuperTrack
  if not (SuperTrack and SuperTrack.SetSuperTrackedQuestID) then return end
  if SuperTrack.GetSuperTrackedQuestID() == questID then
    SuperTrack.SetSuperTrackedQuestID(0)
  else
    SuperTrack.SetSuperTrackedQuestID(questID)
    if _G.SOUNDKIT and _G.SOUNDKIT.UI_MAP_WAYPOINT_SUPER_TRACK_ON then
      _G.PlaySound(_G.SOUNDKIT.UI_MAP_WAYPOINT_SUPER_TRACK_ON)
    end
  end
end

local function Abandon(questID)
  if _G.QuestMapQuestOptions_AbandonQuest then
    _G.QuestMapQuestOptions_AbandonQuest(questID)
    return
  end
  C_QuestLog.SetSelectedQuest(questID)
  C_QuestLog.SetAbandonQuest()
  _G.StaticPopup_Show("ABANDON_QUEST", C_QuestLog.GetTitleForQuestID(questID))
end

local function Share(questID)
  if _G.QuestMapQuestOptions_ShareQuest then
    _G.QuestMapQuestOptions_ShareQuest(questID)
    return
  end
  C_QuestLog.SetSelectedQuest(questID)
  if _G.QuestLogPushQuest then _G.QuestLogPushQuest() end
end

-- (for the quest list's menu too, see QuestText.lua)
Core.FollowQuest, Core.AbandonQuest, Core.ShareQuest = Follow, Abandon, Share

local function Menu(block)
  local MenuUtil = _G.MenuUtil
  local entry = block.entry
  if not (MenuUtil and MenuUtil.CreateContextMenu) then return end
  MenuUtil.CreateContextMenu(block, function (_, root)
    root:CreateTitle(entry.title)
    if entry.kind == "quest" then
      root:CreateButton(entry.super and "Stop following" or "Follow", function () Follow(entry.id) end)
      if Core.BookOn() then
        root:CreateButton("Show in quest log", function () Open(entry) end)
        root:CreateButton("Show on map", function () Core.ShowQuestText(entry.id, true) end)
      end
      if C_QuestLog.IsPushableQuest and C_QuestLog.IsPushableQuest(entry.id) and _G.IsInGroup() then
        root:CreateButton("Share", function () Share(entry.id) end)
      end
      root:CreateButton("Stop tracking", function () Untrack(entry) end)
      if C_QuestLog.CanAbandonQuest == nil or C_QuestLog.CanAbandonQuest(entry.id) then
        root:CreateButton("Abandon", function () Abandon(entry.id) end)
      end
    elseif entry.kind == "achievement" then
      root:CreateButton("Open", function () Open(entry) end)
      root:CreateButton("Stop tracking", function () Untrack(entry) end)
    elseif entry.kind == "recipe" then
      root:CreateButton("Open recipe", function () Open(entry) end)
      root:CreateButton("Stop tracking", function () Untrack(entry) end)
    elseif entry.kind == "dungeon" then
      root:CreateButton("Start the run again", Core.RestartDungeonRun)
    end
  end)
end

function ClickEntry(block, button)
  local entry = block.entry
  if not entry then return end
  if button == "RightButton" then
    Menu(block)
    return
  end
  if entry.kind == "dungeon" then return end
  if _G.IsModifiedClick("CHATLINK") and Link(entry) then return end
  if IsShiftKeyDown() then
    Untrack(entry)
    return
  end
  -- A quest: followed (the map, opened by an addon, made the game block
  -- things in it later in a fight). "Read quest" is in its menu.
  if entry.kind == "quest" and not entry.autoComplete then
    Follow(entry.id)
    return
  end
  Open(entry)
end

function ClickPoi(block)
  if block.entry and block.entry.kind == "quest" then Follow(block.entry.id) end
end

----
-- Position: per Edit Mode layout, moved in Edit Mode. The tracker grows
-- down from its top, on the side of the screen it's on.

local layoutName
local DEFAULT = { point = "TOPRIGHT", x = -85, y = -260 }

local function Position()
  local positions = Profile().positions
  return (layoutName and positions[layoutName]) or positions._last or DEFAULT
end

local function ApplyPosition()
  local position = Position()
  frame:ClearAllPoints()
  frame:SetPoint(position.point, UIParent, position.point, position.x, position.y)
  Schedule() -- the item buttons follow
end

-- Where the tracker is now, from its top corner on its side of the screen
local function CurrentPosition()
  local left, right, top = frame:GetLeft(), frame:GetRight(), frame:GetTop()
  local scale = frame:GetEffectiveScale() / UIParent:GetEffectiveScale()
  if not (left and right and top) then return nil end
  local screenWidth, screenTop = UIParent:GetWidth(), UIParent:GetTop()
  left, right, top = left * scale, right * scale, top * scale
  if (left + right) / 2 < screenWidth / 2 then
    return { point = "TOPLEFT", x = left / scale, y = (top - screenTop) / scale }
  end
  return { point = "TOPRIGHT", x = (right - screenWidth) / scale, y = (top - screenTop) / scale }
end

-- The game's tracker's place, for the first time: the new one goes there
local function GamePosition()
  local tracker = _G.ObjectiveTrackerFrame
  local right, top = tracker and tracker:GetRight(), tracker and tracker:GetTop()
  if not right or not top then return nil end
  local scale = tracker:GetEffectiveScale() / UIParent:GetEffectiveScale()
  return {
    point = "TOPRIGHT",
    x = math.floor(right * scale - UIParent:GetWidth() + 0.5),
    y = math.floor(top * scale - UIParent:GetTop() + 0.5),
  }
end

----
-- The game's tracker: hidden (out of combat; it holds protected buttons)

local hiddenParent = CreateFrame("Frame")
hiddenParent:Hide()
local hidePending = false

local function HideGameTracker()
  local tracker = _G.ObjectiveTrackerFrame
  if not tracker then return end
  if InCombatLockdown() then
    hidePending = true
    return
  end
  hidePending = false
  if tracker:GetParent() ~= hiddenParent then
    tracker.gftParent = tracker:GetParent()
    tracker:SetParent(hiddenParent)
  end
end

local function HookGameTracker()
  local tracker = _G.ObjectiveTrackerFrame
  if not tracker or tracker.gftHooked then return end
  tracker.gftHooked = true
  -- The game puts it back in its place now and then (Edit Mode layouts)
  hooksecurefunc(tracker, "SetParent", function (_, parent)
    if parent ~= hiddenParent then C_Timer.After(0, HideGameTracker) end
  end)
end

----
-- Edit Mode

local function SetupEditMode()
  local LEM = LibStub("LibEditMode", true)
  if not LEM then return end
  Core.LEM = LEM
  LEM:AddFrame(frame, function ()
    local position = CurrentPosition()
    if not position then return end
    local positions = Profile().positions
    positions[layoutName or "_last"] = position
    positions._last = position
    ApplyPosition()
  end, DEFAULT, "Questmark")

  LEM:RegisterCallback("layout", function (name)
    layoutName = name
    local positions = Profile().positions
    if name and not positions[name] then
      -- First time with this layout: where the game's tracker is, or the
      -- place used last
      positions[name] = positions._last or GamePosition() or DEFAULT
      positions._last = positions._last or positions[name]
    end
    ApplyPosition()
    HideGameTracker()
  end)
  LEM:RegisterCallback("enter", function ()
    editing = true
    Core.ShowItems(false)
    Core:Changed("editMode", true)
    Schedule()
  end)
  LEM:RegisterCallback("exit", function ()
    editing = false
    Core.ShowItems(true)
    Core:Changed("editMode", false)
    Schedule()
  end)
  Core:Changed("editModeReady")
end

function Core.InEditMode()
  return editing
end

----
-- Events

local events = CreateFrame("Frame")
local criteriaWatched = false

events:SetScript("OnEvent", function (_, event, ...)
  if event == "PLAYER_REGEN_ENABLED" then
    if hidePending then HideGameTracker() end
    return
  elseif event == "QUEST_WATCH_UPDATE" then
    Core.OpenZoneOf((...))
  elseif event == "QUEST_TURNED_IN" then
    -- The quest leaves first (the light over its name, then out to the
    -- right), and the tracker waits for it: then what's under it glides up
    -- into its place, without going over it
    local questID = ...
    local block = questID and Core.FindBlock(questID)
    if block and block:IsVisible() and Core:Animates() and Core.QuestLeaving then
      Core.HoldLayout(0.8)
      Core.QuestLeaving(block, function () end)
    end
  elseif event == "QUEST_WATCH_LIST_CHANGED" then
    -- Tracked again in the quest log: shown again
    local questID, added = ...
    if added then Core.UnhideQuest(questID) end
  elseif event == "ZONE_CHANGED_NEW_AREA" or event == "PLAYER_ENTERING_WORLD" then
    -- (a moment after arriving: the zone's name and the quest log are ready then)
    C_Timer.After(1, Core.FocusZone)
  elseif event == "ITEM_DATA_LOAD_RESULT" then
    if not Core.ItemLoaded((...)) then return end
  elseif event == "UI_SCALE_CHANGED" or event == "DISPLAY_SIZE_CHANGED" then
    ApplyPosition()
  end
  Schedule()
end)

local EVENTS = {
  "PLAYER_ENTERING_WORLD", "PLAYER_REGEN_ENABLED", "ZONE_CHANGED_NEW_AREA",
  "QUEST_LOG_UPDATE", "QUEST_WATCH_LIST_CHANGED", "QUEST_WATCH_UPDATE", "QUEST_ACCEPTED",
  "QUEST_REMOVED", "QUEST_TURNED_IN", "QUEST_POI_UPDATE", "SUPER_TRACKING_CHANGED",
  "TRACKED_ACHIEVEMENT_LIST_CHANGED", "TRACKED_ACHIEVEMENT_UPDATE", "ACHIEVEMENT_EARNED",
  "CONTENT_TRACKING_UPDATE", "CONTENT_TRACKING_LIST_UPDATE",
  "TRACKED_RECIPE_UPDATE", "BAG_UPDATE_DELAYED", "ITEM_DATA_LOAD_RESULT",
  "UI_SCALE_CHANGED", "DISPLAY_SIZE_CHANGED",
}

-- Achievement criteria change very often (every kill, every step): only
-- listened to while an achievement is tracked
function WatchCriteria(any)
  if any == criteriaWatched then return end
  criteriaWatched = any
  if any then
    pcall(events.RegisterEvent, events, "CRITERIA_UPDATE")
  else
    pcall(events.UnregisterEvent, events, "CRITERIA_UPDATE")
  end
end

local LAYOUT_KEYS = {
  layout = true, profile = true, width = true, zoneHeaders = true, currentZoneFirst = true,
  completedLast = true, questCount = true, instanceMode = true, maxHeight = true, allQuests = true,
  zoneOnly = true, completedObjectives = true, glassBars = true,
  strikeCompleted = true, titleColor = true, questNameColor = true, iconColor = true,
  iconOutline = true, hideMainHeader = true, hideSectionHeaders = true, sectionAnimation = true,
}

Core:OnChange(function (key)
  if key == "enable" then
    -- (turned off in Options: the game's tracker stays, this one hides)
    if not Core.trackerOn then
      frame:Hide()
      return
    end
    enabledAt = GetTime()
    HookGameTracker()
    for _, event in ipairs(EVENTS) do pcall(events.RegisterEvent, events, event) end
    ApplyPosition()
    SetupEditMode()
    -- In case Edit Mode never says which layout is on
    C_Timer.After(5, HideGameTracker)
    Schedule()
  elseif LAYOUT_KEYS[key] then
    Schedule()
  end
end)
