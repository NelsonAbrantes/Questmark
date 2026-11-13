local _, ns = ...
local Core = ns.Core

-- luacheck: push ignore 113
local CreateFrame = CreateFrame
local GameTooltip = GameTooltip
local InCombatLockdown = InCombatLockdown
-- luacheck: pop

local SIZE = 26
local GAP = 6 -- between the button and its quest

----
-- Items
--
-- The quest item buttons, on the left of their quests. They're the game's
-- protected buttons (the only ones allowed to use an item), so they can only
-- be made, placed or hidden out of combat. In a fight they stay where they
-- are; one whose quest left the tracker turns invisible, and they're all
-- placed again when the fight ends. See Frame.lua.

local holder = Core.items
local buttons = {}
local pending = false -- something to place after the fight

local function UpdateCooldown(button)
  local logIndex = button.logIndex
  if not logIndex or not _G.GetQuestLogSpecialItemCooldown then return end
  local start, duration, enable = _G.GetQuestLogSpecialItemCooldown(logIndex)
  if start and duration and duration > 0 and enable and enable ~= 0 then
    button.cooldown:SetCooldown(start, duration)
  else
    button.cooldown:Clear()
  end
end

local function CreateButton(i)
  local button = CreateFrame("Button", "QuestmarkItem"..i, holder, "SecureActionButtonTemplate")
  button:SetSize(SIZE, SIZE)
  button:RegisterForClicks("AnyUp", "AnyDown")
  button:SetAttribute("type", "item")

  -- A thin dark frame around the icon, the Glass way
  button.border = button:CreateTexture(nil, "BACKGROUND")
  button.border:SetPoint("TOPLEFT", -1, 1)
  button.border:SetPoint("BOTTOMRIGHT", 1, -1)
  button.border:SetColorTexture(0, 0, 0, 0.8)
  button.icon = button:CreateTexture(nil, "ARTWORK")
  button.icon:SetAllPoints()
  button.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
  button.highlight = button:CreateTexture(nil, "HIGHLIGHT")
  button.highlight:SetAllPoints()
  button.highlight:SetColorTexture(1, 1, 1, 0.15)
  button.count = button:CreateFontString(nil, "OVERLAY", "NumberFontNormalSmall")
  button.count:SetPoint("BOTTOMRIGHT", -1, 1)
  button.cooldown = CreateFrame("Cooldown", nil, button, "CooldownFrameTemplate")
  button.cooldown:SetAllPoints()

  button:HookScript("OnEnter", function (self)
    GameTooltip:SetOwner(self, "ANCHOR_LEFT")
    if self.logIndex and GameTooltip.SetQuestLogSpecialItem then
      GameTooltip:SetQuestLogSpecialItem(self.logIndex)
    elseif self.link then
      GameTooltip:SetHyperlink(self.link)
    end
    GameTooltip:Show()
    Core:Changed("itemHover", true)
  end)
  button:HookScript("OnLeave", function ()
    GameTooltip:Hide()
    Core:Changed("itemHover", false)
  end)
  buttons[i] = button
  return button
end

---
-- Places a button beside each quest with an item. `quests`: the quest blocks
-- with an item, top to bottom. Waits for the end of a fight if needed.
-- A block in the part of the tracker that shows (it can scroll)
local function InView(block)
  local top, bottom = block:GetTop(), Core.frame:GetBottom()
  local viewTop = Core.frame:GetTop()
  if not (top and bottom and viewTop) then return false end
  return top <= viewTop + 1 and top - 10 >= bottom
end

function Core.PlaceItems(quests)
  Core.itemQuests = quests
  if InCombatLockdown() then
    pending = true
    -- Buttons whose quest left, moved or scrolled out of sight: invisible
    -- (they can't be hidden or moved now)
    for _, button in ipairs(buttons) do
      local still = false
      for _, block in ipairs(quests) do
        if block.id == button.questID then
          still = InView(block) and math.abs((block:GetTop() or 0) - (button.blockTop or 0)) < 1
          break
        end
      end
      button:SetAlpha(still and 1 or 0)
    end
    return
  end
  pending = false
  local scale = Core.frame:GetEffectiveScale() / holder:GetEffectiveScale()
  local used = 0
  for _, block in ipairs(quests) do
    local item = block.entry.item
    local left, top = block:GetLeft(), block:GetTop()
    if item and left and top and InView(block) then
      used = used + 1
      local button = buttons[used] or CreateButton(used)
      button.questID, button.logIndex, button.link = block.id, item.logIndex, item.link
      button.blockTop = top
      button:SetAttribute("item", item.link)
      button.icon:SetTexture(item.texture)
      button.count:SetText(item.charges and item.charges > 1 and item.charges or "")
      -- (in the screen's units: the tracker can have another scale)
      button:ClearAllPoints()
      button:SetPoint("TOPRIGHT", holder, "BOTTOMLEFT", left * scale - GAP, top * scale)
      button:SetAlpha(1)
      button:Show()
      UpdateCooldown(button)
    end
  end
  for i = used + 1, #buttons do
    buttons[i].questID = nil
    buttons[i]:Hide()
  end
end

---
-- True while the mouse is over one of the item buttons
function Core.MouseOverItems()
  for _, button in ipairs(buttons) do
    if button:IsVisible() and button:IsMouseOver() then return true end
  end
  return false
end

-- Hidden in Edit Mode (while the tracker is being moved they'd stay behind)
function Core.ShowItems(show)
  if InCombatLockdown() then return end
  holder:SetShown(show)
end

local events = CreateFrame("Frame")
events:SetScript("OnEvent", function (_, event)
  if event == "PLAYER_REGEN_ENABLED" then
    if pending and Core.itemQuests then Core.PlaceItems(Core.itemQuests) end
  else
    for _, button in ipairs(buttons) do
      if button:IsShown() then UpdateCooldown(button) end
    end
  end
end)

Core:OnChange(function (key)
  if key == "enable" then
    if not Core.trackerOn then return end -- (the tracker turned off)
    events:RegisterEvent("PLAYER_REGEN_ENABLED")
    events:RegisterEvent("BAG_UPDATE_COOLDOWN")
  end
end)
