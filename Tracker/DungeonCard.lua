local _, ns = ...
local Core = ns.Core

-- luacheck: push ignore 113
local CreateColor = CreateColor
local CreateFrame = CreateFrame
local GameTooltip = GameTooltip
local GetTime = GetTime
-- luacheck: pop

local FLAT = "Interface\\Buttons\\WHITE8x8"
local ASSETS = Core.ASSETS
local SKULL = "Interface\\TargetingFrame\\UI-RaidTargetingIcon_8"
local SIZE = 34          -- a portrait
local GAP = 8            -- between portraits
local DEATH_TIME = 2.0   -- the animation when a boss dies
local SPARKS = 10        -- the sparks flying off a boss that dies
local PUFFS = 8          -- the puffs of blue smoke, its soul leaving
local PUFF_TIME = 0.85   -- how long one puff lasts
local ENTER_TIME = 0.45  -- the card coming in
local POP_DELAY = 0.06   -- between one portrait and the next as the card comes in
local GREEN = { 0.45, 0.9, 0.5 }
local SILVER = { 0.75, 0.76, 0.80 }
local GREY = { 0.4, 0.4, 0.4 }

----
-- DungeonCard
--
-- The dungeon section, as a card:
-- - a heading in the dungeon's color: its icon, its name big with the zone
--   and levels under it, the icon faded into the background, and the run's
--   clock big on the right (green once every boss is dead)
-- - a portrait of each boss in a ring (the bosses don't have to be killed
--   in order). The mouse over one shows its name. When a boss dies, its
--   portrait is cut by a slash of light, shakes red, throws sparks, its
--   ghost rises out of it, glowing blue, as it turns grey, a scar stays across it and the
--   time it died at shows under it. Rare bosses come after the others,
--   under their own small title, with a silver ring.
-- - the experience, gold and deaths of the run (DungeonStats.lua)
-- The portraits come from the ForeverDungeonJournal addon when it's
-- installed; without it, a skull stands for each boss.

local frame = Core.content
local fonts = Core.fonts

local card = CreateFrame("Button", nil, frame)
card:RegisterForClicks("RightButtonUp")
card:Hide()
Core.dungeonCard = card

-- The heading, in the dungeon's color (DungeonTheme.lua):
-- - its icon in a ring on the left (from the journal addon)
-- - the name, big, and under it the zone and levels
-- - the same icon, big and faded into the background on the right
-- - a thin line under it all, fading out to the right
local HEAD_ICON = 30
local MARK_SIZE = 72

local function Masked(texture, mask)
  if not (card.CreateMaskTexture and texture.AddMaskTexture) then return end
  local maskTexture = card:CreateMaskTexture()
  maskTexture:SetTexture(mask, "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
  maskTexture:SetAllPoints(texture)
  texture:AddMaskTexture(maskTexture)
end

card.mark = Core.Smooth(card:CreateTexture(nil, "BACKGROUND"))
card.mark:SetSize(MARK_SIZE, MARK_SIZE)
card.mark:SetPoint("RIGHT", card, "TOPRIGHT", 10, 0)
Masked(card.mark, ASSETS.."circleSoft")

card.iconBack = card:CreateTexture(nil, "ARTWORK")
card.iconBack:SetTexture(ASSETS.."circleFill")
card.iconBack:SetVertexColor(0, 0, 0, 0.7)
card.iconBack:SetSize(HEAD_ICON, HEAD_ICON)
card.iconBack:SetPoint("TOPLEFT", 0, 0)
card.icon = Core.Smooth(card:CreateTexture(nil, "ARTWORK", nil, 1))
card.icon:SetSize(HEAD_ICON - 4, HEAD_ICON - 4)
card.icon:SetPoint("CENTER", card.iconBack, "CENTER")
Masked(card.icon, ASSETS.."circleFill")
card.iconRing = card:CreateTexture(nil, "OVERLAY")
card.iconRing:SetTexture(ASSETS.."circleRing")
card.iconRing:SetSize(HEAD_ICON, HEAD_ICON)
card.iconRing:SetPoint("CENTER", card.iconBack, "CENTER")

card.title = card:CreateFontString(nil, "OVERLAY")
card.title:SetFontObject(fonts.title)
card.title:SetJustifyH("LEFT")
card.title:SetWordWrap(false)

card.subtitle = card:CreateFontString(nil, "OVERLAY")
card.subtitle:SetFontObject(fonts.line)
card.subtitle:SetJustifyH("LEFT")
card.subtitle:SetWordWrap(false)
card.subtitle:SetTextColor(0.82, 0.82, 0.82)

card.clock = card:CreateFontString(nil, "OVERLAY")
card.clock:SetFontObject(fonts.title)
card.clock:SetJustifyH("RIGHT")

card.underline = card:CreateTexture(nil, "ARTWORK")
card.underline:SetTexture(FLAT)
Core.PixelHeight(card.underline, 1)

card.cells = {}

-- The rare bosses' title ("Rares"), with a thin line on each side
card.rareLabel = card:CreateFontString(nil, "OVERLAY")
card.rareLabel:SetFontObject(fonts.zone)
card.rareLabel:SetTextColor(0.75, 0.76, 0.80, 0.85)
card.rareLine = card:CreateTexture(nil, "ARTWORK")
card.rareLine:SetTexture(FLAT)
Core.PixelHeight(card.rareLine, 1)
card.rareLineLeft = card:CreateTexture(nil, "ARTWORK")
card.rareLineLeft:SetTexture(FLAT)
Core.PixelHeight(card.rareLineLeft, 1)

-- The game's silver dragon of rare creatures, on each side of the title,
-- facing it
local RARE_ICON = 14
local function RareIcon(mirrored)
  local icon = card:CreateTexture(nil, "OVERLAY")
  icon:SetSize(RARE_ICON, RARE_ICON)
  if not (icon.SetAtlas and pcall(icon.SetAtlas, icon, "nameplates-icon-elite-silver")
    and icon.GetAtlas and icon:GetAtlas()) then
    icon:SetTexture("Interface\\Tooltips\\EliteNameplateIcon")
    icon:SetVertexColor(SILVER[1], SILVER[2], SILVER[3])
  end
  if mirrored then icon:SetTexCoord(1, 0, 0, 1) end
  return icon
end
card.rareIconLeft = RareIcon(true)
card.rareIconRight = RareIcon(false)

local function Clock(seconds)
  seconds = math.max(0, math.floor(seconds or 0))
  local hours, minutes = math.floor(seconds / 3600), math.floor(seconds / 60) % 60
  if hours > 0 then return ("%d:%02d:%02d"):format(hours, minutes, seconds % 60) end
  return ("%d:%02d"):format(minutes, seconds % 60)
end

----
-- A boss's portrait

local function Cell(i)
  local cell = card.cells[i]
  if cell then return cell end
  cell = CreateFrame("Frame", nil, card)
  cell:SetSize(SIZE, SIZE)
  cell:EnableMouse(true)
  -- A right click opens the card's menu (passing the click on to the card is
  -- something the game blocks in combat)
  cell:SetScript("OnMouseUp", function (_, button)
    if button == "RightButton" then Core.DungeonMenu() end
  end)

  cell.back = cell:CreateTexture(nil, "BACKGROUND")
  cell.back:SetTexture(ASSETS.."circleFill")
  cell.back:SetVertexColor(0, 0, 0, 0.6)
  cell.back:SetPoint("CENTER")
  cell.back:SetSize(SIZE, SIZE)

  cell.portrait = Core.Smooth(cell:CreateTexture(nil, "ARTWORK"))
  cell.portrait:SetPoint("CENTER")

  cell.ring = Core.Smooth(cell:CreateTexture(nil, "OVERLAY", nil, 1))
  cell.ring:SetTexture(ASSETS.."circleRing")
  cell.ring:SetPoint("CENTER")

  cell.flash = Core.Smooth(cell:CreateTexture(nil, "OVERLAY", nil, 2))
  cell.flash:SetTexture(ASSETS.."circleSoft")
  cell.flash:SetBlendMode("ADD")
  cell.flash:SetPoint("CENTER")
  cell.flash:SetSize(SIZE * 1.7, SIZE * 1.7)
  cell.flash:SetAlpha(0)

  -- The kill: the slash of light, the scar it leaves (with a dark edge),
  -- the soul rising and the sparks
  cell.slash = Core.Smooth(cell:CreateTexture(nil, "OVERLAY", nil, 4))
  cell.slash:SetTexture(ASSETS.."slash")
  cell.slash:SetBlendMode("ADD")
  cell.slash:SetPoint("CENTER")
  cell.slash:SetSize(SIZE * 1.3, SIZE * 1.3)
  cell.slash:SetAlpha(0)

  cell.scarEdge = Core.Smooth(cell:CreateTexture(nil, "OVERLAY", nil, 3))
  cell.scarEdge:SetTexture(ASSETS.."scarOutline")
  cell.scarEdge:SetVertexColor(0, 0, 0, 0.85)
  cell.scarEdge:SetPoint("CENTER")
  cell.scarEdge:SetSize(SIZE * 0.95, SIZE * 0.95)
  cell.scar = Core.Smooth(cell:CreateTexture(nil, "OVERLAY", nil, 4))
  cell.scar:SetTexture(ASSETS.."scar")
  cell.scar:SetVertexColor(0.85, 0.12, 0.1)
  cell.scar:SetAllPoints(cell.scarEdge)

  -- The boss's ghost: its own face, white and blue and glowing, its edge
  -- melting away, with a blue light behind it
  cell.ghostGlow = Core.Smooth(cell:CreateTexture(nil, "OVERLAY", nil, 5))
  cell.ghostGlow:SetTexture(ASSETS.."circleSoft")
  cell.ghostGlow:SetBlendMode("ADD")
  cell.ghostGlow:SetVertexColor(0.3, 0.6, 1)
  cell.ghostGlow:SetAlpha(0)
  cell.ghost = Core.Smooth(cell:CreateTexture(nil, "OVERLAY", nil, 6))
  cell.ghost:SetBlendMode("ADD")
  cell.ghost:SetAlpha(0)
  if cell.CreateMaskTexture and cell.ghost.AddMaskTexture then
    local mask = cell:CreateMaskTexture()
    mask:SetTexture(ASSETS.."circleSoft", "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
    mask:SetAllPoints(cell.ghost)
    cell.ghost:AddMaskTexture(mask)
  end

  -- A soft trail of blue smoke under it as it rises
  cell.puffs = {}
  for n = 1, PUFFS do
    local puff = Core.Smooth(cell:CreateTexture(nil, "OVERLAY", nil, 5))
    puff:SetTexture(ASSETS..(n % 2 == 0 and "smoke2" or "smoke1"))
    puff:SetBlendMode("ADD")
    puff:SetVertexColor(0.35, 0.62, 1)
    puff:SetAlpha(0)
    puff.delay = 0.3 + (n - 1) * 0.07
    puff.drift = (math.random() - 0.5) * 16
    puff.rise = 24 + math.random() * 14
    puff.spin = (math.random() - 0.5) * 3
    puff.turn = math.random() * math.pi * 2
    puff.size = SIZE * (0.45 + math.random() * 0.2)
    cell.puffs[n] = puff
  end

  cell.sparks = {}
  for n = 1, SPARKS do
    local spark = Core.Smooth(cell:CreateTexture(nil, "OVERLAY", nil, 6))
    spark:SetTexture(ASSETS.."circleSoft")
    spark:SetBlendMode("ADD")
    spark:SetVertexColor(1, 0.8, 0.35)
    spark:SetAlpha(0)
    -- Each one its own way out, a little random
    spark.angle = (n / SPARKS) * math.pi * 2 + math.random() * 0.5
    spark.speed = 18 + math.random() * 16
    spark.size = 3 + math.random() * 3
    cell.sparks[n] = spark
  end

  cell.time = cell:CreateFontString(nil, "OVERLAY")
  cell.time:SetFontObject(fonts.zone)
  cell.time:SetPoint("TOP", cell, "BOTTOM", 0, -1)
  cell.time:SetTextColor(0.7, 0.7, 0.7)

  cell:SetScript("OnEnter", function (self)
    local boss = self.boss
    if not boss then return end
    GameTooltip:SetOwner(self, "ANCHOR_LEFT")
    local r, g, b = Core:CardColor()
    GameTooltip:AddLine(boss.name, r, g, b)
    if boss.rare then GameTooltip:AddLine("Rare", SILVER[1], SILVER[2], SILVER[3]) end
    if boss.killed then
      GameTooltip:AddLine(boss.killedAt and ("Killed at "..Clock(boss.killedAt)) or "Killed", 0.7, 0.7, 0.7)
    end
    GameTooltip:Show()
  end)
  cell:SetScript("OnLeave", function () GameTooltip:Hide() end)
  card.cells[i] = cell
  return cell
end

local function SetDesaturation(texture, amount)
  if texture.SetDesaturation then
    texture:SetDesaturation(amount)
  else
    texture:SetDesaturated(amount > 0.5)
  end
end

-- The portrait's look, `k` from alive (0) to dead (1), its size, how red
-- the hit still makes it (`hit`, 0 to 1) and how far it's shaken aside
local function Look(cell, k, scale, hit, shake)
  local boss = cell.boss
  local r, g, b = Core:CardColor()
  local ring = boss.rare and SILVER or { r, g, b }
  local size = SIZE * (scale or 1)
  cell.portrait:SetSize(size - 4, size - 4)
  cell.ring:SetSize(size, size)
  SetDesaturation(cell.portrait, k)
  local shade = (boss.rare and 0.85 or 1) * (1 - 0.35 * k)
  hit = hit or 0
  cell.portrait:SetVertexColor(shade, shade * (1 - 0.7 * hit), shade * (1 - 0.7 * hit), cell.hasPortrait and 1 or 0.7)
  cell.portrait:ClearAllPoints()
  cell.portrait:SetPoint("CENTER", cell, "CENTER", shake or 0, 0)
  cell.ring:SetVertexColor(
    ring[1] + (GREY[1] - ring[1]) * k, ring[2] + (GREY[2] - ring[2]) * k, ring[3] + (GREY[3] - ring[3]) * k,
    boss.rare and 0.7 or 0.95)
end

local function Quiet(cell)
  cell.flash:SetAlpha(0)
  cell.slash:SetAlpha(0)
  for _, puff in ipairs(cell.puffs) do puff:SetAlpha(0) end
  cell.ghost:SetAlpha(0)
  cell.ghostGlow:SetAlpha(0)
  for _, spark in ipairs(cell.sparks) do spark:SetAlpha(0) end
end

local function Dead(cell)
  Look(cell, 1)
  Quiet(cell)
  cell.scar:SetAlpha(1)
  cell.scarEdge:SetAlpha(0.85)
  cell.scar:Show()
  cell.scarEdge:Show()
  cell.time:SetAlpha(1)
end

local function Alive(cell)
  Look(cell, 0)
  Quiet(cell)
  cell.scar:Hide()
  cell.scarEdge:Hide()
  cell.time:SetText("")
end

----
-- Animations: a boss dying, the card coming in

local dying = {}  -- cell -> start time
local popping = {} -- cell -> start time (the card coming in)
local entering    -- start time of the card's entrance
local driver = CreateFrame("Frame")
driver:Hide()

local function Ease(k) return k * k * (3 - 2 * k) end
local function Part(t, from, length) return math.max(0, math.min(1, (t - from) / length)) end

driver:SetScript("OnUpdate", function ()
  local now = GetTime()
  for cell, start in pairs(dying) do
    local t = now - start
    if t >= DEATH_TIME or not cell.boss then
      dying[cell] = nil
      cell:SetFrameLevel(card:GetFrameLevel() + 1)
      if cell.boss then Dead(cell) end
    else
      -- 1. The slash: a blade of light cuts across, from the top right
      local cut = Part(t, 0, 0.18)
      local slashAlpha = t < 0.18 and Ease(cut) or 1 - Part(t, 0.18, 0.25)
      cell.slash:SetAlpha(slashAlpha)
      cell.slash:ClearAllPoints()
      cell.slash:SetPoint("CENTER", cell, "CENTER", 10 * (1 - Ease(cut)), 10 * (1 - Ease(cut)))
      -- 2. The hit: a flash, the portrait jolting and red for a moment
      local flash = t < 0.1 and t / 0.1 or 1 - Part(t, 0.1, 0.35)
      cell.flash:SetAlpha(0.6 * flash)
      local hit = 1 - Part(t, 0.12, 0.5)
      local shake = 3 * math.sin(t * 60) * (1 - Part(t, 0.1, 0.35))
      -- 4. ...turning grey and dark as its soul leaves
      Look(cell, Ease(Part(t, 0.35, 0.6)), 1 + 0.12 * math.sin(math.pi * math.min(1, t / 0.25)), hit, shake)
      -- 3. The sparks, flying out and falling a little
      local fly = Part(t, 0.12, 0.7)
      for _, spark in ipairs(cell.sparks) do
        if fly > 0 and fly < 1 then
          local distance = spark.speed * Ease(fly)
          spark:ClearAllPoints()
          spark:SetPoint("CENTER", cell, "CENTER",
            math.cos(spark.angle) * distance, math.sin(spark.angle) * distance - 6 * fly * fly)
          spark:SetSize(spark.size * (1 - 0.5 * fly), spark.size * (1 - 0.5 * fly))
          spark:SetAlpha(1 - fly)
        else
          spark:SetAlpha(0)
        end
      end
      -- 4. The ghost: it lifts out of the portrait, grows a little, sways
      -- and fades as it goes up, its blue light with it
      local up = Part(t, 0.3, 1.5)
      if up > 0 and up < 1 then
        local lift = 44 * Ease(up)
        local sway = 3 * math.sin(up * math.pi * 2)
        local size = (SIZE - 4) * (1.1 + 0.8 * Ease(up))
        -- (bright for longer before it fades)
        local light = up < 0.15 and up / 0.15 or (up < 0.45 and 1 or 1 - (up - 0.45) / 0.55)
        cell.ghost:ClearAllPoints()
        cell.ghost:SetPoint("CENTER", cell, "CENTER", sway, lift)
        cell.ghost:SetSize(size, size)
        cell.ghost:SetAlpha(light)
        cell.ghostGlow:ClearAllPoints()
        cell.ghostGlow:SetPoint("CENTER", cell.ghost, "CENTER")
        cell.ghostGlow:SetSize(size * 2.2, size * 2.2)
        cell.ghostGlow:SetAlpha(0.85 * light)
      else
        cell.ghost:SetAlpha(0)
        cell.ghostGlow:SetAlpha(0)
      end
      -- ...and a soft trail of blue smoke under it: each puff rises, drifts
      -- aside, swirls, spreads and fades
      for _, puff in ipairs(cell.puffs) do
        local k = Part(t, puff.delay, PUFF_TIME)
        if k > 0 and k < 1 then
          puff:ClearAllPoints()
          puff:SetPoint("CENTER", cell, "CENTER", puff.drift * Ease(k), puff.rise * Ease(k))
          local size = puff.size * (1 + 1.4 * k)
          puff:SetSize(size, size)
          if puff.SetRotation then puff:SetRotation(puff.turn + puff.spin * k) end
          local light = k < 0.2 and k / 0.2 or 1 - (k - 0.2) / 0.8
          puff:SetAlpha(0.5 * light)
        else
          puff:SetAlpha(0)
        end
      end
      -- 5. The scar where the blade went, appearing as the light goes
      local scar = Part(t, 0.15, 0.3)
      cell.scar:SetAlpha(scar)
      cell.scarEdge:SetAlpha(0.85 * scar)
      cell.scar:Show()
      cell.scarEdge:Show()
      cell.time:SetAlpha(Part(t, 0.8, 0.3))
    end
  end
  for cell, start in pairs(popping) do
    local k = Part(now - start, 0, 0.3)
    cell:SetAlpha(Ease(k))
    if k >= 1 then popping[cell] = nil end
  end
  if entering then
    local k = math.min(1, (now - entering) / ENTER_TIME)
    card:SetAlpha(Ease(k))
    card.slide = 20 * (1 - Ease(k))
    card:SetPoint("TOPLEFT", frame, "TOPLEFT", card.slide, -card.y)
    if k >= 1 then entering = nil end
  end
  if next(dying) == nil and next(popping) == nil and not entering then driver:Hide() end
end)

----

function Core.SetDungeonClock(entry)
  if not card:IsShown() then return end
  card.clock:SetText(Clock(entry.elapsed))
  if entry.finished then
    card.clock:SetTextColor(GREEN[1], GREEN[2], GREEN[3])
  else
    card.clock:SetTextColor(1, 1, 1)
  end
end

local function SetPortrait(cell, boss)
  local key = boss.display or "skull"
  if cell.portraitKey == key then return end
  cell.portraitKey = key
  cell.hasPortrait = false
  local draw = _G.SetPortraitTextureFromCreatureDisplayID
  if boss.display and draw and pcall(draw, cell.portrait, boss.display) then
    cell.portrait:SetTexCoord(0, 1, 0, 1)
    cell.hasPortrait = true
    pcall(draw, cell.ghost, boss.display)
  else
    cell.portrait:SetTexture(SKULL)
    cell.ghost:SetTexture(SKULL)
  end
  -- White and blue, like a spirit
  if cell.ghost.SetDesaturation then cell.ghost:SetDesaturation(1) else cell.ghost:SetDesaturated(true) end
  cell.ghost:SetVertexColor(0.75, 0.92, 1)
end

---
-- Lays the card out at `y` from the top of the tracker; returns its height.
-- `isNew`: it just appeared (its entrance plays).
function Core.PlaceDungeonCard(entry, y, isNew)
  local profile = Core.db.profile
  local width = frame:GetWidth()
  local r, g, b = Core:CardColor()
  local animate = Core:Animates()
  card.entry, card.y = entry, y
  card:ClearAllPoints()
  card:SetPoint("TOPLEFT", frame, "TOPLEFT", card.slide or 0, -y)
  card:SetWidth(width)
  card:Show()

  -- The heading, in the dungeon's color
  local tr, tg, tb, style = Core.DungeonTheme(entry.title, entry.icon)
  local hasIcon = entry.icon ~= nil
  card.icon:SetTexture(entry.icon)
  card.mark:SetTexture(entry.icon)
  card.mark:SetAlpha(0.22)
  card.mark:SetShown(hasIcon)
  card.icon:SetShown(hasIcon)
  card.iconBack:SetShown(hasIcon)
  card.iconRing:SetShown(hasIcon)
  card.iconRing:SetVertexColor(tr, tg, tb, 0.95)
  local left = hasIcon and HEAD_ICON + 8 or 0

  -- A dungeon with wings ("Scarlet Monastery: Library"): the dungeon big,
  -- the wing under it. (Nothing under it otherwise: the zone and the levels
  -- made the heading too busy.)
  local name, subtitle = entry.title, nil
  local whole, wing = name:match("^(.-):%s*(.+)$")
  if whole and wing and whole ~= "" then name, subtitle = whole, wing end
  local titleSize = profile.headerFontSize + 4
  local headHeight = math.max(hasIcon and HEAD_ICON or 0, titleSize + (subtitle and profile.lineFontSize + 3 or 0)) + 2

  card.title:ClearAllPoints()
  card.title:SetPoint("TOPLEFT", card, "TOPLEFT", left, subtitle and 0 or -(headHeight - titleSize) / 2)
  card.title:SetFontObject(fonts.title)
  card.title:SetText(name)
  card.title:SetTextColor(Core.Lighter(tr, tg, tb, 0.3))
  card.subtitle:ClearAllPoints()
  card.subtitle:SetPoint("TOPLEFT", card.title, "BOTTOMLEFT", 0, -2)
  card.subtitle:SetText(subtitle or "")
  card.subtitle:SetShown(subtitle ~= nil)

  card.clock:ClearAllPoints()
  card.clock:SetPoint("RIGHT", card, "TOPRIGHT", 0, -headHeight / 2)
  Core.SetDungeonClock(entry)
  local room = math.max(40, width - left - (card.clock:GetStringWidth() or 40) - 12)
  card.title:SetWidth(room)
  card.subtitle:SetWidth(room)
  -- A name too long for the room: its letters a little smaller, down to the
  -- names' size (past that it's cut, with "...")
  local file, size, flags = fonts.title:GetFont()
  if file and size then
    local smallest = profile.headerFontSize - 1
    local function Wide()
      local text = card.title
      return (text.GetUnboundedStringWidth and text:GetUnboundedStringWidth() or text:GetStringWidth()) or 0
    end
    while Wide() > room and size > smallest do
      size = size - 1
      card.title:SetFont(file, size, flags)
    end
  end
  card.mark:ClearAllPoints()
  card.mark:SetPoint("CENTER", card, "TOPRIGHT", -24, -headHeight / 2)

  card.underline:ClearAllPoints()
  card.underline:SetPoint("TOPLEFT", card, "TOPLEFT", 0, -(headHeight + 3))
  card.underline:SetPoint("TOPRIGHT", card, "TOPRIGHT", 0, -(headHeight + 3))
  card.underline:SetGradient("HORIZONTAL", CreateColor(tr, tg, tb, 0.7), CreateColor(tr, tg, tb, 0))
  -- The living scene behind the heading (water, fire, fog...)
  Core.PlaceDungeonScene(card, style, tr, tg, tb, width, headHeight)
  local top = headHeight + 16

  -- The portraits, in rows: the bosses, then the rare ones under their own
  -- small title with a thin line, like the zones
  local timeHeight = Core.ZoneFontSize() + 3
  local rowHeight = SIZE + timeHeight + 4
  local columns = math.max(1, math.floor((width + GAP) / (SIZE + GAP)))
  local groups = { {}, {} }
  for _, boss in ipairs(entry.bosses) do
    table.insert(boss.rare and groups[2] or groups[1], boss)
  end
  local shown = 0
  local rareShown = false
  for group, bosses in ipairs(groups) do
    if #bosses > 0 then
      if group == 2 then
        -- (the rare ones' title, after the bosses)
        if shown > 0 then top = top + 6 end
        -- (its text set here: the fonts aren't ready while the files load)
        card.rareLabel:SetText("Rares")
        -- In the middle, a thin line fading out to each side
        card.rareLabel:ClearAllPoints()
        card.rareLabel:SetPoint("TOP", card, "TOPLEFT", width / 2, -top)
        -- (each line hangs from the title only, so both sit at its middle)
        local lineWidth = math.max(1, (width - (card.rareLabel:GetStringWidth() or 0)) / 2 - RARE_ICON - 10)
        card.rareIconLeft:ClearAllPoints()
        card.rareIconLeft:SetPoint("RIGHT", card.rareLabel, "LEFT", -3, 0)
        card.rareIconRight:ClearAllPoints()
        card.rareIconRight:SetPoint("LEFT", card.rareLabel, "RIGHT", 3, 0)
        card.rareLine:ClearAllPoints()
        card.rareLine:SetPoint("LEFT", card.rareIconRight, "RIGHT", 4, 0)
        card.rareLine:SetWidth(lineWidth)
        card.rareLine:SetGradient("HORIZONTAL", CreateColor(SILVER[1], SILVER[2], SILVER[3], 0.4),
          CreateColor(SILVER[1], SILVER[2], SILVER[3], 0))
        card.rareLineLeft:ClearAllPoints()
        card.rareLineLeft:SetPoint("RIGHT", card.rareIconLeft, "LEFT", -4, 0)
        card.rareLineLeft:SetWidth(lineWidth)
        card.rareLineLeft:SetGradient("HORIZONTAL", CreateColor(SILVER[1], SILVER[2], SILVER[3], 0),
          CreateColor(SILVER[1], SILVER[2], SILVER[3], 0.4))
        card.rareLabel:Show()
        card.rareLine:Show()
        card.rareLineLeft:Show()
        card.rareIconLeft:Show()
        card.rareIconRight:Show()
        rareShown = true
        top = top + Core.ZoneFontSize() + 12
      end
      for j, boss in ipairs(bosses) do
        shown = shown + 1
        local cell = Cell(shown)
        local before = cell.boss
        cell.boss = boss
        local column, row = (j - 1) % columns, math.floor((j - 1) / columns)
        -- Each row in the middle of the card
        local inRow = math.min(columns, #bosses - row * columns)
        local rowWidth = inRow * SIZE + (inRow - 1) * GAP
        cell:ClearAllPoints()
        cell:SetPoint("TOPLEFT", card, "TOPLEFT", (width - rowWidth) / 2 + column * (SIZE + GAP),
          -(top + row * rowHeight))
        SetPortrait(cell, boss)
        cell.time:SetText(boss.killed and boss.killedAt and Clock(boss.killedAt) or "")
        -- Just died: its animation; else how it is
        local justDied = boss.killed and before and before.name == boss.name and not before.killed
        if justDied and animate then
          dying[cell] = GetTime()
          -- (above the other portraits while its ghost rises over them)
          cell:SetFrameLevel(card:GetFrameLevel() + 10)
          driver:Show()
        elseif not dying[cell] then
          if boss.killed then Dead(cell) else Alive(cell) end
        end
        if isNew and animate then
          cell:SetAlpha(0)
          popping[cell] = GetTime() + ENTER_TIME * 0.4 + (shown - 1) * POP_DELAY
        elseif not popping[cell] then
          cell:SetAlpha(1)
        end
        cell:Show()
      end
      top = top + math.ceil(#bosses / columns) * rowHeight
    end
  end
  if not rareShown then
    card.rareLineLeft:Hide()
    card.rareIconLeft:Hide()
    card.rareIconRight:Hide()
    card.rareLabel:Hide()
    card.rareLine:Hide()
  end
  for i = shown + 1, #card.cells do
    local cell = card.cells[i]
    cell.boss = nil
    dying[cell], popping[cell] = nil, nil
    cell:Hide()
  end
  if shown > 0 then top = top + 8 end -- (a little room before the experience and gold)

  -- Experience, gold, deaths
  if isNew then Core.ResetDungeonStats() end
  top = top + Core.PlaceDungeonStats(card, entry, top, width, animate and not isNew)

  -- Every boss dead: the light passes over the name
  if entry.finished and card.wasFinished == false and animate then
    Core:Changed("questComplete", card)
  end
  card.wasFinished = entry.finished

  if isNew and animate then
    card:SetAlpha(0)
    card.slide = 20
    entering = GetTime()
    driver:Show()
  elseif not entering then
    card:SetAlpha(1)
    card.slide = 0
  end

  card:SetHeight(top)
  return top
end

function Core.HideDungeonCard()
  if not card:IsShown() then return end
  card:Hide()
  Core.HideDungeonScene()
  card.wasFinished = nil
  entering = nil
  Core.ResetDungeonStats()
  wipe(dying)
  wipe(popping)
  for _, cell in ipairs(card.cells) do cell.boss = nil end
end

-- The card's menu (a right click on it, a portrait or a chip)
function Core.DungeonMenu()
  local MenuUtil = _G.MenuUtil
  if not (MenuUtil and MenuUtil.CreateContextMenu) then return end
  MenuUtil.CreateContextMenu(card, function (_, root)
    root:CreateTitle(card.entry and card.entry.title or "Dungeon")
    root:CreateButton("Start the run again", Core.RestartDungeonRun)
  end)
end
card:SetScript("OnClick", Core.DungeonMenu)
