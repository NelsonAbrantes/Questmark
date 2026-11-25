local _, ns = ...
local Core = ns.Core

-- luacheck: push ignore 113
local CreateFrame = CreateFrame
local CreateFont = CreateFont
local GetCursorPosition = GetCursorPosition
local InCombatLockdown = InCombatLockdown
local C_QuestLog = C_QuestLog
-- luacheck: pop

-- The book: the game's own spellbook pages (see GameBook); without them
-- (an older game), the tracker's picture (Assets/book, rendered in Blender,
-- see Tools). And where the writing goes on its pages.
local BOOK_W, BOOK_H = 880, 550
local LEFT_X, RIGHT_X = 110, 506 -- where the writing starts on each page
local TEXT_W = 264 -- the writing's width on a page
local TOP, BOTTOM = 60, 104 -- the writing's margins on the book
local MAP_W, MAP_H = 264, 176 -- the map, over the right page (Show map)
local MAP_TOP = 34 -- room above it, for the way back to the quest
local MAP_WIDER = 40 -- it goes past the writing's width, into the margins
local SWITCH_TIME = 0.25 -- the map coming over the page: it fades in
local GAME_LEFT = "spellbook-background-evergreen-left"
local GAME_RIGHT = "spellbook-background-evergreen-right"
local GAME_RIBBON = "spellbook-background-evergreen-ribbon"
local GAME_DIVIDER = "spellbook-divider"
-- the spellbook's dog-eared page corner (it resizes the book): its size there,
-- its frames (2 rows of 4) and how long its tip takes to lift
local GAME_CORNER = "spellbook-corner-flipbook-evergreen"
local CORNER_W, CORNER_H = 150, 155
local CORNER_COLUMNS, CORNER_ROWS, CORNER_FRAMES = 4, 2, 8
local CORNER_TIME = 0.45
local BOOK_MIN, BOOK_MAX = 0.7, 2.2 -- how small and big its corner can make it
local GAME_SCALE = 1.35 -- the book, writing and all, about the spellbook's size
local GAP = 12 -- between the parts of a page
local ROW_GAP = 3 -- between the rows of the list
local INDENT = 14 -- quests under their zone
local WHEEL_STEP = 40
local REFRESH_WAIT = 0.2 -- seconds: the quest log changes in bursts
local TURN_OUT, TURN_IN = 0.12, 0.2 -- seconds: a page turn, out and in
local TURN_SLIDE = 14 -- how far the writing slides as the page turns
local REWARD_H = 34
local ICON = 28

-- Ink colors
local INK = { 0.22, 0.13, 0.06 }
local RED = { 0.48, 0.10, 0.04 } -- titles, and the quest under the mouse or open
local GREEN = { 0.10, 0.36, 0.08 } -- done
local FADED = { 0.30, 0.21, 0.12 } -- (darker since the paper is: it got lost on it)
local FADED_HEX = "|cff4d361f"
local COUNT = { 0.36, 0.20, 0.08 } -- a zone's count of quests: a warm dark ink
local CREAM = { 1.0, 0.93, 0.78 } -- the cream of the game's zone names
-- A color of the list's options (cream, or one of Core.COLORS); nil if unknown
local YELLOW = { 1.0, 0.82, 0.0 } -- the game's yellow of quest titles
local function ListColor(key)
  if key == "cream" then return CREAM end
  if key == "yellow" then return YELLOW end
  local r, g, b = Core:Color(key)
  return r and { r, g, b } or nil
end
-- The zones in the list (Options: Zones color), with a thin dark edge
local function ZONE() return ListColor(Core.db.profile.bookZoneColor) or CREAM end

----
-- Quest book
--
-- The quest log as an open book: the quests taken on the left page (under
-- their zones, which open and close), the one chosen on the right one, with a
-- map of where it goes (QuestMap.lua), its objectives, its description and
-- its rewards. Choosing another quest turns the page.
-- It never opens the game's map: an addon opening it (the quest log is in
-- it) makes the game block parts of it later in a fight.

local book, list, listContent, count, rightContent, textScroll, textContent
local title, tags, parts, hint, mapHolder, rewardsHeading, rewardsText, chooseText, stamp
local STAMP_W = 130 -- "Completed" stamped over a quest done: its width,
local STAMP_ALPHA = 0.78 -- and how strong (the writing shows through)
local rows, rewardButtons = {}, {} -- made as needed and kept
local selected -- the quest on the right page
local pending -- a refresh waiting
local turning -- a page turn going (the tracker's own book): { t, questID, filled }
local CloseBook, StartOpen, StartFlip, Flash, ResetAnimations -- (Animations, below)
local BookDust -- (the open quest abandoned turns to dust, below)
local pageLeft, pageRight -- the spellbook's pages (nil with the tracker's own book)
local bookPicture -- the tracker's own book (nil with the spellbook's pages)
local earLayers -- the turned-up corner's pictures of the page

-- How bright the paper is (Options: Page brightness), 0.5 to 1: the pages,
-- their turning sheets, the fades over them and the turned-up corner
local function Paper()
  return math.max(0.5, math.min(1, (Core.db.profile.bookPaper or 75) / 100))
end
local ribbonMark -- the spellbook's ribbon, in the middle
local bookShadow -- the soft shadow under the spellbook's pages
local bookBase = 1 -- the book's own size (the chosen % is of it)
local UpdateMarker -- (the mark of the quest open, below)
local writingAlpha = 1 -- the writing's alpha (it fades as the book opens and shuts)
local shown = {} -- the book's writing and buttons, faded in as it opens
local wasDone = {} -- each quest: done the last time the list was filled
-- The map over the right page (Show map); it stays for the next quest
-- opened from it; the open quest has a map
local mapView, wantMap, selectedHasMap, ShowMapView

local fonts = {}
local function Font(key, file, size, spacing, flags)
  local font = CreateFont("QuestmarkBook"..key)
  font:SetFont(file, size, flags or "")
  if not font:GetFont() then font:SetFont(Core.FONT_TEXT, size, flags or "") end
  font:SetShadowOffset(0, 0)
  font:SetJustifyH("LEFT")
  font:SetSpacing(spacing or 0)
  fonts[key] = font
end
Font("Title", Core.FONT_TITLE, 24)
Font("Heading", Core.FONT_TITLE, 17)
Font("Zone", Core.FONT_TITLE, 15)
Font("Text", Core.FONT_TEXT, 12, 2)
Font("Small", Core.FONT_TEXT, 11)
Font("Badge", Core.FONT_TEXT, 10)
Font("Stamp", Core.FONT_TITLE, 21)
Font("Button", Core.FONT_TITLE, 13)
-- (the quest list: the book's own letters, or a font chosen in the options)
Font("List", Core.FONT_TEXT, 12)
Font("ListZone", Core.FONT_TITLE, 15)
-- (the zones' counts and "No quests taken.", in dark ink: no dark edge)
Font("ListPlain", Core.FONT_TEXT, 12)
-- (the rewards' names, in their quality's color: a thin dark edge to read on the paper)
Font("Reward", Core.FONT_TEXT, 11)
fonts.Reward:SetShadowColor(0, 0, 0, 0.9)
fonts.Reward:SetShadowOffset(1, -1)
Core.bookFonts = fonts

-- The sound of the book shutting: the game's spellbook closing (a book's thump)
local CLOSE_SOUND = "IG_SPELLBOOK_CLOSE"
local closeSounded = false -- its closing played it (the hiding then doesn't)

local function Sound(key)
  if not Core.db.profile.bookSounds then return end
  local kit = _G.SOUNDKIT
  -- (without the spellbook's sound, the quest log's)
  if kit and key == CLOSE_SOUND and not kit[key] then key = "IG_QUEST_LOG_CLOSE" end
  if kit and kit[key] then _G.PlaySound(kit[key]) end
end

local function Collapsed()
  Core.db.char.bookCollapsed = Core.db.char.bookCollapsed or {}
  return Core.db.char.bookCollapsed
end

---
-- Reads the quest log for a quest: it reads the selected quest, so the quest
-- is chosen for a moment, then the one before put back
local function WithQuest(questID, read)
  local before = C_QuestLog.GetSelectedQuest and C_QuestLog.GetSelectedQuest()
  C_QuestLog.SetSelectedQuest(questID)
  local ok, a, b = pcall(read)
  if before then C_QuestLog.SetSelectedQuest(before) end
  if ok then return a, b end
  return nil
end

---
-- The quest's description and objectives
local function QuestText(questID)
  local GetText = _G.GetQuestLogQuestText
  local index = C_QuestLog.GetLogIndexForQuestID and C_QuestLog.GetLogIndexForQuestID(questID)
  if not (GetText and index) then return nil end
  local description, objectives = WithQuest(questID, function () return GetText(index) end)
  return Core.Readable(description) and description or nil,
    Core.Readable(objectives) and objectives or nil
end
Core.BookQuestText = QuestText -- (Behavior/History.lua)

----
-- Tags: what kind of quest it is (daily, group, campaign...)

-- The game's icons for the quest kinds, by the name the game gives them
local TAG_ICON = 16
local TAG_ICON_PAGE = 13 -- (after the name, on the quest's page)
local TAG_ICONS = {
  elite = "nameplates-icon-elite-gold",
  dungeon = "questlog-questtypeicon-dungeon",
  raid = "questlog-questtypeicon-raid",
  ["raid (10)"] = "questlog-questtypeicon-raid",
  ["raid (25)"] = "questlog-questtypeicon-raid",
  group = "questlog-questtypeicon-group",
  heroic = "questlog-questtypeicon-heroic",
  pvp = "questlog-questtypeicon-pvp",
  scenario = "questlog-questtypeicon-scenario",
  account = "questlog-questtypeicon-account",
}

-- (apart: the icons on their own, as a second answer, at size, for after
-- the quest's name on its page)
local function Tags(questID, frequency, size, apart)
  size = size or TAG_ICON
  local found, icons, seen = {}, {}, {}
  local function Add(text, isIcon)
    if text and text ~= "" and not seen[text] then
      seen[text] = true
      local into = (apart and isIcon) and icons or found
      into[#into + 1] = text
    end
  end
  local Frequency = _G.Enum and _G.Enum.QuestFrequency
  if Frequency and frequency == Frequency.Daily then Add("Daily") end
  if Frequency and frequency == Frequency.Weekly then Add("Weekly") end
  local Classification = _G.Enum and _G.Enum.QuestClassification
  local kind = Classification and C_QuestLog.GetQuestClassification and C_QuestLog.GetQuestClassification(questID)
  if kind then
    local names = {
      [Classification.Campaign or -1] = "Campaign",
      [Classification.Important or -1] = "Important",
      [Classification.Legendary or -1] = "Legendary",
      [Classification.Calling or -1] = "Calling",
      [Classification.Meta or -1] = "Meta",
    }
    Add(names[kind])
  end
  local info = C_QuestLog.GetQuestTagInfo and C_QuestLog.GetQuestTagInfo(questID)
  if info then
    -- (elite, dungeon, raid...: the game's own icon for it, its name if none)
    local name = Core.Readable(info.tagName) and info.tagName or nil
    local atlas = name and TAG_ICONS[name:lower()]
    local Info = _G.C_Texture and _G.C_Texture.GetAtlasInfo
    if atlas and Info and Info(atlas) then
      Add("|A:"..atlas..":"..size..":"..size.."|a", true)
    else
      local Icon = _G.QuestUtils_GetQuestTypeIconMarkupString
      local ok, icon = false, nil
      if Icon then ok, icon = pcall(Icon, questID, size, size) end
      if ok and type(icon) == "string" and icon ~= "" then
        Add(icon, true)
      else
        Add(name)
      end
    end
  end
  return table.concat(found, " · "), table.concat(icons, " ")
end

---
-- Every quest taken, under its zone: { header, title, quests } or { questID, title, done, tags }
-- A quest's difficulty for you: the game's own colors (red, orange, yellow,
-- green, grey), as in its quest log and the tracker (a dark shadow under the
-- list's quests makes them read on the paper)
local function DifficultyInk(questID, level)
  -- (Options: Quests color, unless by difficulty)
  local chosen = ListColor(Core.db.profile.bookQuestColor)
  if chosen then return chosen end
  if not Core.DifficultyColor then return INK end
  local r, g, b = Core.DifficultyColor(questID, level)
  if not (r and g and b) then return INK end
  return { r, g, b }
end

local function QuestList()
  -- The quests turned in, instead (the red ribbon, see BuildRibbon; Behavior/History.lua)
  -- Under the day they were turned in ("Today", "Yesterday", "19 November")
  -- this month; before it, the days inside their month ("October"), and
  -- before this year the months inside their year ("2025"): not too many
  -- headers
  if book.showDone then
    local done, header = {}, nil
    -- (the year and the month open around the day, outermost first)
    local outers = {}
    local today = date("%Y-%m-%d")
    local yesterday = date("%Y-%m-%d", time() - 24 * 60 * 60)
    local history = Core.QuestHistory and Core.QuestHistory() or {}
    for _, one in ipairs(history) do
      local day = one.at and date("%Y-%m-%d", one.at) or "?"
      local keys = {}
      if one.at and day ~= yesterday and day:sub(1, 7) ~= today:sub(1, 7) then
        if day:sub(1, 4) ~= today:sub(1, 4) then keys[#keys + 1] = day:sub(1, 4) end
        keys[#keys + 1] = day:sub(1, 7)
      end
      for level, key in ipairs(keys) do
        local was = outers[level]
        if not was or was.day ~= key then
          -- (no zone of the game starts with that first letter)
          outers[level] = { header = true, title = "\1done:"..key, day = key, quests = 0,
            label = #key == 4 and key or date("%B", one.at), parent = outers[level - 1], diary = key }
          done[#done + 1] = outers[level]
          -- (a new year: its months start again)
          for deeper = level + 1, #outers do outers[deeper] = nil end
        end
        outers[level].quests = outers[level].quests + 1
      end
      for deeper = #keys + 1, #outers do outers[deeper] = nil end
      if not header or header.day ~= day then
        local label = day == today and "Today" or day == yesterday and "Yesterday"
          or not one.at and "Long ago"
          or date("%d %B", one.at):gsub("^0", "")
        -- (a day inside its month: a step in, shown while it's open)
        header = { header = true, title = "\1done:"..day, label = label, day = day, quests = 0,
          parent = outers[#keys], diary = one.at and day or nil }
        done[#done + 1] = header
      end
      header.quests = header.quests + 1
      done[#done + 1] = { history = one, title = one.title or "", level = one.level, zone = header, tags = "" }
    end
    return done, #history
  end
  -- (the log can have the same zone twice, as two groups: one zone here, in
  -- the place of its first group, with the quests of both)
  local groups, byTitle = {}, {}
  local n = 0
  local group
  for i = 1, C_QuestLog.GetNumQuestLogEntries() do
    local info = C_QuestLog.GetInfo(i)
    if info and info.isHeader then
      local title = info.title or ""
      group = byTitle[title]
      if not group then
        group = { header = { header = true, title = title, quests = 0 }, quests = {} }
        byTitle[title] = group
        groups[#groups + 1] = group
      end
    elseif info and not info.isHidden and info.questID and info.questID > 0 then
      if not group then
        group = { quests = {} }
        groups[#groups + 1] = group
      end
      local header = group.header
      if header then header.quests = header.quests + 1 end
      group.quests[#group.quests + 1] = {
        questID = info.questID,
        title = info.title or "",
        done = C_QuestLog.IsComplete and C_QuestLog.IsComplete(info.questID),
        level = info.level,
        tags = Tags(info.questID, info.frequency),
        zone = header,
      }
      n = n + 1
    end
  end
  -- (a zone only goes in with quests: no empty zones)
  local quests = {}
  for _, one in ipairs(groups) do
    if #one.quests > 0 then
      if one.header then quests[#quests + 1] = one.header end
      for _, quest in ipairs(one.quests) do quests[#quests + 1] = quest end
    end
  end
  return quests, n
end

----
-- Rewards

local function Rewards(questID)
  local found = { items = {}, choices = {} }
  WithQuest(questID, function ()
    found.money = _G.GetQuestLogRewardMoney and _G.GetQuestLogRewardMoney(questID) or 0
    found.xp = _G.GetQuestLogRewardXP and _G.GetQuestLogRewardXP(questID) or 0
    for i = 1, _G.GetNumQuestLogRewards and _G.GetNumQuestLogRewards(questID) or 0 do
      local name, texture, amount, quality, _, itemID = _G.GetQuestLogRewardInfo(i, questID)
      found.items[#found.items + 1] = { kind = "reward", index = i, name = name, texture = texture, amount = amount, quality = quality, itemID = itemID }
    end
    for i = 1, _G.GetNumQuestLogChoices and _G.GetNumQuestLogChoices(questID, true) or 0 do
      local name, texture, amount, quality, _, itemID = _G.GetQuestLogChoiceInfo(i)
      found.choices[#found.choices + 1] = { kind = "choice", index = i, name = name, texture = texture, amount = amount, quality = quality, itemID = itemID }
    end
    local currencies = C_QuestLog.GetQuestRewardCurrencies and C_QuestLog.GetQuestRewardCurrencies(questID)
    for i, currency in ipairs(currencies or {}) do
      found.items[#found.items + 1] = {
        kind = "currency", index = i, name = currency.name, texture = currency.texture,
        amount = currency.totalRewardAmount or currency.baseRewardAmount, quality = currency.quality,
      }
    end
  end)
  return found
end

Core.BookRewards = Rewards -- (Behavior/History.lua)

-- An item's name color, dark enough for the paper (plain items in ink)
local function QualityColor(quality)
  if not quality or quality <= 1 then return INK[1], INK[2], INK[3] end
  local Item = _G.C_Item
  if not (Item and Item.GetItemQualityColor) then return INK[1], INK[2], INK[3] end
  local r, g, b = Item.GetItemQualityColor(quality)
  if not (r and g and b) then return INK[1], INK[2], INK[3] end
  return r, g, b
end

local function RewardButton(i)
  local button = rewardButtons[i]
  if button then return button end
  button = CreateFrame("Button", nil, textContent)
  button:SetSize(TEXT_W / 2 - 4, REWARD_H)
  button.icon = button:CreateTexture(nil, "ARTWORK")
  button.icon:SetSize(ICON, ICON)
  button.icon:SetPoint("LEFT")
  button.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
  button.amount = button:CreateFontString(nil, "OVERLAY", "NumberFontNormal")
  button.amount:SetPoint("BOTTOMRIGHT", button.icon, "BOTTOMRIGHT", 1, 0)
  button.name = button:CreateFontString(nil, "ARTWORK")
  button.name:SetFontObject(fonts.Reward)
  button.name:SetPoint("LEFT", button.icon, "RIGHT", 6, 0)
  button.name:SetPoint("RIGHT")
  button.name:SetMaxLines(2)
  -- The tooltip follows the mouse, like the game's over the world. The
  -- game's "at the mouse" only puts it there once (then it stayed in
  -- place): moved here while the mouse is over the reward, only if it moved
  local lastX, lastY
  local function Follow()
    local tooltip = _G.GameTooltip
    local x, y = _G.GetCursorPosition()
    if x == lastX and y == lastY then return end
    lastX, lastY = x, y
    local scale = tooltip:GetEffectiveScale()
    tooltip:ClearAllPoints()
    tooltip:SetPoint("BOTTOMLEFT", _G.UIParent, "BOTTOMLEFT", x / scale + 12, y / scale + 12)
  end
  button:SetScript("OnEnter", function (self)
    local tooltip = _G.GameTooltip
    tooltip:SetOwner(self, "ANCHOR_NONE")
    if self.link then
      -- (a quest turned in: its item, kept)
      pcall(tooltip.SetHyperlink, tooltip, self.link)
    elseif not selected then
      return
    elseif self.kind == "currency" then
      pcall(tooltip.SetQuestLogCurrency, tooltip, "reward", self.index, selected)
    else
      pcall(tooltip.SetQuestLogItem, tooltip, self.kind, self.index, selected)
    end
    lastX, lastY = nil, nil
    Follow()
    tooltip:Show()
    if Core.BookPadEnter then Core.BookPadEnter(self, textScroll) end
    self:SetScript("OnUpdate", Follow)
  end)
  button:SetScript("OnLeave", function (self)
    self:SetScript("OnUpdate", nil)
    _G.GameTooltip:Hide()
  end)
  -- Like the game's rewards: Ctrl-click tries it on, Shift-click links it
  button:SetScript("OnClick", function (self)
    local link = self.link
    if not link and (self.kind == "currency" or not selected) then return end
    link = link or _G.GetQuestLogItemLink and _G.GetQuestLogItemLink(self.kind, self.index, selected)
    if not link then return end
    if _G.IsModifiedClick("DRESSUP") and _G.DressUpItemLink then
      _G.DressUpItemLink(link)
    elseif _G.IsModifiedClick("CHATLINK") then
      local insert = (_G.ChatFrameUtil and _G.ChatFrameUtil.InsertLink) or _G.ChatEdit_InsertLink
      if insert then insert(link) end
    end
  end)
  rewardButtons[i] = button
  return button
end

local function ShowReward(i, item, y, column)
  local button = RewardButton(i)
  button.kind, button.index, button.link = item.kind, item.index, item.link
  button.icon:SetTexture(item.texture or 134400) -- (a question mark until known)
  -- (a quest turned in: the rewards not chosen in gray)
  button.icon:SetDesaturated(item.dim or false)
  button.icon:SetAlpha(item.dim and 0.6 or 1)
  button.amount:SetText(item.amount and item.amount > 1 and item.amount or "")
  button.name:SetText(item.name or "")
  if item.dim then
    button.name:SetTextColor(unpack(FADED))
  else
    button.name:SetTextColor(QualityColor(item.quality))
  end
  button:ClearAllPoints()
  button:SetPoint("TOPLEFT", column * (TEXT_W / 2 + 4), -y)
  button:Show()
end

----
-- The quest menu (right click on a quest)

local Select, Turn, FillList, FillText, MapSize

---
-- The quest shows in the tracker (tracked, or not hidden with All quests)
local function InTracker(questID)
  for _, id in ipairs(Core.ShownQuestIDs()) do
    if id == questID then return true end
  end
  return false
end

-- Tracks the quest, or stops tracking it
local function ToggleTrack(questID)
  if InTracker(questID) then
    -- (with every quest showing, it's hidden from the tracker too)
    if Core.db.profile.allQuests then Core.HideQuest(questID) end
    C_QuestLog.RemoveQuestWatch(questID)
  else
    Core.UnhideQuest(questID)
    C_QuestLog.AddQuestWatch(questID)
  end
end

local function QuestMenu(owner, questID)
  local MenuUtil = _G.MenuUtil
  if not (MenuUtil and MenuUtil.CreateContextMenu) then return end
  MenuUtil.CreateContextMenu(owner, function (_, root)
    root:CreateTitle(C_QuestLog.GetTitleForQuestID(questID) or "")
    root:CreateButton("Read quest", function () Turn(questID) end)
    root:CreateButton(InTracker(questID) and "Stop tracking" or "Track", function () ToggleTrack(questID) end)
    local SuperTrack = _G.C_SuperTrack
    local followed = SuperTrack and SuperTrack.GetSuperTrackedQuestID and SuperTrack.GetSuperTrackedQuestID() == questID
    root:CreateButton(followed and "Stop following" or "Follow", function () Core.FollowQuest(questID) end)
    if C_QuestLog.IsPushableQuest and C_QuestLog.IsPushableQuest(questID) and _G.IsInGroup() then
      root:CreateButton("Share", function () Core.ShareQuest(questID) end)
    end
    if C_QuestLog.CanAbandonQuest == nil or C_QuestLog.CanAbandonQuest(questID) then
      root:CreateButton("Abandon", function () Core.AbandonQuest(questID) end)
    end
  end)
end

----
-- Buttons under the open quest, as in the game's quest log: Show map (the
-- map over the page, when the quest has one), Track (or Untrack), Share (in
-- a group, a quest that can be shared) and Abandon.
-- Words in the book's red ink, brighter under the mouse, faded when they
-- can't be used.

local BUTTONS_H = 20 -- room for them at the bottom of the right page
local BUTTON_GAP = 22
local pageButtons = {}

local function UpdateButtons()
  local bar = pageButtons.bar
  if not bar then return end
  local questID = selected
  -- (not over the map)
  bar:SetShown(questID ~= nil and not (mapView and mapView:IsShown()))
  if not questID then return end
  pageButtons[1]:SetEnabled(selectedHasMap and true or false)
  pageButtons[2].label:SetText(InTracker(questID) and "Untrack" or "Track")
  pageButtons[3]:SetEnabled(C_QuestLog.IsPushableQuest and C_QuestLog.IsPushableQuest(questID)
    and _G.IsInGroup() and true or false)
  pageButtons[4]:SetEnabled((C_QuestLog.CanAbandonQuest == nil or C_QuestLog.CanAbandonQuest(questID)) and true or false)
  -- (the group's leader: Guide group, GroupLead.lua)
  if pageButtons[5] then
    pageButtons[5]:SetShown(Core.CanGuide and Core.CanGuide() or false)
    local plan = Core.GroupPlan and Core.GroupPlan()
    local words = "Guide group"
    if plan and Core.InGroupPlan(questID) then
      words = "Out of plan"
    elseif Core.GuidedQuest and Core.GuidedQuest() == questID then
      words = "Stop guiding"
    elseif plan then
      words = "Add to plan"
    end
    pageButtons[5].label:SetText(words)
  end
  local words, shown = 0, {}
  for _, button in ipairs(pageButtons) do
    if button:IsShown() then
      -- (the titles' font reaches past its own measure: room so no letter is cut)
      local label = button.label
      local textWidth = (label.GetUnboundedStringWidth and label:GetUnboundedStringWidth() or label:GetStringWidth()) + 12
      label:SetWidth(textWidth)
      button:SetWidth(textWidth)
      button:Paint()
      words = words + textWidth
      shown[#shown + 1] = button
    end
  end
  -- Within the page: the gaps narrower when they don't fit (five buttons
  -- with Guide group), then all of them a little smaller
  local room = math.max(100, (rightContent:GetWidth() or 0) - 24)
  local gaps = math.max(0, #shown - 1)
  local gap = gaps > 0 and math.max(10, math.min(BUTTON_GAP, (room - words) / gaps)) or 0
  for i, button in ipairs(shown) do
    button:ClearAllPoints()
    if i == 1 then
      button:SetPoint("LEFT")
    else
      button:SetPoint("LEFT", shown[i - 1], "RIGHT", gap, 0)
    end
  end
  local width = words + gap * gaps
  bar:SetWidth(math.max(1, width))
  bar:SetScale(width > room and room / width or 1)
end

local function BuildButtons()
  local bar = CreateFrame("Frame", nil, rightContent)
  bar:SetHeight(BUTTONS_H)
  bar:SetPoint("BOTTOM")
  -- (over the page's dog-eared corner, which covered the last button)
  bar:SetFrameLevel(book:GetFrameLevel() + 75)
  pageButtons.bar = bar
  local actions = {
    { "Show map", function () ShowMapView(true) end },
    { "Track", function (questID)
      ToggleTrack(questID)
      -- (its word follows once the tracker has it)
      _G.C_Timer.After(0.1, UpdateButtons)
    end },
    { "Share", function (questID) Core.ShareQuest(questID) end },
    { "Abandon", function (questID) Core.AbandonQuest(questID) end },
    { "Guide group", function (questID)
      if not Core.PlanToggle then return end
      Core.PlanToggle(questID)
      _G.C_Timer.After(0.1, UpdateButtons)
    end },
  }
  for i, action in ipairs(actions) do
    local button = CreateFrame("Button", nil, bar)
    button:SetHeight(BUTTONS_H)
    button.label = button:CreateFontString(nil, "ARTWORK")
    button.label:SetFontObject(fonts.Button)
    button.label:SetPoint("CENTER")
    button.label:SetText(action[1])
    if i == 1 then
      button:SetPoint("LEFT")
    else
      button:SetPoint("LEFT", pageButtons[i - 1], "RIGHT", BUTTON_GAP, 0)
    end
    function button:Paint()
      if not self:IsEnabled() then
        self.label:SetTextColor(FADED[1], FADED[2], FADED[3], 0.45)
      -- (fully seen again: the color alone kept the faded one's see-through)
      elseif self:IsMouseOver() or self.padFocus then
        self.label:SetTextColor(0.78, 0.22, 0.06, 1)
      else
        self.label:SetTextColor(RED[1], RED[2], RED[3], 1)
      end
    end
    button:SetScript("OnEnter", button.Paint)
    button:SetScript("OnLeave", button.Paint)
    button:SetScript("OnClick", function () if selected then action[2](selected) end end)
    pageButtons[i] = button
  end
  bar:Hide()
end

----
-- Building the book

----
-- Soft edges on the scrolled writing: a strip of the page itself drawn over
-- the writing's top or bottom edge, fading into it (only where there's more
-- writing past the edge). Text can't be faded by a mask in this game.

local FADE = 22
local pages = {} -- each page's picture: where it is on the book and its texture
local fadeLayer, faded = nil, {}

local function PlaceFade(texture, x0, x1, y0, y1, solidTop)
  for _, page in ipairs(pages) do
    if x0 >= page.x0 - 1 and x1 <= page.x1 + 1 then
      local function U(x) return page.l + (x - page.x0) / (page.x1 - page.x0) * (page.r - page.l) end
      local function V(y) return page.t + y / BOOK_H * (page.b - page.t) end
      texture:SetTexture(page.file)
      texture:SetTexCoord(U(x0), U(x1), V(y0), V(y1))
      texture:ClearAllPoints()
      texture:SetPoint("TOPLEFT", book, "TOPLEFT", x0, -y0)
      texture:SetSize(x1 - x0, y1 - y0)
      local k = Paper()
      local solid, clear = _G.CreateColor(k, k, k, 1), _G.CreateColor(k, k, k, 0)
      -- (vertical gradients go from the bottom up)
      if solidTop then texture:SetGradient("VERTICAL", clear, solid) else texture:SetGradient("VERTICAL", solid, clear) end
      return true
    end
  end
  return false
end

local function UpdateFades()
  if not (book and book:IsShown()) then return end
  UpdateMarker()
  local left, top = book:GetLeft(), book:GetTop()
  for _, one in ipairs(faded) do
    local scroll, content = one.scroll, one.content
    if scroll:IsVisible() and scroll:GetTop() and left then
      local x0 = math.floor(scroll:GetLeft() - left) - 6
      local x1 = math.ceil(scroll:GetRight() - left) + 6
      local y0, y1 = top - scroll:GetTop(), top - scroll:GetBottom()
      local at = scroll:GetVerticalScroll()
      local more = content:GetHeight() - scroll:GetHeight() - at
      one.top:SetShown(at > 1 and PlaceFade(one.top, x0, x1, y0, y0 + FADE, true))
      one.bottom:SetShown(more > 1 and PlaceFade(one.bottom, x0, x1, y1 - FADE, y1, false))
    else
      one.top:Hide()
      one.bottom:Hide()
    end
  end
end

local function Fades(scroll, content)
  local one = {
    scroll = scroll, content = content,
    top = fadeLayer:CreateTexture(nil, "OVERLAY"),
    bottom = fadeLayer:CreateTexture(nil, "OVERLAY"),
  }
  faded[#faded + 1] = one
  scroll:SetScript("OnVerticalScroll", UpdateFades)
  scroll:SetScript("OnScrollRangeChanged", UpdateFades)
end

local function Wheel(scroll, content)
  Fades(scroll, content)
  scroll:EnableMouseWheel(true)
  scroll:SetScript("OnMouseWheel", function (self, delta)
    local most = math.max(0, content:GetHeight() - self:GetHeight())
    self:SetVerticalScroll(math.min(most, math.max(0, self:GetVerticalScroll() - delta * WHEEL_STEP)))
  end)
end

local function Atlas(name)
  local Info = _G.C_Texture and _G.C_Texture.GetAtlasInfo
  return Info and Info(name)
end

----
-- The quest open on the right page, marked in the list by the game's own
-- quest marks: the yellow "!", or the "?" once it's done (to give back).
-- It's over the list, not in it (it would be cut at the list's
-- edge), so it follows the quest's row and hides when the row is scrolled
-- out of sight.

local MARK_SIZE = 17
local MARK_GOING, MARK_DONE = "QuestNormal", "QuestTurnin"
local DONE_MARK = 15 -- the "?" after a quest done in the list
local markLayer, marker

function UpdateMarker()
  if not (book and book:IsShown()) then return end
  if not markLayer then
    markLayer = CreateFrame("Frame", nil, book)
    markLayer:SetAllPoints()
    markLayer:SetFrameLevel(book:GetFrameLevel() + 20)
    -- (it comes and goes with the writing as the book opens and shuts)
    shown[#shown + 1] = markLayer
    markLayer:SetAlpha(writingAlpha)
    marker = markLayer:CreateTexture(nil, "ARTWORK")
    marker:SetSize(MARK_SIZE, MARK_SIZE)
  end
  local row
  for _, one in ipairs(rows) do
    if one:IsShown() and one.questID and one.questID == selected then
      row = one
      break
    end
  end
  local top, bottom = list:GetTop(), list:GetBottom()
  local rowTop, rowBottom = row and row:GetTop(), row and row:GetBottom()
  if not (rowTop and top and rowTop <= top + 1 and rowBottom >= bottom - 1) then
    marker:Hide()
    return
  end
  -- (always the "!": a quest done has its "?" after its name already)
  local mark = MARK_GOING
  if Atlas(mark) then
    marker:SetAtlas(mark)
  else
    marker:SetTexture(Core.ASSETS.."circleFill")
    marker:SetVertexColor(RED[1], RED[2], RED[3])
  end
  marker:ClearAllPoints()
  marker:SetPoint("RIGHT", row.text, "TOPLEFT", -1, -7)
  marker:SetAlpha(row:GetAlpha())
  marker:Show()
end

---
-- The game's spellbook pages, when the game has them: the book takes their
-- shape, and the writing goes where the spellbook's does. False if not.
-- The map on the right page: as wide as chosen (Options: % of the page's
-- width), the shape of the zones' maps
function MapSize()
  local size = (Core.db.profile.bookMapSize or 100) / 100
  return math.floor((TEXT_W + MAP_WIDER) * size), math.floor((BOOK_H - TOP - BOTTOM - MAP_TOP) * size)
end

local function GameBook()
  local page = Atlas(GAME_LEFT)
  if not (page and Atlas(GAME_RIGHT) and page.width and page.width > 0) then return false end
  local half = BOOK_W / 2
  BOOK_H = math.floor(half * page.height / page.width + 0.5)
  LEFT_X = math.floor(half * 0.10)
  RIGHT_X = half + math.floor(half * 0.11)
  TEXT_W = math.floor(half * 0.76)
  TOP, BOTTOM = math.floor(BOOK_H * 0.085), math.floor(BOOK_H * 0.07)
  -- (the map smaller than the page's width, centered: room for the writing)
  MAP_W, MAP_H = MapSize()
  return true
end

-- Under the page titles: the spellbook's divider, or a thin ink line fading
-- out at both ends
local function Ornament(page, anchor, width)
  local divider = Atlas(GAME_DIVIDER)
  if divider and divider.width and divider.width > 0 then
    local line = page:CreateTexture(nil, "ARTWORK")
    line:SetAtlas(GAME_DIVIDER)
    line:SetSize(width * 1.3, width * 1.3 * divider.height / divider.width)
    line:SetPoint("TOP", anchor, "BOTTOM", 0, -2)
    return
  end
  local function Half(point, from, to)
    local line = page:CreateTexture(nil, "ARTWORK")
    line:SetColorTexture(1, 1, 1, 1)
    line:SetGradient("HORIZONTAL", from, to)
    line:SetSize(width / 2, 1)
    line:SetPoint(point, anchor, "BOTTOM", 0, -8)
  end
  local ink = _G.CreateColor(INK[1], INK[2], INK[3], 0.7)
  local none = _G.CreateColor(INK[1], INK[2], INK[3], 0)
  Half("TOPRIGHT", none, ink)
  Half("TOPLEFT", ink, none)
end

local function Row(i)
  local row = rows[i]
  if row then return row end
  row = CreateFrame("Button", nil, listContent)
  row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
  row.text = row:CreateFontString(nil, "ARTWORK")
  row.text:SetWordWrap(true)
  -- A zone: open or closed (the tracker's own icons, in ink)
  row.toggle = Core.Smooth(row:CreateTexture(nil, "ARTWORK"))
  row.toggle:SetSize(11, 11)
  row.toggle:SetPoint("LEFT", 0, 0)
  row.toggle:SetVertexColor(unpack(ZONE()))
  -- A zone's count of quests, between brackets after its name, in dark ink
  row.count = row:CreateFontString(nil, "OVERLAY")
  row.count:SetFontObject(fonts.ListPlain)
  row.count:SetTextColor(COUNT[1], COUNT[2], COUNT[3])
  row.count:Hide()
  -- The quest open on the right page: a soft warm glow behind its name
  row.selected = Core.Smooth(row:CreateTexture(nil, "BACKGROUND"))
  row.selected:SetTexture(Core.ASSETS.."circleSoft")
  row.selected:SetBlendMode("ADD")
  row.selected:SetVertexColor(1.0, 0.78, 0.35, 0.32)
  row.selected:Hide()
  -- Under the mouse: red ink, underlined with a line fading to the right
  row.underline = row:CreateTexture(nil, "ARTWORK")
  row.underline:SetColorTexture(1, 1, 1, 1)
  row.underline:SetHeight(1)
  row.underline:SetPoint("TOPLEFT", row.text, "BOTTOMLEFT", 0, -1)
  row.underline:Hide()
  row:SetScript("OnEnter", function (self)
    local width = math.min(self.text:GetWidth(), self.text:GetStringWidth())
    self.underline:SetWidth(width + 6)
    self.underline:SetGradient("HORIZONTAL", _G.CreateColor(RED[1], RED[2], RED[3], 0.8),
      _G.CreateColor(RED[1], RED[2], RED[3], 0))
    self.underline:Show()
    self.text:SetTextColor(RED[1], RED[2], RED[3])
    if self.zone then self.toggle:SetVertexColor(RED[1], RED[2], RED[3]) end
    if self.history and Core.HistoryTooltip then Core.HistoryTooltip(self, self.history) end
    if Core.BookPadEnter then Core.BookPadEnter(self, list) end
  end)
  row:SetScript("OnLeave", function (self)
    self.underline:Hide()
    -- (the quest open stays red)
    self.text:SetTextColor(unpack(self.open and RED or self.color))
    self.toggle:SetVertexColor(unpack(ZONE()))
    if self.history then _G.GameTooltip:Hide() end
  end)
  row:SetScript("OnClick", function (self, button)
    if self.zone then
      -- A zone: opens or closes
      local collapsed = Collapsed()
      collapsed[self.zone] = not collapsed[self.zone] or nil
      FillList()
      -- (a day, month or year of the quests turned in: its diary on the
      -- right page, Behavior/Diary.lua)
      local page = self.diary and Core.DiaryPage and Core.DiaryPage(self.diary)
      if page then Core.ShowDoneQuest(page) end
    elseif self.questID then
      -- Shift-click: its link in the chat box being written, as in the game
      if button == "LeftButton" and _G.IsModifiedClick("CHATLINK") then
        local link = _G.GetQuestLink and _G.GetQuestLink(self.questID)
        local insert = (_G.ChatFrameUtil and _G.ChatFrameUtil.InsertLink) or _G.ChatEdit_InsertLink
        if link and insert and insert(link) then return end
      end
      if button == "RightButton" then
        QuestMenu(self, self.questID)
      else
        wantMap = false
        Turn(self.questID)
      end
    elseif self.history and Core.ShowDoneQuest then
      Core.ShowDoneQuest(self.history)
    end
  end)
  rows[i] = row
  return row
end

-- (the book is built in parts: one function with all of it went past the
-- game's limit of 60 outside names a function can use)

-- The book itself: its frame, pages, shadow, ribbon and close button
local function BuildBook(gameBook)
  book = CreateFrame("Frame", "QuestmarkQuestBook", _G.UIParent)
  -- (in the game's windows' layer, like the character window or the map:
  -- the last one opened or clicked in front. Addon windows a layer higher,
  -- like the Dungeon Journal, stay over it, never through its writing)
  book:SetFrameStrata("MEDIUM")
  book:SetToplevel(true)
  book:SetSize(BOOK_W, BOOK_H)
  -- (the spellbook's pages: as big on the screen as the game's spellbook)
  -- (its size: as chosen with its corner, or about the spellbook's)
  bookBase = gameBook and GAME_SCALE or 1
  book:SetScale(bookBase * (Core.db.profile.bookSize or 100) / 100)
  book:SetPoint("CENTER", 0, 20)
  book:SetClampedToScreen(true)
  book:EnableMouse(true)
  book:SetMovable(true)
  book:RegisterForDrag("LeftButton")
  book:SetScript("OnDragStart", book.StartMoving)
  book:SetScript("OnDragStop", book.StopMovingOrSizing)
  book:Hide()
  -- Escape closes it, like the game's windows
  table.insert(_G.UISpecialFrames, book:GetName())

  -- Above the writing: the soft edges
  fadeLayer = CreateFrame("Frame", nil, book)
  fadeLayer:SetAllPoints()
  fadeLayer:SetFrameLevel(book:GetFrameLevel() + 30)
  shown[#shown + 1] = fadeLayer
  if gameBook then
    local function Page(name, x0, x1)
      local info = Atlas(name)
      pages[#pages + 1] = { x0 = x0, x1 = x1, file = info.file, l = info.leftTexCoord,
        r = info.rightTexCoord, t = info.topTexCoord, b = info.bottomTexCoord }
    end
    Page(GAME_LEFT, 0, BOOK_W / 2)
    Page(GAME_RIGHT, BOOK_W / 2, BOOK_W)
    -- The spellbook's pages, a soft shadow under them, its ribbon and its
    -- close button
    local shadow = Core.Smooth(book:CreateTexture(nil, "BACKGROUND", nil, -8))
    shadow:SetTexture(Core.ASSETS.."softBackground")
    if shadow.SetTextureSliceMargins then
      shadow:SetTextureSliceMargins(56, 56, 56, 56)
      if shadow.SetTextureSliceMode and _G.Enum and _G.Enum.UITextureSliceMode then
        shadow:SetTextureSliceMode(_G.Enum.UITextureSliceMode.Stretched)
      end
    end
    shadow:SetPoint("TOPLEFT", -36, 36)
    shadow:SetPoint("BOTTOMRIGHT", 36, -40)
    bookShadow = shadow
    shadow:SetVertexColor(0, 0, 0, 0.8)
    local leftPage = book:CreateTexture(nil, "BACKGROUND")
    pageLeft = leftPage
    leftPage:SetAtlas(GAME_LEFT)
    leftPage:SetPoint("TOPLEFT")
    leftPage:SetPoint("BOTTOMRIGHT", book, "BOTTOM")
    local rightPage = book:CreateTexture(nil, "BACKGROUND")
    pageRight = rightPage
    rightPage:SetAtlas(GAME_RIGHT)
    rightPage:SetPoint("TOPLEFT", book, "TOP")
    rightPage:SetPoint("BOTTOMRIGHT")
    leftPage:SetVertexColor(Paper(), Paper(), Paper())
    rightPage:SetVertexColor(Paper(), Paper(), Paper())
    local ribbon = Atlas(GAME_RIBBON)
    if ribbon then
      -- (as big as on the spellbook, for the book's size here)
      local scale = (BOOK_W / 2) / Atlas(GAME_LEFT).width
      local mark = book:CreateTexture(nil, "BACKGROUND", nil, 2)
      mark:SetAtlas(GAME_RIBBON)
      mark:SetSize(ribbon.width * scale, ribbon.height * scale)
      -- (in the middle, just right of the fold, where the spellbook has it)
      mark:SetPoint("TOPRIGHT", leftPage, "TOPRIGHT", 62 * scale, 0)
      shown[#shown + 1] = mark
      ribbonMark = mark
    end
  else
    pages[1] = { x0 = 0, x1 = BOOK_W, file = Core.ASSETS.."book", l = 0, r = 1, t = 0, b = 1 }
    -- (the picture has its own shadow under the book)
    local picture = Core.Smooth(book:CreateTexture(nil, "BACKGROUND"))
    picture:SetTexture(Core.ASSETS.."book")
    picture:SetAllPoints()
    picture:SetVertexColor(Paper(), Paper(), Paper())
    bookPicture = picture
  end

  -- Closing: a cross of two brush strokes in the titles' red ink, in the
  -- page's top right corner (brighter under the mouse)
  local close = CreateFrame("Button", nil, book)
  close:SetSize(20, 20)
  if gameBook then
    close:SetPoint("CENTER", book, "TOPRIGHT", -44, -40)
  else
    close:SetPoint("CENTER", book, "TOPLEFT", 780, -52)
  end
  local strokes = {}
  for i = 1, 2 do
    local stroke = Core.Smooth(close:CreateTexture(nil, "ARTWORK"))
    stroke:SetTexture(Core.ASSETS.."slash")
    stroke:SetAllPoints()
    if i == 2 then stroke:SetTexCoord(1, 0, 0, 1) end -- (the other way)
    stroke:SetVertexColor(unpack(RED))
    strokes[i] = stroke
  end
  local function Ink(r, g, b)
    for _, stroke in ipairs(strokes) do stroke:SetVertexColor(r, g, b) end
  end
  close:SetScript("OnEnter", function () Ink(0.78, 0.22, 0.06) end)
  close:SetScript("OnLeave", function () Ink(unpack(RED)) end)
  close:SetScript("OnClick", function () CloseBook() end)
  shown[#shown + 1] = close

  -- The bottom right corner resizes it (the whole book, its shape kept);
  -- right click: its first size again. It's the spellbook's own dog-eared
  -- page corner, its tip lifting under the mouse (its frames, one after the
  -- other); the chat's size grabber without it.
  local grip = CreateFrame("Button", nil, book)
  book.grip = grip -- (hidden while a sheet turns over it, see BuildFlip)
  grip:SetFrameLevel(book:GetFrameLevel() + 70)
  grip:RegisterForClicks("RightButtonUp")
  shown[#shown + 1] = grip
  local ear = gameBook and Atlas(GAME_CORNER)
  if ear then
    -- The spellbook's own dog-eared page corner, its tip lifting under the
    -- mouse through its frames. Two layers: each frame blends into the next,
    -- the lift eased in and out, so it moves smoothly though the picture has
    -- only a few frames.
    local scale = (BOOK_W / 2) / Atlas(GAME_LEFT).width
    -- (the mouse takes only the very corner, so the page's writing stays clickable)
    grip:SetSize(CORNER_W * scale * 0.42, CORNER_H * scale * 0.42)
    grip:SetPoint("BOTTOMRIGHT", -15 * scale, 6 * scale)
    local layers = {}
    for i = 1, 2 do
      local layer = grip:CreateTexture(nil, "ARTWORK", nil, i)
      layer:SetSize(CORNER_W * scale, CORNER_H * scale)
      layer:SetPoint("BOTTOMRIGHT")
      layer:SetTexture(ear.file)
      layer:SetVertexColor(Paper(), Paper(), Paper())
      layers[i] = layer
    end
    earLayers = layers
    local du = (ear.rightTexCoord - ear.leftTexCoord) / CORNER_COLUMNS
    local dv = (ear.bottomTexCoord - ear.topTexCoord) / CORNER_ROWS
    local function Frame(layer, k)
      local column, row = k % CORNER_COLUMNS, math.floor(k / CORNER_COLUMNS)
      local u, v = ear.leftTexCoord + du * column, ear.topTexCoord + dv * row
      layer:SetTexCoord(u, u + du, v, v + dv)
    end
    local last = CORNER_FRAMES - 1
    local function Show(p)
      local at = p * p * (3 - 2 * p) * last -- (eased in and out)
      local k = math.min(math.floor(at), last - 1)
      Frame(layers[1], k)
      Frame(layers[2], k + 1)
      layers[2]:SetAlpha(at - k)
    end
    Show(0)
    local lift, aim = 0, 0
    grip:SetScript("OnEnter", function () aim = 1 end)
    grip:SetScript("OnLeave", function () aim = 0 end)
    -- (in a frame of its own: the resizing sets the grip's own OnUpdate)
    local curl = CreateFrame("Frame", nil, grip)
    curl:SetScript("OnUpdate", function (_, elapsed)
      if lift == aim then return end
      local step = elapsed / CORNER_TIME
      if aim > lift then lift = math.min(aim, lift + step) else lift = math.max(aim, lift - step) end
      Show(lift)
    end)
  else
    grip:SetSize(18, 18)
    grip:SetPoint("BOTTOMRIGHT", -6, 6)
    grip:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
    grip:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
    grip:SetPushedTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Down")
  end
  local sizing
  -- (kept at its top left: the book grows down and to the right)
  local function Pin(scale)
    local left, top = book:GetLeft() * book:GetEffectiveScale(), book:GetTop() * book:GetEffectiveScale()
    book:SetScale(scale)
    local unit = book:GetEffectiveScale()
    book:ClearAllPoints()
    book:SetPoint("TOPLEFT", _G.UIParent, "BOTTOMLEFT", left / unit, top / unit)
  end
  book.Resize = Pin
  grip:SetScript("OnMouseDown", function (_, button)
    if button ~= "LeftButton" then return end
    local x = GetCursorPosition()
    sizing = { x = x, scale = book:GetScale(), width = BOOK_W * book:GetEffectiveScale() }
    grip:SetScript("OnUpdate", function ()
      local now = GetCursorPosition()
      local scale = sizing.scale * (1 + (now - sizing.x) / sizing.width)
      Pin(math.max(BOOK_MIN, math.min(BOOK_MAX, scale)))
    end)
  end)
  grip:SetScript("OnMouseUp", function ()
    grip:SetScript("OnUpdate", nil)
    if sizing then
      Core.db.profile.bookSize = math.floor(book:GetScale() / bookBase * 100 + 0.5)
      Core:Changed("bookSizeDragged")
      sizing = nil
      UpdateFades()
    end
  end)
  grip:SetScript("OnClick", function ()
    Core.db.profile.bookSize = 100
    Pin(bookBase)
    Core:Changed("bookSizeDragged")
    UpdateFades()
  end)
end

-- Left page: the quests
local function BuildLeft()
  local left = CreateFrame("Frame", nil, book)
  shown[#shown + 1] = left
  left:SetPoint("TOPLEFT", LEFT_X, -TOP)
  left:SetSize(TEXT_W, BOOK_H - TOP - BOTTOM)
  local heading = left:CreateFontString(nil, "ARTWORK")
  heading:SetFontObject(fonts.Title)
  heading:SetPoint("TOP")
  heading:SetText("Quests")
  heading:SetTextColor(unpack(RED))
  book.heading = heading
  Ornament(left, heading, 180)
  count = left:CreateFontString(nil, "ARTWORK")
  count:SetFontObject(fonts.Small)
  count:SetPoint("TOP", heading, "BOTTOM", 0, -16)
  count:SetTextColor(unpack(FADED))

  -- The search: only a little magnifying glass in ink beside the title.
  -- Clicked, a line to write on takes the place of the quests' count (the
  -- count goes after it: "3 of 22 quests"); left empty, it goes away again.
  -- It takes the keys only when clicked; Escape empties it, then lets go.
  -- What it finds shows as you type (FillList)
  local search = CreateFrame("EditBox", nil, left)
  search:SetSize(TEXT_W * 0.42, 18)
  search:SetPoint("TOP", heading, "BOTTOM", 0, -12)
  search:SetAutoFocus(false)
  search:SetFontObject(fonts.Small)
  search:SetTextColor(unpack(INK))
  search:SetTextInsets(2, 14, 0, 0)
  search:SetMaxLetters(40)
  search:Hide()
  -- (under it, the same ornament as under the title, smaller)
  Ornament(search, search, TEXT_W * 0.42)
  -- (a red ink cross to empty it, while there's something in it)
  local clear = CreateFrame("Button", nil, search)
  clear:SetSize(18, 18)
  clear:SetPoint("RIGHT", 2, 0)
  clear.label = clear:CreateFontString(nil, "ARTWORK")
  clear.label:SetFontObject(fonts.Small)
  -- (bigger than the writing, to be seen)
  if clear.label.SetTextScale then clear.label:SetTextScale(1.5) end
  clear.label:SetPoint("CENTER", 0, 1)
  clear.label:SetText("x")
  clear.label:SetTextColor(unpack(RED))
  clear:Hide()

  -- The glass, faint until the mouse is over it
  local glass = CreateFrame("Button", nil, left)
  glass:SetSize(15, 15)
  glass:SetPoint("LEFT", heading, "RIGHT", 10, 0)
  glass.icon = glass:CreateTexture(nil, "ARTWORK")
  glass.icon:SetAllPoints()
  if Atlas("common-search-magnifyingglass") then
    glass.icon:SetAtlas("common-search-magnifyingglass")
  else
    glass.icon:SetTexture("Interface\\Common\\UI-Searchbox-Icon")
  end
  glass.icon:SetDesaturated(true)
  local function Faint(on) glass.icon:SetVertexColor(INK[1], INK[2], INK[3], on and 0.45 or 0.9) end
  Faint(true)
  glass:SetScript("OnEnter", function () Faint(false) end)
  glass:SetScript("OnLeave", function () Faint(true) end)

  -- Open: the line where the count was, the count after it
  local function Open(on)
    if search:IsShown() and not on then glass.closedAt = GetTime() end
    search:SetShown(on)
    count:ClearAllPoints()
    if on then
      count:SetPoint("LEFT", search, "RIGHT", 14, 0)
    else
      count:SetPoint("TOP", heading, "BOTTOM", 0, -16)
    end
  end
  -- (a toggle: open, it closes, emptied. A click on the glass first takes
  -- the keys from the line, which closes it if empty: that click then
  -- closed it, it doesn't open it again)
  glass:SetScript("OnClick", function ()
    if search:IsShown() then
      search:SetText("")
      search:ClearFocus()
      Open(false)
    elseif not (glass.closedAt and GetTime() - glass.closedAt < 0.3) then
      Open(true)
      search:SetFocus()
    end
  end)
  clear:SetScript("OnClick", function () search:SetText("") search:ClearFocus() end)
  local function Changed(self)
    local text = self:GetText() or ""
    clear:SetShown(text ~= "")
    if book.query ~= text then
      book.query = text
      FillList()
      list:SetVerticalScroll(0)
    end
  end
  search:SetScript("OnTextChanged", Changed)
  -- (left empty: only the glass again)
  search:SetScript("OnEditFocusLost", function (self)
    if (self:GetText() or "") == "" then Open(false) end
  end)
  search:SetScript("OnEnterPressed", search.ClearFocus)
  search:SetScript("OnEscapePressed", function (self)
    if (self:GetText() or "") ~= "" then self:SetText("") else self:ClearFocus() end
  end)
  book.search, book.searchOpen = search, Open

  list = CreateFrame("ScrollFrame", nil, left)
  list:SetPoint("TOPLEFT", 8, -70)
  list:SetPoint("BOTTOMRIGHT")
  listContent = CreateFrame("Frame", nil, list)
  listContent:SetWidth(TEXT_W - 8)
  list:SetScrollChild(listContent)
  Wheel(list, listContent)
end

-- Right page: the quest chosen (all in one frame, for the page turns)
local function BuildRight()
  rightContent = CreateFrame("Frame", nil, book)
  shown[#shown + 1] = rightContent
  rightContent:SetSize(TEXT_W, BOOK_H - TOP - BOTTOM)
  rightContent:SetPoint("TOPLEFT", RIGHT_X, -TOP)

  textScroll = CreateFrame("ScrollFrame", nil, rightContent)
  textContent = CreateFrame("Frame", nil, textScroll)
  textContent:SetWidth(TEXT_W)
  textScroll:SetScrollChild(textContent)
  Wheel(textScroll, textContent)

  title = textContent:CreateFontString(nil, "ARTWORK")
  title:SetFontObject(fonts.Title)
  title:SetPoint("TOPLEFT")
  title:SetWidth(TEXT_W)
  title:SetTextColor(unpack(RED))
  -- A quest done: "Completed" stamped in green ink at the bottom right of the page,
  -- like a rubber stamp's mark (Assets/stampFrame, see
  -- Tools/stamp.py). Over the writing, which shows through it; it doesn't
  -- scroll, and goes with the writing when the map shows.
  stamp = CreateFrame("Frame", nil, textScroll)
  stamp:SetSize(STAMP_W, STAMP_W * 224 / 512)
  stamp:SetPoint("BOTTOMRIGHT", -2, 6)
  -- (over the page's dog-eared corner, which covered its right end; away
  -- while a page turns, see StartFlip)
  stamp:SetFrameLevel(book:GetFrameLevel() + 75)
  stamp:SetAlpha(STAMP_ALPHA)
  local frame = Core.Smooth(stamp:CreateTexture(nil, "ARTWORK"))
  frame:SetTexture(Core.ASSETS.."stampFrame")
  frame:SetAllPoints()
  frame:SetVertexColor(GREEN[1], GREEN[2], GREEN[3])
  local word = stamp:CreateFontString(nil, "OVERLAY")
  word:SetFontObject(fonts.Stamp)
  word:SetText("Completed")
  word:SetTextColor(GREEN[1], GREEN[2], GREEN[3])
  word:SetPoint("CENTER", -1, 0)
  -- Stamped like a rubber stamp: it comes down from above the page, faster
  -- and faster, onto it; the ink is dark at first and soaks into the paper;
  -- the page jolts with the blow
  local thump = stamp:CreateAnimationGroup()
  local down = thump:CreateAnimation("Scale")
  down:SetScaleFrom(2.4, 2.4)
  down:SetScaleTo(1, 1)
  down:SetDuration(0.17)
  down:SetSmoothing("IN")
  down:SetOrder(1)
  local show = thump:CreateAnimation("Alpha")
  show:SetFromAlpha(0)
  show:SetToAlpha(1)
  show:SetDuration(0.1)
  show:SetOrder(1)
  local soak = thump:CreateAnimation("Alpha")
  soak:SetFromAlpha(1)
  soak:SetToAlpha(STAMP_ALPHA)
  soak:SetDuration(0.6)
  soak:SetSmoothing("OUT")
  soak:SetOrder(2)
  stamp.thump = thump
  -- (the jolt: the page's writing knocked down a little and back)
  local jolt = rightContent:CreateAnimationGroup()
  local knock = jolt:CreateAnimation("Translation")
  knock:SetOffset(0, -2)
  knock:SetDuration(0.04)
  knock:SetOrder(1)
  local rise = jolt:CreateAnimation("Translation")
  rise:SetOffset(0, 2)
  rise:SetDuration(0.1)
  rise:SetSmoothing("OUT")
  rise:SetOrder(2)
  thump:SetScript("OnPlay", function ()
    jolt:Stop()
    _G.C_Timer.After(0.17, function () if thump:IsPlaying() then jolt:Play() end end)
  end)
  stamp:Hide()
  tags = textContent:CreateFontString(nil, "ARTWORK")
  tags:SetFontObject(fonts.Small)
  tags:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -3)
  tags:SetTextColor(unpack(FADED))

  -- Heading and text, for the objectives and then the description
  parts = {}
  for i = 1, 2 do
    local partHeading = textContent:CreateFontString(nil, "ARTWORK")
    partHeading:SetFontObject(fonts.Heading)
    partHeading:SetTextColor(unpack(RED))
    local text = textContent:CreateFontString(nil, "ARTWORK")
    text:SetFontObject(fonts.Text)
    text:SetWidth(TEXT_W)
    text:SetWordWrap(true)
    text:SetTextColor(unpack(INK))
    text:SetPoint("TOPLEFT", partHeading, "BOTTOMLEFT", 0, -4)
    parts[i] = { heading = partHeading, text = text }
  end

  rewardsHeading = textContent:CreateFontString(nil, "ARTWORK")
  rewardsHeading:SetFontObject(fonts.Heading)
  rewardsHeading:SetTextColor(unpack(RED))
  rewardsHeading:SetText("Rewards")
  rewardsText = textContent:CreateFontString(nil, "ARTWORK")
  rewardsText:SetFontObject(fonts.Text)
  rewardsText:SetTextColor(unpack(INK))
  chooseText = textContent:CreateFontString(nil, "ARTWORK")
  chooseText:SetFontObject(fonts.Small)
  chooseText:SetTextColor(unpack(FADED))
  chooseText:SetText("Choose one:")

  hint = rightContent:CreateFontString(nil, "ARTWORK")
  hint:SetFontObject(fonts.Heading)
  hint:SetPoint("CENTER")
  hint:SetText("Choose a quest from the list")
  hint:SetTextColor(unpack(FADED))
end

-- The page turns (the tracker's own book) and the book following the quest log
local function BuildEvents()
  -- Page turns: the writing fades and slides out, the new one in
  rightContent:SetScript("OnUpdate", function (self, elapsed)
    if not turning then return end
    turning.t = turning.t + elapsed
    local t = turning.t
    local alpha, slide
    if t < TURN_OUT then
      local p = t / TURN_OUT
      alpha, slide = 1 - p, -TURN_SLIDE * p
    else
      if not turning.filled then
        turning.filled = true
        Select(turning.questID)
      end
      local p = math.min(1, (t - TURN_OUT) / TURN_IN)
      p = 1 - (1 - p) * (1 - p)
      alpha, slide = p, TURN_SLIDE * (1 - p)
      if p >= 1 then
        turning = nil
        UpdateFades()
      end
    end
    self:SetAlpha(alpha)
    self:ClearAllPoints()
    self:SetPoint("TOPLEFT", book, "TOPLEFT", RIGHT_X + slide, -TOP)
  end)

  -- The pages follow the quest log while the book is open
  book:SetScript("OnShow", function (self)
    self:RegisterEvent("QUEST_LOG_UPDATE")
    self:RegisterEvent("GET_ITEM_INFO_RECEIVED")
    self:RegisterEvent("QUEST_REMOVED")
    self:RegisterEvent("QUEST_TURNED_IN")
    -- (Share: only in a group)
    self:RegisterEvent("GROUP_ROSTER_UPDATE")
    Sound("IG_QUEST_LOG_OPEN")
  end)
  book:SetScript("OnHide", function (self)
    -- (the search starts empty next time)
    self.query = nil
    if self.search then
      self.search:SetText("")
      self.search:ClearFocus()
      self.searchOpen(false)
    end
    self:UnregisterEvent("QUEST_LOG_UPDATE")
    self:UnregisterEvent("GET_ITEM_INFO_RECEIVED")
    self:UnregisterEvent("QUEST_REMOVED")
    self:UnregisterEvent("QUEST_TURNED_IN")
    self:UnregisterEvent("GROUP_ROSTER_UPDATE")
    Core.HideQuestMap()
    ResetAnimations()
    rightContent:SetAlpha(1)
    -- (the book shutting: its sound, when its closing didn't play it already)
    if not closeSounded then Sound(CLOSE_SOUND) end
    closeSounded = false
  end)
  -- The open quest abandoned: its writing turns to dust first (BookDust,
  -- below), then the page empties. Not when it was turned in (the game may
  -- say so a moment after it says the quest left the log).
  local turnedIn, dusting
  local function Emptied(questID)
    dusting = false
    if selected == questID then Select(nil) end
  end
  book:SetScript("OnEvent", function (_, event, questID)
    if event == "QUEST_TURNED_IN" then
      turnedIn = questID
      return
    elseif event == "GROUP_ROSTER_UPDATE" then
      UpdateButtons()
      return
    elseif event == "QUEST_REMOVED" then
      if not questID or questID ~= selected then return end
      dusting = true
      _G.C_Timer.After(0.08, function ()
        local flagged = C_QuestLog.IsQuestFlaggedCompleted
        local done = turnedIn == questID or (flagged and flagged(questID))
        if done or not book:IsShown() or not BookDust(function () Emptied(questID) end) then
          Emptied(questID)
        end
      end)
      return
    end
    if pending then return end
    pending = true
    _G.C_Timer.After(REFRESH_WAIT, function ()
      pending = false
      if not book:IsShown() then return end
      -- (a quest given or abandoned leaves the right page)
      if selected and not C_QuestLog.GetLogIndexForQuestID(selected) then
        if not dusting then Select(nil) end
      elseif selected and not turning then
        FillText(selected, true)
        -- (the buttons too: what the game knows of the quest may have come)
        UpdateButtons()
      end
      FillList()
    end)
  end)
end

----
-- The map over the whole right page (Show map); "« Quest" above it goes back
-- to the writing. It's on the page, so it turns with it.

-- Shows the map over the page, or the writing again
function ShowMapView(show)
  show = show and selectedHasMap and true or false
  if show == mapView:IsShown() then return end
  mapView:SetShown(show)
  textScroll:SetShown(not show and selected ~= nil)
  -- (the page's dog-eared corner would cover the map's corner: away while
  -- the map shows)
  if book.grip then book.grip:SetShown(not show) end
  if show and Core:Animates() and book:IsShown() then mapView.fadeIn:Play() end
  UpdateButtons()
  UpdateFades()
end

local function BuildMapView()
  mapView = CreateFrame("Frame", nil, rightContent)
  mapView:SetAllPoints()
  mapView:Hide()
  mapView.fadeIn = mapView:CreateAnimationGroup()
  local fade = mapView.fadeIn:CreateAnimation("Alpha")
  fade:SetFromAlpha(0)
  fade:SetToAlpha(1)
  fade:SetDuration(SWITCH_TIME)
  fade:SetSmoothing("OUT")

  -- Back to the quest: "« Quest" in the titles' red ink, brighter under the mouse
  local back = CreateFrame("Button", nil, mapView)
  back:SetPoint("TOPLEFT", -MAP_WIDER / 2, 0)
  back:SetHeight(24)
  local label = back:CreateFontString(nil, "ARTWORK")
  label:SetFontObject(fonts.Heading)
  label:SetPoint("LEFT")
  label:SetText("\194\171 Quest")
  label:SetTextColor(unpack(RED))
  back:SetWidth(label:GetStringWidth() + 6)
  back:SetScript("OnEnter", function () label:SetTextColor(0.78, 0.22, 0.06) end)
  back:SetScript("OnLeave", function () label:SetTextColor(unpack(RED)) end)
  back:SetScript("OnClick", function ()
    wantMap = false
    ShowMapView(false)
  end)

  mapHolder = CreateFrame("Frame", nil, mapView)
  MAP_W, MAP_H = MapSize()
  mapHolder:SetSize(MAP_W, MAP_H)
  mapHolder:SetPoint("TOP", 0, -MAP_TOP)
end

-- (in a block of their own: the file's main part is at the game's limit of
-- 200 names)
local Build
do
-- The quests turned in: a second ribbon, red, falling from the top of the
-- book over the left page's margin, shorter than the blue one in the middle
-- (the spellbook's ribbon, its end only).
-- Clicked, the left page lists them; again, the quests
local RIBBON_SHOW = 0.34 -- how much of the ribbon shows (its forked end)
local RIBBON_X = LEFT_X - 46 -- where, from the book's left (in the margin)
local RIBBON_TOP = 6 -- from the book's top
-- A ribbon at x from the book's left, in its color (r, g, b): open while
-- IsOpen(), its tooltip saying where a click goes, Toggle on a click.
-- Returns its Paint and its width
local function Ribbon(x, color, IsOpen, openTip, closedTip, Toggle)
  local info = Atlas(GAME_RIBBON)
  local pageInfo = Atlas(GAME_LEFT)
  if not (info and pageInfo) then return nil end
  local scale = (BOOK_W / 2) / pageInfo.width * 0.8
  local width, height = info.width * scale, info.height * scale * RIBBON_SHOW
  -- (over the page, under the writing)
  local ribbon = book:CreateTexture(nil, "BACKGROUND", nil, 3)
  ribbon:SetTexture(info.file)
  local t, b = info.topTexCoord, info.bottomTexCoord
  ribbon:SetTexCoord(info.leftTexCoord, info.rightTexCoord, b - (b - t) * RIBBON_SHOW, b)
  ribbon:SetDesaturated(true)
  ribbon:SetSize(width, height)
  ribbon:SetPoint("TOP", book, "TOPLEFT", x, -RIBBON_TOP)
  shown[#shown + 1] = ribbon
  local button = CreateFrame("Button", nil, book)
  button:SetAllPoints(ribbon)
  -- (for the controller, BookPad.lua: left to right)
  book.ribbonButtons = book.ribbonButtons or {}
  table.insert(book.ribbonButtons, button)
  -- (its picture has room around it, most on the right: only the ribbon itself is under the
  -- mouse, or the red one's took the green one's place)
  button:SetHitRectInsets(width * 0.06, width * 0.5, 0, 0)
  local function Paint(over)
    local light = (over or IsOpen()) and 1 or 0.78
    ribbon:SetVertexColor(color[1] * light, color[2] * light, color[3] * light)
    -- (a little longer while it's open)
    ribbon:SetHeight(height + (IsOpen() and 8 or 0))
  end
  Paint(false)
  button:SetScript("OnEnter", function (self)
    Paint(true)
    local tooltip = _G.GameTooltip
    tooltip:SetOwner(self, "ANCHOR_RIGHT")
    tooltip:SetText(IsOpen() and openTip or closedTip)
    tooltip:Show()
  end)
  button:SetScript("OnLeave", function ()
    Paint(false)
    _G.GameTooltip:Hide()
  end)
  button:SetScript("OnClick", function (self)
    Toggle()
    Sound("IG_ABILITY_PAGE_TURN")
    Paint(self:IsMouseOver())
    if self:IsMouseOver() then self:GetScript("OnEnter")(self) end
  end)
  return Paint, width
end

local function BuildRibbon()
  -- The quests turned in: red, over the left page's margin
  local width
  book.ribbonPaint, width = Ribbon(RIBBON_X, { 0.85, 0.24, 0.16 }, function () return book.showDone end,
    "Back to the quests", "Completed quests", function ()
      book.showDone = not book.showDone or nil
      -- (the right page empty, as when the book opens)
      Select(nil)
      list:SetVerticalScroll(0)
      FillList()
    end)
  -- The atlas (Tracker/Atlas.lua): green, beside the red one (its picture
  -- has room on both sides: half its width apart).
  -- Clicked, the right page shows it; again (or a quest opened), it goes
  if Core.AtlasShow then
    book.atlasPaint = Ribbon(RIBBON_X + (width or 60) * 0.48, { 0.22, 0.52, 0.30 }, function () return book.showAtlas end,
      "Close the atlas", "Atlas", function ()
        book.showAtlas = not book.showAtlas or nil
        Select(nil)
      end)
  end
end

function Build()
  BuildBook(GameBook())
  BuildRibbon()
  BuildLeft()
  BuildRight()
  BuildMapView()
  BuildButtons()
  BuildEvents()
  if Core.BookBuilt then Core.BookBuilt() end
end
end


----
-- Animations (only while the book is open, and only with the animations on
-- in the options):
-- - opening: the pages unfold from the spine, then the writing fades in;
--   closing: the pages fold back and the book fades out
-- - another quest: a page turns over the spine
-- - the list's quests come in one after the other as the book opens
-- - a quest just done glows gold in the list
-- One driver runs them all, and only while the book shows.

-- (in a scope of its own: the file has more locals than the game allows in
-- one; what the rest uses is declared outside it)
local closing, flip, Animates
do
local OPEN_IN, OPEN_TURN, OPEN_WRITING = 0.14, 0.7, 0.2 -- the shut book shows, its cover opens, the writing comes
local CLOSE_WRITING, CLOSE_TURN, CLOSE_OUT = 0.1, 0.55, 0.16 -- the writing goes, the page folds over, the book goes
local sheetEnd = 0 -- where the turning sheet ends, from the spine (left: below 0)

-- The book's shadow out to the right of the spine as far as the pages go
-- (none on the right while the book is shut)
local function ShadowTo(right)
  if not bookShadow then return end
  bookShadow:SetPoint("BOTTOMRIGHT", book, "BOTTOM", math.max(0, right) + 36, -40)
end
local FLIP_OUT = 0.12 -- the old writing fades off the page
local FLIP_TIME = 0.72 -- then the sheet turns
local FLIP_STRIPS = 16 -- the sheet in strips, so it can bend
local FLIP_CURL = 0.45 -- how far its outer edge leads the part by the spine
local FLIP_LAND = 0.18 -- at the end, the sheet fades into the page it lands on
local CASCADE_STEP, CASCADE_IN, CASCADE_MAX = 0.025, 0.2, 24
local FLASH_TIME = 1.6
local GOLD = { 1.0, 0.80, 0.35 }

local driver, opening, cascadeT
local strips, sheetShadow, flipLayer, flipQuest = {}, nil, nil, nil
local flashing = {} -- rows glowing: row = time left

local function Ease(p) return p * p * (3 - 2 * p) end
function Animates() return Core:Animates() and Core.db.profile.bookAnimations end

-- The pages' width out from the spine, 0 (shut) to 1 (open)
local function Unfold(p)
  if not pageLeft then return end
  local half = BOOK_W / 2
  local w = math.max(1, half * p)
  local shade = (0.55 + 0.45 * p) * Paper()
  pageLeft:ClearAllPoints()
  pageLeft:SetPoint("TOPRIGHT", book, "TOP")
  pageLeft:SetPoint("BOTTOMRIGHT", book, "BOTTOM")
  pageLeft:SetWidth(w)
  pageRight:ClearAllPoints()
  pageRight:SetPoint("TOPLEFT", book, "TOP")
  pageRight:SetPoint("BOTTOMLEFT", book, "BOTTOM")
  pageRight:SetWidth(w)
  pageLeft:SetVertexColor(shade, shade, shade)
  pageRight:SetVertexColor(shade, shade, shade)
end

local function Writing(alpha)
  writingAlpha = alpha
  for _, region in ipairs(shown) do region:SetAlpha(alpha) end
  -- (the map's corner tape comes with the writing, unless a sheet turns:
  -- it stayed hidden when the cover's turn ended before the writing came)
  local tapes = Core.QuestMapTapes and Core.QuestMapTapes()
  if tapes and not (flipLayer and flipLayer:IsShown()) then tapes:SetAlpha(alpha) end
end

local function BuildFlip()
  flipLayer = CreateFrame("Frame", nil, book)
  flipLayer:SetAllPoints()
  flipLayer:SetFrameLevel(book:GetFrameLevel() + 60)
  for i = 1, FLIP_STRIPS do
    strips[i] = flipLayer:CreateTexture(nil, "ARTWORK")
  end
  sheetShadow = flipLayer:CreateTexture(nil, "BORDER")
  sheetShadow:SetColorTexture(1, 1, 1, 1)
  -- (the page's dog-eared corner is over the sheets' layer: away while a
  -- sheet or the cover turns, or it shows over it)
  -- (the map's corner tape too, put over it: see Select)
  local function Over(alpha)
    if book.grip then book.grip:SetAlpha(alpha) end
    local tapes = Core.QuestMapTapes and Core.QuestMapTapes()
    if tapes then tapes:SetAlpha(alpha > 0 and 1 or 0) end
  end
  flipLayer:SetScript("OnShow", function () Over(0) end)
  flipLayer:SetScript("OnHide", function () Over(writingAlpha) end)
  flipLayer:Hide()
end

local function Smoother(p) return p < 0.5 and 4 * p * p * p or 1 - (-2 * p + 2) ^ 3 / 2 end

-- The sheet at a time of its turn (0 to 1). It's a chain of strips from the
-- spine out; each strip turns over the spine, the outer ones ahead of the
-- ones by the spine, so the sheet bends. A strip turned past standing up
-- shows the back of the sheet (the left page's paper). True when it's over.
local function UpdateSheet(p, kind)
  local half = BOOK_W / 2
  local piece = half / FLIP_STRIPS
  local right, left = Atlas(GAME_RIGHT), Atlas(GAME_LEFT)
  local x = 0 -- where the strip starts, from the spine (left: below 0)
  local edgeLift = 0
  -- (a page turned fades into the page it lands on)
  local alpha = kind == "turn" and 1 - Ease(math.max(0, (p - (1 - FLIP_LAND)) / FLIP_LAND)) or 1
  for i, strip in ipairs(strips) do
    local d0, d1 = (i - 1) / FLIP_STRIPS, i / FLIP_STRIPS
    -- (a cover, or the book shutting, turns stiff and all at once; a page bends)
    local turn = kind ~= "turn" and p or math.max(0, math.min(1, p * (1 + FLIP_CURL) - FLIP_CURL * (1 - d1)))
    -- (the cover opens from the left; a page turns, and the book closes, to it)
    local angle = math.pi * (kind == "open" and 1 - turn or turn)
    local c = math.cos(angle)
    local x2 = x + piece * c
    -- light: full lying flat, darker standing up, the back a little darker
    local shade = (0.5 + 0.5 * math.abs(c)) * (c < 0 and 0.92 or 1)
    local from, to = math.min(x, x2), math.max(x, x2)
    strip:ClearAllPoints()
    strip:SetPoint("TOPLEFT", book, "TOP", from, 0)
    strip:SetPoint("BOTTOMLEFT", book, "BOTTOM", from, 0)
    strip:SetWidth(math.max(0.5, to - from))
    if c >= 0 then
      -- the front: the right page's paper from d0 to d1 (left to right)
      local u0 = right.leftTexCoord + (right.rightTexCoord - right.leftTexCoord) * d0
      local u1 = right.leftTexCoord + (right.rightTexCoord - right.leftTexCoord) * d1
      strip:SetTexture(right.file)
      strip:SetTexCoord(u0, u1, right.topTexCoord, right.bottomTexCoord)
    elseif kind ~= "turn" then
      -- the book opening or shutting: its front cover (Assets/cover, see
      -- Tools/marks.py; its right edge at the spine)
      strip:SetTexture(Core.ASSETS.."cover")
      strip:SetTexCoord(1 - d1, 1 - d0, 0, 1)
    else
      -- the back: the left page's paper, as far from the spine (its outer
      -- end is on the screen's left)
      local function U(d) return left.rightTexCoord - (left.rightTexCoord - left.leftTexCoord) * d end
      strip:SetTexture(left.file)
      strip:SetTexCoord(U(d1), U(d0), left.topTexCoord, left.bottomTexCoord)
    end
    -- (the paper as bright as the pages; the cover as it is)
    local k = (c >= 0 or kind == "turn") and shade * Paper() or shade
    strip:SetVertexColor(k, k, k, alpha)
    strip:Show()
    x = x2
    if i == FLIP_STRIPS then edgeLift = math.sin(angle) end
  end
  -- (the ribbon, gone while a page turns, comes back as it lands)
  if ribbonMark and kind == "turn" then ribbonMark:SetAlpha(1 - alpha) end
  -- A soft shadow on the page past the sheet's outer edge, while it's up
  local dark = _G.CreateColor(0, 0, 0, 0.32 * edgeLift * alpha)
  local clear = _G.CreateColor(0, 0, 0, 0)
  local reach = 20 + 60 * edgeLift
  sheetShadow:ClearAllPoints()
  if x >= 0 then
    sheetShadow:SetPoint("TOPLEFT", book, "TOP", x, 0)
    sheetShadow:SetPoint("BOTTOMLEFT", book, "BOTTOM", x, 0)
    sheetShadow:SetWidth(math.max(1, math.min(reach, half - x)))
    sheetShadow:SetGradient("HORIZONTAL", dark, clear)
  else
    sheetShadow:SetPoint("TOPRIGHT", book, "TOP", x, 0)
    sheetShadow:SetPoint("BOTTOMRIGHT", book, "BOTTOM", x, 0)
    sheetShadow:SetWidth(math.max(1, math.min(reach, half + x)))
    sheetShadow:SetGradient("HORIZONTAL", clear, dark)
  end
  sheetEnd = x
  return p >= 1
end

local function UpdateFlip(t)
  return UpdateSheet(Smoother(math.min(1, t / FLIP_TIME)), "turn")
end

---
-- A quest just done: a gold glow behind it, its gold fading into green
function Flash(row)
  if not Animates() then return end
  if not row.glow then
    row.glow = Core.Smooth(row:CreateTexture(nil, "BACKGROUND"))
    row.glow:SetTexture(Core.ASSETS.."circleSoft")
    row.glow:SetBlendMode("ADD")
    row.glow:SetPoint("CENTER", row.text, "CENTER")
  end
  flashing[row] = FLASH_TIME
end

local function UpdateFlashes(elapsed)
  for row, left in pairs(flashing) do
    left = left - elapsed
    if left <= 0 or not row:IsShown() then
      flashing[row] = nil
      row.glow:Hide()
      row.text:SetTextColor(unpack(row.open and RED or row.color))
    else
      flashing[row] = left
      local p = 1 - left / FLASH_TIME
      local glow = math.sin(math.pi * math.min(1, p * 1.4))
      local width = math.min(row.text:GetWidth(), row.text:GetStringWidth())
      row.glow:SetSize(width + 50, row:GetHeight() * 3)
      row.glow:SetVertexColor(GOLD[1], GOLD[2], GOLD[3], 0.7 * glow)
      row.glow:Show()
      local k = Ease(p)
      local c = row.color
      local r, g, b = GOLD[1] * 0.6, GOLD[2] * 0.6, GOLD[3] * 0.3
      row.text:SetTextColor(r + (c[1] - r) * k, g + (c[2] - g) * k, b + (c[3] - b) * k)
    end
  end
end

-- The list's rows coming in, one after the other, sliding in from the left
local function UpdateCascade()
  local done = true
  for _, row in ipairs(rows) do
    if row:IsShown() and row.y then
      local delay = math.min(row.order or 1, CASCADE_MAX) * CASCADE_STEP
      local a = math.max(0, math.min(1, (cascadeT - delay) / CASCADE_IN))
      if a < 1 then done = false end
      local k = Ease(a)
      row:SetAlpha(k)
      row:ClearAllPoints()
      row:SetPoint("TOPLEFT", row.x - 12 * (1 - k), -row.y)
    end
  end
  UpdateMarker()
  if done then cascadeT = nil end
end

local function Driver(_, elapsed)
  if opening then
    -- shut (its cover over the left page), it fades in; the cover opens over
    -- the spine onto the right; then the writing comes
    opening = opening + elapsed
    local t = opening
    if t < OPEN_IN then
      book:SetAlpha(Ease(t / OPEN_IN))
      UpdateSheet(0, "open")
      ShadowTo(0)
    elseif t < OPEN_IN + OPEN_TURN then
      book:SetAlpha(1)
      UpdateSheet(Smoother((t - OPEN_IN) / OPEN_TURN), "open")
      ShadowTo(sheetEnd)
    else
      if flipLayer:IsShown() then
        flipLayer:Hide()
        pageRight:Show()
        ShadowTo(BOOK_W / 2)
        cascadeT = 0
      end
      local p = math.min(1, (t - OPEN_IN - OPEN_TURN) / OPEN_WRITING)
      Writing(Ease(p))
      if p >= 1 then
        opening = nil
        -- (a quest done: its stamp comes down now, the page all there)
        if stamp:IsShown() then
          stamp:SetAlpha(STAMP_ALPHA)
          stamp.thump:Play()
        end
        UpdateFades()
      end
    end
  elseif closing then
    -- the writing goes; the right page folds over the spine, its cover on
    -- top as it lands on the left; then the shut book fades out
    closing = closing + elapsed
    local t = closing
    if t < CLOSE_WRITING then
      Writing(1 - Ease(t / CLOSE_WRITING))
    elseif t < CLOSE_WRITING + CLOSE_TURN then
      if not flipLayer:IsShown() then
        Writing(0)
        pageRight:Hide()
        flipLayer:Show()
      end
      UpdateSheet(Smoother((t - CLOSE_WRITING) / CLOSE_TURN), "close")
      ShadowTo(sheetEnd)
    else
      UpdateSheet(1, "close")
      ShadowTo(0)
      local p = math.min(1, (t - CLOSE_WRITING - CLOSE_TURN) / CLOSE_OUT)
      book:SetAlpha(1 - Ease(p))
      if p >= 1 then
        closing = nil
        book:Hide()
        return
      end
    end
  end
  if flip then
    flip = flip + elapsed
    if flip < FLIP_OUT then
      -- the old writing (and the ribbon) fades off the page first
      rightContent:SetAlpha(1 - Ease(flip / FLIP_OUT))
      if ribbonMark then ribbonMark:SetAlpha(1 - Ease(flip / FLIP_OUT)) end
    else
      if flipQuest then
        -- then the new quest goes under the sheet, which starts to turn
        local questID = flipQuest
        flipQuest = nil
        Select(questID)
        rightContent:SetAlpha(1)
        flipLayer:Show()
      end
      if UpdateFlip(flip - FLIP_OUT) then
        flip = nil
        flipLayer:Hide()
        if pageButtons.bar then pageButtons.bar:SetAlpha(1) end
        stamp:SetAlpha(STAMP_ALPHA)
        if stamp:IsShown() then stamp.thump:Play() end
        UpdateFades()
      end
    end
  end
  if cascadeT then
    cascadeT = cascadeT + elapsed
    UpdateCascade()
  end
  if next(flashing) then UpdateFlashes(elapsed) end
end

---
-- The book opening (called as it shows)
function StartOpen()
  if not driver then
    driver = CreateFrame("Frame", nil, book)
    driver:SetScript("OnUpdate", Driver)
  end
  closing = nil
  book:SetAlpha(1)
  if not Animates() then
    Unfold(1)
    Writing(1)
    return
  end
  if pageLeft then
    if not flipLayer then BuildFlip() end
    opening = 0
    flip, flipQuest = nil, nil
    Unfold(1)
    Writing(0)
    pageRight:Hide()
    flipLayer:Show()
    book:SetAlpha(0)
    UpdateSheet(0, "open")
  else
    cascadeT = 0
  end
end

---
-- Closes the book (the pages folding back to the spine)
function CloseBook()
  if not book or not book:IsShown() then return end
  if not Animates() or not pageLeft then
    book:Hide()
    return
  end
  if closing then return end
  if not flipLayer then BuildFlip() end
  -- (the sound of a book shutting, as it starts to)
  Sound(CLOSE_SOUND)
  closeSounded = true
  opening, flip, flipQuest = nil, nil, nil
  flipLayer:Hide()
  pageRight:Show()
  book:SetAlpha(1)
  closing = 0
end

---
-- A page turn on the spellbook's pages, to a quest; false without them or
-- with the animations off
function StartFlip(questID)
  if not (pageLeft and Animates()) then return false end
  if not flipLayer then BuildFlip() end
  flipLayer:Hide()
  UpdateFlip(0)
  if ribbonMark then ribbonMark:SetAlpha(1) end -- (it fades with the old writing)
  flip, flipQuest = 0, questID
  -- (the buttons are over the turning sheet's level: away while it turns)
  if pageButtons.bar then pageButtons.bar:SetAlpha(0) end
  stamp:SetAlpha(0)
  return true
end

---
-- Everything back in place (the book hidden, Escape included)
function ResetAnimations()
  turning, opening, closing, flip, cascadeT, flipQuest = nil, nil, nil, nil, nil, nil
  if flipLayer then flipLayer:Hide() end
  if pageButtons.bar then pageButtons.bar:SetAlpha(1) end
  stamp:SetAlpha(STAMP_ALPHA)
  if pageRight then pageRight:Show() end
  ShadowTo(BOOK_W / 2)
  book:SetAlpha(1)
  Unfold(1)
  Writing(1)
  for row in pairs(flashing) do
    flashing[row] = nil
    row.glow:Hide()
  end
  for _, row in ipairs(rows) do row:SetAlpha(1) end
end
end

----
-- Filling the pages

-- The quests the search finds (in their name, their zone or their
-- objectives), with their zones; and how many
local function Searched(quests, query)
  local found, kept, zone, added = {}, 0, nil, {}
  for _, item in ipairs(quests) do
    if item.header then
      zone = item
    else
      local words = { item.title or "", item.history and (item.history.zone or "") or item.zone and item.zone.title or "" }
      for _, objective in ipairs(item.questID and C_QuestLog.GetQuestObjectives(item.questID) or {}) do
        words[#words + 1] = objective.text or ""
      end
      if table.concat(words, " "):lower():find(query, 1, true) then
        -- (its zone once, before its first quest found)
        -- (and a day's month and year, before it)
        local around, outer = {}, zone
        while outer and not added[outer] do
          table.insert(around, 1, outer)
          added[outer] = true
          outer = outer.parent
        end
        for _, header in ipairs(around) do found[#found + 1] = header end
        found[#found + 1] = item
        kept = kept + 1
      end
    end
  end
  return found, kept
end

function FillList()
  local quests, n = QuestList()
  -- (the search box: only what it finds, every zone open)
  local query = book.query ~= nil and book.query ~= "" and book.query:lower() or nil
  local shownCount = n
  if query then quests, shownCount = Searched(quests, query) end
  book.heading:SetText(book.showDone and "Completed" or "Quests")
  if query then
    count:SetText(("%d of %d quests"):format(shownCount, n))
  elseif book.showDone then
    count:SetText(n == 1 and "1 quest turned in" or n.." quests turned in")
  else
    count:SetText(n == 1 and "1 quest" or n.." quests")
  end
  local at = list:GetVerticalScroll()
  for _, row in ipairs(rows) do row:Hide() end
  local collapsed = Collapsed()

  local width = listContent:GetWidth()
  local y, i = 0, 0
  local last
  for _, item in ipairs(quests) do
    -- (a day inside a month or year: shown while that one is open, its
    -- quests while both are; one step in)
    -- (a year, month or day closed: what's inside it hidden; a step in for
    -- each one around)
    local outer = item.header and item.parent or item.zone
    local hidden, depth = false, 0
    while outer do
      if collapsed[outer.title] then hidden = true end
      depth = depth + 1
      outer = outer.parent
    end
    outer = item.header and item.parent or item.zone and item.zone.parent
    if query then hidden = false end
    -- (a quest outside any zone: still a step in)
    if not item.header and depth == 0 then depth = 1 end
    if not hidden then
      i = i + 1
      local row = Row(i)
      local indent = depth * INDENT
      -- (a little more room above each zone, but the first, and a day right
      -- under its month)
      if item.header and i > 1 and not (outer and last == outer) then y = y + GAP - ROW_GAP end
      last = item
      row.questID = item.questID
      row.history = item.history
      row.zone = item.header and item.title or nil
      row.diary = item.header and item.diary or nil
      row.text:SetFontObject(item.header and fonts.ListZone or fonts.List)
      -- (the game's colors, with a thin black edge to read on the paper)
      row.text:SetShadowColor(0, 0, 0, 0.9)
      row.text:SetShadowOffset(1, -1)
      row.text:ClearAllPoints()
      if item.header then
        local closed = not query and collapsed[item.title]
        row.color = ZONE()
        row.toggle:SetVertexColor(unpack(row.color))
        row.text:SetText(item.label or item.title)
        -- (and how many quests it has, between brackets after it)
        row.count:SetText("("..item.quests..")")
        row.count:ClearAllPoints()
        row.count:SetPoint("LEFT", row.text, "LEFT", math.min(row.text:GetStringWidth(), width - indent - 16) + 5, -1)
        row.count:Show()
        row.toggle:SetTexture(Core.ASSETS..(closed and "expand" or "collapse"))
        row.toggle:Show()
        row.text:SetPoint("TOPLEFT", 16, 0)
        row.text:SetWidth(width - indent - 16)
      else
        row.toggle:Hide()
        row.count:Hide()
        if item.history then
          -- (turned in: faded, under its day; a repeatable one with how many times)
          row.color = FADED
          local times = item.history.times
          row.text:SetText(times and times > 1 and ("%s  %sx%d|r"):format(item.title, FADED_HEX, times) or item.title)
        else
          -- (its difficulty's color; done: the game's "?" to give it back after it)
          row.color = DifficultyInk(item.questID, item.level)
          local text = Core.QuestName(item.title, item.level)
          if item.done then
            -- (the game sizes atlas icons with the letters: the same number fits
            -- any text size)
            text = Atlas(MARK_DONE) and ("%s |A:%s:%d:%d|a"):format(text, MARK_DONE, DONE_MARK, DONE_MARK) or text
          end
          if item.tags ~= "" then text = text.."  "..FADED_HEX..item.tags.."|r" end
          row.text:SetText(text)
        end
        row.text:SetPoint("TOPLEFT")
        row.text:SetWidth(width - indent)
      end
      local open = (item.questID and item.questID == selected)
        or (item.history and item.history == book.openDone) or false
      row.selected:SetShown(open)
      row.open = open
      row.order = i
      -- (just done while the book was open, or since it last was: a glow)
      if item.questID then
        if item.done and wasDone[item.questID] == false then Flash(row) end
        wasDone[item.questID] = item.done and true or false
      end
      row.text:SetTextColor(unpack(open and RED or row.color))
      row.underline:Hide()
      row:ClearAllPoints()
      row:SetPoint("TOPLEFT", indent, -y)
      row.x, row.y = indent, y
      row:SetWidth(width - indent)
      row:SetHeight(row.text:GetStringHeight())
      if open then
        local textWidth = math.min(row.text:GetWidth(), row.text:GetStringWidth())
        row.selected:ClearAllPoints()
        row.selected:SetPoint("CENTER", row.text, "LEFT", textWidth / 2, 0)
        row.selected:SetSize(textWidth + 70, row:GetHeight() * 2.6)
      end
      row:Show()
      y = y + row:GetHeight() + ROW_GAP
    end
  end
  if i == 0 then
    local row = Row(1)
    row.questID, row.zone, row.history, row.diary = nil, nil, nil, nil
    row.color = FADED
    row.toggle:Hide()
    row.count:Hide()
    row.selected:Hide()
    row.text:SetFontObject(fonts.ListPlain)
    row.text:SetShadowOffset(0, 0)
    row.text:SetText(n > 0 and "No quests found." or book.showDone and "No quests turned in yet." or "No quests taken.")
    row.text:SetTextColor(unpack(FADED))
    row.text:ClearAllPoints()
    row.text:SetPoint("TOPLEFT")
    row.text:SetWidth(width)
    row:ClearAllPoints()
    row:SetPoint("TOPLEFT")
    row:SetWidth(width)
    row:SetHeight(row.text:GetStringHeight())
    row:Show()
    y = row:GetHeight()
  end
  listContent:SetHeight(math.max(1, y))
  list:SetVerticalScroll(math.min(at, math.max(0, y - list:GetHeight())))
  UpdateFades()
  if Core.BookListFilled then Core.BookListFilled() end
end

---
-- The right page's writing (keep: where it was scrolled stays)
function FillText(questID, keep, entry)
  -- A quest done: "Completed" stamped on the page (with a thump as it shows)
  local done = (entry and not entry.diary) or (not entry and C_QuestLog.IsComplete(questID)) and true or false
  local wasShown = stamp:IsShown()
  stamp:SetShown(done)
  -- (during a page turn, once the page lands; the book opening, once its
  -- writing is all there: see the animations)
  local later = flip or writingAlpha < 1
  if done and (not keep or not wasShown) and Core:Animates() then
    -- (not there at all until it comes down)
    if later then stamp:SetAlpha(0) else stamp.thump:Play() end
  end
  local kinds, icons, name
  if entry and entry.diary then
    -- (a page of the diary: its day, and where you went)
    kinds, icons, name = entry.sub or "", "", entry.title or ""
  elseif entry then
    -- (turned in: when, and where)
    local last = (entry.times or 1) > 1 and entry.times.." times, last " or ""
    kinds, icons, name = entry.at and ("Turned in "..last..date("%d %b %Y", entry.at)) or "", "", entry.title or ""
    if entry.zone then kinds = kinds ~= "" and kinds..", "..entry.zone or entry.zone end
  else
    local index = C_QuestLog.GetLogIndexForQuestID(questID)
    local info = index and C_QuestLog.GetInfo(index)
    -- (the kind's icon right after the name, a little bigger; the words below)
    kinds, icons = Tags(questID, info and info.frequency, TAG_ICON_PAGE, true)
    name = C_QuestLog.GetTitleForQuestID(questID) or ""
  end
  title:SetText(icons ~= "" and name.." "..icons or name)
  tags:SetText(kinds)
  local y = title:GetStringHeight() + (kinds ~= "" and tags:GetStringHeight() + 3 or 0) + GAP

  local description, objectives
  if entry and entry.diary then
    description = entry.text
  elseif entry then
    description, objectives = entry.text or "Turned in before the book kept the quests' text.", entry.objectives
  else
    description, objectives = QuestText(questID)
  end
  local texts = {
    { "Objectives", objectives },
    { entry and entry.diary and (entry.heading or "Diary") or "Description",
      description or "The game didn't give this quest's text." },
  }
  -- (in a party: the others' faces beside "Objectives", over each their
  -- objectives, GroupLead.lua)
  if Core.DrawFaces then
    local heading = parts[1].heading
    if not book.groupFaces then
      book.groupFaces = CreateFrame("Frame", nil, heading:GetParent())
    end
    local faces = not entry and objectives and objectives ~= "" and Core.GroupFaces(questID) or nil
    local height, width = Core.DrawFaces(book.groupFaces, faces, 16, questID)
    book.groupFaces:SetSize(math.max(1, width), math.max(1, height))
  end
  for i, part in ipairs(parts) do
    local name, text = texts[i][1], texts[i][2]
    if text and text ~= "" then
      part.heading:ClearAllPoints()
      part.heading:SetPoint("TOPLEFT", 0, -y)
      part.heading:SetText(name)
      part.text:SetText(text)
      part.heading:Show()
      part.text:Show()
      if i == 1 and book.groupFaces then
        book.groupFaces:ClearAllPoints()
        book.groupFaces:SetPoint("LEFT", part.heading, "RIGHT", 8, 0)
      end
      y = y + part.heading:GetStringHeight() + 4 + part.text:GetStringHeight() + GAP
    else
      part.heading:Hide()
      part.text:Hide()
    end
  end

  -- Rewards: experience and money in a line, then the items (and the ones
  -- to choose from)
  for _, button in ipairs(rewardButtons) do button:Hide() end
  local rewards
  if entry then
    -- (turned in: what it gave, and all the rewards to choose from, the
    -- one chosen in its color)
    local kept = entry.rewards or {}
    -- (an item the game hadn't loaded then: its name and icon asked for now,
    -- the page filled again once they come; one not known at all, left out)
    local function Known(item, dim)
      local id = item.itemID or item.link
      local GetInfo = _G.C_Item and _G.C_Item.GetItemInfo or _G.GetItemInfo
      if item.name or not (id and GetInfo) then
        return item.name and setmetatable({ dim = dim }, { __index = item }) or nil
      end
      local name, link, quality, _, _, _, _, _, _, texture = GetInfo(id)
      if not name and item.itemID and _G.Item and _G.Item.CreateFromItemID then
        _G.Item:CreateFromItemID(item.itemID):ContinueOnItemLoad(function ()
          if book.openDone == entry then FillText(nil, true, entry) end
        end)
      end
      return setmetatable({ name = name, link = item.link or link, quality = quality, texture = texture, dim = dim },
        { __index = item })
    end
    local items, choices = {}, {}
    for _, item in ipairs(kept.items or {}) do items[#items + 1] = Known(item) end
    for i, item in ipairs(kept.choices or {}) do
      choices[#choices + 1] = Known(item, entry.chosen and entry.chosen ~= i or nil)
    end
    rewards = { xp = kept.xp or entry.xp, money = kept.money or entry.money, items = items, choices = choices }
  else
    rewards = Rewards(questID)
  end
  chooseText:SetText(not entry and "Choose one:" or entry.chosen and "You chose:" or "To choose from:")
  rewardsHeading:SetText(entry and entry.diary and "Earned" or "Rewards")
  local line = {}
  -- (the experience with the tracker's own xp icon, in the experience bar's
  -- purple with a thin dark outline; the money with the game's coins: gold,
  -- silver and copper)
  -- (the icons go with the writing's size, a little lower than the line's
  -- middle so they sit on the numbers; the xp picture is wide, so bigger)
  local _, textSize = fonts.Text:GetFont()
  textSize = textSize or Core.db.profile.bookTextSize or 12
  local size = math.floor(textSize * 1.25 + 0.5)
  local xpSize = math.floor(textSize * 1.7 + 0.5)
  local down = -math.floor(textSize * 0.25 + 0.5)
  if rewards.xp and rewards.xp > 0 then
    local number = _G.BreakUpLargeNumbers and _G.BreakUpLargeNumbers(rewards.xp) or rewards.xp
    line[#line + 1] = ("|T%sxpBook:%d:%d:0:%d|t %s"):format(Core.ASSETS, xpSize, xpSize, down, number)
  end
  if rewards.money and rewards.money > 0 then
    local gold = math.floor(rewards.money / 10000)
    local silver = math.floor(rewards.money / 100) % 100
    local copper = rewards.money % 100
    local coins = {}
    local function Coin(amount, icon)
      if amount > 0 then coins[#coins + 1] = ("%d|TInterface\\MoneyFrame\\UI-%sIcon:%d:%d:2:%d|t"):format(amount, icon, size, size, down) end
    end
    Coin(gold, "Gold")
    Coin(silver, "Silver")
    Coin(copper, "Copper")
    line[#line + 1] = table.concat(coins, "  ")
  end
  local any = #line > 0 or #rewards.items > 0 or #rewards.choices > 0
  rewardsHeading:SetShown(any)
  rewardsText:SetShown(#line > 0)
  chooseText:SetShown(#rewards.choices > 0)
  if any then
    rewardsHeading:ClearAllPoints()
    rewardsHeading:SetPoint("TOPLEFT", 0, -y)
    y = y + rewardsHeading:GetStringHeight() + 6
    if #line > 0 then
      rewardsText:SetText(table.concat(line, "     "))
      rewardsText:ClearAllPoints()
      rewardsText:SetPoint("TOPLEFT", 0, -y)
      y = y + rewardsText:GetStringHeight() + 6
    end
    local n = 0
    local function Grid(items)
      for i, item in ipairs(items) do
        n = n + 1
        ShowReward(n, item, y, (i - 1) % 2)
        if i % 2 == 0 or i == #items then y = y + REWARD_H + 2 end
      end
    end
    Grid(rewards.items)
    if #rewards.choices > 0 then
      chooseText:ClearAllPoints()
      chooseText:SetPoint("TOPLEFT", 0, -(y + 2))
      y = y + chooseText:GetStringHeight() + 6
      Grid(rewards.choices)
    end
    y = y + GAP
  end


  textContent:SetHeight(math.max(1, y - GAP))
  if keep then
    textScroll:SetVerticalScroll(math.min(textScroll:GetVerticalScroll(),
      math.max(0, textContent:GetHeight() - textScroll:GetHeight())))
  else
    textScroll:SetVerticalScroll(0)
  end
  UpdateFades()
  UpdateButtons()
end

-- The zone of a quest open in the list (true if it was closed)
local function OpenZoneOf(questID)
  local collapsed, zoneTitle = Collapsed(), nil
  for i = 1, C_QuestLog.GetNumQuestLogEntries() do
    local info = C_QuestLog.GetInfo(i)
    if info and info.isHeader then
      zoneTitle = info.title
    elseif info and info.questID == questID then
      if zoneTitle and collapsed[zoneTitle] then
        collapsed[zoneTitle] = nil
        return true
      end
      return false
    end
  end
  return false
end

---
-- Opens a quest on the right page at once (nil: none); its zone opens in
-- the list
function Select(questID)
  selected = questID
  book.openDone = nil
  -- (a quest opened: the atlas goes)
  if questID and book.showAtlas then
    book.showAtlas = nil
    if book.atlasPaint then book.atlasPaint(false) end
  end
  if questID and OpenZoneOf(questID) and book:IsShown() then FillList() end
  if not questID then
    Core.HideQuestMap()
    selectedHasMap = false
    mapView:Hide()
    if book.grip then book.grip:Show() end
    textScroll:Hide()
    -- (the atlas ribbon open: the atlas on the empty page, Tracker/Atlas.lua)
    local atlas = book.showAtlas and Core.AtlasShow and Core.AtlasShow(rightContent)
    if not atlas and Core.AtlasHide then Core.AtlasHide() end
    hint:SetShown(not atlas)
    UpdateButtons()
    if book:IsShown() then FillList() end
    return
  end
  hint:Hide()
  if Core.AtlasHide then Core.AtlasHide() end
  textScroll:Show()
  -- The writing the whole page; the map over it with Show map (and for a
  -- quest opened from the map)
  selectedHasMap = Core.ShowQuestMap(questID, mapHolder)
  -- (the tape on the map's bottom right corner was under the page's
  -- dog-eared corner: put over it, away while a sheet turns, see BuildFlip)
  local tapes = Core.QuestMapTapes and Core.QuestMapTapes()
  if tapes and not tapes.raised then
    tapes.raised = true
    tapes:SetFrameLevel(book:GetFrameLevel() + 76)
  end
  mapView:SetShown(selectedHasMap and wantMap or false)
  textScroll:SetShown(not mapView:IsShown())
  if book.grip then book.grip:SetShown(not mapView:IsShown()) end
  textScroll:ClearAllPoints()
  textScroll:SetPoint("TOPLEFT")
  -- (the buttons under it: Track, Share, Abandon)
  textScroll:SetPoint("BOTTOMRIGHT", 0, BUTTONS_H + 6)
  FillText(questID)
  if book:IsShown() then FillList() end
end

---
-- Opens a quest with a page turn (at once if none was open)
function Turn(questID)
  if not selected or not book:IsShown() then
    Select(questID)
    return
  end
  if questID == selected and not turning and not flip then return end
  Sound("IG_ABILITY_PAGE_TURN")
  -- (the spellbook's pages: a sheet turns over; the tracker's own book: the
  -- writing fades out and in)
  if StartFlip(questID) then return end
  turning = { t = 0, questID = questID }
end

---
-- Opens a quest turned in on the right page (an entry of the history)
function Core.ShowDoneQuest(entry)
  if not book or book.openDone == entry then return end
  Sound("IG_ABILITY_PAGE_TURN")
  selected = nil
  book.openDone = entry
  if book.showAtlas then
    book.showAtlas = nil
    if book.atlasPaint then book.atlasPaint(false) end
  end
  Core.HideQuestMap()
  selectedHasMap = false
  mapView:Hide()
  if book.grip then book.grip:Show() end
  hint:Hide()
  if Core.AtlasHide then Core.AtlasHide() end
  textScroll:Show()
  textScroll:ClearAllPoints()
  textScroll:SetPoint("TOPLEFT")
  textScroll:SetPoint("BOTTOMRIGHT", 0, BUTTONS_H + 6)
  FillText(nil, false, entry)
  FillList()
end

-- The names the zone you're in can have in the quest log: its map's (and
-- the maps around it, for a town or a cave in a zone) and the game's own
local function HereNames()
  local names = {}
  local function Add(name) if Core.Readable(name) and name ~= "" then names[name] = true end end
  Add(_G.GetZoneText and _G.GetZoneText())
  Add(_G.GetRealZoneText and _G.GetRealZoneText())
  local Map = _G.C_Map
  local mapID = Map and Map.GetBestMapForUnit and Map.GetBestMapForUnit("player")
  for _ = 1, 4 do
    local info = mapID and Map.GetMapInfo(mapID)
    if not info then break end
    Add(info.name)
    mapID = info.parentMapID
  end
  return names
end

-- Opening the book: every zone of the list closed, but the one you're in
local function CloseZones()
  local collapsed, here = Collapsed(), HereNames()
  for i = 1, C_QuestLog.GetNumQuestLogEntries() do
    local info = C_QuestLog.GetInfo(i)
    if info and info.isHeader and info.title then
      collapsed[info.title] = not here[info.title] or nil
    end
  end
end

local function Open()
  if not book then Build() end
  if not book:IsShown() or closing then
    if not book:IsShown() then
      CloseZones()
      book.showDone, book.showAtlas = nil, nil
      if book.ribbonPaint then book.ribbonPaint(false) end
      if book.atlasPaint then book.atlasPaint(false) end
    end
    book:Show()
    book:Raise()
    StartOpen()
    FillList()
  end
end

---
-- Opens the book on a quest; the same quest again closes it
-- (onMap: on its map, shown over the page, when it has one)
function Core.ShowQuestText(questID, onMap)
  if not Core.BookOn() then return end
  if book and book:IsShown() and not closing and selected == questID then
    if onMap then ShowMapView(true) else CloseBook() end
    return
  end
  local wasShown = book and book:IsShown()
  Open()
  wantMap = onMap and true or false
  if wasShown then Turn(questID) else Select(questID) end
end

---
-- Opens a quest in the book (from the map's other quests)
function Core.BookOpenQuest(questID)
  Open()
  -- (from the map: the map stays)
  wantMap = mapView:IsShown()
  -- (its zone opens in the list, if it was closed)
  if OpenZoneOf(questID) then FillList() end
  Turn(questID)
end

---
-- Opens the book with no quest chosen; again closes it
function Core.ShowQuestList()
  if not Core.BookOn() then return end
  if book and book:IsShown() and not closing then
    CloseBook()
    return
  end
  Open()
  wantMap = false
  -- (opened on its own: no quest chosen yet, the right page waiting; a
  -- quest opened from the tracker or the map goes through ShowQuestText)
  Select(nil)
end

----
-- The open quest abandoned (Animations on): its writing turns to dust, all
-- at once. Every text, icon and button fades away together while soft specks
-- in its ink rise out of it and drift up and to the right, thinning out.
-- Then the page empties. Nothing runs until then.

do
local DUST = {
  TIME = 1.1,       -- seconds for the writing to fade away
  DENSITY = 0.07,   -- specks for each square pixel of writing, all told
  MOST = 1600,      -- at most this many specks in all
  MAX = 900,        -- at most this many flying at once (made once)
}
local dustLayer, dustStart, dustDone, dustTotal, dustMade
local dustItems, liveSpecks, freeSpecks = {}, {}, {}

-- What shows on the page: each text, icon and button, where it is on the
-- book, and how much of the page it takes (bigger ones give more specks)
local function Gather()
  _G.wipe(dustItems)
  local bookLeft, bookTop = book:GetLeft(), book:GetTop()
  local top, bottom = textScroll:GetTop(), textScroll:GetBottom()
  if not (bookLeft and top) then return 0 end
  local area = 0
  local function Add(region, always)
    -- (not what can't be seen)
    if not (region and region:IsVisible()) or region:GetAlpha() <= 0.01 then return end
    local left, regionTop = region:GetLeft(), region:GetTop()
    local width, height = region:GetWidth(), region:GetHeight()
    if not (left and regionTop) or width < 1 or height < 1 then return end
    local isText = region:GetObjectType() == "FontString"
    if isText and (region:GetText() or "") == "" then return end
    -- (scrolled out of sight: not there)
    if not always and (regionTop < bottom or regionTop - height > top) then return end
    local r, g, b = INK[1], INK[2], INK[3]
    if isText then
      r, g, b = region:GetTextColor()
      width = math.min(width, region:GetStringWidth() + 2)
    end
    area = area + width * height
    dustItems[#dustItems + 1] = { region = region, x = left - bookLeft, y = bookTop - regionTop,
      w = width, h = height, r = r, g = g, b = b, upTo = area }
  end
  for _, region in ipairs({ textContent:GetRegions() }) do Add(region) end
  for _, child in ipairs({ textContent:GetChildren() }) do
    for _, region in ipairs({ child:GetRegions() }) do Add(region) end
  end
  for _, button in ipairs(pageButtons) do Add(button.label, true) end
  -- (the "Completed" stamp too)
  for _, region in ipairs({ stamp:GetRegions() }) do Add(region, true) end
  return area
end

-- A speck out of a random place of the writing (the bigger a text, the
-- likelier)
local function Speck(area)
  if #liveSpecks >= DUST.MAX then return end
  local pick = math.random() * area
  local item = dustItems[#dustItems]
  for _, one in ipairs(dustItems) do
    if pick <= one.upTo then
      item = one
      break
    end
  end
  local texture = table.remove(freeSpecks)
  if not (texture and item) then return end
  local size = 2 + math.random() * 2.8
  -- (a little lighter or darker than the ink, like grains of sand)
  local shade = 0.7 + math.random() * 0.6
  texture:SetVertexColor(math.min(1, item.r * shade), math.min(1, item.g * shade), math.min(1, item.b * shade))
  texture:SetSize(size, size)
  texture:Show()
  liveSpecks[#liveSpecks + 1] = {
    texture = texture, size = size,
    x = item.x + math.random() * item.w, y = -(item.y + math.random() * item.h),
    vx = 14 + math.random() * 38, vy = 12 + math.random() * 30,
    sway = math.random() * 6.28, life = 0.9 + math.random() * 0.9, age = 0,
  }
end

-- Done (or the book shut meanwhile): everything back as it was
local function Finish()
  for _, item in ipairs(dustItems) do item.region:SetAlpha(1) end
  _G.wipe(dustItems)
  for _, speck in ipairs(liveSpecks) do
    speck.texture:Hide()
    freeSpecks[#freeSpecks + 1] = speck.texture
  end
  _G.wipe(liveSpecks)
  dustLayer:SetScript("OnUpdate", nil)
  local done = dustDone
  dustDone = nil
  if done then done() end
end

local function Update(_, elapsed)
  local p = math.min(1, (_G.GetTime() - dustStart) / DUST.TIME)
  -- the writing fades away, all of it together
  local eased = p * p * (3 - 2 * p)
  for _, item in ipairs(dustItems) do item.region:SetAlpha(1 - eased) end
  -- the specks come out as it goes: most in the middle of it
  if p < 1 then
    local due = dustTotal * (0.5 - 0.5 * math.cos(math.pi * p))
    local count = math.floor(due - dustMade)
    for _ = 1, count do Speck(dustItems.area) end
    dustMade = dustMade + count
  end
  for i = #liveSpecks, 1, -1 do
    local speck = liveSpecks[i]
    speck.age = speck.age + elapsed
    if speck.age >= speck.life then
      speck.texture:Hide()
      freeSpecks[#freeSpecks + 1] = speck.texture
      table.remove(liveSpecks, i)
    else
      -- up and to the right, swaying a little, rising faster as it goes
      speck.vy = speck.vy + 16 * elapsed
      speck.x = speck.x + (speck.vx + 8 * math.sin(speck.sway + speck.age * 5)) * elapsed
      speck.y = speck.y + speck.vy * elapsed
      speck.texture:SetPoint("CENTER", book, "TOPLEFT", speck.x, speck.y)
      local life = speck.age / speck.life
      speck.texture:SetAlpha(0.9 * (1 - life * life))
      local size = speck.size * (1 - 0.5 * life)
      speck.texture:SetSize(size, size)
    end
  end
  if p >= 1 and #liveSpecks == 0 then Finish() end
end

---
-- Turns the open quest's writing to dust, then calls `done`. False (and
-- nothing happens) with the animations off or nothing written.
function BookDust(done)
  if not (Animates() and selected) then return false end
  if not dustLayer then
    dustLayer = CreateFrame("Frame", nil, book)
    dustLayer:SetAllPoints()
    dustLayer:SetFrameLevel(book:GetFrameLevel() + 65)
    -- (the book shut while it runs: it ends at once)
    dustLayer:SetScript("OnHide", function () if dustDone then Finish() end end)
    -- (soft round specks, made once, so none is made while it runs)
    for _ = 1, DUST.MAX do
      local texture = Core.Smooth(dustLayer:CreateTexture(nil, "OVERLAY"))
      texture:SetTexture(Core.ASSETS.."circleSoft")
      texture:Hide()
      freeSpecks[#freeSpecks + 1] = texture
    end
  end
  if dustDone then Finish() end
  local area = Gather()
  if #dustItems == 0 or area <= 0 then return false end
  dustItems.area = area
  dustTotal = math.min(DUST.MOST, area * DUST.DENSITY)
  dustMade = 0
  dustDone = done
  dustStart = _G.GetTime()
  dustLayer:SetScript("OnUpdate", Update)
  return true
end
end

----
-- The quest log's key (L): opens the book instead, while the option is on
-- (Options: Quest book on the quest log key). A binding over the game's own,
-- not saved: off, the key opens the game's quest log again. Bindings can't
-- change in a fight, so a change then waits for its end.

do
local keyButton = CreateFrame("Button", "QuestmarkBookKey", _G.UIParent)
keyButton:SetScript("OnClick", function () Core.ShowQuestList() end)

local boundKeys -- the keys bound now (nil: none yet)

-- The quest log's button in the game's menu bar opens the book too: a button
-- of our own over it takes the clicks (the game's own is left untouched, so
-- it can't get it blocked in a fight), and lights it up under the mouse
local overButton
local function CoverMenuButton()
  local menuButton = _G.QuestLogMicroButton
  if not menuButton then return end
  if not overButton then
    overButton = CreateFrame("Button", "QuestmarkQuestLogButton", menuButton)
    overButton:SetAllPoints()
    overButton:SetFrameLevel(menuButton:GetFrameLevel() + 5)
    overButton:RegisterForClicks("LeftButtonUp")
    overButton:SetScript("OnClick", function () Core.ShowQuestList() end)
    overButton:SetScript("OnEnter", function (self)
      if menuButton.LockHighlight then menuButton:LockHighlight() end
      local tooltip = _G.GameTooltip
      tooltip:SetOwner(self, "ANCHOR_RIGHT")
      local key = _G.GetBindingKey("TOGGLEQUESTLOG")
      tooltip:SetText(key and ("Quest Book |cffffd100(%s)|r"):format(key) or "Quest Book")
      tooltip:Show()
    end)
    overButton:SetScript("OnLeave", function ()
      if menuButton.UnlockHighlight then menuButton:UnlockHighlight() end
      _G.GameTooltip:Hide()
    end)
  end
  overButton:SetShown(Core.BookOn() and Core.db.profile.bookKey and true or false)
end

local function BindKey()
  CoverMenuButton()
  if InCombatLockdown() then
    keyButton:RegisterEvent("PLAYER_REGEN_ENABLED")
    return
  end
  keyButton:UnregisterEvent("PLAYER_REGEN_ENABLED")
  local keys = Core.db.profile.bookKey and Core.BookOn() and { _G.GetBindingKey("TOGGLEQUESTLOG") } or {}
  -- (only when they change: changing them makes the game say the bindings
  -- changed, which comes back here)
  local wanted = table.concat(keys, " ")
  if wanted == boundKeys then return end
  boundKeys = wanted
  _G.ClearOverrideBindings(keyButton)
  for _, key in ipairs(keys) do
    _G.SetOverrideBindingClick(keyButton, false, key, keyButton:GetName())
  end
end

keyButton:SetScript("OnEvent", BindKey)
keyButton:RegisterEvent("PLAYER_LOGIN")
keyButton:RegisterEvent("UPDATE_BINDINGS")

Core:OnChange(function (key)
  if key == "bookKey" or key == "profile" or key == "useBook" then BindKey() end
  -- (the book turned off while open: it closes)
  if key == "useBook" and not Core.BookOn() and book and book:IsShown() then book:Hide() end
end)
end

----
-- The book's parts, for the controller (Tracker/BookPad.lua)

do
local pad
function Core.BookParts()
  if not book then return nil end
  if not pad then
    pad = {
      book = book, list = list, textScroll = textScroll, rows = rows, ribbons = book.ribbonButtons or {},
      buttons = pageButtons, mapView = mapView, ToggleTrack = ToggleTrack,
      Selected = function () return selected end,
      MapBack = function ()
        wantMap = false
        ShowMapView(false)
      end,
    }
  end
  return pad
end
end

----
-- The book's options (Options, Quest book), applied at once

do
-- Its fonts' sizes: the writing's, and the titles' (headings and zones go
-- with them)
local function UpdateFonts()
  local profile = Core.db.profile
  local text, title = profile.bookTextSize or 12, profile.bookTitleSize or 24
  local function Size(key, size)
    local file, _, flags = fonts[key]:GetFont()
    fonts[key]:SetFont(file, math.floor(size + 0.5), flags or "")
  end
  Size("Text", text)
  Size("Small", text - 1)
  Size("Reward", text - 1)
  Size("Badge", text - 2)
  Size("Title", title)
  Size("Heading", title * 0.71)
  Size("Zone", title * 0.62)
  Size("Stamp", title * 0.88)
  Size("Button", title * 0.54)
  -- The list: its own font and size (the zones a little bigger)
  local list = profile.bookListSize or text
  local chosen = profile.bookListFont ~= "" and profile.bookListFont
    and Core.LSM:Fetch(Core.LSM.MediaType.FONT, profile.bookListFont, true)
  local function ListFont(key, own, size, flags)
    size = math.floor(size + 0.5)
    fonts[key]:SetFont(chosen or own, size, flags or "")
    if not fonts[key]:GetFont() then fonts[key]:SetFont(own, size, flags or "") end
  end
  ListFont("List", Core.FONT_TEXT, list)
  ListFont("ListZone", Core.FONT_TITLE, list * 1.65)
  ListFont("ListPlain", Core.FONT_TEXT, list, "")
end

local function Refill()
  if not (book and book:IsShown()) then return end
  FillList()
  if selected then
    FillText(selected, true)
  elseif book.openDone then
    FillText(nil, true, book.openDone)
  end
end

Core:OnChange(function (key)
  if key == "init" or key == "profile" or key == "bookTextSize" or key == "bookTitleSize"
    or key == "bookListFont" or key == "bookListSize" or key == "questLevels"
    or key == "bookZoneColor" or key == "bookQuestColor" then
    UpdateFonts()
    Refill()
  end
  if not book then return end
  if key == "bookSize" or key == "profile" then
    book.Resize(bookBase * (Core.db.profile.bookSize or 100) / 100)
    UpdateFades()
  elseif key == "bookPaper" then
    local k = Paper()
    for _, texture in pairs({ pageLeft, pageRight, bookPicture, earLayers and earLayers[1], earLayers and earLayers[2] }) do
      texture:SetVertexColor(k, k, k)
    end
    UpdateFades()
  elseif key == "bookMapSize" then
    MAP_W, MAP_H = MapSize()
    mapHolder:SetSize(MAP_W, MAP_H)
    Core.QuestMapResize(MAP_W, MAP_H)
    if selected and book:IsShown() then Select(selected) end
  end
end)
end
