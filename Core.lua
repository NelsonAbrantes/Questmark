local AddonName, ns = ...

local Core = LibStub("AceAddon-3.0"):NewAddon(AddonName, "AceHook-3.0")
ns.Core = Core
_G.GlassForeverTracker = Core

Core.Version = "0.1.0-forever"
Core.LSM = LibStub("LibSharedMedia-3.0")
Core.listeners = {} -- filled while the files load, see Core:OnChange

-- The Glass gold, for titles and highlights
Core.GOLD = { r = 223 / 255, g = 186 / 255, b = 105 / 255 }

-- Colors offered in the options (the Glass Forever accent colors), in order
Core.COLORS = {
  -- Brighter and yellower than the Glass gold, so it stands apart from bronze
  { "gold", "Gold", { 1.00, 0.82, 0.22 } },
  { "white", "White", { 1, 1, 1 } },
  { "silver", "Silver", { 0.75, 0.76, 0.80 } },
  { "bronze", "Bronze", { 0.88, 0.62, 0.36 } },
  { "cyan", "Cyan", { 0.30, 0.80, 0.95 } },
  { "green", "Green", { 0.40, 0.90, 0.45 } },
  { "purple", "Purple", { 0.72, 0.50, 0.95 } },
  { "red", "Red", { 0.95, 0.38, 0.32 } },
  { "class", "Class color" },
}

---
-- Makes a thin line (or bar) an exact number of screen pixels tall: sizes in
-- the UI's units don't fall on whole pixels with every UI scale, and some
-- lines came out thicker than others
function Core.PixelHeight(region, pixels)
  local PixelUtil = _G.PixelUtil
  if PixelUtil and PixelUtil.SetHeight then
    PixelUtil.SetHeight(region, pixels, pixels)
  else
    region:SetHeight(pixels)
  end
end

---
-- r, g, b of a color from Core.COLORS by its key; nil if unknown
function Core:Color(key)
  if key == "class" then
    local _, class = UnitClass("player")
    local color = class and _G.RAID_CLASS_COLORS and _G.RAID_CLASS_COLORS[class]
    if color then return color.r, color.g, color.b end
    key = "gold"
  end
  for _, entry in ipairs(self.COLORS) do
    if entry[1] == key then
      return entry[3][1], entry[3][2], entry[3][3]
    end
  end
  return nil
end

Core.defaults = {
  profile = {
    -- Fade
    fade = true,              -- the tracker fades out when you're not using it
    holdTime = 8,             -- seconds before it fades out
    fadeInDuration = 0.3,
    fadeOutDuration = 0.8,
    fadedAlpha = 0,           -- how visible it stays when faded (0 = hidden)
    showOnMouseOver = true,   -- comes back while the mouse is over it
    showOnProgress = true,    -- comes back for a while when an objective changes

    -- Look
    glassLook = true,         -- no game backgrounds, Glass font
    font = "Friz Quadrata TT",
    fontFlags = "",
    headerFontSize = 14,      -- section titles ("Quests") and quest names
    lineFontSize = 12,        -- objectives
    backgroundOpacity = 0.25, -- the Glass fading background behind the tracker
    backgroundColor = "black", -- black, brown, blue or grey
    backgroundSize = 36,      -- how far the background reaches past the text
    lineSpacing = 0,          -- extra space between the lines of a text
    width = 260,              -- tracker width (the game's own is 260)
    titleColor = "gold",      -- section titles ("Quests"); see Core.COLORS
    questNameColor = "auto",  -- quest names; "auto" keeps the game's colors
    iconColor = "gold",       -- quest and minimize icons; "game" = the game's own
    iconOutline = true,       -- a dark outline around the Glass icons
    hideMainHeader = false,   -- hide the "All Objectives" title
    hideSectionHeaders = false, -- hide the section titles ("Quests"...)

    questCount = true,        -- "Quests 12/25" in the Quests title
    completedObjectives = "show", -- finished objectives: show or dim
    glassBars = true,         -- progress bars in the Glass style
    sectionAnimation = "glass", -- animations of sections, quests and objectives: glass, game or off

    -- Behavior
    zoneOnly = false,         -- track only the quests of the current zone
    zoneHeaders = true,       -- quests sorted by zone, with each zone's name above them
    currentZoneFirst = true,  -- the zone you're in at the top
    completedLast = true,     -- quests ready to turn in at the end of their zone
    strikeCompleted = true,   -- finished objectives struck through
    instanceMode = "normal",  -- in dungeons and raids: normal, hide, show or dungeon (only its quests)
    completeSound = true,     -- a sound when an objective or quest is done
    orcVoice = true,          -- quest ready to turn in: the orc peon's "Work complete!"
  }
}

----
-- Core
--
-- Settings changes are announced with Core:Changed(key); the other parts of
-- the addon listen with Core:OnChange(function (key, ...) ... end). Some
-- announcements carry more (e.g. "questAdded" carries the quest block).

function Core:OnInitialize()
  self.db = LibStub("AceDB-3.0"):New("GlassForeverTrackerDB", self.defaults, true)

  local function Refresh() self:Changed("profile") end
  self.db.RegisterCallback(self, "OnProfileChanged", Refresh)
  self.db.RegisterCallback(self, "OnProfileCopied", Refresh)
  self.db.RegisterCallback(self, "OnProfileReset", Refresh)

  self:Changed("init")
end

function Core:OnChange(listener)
  table.insert(self.listeners, listener)
end

function Core:Changed(key, ...)
  for _, listener in ipairs(self.listeners) do
    listener(key, ...)
  end
end

---
-- True if the addon's animations are on: the Glass look with the Animation
-- style set to Glass
function Core:Animates()
  local profile = self.db.profile
  return profile.glassLook and profile.sectionAnimation == "glass"
end

---
-- /gft animlog: writes in chat when animations start, to find problems
function Core:AnimLog(...)
  if not self.animLog then return end
  print(("|cffdfba69GFT|r %.2f"):format(GetTime()), ...)
end

---
-- Textures snap to whole pixels by default, so ones that grow or move went
-- in small jumps (an icon growing a few pixels had only 3 or 4 sizes).
-- Without it they animate smoothly. Returns the texture.
function Core.Smooth(texture)
  if texture and texture.SetSnapToPixelGrid then
    texture:SetSnapToPixelGrid(false)
    texture:SetTexelSnappingBias(0)
  end
  return texture
end

---
-- Growing animations go wrong in this game version: what they grow can
-- become huge for a moment (a gold glow over half the screen). The game's
-- own tracker animations keep their other steps but no longer grow.
function Core.NoGrowing(group)
  if not group or group.gftNoGrowing or not group.GetAnimations then return end
  group.gftNoGrowing = true
  for _, animation in ipairs({ group:GetAnimations() }) do
    if animation:GetObjectType() == "Scale" then
      if animation.SetScaleFrom then animation:SetScaleFrom(1, 1) end
      if animation.SetScaleTo then animation:SetScaleTo(1, 1) end
      if animation.SetScale then animation:SetScale(1, 1) end
    end
  end
end
