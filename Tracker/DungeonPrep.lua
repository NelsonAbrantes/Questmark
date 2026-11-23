local _, ns = ...
local Core = ns.Core

-- luacheck: push ignore 113
local C_Map = C_Map
local C_QuestLog = C_QuestLog
local C_Timer = C_Timer
local CreateFrame = CreateFrame
local IsInInstance = IsInInstance
local UnitLevel = UnitLevel
local wipe = wipe
-- luacheck: pop

----
-- Before you go in
--
-- Near a dungeon's entrance (Options: Dungeon quests before going in), a
-- section at the top of the tracker with that dungeon's quests: the ones you
-- have checked, and the ones you're missing with where to get them, so you
-- don't go in without half of them. Quests done, of the other faction or of
-- a level you haven't reached yet aren't listed.
-- Its quests and entrances come from the ForeverDungeonJournal addon (and the
-- game's own entrances, where it has them). Right click: hidden until you
-- leave.
-- It only looks how near you are (every 2 seconds) in a zone with an
-- entrance, and never inside.

local NEAR = 150 -- yards from the entrance it shows
local AWAY = 220 -- and goes again (a little further: no going and coming at the edge)
local EVERY = 2  -- seconds between looks

local events = CreateFrame("Frame")
local byMap -- map -> its entrances: { name, x, y }
local watching = {} -- the entrances of the maps you're on
local ticker
local near -- the dungeon whose entrance you're near
local hidden = {} -- dungeons hidden by a right click, until you leave

local function Journal()
  local journal = _G.ForeverDungeonJournal_NS
  return type(journal) == "table" and type(journal.DB) == "table" and journal.DB or nil
end

-- Every entrance, by the map it's on
local function Entrances()
  if byMap then return byMap end
  byMap = {}
  local db = Journal()
  if not db then return byMap end
  local function Add(mapID, name, x, y)
    if not (mapID and name and x and y) then return end
    byMap[mapID] = byMap[mapID] or {}
    for _, one in ipairs(byMap[mapID]) do
      if one.name == name then return end
    end
    table.insert(byMap[mapID], { name = name, x = x, y = y })
  end
  for name, dungeon in pairs(db) do
    local entrance = type(dungeon) == "table" and dungeon.entrance
    if type(entrance) == "table" and type(dungeon.quests) == "table" then
      Add(entrance.mapID, name, entrance.x, entrance.y)
    end
  end
  return byMap
end

-- The game's own entrances on a map (the ones the journal addon knows)
local function GameEntrances(mapID)
  local Journal_ = _G.C_EncounterJournal
  local db = Journal()
  if not (db and Journal_ and Journal_.GetDungeonEntrancesForMap) then return end
  local ok, list = pcall(Journal_.GetDungeonEntrancesForMap, mapID)
  if not ok or type(list) ~= "table" then return end
  Entrances()
  for _, info in ipairs(list) do
    local name, position = info.name, info.position
    if name and db[name] and type(db[name].quests) == "table" and position then
      byMap[mapID] = byMap[mapID] or {}
      local known = false
      for _, one in ipairs(byMap[mapID]) do
        if one.name == name then known = true end
      end
      if not known then table.insert(byMap[mapID], { name = name, x = position.x, y = position.y }) end
    end
  end
end

-- How far (yards) you are from a spot on a map; nil if you're not on it
local function Distance(mapID, x, y)
  local position = C_Map.GetPlayerMapPosition(mapID, "player")
  if not position or not C_Map.GetWorldPosFromMapPos then return nil end
  local px, py = position:GetXY()
  if not px or (px == 0 and py == 0) then return nil end
  local Vector = _G.CreateVector2D
  local _, here = C_Map.GetWorldPosFromMapPos(mapID, position)
  local _, there = C_Map.GetWorldPosFromMapPos(mapID, Vector(x, y))
  if not (here and there) then return nil end
  local dx, dy = here.x - there.x, here.y - there.y
  return math.sqrt(dx * dx + dy * dy)
end

local function Look()
  local was = near
  local found, closest
  for _, entrance in ipairs(watching) do
    local yards = Distance(entrance.mapID, entrance.x, entrance.y)
    local reach = entrance.name == near and AWAY or NEAR
    if yards and yards <= reach and (not closest or yards < closest) then
      found, closest = entrance.name, yards
    end
  end
  if was and found ~= was then hidden[was] = nil end
  near = found
  if near ~= was then Core.Refresh() end
end

-- The zone changed: the entrances of the maps you're on (a town or a cave,
-- and the zone around it)
local function Watch()
  wipe(watching)
  local inInstance = IsInInstance()
  if Core.db.profile.dungeonPrep ~= false and not inInstance and Journal() then
    local mapID = C_Map.GetBestMapForUnit("player")
    local all = Entrances()
    for _ = 1, 4 do
      if not mapID then break end
      GameEntrances(mapID)
      for _, one in ipairs(all[mapID] or {}) do
        watching[#watching + 1] = { mapID = mapID, name = one.name, x = one.x, y = one.y }
      end
      local info = C_Map.GetMapInfo(mapID)
      mapID = info and info.parentMapID
    end
  end
  if #watching > 0 then
    if not ticker then ticker = C_Timer.NewTicker(EVERY, Look) end
    Look()
  else
    if ticker then ticker:Cancel() ticker = nil end
    if near then
      hidden[near] = nil
      near = nil
      Core.Refresh()
    end
  end
end

----
-- The section

local function Faction(quest)
  local mine = _G.UnitFactionGroup("player")
  return not quest.faction or quest.faction == mine or quest.faction == "Both" or quest.faction == "Neutral"
end

function Core.PrepSection()
  local section = { key = "prep", title = "Before you go in", entries = {}, count = 0 }
  local db = Journal()
  local dungeon = near and not hidden[near] and db and db[near]
  if not dungeon or Core.db.profile.dungeonPrep == false then return section end
  local level = UnitLevel("player")
  local have, missing = {}, {}
  for _, quest in ipairs(dungeon.quests) do
    local id = quest.id
    local done = id and C_QuestLog.IsQuestFlaggedCompleted and C_QuestLog.IsQuestFlaggedCompleted(id)
    if id and quest.name and not done and Faction(quest) then
      if C_QuestLog.GetLogIndexForQuestID(id) then
        have[#have + 1] = { key = "h"..id, text = quest.name, check = true, ready = true }
      elseif not quest.requires or quest.requires <= level then
        local from = quest.pickup and (" |cff999999- "..quest.pickup.."|r") or ""
        missing[#missing + 1] = { key = "m"..id, text = quest.name..from }
      end
    end
  end
  local total = #have + #missing
  if total == 0 then return section end
  local lines = {
    { key = "count", plain = true,
      text = #missing == 0 and "You have all "..total.." of its quests"
        or ("You have %d of its %d quests"):format(#have, total) },
  }
  for _, line in ipairs(have) do lines[#lines + 1] = line end
  for _, line in ipairs(missing) do lines[#lines + 1] = line end
  section.entries[1] = { kind = "prep", key = "p:"..near, id = near, title = near, lines = lines }
  section.count = 1
  return section
end

---
-- Right click: hidden until you leave its entrance
function Core.HidePrep(name)
  hidden[name] = true
  Core.Refresh()
end

----
-- Events

events:SetScript("OnEvent", function (_, event)
  if event == "QUEST_ACCEPTED" or event == "QUEST_REMOVED" or event == "QUEST_TURNED_IN" then
    if near then Core.Refresh() end
    return
  end
  -- (a moment later: the new map is known then)
  C_Timer.After(0.5, Watch)
end)

Core:OnChange(function (key)
  if key == "enable" then
    if not Core.trackerOn then return end
    for _, event in ipairs({
      "PLAYER_ENTERING_WORLD", "ZONE_CHANGED_NEW_AREA", "ZONE_CHANGED", "ZONE_CHANGED_INDOORS",
      "QUEST_ACCEPTED", "QUEST_REMOVED", "QUEST_TURNED_IN",
    }) do
      pcall(events.RegisterEvent, events, event)
    end
  elseif key == "dungeonPrep" or key == "profile" then
    Watch()
    Core.Refresh()
  end
end)
