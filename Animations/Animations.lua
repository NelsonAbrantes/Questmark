local _, ns = ...
local Core = ns.Core

-- luacheck: push ignore 113
local CreateFrame = CreateFrame
local C_Timer = C_Timer
local GetTime = GetTime
local geterrorhandler = geterrorhandler
-- luacheck: pop

local SOFT = Core.ASSETS.."softBackground"
local LINE = Core.ASSETS.."line"
local SLIDE_DISTANCE = 30
local SLIDE_TIME = 0.4
local TYPE_SPEED = 45        -- letters per second when the name writes itself
local TYPE_SOFTNESS = 6      -- letters fading in at the edge of the writing
local LINE_DELAY = 0.12      -- between one objective and the next
local LINE_FADE = 0.3
local FLASH_TIME = 0.45      -- how long a finished objective stays white
local CHECK_SIZE, CHECK_GROW, CHECK_TIME = 12, 0.35, 0.3

----
-- Animations (Options: Animations: Glass)
--
-- - A new quest (achievement, recipe): it slides in from the right, its name
--   writes itself letter by letter, its objectives appear one by one, and a
--   ring opens around its icon (Icons.lua)
-- - A new section: its title fades in, with a shine passing over it
-- - An objective that moves on: a thin line lights up under it
-- - An objective done: its check pops and the text flashes white
-- - A quest ready to turn in: a shine passes over its name
-- - Quests coming back (a zone opened): they fade in, one after the other
-- - A quest leaving (the zone filter): it fades out first

-- Small animations run frame by frame: each task gets the time since it
-- started and returns true when it's done
local tasks = {}
local driver = CreateFrame("Frame")
driver:Hide()
driver:SetScript("OnUpdate", function ()
  local now = GetTime()
  for task, started in pairs(tasks) do
    -- A task that fails is dropped, so an error can't repeat every frame
    local ok, done = pcall(task, now - started)
    if not ok or done then tasks[task] = nil end
    if not ok then geterrorhandler()(done) end
  end
  if next(tasks) == nil then driver:Hide() end
end)

local function Run(task)
  tasks[task] = GetTime()
  driver:Show()
end

-- Smooth start and end
local function Ease(k) return k * k * (3 - 2 * k) end

local Flash -- below

----
-- The Glass light: a thin line in the title color lights up under a text
-- (fading at both ends) and, for titles, a soft shine passes over it; then
-- it all fades. "title" (with the shine) or "line" (only the line, quicker).

local function GlassAnimation(owner, anchor, kind)
  owner.gftAnims = owner.gftAnims or {}
  if owner.gftAnims[kind] then return owner.gftAnims[kind] end

  local glassLine = Core.Smooth(owner:CreateTexture(nil, "ARTWORK"))
  glassLine:SetTexture(LINE)
  glassLine:SetHeight(1)
  glassLine:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, -1)
  glassLine:SetPoint("TOPRIGHT", anchor, "BOTTOMRIGHT", 0, -1)
  glassLine:SetAlpha(0)

  local anim = owner:CreateAnimationGroup()
  local function Fade(target, from, to, duration, delay)
    local fade = anim:CreateAnimation("Alpha")
    fade:SetTarget(target)
    fade:SetFromAlpha(from)
    fade:SetToAlpha(to)
    fade:SetDuration(duration)
    fade:SetStartDelay(delay or 0)
    fade:SetSmoothing("IN_OUT")
    return fade
  end

  local quick = kind == "line"
  Fade(glassLine, 0, 1, quick and 0.2 or 0.3, 0.1)
  Fade(glassLine, 1, 0, quick and 0.6 or 0.9, quick and 0.6 or 1.2)

  local shine
  if not quick then
    shine = Core.Smooth(owner:CreateTexture(nil, "OVERLAY"))
    shine:SetTexture(SOFT)
    shine:SetBlendMode("ADD")
    shine:SetPoint("LEFT", anchor, "LEFT", -35, 0)
    shine:SetAlpha(0)
    Fade(shine, 0, 0.5, 0.3, 0.2)
    Fade(shine, 0.5, 0, 0.5, 0.9)
    -- (it moves by hand, see PlayGlass: the game's own move animations went
    -- wrong inside the tracker's scrolling frame)
  end

  anim:SetScript("OnFinished", function ()
    glassLine:SetAlpha(0)
    if shine then shine:SetAlpha(0) end
  end)

  anim.gftLine = glassLine
  anim.gftShine = shine
  owner.gftAnims[kind] = anim
  return anim
end

local function PlayGlass(owner, anchor, kind)
  local anim = GlassAnimation(owner, anchor, kind)
  anim.gftLine:SetVertexColor(Core:TitleColor())
  if anim.gftShine then
    -- Shine as tall as the text, passing over its whole width (capped)
    local shine = anim.gftShine
    shine:SetSize(70, math.min(40, math.max(12, anchor:GetStringHeight() or 12)))
    local distance = math.min(600, math.max(100, anchor:GetStringWidth() or 100))
    anim.gftRun = (anim.gftRun or 0) + 1
    local run = anim.gftRun
    Run(function (elapsed)
      -- (a newer light started on it meanwhile: this one stops)
      if anim.gftRun ~= run then return true end
      local k = math.max(0, math.min(1, (elapsed - 0.2) / 1.2))
      shine:ClearAllPoints()
      shine:SetPoint("LEFT", anchor, "LEFT", -35 + distance * Ease(k), 0)
      return k >= 1
    end)
  end
  anim:Stop()
  anim:Play()
end

-- A new section: the title fades in, and the light passes over it
local function SectionAdded(header)
  local text = header.text
  header.gftTitleFade = header.gftTitleFade or text:CreateAnimationGroup()
  local fadeIn = header.gftTitleFade
  if not fadeIn.gftReady then
    fadeIn.gftReady = true
    local alpha = fadeIn:CreateAnimation("Alpha")
    alpha:SetFromAlpha(0)
    alpha:SetToAlpha(1)
    alpha:SetDuration(0.5)
    alpha:SetSmoothing("OUT")
  end
  fadeIn:Stop()
  fadeIn:Play()
  PlayGlass(header, text, "title")
end

----
-- A new quest

-- (moved by hand: the game's own slide animations went wrong inside the
-- tracker's scrolling frame, the quest showing far off to the right)
local function Slide(block)
  local entry = block.entry
  local parent = block:GetParent()
  block.slideX = SLIDE_DISTANCE
  Run(function (elapsed)
    local k = math.min(1, elapsed / SLIDE_TIME)
    -- Reused for something else meanwhile: in its place at once
    if block.entry ~= entry then k = 1 end
    block.slideX = SLIDE_DISTANCE * (1 - k) * (1 - k)
    block:ClearAllPoints()
    block:SetPoint("TOPLEFT", parent, "TOPLEFT", block.slideX, -(block.placedY or 0))
    if k >= 1 then
      block.slideX = nil
      return true
    end
    return false
  end)
end

-- The name writes itself: the letters show from left to right, with a soft
-- edge. Returns how long it takes.
local function TypeName(block)
  local text = block.title
  if not text.SetAlphaGradient then return 0 end
  local value = text:GetText()
  if not Core.Readable(value) or type(value) ~= "string" then return 0 end
  local _, length = value:gsub("[^\128-\191]", "") -- letters, not bytes (accented letters take more)
  local duration = length / TYPE_SPEED
  local entry = block.entry
  text:SetAlphaGradient(0, TYPE_SOFTNESS)
  Run(function (elapsed)
    -- Reused for something else meanwhile: shown as it is
    if elapsed >= duration or block.entry ~= entry then
      text:SetAlphaGradient(length + TYPE_SOFTNESS, 1) -- all shown (the game needs a length of at least 1)
      return true
    end
    text:SetAlphaGradient(math.floor(elapsed * TYPE_SPEED), TYPE_SOFTNESS)
    return false
  end)
  return duration
end

-- The objectives appear one by one, top to bottom, starting after `delay`
local function ShowLines(block, delay)
  local lines = {}
  for _, line in pairs(block.lines.used) do table.insert(lines, line) end
  table.sort(lines, function (a, b) return (a:GetTop() or 0) > (b:GetTop() or 0) end)
  for _, line in ipairs(lines) do
    line.gftAnimating = true
    line:SetAlpha(0)
  end
  local function Target(line)
    local profile = Core.db.profile
    return line.data and line.data.done and profile.completedObjectives == "dim" and 0.35 or 1
  end
  Run(function (elapsed)
    local done = true
    for i, line in ipairs(lines) do
      if line.gftAnimating then
        local progress = (elapsed - delay - (i - 1) * LINE_DELAY) / LINE_FADE
        if progress >= 1 or not line:IsShown() then
          line:SetAlpha(Target(line))
          line.gftAnimating = nil
        else
          line:SetAlpha(Target(line) * Ease(math.max(0, progress)))
          done = false
        end
      end
    end
    return done
  end)
end

local function QuestAdded(block)
  -- Not while the whole tracker slides in: two slides at once looked jumpy
  if not Core:TrackerSliding() then Slide(block) end
  local typing = TypeName(block)
  -- Objectives start when the name is about half written
  ShowLines(block, typing * 0.5)
  if block.poi:IsShown() then Core.RingIcon(block.poi) end
end

----
-- Quests coming back (a zone opened, the zone filter): they fade in one by
-- one, top to bottom, in a quiet cascade

local BACK_DELAY = 0.08 -- between one quest and the next
local BACK_FADE = 0.35
local BURST = 0.5       -- quests coming back this close together are one cascade
local burst

local function FadeBack(block)
  local now = GetTime()
  if not burst or now - burst.last > BURST then
    burst = { blocks = {}, sorted = false, last = now }
    local current = burst
    Run(function (elapsed)
      if not current.sorted then
        table.sort(current.blocks, function (a, b) return (a.block:GetTop() or 0) > (b.block:GetTop() or 0) end)
        current.sorted = true
      end
      local done = true
      for i, item in ipairs(current.blocks) do
        local b = item.block
        if b.gftFading then
          if b.entry ~= item.entry and b.id ~= item.id then
            b.gftFading = false
            b:SetAlpha(1)
          else
            local progress = (elapsed - (i - 1) * BACK_DELAY) / BACK_FADE
            if progress >= 1 then
              b:SetAlpha(1)
              b.gftFading = false
            else
              b:SetAlpha(Ease(math.max(0, progress)))
              done = false
            end
          end
        end
      end
      return done
    end)
  end
  burst.last = now
  block.gftFading = true
  block:SetAlpha(0)
  table.insert(burst.blocks, { block = block, id = block.id, entry = block.entry })
  -- Never left invisible
  C_Timer.After(2, function ()
    if block.gftFading then
      block.gftFading = false
      block:SetAlpha(1)
    end
  end)
end

---
-- A quest leaving the tracker (the zone filter): it fades out, then `done`
-- runs (which stops tracking it)
local LEAVE_FADE = 0.6
function Core:FadeOutBlock(block, done)
  local id = block.id
  Run(function (elapsed)
    -- Reused for another quest meanwhile: left as it is
    if block.id ~= id then
      block:SetAlpha(1)
      done()
      return true
    end
    local progress = elapsed / LEAVE_FADE
    if progress >= 1 then
      block:SetAlpha(0)
      done()
      -- Still there a moment later (not untracked after all): shown again
      C_Timer.After(1, function ()
        if block.id == id and block:GetAlpha() == 0 then block:SetAlpha(1) end
      end)
      return true
    end
    block:SetAlpha(1 - Ease(progress))
    return false
  end)
end

----
-- A quest turned in: the light passes over its name, then it slides to the
-- right and fades out; `done` gives its frame back

local LEAVE_SLIDE = 40
function Core.QuestLeaving(block, done)
  PlayGlass(block, block.title, "title")
  local y = block.placedY or 0
  local parent = block:GetParent()
  Run(function (elapsed)
    local k = math.max(0, math.min(1, (elapsed - 0.3) / 0.45))
    block:ClearAllPoints()
    block:SetPoint("TOPLEFT", parent, "TOPLEFT", LEAVE_SLIDE * Ease(k), -y)
    block:SetAlpha(1 - Ease(k))
    if k >= 1 then
      done()
      return true
    end
    return false
  end)
end

----
-- Objectives

-- The check of a finished objective pops: a little bigger, then back
local function PopCheck(check)
  Core.Smooth(check)
  Run(function (elapsed)
    local k = elapsed / CHECK_TIME
    if k >= 1 then
      check:SetSize(CHECK_SIZE, CHECK_SIZE)
      return true
    end
    local size = CHECK_SIZE * (1 + CHECK_GROW * math.sin(math.pi * k))
    check:SetSize(size, size)
    return false
  end)
end

-- A text lit white for a moment, then its color again
function Flash(text, time)
  local r, g, b = text:GetTextColor()
  if r == 1 and g == 1 and b == 1 then return end
  text:SetTextColor(1, 1, 1)
  C_Timer.After(time, function ()
    -- Unless the tracker has colored it again meanwhile
    local nr, ng, nb = text:GetTextColor()
    if nr == 1 and ng == 1 and nb == 1 then text:SetTextColor(r, g, b) end
  end)
end

local function LineDone(line)
  PopCheck(line.check)
  Flash(line.text, FLASH_TIME)
end

----

Core:OnChange(function (key, object)
  if not object or not Core:Animates() then return end
  if key == "questAdded" then
    Core:AnimLog("new", tostring(object.id))
    QuestAdded(object)
  elseif key == "questBack" then
    FadeBack(object)
  elseif key == "sectionAdded" then
    SectionAdded(object)
  elseif key == "lineProgress" then
    PlayGlass(object, object.text, "line")
    Flash(object.text, 0.25)
  elseif key == "lineDone" then
    LineDone(object)
  elseif key == "questComplete" then
    PlayGlass(object, object.title, "title")
    -- (a quest: a ring of light on its icon, and "Ready for turn-in" fading in)
    if object.poi and object.poi:IsShown() then Core.RingIcon(object.poi) end
    if object.lines and object.lines.used then ShowLines(object, 0.15) end
  end
end)

-- /gft testanim: the new section animation on the first title shown
function Core:TestAnimation()
  if not Core:Animates() then return "off" end
  local header = Core.FirstHeader and Core.FirstHeader()
  if not header then return false end
  Core:Changed("sectionAdded", header)
  return true
end
