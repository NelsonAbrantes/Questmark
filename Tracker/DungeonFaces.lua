local _, ns = ...
local Core = ns.Core

----
-- The faces of dungeon bosses the addon knows from the start (boss name ->
-- what the game draws for it), so the dungeon card shows them without any
-- other addon. Gathered in game: each one is a face the game showed when the
-- boss was seen (Dungeon.lua learns them). Grows with each version.

Core.KNOWN_FACES = {
}
