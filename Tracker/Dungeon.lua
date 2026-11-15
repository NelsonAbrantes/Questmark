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
  if not key and type(journal.DUNGEON_MAPS) == "table" then
    local map = _G.C_Map and _G.C_Map.GetBestMapForUnit and _G.C_Map.GetBestMapForUnit("player")
    for dungeonName, info in pairs(journal.DUNGEON_MAPS) do
      for _, floor in ipairs(type(info) == "table" and info.floors or {}) do
        if map and floor.uiMapID == map and db[dungeonName] then key = dungeonName break end
      end
      if key then break end
    end
  end
  local dungeon = key and db[key]
  return type(dungeon) == "table" and dungeon or nil, journal, key
end

local function JournalAddon(name)
  local dungeon, journal = JournalDungeon(name)
  if not dungeon or type(dungeon.bosses) ~= "table" then return nil end
  -- Its pictures of the bosses (creature -> what the game draws for it)
  local displays = type(journal.STATIC_DISPLAY_IDS) == "table" and journal.STATIC_DISPLAY_IDS or {}
  local bosses = {}
  for _, boss in ipairs(dungeon.bosses) do
    if type(boss) == "table" and type(boss.name) == "string" and not boss.trash then
      local display = displays[boss.portraitNpcID or boss.npcID] or boss.displayID
      table.insert(bosses, {
        name = boss.name, npcID = tonumber(boss.npcID), display = tonumber(display),
        aliases = type(boss.aliases) == "table" and boss.aliases or nil,
        rare = boss.rare and true or nil,
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
local function BossList(name)
  local bosses = GameJournal() or JournalAddon(name) or AtlasBosses(name) or Learned(name)
  local faces, known = Faces(), Core.KNOWN_FACES or {}
  for _, boss in ipairs(bosses or {}) do
    boss.display = boss.display or faces[boss.name] or known[boss.name]
  end
  return bosses
end

-- Icons for dungeons the journal addon doesn't know
local OWN_ICONS = {
  ["The Hall of Thanes"] = "Interface\\Icons\\inv_misc_statue_07",
}

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
    Run().bosses = BossList(Run().name) or Run().bosses
    -- Its icon, zone and levels, from the journal addon (and the wing's name)
    local dungeon, _, key = JournalDungeon(Run().name)
    if dungeon then
      if key and key ~= Run().name then
        Run().name = key
        Run().bosses = BossList(key) or Run().bosses
      end
      Run().icon = type(dungeon.icon) == "string" and dungeon.icon or nil
      Run().location = type(dungeon.location) == "string" and dungeon.location or nil
      Run().levels = type(dungeon.level) == "string" and dungeon.level or nil
    end
    Run().icon = Run().icon or OWN_ICONS[Run().name]
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

local function AllKilled(run)
  if not run.bosses then return false end
  for _, boss in ipairs(run.bosses) do
    if not boss.rare and not run.killed[boss.name] then return false end
  end
  return true
end

-- The boss of the list that a kill is (by its ID, name or other names)
local function FindBoss(run, name, encounterID, npcID)
  for _, boss in ipairs(run.bosses or {}) do
    if (encounterID and boss.id == encounterID) or (npcID and boss.npcID == npcID)
      or (name and boss.name == name) then
      return boss
    end
    for _, alias in ipairs(boss.aliases or {}) do
      if name and alias == name then return boss end
    end
  end
end

-- A boss died: checked in the list (and learned for next time when the
-- game said it was a boss)
local function Killed(name, encounterID, npcID, fromEncounter)
  local run = Run()
  if not run then return end
  local boss = FindBoss(run, name, encounterID, npcID)
  if boss then
    if fromEncounter then Learn(run.name, boss.name) end
    if run.killed[boss.name] then return end
    run.killed[boss.name] = true
    run.killedAt = run.killedAt or {}
    run.killedAt[boss.name] = time() - run.start
  elseif fromEncounter and name then
    -- A boss the list didn't have: added, and remembered for next time
    run.killed[name] = true
    run.killedAt = run.killedAt or {}
    run.killedAt[name] = time() - run.start
    run.bosses = run.bosses or {}
    table.insert(run.bosses, { name = name, id = encounterID })
    Learn(run.name, name)
  else
    return
  end
  if AllKilled(run) and not run.finished then run.finished = time() end
  Core.Refresh()
end

-- The game doesn't report every boss kill in the dungeons WoW: Forever added,
-- and addons may not read the combat log here. So, once a second: is one of
-- the list's bosses lying dead as your target, a group member's target or
-- one of the encounter's bosses?
local WATCHED = { "target", "focus", "boss1", "boss2", "boss3", "boss4", "boss5",
  "party1target", "party2target", "party3target", "party4target" }

function LookForDeadBosses()
  for _, unit in ipairs(WATCHED) do
    if _G.UnitExists(unit) and _G.UnitIsDead(unit) and not _G.UnitIsPlayer(unit) then
      local guid = _G.UnitGUID(unit)
      if Core.Readable(guid) and type(guid) == "string" then
        local npcID = tonumber((select(6, strsplit("-", guid))))
        local name = _G.UnitName(unit)
        if npcID then Killed(Core.Readable(name) and name or nil, nil, npcID, false) end
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
          new.bosses = BossList(run.name) or run.bosses
          new.icon, new.location, new.levels = run.icon, run.location, run.levels
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
      local boss = name and FindBoss(run, name)
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
  Run().bosses = BossList(Run().name)
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
  for name in pairs(type(journal) == "table" and type(journal.DB) == "table" and journal.DB or {}) do Add(name) end
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
    icon = dungeon and dungeon.icon or "Interface\\Icons\\Spell_Frost_SummonWaterElemental",
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
    icon = run.icon, location = run.location, levels = run.levels,
  }
  if not AtMaxLevel() then
    entry.xp, entry.xpMax = demo and run.xp or math.max(0, run.xp - (run.questXP or 0)), UnitXPMax("player")
  end
  for _, boss in ipairs(run.bosses or {}) do
    table.insert(entry.bosses, {
      name = boss.name, rare = boss.rare, display = boss.display,
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
  if not inside or not run then return end
  if event == "ENCOUNTER_END" then
    local encounterID, name, _, _, success = ...
    if success == 1 and Core.Readable(name) and name then Killed(name, encounterID, nil, true) end
    return
  elseif event == "BOSS_KILL" then
    local encounterID, name = ...
    if Core.Readable(name) and name then Killed(name, encounterID, nil, true) end
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
      "PLAYER_ENTERING_WORLD", "ZONE_CHANGED_NEW_AREA", "ENCOUNTER_END", "BOSS_KILL",
      "PLAYER_XP_UPDATE", "PLAYER_LEVEL_UP", "PLAYER_MONEY", "QUEST_TURNED_IN",
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
