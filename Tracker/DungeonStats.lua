local _, ns = ...
local Core = ns.Core

-- luacheck: push ignore 113
local CreateFrame = CreateFrame
local GameTooltip = GameTooltip
local GetTime = GetTime
-- luacheck: pop

local ASSETS = Core.ASSETS
local COIN = "Interface\\MoneyFrame\\UI-GoldIcon"
local SKULL = "Interface\\TargetingFrame\\UI-RaidTargetingIcon_8"
local ICON = 14
local PAD = 6           -- inside a chip
local CHIP_GAP = 6
local XP_COLOR = { 0.72, 0.45, 1.0 }   -- the experience bar's purple, lighter
local RED = { 1, 0.3, 0.25 }
local COUNT_TIME = 0.7  -- a number counting up to its new value
local FLOAT_TIME = 1.1  -- the "+120" rising over a chip
local POP_TIME = 0.35   -- an icon's little jump
local SHAKE_TIME = 0.5  -- the skull shaking when you die

----
-- DungeonStats
--
-- The run's experience, gold and deaths under the bosses' portraits, each in
-- a small dark chip with its icon:
-- - a new value counts up to itself, and a small "+120" rises over the chip
-- - the "XP" jumps; the coin jumps and shines
-- - a death makes the skull shake and turn red for a moment
-- - the mouse over a chip: the run's total and how much it makes per hour

local function Plain(number)
  number = math.floor(number + 0.5)
  return _G.BreakUpLargeNumbers and _G.BreakUpLargeNumbers(number) or tostring(number)
end

-- Gold, silver and copper, each number in its coin's color
local function Money(copper)
  local sign = copper < 0 and "-" or "+"
  copper = math.abs(math.floor(copper + 0.5))
  local gold, silver, rest = math.floor(copper / 10000), math.floor(copper / 100) % 100, copper % 100
  local parts = {}
  if gold > 0 then table.insert(parts, ("|cffffd100%sg|r"):format(Plain(gold))) end
  if gold > 0 or silver > 0 then table.insert(parts, ("|cffc7c7cf%ds|r"):format(silver)) end
  table.insert(parts, ("|cffeda55f%dc|r"):format(rest))
  return sign..table.concat(parts, " ")
end

local function PerHour(value, elapsed)
  if not elapsed or elapsed < 60 then return nil end
  return value / elapsed * 3600
end

local function Short(number)
  if number >= 10000 then return ("%.1fk"):format(number / 1000) end
  return Plain(number)
end

----
-- A chip

local chips = {}
local driver = CreateFrame("Frame")
driver:Hide()
local moving = {} -- chip -> true while something on it moves

local function Chip(card, key, icon, outline)
  if chips[key] then return chips[key] end
  local chip = CreateFrame("Frame", nil, card)
  chip:EnableMouse(true)
  -- A right click opens the card's menu (DungeonCard.lua)
  chip:SetScript("OnMouseUp", function (_, button)
    if button == "RightButton" and Core.DungeonMenu then Core.DungeonMenu() end
  end)
  chip.key = key

  chip.back = chip:CreateTexture(nil, "BACKGROUND")
  chip.back:SetTexture(ASSETS.."roundRect")
  if chip.back.SetTextureSliceMargins then chip.back:SetTextureSliceMargins(10, 10, 10, 10) end
  chip.back:SetAllPoints()
  chip.back:SetVertexColor(0, 0, 0, 0.5)

  chip.icon = Core.Smooth(chip:CreateTexture(nil, "ARTWORK"))
  chip.icon:SetTexture(icon)
  chip.icon:SetSize(ICON, ICON)
  chip.icon:SetPoint("LEFT", PAD, 0)
  -- The addon's own icons have a dark outline (the XP letters), like the
  -- tracker's other icons
  if outline then
    chip.outline = Core.Smooth(chip:CreateTexture(nil, "ARTWORK", nil, -1))
    chip.outline:SetTexture(outline)
    chip.outline:SetVertexColor(0, 0, 0, 0.9)
    chip.outline:SetAllPoints(chip.icon)
  end

  chip.shine = Core.Smooth(chip:CreateTexture(nil, "OVERLAY"))
  chip.shine:SetTexture(ASSETS.."circleSoft")
  chip.shine:SetBlendMode("ADD")
  chip.shine:SetPoint("CENTER", chip.icon, "CENTER")
  chip.shine:SetSize(ICON * 2.4, ICON * 2.4)
  chip.shine:SetAlpha(0)

  chip.text = chip:CreateFontString(nil, "OVERLAY")
  chip.text:SetFontObject(Core.fonts.line)
  chip.text:SetPoint("LEFT", chip.icon, "RIGHT", 4, 0)
  chip.text:SetTextColor(0.92, 0.92, 0.92)

  -- (measures the final value, so the chip has its size while counting)
  chip.measure = chip:CreateFontString(nil, "OVERLAY")
  chip.measure:SetFontObject(Core.fonts.line)
  chip.measure:SetAlpha(0)

  chip.float = chip:CreateFontString(nil, "OVERLAY")
  chip.float:SetFontObject(Core.fonts.zone)
  chip.float:SetAlpha(0)

  chip:SetScript("OnEnter", function (self)
    if not self.tooltip then return end
    GameTooltip:SetOwner(self, "ANCHOR_LEFT")
    for i, line in ipairs(self.tooltip()) do
      if i == 1 then
        GameTooltip:AddLine(line, Core:CardColor())
      else
        GameTooltip:AddLine(line, 0.85, 0.85, 0.85)
      end
    end
    GameTooltip:Show()
  end)
  chip:SetScript("OnLeave", function () GameTooltip:Hide() end)
  chips[key] = chip
  return chip
end

-- Shows `value` on a chip, counting up to it when it grows (`animate`)
local function SetValue(chip, value, animate)
  local before = chip.value
  chip.value = value
  if before == nil or not animate or value <= before then
    chip.shown, chip.countFrom, chip.countStart = value, nil, nil
    return before ~= nil and value > before
  end
  chip.countFrom, chip.countStart = chip.shown or before, GetTime()
  -- The rise of what came in
  chip.floatText = chip.format(value - before, true)
  chip.floatStart = GetTime()
  chip.popStart = GetTime()
  moving[chip] = true
  driver:Show()
  return true
end

local function Ease(k) return k * k * (3 - 2 * k) end

driver:SetScript("OnUpdate", function ()
  local now = GetTime()
  for chip in pairs(moving) do
    local busy = false
    -- Counting up
    if chip.countStart then
      local k = math.min(1, (now - chip.countStart) / COUNT_TIME)
      chip.shown = chip.countFrom + (chip.value - chip.countFrom) * Ease(k)
      chip.text:SetText(chip.format(chip.shown))
      if k >= 1 then chip.countStart = nil else busy = true end
    end
    -- The "+120" rising and fading
    if chip.floatStart then
      local k = (now - chip.floatStart) / FLOAT_TIME
      if k >= 1 then
        chip.floatStart = nil
        chip.float:SetAlpha(0)
      else
        chip.float:SetText(chip.floatText)
        chip.float:ClearAllPoints()
        chip.float:SetPoint("BOTTOM", chip, "TOP", 0, -2 + 14 * Ease(k))
        chip.float:SetAlpha(k < 0.2 and k / 0.2 or 1 - (k - 0.2) / 0.8)
        busy = true
      end
    end
    -- The icon's jump (and the coin's shine)
    if chip.popStart then
      local k = (now - chip.popStart) / POP_TIME
      if k >= 1 then
        chip.popStart = nil
        chip.icon:SetSize(ICON, ICON)
        chip.icon:SetPoint("LEFT", PAD, 0)
        chip.shine:SetAlpha(0)
      else
        local size = ICON * (1 + 0.35 * math.sin(math.pi * k))
        chip.icon:SetSize(size, size)
        chip.icon:SetPoint("LEFT", PAD - (size - ICON) / 2, 3 * math.sin(math.pi * k))
        if chip.key == "gold" then chip.shine:SetAlpha(0.7 * math.sin(math.pi * k)) end
        busy = true
      end
    end
    -- The skull shaking, red for a moment
    if chip.shakeStart then
      local k = (now - chip.shakeStart) / SHAKE_TIME
      if k >= 1 then
        chip.shakeStart = nil
        chip.icon:SetPoint("LEFT", PAD, 0)
        chip.icon:SetVertexColor(1, 1, 1)
      else
        chip.icon:SetPoint("LEFT", PAD + 3 * math.sin(k * math.pi * 8) * (1 - k), 0)
        local red = 1 - k
        chip.icon:SetVertexColor(1, 1 - (1 - RED[2]) * red, 1 - (1 - RED[3]) * red)
        busy = true
      end
    end
    if not busy then moving[chip] = nil end
  end
  if next(moving) == nil then driver:Hide() end
end)

local function Size(chip)
  chip.measure:SetText(chip.format(chip.value or 0))
  local width = PAD + ICON + 4 + math.max(20, chip.measure:GetStringWidth() or 20) + PAD
  -- (a little room ahead, so it doesn't jump while counting)
  chip:SetSize(math.ceil(width / 4) * 4 + 4, Core.db.profile.lineFontSize + 10)
end

----

---
-- The chips at `top` on the card; returns the room they take
function Core.PlaceDungeonStats(card, entry, top, width, animate)
  local x = 0
  local height = Core.db.profile.lineFontSize + 10

  -- Experience (not at the highest level)
  local xp = Chip(card, "xp", ASSETS.."xp", ASSETS.."xpOutline")
  xp.icon:SetVertexColor(XP_COLOR[1], XP_COLOR[2], XP_COLOR[3])
  xp.format = function (value, rising)
    local text = "+"..Plain(value)
    if rising or not entry.xpMax or entry.xpMax <= 0 then return text end
    return text..(" |cff999999%d%%|r"):format(math.floor(100 * value / entry.xpMax))
  end
  if entry.xp then
    SetValue(xp, entry.xp, animate)
    if not xp.countStart then xp.text:SetText(xp.format(entry.xp)) end
    xp.tooltip = function ()
      local lines = { "Experience", Plain(entry.xp).." this run" }
      if entry.xpMax and entry.xpMax > 0 then
        table.insert(lines, ("%d%% of a level"):format(math.floor(100 * entry.xp / entry.xpMax)))
      end
      local rate = PerHour(entry.xp, entry.elapsed)
      if rate then table.insert(lines, Short(rate).." per hour") end
      return lines
    end
    Size(xp)
    xp:Show()
  else
    xp:Hide()
  end

  -- Gold
  local gold = Chip(card, "gold", COIN)
  gold.format = function (value) return Money(value) end
  SetValue(gold, entry.copper, animate)
  if not gold.countStart then gold.text:SetText(Money(entry.copper)) end
  gold.tooltip = function ()
    local lines = { "Gold", Money(entry.copper).." this run" }
    local rate = PerHour(entry.copper, entry.elapsed)
    if rate and rate > 0 then table.insert(lines, Money(rate).." per hour") end
    return lines
  end
  Size(gold)
  gold:Show()

  -- Deaths (once you've died)
  local deaths = Chip(card, "deaths", SKULL)
  deaths.format = function (value) return tostring(math.floor(value + 0.5)) end
  if entry.deaths and entry.deaths > 0 then
    local before = deaths.value
    deaths.value = entry.deaths
    deaths.text:SetText(tostring(entry.deaths))
    if before and entry.deaths > before and animate then
      deaths.shakeStart = GetTime()
      moving[deaths] = true
      driver:Show()
    end
    -- Who died, and how many times (most first)
    deaths.tooltip = function ()
      local lines = { "Deaths" }
      local who = {}
      for name, count in pairs(entry.deathsBy or {}) do table.insert(who, { name = name, count = count }) end
      table.sort(who, function (a, b)
        if a.count ~= b.count then return a.count > b.count end
        return a.name < b.name
      end)
      for _, person in ipairs(who) do
        table.insert(lines, ("%s  |cffffffff%d|r"):format(person.name, person.count))
      end
      if #who == 0 then table.insert(lines, entry.deaths.." this run") end
      return lines
    end
    Size(deaths)
    deaths:Show()
  else
    deaths.value = 0
    deaths:Hide()
  end

  -- In the middle of the card, side by side
  local total = -CHIP_GAP
  for _, chip in ipairs({ xp, gold, deaths }) do
    if chip:IsShown() then total = total + chip:GetWidth() + CHIP_GAP end
  end
  x = (width - total) / 2
  for _, chip in ipairs({ xp, gold, deaths }) do
    if chip:IsShown() then
      chip:ClearAllPoints()
      chip:SetPoint("TOPLEFT", card, "TOPLEFT", x, -top)
      x = x + chip:GetWidth() + CHIP_GAP
    end
  end
  return height + 4
end

---
-- A new run: the chips start from their new values, without counting
function Core.ResetDungeonStats()
  for _, chip in pairs(chips) do
    chip.value, chip.shown, chip.countStart, chip.floatStart = nil, nil, nil, nil
    chip.float:SetAlpha(0)
  end
end
