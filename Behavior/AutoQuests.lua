local _, ns = ...
local Core = ns.Core

-- luacheck: push ignore 113
local CreateFrame = CreateFrame
local IsShiftKeyDown = IsShiftKeyDown
-- luacheck: pop

----
-- Quests taken and given back by themselves (Options: Accept and turn in
-- quests). Talking to someone takes the quests they offer and gives back the
-- ones ready. Never when a reward must be chosen, a quest asks for money,
-- someone in the party isn't done with it, or Shift is held. Off by default; nothing listens while it's off.

local events = CreateFrame("Frame")
local EVENTS = { "GOSSIP_SHOW", "QUEST_GREETING", "QUEST_DETAIL", "QUEST_PROGRESS", "QUEST_COMPLETE" }

local function Call(name, ...)
  local fn = _G[name]
  if fn then pcall(fn, ...) end
end

-- Someone with things to say and quests: the first quest ready, else the
-- first offered (a gray one isn't taken by itself)
local function FromGossip()
  local Gossip = _G.C_GossipInfo
  if not Gossip then return end
  for _, quest in ipairs(Gossip.GetActiveQuests and Gossip.GetActiveQuests() or {}) do
    if quest.isComplete and quest.questID then
      Gossip.SelectActiveQuest(quest.questID)
      return
    end
  end
  for _, quest in ipairs(Gossip.GetAvailableQuests and Gossip.GetAvailableQuests() or {}) do
    if not quest.isTrivial and quest.questID then
      Gossip.SelectAvailableQuest(quest.questID)
      return
    end
  end
end

-- Someone with only quests (the old quest window)
local function FromGreeting()
  for i = 1, (_G.GetNumActiveQuests and _G.GetNumActiveQuests() or 0) do
    local _, complete = _G.GetActiveTitle(i)
    if complete then Call("SelectActiveQuest", i) return end
  end
  for i = 1, (_G.GetNumAvailableQuests and _G.GetNumAvailableQuests() or 0) do
    local trivial = _G.GetAvailableQuestInfo and select(1, _G.GetAvailableQuestInfo(i))
    if not trivial then Call("SelectAvailableQuest", i) return end
  end
end

events:SetScript("OnEvent", function (_, event)
  if IsShiftKeyDown() then return end
  if event == "GOSSIP_SHOW" then
    FromGossip()
  elseif event == "QUEST_GREETING" then
    FromGreeting()
  elseif event == "QUEST_DETAIL" then
    -- (quests the game takes by itself need nothing)
    if not (_G.QuestGetAutoAccept and _G.QuestGetAutoAccept()) then Call("AcceptQuest") end
  elseif (event == "QUEST_PROGRESS" or event == "QUEST_COMPLETE")
    and Core.GroupBehind and Core.GroupBehind(_G.GetQuestID and _G.GetQuestID()) then
    -- (someone in the party isn't done with it: turned in by hand, if
    -- you mean it. GroupLead.lua says who)
    return
  elseif event == "QUEST_PROGRESS" then
    local money = _G.GetQuestMoneyToGet and _G.GetQuestMoneyToGet() or 0
    if _G.IsQuestCompletable and _G.IsQuestCompletable() and money == 0 then Call("CompleteQuest") end
  elseif event == "QUEST_COMPLETE" then
    local choices = _G.GetNumQuestChoices and _G.GetNumQuestChoices() or 0
    if choices <= 1 then Call("GetQuestReward", choices) end
  end
end)

local function Update()
  local on = Core.db.profile.autoQuests == true
  for _, event in ipairs(EVENTS) do
    if on then
      pcall(events.RegisterEvent, events, event)
    else
      pcall(events.UnregisterEvent, events, event)
    end
  end
end

Core:OnChange(function (key)
  if key == "enable" or key == "autoQuests" or key == "profile" then Update() end
end)
