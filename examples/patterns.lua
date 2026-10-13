-- patterns.lua -- cut-and-paste starting points.  Files in _examples are never loaded;
-- copy what you want into a new file directly inside mods\ .  See also the complete little
-- mods next to this file: gravity_gun.lua, grapple.lua, moon.lua.

------------------------------------------------------------------ tools
-- react when ANY existing tool is fired ("bomb", "rocket", "frog", ... or "*" for all)
ml.on_fire("bomb", function(ctx)
	-- ctx.player, ctx.x, ctx.y, ctx.aim(), ctx.angle(), ctx.item.ammo
	ml.sfx("frog")                                   -- any of the game's sound names
end)

------------------------------------------------------------------ objects
-- ml.spawn("frog", x, y)            create any of the ~680 object types (ml.spawnable() lists them)
-- ml.destroy(inst)                  remove one
-- ml.pos(inst) / ml.set_pos(inst, x, y) / ml.set_velocity(inst, vx, vy) / ml.impulse(inst, strength, angle)
-- ml.instances("coin")              every live instance of a type or family
-- inst.someVariable                 the object's own variables (see mods\explore_classes.txt)

ml.on_create("frog", function(frog) ml.set_size(frog, 32, 32) end)       -- as each one appears
ml.on_destroy("coin", function(coin) print("a coin went at", ml.pos(coin)) end)
ml.each_frame("frog", function(frog, dt) end)                             -- every frame, per object

------------------------------------------------------------------ collisions
-- selectors: a type ("frog"), a family ("physics_obj"), "*", one object, or function(inst) -> bool
ml.on_collision("frog", "*", function(frog, other, hit)
	-- hit.x, hit.y, hit.nx, hit.ny (from frog to other), hit.speed; safe to spawn/destroy here
	if hit.speed > 300 then ml.explode(hit.x, hit.y, 40) end
end)
ml.on_impact("*", "*", 5, function(a, b, hit) end)                        -- only hard hits (hit.strength)
ml.no_collide("frog", "coin")                                             -- never touch each other
ml.pass_through("player", "frog", function(player, frog) return ml.key_down("shift") end)

------------------------------------------------------------------ your own kind of object
ml.define("heavy_frog", {
	base = "frog",                                    -- the game object it is made from
	init = function(inst) ml.set_density(inst, 20); b2.set_restitution(inst, 0.5) end,
	tick = function(inst, dt) end,
	collide = function(inst, other, hit) end,
	destroy = function(inst) end,
})
-- ml.spawn("heavy_frog", x, y)      and "heavy_frog" works in every selector above

------------------------------------------------------------------ physics
-- ml.set_gravity_scale(0.3)                         gravity of everything (the game's own, see the guide)
-- ml.gravity(inst, 0)                               one object floats; ml.weight(inst) is the force pulling on it
-- b2.launch(inst, vx, vy)                           add velocity, whatever the mass
-- b2.set_restitution(inst, 0.9) / b2.set_friction(inst, 0) / ml.set_density(inst, 5)
-- b2.raycast(x1, y1, x2, y2) -> hit.inst, hit.x, hit.y, hit.distance
-- b2.instances_in(x1, y1, x2, y2) / b2.instance_at(x, y)
-- b2.revolute(a, b, x, y)   hinge      b2.distance(a, b, { length = 80, frequency = 2 })   rope / spring
-- b2.add_circle(inst, 60, { sensor = true })        an extra shape on an object (here: a detector)
-- b2.raw.body_get_angle(b2.body(inst))              any of the 126 natives directly (metres, radians)

------------------------------------------------------------------ the game's own functions
-- named functions of the gameplay sheet (ml.game_functions() lists them), by name:
ml.on_game("jump", function(player_id) print("jump", player_id) end)
ml.before_game("jump", function(player_id) return not ml.key_down("ctrl") end)   -- false = it does not happen
ml.on_explosion(function(x, y, radius, power) end)
ml.on_player_death(function(player_id) end)                                      -- return false to prevent it

-- anything else: mods\hookable.txt lists every hookable function with its argument types
mosa.hook("fish@world_step", function(orig, world, dt, vi, pi) return orig(world, dt, vi, pi) end)   -- a native
-- mosa.trace("EvSheet_gameplay:1127")              -- logs each call: handy to learn what a block does

------------------------------------------------------------------ time and keys
ml.after(2, function() print("two seconds of level time later") end)     -- follows slow motion, ends with the level
mosa.delay(2, function() end)                                             -- real time, survives level changes
ml.on_key("g", function() print("G pressed") end)
-- ml.key_down("space") / ml.set_time_scale(0.25)
