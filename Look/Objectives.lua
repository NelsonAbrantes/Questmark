local _, ns = ...
local Core = ns.Core

-- luacheck: push ignore 113
local CreateFrame = CreateFrame
local GetTime = GetTime
local hooksecurefunc = hooksecurefunc
-- luacheck: pop

local STRIKE_TIME = 0.35  -- seconds for the line to cross a finished objective
local STRIKE_ALPHA = 0.6

----
-- Objectives
--
-- Strike finished objectives (Options): when an objective with a count
-- ("3/10 Gnoll Paw") is done, a thin line crosses it out, drawn from left to
-- right, and it stays struck. Drawn on the game's lines, over the room they
-- already have, so the game's layout isn't changed. Placed again after each
-- layout, since the game reuses its lines for other objectives.

local module = _G.QuestObjectiveTracker

local function Profile() return Core.db.profile end

-- The count in an objective's text: "3/10 Gnoll Paw" -> 3, 10
local function Count(text)
  if type(text) ~= "string" or (issecretvalue and issecretvalue(text)) then return nil end
  local have, need = text:match("(%d+)%s*/%s*(%d+)")
  have, need = tonumber(have), tonumber(need)
  if not have or not need or need <= 0 then return nil end
  return math.min(have, need), need
end

----
-- The strike's drawing, frame by frame, only while one is being drawn

local drawing = {} -- strike -> start time
local animator = CreateFrame("Frame")
animator:Hide()
animator:SetScript("OnUpdate", function ()
  local now = GetTime()
  for strike, start in pairs(drawing) do
    local k = math.min(1, (now - start) / STRIKE_TIME)
    k = k * k * (3 - 2 * k)
    strike:SetWidth(math.max(0.1, strike.glassFullWidth * k))
    if k >= 1 then drawing[strike] = nil end
  end
  if next(drawing) == nil then animator:Hide() end
end)

----

local wasDone = {} -- "questID:objective" -> true once seen finished

local function Decorate(block, line)
  local text = line.Text
  if not text then return end
  local have, need = Count(text:GetText())
  local profile = Profile()
  local width = text:GetStringWidth() or 0
  if issecretvalue and issecretvalue(width) then width = 0 end


  -- Strike
  local done = have and have >= need
  local key = tostring(block.id)..":"..tostring(line.objectiveKey)
  local showStrike = profile.glassLook and profile.strikeCompleted and done and width > 0
  if showStrike and not line.gftStrike then
    local strike = line:CreateTexture(nil, "OVERLAY")
    strike:SetColorTexture(1, 1, 1, 1)
    Core.PixelHeight(strike, 1)
    line.gftStrike = strike
  end
  if line.gftStrike then
    local strike = line.gftStrike
    if showStrike then
      strike:ClearAllPoints()
      strike:SetPoint("LEFT", text, "LEFT", 0, 0)
      strike:SetVertexColor(1, 1, 1, STRIKE_ALPHA)
      strike.glassFullWidth = width
      -- Drawn across when it has just been finished; already struck otherwise
      if not wasDone[key] and line.gftStrikeKey == key then
        strike:SetWidth(0.1)
        drawing[strike] = GetTime()
        animator:Show()
      elseif not drawing[strike] then
        strike:SetWidth(width)
      end
      strike:Show()
    else
      drawing[strike] = nil
      strike:Hide()
    end
  end
  line.gftStrikeKey = key
  if done then wasDone[key] = true else wasDone[key] = nil end
end

local function DecorateAll()
  if not module or not module.firstBlock then return end
  local block = module.firstBlock
  while block do
    if block.used and block.usedLines then
      for _, line in pairs(block.usedLines) do
        Decorate(block, line)
      end
    end
    block = block.nextBlock
  end
end

Core:OnChange(function (key)
  if key == "enable" then
    if module and module.EndLayout then
      hooksecurefunc(module, "EndLayout", DecorateAll)
    end
    DecorateAll()
  elseif key == "strikeCompleted" or key == "glassLook" or key == "titleColor"
    or key == "profile" then
    DecorateAll()
  end
end)
