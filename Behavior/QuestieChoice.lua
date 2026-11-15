local _, ns = ...
local Core = ns.Core

-- luacheck: push ignore 113
local C_Timer = C_Timer
-- luacheck: pop

----
-- Two quest trackers: with Questie's tracker on as well as Questmark's, the
-- game's dialog box asks once which one to keep. Questmark turns the other off
-- and reloads the UI. "Both" asks no more.

local function QuestieTrackerOn()
  local AddOns = _G.C_AddOns
  local loaded = AddOns and AddOns.IsAddOnLoaded and AddOns.IsAddOnLoaded("Questie")
  local questie = _G.Questie
  local profile = loaded and type(questie) == "table" and questie.db and questie.db.profile
  return profile and profile.trackerEnabled and true or false
end

-- The game's own dialog box (it looks like the rest of the game's)
local function Ask()
  local Dialogs = _G.StaticPopupDialogs
  if not (Dialogs and _G.StaticPopup_Show) then return end
  local function Chosen() Core.db.global.trackerAsked = true end
  Dialogs.QUESTMARK_TRACKER_CHOICE = Dialogs.QUESTMARK_TRACKER_CHOICE or {
    text = "Questmark and Questie both have a quest tracker on.\nWhich one do you want to keep?",
    button1 = "Questmark",
    button2 = "Questie",
    button3 = "Both",
    -- (the other one off, then a reload by Questmark itself: the game
    -- blocks the reload when Questie's own code asks for it from here)
    -- Questmark's: Questie's tracker off
    OnAccept = function ()
      Chosen()
      _G.Questie.db.profile.trackerEnabled = false
      _G.ReloadUI()
    end,
    -- Questie's: Questmark's tracker off
    OnCancel = function (_, _, reason)
      if reason ~= "clicked" then return end
      Chosen()
      Core.db.profile.useTracker = false
      _G.ReloadUI()
    end,
    OnAlt = Chosen,
    timeout = 0,
    whileDead = true,
    hideOnEscape = false,
  }
  _G.StaticPopup_Show("QUESTMARK_TRACKER_CHOICE")
end

Core:OnChange(function (key)
  if key ~= "enable" then return end
  if Core.db.global.trackerAsked or Core.db.profile.useTracker == false then return end
  -- (a moment after logging in: Questie sets itself up then)
  C_Timer.After(6, function ()
    if QuestieTrackerOn() and not _G.InCombatLockdown() then Ask() end
  end)
end)
