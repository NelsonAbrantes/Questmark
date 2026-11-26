local _, ns = ...
local Core = ns.Core

-- luacheck: push ignore 113
local C_LootHistory = C_LootHistory
local C_Timer = C_Timer
local CreateFrame = CreateFrame
local GameTooltip = GameTooltip
-- luacheck: pop

----
-- Group roll results
--
-- When a roll of the group ends, a small card shows the item, who chose
-- Need, Greed or Pass, the number each one rolled, and who won (Options:
-- Group roll results). The game's roll frames (and BetterGroupLoot's) close
-- before the numbers are known: these stay a while after. Drag to move,
-- right-click to close, Shift-click the item to link it. The numbers come
-- from the game's loot history; nothing runs between rolls.

local SHOW_FOR = 45 -- seconds a card stays (more while the mouse is on it)
local MAX_CARDS = 4
local MAX_ROWS = 5 -- players listed on a card in a raid (the others: in its tooltip)
local WIDTH = 290
local PAD = 10

-- Enum.EncounterLootDropRollState, with its known values as a fallback
local STATE = _G.Enum and _G.Enum.EncounterLootDropRollState
  or { NeedMainSpec = 0, NeedOffSpec = 1, Transmog = 2, Greed = 3, NoRoll = 4, Pass = 5 }
local CHOICES = {
  [STATE.NeedMainSpec] = { "Need", 0.35, 0.9, 0.35 },
  [STATE.NeedOffSpec] = { "Need (OS)", 0.35, 0.8, 0.55 },
  [STATE.Transmog] = { "Transmog", 0.8, 0.55, 1 },
  [STATE.Greed] = { "Greed", 1, 0.82, 0.2 },
  [STATE.NoRoll] = { "...", 0.55, 0.55, 0.55 },
  [STATE.Pass] = { "Pass", 0.55, 0.55, 0.55 },
}

local function On() return Core.db.profile.rollResults ~= false end

----
-- The place the cards stack from (saved when dragged)

local anchor = CreateFrame("Frame", "QuestmarkRollResults", _G.UIParent)
anchor:SetSize(WIDTH, 1)
anchor:SetClampedToScreen(true)
anchor:SetMovable(true)

local function PlaceAnchor()
  local point = Core.db.profile.rollResultsPoint
  anchor:ClearAllPoints()
  if type(point) == "table" and point[1] then
    anchor:SetPoint(point[1], _G.UIParent, point[1], point[2] or 0, point[3] or 0)
  else
    anchor:SetPoint("TOP", _G.UIParent, "CENTER", 320, 220)
  end
end

----
-- Cards

local cards = {} -- shown, newest first
local pool = {}

local function Layout()
  local previous
  for _, card in ipairs(cards) do
    card:ClearAllPoints()
    if previous then
      card:SetPoint("TOP", previous, "BOTTOM", 0, -6)
    else
      card:SetPoint("TOP", anchor, "TOP")
    end
    previous = card
  end
end

local byDrop = {} -- "encounter:drop" -> its card while shown, false once closed

local function Close(card)
  card.timer = nil
  if card.key and byDrop[card.key] == card then byDrop[card.key] = false end
  card.key = nil
  card.fade:Stop()
  card:Hide()
  for i, shown in ipairs(cards) do
    if shown == card then table.remove(cards, i) break end
  end
  pool[#pool + 1] = card
  Layout()
end

-- Fades out after a while; not while the mouse is on it
local function Later(card)
  local token = {}
  card.timer = token
  C_Timer.After(SHOW_FOR, function ()
    if card.timer ~= token or not card:IsShown() then return end
    if card:IsMouseOver() then Later(card) return end
    card.fade:Play()
  end)
end

local function Row(card, i)
  local row = card.rows[i]
  if row then return row end
  local fonts = Core.fonts
  row = {
    choice = card:CreateFontString(nil, "OVERLAY"),
    name = card:CreateFontString(nil, "OVERLAY"),
    roll = card:CreateFontString(nil, "OVERLAY"),
  }
  for _, text in pairs(row) do
    text:SetFontObject(fonts.line)
    text:SetWordWrap(false)
  end
  row.choice:SetJustifyH("LEFT")
  row.name:SetJustifyH("LEFT")
  row.roll:SetJustifyH("RIGHT")
  card.rows[i] = row
  return row
end

local function NewCard()
  local card = table.remove(pool)
  if card then return card end
  card = CreateFrame("Button", nil, anchor)
  card:SetWidth(WIDTH)
  card:SetClampedToScreen(true)
  card:RegisterForClicks("LeftButtonUp", "RightButtonUp")
  card:RegisterForDrag("LeftButton")

  local background = Core.Smooth(card:CreateTexture(nil, "BACKGROUND"))
  background:SetTexture(Core.ASSETS.."softBackground")
  if background.SetTextureSliceMargins then
    background:SetTextureSliceMargins(56, 56, 56, 56)
  end
  background:SetPoint("TOPLEFT", -24, 24)
  background:SetPoint("BOTTOMRIGHT", 24, -24)
  background:SetVertexColor(0, 0, 0, 0.85)

  card.icon = card:CreateTexture(nil, "ARTWORK")
  card.icon:SetSize(22, 22)
  card.icon:SetPoint("TOPLEFT", PAD, -PAD)
  card.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)

  card.item = CreateFrame("Button", nil, card)
  card.item:SetPoint("TOPLEFT", card.icon, "TOPLEFT")
  card.item:SetPoint("BOTTOMRIGHT", card, "TOPRIGHT", -PAD, -PAD - 22)
  card.item.text = card.item:CreateFontString(nil, "OVERLAY")
  card.item.text:SetFontObject(Core.fonts.header)
  card.item.text:SetPoint("LEFT", card.icon, "RIGHT", 6, 0)
  card.item.text:SetPoint("RIGHT")
  card.item.text:SetJustifyH("LEFT")
  card.item.text:SetWordWrap(false)
  card.item:SetScript("OnEnter", function (self)
    local link = self:GetParent().link
    if not link then return end
    GameTooltip:SetOwner(self, "ANCHOR_LEFT")
    pcall(GameTooltip.SetHyperlink, GameTooltip, link)
    GameTooltip:Show()
  end)
  card.item:SetScript("OnLeave", function () GameTooltip:Hide() end)
  card.item:SetScript("OnClick", function (self, button)
    local parent = self:GetParent()
    if button == "LeftButton" and parent.link and _G.HandleModifiedItemClick then
      if _G.HandleModifiedItemClick(parent.link) then return end
    end
    parent:Click(button)
  end)
  card.item:RegisterForClicks("LeftButtonUp", "RightButtonUp")

  card.rows = {}

  card.fade = card:CreateAnimationGroup()
  local alpha = card.fade:CreateAnimation("Alpha")
  alpha:SetFromAlpha(1)
  alpha:SetToAlpha(0)
  alpha:SetDuration(1)
  card.fade:SetScript("OnFinished", function () Close(card) end)

  card:SetScript("OnClick", function (self, button)
    if button == "RightButton" then Close(self) end
  end)
  -- (in a raid: everyone, with their choice and number)
  card:SetScript("OnEnter", function (self)
    local everyone = self.everyone
    if not (everyone and #everyone > MAX_ROWS + 1) then return end
    GameTooltip:SetOwner(self, "ANCHOR_LEFT")
    GameTooltip:AddLine(self.link or "?")
    local passed = 0
    for _, info in ipairs(everyone) do
      local choice = CHOICES[info.state] or CHOICES[STATE.NoRoll]
      if info.state == STATE.Pass or info.state == STATE.NoRoll then
        passed = passed + 1
      else
      local class = Core.Readable(info.playerClass) and info.playerClass
      local color = class and _G.RAID_CLASS_COLORS and _G.RAID_CLASS_COLORS[class]
      local name = color and ("|c"..color.colorStr..info.playerName.."|r") or info.playerName
      local roll = Core.Readable(info.roll) and info.roll and tostring(info.roll) or ""
      if info.isWinner then roll = roll.." won" end
      GameTooltip:AddDoubleLine(name, roll.."  "..choice[1], 1, 1, 1, choice[2], choice[3], choice[4])
      end
    end
    if passed > 0 then GameTooltip:AddLine(passed.." passed", 0.55, 0.55, 0.55) end
    GameTooltip:Show()
  end)
  card:SetScript("OnLeave", function () GameTooltip:Hide() end)
  -- (dragging any card moves them all)
  card:SetScript("OnDragStart", function () anchor:StartMoving() end)
  card:SetScript("OnDragStop", function ()
    anchor:StopMovingOrSizing()
    local point, _, _, x, y = anchor:GetPoint(1)
    Core.db.profile.rollResultsPoint = { point, x, y }
  end)
  return card
end

local function Fill(card, drop)
  local link = drop.itemHyperlink
  card.link = Core.Readable(link) and link or nil
  local icon = card.link and _G.C_Item and _G.C_Item.GetItemIconByID
    and _G.C_Item.GetItemIconByID(card.link)
  card.icon:SetTexture(icon or 134400)
  card.item.text:SetText(card.link or "?")

  -- Who's listed: everyone in a small group. In a raid, only who rolled
  -- (the winner always), the best first, then a line with how many more
  -- rolled and how many passed; the whole list in the card's tooltip.
  local everyone, rolled = {}, {}
  local passed = 0
  for _, info in ipairs(drop.rollInfos or {}) do
    if Core.Readable(info.playerName) and info.playerName then
      everyone[#everyone + 1] = info
      if info.state == STATE.Pass or info.state == STATE.NoRoll then
        passed = passed + 1
      elseif info.isWinner then
        table.insert(rolled, 1, info)
      else
        rolled[#rolled + 1] = info
      end
    end
  end
  card.everyone = everyone
  local list, more = everyone, nil
  if #everyone > MAX_ROWS + 1 then
    list = {}
    for i = 1, math.min(MAX_ROWS, #rolled) do list[i] = rolled[i] end
    local extra = #rolled - #list
    local parts = {}
    if extra > 0 then parts[#parts + 1] = "+"..extra.." more rolled" end
    if passed > 0 then parts[#parts + 1] = passed.." passed" end
    if #parts > 0 then more = table.concat(parts, " · ") end
  end

  local lineHeight = select(2, Core.fonts.line:GetFont()) or 12
  local rowHeight = lineHeight + 5
  local y = -PAD - 22 - 6
  local shown = 0
  for _, info in ipairs(list) do
    local name = info.playerName
    do
      shown = shown + 1
      local row = Row(card, shown)
      local choice = CHOICES[info.state] or CHOICES[STATE.NoRoll]
      row.choice:SetText(choice[1])
      row.choice:SetTextColor(choice[2], choice[3], choice[4])
      row.name:SetText(name)
      local class = info.playerClass
      local color = Core.Readable(class) and class and _G.RAID_CLASS_COLORS and _G.RAID_CLASS_COLORS[class]
      if color then row.name:SetTextColor(color.r, color.g, color.b) else row.name:SetTextColor(1, 1, 1) end
      local roll = info.roll
      if info.isWinner then
        -- the winner: their number in gold, with a mark
        row.roll:SetText((Core.Readable(roll) and roll and tostring(roll) or "").." won")
        row.roll:SetTextColor(Core.GOLD.r, Core.GOLD.g, Core.GOLD.b)
      else
        row.roll:SetText(Core.Readable(roll) and roll and tostring(roll) or "")
        row.roll:SetTextColor(0.85, 0.85, 0.85)
      end
      row.choice:ClearAllPoints()
      row.choice:SetPoint("TOPLEFT", PAD, y)
      row.choice:SetWidth(62)
      row.roll:ClearAllPoints()
      row.roll:SetPoint("TOPRIGHT", -PAD, y)
      row.roll:SetWidth(56)
      row.name:ClearAllPoints()
      row.name:SetPoint("TOPLEFT", PAD + 66, y)
      row.name:SetPoint("RIGHT", row.roll, "LEFT", -4, 0)
      for _, text in pairs(row) do text:Show() end
      y = y - rowHeight
    end
  end
  local summary = more or (shown == 0 and "Everyone passed")
  if summary then
    shown = shown + 1
    local row = Row(card, shown)
    row.choice:SetText(summary)
    row.choice:SetTextColor(0.55, 0.55, 0.55)
    row.choice:ClearAllPoints()
    row.choice:SetPoint("TOPLEFT", PAD, y)
    row.choice:SetWidth(WIDTH - PAD * 2)
    row.name:SetText("")
    row.roll:SetText("")
    row.choice:Show()
    y = y - rowHeight
  end
  for i = shown + 1, #card.rows do
    for _, text in pairs(card.rows[i]) do text:Hide() end
  end
  card:SetHeight(-y + PAD - 4)
end

----
-- The loot history: a drop whose roll ended

local function ShowDrop(key, drop)
  local card = byDrop[key]
  if card and card.key == key and card:IsShown() then
    -- the same roll again (a late number): only filled again
    Fill(card, drop)
    Layout()
    return
  end
  if byDrop[key] == false then return end -- shown already and closed
  card = NewCard()
  card.key = key
  byDrop[key] = card
  card.fade:Stop()
  card:SetAlpha(1)
  Fill(card, drop)
  table.insert(cards, 1, card)
  while #cards > MAX_CARDS do Close(cards[#cards]) end
  Layout()
  card:Show()
  Later(card)
end

local function OnDrop(encounterID, lootListID)
  if not (On() and C_LootHistory and C_LootHistory.GetSortedInfoForDrop) then return end
  local ok, drop = pcall(C_LootHistory.GetSortedInfoForDrop, encounterID, lootListID)
  if not (ok and type(drop) == "table") then return end
  -- (still being rolled for: nothing yet)
  if not (drop.winner or drop.allPassed) then return end
  ShowDrop(tostring(encounterID)..":"..tostring(lootListID), drop)
end

local events = CreateFrame("Frame")
events:SetScript("OnEvent", function (_, event, encounterID, lootListID)
  if event == "LOOT_HISTORY_UPDATE_DROP" then
    OnDrop(encounterID, lootListID)
  elseif event == "LOOT_HISTORY_CLEAR_HISTORY" then
    byDrop = {}
  end
end)

Core:OnChange(function (key)
  if key == "enable" then
    PlaceAnchor()
    for _, event in ipairs({ "LOOT_HISTORY_UPDATE_DROP", "LOOT_HISTORY_CLEAR_HISTORY" }) do
      pcall(events.RegisterEvent, events, event)
    end
  elseif key == "rollResults" and not On() then
    while cards[1] do Close(cards[1]) end
  end
end)

----
-- The game's roll windows (Options: Roll windows: choices and moving)
--
-- Under each of the game's windows to choose Need, Greed or Pass: how many
-- chose what so far ("Need 2 · Greed 1 · Pass 3") and your own number once
-- you chose Need; the mouse on that line lists who chose what. The windows
-- can be moved in Edit Mode ("Questmark: loot rolls"). Only the game's own
-- windows, only placed somewhere else: nothing of the game is replaced.

local ROLL_FRAMES = 4 -- GroupLootFrame1 to 4
local ROLL_GAP = 18 -- room under each window for its line
local MOVER_DEFAULT = { point = "BOTTOM", x = 0, y = 330 } -- (above the cast bar: easy to pick in Edit Mode)

local function WindowsOn() return Core.db.profile.rollWindows ~= false end

local dropOf = {} -- rollID -> { encounterID, lootListID }
local myRoll = {} -- rollID -> { roll, winning }

local function ItemID(link)
  return type(link) == "string" and tonumber(link:match("item:(%d+)"))
end

-- The loot history's entry for a roll still running: the same item, not
-- won yet, and not the entry of another roll (two of the same item)
local function FindDrop(rollID)
  if not (C_LootHistory and C_LootHistory.GetAllEncounterInfos and _G.GetLootRollItemLink) then return nil end
  local link = _G.GetLootRollItemLink(rollID)
  if not Core.Readable(link) or not link then return nil end
  local id = ItemID(link)
  local taken = {}
  for other, ref in pairs(dropOf) do
    if other ~= rollID then taken[ref[1]..":"..ref[2]] = true end
  end
  local best, bestScore = nil, 0
  for _, encounter in ipairs(C_LootHistory.GetAllEncounterInfos() or {}) do
    local encounterID = encounter.encounterID
    for _, drop in ipairs(C_LootHistory.GetSortedDropsForEncounter(encounterID) or {}) do
      local listID = drop.lootListID or drop.lootListKey
      if listID and not taken[encounterID..":"..listID] then
        local score = (drop.itemHyperlink == link and 2) or (id and ItemID(drop.itemHyperlink) == id and 1) or 0
        if score > 0 and not drop.winner and not drop.allPassed then score = score + 2 end
        if score > bestScore then best, bestScore = { encounterID, listID }, score end
      end
    end
  end
  return best
end

local function DropFor(rollID)
  if not (C_LootHistory and C_LootHistory.GetSortedInfoForDrop) then return nil end
  local ref = dropOf[rollID]
  local drop = ref and C_LootHistory.GetSortedInfoForDrop(ref[1], ref[2])
  if not drop then
    ref = FindDrop(rollID)
    dropOf[rollID] = ref
    drop = ref and C_LootHistory.GetSortedInfoForDrop(ref[1], ref[2])
  end
  return drop
end

local COUNTED = {
  { "Need", { STATE.NeedMainSpec, STATE.NeedOffSpec }, "59e659" },
  { "Transmog", { STATE.Transmog }, "cc8cff" },
  { "Greed", { STATE.Greed }, "ffd133" },
  { "Pass", { STATE.Pass }, "8c8c8c" },
}

local function Extra(window)
  if window.questmark then return window.questmark end
  local extra = CreateFrame("Frame", nil, window)
  extra:SetPoint("TOPLEFT", window, "BOTTOMLEFT", 8, -1)
  extra:SetPoint("TOPRIGHT", window, "BOTTOMRIGHT", -8, -1)
  extra:SetHeight(ROLL_GAP - 2)
  extra.text = extra:CreateFontString(nil, "OVERLAY")
  extra.text:SetFontObject(Core.fonts.line)
  extra.text:SetAllPoints()
  extra.text:SetJustifyH("CENTER")
  extra.text:SetWordWrap(false)
  extra:EnableMouse(true)
  extra:SetScript("OnEnter", function (self)
    local drop = self.rollID and DropFor(self.rollID)
    if not (drop and drop.rollInfos) then return end
    GameTooltip:SetOwner(self, "ANCHOR_TOP")
    for _, kind in ipairs(COUNTED) do
      local names = {}
      for _, info in ipairs(drop.rollInfos) do
        for _, state in ipairs(kind[2]) do
          if info.state == state and Core.Readable(info.playerName) and info.playerName then
            local class = Core.Readable(info.playerClass) and info.playerClass
            local color = class and _G.RAID_CLASS_COLORS and _G.RAID_CLASS_COLORS[class]
            names[#names + 1] = color and ("|c"..color.colorStr..info.playerName.."|r") or info.playerName
          end
        end
      end
      if #names > 0 then
        GameTooltip:AddLine("|cff"..kind[3]..kind[1].."|r ("..#names..")")
        GameTooltip:AddLine(table.concat(names, ", "), 1, 1, 1, true)
      end
    end
    GameTooltip:Show()
  end)
  extra:SetScript("OnLeave", function () GameTooltip:Hide() end)
  window.questmark = extra
  return extra
end

-- The line under one window: the counts so far, and your number
local function UpdateWindow(window)
  local rollID = window.rollID
  local extra = Extra(window)
  extra.rollID = rollID
  if not (WindowsOn() and rollID and window:IsShown()) then extra:Hide() return end
  local parts = {}
  local mine = myRoll[rollID]
  if mine then
    parts[#parts + 1] = (mine[2] and "|cff59e659" or "|cffff5959").."You: "..mine[1].."|r"
  end
  local drop = DropFor(rollID)
  for _, kind in ipairs(COUNTED) do
    local count = 0
    for _, info in ipairs(drop and drop.rollInfos or {}) do
      for _, state in ipairs(kind[2]) do
        if info.state == state then count = count + 1 end
      end
    end
    if count > 0 then parts[#parts + 1] = "|cff"..kind[3]..kind[1].." "..count.."|r" end
  end
  extra.text:SetText(table.concat(parts, "  ·  "))
  extra:Show()
end

local function UpdateWindows()
  for i = 1, ROLL_FRAMES do
    local window = _G["GroupLootFrame"..i]
    if window then UpdateWindow(window) end
  end
end

-- Where the windows stack from (Edit Mode)
local mover = CreateFrame("Frame", "QuestmarkLootRollsMover", _G.UIParent)
mover:SetSize(260, 60)
mover:SetClampedToScreen(true)

local function PlaceMover()
  local position = Core.db.profile.rollWindowsPosition or MOVER_DEFAULT
  mover:ClearAllPoints()
  mover:SetPoint(position.point, _G.UIParent, position.point, position.x, position.y)
end

-- The game's windows, stacked up from the mover (after each time the game
-- places them itself). Only while the option is on: off, the game's own
-- place (from the next roll)
local placing = false
local function PlaceWindows()
  if placing or not WindowsOn() then return end
  placing = true
  local y = 0
  for i = 1, ROLL_FRAMES do
    local window = _G["GroupLootFrame"..i]
    if window and window:IsShown() then
      window:ClearAllPoints()
      window:SetPoint("BOTTOM", mover, "BOTTOM", 0, y)
      y = y + window:GetHeight() + ROLL_GAP
    end
  end
  placing = false
end

local function HookWindows()
  for _, name in ipairs({ "GroupLootContainer_Update", "GroupLootContainer_AddFrame", "GroupLootContainer_RemoveFrame" }) do
    if type(_G[name]) == "function" then _G.hooksecurefunc(name, PlaceWindows) end
  end
  for i = 1, ROLL_FRAMES do
    local window = _G["GroupLootFrame"..i]
    if window then
      window:HookScript("OnShow", function (self)
        PlaceWindows()
        UpdateWindow(self)
      end)
      window:HookScript("OnHide", function (self)
        if self.questmark then self.questmark:Hide() end
        PlaceWindows()
      end)
    end
  end
  local LEM = Core.LEM
  if LEM and LEM.AddFrame then
    LEM:AddFrame(mover, function (_, _, point, x, y)
      Core.db.profile.rollWindowsPosition = { point = point, x = x, y = y }
      PlaceMover()
      PlaceWindows()
    end, MOVER_DEFAULT, "Questmark: loot rolls")
  end
end

local windowEvents = CreateFrame("Frame")
windowEvents:SetScript("OnEvent", function (_, event, rollID, roll, winning)
  if event == "MAIN_SPEC_NEED_ROLL" then
    if Core.Readable(rollID) and Core.Readable(roll) then myRoll[rollID] = { roll, winning } end
  elseif event == "CANCEL_LOOT_ROLL" then
    if Core.Readable(rollID) then dropOf[rollID], myRoll[rollID] = nil, nil end
  end
  UpdateWindows()
end)

Core:OnChange(function (key)
  if key == "enable" then
    PlaceMover()
    HookWindows()
    for _, event in ipairs({ "START_LOOT_ROLL", "CANCEL_LOOT_ROLL", "MAIN_SPEC_NEED_ROLL", "LOOT_HISTORY_UPDATE_DROP" }) do
      pcall(windowEvents.RegisterEvent, windowEvents, event)
    end
  elseif key == "rollWindows" then
    UpdateWindows()
    PlaceWindows()
  end
end)

-- Tests the look: /run Questmark_TestRolls() (a group), Questmark_TestRolls(40) (a raid)
function _G.Questmark_TestRolls(size)
  local _, link = _G.C_Item.GetItemInfo(13353) -- Book of the Dead
  local infos = {
    { playerName = "Malark Nightsong", playerClass = "DRUID", state = STATE.NeedMainSpec, roll = 87, isWinner = true },
    { playerName = "Rethz Lightbane", playerClass = "PALADIN", state = STATE.NeedMainSpec, roll = 42 },
    { playerName = "Bigfoot Jones", playerClass = "SHAMAN", state = STATE.Greed, roll = 91 },
    { playerName = "Aehya", playerClass = "PRIEST", state = STATE.Pass },
  }
  local classes = { "WARRIOR", "MAGE", "ROGUE", "HUNTER", "WARLOCK", "PRIEST", "DRUID", "PALADIN", "SHAMAN" }
  for i = #infos + 1, size or 0 do
    local state = i % 4 == 0 and STATE.Greed or (i % 3 == 0 and STATE.NeedMainSpec or STATE.Pass)
    infos[i] = { playerName = "Raider"..i, playerClass = classes[i % #classes + 1], state = state,
      roll = state ~= STATE.Pass and math.random(1, 86) or nil }
  end
  ShowDrop("test"..math.random(1000000), {
    itemHyperlink = link or "|cffa335ee|Hitem:13353::::::::60:::::|h[Book of the Dead]|h|r",
    winner = true,
    rollInfos = infos,
  })
end
