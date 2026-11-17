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
  quest = "navQuest", faction = "navDiamond" }

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
  if not crest then
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
  -- (close to the place, see-through: the mark in the way of what's there)
  local alpha = 1
  if yards and yards < FAR then
    alpha = NEAR_ALPHA + (1 - NEAR_ALPHA) * math.max(0, yards - NEAR) / (FAR - NEAR)
  end
  if math.abs(marker:GetAlpha() - alpha) > 0.01 then marker:SetAlpha(alpha) end
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
