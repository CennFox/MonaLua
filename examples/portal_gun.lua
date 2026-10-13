-- portal_gun.lua -- a new tool for the item pool: the Portal Gun.
--
-- It never runs out.  Every shot opens a portal on the first solid surface in the direction of
-- the cursor: blue, orange, blue, orange...  A new portal of a colour replaces the old one of
-- that colour.  While both are open, whatever goes into one comes out of the other with the
-- speed it went in with, turned to point away from the wall it comes out of.  That goes for
-- you and for every loose object: boxes, bombs, creatures.
--
-- The tool has a picture of its own and sounds of its own; both are made in this file (the
-- picture from the rows of letters below, the sounds from the functions further down).  To
-- use other sounds put WAV files with the names in SOUND_FILES into the mods folder.
--
-- Press P in a level to get the gun at once.

local PORTAL_HALF    = 20        -- half the length of a portal (pixels; a tile is about 30 wide)
local RANGE          = 2000      -- how far a shot travels
local MIN_EXIT_SPEED = 90        -- things come out at least this fast (pixels per second)
local COOLDOWN       = 0.25      -- seconds before the same thing can go through a portal again
local TRY_KEY        = "p"       -- gives you the gun at once, for trying it out; nil switches that off
local BLUE, ORANGE   = 0x2E9BFF, 0xFF8A1E
-- A sound file in the mods folder with one of these names is used instead of the built-in sound.
local SOUND_FILES = {
	shoot_blue   = "portal_gun_shoot_blue.wav",
	shoot_orange = "portal_gun_shoot_orange.wav",
	enter        = "portal_gun_enter.wav",
	miss         = "portal_gun_miss.wav",
}
-- played when a sound of this mod cannot be loaded; one of the game's own
local FALLBACK_SOUND = "vaporites_create_pull_freeze alternative 2"

local TOOL = "portal_gun"

if not ml.add_sound then
	print("this mod needs the Lua kit 1.5.0 or later (yours is " .. tostring(ml.version) .. "): run the new mosalua_patcher.py, then start the game again")
	return
end

---------------------------------------------------------------- the tool and its picture

local PICTURE = {
	rows = {
		"................",
		"................",
		"..........oo....",
		".........o..o...",
		"...WWWWWWWb.o...",
		"..WWWWWWWWWb....",
		".KWWGGGGWWWWbb..",
		".KWWGBBGWWWWKbB.",
		".KWWGBBGWWWWKbB.",
		".KWWGGGGWWWWbb..",
		"..WWWWWWWWWb....",
		"...WWKKWWWb.o...",
		"....KKK..o..o...",
		"....KK....oo....",
		"................",
		"................",
	},
	palette = { W = 0xF2F2F2, K = 0x20242C, G = 0x8A93A0, B = BLUE, b = 0x9AD0FF, o = ORANGE },
}

ml.add_tool{ name = TOOL, label = "Portal Gun", aim = "long", ammo = 1, icon = "gun", picture = PICTURE }

---------------------------------------------------------------- the sounds

local sin, exp, pi, random = math.sin, math.exp, math.pi, math.random

-- a falling whistle with a little hiss at the start
local function shot(from, to)
	return function(t, len)
		local k = t / len
		local freq = from + (to - from) * k * (2 - k)
		local phase = 2 * pi * (from * t + (to - from) * (t * t / len - t * t * t / (3 * len * len)))
		local tone = sin(phase) * 0.6 + sin(phase * 2.01) * 0.2
		local hiss = (random() * 2 - 1) * exp(-t * 60) * 0.5
		local fade = exp(-t * 9) * math.min(1, t * 400)
		return (tone * fade + hiss) * 0.8
	end
end

-- a short rush of air: noise that opens and closes, over a sinking hum
local low = 0
local function whoosh(t, len)
	local k = t / len
	local shape = sin(pi * k) ^ 2
	low = low + ((random() * 2 - 1) - low) * (0.05 + 0.3 * k)      -- noise through a filter that opens up
	local hum = sin(2 * pi * (220 * t - 70 * t * t / len)) * 0.35
	return (low * 1.6 + hum) * shape * 0.8
end

-- a dull double thud
local function thud(t)
	local a = sin(2 * pi * 140 * t) * exp(-t * 30)
	local b = t > 0.07 and sin(2 * pi * 105 * (t - 0.07)) * exp(-(t - 0.07) * 30) or 0
	return (a + b) * 0.6
end

local MADE = {
	shoot_blue   = { 0.32, shot(1500, 520) },
	shoot_orange = { 0.32, shot(1150, 380) },
	enter        = { 0.30, whoosh },
	miss         = { 0.22, thud },
}

for key, made in pairs(MADE) do
	local name = "portal_gun_" .. key
	local ok, why = ml.add_sound(name, SOUND_FILES[key])
	if not ok then ok, why = ml.add_sound(name, made[1], made[2]) end
	if not ok then print("sound '" .. key .. "': " .. tostring(why)) end
end

local function sound(key)
	local ok, played = pcall(ml.sfx, "portal_gun_" .. key)
	if (not ok or played == nil) and FALLBACK_SOUND then pcall(ml.sfx, FALLBACK_SOUND) end
end

---------------------------------------------------------------- the portals on screen

local drawn = {}             -- { gfx, layout } of every portal on screen, in the level and in a replay of it

local function top_layer()
	local top = 0
	for _, inst in ipairs(ml.instances("physics_obj")) do
		local layer = inst.sprite.layer
		if layer > top then top = layer end
	end
	return top
end

-- an oval lying on the surface: a ring of the portal's colour around a dark middle
local function draw_portal(p, color)
	local layout = ml.layout
	local turn = math.atan(-p.nx, p.ny)              -- the direction of the surface
	local ok, g = pcall(function()
		local g = mosa.new("h2d.Graphics")
		local function oval(rx, ry, c, alpha)
			g:beginFill(c, alpha)
			if not pcall(function() g:drawEllipse(0, 0, rx, ry, turn, 24) end) then g:drawCircle(0, 0, ry + 2, 16) end
			g:endFill()
		end
		oval(PORTAL_HALF + 3, 7, color, 0.35)
		oval(PORTAL_HALF + 1, 5, color, 1)
		oval(PORTAL_HALF - 2, 2.5, 0x0B0E14, 1)
		g:setPosition(p.x + p.nx * 2, p.y + p.ny * 2)
		layout.scene:add(g, top_layer(), nil)
		return g
	end)
	if not ok then
		print("could not draw the portal (it works all the same): " .. tostring(g))
		return nil
	end
	drawn[#drawn + 1] = { g, layout }
	return g
end

local function erase(g)
	if g == nil then return end
	for i = #drawn, 1, -1 do
		if drawn[i][1] == g then table.remove(drawn, i) end
	end
	pcall(function() g:remove() end)
end

ml.on_level_end(function(layout)
	for i = #drawn, 1, -1 do
		if drawn[i][2] == layout then
			local g = drawn[i][1]
			table.remove(drawn, i)
			pcall(function() g:remove() end)
		end
	end
end)

---------------------------------------------------------------- shooting

local function state()
	local v = ml.vars()
	if v.portals == nil then v.portals, v.next, v.movers, v.frame, v.trips = {}, 1, {}, 0, 0 end
	return v
end

-- A shot stops at the first thing that is fixed in place and solid: it goes through the
-- player, through loose objects and through things that only detect a touch (fruit, triggers).
local function solid_and_fixed(inst, fixture)
	if inst == nil then return false end
	local ok, sensor = pcall(b2.is_sensor, fixture)
	if ok and sensor then return false end
	local ok2, kind = pcall(b2.type, fixture)
	return ok2 and kind ~= "dynamic"
end

ml.on_fire(TOOL, function(ctx)
	local v = state()
	ctx.item.ammo = ctx.item.ammo + 1                -- it never runs out: the shot is given back
	local ax, ay = ctx.aim()
	if ax == nil then return end
	local dx, dy = ax - ctx.x, ay - ctx.y
	local d = math.sqrt(dx * dx + dy * dy)
	if d < 1 then return end
	dx, dy = dx / d, dy / d
	local hit = b2.raycast(ctx.x, ctx.y, ctx.x + dx * RANGE, ctx.y + dy * RANGE, solid_and_fixed)
	if hit == nil then
		sound("miss")
		return
	end
	local which = v.next
	v.next = 3 - which
	local old = v.portals[which]
	if old ~= nil then erase(old.gfx) end
	local p = { x = hit.x, y = hit.y, nx = hit.nx, ny = hit.ny }
	p.gfx = draw_portal(p, which == 1 and BLUE or ORANGE)
	v.portals[which] = p
	sound(which == 1 and "shoot_blue" or "shoot_orange")
end)

---------------------------------------------------------------- going through

-- the loose things of the level (the player is one of them); asked for a few times a second
local function find_movers(v)
	local known = {}
	for _, e in ipairs(v.movers) do known[e.inst.uid] = e end
	local list = {}
	for _, inst in ipairs(ml.instances("physics_obj")) do
		local sp, ph = inst.sprite, inst.physics
		if ph ~= nil and sp.destroyed == false then
			local ok, kind = pcall(b2.type, inst)
			if ok and kind == "dynamic" then
				list[#list + 1] = known[inst.uid] or { inst = inst, sprite = sp, physics = ph, cool = 0 }
			end
		end
	end
	v.movers = list
end

local abs, max, min, sqrt = math.abs, math.max, math.min, math.sqrt

-- e is at portal a: is it going in?  Returns the speed it goes in with, or nil.
local function entering(e, a, px, py, vx, vy, dt)
	local rx, ry = px - a.x, py - a.y
	local along = -rx * a.ny + ry * a.nx             -- along the surface, from the middle of the portal
	if abs(along) > PORTAL_HALF then return nil end
	local out = rx * a.nx + ry * a.ny                -- how far in front of the surface its middle is
	local sp = e.sprite
	local reach = (sp.width * abs(a.nx) + sp.height * abs(a.ny)) / 2
	local vn = vx * a.nx + vy * a.ny                 -- below zero: moving towards the surface
	-- the speed of the frame before counts too: touching the wall has already stopped it
	local was = (e.pvx or 0) * a.nx + (e.pvy or 0) * a.ny
	local inward = max(-vn, -was, 0)
	if out < -6 or out > reach + 3 + inward * dt * 2 then return nil end
	if vn > 20 then return nil end                   -- on its way out
	return inward, along
end

ml.on_update(function()
	local v = ml.vars()
	if v.portals == nil then return end
	v.frame = v.frame + 1
	if v.frame % 8 == 1 then find_movers(v) end
	local a, b = v.portals[1], v.portals[2]
	local now, dt = ml.time(), ml.dt()
	local movers = v.movers
	for i = 1, #movers do
		local e = movers[i]
		if e.sprite.destroyed == false then
			local ph = e.physics
			local vx, vy = ph:getVelocityX(), ph:getVelocityY()
			if e.again ~= nil then
				-- the frame after a trip: the speed is set once more, in case the game's own
				-- code for that object had the last word in the frame of the trip
				ph:setVelocity(e.again[1], e.again[2])
				vx, vy = e.again[1], e.again[2]
				e.again = nil
			elseif a ~= nil and b ~= nil and now >= e.cool then
				local p = e.sprite.position
				local px, py = p.x, p.y
				local from, to = a, b
				local inward, along = entering(e, a, px, py, vx, vy, dt)
				if inward == nil then
					from, to = b, a
					inward, along = entering(e, b, px, py, vx, vy, dt)
				end
				if inward ~= nil then
					-- the speed along the wall it went into, as it was before the wall could stop it
					local use_x, use_y = vx, vy
					if -((e.pvx or 0) * from.nx + (e.pvy or 0) * from.ny) > -(vx * from.nx + vy * from.ny) then use_x, use_y = e.pvx, e.pvy end
					local slide = -use_x * from.ny + use_y * from.nx
					local speed = max(inward, MIN_EXIT_SPEED)
					-- out of the other portal: what went in straight comes out straight, and what
					-- went in sideways keeps its sideways part (turned with the portal)
					local tx, ty = to.ny, -to.nx
					local ox, oy = to.nx * speed + tx * slide, to.ny * speed + ty * slide
					local sp = e.sprite
					local reach = (sp.width * abs(to.nx) + sp.height * abs(to.ny)) / 2 + 4
					local shift = max(-PORTAL_HALF, min(PORTAL_HALF, along))
					ml.set_pos(e.inst, to.x + to.nx * reach + tx * shift, to.y + to.ny * reach + ty * shift)
					ph:setVelocity(ox, oy)
					e.again = { ox, oy }
					e.cool = now + COOLDOWN
					vx, vy = ox, oy
					v.trips = v.trips + 1
					sound("enter")
				end
			end
			e.pvx, e.pvy = vx, vy
		end
	end
end)

---------------------------------------------------------------- trying it out

if TRY_KEY then
	ml.on_key(TRY_KEY, function()
		if not ml.gameplay() or ml.player() == nil then return end
		local ok, err = pcall(ml.give_tool, TOOL)
		if not ok then print("could not hand out the Portal Gun: " .. tostring(err)) end
	end)
end

print("the Portal Gun is in the item pool" .. (TRY_KEY and (" (press " .. TRY_KEY:upper() .. " in a level to get one at once)") or ""))
