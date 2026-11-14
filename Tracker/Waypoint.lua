local _, ns = ...
local Core = ns.Core

-- luacheck: push ignore 113
local C_Map = C_Map
local C_SuperTrack = C_SuperTrack
local C_Timer = C_Timer
local CreateFrame = CreateFrame
local CreateVector2D = CreateVector2D
local GetPlayerFacing = GetPlayerFacing
local UIParent = UIParent
-- luacheck: pop

----
-- The quest GPS (Options: Quest GPS): with a quest followed (its icon in
-- the tracker clicked), an arrow on the screen points the way to it, with
-- how far it is. It leads to the quest's next step (a place, or the one
-- who takes it back), even in another zone; to the zone itself when the
-- game doesn't know the place. Drag it to move it; a right click stops
-- following the quest. Not in dungeons (the game doesn't tell where you
-- are there). Nothing runs while no quest is followed.

local EVERY = 0.1    -- where the quest is from you: 10 times a second
-- (the arrow turns every frame, with where you face then: smooth)
local ARRIVED = 10   -- yards: there

local frame = CreateFrame("Frame", "QuestmarkGPS", UIParent)
frame:SetClampedToScreen(true)
frame:SetMovable(true)
frame:EnableMouse(true)
frame:RegisterForDrag("LeftButton")
frame:Hide()

local arrow = Core.Smooth(frame:CreateTexture(nil, "ARTWORK"))
arrow:SetPoint("TOP")

local font = CreateFont("QuestmarkGPSFont")
font:SetFont("Fonts\\FRIZQT__.TTF", 13, "OUTLINE")
local small = CreateFont("QuestmarkGPSSmall")
small:SetFont("Fonts\\FRIZQT__.TTF", 10, "OUTLINE")

local distance = frame:CreateFontString(nil, "OVERLAY")
distance:SetFontObject(font)
distance:SetPoint("TOP", arrow, "BOTTOM", 0, -1)

local name = frame:CreateFontString(nil, "OVERLAY")
name:SetFontObject(small)
name:SetPoint("TOP", distance, "BOTTOM", 0, -2)
name:SetWidth(220)
name:SetWordWrap(false)
name:SetTextColor(0.8, 0.8, 0.8)

local function Profile() return Core.db.profile end

-- Its look (Options: GPS arrow, size, text size, color)
local STYLES = { arrow = "gpsArrow", chevron = "gpsChevron", double = "gpsDouble",
  triangle = "gpsTriangle", needle = "gpsNeedle", dart = "gpsDart" }

local function Look()
  local profile = Profile()
  local size = profile.gpsSize or 44
  local text = profile.gpsTextSize or 13
  arrow:SetTexture(Core.ASSETS..(STYLES[profile.gpsStyle] or STYLES.arrow))
  arrow:SetSize(size, size)
  font:SetFont("Fonts\\FRIZQT__.TTF", text, "OUTLINE")
  small:SetFont("Fonts\\FRIZQT__.TTF", math.max(8, text - 3), "OUTLINE")
  name:SetShown(profile.gpsQuestName ~= false)
  frame:SetSize(math.max(160, size), size + text * 2 + 10)
  local r, g, b = Core:Color(profile.gpsColor)
  if not r then r, g, b = Core:TitleColor() end
  arrow:SetVertexColor(r, g, b)
end

local function Place()
  local at = Profile().gpsPosition
  frame:ClearAllPoints()
  if at then
    frame:SetPoint(at.point, UIParent, at.point, at.x, at.y)
  else
    frame:SetPoint("TOP", UIParent, "TOP", 0, -120)
  end
end

frame:SetScript("OnDragStart", frame.StartMoving)
frame:SetScript("OnDragStop", function (self)
  self:StopMovingOrSizing()
  local point, _, _, x, y = self:GetPoint()
  Profile().gpsPosition = { point = point, x = x, y = y }
end)
frame:SetScript("OnMouseUp", function (self, button)
  if button == "RightButton" and self.questID and Core.FollowQuest then Core.FollowQuest(self.questID) end
end)
frame:SetScript("OnEnter", function (self)
  GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
  GameTooltip:AddLine("Quest GPS")
  GameTooltip:AddLine("Drag to move it. Right click: stop following the quest", 0.8, 0.8, 0.8, true)
  GameTooltip:Show()
end)
frame:SetScript("OnLeave", function () GameTooltip:Hide() end)

-- Where it leads: the quest's map and place there (the middle of the zone
-- when the game doesn't know the place)
local target = {}

local function Retarget()
  local questID = C_SuperTrack and C_SuperTrack.GetSuperTrackedQuestID and C_SuperTrack.GetSuperTrackedQuestID()
  local on = Profile().gpsArrow and Core.trackerOn ~= false
  local mapID, x, y
  if on and questID and questID > 0 and Core.QuestPlace then mapID, x, y = Core.QuestPlace(questID) end
  if not mapID then
    frame.questID = nil
    frame:Hide()
    return
  end
  target.map, target.zoneOnly = mapID, not (x and y)
  target.x, target.y = x or 0.5, y or 0.5
  local info = C_Map.GetMapInfo(mapID)
  target.zone = info and info.name or ""
  frame.questID = questID
  local title = C_QuestLog.GetTitleForQuestID and C_QuestLog.GetTitleForQuestID(questID)
  name:SetText(title or "")
  frame:Show()
end

-- The target on the player's map (nil if it's on another continent)
local function TargetOn(mapID)
  if mapID == target.map then return target.x, target.y end
  if not (C_Map.GetWorldPosFromMapPos and C_Map.GetMapPosFromWorldPos and CreateVector2D) then return nil end
  local continent, world = C_Map.GetWorldPosFromMapPos(target.map, CreateVector2D(target.x, target.y))
  if not continent or not world then return nil end
  local _, place = C_Map.GetMapPosFromWorldPos(continent, world, mapID)
  if not place then return nil end
  return place:GetXY()
end

local function Say(text)
  arrow:Hide()
  distance:SetText(text)
end

local since = EVERY
local bearing -- where the quest is, from the north (nil: no arrow)
local shown   -- the arrow's turn now, gliding to the right one

local function Turn(elapsed)
  local facing = bearing and GetPlayerFacing and GetPlayerFacing()
  if not facing then return end
  local want = bearing - facing
  if not shown then shown = want end
  -- (the short way round, gliding the rest of the way quickly)
  local gap = (want - shown + math.pi) % (2 * math.pi) - math.pi
  shown = shown + gap * math.min(1, elapsed * 18)
  arrow:SetRotation(shown)
end

local function Measure()
  bearing = nil
  local mapID = C_Map.GetBestMapForUnit("player")
  local at = mapID and C_Map.GetPlayerMapPosition(mapID, "player")
  local facing = GetPlayerFacing and GetPlayerFacing()
  if not (at and facing) then return Say("") end
  local px, py = at:GetXY()
  local tx, ty = TargetOn(mapID)
  local width, height = C_Map.GetMapWorldSize(mapID)
  if not (tx and ty and width and width > 0) then return Say(target.zone) end
  -- (yards east and south of you; the arrow turns from where you face)
  local east, south = (tx - px) * width, (ty - py) * height
  local yards = math.sqrt(east * east + south * south)
  if target.zoneOnly and mapID == target.map then return Say(target.zone) end
  if yards < ARRIVED then
    arrow:Show()
    arrow:SetRotation(0)
    shown = nil
    arrow:SetAlpha(0.35)
    distance:SetText("Here")
    return
  end
  arrow:SetAlpha(1)
  arrow:Show()
  bearing = math.atan2(-east, -south)
  -- (Options: in yards or meters)
  local meters = Profile().gpsUnits == "meters"
  distance:SetText(("%s%d %s"):format(target.zoneOnly and "~" or "", math.floor(meters and yards * 0.9144 or yards),
    meters and "m" or "yd"))
end

frame:SetScript("OnUpdate", function (_, elapsed)
  since = since + elapsed
  if since >= EVERY then
    since = 0
    Measure()
  end
  Turn(elapsed)
end)

-- A new target a moment after the quests change (they change in bursts)
local pending = false
local function Soon()
  if pending then return end
  pending = true
  C_Timer.After(0.3, function ()
    pending = false
    Retarget()
  end)
end

local events = CreateFrame("Frame")
events:SetScript("OnEvent", Soon)

Core:OnChange(function (key)
  if key == "enable" then
    Place()
    Look()
    for _, event in ipairs({ "SUPER_TRACKING_CHANGED", "QUEST_LOG_UPDATE", "ZONE_CHANGED_NEW_AREA",
      "PLAYER_ENTERING_WORLD", "QUEST_POI_UPDATE", "WAYPOINT_UPDATE" }) do
      pcall(events.RegisterEvent, events, event)
    end
    Retarget()
  elseif key == "gpsArrow" or key == "profile" then
    if key == "profile" then Place() Look() end
    Retarget()
  elseif key == "titleColor" or (type(key) == "string" and key:find("^gps")) then
    Look()
  end
end)
