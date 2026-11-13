local _, ns = ...
local Core = ns.Core

-- luacheck: push ignore 113
local C_QuestLog = C_QuestLog
local C_Timer = C_Timer
local CreateFrame = CreateFrame
local PlaySound = PlaySound
local PlaySoundFile = PlaySoundFile
local SOUNDKIT = SOUNDKIT
local wipe = wipe
-- luacheck: pop

----
-- Sounds
--
-- A discreet sound when a quest objective is done, and another when a quest
-- is ready to turn in (Options: Sound on complete). Works from the quest log,
-- comparing it with how it was a moment before.

-- The orc peon's "Work complete!" (Options: Orc voice on quest complete)
local ORC_VOICE = 558132 -- Sound/Creature/Peon/PeonBuildingComplete1.ogg

-- How the quest log was, and how it is now: questID -> finished objectives,
-- and questID -> ready to turn in. Two sets of tables, swapped and reused on
-- every check (new ones every time were garbage for the game to clean up).
local knownDone, knownComplete = {}, {}
local nowDone, nowComplete = {}, {}
local hasKnown = false

local function Snapshot()
  wipe(nowDone)
  wipe(nowComplete)
  if not (C_QuestLog and C_QuestLog.GetNumQuestLogEntries) then return end
  for i = 1, C_QuestLog.GetNumQuestLogEntries() do
    local info = C_QuestLog.GetInfo(i)
    if info and not info.isHeader and info.questID then
      local done = 0
      local objectives = C_QuestLog.GetQuestObjectives(info.questID)
      if objectives then
        for _, objective in ipairs(objectives) do
          if objective.finished then done = done + 1 end
        end
      end
      nowDone[info.questID] = done
      nowComplete[info.questID] = C_QuestLog.IsComplete(info.questID) and true or false
    end
  end
end

local function Play(sound)
  if sound then PlaySound(sound) end
end

local function Check()
  -- Sound off: nothing to compare (the first check after turning it on
  -- only remembers how things are)
  if not Core.db.profile.completeSound then
    hasKnown = false
    return
  end
  Snapshot()
  if hasKnown then
    local questDone, objectiveDone = false, false
    for questID, done in pairs(nowDone) do
      local before = knownDone[questID]
      if before then
        if nowComplete[questID] and not knownComplete[questID] then
          questDone = true
        elseif done > before then
          objectiveDone = true
        end
      end
    end
    -- One sound at a time: a finished quest wins over its last objective
    if questDone and Core.db.profile.orcVoice then
      PlaySoundFile(ORC_VOICE)
    elseif questDone then
      Play(SOUNDKIT and SOUNDKIT.IG_QUEST_LIST_COMPLETE)
    elseif objectiveDone then
      Play(SOUNDKIT and SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON)
    end
  end
  -- Now becomes how it was; the old tables are reused next time
  knownDone, nowDone = nowDone, knownDone
  knownComplete, nowComplete = nowComplete, knownComplete
  hasKnown = true
end

-- The quest log changes in bursts: check once after each burst
local pending = false
local function CheckNow()
  pending = false
  Check()
end
local function CheckSoon()
  if pending then return end
  pending = true
  C_Timer.After(0.2, CheckNow)
end

local events = CreateFrame("Frame")
events:SetScript("OnEvent", CheckSoon)

-- Only listened to while the sound is on (Options)
local function Listen()
  if Core.db.profile.completeSound then
    events:RegisterEvent("QUEST_LOG_UPDATE")
    events:RegisterEvent("QUEST_WATCH_UPDATE")
    -- The first look only remembers how things are (no sounds on login)
    CheckSoon()
  else
    events:UnregisterAllEvents()
    hasKnown = false
  end
end

Core:OnChange(function (key)
  if key == "enable" or key == "completeSound" or key == "profile" then Listen() end
end)
