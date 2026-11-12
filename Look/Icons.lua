local _, ns = ...
local Core = ns.Core

-- luacheck: push ignore 113
local CreateFrame = CreateFrame
local GetTime = GetTime
-- luacheck: pop

local ASSETS = Core.ASSETS
local Smooth = Core.Smooth -- grows smoothly, not pixel by pixel

----
-- Icons
--
-- The tracker's icons ("?" ready to turn in, "..." in progress, the minimize
-- buttons): plain icons in the icon color with a dark outline, lighter under
-- the mouse or on the quest you follow.
-- - Pulse: a quest ready to turn in, its "?" a little bigger and fainter,
--   then back, over and over
-- - Ring: a quest just added, a soft ring opens around its icon
-- Sizes are worked out frame by frame and capped (the game's own scale
-- animations kept growing without end in this game version).

local LIGHTER = 0.55 -- how much white is mixed in on the followed quest

---
-- Gives a button a Glass icon of `size`. Returns the icon texture.
function Core.CreateIcon(button, size)
  local icon = Smooth(button:CreateTexture(nil, "OVERLAY", nil, 7))
  icon:SetSize(size, size)
  icon:SetPoint("CENTER")
  button.gftIcon = icon
  button.gftIconSize = size

  -- The outline: the icon's shape a little bigger, in black, behind it
  local outline = Smooth(button:CreateTexture(nil, "OVERLAY", nil, 6))
  outline:SetSize(size, size)
  outline:SetPoint("CENTER")
  outline:SetVertexColor(0, 0, 0, 0.9)
  button.gftOutline = outline
  return icon
end

---
-- Sets which icon a button shows ("questComplete", "questProgress",
-- "collapse", "expand"), with its outline
function Core.SetIcon(button, name)
  if button.gftIconName ~= name then
    button.gftIconName = name
    button.gftIcon:SetTexture(ASSETS..name)
    button.gftOutline:SetTexture(ASSETS..name.."Outline")
  end
  button.gftOutline:SetShown(Core.db.profile.iconOutline)
end

---
-- The icon color (Options). Under the mouse and on the quest you follow it's
-- a lighter version of it, so the color still shows (white icons get gold).
function Core.IconColor(bright)
  local choice = Core.db.profile.iconColor
  local r, g, b = Core:Color(choice)
  local gold = Core.GOLD
  r, g, b = r or gold.r, g or gold.g, b or gold.b
  if bright then
    if choice == "white" then return gold.r, gold.g, gold.b end
    return Core.Lighter(r, g, b, LIGHTER)
  end
  return r, g, b
end

function Core.ColorIcon(button, bright)
  button.gftIcon:SetVertexColor(Core.IconColor(bright or button.gftHover))
end

----
-- Pulse and ring

local MAX_SCALE = 1.5
local PULSE_TIME = 0.7   -- seconds to grow (and as many to come back)
local PULSE_GROW = 0.18  -- 18% bigger at the top
local RING_TIME, RING_SIZE = 1.0, 30
local RING_LIGHT_UP = 0.25 -- part of the time it takes to light up
local PULSE_EASE = 0.4     -- seconds the "?" pulse takes to calm down or come back around the ring

local animated = {} -- button -> { pulse = start time, ring = start time }
local animator = CreateFrame("Frame")
animator:Hide()

animator:SetScript("OnUpdate", function ()
  local now = GetTime()
  for button, state in pairs(animated) do
    local scale, alpha = 1, 1

    if state.pulse then
      -- On a shared clock, not from its start: every "?" pulses together
      local t = now % (PULSE_TIME * 2)
      local wave = 0.5 - 0.5 * math.cos(math.pi * t / PULSE_TIME)
      -- Quiet while the ring opens (both together looked like a double
      -- pulse): it eases out as the ring starts and back in after it ends
      local strength = 1
      if state.ring then
        strength = 1 - math.min(1, (now - state.ring) / PULSE_EASE)
      elseif state.ringEnded then
        strength = math.min(1, (now - state.ringEnded) / PULSE_EASE)
        if strength >= 1 then state.ringEnded = nil end
      end
      wave = wave * strength * strength * (3 - 2 * strength)
      scale = scale * (1 + PULSE_GROW * wave)
      alpha = 1 - 0.4 * wave
    end

    if state.ring and button.gftRing then
      local k = (now - state.ring) / RING_TIME
      if k < 1 then
        -- Opens with a soft start and end, lights up gently at first and
        -- fades out smoothly at the end
        local size = RING_SIZE * (0.6 + 0.9 * k * k * (3 - 2 * k))
        button.gftRing:SetSize(size, size)
        local light = k < RING_LIGHT_UP and k / RING_LIGHT_UP or (1 - k) / (1 - RING_LIGHT_UP)
        button.gftRing:SetAlpha(0.8 * light * light * (3 - 2 * light))
      else
        button.gftRing:SetAlpha(0)
        button.gftRing:Hide()
        state.ring = nil
        state.ringEnded = now
      end
    end

    local size = button.gftIconSize * math.min(scale, MAX_SCALE)
    button.gftIcon:SetSize(size, size)
    button.gftIcon:SetAlpha(alpha)
    button.gftOutline:SetSize(size, size)
    button.gftOutline:SetAlpha(alpha)

    if not (state.pulse or state.ring) then
      animated[button] = nil
    end
  end
  if next(animated) == nil then animator:Hide() end
end)

---
-- Starts or stops an icon's pulse ("pulse") or ring ("ring")
function Core.AnimateIcon(button, key, on)
  local state = animated[button]
  if on then
    if not state then
      state = {}
      animated[button] = state
    end
    if key ~= "pulse" or not state.pulse then state[key] = GetTime() end
    animator:Show()
  elseif state and state[key] then
    state[key] = nil
    -- Back to its normal size (the animator lets go of it once nothing's left)
    animator:Show()
  end
end

---
-- A quest just added: a soft ring opens around its icon, in the icon color
function Core.RingIcon(button)
  if not button or not button.gftIcon then return end
  if not button.gftRing then
    local ring = Smooth(button:CreateTexture(nil, "OVERLAY", nil, 5))
    ring:SetTexture(ASSETS.."ring")
    ring:SetBlendMode("ADD")
    ring:SetPoint("CENTER")
    ring:SetAlpha(0)
    button.gftRing = ring
  end
  -- Already opening: starting over halfway looked like a jump back
  local state = animated[button]
  if state and state.ring and GetTime() - state.ring < RING_TIME then return end
  button.gftRing:SetVertexColor(button.gftIcon:GetVertexColor())
  button.gftRing:Show()
  Core.AnimateIcon(button, "ring", true)
end

---
-- An icon given back to the pool: no animation left on it
function Core.ResetIcon(button)
  animated[button] = nil
  if button.gftRing then
    button.gftRing:SetAlpha(0)
    button.gftRing:Hide()
  end
  local size = button.gftIconSize
  button.gftIcon:SetSize(size, size)
  button.gftIcon:SetAlpha(1)
  button.gftOutline:SetSize(size, size)
  button.gftOutline:SetAlpha(1)
end
