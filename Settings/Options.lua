local _, ns = ...
local Core = ns.Core

-- luacheck: push ignore 113
local CreateFrame = CreateFrame
local CreateFromMixins = CreateFromMixins
-- luacheck: pop

local TITLE = "Glass Forever Tracker"

----
-- Options
--
-- The addon's page in the game's Options window (Options > AddOns > Glass
-- Forever Tracker), built with the game's own controls. /gft opens it.

local function Profile() return Core.db.profile end

local function RoundTo2(value)
  return math.floor(value * 100 + 0.5) / 100
end

local function Header(layout, text)
  if _G.CreateSettingsListSectionHeaderInitializer then
    layout:AddInitializer(_G.CreateSettingsListSectionHeaderInitializer(text))
  end
end

-- A setting stored in the profile; changes are announced with its key
local function ProfileSetting(category, key, varType, name, round)
  return _G.Settings.RegisterProxySetting(
    category,
    "GLASSFOREVERTRACKER_"..key:upper(),
    varType,
    name,
    Core.defaults.profile[key],
    function () return Profile()[key] end,
    function (value)
      if round then value = RoundTo2(value) end
      Profile()[key] = value
      Core:Changed(key)
    end
  )
end

local function Slider(category, key, name, minValue, maxValue, step, tooltip)
  local Settings = _G.Settings
  local decimals = step < 1
  local setting = ProfileSetting(category, key, Settings.VarType.Number, name, decimals)
  local options = Settings.CreateSliderOptions(minValue, maxValue, step)
  options:SetLabelFormatter(_G.MinimalSliderWithSteppersMixin.Label.Right, function (value)
    return decimals and RoundTo2(value) or value
  end)
  Settings.CreateSlider(category, setting, options, tooltip)
end

local function Checkbox(category, key, name, tooltip)
  local Settings = _G.Settings
  Settings.CreateCheckbox(category, ProfileSetting(category, key, Settings.VarType.Boolean, name), tooltip)
end

local function Dropdown(category, key, name, values, tooltip)
  local Settings = _G.Settings
  local setting = ProfileSetting(category, key, Settings.VarType.String, name)
  Settings.CreateDropdown(category, setting, function ()
    local container = Settings.CreateControlTextContainer()
    for _, entry in ipairs(values) do
      container:Add(entry[1], entry[2])
    end
    return container:GetData()
  end, tooltip)
end

-- Font list with scrolling: there can be many fonts, more than fit on screen
local function FontDropdown(layout)
  local Initializer = CreateFromMixins(
    _G.ScrollBoxFactoryInitializerMixin,
    _G.SettingsElementHierarchyMixin,
    _G.SettingsSearchableElementMixin
  )

  function Initializer:Init()
    _G.ScrollBoxFactoryInitializerMixin.Init(self, "SettingsListElementTemplate")
    self.data = { name = "Font", tooltip = "Font of the tracker's text" }
    self:AddSearchTags("Font")
  end

  function Initializer:GetExtent()
    return 26
  end

  function Initializer:InitFrame(frame)
    frame:SetSize(280, 26)
    frame.data = self.data
    frame.Text:SetFontObject("GameFontNormal")
    frame.Text:SetText("Font")
    frame.Text:SetPoint("LEFT", 37, 0)
    frame.Text:SetPoint("RIGHT", frame, "CENTER", -85, 0)

    if not frame.gftFontDropdown then
      local dropdown = CreateFrame("DropdownButton", nil, frame, "WowStyle1DropdownTemplate")
      dropdown:SetPoint("LEFT", frame, "CENTER", -80, 0)
      dropdown:SetPoint("RIGHT", frame, "RIGHT", -20, 0)
      dropdown:SetHeight(26)
      frame.gftFontDropdown = dropdown
    end

    local dropdown = frame.gftFontDropdown
    dropdown:Show()
    dropdown:SetupMenu(function (_, rootDescription)
      rootDescription:SetScrollMode(300)
      -- A copy: the font list is shared with other addons
      local fonts = {}
      for _, font in ipairs(Core.LSM:List("font")) do
        table.insert(fonts, font)
      end
      for _, font in ipairs(fonts) do
        rootDescription:CreateRadio(
          font,
          function (value) return Profile().font == value end,
          function (value)
            Profile().font = value
            Core:Changed("font")
            dropdown:OverrideText(value)
          end,
          font
        )
      end
    end)
    dropdown:OverrideText(Profile().font)
  end

  function Initializer:Resetter(frame)
    if frame.gftFontDropdown then
      frame.gftFontDropdown:Hide()
    end
  end

  local initializer = CreateFromMixins(Initializer)
  initializer:Init()
  layout:AddInitializer(initializer)
end

-- The color choices, with extra entries first (e.g. "Game colors")
local function ColorChoices(extra)
  local choices = {}
  for _, entry in ipairs(extra or {}) do
    table.insert(choices, entry)
  end
  for _, entry in ipairs(Core.COLORS) do
    table.insert(choices, { entry[1], entry[2] })
  end
  return choices
end

local function Build()
  local Settings = _G.Settings
  local category, layout = Settings.RegisterVerticalLayoutCategory(TITLE)

  Header(layout, "Fade")
  Checkbox(category, "fade", "Fade out", "The tracker fades out when you're not using it. Turn off to keep it always visible")
  Slider(category, "holdTime", "Fade out delay", 1, 60, 1, "Seconds before the tracker fades out")
  Slider(category, "fadedAlpha", "Faded visibility", 0, 0.8, 0.05, "How visible the tracker stays when faded. 0 hides it completely")
  Slider(category, "fadeInDuration", "Fade in duration", 0, 3, 0.05, "Seconds the tracker takes to appear")
  Slider(category, "fadeOutDuration", "Fade out duration", 0, 3, 0.05, "Seconds the tracker takes to disappear")
  Checkbox(category, "showOnMouseOver", "Show on mouse over", "Show the tracker while the mouse is over it")
  Checkbox(category, "showOnProgress", "Show on progress", "Show the tracker for a while when a quest or achievement objective changes, or you accept or turn in a quest")

  Header(layout, "Text")
  Checkbox(category, "glassLook", "Glass look", "No header bars or panel background from the game, the Glass background, font, colors and icons. Off: the game's own look")
  FontDropdown(layout)
  Dropdown(category, "fontFlags", "Font outline", {
    { "", "None" },
    { "OUTLINE", "Outline" },
    { "OUTLINE, MONOCHROME", "Outline Monochrome" },
  }, "Outline around the letters")
  Slider(category, "headerFontSize", "Title size", 8, 24, 1, "Size of the section titles and quest names")
  Slider(category, "lineFontSize", "Objective size", 8, 24, 1, "Size of the objectives")
  Slider(category, "lineSpacing", "Line spacing", 0, 10, 1, "Extra space between the lines of a text that takes more than one line")
  Slider(category, "width", "Width", 200, 500, 10, "Width of the tracker. Longer quest names and objectives fit on one line. The game's own is 260")

  Header(layout, "Colors and icons")
  Dropdown(category, "titleColor", "Section title color", ColorChoices(),
    "Color of the section titles (\"All Objectives\", \"Quests\", \"Campaign\"...)")
  Dropdown(category, "questNameColor", "Quest name color", ColorChoices({ { "auto", "Game colors" } }),
    "Color of the quest names. Game colors: as the game (or another addon) colors them, e.g. by difficulty")
  Dropdown(category, "iconColor", "Icons", ColorChoices({ { "game", "Game icons" } }),
    "Color of the quest icons (\"?\" and \"...\") and the minimize buttons. Game icons: the game's own round icons")
  Checkbox(category, "iconOutline", "Icon outline", "A dark outline around the Glass icons, so they stand out on any background")
  Checkbox(category, "glassBars", "Glass progress bars", "Progress bars (shown by some objectives) as a flat bar in the section title color, without the game's frame")
  Dropdown(category, "completedObjectives", "Completed objectives", {
    { "show", "Show" },
    { "dim", "Dim" },
  }, "Dim: finished objectives (with the green check) are shown faded, so what's left stands out")
  Checkbox(category, "strikeCompleted", "Strike finished objectives", "A thin line crosses out an objective when it's done, drawn from left to right")

  Header(layout, "Titles")
  Checkbox(category, "hideMainHeader", "Hide \"All Objectives\"", "Hide the tracker's main title and its minimize button. Its space stays")
  Checkbox(category, "hideSectionHeaders", "Hide section titles", "Hide the section titles (\"Quests\", \"Campaign\"...) and their minimize buttons. Their space stays")
  Checkbox(category, "questCount", "Quest count", "Show in the Quests title how many quests you have and how many fit in the quest log, like \"Quests  12/25\"")

  Header(layout, "Animations")
  Dropdown(category, "sectionAnimation", "Animation style", {
    { "glass", "Glass" },
    { "game", "Game" },
    { "off", "Off" },
  }, "Glass: the addon's animations (titles lighting up, objective progress, the pulsing \"?\", new quests sliding in and writing their name, abandoned quests turning to dust...). Game: the game's own gold glows. Off: no animations")

  Header(layout, "Background")
  Slider(category, "backgroundOpacity", "Background opacity", 0, 1, 0.05, "Opacity of the Glass background behind the tracker. 0 turns it off. The Opacity setting in Edit Mode changes it too")
  Dropdown(category, "backgroundColor", "Background color", {
    { "black", "Black" },
    { "brown", "Dark brown" },
    { "blue", "Dark blue" },
    { "grey", "Dark grey" },
  }, "Color of the Glass background")
  Slider(category, "backgroundSize", "Background size", 0, 80, 2, "How far the background reaches past the text, where it fades out")

  Header(layout, "Behavior")
  Checkbox(category, "zoneHeaders", "Group quests by zone", "Sorts the quests by zone (in the order of your quest log) and writes each zone's name above its quests. Sorting waits for the end of a fight")
  Checkbox(category, "currentZoneFirst", "Your zone first", "With quests grouped by zone, the zone you're in goes to the top")
  Checkbox(category, "completedLast", "Quests to turn in last", "With quests grouped by zone, the quests ready to turn in go to the end of their zone")
  Checkbox(category, "zoneOnly", "Only quests in this zone", "Track only the quests of the zone you're in, and switch when you change zone. The others stay in your quest log. Changes wait for the end of a fight. Turning it off tracks them again")
  Dropdown(category, "instanceMode", "In dungeons and raids", {
    { "normal", "Like outside" },
    { "hide", "Hide the tracker" },
    { "show", "Always show it" },
    { "dungeon", "Dungeon quests only" },
  }, "What the tracker does in dungeons and raids. Dungeon quests only: while you're inside, it tracks only the quests of that dungeon or raid, and the others again when you leave (changes wait for the end of a fight)")
  Checkbox(category, "completeSound", "Sound on complete", "A discreet sound when a quest objective is done, and another when a quest is ready to turn in")
  Checkbox(category, "orcVoice", "Orc voice on quest complete", "When a quest is ready to turn in, an orc peon says \"Work complete!\" instead of the usual sound. Needs Sound on complete")

  Settings.RegisterAddOnCategory(category)
  return category
end

Core:OnChange(function (key)
  if key ~= "enable" or Core.optionsCategory then return end
  if not (_G.Settings and _G.Settings.RegisterVerticalLayoutCategory) then return end
  Core.optionsCategory = Build()

  _G.SLASH_GLASSFOREVERTRACKER1 = "/gft"
  _G.SlashCmdList.GLASSFOREVERTRACKER = function (input)
    -- /gft testanim: plays the new section animation now
    if input and input:lower():match("^%s*testanim") then
      local result = Core:TestAnimation()
      if result == "off" then
        print("|cffdfba69Glass Forever Tracker|r: animations are off (Options > Animations)")
      elseif not result then
        print("|cffdfba69Glass Forever Tracker|r: no section shown to animate")
      end
      return
    end
    -- /gft animlog: animation messages in chat, on or off
    if input and input:lower():match("^%s*animlog") then
      Core.animLog = not Core.animLog
      print("|cffdfba69Glass Forever Tracker|r: animation log", Core.animLog and "on" or "off")
      return
    end
    -- /gft zone: what "Only quests in this zone" decides for each quest
    if input and input:lower():match("^%s*zone") then
      Core:ZoneDebug()
      return
    end
    -- /gft debug: what the addon sees, to find problems
    if input and input:lower():match("^%s*debug") then
      local profile = Profile()
      local tracker = _G.ObjectiveTrackerFrame
      local modules, hooked = 0, 0
      for _, module in ipairs(tracker.modules or {}) do
        modules = modules + 1
        if module.Header and module.Header.AddAnim and module.Header.AddAnim.gftHooked then
          hooked = hooked + 1
        end
      end
      local pois, names = Core:IconsDebug()
      print("|cffdfba69Glass Forever Tracker|r", Core.Version)
      print("  glassLook", tostring(profile.glassLook), "iconColor", tostring(profile.iconColor),
        "questNameColor", tostring(profile.questNameColor), "animation", tostring(profile.sectionAnimation))
      print("  sections", modules, "with animation hooked", hooked, "quest icons", pois, "quest names", names)
      local bg = Core.background
      local texture = bg and bg:GetRegions()
      if texture then
        local r, g, b, a = texture:GetVertexColor()
        print(("  background shown %s size %dx%d alpha %.2f color %.2f %.2f %.2f %.2f texture %s"):format(
          tostring(bg:IsShown()), bg:GetWidth(), bg:GetHeight(), texture:GetAlpha(),
          r or 0, g or 0, b or 0, a or 0, tostring(texture:GetTexture())))
        print("  opacity", tostring(profile.backgroundOpacity), "bgsize", tostring(profile.backgroundSize),
          "slices", tostring(texture.GetTextureSliceMargins and texture:GetTextureSliceMargins()),
          "scale", ("%.2f"):format(bg:GetEffectiveScale()))
      end
      Core:IconsDetails()
      return
    end
    _G.Settings.OpenToCategory(Core.optionsCategory:GetID())
  end
end)
