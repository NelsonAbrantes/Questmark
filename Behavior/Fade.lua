local _, ns = ...
local Core = ns.Core

-- luacheck: push ignore 113
local CreateFrame = CreateFrame
local GetMouseFocus = GetMouseFocus
local GetMouseFoci = GetMouseFoci
local GetTime = GetTime
local IsInInstance = IsInInstance
local UIParent = UIParent
local WorldFrame = WorldFrame
-- luacheck: pop

----
-- Fade
--
-- Fades the tracker out when you're not using it, and brings it back while
-- the mouse is over it, when an objective changes, and while Edit Mode is
-- open. The quest item buttons fade with it (only their transparency
-- changes, which the game allows in combat).

local frame = Core.frame
local items = Core.items

local state = {
  alpha = 1,          -- current visibility
  target = 1,         -- where it's going
  visibleUntil = 0,   -- shown until this time (GetTime), then it fades out
  mouseOver = false,
}

local function Profile() return Core.db.profile end

-- Keeps it shown for holdTime seconds from now
local function Reveal()
  state.visibleUntil = math.max(state.visibleUntil, GetTime() + Profile().holdTime)
end
Core.Reveal = Reveal

local function Apply(alpha)
  frame:SetAlpha(alpha)
  items:SetAlpha(alpha)
end

-- The slide that goes with the fade in (Animations: Glass): the tracker
-- comes in from a little to the right
local SLIDE_DISTANCE = 24
local SLIDE_TIME = 0.35

local slider = CreateFrame("Frame")
slider:Hide()
local slideStart
slider:SetScript("OnUpdate", function ()
  local k = math.min(1, (GetTime() - slideStart) / SLIDE_TIME)
  Core.SetContentOffset(SLIDE_DISTANCE * (1 - k) * (1 - k))
  if k >= 1 then slider:Hide() end
end)

local function SlideIn()
  if not Core:Animates() or Core.InEditMode() then return end
  slideStart = GetTime()
  Core.SetContentOffset(SLIDE_DISTANCE)
  slider:Show()
end

-- True while the tracker slides in (a new quest's own slide waits then)
function Core:TrackerSliding()
  return slider:IsShown()
end

-- Part of the tracker (its quests, buttons...) or an item button
local function IsTrackerPart(focus)
  for _ = 1, 20 do
    if not focus then return false end
    if focus == frame or focus == items then return true end
    focus = focus.GetParent and focus:GetParent()
  end
  return false
end

-- Another window (bags, character...) under the mouse, on top of the tracker
local function OtherWindowOnTop()
  local foci = GetMouseFoci and GetMouseFoci() or { GetMouseFocus and GetMouseFocus() }
  for _, focus in ipairs(foci) do
    if focus and focus ~= WorldFrame and not IsTrackerPart(focus) then return true end
  end
  return false
end

-- The mouse over what the tracker shows (or its item buttons), with nothing
-- else on top
local function MouseOverQuests()
  if Core.MouseOverItems() then return true end
  if not frame:IsVisible() or (Core.contentHeight or 0) <= 0 then return false end
  return frame:IsMouseOver(8, -8, -8, 8) and not OtherWindowOnTop()
end

-- Moves towards the target over the fade in / fade out duration
local function MoveAlpha(profile, elapsed)
  local duration = state.target > state.alpha and profile.fadeInDuration or profile.fadeOutDuration
  local step = duration > 0 and elapsed / duration or 1
  if state.target > state.alpha then
    state.alpha = math.min(state.target, state.alpha + step)
  else
    state.alpha = math.max(state.target, state.alpha - step)
  end
  Apply(state.alpha)
end

-- Where it should be (shown or faded) is worked out 20 times a second, which
-- feels instant; only the fade itself moves every frame, and only while it
-- moves
local CHECK_EVERY = 0.05
local sinceCheck = CHECK_EVERY

local ticker = CreateFrame("Frame", nil, UIParent)
ticker:Hide()
ticker:SetScript("OnUpdate", function (_, elapsed)
  local profile = Profile()
  sinceCheck = sinceCheck + elapsed
  if sinceCheck < CHECK_EVERY then
    if state.alpha ~= state.target then MoveAlpha(profile, elapsed) end
    return
  end
  sinceCheck = 0

  local mouseOver = MouseOverQuests()
  if mouseOver ~= state.mouseOver then
    state.mouseOver = mouseOver
    -- Leaving it starts the countdown again
    if not mouseOver then Reveal() end
  end

  -- In dungeons and raids (Options): hidden, or always shown
  local instanceMode = state.inInstance and profile.instanceMode or "normal"
  local editMode = Core.InEditMode()

  local shown = not profile.fade
    or instanceMode == "show"
    or (state.inInstance and profile.dungeonAlwaysShow and instanceMode ~= "hide")
    or editMode
    or (profile.showOnMouseOver and mouseOver)
    or GetTime() < state.visibleUntil
  if instanceMode == "hide" and not editMode then
    shown = false
  end
  local target = shown and 1 or (instanceMode == "hide" and 0 or profile.fadedAlpha)
  -- Coming back from (nearly) hidden: it also slides in a little
  if target == 1 and state.target ~= 1 and state.alpha < 0.3 then
    SlideIn()
  end
  state.target = target

  if state.alpha ~= state.target then MoveAlpha(profile, elapsed) end
end)

-- Objective changes that bring the tracker back
local PROGRESS_EVENTS = {
  "QUEST_WATCH_UPDATE",       -- an objective of a tracked quest moved
  "QUEST_ACCEPTED",
  "QUEST_WATCH_LIST_CHANGED", -- a quest tracked or untracked
  "QUEST_TURNED_IN",
  "QUEST_REMOVED",
  "QUEST_LOG_CRITERIA_UPDATE",
  "TRACKED_ACHIEVEMENT_UPDATE",
  "TRACKED_RECIPE_UPDATE",
}

local events = CreateFrame("Frame")
events:SetScript("OnEvent", function (_, event)
  if event == "PLAYER_ENTERING_WORLD" or event == "ZONE_CHANGED_NEW_AREA" then
    -- Dungeons and raids
    local inInstance, instanceType = IsInInstance()
    state.inInstance = inInstance and (instanceType == "party" or instanceType == "raid") or false
    if event == "PLAYER_ENTERING_WORLD" then Reveal() end
  elseif Profile().showOnProgress then
    Reveal()
  end
end)

Core:OnChange(function (key)
  if key == "enable" then
    if not Core.trackerOn then return end -- (the tracker turned off)
    Apply(state.alpha)
    events:RegisterEvent("PLAYER_ENTERING_WORLD")
    events:RegisterEvent("ZONE_CHANGED_NEW_AREA")
    for _, event in ipairs(PROGRESS_EVENTS) do
      pcall(events.RegisterEvent, events, event)
    end
    Reveal()
    ticker:Show()
  elseif key == "fade" or key == "profile" or key == "sectionAdded" or key == "questAdded" then
    Reveal()
  end
end)
