local _, ns = ...
local Core = ns.Core

-- luacheck: push ignore 113
local CreateFont = CreateFont
-- luacheck: pop

----
-- Fonts
--
-- The tracker's own fonts. Every text of the tracker uses one of them, so a
-- change in the options reaches all of them at once.
-- - header: section titles and the names of quests, achievements, recipes
-- - line: objectives, criteria and reagents
-- - zone: the small zone names between quests

local fonts = {
  header = CreateFont("GlassForeverTrackerHeaderFont"),
  line = CreateFont("GlassForeverTrackerLineFont"),
  zone = CreateFont("GlassForeverTrackerZoneFont"),
  title = CreateFont("GlassForeverTrackerTitleFont"), -- the dungeon's name, bigger
}
Core.fonts = fonts

local FALLBACK = "Fonts\\FRIZQT__.TTF"

-- The zone names: small, to sit between the quests
function Core.ZoneFontSize()
  return math.max(8, Core.db.profile.lineFontSize - 3)
end

function Core:UpdateFonts()
  local profile = self.db.profile
  local path = self.LSM:Fetch(self.LSM.MediaType.FONT, profile.font, true) or FALLBACK
  local flags = profile.fontFlags or ""
  local sizes = {
    header = profile.headerFontSize,
    line = profile.lineFontSize,
    zone = self.ZoneFontSize(),
    title = profile.headerFontSize + 4,
  }
  for key, font in pairs(fonts) do
    font:SetFont(path, sizes[key], flags)
    if not font:GetFont() then font:SetFont(FALLBACK, sizes[key], flags) end
    -- A soft shadow, like the game's tracker, so the text reads on any background
    font:SetShadowColor(0, 0, 0, 1)
    font:SetShadowOffset(1, -1)
    font:SetSpacing(profile.lineSpacing or 0)
    font:SetJustifyH("LEFT")
  end
end

local FONT_KEYS = {
  init = true, profile = true, font = true, fontFlags = true,
  headerFontSize = true, lineFontSize = true, lineSpacing = true,
}

Core:OnChange(function (key)
  if FONT_KEYS[key] then
    Core:UpdateFonts()
    if key ~= "init" then Core:Changed("layout") end
  end
end)
