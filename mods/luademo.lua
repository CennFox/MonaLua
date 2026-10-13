-- luademo.lua -- a tool whose behaviour is written in Lua.
--
-- The tool itself (name, icon, aim type, ammo, its place in the tool pool) is created by the
-- patcher: tick "luademo" in the combo tools list (it has no effects of its own), tick
-- "Lua mods", and patch.  Without the tool in the build this file simply never runs.
ml.on_fire("luademo", function(ctx)
	local ax, ay = ctx.aim()                 -- where the crosshair is
	if not ax then ax, ay = ctx.x, ctx.y - 40 end
	for i = -1, 1 do
		local frog = ml.spawn("frog", ax + i * 24, ay)
		if frog.physics then ml.set_velocity(frog, i * 120, -200) end
	end
	print(string.format("luademo: three frogs at (%.0f, %.0f)", ax, ay))
end)
