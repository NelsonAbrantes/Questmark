local AddonName, ns = ...

local Core = LibStub("AceAddon-3.0"):NewAddon(AddonName, "AceHook-3.0")
ns.Core = Core
_G.Questmark = Core

Core.Version = "0.1.0-forever"
Core.LSM = LibStub("LibSharedMedia-3.0")
Core.listeners = {} -- filled while the files load, see Core:OnChange
Core.ASSETS = "Interface\\AddOns\\Questmark\\Assets\\"

-- The Glass gold, for titles and highlights
Core.GOLD = { r = 223 / 255, g = 186 / 255, b = 105 / 255 }

-- Colors offered in the options (the Glass Forever accent colors), in order
Core.COLORS = {
  -- The Glass Forever chat's own gold (the default)
  { "glass", "Warm gold", { 223 / 255, 186 / 255, 105 / 255 } },
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

---
-- The title color (Options), gold if unknown
function Core:TitleColor()
  local r, g, b = self:Color(self.db.profile.titleColor)
  return r or self.GOLD.r, g or self.GOLD.g, b or self.GOLD.b
end

---
-- The dungeon card's color: the brighter gold it had before the Glass gold
-- became the title color (another title color chosen in the options counts)
function Core:CardColor()
  if self.db.profile.titleColor == "glass" then return self:Color("gold") end
  return self:TitleColor()
end

---
-- A color made lighter (mixed with white), for things under the mouse
function Core.Lighter(r, g, b, amount)
  amount = amount or 0.4
  return r + (1 - r) * amount, g + (1 - g) * amount, b + (1 - b) * amount
end

---
-- False for values the game marks as secret (they can't be read)
function Core.Readable(value)
  return value ~= nil and not (issecretvalue and issecretvalue(value))
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
    font = "Friz Quadrata TT",
    fontFlags = "",
    headerFontSize = 14,      -- section titles ("Quests") and quest names
    lineFontSize = 12,        -- objectives
    backgroundOpacity = 0.25, -- the Glass fading background behind the tracker
    backgroundColor = "black", -- black, brown, blue or grey
    backgroundSize = 36,      -- how far the background reaches past the text
    lineSpacing = 0,          -- extra space between the lines of a text
    width = 260,              -- tracker width
    maxHeight = 650,          -- the highest the tracker gets; past it, it scrolls (0: no limit)
    titleColor = "glass",     -- section titles ("Quests"), zone names, bars; see Core.COLORS
    questNameColor = "auto",  -- quest names; "auto" = by difficulty, like the game
    iconColor = "glass",      -- quest and minimize icons
    iconOutline = true,       -- a dark outline around the icons
    hideMainHeader = false,   -- hide the "Objectives" title
    hideSectionHeaders = false, -- hide the section titles ("Quests"...)

    questCount = true,        -- "Quests 12/25" in the Quests title
    completedObjectives = "show", -- finished objectives: show or dim
    glassBars = true,         -- progress bars in the title color (off: the game's green)
    sectionAnimation = "glass", -- animations: glass or off

    -- Parts (each can be turned off)
    useTracker = true,        -- the tracker in place of the game's (changes need a reload)
    useBook = true,           -- the quest book (off: the game's quest log)

    -- Behavior
    allQuests = true,         -- every quest in the quest log, not only the tracked ones
    bookKey = true,           -- the quest log's key (L) opens the quest book
    bookSize = 100,           -- the quest book's size (% of its own; also its corner)
    bookTextSize = 12,        -- its writing and list
    bookTitleSize = 24,       -- its titles (headings and zones go with it)
    bookMapSize = 100,        -- its map (% of the page, Show map)
    bookMapZoom = 1,          -- how close its map opens on the quest's place
    bookAnimations = true,    -- it opens, shuts and turns its pages as a book
    bookSounds = true,        -- its sounds (opening, shutting, page turns)
    zoneOnly = false,         -- only the quests of the current zone
    zoneHeaders = true,       -- quests sorted by zone, with each zone's name above them
    currentZoneFirst = true,  -- the zone you're in at the top
    completedLast = true,     -- quests ready to turn in at the end of their zone
    strikeCompleted = true,   -- finished objectives struck through
    instanceMode = "dungeon", -- in dungeons and raids: normal, hide, show or dungeon (only its quests)
    dungeonInfo = true,
    dungeonAlwaysShow = true, -- in dungeons and raids the tracker doesn't fade out       -- in dungeons and raids: time, bosses, experience and gold of the run
    completeSound = true,     -- a sound when an objective or quest is done
    orcVoice = true,          -- quest ready to turn in: the orc peon's "Work complete!"

    -- Where the tracker is, per Edit Mode layout (layout name -> point, x, y)
    positions = {},
  }
}

----
-- Core
--
-- Settings changes are announced with Core:Changed(key); the other parts of
-- the addon listen with Core:OnChange(function (key, ...) ... end). Some
-- announcements carry more (e.g. "questAdded" carries the quest block).

function Core:OnInitialize()
  self.db = LibStub("AceDB-3.0"):New("QuestmarkDB", self.defaults, true)

  -- Settings of the version that restyled the game's tracker
  local profile = self.db.profile
  if profile.sectionAnimation == "game" then profile.sectionAnimation = "glass" end
  if profile.iconColor == "game" then profile.iconColor = "glass" end
  -- The Glass gold became the default (once: "Gold" can still be chosen)
  if not profile.glassGoldDefault then
    profile.glassGoldDefault = true
    if profile.titleColor == "gold" then profile.titleColor = "glass" end
    if profile.iconColor == "gold" then profile.iconColor = "glass" end
  end

  local function Refresh() self:Changed("profile") end
  self.db.RegisterCallback(self, "OnProfileChanged", Refresh)
  self.db.RegisterCallback(self, "OnProfileCopied", Refresh)
  self.db.RegisterCallback(self, "OnProfileReset", Refresh)

  self:Changed("init")
end

function Core:OnEnable()
  -- The tracker on or off, as it was when the game loaded (turning it on or
  -- off needs a reload: the game's tracker only comes back right then)
  self.trackerOn = self.db.profile.useTracker ~= false
  self:Changed("enable")
end

---
-- True while the quest book is on (Options: Quest book)
function Core.BookOn()
  return Core.db.profile.useBook ~= false
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
-- True if the addon's animations are on (Options: Animations)
function Core:Animates()
  return self.db.profile.sectionAnimation ~= "off"
end

---
-- /qm animlog: writes in chat when animations start, to find problems
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
-- Old entries of a "when" list are dropped, so it doesn't keep growing over
-- a session
function Core.DropOld(list, now, age)
  for key, when in pairs(list) do
    if now - when > age then list[key] = nil end
  end
end

-- Quests tracked again by the addon (the zone filter), not by you: they come
-- in without the new quest animations. questID -> when.
Core.rewatched = {}
