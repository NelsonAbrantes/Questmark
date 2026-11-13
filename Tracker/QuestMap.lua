local _, ns = ...
local Core = ns.Core

-- luacheck: push ignore 113
local CreateFrame = CreateFrame
local C_Map = C_Map
local C_QuestLog = C_QuestLog
local GetCursorPosition = GetCursorPosition
-- luacheck: pop

local WIDTH, HEIGHT = 264, 176 -- the map: the size of its holder (QuestText.lua)
local PIN_SIZE = 26
local ARROW_SIZE = 24
local MAX_ZOOM = 5 -- over the zone all in view
local ZOOM_STEP = 1.25 -- each turn of the mouse wheel
local ZOOM_SPEED = 14 -- how fast the zoom glides there
local DRAG_START = 4 -- the mouse moves this much (pixels): a drag, not a click
local PLAYER_EVERY = 0.1 -- seconds between moves of your arrow
-- The game's quest ball (gold, as for the quest you follow) and what's on it
local BALL = "UI-QuestPoi-QuestNumber-SuperTracked"
local BALL_GOING = "Quest-In-Progress-Icon-Brown"
local BALL_DONE = "UI-QuestIcon-TurnIn-Normal"
-- The other quests in the zone: the game's plain quest ball, smaller
local OTHER_BALL = "UI-QuestPoi-QuestNumber"
local OTHER_GOING = "Quest-In-Progress-Icon-yellow"
local OTHER_SIZE = 18
local INK = { 0.22, 0.13, 0.06 }

local MapType = _G.Enum and _G.Enum.UIMapType or {}
local CONTINENT = MapType.Continent or 2

----
-- Quest map
--
-- A small map on the quest book's right page, with where the quest goes. The
-- tracker draws it itself from the zones' pictures: an addon opening the
-- game's map makes the game block parts of it later in a fight.
--
-- It shows the quest's zone (the parts not explored yet hidden, like on the
-- game's map), a mark on the quest's next place, the other quests taken
-- there, and an arrow for you. Only that zone: the mouse wheel zooms in
-- (never out past the whole zone), dragging moves it, right click shows the
-- whole zone again.

local map, canvas, pin, arrow, zone, top, edgeMask, zoneBack
local PlaceTapes -- (below)
-- The linen tape on the map's corners: its size (at least, and for the map's
-- size), and how far in it sits, for the map's size (where the torn edge's
-- corners are: Assets/mapMask)
local TAPE, TAPE_SIZE = 46, 0.15
local tapes, holds = {}, nil
local others = {} -- the other quests' balls, kept
local shownQuest -- the quest the map is for
local textures = {} -- the zones' pictures, kept
local usedTextures = 0
local shownMap, layerW, layerH -- the zone in the middle, its size in its pixels
local land -- its continent and where the zone is on it, or nil
local baseScale = 1 -- the canvas' scale with the zone all in view
local zoom, ox, oy = 1, 0, 0 -- the zoom, and where the view is on the zoomed canvas
local dragging -- the cursor and the view when the drag started
local zooming, GlideZoom -- a smooth zoom going: { to, x, y } (the place kept)
local questMap, questX, questY -- where the quest goes (questX nil: no place)
local questLand -- the same on its continent: { id, x, y }

----
-- Maps

-- The continent a map is in (nil for one out of any, like a dungeon's)
local function Continent(mapID)
  local info = C_Map.GetMapInfo(mapID)
  for _ = 1, 10 do
    if not info then return nil end
    if info.mapType == CONTINENT then return info.mapID end
    if not info.parentMapID or info.parentMapID == 0 then return nil end
    info = C_Map.GetMapInfo(info.parentMapID)
  end
  return nil
end

-- Where a map is on a continent: { id, minX, maxX, minY, maxY }, or nil
local function Rect(mapID, landID)
  if not (landID and landID ~= mapID and C_Map.GetMapRectOnMap) then return nil end
  local minX, maxX, minY, maxY = C_Map.GetMapRectOnMap(mapID, landID)
  if not (minX and maxX and maxX > minX and maxY > minY) then return nil end
  return { id = landID, minX = minX, maxX = maxX, minY = minY, maxY = maxY }
end

---
-- Where the quest goes: mapID, x, y (x and y nil if the zone has no place)
local function QuestPlace(questID)
  -- The next step first (it can be in another zone)
  if C_QuestLog.GetNextWaypoint then
    local mapID, x, y = C_QuestLog.GetNextWaypoint(questID)
    if mapID and x and y then return mapID, x, y end
  end
  local mapID = _G.GetQuestUiMapID and _G.GetQuestUiMapID(questID)
  if not mapID or mapID == 0 then return nil end
  for _, info in ipairs(C_QuestLog.GetQuestsOnMap and C_QuestLog.GetQuestsOnMap(mapID) or {}) do
    if info.questID == questID then return mapID, info.x, info.y end
  end
  return mapID
end

local function ArtLayer(mapID)
  local layers = C_Map.GetMapArtLayers and C_Map.GetMapArtLayers(mapID)
  local layer = layers and layers[1]
  local files = layer and C_Map.GetMapArtLayerTextures(mapID, 1)
  if files and #files > 0 then return layer, files end
  return nil
end

----
-- Drawing

-- The next picture piece
local function NextTexture(layer, sublevel)
  usedTextures = usedTextures + 1
  local texture = textures[usedTextures]
  if not texture then
    texture = canvas:CreateTexture()
    texture:AddMaskTexture(edgeMask)
    textures[usedTextures] = texture
  end
  texture:SetDrawLayer(layer, sublevel)
  texture:ClearAllPoints()
  texture:SetTexCoord(0, 1, 0, 1)
  texture:Show()
  return texture
end

---
-- A zone's picture on the canvas: its top left there and the size of its
-- pixels there (the middle zone's pixels are the canvas'); on top or under
local function DrawArt(mapID, left, top, size, onTop)
  local layer, files = ArtLayer(mapID)
  if not layer then return false end
  local base = onTop and 0 or -6

  local tileW, tileH = layer.tileWidth, layer.tileHeight
  local columns = math.ceil(layer.layerWidth / tileW)
  for i, file in ipairs(files) do
    local texture = NextTexture("BACKGROUND", base)
    local column, row = (i - 1) % columns, math.floor((i - 1) / columns)
    texture:SetSize(tileW * size, tileH * size)
    texture:SetPoint("TOPLEFT", left + column * tileW * size, -(top + row * tileH * size))
    texture:SetTexture(file, nil, nil, "TRILINEAR")
  end

  -- The parts explored (the zone's picture leaves them blank), as the game's
  -- map lays them out
  local explored = _G.C_MapExplorationInfo and _G.C_MapExplorationInfo.GetExploredMapTextures(mapID)
  for _, info in ipairs(explored or {}) do
    if not info.isShownByMouseOver then
      local wide = math.ceil(info.textureWidth / tileW)
      local tall = math.ceil(info.textureHeight / tileH)
      local sublevel = base + 1 + (info.isDrawOnTopLayer and 1 or 0)
      for j = 1, tall do
        local pixelH, fileH = tileH, tileH
        if j == tall then
          pixelH = info.textureHeight % tileH
          if pixelH == 0 then pixelH = tileH end
          fileH = 16
          while fileH < pixelH do fileH = fileH * 2 end
        end
        for k = 1, wide do
          local pixelW, fileW = tileW, tileW
          if k == wide then
            pixelW = info.textureWidth % tileW
            if pixelW == 0 then pixelW = tileW end
            fileW = 16
            while fileW < pixelW do fileW = fileW * 2 end
          end
          local texture = NextTexture("BACKGROUND", sublevel)
          texture:SetSize(pixelW * size, pixelH * size)
          texture:SetTexCoord(0, pixelW / fileW, 0, pixelH / fileH)
          texture:SetPoint("TOPLEFT", left + (info.offsetX + tileW * (k - 1)) * size,
            -(top + (info.offsetY + tileH * (j - 1)) * size))
          texture:SetTexture(info.fileDataIDs[(j - 1) * wide + k], nil, nil, "TRILINEAR")
        end
      end
    end
  end
  return true
end

----
-- The view

local function Scale() return baseScale * zoom end

-- A place on the middle zone (0 to 1) in the view (from its top left)
local function ZoneToView(x, y)
  local scale = Scale()
  return x * layerW * scale - ox, y * layerH * scale - oy
end

-- A place on the continent in the view
local function LandToView(x, y)
  return ZoneToView((x - land.minX) / (land.maxX - land.minX), (y - land.minY) / (land.maxY - land.minY))
end

---
-- Draws the map shown (a zone, or its continent)
local function DrawAll()
  usedTextures = 0
  DrawArt(shownMap, 0, 0, 1, true)
  for i = usedTextures + 1, #textures do textures[i]:Hide() end
end

---
-- Puts a mark at a place in the view; hidden when it's out of it. Near the
-- map's torn edge it fades out (the edge eats up to 7% of each side: Assets/
-- mapMask, 512 wide), so no mark sits on the page beside the map
local EDGE_GONE, EDGE_SHOWN = 22, 58 -- (in mapMask's 512 pixels from a side)
local function Place(region, px, py)
  if not px or px < 0 or py < 0 or px > WIDTH or py > HEIGHT then
    region:Hide()
    return false
  end
  local edge = math.min(math.min(px, WIDTH - px) / WIDTH, math.min(py, HEIGHT - py) / HEIGHT) * 512
  local alpha = math.max(0, math.min(1, (edge - EDGE_GONE) / (EDGE_SHOWN - EDGE_GONE)))
  if alpha <= 0 then
    region:Hide()
    return false
  end
  region:SetAlpha(alpha)
  region:ClearAllPoints()
  region:SetPoint("CENTER", map, "TOPLEFT", px, -py)
  region:Show()
  return true
end

-- Keeps the view on the continent (on the zone without one, centered if smaller)
local function Clamp(at, first, last, size)
  if last - first <= size then return (first + last - size) / 2 end
  return math.max(first, math.min(at, last - size))
end

-- You on the map (the game hides you in some places)
local function UpdatePlayer()
  local mapID = land and land.id or shownMap
  local position = mapID and C_Map.GetPlayerMapPosition(mapID, "player")
  local x, y
  if position then x, y = position:GetXY() end
  if not (Core.Readable(x) and Core.Readable(y)) or (x == 0 and y == 0) then
    arrow:Hide()
    return
  end
  local px, py
  if land then px, py = LandToView(x, y) else px, py = ZoneToView(x, y) end
  if Place(arrow, px, py) then
    local facing = _G.GetPlayerFacing and _G.GetPlayerFacing()
    arrow:SetRotation(Core.Readable(facing) and facing or 0)
  end
end

local function UpdatePin()
  local px, py
  if land and questLand and questLand.id == land.id then
    px, py = LandToView(questLand.x, questLand.y)
  elseif questLand and questLand.id == shownMap then
    px, py = ZoneToView(questLand.x, questLand.y) -- (the continent shown)
  elseif questX and questMap == shownMap then
    px, py = ZoneToView(questX, questY)
  end
  Place(pin, px, py)
  for _, ball in ipairs(others) do
    if ball.questID then Place(ball, ZoneToView(ball.x, ball.y)) end
  end
end

-- The other quests taken on the zone in the middle (a click opens them)
local function OtherBall(i)
  local ball = others[i]
  if ball then return ball end
  ball = CreateFrame("Button", nil, top)
  ball:SetSize(OTHER_SIZE, OTHER_SIZE)
  ball:SetFrameLevel(top:GetFrameLevel() + 1)
  ball.back = ball:CreateTexture(nil, "ARTWORK")
  ball.back:SetAllPoints()
  ball.icon = ball:CreateTexture(nil, "ARTWORK", nil, 1)
  ball.icon:SetPoint("CENTER")
  ball:SetScript("OnEnter", function (self)
    local tooltip = _G.GameTooltip
    tooltip:SetOwner(self, "ANCHOR_RIGHT")
    tooltip:SetText(C_QuestLog.GetTitleForQuestID(self.questID) or "")
    tooltip:Show()
  end)
  ball:SetScript("OnLeave", function () _G.GameTooltip:Hide() end)
  ball:SetScript("OnClick", function (self)
    if Core.BookOpenQuest then Core.BookOpenQuest(self.questID) end
  end)
  others[i] = ball
  return ball
end

local function FillOthers()
  local Atlas = _G.C_Texture and _G.C_Texture.GetAtlasInfo
  local n = 0
  for _, info in ipairs(C_QuestLog.GetQuestsOnMap and C_QuestLog.GetQuestsOnMap(shownMap) or {}) do
    if info.questID ~= shownQuest and info.x and info.y and C_QuestLog.GetLogIndexForQuestID(info.questID) then
      n = n + 1
      local ball = OtherBall(n)
      ball.questID, ball.x, ball.y = info.questID, info.x, info.y
      local done = C_QuestLog.IsComplete(info.questID)
      local inside = done and BALL_DONE or OTHER_GOING
      if Atlas and Atlas(OTHER_BALL) and Atlas(inside) then
        ball.back:SetAtlas(OTHER_BALL)
        ball.icon:SetAtlas(inside)
      else
        ball.back:SetTexture(Core.ASSETS.."circleFill")
        ball.back:SetVertexColor(INK[1], INK[2], INK[3])
        ball.icon:SetTexture(nil)
      end
      ball.icon:SetSize(OTHER_SIZE * (done and 0.85 or 0.6), OTHER_SIZE * (done and 0.85 or 0.6))
    end
  end
  for i = n + 1, #others do
    others[i].questID = nil
    others[i]:Hide()
  end
end

local function UpdateView()
  local scale = Scale()
  local zoneW, zoneH = layerW * scale, layerH * scale
  ox = Clamp(ox, 0, zoneW, WIDTH)
  oy = Clamp(oy, 0, zoneH, HEIGHT)
  canvas:SetScale(scale)
  canvas:ClearAllPoints()
  -- (a scaled frame's offsets are in its own scale)
  canvas:SetPoint("TOPLEFT", map, "TOPLEFT", -ox / scale, oy / scale)
  UpdatePin()
  UpdatePlayer()
end

---
-- Shows a map (a zone, or its continent), all in view
local function ShowZone(mapID)
  local layer = ArtLayer(mapID)
  if not layer then return false end
  shownMap = mapID
  zooming = nil
  layerW, layerH = layer.layerWidth, layer.layerHeight
  canvas:SetSize(layerW, layerH)
  land = Rect(mapID, Continent(mapID))
  -- (the zone fills the map: a zone of another shape is cut a little, never
  -- shown with empty edges)
  baseScale = math.max(WIDTH / layerW, HEIGHT / layerH)

  zoom = 1
  ox = (layerW * baseScale - WIDTH) / 2
  oy = (layerH * baseScale - HEIGHT) / 2

  local info = C_Map.GetMapInfo(mapID)
  zone:SetText(info and info.name or "")
  zone:SetTextColor(1.0, 0.82, 0.0)
  zoneBack:SetWidth(zone:GetStringWidth() + 60)
  FillOthers()
  UpdateView()
  DrawAll()
  return true
end

-- A step of the smooth zoom (1: all the way)
function GlideZoom(step)
  local new = zoom + (zooming.to - zoom) * step
  if math.abs(new - zooming.to) < 0.003 then new = zooming.to end
  ox = (zooming.x + ox) / zoom * new - zooming.x
  oy = (zooming.y + oy) / zoom * new - zooming.y
  zoom = new
  if new == zooming.to then zooming = nil end
  UpdateView()
end

-- The cursor on the map, from its top left
local function Cursor()
  local x, y = GetCursorPosition()
  local scale = map:GetEffectiveScale()
  return x / scale - map:GetLeft(), map:GetTop() - y / scale
end

-- The tape on the corners, for the map's size
function PlaceTapes()
  local size = math.max(TAPE, math.min(WIDTH, HEIGHT) * TAPE_SIZE)
  for _, tape in ipairs(tapes) do
    local at = tape.at
    tape:SetSize(size, size)
    tape:ClearAllPoints()
    tape:SetPoint("CENTER", map, at[1], at[2] * WIDTH, at[3] * HEIGHT)
  end
end

local function Build(holder)
  WIDTH, HEIGHT = holder:GetWidth(), holder:GetHeight()
  map = CreateFrame("Frame", nil, holder)
  map:SetPoint("TOPLEFT")
  map:SetSize(WIDTH, HEIGHT)
  map:SetClipsChildren(true)
  map:EnableMouse(true)
  map:EnableMouseWheel(true)
  map:Hide()

  -- A torn, scorched piece of an old map (Assets/mapMask and mapBurn, see
  -- Tools/mapedge.py) taped to the page
  edgeMask = map:CreateMaskTexture()
  edgeMask:SetTexture(Core.ASSETS.."mapMask", "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
  edgeMask:SetAllPoints()
  -- (shown with the map: the tape goes in it, below)
  local shade = CreateFrame("Frame", nil, holder)
  shade:SetAllPoints()
  shade:SetFrameLevel(holder:GetFrameLevel())
  shade:Hide()

  canvas = CreateFrame("Frame", nil, map)
  canvas:SetPoint("TOPLEFT")

  -- Above the zones' pictures (the canvas is a frame over the map's own)
  top = CreateFrame("Frame", nil, map)
  top:SetAllPoints()
  top:SetFrameLevel(canvas:GetFrameLevel() + 5)

  local burn = top:CreateTexture(nil, "BACKGROUND")
  burn:SetTexture(Core.ASSETS.."mapBurn")
  burn:SetAllPoints()

  -- Pieces of old linen tape across its corners, holding it to the
  -- page (Assets/tape, see Tools/tape.py; over its edge: in a frame of their
  -- own, so the map doesn't cut them)
  holds = CreateFrame("Frame", nil, holder)
  holds:SetAllPoints()
  holds:SetFrameLevel(map:GetFrameLevel() + 20)
  holds:Hide()
  -- (which corner, which way in and how far, in parts of the map's size:
  -- across the torn corner, half on it; the bottom right one is torn deeper;
  -- and the picture mirrored for the other corners)
  for _, at in ipairs({
    { "TOPLEFT", 0.045, -0.045, 0, 1, 0, 1 }, { "TOPRIGHT", -0.05, -0.05, 1, 0, 0, 1 },
    { "BOTTOMLEFT", 0.05, 0.05, 0, 1, 1, 0 }, { "BOTTOMRIGHT", -0.065, 0.065, 1, 0, 1, 0 },
  }) do
    local tape = Core.Smooth(holds:CreateTexture(nil, "ARTWORK"))
    tape:SetTexture(Core.ASSETS.."tape")
    tape:SetTexCoord(at[4], at[5], at[6], at[7])
    tape.at = at
    tapes[#tapes + 1] = tape
  end
  PlaceTapes()
  shade.holds = holds

  -- The zone's name, in the book's ink (a light glow behind, to read on the map)
  zone = top:CreateFontString(nil, "OVERLAY")
  zone:SetFontObject(Core.bookFonts.Zone)
  zone:SetPoint("TOP", 0, -8)
  -- (the quests' yellow with a dark shadow, over a soft dark patch, so it
  -- reads on any map)
  zone:SetShadowColor(0.12, 0.05, 0.0, 1)
  zone:SetShadowOffset(1, -1)
  zoneBack = Core.Smooth(top:CreateTexture(nil, "ARTWORK"))
  zoneBack:SetTexture(Core.ASSETS.."circleSoft")
  zoneBack:SetVertexColor(0, 0, 0, 0.55)
  zoneBack:SetPoint("CENTER", zone, "CENTER", 0, 0)
  zoneBack:SetHeight(34)

  -- The quest's place: the game's gold quest ball (with its "?" when the
  -- quest is done), over a soft pulsing glow; a ring and a dot in the title
  -- color if the game has no ball
  pin = CreateFrame("Frame", nil, top)
  pin:SetSize(PIN_SIZE, PIN_SIZE)
  pin:SetFrameLevel(top:GetFrameLevel() + 3)
  pin.glow = Core.Smooth(pin:CreateTexture(nil, "BACKGROUND"))
  pin.glow:SetTexture(Core.ASSETS.."circleSoft")
  pin.glow:SetBlendMode("ADD")
  pin.glow:SetPoint("CENTER")
  pin.glow:SetSize(PIN_SIZE * 2.6, PIN_SIZE * 2.6)
  pin.ring = Core.Smooth(pin:CreateTexture(nil, "ARTWORK"))
  pin.ring:SetTexture(Core.ASSETS.."circleRing")
  pin.ring:SetAllPoints()
  pin.dot = Core.Smooth(pin:CreateTexture(nil, "ARTWORK", nil, 1))
  pin.dot:SetTexture(Core.ASSETS.."circleFill")
  pin.dot:SetPoint("CENTER")
  pin.dot:SetSize(PIN_SIZE * 0.34, PIN_SIZE * 0.34)
  pin.ball = pin:CreateTexture(nil, "ARTWORK", nil, 2)
  pin.ball:SetPoint("CENTER")
  pin.ball:SetSize(PIN_SIZE, PIN_SIZE)
  pin.display = pin:CreateTexture(nil, "ARTWORK", nil, 3)
  pin.display:SetPoint("CENTER")
  local pulse = pin.glow:CreateAnimationGroup()
  pulse:SetLooping("BOUNCE")
  local fade = pulse:CreateAnimation("Alpha")
  fade:SetFromAlpha(1)
  fade:SetToAlpha(0.3)
  fade:SetDuration(0.9)
  fade:SetSmoothing("IN_OUT")
  pin.pulse = pulse

  arrow = top:CreateTexture(nil, "OVERLAY", nil, 7)
  arrow:SetTexture("Interface\\Minimap\\MinimapArrow")
  arrow:SetSize(ARROW_SIZE, ARROW_SIZE)
  arrow:Hide()

  -- Zoom on the cursor (the place under it stays under it)
  -- (never out past the whole zone: only the quest's zone shows)
  -- (smooth: the wheel sets where the zoom goes, and it glides there, the
  -- place under the mouse staying under it)
  map:SetScript("OnMouseWheel", function (_, delta)
    local target = math.max(1, math.min(MAX_ZOOM, (zooming and zooming.to or zoom) * ZOOM_STEP ^ delta))
    if target == zoom and not zooming then return end
    local mx, my = Cursor()
    zooming = { to = target, x = mx, y = my }
    if not Core:Animates() then GlideZoom(1) end
  end)
  map:SetScript("OnMouseDown", function (_, button)
    if button == "LeftButton" then
      local mx, my = Cursor()
      zooming = nil
      dragging = { mx, my, ox, oy }
    elseif button == "RightButton" then
      -- the whole zone in view again
      zooming = nil
      zoom = 1
      ox = (layerW * baseScale - WIDTH) / 2
      oy = (layerH * baseScale - HEIGHT) / 2
      UpdateView()
    end
  end)
  map:SetScript("OnMouseUp", function () dragging = nil end)

  local wait = 0
  map:SetScript("OnUpdate", function (_, elapsed)
    if dragging then
      local mx, my = Cursor()
      local dx, dy = mx - dragging[1], my - dragging[2]
      if not dragging.moved and dx * dx + dy * dy < DRAG_START * DRAG_START then return end
      dragging.moved = true
      ox, oy = dragging[3] - dx, dragging[4] - dy
      UpdateView()
      return
    end
    if zooming then GlideZoom(math.min(1, elapsed * ZOOM_SPEED)) end
    wait = wait - elapsed
    if wait > 0 then return end
    wait = PLAYER_EVERY
    UpdatePlayer()
  end)
  map:SetScript("OnShow", function () shade:Show() shade.holds:Show() end)
  map:SetScript("OnHide", function ()
    shade:Hide()
    shade.holds:Hide()
    pin.pulse:Stop()
    dragging, zooming = nil, nil
  end)
end

---
-- Shows the quest's map in `holder` (always the same frame, on the book's
-- page); hides it if the quest has no zone. True if it shows.
function Core.ShowQuestMap(questID, holder)
  if not map then Build(holder) end
  shownQuest = questID
  questMap, questX, questY = QuestPlace(questID)
  questLand = nil
  local where = questMap and questX and Rect(questMap, Continent(questMap))
  if where then
    questLand = {
      id = where.id,
      x = where.minX + questX * (where.maxX - where.minX),
      y = where.minY + questY * (where.maxY - where.minY),
    }
  end

  local r, g, b = Core:TitleColor()
  local Atlas = _G.C_Texture and _G.C_Texture.GetAtlasInfo
  local done = C_QuestLog.IsComplete(questID)
  local inside = done and BALL_DONE or BALL_GOING
  local ball = Atlas and Atlas(BALL) and Atlas(inside) and true or false
  if ball then
    pin.ball:SetAtlas(BALL)
    pin.display:SetAtlas(inside)
    pin.display:SetSize(PIN_SIZE * (done and 0.85 or 0.6), PIN_SIZE * (done and 0.85 or 0.6))
  end
  pin.ball:SetShown(ball)
  pin.display:SetShown(ball)
  pin.ring:SetShown(not ball)
  pin.dot:SetShown(not ball)
  pin.glow:SetVertexColor(r, g, b, 0.8)
  pin.ring:SetVertexColor(r, g, b)
  pin.dot:SetVertexColor(r, g, b)

  map:Show()
  if not (questMap and ShowZone(questMap)) then
    map:Hide()
    return false
  end
  if questX then
    -- Opens zoomed in on the quest's place (right click: the whole zone)
    -- (how close: Options, Quest book)
    zoom = Core.db.profile.bookMapZoom or 1
    local scale = Scale()
    ox = questX * layerW * scale - WIDTH / 2
    oy = questY * layerH * scale - HEIGHT / 2
    UpdateView()
    pin.pulse:Play()
  end
  return true
end

---
-- The map's size changed (Options): its holder's new size
function Core.QuestMapResize(width, height)
  if not map then return end
  WIDTH, HEIGHT = width, height
  map:SetSize(width, height)
  PlaceTapes()
end

---
-- The frame of the tape on its corners (the book puts it over its page's
-- dog-eared corner), once the map is made
function Core.QuestMapTapes()
  return holds
end

function Core.HideQuestMap()
  if map then map:Hide() end
end
