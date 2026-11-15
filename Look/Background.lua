local _, ns = ...
local Core = ns.Core

-- luacheck: push ignore 113
local CreateFrame = CreateFrame
-- luacheck: pop

-- The looks (Options: Background style): the soft shadow, or a smear of
-- dark paint with rough edges (Tools/smudge.py), each with the part of its
-- picture kept as it is at each side (the rest stretches)
local STYLES = {
  soft = { file = Core.ASSETS.."softBackground", edge = 56 },
  smudge = { file = Core.ASSETS.."smudgeBackground", edge = 128 },
}
-- (the paint is gray: tinted, not darkened, by the color chosen)
local SMUDGE_TINTS = {
  black = { 1, 1, 1 },
  brown = { 1, 0.86, 0.7 },
  blue = { 0.78, 0.86, 1 },
  grey = { 1.1, 1.1, 1.1 },
}
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

local function ApplyStyle()
  local style = STYLES[Core.db.profile.backgroundStyle] or STYLES.soft
  texture:SetTexture(style.file)
  if texture.SetTextureSliceMargins then
    texture:SetTextureSliceMargins(style.edge, style.edge, style.edge, style.edge)
    if texture.SetTextureSliceMode and _G.Enum and _G.Enum.UITextureSliceMode then
      texture:SetTextureSliceMode(_G.Enum.UITextureSliceMode.Stretched)
    end
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
  local smudge = profile.backgroundStyle == "smudge"
  local colors = smudge and SMUDGE_TINTS or BACKGROUND_COLORS
  local color = colors[profile.backgroundColor] or colors.black
  -- (the paint is meant to be seen, the shadow barely: the same slider
  -- makes the paint much more solid)
  local opacity = smudge and math.min(1, profile.backgroundOpacity * 3) or profile.backgroundOpacity
  texture:SetVertexColor(color[1], color[2], color[3], opacity * presence)
end

---
-- Covers the tracker's content (`height` tall from its top); 0: nothing shown
function background:Update(height)
  local pad = Core.db.profile.backgroundSize
  -- (the paint's picture has room around it for the strokes running out)
  if Core.db.profile.backgroundStyle == "smudge" then pad = pad + 64 end
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
  if key == "backgroundStyle" or key == "profile" or key == "enable" then
    ApplyStyle()
    background:UpdateColor()
    if key == "backgroundStyle" then Core:Changed("layout") end
  elseif key == "backgroundOpacity" or key == "backgroundColor" then
    background:UpdateColor()
  elseif key == "backgroundSize" then
    Core:Changed("layout")
  end
end)
