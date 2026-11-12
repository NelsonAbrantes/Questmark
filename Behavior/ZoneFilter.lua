local _, ns = ...
local Core = ns.Core

-- luacheck: push ignore 113
local C_Map = C_Map
local C_QuestLog = C_QuestLog
local C_Timer = C_Timer
local CreateFrame = CreateFrame
local GetRealZoneText = GetRealZoneText
local GetTime = GetTime
local InCombatLockdown = InCombatLockdown
-- luacheck: pop

----
-- ZoneFilter
--
-- "Only quests in this zone" (Options, off by default): tracks the quests of
-- the zone you're in and stops tracking the others, again whenever you change
-- zone or accept a quest. The quests stay in your quest log. It's like
-- clicking them yourself, which the game only allows out of combat, so in
-- combat it waits until the fight is over. Turning it off tracks again the
-- quests it had stopped tracking.

local function Profile() return Core.db.profile end

-- Quests this filter stopped tracking (per character, kept between sessions)
local function Untracked()
  Core.db.char.zoneUntracked = Core.db.char.zoneUntracked or {}
  return Core.db.char.zoneUntracked
end

-- The filter runs with "Only quests in this zone" on
-- ("Dungeon quests only" no longer stops tracking quests: the tracker only
-- hides the others while you're inside, see Data.lua. The quests it had
-- stopped tracking are tracked again.)
local function Active()
  -- (with every quest showing, the tracker leaves the others out itself)
  return Profile().zoneOnly and not Profile().allQuests and true or false
end

local function IsTracked(questID)
  return C_QuestLog.GetQuestWatchType(questID) ~= nil
end

local pendingCombat = false

-- Tracks a quest again: noted, so it comes back without the new quest
-- animations (Tracker.lua)
local DropOld = Core.DropOld

local function Watch(questID)
  local now = GetTime()
  DropOld(Core.rewatched, now, 30)
  Core.rewatched[questID] = now
  C_QuestLog.AddQuestWatch(questID)
end

-- Quests with their marker in the zone you're in: questID -> true, or a
-- text saying why not (for /gft zone). The game's own "on the map" and its
-- list of quests on this zone's map both include nearby zones (in Mulgore
-- they kept The Barrens' quests), so each marker is checked: it must sit
-- inside this map, and the quest's own map must be this one.
local function MarkersHere()
  local result = {}
  local mapID = C_Map and C_Map.GetBestMapForUnit and C_Map.GetBestMapForUnit("player")
  if not mapID or not C_QuestLog.GetQuestsOnMap then return result, mapID end
  for _, quest in ipairs(C_QuestLog.GetQuestsOnMap(mapID) or {}) do
    local questID = quest.questID
    if questID then
      local x, y = quest.x, quest.y
      local inside = x and y and x >= 0 and x <= 1 and y >= 0 and y <= 1
      local questMap = _G.GetQuestUiMapID and _G.GetQuestUiMapID(questID)
      if inside and (not questMap or questMap == 0 or questMap == mapID) then
        result[questID] = true
      else
        result[questID] = ("x %s y %s quest map %s"):format(
          x and ("%.2f"):format(x) or "-", y and ("%.2f"):format(y) or "-", tostring(questMap))
      end
    end
  end
  return result, mapID
end

-- A quest just accepted for another zone stays a few seconds before it goes,
-- so it doesn't vanish right after it comes in
local GRACE = 6
local accepted = {} -- questID -> when it was accepted
local leaving = {}  -- questID -> fading out before it stops being tracked

-- The tracker's block of a quest, if it's shown
local function FindBlock(questID)
  local block = Core.FindBlock(questID)
  return block and block:IsVisible() and block or nil
end

local ApplySoon

-- Stops tracking a quest: it fades out first (Animations: Glass), then goes
local function Unwatch(questID, untracked)
  untracked[questID] = true
  local block = Core:Animates() and Core.FadeOutBlock and FindBlock(questID)
  if not block then
    C_QuestLog.RemoveQuestWatch(questID)
    return
  end
  leaving[questID] = true
  Core:FadeOutBlock(block, function ()
    leaving[questID] = nil
    if InCombatLockdown() then
      -- A fight started meanwhile: shown again, it goes after the fight
      block:SetAlpha(1)
      untracked[questID] = nil
      pendingCombat = true
    elseif IsTracked(questID) then
      C_QuestLog.RemoveQuestWatch(questID)
    end
  end)
end

local function Apply()
  if not (C_QuestLog and C_QuestLog.GetNumQuestLogEntries) then return end
  if InCombatLockdown() then
    pendingCombat = true
    return
  end

  local untracked = Untracked()

  -- Off: give back what it took
  if not Active() then
    for questID in pairs(untracked) do
      if C_QuestLog.GetLogIndexForQuestID(questID) and not IsTracked(questID) then
        Watch(questID)
      end
      untracked[questID] = nil
    end
    return
  end

  -- The quest log groups quests under zone names. Quests of other zones
  -- with their marker in this zone count too.
  local zone = GetRealZoneText()
  local onThisMap = MarkersHere()
  local header
  for i = 1, C_QuestLog.GetNumQuestLogEntries() do
    local info = C_QuestLog.GetInfo(i)
    if info then
      if info.isHeader then
        header = info.title
      elseif info.questID and not info.isHidden then
        local questID = info.questID
        local inZone = onThisMap[questID] == true or (header ~= nil and header == zone)
        if inZone and not IsTracked(questID) then
          Watch(questID)
          untracked[questID] = nil
        elseif not inZone and IsTracked(questID) and not leaving[questID] then
          local waited = GetTime() - (accepted[questID] or 0)
          if waited < GRACE then
            C_Timer.After(GRACE - waited + 0.1, ApplySoon)
          else
            accepted[questID] = nil
            Unwatch(questID, untracked)
          end
        end
      end
    end
  end
end

-- /gft zone: the zone, the map and, for each quest, why it's kept or not
function Core:ZoneDebug()
  local onThisMap, mapID = MarkersHere()
  print("|cffdfba69Glass Forever Tracker|r zone filter")
  print("  zoneOnly", tostring(Profile().zoneOnly), "instanceMode", tostring(Profile().instanceMode),
    "active", tostring(Active()), "combat wait", tostring(pendingCombat))
  print("  zone", tostring(GetRealZoneText()), "map", tostring(mapID))
  local header
  for i = 1, C_QuestLog.GetNumQuestLogEntries() do
    local info = C_QuestLog.GetInfo(i)
    if info then
      if info.isHeader then
        header = info.title
      elseif info.questID and not info.isHidden then
        print(("  %s | header %s | marker here %s | tracked %s"):format(
          tostring(info.title), tostring(header), tostring(onThisMap[info.questID] or false),
          tostring(IsTracked(info.questID))))
      end
    end
  end
end

-- Zone changes come with a few events in a row: apply once, a moment later
local pending = false
function ApplySoon()
  if pending then return end
  pending = true
  C_Timer.After(0.5, function ()
    pending = false
    Apply()
  end)
end

-- After logging in or /reload the game only fills the quest log and puts
-- back the tracked quests a few seconds later, undoing an early filter. It's
-- applied again then (it only changes what doesn't match).
local AFTER_LOADING = { 2, 5, 10 }
local waitingForLog = false

local events = CreateFrame("Frame")
events:SetScript("OnEvent", function (_, event, ...)
  if event == "QUEST_ACCEPTED" then
    -- (questID), or (quest log index, questID) in some game versions
    local first, second = ...
    local questID = second or first
    if questID then
      DropOld(accepted, GetTime(), 60)
      accepted[questID] = GetTime()
    end
  end
  if event == "PLAYER_REGEN_ENABLED" then
    if pendingCombat then
      pendingCombat = false
      ApplySoon()
    end
  elseif event == "QUEST_LOG_UPDATE" then
    -- The first full quest log after loading
    if waitingForLog and C_QuestLog.GetNumQuestLogEntries() > 0 then
      waitingForLog = false
      events:UnregisterEvent("QUEST_LOG_UPDATE")
      ApplySoon()
    end
  else
    ApplySoon()
    if event == "PLAYER_ENTERING_WORLD" then
      for _, delay in ipairs(AFTER_LOADING) do
        C_Timer.After(delay, Apply)
      end
      waitingForLog = true
      events:RegisterEvent("QUEST_LOG_UPDATE")
    end
  end
end)

Core:OnChange(function (key)
  if key == "enable" then
    events:RegisterEvent("PLAYER_ENTERING_WORLD")
    events:RegisterEvent("ZONE_CHANGED_NEW_AREA")
    events:RegisterEvent("QUEST_ACCEPTED")
    events:RegisterEvent("PLAYER_REGEN_ENABLED")
    ApplySoon()
    for _, delay in ipairs(AFTER_LOADING) do
      C_Timer.After(delay, Apply)
    end
  elseif key == "zoneOnly" or key == "instanceMode" or key == "profile" then
    ApplySoon()
  end
end)
