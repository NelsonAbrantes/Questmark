local _, ns = ...
local Core = ns.Core

-- luacheck: push ignore 113
local C_Timer = C_Timer
local CreateFrame = CreateFrame
local GetInstanceInfo = GetInstanceInfo
local GetMoney = GetMoney
local IsInInstance = IsInInstance
local UnitLevel = UnitLevel
local UnitXP = UnitXP
local UnitXPMax = UnitXPMax
local strsplit = strsplit
local time = time
-- luacheck: pop

local KEEP_RUN = 15 * 60 -- seconds outside before a run is over (a corpse run keeps it)

----
-- Dungeon
--
-- Inside a dungeon or raid (Options: Dungeon info), a section at the top of
-- the tracker with the run: how long it's taking, the bosses (killed ones
-- checked), the experience and the gold you've made since you came in, and
-- how many times you died. A run is kept while you go out and back (a
-- corpse run, a /reload) and starts again in another dungeon, or after a
-- while outside. With "Dungeon quests only", only that dungeon's quests show
-- (Data.lua).

local function Profile() return Core.db.profile end

local inside = false
local clock -- the once-a-second clock (below): it only runs inside
local LookForDeadBosses, CountGroupDeaths -- below
local events = CreateFrame("Frame")

---
-- True inside a dungeon or raid
function Core.InDungeon()
  return inside
end

-- The run, per character (kept over a /reload)
local function Run()
  return Core.db.char.dungeonRun
end

local function InstanceID()
  local name, _, _, _, _, _, _, instanceID = GetInstanceInfo()
  return instanceID, name
end

----
-- Bosses. The list comes from, in this order:
-- 1. the game's encounter journal, if it has one for this dungeon
-- 2. the ForeverDungeonJournal addon, if it's installed (it knows the
--    dungeons added by WoW: Forever)
-- 3. AtlasLoot, if it's installed
-- 4. the bosses killed in this dungeon before, which the addon learns
-- Rare bosses are marked: they don't always show, so a run is done without
-- them.

local function GameJournal()
  local EJ_GetInstanceForMap, EJ_GetEncounterInfoByIndex = _G.EJ_GetInstanceForMap, _G.EJ_GetEncounterInfoByIndex
  local map = _G.C_Map and _G.C_Map.GetBestMapForUnit and _G.C_Map.GetBestMapForUnit("player")
  if not (EJ_GetInstanceForMap and EJ_GetEncounterInfoByIndex and map) then return nil end
  local ok, journalID = pcall(EJ_GetInstanceForMap, map)
  if not ok or not journalID or journalID == 0 then return nil end
  local bosses = {}
  for i = 1, 30 do
    -- (name, description, journal IDs..., then the ID the kill reports)
    local found, name, _, _, _, _, _, encounterID = pcall(EJ_GetEncounterInfoByIndex, i, journalID)
    if not found or not name then break end
    table.insert(bosses, { name = name, id = encounterID })
  end
  return #bosses > 0 and bosses or nil
end

-- The dungeon in the ForeverDungeonJournal addon, if it's installed
-- Found by the dungeon's name, or by the map you're on: the game names some
-- dungeons with wings by the whole place ("Scarlet Monastery"), the addon
-- each wing ("Scarlet Monastery: Library"). Returns the dungeon, the addon
-- and the name the addon gives it.
local function JournalDungeon(name)
  local journal = _G.ForeverDungeonJournal_NS
  local db = type(journal) == "table" and type(journal.DB) == "table" and journal.DB
  if not db then return nil, nil end
  local key = (db[name] and name) or (_G.GetRealZoneText and db[_G.GetRealZoneText()] and _G.GetRealZoneText())
  -- (the game's name may differ from the addon's: "Stormwind Stockade" is
  -- its "The Stockade". Then by the dungeon's number, inside it)
  if not key and type(journal.INSTANCE_ID_TO_DUNGEON) == "table" and _G.IsInInstance() then
    local byID = journal.INSTANCE_ID_TO_DUNGEON[select(8, GetInstanceInfo())]
    if byID and db[byID] then key = byID end
  end
  if not key and type(journal.DUNGEON_MAPS) == "table" then
    local map = _G.C_Map and _G.C_Map.GetBestMapForUnit and _G.C_Map.GetBestMapForUnit("player")
    for dungeonName, info in pairs(journal.DUNGEON_MAPS) do
      for _, floor in ipairs(type(info) == "table" and info.floors or {}) do
        if map and floor.uiMapID == map and db[dungeonName] then key = dungeonName break end
      end
      if key then break end
    end
  end
  -- (Stratholme: both sides are one dungeon to the game. The side from the
  -- room you're in, as the journal addon tells them apart)
  if not key and type(journal.WingFromText) == "function" then
    for _, text in ipairs({ _G.GetSubZoneText and _G.GetSubZoneText(), _G.GetMinimapZoneText and _G.GetMinimapZoneText() }) do
      local ok, wing = pcall(journal.WingFromText, text)
      if ok and type(wing) == "string" and db[wing] then key = wing break end
    end
  end
  local dungeon = key and db[key]
  return type(dungeon) == "table" and dungeon or nil, journal, key
end

-- The creatures a boss of the journal addon is made of, each to be killed
-- before it's done (nil: just the one):
-- - a group (the Sunken Temple's "Altar Bosses": its six trolls, which the
--   tracker shows only as the group)
-- - two fought together (killWith: "Dreamscythe & Weaver")
local function JournalParts(boss, byNpc)
  local function Names(list)
    local names = {}
    for _, value in ipairs(type(list) == "table" and list or {}) do
      if type(value) == "string" then names[#names + 1] = value end
    end
    return #names > 0 and names or nil
  end
  local parts = {}
  if type(boss.children) == "table" then
    for _, id in ipairs(boss.children) do
      id = tonumber(id)
      local child = id and byNpc[id]
      if id then
        table.insert(parts, { npcID = id, name = child and child.name, aliases = child and Names(child.aliases) })
      end
    end
  elseif type(boss.killWith) == "table" then
    table.insert(parts, { npcID = tonumber(boss.npcID), aliases = Names(boss.aliases) })
    for _, partner in ipairs(boss.killWith) do
      if type(partner) == "table" then
        local id
        for _, value in ipairs(partner) do
          if type(value) == "number" then id = value end
        end
        local names = Names(partner)
        table.insert(parts, { npcID = id, name = names and names[1], aliases = names })
      end
    end
  end
  return #parts > 1 and parts or nil
end

-- The kills the game reports for a dungeon of the journal addon (boss name
-- -> its encounter IDs)
local function JournalEncounters(journal, key)
  local encounters = {}
  local list = type(journal.RUNLOG_ENCOUNTERS) == "table" and journal.RUNLOG_ENCOUNTERS or {}
  for id, info in pairs(list) do
    if type(id) == "number" and type(info) == "table" and info[1] == key and type(info[2]) == "string" then
      encounters[info[2]] = encounters[info[2]] or {}
      encounters[info[2]][id] = true
    end
  end
  return encounters
end

local function JournalAddon(name)
  local dungeon, journal, key = JournalDungeon(name)
  if not dungeon or type(dungeon.bosses) ~= "table" then return nil end
  -- Its pictures of the bosses (creature -> what the game draws for it)
  local displays = type(journal.STATIC_DISPLAY_IDS) == "table" and journal.STATIC_DISPLAY_IDS or {}
  local encounters = JournalEncounters(journal, key)
  local byNpc = {}
  for _, boss in ipairs(dungeon.bosses) do
    if type(boss) == "table" and tonumber(boss.npcID) then byNpc[tonumber(boss.npcID)] = boss end
  end
  local bosses = {}
  for _, boss in ipairs(dungeon.bosses) do
    -- (a group's members show only as the group)
    if type(boss) == "table" and type(boss.name) == "string" and not boss.trash and not boss.trackerHidden then
      local display = displays[boss.portraitNpcID or boss.npcID] or boss.displayID
      table.insert(bosses, {
        name = boss.name, npcID = tonumber(boss.npcID), display = tonumber(display),
        aliases = type(boss.aliases) == "table" and boss.aliases or nil,
        rare = boss.rare and true or nil,
        parts = JournalParts(boss, byNpc), ids = encounters[boss.name],
      })
    end
  end
  return #bosses > 0 and bosses or nil
end

----
-- A click on a boss in the card: its loot, in the journal addon or in
-- AtlasLoot (Options: Boss loot; the other one if that one isn't there)

-- The journal addon on the boss's page. False if it can't.
local function JournalLoot(dungeonName, bossName)
  local dungeon, journal, key = JournalDungeon(dungeonName)
  if not dungeon or type(dungeon.bosses) ~= "table" or type(journal.OpenBossPage) ~= "function" then return false end
  for i, boss in ipairs(dungeon.bosses) do
    local found = type(boss) == "table" and boss.name == bossName
    for _, alias in ipairs(type(boss) == "table" and type(boss.aliases) == "table" and boss.aliases or {}) do
      if alias == bossName then found = true end
    end
    if found then
      local frame = _G.ForeverDungeonJournalFrame
      if frame and not frame:IsShown() then frame:Show() end
      pcall(journal.OpenBossPage, key, i)
      return true
    end
  end
  return false
end

-- AtlasLoot on the boss. Its dungeons load when first needed (not in
-- combat, so then it can't). Found by the dungeon's map, else its name; the
-- boss by its creature, else its name. False if it can't.
local ATLAS_MODULE = "AtlasLootClassic_DungeonsAndRaids"

-- AtlasLoot's dungeons and raids (nil without it, or in combat before it
-- loaded them), and AtlasLoot
local function AtlasData()
  local AL = _G.AtlasLoot
  if type(AL) ~= "table" or not (AL.Loader and AL.ItemDB) then return nil end
  if not AL.Loader:IsModuleLoaded(ATLAS_MODULE) then
    if _G.InCombatLockdown() then return nil end
    pcall(AL.Loader.LoadModule, AL.Loader, ATLAS_MODULE)
  end
  local ok, data = pcall(AL.ItemDB.Get, AL.ItemDB, ATLAS_MODULE)
  if not ok or type(data) ~= "table" then return nil end
  return data, AL
end

-- A dungeon's name in AtlasLoot, without the picture after it
local function AtlasName(dungeon)
  if type(dungeon) ~= "table" or type(dungeon.name) ~= "string" or type(dungeon.items) ~= "table" then return nil end
  local name = dungeon.name:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""):gsub("|T.-|t", "")
  return strtrim(name)
end

-- The AtlasLoot dungeon called `name` (the classic one over a later one
-- with the same name)
local function AtlasDungeon(name)
  local data, AL = AtlasData()
  local found
  for _, dungeon in pairs(data or {}) do
    if AtlasName(dungeon) == name then
      if dungeon.gameVersion == AL.CLASSIC_VERSION_NUM or dungeon.gameVersion == 0 then return dungeon end
      found = found or dungeon
    end
  end
  return found
end

-- The bosses of a dungeon in AtlasLoot
local function AtlasBosses(name)
  local dungeon = AtlasDungeon(name)
  local bosses = {}
  for _, item in ipairs(dungeon and dungeon.items or {}) do
    if type(item) == "table" and type(item.name) == "string" and item.npcID then
      -- (its face: the first of the creatures AtlasLoot draws for it)
      local displays = type(item.DisplayIDs) == "table" and item.DisplayIDs[1]
      local display = type(displays) == "table" and displays[1] or displays
      table.insert(bosses, { name = item.name, npcID = tonumber(item.npcID), display = tonumber(display) })
    end
  end
  return #bosses > 0 and bosses or nil
end

local function AtlasLoot(entry, boss)
  local data, AL = AtlasData()
  local frame = AL and AL.GUI and AL.GUI.frame
  if not (data and frame and frame.moduleSelect and frame.subCatSelect and frame.boss) then return false end
  local classic = AL.CLASSIC_VERSION_NUM
  local key, bossIndex, best
  for name, dungeon in pairs(data) do
    if AtlasName(dungeon) then
      local same = (type(entry.id) == "number" and dungeon.InstanceID == entry.id)
        or AtlasName(dungeon) == entry.title
      if same then
        for i, item in ipairs(dungeon.items) do
          if type(item) == "table" and ((boss.npcID and item.npcID == boss.npcID) or item.name == boss.name) then
            -- (the classic dungeon over the later one with the same map)
            local rank = (dungeon.gameVersion == classic or dungeon.gameVersion == 0) and 2 or 1
            if not best or rank > best then key, bossIndex, best = name, i, rank end
            break
          end
        end
      end
    end
  end
  if not key then return false end
  if not frame:IsShown() then frame:Show() end
  local version = data[key].gameVersion
  local saved = AL.db and AL.db.GUI
  if saved and version and version ~= 0 then saved.selectedGameVersion = version end
  pcall(frame.moduleSelect.SetSelected, frame.moduleSelect, ATLAS_MODULE)
  pcall(frame.subCatSelect.SetSelected, frame.subCatSelect, key)
  pcall(frame.boss.SetSelected, frame.boss, bossIndex)
  return true
end

function Core.OpenBossLoot(entry, boss)
  if not entry or not boss then return end
  if Core.db.profile.bossLoot == "atlasloot" then
    if not AtlasLoot(entry, boss) then JournalLoot(entry.title, boss.name) end
  elseif not JournalLoot(entry.title, boss.name) then
    AtlasLoot(entry, boss)
  end
end

-- Bosses killed in each dungeon before (dungeon name -> names, in the order
-- they were killed), for every character
local function Learned(name)
  Core.db.global.learnedBosses = Core.db.global.learnedBosses or {}
  local learned = Core.db.global.learnedBosses[name or ""]
  if not learned or #learned == 0 then return nil end
  local bosses = {}
  for _, bossName in ipairs(learned) do table.insert(bosses, { name = bossName }) end
  return bosses
end

local function Learn(dungeon, bossName)
  if not dungeon or not bossName then return end
  Core.db.global.learnedBosses = Core.db.global.learnedBosses or {}
  local learned = Core.db.global.learnedBosses[dungeon] or {}
  Core.db.global.learnedBosses[dungeon] = learned
  for _, known in ipairs(learned) do
    if known == bossName then return end
  end
  table.insert(learned, bossName)
end

-- The faces of bosses, learned when one is seen or from the group (boss
-- name -> what the game draws for it), for every character. Only ones the
-- game showed: never the journal addons' pictures.
local function Faces()
  Core.db.global.learnedFaces = Core.db.global.learnedFaces or {}
  return Core.db.global.learnedFaces
end

-- A boss's face: a journal addon's, else one learned, else the addon's own
-- list (DungeonFaces.lua)
-- Also true if the list is only the bosses learned before: maybe not all of
-- them (a run doesn't end on it)
local function BossList(name)
  local bosses = GameJournal() or JournalAddon(name) or AtlasBosses(name)
  local learned = not bosses
  bosses = bosses or Learned(name)
  local faces, known = Faces(), Core.KNOWN_FACES or {}
  for _, boss in ipairs(bosses or {}) do
    boss.display = boss.display or faces[boss.name] or known[boss.name]
  end
  return bosses, learned and bosses ~= nil
end
local SetBosses -- (below)

-- Icons for dungeons the journal addon doesn't know
local OWN_ICONS = {
  ["The Hall of Thanes"] = "Interface\\Icons\\inv_misc_statue_07",
}

-- Icons that fit better than the journal addon's: the game's own, most
-- often the face of the dungeon's best known boss. Several names each (the
-- game's icons aren't listed anywhere): the first the game has is used, else
-- the journal addon's icon stays (/qm icons tells which)
local SCARLET = { "achievement_boss_highinquistor_whitemane", "achievement_boss_highinquisitor_whitemane",
  "achievement_boss_whitemane", "achievement_boss_herod" }
local BETTER_ICONS = {
  ["The Deadmines"] = { "achievement_boss_edwinvancleef" },
  ["Alcaz Prison"] = { "inv_misc_bandana_03" }, -- the Defias' bandana: they hold it
  ["Ragefire Chasm"] = { "achievement_boss_taragaman", "achievement_boss_taragamanthehungerer",
    "achievement_boss_bazzalan" },
  ["Wailing Caverns"] = { "achievement_boss_mutanus_the_devourer", "achievement_boss_mutanusthedevourer",
    "achievement_boss_mutanus" },
  ["Shadowfang Keep"] = { "achievement_boss_archmagearugal", "achievement_boss_archmage_arugal",
    "achievement_boss_arugal" },
  ["Blackfathom Deeps"] = { "achievement_boss_bazil_akumai", "achievement_boss_akumai" },
  ["The Stockade"] = { "achievement_boss_bazil_thredd", "achievement_boss_bazilthredd" },
  ["Gnomeregan"] = { "achievement_boss_mekgineer_thermaplugg", "achievement_boss_mekgineerthermaplugg",
    "achievement_boss_thermaplugg" },
  ["Razorfen Kraul"] = { "achievement_boss_charlgarazorflank", "achievement_boss_charlga_razorflank" },
  ["Scarlet Monastery"] = SCARLET,
  ["Scarlet Monastery: Cathedral"] = SCARLET,
  ["Scarlet Monastery: Armory"] = { "achievement_boss_herod" },
  ["Scarlet Monastery: Library"] = { "achievement_boss_arcanistdoan", "achievement_boss_arcanist_doan" },
  ["Scarlet Monastery: Graveyard"] = { "achievement_boss_bloodmagethalnos", "achievement_boss_bloodmage_thalnos" },
  ["Razorfen Downs"] = { "achievement_boss_amnennarthecoldbringer", "achievement_boss_amnennar_the_coldbringer",
    "achievement_boss_amnennar" },
  ["Uldaman"] = { "achievement_boss_archaedas" },
  ["Zul'Farrak"] = { "achievement_boss_chiefukorzsandscalp", "achievement_boss_chief_ukorz_sandscalp",
    "achievement_boss_gahzrilla" },
  ["Maraudon"] = { "achievement_boss_princesstheradras", "achievement_boss_princess_theradras" },
  ["Sunken Temple"] = { "achievement_boss_shadeoferanikus", "achievement_boss_eranikus",
    "achievement_boss_avatarofhakkar" },
  ["Blackrock Depths"] = { "achievement_boss_emperordagranthaurissan", "achievement_boss_emperor_dagran_thaurissan" },
  ["Lower Blackrock Spire"] = { "achievement_boss_overlordwyrmthalak", "achievement_boss_overlord_wyrmthalak" },
  ["Upper Blackrock Spire"] = { "achievement_boss_generaldrakkisath", "achievement_boss_general_drakkisath" },
  ["Dire Maul: East"] = { "achievement_boss_alzzinthewildshaper", "achievement_boss_alzzin" },
  ["Dire Maul: West"] = { "achievement_boss_princetortheldrin", "achievement_boss_prince_tortheldrin",
    "achievement_boss_immolthar" },
  ["Dire Maul: North"] = { "achievement_boss_kinggordok", "achievement_boss_king_gordok" },
  ["Scholomance"] = { "achievement_boss_darkmastergandling", "achievement_boss_darkmaster_gandling" },
  ["Stratholme"] = { "achievement_boss_baronrivendare", "achievement_boss_baron_rivendare" },
  ["Stratholme: Undead"] = { "achievement_boss_baronrivendare", "achievement_boss_baron_rivendare" },
  ["Stratholme: Living"] = { "achievement_boss_balnazzar" },
  ["Molten Core"] = { "achievement_boss_ragnaros" },
  ["Onyxia's Lair"] = { "achievement_boss_onyxia" },
  ["Blackwing Lair"] = { "achievement_boss_nefarion" },
  ["Zul'Gurub"] = { "achievement_boss_hakkar" },
  ["Ruins of Ahn'Qiraj"] = { "achievement_boss_ossiriantheunscarred", "achievement_boss_ossirian" },
  ["Temple of Ahn'Qiraj"] = { "achievement_boss_cthun" },
  ["Naxxramas"] = { "achievement_boss_kelthuzad_01", "achievement_boss_kelthuzad" },
}
-- (shown in gray, for an icon whose color doesn't fit)
local GRAY_ICONS = {}

-- The better icon of a dungeon the game has (nil: the journal addon's stays;
-- also when the game can't tell which icons it has)
local function BetterIcon(name)
  local FileID = _G.GetFileIDFromPath
  if not (name and FileID and BETTER_ICONS[name]) then return nil end
  for _, file in ipairs(BETTER_ICONS[name]) do
    local path = "Interface\\Icons\\"..file
    if FileID(path) then return path end
  end
end

-- (/qm icons: which icon each dungeon gets)
function Core.DungeonIconReport()
  local names = {}
  for name in pairs(BETTER_ICONS) do names[#names + 1] = name end
  table.sort(names)
  for _, name in ipairs(names) do
    local path = BetterIcon(name)
    print(("|T%s:16|t %s: %s"):format(path or "Interface\\Icons\\INV_Misc_QuestionMark", name,
      path and path:match("([^\\]+)$") or "|cff999999the journal's|r"))
  end
end

----
-- Starting, keeping and ending a run

local function StartRun(instanceID, name)
  Core.db.char.dungeonRun = {
    id = instanceID, name = name, start = time(), seen = time(),
    money = GetMoney(), xp = 0, deaths = 0, killed = {},
    level = UnitLevel("player"), lastXP = UnitXP("player"), lastMax = UnitXPMax("player"),
  }
end

-- How things were when you last came in: a run found to be in a new copy of
-- the dungeon (below) starts from then
local function EntrySnapshot()
  return {
    start = time(), money = GetMoney(),
    level = UnitLevel("player"), xp = UnitXP("player"), max = UnitXPMax("player"),
  }
end

local function UpdateInside()
  local inInstance, instanceType = IsInInstance()
  local wasInside = inside
  inside = inInstance and (instanceType == "party" or instanceType == "raid") or false
  if inside and clock then clock:Show() end
  if inside then
    local instanceID, name = InstanceID()
    local run = Run()
    if not run or run.id ~= instanceID or time() - (run.seen or 0) > KEEP_RUN then
      StartRun(instanceID, name)
    else
      run.seen = time()
    end
    if not wasInside then
      Run().entry = EntrySnapshot()
      C_Timer.After(5, Core.ShareDungeonFaces)
    end
    SetBosses(Run(), Run().name)
    -- Its icon, zone and levels, from the journal addon (and the wing's name)
    local dungeon, _, key = JournalDungeon(Run().name)
    if dungeon then
      if key and key ~= Run().name then
        Run().name = key
        SetBosses(Run(), key)
      end
      Run().icon = type(dungeon.icon) == "string" and dungeon.icon or nil
      Run().location = type(dungeon.location) == "string" and dungeon.location or nil
      Run().levels = type(dungeon.level) == "string" and dungeon.level or nil
    end
    local better = BetterIcon(Run().name)
    Run().icon = better or Run().icon or OWN_ICONS[Run().name]
    Run().iconGray = better and GRAY_ICONS[Run().name] or nil
  end
  if inside ~= wasInside then Core:Changed("layout") end
end

-- Experience: what's new since the last look (across a level up too)
local function CountXP()
  local run = Run()
  if not inside or not run then return end
  local level, xp, max = UnitLevel("player"), UnitXP("player"), UnitXPMax("player")
  if level > (run.level or level) then
    run.xp = run.xp + (run.lastMax - run.lastXP) + xp
  elseif xp > run.lastXP then
    run.xp = run.xp + xp - run.lastXP
  end
  run.level, run.lastXP, run.lastMax = level, xp, max
end

-- The fastest run of each dungeon (dungeon name -> seconds, for all your
-- characters)
local function Records()
  Core.db.global.dungeonRecords = Core.db.global.dungeonRecords or {}
  return Core.db.global.dungeonRecords
end

-- The run is done: its time kept if it's the dungeon's fastest (run.best:
-- the record it had to beat)
local function Finish(run)
  if run.finished then return end
  run.finished = time()
  run.finishedName = run.name
  if not run.name then return end
  local took, records = run.finished - run.start, Records()
  run.best = records[run.name]
  if not run.best or took < run.best then
    records[run.name] = took
    run.newRecord = true
  end
  -- (and in the day's diary, Behavior/Diary.lua)
  if Core.DiaryDungeon then Core.DiaryDungeon(run) end
end

local function AllKilled(run)
  -- (not on a list made from this run's kills or learned before: the
  -- dungeon's other bosses may be missing from it)
  if not run.bosses or run.guessed then return false end
  for _, boss in ipairs(run.bosses) do
    if not boss.rare and not run.killed[boss.name] then return false end
  end
  return true
end

-- Done too early, on a list that missed bosses (found later: the side of
-- Stratholme you're on): going on, and the record it set taken back
local function Unfinish(run)
  -- (under the name it had then: it may have changed since)
  local name = run.finishedName or run.name
  if run.newRecord and name then Records()[name] = run.best end
  if Core.DiaryUndoDungeon then Core.DiaryUndoDungeon(name, run.finished - run.start) end
  run.finished, run.best, run.newRecord, run.finishedName = nil, nil, nil, nil
end

-- The dungeon's boss list put on the run (if one is found)
-- A dungeon with sides (Blackrock Spire, Stratholme, Dire Maul...) whose
-- side isn't known yet: the bosses of all its sides, each with its side, so
-- they show from the start (and a kill tells the side, LookForWing)
local function AllSides(run, name)
  if not run or not run.id or JournalDungeon(name) then return nil end
  local journal = _G.ForeverDungeonJournal_NS
  local groups = type(journal) == "table" and journal.RunLogWingGroups
  local wings = type(groups) == "table" and groups[run.id]
  if type(wings) ~= "table" then return nil end
  local all = {}
  for _, wing in ipairs(wings) do
    for _, boss in ipairs(JournalAddon(wing) or {}) do
      boss.side = wing
      all[#all + 1] = boss
    end
  end
  if #all == 0 then return nil end
  local faces, known = Faces(), Core.KNOWN_FACES or {}
  for _, boss in ipairs(all) do
    boss.display = boss.display or faces[boss.name] or known[boss.name]
  end
  return all
end

function SetBosses(run, name)
  local sides = AllSides(run, name)
  local bosses, learned
  if sides then
    bosses = sides
  else
    bosses, learned = BossList(name)
  end
  if not bosses then return end
  run.bosses, run.guessed = bosses, learned or nil
  if run.finished and not AllKilled(run) then Unfinish(run) end
end

-- True if a boss (or one of the creatures it's made of) is that creature
local function Is(thing, name, npcID)
  if npcID and thing.npcID == npcID then return true end
  if not name then return false end
  if thing.name == name then return true end
  for _, alias in ipairs(thing.aliases or {}) do
    if alias == name then return true end
  end
  return false
end

-- The boss of the list that a kill is (by its ID, name or other names), and
-- which of the creatures it's made of (nil: the boss itself)
local function FindBoss(run, name, encounterID, npcID)
  for _, boss in ipairs(run.bosses or {}) do
    if encounterID and (boss.id == encounterID or (boss.ids and boss.ids[encounterID])) then return boss end
    for i, part in ipairs(boss.parts or {}) do
      if Is(part, name, npcID) then return boss, i end
    end
    if Is(boss, name, npcID) then return boss end
  end
end

-- A boss died: checked in the list (and learned for next time when the
-- game said it was a boss). A boss made of several creatures is checked
-- when all of them died, or when the game says its fight is won.
local function Killed(name, encounterID, npcID, fromEncounter)
  local run = Run()
  if not run then return end
  local boss, part = FindBoss(run, name, encounterID, npcID)
  if boss then
    if fromEncounter then Learn(run.name, boss.name) end
    if run.killed[boss.name] then return end
    if part and not fromEncounter then
      run.killedParts = run.killedParts or {}
      local dead = run.killedParts[boss.name] or {}
      run.killedParts[boss.name] = dead
      if dead[part] then return end
      dead[part] = true
      for i in ipairs(boss.parts) do
        if not dead[i] then return end
      end
    end
    run.killed[boss.name] = true
    run.killedAt = run.killedAt or {}
    run.killedAt[boss.name] = time() - run.start
  elseif fromEncounter and name then
    -- A boss the list didn't have: added, and remembered for next time
    -- (no list at all: the dungeon's other bosses aren't known)
    if not run.bosses then run.guessed = true end
    run.killed[name] = true
    run.killedAt = run.killedAt or {}
    run.killedAt[name] = time() - run.start
    run.bosses = run.bosses or {}
    table.insert(run.bosses, { name = name, id = encounterID })
    Learn(run.name, name)
  else
    return
  end
  if AllKilled(run) then Finish(run) end
  Core.Refresh()
end

-- The game doesn't report every boss kill in the dungeons WoW: Forever added,
-- and addons may not read the combat log here. So, once a second: is one of
-- the list's bosses lying dead as your target, a group member's target or
-- one of the encounter's bosses? In combat the game hides who a creature is,
-- so one that dies while the fight goes on (a boss's add, a pack's leader)
-- is looked for again when the fight is over, as the corpse under the mouse,
-- and as the corpse looted (below).
local WATCHED = { "target", "focus", "mouseover", "boss1", "boss2", "boss3", "boss4", "boss5",
  "party1target", "party2target", "party3target", "party4target" }

-- The creature a GUID is (Creature-0-server-map-copy-npc-spawn), nil if
-- it can't be read or isn't one
local function NpcID(guid)
  if not (Core.Readable(guid) and type(guid) == "string") then return nil end
  local kind, _, _, _, _, npc = strsplit("-", guid)
  if kind ~= "Creature" and kind ~= "Vehicle" then return nil end
  return tonumber(npc)
end

function LookForDeadBosses()
  for _, unit in ipairs(WATCHED) do
    if _G.UnitExists(unit) and _G.UnitIsDead(unit) and not _G.UnitIsPlayer(unit) then
      local npcID = NpcID(_G.UnitGUID(unit))
      local name = _G.UnitName(unit)
      if npcID then Killed(Core.Readable(name) and name or nil, nil, npcID, false) end
    end
  end
end

-- The corpses whose loot is open
local function LookInLoot()
  local Count, Source = _G.GetNumLootItems, _G.GetLootSourceInfo
  if not (Count and Source) then return end
  for slot = 1, Count() or 0 do
    -- (guid, how many, guid, how many...: an area loot has several corpses)
    local sources = { pcall(Source, slot) }
    if sources[1] then
      for i = 2, #sources, 2 do
        local npcID = NpcID(sources[i])
        if npcID then Killed(nil, nil, npcID, false) end
      end
    end
  end
end

-- A reset dungeon is a new copy of it, with the same map: the run starts
-- again (from when you came in) when a creature around shows a copy other
-- than the run's. (A creature's GUID says which copy it's in:
-- Creature-0-server-map-copy-npc-spawn.)
local COPY_UNITS = { "target", "mouseover", "focus", "boss1",
  "party1target", "party2target", "party3target", "party4target" }

local function LookForNewCopy(run)
  for _, unit in ipairs(COPY_UNITS) do
    local guid = _G.UnitExists(unit) and _G.UnitGUID(unit)
    if guid and Core.Readable(guid) and type(guid) == "string" then
      local kind, _, _, map, copy = strsplit("-", guid)
      if (kind == "Creature" or kind == "Vehicle") and copy and tonumber(map) == run.id then
        if not run.copy then
          run.copy = copy
        elseif run.copy ~= copy then
          local entry = run.entry or EntrySnapshot()
          StartRun(run.id, run.name)
          local new = Run()
          new.start, new.money = entry.start, entry.money
          new.level, new.lastXP, new.lastMax = entry.level, entry.xp, entry.max
          new.copy, new.entry = copy, entry
          -- (counted from the way in: the quests turned in since then too)
          new.questXP, new.questMoney = run.questXP, run.questMoney
          SetBosses(new, run.name)
          if not new.bosses then new.bosses, new.guessed = run.bosses, run.guessed end
          new.icon, new.iconGray, new.location, new.levels = run.icon, run.iconGray, run.location, run.levels
          Core.Refresh()
        end
        return
      end
    end
  end
end

-- A boss of the list without a face, seen (alive or dead) as your target, a
-- group member's target or one of the encounter's bosses: what the game draws
-- for it is learned (a hidden model shown that unit tells it), and drawn from
-- then on
local probe
local function LookForFaces(run)
  local faces = Faces()
  for _, unit in ipairs(WATCHED) do
    if _G.UnitExists(unit) and not _G.UnitIsPlayer(unit) then
      local name = _G.UnitName(unit)
      name = Core.Readable(name) and name or nil
      local boss, part = nil, nil
      if name then boss, part = FindBoss(run, name) end
      -- (not a boss's partner or a group's member: the boss has its own face)
      if part then boss = nil end
      -- (the encounter's bosses too, when the list doesn't know them yet)
      local key = boss and boss.name or (name and unit:find("^boss") and name)
      if key and not faces[key] then
        if not probe then
          probe = CreateFrame("PlayerModel", nil, _G.UIParent)
          probe:SetSize(1, 1)
          probe:SetPoint("TOPLEFT", _G.UIParent, "BOTTOMRIGHT", 10, -10)
          probe:SetAlpha(0)
        end
        if probe.SetUnit and probe.GetDisplayInfo then
          pcall(probe.SetUnit, probe, unit)
          local ok, display = pcall(probe.GetDisplayInfo, probe)
          display = ok and tonumber(display)
          if display and display > 0 then
            faces[key] = display
            if boss and not boss.display then
              boss.display = display
              Core.Refresh()
            end
          end
        end
      end
    end
  end
end

----
-- Faces shared in the group: entering a dungeon in a group, or someone
-- joining while you're in one, the addon tells the others the faces it
-- learned of that dungeon's bosses, and keeps the ones it didn't know.
-- Never in combat, at most once every 30 seconds.

local FACES_PREFIX = "QuestmarkF"
local SHARE_EVERY = 30
local lastShared = 0

local function GroupChannel()
  if _G.IsInGroup(_G.LE_PARTY_CATEGORY_INSTANCE) then return "INSTANCE_CHAT" end
  if _G.IsInRaid() then return "RAID" end
  if _G.IsInGroup() then return "PARTY" end
end

function Core.ShareDungeonFaces()
  local run = inside and Run()
  local Info = _G.C_ChatInfo
  local channel = GroupChannel()
  if not (run and run.bosses and channel and Info and Info.SendAddonMessage) then return end
  if _G.InCombatLockdown() or (Info.InChatMessagingLockdown and Info.InChatMessagingLockdown()) then return end
  if GetTime() - lastShared < SHARE_EVERY then return end
  lastShared = GetTime()
  local faces, known = Faces(), Core.KNOWN_FACES or {}
  local message = ""
  for _, boss in ipairs(run.bosses) do
    local display = faces[boss.name]
    -- (the ones in the addon's own list, everyone has)
    if display and known[boss.name] ~= display then
      local part = boss.name.."="..display
      if #message + #part + 1 > 250 then
        pcall(Info.SendAddonMessage, FACES_PREFIX, message, channel)
        message = ""
      end
      message = message == "" and part or (message..";"..part)
    end
  end
  if message ~= "" then pcall(Info.SendAddonMessage, FACES_PREFIX, message, channel) end
end

local function FacesReceived(message)
  local faces, known = Faces(), Core.KNOWN_FACES or {}
  local count, changed = 0, false
  for name, display in message:gmatch("([^;=]+)=(%d+)") do
    count = count + 1
    if count > 40 then break end
    display = tonumber(display)
    if #name <= 60 and display and display > 0 and not faces[name] and not known[name] then
      faces[name] = display
      changed = true
    end
  end
  local run = changed and inside and Run()
  if not run then return end
  for _, boss in ipairs(run.bosses or {}) do
    boss.display = boss.display or faces[boss.name]
  end
  Core.Refresh()
end

local sharing = CreateFrame("Frame")
sharing:SetScript("OnEvent", function (_, event, prefix, message)
  if event == "GROUP_ROSTER_UPDATE" then
    -- (a moment for the newcomer's addons to start)
    if inside then C_Timer.After(5, Core.ShareDungeonFaces) end
  elseif prefix == FACES_PREFIX and type(message) == "string"
    and not (_G.issecretvalue and _G.issecretvalue(message)) then
    FacesReceived(message)
  end
end)

-- The group's deaths: once a second, who's lying dead now that wasn't a
-- moment ago (you too). A hunter's Feign Death doesn't count.
local GROUP = { "player", "party1", "party2", "party3", "party4" }

function CountGroupDeaths(run)
  run.deathsBy = run.deathsBy or {}
  run.wasDead = run.wasDead or {}
  local units = GROUP
  if _G.IsInRaid and _G.IsInRaid() then
    units = {}
    for i = 1, (_G.GetNumGroupMembers and _G.GetNumGroupMembers() or 0) do units[i] = "raid"..i end
  end
  local changed = false
  for _, unit in ipairs(units) do
    if _G.UnitExists(unit) then
      local name = _G.UnitName(unit)
      if Core.Readable(name) and name then
        local dead = _G.UnitIsDeadOrGhost(unit) and not (_G.UnitIsFeignDeath and _G.UnitIsFeignDeath(unit))
        if dead and not run.wasDead[name] then
          run.deathsBy[name] = (run.deathsBy[name] or 0) + 1
          run.deaths = (run.deaths or 0) + 1
          changed = true
        end
        run.wasDead[name] = dead and true or nil
      end
    end
  end
  if changed then Core.Refresh() end
end

----
-- What the section shows

local function Elapsed(run)
  return (run.finished or time()) - run.start
end

local function AtMaxLevel()
  if _G.IsPlayerAtEffectiveMaxLevel then return _G.IsPlayerAtEffectiveMaxLevel() end
  return _G.GetMaxPlayerLevel and UnitLevel("player") >= _G.GetMaxPlayerLevel()
end

---
-- Starts the run again (the dungeon's menu, "Start again")
function Core.RestartDungeonRun()
  if not inside then return end
  StartRun(InstanceID())
  SetBosses(Run(), Run().name)
  Core.Refresh()
end


----
-- /qm testcard: the card of a made-up run of The Drowned City, anywhere,
-- with a boss dying every two seconds (and experience, gold and a death
-- coming in), to see it and its animations

local demo
local DEMO_BOSSES = {
  { name = "Zul'Alai" }, { name = "Var'Taka" }, { name = "Captain Dreadrise" },
  { name = "Min'loth the Serpent" }, { name = "Gill", rare = true }, { name = "Umbra", rare = true },
}

-- The dungeons the journal addon and AtlasLoot know, by name
local function DungeonNames()
  local journal = _G.ForeverDungeonJournal_NS
  local names, seen = {}, {}
  local function Add(name)
    if name and not seen[name] then seen[name] = true table.insert(names, name) end
  end
  -- (not its quest chain pages: the Onyxia Attunement, the Cozy Sleeping Bag...)
  for name, page in pairs(type(journal) == "table" and type(journal.DB) == "table" and journal.DB or {}) do
    if not (type(page) == "table" and page.questChainPage) then Add(name) end
  end
  for _, dungeon in pairs(AtlasData() or {}) do Add(AtlasName(dungeon)) end
  table.sort(names)
  return names
end

-- The dungeon a typed name means ("deadmines", "scarlet library"...): the
-- dungeon whose name has every word typed. Nil if none.
local function FindDungeon(typed)
  if not typed or typed == "" then return nil end
  local found
  for _, name in ipairs(DungeonNames()) do
    local lower, all = name:lower(), true
    for word in typed:lower():gmatch("%S+") do
      if not lower:find(word, 1, true) then all = false break end
    end
    -- (the shortest name that fits: "stratholme" picks one, not a list)
    if all and (not found or #name < #found) then found = name end
  end
  return found
end

function Core.DungeonDemo(typed)
  local name = "The Drowned City"
  if typed and typed ~= "" then
    name = FindDungeon(typed)
    if not name then
      print("|cffdfba69Questmark|r: no dungeon called \""..typed.."\". Try one of:")
      print("  "..table.concat(DungeonNames(), ", "))
      return
    end
  end
  local dungeon = JournalDungeon(name)
  local atlas = not dungeon and AtlasDungeon(name)
  local range = atlas and type(atlas.LevelRange) == "table" and atlas.LevelRange
  demo = {
    name = name, start = time() - 754, xp = 2380, money = 0, copper = 4210, deaths = 0, deathsBy = {},
    killed = {}, killedAt = {}, bosses = JournalAddon(name) or AtlasBosses(name) or DEMO_BOSSES,
    icon = BetterIcon(name) or dungeon and dungeon.icon or "Interface\\Icons\\Spell_Frost_SummonWaterElemental",
    levels = dungeon and dungeon.level or (range and range[1] and (range[1].."-"..range[#range])) or "35-40",
    id = "demo:"..name,
  }
  local current = demo
  if clock then clock:Show() end
  if Core.Reveal then Core.Reveal() end
  Core.Refresh()
  -- The bosses die one after the other (the rare ones too)
  for i, boss in ipairs(demo.bosses) do
    C_Timer.After(1.5 + i * 2, function ()
      if demo ~= current then return end
      demo.killed[boss.name] = true
      demo.killedAt[boss.name] = time() - demo.start
      demo.xp = demo.xp + 900 + math.random(0, 600)
      demo.copper = demo.copper + 1500 + math.random(0, 3000)
      if i == 2 then
        local player = _G.UnitName("player") or "You"
        demo.deaths = demo.deaths + 1
        demo.deathsBy[player] = (demo.deathsBy[player] or 0) + 1
      end
      if AllKilled(demo) and not demo.finished then demo.finished = time() end
      if Core.Reveal then Core.Reveal() end
      Core.Refresh()
    end)
  end
  -- Then it goes
  C_Timer.After(1.5 + #demo.bosses * 2 + 6, function ()
    if demo ~= current then return end
    demo = nil
    Core.Refresh()
  end)
end

function Core.DungeonSection()
  local section = { key = "dungeon", title = "Dungeon", entries = {}, count = 0 }
  local run = demo or Run()
  if not run or not Profile().dungeonInfo or not (inside or demo) then return section end
  if not demo then CountXP() end
  local entry = {
    kind = "dungeon", key = "d"..tostring(run.id), id = run.id, title = run.name or "",
    elapsed = Elapsed(run), finished = run.finished ~= nil,
    -- (what the fighting and looting brought: not the quests turned in)
    copper = demo and demo.copper or math.max(0, GetMoney() - run.money - (run.questMoney or 0)),
    deaths = run.deaths, deathsBy = run.deathsBy, bosses = {}, lines = {},
    icon = run.icon, iconGray = run.iconGray, location = run.location, levels = run.levels,
    -- (the record to beat, and if this run beat it)
    best = not demo and (run.finished and run.best or (run.name and Records()[run.name])) or nil,
    newRecord = not demo and run.newRecord or nil,
  }
  if not AtMaxLevel() then
    entry.xp, entry.xpMax = demo and run.xp or math.max(0, run.xp - (run.questXP or 0)), UnitXPMax("player")
  end
  for _, boss in ipairs(run.bosses or {}) do
    table.insert(entry.bosses, {
      name = boss.name, rare = boss.rare, display = boss.display, side = boss.side,
      killed = run.killed[boss.name] and true or false,
      killedAt = run.killedAt and run.killedAt[boss.name],
    })
  end
  section.entries[1] = entry
  section.count = 1
  return section
end

---
-- The clock, once a second (only its text changes)
function Core.DungeonClock()
  local run = demo or Run()
  if not run then return nil end
  return { elapsed = Elapsed(run), finished = run.finished ~= nil }
end

----
-- Events

events:SetScript("OnEvent", function (_, event, ...)
  local run = Run()
  if event == "PLAYER_ENTERING_WORLD" or event == "ZONE_CHANGED_NEW_AREA" then
    -- (a moment later: the instance's map is known then)
    C_Timer.After(0.5, UpdateInside)
    return
  end
  if event == "ZONE_CHANGED" or event == "ZONE_CHANGED_INDOORS" then
    -- (a new room: which side of Stratholme, while the dungeon isn't known)
    if inside and run and not JournalDungeon(run.name) then UpdateInside() end
    return
  end
  if not inside or not run then return end
  if event == "ENCOUNTER_END" then
    local encounterID, name, _, _, success = ...
    if success == 1 and Core.Readable(name) and name then Killed(name, encounterID, nil, true) end
    return
  elseif event == "BOSS_KILL" then
    local encounterID, name = ...
    if Core.Readable(name) and name then Killed(name, encounterID, nil, true) end
    return
  elseif event == "PLAYER_REGEN_ENABLED" then
    -- (the fight's over: who died in it can be read now)
    if run.bosses then LookForDeadBosses() end
    return
  elseif event == "LOOT_OPENED" or event == "LOOT_READY" then
    if run.bosses then LookInLoot() end
    return
  elseif event == "QUEST_TURNED_IN" then
    -- (a quest's experience and gold don't count: only the fighting's)
    local _, xp, money = ...
    run.questXP = (run.questXP or 0) + (tonumber(xp) or 0)
    run.questMoney = (run.questMoney or 0) + (tonumber(money) or 0)
  end
  Core.Refresh()
end)

-- The clock: once a second, only its line changes (and only inside: it
-- stops outside, and starts again on going in or with the test card)

-- A dungeon with two sides in one (Stratholme, Blackrock Spire): which
-- side. First as the journal addon's own run log already knows it (its
-- rooms, creatures and bosses). WoW: Forever
-- names no room there and has no map at its doors, so: by a boss killed that
-- only one side has (the journal addon's lists), or by the creatures around
-- you, as the journal addon knows each side's (their IDs can be secret in a
-- dungeon: then the bosses tell it). Looked for only until it's known.
local WING_UNITS = { "target", "mouseover", "focus", "party1target", "party2target", "party3target", "party4target" }
for i = 1, 20 do WING_UNITS[#WING_UNITS + 1] = "nameplate"..i end

local function LookForWing(run)
  if not run or not run.id or JournalDungeon(run.name) then return end
  local journal = _G.ForeverDungeonJournal_NS
  local groups = type(journal) == "table" and journal.RunLogWingGroups
  local trash = type(journal) == "table" and journal.RunLogWingTrash
  local wings = type(groups) == "table" and groups[run.id]
  if type(wings) ~= "table" then return end
  local function Found(wing)
    run.name = wing
    UpdateInside()
    Core.Refresh()
  end
  -- (the journal addon's open run here, with its side)
  local saved = _G.ForeverDungeonJournalCharacterDB
  local log = type(saved) == "table" and type(saved.runLog) == "table" and saved.runLog.runs
  for _, other in ipairs(type(log) == "table" and log or {}) do
    if type(other) == "table" and not other.closed and other.map == run.id and type(other.dungeon) == "string" then
      for _, wing in ipairs(wings) do
        if wing == other.dungeon then
          Found(wing)
          return
        end
      end
    end
  end
  -- (a boss killed of one side only)
  local db = type(journal.DB) == "table" and journal.DB
  if db then
    local found
    -- (the list of all sides: each boss knows its side)
    for _, boss in ipairs(run.bosses or {}) do
      if boss.side and run.killed and run.killed[boss.name] then
        if found and found ~= boss.side then found = false break end
        found = found or boss.side
      end
    end
    -- (a kill the game named by its fight: the journal addon's side of it)
    local encounters = type(journal.RUNLOG_ENCOUNTERS) == "table" and journal.RUNLOG_ENCOUNTERS
    for _, boss in ipairs(found == nil and encounters and run.bosses or {}) do
      local hit = boss.id and run.killed and run.killed[boss.name] and encounters[boss.id]
      local side = type(hit) == "table" and hit[1]
      for _, wing in ipairs(side and wings or {}) do
        if wing == side then
          if found and found ~= wing then found = false end
          found = found == nil and wing or found
        end
      end
    end
    for _, wing in ipairs(found == nil and wings or {}) do
      local dungeon = db[wing]
      for _, boss in ipairs(type(dungeon) == "table" and type(dungeon.bosses) == "table" and dungeon.bosses or {}) do
        if type(boss) == "table" and boss.name and run.killed and run.killed[boss.name] then
          if found and found ~= wing then found = false break end
          found = found == nil and wing or found
        end
      end
      if found == false then break end
    end
    if found then
      Found(found)
      return
    end
  end
  if type(trash) ~= "table" then return end
  for _, unit in ipairs(WING_UNITS) do
    -- (by its name when its ID is secret: the lists name each creature)
    local name = _G.UnitExists(unit) and not _G.UnitIsPlayer(unit) and _G.UnitName(unit)
    if name and Core.Readable(name) and type(name) == "string" then
      for _, wing in ipairs(wings) do
        for _, known in pairs(type(trash[wing]) == "table" and trash[wing] or {}) do
          if known == name then
            Found(wing)
            return
          end
        end
      end
    end
    local guid = _G.UnitExists(unit) and _G.UnitGUID(unit)
    if guid and Core.Readable(guid) and type(guid) == "string" then
      local npcID = tonumber((select(6, strsplit("-", guid))))
      if npcID then
        for _, wing in ipairs(wings) do
          if type(trash[wing]) == "table" and trash[wing][npcID] then
            Found(wing)
            return
          end
        end
      end
    end
  end
end

clock = CreateFrame("Frame")
local sinceTick = 0
clock:SetScript("OnUpdate", function (self, elapsed)
  if not inside and not demo then
    self:Hide()
    return
  end
  sinceTick = sinceTick + elapsed
  if sinceTick < 1 then return end
  sinceTick = 0
  if demo then
    Core.SetDungeonClock(Core.DungeonClock())
    return
  end
  if not inside then return end
  if Run() then
    Run().seen = time()
    LookForNewCopy(Run())
    LookForWing(Run())
  end
  local run = Run()
  local clock = Core.DungeonClock()
  if clock then Core.SetDungeonClock(clock) end
  if run and run.bosses then
    LookForDeadBosses()
    LookForFaces(run)
  end
  if run then CountGroupDeaths(run) end
end)

Core:OnChange(function (key)
  if key == "enable" then
    if not Core.trackerOn then return end -- (the tracker turned off)
    for _, event in ipairs({
      "PLAYER_ENTERING_WORLD", "ZONE_CHANGED_NEW_AREA", "ZONE_CHANGED", "ZONE_CHANGED_INDOORS",
      "ENCOUNTER_END", "BOSS_KILL",
      "PLAYER_XP_UPDATE", "PLAYER_LEVEL_UP", "PLAYER_MONEY", "QUEST_TURNED_IN",
      "PLAYER_REGEN_ENABLED", "LOOT_OPENED", "LOOT_READY",
    }) do
      pcall(events.RegisterEvent, events, event)
    end
    UpdateInside()
    local Info = _G.C_ChatInfo
    if Info and Info.RegisterAddonMessagePrefix then
      pcall(Info.RegisterAddonMessagePrefix, FACES_PREFIX)
      sharing:RegisterEvent("CHAT_MSG_ADDON")
      sharing:RegisterEvent("GROUP_ROSTER_UPDATE")
    end
  elseif key == "dungeonInfo" then
    Core.Refresh()
  end
end)
