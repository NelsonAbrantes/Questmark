local _, ns = ...
local Core = ns.Core

-- luacheck: push ignore 113
local CreateFrame = CreateFrame
local GetTime = GetTime
-- luacheck: pop

local ASSETS = Core.ASSETS
local FLAT = "Interface\\Buttons\\WHITE8x8"
local PARTICLES = 14

----
-- DungeonScene
--
-- A living scene behind the dungeon card's heading, after the dungeon
-- (DungeonTheme.lua): light dancing under water with waves and rising
-- bubbles, flames with embers, a green fog with wisps... It fades out at its
-- edges (most to the right) and stays faint, so the name reads over it. Made
-- of a tint, two layers that drift, and a few particles. It only moves while
-- the card shows and the tracker isn't faded out.

-- Each scene: two drifting layers (texture, opacity, drift in tiles per
-- second across and up, color) and its particles
local SCENES = {
  water = {
    tint = 0.35,
    layers = {
      { "sceneCaustics", 0.45, 0.025, 0.008, { 0.5, 0.85, 1 } },
      { "sceneWaves", 0.35, -0.06, 0, { 0.6, 0.9, 1 } },
    },
    particles = "bubble",
  },
  fire = {
    tint = 0.4,
    layers = {
      { "sceneClouds", 0.5, 0.015, 0.14, { 1, 0.45, 0.1 } },
      { "sceneClouds", 0.3, -0.03, 0.22, { 1, 0.75, 0.25 } },
    },
    particles = "ember",
  },
  scarlet = {
    tint = 0.35,
    layers = {
      { "sceneClouds", 0.4, 0.02, -0.01, { 0.9, 0.2, 0.15 } },
      { "sceneClouds", 0.2, -0.015, 0.01, { 1, 0.5, 0.4 } },
    },
    particles = "ash",
  },
  undead = {
    tint = 0.3,
    layers = {
      { "sceneClouds", 0.45, 0.03, 0.004, { 0.5, 0.9, 0.4 } },
      { "sceneClouds", 0.25, -0.02, -0.004, { 0.7, 1, 0.6 } },
    },
    particles = "wisp",
  },
  shadow = {
    tint = 0.35,
    layers = {
      { "sceneClouds", 0.45, 0.025, 0.006, { 0.55, 0.35, 1 } },
      { "sceneClouds", 0.25, -0.02, -0.005, { 0.8, 0.6, 1 } },
    },
    particles = "wisp",
  },
  nature = {
    tint = 0.3,
    layers = {
      { "sceneClouds", 0.35, 0.012, 0.004, { 0.45, 0.9, 0.4 } },
      { "sceneCaustics", 0.2, -0.01, 0.006, { 0.8, 1, 0.5 } },
    },
    particles = "firefly",
  },
  sand = {
    tint = 0.3,
    layers = {
      { "sceneClouds", 0.45, -0.12, 0.01, { 1, 0.8, 0.45 } },
      { "sceneClouds", 0.25, -0.2, -0.01, { 1, 0.9, 0.6 } },
    },
    particles = "sand",
  },
  arcane = {
    tint = 0.35,
    layers = {
      { "sceneClouds", 0.4, 0.02, 0.01, { 0.75, 0.45, 1 } },
      { "sceneCaustics", 0.25, -0.015, -0.006, { 0.9, 0.7, 1 } },
    },
    particles = "sparkle",
  },
  dust = {
    tint = 0.25,
    layers = {
      { "sceneClouds", 0.3, 0.01, 0.003, { 1, 0.85, 0.6 } },
      { "sceneClouds", 0.15, -0.008, -0.002, { 1, 0.95, 0.8 } },
    },
    particles = "dust",
  },
}

-- How each kind of particle starts (in the scene's width w and height h)
-- and moves: returns x, y, size, alpha for its age (t, seconds)
local KINDS = {
  bubble = {
    texture = "circleRing", color = { 0.75, 0.95, 1 }, life = { 2.5, 4.5 },
    start = function (p, w, h)
      p.x0, p.size, p.speed, p.wobble = math.random() * w * 0.75, 3 + math.random() * 3, 9 + math.random() * 9, math.random() * 6
    end,
    move = function (p, t, h)
      return p.x0 + 1.5 * math.sin(t * 3 + p.wobble), h - 2 - p.speed * t, p.size, 0.6 * math.min(1, t * 2)
    end,
  },
  ember = {
    texture = "circleSoft", color = { 1, 0.6, 0.2 }, life = { 1.2, 2.4 },
    start = function (p, w)
      p.x0, p.size, p.speed, p.drift = math.random() * w * 0.75, 2 + math.random() * 2.5, 14 + math.random() * 14, (math.random() - 0.5) * 10
    end,
    move = function (p, t, h)
      local flicker = 0.6 + 0.4 * math.sin(t * 18 + p.size * 7)
      return p.x0 + p.drift * t, h - p.speed * t, p.size, flicker * (1 - t / p.life)
    end,
  },
  ash = {
    texture = "circleSoft", color = { 0.95, 0.55, 0.5 }, life = { 3, 5 },
    start = function (p, w)
      p.x0, p.size, p.speed, p.drift = math.random() * w * 0.75, 1.5 + math.random() * 2, 5 + math.random() * 6, (math.random() - 0.5) * 8
    end,
    move = function (p, t)
      return p.x0 + p.drift * t + 3 * math.sin(t * 2), -2 + p.speed * t, p.size, 0.6 * math.sin(math.pi * t / p.life)
    end,
  },
  wisp = {
    texture = "circleSoft", color = { 1, 1, 1 }, life = { 4, 7 },
    start = function (p, w, h)
      p.x0, p.y0, p.size, p.speed = math.random() * w * 0.6, h * (0.2 + math.random() * 0.6), 10 + math.random() * 10, 4 + math.random() * 6
    end,
    move = function (p, t)
      return p.x0 + p.speed * t, p.y0 + 2 * math.sin(t * 0.9 + p.size), p.size, 0.25 * math.sin(math.pi * t / p.life)
    end,
    tinted = true,
  },
  firefly = {
    texture = "circleSoft", color = { 0.85, 1, 0.45 }, life = { 3, 6 },
    start = function (p, w, h)
      p.x0, p.y0, p.size, p.phase = math.random() * w * 0.7, h * (0.2 + math.random() * 0.6), 2 + math.random() * 1.5, math.random() * 6
    end,
    move = function (p, t)
      local blink = math.max(0, math.sin(t * 2.2 + p.phase)) ^ 2
      return p.x0 + 6 * math.sin(t * 0.7 + p.phase), p.y0 + 4 * math.sin(t * 1.1 + p.phase * 2), p.size, blink * math.sin(math.pi * t / p.life)
    end,
  },
  sand = {
    texture = "circleSoft", color = { 1, 0.85, 0.55 }, life = { 0.8, 1.6 }, stretch = 5,
    start = function (p, w, h)
      p.y0, p.size, p.speed = h * (0.15 + math.random() * 0.7), 1.5 + math.random(), 50 + math.random() * 40
    end,
    move = function (p, t)
      return -6 + p.speed * t, p.y0 + 2 * t, p.size, 0.5 * math.sin(math.pi * t / p.life)
    end,
  },
  sparkle = {
    texture = "circleSoft", color = { 0.95, 0.85, 1 }, life = { 1, 2.2 },
    start = function (p, w, h)
      p.x0, p.y0, p.size = math.random() * w * 0.7, h * (0.15 + math.random() * 0.7), 2 + math.random() * 2.5
    end,
    move = function (p, t)
      local k = math.sin(math.pi * t / p.life)
      return p.x0, p.y0 - 3 * t, p.size * (0.6 + 0.6 * k), k
    end,
  },
  dust = {
    texture = "circleSoft", color = { 1, 0.92, 0.75 }, life = { 4, 8 },
    start = function (p, w, h)
      p.x0, p.y0, p.size, p.vx, p.vy = math.random() * w * 0.7, h * (0.1 + math.random() * 0.8), 1.2 + math.random() * 1.5,
        (math.random() - 0.3) * 5, (math.random() - 0.5) * 3
    end,
    move = function (p, t)
      return p.x0 + p.vx * t, p.y0 + p.vy * t, p.size, 0.45 * math.sin(math.pi * t / p.life)
    end,
  },
}

local scene = { particles = {} }
local driver = CreateFrame("Frame")
driver:Hide()

local function Build(card)
  if scene.mask then return end
  scene.card = card
  scene.mask = card:CreateMaskTexture()
  scene.mask:SetTexture(ASSETS.."sceneMask", "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
  local function Layer(sublevel)
    local texture = card:CreateTexture(nil, "BACKGROUND", nil, sublevel)
    texture:AddMaskTexture(scene.mask)
    return texture
  end
  scene.tint = Layer(-8)
  scene.tint:SetTexture(FLAT)
  scene.layers = { Layer(-7), Layer(-6) }
  for i = 1, PARTICLES do
    local particle = Core.Smooth(Layer(-5))
    particle:SetBlendMode("ADD")
    scene.particles[i] = { texture = particle }
  end
end

local function Restart(p, now)
  local kind = scene.kind
  p.born = now + math.random() * 0.5
  p.life = kind.life[1] + math.random() * (kind.life[2] - kind.life[1])
  kind.start(p, scene.width, scene.height)
end

local lastFrame
driver:SetScript("OnUpdate", function ()
  local card = scene.card
  if not card or not card:IsVisible() then return end
  -- (nothing to see while the tracker is faded out)
  if Core.frame:GetEffectiveAlpha() < 0.05 then return end
  local now = GetTime()
  local elapsed = now - (lastFrame or now)
  lastFrame = now

  -- The layers drift
  for i, layer in ipairs(scene.layers) do
    local setup = scene.setup.layers[i]
    layer.u = ((layer.u or 0) + setup[3] * elapsed) % 1
    layer.v = ((layer.v or 0) + setup[4] * elapsed) % 1
    layer:SetTexCoord(layer.u, layer.u + layer.across, layer.v, layer.v + layer.down)
  end

  -- The particles live, die and start again
  local kind = scene.kind
  for _, p in ipairs(scene.particles) do
    local t = now - (p.born or 0)
    if not p.born or t > p.life then
      Restart(p, now)
      t = now - p.born
    end
    if t < 0 then
      p.texture:SetAlpha(0)
    else
      local x, y, size, alpha = kind.move(p, t, scene.height)
      p.texture:ClearAllPoints()
      p.texture:SetPoint("CENTER", card, "TOPLEFT", scene.left + x, scene.top - y)
      p.texture:SetSize(size * (kind.stretch or 1), size)
      p.texture:SetAlpha(math.max(0, math.min(1, alpha)))
    end
  end
end)

---
-- The scene behind the heading of `card`: `style` (DungeonTheme.lua), in
-- the dungeon's color, over `width` and `height` from the card's top left
function Core.PlaceDungeonScene(card, style, r, g, b, width, height)
  Build(card)
  local setup = SCENES[style] or SCENES.dust
  local left, top = -8, 6
  local sceneWidth, sceneHeight = width + 16, height + 10
  scene.left, scene.top, scene.width, scene.height = left, top, sceneWidth, sceneHeight

  scene.mask:ClearAllPoints()
  scene.mask:SetPoint("TOPLEFT", card, "TOPLEFT", left, top)
  scene.mask:SetSize(sceneWidth, sceneHeight)

  scene.tint:ClearAllPoints()
  scene.tint:SetAllPoints(scene.mask)
  scene.tint:SetVertexColor(r * 0.5, g * 0.5, b * 0.5, setup.tint)

  for i, layer in ipairs(scene.layers) do
    local layerSetup = setup.layers[i]
    layer:SetTexture(ASSETS..layerSetup[1], "REPEAT", "REPEAT")
    layer:SetBlendMode("ADD")
    local color = layerSetup[5]
    layer:SetVertexColor(color[1], color[2], color[3], layerSetup[2])
    layer:ClearAllPoints()
    layer:SetAllPoints(scene.mask)
    -- (the tile's own size on screen, however big the heading is)
    local tileWidth = layerSetup[1] == "sceneWaves" and 128 or 256
    local tileHeight = layerSetup[1] == "sceneWaves" and 32 or 64
    layer.across, layer.down = sceneWidth / tileWidth, sceneHeight / tileHeight
  end

  -- Another kind of scene: its particles start over
  local kind = KINDS[setup.particles]
  if scene.style ~= style then
    scene.style, scene.setup, scene.kind = style, setup, kind
    for _, p in ipairs(scene.particles) do
      p.texture:SetTexture(ASSETS..kind.texture)
      local color = kind.tinted and { Core.Lighter(r, g, b, 0.3) } or kind.color
      p.texture:SetVertexColor(color[1], color[2], color[3])
      p.born = nil
    end
  end
  scene.tint:Show()
  for _, layer in ipairs(scene.layers) do layer:Show() end
  for _, p in ipairs(scene.particles) do p.texture:Show() end
  driver:Show()
end

function Core.HideDungeonScene()
  driver:Hide()
  lastFrame = nil
  if not scene.mask then return end
  scene.tint:Hide()
  for _, layer in ipairs(scene.layers) do layer:Hide() end
  for _, p in ipairs(scene.particles) do p.texture:Hide() end
end
