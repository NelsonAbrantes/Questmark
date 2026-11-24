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
--   D-pad up/down     the quests and zones of the list (up from the first:
--                     the ribbons over the page, the quests turned in and
--                     the atlas; right/left between them)
--   D-pad right/left  from the list to the quest's page (its buttons: Show
--                     map, Track...) and back
--   Cross (A)         opens the quest or zone, or clicks the button
--   Circle (B)        back from the map, or closes the book
--   Square (X)        tracks or untracks the quest
--   Triangle (Y)      follows the quest
--   L1 / R1           the quest before / after
--   L2 / R2           scrolls the quest's page
--   Right stick       scrolls the page you're on: the list, or the quest's
--                     page (the shoulders and triggers can be the
--                     controller's Shift, Ctrl or Alt in the game's options:
--                     those don't reach the book)
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
local onRibbons = false -- on the ribbons over the left page

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

---
-- Where you are, with the controller only (the mouse sees nothing of it):
-- the page you're on framed at its four corners by strokes of the book's red
-- ink, thin and fading out from the corner like a pen's, with a drop of ink
-- where they meet; and a small arrow by the list's row
local ARROW = "Interface\\ChatFrame\\ChatFrameExpandArrow"
local LINE = Core.ASSETS.."line" -- (a line fading out at both ends: half of it, from its middle)
local DOT = Core.ASSETS.."circleSoft"
local INK = { 0.55, 0.12, 0.08 } -- the titles' red
local ARM, THICK, DROP = 38, 2, 6 -- each stroke's length, its width, the drop of ink
local corners, arrow

local function UsingPad()
  local Using = _G.IsUsingGamepad
  return not Using or Using()
end

-- One stroke from a corner (at), along the top/bottom or the side
-- (drawn on the book itself, over its pages but under its ribbons: one
-- corner would cross the red and green ones)
local inks = {}
local function Stroke(holder, at, along)
  local line = holder:GetParent():CreateTexture(nil, "BACKGROUND", nil, 1)
  inks[#inks + 1] = line
  line:SetTexture(LINE)
  line:SetVertexColor(INK[1], INK[2], INK[3], 0.7)
  local left, top = at:find("LEFT") ~= nil, at:find("TOP") ~= nil
  if along then
    line:SetSize(ARM, THICK)
    -- (solid at the corner, fading away from it)
    if left then line:SetTexCoord(0.5, 1, 0, 1) else line:SetTexCoord(1, 0.5, 0, 1) end
  else
    line:SetSize(THICK, ARM)
    if top then
      line:SetTexCoord(0.5, 0, 1, 0, 0.5, 1, 1, 1)
    else
      line:SetTexCoord(1, 0, 0.5, 0, 1, 1, 0.5, 1)
    end
  end
  line:SetPoint(at, holder, at)
end

local function Marks()
  local parts = Core.BookParts()
  if not parts then return end
  if not corners then
    corners = CreateFrame("Frame", nil, parts.book)
    corners:SetFrameLevel(parts.book:GetFrameLevel() + 20)
    for _, at in ipairs({ "TOPLEFT", "TOPRIGHT", "BOTTOMLEFT", "BOTTOMRIGHT" }) do
      Stroke(corners, at, true)
      Stroke(corners, at, false)
      local drop = parts.book:CreateTexture(nil, "BACKGROUND", nil, 1)
      inks[#inks + 1] = drop
      drop:SetTexture(DOT)
      drop:SetVertexColor(INK[1], INK[2], INK[3], 0.8)
      drop:SetSize(DROP, DROP)
      drop:SetPoint("CENTER", corners, at, at:find("LEFT") and 1 or -1, at:find("TOP") and -1 or 1)
    end
    arrow = parts.book:CreateTexture(nil, "OVERLAY", nil, 7)
    arrow:SetTexture(ARROW)
    arrow:SetSize(14, 14)
    arrow:SetVertexColor(INK[1], INK[2], INK[3])
  end
  local on = bound and UsingPad() and parts.book:IsShown()
  if not on then
    corners:Hide()
    for _, ink in ipairs(inks) do ink:Hide() end
    arrow:Hide()
    return
  end
  -- (the page: the quest's once on its buttons, else the list's)
  local page = onButtons and parts.textScroll:GetParent() or parts.list:GetParent()
  corners:ClearAllPoints()
  corners:SetPoint("TOPLEFT", page, "TOPLEFT", -8, 6)
  corners:SetPoint("BOTTOMRIGHT", page, "BOTTOMRIGHT", 8, -6)
  corners:Show()
  for _, ink in ipairs(inks) do ink:Show() end
  if focus and not onButtons and Key(focus) and focus:IsVisible() then
    arrow:ClearAllPoints()
    arrow:SetPoint("RIGHT", focus, "LEFT", 2, 0)
    arrow:Show()
  else
    arrow:Hide()
  end
end

local function Leave()
  local was = focus
  focus = nil
  if not was then return end
  Marks()
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
  Marks()
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
  onButtons, onRibbons = false, false
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

-- The buttons under the quest that can be clicked (the atlas open: its
-- continents' tabs)
local function PageButtons()
  local parts = Core.BookParts()
  local atlas = Core.AtlasTabs and Core.AtlasTabs() or {}
  if #atlas > 0 then return atlas end
  local list = {}
  if not (parts.buttons.bar and parts.buttons.bar:IsShown()) then return list end
  for _, button in ipairs(parts.buttons) do
    if button:IsShown() and button:IsEnabled() then list[#list + 1] = button end
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

-- The ribbons that can be clicked (left to right)
local function Ribbons()
  local list = {}
  for _, button in ipairs(Core.BookParts().ribbons or {}) do
    if button:IsShown() then list[#list + 1] = button end
  end
  return list
end

local function EnterRibbon(button)
  onButtons, onRibbons = false, true
  focusKey = nil
  Enter(button)
end

function actions.Up()
  if onRibbons then return end
  local rows = Rows()
  local at = Here(rows)
  -- (up from the first row, or no list: the ribbons)
  if #rows == 0 or (focus and not onButtons and at == 1) then
    local ribbons = Ribbons()
    if ribbons[1] then EnterRibbon(ribbons[1]) end
    return
  end
  if onButtons or not focus then
    EnterRow(rows[at or 1])
  else
    EnterRow(rows[math.max(1, (at or 1) - 1)])
  end
end

function actions.Down()
  local rows = Rows()
  if onRibbons then
    if rows[1] then EnterRow(rows[1]) end
    return
  end
  if #rows == 0 then return end
  local at = Here(rows)
  if onButtons or not focus then
    EnterRow(rows[at or 1])
  else
    EnterRow(rows[math.min(#rows, (at or 0) + 1)])
  end
end

local function Sideways(step)
  -- (along the ribbons; right of the last, over to the right page)
  if onRibbons then
    local ribbons = Ribbons()
    for i, button in ipairs(ribbons) do
      if button == focus then
        if ribbons[i + step] then
          EnterRibbon(ribbons[i + step])
          return
        end
        if step > 0 and #PageButtons() > 0 then
          onRibbons = false
          break
        end
        return
      end
    end
    if onRibbons then return end
  end
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
  onButtons, onRibbons = true, false
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
    local clicked = focus
    focus:Click("LeftButton")
    C_Timer.After(0, AfterClick)
    -- (a ribbon: still lit, with its new words)
    if onRibbons and focus == clicked then
      local OnEnter = clicked:GetScript("OnEnter")
      if OnEnter then OnEnter(clicked) end
    end
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

-- The quest before or after the one open, opened (a quest turned in too)
local function NextQuest(step)
  local rows = Rows()
  local at = 0
  for i, row in ipairs(rows) do
    if row.open then at = i end
  end
  if at == 0 and step < 0 then at = #rows + 1 end
  local i = at + step
  while rows[i] and not (rows[i].questID or rows[i].history) do i = i + step end
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
  -- (only on the book open: a binding left over does nothing)
  button:SetScript("OnClick", function ()
    local parts = Core.BookParts()
    if parts and parts.book:IsShown() then actions[action]() end
  end)
  buttons[key] = button
end

-- The buttons the game uses as Shift, Ctrl or Alt (Options: Gamepad): left
-- to it
local function Modifier(key)
  local GetCVar = _G.C_CVar and _G.C_CVar.GetCVar or _G.GetCVar
  for _, cvar in ipairs({ "GamePadEmulateShift", "GamePadEmulateCtrl", "GamePadEmulateAlt" }) do
    if GetCVar(cvar) == key then return true end
  end
  return false
end

---
-- The right stick, looked at while the book is open (no binding: the game
-- turns the camera with it): it only scrolls, the page you're on (the list,
-- or the quest's page once on its buttons)
local STICK_SPEED = 700 -- pixels a second, the stick all the way
local STICK_DEAD = 0.25
local stick = CreateFrame("Frame")
stick:Hide()
-- The sticks taken by the book while it's open, as the game's own windows
-- do (a vendor's): then they don't turn the camera. Their positions come
-- here; the right one scrolls.
local heard = {} -- stick name -> its y
if stick.EnableGamePadStick then
  stick:EnableGamePadStick(true)
  stick:SetScript("OnGamePadStick", function (_, name, _, y)
    heard[name] = y
  end)
end

stick:SetScript("OnUpdate", function (_, elapsed)
  local y = heard.Right or heard.Camera or heard.RStick
  if y == nil then
    -- (no stick heard: read from the controller itself)
    local GamePad = _G.C_GamePad
    local device = GamePad and GamePad.GetActiveDeviceID and GamePad.GetActiveDeviceID()
    local state = device and GamePad.GetDeviceMappedState and GamePad.GetDeviceMappedState(device)
    local right = state and state.sticks and state.sticks[2]
    if not right then return end
    y = right.y
  end
  y = y or 0
  if math.abs(y) <= STICK_DEAD then return end
  local parts = Core.BookParts()
  local scroll = onButtons and parts.textScroll or parts.list
  if not (scroll and scroll:IsShown()) then scroll = parts.textScroll end
  if not scroll:IsShown() then return end
  local most = scroll:GetVerticalScrollRange() or 0
  local step = -y * STICK_SPEED * elapsed
  scroll:SetVerticalScroll(math.min(most, math.max(0, scroll:GetVerticalScroll() + step)))
end)

---
-- The camera held still while the book is open (the right stick scrolls the
-- page): its turning speeds set to 0, and given back when it closes. Kept in
-- the saved settings too, so a /reload or a crash with the book open gives
-- them back on the next login.
local CAMERA = { "GamePadCameraYawSpeed", "GamePadCameraPitchSpeed" }

local function GetC(name) return (_G.C_CVar and _G.C_CVar.GetCVar or _G.GetCVar)(name) end
local function SetC(name, value) pcall(_G.C_CVar and _G.C_CVar.SetCVar or _G.SetCVar, name, value) end

local function HoldCamera()
  -- (the sticks taken by the book: nothing to change)
  if stick.EnableGamePadStick then return end
  local global = Core.db.global
  if global.padCamera then return end
  local saved = {}
  for _, name in ipairs(CAMERA) do
    local value = GetC(name)
    if value then saved[name] = value end
  end
  global.padCamera = saved
  -- (0.1: the least the game takes; 0 is refused and left as it was)
  for name in pairs(saved) do SetC(name, "0.1") end
end

local function FreeCamera()
  wipe(heard)
  local saved = Core.db and Core.db.global.padCamera
  if not saved then return end
  for name, value in pairs(saved) do SetC(name, value) end
  Core.db.global.padCamera = nil
end

-- (held when the game closed with the book open: given back)
C_Timer.After(1, function () if not (Core.BookParts and Core.BookParts() and Core.BookParts().book:IsShown()) then FreeCamera() end end)

function owner:Bind()
  local parts = Core.BookParts()
  if bound or not (parts and parts.book:IsShown()) or not PadOn() or InCombatLockdown() then return end
  bound = true
  for key, button in pairs(buttons) do
    if not Modifier(key) then _G.SetOverrideBindingClick(owner, true, key, button:GetName()) end
  end
  stick:Show()
  HoldCamera()
  Marks()
end

function owner:Unbind()
  Leave()
  focusKey, onButtons, onRibbons = nil, false, false
  stick:Hide()
  FreeCamera()
  if corners then
    corners:Hide()
    for _, ink in ipairs(inks) do ink:Hide() end
    arrow:Hide()
  end
  if not bound or InCombatLockdown() then return end
  bound = false
  _G.ClearOverrideBindings(owner)
end

owner:SetScript("OnEvent", function (self, event)
  -- (the mouse or the controller taken up: the marks follow)
  if event == "GAME_PAD_ACTIVE_CHANGED" then Marks() return end
  -- (a fight coming: let go while it still can; after it, back)
  if event == "PLAYER_REGEN_DISABLED" then self:Unbind() else self:Bind() end
end)
owner:RegisterEvent("PLAYER_REGEN_DISABLED")
owner:RegisterEvent("PLAYER_REGEN_ENABLED")
pcall(owner.RegisterEvent, owner, "GAME_PAD_ACTIVE_CHANGED")

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
