-- destruction.lua -- explosions eat the level, a pixel at a time.
--
-- Every explosion (bombs, turret shots, anything that goes through the game's explosion code)
-- bites a round hole out of the tiles it reaches.  A tile that is hit is rebuilt from small
-- tiles: what is left of it keeps its place and stays solid, and the part inside the blast
-- crumbles into pixels that fly off and fall.
--
-- The game draws a small tile at full size whatever size it is given, so this mod draws
-- itself: the solid pieces are invisible tiles (their collision box does follow the size)
-- with a drawn rectangle on top, and the rubble is drawn pixels that are not objects at all.

local PIXEL      = 2       -- size of one pixel of rubble, and how fine a tile is cut (game pixels)
local CRATER     = 0.6     -- size of the hole: this times the explosion's own radius
local KICK       = 180     -- how fast the rubble is thrown outwards (pixels per second)
local PIXEL_LIFE = 4       -- seconds until a loose pixel disappears; 0 = they stay
local MAX_PIXELS = 400     -- loose pixels allowed at once; the oldest go first
local PER_BLAST  = 160     -- loose pixels one tile may shed in one blast (the rest of its crater just vanishes)
local TEST_KEY   = "v"     -- sets off an explosion at the cursor, for trying things out; nil switches that off
local TEST_SIZE  = 45      -- the radius of that explosion
local GRAVITY    = 420     -- how fast the rubble falls (pixels per second, per second)
local COLOR      = 0xE8E4DA   -- the colour used when a tile's own colour cannot be found out, 0xRRGGBB
local PIECE      = "tile_tiny"   -- the game's plain square tile: every solid piece is one of these (made invisible)

if not ml.give_tool then
	print("this mod needs the Lua kit 1.4.0 or later: unzip the new files into the game folder first")
	return
end

local floor, sqrt, cos, sin, rad, max = math.floor, math.sqrt, math.cos, math.sin, math.rad, math.max

local function state()
	local v = ml.vars()
	if v.rubble == nil then v.rubble, v.pieces, v.hidden, v.dirty, v.frame, v.colour = {}, {}, {}, false, 0, {} end
	return v
end

---------------------------------------------------------------- a tile's shape, as a grid

-- the collision shape in the tile's own frame: a list of convex polygons, or nil for a plain box
local function polygons(inst)
	local ok, list = pcall(function()
		local out = {}
		for _, f in ipairs(b2.fixtures(inst)) do
			local s = b2.shape(f)
			if s.type ~= "polygon" then return nil end
			out[#out + 1] = s.points
		end
		return out
	end)
	if not ok or list == nil or #list == 0 then return nil end
	return list
end

local function inside(polys, x, y)
	for p = 1, #polys do
		local pts = polys[p]
		local n, sign, hit = #pts, 0, true
		for i = 1, n, 2 do
			local x1, y1 = pts[i], pts[i + 1]
			local k = i + 2 <= n and i + 2 or 1
			local cross = (pts[k] - x1) * (y - y1) - (pts[k + 1] - y1) * (x - x1)
			if cross ~= 0 then
				local s = cross > 0 and 1 or -1
				if sign == 0 then sign = s elseif s ~= sign then hit = false; break end
			end
		end
		if hit then return true end
	end
	return false
end

-- the fewest-ish rectangles that cover the cells marked true (rows of equal runs are joined)
local function rectangles(keep, nx, ny)
	local out = {}
	for j = 1, ny do
		local row = keep[j]
		local i = 1
		while i <= nx do
			if row[i] then
				local i2 = i
				while i2 < nx and row[i2 + 1] do i2 = i2 + 1 end
				local j2 = j
				while j2 < ny do
					local below, all = keep[j2 + 1], true
					for k = i, i2 do if not below[k] then all = false; break end end
					if not all then break end
					j2 = j2 + 1
				end
				for jj = j, j2 do for k = i, i2 do keep[jj][k] = false end end
				out[#out + 1] = { i, j, i2, j2 }
				i = i2 + 1
			else
				i = i + 1
			end
		end
	end
	return out
end

---------------------------------------------------------------- pieces and pixels

-- everything this mod shows is drawn into two layers of the level's scene
local function layers(v, layer)
	if v.gfx_pieces == nil then
		local ok, err = pcall(function()
			local a, b = mosa.new("h2d.Graphics"), mosa.new("h2d.Graphics")
			ml.layout.scene:add(a, layer, nil)
			ml.layout.scene:add(b, layer, nil)
			v.gfx_pieces, v.gfx_rubble = a, b
		end)
		if not ok then
			v.gfx_pieces = false
			print("cannot draw into the level: " .. tostring(err))
		end
	end
	return v.gfx_pieces
end

---------------------------------------------------------------- a tile's colour

-- The game colours a tile in two steps: the picture it is drawn from, and a shift of hue,
-- saturation and luminance on top (its "adjusthsl").  So: read one pixel from the middle of
-- the tile's picture (the image is fetched from the graphics card once and kept), then apply
-- the same shift.
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
		if not ok then print("could not read the tile image: " .. tostring(got)) end
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

-- the colour a tile is seen in, as 0xRRGGBB (pieces we made remember theirs)
local function colour_of(v, inst)
	local known = v.colour[inst.uid]
	if known then return known end
	local c = COLOR
	local ok, err = pcall(function()
		local r, g, b, a = base_colour(inst)
		if r == nil then return end
		local hsl = inst.adjusthsl
		local hue, sat, lum = 0, 1, 1
		if hsl ~= nil then hue, sat, lum = hsl:get_hue(), hsl:get_saturation(), hsl:get_luminance() end
		c = shift(r, g, b, hue, sat, lum)
		if not shade_told then
			shade_told = true
			print(string.format("colour of a %s: picture pixel %d,%d,%d (alpha %d), hue %.3f sat %.3f lum %.3f -> %06X", tostring(inst.type), r, g, b, a, hue, sat, lum, c))
		end
	end)
	if not ok and not shade_told then shade_told = true; print("could not work out a tile's colour (using COLOR): " .. tostring(err)) end
	return c
end

local told = false
local function describe(from, o, w, h)
	if told then return end
	told = true
	local function try(f) local ok, r = pcall(f); return ok and tostring(r) or "?" end
	local sp = from.sprite
	print(string.format("first tile cut (%s): batched %s, tiled %s, visible %s, anim %s, tint %s, hue/sat/lum %s, r/g/b %s; first piece %.1f x %.1f, the game says %.1f x %.1f, visible %s",
		tostring(from.type), try(function() return sp.isBatched end), try(function() return sp.isTiledBg end), try(function() return sp.visible end),
		try(function() return sp.anim end),
		try(function() local c = sp.color; return string.format("%.2f,%.2f,%.2f,%.2f", c.x, c.y, c.z, c.w) end),
		try(function() local a = from.adjusthsl; return string.format("%.2f,%.2f,%.2f", a:get_hue(), a:get_saturation(), a:get_luminance()) end),
		try(function() return string.format("%s,%s,%s", from.r, from.g, from.b) end),
		w, h, o.sprite.width, o.sprite.height, try(function() return o.sprite.visible end)))
end

-- a solid piece: a tile of the game for the collision, hidden, and a rectangle of ours to see
local function piece(v, from, x, y, w, h, angle, static)
	local function shape(o)
		o.sprite:setSize(w, h)
		o.sprite:setAngle(angle)
	end
	local o = ml.spawn(PIECE, x, y, { layer = from.sprite.layer, init = shape })
	if o == nil then return nil end
	shape(o)
	pcall(function() o.physics:syncPosWithSprite() end)
	pcall(function() o.sprite:setVisible(0) end)
	pcall(function() o.sprite:setOpacity(0) end)
	if static then ml.freeze(o) else ml.freeze(o, false) end
	local c = colour_of(v, from)
	v.colour[o.uid] = c
	v.pieces[#v.pieces + 1] = { inst = o, w = w, h = h, static = static, c = c }
	v.hidden[o.uid] = 4                              -- frames in which it is hidden again, in case the game shows it
	v.dirty = true
	describe(from, o, w, h)
	return o
end

---------------------------------------------------------------- the bite

local function from_layer(v, inst)
	local l = inst.sprite.layer
	if v.layer == nil or l > v.layer then v.layer = l end
	return v.layer
end

-- returns pieces made, pixels made (nil when the tile was not touched)
local function carve(v, inst, bx, by, r)
	local w, h = ml.size(inst)
	local px, py = ml.pos(inst)
	local deg = ml.angle(inst)
	if px ~= px or py ~= py then return nil end
	local ca, sa = cos(rad(deg)), sin(rad(deg))
	-- the blast centre in the tile's own frame
	local dx, dy = bx - px, by - py
	local cx, cy = dx * ca + dy * sa, -dx * sa + dy * ca
	if math.abs(cx) > w / 2 + r or math.abs(cy) > h / 2 + r then return nil end
	local nx, ny = max(1, floor(w / PIXEL + 0.5)), max(1, floor(h / PIXEL + 0.5))
	if nx * ny > 8000 then return nil end                 -- something huge: leave it
	local cw, ch = w / nx, h / ny
	local polys = polygons(inst)
	if polys and #polys == 1 and #polys[1] == 8 then polys = nil end      -- one four-cornered shape: the box itself
	local keep, gone, hits, solid = {}, {}, 0, 0
	local r2 = r * r
	for j = 1, ny do
		local row = {}
		keep[j] = row
		local ly = -h / 2 + (j - 0.5) * ch
		for i = 1, nx do
			local lx = -w / 2 + (i - 0.5) * cw
			if polys == nil or inside(polys, lx, ly) then
				solid = solid + 1
				local ex, ey = lx - cx, ly - cy
				if ex * ex + ey * ey <= r2 then
					hits = hits + 1
					gone[hits] = { lx, ly, ex, ey }
					row[i] = false
				else
					row[i] = true
				end
			else
				row[i] = false
			end
		end
	end
	if hits == 0 then return nil end
	local static = b2.type(inst) == "static"
	local function world(lx, ly) return px + lx * ca - ly * sa, py + lx * sa + ly * ca end
	layers(v, from_layer(v, inst))
	-- what is left keeps its place
	local rects = rectangles(keep, nx, ny)
	for _, q in ipairs(rects) do
		local rw, rh = (q[3] - q[1] + 1) * cw, (q[4] - q[2] + 1) * ch
		local x, y = world(-w / 2 + (q[1] - 1) * cw + rw / 2, -h / 2 + (q[2] - 1) * ch + rh / 2)
		piece(v, inst, x, y, rw, rh, deg, static)
	end
	-- what was hit becomes rubble, thrown away from the middle of the blast: drawn pixels
	local every = math.ceil(hits / PER_BLAST)
	local rubble, now, made = v.rubble, ml.time(), 0
	local c = colour_of(v, inst)
	for n = 1, hits, every do
		local g = gone[n]
		local x, y = world(g[1], g[2])
		local ex, ey = g[3] * ca - g[4] * sa, g[3] * sa + g[4] * ca
		local d = sqrt(ex * ex + ey * ey)
		if d < 0.001 then ex, ey, d = 0, -1, 1 end
		-- (no random numbers: a GIF replay has to throw every pixel the same way)
		local speed = KICK * (0.35 + ((n * 37) % 23) / 22)
		rubble[#rubble + 1] = { x = x, y = y, vx = ex / d * speed, vy = ey / d * speed - KICK * 0.45, born = now, c = c }
		made = made + 1
	end
	-- the tile itself goes; if it was one of our pieces, so does its rectangle
	ml.destroy(inst)
	v.dirty = true
	return #rects, made
end

local function blast(x, y, r)
	if not ml.gameplay() or r <= 0 then return end
	if not ml.can_spawn(PIECE) then
		print("the game has no '" .. PIECE .. "' object in this version: nothing is cut")
		return
	end
	local v = state()
	local tiles, pixels, pieces = 0, 0, 0
	for _, inst in ipairs(ml.instances("tiles")) do
		if ml.alive(inst) and inst.physics ~= nil then
			local ok, a, b = pcall(carve, v, inst, x, y, r)
			if not ok then
				print("could not cut a " .. tostring(inst.type) .. ": " .. tostring(a))
			elseif a then
				tiles, pieces, pixels = tiles + 1, pieces + a, pixels + b
			end
		end
	end
	if tiles > 0 then
		print(string.format("blast at (%.0f, %.0f) radius %.0f: %d tiles cut into %d pieces and %d pixels of rubble", x, y, r, tiles, pieces, pixels))
	end
end

ml.on_explosion(function(x, y, radius)
	local r = radius * CRATER
	if b2.locked() then
		b2.after_step(function() blast(x, y, r) end)      -- (an explosion from inside the physics step)
	else
		blast(x, y, r)
	end
end)

---------------------------------------------------------------- drawing, every frame

local function draw_pieces(v)
	local g = v.gfx_pieces
	local list, n = v.pieces, 0
	g:clear()
	local cur
	for i = 1, #list do
		local e = list[i]
		local sp = e.inst.sprite
		if sp.destroyed == false then
			if e.c ~= cur then
				if cur then g:endFill() end
				cur = e.c
				g:beginFill(cur, 1)
			end
			n = n + 1
			list[n] = e
			local p = sp.position
			local x, y, deg = p.x, p.y, sp.angle
			local hw, hh = e.w / 2, e.h / 2
			if deg == 0 then
				g:drawRect(x - hw, y - hh, e.w, e.h)
			else
				local ca, sa = cos(rad(deg)), sin(rad(deg))
				g:moveTo(x - hw * ca + hh * sa, y - hw * sa - hh * ca)
				g:lineTo(x + hw * ca + hh * sa, y + hw * sa - hh * ca)
				g:lineTo(x + hw * ca - hh * sa, y + hw * sa + hh * ca)
				g:lineTo(x - hw * ca - hh * sa, y - hw * sa + hh * ca)
				g:lineTo(x - hw * ca + hh * sa, y - hw * sa - hh * ca)
			end
			local left = v.hidden[e.inst.uid]
			if left then
				pcall(function() sp:setVisible(0) end)
				v.hidden[e.inst.uid] = left > 1 and left - 1 or nil
			end
		end
	end
	for i = #list, n + 1, -1 do list[i] = nil end
	if cur then g:endFill() end
end

ml.on_update(function(dt)
	local v = ml.vars()
	if v.rubble == nil or not v.gfx_pieces then return end
	v.frame = v.frame + 1
	-- the solid pieces: when something changed, and now and then in case something moved them
	if v.dirty or v.frame % 20 == 0 or next(v.hidden) ~= nil then
		v.dirty = false
		local ok, err = pcall(draw_pieces, v)
		if not ok and not v.complained then v.complained = true; print("drawing the pieces failed: " .. tostring(err)) end
	end
	-- the rubble: thrown, falling, gone after a while
	local list = v.rubble
	if #list == 0 then
		if v.rubble_drawn then v.rubble_drawn = false; pcall(function() v.gfx_rubble:clear() end) end
		return
	end
	local now, n, over = ml.time(), 0, #list - MAX_PIXELS
	local g, half, floor_y = v.gfx_rubble, PIXEL / 2, ml.layout.height + 20
	local ok, err = pcall(function()
		g:clear()
		local cur
		for i = 1, #list do
			local e = list[i]
			if i > over and now - e.born < PIXEL_LIFE and e.y < floor_y then
				if e.c ~= cur then
					if cur then g:endFill() end
					cur = e.c
					g:beginFill(cur, 1)
				end
				e.vy = e.vy + GRAVITY * dt
				e.x, e.y = e.x + e.vx * dt, e.y + e.vy * dt
				g:drawRect(e.x - half, e.y - half, PIXEL, PIXEL)
				n = n + 1
				list[n] = e
			end
		end
		if cur then g:endFill() end
	end)
	for i = #list, n + 1, -1 do list[i] = nil end
	v.rubble_drawn = true
	if not ok and not v.complained then v.complained = true; print("drawing the rubble failed: " .. tostring(err)) end
end)

---------------------------------------------------------------- trying it out

if TEST_KEY then
	ml.on_key(TEST_KEY, function()
		if not ml.gameplay() then return end
		local x, y = ml.aim_point()
		if x == nil then return end
		local ok, err = pcall(ml.explode, x, y, TEST_SIZE)
		if not ok then print("could not make the test explosion: " .. tostring(err)) end
	end)
end

print("explosions now break tiles into pixels" .. (TEST_KEY and (" (" .. TEST_KEY:upper() .. " sets one off at the cursor)") or ""))
