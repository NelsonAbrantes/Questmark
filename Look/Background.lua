local _, ns = ...
local Core = ns.Core

-- luacheck: push ignore 113
local CreateFrame = CreateFrame
-- luacheck: pop

local TEXTURE = Core.ASSETS.."softBackground"
local SOFT_EDGE = 56 -- how many pixels of the image fade out at each side
-- Background colors offered in the options (dark, so the text stays readable)
local BACKGROUND_COLORS = {
  black = { 0, 0, 0 },
  brown = { 0.14, 0.09, 0.05 },
  blue = { 0.03, 0.06, 0.13 },
  grey = { 0.13, 0.13, 0.14 },
}
local PRESENCE_FADE = 0.4 -- seconds to fade out when the tracker empties

----
-- Background
--
-- The Glass background behind the tracker: dark in the middle and fading out
-- softly on every side, like a diffuse shadow. It covers what the tracker
-- shows, and fades out when there's nothing in it. It's part of the tracker,
-- so it fades and slides with it.

local frame = Core.frame

local texture = Core.Smooth(frame:CreateTexture(nil, "BACKGROUND"))
texture:SetTexture(TEXTURE)
if texture.SetTextureSliceMargins then
  texture:SetTextureSliceMargins(SOFT_EDGE, SOFT_EDGE, SOFT_EDGE, SOFT_EDGE)
  if texture.SetTextureSliceMode and _G.Enum and _G.Enum.UITextureSliceMode then
    texture:SetTextureSliceMode(_G.Enum.UITextureSliceMode.Stretched)
  end
end

local background = { texture = texture }
Core.background = background

local presence, presenceTarget = 0, 0
local fader = CreateFrame("Frame")
fader:Hide()

-- The chosen opacity and the fade out when empty go together in the color's
-- alpha (in this game version a texture's own alpha replaces it instead)
function background:UpdateColor()
  local profile = Core.db.profile
  local color = BACKGROUND_COLORS[profile.backgroundColor] or BACKGROUND_COLORS.black
  texture:SetVertexColor(color[1], color[2], color[3], profile.backgroundOpacity * presence)
end

---
-- Covers the tracker's content (`height` tall from its top); 0: nothing shown
function background:Update(height)
  local pad = Core.db.profile.backgroundSize
  presenceTarget = height > 0 and 1 or 0
  if height > 0 then
    texture:ClearAllPoints()
    texture:SetPoint("TOPLEFT", frame, "TOPLEFT", -pad, pad)
    texture:SetPoint("BOTTOMRIGHT", frame, "TOPRIGHT", pad, -(height + pad))
  end
  if presence ~= presenceTarget then fader:Show() end
end

fader:SetScript("OnUpdate", function (_, elapsed)
  local step = elapsed / PRESENCE_FADE
  if presenceTarget > presence then
    presence = math.min(presenceTarget, presence + step)
  else
    presence = math.max(presenceTarget, presence - step)
  end
  background:UpdateColor()
  if presence == presenceTarget then fader:Hide() end
end)

Core:OnChange(function (key)
  if key == "backgroundOpacity" or key == "backgroundColor" or key == "profile" or key == "enable" then
    background:UpdateColor()
  elseif key == "backgroundSize" then
    Core:Changed("layout")
  end
end)
