-- ink.lua -- a new tool for the item pool: Ink.
--
-- Fire it and the mouse pointer becomes a pen: for the next few seconds everything it passes over is
-- drawn into the level as a solid line.  Sweep it for a bridge, flick it up for a wall, scribble
-- a staircase, catch something in a cup.  What you draw stays, holds your weight and everything
-- else's, and can be blown up, pulled and frozen like any other part of the level.

local INK       = 320       -- how much line one shot draws (game pixels)
local SECONDS   = 6         -- the pen dries after this long, used up or not
local THICK     = 5         -- how thick the line is
local STEP      = 7         -- a new piece is laid whenever the cursor has moved this far
local COLOR     = 0x1B1F3A  -- the colour of the ink, 0xRRGGBB
local MOUSE     = true      -- true: the pen is the mouse pointer; false: the character's aiming cursor
local TRY_KEY   = "u"       -- gives you the tool at once, for trying it out; nil switches that off
local PIECE     = "tile_tiny"   -- the game's plain square tile: every stroke is one of these, hidden and resized

local TOOL = "ink"

if not ml.add_tool then
	print("this mod needs the Lua kit 1.4.0 or later: unzip the new files into the game folder first")
	return
end

ml.add_tool{ name = TOOL, label = "Ink", aim = "long", ammo = 2, icon = "board" }

local sqrt, cos, sin, rad, deg, atan = math.sqrt, math.cos, math.sin, math.rad, math.deg, math.atan

local function state()
	local v = ml.vars()
	if v.strokes == nil then v.strokes, v.hidden, v.frame, v.dirty = {}, {}, 0, false end
	return v
end

local function canvas(v)
	if v.gfx == nil then
		local ok, err = pcall(function()
			local top = 0
			for _, inst in ipairs(ml.instances("physics_obj")) do
				local l = inst.sprite.layer
				if l > top then top = l end
			end
			local a, b = mosa.new("h2d.Graphics"), mosa.new("h2d.Graphics")
			ml.layout.scene:add(a, top, nil)
			ml.layout.scene:add(b, top, nil)
			v.gfx, v.gfx_pen = a, b
		end)
		if not ok then v.gfx = false; print("cannot draw into the level: " .. tostring(err)) end
	end
	return v.gfx
end

-- one piece of line from (x1, y1) to (x2, y2): a hidden tile of the game for the collision
-- (the game draws a resized tile at full size, so the mod draws the line itself)
local function stroke(v, x1, y1, x2, y2)
	local dx, dy = x2 - x1, y2 - y1
	local len = sqrt(dx * dx + dy * dy)
	local angle = deg(atan(dy, dx))
	local w, h = len + THICK, THICK                  -- a little longer, so that pieces overlap at the bends
	local function shape(o)
		o.sprite:setSize(w, h)
		o.sprite:setAngle(angle)
	end
	local o = ml.spawn(PIECE, (x1 + x2) / 2, (y1 + y2) / 2, { layer = v.layer or 0, init = shape })
	if o == nil then return end
	shape(o)
	pcall(function() o.physics:syncPosWithSprite() end)
	pcall(function() o.sprite:setVisible(0) end)
	pcall(function() o.sprite:setOpacity(0) end)
	ml.freeze(o)
	v.strokes[#v.strokes + 1] = { inst = o, w = w, h = h }
	v.hidden[o.uid] = 4
	v.dirty = true
end

local function draw_strokes(v)
	local g, list, n = v.gfx, v.strokes, 0
	g:clear()
	g:beginFill(COLOR, 1)
	for i = 1, #list do
		local e = list[i]
		local sp = e.inst.sprite
		if sp.destroyed == false then
			n = n + 1
			list[n] = e
			local p = sp.position
			local x, y, a = p.x, p.y, rad(sp.angle)
			local ca, sa, hw, hh = cos(a), sin(a), e.w / 2, e.h / 2
			g:moveTo(x - hw * ca + hh * sa, y - hw * sa - hh * ca)
			g:lineTo(x + hw * ca + hh * sa, y + hw * sa - hh * ca)
			g:lineTo(x + hw * ca - hh * sa, y + hw * sa + hh * ca)
			g:lineTo(x - hw * ca - hh * sa, y - hw * sa + hh * ca)
			g:lineTo(x - hw * ca + hh * sa, y - hw * sa - hh * ca)
			local left = v.hidden[e.inst.uid]
			if left then
				pcall(function() sp:setVisible(0) end)
				v.hidden[e.inst.uid] = left > 1 and left - 1 or nil
			end
		end
	end
	for i = #list, n + 1, -1 do list[i] = nil end
	g:endFill()
end

-- Where the pen is.  The mouse is read from the engine and turned into level coordinates.  A
-- GIF replay has no mouse to read, so the pen's way is written down frame by frame while the
-- level is played and read back when the game plays it again.
local tape = {}
ml.on_level(function() if not ml.replaying() then tape = {} end end)

local function mouse()
	local scene = ml.layout.scene
	local root = scene:getScene()
	if root == nil then return nil end
	local pt = mosa.new("h2d.col.PointImpl", root:get_mouseX(), root:get_mouseY())
	scene:globalToLocal(pt)
	return pt.x, pt.y
end

local mouse_told = false
local function pen_at(player)
	local tick = ml.tick()
	if ml.replaying() then
		local p = tape[tick]
		if p then return p[1], p[2] end
		return nil
	end
	local x, y
	if MOUSE then
		local ok, a, b = pcall(mouse)
		if ok and a ~= nil then x, y = a, b
		elseif not mouse_told then mouse_told = true; print("cannot read the mouse (using the aiming cursor): " .. tostring(a)) end
	end
	if x == nil then x, y = ml.aim_point(player) end
	if x ~= nil then tape[tick] = { x, y } end
	return x, y
end

ml.on_fire(TOOL, function(ctx)
	local v = state()
	local x, y = pen_at(ctx.player)
	if x == nil then return end
	if not canvas(v) then return end
	pcall(function() v.layer = ctx.player.sprite.layer end)
	v.pen = { x = x, y = y, left = INK, ends = ml.time() + SECONDS, player = ctx.player }
	print(string.format("pen down at (%.0f, %.0f)", x, y))
end)

ml.on_update(function()
	if not ml.gameplay() then return end
	local v = ml.vars()
	if v.strokes == nil or not v.gfx then return end
	v.frame = v.frame + 1
	local pen = v.pen
	if pen then
		local x, y = pen_at(pen.player)
		if x == nil or ml.time() >= pen.ends or pen.left <= 0 or not ml.alive(pen.player) then
			print(string.format("pen up: %.0f of %d pixels of ink used, %d strokes in the level", INK - pen.left, INK, #v.strokes))
			v.pen = nil
			pcall(function() v.gfx_pen:clear() end)
		else
			local dx, dy = x - pen.x, y - pen.y
			local d = sqrt(dx * dx + dy * dy)
			if d >= STEP then
				-- a jump of the cursor is drawn as a straight line, as far as the ink goes
				local use = math.min(d, pen.left)
				local ex, ey = pen.x + dx / d * use, pen.y + dy / d * use
				local parts = math.ceil(use / 40)             -- long jumps in pieces of at most 40
				for i = 1, parts do
					local a, b = (i - 1) / parts, i / parts
					local ok, err = pcall(stroke, v, pen.x + (ex - pen.x) * a, pen.y + (ey - pen.y) * a, pen.x + (ex - pen.x) * b, pen.y + (ey - pen.y) * b)
					if not ok and not v.complained then v.complained = true; print("could not draw a stroke: " .. tostring(err)) end
				end
				pen.x, pen.y, pen.left = ex, ey, pen.left - use
			end
			-- the tip of the pen, and a ring that shrinks as the ink runs out
			pcall(function()
				local g = v.gfx_pen
				g:clear()
				g:beginFill(COLOR, 0.35)
				g:drawCircle(x, y, 3 + 9 * pen.left / INK, 20)
				g:endFill()
				g:beginFill(COLOR, 1)
				g:drawCircle(x, y, THICK / 2 + 0.5, 12)
				g:endFill()
			end)
		end
	end
	if v.dirty or v.frame % 20 == 0 or next(v.hidden) ~= nil then
		v.dirty = false
		local ok, err = pcall(draw_strokes, v)
		if not ok and not v.complained then v.complained = true; print("drawing failed: " .. tostring(err)) end
	end
end)

if TRY_KEY then
	ml.on_key(TRY_KEY, function()
		if not ml.gameplay() or ml.player() == nil then return end
		local ok, err = pcall(ml.give_tool, TOOL)
		if not ok then print("could not hand out Ink: " .. tostring(err)) end
	end)
end

print("Ink is in the item pool" .. (TRY_KEY and (" (press " .. TRY_KEY:upper() .. " in a level to get one at once)") or ""))
