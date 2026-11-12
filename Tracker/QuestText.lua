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
local MAP_W, MAP_H = 264, 176 -- the map on the right page
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
local FADED = { 0.42, 0.32, 0.20 }
local FADED_HEX = "|cff6b5233"
local COUNT = { 0.36, 0.20, 0.08 } -- a zone's count of quests: a warm dark ink
local ZONE = { 1.0, 0.82, 0.0 } -- the zones in the list: the quests' own yellow (with a dark shadow)

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
local STAMP_W = 100 -- "Completed" by a quest's title
local rows, rewardButtons = {}, {} -- made as needed and kept
local selected -- the quest on the right page
local pending -- a refresh waiting
local turning -- a page turn going (the tracker's own book): { t, questID, filled }
local CloseBook, StartOpen, StartFlip, Flash, ResetAnimations -- (Animations, below)
local pageLeft, pageRight -- the spellbook's pages (nil with the tracker's own book)
local ribbonMark -- the spellbook's ribbon, in the middle
local bookShadow -- the soft shadow under the spellbook's pages
local bookBase = 1 -- the book's own size (the chosen % is of it)
local UpdateMarker -- (the mark of the quest open, below)
local writingAlpha = 1 -- the writing's alpha (it fades as the book opens and shuts)
local shown = {} -- the book's writing and buttons, faded in as it opens
local wasDone = {} -- each quest: done the last time the list was filled

local fonts = {}
local function Font(key, file, size, spacing, flags)
  local font = CreateFont("QuestmarkBook"..key)
  font:SetFont(file, size, flags or "")
  if not font:GetFont() then font:SetFont("Fonts\\FRIZQT__.TTF", size, flags or "") end
  font:SetShadowOffset(0, 0)
  font:SetJustifyH("LEFT")
  font:SetSpacing(spacing or 0)
  fonts[key] = font
end
Font("Title", "Fonts\\MORPHEUS.TTF", 24)
Font("Heading", "Fonts\\MORPHEUS.TTF", 17)
Font("Zone", "Fonts\\MORPHEUS.TTF", 15)
Font("Text", "Fonts\\FRIZQT__.TTF", 12, 2)
Font("Small", "Fonts\\FRIZQT__.TTF", 11)
Font("Badge", "Fonts\\FRIZQT__.TTF", 10)
Font("Stamp", "Fonts\\MORPHEUS.TTF", 17)
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

----
-- Tags: what kind of quest it is (daily, group, campaign...)

-- The game's icons for the quest kinds, by the name the game gives them
local TAG_ICON = 16
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

local function Tags(questID, frequency)
  local found, seen = {}, {}
  local function Add(text)
    if text and text ~= "" and not seen[text] then
      seen[text] = true
      found[#found + 1] = text
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
      Add("|A:"..atlas..":"..TAG_ICON..":"..TAG_ICON.."|a")
    else
      local Icon = _G.QuestUtils_GetQuestTypeIconMarkupString
      local ok, icon = false, nil
      if Icon then ok, icon = pcall(Icon, questID, TAG_ICON, TAG_ICON) end
      if ok and type(icon) == "string" and icon ~= "" then
        Add(icon)
      else
        Add(name)
      end
    end
  end
  return table.concat(found, " · ")
end

---
-- Every quest taken, under its zone: { header, title, quests } or { questID, title, done, tags }
local function QuestList()
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
      local name, texture, amount, quality = _G.GetQuestLogRewardInfo(i, questID)
      found.items[#found.items + 1] = { kind = "reward", index = i, name = name, texture = texture, amount = amount, quality = quality }
    end
    for i = 1, _G.GetNumQuestLogChoices and _G.GetNumQuestLogChoices(questID, true) or 0 do
      local name, texture, amount, quality = _G.GetQuestLogChoiceInfo(i)
      found.choices[#found.choices + 1] = { kind = "choice", index = i, name = name, texture = texture, amount = amount, quality = quality }
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

-- An item's name color, dark enough for the paper (plain items in ink)
local function QualityColor(quality)
  if not quality or quality <= 1 then return INK[1], INK[2], INK[3] end
  local Item = _G.C_Item
  if not (Item and Item.GetItemQualityColor) then return INK[1], INK[2], INK[3] end
  local r, g, b = Item.GetItemQualityColor(quality)
  if not (r and g and b) then return INK[1], INK[2], INK[3] end
  return r * 0.55, g * 0.55, b * 0.55
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
  button.name:SetFontObject(fonts.Small)
  button.name:SetPoint("LEFT", button.icon, "RIGHT", 6, 0)
  button.name:SetPoint("RIGHT")
  button.name:SetMaxLines(2)
  button:SetScript("OnEnter", function (self)
    local tooltip = _G.GameTooltip
    tooltip:SetOwner(self, "ANCHOR_RIGHT")
    if self.kind == "currency" then
      pcall(tooltip.SetQuestLogCurrency, tooltip, "reward", self.index, selected)
    else
      pcall(tooltip.SetQuestLogItem, tooltip, self.kind, self.index, selected)
    end
    tooltip:Show()
  end)
  button:SetScript("OnLeave", function () _G.GameTooltip:Hide() end)
  rewardButtons[i] = button
  return button
end

local function ShowReward(i, item, y, column)
  local button = RewardButton(i)
  button.kind, button.index = item.kind, item.index
  button.icon:SetTexture(item.texture or 134400) -- (a question mark until known)
  button.amount:SetText(item.amount and item.amount > 1 and item.amount or "")
  button.name:SetText(item.name or "")
  button.name:SetTextColor(QualityColor(item.quality))
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

local function QuestMenu(owner, questID)
  local MenuUtil = _G.MenuUtil
  if not (MenuUtil and MenuUtil.CreateContextMenu) then return end
  MenuUtil.CreateContextMenu(owner, function (_, root)
    root:CreateTitle(C_QuestLog.GetTitleForQuestID(questID) or "")
    root:CreateButton("Read quest", function () Turn(questID) end)
    if InTracker(questID) then
      root:CreateButton("Stop tracking", function ()
        -- (with every quest showing, it's hidden from the tracker too)
        if Core.db.profile.allQuests then Core.HideQuest(questID) end
        C_QuestLog.RemoveQuestWatch(questID)
      end)
    else
      root:CreateButton("Track", function ()
        Core.UnhideQuest(questID)
        C_QuestLog.AddQuestWatch(questID)
      end)
    end
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
      local solid, clear = _G.CreateColor(1, 1, 1, 1), _G.CreateColor(1, 1, 1, 0)
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
    if scroll:IsShown() and scroll:GetTop() and left then
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
  local done = C_QuestLog.IsComplete(selected)
  local mark = done and MARK_DONE or MARK_GOING
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
  local width = math.floor(TEXT_W * (Core.db.profile.bookMapSize or 78) / 100)
  return width, math.floor(width * 2 / 3)
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
  row.toggle:SetVertexColor(ZONE[1], ZONE[2], ZONE[3])
  -- A zone's count of quests, between brackets after its name, in dark ink
  row.count = row:CreateFontString(nil, "OVERLAY")
  row.count:SetFontObject(fonts.Text)
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
  end)
  row:SetScript("OnLeave", function (self)
    self.underline:Hide()
    -- (the quest open stays red)
    self.text:SetTextColor(unpack(self.open and RED or self.color))
    self.toggle:SetVertexColor(ZONE[1], ZONE[2], ZONE[3])
  end)
  row:SetScript("OnClick", function (self, button)
    if self.zone then
      -- A zone: opens or closes
      local collapsed = Collapsed()
      collapsed[self.zone] = not collapsed[self.zone] or nil
      FillList()
    elseif self.questID then
      if button == "RightButton" then
        QuestMenu(self, self.questID)
      else
        Turn(self.questID)
      end
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
  book:SetFrameStrata("DIALOG")
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
    local closeButton = CreateFrame("Button", nil, book, "UIPanelCloseButton")
    closeButton:SetPoint("TOPRIGHT", 2, 2)
    closeButton:SetScript("OnClick", function () CloseBook() end)
    shown[#shown + 1] = closeButton
  else
    pages[1] = { x0 = 0, x1 = BOOK_W, file = Core.ASSETS.."book", l = 0, r = 1, t = 0, b = 1 }
    -- (the picture has its own shadow under the book)
    local picture = Core.Smooth(book:CreateTexture(nil, "BACKGROUND"))
    picture:SetTexture(Core.ASSETS.."book")
    picture:SetAllPoints()
  end

  local close = CreateFrame("Button", nil, book)
  close:SetShown(not gameBook)
  close:SetSize(14, 14)
  close:SetPoint("CENTER", book, "TOPLEFT", 780, -52)
  local x = close:CreateFontString(nil, "ARTWORK")
  x:SetFontObject(fonts.Heading)
  x:SetPoint("CENTER")
  x:SetText("x")
  x:SetTextColor(unpack(FADED))
  close:SetScript("OnEnter", function () x:SetTextColor(unpack(RED)) end)
  close:SetScript("OnLeave", function () x:SetTextColor(unpack(FADED)) end)
  close:SetScript("OnClick", function () CloseBook() end)
  shown[#shown + 1] = close

  -- The bottom right corner resizes it (the whole book, its shape kept);
  -- right click: its first size again. It's the spellbook's own dog-eared
  -- page corner, its tip lifting under the mouse (its frames, one after the
  -- other); the chat's size grabber without it.
  local grip = CreateFrame("Button", nil, book)
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
      layers[i] = layer
    end
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
  Ornament(left, heading, 180)
  count = left:CreateFontString(nil, "ARTWORK")
  count:SetFontObject(fonts.Small)
  count:SetPoint("TOP", heading, "BOTTOM", 0, -16)
  count:SetTextColor(unpack(FADED))

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
  mapHolder = CreateFrame("Frame", nil, rightContent)
  mapHolder:SetSize(MAP_W, MAP_H)
  mapHolder:SetPoint("TOP")

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
  -- "Completed" by the title of a quest done, in green ink
  -- (in the writing: it scrolls with the title)
  stamp = CreateFrame("Frame", nil, textContent)
  stamp:SetSize(STAMP_W, 24)
  stamp:SetPoint("TOPRIGHT", 0, -2)
  local word = stamp:CreateFontString(nil, "OVERLAY")
  word:SetFontObject(fonts.Stamp)
  word:SetText("Completed")
  word:SetTextColor(GREEN[1], GREEN[2], GREEN[3])
  word:SetPoint("RIGHT")
  local thump = stamp:CreateAnimationGroup()
  local grow = thump:CreateAnimation("Scale")
  grow:SetScaleFrom(1.8, 1.8)
  grow:SetScaleTo(1, 1)
  grow:SetDuration(0.22)
  grow:SetSmoothing("IN")
  local fade = thump:CreateAnimation("Alpha")
  fade:SetFromAlpha(0)
  fade:SetToAlpha(1)
  fade:SetDuration(0.16)
  stamp.thump = thump
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
    Sound("IG_QUEST_LOG_OPEN")
  end)
  book:SetScript("OnHide", function (self)
    self:UnregisterEvent("QUEST_LOG_UPDATE")
    self:UnregisterEvent("GET_ITEM_INFO_RECEIVED")
    Core.HideQuestMap()
    ResetAnimations()
    rightContent:SetAlpha(1)
    -- (the book shutting: its sound, when its closing didn't play it already)
    if not closeSounded then Sound(CLOSE_SOUND) end
    closeSounded = false
  end)
  book:SetScript("OnEvent", function ()
    if pending then return end
    pending = true
    _G.C_Timer.After(REFRESH_WAIT, function ()
      pending = false
      if not book:IsShown() then return end
      -- (a quest given or abandoned leaves the right page)
      if selected and not C_QuestLog.GetLogIndexForQuestID(selected) then
        Select(nil)
      elseif selected and not turning then
        FillText(selected, true)
      end
      FillList()
    end)
  end)
end

local function Build()
  BuildBook(GameBook())
  BuildLeft()
  BuildRight()
  BuildEvents()
end


----
-- Animations (only while the book is open, and only with the animations on
-- in the options):
-- - opening: the pages unfold from the spine, then the writing fades in;
--   closing: the pages fold back and the book fades out
-- - another quest: a page turns over the spine
-- - the list's quests come in one after the other as the book opens
-- - a quest just done glows gold in the list
-- - gold dust floats over the pages
-- One driver runs them all, and only while the book shows.

-- (in a scope of its own: the file has more locals than the game allows in
-- one; what the rest uses is declared outside it)
local closing, flip, Animates
local dust = {}
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
local DUST = 16
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
  local shade = 0.55 + 0.45 * p
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
    strip:SetVertexColor(shade, shade, shade, alpha)
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

-- The dust: small soft specks drifting up slowly over the pages, fading in
-- and out
local function Speck(speck, first)
  speck.x = 30 + math.random() * (BOOK_W - 60)
  speck.y = 40 + math.random() * (BOOK_H - 80)
  speck.vx, speck.vy = (math.random() - 0.5) * 6, 3 + math.random() * 6
  speck.life = 4 + math.random() * 5
  speck.t = first and math.random() * speck.life or 0
  local size = 2 + math.random() * 3.5
  speck.texture:SetSize(size, size)
end

local function BuildDust()
  local layer = CreateFrame("Frame", nil, book)
  layer:SetAllPoints()
  layer:SetFrameLevel(book:GetFrameLevel() + 40)
  for i = 1, DUST do
    local texture = Core.Smooth(layer:CreateTexture(nil, "OVERLAY"))
    texture:SetTexture(Core.ASSETS.."circleSoft")
    texture:SetBlendMode("ADD")
    texture:SetVertexColor(GOLD[1], GOLD[2], GOLD[3])
    dust[i] = { texture = texture }
    Speck(dust[i], true)
  end
  dust.layer = layer
  -- (it only shows with the book all open: it comes and goes with the writing)
  shown[#shown + 1] = layer
  layer:SetAlpha(writingAlpha)
end

local function UpdateDust(elapsed)
  for _, speck in ipairs(dust) do
    speck.t = speck.t + elapsed
    if speck.t >= speck.life then Speck(speck) end
    local x = speck.x + speck.vx * speck.t + 4 * math.sin(speck.t * 1.3 + speck.life)
    local y = speck.y - speck.vy * speck.t
    speck.texture:ClearAllPoints()
    speck.texture:SetPoint("CENTER", book, "TOPLEFT", x, -y)
    speck.texture:SetAlpha(0.45 * math.sin(math.pi * speck.t / speck.life))
  end
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
        UpdateFades()
      end
    end
  end
  if cascadeT then
    cascadeT = cascadeT + elapsed
    UpdateCascade()
  end
  if next(flashing) then UpdateFlashes(elapsed) end
  if dust[1] and dust.layer:IsShown() then UpdateDust(elapsed) end
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
    if dust.layer then dust.layer:Hide() end
    return
  end
  if not dust[1] then BuildDust() end
  dust.layer:SetShown(Core.db.profile.bookDust)
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
  return true
end

---
-- Everything back in place (the book hidden, Escape included)
function ResetAnimations()
  turning, opening, closing, flip, cascadeT, flipQuest = nil, nil, nil, nil, nil, nil
  if flipLayer then flipLayer:Hide() end
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

function FillList()
  local quests, n = QuestList()
  count:SetText(n == 1 and "1 quest" or n.." quests")
  local at = list:GetVerticalScroll()
  for _, row in ipairs(rows) do row:Hide() end
  local collapsed = Collapsed()

  local width = listContent:GetWidth()
  local y, i = 0, 0
  for _, item in ipairs(quests) do
    if item.header or not (item.zone and collapsed[item.zone.title]) then
      i = i + 1
      local row = Row(i)
      local indent = item.header and 0 or INDENT
      -- (a little more room above each zone, but the first)
      if item.header and i > 1 then y = y + GAP - ROW_GAP end
      row.questID = item.questID
      row.zone = item.header and item.title or nil
      row.text:SetFontObject(item.header and fonts.Zone or fonts.Text)
      -- (the zones' gold with a soft dark brown shadow, to stand out of the paper)
      if item.header then
        row.text:SetShadowColor(0.20, 0.09, 0.0, 0.95)
        row.text:SetShadowOffset(1, -1)
      else
        row.text:SetShadowOffset(0, 0)
      end
      row.text:ClearAllPoints()
      if item.header then
        local closed = collapsed[item.title]
        row.color = ZONE
        row.text:SetText(item.title)
        -- (and how many quests it has, between brackets after it)
        row.count:SetText("("..item.quests..")")
        row.count:ClearAllPoints()
        row.count:SetPoint("LEFT", row.text, "LEFT", math.min(row.text:GetStringWidth(), width - 16) + 5, -1)
        row.count:Show()
        row.toggle:SetTexture(Core.ASSETS..(closed and "expand" or "collapse"))
        row.toggle:Show()
        row.text:SetPoint("TOPLEFT", 16, 0)
        row.text:SetWidth(width - 16)
      else
        row.toggle:Hide()
        row.count:Hide()
        row.color = item.done and GREEN or INK
        local text = item.title
        if item.tags ~= "" then text = text.."  "..FADED_HEX..item.tags.."|r" end
        row.text:SetText(text)
        row.text:SetPoint("TOPLEFT")
        row.text:SetWidth(width - indent)
      end
      local open = item.questID and item.questID == selected
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
  if n == 0 then
    local row = Row(1)
    row.questID, row.zone = nil, nil
    row.color = FADED
    row.toggle:Hide()
    row.count:Hide()
    row.selected:Hide()
    row.text:SetFontObject(fonts.Text)
    row.text:SetShadowOffset(0, 0)
    row.text:SetText("No quests taken.")
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
end

---
-- The right page's writing (keep: where it was scrolled stays)
function FillText(questID, keep)
  -- A quest done: "Completed" by its title (with a little thump as the page shows)
  local done = C_QuestLog.IsComplete(questID) and true or false
  local wasShown = stamp:IsShown()
  stamp:SetShown(done)
  if done and (not keep or not wasShown) and Core:Animates() then stamp.thump:Play() end
  title:SetWidth(TEXT_W - (done and STAMP_W or 0))
  title:SetText(C_QuestLog.GetTitleForQuestID(questID) or "")
  local index = C_QuestLog.GetLogIndexForQuestID(questID)
  local info = index and C_QuestLog.GetInfo(index)
  local kinds = Tags(questID, info and info.frequency)
  tags:SetText(kinds)
  local y = title:GetStringHeight() + (kinds ~= "" and tags:GetStringHeight() + 3 or 0) + GAP

  local description, objectives = QuestText(questID)
  local texts = {
    { "Objectives", objectives },
    { "Description", description or "The game didn't give this quest's text." },
  }
  for i, part in ipairs(parts) do
    local name, text = texts[i][1], texts[i][2]
    if text and text ~= "" then
      part.heading:ClearAllPoints()
      part.heading:SetPoint("TOPLEFT", 0, -y)
      part.heading:SetText(name)
      part.text:SetText(text)
      part.heading:Show()
      part.text:Show()
      y = y + part.heading:GetStringHeight() + 4 + part.text:GetStringHeight() + GAP
    else
      part.heading:Hide()
      part.text:Hide()
    end
  end

  -- Rewards: experience and money in a line, then the items (and the ones
  -- to choose from)
  for _, button in ipairs(rewardButtons) do button:Hide() end
  local rewards = Rewards(questID)
  local line = {}
  -- (the experience with the tracker's own xp icon, in the experience bar's
  -- purple with a thin dark outline; the money with the game's coins: gold,
  -- silver and copper)
  local size = math.floor((Core.db.profile.bookTextSize or 12) * 1.3)
  if rewards.xp and rewards.xp > 0 then
    local number = _G.BreakUpLargeNumbers and _G.BreakUpLargeNumbers(rewards.xp) or rewards.xp
    -- (a little lower, so it sits on the numbers' line like the coins do)
    line[#line + 1] = ("|T%sxpBook:%d:%d:0:%d|t %s"):format(Core.ASSETS, size, size, -math.floor(size * 0.18 + 0.5), number)
  end
  if rewards.money and rewards.money > 0 then
    local gold = math.floor(rewards.money / 10000)
    local silver = math.floor(rewards.money / 100) % 100
    local copper = rewards.money % 100
    local coins = {}
    local function Coin(amount, icon)
      if amount > 0 then coins[#coins + 1] = ("%d|TInterface\\MoneyFrame\\UI-%sIcon:%d:%d:2:0|t"):format(amount, icon, size, size) end
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
end

---
-- Opens a quest on the right page at once (nil: none)
function Select(questID)
  selected = questID
  if not questID then
    Core.HideQuestMap()
    textScroll:Hide()
    hint:Show()
    if book:IsShown() then FillList() end
    return
  end
  hint:Hide()
  textScroll:Show()
  -- The map on top when the quest has one, the writing under it
  local hasMap = Core.ShowQuestMap(questID, mapHolder)
  textScroll:ClearAllPoints()
  textScroll:SetPoint("TOPLEFT", 0, -(hasMap and MAP_H + GAP or 0))
  textScroll:SetPoint("BOTTOMRIGHT")
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
    if not book:IsShown() then CloseZones() end
    book:Show()
    StartOpen()
    FillList()
  end
end

---
-- Opens the book on a quest; the same quest again closes it
function Core.ShowQuestText(questID)
  if book and book:IsShown() and not closing and selected == questID then
    CloseBook()
    return
  end
  local wasShown = book and book:IsShown()
  Open()
  if wasShown then Turn(questID) else Select(questID) end
end

---
-- Opens a quest in the book (from the map's other quests)
function Core.BookOpenQuest(questID)
  Open()
  Turn(questID)
end

---
-- Opens the book (on the quest you follow, if none is open); again closes it
function Core.ShowQuestList()
  if book and book:IsShown() and not closing then
    CloseBook()
    return
  end
  Open()
  if selected and C_QuestLog.GetLogIndexForQuestID(selected) then
    Select(selected) -- (its map again: it goes with the book)
  else
    local SuperTrack = _G.C_SuperTrack
    local followed = SuperTrack and SuperTrack.GetSuperTrackedQuestID and SuperTrack.GetSuperTrackedQuestID()
    if followed and followed > 0 and C_QuestLog.GetLogIndexForQuestID(followed) then
      Select(followed)
    else
      Select(nil)
    end
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

local function BindKey()
  if InCombatLockdown() then
    keyButton:RegisterEvent("PLAYER_REGEN_ENABLED")
    return
  end
  keyButton:UnregisterEvent("PLAYER_REGEN_ENABLED")
  local keys = Core.db.profile.bookKey and { _G.GetBindingKey("TOGGLEQUESTLOG") } or {}
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
  if key == "bookKey" or key == "profile" then BindKey() end
end)
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
  Size("Badge", text - 2)
  Size("Title", title)
  Size("Heading", title * 0.71)
  Size("Zone", title * 0.62)
  Size("Stamp", title * 0.71)
end

local function Refill()
  if not (book and book:IsShown()) then return end
  FillList()
  if selected then FillText(selected, true) end
end

Core:OnChange(function (key)
  if key == "init" or key == "profile" or key == "bookTextSize" or key == "bookTitleSize" then
    UpdateFonts()
    Refill()
  end
  if not book then return end
  if key == "bookSize" or key == "profile" then
    book.Resize(bookBase * (Core.db.profile.bookSize or 100) / 100)
    UpdateFades()
  elseif key == "bookMapSize" then
    MAP_W, MAP_H = MapSize()
    mapHolder:SetSize(MAP_W, MAP_H)
    Core.QuestMapResize(MAP_W, MAP_H)
    if selected and book:IsShown() then Select(selected) end
  elseif key == "bookDust" and dust.layer then
    dust.layer:SetShown(Core.db.profile.bookDust and book:IsShown())
  end
end)
end
