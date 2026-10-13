-- gravity_gun.lua -- hold G to carry the loose object nearest to the crosshair, let go to drop
-- it, press F while carrying to throw it.  Copy into mods\ to use.
--
-- "Loose" means something with a moving physics body: a box or ball you shot, a creature, a
-- falling block.  Level terrain does not move, and coins are left alone.  In a level with
-- nothing loose, shoot a box first.  What is being carried turns half transparent, and every
-- grab is written to mods\mosalua.log.
--
-- Shows: a per-frame handler, keys, finding objects through the physics world, forces.
local REACH = 150                                    -- pixels around the crosshair
local SKIP = { player = true, coin = true }
-- What is being carried lives in ml.vars(): empty when a level starts, and separate for a
-- GIF replay of the level, in which this mod carries and throws the same things again.

local function loose(inst)
	return not SKIP[inst.type] and ml.alive(inst) and b2.body(inst) ~= nil
		and b2.type(inst) == "dynamic" and b2.mass(inst) > 0
end

-- the loose object whose centre is nearest to a point: Box2D tells what has a shape around there
local function pick(x, y)
	local best, best_d
	for _, inst in ipairs(b2.instances_in(x - REACH, y - REACH, x + REACH, y + REACH)) do
		if loose(inst) then
			local cx, cy = b2.center(inst)
			local d = math.sqrt((cx - x) ^ 2 + (cy - y) ^ 2)
			if d <= REACH and (best_d == nil or d < best_d) then best, best_d = inst, d end
		end
	end
	return best
end

local function release(v)
	if v.held and v.opacity and ml.alive(v.held) then v.held.sprite:setOpacity(v.opacity) end
	v.held, v.opacity = nil, nil
end

ml.on_update(function(dt)
	local v = ml.vars()
	local p = ml.player()
	local ax, ay
	if p then ax, ay = ml.aim_point(p) end
	if not ax or not ml.key_down("g") then
		release(v)
		v.told, v.thrown = nil, nil
		return
	end
	if v.thrown then return end                      -- after a throw: let go of G before grabbing again
	if v.held and not loose(v.held) then release(v) end
	if not v.held then
		v.held = pick(ax, ay)
		if not v.held then
			if not v.told then
				v.told = true
				print("gravity gun: nothing loose within " .. REACH .. " px of the crosshair (shoot a box or a ball first)")
			end
			return
		end
		print(string.format("gravity gun: carrying a %s (mass %.3f, weight %.3f)", tostring(v.held.type), b2.mass(v.held), ml.weight(v.held)))
		v.opacity = v.held.sprite:getOpacity()
		v.held.sprite:setOpacity(v.opacity * 0.5)
	end
	local held = v.held
	-- a damped spring towards the crosshair, plus a force that carries the object's weight
	local x, y = b2.center(held)
	local vx, vy = b2.velocity(held)
	local m, s = b2.mass(held), b2.scale()
	local pull, drag = 120, 22                       -- stiffness and damping: about critically damped
	b2.force(held, ((ax - x) * pull - vx * drag) * s * m,
		((ay - y) * pull - vy * drag) * s * m - ml.weight(held))
	if ml.key_pressed("f") then
		local px, py = ml.pos(p)
		local dx, dy = ax - px, ay - py
		local len = math.sqrt(dx * dx + dy * dy)
		if len > 0 then b2.launch(held, dx / len * 900, dy / len * 900) end
		print("gravity gun: threw the " .. tostring(held.type))
		release(v)
		v.thrown = true
	end
end)
