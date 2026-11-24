local _, ns = ...
local Core = ns.Core

-- luacheck: push ignore 113
local C_Map = C_Map
local CreateFrame = CreateFrame
local GetCursorPosition = GetCursorPosition
local date = date
-- luacheck: pop

----
-- Atlas
--
-- The book's green ribbon: the right page shows your own atlas. A continent's map printed faintly on the paper,
-- each zone washed in red ink, darker the more quests you turned in there,
-- with how many. Over a zone: its name, its quests, and when you were there.
-- The other continents by their names above it.
-- The counts are kept by Behavior/Diary.lua (Core.AtlasCounts).

local INK = { 0.22, 0.13, 0.06 }
local RED = { 0.48, 0.10, 0.04 }
local WASH = { 0.80, 0.16, 0.06 } -- (added to the paper: the game's zone shapes are white on black)
local FADED = { 0.30, 0.21, 0.12 }
local TOP = 70 -- the title, the line under it and the continents' names
local BOTTOM = 20 -- the hint under the map

local page, canvas, title, sub, hint
local tabs, tiles, washes, numbers = {}, {}, {}, {}
local continent -- the continent shown
local spots = {} -- continent -> its zones: { mapID, name, x, y } (where its wash is)

local function Enum(kind, fallback)
  return _G.Enum and _G.Enum.UIMapType and _G.Enum.UIMapType[kind] or fallback
end

-- The continent a map is on
local function ContinentOf(mapID)
  for _ = 1, 8 do
    local info = mapID and C_Map.GetMapInfo(mapID)
    if not info then return nil end
    if info.mapType == Enum("Continent", 2) then return mapID end
    mapID = info.parentMapID
  end
  return nil
end

-- The map right under the world a map is on, and the world: a continent,
-- or an island of its own (the Skyborn's Zephras Isle sits straight on
-- Azeroth, on no continent)
local function TopOf(mapID)
  for _ = 1, 8 do
    local info = mapID and C_Map.GetMapInfo(mapID)
    if not info then return nil end
    local parent = info.parentMapID and info.parentMapID > 0 and C_Map.GetMapInfo(info.parentMapID)
    if not parent or parent.mapType <= Enum("World", 1) then return mapID, parent and info.parentMapID end
    mapID = info.parentMapID
  end
  return nil
end

-- The continents, with a map to show (and the island you're on)
local function Continents()
  local list, seen = {}, {}
  local best = C_Map.GetBestMapForUnit("player")
  local top, world = TopOf(best)
  local here = ContinentOf(best) or top
  local found = C_Map.GetMapChildrenInfo(world or 947, Enum("Continent", 2)) or {}
  if #found == 0 then found = C_Map.GetMapChildrenInfo(946, Enum("Continent", 2), true) or {} end
  local function Add(mapID, name)
    local layers = mapID and C_Map.GetMapArtLayers(mapID)
    if not seen[mapID] and layers and layers[1] then
      seen[mapID] = true
      list[#list + 1] = { mapID = mapID, name = name }
    end
  end
  for _, info in ipairs(found) do Add(info.mapID, info.name) end
  if here and not seen[here] then
    local info = C_Map.GetMapInfo(here)
    Add(here, info and info.name)
  end
  return list, here
end

-- Its zones, and a spot inside each (the middle of its box, or the first
-- spot found on it)
local function Spots(mapID)
  if spots[mapID] then return spots[mapID] end
  local list = {}
  for _, zone in ipairs(C_Map.GetMapChildrenInfo(mapID, Enum("Zone", 3)) or {}) do
    local minX, maxX, minY, maxY = C_Map.GetMapRectOnMap(zone.mapID, mapID)
    if minX and maxX > minX then
      local spot
      for _, at in ipairs({ { 0.5, 0.5 }, { 0.35, 0.5 }, { 0.65, 0.5 }, { 0.5, 0.35 }, { 0.5, 0.65 },
        { 0.3, 0.3 }, { 0.7, 0.3 }, { 0.3, 0.7 }, { 0.7, 0.7 } }) do
        local x, y = minX + (maxX - minX) * at[1], minY + (maxY - minY) * at[2]
        local info = C_Map.GetMapInfoAtPosition(mapID, x, y)
        if info and info.mapID == zone.mapID then spot = { x, y } break end
      end
      if spot then list[#list + 1] = { mapID = zone.mapID, name = zone.name, x = spot[1], y = spot[2] } end
    end
  end
  -- (an island with no zones in it: itself, a mark in its middle)
  if #list == 0 then
    local info = C_Map.GetMapInfo(mapID)
    list[1] = { mapID = mapID, name = info and info.name, x = 0.5, y = 0.5 }
  end
  spots[mapID] = list
  return list
end

local function Get(pool, i, make)
  if not pool[i] then pool[i] = make() end
  return pool[i]
end

----
-- Drawing a continent

local function Draw()
  local width, height = page:GetWidth(), page:GetHeight() - TOP - BOTTOM
  local layers = C_Map.GetMapArtLayers(continent)
  local layer = layers and layers[1]
  for _, one in ipairs(tiles) do one:Hide() end
  for _, one in ipairs(washes) do one:Hide() end
  for _, one in ipairs(numbers) do one:Hide() end
  if not layer then return end
  -- (the whole map on the page, as big as it fits)
  local scale = math.min(width / layer.layerWidth, height / layer.layerHeight)
  local w, h = layer.layerWidth * scale, layer.layerHeight * scale
  canvas:SetSize(w, h)
  canvas:ClearAllPoints()
  canvas:SetPoint("TOP", page, "TOP", 0, -TOP)

  -- The map, faint, in the paper's brown
  local files = C_Map.GetMapArtLayerTextures(continent, 1) or {}
  local columns = math.ceil(layer.layerWidth / layer.tileWidth)
  local tw, th = layer.tileWidth * scale, layer.tileHeight * scale
  for i, file in ipairs(files) do
    local tile = Get(tiles, i, function ()
      local texture = canvas:CreateTexture(nil, "BACKGROUND")
      texture:SetDesaturated(true)
      texture:SetVertexColor(0.72, 0.58, 0.42, 0.55)
      return texture
    end)
    local column, row = (i - 1) % columns, math.floor((i - 1) / columns)
    tile:SetTexture(file, nil, nil, "TRILINEAR")
    tile:SetSize(tw, th)
    tile:ClearAllPoints()
    tile:SetPoint("TOPLEFT", canvas, "TOPLEFT", column * tw, -row * th)
    tile:Show()
  end

  -- Each zone in red ink, darker with more quests
  local counts = Core.AtlasCounts and Core.AtlasCounts() or {}
  local most, zones, quests = 1, 0, 0
  for _, spot in ipairs(Spots(continent)) do
    local n = counts[spot.mapID] and counts[spot.mapID].quests or 0
    if n > most then most = n end
  end
  local used = 0
  for _, spot in ipairs(Spots(continent)) do
    local n = counts[spot.mapID] and counts[spot.mapID].quests or 0
    if n > 0 then
      zones, quests = zones + 1, quests + n
      local file, atlasID, texX, texY, sizeX, sizeY, left, top =
        C_Map.GetMapHighlightInfoAtPosition(continent, spot.x, spot.y)
      used = used + 1
      local wash = Get(washes, used, function () return canvas:CreateTexture(nil, "ARTWORK") end)
      wash:ClearAllPoints()
      if (file and file > 0) or atlasID then
        if not (atlasID and pcall(wash.SetAtlas, wash, atlasID)) then wash:SetTexture(file, nil, nil, "TRILINEAR") end
        wash:SetTexCoord(0, texX or 1, 0, texY or 1)
        wash:SetSize(math.max(1, (sizeX or 0) * w), math.max(1, (sizeY or 0) * h))
        wash:SetPoint("TOPLEFT", canvas, "TOPLEFT", (left or 0) * w, -(top or 0) * h)
        -- (added, as the game's map does: its black is then nothing)
        wash:SetBlendMode("ADD")
        wash:SetVertexColor(WASH[1], WASH[2], WASH[3], 0.25 + 0.6 * math.sqrt(n / most))
      else
        -- (no shape for it: a round mark, added to the paper the same way,
        -- so its red says the same as the shapes': painted over, it looked
        -- deepest with few quests)
        wash:SetTexture(Core.ASSETS.."circleSoft")
        wash:SetTexCoord(0, 1, 0, 1)
        wash:SetSize(34, 34)
        wash:SetBlendMode("ADD")
        wash:SetPoint("CENTER", canvas, "TOPLEFT", spot.x * w, -spot.y * h)
        wash:SetVertexColor(WASH[1], WASH[2], WASH[3], 0.25 + 0.6 * math.sqrt(n / most))
      end
      wash:Show()
      local number = Get(numbers, used, function ()
        local text = canvas:CreateFontString(nil, "OVERLAY")
        text:SetFontObject(Core.bookFonts.Badge)
        text:SetTextColor(INK[1], INK[2], INK[3])
        return text
      end)
      number:SetText(n)
      number:ClearAllPoints()
      number:SetPoint("CENTER", canvas, "TOPLEFT", spot.x * w, -spot.y * h)
      number:Show()
    end
  end
  sub:SetText(zones == 0 and "No quests turned in here yet."
    or ("%d %s, %d %s"):format(zones, zones == 1 and "zone" or "zones", quests, quests == 1 and "quest" or "quests"))
  for _, tab in ipairs(tabs) do tab:Paint() end
end

----
-- Over a zone: its name and what you did there

local hovered
local function Hover()
  local scale = canvas:GetEffectiveScale()
  local x, y = GetCursorPosition()
  local left, top = canvas:GetLeft(), canvas:GetTop()
  if not (left and top) then return end
  x = (x / scale - left) / canvas:GetWidth()
  y = (top - y / scale) / canvas:GetHeight()
  local inside = x >= 0 and x <= 1 and y >= 0 and y <= 1
  local info = inside and C_Map.GetMapInfoAtPosition(continent, x, y)
  -- (an island on its own: the island itself)
  local only = Spots(continent)
  if inside and not info and #only == 1 and only[1].mapID == continent then info = C_Map.GetMapInfo(continent) end
  local mapID = info and info.mapID
  if mapID == hovered then return end
  hovered = mapID
  local tooltip = _G.GameTooltip
  if not info then
    tooltip:Hide()
    return
  end
  local kept = (Core.AtlasCounts and Core.AtlasCounts() or {})[mapID]
  tooltip:SetOwner(canvas, "ANCHOR_CURSOR")
  tooltip:SetText(info.name or "", 1, 0.82, 0)
  if kept and kept.quests > 0 then
    tooltip:AddLine(kept.quests == 1 and "1 quest turned in" or kept.quests.." quests turned in", 1, 1, 1)
    if kept.first and kept.last then
      local first, last = date("%d %b %Y", kept.first):gsub("^0", ""), date("%d %b %Y", kept.last):gsub("^0", "")
      tooltip:AddLine(first == last and first or first.." to "..last, 0.8, 0.8, 0.8)
    end
  else
    tooltip:AddLine("No quests turned in here", 0.7, 0.7, 0.7)
  end
  tooltip:Show()
end

----
-- Built the first time it shows

local function Build(parent)
  local fonts = Core.bookFonts
  page = CreateFrame("Frame", nil, parent)
  page:SetAllPoints(parent)

  title = page:CreateFontString(nil, "ARTWORK")
  title:SetFontObject(fonts.Title)
  title:SetTextColor(RED[1], RED[2], RED[3])
  title:SetPoint("TOP", 0, 0)
  title:SetText("Atlas")

  sub = page:CreateFontString(nil, "ARTWORK")
  sub:SetFontObject(fonts.Small)
  sub:SetTextColor(FADED[1], FADED[2], FADED[3])
  sub:SetPoint("TOP", title, "BOTTOM", 0, -2)

  canvas = CreateFrame("Frame", nil, page)
  canvas:EnableMouse(true)
  canvas:SetScript("OnEnter", function (self)
    hovered = nil
    self:SetScript("OnUpdate", Hover)
  end)
  canvas:SetScript("OnLeave", function (self)
    self:SetScript("OnUpdate", nil)
    hovered = nil
    _G.GameTooltip:Hide()
  end)

  hint = page:CreateFontString(nil, "ARTWORK")
  hint:SetFontObject(fonts.Small)
  hint:SetTextColor(FADED[1], FADED[2], FADED[3])
  hint:SetPoint("BOTTOM", 0, 0)
  hint:SetText("The more quests, the stronger the red")
end

local function Tabs(list)
  local fonts = Core.bookFonts
  local width = 0
  for i, info in ipairs(list) do
    local tab = Get(tabs, i, function ()
      local button = CreateFrame("Button", nil, page)
      button.label = button:CreateFontString(nil, "ARTWORK")
      button.label:SetFontObject(fonts.Button)
      button.label:SetPoint("CENTER")
      function button:Paint()
        local on = self.mapID == continent
        -- (padFocus: the controller on it, Tracker/BookPad.lua)
        local color = (on or self:IsMouseOver() or self.padFocus) and RED or FADED
        self.label:SetTextColor(color[1], color[2], color[3], on and 1 or 0.75)
      end
      button:SetScript("OnEnter", button.Paint)
      button:SetScript("OnLeave", button.Paint)
      button:SetScript("OnClick", function (self)
        continent = self.mapID
        Draw()
      end)
      return button
    end)
    tab.mapID = info.mapID
    tab.label:SetText(info.name)
    tab:SetSize(tab.label:GetStringWidth() + 12, 18)
    width = width + tab:GetWidth()
    tab:Show()
  end
  for i = #list + 1, #tabs do tabs[i]:Hide() end
  -- (side by side, under the title)
  local x = -width / 2
  for i = 1, #list do
    tabs[i]:ClearAllPoints()
    tabs[i]:SetPoint("TOPLEFT", page, "TOP", x, -44)
    x = x + tabs[i]:GetWidth()
  end
end

---
-- Shown on the book's right page (parent); false if the game has no maps
function Core.AtlasShow(parent)
  if not (C_Map and C_Map.GetMapArtLayers and C_Map.GetMapChildrenInfo) then return false end
  if not page then Build(parent) end
  local list, here = Continents()
  if #list == 0 then return false end
  -- (the one you're on, the first time)
  if not continent then
    continent = list[1].mapID
    for _, info in ipairs(list) do
      if info.mapID == here then continent = here end
    end
  end
  Tabs(list)
  page:Show()
  Draw()
  return true
end

-- Its continents' tabs shown, left to right (for the controller)
function Core.AtlasTabs()
  local list = {}
  if not (page and page:IsShown()) then return list end
  for _, tab in ipairs(tabs) do
    if tab:IsShown() then list[#list + 1] = tab end
  end
  return list
end

function Core.AtlasHide()
  if page then page:Hide() end
end
