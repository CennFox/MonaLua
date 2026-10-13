-- avalanche.lua -- how much can the game take?  Pour real physics objects into the level until
-- it creaks, and watch it creak.
--
--   hold K   objects pour out of the mouse pointer, as fast as RATE says
--   press L  sweeps away everything that was poured
--
-- Every object is one of the game's own (balls, boxes), with a real Box2D body: they stack, roll,
-- jam, get blown up by bombs and eaten by the Black Hole.  Top left there is a meter: one small
-- square per 50 objects poured, and under it the time each frame takes, a column per frame.
-- Green columns are a smooth 60 frames a second or better, yellow down to 30, red below that.

local THINGS = { "ball", "box" }   -- what is poured, in turn (names of game objects; unknown ones are skipped)
local RATE   = 6        -- objects per frame while K is held
local LIMIT  = 3000     -- never more than this many at once
local SPRAY  = 90       -- how fast they leave the pointer (pixels per second)
local POUR, CLEAR = "k", "l"

local floor, cos, sin = math.floor, math.cos, math.sin

local function state()
	local v = ml.vars()
	if v.poured == nil then v.poured, v.n, v.made, v.frame = {}, 0, 0, 0 end
	return v
end

-- the mouse pointer in level coordinates (written down frame by frame, so that a GIF replay,
-- which has no mouse, pours in the same places)
local tape = {}
ml.on_level(function() if not ml.replaying() then tape = {} end end)
local function pointer()
	local tick = ml.tick()
	if ml.replaying() then
		local p = tape[tick]
		if p then return p[1], p[2] end
		return nil
	end
	local x, y
	pcall(function()
		local scene = ml.layout.scene
		local root = scene:getScene()
		local pt = mosa.new("h2d.col.PointImpl", root:get_mouseX(), root:get_mouseY())
		scene:globalToLocal(pt)
		x, y = pt.x, pt.y
	end)
	if x == nil then x, y = ml.aim_point() end
	if x ~= nil then tape[tick] = { x, y } end
	return x, y
end

---------------------------------------------------------------- the meter

-- how long frames really take: measured on the game's own clock tick, outside the level's time
local times, at, last_dt = {}, 0, 0
mosa.on("tick", function(dt)
	last_dt = dt or 0
	at = at % 150 + 1
	times[at] = last_dt
end)

local function meter(v)
	if v.gfx == nil then
		local ok = pcall(function()
			local top = 0
			for _, inst in ipairs(ml.all()) do
				local l = inst.sprite.layer
				if l > top then top = l end
			end
			local g = mosa.new("h2d.Graphics")
			ml.layout.scene:add(g, top, nil)
			v.gfx = g
		end)
		if not ok then v.gfx = false end
	end
	local g = v.gfx
	if not g then return end
	pcall(function()
		g:clear()
		-- one square per 50 objects
		g:beginFill(0xFFFFFF, 0.9)
		for i = 0, floor(v.n / 50) - 1 do
			g:drawRect(8 + (i % 30) * 5, 8 + floor(i / 30) * 5, 4, 4)
		end
		g:endFill()
		-- frame times, oldest left: 1 pixel of height per millisecond, the line is 16.7 ms
		local base = 60
		local groups = { {}, {}, {} }
		for i = 1, 150 do
			local dt = times[(at + i - 1) % 150 + 1]
			if dt then
				local ms = dt * 1000
				local grp = ms <= 17.5 and 1 or (ms <= 34 and 2 or 3)
				groups[grp][#groups[grp] + 1] = { i, math.min(ms, 40) }
			end
		end
		for k, colour in ipairs({ 0x4CD964, 0xFFCC00, 0xFF3B30 }) do
			if #groups[k] > 0 then
				g:beginFill(colour, 0.9)
				for _, c in ipairs(groups[k]) do g:drawRect(8 + c[1], base - c[2], 1, c[2]) end
				g:endFill()
			end
		end
		g:beginFill(0xFFFFFF, 0.5)
		g:drawRect(8, base - 16.7, 151, 0.5)
		g:endFill()
	end)
end

---------------------------------------------------------------- pouring

local kinds
local function pour(v)
	if kinds == nil then
		kinds = {}
		for _, name in ipairs(THINGS) do if ml.can_spawn(name) then kinds[#kinds + 1] = name end end
		if #kinds == 0 then print("the game has none of the objects in THINGS") end
	end
	if #kinds == 0 then return end
	local x, y = pointer()
	if x == nil then return end
	for _ = 1, RATE do
		if v.n >= LIMIT then return end
		v.made = v.made + 1
		local k = v.made
		-- a fan of directions that never repeats soon (no random numbers: a replay must match)
		local a = k * 2.399963
		local o = ml.spawn(kinds[k % #kinds + 1], x + cos(a) * 4, y + sin(a) * 4)
		if o ~= nil then
			if o.physics ~= nil then
				pcall(function() ml.freeze(o, false) end)
				ml.set_velocity(o, cos(a) * SPRAY, sin(a) * SPRAY * 0.5 + SPRAY * 0.3)
			end
			v.n = v.n + 1
			v.poured[v.n] = o
		end
	end
end

ml.on_update(function()
	if not ml.gameplay() then return end
	local v = state()
	v.frame = v.frame + 1
	if ml.key_down(POUR) then pour(v) end
	if ml.key_pressed(CLEAR) and v.n > 0 then
		for i = 1, v.n do ml.destroy(v.poured[i]) end
		print(string.format("swept away %d objects", v.n))
		v.poured, v.n = {}, 0
	end
	-- forget what something else has destroyed meanwhile
	if v.frame % 30 == 0 and v.n > 0 then
		local keep, n = {}, 0
		for i = 1, v.n do
			local o = v.poured[i]
			if o.sprite.destroyed == false then n = n + 1; keep[n] = o end
		end
		v.poured, v.n = keep, n
	end
	if v.n == 0 then
		if v.shown then v.shown = false; pcall(function() v.gfx:clear() end) end
	else
		v.shown = true
		meter(v)
		if v.frame % 120 == 0 and not ml.replaying() then
			local sum, cnt, worst = 0, 0, 0
			for i = 1, 150 do local d = times[i]; if d then sum, cnt = sum + d, cnt + 1; if d > worst then worst = d end end end
			local bodies = 0
			pcall(function() bodies = #b2.bodies() end)
			print(string.format("%d poured objects, %d bodies in the world: %.1f ms per frame on average (%.0f frames a second), worst %.1f ms",
				v.n, bodies, sum / cnt * 1000, cnt / sum, worst * 1000))
		end
	end
end)

print("avalanche: hold " .. POUR:upper() .. " to pour objects out of the mouse pointer, " .. CLEAR:upper() .. " sweeps them away")
