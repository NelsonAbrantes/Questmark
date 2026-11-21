local _, ns = ...
local Core = ns.Core

-- luacheck: push ignore 113
local CreateFrame = CreateFrame
local UIParent = UIParent
-- luacheck: pop

----
-- The navigation marker (Options: Navigation marker): with a quest followed,
-- a mark on the screen over the place it leads to, with how far it is. The
-- game places its own mark there (its in-game navigation, turned on while
-- the option is on, and back as it was after); the addon hides the game's
-- and draws its own on the same spot, with the shape, size, color and text
-- chosen (Quest GPS options page). Out of sight, at the screen's edge, a
-- little arrow beside it points the way.

local STYLES = { pin = "navPin", diamond = "navDiamond", ring = "navRing", flag = "navFlag", star = "navStar",
  quest = "navQuest", faction = "navDiamond", class = "navDiamond" }

-- "Faction crest": the game's own crest of your faction (from the game's
-- files, in its own colors); a character with no faction yet gets the diamond
local CRESTS = {
  -- (color: the crest's own, for the little arrow beside it: the Alliance's
  -- gold, the Horde's red)
  Alliance = { atlas = "MountJournalIcons-Alliance", file = "Interface\\Timer\\Alliance-Logo", color = { 0.8, 0.56, 0.16 } },
  Horde = { atlas = "MountJournalIcons-Horde", file = "Interface\\Timer\\Horde-Logo", color = { 0.8, 0.12, 0.1 } },
}

local function CrestColor()
  local crest = CRESTS[_G.UnitFactionGroup and _G.UnitFactionGroup("player") or ""]
  if crest then return crest.color[1], crest.color[2], crest.color[3] end
end

-- The crest put on the texture: true if there was one
local function Crest(texture)
  local faction = _G.UnitFactionGroup and _G.UnitFactionGroup("player")
  local crest = CRESTS[faction]
  if not crest then return false end
  -- (the battleground clock's crest first: solid, in full color. The mount
  -- journal's is a faint watermark: only if the other isn't there)
  texture:SetTexCoord(0, 1, 0, 1)
  if texture:SetTexture(crest.file) ~= false and texture:GetTexture() then return true end
  local Atlas = _G.C_Texture and _G.C_Texture.GetAtlasInfo
  if Atlas and Atlas(crest.atlas) then
    texture:SetAtlas(crest.atlas)
    return true
  end
  return false
end

-- "Class icon": the game's icon of your class without a background (the
-- one of the battlegrounds' score board), in its own colors, its little
-- arrow in your class's color; a class without one gets the diamond
local CLASS_FILE = "Interface\\WorldStateFrame\\Icons-Classes"
-- (where each class is on it, if the game doesn't say: CLASS_ICON_TCOORDS)
local CLASS_COORDS = {
  WARRIOR = { 0, 0.25, 0, 0.25 }, MAGE = { 0.25, 0.49609375, 0, 0.25 },
  ROGUE = { 0.49609375, 0.7421875, 0, 0.25 }, DRUID = { 0.7421875, 0.98828125, 0, 0.25 },
  HUNTER = { 0, 0.25, 0.25, 0.5 }, SHAMAN = { 0.25, 0.49609375, 0.25, 0.5 },
  PRIEST = { 0.49609375, 0.7421875, 0.25, 0.5 }, WARLOCK = { 0.7421875, 0.98828125, 0.25, 0.5 },
  PALADIN = { 0, 0.25, 0.5, 0.75 },
}

local function PlayerClass()
  local _, class = _G.UnitClass("player")
  return class
end

local function ClassColor()
  local class = PlayerClass()
  local color = class and _G.C_ClassColor and _G.C_ClassColor.GetClassColor and _G.C_ClassColor.GetClassColor(class)
  color = color or (class and _G.RAID_CLASS_COLORS and _G.RAID_CLASS_COLORS[class])
  if color then return color.r, color.g, color.b end
end

-- The class icon put on the texture: true if there was one
local function ClassIcon(texture)
  local class = PlayerClass()
  local coords = class and (_G.CLASS_ICON_TCOORDS and _G.CLASS_ICON_TCOORDS[class] or CLASS_COORDS[class])
  if not coords then return false end
  if texture:SetTexture(CLASS_FILE) == false or not texture:GetTexture() then return false end
  texture:SetTexCoord(coords[1], coords[2], coords[3], coords[4])
  return true
end

local function Profile() return Core.db.profile end

-- At the place: the mark see-through, from FAR yards (not yet) to NEAR
local NEAR, FAR = 10, 30
local NEAR_ALPHA = 0.35

local marker = CreateFrame("Frame", "QuestmarkNavigation", UIParent)
marker:SetFrameStrata("BACKGROUND")
marker:SetSize(32, 32)
marker:Hide()

local shape = Core.Smooth(marker:CreateTexture(nil, "ARTWORK"))
shape:SetPoint("CENTER")

local font = CreateFont("QuestmarkNavigationFont")
font:SetFont("Fonts\\FRIZQT__.TTF", 12, "OUTLINE")
-- (out of sight: a little arrow beside the mark, toward the place)
local pointer = Core.Smooth(marker:CreateTexture(nil, "OVERLAY"))
pointer:SetTexture(Core.ASSETS.."gpsTriangle")
pointer:Hide()

local distance = marker:CreateFontString(nil, "OVERLAY")
distance:SetFontObject(font)
distance:SetPoint("TOP", shape, "BOTTOM", 0, -2)

local function Look()
  local profile = Profile()
  local size = profile.navSize or 32
  local crest = profile.navStyle == "faction" and Crest(shape)
  local classIcon = profile.navStyle == "class" and ClassIcon(shape)
  if not (crest or classIcon) then
    -- (the whole image again: the game's crest cuts a part of a bigger one)
    shape:SetTexture(Core.ASSETS..(STYLES[profile.navStyle] or STYLES.diamond))
    shape:SetTexCoord(0, 1, 0, 1)
  end
  -- (the game's crest has room around it in its picture: drawn bigger, to
  -- look as big as the other marks)
  local drawn = crest and size * 1.5 or size
  shape:SetSize(drawn, drawn)
  pointer:SetSize(size * 0.45, size * 0.45)
  -- (a pin stands on the place with its point; the others sit over it)
  shape:ClearAllPoints()
  shape:SetPoint(profile.navStyle == "pin" and "BOTTOM" or "CENTER", marker, "CENTER")
  marker:SetSize(size, size)
  font:SetFont("Fonts\\FRIZQT__.TTF", profile.navTextSize or 12, "OUTLINE")
  local r, g, b = Core:Color(profile.navColor)
  if not r then r, g, b = Core:TitleColor() end
  -- (the crest keeps the game's colors, and its little arrow takes the
  -- crest's; the distance takes the color chosen)
  if crest then
    shape:SetVertexColor(1, 1, 1)
    pointer:SetVertexColor(CrestColor())
  elseif classIcon then
    local cr, cg, cb = ClassColor()
    shape:SetVertexColor(1, 1, 1)
    pointer:SetVertexColor(cr or r, cg or g, cb or b)
  else
    shape:SetVertexColor(r, g, b)
    pointer:SetVertexColor(r, g, b)
  end
  distance:SetTextColor(r, g, b)
end

-- The game's mark: hidden while ours shows (its own code sets how visible
-- it is as it goes: put back to hidden each time)
local hiding, settingAlpha = false, false
local gameAlpha = 1 -- how visible the game had its mark, put back when ours goes
local function HideGameMark(on)
  local game = _G.SuperTrackedFrame
  if not game then return end
  -- (how visible the game had it, kept before ours hides it)
  if on and not hiding then gameAlpha = game:GetAlpha() end
  hiding = on
  if not game.questmarkHooked then
    game.questmarkHooked = true
    hooksecurefunc(game, "SetAlpha", function (self, alpha)
      if not settingAlpha then gameAlpha = alpha or 1 end
      if hiding and not settingAlpha then
        settingAlpha = true
        self:SetAlpha(0)
        settingAlpha = false
      end
    end)
  end
  settingAlpha = true
  game:SetAlpha(on and 0 or gameAlpha)
  settingAlpha = false
end

-- How visible ours is, the way the game has its own ("Default"):
-- - behind something (a hill, a tree, a wall), see-through; in sight, or at
--   the screen's edge, whole
-- - under the mouse, fainter toward its middle (out of the way of a click)
-- - from one to the other smoothly, not at once
-- and, ours only, see-through close to the place (the mark in the way of
-- what's there)
local OCCLUDED_ALPHA = 0.6 -- the game's

local function NearAlpha(yards)
  if yards and yards < FAR then
    return NEAR_ALPHA + (1 - NEAR_ALPHA) * math.max(0, yards - NEAR) / (FAR - NEAR)
  end
  return 1
end

-- (asked to the game's mark first: how visible it wants itself, before its
-- fading under the mouse; it knows when the place is behind something)
local function SightAlpha(Nav)
  local game = _G.SuperTrackedFrame
  if game and type(game.GetTargetAlphaBaseValue) == "function" then
    local ok, alpha = pcall(game.GetTargetAlphaBaseValue, game)
    -- (0: the game keeping its own mark hidden, its navigation setting off or
    -- gone; ours shows anyway, by the place being in sight or not)
    if ok and type(alpha) == "number" and alpha > 0 then return math.min(1, alpha) end
  end
  if Nav.WasClampedToScreen and Nav.WasClampedToScreen() then return 1 end
  local states = _G.Enum and _G.Enum.NavigationState
  local state = Nav.GetTargetState and Nav.GetTargetState()
  if states and state == states.Occluded then return OCCLUDED_ALPHA end
  -- (the game not knowing if it's in sight: its navigation setting gone on
  -- this game, "Invalid". See-through, as the game's mark mostly was)
  if states and state == states.InRange then return 1 end
  return OCCLUDED_ALPHA
end

local function MouseAlpha()
  if not shape:IsMouseOver() then return 1 end
  local x, y = _G.GetCursorPosition()
  local scale = shape:GetEffectiveScale()
  local cx, cy = shape:GetCenter()
  if not (x and cx) then return 1 end
  local dx, dy = x / scale - cx, y / scale - cy
  local radius = math.max(shape:GetWidth(), shape:GetHeight())
  local reach = radius * radius * 2
  if reach <= 0 then return 1 end
  return math.min(1, (dx * dx + dy * dy) / reach)
end

local function Toward(current, target)
  if _G.FrameDeltaLerp then return _G.FrameDeltaLerp(current, target, 0.1) end
  return current + (target - current) * 0.1
end

-- Something to lead to: the game shows its frame even with nothing followed
-- (only see-through), and ours was then drawn where it sat, over the player
local function Leading()
  local SuperTrack = _G.C_SuperTrack
  if SuperTrack and SuperTrack.IsSuperTrackingAnything and not SuperTrack.IsSuperTrackingAnything() then return false end
  local Nav = _G.C_Navigation
  if Nav and Nav.GetFrame and not Nav.GetFrame() then return false end
  -- Not in dungeons, like the GPS: the game doesn't tell where you are
  -- there (no distance), and the mark sat at the screen's edge
  local InInstance = _G.IsInInstance
  if InInstance and InInstance() then return false end
  -- Nor with no distance: a place the game can't lead to from here (a
  -- quest inside a dungeon, followed from outside), where the mark sat
  -- still at the top of the screen
  if Nav and Nav.GetDistance then
    local yards = Nav.GetDistance()
    if not yards or yards <= 0 then return false end
  end
  -- (not how visible the game has its mark: it fades it from where it is,
  -- and ours keeps it at 0, so it went up and down by the frame: blinking)
  return true
end

-- Over the game's mark, every frame
marker:SetScript("OnUpdate", function ()
  local game = _G.SuperTrackedFrame
  -- (both of its numbers: "a and f()" would keep only the first)
  local x, y
  if game and game:IsShown() and Leading() then x, y = game:GetCenter() end
  if not (x and y) then
    shape:Hide()
    pointer:Hide()
    distance:SetText("")
    return
  end
  local scale = game:GetEffectiveScale() / UIParent:GetEffectiveScale()
  x, y = x * scale, y * scale
  marker:ClearAllPoints()
  marker:SetPoint("CENTER", UIParent, "BOTTOMLEFT", x, y)
  shape:Show()
  local Nav = _G.C_Navigation
  -- (out of sight, at the screen's edge: the little arrow on the side of
  -- the place, from the middle of the screen)
  if Nav and Nav.WasClampedToScreen and Nav.WasClampedToScreen() then
    local cx, cy = UIParent:GetCenter()
    local angle = math.atan2(y - cy, x - cx)
    local away = shape:GetWidth() * 0.75
    pointer:ClearAllPoints()
    pointer:SetPoint("CENTER", shape, "CENTER", math.cos(angle) * away, math.sin(angle) * away)
    pointer:SetRotation(angle - math.pi / 2)
    pointer:Show()
  else
    pointer:Hide()
  end
  local yards = Nav and Nav.GetDistance and Nav.GetDistance()
  local alpha = Toward(marker:GetAlpha(), SightAlpha(Nav or {}) * MouseAlpha() * NearAlpha(yards))
  if math.abs(marker:GetAlpha() - alpha) > 0.001 then marker:SetAlpha(alpha) end
  if yards and yards > 0 then
    local meters = Profile().navUnits == "meters"
    distance:SetText(("%d %s"):format(math.floor(meters and yards * 0.9144 or yards), meters and "m" or "yd"))
  else
    distance:SetText("")
  end
end)

-- The game's in-game navigation (its setting), which places the mark: on
-- while the option is, then back as it was (off, the game's own default,
-- if it was already on when the option was turned on)
local function GameNavigation(on)
  local SetCVar, GetCVar = _G.SetCVar, _G.GetCVar
  if not (SetCVar and GetCVar) then return end
  local profile = Profile()
  if on and GetCVar("showInGameNavigation") ~= "1" then
    profile.navWas = GetCVar("showInGameNavigation")
    pcall(SetCVar, "showInGameNavigation", "1")
  elseif not on then
    pcall(SetCVar, "showInGameNavigation", profile.navWas or "0")
    profile.navWas = nil
  end
end

-- (Marker "Default": the game's own mark, as it is)
local function Update()
  local profile = Profile()
  local own = profile.navMarker and STYLES[profile.navStyle] and true or false
  Look()
  HideGameMark(own)
  marker:SetShown(own)
end

Core:OnChange(function (key)
  if key == "enable" then
    local profile = Profile()
    if profile.navMarker then
      GameNavigation(true)
    elseif not profile.navChecked then
      -- (once: the option off but the game's navigation left on, from the
      -- tests before 0.2.1)
      GameNavigation(false)
    end
    profile.navChecked = true
    Update()
  elseif key == "navMarker" or key == "profile" then
    GameNavigation(Profile().navMarker)
    Update()
  elseif key == "navStyle" then
    Update()
  elseif key == "titleColor" or (type(key) == "string" and key:find("^nav")) then
    Look()
  end
end)
