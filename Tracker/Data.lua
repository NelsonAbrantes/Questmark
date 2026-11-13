local _, ns = ...
local Core = ns.Core

-- luacheck: push ignore 113
local C_QuestLog = C_QuestLog
local C_Timer = C_Timer
local GetTime = GetTime
local GetInstanceInfo = GetInstanceInfo
local InCombatLockdown = InCombatLockdown
local wipe = wipe
-- luacheck: pop

local Readable = Core.Readable
local MAX_CRITERIA = 10 -- criteria shown for one achievement (then "...")

----
-- Data
--
-- What the tracker shows, read from the game: the tracked quests (grouped by
-- zone), achievements and recipes. Each one becomes an entry:
--   { kind, key, id, title, lines = { { key, text, done, bar } }, ... }
-- The tracker (Tracker.lua) draws the entries; nothing here draws.

local function Profile() return Core.db.profile end

----
-- Which quests show: every quest in your quest log (Options: All quests),
-- or only the ones you track, like the game's tracker (which can track only
-- so many). With all of them, "Stop tracking" hides a quest from the tracker
-- (per character); tracking it again in the quest log shows it again.

local function HiddenQuests()
  Core.db.char.hiddenQuests = Core.db.char.hiddenQuests or {}
  return Core.db.char.hiddenQuests
end

function Core.HideQuest(questID)
  HiddenQuests()[questID] = true
  Core:Changed("layout")
end

function Core.UnhideQuest(questID)
  if questID and HiddenQuests()[questID] then
    HiddenQuests()[questID] = nil
    Core:Changed("layout")
  end
end

---
-- The quests the tracker shows, in order (questIDs)
function Core.ShownQuestIDs()
  local list = {}
  if Profile().allQuests then
    local hidden = HiddenQuests()
    for i = 1, C_QuestLog.GetNumQuestLogEntries() do
      local info = C_QuestLog.GetInfo(i)
      if info and not info.isHeader and not info.isHidden and info.questID and not hidden[info.questID] then
        table.insert(list, info.questID)
      end
    end
    -- Tracked ones the log doesn't list right now (their zone is closed in
    -- the log) come too
    local seen = {}
    for _, questID in ipairs(list) do seen[questID] = true end
    for i = 1, C_QuestLog.GetNumQuestWatches() do
      local questID = C_QuestLog.GetQuestIDForQuestWatchIndex(i)
      if questID and not seen[questID] and not hidden[questID] then table.insert(list, questID) end
    end
  else
    for i = 1, C_QuestLog.GetNumQuestWatches() do
      local questID = C_QuestLog.GetQuestIDForQuestWatchIndex(i)
      if questID then table.insert(list, questID) end
    end
  end
  return list
end

----
-- Zones

-- Minimized zones (zone name -> true), per character
local function Collapsed()
  Core.db.char.collapsedZones = Core.db.char.collapsedZones or {}
  return Core.db.char.collapsedZones
end

-- The zone of each quest in your log (questID -> zone name) and the order of
-- the zones there (zone name -> position)
local zoneOf, zoneOrder = {}, {}

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
  -- Tracked quests the log didn't list: their zone from the map, after the
  -- log's zones
  local extra = 5000
  for _, questID in ipairs(Core.ShownQuestIDs()) do
    if not zoneOf[questID] then
      local mapZone = MapZone(questID)
      if mapZone then
        zoneOf[questID] = mapZone
        if not zoneOrder[mapZone] then
          extra = extra + 1
          zoneOrder[mapZone] = extra
        end
      end
    end
  end
end

function Core.ZoneOf(questID)
  return zoneOf[questID]
end

local function Here()
  return _G.GetRealZoneText and _G.GetRealZoneText()
end

-- Where a zone goes in the list: the zone you're in first (Options), then
-- the others in the order of your quest log
local function ZoneRank(zone)
  if not zone then return 9999 end
  if Profile().currentZoneFirst and zone == Here() then return -1 end
  return zoneOrder[zone] or 9999
end

function Core.IsZoneCollapsed(zone)
  return zone ~= nil and Collapsed()[zone] == true
end

---
-- Minimizes a zone (its quests hidden, listed under the last quest) or opens
-- it. The quests stay tracked: only the tracker stops showing them.
-- "Only quests in this zone" (with every quest showing): the zones opened by
-- hand while here, and where that was (they minimize again in another zone)
local openedHere, openedWhere = {}, nil

function Core.SetZoneCollapsed(zone, collapse)
  if not zone then return end
  Collapsed()[zone] = collapse and true or nil
  openedHere[zone] = not collapse or nil
  -- Its quests come back in a quiet cascade, not as new quests
  if not collapse then Core.openedZone = { zone = zone, when = GetTime() } end
  Core:Changed("layout")
end

-- Arriving in a zone with tracked quests: it opens (if minimized) and the
-- other zones are minimized. Only when it has quests (else nothing would be
-- left to see). Opening a zone by hand while there still works.
function Core.FocusZone()
  if not Profile().zoneHeaders then return end
  local here = Here()
  if not here then return end
  ReadZones()
  local hasHere, others = false, {}
  for _, questID in ipairs(Core.ShownQuestIDs()) do
    local zone = zoneOf[questID]
    if zone == here then
      hasHere = true
    elseif zone then
      others[zone] = true
    end
  end
  if not hasHere then return end
  local collapsed = Collapsed()
  if collapsed[here] then
    collapsed[here] = nil
    Core.openedZone = { zone = here, when = GetTime() }
  end
  for zone in pairs(others) do collapsed[zone] = true end
  Core:Changed("layout")
end

---
-- The quest moved on in a minimized zone: the zone opens, so you see it
function Core.OpenZoneOf(questID)
  local zone = questID and zoneOf[questID]
  if zone and Collapsed()[zone] then Core.SetZoneCollapsed(zone, false) end
end

----
-- Quests

local function DifficultyColor(questID, level)
  local PlayerInfo = _G.C_PlayerInfo
  if PlayerInfo and PlayerInfo.GetContentDifficultyQuestForPlayer and _G.GetDifficultyColor then
    local ok, difficulty = pcall(PlayerInfo.GetContentDifficultyQuestForPlayer, questID)
    local color = ok and difficulty and _G.GetDifficultyColor(difficulty)
    if color then return color.r, color.g, color.b end
  end
  if level and _G.GetQuestDifficultyColor then
    local color = _G.GetQuestDifficultyColor(level)
    if color then return color.r, color.g, color.b end
  end
  return 0.75, 0.61, 0
end

-- The quest name color: chosen in the options, or by difficulty
local function QuestColor(questID, level)
  local r, g, b = Core:Color(Profile().questNameColor)
  if r then return r, g, b end
  return DifficultyColor(questID, level)
end
Core.QuestColor = QuestColor

-- Other addons can put colors in quest names: taken out, the tracker colors them
local function Plain(text)
  if type(text) ~= "string" or not text:find("|", 1, true) then return text end
  return (text:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|cn.-:", ""):gsub("|r", ""))
end

local function QuestLines(questID, logIndex, info, complete, failed)
  local lines = {}
  if failed then
    table.insert(lines, { key = "failed", text = _G.FAILED or "Failed", failed = true })
    return lines
  end
  if complete then
    local text
    if info and info.isAutoComplete then
      text = _G.QUEST_WATCH_CLICK_TO_COMPLETE or "(click to complete)"
    else
      text = _G.GetQuestLogCompletionText and logIndex and _G.GetQuestLogCompletionText(logIndex)
      if not Readable(text) or text == "" then text = _G.QUEST_WATCH_QUEST_READY or "Ready for turn-in" end
    end
    table.insert(lines, { key = "complete", text = text, ready = true })
    return lines
  end
  for i, objective in ipairs(C_QuestLog.GetQuestObjectives(questID) or {}) do
    local text = objective.text
    if Readable(text) and text ~= "" then
      local line = { key = i, text = text, done = objective.finished and true or false }
      if objective.type == "progressbar" and not objective.finished and _G.GetQuestProgressBarPercent then
        line.bar = _G.GetQuestProgressBarPercent(questID) or 0
      end
      table.insert(lines, line)
    end
  end
  -- No objectives listed: the quest's own short description
  if #lines == 0 and logIndex and _G.GetQuestLogQuestText then
    local ok, _, objectives = pcall(_G.GetQuestLogQuestText, logIndex)
    if ok and Readable(objectives) and objectives ~= "" then
      table.insert(lines, { key = "text", text = objectives })
    end
  end
  return lines
end

local function QuestItem(logIndex, complete)
  if not logIndex or not _G.GetQuestLogSpecialItemInfo then return nil end
  local link, texture, charges, showWhenComplete = _G.GetQuestLogSpecialItemInfo(logIndex)
  if not link or (complete and not showWhenComplete) then return nil end
  return { link = link, texture = texture, charges = charges, logIndex = logIndex }
end

local function QuestEntry(questID, watchIndex)
  local logIndex = C_QuestLog.GetLogIndexForQuestID(questID)
  local info = logIndex and C_QuestLog.GetInfo(logIndex)
  local title = C_QuestLog.GetTitleForQuestID and C_QuestLog.GetTitleForQuestID(questID) or (info and info.title)
  if not Readable(title) or not title then return nil end
  local complete = C_QuestLog.IsComplete(questID) and true or false
  local failed = C_QuestLog.IsFailed and C_QuestLog.IsFailed(questID) or false
  local super = _G.C_SuperTrack and _G.C_SuperTrack.GetSuperTrackedQuestID
    and _G.C_SuperTrack.GetSuperTrackedQuestID() == questID
  return {
    kind = "quest", key = "q"..questID, id = questID, logIndex = logIndex,
    title = Plain(title), level = info and info.level,
    complete = complete, failed = failed and true or false,
    autoComplete = info and info.isAutoComplete and complete,
    super = super and true or false,
    zone = zoneOf[questID], watchIndex = watchIndex,
    lines = QuestLines(questID, logIndex, info, complete, failed),
    item = QuestItem(logIndex, complete),
  }
end

local function QuestCount()
  local _, quests = C_QuestLog.GetNumQuestLogEntries()
  local max = C_QuestLog.GetMaxNumQuestsCanAccept and C_QuestLog.GetMaxNumQuestsCanAccept()
    or _G.MAX_QUESTS or 25
  return quests, max
end

---
-- The quests section: its title and entries, in order. With "Group quests
-- by zone", each zone's name comes before its quests ("zone" entries) and
-- minimized zones are listed at the end ("collapsedZone" entries).
function Core.QuestSection()
  ReadZones()
  local profile = Profile()
  local quests = {}
  for i, questID in ipairs(Core.ShownQuestIDs()) do
    local entry = QuestEntry(questID, i)
    if entry then table.insert(quests, entry) end
  end

  -- "Only quests in this zone" with every quest showing: the other zones
  -- show minimized (one opened by hand stays open until you change zone);
  -- without zone names, they're left out (the zone filter then doesn't stop
  -- tracking them)
  local forced = {}
  if profile.allQuests and profile.zoneOnly and not (Core.InDungeon and Core.InDungeon()) then
    local here = Here()
    if profile.zoneHeaders then
      if here ~= openedWhere then
        wipe(openedHere)
        openedWhere = here
      end
      for _, quest in ipairs(quests) do
        local zone = quest.zone or (_G.OTHER or "Other")
        if zone ~= here and not openedHere[zone] then forced[zone] = true end
      end
    else
      local kept = {}
      for _, quest in ipairs(quests) do
        if quest.zone == here then table.insert(kept, quest) end
      end
      quests = kept
    end
  end

  -- Every zone with a tracked quest, before any is left out below (a
  -- minimized zone is only forgotten once it has no tracked quest at all)
  local zonesTracked = {}
  for _, quest in ipairs(quests) do zonesTracked[quest.zone or (_G.OTHER or "Other")] = true end

  -- Inside a dungeon or raid with "Dungeon quests only": only its quests
  -- show (the others stay tracked, for when you're out)
  if profile.instanceMode == "dungeon" and Core.InDungeon and Core.InDungeon() then
    local name = GetInstanceInfo()
    local here = Here()
    local map = _G.C_Map and _G.C_Map.GetBestMapForUnit and _G.C_Map.GetBestMapForUnit("player")
    local kept = {}
    for _, quest in ipairs(quests) do
      local questMap = _G.GetQuestUiMapID and _G.GetQuestUiMapID(quest.id)
      if quest.zone == name or quest.zone == here or (map and questMap == map) then
        table.insert(kept, quest)
      end
    end
    quests = kept
  end

  local title = _G.TRACKER_HEADER_QUESTS or "Quests"
  if profile.questCount then
    local count, max = QuestCount()
    if count then title = ("%s  %d/%d"):format(title, count, max) end
  end
  local section = { key = "quests", title = title, entries = {}, count = #quests }
  if #quests == 0 then return section end

  if not profile.zoneHeaders then
    for _, quest in ipairs(quests) do table.insert(section.entries, quest) end
    return section
  end

  for _, quest in ipairs(quests) do
    quest.rank = ZoneRank(quest.zone)
    quest.order = profile.completedLast and quest.complete and 1 or 0
    quest.log = quest.logIndex or 9999
  end
  table.sort(quests, function (a, b)
    if a.rank ~= b.rank then return a.rank < b.rank end
    if (a.zone or "") ~= (b.zone or "") then return (a.zone or "") < (b.zone or "") end
    if a.order ~= b.order then return a.order < b.order end -- ready to turn in: last of the zone
    if a.log ~= b.log then return a.log < b.log end
    return a.watchIndex < b.watchIndex
  end)

  local collapsed, hiddenCount, collapsedOrder = Collapsed(), {}, {}
  local previous
  for _, quest in ipairs(quests) do
    local zone = quest.zone or (_G.OTHER or "Other")
    if collapsed[zone] or forced[zone] then
      if not hiddenCount[zone] then table.insert(collapsedOrder, zone) end
      hiddenCount[zone] = (hiddenCount[zone] or 0) + 1
    else
      if zone ~= previous then
        table.insert(section.entries, { kind = "zone", key = "z:"..zone, zone = zone })
        previous = zone
      end
      table.insert(section.entries, quest)
    end
  end
  for _, zone in ipairs(collapsedOrder) do
    table.insert(section.entries, { kind = "collapsedZone", key = "c:"..zone, zone = zone, count = hiddenCount[zone] })
  end
  -- Minimized zones with no tracked quest left are forgotten (not the ones
  -- only left out inside a dungeon)
  for zone in pairs(collapsed) do
    if not zonesTracked[zone] then collapsed[zone] = nil end
  end
  return section
end

----
-- Achievements

local function TrackedAchievements()
  local tracking, types = _G.C_ContentTracking, _G.Enum and _G.Enum.ContentTrackingType
  if tracking and tracking.GetTrackedIDs and types and types.Achievement then
    return tracking.GetTrackedIDs(types.Achievement) or {}
  end
  if _G.GetTrackedAchievements then return { _G.GetTrackedAchievements() } end
  return {}
end

local PROGRESS_BAR_FLAG = 0x00000001 -- a criterion shown as a bar in the game

local function AchievementEntry(id)
  if not _G.GetAchievementInfo then return nil end
  local _, name, _, completed, _, _, _, description = _G.GetAchievementInfo(id)
  if not Readable(name) or not name then return nil end
  local lines = {}
  local count = _G.GetAchievementNumCriteria and _G.GetAchievementNumCriteria(id) or 0
  local hidden = 0
  for i = 1, count do
    local text, _, done, quantity, required, _, flags, _, quantityText = _G.GetAchievementCriteriaInfo(id, i)
    if not done and Readable(text) then
      if #lines < MAX_CRITERIA then
        local line = { key = i, text = text }
        if flags and bit.band(flags, PROGRESS_BAR_FLAG) == PROGRESS_BAR_FLAG and required and required > 0 then
          line.bar = math.floor(100 * (quantity or 0) / required)
        elseif required and required > 1 and Readable(quantityText) and quantityText and quantityText ~= "" then
          line.text = quantityText.." "..text
        end
        table.insert(lines, line)
      else
        hidden = hidden + 1
      end
    end
  end
  if hidden > 0 then table.insert(lines, { key = "more", text = "..." }) end
  if count == 0 and Readable(description) and description and description ~= "" then
    table.insert(lines, { key = "text", text = description })
  end
  return {
    kind = "achievement", key = "a"..id, id = id, title = name,
    complete = completed and true or false, lines = lines,
  }
end

function Core.AchievementSection()
  local section = { key = "achievements", title = _G.TRACKER_HEADER_ACHIEVEMENTS or "Achievements", entries = {} }
  for _, id in ipairs(TrackedAchievements()) do
    local entry = AchievementEntry(id)
    if entry then table.insert(section.entries, entry) end
  end
  section.count = #section.entries
  return section
end

----
-- Recipes

local loading = {} -- item IDs whose name the game is still loading

local function ItemName(itemID)
  local name = _G.C_Item and _G.C_Item.GetItemNameByID and _G.C_Item.GetItemNameByID(itemID)
  if not name and _G.GetItemInfo then name = _G.GetItemInfo(itemID) end
  if not name and not loading[itemID] and _G.C_Item and _G.C_Item.RequestLoadItemDataByID then
    loading[itemID] = true
    _G.C_Item.RequestLoadItemDataByID(itemID)
  end
  return name
end

function Core.ItemLoaded(itemID)
  if loading[itemID] then
    loading[itemID] = nil
    return true
  end
  return false
end

local function ItemCount(itemID)
  local count = _G.C_Item and _G.C_Item.GetItemCount
  if count then return count(itemID, true, false, true) or 0 end
  return _G.GetItemCount and _G.GetItemCount(itemID, true) or 0
end

local function RecipeLines(schematic)
  local lines = {}
  local basic = _G.Enum and _G.Enum.CraftingReagentType and _G.Enum.CraftingReagentType.Basic
  for i, slot in ipairs(schematic and schematic.reagentSlotSchematics or {}) do
    local needed = slot.quantityRequired or 0
    local isBasic = basic == nil or slot.reagentType == nil or slot.reagentType == basic
    if needed > 0 and isBasic and (slot.required ~= false) and slot.reagents and slot.reagents[1] then
      -- Every quality of the reagent counts
      local have, name = 0, nil
      for _, reagent in ipairs(slot.reagents) do
        if reagent.itemID then
          have = have + ItemCount(reagent.itemID)
          name = name or ItemName(reagent.itemID)
        end
      end
      name = name or "..."
      table.insert(lines, {
        key = i, text = ("%d/%d %s"):format(math.min(have, needed), needed, name), done = have >= needed,
      })
    end
  end
  return lines
end

local function TrackedRecipes()
  local list = {}
  local TradeSkill = _G.C_TradeSkillUI
  if not (TradeSkill and TradeSkill.GetRecipesTracked) then return list end
  for _, recraft in ipairs({ false, true }) do
    local ok, ids = pcall(TradeSkill.GetRecipesTracked, recraft)
    if ok and type(ids) == "table" then
      for _, id in ipairs(ids) do table.insert(list, { id = id, recraft = recraft }) end
    end
  end
  return list
end

local function RecipeEntry(recipe)
  local TradeSkill = _G.C_TradeSkillUI
  local schematic
  if TradeSkill.GetRecipeSchematic then
    local ok, result = pcall(TradeSkill.GetRecipeSchematic, recipe.id, recipe.recraft)
    if ok then schematic = result end
  end
  local name = schematic and schematic.name
  if not name and TradeSkill.GetRecipeInfo then
    local ok, info = pcall(TradeSkill.GetRecipeInfo, recipe.id)
    name = ok and info and info.name
  end
  if not name and _G.C_Spell and _G.C_Spell.GetSpellName then name = _G.C_Spell.GetSpellName(recipe.id) end
  if not name and _G.GetSpellInfo then name = _G.GetSpellInfo(recipe.id) end
  if not Readable(name) or not name then return nil end
  if recipe.recraft then name = (_G.PROFESSIONS_CRAFTING_FORM_RECRAFTING or "Recrafting")..": "..name end
  return {
    kind = "recipe", key = "r"..recipe.id..(recipe.recraft and "r" or ""), id = recipe.id,
    recraft = recipe.recraft, title = name, lines = RecipeLines(schematic),
  }
end

function Core.RecipeSection()
  local section = { key = "recipes", title = _G.PROFESSIONS_TRACKER_HEADER_PROFESSION or "Professions", entries = {} }
  for _, recipe in ipairs(TrackedRecipes()) do
    local entry = RecipeEntry(recipe)
    if entry then table.insert(section.entries, entry) end
  end
  section.count = #section.entries
  return section
end

----
-- Quests a minimized zone of the old version stopped tracking (it hid them
-- that way): tracked again, the zone stays minimized

Core:OnChange(function (key)
  if key ~= "enable" then return end
  local hidden = Core.db.char.zoneHiddenQuests
  if not hidden or not next(hidden) then return end
  local function Restore()
    if InCombatLockdown() then
      C_Timer.After(5, Restore)
      return
    end
    for questID in pairs(hidden) do
      local inLog = C_QuestLog.IsOnQuest and C_QuestLog.IsOnQuest(questID)
        or C_QuestLog.GetLogIndexForQuestID(questID)
      if inLog and C_QuestLog.GetQuestWatchType(questID) == nil then
        Core.rewatched[questID] = GetTime()
        C_QuestLog.AddQuestWatch(questID)
      end
    end
    Core.db.char.zoneHiddenQuests = nil
  end
  -- (a moment after loading: the quest log is filled then)
  C_Timer.After(3, Restore)
end)
