local _, ns = ...
local Core = ns.Core

-- luacheck: push ignore 113
local C_QuestLog = C_QuestLog
local CreateFrame = CreateFrame
-- luacheck: pop

----
-- History
--
-- The quests you turned in (per character), newest first, for the quest
-- book's red ribbon: { id, title, zone, level, at, xp, money, text,
-- objectives, rewards, chosen, times }. Only the last MAX are kept.
-- A quest turned in again (a repeatable one) is kept once, at the top, with
-- how many times (times).
-- The text and rewards are read when the quest's reward window opens (it's
-- still in the quest log then), and the reward chosen when it's taken.

local MAX = 300

local events = CreateFrame("Frame")
local pending -- the quest whose reward window is open: what it was

-- A quest never in the quest log (one handed in straight away, like the
-- repeatable ones): its text and rewards from the reward window
local function FromWindow(read)
  local text = _G.GetRewardText and _G.GetRewardText()
  read.text = Core.Readable(text) and text or nil
  local found = {
    items = {}, choices = {},
    xp = _G.GetRewardXP and _G.GetRewardXP() or 0,
    money = _G.GetRewardMoney and _G.GetRewardMoney() or 0,
  }
  local function Add(list, kind, count)
    for i = 1, count or 0 do
      local name, texture, amount, quality, _, itemID = _G.GetQuestItemInfo(kind, i)
      list[#list + 1] = {
        kind = kind, index = i, name = name, texture = texture, amount = amount, quality = quality, itemID = itemID,
        link = _G.GetQuestItemLink and _G.GetQuestItemLink(kind, i),
      }
    end
  end
  if _G.GetQuestItemInfo then
    Add(found.items, "reward", _G.GetNumQuestRewards and _G.GetNumQuestRewards())
    Add(found.choices, "choice", _G.GetNumQuestChoices and _G.GetNumQuestChoices())
  end
  read.rewards = found
  return read
end

-- Its text and rewards (with the items' links, kept for their tooltips)
local function Read(questID)
  local read = { id = questID }
  if not (C_QuestLog.GetLogIndexForQuestID and C_QuestLog.GetLogIndexForQuestID(questID)) then
    return FromWindow(read)
  end
  if Core.BookQuestText then read.text, read.objectives = Core.BookQuestText(questID) end
  local rewards = Core.BookRewards and Core.BookRewards(questID)
  if rewards then
    for _, list in ipairs({ rewards.items, rewards.choices }) do
      for _, item in ipairs(list) do
        if item.kind ~= "currency" and _G.GetQuestLogItemLink then
          item.link = _G.GetQuestLogItemLink(item.kind, item.index, questID)
        end
      end
    end
    read.rewards = rewards
  end
  return read
end

-- The reward chosen (its place among the choices)
if _G.GetQuestReward then
  hooksecurefunc("GetQuestReward", function (choice)
    if pending and tonumber(choice) and choice > 0 then pending.chosen = choice end
  end)
end

---
-- The quests turned in, newest first
local merged -- (the history kept before: its repeats put together, once)
function Core.QuestHistory()
  Core.db.char.questHistory = Core.db.char.questHistory or {}
  local history = Core.db.char.questHistory
  if not merged then
    merged = true
    local first = {}
    for i = 1, #history do
      local done = history[i]
      local kept = done.id and first[done.id]
      if kept then
        kept.times = (kept.times or 1) + (done.times or 1)
        kept.text = kept.text or done.text
        history[i] = false
      elseif done.id then
        first[done.id] = done
      end
    end
    for i = #history, 1, -1 do
      if not history[i] then table.remove(history, i) end
    end
  end
  return history
end

---
-- A quest turned in, under the mouse in the book: its zone, when, and what
-- it gave
function Core.HistoryTooltip(owner, done)
  local tooltip = _G.GameTooltip
  tooltip:SetOwner(owner, "ANCHOR_RIGHT")
  tooltip:SetText(done.title or "", 1, 0.82, 0)
  if done.zone then tooltip:AddLine(done.zone, 1, 1, 1) end
  if done.at then
    local last = (done.times or 1) > 1 and done.times.." times, last " or ""
    tooltip:AddLine("Turned in "..last..date("%d %b %Y, %H:%M", done.at), 0.8, 0.8, 0.8)
  end
  if (done.xp or 0) > 0 then
    local Big = _G.BreakUpLargeNumbers
    tooltip:AddLine((Big and Big(done.xp) or tostring(done.xp)).." XP", 0.6, 0.4, 0.9)
  end
  if (done.money or 0) > 0 and _G.GetMoneyString then
    tooltip:AddLine(_G.GetMoneyString(done.money), 1, 1, 1)
  end
  tooltip:Show()
end

-- A quest's zone and level, read from the quest log while it's still there
local function FromLog(questID)
  local index = C_QuestLog.GetLogIndexForQuestID and C_QuestLog.GetLogIndexForQuestID(questID)
  if not index then return nil, nil end
  local info = C_QuestLog.GetInfo(index)
  local level = info and info.level
  for i = index - 1, 1, -1 do
    local header = C_QuestLog.GetInfo(i)
    if header and header.isHeader then return header.title, level end
  end
  return nil, level
end

events:SetScript("OnEvent", function (_, event, questID, xp, money)
  if event == "QUEST_COMPLETE" then
    local id = _G.GetQuestID and _G.GetQuestID()
    pending = id and id > 0 and Read(id) or nil
    return
  end
  if not questID then return end
  local read = pending and pending.id == questID and pending or {}
  pending = nil
  local title = C_QuestLog.GetTitleForQuestID and C_QuestLog.GetTitleForQuestID(questID)
  if not (Core.Readable(title) and title and title ~= "") then return end
  local zone, level = FromLog(questID)
  local history = Core.QuestHistory()
  -- (turned in before: that one taken out, counted)
  local times, before = 1, nil
  for i, done in ipairs(history) do
    if done.id == questID then
      before = table.remove(history, i)
      times = (before.times or 1) + 1
      break
    end
  end
  table.insert(history, 1, {
    id = questID, title = title, zone = Core.Readable(zone) and zone or nil, level = level,
    at = time(), xp = tonumber(xp) or 0, money = tonumber(money) or 0,
    text = read.text or before and before.text, objectives = read.objectives,
    rewards = read.rewards, chosen = read.chosen, times = times > 1 and times or nil,
  })
  for i = #history, MAX + 1, -1 do history[i] = nil end
end)

Core:OnChange(function (key)
  if key == "enable" then
    pcall(events.RegisterEvent, events, "QUEST_TURNED_IN")
    pcall(events.RegisterEvent, events, "QUEST_COMPLETE")
  end
end)
