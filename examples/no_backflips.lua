-- no_backflips.lua -- no backflips, without switching Director's Cut on.  Copy into mods\ to use.
--
-- How the game does it (read from its code): every frame the gameplay sheet sets each
-- player's `backflip` variable: to 1 normally, to 0 when Director's Cut is on.  A backflip
-- only starts while it is 1, and while it is 0 the game uses its other turn-around handling.
-- That is the whole of what Director's Cut does to backflips, so this mod makes the "set it
-- to 1" line set 0 instead.  Everything else Director's Cut changes stays as it is.
-- (The backflip tool, if you draw it, does nothing either: it asks the same variable.)
local SET_TO_ONE = "fish.game.evsheet.EvSheet_gameplay:11156"    -- the event block `player.backflip = 1`

if mosa.hookable(SET_TO_ONE) then
	mosa.replace(SET_TO_ONE, function(player) player.backflip = 0 end)
	print("backflips are off (the game's own switch for them, as under Director's Cut)")
elseif mosa.hookable("fish.game.evsheet.EvSheet_gameplay.backflip_start") then
	-- a game update moved that block: stop the backflip itself from starting instead
	ml.before_game("backflip_start", function() return false end)
	print("backflips are off (by blocking backflip_start: the game's code has changed since this mod was written)")
else
	print("cannot find the game's backflip code: this mod does nothing in this version of the game")
end
