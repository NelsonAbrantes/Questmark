local _, ns = ...
local Core = ns.Core

-- luacheck: push ignore 113
local C_Map = C_Map
local C_Timer = C_Timer
local CreateFrame = CreateFrame
local GetMoney = GetMoney
local date = date
local time = time
-- luacheck: pop

----
-- Diary
--
-- The book writes a page for each day you play (per character), read by
-- clicking a day in the quests turned in (the red ribbon): the quests turned
-- in, the levels reached, the zones seen (and the ones seen for the first
-- time), the dungeons done (with their time, and if it was the fastest), the
-- deaths, the gold made and how long you played. A month or a year clicked:
-- all its days put together.
-- And the atlas (Tracker/Atlas.lua): how many quests you turned in in each
-- zone, kept apart from the history (which only keeps the last ones).
--
-- Kept: Core.db.char.diary[day] = { quests, xp, money, minutes, deaths,
-- levels = {}, zones = {}, newZones = {}, dungeons = {} }, day "2026-11-22";
-- Core.db.char.zonesSeen[zone] = the day first seen;
-- Core.db.char.atlas[zone mapID] = { quests, first, last }.

local MAX_ZONES = 12 -- zones kept per day (a day of flying around)

local events = CreateFrame("Frame")
local lastMoney -- the gold a moment ago (only what you make is counted)

local function Today() return date("%Y-%m-%d") end

local function Day(day)
  local char = Core.db.char
  char.diary = char.diary or {}
  day = day or Today()
  local page = char.diary[day]
  if not page then
    page = { quests = 0, xp = 0, money = 0, minutes = 0, deaths = 0, levels = {}, zones = {}, newZones = {}, dungeons = {} }
    char.diary[day] = page
  end
  return page
end

local function Has(list, value)
  for _, one in ipairs(list) do
    if one == value then return true end
  end
  return false
end

-- The zones seen before the diary (the first time it runs): the ones of the
-- quests turned in, so they don't count as seen for the first time
local function Seen()
  local char = Core.db.char
  if not char.zonesSeen then
    char.zonesSeen = {}
    for _, done in ipairs(Core.QuestHistory and Core.QuestHistory() or {}) do
      if done.zone then char.zonesSeen[done.zone] = "before" end
    end
  end
  return char.zonesSeen
end

local function ZoneHere()
  local zone = _G.GetRealZoneText and _G.GetRealZoneText()
  if not (Core.Readable(zone) and zone and zone ~= "") then return nil end
  local page, seen = Day(), Seen()
  if not Has(page.zones, zone) and #page.zones < MAX_ZONES then table.insert(page.zones, zone) end
  if not seen[zone] then
    seen[zone] = Today()
    if not Has(page.newZones, zone) then table.insert(page.newZones, zone) end
  end
end

----
-- The atlas: the zone (its map) a quest was turned in in

-- The zone a map is in (a town or a cave goes up to its zone)
local function ZoneMap(mapID)
  local Zone = _G.Enum and _G.Enum.UIMapType and _G.Enum.UIMapType.Zone or 3
  for _ = 1, 6 do
    local info = mapID and C_Map.GetMapInfo(mapID)
    if not info then return nil end
    if info.mapType == Zone then return mapID end
    if (info.mapType or 0) < Zone then return nil end
    mapID = info.parentMapID
  end
  return nil
end

local function Atlas()
  local char = Core.db.char
  if not char.atlas then
    char.atlas = {}
    -- (the quests turned in before the atlas: their zone's name, found on
    -- the continents' maps, once)
    local byName = {}
    local Continent = _G.Enum and _G.Enum.UIMapType and _G.Enum.UIMapType.Continent or 2
    local Zone = _G.Enum and _G.Enum.UIMapType and _G.Enum.UIMapType.Zone or 3
    for _, continent in ipairs(C_Map.GetMapChildrenInfo(946, Continent, true) or {}) do
      for _, zone in ipairs(C_Map.GetMapChildrenInfo(continent.mapID, Zone) or {}) do
        byName[zone.name] = byName[zone.name] or zone.mapID
      end
    end
    for _, done in ipairs(Core.QuestHistory and Core.QuestHistory() or {}) do
      local mapID = done.zone and byName[done.zone]
      if mapID then
        local zone = char.atlas[mapID] or { quests = 0 }
        char.atlas[mapID] = zone
        zone.quests = zone.quests + (done.times or 1)
        if done.at then
          zone.first = math.min(zone.first or done.at, done.at)
          zone.last = math.max(zone.last or done.at, done.at)
        end
      end
    end
  end
  return char.atlas
end

---
-- The quests turned in in each zone: zone mapID -> { quests, first, last }
function Core.AtlasCounts()
  return Atlas()
end

----
-- What happens

events:SetScript("OnEvent", function (_, event, ...)
  if event == "QUEST_TURNED_IN" then
    local _, xp = ...
    local page = Day()
    page.quests = page.quests + 1
    page.xp = page.xp + (tonumber(xp) or 0)
    local mapID = ZoneMap(C_Map.GetBestMapForUnit("player"))
    if mapID then
      local atlas = Atlas()
      local zone = atlas[mapID] or { quests = 0 }
      atlas[mapID] = zone
      zone.quests = zone.quests + 1
      zone.first = zone.first or time()
      zone.last = time()
    end
  elseif event == "PLAYER_LEVEL_UP" then
    local level = ...
    if tonumber(level) then table.insert(Day().levels, tonumber(level)) end
  elseif event == "PLAYER_DEAD" then
    local page = Day()
    page.deaths = page.deaths + 1
  elseif event == "PLAYER_MONEY" then
    local now = GetMoney()
    if lastMoney and now > lastMoney then
      local page = Day()
      page.money = page.money + (now - lastMoney)
    end
    lastMoney = now
  else
    -- (a new zone, or coming into the world: a moment later, its name is
    -- known then)
    C_Timer.After(1, ZoneHere)
  end
end)

---
-- A dungeon run done (Dungeon.lua): its name, how long it took, if it was the
-- fastest
function Core.DiaryDungeon(run)
  if not (run and run.name and run.start and run.finished) then return end
  table.insert(Day().dungeons, {
    name = run.name, seconds = run.finished - run.start, record = run.newRecord and true or nil,
    best = run.best,
  })
end

-- A run counted as done too early (Dungeon.lua, Unfinish): out of the day again
function Core.DiaryUndoDungeon(name, seconds)
  if not name then return end
  local dungeons = Day().dungeons
  for i = #dungeons, 1, -1 do
    if dungeons[i].name == name and dungeons[i].seconds == seconds then
      table.remove(dungeons, i)
      return
    end
  end
end

----
-- The page of a day, a month ("2026-10") or a year ("2025"), for the book:
-- { title, sub, text, xp, money }

local function Plural(n, one, many) return n == 1 and "1 "..one or n.." "..(many or one.."s") end

-- "a, b and c"
local function Join(list)
  if #list <= 1 then return list[1] or "" end
  return table.concat(list, ", ", 1, #list - 1).." and "..list[#list]
end

local function Duration(seconds)
  local hours, minutes = math.floor(seconds / 3600), math.floor(seconds / 60) % 60
  if hours > 0 then return minutes > 0 and Plural(hours, "hour").." "..Plural(minutes, "minute") or Plural(hours, "hour") end
  return Plural(math.max(1, minutes), "minute")
end

-- The day's quests from the history (the days before the diary, and their
-- names): newest first
local function HistoryOf(prefix)
  local list = {}
  for _, done in ipairs(Core.QuestHistory and Core.QuestHistory() or {}) do
    if done.at and date("%Y-%m-%d", done.at):sub(1, #prefix) == prefix then list[#list + 1] = done end
  end
  return list
end

local function Noon(day)
  local y, m, d = day:match("^(%d+)-(%d+)-?(%d*)$")
  if not y then y = day:match("^(%d+)$") m, d = "1", "1" end
  return time({ year = tonumber(y), month = tonumber(m), day = tonumber(d ~= "" and d or 1), hour = 12 })
end

function Core.DiaryPage(key)
  if not key or key == "?" then return nil end
  local diary = Core.db.char.diary or {}
  local isDay = #key == 10
  -- Everything of the days it has
  local sum = { quests = 0, xp = 0, money = 0, minutes = 0, deaths = 0, levels = {}, zones = {}, newZones = {},
    dungeons = {}, days = 0, written = false }
  local busiest, busiestDay = 0, nil
  local days = {}
  for day in pairs(diary) do
    if day:sub(1, #key) == key then days[#days + 1] = day end
  end
  table.sort(days)
  for _, day in ipairs(days) do
    local page = diary[day]
    sum.written = true
    sum.days = sum.days + 1
    for _, field in ipairs({ "quests", "xp", "money", "minutes", "deaths" }) do sum[field] = sum[field] + (page[field] or 0) end
    for _, field in ipairs({ "levels", "zones", "newZones", "dungeons" }) do
      for _, one in ipairs(page[field] or {}) do
        if field == "dungeons" or not Has(sum[field], one) then table.insert(sum[field], one) end
      end
    end
    if (page.quests or 0) > busiest then busiest, busiestDay = page.quests, day end
  end
  -- (before the diary: the history's quests of then)
  local history = HistoryOf(key)
  if sum.quests < #history then
    sum.quests = #history
    sum.xp = 0
    for _, done in ipairs(history) do sum.xp = sum.xp + (done.xp or 0) end
  end

  local at = Noon(key)
  local page = { diary = true, xp = sum.xp, money = sum.money,
    heading = isDay and "The day" or #key == 7 and "The month" or "The year" }
  if isDay then
    page.title = date("%A, ", at)..date("%d %B %Y", at):gsub("^0", "")
  elseif #key == 7 then
    page.title = date("%B %Y", at)
  else
    page.title = key
  end
  page.sub = Join({ unpack(sum.zones, 1, math.min(#sum.zones, 4)) })

  local say = {}
  if sum.quests > 0 then
    local names = {}
    for i = 1, math.min(3, #history) do names[i] = history[i].title end
    local line = "You turned in "..Plural(sum.quests, "quest").."."
    if isDay and #names > 0 then
      line = #history == 1 and "You turned in "..names[1].."."
        or line.." The last ones: "..Join(names).."."
    end
    say[#say + 1] = line
  end
  if #sum.levels == 1 then
    say[#say + 1] = "You reached level "..sum.levels[1].."."
  elseif #sum.levels > 1 then
    table.sort(sum.levels)
    say[#say + 1] = "You went from level "..(sum.levels[1] - 1).." to "..sum.levels[#sum.levels].."."
  end
  if #sum.newZones > 0 then
    say[#say + 1] = "For the first time you set foot in "..Join(sum.newZones).."."
  elseif isDay and #sum.zones > 1 then
    say[#say + 1] = "Your road went through "..Join(sum.zones).."."
  end
  for i, run in ipairs(sum.dungeons) do
    if not isDay and i > 3 then
      say[#say + 1] = "And "..Plural(#sum.dungeons - 3, "more dungeon").."."
      break
    end
    local line = run.name.." took you "..Duration(run.seconds or 0).."."
    if run.record and run.best then
      line = line.." Your fastest ever, "..Duration(run.best - run.seconds).." better than before."
    elseif run.record then
      line = line.." Your first time through."
    end
    say[#say + 1] = line
  end
  if sum.written then
    if sum.deaths == 0 then
      say[#say + 1] = isDay and "You didn't die once." or "Not a single death."
    else
      say[#say + 1] = "You died "..(sum.deaths == 1 and "once" or sum.deaths == 2 and "twice" or sum.deaths.." times").."."
    end
  end
  if not isDay and busiestDay and sum.days > 1 then
    say[#say + 1] = "Your busiest day: "..date("%d %B", Noon(busiestDay)):gsub("^0", "")
      ..", with "..Plural(busiest, "quest").."."
  end
  if sum.minutes > 0 then
    say[#say + 1] = "You played for "..Duration(sum.minutes * 60)
      ..(not isDay and sum.days > 1 and ", over "..sum.days.." days" or "").."."
  end
  if #say == 0 then
    say[1] = "Nothing was written on this day."
  elseif not sum.written then
    say[#say + 1] = "(The rest of this day came before the book kept a diary.)"
  end
  page.text = table.concat(say, "\n\n")
  return page
end

----
-- Turned on with the addon

local ticker
Core:OnChange(function (key)
  if key ~= "enable" then return end
  for _, event in ipairs({
    "QUEST_TURNED_IN", "PLAYER_LEVEL_UP", "PLAYER_DEAD", "PLAYER_MONEY",
    "ZONE_CHANGED_NEW_AREA", "PLAYER_ENTERING_WORLD",
  }) do
    pcall(events.RegisterEvent, events, event)
  end
  lastMoney = GetMoney()
  Seen()
  -- (the time played: a minute at a time, on the day it's played)
  if not ticker then
    ticker = C_Timer.NewTicker(60, function ()
      local page = Day()
      page.minutes = page.minutes + 1
    end)
  end
end)
