local _, ns = ...
local Core = ns.Core

-- luacheck: push ignore 113
local C_ChatInfo = C_ChatInfo
local C_Timer = C_Timer
local CreateFrame = CreateFrame
local GetTime = GetTime
local InCombatLockdown = InCombatLockdown
local IsInGroup = IsInGroup
local IsInGuild = IsInGuild
local IsInRaid = IsInRaid
local LE_PARTY_CATEGORY_INSTANCE = LE_PARTY_CATEGORY_INSTANCE
-- luacheck: pop

local PREFIX = "Questmark"
local SEND_EVERY = 60  -- at most one announcement a minute
local REPLY_EVERY = 300 -- at most one reply to the same player in 5 minutes

----
-- VersionCheck
--
-- Addons can't look up new versions online, so players tell each other: the
-- addon quietly says its version to the guild and the group (addon messages,
-- not shown in chat). If someone has a newer one, a message in chat says so,
-- once per session. Someone with an older one gets told our version back, so
-- the news spreads.

local function Notify(message)
  print("|c00DFBA69Questmark|r: " .. message)
end

-- "0.1.0" -> 0, 1, 0. Only versions named this way count (the copies made
-- before the first release said "-forever" after it: still read).
local function Parse(version)
  if type(version) ~= "string" then return nil end
  local major, minor, patch = version:gsub("%-forever$", ""):match("^(%d+)%.(%d+)%.(%d+)$")
  if not major then return nil end
  return tonumber(major), tonumber(minor), tonumber(patch)
end

local function Newer(a, b)
  local a1, a2, a3 = Parse(a)
  local b1, b2, b3 = Parse(b)
  if not a1 or not b1 then return false end
  if a1 ~= b1 then return a1 > b1 end
  if a2 ~= b2 then return a2 > b2 end
  return a3 > b3
end

local function Send(channel, target)
  if InCombatLockdown() then return end
  pcall(C_ChatInfo.SendAddonMessage, PREFIX, "V:" .. Core.Version, channel, target)
end

local lastSent = 0
local function Announce()
  if GetTime() - lastSent < SEND_EVERY or not Parse(Core.Version) then return end
  lastSent = GetTime()
  if IsInGuild() then Send("GUILD") end
  if IsInGroup(LE_PARTY_CATEGORY_INSTANCE) then
    Send("INSTANCE_CHAT")
  elseif IsInRaid() then
    Send("RAID")
  elseif IsInGroup() then
    Send("PARTY")
  end
end

local notified = false
local replied = {}

local function OnMessage(prefix, message, _, sender)
  if prefix ~= PREFIX then return end
  if issecretvalue and (issecretvalue(message) or issecretvalue(sender)) then return end
  local version = type(message) == "string" and message:match("^V:(.+)$")
  if not version then return end

  if Newer(version, Core.Version) then
    if not notified then
      notified = true
      Notify("there's a new version (" .. version .. "). Update it on CurseForge.")
    end
  elseif Newer(Core.Version, version) and sender then
    -- Theirs is older: tell them ours (not too often)
    local now = GetTime()
    if not replied[sender] or now - replied[sender] > REPLY_EVERY then
      replied[sender] = now
      Send("WHISPER", sender)
    end
  end
end

Core:OnChange(function (key)
  if key ~= "enable" then return end
  if not (C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix) then return end
  C_ChatInfo.RegisterAddonMessagePrefix(PREFIX)

  local events = CreateFrame("Frame")
  events:RegisterEvent("CHAT_MSG_ADDON")
  events:RegisterEvent("PLAYER_ENTERING_WORLD")
  events:RegisterEvent("GROUP_ROSTER_UPDATE")
  events:SetScript("OnEvent", function (_, event, ...)
    if event == "CHAT_MSG_ADDON" then
      OnMessage(...)
    else
      -- Give the game a moment (guild and group info arrive after login)
      C_Timer.After(10, Announce)
    end
  end)
  -- Login already happened by the time the addon is enabled
  C_Timer.After(10, Announce)
end)
