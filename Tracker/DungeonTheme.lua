local _, ns = ...
local Core = ns.Core

----
-- DungeonTheme
--
-- Each dungeon's color for its card: the sea is blue, Blackrock is fire,
-- the Scarlet Crusade is red, the undead are a sickly green... Dungeons not
-- in the list get a color from their icon (frost, fire, shadow, nature,
-- arcane), or the title color.

local SEA = { 0.30, 0.72, 0.98 }
local FIRE = { 1.00, 0.52, 0.20 }
local SCARLET = { 0.95, 0.30, 0.28 }
local UNDEAD = { 0.62, 0.88, 0.45 }
local SHADOW = { 0.68, 0.48, 1.00 }
local NATURE = { 0.45, 0.88, 0.42 }
local SAND = { 0.98, 0.78, 0.42 }
local STONE = { 0.82, 0.70, 0.50 }
local ARCANE = { 0.80, 0.52, 1.00 }
local STEEL = { 0.55, 0.82, 0.92 }
local IRON = { 0.66, 0.70, 0.80 }
local OGRE = { 0.90, 0.58, 0.32 }

local THEMES = {
  ["The Drowned City"] = SEA,
  ["Blackfathom Deeps"] = SEA,
  ["Alcaz Prison"] = SEA,
  ["The Deadmines"] = OGRE,
  ["Ragefire Chasm"] = FIRE,
  ["Blackrock Depths"] = FIRE,
  ["Lower Blackrock Spire"] = FIRE,
  ["Upper Blackrock Spire"] = FIRE,
  ["Molten Core"] = FIRE,
  ["Blackwing Lair"] = FIRE,
  ["Scarlet Monastery: Graveyard"] = SCARLET,
  ["Scarlet Monastery: Library"] = SCARLET,
  ["Scarlet Monastery: Armory"] = SCARLET,
  ["Scarlet Monastery: Cathedral"] = SCARLET,
  ["Scarlet Monastery"] = SCARLET,
  ["Stratholme: Living"] = SCARLET,
  ["Stratholme: Undead"] = UNDEAD,
  ["Stratholme"] = UNDEAD,
  ["Scholomance"] = UNDEAD,
  ["Razorfen Downs"] = UNDEAD,
  ["Naxxramas"] = UNDEAD,
  ["Shadowfang Keep"] = SHADOW,
  ["Sunken Temple"] = NATURE,
  ["Wailing Caverns"] = NATURE,
  ["Maraudon"] = NATURE,
  ["Razorfen Kraul"] = NATURE,
  ["Dire Maul: East"] = NATURE,
  ["Dire Maul: West"] = ARCANE,
  ["Dire Maul: North"] = OGRE,
  ["Blackmaw Hold"] = NATURE,
  ["Zul'Farrak"] = SAND,
  ["Uldaman"] = STONE,
  ["Shaper's Terrace"] = STONE,
  ["Excavation Site: Wetlands"] = STONE,
  ["City of Dalaran"] = ARCANE,
  ["Gnomeregan"] = STEEL,
  ["The Stockade"] = IRON,
  ["Krol'dok Stronghold"] = OGRE,
  ["Onyxia's Lair"] = FIRE,
  ["Zul'Gurub"] = NATURE,
  ["Ruins of Ahn'Qiraj"] = SAND,
  ["Temple of Ahn'Qiraj"] = SAND,
}

-- From the icon's name, for dungeons not in the list
local ICON_WORDS = {
  { "frost", SEA }, { "water", SEA }, { "fire", FIRE }, { "lava", FIRE }, { "sulfuras", FIRE },
  { "shadow", SHADOW }, { "bone", UNDEAD }, { "skull", UNDEAD }, { "nature", NATURE },
  { "arcane", ARCANE }, { "gizmo", STEEL }, { "platnum", STEEL }, { "dragon", FIRE },
  { "troll", NATURE }, { "orc", OGRE }, { "pick", STONE }, { "amethyst", ARCANE },
}

-- The kind of scene behind each color's heading (DungeonScene.lua)
local STYLES = {
  [SEA] = "water", [FIRE] = "fire", [SCARLET] = "scarlet", [UNDEAD] = "undead",
  [SHADOW] = "shadow", [NATURE] = "nature", [SAND] = "sand", [ARCANE] = "arcane",
  [STONE] = "dust", [STEEL] = "dust", [IRON] = "dust", [OGRE] = "dust",
}

---
-- A dungeon's color (r, g, b) and the kind of scene behind its heading
function Core.DungeonTheme(name, icon)
  local theme = name and THEMES[name]
  if not theme and type(icon) == "string" then
    local lower = icon:lower()
    for _, entry in ipairs(ICON_WORDS) do
      if lower:find(entry[1], 1, true) then theme = entry[2] break end
    end
  end
  if theme then return theme[1], theme[2], theme[3], STYLES[theme] end
  local r, g, b = Core:CardColor()
  return r, g, b, "dust"
end
