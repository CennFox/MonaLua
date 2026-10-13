-- trip.lua -- the rotating background, replaced by something to stare into.
--
-- The game's turning background picture is hidden, and in its place a tunnel is drawn every
-- frame: rings of wobbling flower shapes that fall towards you without end, each turned a
-- little further than the one before, in colours that run round the rainbow, about a centre
-- that drifts.  F4 switches between this and the game's own background.
--
-- (It is drawn geometry, a few thousand corners a frame, not a GPU shader: a mod cannot
-- compile new shaders into the game.)

local RINGS   = 22        -- how many rings deep the tunnel is
local CORNERS = 44        -- corners per ring: more is rounder and costs more
local SPEED   = 0.55      -- how fast the rings come at you
local TWIST   = 0.33      -- how much further each ring is turned than the last
local PETALS  = 6         -- lobes of the flower shape
local WOBBLE  = 0.22      -- how deep the lobes are (0 = plain circles)
local COLOURS = 0.45      -- how fast the colours run
local BRIGHT  = 0.85      -- 0 dark .. 1 full
local TOGGLE  = "f4"
local HIDE    = { "rotating_bg", "rotating_bg2", "rotating_bg3" }   -- the game's background objects

local sin, cos, pi, floor = math.sin, math.cos, math.pi, math.floor
local on = true

local function hsv(h, s, v)
	h = (h % 1) * 6
	local i = floor(h)
	local f = h - i
	local p, q, t = v * (1 - s), v * (1 - s * f), v * (1 - s * (1 - f))
	local r, g, b
	if i == 0 then r, g, b = v, t, p elseif i == 1 then r, g, b = q, v, p elseif i == 2 then r, g, b = p, v, t
	elseif i == 3 then r, g, b = p, q, v elseif i == 4 then r, g, b = t, p, v else r, g, b = v, p, q end
	return (floor(r * 255) << 16) | (floor(g * 255) << 8) | floor(b * 255)
end

-- the game's background objects of this level, and the layer they are drawn in
local function backgrounds()
	local list, layer = {}, nil
	for _, name in ipairs(HIDE) do
		for _, inst in ipairs(ml.instances(name)) do
			list[#list + 1] = inst
			local l = inst.sprite.layer
			if layer == nil or l < layer then layer = l end
		end
	end
	return list, layer
end

local function show_game_background(v, yes)
	for _, inst in ipairs(v.bgs) do
		pcall(function() if inst.sprite.destroyed == false then inst.sprite:setVisible(yes and 1 or 0) end end)
	end
end

local function setup(v)
	v.frame = 0
	local ok, err = pcall(function()
		local bgs, layer = backgrounds()
		v.bgs = bgs
		if layer == nil then
			-- no background object here: under everything of the lowest layer in use
			for _, inst in ipairs(ml.all()) do
				local l = inst.sprite.layer
				if layer == nil or l < layer then layer = l end
			end
		end
		local g = mosa.new("h2d.Graphics")
		ml.layout.scene:add(g, layer or 0, 0)
		v.gfx = g
		print(string.format("drawing in layer %s; %d background objects of the game hidden", tostring(layer), #bgs))
	end)
	if not ok then
		v.gfx, v.bgs = false, {}
		print("cannot draw into the level: " .. tostring(err))
	end
end

local ring = {}              -- the unit shape of a ring is the same for all: worked out once per frame

local function paint(v, t)
	local g, l = v.gfx, ml.layout
	local w, h = l.width, l.height
	local cx = w / 2 + sin(t * 0.37) * w * 0.12
	local cy = h / 2 + cos(t * 0.29) * h * 0.14
	local reach = math.sqrt(w * w + h * h) * 0.75          -- the outermost ring covers the screen
	local shrink = 0.80                                    -- each ring is this much smaller than the one outside it
	local phase = (t * SPEED) % 1
	-- the flower shape, breathing
	local lobes = WOBBLE * (0.6 + 0.4 * sin(t * 0.9))
	for k = 0, CORNERS - 1 do
		local a = k / CORNERS * 2 * pi
		local r = 1 + lobes * sin(a * PETALS + t * 1.7)
		ring[k * 2 + 1], ring[k * 2 + 2] = cos(a) * r, sin(a) * r
	end
	g:clear()
	for i = 0, RINGS - 1 do
		-- rings grow as they come nearer; a new one is born in the middle as the outermost leaves
		local depth = i - phase
		local radius = reach * 1.6 * shrink ^ depth
		local turn = depth * TWIST + t * 0.25 + sin(t * 0.5 + depth * 0.3) * 0.4
		local ca, sa = cos(turn) * radius, sin(turn) * radius
		local band = floor(i - t * SPEED)                  -- stays with the ring as it travels
		local shade = BRIGHT * (0.55 + 0.45 * sin(depth * 0.9 + t * 2.1))
		g:beginFill(hsv(band * 0.071 + t * COLOURS * 0.1, 0.85, band % 2 == 0 and shade or shade * 0.45), 1)
		g:moveTo(cx + ring[1] * ca - ring[2] * sa, cy + ring[1] * sa + ring[2] * ca)
		for k = 1, CORNERS - 1 do
			local x, y = ring[k * 2 + 1], ring[k * 2 + 2]
			g:lineTo(cx + x * ca - y * sa, cy + x * sa + y * ca)
		end
		g:lineTo(cx + ring[1] * ca - ring[2] * sa, cy + ring[1] * sa + ring[2] * ca)
		g:endFill()
	end
end

ml.on_update(function()
	if not ml.gameplay() then return end
	local v = ml.vars()
	if v.gfx == nil then setup(v) end
	if not v.gfx then return end
	v.frame = v.frame + 1
	if on ~= v.on then
		v.on = on
		show_game_background(v, not on)
		if not on then pcall(function() v.gfx:clear() end) end
	end
	if not on then return end
	-- background objects that turn up later, and ones the game made visible again
	if v.frame % 30 == 0 then
		local bgs = backgrounds()
		v.bgs = bgs
		show_game_background(v, false)
	end
	local ok, err = pcall(paint, v, ml.time())
	if not ok and not v.complained then v.complained = true; print("drawing failed: " .. tostring(err)) end
end)

if TOGGLE then
	ml.on_key(TOGGLE, function()
		on = not on
		print("trip " .. (on and "on" or "off"))
	end)
end

print("the background is a tunnel now" .. (TOGGLE and (" (" .. TOGGLE:upper() .. " switches it)") or ""))
