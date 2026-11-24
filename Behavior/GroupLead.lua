local _, ns = ...
local Core = ns.Core

-- luacheck: push ignore 113
local C_ChatInfo = C_ChatInfo
local C_Map = C_Map
local C_QuestLog = C_QuestLog
local C_SuperTrack = C_SuperTrack
local C_Timer = C_Timer
local CreateFrame = CreateFrame
local IsInGroup = IsInGroup
local IsInRaid = IsInRaid
local LE_PARTY_CATEGORY_INSTANCE = LE_PARTY_CATEGORY_INSTANCE
local UIParent = UIParent
local UnitIsGroupLeader = UnitIsGroupLeader
local wipe = wipe
-- luacheck: pop

----
-- Questing in a group (Options: Quests with the group)
--
-- Everyone in the party with Questmark tells the others how far they are in
-- their quests:
-- - under each quest in the tracker (and by its objectives in the book),
--   the faces of the others who have it: a little bar under each for how
--   far they are, a check when they're done; over a face, their objectives
-- - turning a quest in while someone isn't done: a word first (and Accept
--   and turn in quests waits)
-- - everyone done: "Everyone is ready to turn in ..."
-- - the quests the others have and you don't, in the tracker's Group part:
--   a click asks one of them to share it (they get a Share button)
-- The leader can guide the group: the flag by a quest in the tracker (over
-- it), or Guide group in the book. The others are asked once (or never
-- again: Always follow); following, their navigation leads to that quest
-- (the quest itself if they have it, else a marker where the leader's next
-- step is), then to the next one the leader picks. The guided quest keeps
-- its flag for everyone. A quest the leader takes: "Rethz took ... here",
-- marked on the others' map.
-- The words come on little cards beside the tracker, with the face of who
-- they're about.
--
-- Addon messages (not seen in chat), the version check's prefix:
--   Q?:id=state,...  your quests, all of them (and send me yours)
--   Q!:id=state,...  your quests, all of them
--   Q:id=state,...   more of them, or the ones that changed
--     state: "2/5+1/3" (each objective), "d" (done), "o" (on it, nothing
--            to count), "t" (turned in), "-" (not any more)
--   L:questID:mapID:x:y:title  the leader's quest (L:0: no more)
--   T:questID:mapID:x:y:title  the leader took a quest here
--   A:questID  (whispered) can you share it?    N:questID  it can't be shared

local PREFIX = "Questmark"
local GAP = 2 -- seconds: changes close together go in one message
local READY = "Interface\\RaidFrame\\ReadyCheck-Ready"
local ASK_ICON = "|TInterface\\GossipFrame\\AvailableQuestIcon:0|t "
local FACE_MASK = "Interface\\CharacterFrame\\TempPortraitAlphaMask"
local UNKNOWN_FACE = "Interface\\Icons\\INV_Misc_QuestionMark"
local MISSING_SHOWN = 6 -- quests the others have listed in the tracker (more: "and N more")
local CARD_HOLD = 5 -- seconds a card stays

local events = CreateFrame("Frame")
local lead -- { questID, title, mapID, x, y, leader (full name), mine }
local following = {} -- leader -> true (followed) or false (ignored), this session
local others = {} -- full name -> { [questID] = state }
local sent = {} -- questID -> the state the others were last told
local ourPoint -- the map marker put for the leader's quest
local lastLead, lastPlace
local ready = {} -- questID -> true: "everyone is ready" said
local failed = false -- a message held back (an instance's fight): sent again after it
local testing = false -- /qm testgroup: two made-up friends, to see how it looks alone

local function On()
  return Core.db.profile.groupLead ~= false
end

local function Party()
  return testing or (On() and IsInGroup() and not IsInRaid())
end

-- "Quest together" (right click Quests, or /qm group): what the others are
-- doing shows only then. Off in each new group (someone met for one quest
-- doesn't fill the tracker); the quests are still told in the background,
-- so it's all there as soon as it's turned on.
local together = false

local function Together()
  return testing or (together and Party())
end

-- Your realm, as addon messages write it ("Lightbane"). WoW: Forever's
-- GetNormalizedRealmName gives nothing: from your own full name then
local function MyRealm()
  local realm = _G.GetNormalizedRealmName and _G.GetNormalizedRealmName()
  if not (Core.Readable(realm) and realm and realm ~= "") then
    local _, own = _G.UnitFullName("player")
    realm = Core.Readable(own) and own or nil
  end
  if not realm or realm == "" then
    local name = _G.GetRealmName and _G.GetRealmName()
    realm = Core.Readable(name) and name and name:gsub("[%s%-]", "") or ""
  end
  return realm
end

local function Me()
  return _G.UnitName("player").."-"..MyRealm()
end

local function Short(full)
  return _G.Ambiguate and _G.Ambiguate(full, "short") or full:match("^[^-]+")
end

-- (the name the game's unit functions know: with the realm only if it's
-- another one)
local function Unit(full)
  return _G.Ambiguate and _G.Ambiguate(full, "none") or Short(full)
end

local function FullName(unit)
  local name, realm = _G.UnitFullName(unit)
  if not (Core.Readable(name) and name) then return nil end
  if not Core.Readable(realm) or not realm or realm == "" then realm = MyRealm() end
  return name.."-"..realm
end

-- The group leader's full name ("Name-Realm", as addon messages say it)
local function LeaderName()
  if not IsInGroup() then return nil end
  if UnitIsGroupLeader("player") then return Me() end
  local raid = IsInRaid()
  local count = raid and _G.GetNumGroupMembers() or _G.GetNumSubgroupMembers()
  for i = 1, count do
    local unit = (raid and "raid" or "party")..i
    if UnitIsGroupLeader(unit) then return FullName(unit) end
  end
  return nil
end

-- Someone in the party: their unit ("party2"), nil if not found
local function GroupUnit(full)
  if full == Me() or testing then return "player" end
  for i = 1, 4 do
    local unit = "party"..i
    if _G.UnitExists(unit) and FullName(unit) == full then return unit end
  end
  return nil
end

-- (found among the group's units by full name: by the name alone, the game
-- didn't know someone of your own realm written with it)
local function InGroup(full)
  if full == Me() or testing then return true end
  local raid = IsInRaid()
  local count = raid and _G.GetNumGroupMembers() or _G.GetNumSubgroupMembers()
  for i = 1, count do
    local unit = (raid and "raid" or "party")..i
    if _G.UnitExists(unit) and FullName(unit) == full then return true end
  end
  return false
end

local function ClassColor(full)
  local ok, _, class = pcall(_G.UnitClass, GroupUnit(full) or Unit(full))
  return ok and class and _G.RAID_CLASS_COLORS and _G.RAID_CLASS_COLORS[class] or nil
end

local function Colored(full)
  local color = ClassColor(full)
  if color and color.colorStr then return "|c"..color.colorStr..Short(full).."|r" end
  return Short(full)
end

local function Title(questID)
  local title = C_QuestLog.GetTitleForQuestID(questID)
  if Core.Readable(title) and title and title ~= "" then return title end
  -- (not known yet: asked for, the tracker is drawn again when it comes)
  if C_QuestLog.RequestLoadQuestByID then C_QuestLog.RequestLoadQuestByID(questID) end
  return nil
end

local function Send(message, target)
  local channel
  if target then
    channel = "WHISPER"
  elseif IsInGroup(LE_PARTY_CATEGORY_INSTANCE) then
    channel = "INSTANCE_CHAT"
  elseif IsInRaid() then
    channel = "RAID"
  elseif IsInGroup() then
    channel = "PARTY"
  else
    return true
  end
  local ok, result = pcall(C_ChatInfo.SendAddonMessage, PREFIX, message:sub(1, 250), channel, target)
  ok = ok and result ~= false and (type(result) ~= "number" or result == 0)
  if not ok then failed = true end
  return ok
end

----
-- States

local function Over(state) return state == "d" or state == "t" end

-- Each objective's { got, wanted }, and how far in all (0 to 1)
local function Counts(state)
  local list, have, need = {}, 0, 0
  for got, wanted in tostring(state):gmatch("(%d+)/(%d+)") do
    got, wanted = tonumber(got), tonumber(wanted)
    list[#list + 1] = { got, wanted }
    have, need = have + got, need + wanted
  end
  return list, need > 0 and have / need or 0, have, need
end

local function State(questID)
  if C_QuestLog.IsComplete(questID) then return "d" end
  local parts = {}
  for _, objective in ipairs(C_QuestLog.GetQuestObjectives(questID) or {}) do
    local got, wanted = objective.numFulfilled, objective.numRequired
    if Core.Readable(got) and Core.Readable(wanted) and wanted and wanted > 0 then
      parts[#parts + 1] = math.min(got, wanted).."/"..wanted
    else
      parts[#parts + 1] = (objective.finished and "1/1" or "0/1")
    end
  end
  return #parts > 0 and table.concat(parts, "+") or "o"
end

----
-- Faces: someone's portrait in a circle, a ring of their class color, a
-- little bar under it (how far), a check when done; faded if they don't
-- have the quest. Over it: their objectives

-- One person's lines: their name, then how far they are
local function AddPerson(tooltip, one, questID, first)
  if first then tooltip:SetText(Colored(one.name)) else tooltip:AddLine(" ") tooltip:AddLine(Colored(one.name)) end
  if one.state == "-" then
    tooltip:AddLine("Doesn't have this quest", 0.6, 0.6, 0.6)
  elseif one.state == "t" then
    tooltip:AddLine("Turned it in", 0.4, 1, 0.4)
  elseif one.state == "d" then
    tooltip:AddLine("Ready to turn it in", 0.4, 1, 0.4)
  elseif one.state == "o" then
    tooltip:AddLine("On it", 1, 1, 1)
  else
    -- (your objectives' words, with their numbers)
    local mine = questID and C_QuestLog.GetQuestObjectives(questID) or {}
    for i, count in ipairs((Counts(one.state))) do
      local text = mine[i] and Core.Readable(mine[i].text) and mine[i].text
      local numbers = count[1].."/"..count[2]
      if text and text:find("%d+/%d+") then
        text = text:gsub("%d+/%d+", numbers, 1)
      else
        text = (text or ("Objective "..i))..": "..numbers
      end
      local done = count[1] >= count[2]
      tooltip:AddLine(text, done and 0.5 or 1, done and 0.5 or 1, done and 0.5 or 1)
    end
  end
end

-- Over a face: that person, or (overlapping faces by a quest) everyone
local function FaceTooltip(face)
  local one = face.data
  if not one then return end
  local tooltip = _G.GameTooltip
  tooltip:SetOwner(face, "ANCHOR_RIGHT")
  for i, person in ipairs(face.group or { one }) do AddPerson(tooltip, person, face.questID, i == 1) end
  tooltip:Show()
end

local function NewFace(owner)
  local face = CreateFrame("Frame", nil, owner)
  face.portrait = face:CreateTexture(nil, "ARTWORK")
  face.portrait:SetAllPoints()
  if face.CreateMaskTexture and face.portrait.AddMaskTexture then
    local mask = face:CreateMaskTexture()
    mask:SetTexture(FACE_MASK, "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
    mask:SetAllPoints(face.portrait)
    face.portrait:AddMaskTexture(mask)
  end
  face.ring = Core.Smooth(face:CreateTexture(nil, "OVERLAY"))
  face.ring:SetTexture(Core.ASSETS.."circleRing")
  face.ring:SetPoint("CENTER")
  face.back = face:CreateTexture(nil, "OVERLAY")
  face.back:SetColorTexture(0, 0, 0, 0.75)
  face.bar = face:CreateTexture(nil, "OVERLAY", nil, 2)
  face.bar:SetColorTexture(1, 1, 1, 1)
  face.check = face:CreateTexture(nil, "OVERLAY", nil, 3)
  face.check:SetTexture(READY)
  face:EnableMouse(true)
  -- (only for its tooltip: clicks go to what's under it)
  if face.SetMouseClickEnabled then face:SetMouseClickEnabled(false) end
  face:SetScript("OnEnter", FaceTooltip)
  face:SetScript("OnLeave", function () _G.GameTooltip:Hide() end)
  return face
end

-- A face showing someone (full name), or an icon (no one)
local function Portrait(face, full, size, icon)
  face:SetSize(size, size)
  local unit = full and GroupUnit(full)
  if unit then
    _G.SetPortraitTexture(face.portrait, unit)
  else
    face.portrait:SetTexture(icon or UNKNOWN_FACE)
    face.portrait:SetTexCoord(0, 1, 0, 1)
  end
  face.ring:SetSize(size * 1.3, size * 1.3)
  local color = full and ClassColor(full)
  if color then face.ring:SetVertexColor(color.r, color.g, color.b) else face.ring:SetVertexColor(Core:TitleColor()) end
  face.ring:SetShown(full ~= nil)
end

---
-- The faces of a list ({ name, state }) in a row on owner, at its top
-- left, size big; nil hides them. Returns the row's height and width
-- (inline: on a quest's title line, overlapping like a chat group's
-- pictures, the first on top, without bars: over a face, how far each is)
function Core.DrawFaces(owner, list, size, questID, inline)
  owner.faces = owner.faces or {}
  local count = list and #list or 0
  local step = inline and math.floor(size * 0.6 + 0.5) or size + 6
  for i = 1, count do
    local one = list[i]
    local face = owner.faces[i] or NewFace(owner)
    owner.faces[i] = face
    face.data, face.questID, face.group = one, questID, inline and list or nil
    face:ClearAllPoints()
    face:SetPoint("TOPLEFT", owner, "TOPLEFT", (i - 1) * step + 2, -1)
    if inline then face:SetFrameLevel(owner:GetFrameLevel() + count - i + 1) end
    Portrait(face, one.name, size)
    local missing, over = one.state == "-", Over(one.state)
    face.portrait:SetDesaturated(missing)
    face:SetAlpha(missing and 0.45 or 1)
    face.check:SetShown(over)
    face.check:SetSize(size * 0.75, size * 0.75)
    face.check:ClearAllPoints()
    face.check:SetPoint("CENTER", face, "BOTTOMRIGHT", -size * 0.1, size * 0.1)
    local _, fraction = Counts(one.state)
    local bar = not (inline or over or missing or one.state == "o")
    face.back:SetShown(bar)
    face.bar:SetShown(bar and fraction > 0)
    if bar then
      face.back:ClearAllPoints()
      face.back:SetPoint("TOPLEFT", face, "BOTTOMLEFT", 0, -2)
      face.back:SetSize(size, 3)
      face.bar:ClearAllPoints()
      face.bar:SetPoint("TOPLEFT", face.back, "TOPLEFT")
      face.bar:SetSize(math.max(0.1, size * fraction), 3)
      face.bar:SetVertexColor(Core:TitleColor())
    end
    face:Show()
  end
  for i = count + 1, #owner.faces do
    owner.faces[i]:Hide()
    owner.faces[i].data = nil
  end
  if count == 0 then return 0, 0 end
  if inline then return size, size + (count - 1) * step + 4 end
  return size + 6, count * step
end

----
-- Cards: a word beside the tracker, with the face of who it's about,
-- for a few seconds (three at most, the newest on top)

local cards, spare = {}, {}

local function Stack()
  local anchor = Core.frame
  for i, card in ipairs(cards) do
    card:ClearAllPoints()
    if anchor and anchor:GetLeft() and anchor:GetLeft() > 260 then
      card:SetPoint("TOPRIGHT", anchor, "TOPLEFT", -14, -(i - 1) * 56)
    else
      card:SetPoint("TOP", UIParent, "TOP", 0, -150 - (i - 1) * 56)
    end
  end
end

local function NewCard()
  local card = CreateFrame("Frame", nil, UIParent)
  card:SetFrameStrata("MEDIUM")
  card:SetWidth(250)
  card.bg = card:CreateTexture(nil, "BACKGROUND")
  card.bg:SetAllPoints()
  card.bg:SetColorTexture(0, 0, 0, 0.72)
  card.edge = card:CreateTexture(nil, "ARTWORK")
  card.edge:SetPoint("TOPLEFT")
  card.edge:SetPoint("BOTTOMLEFT")
  card.edge:SetWidth(2)
  card.face = NewFace(card)
  card.face:SetPoint("LEFT", 12, 0)
  card.face.back:Hide()
  card.face.bar:Hide()
  card.face.check:Hide()
  card.title = card:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  card.title:SetPoint("TOPLEFT", 52, -9)
  card.title:SetWidth(188)
  card.title:SetJustifyH("LEFT")
  card.text = card:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  card.text:SetPoint("TOPLEFT", card.title, "BOTTOMLEFT", 0, -3)
  card.text:SetWidth(188)
  card.text:SetJustifyH("LEFT")
  card.text:SetWordWrap(true)
  local fade = card:CreateAnimationGroup()
  local come = fade:CreateAnimation("Alpha")
  come:SetFromAlpha(0)
  come:SetToAlpha(1)
  come:SetDuration(0.25)
  come:SetOrder(1)
  card.go = fade:CreateAnimation("Alpha")
  card.go:SetFromAlpha(1)
  card.go:SetToAlpha(0)
  card.go:SetDuration(0.6)
  card.go:SetOrder(2)
  local function Gone()
    card:Hide()
    for i, one in ipairs(cards) do
      if one == card then table.remove(cards, i) break end
    end
    spare[#spare + 1] = card
    Stack()
  end
  fade:SetScript("OnFinished", Gone)
  card.fade = fade
  -- (a card that does something: clicked, it does it and goes)
  card:SetScript("OnMouseUp", function ()
    local onClick = card.onClick
    if not onClick then return end
    card.fade:Stop()
    Gone()
    onClick()
  end)
  return card
end

-- A card: about someone (full name; nil: icon instead), its title (in r, g,
-- b) and words, for hold seconds
local function Card(full, title, text, color, icon, hold, onClick)
  if #cards >= 3 then
    cards[#cards].fade:Stop()
    cards[#cards]:Hide()
    spare[#spare + 1] = table.remove(cards)
  end
  local card = table.remove(spare) or NewCard()
  Portrait(card.face, full, 30, icon)
  card.face.data = nil
  card.face.portrait:SetDesaturated(false)
  card.face:SetAlpha(1)
  local r, g, b = Core:TitleColor()
  if color then r, g, b = color[1], color[2], color[3] end
  card.edge:SetColorTexture(r, g, b, 0.9)
  card.title:SetText(title)
  card.title:SetTextColor(r, g, b)
  card.text:SetText(text or "")
  card:SetHeight(math.max(48, 22 + card.title:GetStringHeight() + (text and card.text:GetStringHeight() or 0)))
  card.go:SetStartDelay(hold or CARD_HOLD)
  card.onClick = onClick
  card:EnableMouse(onClick and true or false)
  table.insert(cards, 1, card)
  Stack()
  card:Show()
  card.fade:Stop()
  card.fade:Play()
end

local GREEN, RED = { 0.4, 1, 0.4 }, { 1, 0.35, 0.3 }

----
-- Your quests, told to the others

local function Mine()
  local now = {}
  for i = 1, C_QuestLog.GetNumQuestLogEntries() do
    local info = C_QuestLog.GetInfo(i)
    if info and not info.isHeader and not info.isHidden and not info.isTask and info.questID then
      now[info.questID] = State(info.questID)
    end
  end
  return now
end

-- "id=state" items in as few messages as fit, the first one headed so
local function SendItems(head, items)
  local message = head
  for _, item in ipairs(items) do
    if #message + #item + 1 > 250 then
      Send(message)
      message = "Q:"
    end
    message = message..(message:sub(-1) == ":" and "" or ",")..item
  end
  if message ~= "Q:" then Send(message) end
end

-- All of them (head "Q?:" asks the others for theirs too), or the changes
local function SendQuests(all, head)
  if not Party() then return end
  local now = Mine()
  local items = {}
  for questID, state in pairs(now) do
    if all or sent[questID] ~= state then items[#items + 1] = questID.."="..state end
  end
  if not all then
    for questID in pairs(sent) do
      if not now[questID] then
        local over = C_QuestLog.IsQuestFlaggedCompleted and C_QuestLog.IsQuestFlaggedCompleted(questID)
        items[#items + 1] = questID.."="..(over and "t" or "-")
      end
    end
    if #items == 0 then return false end
  end
  sent = now
  SendItems(all and (head or "Q!:") or "Q:", items)
  return true
end

----
-- What the others have

local function Others(questID)
  local list = {}
  for name, quests in pairs(others) do
    local state = quests[questID]
    if state and state ~= "-" and InGroup(name) then list[#list + 1] = { name = name, state = state } end
  end
  table.sort(list, function (a, b) return a.name < b.name end)
  return list
end

---
-- The faces under a quest: the others who have it (and, for the quest the
-- group is guided to, faded, the ones who don't); nil: nobody
function Core.GroupFaces(questID)
  if not (Together() and questID) then return nil end
  local list = Others(questID)
  if lead and lead.questID == questID then
    for name, quests in pairs(others) do
      if InGroup(name) and (not quests[questID] or quests[questID] == "-") then
        list[#list + 1] = { name = name, state = "-" }
      end
    end
  end
  return #list > 0 and list or nil
end

---
-- The ones not done with a quest yet: "Ana (3/8)", the first one's full
-- name; nil if none
function Core.GroupBehind(questID)
  if not (Together() and questID and questID > 0) then return nil end
  local behind, first = {}, nil
  for _, one in ipairs(Others(questID)) do
    if not Over(one.state) then
      local _, _, have, need = Counts(one.state)
      behind[#behind + 1] = Short(one.name)..(need > 0 and (" ("..have.."/"..need..")") or "")
      first = first or one.name
    end
  end
  return #behind > 0 and table.concat(behind, ", ") or nil, first
end

-- Everyone done with a quest you're done with: said once
local function CheckReady()
  local now = {} -- (several at once: one card)
  for questID, state in pairs(sent) do
    local list = state == "d" and Others(questID) or {}
    local all = #list > 0
    local waiting = false
    for _, one in ipairs(list) do
      if not Over(one.state) then all = false end
      if one.state == "d" then waiting = true end
    end
    if all and waiting then
      if not ready[questID] then
        ready[questID] = true
        now[#now + 1] = questID
      end
    else
      ready[questID] = nil
    end
  end
  if #now == 0 then return end
  Card(nil, "Everyone is ready", #now == 1 and ("to turn in "..(Title(now[1]) or "the quest"))
    or ("to turn in "..#now.." quests"), GREEN, READY)
  if _G.SOUNDKIT and _G.SOUNDKIT.READY_CHECK then _G.PlaySound(_G.SOUNDKIT.READY_CHECK) end
end

-- The quests the others have and you don't: { questID, title, names }
local function Missing()
  local byQuest, list = {}, {}
  for name, quests in pairs(others) do
    if InGroup(name) then
      for questID, state in pairs(quests) do
        if state ~= "-" and state ~= "t" and not C_QuestLog.GetLogIndexForQuestID(questID)
          and not (C_QuestLog.IsQuestFlaggedCompleted and C_QuestLog.IsQuestFlaggedCompleted(questID)) then
          if not byQuest[questID] then
            byQuest[questID] = { questID = questID, names = {} }
            list[#list + 1] = byQuest[questID]
          end
          table.insert(byQuest[questID].names, name)
        end
      end
    end
  end
  for _, one in ipairs(list) do
    one.title = Title(one.questID)
    table.sort(one.names)
  end
  table.sort(list, function (a, b)
    if (a.title ~= nil) ~= (b.title ~= nil) then return a.title ~= nil end
    if a.title ~= b.title then return (a.title or "") < (b.title or "") end
    return a.questID < b.questID
  end)
  return list
end

---
-- Asks someone to share a quest
function Core.AskShare(name, questID)
  Send("A:"..questID, name)
  _G.UIErrorsFrame:AddMessage("Asked "..Short(name).." to share it", 1, 0.82, 0)
end

_G.StaticPopupDialogs.QUESTMARK_SHARE = {
  text = "%s asks you to share:\n\n%s",
  button1 = "Share",
  button2 = "No",
  OnAccept = function (_, data) Core.ShareQuest(data) end,
  timeout = 60,
  whileDead = true,
  hideOnEscape = true,
  preferredIndex = 3,
}

----
-- Following the leader (not the leader)

local function ClearPoint()
  if not ourPoint then return end
  local now = C_Map.GetUserWaypoint and C_Map.GetUserWaypoint()
  if now and now.uiMapID == ourPoint.uiMapID and now.position and ourPoint.position
    and math.abs(now.position.x - ourPoint.position.x) < 0.0001
    and math.abs(now.position.y - ourPoint.position.y) < 0.0001 then
    C_Map.ClearUserWaypoint()
  end
  ourPoint, lastPlace = nil, nil
end

local function Point(mapID, x, y)
  if not (mapID and x and y and C_Map.CanSetUserWaypointOnMap and C_Map.CanSetUserWaypointOnMap(mapID) and _G.UiMapPoint) then
    return nil
  end
  local point = _G.UiMapPoint.CreateFromCoordinates(mapID, x, y)
  C_Map.SetUserWaypoint(point)
  return point
end

-- The navigation to the leader's quest (changed: the leader picked another
-- one: followed again even if you followed something else meanwhile)
local function Apply(changed)
  if not (lead and not lead.mine and following[lead.leader]) then return end
  local questID = lead.questID
  if C_QuestLog.GetLogIndexForQuestID(questID) then
    ClearPoint()
    if changed and C_SuperTrack.GetSuperTrackedQuestID() ~= questID and Core.FollowQuest then
      Core.FollowQuest(questID)
    end
    return
  end
  -- (not in your log: a marker where the leader's next step is)
  local place = lead.mapID and lead.x and (lead.mapID..":"..lead.x..":"..lead.y)
  if not place or (place == lastPlace and not changed) then return end
  local point = Point(lead.mapID, lead.x, lead.y)
  if not point then return end
  ourPoint, lastPlace = point, place
  if C_SuperTrack.SetSuperTrackedUserWaypoint then C_SuperTrack.SetSuperTrackedUserWaypoint(true) end
end

local function Always()
  Core.db.global.alwaysFollow = Core.db.global.alwaysFollow or {}
  return Core.db.global.alwaysFollow
end

function Core.FollowLeader(leader, always)
  if always then Always()[leader] = true end
  if not (lead and lead.leader == leader) then return end
  following[leader] = true
  Apply(true)
  Core.Refresh()
end

function Core.IgnoreLeader(leader)
  following[leader] = false
  ClearPoint()
  Core.Refresh()
end

_G.StaticPopupDialogs.QUESTMARK_GUIDE = {
  text = "%s wants to guide the group to:\n\n%s",
  button1 = "Follow",
  button2 = "Ignore",
  button3 = "Always follow",
  OnAccept = function (_, data) Core.FollowLeader(data) end,
  OnCancel = function (_, data, reason)
    if reason ~= "timeout" then Core.IgnoreLeader(data) end
  end,
  OnAlt = function (_, data) Core.FollowLeader(data, true) end,
  timeout = 60,
  whileDead = true,
  hideOnEscape = true,
  preferredIndex = 3,
}

----
-- Leading

local function SendLead(force)
  if not (lead and lead.mine) then return end
  local mapID, x, y = Core.QuestPlace and Core.QuestPlace(lead.questID)
  local where = (mapID and x and y) and ("%d:%.4f:%.4f"):format(mapID, x, y) or "0:0:0"
  local message = "L:"..lead.questID..":"..where..":"..lead.title
  if force or message ~= lastLead then
    lastLead = message
    if not Send(message) then lastLead = nil end
  end
end

-- Changes close together: one message (all: every quest, as to someone new)
local waiting, waitingAll, waitingHead = false, false, nil
local heard = false -- something came from the others meanwhile
local function Later(all, head)
  waitingAll = waitingAll or all
  if head then waitingHead = head end
  if waiting then return end
  waiting = true
  C_Timer.After(GAP, function ()
    local sendAll, sendHead = waitingAll, waitingHead
    waiting, waitingAll, waitingHead = false, false, nil
    -- (the tracker drawn again only if something changed: the quest log
    -- says it changed far more often than it does)
    local changed = SendQuests(sendAll, sendHead) or heard
    heard = false
    SendLead(false)
    CheckReady()
    if changed or lead then Core.Refresh() end
  end)
end

local function Drop()
  if not lead then return end
  ClearPoint()
  lead, lastLead = nil, nil
  Core.Refresh()
end

---
-- The leader: the group guided to a quest (nil: not any more)
function Core.GuideGroup(questID)
  if questID and Core.CanGuide() then
    local title = C_QuestLog.GetTitleForQuestID(questID)
    local already = lead and lead.mine
    lead = { questID = questID, title = Core.Readable(title) and title or ("Quest "..questID), leader = Me(), mine = true }
    SendLead(true)
    -- (said once: then each quest you focus moves the group along)
    if not already then Card(Me(), "You're guiding the group", lead.title) end
    Core.Refresh()
  elseif lead and lead.mine then
    Send("L:0")
    Drop()
  end
end

---
-- The quest the group is guided to by you (nil if none)
function Core.GuidedQuest()
  return lead and lead.mine and lead.questID or nil
end

---
-- Can you guide the group (the flag and the book's button show then)
function Core.CanGuide()
  return testing or (Together() and UnitIsGroupLeader("player") and true or false)
end

----
-- The flag by a quest's name in the tracker: the guided quest's, for
-- everyone; the leader's, over any quest (a click guides the group there)

local function FlagTooltip(flag)
  local questID = flag.questID
  local tooltip = _G.GameTooltip
  tooltip:SetOwner(flag, "ANCHOR_RIGHT")
  if lead and lead.questID == questID then
    if lead.mine then
      tooltip:SetText("You're guiding the group here")
      tooltip:AddLine("Click to stop", 1, 1, 1)
    else
      tooltip:SetText(Short(lead.leader).." is guiding the group here")
      if not following[lead.leader] then tooltip:AddLine("Click to follow", 1, 1, 1) end
    end
  else
    tooltip:SetText("Guide the group here")
    tooltip:AddLine("Everyone with Questmark is asked to follow: their navigation leads here", 1, 1, 1, true)
  end
  tooltip:Show()
end

local function FlagClick(flag)
  local questID = flag.questID
  if lead and lead.questID == questID and not lead.mine then
    Core.ClickLead()
  elseif Core.CanGuide() then
    Core.GuideGroup(Core.GuidedQuest() ~= questID and questID or nil)
  end
  _G.GameTooltip:Hide()
end

---
-- The flag of a quest's block (block.entry): shown or not; true if the
-- title must leave room for it
function Core.GroupFlag(block)
  local entry = block.entry
  local questID = entry and entry.kind == "quest" and entry.id
  local guided = questID and lead and lead.questID == questID and Together()
  local can = questID and Core.CanGuide()
  if not (guided or can) then
    if block.groupFlag then block.groupFlag:Hide() end
    return false
  end
  local flag = block.groupFlag
  if not flag then
    flag = CreateFrame("Button", nil, block)
    flag:SetSize(14, 14)
    flag:SetPoint("TOPRIGHT", block, "TOPRIGHT", 0, 1)
    flag.icon = Core.Smooth(flag:CreateTexture(nil, "OVERLAY"))
    flag.icon:SetAllPoints()
    flag.icon:SetTexture(Core.ASSETS.."navFlag")
    flag:SetScript("OnClick", FlagClick)
    flag:SetScript("OnEnter", function (self)
      FlagTooltip(self)
      Core.GroupFlag(block)
    end)
    flag:SetScript("OnLeave", function ()
      _G.GameTooltip:Hide()
      Core.GroupFlag(block)
    end)
    block.groupFlag = flag
  end
  flag.questID = questID
  -- (the leader's on every quest, faint, so it's found; brighter over the
  -- quest; lit on the guided one)
  flag:Show()
  local r, g, b = Core:TitleColor()
  if flag:IsMouseOver() then r, g, b = Core.Lighter(r, g, b, 0.4) end
  flag.icon:SetVertexColor(r, g, b, guided and 1 or (block:IsMouseOver() and 0.8 or 0.45))
  return true
end

----
-- The tracker's Group part

local WORDS = { d = "ready to turn in", t = "turned in", o = "on it" }

---
-- By an objective, how far each of the others is: "S 3  R 9 [check]", in
-- their class colors (the first letter of their name). nil: nobody, or not
-- questing together
local CHECK = "|TInterface\\RaidFrame\\ReadyCheck-Ready:0|t"

local function Tag(full)
  local name = Short(full) or "?"
  local first = name:match("^[%z\1-\127\194-\244][\128-\191]*") or name:sub(1, 1)
  local color = ClassColor(full)
  return (color and color.colorStr and "|c"..color.colorStr or "|cffdfba69")..first
end

function Core.GroupObjective(questID, index)
  if not (Together() and questID) then return nil end
  local chips = {}
  for _, one in ipairs(Others(questID)) do
    if Over(one.state) then
      chips[#chips + 1] = Tag(one.name).."|r"..CHECK
    else
      local count = (Counts(one.state))[index]
      if count then
        chips[#chips + 1] = Tag(one.name).." "..count[1]..(count[1] >= count[2] and "|r"..CHECK or "|r")
      end
    end
  end
  return #chips > 0 and table.concat(chips, "  ") or nil
end

-- By a quest you can turn in: "all ready", or who isn't yet and how far
function Core.GroupReady(questID)
  if not (Together() and questID) then return nil end
  local list, behind = Others(questID), {}
  if #list == 0 then return nil end
  for _, one in ipairs(list) do
    if not Over(one.state) then
      local _, _, have, need = Counts(one.state)
      behind[#behind + 1] = Tag(one.name)..(need > 0 and (" "..have.."/"..need) or "").."|r"
    end
  end
  if #behind == 0 then return "|cff66ff66all ready|r" end
  return table.concat(behind, "  ")
end

-- The others in the party with Questmark (full names, sorted)
local function Known()
  local list = {}
  if not Party() then return list end
  for name in pairs(others) do
    if InGroup(name) then list[#list + 1] = name end
  end
  table.sort(list)
  return list
end

-- How many of a person's quests (that you have too) they can turn in
local function ReadyCount(full)
  local count = 0
  for questID, state in pairs(others[full] or {}) do
    if state == "d" and C_QuestLog.GetLogIndexForQuestID(questID) then count = count + 1 end
  end
  return count
end

function Core.LeadSection()
  local section = { key = "lead", title = "Quest together", entries = {}, count = 0 }
  local known = testing and {} or Known()
  if not On() or not (Together() or #known > 0) then return section end
  -- Off: one line, the switch (a click on it turns it on)
  if not Together() then
    section.title = "Quest together  |cff999999off|r"
    section.closed = true
    section.entries[1] = { kind = "groupMissing", key = "groupMissing", title = "", lines = {}, missing = {} }
    section.count = 1
    return section
  end
  section.title = "Quest together  |cff66ff66on|r"
  if lead then
    -- (the quest itself in the tracker, with its flag and faces, says it
    -- all: the part only when it isn't, or you don't follow yet)
    local inTracker = false
    for _, questID in ipairs(Core.ShownQuestIDs()) do
      if questID == lead.questID then inTracker = true end
    end
    if not (inTracker and (lead.mine or following[lead.leader])) then
      local who
      if lead.mine then
        who = "You're guiding the group"
      elseif following[lead.leader] then
        who = Short(lead.leader).." is guiding the group"
      else
        who = Short(lead.leader).." is guiding the group: click to follow"
      end
      local lines = { { key = "who", text = who, plain = true } }
      local list = Others(lead.questID)
      for name, quests in pairs(others) do
        if InGroup(name) and (not quests[lead.questID] or quests[lead.questID] == "-") then
          list[#list + 1] = { name = name, state = "-" }
        end
      end
      if #list > 0 then lines[#lines + 1] = { key = "faces", text = "", plain = true, group = true, faces = list } end
      section.entries[#section.entries + 1] = {
        kind = "lead", key = "lead", id = lead.questID, title = lead.title, lines = lines,
      }
    end
  end
  if Party() then
    local missing = Missing()
    -- Who's in it, and how many quests each can turn in
    local who = {}
    for _, name in ipairs(Known()) do
      local ready = ReadyCount(name)
      who[#who + 1] = Colored(name)..(ready > 0 and (" |cff999999- "..ready.." ready|r") or "")
    end
    local whoLine = #who > 0 and { key = "who", plain = true, text = table.concat(who, "   ") } or nil
    -- Their quests you don't have: one line, opened by a click (the list
    -- can be long)
    local saved = Core.db.char.collapsedSections
    local open = saved and saved.leadOpen
    local words = #missing > 0 and (#missing.." quest"..(#missing > 1 and "s" or "").." you don't have") or nil
    if #missing == 0 or not open then
      section.entries[#section.entries + 1] = {
        kind = "groupMissing", key = "groupMissing", lines = { whoLine },
        title = words and (words.."  |cff999999(click)|r") or "Nothing new to ask for", missing = missing,
      }
    else
      local lines = { whoLine }
      for i, one in ipairs(missing) do
        if i > MISSING_SHOWN then
          lines[#lines + 1] = { key = "more", text = "and "..(#missing - MISSING_SHOWN).." more (right click)", plain = true }
          break
        end
        local names = {}
        for _, name in ipairs(one.names) do names[#names + 1] = Colored(name) end
        local first = one.names[1]
        lines[#lines + 1] = {
          -- (the game's "quest to take" mark in place of the dash: it can be
          -- asked for)
          key = "m"..one.questID, plain = true,
          text = ASK_ICON..(one.title or "...").." |cff999999-|r "..table.concat(names, ", "),
          onClick = function () Core.AskShare(first, one.questID) end,
          tip = "Click to ask "..Short(first).." to share it"..(#one.names > 1 and "\n(right click: the others)" or ""),
        }
      end
      section.entries[#section.entries + 1] = {
        kind = "groupMissing", key = "groupMissing", title = words, lines = lines, missing = missing,
      }
    end
  end
  section.count = #section.entries
  return section
end

---
-- A click on the leader's quest: follow the leader (if you didn't)
function Core.ClickLead()
  if lead and not lead.mine and not following[lead.leader] then Core.FollowLeader(lead.leader) end
end

---
-- The right click menu of the Group part's entries
function Core.LeadMenu(root, entry)
  if entry and entry.kind == "groupMissing" then
    local buttons = 0
    for _, one in ipairs(entry.missing or {}) do
      for _, name in ipairs(one.names) do
        if buttons < 12 then
          buttons = buttons + 1
          root:CreateButton("Ask "..Short(name)..": "..(one.title or ("quest "..one.questID)), function ()
            Core.AskShare(name, one.questID)
          end)
        end
      end
    end
    return
  end
  if not lead then return end
  if lead.mine then
    root:CreateButton("Stop guiding the group", function () Core.GuideGroup(nil) end)
  elseif following[lead.leader] then
    root:CreateButton("Stop following", function () Core.IgnoreLeader(lead.leader) end)
  else
    root:CreateButton("Follow", function () Core.FollowLeader(lead.leader) end)
  end
  if not lead.mine and Always()[lead.leader] then
    local leader = lead.leader
    root:CreateButton("Don't always follow "..Short(leader), function () Always()[leader] = nil end)
  end
end

----
-- Messages

local function OnQuests(sender, kind, body)
  local new = others[sender] == nil
  if kind ~= "Q:" then others[sender] = {} end
  local quests = others[sender] or {}
  others[sender] = quests
  for questID, state in body:gmatch("(%d+)=([^,]+)") do
    questID = tonumber(questID)
    if state == "-" then quests[questID] = nil else quests[questID] = state end
  end
  -- (the first time someone else has Questmark: what it does, once)
  -- (once per person each session, while not questing together: how to)
  if new and not together then
    Card(sender, Short(sender).." has Questmark too",
      "|cffffffffClick to quest together|r: see how far everyone is (or click their face by Quests).",
      nil, nil, 15, function () Core.SetQuestTogether(true) end)
  end
  -- (someone new, or back after a reload: ours too)
  if kind == "Q?:" then Later(true, "Q!:") end
  heard = true
  Later(false)
end

local function OnLead(sender, message)
  if sender ~= LeaderName() or not Together() then return end
  local questID = tonumber(message:match("^L:(%d+)"))
  if not questID or questID == 0 then
    Drop()
    return
  end
  local mapID, x, y, title = message:match("^L:%d+:(%d+):([%d%.]+):([%d%.]+):(.*)$")
  local changed = not lead or lead.questID ~= questID or lead.leader ~= sender
  mapID = tonumber(mapID)
  lead = {
    questID = questID, title = (title and title ~= "") and title or ("Quest "..questID),
    mapID = mapID ~= 0 and mapID or nil, x = tonumber(x), y = tonumber(y), leader = sender,
  }
  if following[sender] == nil and Always()[sender] then following[sender] = true end
  if following[sender] then
    Apply(changed)
    if changed then Card(sender, Short(sender).." is guiding the group", lead.title) end
  elseif following[sender] == nil and changed then
    _G.StaticPopup_Show("QUESTMARK_GUIDE", Short(sender), lead.title, sender)
  end
  Core.Refresh()
end

-- The leader took a quest: where, marked on your map (if you have no
-- marker of your own there already). Taken close together, as at a town
-- full of quests: one card
local took = {} -- the leader's quests taken, waiting to be said together
local TOOK_WAIT = 3 -- seconds

local function OnTook(sender, message)
  if sender ~= LeaderName() or not Together() then return end
  local questID, mapID, x, y, title = message:match("^T:(%d+):(%d+):([%d%.]+):([%d%.]+):(.*)$")
  questID = tonumber(questID)
  if not questID or C_QuestLog.GetLogIndexForQuestID(questID)
    or (C_QuestLog.IsQuestFlaggedCompleted and C_QuestLog.IsQuestFlaggedCompleted(questID)) then
    return
  end
  took[#took + 1] = title ~= "" and title or "a quest"
  if #took > 1 then return end
  local marked = false
  if not (C_Map.HasUserWaypoint and C_Map.HasUserWaypoint()) then
    marked = Point(tonumber(mapID), tonumber(x), tonumber(y)) ~= nil
  end
  C_Timer.After(TOOK_WAIT, function ()
    local text = #took == 1 and took[1] or (#took <= 3 and table.concat(took, ", ")
      or (took[1]..", "..took[2].." and "..(#took - 2).." more"))
    Card(sender, Short(sender)..(#took == 1 and " took a quest here" or (" took "..#took.." quests here")),
      text..(marked and "\n|cff999999Marked on your map|r" or ""))
    wipe(took)
  end)
end

local function OnMessage(prefix, message, _, sender)
  if prefix ~= PREFIX or not On() then return end
  if issecretvalue and (issecretvalue(message) or issecretvalue(sender)) then return end
  if type(message) ~= "string" or type(sender) ~= "string" then return end
  -- ("Name-Realm". WoW: Forever writes "Name Realm", or the name alone for
  -- your own realm)
  local name, realm = sender:match("^([^%s%-]+)[%s%-](.+)$")
  if name then
    sender = name.."-"..realm:gsub("[%s%-]", "")
  else
    sender = sender.."-"..MyRealm()
  end
  if sender == Me() then return end

  local kind, body = message:match("^(Q[!?]?:)(.*)$")
  if kind then
    if Party() then OnQuests(sender, kind, body) end
    return
  end
  local head = message:sub(1, 2)
  if head == "L:" then
    OnLead(sender, message)
  elseif head == "T:" then
    OnTook(sender, message)
  elseif head == "A:" then
    -- (asked to share: a Share button, if it can be shared)
    local questID = tonumber(message:sub(3))
    if not (questID and C_QuestLog.GetLogIndexForQuestID(questID)) then return end
    if C_QuestLog.IsPushableQuest and not C_QuestLog.IsPushableQuest(questID) then
      Send("N:"..questID, sender)
      return
    end
    _G.StaticPopup_Show("QUESTMARK_SHARE", Short(sender), Title(questID) or ("quest "..questID), questID)
  elseif head == "N:" then
    local questID = tonumber(message:sub(3))
    Card(sender, Short(sender).." can't share it", questID and Title(questID) or nil, RED)
  end
end

-- About to turn in a quest someone isn't done with yet: a word (once per
-- talk)
local warned
local members = "" -- who's in the party ("a,b,c"): all our quests to someone new only

local function Members()
  local list = {}
  for i = 1, 4 do
    local unit = "party"..i
    if _G.UnitExists(unit) then list[#list + 1] = FullName(unit) or "" end
  end
  table.sort(list)
  return table.concat(list, ",")
end

local function TurningIn(event)
  local questID = _G.GetQuestID and _G.GetQuestID()
  if event == "QUEST_FINISHED" or not questID then
    warned = nil
    return
  end
  local behind, first = Core.GroupBehind(questID)
  if behind and warned ~= questID then
    warned = questID
    Card(first, "Not everyone is done", behind, RED)
  end
end

events:SetScript("OnEvent", function (_, event, ...)
  if event == "CHAT_MSG_ADDON" then
    OnMessage(...)
  elseif event == "GROUP_ROSTER_UPDATE" or event == "PARTY_LEADER_CHANGED" or event == "PLAYER_ENTERING_WORLD" then
    if not IsInGroup() and not testing then
      together = false
      Drop()
      wipe(others)
      wipe(sent)
      wipe(following)
      members = ""
      return
    end
    if lead and lead.leader ~= LeaderName() then Drop() end
    if lead and lead.mine then lastLead = nil end
    -- (gone from the group: forgotten)
    for name in pairs(others) do
      if not InGroup(name) then others[name] = nil end
    end
    -- (someone new, or after a login or reload: all of ours, and theirs
    -- asked for. The game says the group changed for far less: its
    -- members' levels, places...)
    local isLogin, isReload = ...
    local now = Members()
    if (event == "PLAYER_ENTERING_WORLD" and (isLogin or isReload))
      or (event == "GROUP_ROSTER_UPDATE" and now ~= members) then
      Later(true, "Q?:")
    end
    members = now
    Core.Refresh()
  elseif event == "PLAYER_REGEN_ENABLED" then
    if failed then
      failed = false
      lastLead = nil
      Later(true, "Q!:")
    end
  elseif event == "SUPER_TRACKING_CHANGED" then
    -- The leader questing together focuses a quest: the group is guided
    -- there (the flag by a quest does the same)
    if Together() and UnitIsGroupLeader("player") then
      local questID = C_SuperTrack.GetSuperTrackedQuestID and C_SuperTrack.GetSuperTrackedQuestID()
      if questID and questID > 0 and questID ~= Core.GuidedQuest() and C_QuestLog.GetLogIndexForQuestID(questID) then
        Core.GuideGroup(questID)
      end
    end
  elseif event == "QUEST_DATA_LOAD_RESULT" then
    if IsInGroup() or testing then Core.Refresh() end
  elseif event == "QUEST_PROGRESS" or event == "QUEST_COMPLETE" or event == "QUEST_FINISHED" then
    TurningIn(event)
  elseif IsInGroup() then
    local questID = ...
    if lead and lead.mine and questID == lead.questID and (event == "QUEST_TURNED_IN" or event == "QUEST_REMOVED") then
      -- (the leader's quest gone: the group isn't guided any more)
      C_Timer.After(0.5, function ()
        if lead and lead.mine and not C_QuestLog.GetLogIndexForQuestID(questID) then Core.GuideGroup(nil) end
      end)
    end
    if event == "QUEST_ACCEPTED" and questID then
      if lead and questID == lead.questID then Apply(true) end
      -- (the leader took it: where, told to the others)
      if On() and UnitIsGroupLeader("player") then
        local mapID = C_Map.GetBestMapForUnit("player")
        local position = mapID and C_Map.GetPlayerMapPosition(mapID, "player")
        local x, y
        if position then x, y = position:GetXY() end
        local title = C_QuestLog.GetTitleForQuestID(questID)
        if x and y and Core.Readable(title) and title then
          Send(("T:%d:%d:%.4f:%.4f:%s"):format(questID, mapID, x, y, title))
        end
      end
    end
    if On() then Later(false) end
  end
end)

Core:OnChange(function (key)
  if key == "enable" then
    if not (Core.trackerOn and C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix) then return end
    C_ChatInfo.RegisterAddonMessagePrefix(PREFIX)
    for _, event in ipairs({
      "CHAT_MSG_ADDON", "GROUP_ROSTER_UPDATE", "PARTY_LEADER_CHANGED", "PLAYER_ENTERING_WORLD",
      "PLAYER_REGEN_ENABLED", "QUEST_LOG_UPDATE", "QUEST_ACCEPTED", "QUEST_REMOVED", "QUEST_TURNED_IN",
      "QUEST_DATA_LOAD_RESULT", "QUEST_PROGRESS", "QUEST_COMPLETE", "QUEST_FINISHED", "SUPER_TRACKING_CHANGED",
    }) do
      pcall(events.RegisterEvent, events, event)
    end
  elseif key == "groupLead" or key == "profile" then
    if not On() then
      if lead and lead.mine then Send("L:0") end
      Drop()
      wipe(others)
      wipe(sent)
    elseif IsInGroup() then
      Later(true, "Q?:")
    end
    Core.Refresh()
  end
end)

---
-- The list of their quests you don't have: opened or closed
function Core.ToggleGroupMissing()
  local saved = Core.db.char
  saved.collapsedSections = saved.collapsedSections or {}
  saved.collapsedSections.leadOpen = not saved.collapsedSections.leadOpen or nil
  Core.Refresh()
end

---
-- Quest together: on or off (nil: the other way); false if not in a party
function Core.QuestTogether()
  return Together() and true or false
end

function Core.SetQuestTogether(on)
  if on == nil then on = not together end
  if on and not Party() then
    print("|cffdfba69Questmark|r: Quest together works in a party (not a raid).")
    return
  end
  together = on and true or false
  if not together then
    if lead and lead.mine then Send("L:0") end
    Drop()
  else
    Later(true, "Q?:")
  end
  Core.Refresh()
end

---
-- The faces by the Quests title: the others in the party with Questmark,
-- grey while not questing together, in color when you are; a click turns
-- it on or off. Returns the room they take (0: none)
local HEADER_FACE = 14
function Core.GroupHeader(header)
  local list = {}
  if Party() and not testing then
    for name in pairs(others) do
      if InGroup(name) then list[#list + 1] = { name = name, state = together and "o" or "-" } end
    end
    table.sort(list, function (a, b) return a.name < b.name end)
  end
  local holder = header.groupFaces
  if #list == 0 then
    if holder then holder:Hide() end
    return 0
  end
  if not holder then
    holder = CreateFrame("Button", nil, header)
    holder:RegisterForClicks("LeftButtonUp")
    holder:SetScript("OnClick", function () Core.SetQuestTogether() end)
    holder:SetScript("OnEnter", function (self)
      local tooltip = _G.GameTooltip
      tooltip:SetOwner(self, "ANCHOR_LEFT")
      tooltip:SetText(together and "Questing together" or "Quest together")
      tooltip:AddLine(together and "Click to stop seeing the group's progress"
        or "Click to see how far everyone is in your quests", 1, 1, 1, true)
      tooltip:Show()
    end)
    holder:SetScript("OnLeave", function () _G.GameTooltip:Hide() end)
    header.groupFaces = holder
  end
  local _, width = Core.DrawFaces(holder, list, HEADER_FACE, nil, true)
  for _, face in ipairs(holder.faces) do face:EnableMouse(false) end
  holder:SetSize(width, HEADER_FACE)
  holder:Show()
  return width
end

---
-- /qm testgroup: two made-up friends with your own quests (one done with
-- some, one on its way), a quest of theirs you don't have, and the cards
-- one after another. Again: back to normal
function Core.GroupTest()
  testing = not testing
  wipe(others)
  Drop()
  if testing then
    local ana, rui = {}, {}
    local i = 0
    for questID, state in pairs(Mine()) do
      i = i + 1
      ana[questID] = i % 3 == 0 and "d" or (i % 3 == 1 and "1/4+0/2" or "o")
      if i % 2 == 0 then rui[questID] = state == "d" and "d" or "3/8" end
    end
    -- (quests you won't have: the first ones of the human and orc starts)
    for _, questID in ipairs({ 783, 7, 4641 }) do
      if not C_QuestLog.GetLogIndexForQuestID(questID) then ana[questID] = "0/5" end
    end
    others["Ana-Test"], others["Rui-Test"] = ana, rui
    Card("Ana-Test", "Ana has Questmark too",
      "Under your quests, their faces show how far they are. Leader: the flag by a quest guides everyone there.",
      nil, nil, 12)
    C_Timer.After(2, function () Card(nil, "Everyone is ready", "to turn in a quest", GREEN, READY) end)
    C_Timer.After(4, function () Card("Rui-Test", "Not everyone is done", "Rui (3/8)", RED) end)
    C_Timer.After(6, function () Card("Ana-Test", "Ana took a quest here", "A quest\n|cff999999Marked on your map|r") end)
  end
  print("|cffdfba69Questmark|r: group test", testing and "on (/qm testgroup again: off)" or "off")
  Core.Refresh()
end
