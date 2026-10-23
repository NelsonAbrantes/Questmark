local _, ns = ...
local Core = ns.Core

-- luacheck: push ignore 113
local C_QuestLog = C_QuestLog
local C_Timer = C_Timer
local CreateColor = CreateColor
local CreateFrame = CreateFrame
local GetTime = GetTime
local hooksecurefunc = hooksecurefunc
local InCombatLockdown = InCombatLockdown
local UIErrorsFrame = UIErrorsFrame
-- luacheck: pop

local ROW_HEIGHT = 22    -- a minimized zone's row under the last quest
local LINE_ALPHA = 0.5   -- the line under a zone's name, at its strongest
local ICON_SIZE = 12     -- the minimize button (in a minimized zone's row)
local GAP_HEIGHT = 10    -- the gap the game leaves between quests, where open zones get their name
local GAP_FONT_SIZE = 9  -- an open zone's name, small to fit in it
local GAP_ICON_SIZE = 9
local SORT_EVERY = 2     -- seconds between two sorts at most
local ASSETS = "Interface\\AddOns\\GlassForeverTracker\\Assets\\"

----
-- ZoneHeaders
--
-- "Group quests by zone" (Options): the quests are sorted by zone, in the
-- order of the zones in your quest log, and each zone gets its name in the
-- gap above its first quest (small), with a button to minimize the zone (its
-- quests hidden; minimized zones are listed under the last quest, with a
-- plus to open them).
-- - Sorting and minimizing: like tracking quests again, or not, yourself,
--   which the game only allows out of combat; in combat it waits for the
--   fight to end. A minimized zone's quests stay in your quest log, only not
--   tracked; opening the zone tracks them again. Kept per character.
-- - Nothing of the game's tracker layout is changed (that made the whole
--   tracker "tainted"): the names only use room that's already there.

local module = _G.QuestObjectiveTracker

local function Profile() return Core.db.profile end
local function Enabled() return Profile().zoneHeaders end

-- Minimized zones (zone name -> true) and the quests they stopped tracking
-- (questID -> zone name), per character
local function Collapsed()
  Core.db.char.collapsedZones = Core.db.char.collapsedZones or {}
  return Core.db.char.collapsedZones
end
local function HiddenQuests()
  Core.db.char.zoneHiddenQuests = Core.db.char.zoneHiddenQuests or {}
  return Core.db.char.zoneHiddenQuests
end

-- The zone of each quest in your log (questID -> zone name) and the order of
-- the zones there (zone name -> position)
local zoneOf, zoneOrder = {}, {}
local collapsedList = {} -- minimized zones with quests, in log order (CollapsedZones)

-- True while a quest is in your log (also when its zone's header is closed
-- in the log, which hides it from the log's list)
local function InLog(questID)
  if C_QuestLog.IsOnQuest then return C_QuestLog.IsOnQuest(questID) end
  return C_QuestLog.GetLogIndexForQuestID(questID) ~= nil
end

-- The zone of a quest from its map, for quests the quest log doesn't list
local function MapZone(questID)
  local mapID = _G.GetQuestUiMapID and _G.GetQuestUiMapID(questID)
  if (not mapID or mapID == 0) and _G.C_TaskQuest and _G.C_TaskQuest.GetQuestZoneID then
    mapID = _G.C_TaskQuest.GetQuestZoneID(questID)
  end
  local info = mapID and mapID ~= 0 and _G.C_Map and _G.C_Map.GetMapInfo(mapID)
  return info and info.name or nil
end

local function ReadZones()
  wipe(zoneOf)
  wipe(zoneOrder)
  local zone
  for i = 1, C_QuestLog.GetNumQuestLogEntries() do
    local info = C_QuestLog.GetInfo(i)
    if info then
      if info.isHeader then
        zone = info.title
        if zone and not zoneOrder[zone] then zoneOrder[zone] = i end
      elseif info.questID and zone then
        zoneOf[info.questID] = zone
      end
    end
  end

  -- Tracked quests (and the ones a minimized zone hides) the log didn't
  -- list: their zone from the map, after the log's zones
  local extra = 5000
  local function Fill(questID)
    if zoneOf[questID] then return end
    local mapZone = MapZone(questID)
    if not mapZone then return end
    zoneOf[questID] = mapZone
    if not zoneOrder[mapZone] then
      extra = extra + 1
      zoneOrder[mapZone] = extra
    end
  end
  for i = 1, C_QuestLog.GetNumQuestWatches() do
    local questID = C_QuestLog.GetQuestIDForQuestWatchIndex(i)
    if questID then Fill(questID) end
  end
  for questID in pairs(Core.db.char.zoneHiddenQuests or {}) do
    if InLog(questID) then Fill(questID) end
  end
end

-- Minimized zones that still have quests in your log, in log order
local function CollapsedZones()
  local list, seen = {}, {}
  local hidden = HiddenQuests()
  for questID, zone in pairs(hidden) do
    if InLog(questID) then
      if not seen[zone] and Collapsed()[zone] then
        seen[zone] = true
        table.insert(list, zone)
      end
    else
      hidden[questID] = nil -- no longer in the log (turned in or abandoned)
    end
  end
  for zone in pairs(Collapsed()) do
    if not seen[zone] then Collapsed()[zone] = nil end -- nothing left in it
  end
  table.sort(list, function (a, b) return (zoneOrder[a] or 9999) < (zoneOrder[b] or 9999) end)
  return list
end

-- Tracks a quest (again), without the new quest animations (a quest that
-- was already showing, only moved); loud: a quest just accepted keeps them.
local function Watch(questID, watchType, loud)
  if not loud then Core.rewatched[questID] = GetTime() end
  if watchType then
    C_QuestLog.AddQuestWatch(questID, watchType)
  else
    C_QuestLog.AddQuestWatch(questID)
  end
end

-- Where a zone goes in the list: the zone you're in first (Options), then
-- the others in the order of your quest log
local function ZoneRank(zone)
  if not zone then return 9999 end
  if Profile().currentZoneFirst then
    local here = _G.GetRealZoneText and _G.GetRealZoneText()
    if here and here == zone then return -1 end
  end
  return zoneOrder[zone] or 9999
end

-- How many quests a minimized zone hides
local function HiddenCount(zone)
  local count = 0
  for questID, hiddenZone in pairs(HiddenQuests()) do
    if hiddenZone == zone and InLog(questID) then count = count + 1 end
  end
  return count
end

----
-- Sorting

local lastSort, pendingSort, sorting = 0, false, false
local prependsWatches -- nil until found out: true if a quest tracked again goes to the top
local known = {} -- the quests tracked at the last look (questID -> true)

-- now: right away (a quest just came in: sorted before the tracker draws it,
-- so it shows in its place and doesn't jump there after its animation)
local function SortWatches(now)
  if not Enabled() or sorting then return end
  if InCombatLockdown() then pendingSort = true return end
  local time = GetTime()
  if not now and time - lastSort < SORT_EVERY then
    if not pendingSort then
      pendingSort = true
      C_Timer.After(SORT_EVERY, function () pendingSort = false; SortWatches() end)
    end
    return
  end

  ReadZones()
  local watched = {}
  for i = 1, C_QuestLog.GetNumQuestWatches() do
    local questID = C_QuestLog.GetQuestIDForQuestWatchIndex(i)
    if questID then
      table.insert(watched, {
        id = questID,
        watchType = C_QuestLog.GetQuestWatchType(questID),
        zone = ZoneRank(zoneOf[questID]),
        done = Profile().completedLast and C_QuestLog.IsComplete(questID) and 1 or 0,
        log = C_QuestLog.GetLogIndexForQuestID(questID) or 9999,
        was = i,
      })
    end
  end
  local sorted = {}
  for i, entry in ipairs(watched) do sorted[i] = entry end
  table.sort(sorted, function (a, b)
    if a.zone ~= b.zone then return a.zone < b.zone end
    if a.done ~= b.done then return a.done < b.done end -- ready to turn in: last of the zone
    if a.log ~= b.log then return a.log < b.log end
    return a.was < b.was
  end)

  local same = true
  for i, entry in ipairs(sorted) do
    if entry ~= watched[i] then same = false break end
  end
  -- The quests that were already there (the others are new: they keep their
  -- animation when tracked again)
  local before = known
  known = {}
  for _, entry in ipairs(watched) do known[entry.id] = true end
  if same then return end

  -- All of them again, in the new order (in the same moment: the tracker
  -- shows the result once), without the new quest animations
  lastSort = time
  sorting = true
  local function TrackAll()
    for _, entry in ipairs(watched) do
      C_QuestLog.RemoveQuestWatch(entry.id)
    end
    -- This game version puts a quest tracked again at the top of the list,
    -- not at the end: then they're tracked from the last to the first
    local from, to, step = 1, #sorted, 1
    if prependsWatches then from, to, step = #sorted, 1, -1 end
    for i = from, to, step do
      Watch(sorted[i].id, sorted[i].watchType, not before[sorted[i].id] and next(before) ~= nil)
    end
  end
  TrackAll()
  -- Found out the first time: the list came out the wrong way round
  if prependsWatches == nil and #sorted > 1 then
    local firstNow = C_QuestLog.GetQuestIDForQuestWatchIndex(1)
    prependsWatches = firstNow == sorted[#sorted].id
    if prependsWatches then TrackAll() end
  end
  sorting = false
end

----
-- Minimizing a zone

local pendingToggle = {} -- zone -> true, clicked in combat
local PlaceLabels

local function SetCollapsed(zone, collapse)
  if InCombatLockdown() then
    pendingToggle[zone] = collapse
    if UIErrorsFrame then UIErrorsFrame:AddMessage("Glass Forever Tracker: the zone changes after the fight", 1, 0.82, 0.22) end
    return
  end
  ReadZones()
  sorting = true
  if collapse then
    -- The last zone with quests showing stays open: with nothing left, the
    -- names (and the plus to open them) would have no place to show
    local others = false
    for i = 1, C_QuestLog.GetNumQuestWatches() do
      local questID = C_QuestLog.GetQuestIDForQuestWatchIndex(i)
      if questID and zoneOf[questID] ~= zone then others = true break end
    end
    if not others then
      sorting = false
      if UIErrorsFrame then UIErrorsFrame:AddMessage("Glass Forever Tracker: one zone has to stay open", 1, 0.82, 0.22) end
      return
    end
    Collapsed()[zone] = true
    local toHide = {}
    for i = 1, C_QuestLog.GetNumQuestWatches() do
      local questID = C_QuestLog.GetQuestIDForQuestWatchIndex(i)
      if questID and zoneOf[questID] == zone then table.insert(toHide, questID) end
    end
    for _, questID in ipairs(toHide) do
      HiddenQuests()[questID] = zone
      C_QuestLog.RemoveQuestWatch(questID)
    end
  else
    Collapsed()[zone] = nil
    for questID, hiddenZone in pairs(HiddenQuests()) do
      if hiddenZone == zone then
        HiddenQuests()[questID] = nil
        if InLog(questID) then Watch(questID) end
      end
    end
  end
  sorting = false
  collapsedList = CollapsedZones()
  lastSort = 0
  SortWatches()
  -- (the tracker draws itself again for the tracking changes; the names follow)
end

----
-- The names, after each layout of the game's tracker. Nothing of the game's
-- layout is changed (giving the names room of their own changed its spacing
-- values, which made the whole tracker "tainted": errors on secret auras in
-- the scenario section and in Edit Mode). So:
-- - an open zone: its name, small, in the gap above its first quest,
--   with the minimize button in front of it
-- - minimized zones: in rows under the last quest, each with a plus

local labels = {}

local function Label(i)
  local label = labels[i]
  if label then return label end
  label = CreateFrame("Button", nil, module.ContentsFrame)
  label:SetHeight(ROW_HEIGHT)
  label.text = label:CreateFontString(nil, "OVERLAY", "ObjectiveTrackerLineFont")
  label.line = label:CreateTexture(nil, "ARTWORK")
  label.line:SetColorTexture(1, 1, 1, 1)
  Core.PixelHeight(label.line, 1)
  label.line:SetPoint("BOTTOMLEFT", 0, 1)
  label.line:SetPoint("BOTTOMRIGHT", 0, 1)
  -- The minimize button: a bar while open, a plus while minimized, in the
  -- title color with a dark outline, lighter under the mouse
  label.outline = label:CreateTexture(nil, "OVERLAY", nil, 6)
  label.outline:SetSize(ICON_SIZE, ICON_SIZE)
  label.outline:SetVertexColor(0, 0, 0, 0.9)
  label.icon = label:CreateTexture(nil, "OVERLAY", nil, 7)
  label.icon:SetSize(ICON_SIZE, ICON_SIZE)
  label.icon:SetPoint("CENTER", label.outline)
  label:SetScript("OnClick", function (self) SetCollapsed(self.zone, not self.collapsed) end)
  label:SetScript("OnEnter", function (self) self.hover = true; self:UpdateColor() end)
  label:SetScript("OnLeave", function (self) self.hover = false; self:UpdateColor() end)
  function label:UpdateColor()
    local r, g, b = Core:Color(Profile().titleColor)
    r, g, b = r or Core.GOLD.r, g or Core.GOLD.g, b or Core.GOLD.b
    local textAlpha = self.collapsed and 0.6 or 0.7
    if self.hover then
      r, g, b = r + (1 - r) * 0.4, g + (1 - g) * 0.4, b + (1 - b) * 0.4
      textAlpha = 1
    end
    self.text:SetTextColor(r, g, b, textAlpha)
    self.icon:SetVertexColor(r, g, b, 1)
    self.line:SetGradient("HORIZONTAL", CreateColor(r, g, b, LINE_ALPHA), CreateColor(r, g, b, 0))
  end
  labels[i] = label
  return label
end

local function SetIcon(label, collapsed)
  label.icon:SetTexture(ASSETS..(collapsed and "expand" or "collapse"))
  label.outline:SetTexture(ASSETS..(collapsed and "expandOutline" or "collapseOutline"))
end

-- An open zone's name on the right of its first quest's title line
-- The sizes of a label: small in the gap between quests, normal in a row
local function Size(label, small)
  local iconSize = small and GAP_ICON_SIZE or ICON_SIZE
  label.icon:SetSize(iconSize, iconSize)
  label.outline:SetSize(iconSize, iconSize)
  label.text:SetFontObject("ObjectiveTrackerLineFont")
  if small then
    local file, _, flags = label.text:GetFont()
    if file then label.text:SetFont(file, GAP_FONT_SIZE, flags) end
  end
end

-- An open zone's name in the gap the game already leaves above its first
-- quest: small, the minimize button in front of it, and a thin line after it
-- fading out to the right, like a separator
local function GapLabel(used, zone, block)
  local label = Label(used)
  label.zone, label.collapsed = zone, false
  Size(label, true)
  label:ClearAllPoints()
  label:SetPoint("BOTTOMLEFT", block, "TOPLEFT", 0, 0)
  label:SetPoint("BOTTOMRIGHT", block, "TOPRIGHT", 0, 0)
  label:SetHeight(GAP_HEIGHT)
  label.outline:ClearAllPoints()
  label.outline:SetPoint("LEFT", label, "LEFT", -1, 0)
  label.text:ClearAllPoints()
  label.text:SetPoint("LEFT", label.outline, "RIGHT", 2, 0)
  label.text:SetJustifyH("LEFT")
  label.text:SetText(zone)
  label.line:ClearAllPoints()
  label.line:SetPoint("LEFT", label.text, "RIGHT", 4, 0)
  label.line:SetPoint("RIGHT", label, "RIGHT", 0, 0)
  label.line:Show()
  SetIcon(label, false)
  label:UpdateColor()
  label:Show()
end

-- A minimized zone's row under the last quest
local function RowLabel(used, zone, last, row)
  local label = Label(used)
  label.zone, label.collapsed = zone, true
  Size(label, false)
  label.text:ClearAllPoints()
  label.text:SetPoint("BOTTOMLEFT", ICON_SIZE + 3, 3)
  label.text:SetJustifyH("LEFT")
  -- with how many quests it hides
  local count = HiddenCount(zone)
  label.text:SetText(count > 0 and (zone.." |cff999999("..count..")|r") or zone)
  label.outline:ClearAllPoints()
  label.outline:SetPoint("BOTTOMLEFT", label, "BOTTOMLEFT", -1, 3)
  label.line:ClearAllPoints()
  label.line:SetPoint("BOTTOMLEFT", 0, 1)
  label.line:SetPoint("BOTTOMRIGHT", 0, 1)
  label.line:Show()
  label:ClearAllPoints()
  label:SetHeight(ROW_HEIGHT)
  label:SetPoint("TOPLEFT", last, "BOTTOMLEFT", 0, -(ROW_HEIGHT * (row - 1)) - 4)
  label:SetPoint("TOPRIGHT", last, "BOTTOMRIGHT", 0, -(ROW_HEIGHT * (row - 1)) - 4)
  SetIcon(label, true)
  label:UpdateColor()
  label:Show()
end

function PlaceLabels()
  local used = 0
  if Enabled() and module:IsShown() then
    local block, last, previousZone = module.firstBlock, nil, nil
    while block do
      if block.used and block:IsShown() then
        local zone = zoneOf[block.id]
        if zone and zone ~= previousZone then
          used = used + 1
          GapLabel(used, zone, block)
        end
        previousZone = zone
        last = block
      end
      block = block.nextBlock
    end
    if last then
      for row, zone in ipairs(collapsedList) do
        used = used + 1
        RowLabel(used, zone, last, row)
      end
    end
  end
  for i = used + 1, #labels do labels[i]:Hide() end
end

----

-- A quest tracked in a minimized zone (accepted there, or tracked from the
-- quest log) goes with the zone's others, hidden
local function HideInCollapsed()
  if InCombatLockdown() then return end
  local toHide = {}
  for i = 1, C_QuestLog.GetNumQuestWatches() do
    local questID = C_QuestLog.GetQuestIDForQuestWatchIndex(i)
    local zone = questID and zoneOf[questID]
    if zone and Collapsed()[zone] then table.insert(toHide, questID) end
  end
  if #toHide == 0 then return end
  sorting = true
  for _, questID in ipairs(toHide) do
    HiddenQuests()[questID] = zoneOf[questID]
    C_QuestLog.RemoveQuestWatch(questID)
  end
  sorting = false
end

-- Quest log changes come in bursts (QUEST_LOG_UPDATE fires often): looked at
-- once, a moment after the last one
local checkQueued = false
local function QueueCheck()
  if checkQueued then return end
  checkQueued = true
  C_Timer.After(0.5, function ()
    checkQueued = false
    ReadZones()
    HideInCollapsed()
    collapsedList = CollapsedZones()
    SortWatches()
  end)
end

local events = CreateFrame("Frame")
events:SetScript("OnEvent", function (_, event)
  if event == "PLAYER_REGEN_ENABLED" then
    for zone, collapse in pairs(pendingToggle) do
      pendingToggle[zone] = nil
      SetCollapsed(zone, collapse)
    end
    if pendingSort then pendingSort = false; SortWatches() end
    return
  end
  if not Enabled() or sorting then return end
  -- A quest tracked or accepted: sorted right away, before the tracker
  -- draws it (the tracker waits for the next frame to draw)
  if event == "QUEST_WATCH_LIST_CHANGED" or event == "QUEST_ACCEPTED" then
    ReadZones()
    HideInCollapsed()
    collapsedList = CollapsedZones()
    SortWatches(true)
  else
    QueueCheck()
  end
end)

-- Opens every minimized zone (the option turned off): their quests are
-- tracked again
local function OpenAll()
  if InCombatLockdown() then return end
  ReadZones()
  for zone in pairs(Collapsed()) do
    for questID, hiddenZone in pairs(HiddenQuests()) do
      if hiddenZone == zone then
        HiddenQuests()[questID] = nil
        if InLog(questID) then Watch(questID) end
      end
    end
    Collapsed()[zone] = nil
  end
end

Core:OnChange(function (key)
  if key == "enable" then
    if not module or not module.EndLayout then return end
    hooksecurefunc(module, "EndLayout", PlaceLabels)
    for _, event in ipairs({ "QUEST_WATCH_LIST_CHANGED", "QUEST_ACCEPTED", "QUEST_LOG_UPDATE", "PLAYER_REGEN_ENABLED", "ZONE_CHANGED_NEW_AREA" }) do
      events:RegisterEvent(event)
    end
    ReadZones()
    collapsedList = CollapsedZones()
    SortWatches()
    PlaceLabels()
  elseif key == "zoneHeaders" or key == "titleColor" or key == "currentZoneFirst" or key == "completedLast" or key == "profile" then
    if not Enabled() then OpenAll() end
    ReadZones()
    collapsedList = CollapsedZones()
    SortWatches()
    PlaceLabels()
  end
end)

-- /gftzones: what the addon knows of each zone (to find what's wrong)
_G.SLASH_GFTZONES1 = "/gftzones"
_G.SlashCmdList.GFTZONES = function ()
  ReadZones()
  local print = _G.print
  print("|cffdfba69GFT zones|r map API:", _G.GetQuestUiMapID and "yes" or "no")
  for i = 1, C_QuestLog.GetNumQuestWatches() do
    local questID = C_QuestLog.GetQuestIDForQuestWatchIndex(i)
    if questID then
      local zone = zoneOf[questID]
      print(i, questID, C_QuestLog.GetTitleForQuestID and C_QuestLog.GetTitleForQuestID(questID) or "", "->", zone or "?", zone and zoneOrder[zone] or "-", MapZone(questID) or "no map")
    end
  end
  for _, zone in ipairs(CollapsedZones()) do
    print("minimized:", zone, zoneOrder[zone] or "-")
  end
end
