local _, ns = ...
local Core = ns.Core

-- luacheck: push ignore 113
local C_QuestLog = C_QuestLog
local C_SuperTrack = C_SuperTrack
local CreateFrame = CreateFrame
local hooksecurefunc = hooksecurefunc
-- luacheck: pop

----
-- Map: only the quests you track
--
-- The game's world map shows a marker for every quest in your quest log.
-- A quest you stopped tracking (in the tracker or the book) has its marker
-- hidden too (Options: Map shows tracked quests only). Not the quests the
-- "Only quests in this zone" filter stopped tracking itself: their markers
-- stay, for the other zones' maps. The quest you follow always shows. Only
-- runs while the map draws its markers.
--
-- Never asks the map to redraw itself (RefreshAllDataProviders): run by an
-- addon, the markers it makes then are the addon's, and the game can't use
-- them in combat any more (ADDON_ACTION_BLOCKED, SetPassThroughButtons).
-- Only hides, and shows again, the markers the map made itself.

local MAP_PIN = "QuestPinTemplate"

local function On() return Core.db.profile.mapTrackedOnly ~= false end

-- The quest was stopped tracking by you
local function Stopped(questID)
  if type(questID) ~= "number" then return false end
  if C_SuperTrack and C_SuperTrack.GetSuperTrackedQuestID() == questID then return false end
  if Core.db.profile.allQuests then
    local hidden = Core.db.char.hiddenQuests
    return hidden and hidden[questID] and true or false
  end
  local byZone = Core.db.char.zoneUntracked
  if byZone and byZone[questID] then return false end
  return C_QuestLog.GetQuestWatchType(questID) == nil
end

local hid = setmetatable({}, { __mode = "k" }) -- the markers hidden here

local function HidePins()
  local map = _G.WorldMapFrame
  if not (map and map:IsShown() and map.EnumeratePinsByTemplate) then return end
  local on = On()
  for pin in map:EnumeratePinsByTemplate(MAP_PIN) do
    if on and Stopped(pin.questID) then
      if pin:IsShown() then
        pin:Hide()
        hid[pin] = true
      end
    elseif hid[pin] then
      -- tracked again, or the option turned off
      hid[pin] = nil
      pin:Show()
    end
  end
end

-- (after each of the map's own redraws: hooked once, on its first opening)
local hooked = false
local function HookMap()
  local map = _G.WorldMapFrame
  if hooked or not (map and type(map.dataProviders) == "table") then return end
  hooked = true
  for provider in pairs(map.dataProviders) do
    if type(provider.RefreshAllData) == "function" then
      hooksecurefunc(provider, "RefreshAllData", HidePins)
    end
  end
  HidePins()
end

local events = CreateFrame("Frame")
-- a quest tracked or not any more, with the map open
events:SetScript("OnEvent", HidePins)

Core:OnChange(function (key)
  if key == "enable" then
    local map = _G.WorldMapFrame
    if map then map:HookScript("OnShow", HookMap) end
    pcall(events.RegisterEvent, events, "QUEST_WATCH_LIST_CHANGED")
  elseif key == "layout" or key == "mapTrackedOnly" then
    -- (a quest hidden from the tracker with All quests on, or the option)
    HidePins()
  end
end)
