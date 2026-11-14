local _, ns = ...
local Core = ns.Core

-- luacheck: push ignore 113
local C_Container = C_Container
local C_Item = C_Item
local C_QuestLog = C_QuestLog
local C_Timer = C_Timer
local CreateFrame = CreateFrame
-- luacheck: pop

----
-- Quest items no longer needed
--
-- Quest items left in the bags after their quest: one for a quest you turned
-- in (and no longer have), or one no quest you have asks for. Its tooltip
-- says so and, with Baganator, a mark shows in a corner of the item (its
-- option: Corner icons). Never an item that starts a quest you haven't done.
-- It can't know about a quest you haven't taken yet that would need it, so
-- it says "probably". Nothing runs until an item's tooltip shows or
-- Baganator draws the bags.

local MARK = "Interface\\RaidFrame\\ReadyCheck-NotReady" -- the game's red cross
local QUEST_CLASS = 12 -- Enum.ItemClass.Questitem
local BAGS = 5 -- the backpack (0) and the bags after it

local function On() return Core.db.profile.questItemMarks ~= false end

-- Everything the quests you have say, lower case: their objectives (counted
-- ones, like "Scarab Shell: 0/5", and the written ones, like "Deliver the
-- Cask of..."), and their descriptions. Made again when a quest comes or
-- goes. Nil while the quest log isn't there yet, or a text can't be read:
-- then nothing is marked.
local asked, dirty = nil, true

-- (the game gives a quest's texts for the quest selected in its log: chosen
-- for a moment, then the one before put back)
local function QuestTexts(questID, index)
  local GetText = _G.GetQuestLogQuestText
  if not GetText then return nil end
  local before = C_QuestLog.GetSelectedQuest and C_QuestLog.GetSelectedQuest()
  C_QuestLog.SetSelectedQuest(questID)
  local ok, description, objectives = pcall(GetText, index)
  if before then C_QuestLog.SetSelectedQuest(before) end
  if not ok then return nil end
  return description, objectives
end

local function Asked()
  if not dirty then return asked end
  local count = C_QuestLog.GetNumQuestLogEntries()
  if count == 0 then return nil end
  local parts = {}
  for i = 1, count do
    local info = C_QuestLog.GetInfo(i)
    if info and not info.isHeader and info.questID then
      for _, objective in ipairs(C_QuestLog.GetQuestObjectives(info.questID) or {}) do
        if not Core.Readable(objective.text) then return nil end
        if objective.text then parts[#parts + 1] = objective.text end
      end
      local description, objectives = QuestTexts(info.questID, i)
      if not (Core.Readable(description) and Core.Readable(objectives)) then return nil end
      parts[#parts + 1] = description or ""
      parts[#parts + 1] = objectives or ""
    end
  end
  dirty = false
  asked = table.concat(parts, "\n"):lower()
  return asked
end

---
-- The item in a bag's slot is a quest item no longer needed: true or false
-- (nil: not known yet, its name still loading)
local function Unneeded(bag, slot)
  if not (C_Container and C_Container.GetContainerItemQuestInfo) then return false end
  local quest = C_Container.GetContainerItemQuestInfo(bag, slot)
  if not (quest and (quest.isQuestItem or quest.questID)) then return false end
  local questID = quest.questID
  if questID and questID > 0 then
    -- its quest: needed while you have it; a quest not done yet, it starts
    if C_QuestLog.GetLogIndexForQuestID(questID) then return false end
    local done = C_QuestLog.IsQuestFlaggedCompleted and C_QuestLog.IsQuestFlaggedCompleted(questID)
    return done and true or false
  end
  -- no quest of its own: needed while a quest you have names it anywhere
  local itemID = C_Container.GetContainerItemID(bag, slot)
  local name = itemID and C_Item.GetItemNameByID(itemID)
  if not (Core.Readable(name) and name) then return nil end
  local texts = Asked()
  if not texts then return nil end
  return not texts:find(name:lower(), 1, true)
end

----
-- The tooltip: a line under a quest item no longer needed

local function FindInBags(itemID, owner)
  -- (the bag button under the mouse, when it says where it is)
  if owner and owner.GetBagID and owner.GetID then
    local ok, bag = pcall(owner.GetBagID, owner)
    if ok and type(bag) == "number" then return bag, owner:GetID() end
  end
  for bag = 0, BAGS do
    for slot = 1, C_Container.GetContainerNumSlots(bag) do
      if C_Container.GetContainerItemID(bag, slot) == itemID then return bag, slot end
    end
  end
  return nil
end

local function OnItemTooltip(tooltip, data)
  if tooltip ~= _G.GameTooltip or not On() or not (data and data.id) then return end
  if not Core.Readable(data.id) then return end
  -- (only quest items: nothing to look for in the bags for the others)
  local classID = select(6, C_Item.GetItemInfoInstant(data.id))
  if classID ~= QUEST_CLASS then return end
  local bag, slot = FindInBags(data.id, tooltip:GetOwner())
  if bag and Unneeded(bag, slot) then
    tooltip:AddLine("Questmark: probably no longer needed for a quest", 1, 0.45, 0.35, true)
  end
end

----
-- Baganator: a red cross in a corner of the item

local refreshing = false
local function RefreshBags()
  local API = _G.Baganator and _G.Baganator.API
  if not (API and API.RequestItemButtonsRefresh) or refreshing then return end
  refreshing = true
  C_Timer.After(0.5, function ()
    refreshing = false
    pcall(API.RequestItemButtonsRefresh)
  end)
end

local function RegisterBaganator()
  local API = _G.Baganator and _G.Baganator.API
  if not (API and API.RegisterCornerWidget) then return end
  pcall(API.RegisterCornerWidget, "Questmark: quest item no longer needed", "questmark_unneeded",
    function (mark, details)
      if not On() then return false end
      local location = details and details.itemLocation
      if not (location and location.GetBagAndSlot and C_Item.DoesItemExist(location)) then return false end
      local bag, slot = location:GetBagAndSlot()
      if not (bag and slot) then return false end
      local unneeded = Unneeded(bag, slot)
      if unneeded == nil then return nil end
      mark:SetShown(unneeded)
      return unneeded
    end,
    function (button)
      local mark = button:CreateTexture(nil, "OVERLAY")
      mark:SetTexture(MARK)
      mark:SetSize(14, 14)
      mark.padding = 0
      return mark
    end,
    { corner = "top_left", priority = 1 })
end

----

local events = CreateFrame("Frame")
events:SetScript("OnEvent", function ()
  -- a quest came or went: what's needed changed
  dirty = true
  RefreshBags()
end)

-- (on loading: Baganator, listed in the toc's OptionalDeps, is there already)
Core:OnChange(function (key)
  if key == "enable" then
    RegisterBaganator()
    local Processor = _G.TooltipDataProcessor
    local Types = _G.Enum and _G.Enum.TooltipDataType
    if Processor and Processor.AddTooltipPostCall and Types and Types.Item then
      Processor.AddTooltipPostCall(Types.Item, OnItemTooltip)
    end
    for _, event in ipairs({ "QUEST_ACCEPTED", "QUEST_REMOVED", "QUEST_TURNED_IN" }) do
      pcall(events.RegisterEvent, events, event)
    end
  elseif key == "questItemMarks" then
    RefreshBags()
  end
end)
