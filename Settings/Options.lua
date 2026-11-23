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
  return Settings.CreateSlider(category, setting, options, tooltip)
end

local function Checkbox(category, key, name, tooltip)
  local Settings = _G.Settings
  return Settings.CreateCheckbox(category, ProfileSetting(category, key, Settings.VarType.Boolean, name), tooltip)
end

local function Dropdown(category, key, name, values, tooltip)
  local Settings = _G.Settings
  local setting = ProfileSetting(category, key, Settings.VarType.String, name)
  return Settings.CreateDropdown(category, setting, function ()
    local container = Settings.CreateControlTextContainer()
    for _, entry in ipairs(values) do
      container:Add(entry[1], entry[2])
    end
    return container:GetData()
  end, tooltip)
end

-- Font list with scrolling: there can be many fonts, more than fit on screen.
-- key: the setting (font by default); first: an entry before the fonts,
-- { value, label } (e.g. the quest book's own letters)
local function FontDropdown(layout, key, label, tooltip, first)
  key, label = key or "font", label or "Font"
  tooltip = tooltip or "Font of the tracker's text"
  local function Shown(value)
    if first and value == first[1] then return first[2] end
    return value
  end
  local Initializer = CreateFromMixins(
    _G.ScrollBoxFactoryInitializerMixin,
    _G.SettingsElementHierarchyMixin,
    _G.SettingsSearchableElementMixin
  )

  function Initializer:Init()
    _G.ScrollBoxFactoryInitializerMixin.Init(self, "SettingsListElementTemplate")
    self.data = { name = label, tooltip = tooltip }
    self:AddSearchTags(label)
  end

  function Initializer:GetExtent()
    return 26
  end

  function Initializer:InitFrame(frame)
    frame:SetSize(280, 26)
    frame.data = self.data
    frame.Text:SetFontObject("GameFontNormal")
    frame.Text:SetText(label)
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
      if first then table.insert(fonts, first[1]) end
      for _, font in ipairs(Core.LSM:List("font")) do
        table.insert(fonts, font)
      end
      for _, font in ipairs(fonts) do
        rootDescription:CreateRadio(
          Shown(font),
          function (value) return Profile()[key] == value end,
          function (value)
            Profile()[key] = value
            Core:Changed(key)
            dropdown:OverrideText(Shown(value))
          end,
          font
        )
      end
    end)
    dropdown:OverrideText(Shown(Profile()[key]))
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

  Header(layout, "Parts")
  Checkbox(category, "useTracker", "Questmark's tracker", "Questmark's own objective tracker in place of the game's. Off: the game's tracker comes back. Needs a reload")
  Checkbox(category, "useBook", "Quest book", "The quest book: clicking a quest in the tracker reads it there, and the quest log key can open it (Quest Book options). Off: the quest log key opens the game's quest log, and clicking a quest in the tracker follows it")

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
  Checkbox(category, "turnInXP", "XP to turn in", "Show in the Quests title the experience the quests ready to turn in give, like \"+12,400 XP\"")

  Header(layout, "Animations")
  Dropdown(category, "sectionAnimation", "Animations", {
    { "glass", "All" },
    { "off", "Off" },
  }, "All: titles lighting up, objective progress, the pulsing \"?\", new quests sliding in and writing their name, abandoned quests turning to dust... Off: no animations")

  Header(layout, "Background")
  Dropdown(category, "backgroundStyle", "Background style", {
    { "soft", "Default" },
    { "smudge", "Brushed paint" },
  }, "The background's look. Default: a soft shadow fading out on every side. Brushed paint: dark paint brushed on, with rough edges")
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
  Checkbox(category, "zoneOnly", "Only quests in this zone", "Only the zone you're in is open: with All quests on, the other zones show minimized (click one to open it); with it off, only the quests of this zone are tracked (the others stay in your quest log, and are tracked again when you turn this off)")
  Dropdown(category, "instanceMode", "In dungeons and raids", {
    { "normal", "Like outside" },
    { "hide", "Hide the tracker" },
    { "show", "Always show it" },
    { "dungeon", "Dungeon quests only" },
  }, "What the tracker does in dungeons and raids. Dungeon quests only: while you're inside, only the quests of that dungeon or raid show (the others stay tracked and come back when you leave)")
  Checkbox(category, "dungeonAlwaysShow", "Always visible in dungeons", "In dungeons and raids the tracker doesn't fade out (unless \"In dungeons and raids\" is set to hide it)")
  Checkbox(category, "dungeonInfo", "Dungeon info", "In dungeons and raids, a section at the top of the tracker with the run: how long it's taking, the bosses (killed ones checked), the experience and gold you've made and how many times you died. Right click it to start the run again")
  Checkbox(category, "dungeonPrep", "Dungeon quests before going in", "Near a dungeon's entrance, its quests at the top of the tracker: the ones you have checked, the ones missing with where to get them. Needs the ForeverDungeonJournal addon. Right click it to hide it")
  Checkbox(category, "groupLead", "Quests with the group", "In a party with others who have Questmark: under each quest, who else has it and how far they are; a word before turning in a quest someone isn't done with; the quests they have and you don't (right click to ask for one). The leader can right click a quest and choose Guide the group here: the others' navigation leads to it")
  Dropdown(category, "bossLoot", "Boss loot", {
    { "journal", "ForeverDungeonJournal" },
    { "atlasloot", "AtlasLoot" },
  }, "The addon a click on a boss in the dungeon card opens on that boss's loot (if it isn't installed, the other one)")
  Checkbox(category, "questItemMarks", "Quest items no longer needed", "Quest items left in your bags after their quest say so in their tooltip. With Baganator, a red cross can show on them too: turn on \"Questmark: quest item no longer needed\" in its Corner icons")
  Checkbox(category, "completeSound", "Sound on complete", "A discreet sound when a quest objective is done, and another when a quest is ready to turn in")
  Checkbox(category, "orcVoice", "Worker voice on quest complete", "When a quest is ready to turn in, a worker of your faction speaks instead of the usual sound: the orc peon's \"Work complete!\" for the Horde, the human peasant's \"Job's done!\" for the Alliance. Needs Sound on complete")
  Checkbox(category, "questLevels", "Quest levels", "Each quest's level before its name, in the tracker and the quest book's list: [12] The Defias Brotherhood")
  Checkbox(category, "autoQuests", "Accept and turn in quests", "Talking to someone accepts the quests they offer and turns in the ones ready. Not when you must choose a reward or a quest asks for money. Hold Shift to do it yourself")

  -- The quest book's options: a page of their own, under the tracker's
  -- (Options > AddOns > Questmark > Quest Book)
  local book, bookLayout = Settings.RegisterVerticalLayoutSubcategory(category, "Quest Book")
  Header(bookLayout, "Quest book")
  Checkbox(book, "bookKey", "Quest book on the quest log key", "The quest log's key (L) and its button in the game's menu bar open the quest book instead. Changes to the key wait for the end of a fight")
  Slider(book, "bookSize", "Book size", 70, 220, 5, "Size of the quest book, in % of its own size. Dragging its bottom right corner changes it too")
  Slider(book, "bookPaper", "Page brightness", 50, 100, 5, "How bright the quest book's pages are, in %. Lower: darker paper")
  Slider(book, "bookTextSize", "Text size", 9, 18, 1, "Size of the writing on the quest's page: the objectives, the description and the rewards")
  Slider(book, "bookTitleSize", "Titles size", 16, 34, 1, "Size of the quest book's titles. The headings go with it")
  FontDropdown(bookLayout, "bookListFont", "List font", "Font of the quest list: the quests and the zones", { "", "Default" })
  Slider(book, "bookListSize", "List size", 8, 18, 1, "Size of the quest list: the quests (the zones go with it)")
  Dropdown(book, "bookZoneColor", "Zones color", ColorChoices({ { "cream", "Cream" }, { "yellow", "Yellow" } }), "Color of the zones in the quest list")
  Dropdown(book, "bookQuestColor", "Quests color", ColorChoices({ { "auto", "By difficulty" }, { "cream", "Cream" }, { "yellow", "Yellow" } }), "Color of the quests in the quest list. By difficulty: like the game")
  Slider(book, "bookMapSize", "Map size", 40, 100, 2, "Size of the map shown over the right page (Show map), in % of the page")
  Slider(book, "bookMapZoom", "Map zoom", 1, 5, 0.5, "How close the map opens on the quest's place. 1: the whole zone")
  Checkbox(book, "bookAnimations", "Book animations", "The quest book opens and shuts as a book, its pages turn, its quests come in one after the other and a quest just done glows")
  Checkbox(book, "bookSounds", "Book sounds", "The sounds of the quest book opening, shutting and turning its pages")
  Checkbox(book, "bookPad", "Controller in the book", "With the game's controller support on, the controller moves through the open quest book: D-pad to choose, Cross (A) to open, Circle (B) to close, Square (X) to track, Triangle (Y) to follow, L1/R1 for the quest before or after, L2/R2 to scroll the page. With ConsolePort, its own cursor is used instead")

  -- Following a quest: the GPS and the game's navigation, a page of their
  -- own (Options > AddOns > Questmark > Quest GPS)
  local gps, gpsLayout = Settings.RegisterVerticalLayoutSubcategory(category, "Quest GPS")
  Header(gpsLayout, "Navigation")
  local navOn = Checkbox(gps, "navMarker", "Navigation marker", "With a quest followed, a mark on the screen over the place it leads to, with how far it is (out of sight, at the screen's edge, pointing the way). Shows even with Questie. It uses the game's in-game navigation, turned on by this")
  -- (the marker's own options: grayed out while it's off)
  local function NavOn() return Profile().navMarker end
  for _, option in ipairs({
    Dropdown(gps, "navStyle", "Marker", {
      { "game", "Default" }, { "diamond", "Diamond" }, { "pin", "Map pin" }, { "ring", "Ring" }, { "flag", "Flag" }, { "star", "Star" }, { "quest", "Quest mark" }, { "faction", "Faction crest" }, { "class", "Class icon" },
    }, "The navigation marker's shape. Default: the game's own mark (the size, color and distance options below are for the others)"),
    Slider(gps, "navSize", "Marker size", 16, 80, 2, "Size of the navigation marker"),
    Dropdown(gps, "navColor", "Marker color", ColorChoices({ { "title", "Default" } }), "Color of the navigation marker and its distance"),
    Slider(gps, "navTextSize", "Text size", 8, 20, 1, "Size of the distance under the marker"),
    Dropdown(gps, "navUnits", "Distance in", { { "yards", "Yards" }, { "meters", "Meters" } }, "The distance under the marker, in yards (like the game) or meters"),
  }) do
    if option and navOn and option.SetParentInitializer then option:SetParentInitializer(navOn, NavOn) end
  end
  Header(gpsLayout, "Quest GPS")
  local gpsOn = Checkbox(gps, "gpsArrow", "Quest GPS", "With a quest followed (click its icon in the tracker), an arrow on the screen points the way to it and says how far it is. Drag it to move it; right click it to stop following the quest")
  -- (the arrow's own options: grayed out while it's off)
  local function GpsOn() return Profile().gpsArrow end
  for _, option in ipairs({
    Dropdown(gps, "gpsStyle", "Arrow", {
      { "arrow", "Arrow" }, { "chevron", "Chevron" }, { "double", "Double chevron" },
      { "triangle", "Triangle" }, { "needle", "Compass needle" }, { "dart", "Dart" }, { "sword", "Sword" },
    }, "The GPS arrow's shape"),
    Slider(gps, "gpsSize", "Arrow size", 24, 96, 2, "Size of the GPS arrow"),
    Dropdown(gps, "gpsColor", "Arrow color", ColorChoices({ { "title", "Default" } }), "Color of the GPS arrow"),
    Slider(gps, "gpsTextSize", "Text size", 8, 20, 1, "Size of the distance under the arrow (the quest's name a little smaller)"),
    Dropdown(gps, "gpsUnits", "Distance in", { { "yards", "Yards" }, { "meters", "Meters" } }, "The distance under the arrow, in yards (like the game) or meters"),
    Checkbox(gps, "gpsQuestName", "Quest name", "The quest's name under the distance"),
  }) do
    if option and gpsOn and option.SetParentInitializer then option:SetParentInitializer(gpsOn, GpsOn) end
  end
  Header(gpsLayout, "Following")
  Checkbox(gps, "followNext", "Follow the next quest", "When you turn in the quest you were following, the nearest of the tracker's quests is followed, so the GPS and the marker go on to it")

  Settings.RegisterAddOnCategory(category)
  return category
end

-- Turning the tracker on or off: a reload, when you want it
Core:OnChange(function (key)
  if key ~= "useTracker" then return end
  local Popups = _G.StaticPopupDialogs
  if not Popups then return end
  Popups.QUESTMARK_RELOAD = Popups.QUESTMARK_RELOAD or {
    text = "Questmark: the tracker changes after a reload. Reload now?",
    button1 = _G.ACCEPT or "Accept",
    button2 = _G.CANCEL or "Cancel",
    OnAccept = function () _G.ReloadUI() end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
  }
  _G.StaticPopup_Show("QUESTMARK_RELOAD")
end)

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
    -- /qm testgroup: the group's faces, flag and cards with made-up friends
    if input and input:lower():match("^%s*testgroup") then
      Core.GroupTest()
      return
    end
    -- /qm icons: the icon each dungeon's card gets
    if input and input:lower():match("^%s*icons") then
      Core.DungeonIconReport()
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
