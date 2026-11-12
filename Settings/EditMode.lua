local _, ns = ...
local Core = ns.Core

----
-- EditMode
--
-- The tracker in Edit Mode: it can be moved there (Tracker.lua), and its
-- main settings show beside it when it's selected. They're the same
-- settings as in the Options window.

local function RoundTo2(value)
  return math.floor(value * 100 + 0.5) / 100
end

-- The colors from Core.COLORS as dropdown entries, after any extra ones
local function ColorValues(extra)
  local values = {}
  for _, entry in ipairs(extra or {}) do
    table.insert(values, entry)
  end
  for _, entry in ipairs(Core.COLORS) do
    table.insert(values, { text = entry[2], value = entry[1] })
  end
  return values
end

local function Setup()
  local LEM = Core.LEM
  if not LEM or not LEM.AddFrameSettings then return end

  local profile = function () return Core.db.profile end
  local defaults = Core.defaults.profile

  local function Set(key, value)
    profile()[key] = value
    Core:Changed(key)
  end

  LEM:AddFrameSettings(Core.frame, {
    {
      name = "Width",
      desc = "Width of the tracker",
      kind = LEM.SettingType.Slider,
      default = defaults.width,
      minValue = 200,
      maxValue = 500,
      valueStep = 10,
      get = function () return profile().width end,
      set = function (_, value) Set("width", value) end,
    },
    {
      name = "Height",
      desc = "The highest the tracker gets. When there's more, scroll it with the mouse wheel",
      kind = LEM.SettingType.Slider,
      default = defaults.maxHeight,
      minValue = 200,
      maxValue = 1400,
      valueStep = 10,
      get = function () return profile().maxHeight end,
      set = function (_, value) Set("maxHeight", value) end,
    },
    {
      name = "Fade out",
      desc = "The tracker fades out when you're not using it",
      kind = LEM.SettingType.Checkbox,
      default = defaults.fade,
      get = function () return profile().fade end,
      set = function (_, value) Set("fade", value) end,
    },
    {
      name = "Fade out delay",
      desc = "Seconds before the tracker fades out",
      kind = LEM.SettingType.Slider,
      default = defaults.holdTime,
      minValue = 1,
      maxValue = 60,
      valueStep = 1,
      get = function () return profile().holdTime end,
      set = function (_, value) Set("holdTime", value) end,
    },
    {
      name = "Faded visibility",
      desc = "How visible the tracker stays when faded. 0 hides it completely",
      kind = LEM.SettingType.Slider,
      default = defaults.fadedAlpha,
      minValue = 0,
      maxValue = 0.8,
      valueStep = 0.05,
      formatter = RoundTo2,
      get = function () return profile().fadedAlpha end,
      set = function (_, value) Set("fadedAlpha", RoundTo2(value)) end,
    },
    {
      name = "Title size",
      desc = "Size of the titles and the names of quests, achievements and recipes",
      kind = LEM.SettingType.Slider,
      default = defaults.headerFontSize,
      minValue = 8,
      maxValue = 24,
      valueStep = 1,
      get = function () return profile().headerFontSize end,
      set = function (_, value) Set("headerFontSize", value) end,
    },
    {
      name = "Objective size",
      desc = "Size of the objectives",
      kind = LEM.SettingType.Slider,
      default = defaults.lineFontSize,
      minValue = 8,
      maxValue = 24,
      valueStep = 1,
      get = function () return profile().lineFontSize end,
      set = function (_, value) Set("lineFontSize", value) end,
    },
    {
      name = "Line spacing",
      desc = "Extra space between the lines of a text that takes more than one line",
      kind = LEM.SettingType.Slider,
      default = defaults.lineSpacing,
      minValue = 0,
      maxValue = 10,
      valueStep = 1,
      get = function () return profile().lineSpacing end,
      set = function (_, value) Set("lineSpacing", value) end,
    },
    {
      name = "Background opacity",
      desc = "Opacity of the background behind the tracker. 0 turns it off",
      kind = LEM.SettingType.Slider,
      default = defaults.backgroundOpacity,
      minValue = 0,
      maxValue = 1,
      valueStep = 0.05,
      formatter = RoundTo2,
      get = function () return profile().backgroundOpacity end,
      set = function (_, value) Set("backgroundOpacity", RoundTo2(value)) end,
    },
    {
      name = "Background size",
      desc = "How far the background reaches past the text, where it fades out",
      kind = LEM.SettingType.Slider,
      default = defaults.backgroundSize,
      minValue = 0,
      maxValue = 80,
      valueStep = 2,
      get = function () return profile().backgroundSize end,
      set = function (_, value) Set("backgroundSize", value) end,
    },
    {
      name = "Background color",
      kind = LEM.SettingType.Dropdown,
      default = defaults.backgroundColor,
      values = {
        { text = "Black", value = "black" },
        { text = "Dark brown", value = "brown" },
        { text = "Dark blue", value = "blue" },
        { text = "Dark grey", value = "grey" },
      },
      get = function () return profile().backgroundColor end,
      set = function (_, value) Set("backgroundColor", value) end,
    },
    {
      name = "Title color",
      desc = "Color of the section titles",
      kind = LEM.SettingType.Dropdown,
      default = defaults.titleColor,
      values = ColorValues(),
      get = function () return profile().titleColor end,
      set = function (_, value) Set("titleColor", value) end,
    },
    {
      name = "Icon color",
      desc = "Color of the quest icons and minimize buttons",
      kind = LEM.SettingType.Dropdown,
      default = defaults.iconColor,
      values = ColorValues(),
      get = function () return profile().iconColor end,
      set = function (_, value) Set("iconColor", value) end,
    },
  })
end

Core:OnChange(function (key)
  if key == "editModeReady" and not Core.editModeReady then
    Core.editModeReady = true
    Setup()
  end
end)
