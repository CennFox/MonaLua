-- moon.lua -- low gravity, and everything loose bounces.  Copy into mods\ to use.
-- Shows: the game's gravity, changing every object as it appears, a hook on a native.

-- The game gives every object its own weight (see "gravity" in the guide), so gravity is
-- changed with ml, not with Box2D's world gravity.  1 is normal, 0 weightless, -1 falls up.
ml.set_gravity_scale(0.3)

ml.on_create("*", function(inst)
	if inst.physics and b2.body(inst) and b2.type(inst) == "dynamic" then
		b2.set_restitution(inst, 0.6)                -- 0 = no bounce, 1 = keeps all its speed
	end
end)

-- natives can be hooked like any other function: here, the physics step itself.
-- Hold T for slow motion that only affects physics.
mosa.hook("fish@world_step", function(orig, world, dt, velocity_iterations, position_iterations)
	if ml.key_down("t") then dt = dt * 0.25 end
	return orig(world, dt, velocity_iterations, position_iterations)
end)
