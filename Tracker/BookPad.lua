local _, ns = ...
local Core = ns.Core

-- luacheck: push ignore 113
local C_Timer = C_Timer
local CreateFrame = CreateFrame
local InCombatLockdown = InCombatLockdown
local wipe = wipe
-- luacheck: pop

----
-- The quest book with a controller
--
-- With ConsolePort: its cursor goes over the book like over the game's own
-- windows, and what it's on is scrolled into view.
-- With the game's own controller support, while the book is open
-- (Options: Controller in the book):
--   D-pad up/down     the quests and zones of the list
--   D-pad right/left  the buttons under the quest (Show map, Track...)
--   Cross (A)         opens the quest or zone, or clicks the button
--   Circle (B)        back from the map, or closes the book
--   Square (X)        tracks or untracks the quest
--   Triangle (Y)      follows the quest
--   L1 / R1           the quest before / after
--   L2 / R2           scrolls the quest's page
-- The buttons are the book's only while it's open, and not in a fight (the
-- game doesn't let them change in one).

local KEYS = {
  PADDUP = "Up", PADDDOWN = "Down", PADDLEFT = "Left", PADDRIGHT = "Right",
  PAD1 = "Ok", PAD2 = "Back", PAD3 = "Track", PAD4 = "Follow",
  PADLSHOULDER = "Prev", PADRSHOULDER = "Next",
  PADLTRIGGER = "PageUp", PADRTRIGGER = "PageDown",
}
local PAGE_STEP = 60 -- L2 / R2: how far the page scrolls
local MARGIN = 8 -- room kept around what's scrolled to

local owner = CreateFrame("Frame")
local actions = {} -- action -> what it does
local buttons = {} -- action -> its button (the bindings click them)
local bound = false
local focus -- the row or button the controller is on
local focusKey -- the row's quest or zone (found again when the list is filled)
local onButtons = false -- on the buttons under the quest

local function HasConsolePort() return _G.ConsolePort ~= nil end

-- The game's controller support is on (and the option)
local function PadOn()
  if not Core.db.profile.bookPad or HasConsolePort() then return false end
  local GamePad = _G.C_GamePad
  if GamePad and GamePad.IsEnabled then return GamePad.IsEnabled() and true or false end
  return true
end

---
-- Scrolls so the frame shows whole in the scroll frame
local function ScrollTo(scroll, frame)
  local child = scroll and scroll:GetScrollChild()
  local childTop, top = child and child:GetTop(), frame:GetTop()
  if not (childTop and top) then return end
  local from = childTop - top
  local to = from + frame:GetHeight()
  local at, height = scroll:GetVerticalScroll(), scroll:GetHeight()
  local most = scroll:GetVerticalScrollRange() or 0
  if from - MARGIN < at then
    scroll:SetVerticalScroll(math.max(0, from - MARGIN))
  elseif to + MARGIN > at + height then
    scroll:SetVerticalScroll(math.min(most, to + MARGIN - height))
  end
end

-- ConsolePort's cursor on a row or a reward: scrolled into view (the mouse
-- doesn't scroll: only with ConsolePort)
function Core.BookPadEnter(frame, scroll)
  if HasConsolePort() and frame:IsVisible() then ScrollTo(scroll, frame) end
end

----
-- Where the controller is

-- The list's rows that can be chosen, in order (reused)
local chosen = {}
local function Rows()
  wipe(chosen)
  local parts = Core.BookParts()
  for _, row in ipairs(parts.rows) do
    if row:IsShown() and (row.questID or row.zone or row.history) then chosen[#chosen + 1] = row end
  end
  return chosen
end

local function Key(row) return row.questID or row.zone or row.history end

local function Leave()
  local was = focus
  focus = nil
  if not was then return end
  if was.Paint then
    was.padFocus = nil
    was:Paint()
  elseif not was:IsMouseOver() then
    local OnLeave = was:GetScript("OnLeave")
    if OnLeave then OnLeave(was) end
  end
end

local function Enter(frame)
  Leave()
  focus = frame
  if not frame then return end
  if frame.Paint then
    frame.padFocus = true
    frame:Paint()
  else
    local OnEnter = frame:GetScript("OnEnter")
    if OnEnter then OnEnter(frame) end
  end
end

local function EnterRow(row)
  onButtons = false
  Enter(row)
  focusKey = row and Key(row)
  if row then ScrollTo(Core.BookParts().list, row) end
end

-- The row the controller is on (or the quest open's, or the first)
local function Here(rows)
  for i, row in ipairs(rows) do
    if row == focus then return i end
  end
  for i, row in ipairs(rows) do
    if row.open then return i end
  end
  return nil
end

-- The buttons under the quest that can be clicked
local function PageButtons()
  local parts = Core.BookParts()
  local list = {}
  if not (parts.buttons.bar and parts.buttons.bar:IsShown()) then return list end
  for _, button in ipairs(parts.buttons) do
    if button:IsEnabled() then list[#list + 1] = button end
  end
  return list
end

-- The list filled again: the same row (it's a new one, or moved)
function Core.BookListFilled()
  if onButtons or not focusKey then return end
  for _, row in ipairs(Rows()) do
    if Key(row) == focusKey then
      if focus ~= row then
        focus = nil
        Enter(row)
      end
      return
    end
  end
  focus, focusKey = nil, nil
end

----
-- What the buttons do

function actions.Up()
  local rows = Rows()
  if #rows == 0 then return end
  local at = Here(rows)
  if onButtons or not focus then
    EnterRow(rows[at or 1])
  else
    EnterRow(rows[math.max(1, (at or 1) - 1)])
  end
end

function actions.Down()
  local rows = Rows()
  if #rows == 0 then return end
  local at = Here(rows)
  if onButtons or not focus then
    EnterRow(rows[at or 1])
  else
    EnterRow(rows[math.min(#rows, (at or 0) + 1)])
  end
end

local function Sideways(step)
  local list = PageButtons()
  if #list == 0 then return end
  local at
  for i, button in ipairs(list) do
    if button == focus then at = i end
  end
  if not (onButtons and at) then
    if step < 0 then return end
    at = 0
  end
  at = at + step
  if at < 1 then
    -- (left of the first: back to the list)
    onButtons = false
    Leave()
    actions.Down()
    return
  end
  onButtons = true
  Enter(list[math.min(#list, at)])
end

function actions.Right() Sideways(1) end
function actions.Left() Sideways(-1) end

-- After a click: the game asking "Abandon?" takes the buttons back until
-- it's answered
local function AfterClick()
  local Visible = _G.StaticPopup_Visible
  local popup = Visible and Visible("ABANDON_QUEST")
  -- (its name, or itself)
  if type(popup) == "string" then popup = _G[popup] end
  if not popup then return end
  owner:Unbind()
  if not popup.questmarkPad then
    popup.questmarkPad = true
    popup:HookScript("OnHide", function () C_Timer.After(0, function () owner:Bind() end) end)
  end
end

function actions.Ok()
  if not focus then
    actions.Down()
    return
  end
  if focus:IsEnabled() then
    focus:Click("LeftButton")
    C_Timer.After(0, AfterClick)
  end
end

function actions.Back()
  local parts = Core.BookParts()
  if parts.mapView:IsShown() then
    parts.MapBack()
  else
    Core.ShowQuestList()
  end
end

-- The quest the controller is on, or the one open
local function Quest()
  if focus and not onButtons and focus.questID then return focus.questID end
  return Core.BookParts().Selected()
end

function actions.Track()
  local parts = Core.BookParts()
  local questID = Quest()
  if not questID then return end
  if questID == parts.Selected() and parts.buttons[2] then
    -- (the button's word follows)
    parts.buttons[2]:Click("LeftButton")
  else
    parts.ToggleTrack(questID)
  end
end

function actions.Follow()
  local questID = Quest()
  if questID and Core.FollowQuest then Core.FollowQuest(questID) end
end

-- The quest before or after the one open, opened
local function NextQuest(step)
  local rows = Rows()
  local selected = Core.BookParts().Selected()
  local at = 0
  for i, row in ipairs(rows) do
    if selected and row.questID == selected then at = i end
  end
  if at == 0 and step < 0 then at = #rows + 1 end
  local i = at + step
  while rows[i] and not rows[i].questID do i = i + step end
  local row = rows[i]
  if not row then return end
  EnterRow(row)
  row:Click("LeftButton")
end

function actions.Prev() NextQuest(-1) end
function actions.Next() NextQuest(1) end

local function Page(step)
  local scroll = Core.BookParts().textScroll
  if not scroll:IsShown() then return end
  local most = scroll:GetVerticalScrollRange() or 0
  scroll:SetVerticalScroll(math.min(most, math.max(0, scroll:GetVerticalScroll() + step * PAGE_STEP)))
end

function actions.PageUp() Page(-1) end
function actions.PageDown() Page(1) end

----
-- The bindings: only while the book is open

for key, action in pairs(KEYS) do
  local button = CreateFrame("Button", "QuestmarkPad"..action, _G.UIParent)
  button:SetScript("OnClick", function () if Core.BookParts() then actions[action]() end end)
  buttons[key] = button
end

function owner:Bind()
  local parts = Core.BookParts()
  if bound or not (parts and parts.book:IsShown()) or not PadOn() or InCombatLockdown() then return end
  bound = true
  for key, button in pairs(buttons) do
    _G.SetOverrideBindingClick(owner, true, key, button:GetName())
  end
end

function owner:Unbind()
  Leave()
  focusKey, onButtons = nil, false
  if not bound or InCombatLockdown() then return end
  bound = false
  _G.ClearOverrideBindings(owner)
end

owner:SetScript("OnEvent", function (self, event)
  -- (a fight coming: let go while it still can; after it, back)
  if event == "PLAYER_REGEN_DISABLED" then self:Unbind() else self:Bind() end
end)
owner:RegisterEvent("PLAYER_REGEN_DISABLED")
owner:RegisterEvent("PLAYER_REGEN_ENABLED")

-- The book built: its bindings come and go with it; ConsolePort's cursor
-- gets to know it
function Core.BookBuilt()
  local book = Core.BookParts().book
  book:HookScript("OnShow", function () owner:Bind() end)
  book:HookScript("OnHide", function () owner:Unbind() end)
  local ConsolePort = _G.ConsolePort
  if ConsolePort and ConsolePort.AddInterfaceCursorFrame then
    if not pcall(ConsolePort.AddInterfaceCursorFrame, ConsolePort, book) then
      pcall(ConsolePort.AddInterfaceCursorFrame, ConsolePort, book:GetName())
    end
  end
end

-- The controller opens the game's quest log its own way (not through the
-- quest log's key): the quest log gives way to the book. (L opens the book
-- without coming here.)
if _G.ToggleQuestLog then
  hooksecurefunc("ToggleQuestLog", function ()
    if not (Core.db.profile.bookKey and Core.BookOn()) then return end
    local map = _G.WorldMapFrame
    -- (closed by it: nothing to do)
    if not (map and map:IsShown()) then return end
    if _G.HideUIPanel then _G.HideUIPanel(map) else map:Hide() end
    Core.ShowQuestList()
  end)
end

Core:OnChange(function (key)
  if key == "bookPad" or key == "profile" then
    if PadOn() then owner:Bind() else owner:Unbind() end
  end
end)
