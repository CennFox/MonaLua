-- fold.lua -- a new tool for the item pool: Fold.
--
-- Two shots.  The first marks a line through the cursor, the second another one: the strip of
-- level between the two lines is deleted, and the two sides slide together until they meet in
-- the middle.  The level is shorter (or lower) from then on.
--
-- Which way it folds follows from the two points: further apart sideways than up and down, and
-- a standing strip is cut out and left and right close in; otherwise a lying strip is cut out
-- and top and bottom close in.  The player, the fruit and the exit are never deleted, and
-- loose objects are left to the physics: the ground slides away under them, walls push them.
--
-- Press O in a level to get the tool at once.

local SLIDE_SECONDS = 1.2    -- how long the two sides take to meet
local MIN_WIDTH     = 8      -- two marks closer than this (pixels) do nothing
local TRY_KEY       = "o"    -- gives you the tool at once, for trying it out; nil switches that off
local MARK_COLOR    = 0x7CFFB2
local SOUND         = "vaporites_create_pull_freeze alternative 2"   -- one of the game's sounds; nil = silent
-- Object types that are never deleted with the strip.
local SPARE = {
	player = true,
	coin = true, portalberry = true, portalberry2 = true,
}

local TOOL = "fold"

if not ml.add_tool then
	print("this mod needs the Lua kit 1.4.0 or later (yours is " .. tostring(ml.version) .. "): run the new mosalua_patcher.py, then start the game again")
	return
end

ml.add_tool{ name = TOOL, label = "Fold", aim = "long", ammo = 2, icon = "shift" }

---------------------------------------------------------------- the marks on screen

local drawn = {}             -- { gfx, layout } of every mark on screen, in the level and in a replay of it

local function top_layer()
	local top = 0
	for _, inst in ipairs(ml.instances("physics_obj")) do
		local layer = inst.sprite.layer
		if layer > top then top = layer end
	end
	return top
end

-- a cross of two thin lines through the point, long enough to cross any level
local function draw_mark(x, y)
	local layout = ml.layout
	local ok, g = pcall(function()
		local g = mosa.new("h2d.Graphics")
		g:beginFill(MARK_COLOR, 0.55)
		g:drawRect(-1, -3000, 2, 6000)
		g:drawRect(-3000, -1, 6000, 2)
		g:endFill()
		g:beginFill(MARK_COLOR, 1)
		g:drawCircle(0, 0, 4, 16)
		g:endFill()
		g:setPosition(x, y)
		layout.scene:add(g, top_layer(), nil)
		return g
	end)
	if not ok then
		print("could not draw the mark (the tool works all the same): " .. tostring(g))
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

---------------------------------------------------------------- the fold

local function spared(inst)
	local t = inst.type
	if SPARE[t] then return true end
	if t == "frog" then                      -- a frog the player is steering is the player
		local ok, mine = pcall(function() return inst.playerControlled end)
		return ok and mine == true
	end
	return false
end

-- Cuts the strip between a and b out of the level and starts the two sides moving.
-- axis "x": a standing strip (a, b are x positions); axis "y": a lying one.
local function fold(v, axis, a, b)
	if a > b then a, b = b, a end
	local half = (b - a) / 2
	local speed = half / SLIDE_SECONDS
	local moving, deleted = {}, 0
	for _, inst in ipairs(ml.instances("physics_obj")) do
		local sp, ph = inst.sprite, inst.physics
		if ph ~= nil and sp.destroyed == false then
			local p = sp.position
			local c = axis == "x" and p.x or p.y
			local keep = spared(inst)
			if c > a and c < b then
				if not keep then
					ml.destroy(inst)
					deleted = deleted + 1
				end
			elseif not keep then
				-- Only what is fixed in place is moved by the tool: tiles and other terrain.
				local ok, kind = pcall(b2.type, inst)
				if ok and kind ~= "dynamic" then
					local dir = c <= a and 1 or -1
					local e = { inst = inst, sprite = sp, physics = ph, dir = dir }
					if axis == "x" then e.tx, e.ty = p.x + dir * half, p.y else e.tx, e.ty = p.x, p.y + dir * half end
					ml.freeze(inst, false)
					-- no weight while it slides (the game takes an object's weight from personal_gravity)
					pcall(function()
						local weight = inst.personal_gravity
						if type(weight) == "number" and weight ~= 0 then
							e.weight = weight
							inst.personal_gravity = 0
						end
					end)
					moving[#moving + 1] = e
				end
			end
		end
	end
	v.slide = { axis = axis, speed = speed, ends = ml.time() + SLIDE_SECONDS, list = moving }
	if SOUND then pcall(ml.sfx, SOUND) end
	print(string.format("folded along %s from %.0f to %.0f: %d objects deleted, %d sliding%s",
		axis, a, b, deleted, #moving, ml.replaying() and " (in a GIF replay)" or ""))
end

ml.on_fire(TOOL, function(ctx)
	local v = ml.vars()
	local x, y = ctx.aim()
	if x == nil then x, y = ctx.x, ctx.y end
	if v.slide ~= nil then
		ctx.item.ammo = ctx.item.ammo + 1    -- the level is still moving: the shot is given back
		return
	end
	if v.mark == nil then
		v.mark = { x = x, y = y, gfx = draw_mark(x, y) }
		return
	end
	local m = v.mark
	v.mark = nil
	erase(m.gfx)
	local dx, dy = math.abs(x - m.x), math.abs(y - m.y)
	if math.max(dx, dy) < MIN_WIDTH then
		print("the two marks are too close together: nothing folded")
		return
	end
	if dx >= dy then fold(v, "x", m.x, x) else fold(v, "y", m.y, y) end
end)

ml.on_update(function()
	local v = ml.vars()
	local s = v.slide
	if s == nil then return end
	local list = s.list
	if ml.time() < s.ends then
		-- a steady speed, set anew every frame, so that nothing in the way slows a side down
		local speed, along_x = s.speed, s.axis == "x"
		for i = 1, #list do
			local e = list[i]
			if e.sprite.destroyed == false then
				if along_x then e.physics:setVelocity(e.dir * speed, 0) else e.physics:setVelocity(0, e.dir * speed) end
			end
		end
		return
	end
	-- the sides have met: everything is put exactly where it belongs and fixed again
	local fixed = 0
	for i = 1, #list do
		local e = list[i]
		if e.sprite.destroyed == false then
			e.physics:setVelocity(0, 0)
			e.physics:setAngularVelocity(0)
			local p = e.sprite.position
			if math.abs(p.x - e.tx) > 0.25 or math.abs(p.y - e.ty) > 0.25 then ml.set_pos(e.inst, e.tx, e.ty) end
			ml.freeze(e.inst)
			if e.weight then e.inst.personal_gravity = e.weight end
			fixed = fixed + 1
		end
	end
	v.slide = nil
	print(string.format("the fold is closed: %d objects fixed in their new place", fixed))
end)

---------------------------------------------------------------- trying it out

if TRY_KEY then
	ml.on_key(TRY_KEY, function()
		if not ml.gameplay() or ml.player() == nil then return end
		local ok, err = pcall(ml.give_tool, TOOL)
		if not ok then print("could not hand out Fold: " .. tostring(err)) end
	end)
end

print("Fold is in the item pool" .. (TRY_KEY and (" (press " .. TRY_KEY:upper() .. " in a level to get one at once)") or ""))
