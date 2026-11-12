local _, ns = ...
local Core = ns.Core

-- luacheck: push ignore 113
local CreateFrame = CreateFrame
local C_Timer = C_Timer
local CreateFromMixins = CreateFromMixins
-- luacheck: pop

local TITLE = "Questmark"

----
-- Options
--
-- The addon's page in the game's Options window (Options > AddOns > Glass
-- Forever Tracker), built with the game's own controls. /qm opens it.

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
    "QUESTMARK_"..key:upper(),
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
  FontDropdown(layout)
  Dropdown(category, "fontFlags", "Font outline", {
    { "", "None" },
    { "OUTLINE", "Outline" },
    { "OUTLINE, MONOCHROME", "Outline Monochrome" },
  }, "Outline around the letters")
  Slider(category, "headerFontSize", "Title size", 8, 24, 1, "Size of the section titles and quest names")
  Slider(category, "lineFontSize", "Objective size", 8, 24, 1, "Size of the objectives")
  Slider(category, "lineSpacing", "Line spacing", 0, 10, 1, "Extra space between the lines of a text that takes more than one line")
  Slider(category, "width", "Width", 200, 500, 10, "Width of the tracker. Longer quest names and objectives fit on one line")
  Slider(category, "maxHeight", "Height", 200, 1400, 10, "The highest the tracker gets. When there's more, scroll it with the mouse wheel")

  Header(layout, "Colors and icons")
  Dropdown(category, "titleColor", "Section title color", ColorChoices(),
    "Color of the titles (\"Objectives\", \"Quests\", \"Achievements\"...) and the zone names")
  Dropdown(category, "questNameColor", "Name color", ColorChoices({ { "auto", "By difficulty" } }),
    "Color of the names of quests, achievements and recipes. By difficulty: quests in the game's difficulty colors (grey, green, yellow, orange, red)")
  Dropdown(category, "iconColor", "Icons", ColorChoices(),
    "Color of the quest icons (\"?\" and \"...\") and the minimize buttons")
  Checkbox(category, "iconOutline", "Icon outline", "A dark outline around the icons, so they stand out on any background")
  Checkbox(category, "glassBars", "Bars in the title color", "Progress bars (shown by some objectives) in the title color. Off: green")
  Dropdown(category, "completedObjectives", "Completed objectives", {
    { "show", "Show" },
    { "dim", "Dim" },
  }, "Dim: finished objectives (with the green check) are shown faded, so what's left stands out")
  Checkbox(category, "strikeCompleted", "Strike finished objectives", "A thin line crosses out an objective when it's done, drawn from left to right")

  Header(layout, "Titles")
  Checkbox(category, "hideMainHeader", "Hide \"Objectives\"", "Hide the tracker's main title and its minimize button")
  Checkbox(category, "hideSectionHeaders", "Hide section titles", "Hide the section titles (\"Quests\", \"Achievements\"...) and their minimize buttons")
  Checkbox(category, "questCount", "Quest count", "Show in the Quests title how many quests you have and how many fit in the quest log, like \"Quests  12/25\"")

  Header(layout, "Animations")
  Dropdown(category, "sectionAnimation", "Animations", {
    { "glass", "All" },
    { "off", "Off" },
  }, "All: titles lighting up, objective progress, the pulsing \"?\", new quests sliding in and writing their name, abandoned quests turning to dust... Off: no animations")

  Header(layout, "Background")
  Slider(category, "backgroundOpacity", "Background opacity", 0, 1, 0.05, "Opacity of the background behind the tracker. 0 turns it off")
  Dropdown(category, "backgroundColor", "Background color", {
    { "black", "Black" },
    { "brown", "Dark brown" },
    { "blue", "Dark blue" },
    { "grey", "Dark grey" },
  }, "Color of the background")
  Slider(category, "backgroundSize", "Background size", 0, 80, 2, "How far the background reaches past the text, where it fades out")

  Header(layout, "Behavior")
  Checkbox(category, "allQuests", "All quests", "Show every quest in your quest log, not only the ones you track (the game can track only so many). Stop tracking a quest (Shift + click) to hide it; track it again in the quest log to show it again")
  Checkbox(category, "zoneHeaders", "Group quests by zone", "Sorts the quests by zone (in the order of your quest log) and writes each zone's name above its quests. Click a zone's name to minimize it. Arriving in a zone opens it and minimizes the others")
  Checkbox(category, "currentZoneFirst", "Your zone first", "With quests grouped by zone, the zone you're in goes to the top")
  Checkbox(category, "completedLast", "Quests to turn in last", "With quests grouped by zone, the quests ready to turn in go to the end of their zone")
  Checkbox(category, "zoneOnly", "Only quests in this zone", "Track only the quests of the zone you're in, and switch when you change zone. The others stay in your quest log. Changes wait for the end of a fight. Turning it off tracks them again")
  Dropdown(category, "instanceMode", "In dungeons and raids", {
    { "normal", "Like outside" },
    { "hide", "Hide the tracker" },
    { "show", "Always show it" },
    { "dungeon", "Dungeon quests only" },
  }, "What the tracker does in dungeons and raids. Dungeon quests only: while you're inside, only the quests of that dungeon or raid show (the others stay tracked and come back when you leave)")
  Checkbox(category, "dungeonAlwaysShow", "Always visible in dungeons", "In dungeons and raids the tracker doesn't fade out (unless \"In dungeons and raids\" is set to hide it)")
  Checkbox(category, "dungeonInfo", "Dungeon info", "In dungeons and raids, a section at the top of the tracker with the run: how long it's taking, the bosses (killed ones checked), the experience and gold you've made and how many times you died. Right click it to start the run again")
  Checkbox(category, "completeSound", "Sound on complete", "A discreet sound when a quest objective is done, and another when a quest is ready to turn in")
  Checkbox(category, "orcVoice", "Orc voice on quest complete", "When a quest is ready to turn in, an orc peon says \"Work complete!\" instead of the usual sound. Needs Sound on complete")

  -- The quest book's options: a page of their own, under the tracker's
  -- (Options > AddOns > Questmark > Quest Book)
  local book, bookLayout = Settings.RegisterVerticalLayoutSubcategory(category, "Quest Book")
  Header(bookLayout, "Quest book")
  Checkbox(book, "bookKey", "Quest book on the quest log key", "The key that opens the quest log (L) opens the tracker's quest book instead. Changes wait for the end of a fight")
  Slider(book, "bookSize", "Book size", 70, 220, 5, "Size of the quest book, in % of its own size. Dragging its bottom right corner changes it too")
  Slider(book, "bookTextSize", "Text size", 9, 18, 1, "Size of the writing in the quest book: the quests in the list, the objectives, the description and the rewards")
  Slider(book, "bookTitleSize", "Titles size", 16, 34, 1, "Size of the quest book's titles. The headings and the zones in the list go with it")
  Slider(book, "bookMapSize", "Map size", 40, 100, 2, "Width of the map on the right page, in % of the page")
  Slider(book, "bookMapZoom", "Map zoom", 1, 5, 0.5, "How close the map opens on the quest's place. 1: the whole zone")
  Checkbox(book, "bookAnimations", "Book animations", "The quest book opens and shuts as a book, its pages turn, its quests come in one after the other and a quest just done glows")
  Checkbox(book, "bookDust", "Gold dust", "Gold dust floating over the quest book's pages")
  Checkbox(book, "bookSounds", "Book sounds", "The sounds of the quest book opening, shutting and turning its pages")

  Settings.RegisterAddOnCategory(category)
  return category
end

Core:OnChange(function (key)
  if key ~= "enable" or Core.optionsCategory then return end
  if not (_G.Settings and _G.Settings.RegisterVerticalLayoutCategory) then return end
  Core.optionsCategory = Build()

  _G.SLASH_QUESTMARK1 = "/qm"
  _G.SLASH_QUESTMARK2 = "/questmark"
  _G.SlashCmdList.QUESTMARK = function (input)
    -- /qm testcard: the dungeon card, with bosses dying, anywhere
    -- (with a name, that dungeon: /qm testcard deadmines)
    if input and input:lower():match("^%s*testcard") then
      Core.DungeonDemo(input:match("^%s*%S+%s*(.-)%s*$"))
      return
    end
    -- /qm testanim: plays the new section animation now
    if input and input:lower():match("^%s*testanim") then
      local result = Core:TestAnimation()
      if result == "off" then
        print("|cffdfba69Questmark|r: animations are off (Options > Animations)")
      elseif not result then
        print("|cffdfba69Questmark|r: no section shown to animate")
      end
      return
    end
    -- /qm animlog: animation messages in chat, on or off
    if input and input:lower():match("^%s*animlog") then
      Core.animLog = not Core.animLog
      print("|cffdfba69Questmark|r: animation log", Core.animLog and "on" or "off")
      return
    end
    -- /qm zone: what "Only quests in this zone" decides for each quest
    if input and input:lower():match("^%s*zone") then
      Core:ZoneDebug()
      return
    end
    -- /qm debug: what the addon sees, to find problems
    if input and input:lower():match("^%s*debug") then
      local profile = Profile()
      local frame = Core.frame
      local blocks = 0
      for _ in pairs(Core.ShownBlocks()) do blocks = blocks + 1 end
      print("|cffdfba69Questmark|r", Core.Version)
      print(("  shown %s alpha %.2f size %dx%d content %d blocks %d"):format(
        tostring(frame:IsShown()), frame:GetAlpha(), frame:GetWidth(), frame:GetHeight(),
        Core.contentHeight or 0, blocks))
      local point, _, _, x, y = frame:GetPoint(1)
      print("  position", tostring(point), tostring(x), tostring(y), "edit mode", tostring(Core.InEditMode()))
      local game = _G.ObjectiveTrackerFrame
      print("  game tracker", game and tostring(game:IsVisible()) or "none",
        "animations", tostring(profile.sectionAnimation), "zones", tostring(profile.zoneHeaders))
      return
    end
    _G.Settings.OpenToCategory(Core.optionsCategory:GetID())
  end
end)
