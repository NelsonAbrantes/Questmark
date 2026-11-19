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
-- book's "Completed" list: { id, title, zone, level, at, xp, money }. Only
-- the last MAX are kept. A quest's note (the book) goes when it's turned in.

local MAX = 300

local events = CreateFrame("Frame")

---
-- The quests turned in, newest first
function Core.QuestHistory()
  Core.db.char.questHistory = Core.db.char.questHistory or {}
  return Core.db.char.questHistory
end

---
-- The notes written in the book (questID -> text)
function Core.QuestNotes()
  Core.db.char.questNotes = Core.db.char.questNotes or {}
  return Core.db.char.questNotes
end

-- The book's "Completed" zone, in the list of zones closed (no zone of the
-- game can be called that)
Core.HISTORY_KEY = "\1history"

---
-- A quest turned in, under the mouse in the book: its zone, when, and what
-- it gave
function Core.HistoryTooltip(owner, done)
  local tooltip = _G.GameTooltip
  tooltip:SetOwner(owner, "ANCHOR_RIGHT")
  tooltip:SetText(done.title or "", 1, 0.82, 0)
  if done.zone then tooltip:AddLine(done.zone, 1, 1, 1) end
  if done.at then tooltip:AddLine("Turned in "..date("%d %b %Y, %H:%M", done.at), 0.8, 0.8, 0.8) end
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

events:SetScript("OnEvent", function (_, _, questID, xp, money)
  if not questID then return end
  local title = C_QuestLog.GetTitleForQuestID and C_QuestLog.GetTitleForQuestID(questID)
  if not (Core.Readable(title) and title and title ~= "") then return end
  local zone, level = FromLog(questID)
  local history = Core.QuestHistory()
  table.insert(history, 1, {
    id = questID, title = title, zone = Core.Readable(zone) and zone or nil, level = level,
    at = time(), xp = tonumber(xp) or 0, money = tonumber(money) or 0,
  })
  for i = #history, MAX + 1, -1 do history[i] = nil end
  Core.QuestNotes()[questID] = nil
end)

Core:OnChange(function (key)
  if key == "enable" then pcall(events.RegisterEvent, events, "QUEST_TURNED_IN") end
end)
