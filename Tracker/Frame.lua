local _, ns = ...
local Core = ns.Core

-- luacheck: push ignore 113
local CreateFrame = CreateFrame
local UIParent = UIParent
-- luacheck: pop

----
-- Frame
--
-- The tracker's own frames:
-- - Core.frame: the tracker. Everything in it is the addon's own (no game
--   frame and nothing protected), so it can be laid out, moved and animated
--   at any time, also in combat.
-- - Core.items: the quest item buttons. Using an item is something only the
--   game's protected buttons may do, and those can't be created, moved or
--   hidden in combat. They live in a frame of their own over the screen (not
--   in the tracker, which would then be locked in combat too) and are placed
--   beside their quests, again after a fight if something moved during it.

local frame = CreateFrame("Frame", "GlassForeverTrackerFrame", UIParent)
frame:SetSize(Core.defaults.profile.width, 1)
frame:SetFrameStrata("LOW")
frame:SetClampedToScreen(true)
frame.editModeName = "Glass Forever Tracker"
Core.frame = frame

-- What the tracker shows goes in Core.content, inside a scrolling frame:
-- past the highest height (Options: Max height) it scrolls with the mouse
-- wheel. The scrolling frame reaches a little past the tracker on every
-- side, so what goes over its edges (a quest sliding in, a shine) isn't cut.
local MARGIN_X, MARGIN_Y = 48, 12
local scroll = CreateFrame("ScrollFrame", nil, frame)
scroll:SetPoint("TOPLEFT", frame, "TOPLEFT", -MARGIN_X, MARGIN_Y)
scroll:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", MARGIN_X, -MARGIN_Y)
local holder = CreateFrame("Frame", nil, scroll)
holder:SetSize(Core.defaults.profile.width + MARGIN_X * 2, 1)
scroll:SetScrollChild(holder)
local content = CreateFrame("Frame", nil, holder)
content:SetPoint("TOPLEFT", holder, "TOPLEFT", MARGIN_X, -MARGIN_Y)
content:SetSize(Core.defaults.profile.width, 1)
Core.scroll, Core.content = scroll, content

---
-- What shows moved `x` to the right (the tracker sliding in, Fade.lua)
function Core.SetContentOffset(x)
  scroll:ClearAllPoints()
  scroll:SetPoint("TOPLEFT", frame, "TOPLEFT", -MARGIN_X + x, MARGIN_Y)
  scroll:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", MARGIN_X + x, -MARGIN_Y)
end

---
-- The content's size: `width` wide, `height` tall
function Core.SizeContent(width, height)
  content:SetSize(width, math.max(1, height))
  holder:SetSize(width + MARGIN_X * 2, math.max(1, height) + MARGIN_Y * 2)
end

local items = CreateFrame("Frame", "GlassForeverTrackerItems", UIParent)
items:SetAllPoints(UIParent)
items:SetFrameStrata("LOW")
items:SetFrameLevel(frame:GetFrameLevel() + 30)
items:EnableMouse(false)
Core.items = items
