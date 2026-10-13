-- extrude3d.lua -- the level in 3D: every solid thing gets depth.
--
-- The game stays what it is, a flat picture, and that picture becomes the front face of a
-- solid world: behind every tile, every object and the player, walls run back into the screen
-- towards a vanishing point, shaded by the side they face.  The walls are worked out from the
-- real collision shapes, so they follow whatever moves, turns, breaks or is blown up.
--
-- This is an extrusion drawn behind the game's own pictures, not a 3D engine: the camera
-- cannot turn, and nothing is replaced by a model.

local DEPTH    = 0.16      -- how deep things are: 0.16 = the back is 16 % of the way to the vanishing point
local SHADE    = 0.55      -- how dark the darkest wall is (1 = as bright as the front)
local FOLLOW   = 0.25      -- the vanishing point leans this much towards the player (0 = fixed in the middle)
local TOGGLE   = "f3"      -- switches the effect on and off; nil = always on
local COLOR    = 0x9A9AA8  -- wall colour for things whose own colour cannot be found out
local ROUND    = 14        -- corners used for a round shape

local floor, sqrt, cos, sin, rad, pi = math.floor, math.sqrt, math.cos, math.sin, math.rad, math.pi
local on = true

---------------------------------------------------------------- colours (as in destruction.lua)

local images = {}            -- texture -> its pixels (false when they could not be read)
local shade_told = false

local function base_colour(inst)
	local tile = inst.sprite:getCurrentFrame():getTile()
	local tex = tile:getTexture()
	local key = tostring(tex)
	local px = images[key]
	if px == nil then
		local ok, got = pcall(function() return tex:capturePixels(0, 0, nil) end)
		px = ok and got or false
		images[key] = px
		if not ok then print("could not read an image: " .. tostring(got)) end
	end
	if not px then return nil end
	local x, y = floor(tile.x + tile.width / 2), floor(tile.y + tile.height / 2)
	local c = px:getPixel(x, y)
	return (c >> 16) & 255, (c >> 8) & 255, c & 255, (c >> 24) & 255
end

local function shift(r, g, b, hue, sat, lum)
	r, g, b = r / 255, g / 255, b / 255
	local hi, lo = math.max(r, g, b), math.min(r, g, b)
	local h, sv, l = 0, 0, (hi + lo) / 2
	if hi ~= lo then
		local d = hi - lo
		sv = l > 0.5 and d / (2 - hi - lo) or d / (hi + lo)
		if hi == r then h = (g - b) / d + (g < b and 6 or 0) elseif hi == g then h = (b - r) / d + 2 else h = (r - g) / d + 4 end
		h = h / 6
	end
	h = (h + hue) % 1
	sv = math.min(1, math.max(0, sv * sat))
	l = math.min(1, math.max(0, l * lum))
	local function ch(p, q, t)
		t = t % 1
		if t < 1 / 6 then return p + (q - p) * 6 * t end
		if t < 1 / 2 then return q end
		if t < 2 / 3 then return p + (q - p) * (2 / 3 - t) * 6 end
		return p
	end
	if sv == 0 then r, g, b = l, l, l else
		local q = l < 0.5 and l * (1 + sv) or l + sv - l * sv
		local p = 2 * l - q
		r, g, b = ch(p, q, h + 1 / 3), ch(p, q, h), ch(p, q, h - 1 / 3)
	end
	return (floor(r * 255 + 0.5) << 16) | (floor(g * 255 + 0.5) << 8) | floor(b * 255 + 0.5)
end


local function colour_of(v, inst)
	local uid = inst.uid
	local known = v.colour[uid]
	if known then return known end
	local c = COLOR
	pcall(function()
		local r, g, b, a = base_colour(inst)
		if r == nil or a < 40 then return end
		local hsl = inst.adjusthsl
		local hue, sat, lum = 0, 1, 1
		if hsl ~= nil then hue, sat, lum = hsl:get_hue(), hsl:get_saturation(), hsl:get_luminance() end
		c = shift(r, g, b, hue, sat, lum)
	end)
	v.colour[uid] = c
	return c
end

local function darker(c, f)
	local r, g, b = (c >> 16) & 255, (c >> 8) & 255, c & 255
	return (floor(r * f) << 16) | (floor(g * f) << 8) | floor(b * f)
end

---------------------------------------------------------------- shapes

-- the outline(s) of an object in its own frame, from its collision shapes; kept per object
local function outlines(v, inst)
	local uid = inst.uid
	local w, h = inst.sprite.width, inst.sprite.height
	local e = v.shapes[uid]
	if e and e.w == w and e.h == h then return e.polys end
	local polys = {}
	pcall(function()
		for _, f in ipairs(b2.fixtures(inst)) do
			if not b2.is_sensor(f) then
				local s = b2.shape(f)
				if s.type == "polygon" then
					polys[#polys + 1] = s.points
				elseif s.type == "circle" then
					local pts = {}
					for k = 0, ROUND - 1 do
						local a = k / ROUND * 2 * pi
						pts[#pts + 1] = s.x + cos(a) * s.radius
						pts[#pts + 1] = s.y + sin(a) * s.radius
					end
					polys[#polys + 1] = pts
				end
			end
		end
	end)
	-- make every outline run the same way round, so "outside" is always on the same side
	for _, pts in ipairs(polys) do
		local area, n = 0, #pts
		for i = 1, n, 2 do
			local k = i + 2 <= n and i + 2 or 1
			area = area + pts[i] * pts[k + 1] - pts[k] * pts[i + 1]
		end
		if area < 0 then
			local rev = {}
			for i = n - 1, 1, -2 do rev[#rev + 1] = pts[i]; rev[#rev + 1] = pts[i + 1] end
			for i = 1, n do pts[i] = rev[i] end
		end
	end
	v.shapes[uid] = { w = w, h = h, polys = polys }
	return polys
end

-- the walls of one object: the sides that face the vanishing point, as quads with a shade
local function walls(v, inst, vx, vy, out)
	local sp = inst.sprite
	local p = sp.position
	local px, py, deg = p.x, p.y, sp.angle
	local ca, sa = cos(rad(deg)), sin(rad(deg))
	local polys = outlines(v, inst)
	if #polys == 0 then return end
	local c = colour_of(v, inst)
	local k = 1 - DEPTH
	local dx, dy = px - vx, py - vy
	local far = dx * dx + dy * dy
	for _, pts in ipairs(polys) do
		local n = #pts
		local wx, wy = {}, {}
		for i = 1, n, 2 do
			local lx, ly = pts[i], pts[i + 1]
			wx[#wx + 1] = px + lx * ca - ly * sa
			wy[#wy + 1] = py + lx * sa + ly * ca
		end
		local m = #wx
		for i = 1, m do
			local j = i < m and i + 1 or 1
			local x1, y1, x2, y2 = wx[i], wy[i], wx[j], wy[j]
			local ex, ey = x2 - x1, y2 - y1
			local len = sqrt(ex * ex + ey * ey)
			if len > 0.01 then
				local nx, ny = ey / len, -ex / len                       -- pointing out of the shape
				local mx, my = (x1 + x2) / 2, (y1 + y2) / 2
				if nx * (vx - mx) + ny * (vy - my) > 0 then                -- this side is seen from the middle
					-- light from the upper left: sides facing it are bright
					local lit = (nx * -0.6 + ny * -0.8 + 1) / 2
					out[#out + 1] = { far, darker(c, SHADE + (0.95 - SHADE) * lit),
						x1, y1, x2, y2, vx + (x2 - vx) * k, vy + (y2 - vy) * k, vx + (x1 - vx) * k, vy + (y1 - vy) * k }
				end
			end
		end
	end
end

local function paint(g, quads)
	table.sort(quads, function(a, b) return a[1] > b[1] end)          -- far from the vanishing point first
	g:clear()
	local cur
	for i = 1, #quads do
		local q = quads[i]
		if q[2] ~= cur then
			if cur then g:endFill() end
			cur = q[2]
			g:beginFill(cur, 1)
		end
		g:moveTo(q[3], q[4]); g:lineTo(q[5], q[6]); g:lineTo(q[7], q[8]); g:lineTo(q[9], q[10]); g:lineTo(q[3], q[4])
	end
	if cur then g:endFill() end
end

---------------------------------------------------------------- every frame

local function setup(v)
	v.shapes, v.colour, v.frame = {}, {}, 0
	local ok, err = pcall(function()
		-- under everything else of the lowest layer that holds solid things
		local layer
		for _, inst in ipairs(ml.instances("physics_obj")) do
			local l = inst.sprite.layer
			if layer == nil or l < layer then layer = l end
		end
		local g = mosa.new("h2d.Graphics")
		ml.layout.scene:add(g, layer or 0, 0)
		v.gfx = g
	end)
	if not ok then
		v.gfx = false
		print("cannot draw into the level: " .. tostring(err))
	end
end

ml.on_update(function()
	if not ml.gameplay() then return end
	local v = ml.vars()
	if v.gfx == nil then setup(v) end
	local g = v.gfx
	if not g then return end
	if not on then
		if v.shown then v.shown = false; pcall(function() g:clear() end) end
		return
	end
	local layout = ml.layout
	local vx, vy = layout.width / 2, layout.height / 2
	local p = ml.player()
	if p ~= nil and FOLLOW ~= 0 then
		local x, y = ml.pos(p)
		vx, vy = vx + (x - vx) * FOLLOW, vy + (y - vy) * FOLLOW
	end
	local quads = {}
	for _, inst in ipairs(ml.instances("physics_obj")) do
		if inst.sprite.destroyed == false and inst.physics ~= nil then
			pcall(walls, v, inst, vx, vy, quads)
		end
	end
	local ok, err = pcall(paint, g, quads)
	v.shown = true
	if not ok and not v.complained then v.complained = true; print("drawing failed: " .. tostring(err)) end
	if not v.told then
		v.told = true
		print(string.format("drawing %d walls of %d solid things", #quads, #ml.instances("physics_obj")))
	end
end)

if TOGGLE then
	ml.on_key(TOGGLE, function()
		on = not on
		print("3D " .. (on and "on" or "off"))
	end)
end

print("the level has depth now" .. (TOGGLE and (" (" .. TOGGLE:upper() .. " switches it)") or ""))
