local _, ns = ...
local Core = ns.Core

-- luacheck: push ignore 113
local C_QuestLog = C_QuestLog
local C_Timer = C_Timer
local CreateFrame = CreateFrame
local GetTime = GetTime
-- luacheck: pop

----
-- FollowNext
--
-- "Follow the next quest" (Options, Quest GPS page, on by default): when
-- you turn in the quest you were following, the nearest of the quests the
-- tracker shows is followed, so the GPS goes on to it. Nothing happens if
-- you weren't following the quest you turned in.

local function Profile() return Core.db.profile end

local events = CreateFrame("Frame")

-- The quest followed, and the one followed before it stopped (the game may
-- stop following a quest as it's turned in, just before saying so)
local followed, lastFollowed, stoppedAt = 0, 0, 0

local function Followed()
  local SuperTrack = _G.C_SuperTrack
  return SuperTrack and SuperTrack.GetSuperTrackedQuestID and SuperTrack.GetSuperTrackedQuestID() or 0
end

-- The nearest quest shown in the tracker (on this continent first), but
-- the one turned in
local function Nearest(except)
  local Distance = C_QuestLog.GetDistanceSqToQuest
  local best, bestDistance, bestHere
  for _, questID in ipairs(Core.ShownQuestIDs()) do
    if questID ~= except and C_QuestLog.GetLogIndexForQuestID(questID) then
      local distance, here
      if Distance then distance, here = Distance(questID) end
      distance = tonumber(distance) or math.huge
      here = here and true or false
      if not best or (here and not bestHere) or (here == bestHere and distance < bestDistance) then
        best, bestDistance, bestHere = questID, distance, here
      end
    end
  end
  return best
end

events:SetScript("OnEvent", function (_, event, questID)
  if event == "SUPER_TRACKING_CHANGED" then
    local now = Followed()
    if now == 0 and followed ~= 0 then
      lastFollowed, stoppedAt = followed, GetTime()
    end
    followed = now
  elseif event == "QUEST_TURNED_IN" then
    if not Profile().followNext or not questID then return end
    local now = Followed()
    local was = now == questID or (now == 0 and lastFollowed == questID and GetTime() - stoppedAt < 2)
    if not was then return end
    -- (once the quest has left the log)
    C_Timer.After(0.5, function ()
      local current = Followed()
      if current ~= 0 and current ~= questID then return end -- (followed something else meanwhile)
      local nextQuest = Nearest(questID)
      if nextQuest and Core.FollowQuest then Core.FollowQuest(nextQuest) end
    end)
  end
end)

Core:OnChange(function (key)
  if key == "enable" then
    followed = Followed()
    for _, event in ipairs({ "SUPER_TRACKING_CHANGED", "QUEST_TURNED_IN" }) do
      pcall(events.RegisterEvent, events, event)
    end
  end
end)
