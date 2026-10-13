-- black_hole.lua -- a new tool for the item pool: the Black Hole.
--
-- Long aim, one shot.  Where you fire it a small hole opens.  For ten seconds it slowly pulls
-- every tile and every other object of the level towards it and swallows whatever reaches its
-- centre.  Then it closes and everything stays frozen where it is.  The player and the fruit
-- are not pulled.
--
-- The tool is drawn at random like the game's own, shows up in the tool grid (after the next
-- start of the game) and can be pinned there.  To try it right away, press B in a level: the
-- tool in your hand becomes a Black Hole.

local PULL_SECONDS = 10      -- how long the hole stays open
local PULL_SPEED   = 14      -- how fast things drift towards it, in pixels per second (a tile is about 30 wide)
local HOLE_RADIUS  = 9       -- what touches this small centre is deleted (pixels)
local TRY_KEY      = "b"     -- gives you the tool at once, for trying it out; nil switches that off
local SOUND        = "vaporites_create_pull_freeze alternative 2"   -- one of the game's sounds; nil = silent
-- Object types it leaves alone.  The fruit ("coin") stays where it hangs: the exit only opens
-- when every fruit has been collected, so a level whose fruit went into the hole could not be
-- finished any more.  Take a line out to see what happens to that kind of object.
local SPARE = {
	player = true,
	coin = true, portalberry = true, portalberry2 = true,
}

local TOOL = "black_hole"

if not ml.add_tool then
	print("this mod needs the Lua kit 1.4.0 or later (yours is " .. tostring(ml.version) .. "): run the new mosalua_patcher.py, or copy the new mods/_lib files, then start the game again")
	return
end

-- name: what the game calls it inside.  label: what the player reads.  icon: the picture of
-- one of the game's own tools (the vortex is the closest thing it has to a black hole).
ml.add_tool{ name = TOOL, label = "Black Hole", aim = "long", ammo = 1, icon = "vortex" }

---------------------------------------------------------------- the hole on screen

-- a dark disc with a violet rim, drawn straight into the level's scene (above the level's objects)
local drawn = {}             -- { gfx, layout } of every hole on screen, in the level and in a replay of it

local function draw_hole(x, y, layer)
	local layout = ml.layout
	local ok, g = pcall(function()
		local g = mosa.new("h2d.Graphics")
		g:beginFill(0x8A4DFF, 0.5)
		g:drawCircle(0, 0, HOLE_RADIUS + 5, 28)
		g:endFill()
		g:beginFill(0x000000, 1)
		g:drawCircle(0, 0, HOLE_RADIUS + 1, 28)
		g:endFill()
		g:setPosition(x, y)
		g:setScale(0.1)
		layout.scene:add(g, layer, nil)
		return g
	end)
	if ok then
		drawn[#drawn + 1] = { g, layout }
		return g
	end
	print("could not draw the hole (it works all the same): " .. tostring(g))
	return nil
end

local function erase(hole)
	local g = hole.gfx
	if g == nil then return end
	hole.gfx = nil
	for i = #drawn, 1, -1 do
		if drawn[i][1] == g then table.remove(drawn, i) end
	end
	pcall(function() g:remove() end)
end

-- a level that ends with a hole still open takes its picture along
ml.on_level_end(function(layout)
	for i = #drawn, 1, -1 do
		if drawn[i][2] == layout then
			local g = drawn[i][1]
			table.remove(drawn, i)
			pcall(function() g:remove() end)
		end
	end
end)

---------------------------------------------------------------- what it does

-- Everything of the level that has a body is in the game's "physics_obj" family: the tiles,
-- spikes, coins, boxes, creatures, things other tools made.  Tiles are ordinary objects that
-- the game keeps immovable; ml.freeze(inst, false) lets one go, ml.freeze(inst) holds it again.

local function spared(inst)
	local t = inst.type
	if SPARE[t] then return true end
	if t == "frog" then                      -- a frog the player is steering is the player
		local ok, mine = pcall(function() return inst.playerControlled end)
		return ok and mine == true
	end
	return false
end

-- remember every object once: its sprite and physics are asked for many times a second
local function take_in(v)
	local known, list = v.known, v.list
	-- (forget the ones that are gone, keeping the order)
	local n = 0
	for i = 1, #list do
		local e = list[i]
		if not e.gone then n = n + 1; list[n] = e end
	end
	for i = #list, n + 1, -1 do list[i] = nil end
	for _, inst in ipairs(ml.instances("physics_obj")) do
		local uid = inst.uid
		if known[uid] == nil then
			known[uid] = false
			local ph = inst.physics
			if ph ~= nil and not spared(inst) then
				local sprite = inst.sprite
				local e = { inst = inst, sprite = sprite, physics = ph }
				known[uid] = e
				list[#list + 1] = e
				local layer = sprite.layer
				if layer > v.top_layer then v.top_layer = layer end
				ml.freeze(inst, false)
				-- no weight while it is pulled, or everything would sag below the hole: the
				-- game takes an object's weight from its personal_gravity (given back at the end)
				pcall(function()
					local weight = inst.personal_gravity
					if type(weight) == "number" and weight ~= 0 then
						e.weight = weight
						inst.personal_gravity = 0
					end
				end)
			end
		end
	end
end

local function open_hole(x, y)
	local v = ml.vars()
	if v.holes == nil then v.holes, v.known, v.list, v.top_layer, v.frame, v.swallowed = {}, {}, {}, 0, 0, 0 end
	take_in(v)
	local hole = { x = x, y = y, born = ml.time(), ends = ml.time() + PULL_SECONDS }
	hole.gfx = draw_hole(x, y, v.top_layer)
	v.holes[#v.holes + 1] = hole
	if SOUND then pcall(ml.sfx, SOUND) end
	print(string.format("opened at (%.0f, %.0f): %d objects let go%s", x, y, #v.list, ml.replaying() and " (in a GIF replay)" or ""))
end

ml.on_fire(TOOL, function(ctx)
	local x, y = ctx.aim()                   -- the cursor
	if x == nil then x, y = ctx.x, ctx.y end
	open_hole(x, y)
end)

-- the centre: whatever really touches the small circle goes
local exact = true
local function swallow(v, hole)
	local known = v.known
	local r = HOLE_RADIUS
	local fixtures
	if exact then
		local ok, list = pcall(b2.fixtures_at, hole.x, hole.y, r)
		if ok then fixtures = list else exact = false end
	end
	if fixtures == nil then fixtures = b2.query(hole.x - r, hole.y - r, hole.x + r, hole.y + r) end
	for _, f in ipairs(fixtures) do
		local inst = b2.owner(f)
		local e = inst ~= nil and known[inst.uid]
		if e and not e.gone then
			ml.destroy(inst)
			e.gone = true
			v.swallowed = v.swallowed + 1
		end
	end
end

local sqrt, sin = math.sqrt, math.sin

ml.on_update(function()
	local v = ml.vars()
	local holes = v.holes
	if holes == nil or #holes == 0 then return end
	local now = ml.time()

	-- holes whose time is up close
	for i = #holes, 1, -1 do
		if now >= holes[i].ends then
			erase(holes[i])
			table.remove(holes, i)
		end
	end
	local list = v.list
	if #holes == 0 then
		-- the last one closed: everything stays where it is, for good
		local frozen = 0
		for i = 1, #list do
			local e = list[i]
			if not e.gone and e.sprite.destroyed == false then
				e.physics:setVelocity(0, 0)
				e.physics:setAngularVelocity(0)
				ml.freeze(e.inst)
				if e.weight then e.inst.personal_gravity = e.weight end
				frozen = frozen + 1
			end
		end
		print(string.format("closed: %d objects swallowed, %d frozen where they were", v.swallowed, frozen))
		v.list, v.known, v.swallowed = {}, {}, 0
		return
	end

	-- things that appeared since (another tool, a spawner) are pulled too
	v.frame = v.frame + 1
	if v.frame % 6 == 0 then
		take_in(v)
		list = v.list
	end

	-- a steady drift towards the nearest hole: the speed is set anew every frame, so a
	-- collision is never more than a nudge
	local reach = HOLE_RADIUS * HOLE_RADIUS
	for i = 1, #list do
		local e = list[i]
		if not e.gone then
			if e.sprite.destroyed ~= false then
				e.gone = true
			else
				local p = e.sprite.position
				local px, py = p.x, p.y
				local dx, dy, d2 = 0, 0, math.huge
				for k = 1, #holes do
					local h = holes[k]
					local hx, hy = h.x - px, h.y - py
					local q = hx * hx + hy * hy
					if q < d2 then dx, dy, d2 = hx, hy, q end
				end
				if d2 <= reach then
					ml.destroy(e.inst)       -- its middle is in the hole
					e.gone = true
					v.swallowed = v.swallowed + 1
				else
					local s = PULL_SPEED / sqrt(d2)
					e.physics:setVelocity(dx * s, dy * s)
				end
			end
		end
	end

	for i = 1, #holes do
		local h = holes[i]
		swallow(v, h)
		if h.gfx ~= nil then
			-- it grows open, breathes a little, and shrinks away at the end
			local age, left = now - h.born, h.ends - now
			local size = 1 + 0.07 * sin(age * 7)
			if age < 0.3 then size = size * (age / 0.3) end
			if left < 0.5 then size = size * (left / 0.5) end
			if size < 0.05 then size = 0.05 end
			local g = h.gfx
			if not pcall(function() g:setScale(size) end) then erase(h) end
		end
	end
end)

---------------------------------------------------------------- trying it out

if TRY_KEY then
	ml.on_key(TRY_KEY, function()
		if not ml.gameplay() or ml.player() == nil then return end
		local ok, err = pcall(ml.give_tool, TOOL)
		if not ok then print("could not hand out the Black Hole: " .. tostring(err)) end
	end)
end

print("the Black Hole is in the item pool" .. (TRY_KEY and (" (press " .. TRY_KEY:upper() .. " in a level to get one at once)") or ""))
