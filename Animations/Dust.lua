local _, ns = ...
local Core = ns.Core

-- luacheck: push ignore 113
local CreateFrame = CreateFrame
local GetTime = GetTime
local C_Timer = C_Timer
local C_QuestLog = C_QuestLog
local wipe = wipe
local geterrorhandler = geterrorhandler
-- luacheck: pop

local FLAT = "Interface\\Buttons\\WHITE8x8"
local DISSOLVE_TIME = 1.1     -- seconds for a text to turn to dust
local LINE_STAGGER = 0.08     -- each line starts a little after the one above
local SOFT_EDGE = 4           -- letters fading at the dissolving edge
local PARTICLES_PER_SECOND = 140 -- per text, while it dissolves
local MAX_PARTICLES = 220

----
-- Dust
--
-- Abandoning a quest (Animations: Glass): the quest turns to dust, like a
-- snap of the fingers. The game takes the quest out of the tracker right
-- after saying it was removed, so at that moment the addon takes a picture of
-- it (texts, colors, places), draws a copy where it was and blows that away:
-- the letters vanish from right to left while specks in their color drift
-- off to the right and up. Nothing runs until a quest is abandoned.

local tracker = Core.frame

----
-- Pictures of a quest (taken the moment the game says it was abandoned,
-- while it's still in the tracker)
local function Readable(value)
  return value ~= nil and not (issecretvalue and issecretvalue(value))
end

-- How visible a text is inside the tracker: its own transparency times its
-- line's (completed objectives can be dimmed)
local function Alpha(text)
  local parent = text:GetParent()
  local alpha = (text:GetAlpha() or 1) * (parent and parent.GetAlpha and parent:GetAlpha() or 1)
  return Readable(alpha) and alpha or 1
end

local function TextItem(text)
  if not text or not text:IsVisible() then return nil end
  local value = text:GetText()
  if not Readable(value) or value == "" then return nil end
  local left, top = text:GetLeft(), text:GetTop()
  local tLeft, tTop = tracker:GetLeft(), tracker:GetTop()
  if not (left and top and tLeft and tTop) then return nil end
  local file, size, flags = text:GetFont()
  local r, g, b = text:GetTextColor()
  return {
    text = value, file = file, size = size, flags = flags,
    r = r, g = g, b = b, alpha = Alpha(text),
    x = left - tLeft, y = top - tTop, width = text:GetWidth(), stringWidth = text:GetStringWidth(),
    height = text:GetHeight(),
  }
end

-- The quest's block in the tracker, if it's shown
local function FindBlock(questID)
  local block = Core.FindBlock(questID)
  return block and block:IsVisible() and block or nil
end

-- A picture of a quest: its name and objectives, top to bottom
local function TakePicture(questID)
  local block = FindBlock(questID)
  if not block then return nil end
  local items = {}
  local header = TextItem(block.title)
  if header then table.insert(items, header) end
  local lines = {}
  for _, line in pairs(block.lines.used) do table.insert(lines, line) end
  table.sort(lines, function (a, b) return (a:GetTop() or 0) > (b:GetTop() or 0) end)
  for _, line in ipairs(lines) do
    local item = TextItem(line.Text)
    if item then table.insert(items, item) end
  end
  return #items > 0 and { items = items } or nil
end

----
-- Which quests were turned in (those don't turn to dust)

local turnedIn = {}

----
-- The dust

-- On the screen itself, placed over the tracker but not inside it: when the
-- abandoned quest was the last one shown, the tracker hides (or fades out)
-- right away, and the dust went with it
local stage = CreateFrame("Frame", nil, _G.UIParent)
stage:SetAllPoints(tracker)

-- Same layer and size as the tracker, worked out when the dust starts (Edit
-- Mode can change them)
local function PlaceStage()
  stage:SetFrameStrata(tracker:GetFrameStrata())
  stage:SetFrameLevel(tracker:GetFrameLevel() + 20)
  local scale = tracker:GetEffectiveScale() / _G.UIParent:GetEffectiveScale()
  if scale > 0 then stage:SetScale(scale) end
  stage:ClearAllPoints()
  stage:SetAllPoints(tracker)
end

local texts, particles = {}, {}
local active = {}   -- running effects: { start, items }
local liveParticles = {}

local function GetText(i)
  if not texts[i] then
    texts[i] = stage:CreateFontString(nil, "OVERLAY")
    texts[i]:SetJustifyH("LEFT")
    texts[i]:SetJustifyV("TOP")
    texts[i]:SetWordWrap(true)
  end
  return texts[i]
end

local function SpawnParticle(x, y, r, g, b)
  if #liveParticles >= MAX_PARTICLES then return end
  local speck = table.remove(particles) or Core.Smooth(stage:CreateTexture(nil, "OVERLAY"))
  speck:SetTexture(FLAT)
  local size = 1 + math.random() * 2
  speck:SetSize(size, size)
  -- A little lighter or darker than the text, like grains of sand
  local shade = 0.8 + math.random() * 0.4
  speck:SetVertexColor(math.min(1, r * shade), math.min(1, g * shade), math.min(1, b * shade))
  speck:Show()
  table.insert(liveParticles, {
    texture = speck, x = x, y = y,
    vx = 25 + math.random() * 55, vy = 8 + math.random() * 35,
    life = 0.6 + math.random() * 0.6, age = 0,
  })
end

local REVEAL_TIME = 0.3   -- the quests below fade back in over this
local hiddenBlocks = {}   -- quest blocks kept hidden while the dust flies
local hideTop             -- quests from this height down are hidden (tracker coordinates)
local revealStart

-- Hides the quests at or below where the abandoned quest was: the game moves
-- them up into its place at once, under the dust
local function HideQuestsBelow()
  local trackerTop = tracker:GetTop()
  if not hideTop or not trackerTop then return end
  local limit = trackerTop + hideTop + 1
  for _, block in pairs(Core.ShownBlocks()) do
    local top = block:IsVisible() and block:GetTop()
    if top and top <= limit and not hiddenBlocks[block] then
      hiddenBlocks[block] = true
      block:SetAlpha(0)
    end
  end
end

local usedTexts = 0
local driver = CreateFrame("Frame")
driver:Hide()
local lastUpdate = GetTime()

driver:SetScript("OnUpdate", function ()
  local now = GetTime()
  local elapsed = now - lastUpdate
  lastUpdate = now

  for effect in pairs(active) do
    local finished = true
    for _, item in ipairs(effect.items) do
      local t = now - effect.start - item.delay
      local text = item.fontString
      if t < 0 then
        finished = false
      elseif t < DISSOLVE_TIME then
        finished = false
        local progress = t / DISSOLVE_TIME
        -- Letters go from the right: show only up to this one
        local shown = math.floor(item.length * (1 - progress))
        text:SetAlphaGradient(shown, SOFT_EDGE)
        -- Specks fly off where the letters are going
        local count = math.random() < (PARTICLES_PER_SECOND * elapsed) % 1 and 1 or 0
        count = count + math.floor(PARTICLES_PER_SECOND * elapsed)
        local frontX = item.x + item.stringWidth * (1 - progress)
        for _ = 1, count do
          SpawnParticle(frontX + math.random() * 6, item.y - math.random() * item.height, item.r, item.g, item.b)
        end
      else
        text:Hide()
      end
    end
    if finished then active[effect] = nil end
  end

  for i = #liveParticles, 1, -1 do
    local speck = liveParticles[i]
    speck.age = speck.age + elapsed
    if speck.age >= speck.life then
      speck.texture:Hide()
      table.insert(particles, speck.texture)
      table.remove(liveParticles, i)
    else
      speck.x = speck.x + speck.vx * elapsed
      speck.y = speck.y + speck.vy * elapsed
      speck.vy = speck.vy + 10 * elapsed -- drifts up a little more as it goes
      speck.texture:ClearAllPoints()
      speck.texture:SetPoint("CENTER", stage, "TOPLEFT", speck.x, speck.y)
      speck.texture:SetAlpha(0.9 * (1 - speck.age / speck.life))
    end
  end

  -- The quests that move up into the abandoned one's place stay hidden while
  -- it turns to dust, then fade in
  if next(active) ~= nil then
    HideQuestsBelow()
  elseif next(hiddenBlocks) ~= nil then
    revealStart = revealStart or now
    local progress = math.min(1, (now - revealStart) / REVEAL_TIME)
    for block in pairs(hiddenBlocks) do block:SetAlpha(progress) end
    if progress >= 1 then
      wipe(hiddenBlocks)
      revealStart = nil
    end
  end

  if next(active) == nil and #liveParticles == 0 and next(hiddenBlocks) == nil then
    usedTexts = 0
    hideTop = nil
    driver:Hide()
  end
end)

-- Letters that show (color codes and links don't)
local function VisibleLength(value)
  local plain = value:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|cn.-:", ""):gsub("|r", "")
    :gsub("|H.-|h(.-)|h", "%1"):gsub("|T.-|t", "x"):gsub("|A.-|a", "x")
  -- Letters, not bytes: accented, Cyrillic or Asian letters take 2 to 3 bytes
  local _, letters = plain:gsub("[^\128-\191]", "")
  return math.max(1, letters)
end

local function Snap(picture)
  PlaceStage()
  local effect = { start = GetTime(), items = {} }
  for i, item in ipairs(picture.items) do
    usedTexts = usedTexts + 1
    local text = GetText(usedTexts)
    text:SetFont(item.file, item.size, item.flags)
    text:SetTextColor(item.r, item.g, item.b)
    text:SetAlpha(item.alpha)
    text:ClearAllPoints()
    text:SetPoint("TOPLEFT", stage, "TOPLEFT", item.x, item.y)
    text:SetWidth(item.width)
    text:SetText(item.text)
    text:SetAlphaGradient(#item.text + SOFT_EDGE, 1)
    text:Show()
    table.insert(effect.items, {
      fontString = text, length = VisibleLength(item.text), delay = (i - 1) * LINE_STAGGER,
      x = item.x, y = item.y, height = item.height, stringWidth = math.min(item.stringWidth, item.width),
      r = item.r, g = item.g, b = item.b,
    })
  end
  active[effect] = true
  -- The tracker waits while it turns to dust: the quest's place stays empty
  -- (the quest itself hidden under its copy), then what's under it glides up
  -- into it (Tracker.lua)
  if Core.HoldLayout then
    Core.HoldLayout(DISSOLVE_TIME + (#picture.items - 1) * LINE_STAGGER + 0.1)
  end
  revealStart = nil
  lastUpdate = GetTime()
  driver:Show()
  if Core.Reveal then Core.Reveal() end -- shows the tracker while it happens
end

----

local events = CreateFrame("Frame")
events:SetScript("OnEvent", function (_, event, questID)
  if not questID then return end
  if event == "QUEST_TURNED_IN" then
    turnedIn[questID] = GetTime()
  elseif event == "QUEST_REMOVED" then
    -- Turned in, not abandoned: the game may say so a moment after this, so
    -- it's decided a moment later (the tracker waits meanwhile, the quest
    -- still in it for its picture). A quest the game marks as done was
    -- turned in too.
    local flagged = C_QuestLog and C_QuestLog.IsQuestFlaggedCompleted
    if flagged and flagged(questID) then return end
    if not Core:Animates() then
      Core:AnimLog("quest removed, no dust: animations are off", tostring(questID))
      return
    end
    if Core.HoldLayout then Core.HoldLayout(0.2) end
    C_Timer.After(0.08, function ()
      local turned = turnedIn[questID]
      turnedIn[questID] = nil
      if turned and GetTime() - turned < 2 then return end
      if flagged and flagged(questID) then return end
      -- A problem here shows once and never stops the game's own handling
      local ok, problem = pcall(function ()
        local block = FindBlock(questID)
        local picture = TakePicture(questID)
        Core:AnimLog("quest removed", tostring(questID), block and "shown" or "not in the tracker",
          picture and "dust" or "no dust")
        if picture then
          Snap(picture)
          if block then block:SetAlpha(0) end
        end
      end)
      if not ok then geterrorhandler()(problem) end
    end)
  end
end)

Core:OnChange(function (key)
  if key ~= "enable" then return end
  events:RegisterEvent("QUEST_TURNED_IN")
  events:RegisterEvent("QUEST_REMOVED")
end)
