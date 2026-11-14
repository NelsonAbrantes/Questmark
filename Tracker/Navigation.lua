local _, ns = ...
local Core = ns.Core

----
-- The navigation marker (Options: Navigation marker): the game's own mark
-- on the screen over the place a followed quest leads to, with how far it
-- is. It's a setting of the game (in-game navigation) the addon turns on
-- while the option is on, and puts back as it was when it's turned off.

local function GameNavigation(on)
  local SetCVar, GetCVar = _G.SetCVar, _G.GetCVar
  if not (SetCVar and GetCVar) then return end
  local profile = Core.db.profile
  if on and GetCVar("showInGameNavigation") ~= "1" then
    profile.navWas = GetCVar("showInGameNavigation")
    pcall(SetCVar, "showInGameNavigation", "1")
  elseif not on and profile.navWas then
    pcall(SetCVar, "showInGameNavigation", profile.navWas)
    profile.navWas = nil
  end
end

Core:OnChange(function (key)
  if key == "enable" then
    if Core.db.profile.navMarker then GameNavigation(true) end
  elseif key == "navMarker" or key == "profile" then
    GameNavigation(Core.db.profile.navMarker)
  end
end)
