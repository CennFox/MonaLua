-- diag.lua -- first-run diagnostics.  It only reads the game and writes to mods/mosalua.log.
-- Play one level for half a minute, fire a tool or two, quit, and look at (or send) the log.
-- Delete this file once things work.
local shots = 0

print(#mosa.classes() .. " game classes, " .. #mosa.find("") .. " hookable functions, "
	.. #mosa.natives() .. " native functions (" .. #mosa.natives("fish@") .. " of the physics library), "
	.. #ml.spawnable() .. " spawnable object types")

local frames = 0
local key_seen                     -- first key the engine's keyboard class reported
mosa.on("tick", function(dt)
	frames = frames + 1
	if frames == 1 then print("first frame reached: the per-frame tick works (dt = " .. tostring(dt) .. ")") end
	-- ml.key_down and friends read hxd.Key: watch for the first key it reports
	if not key_seen and frames % 4 == 0 then
		for name, code in pairs(ml.keys) do
			if code > 2 and ml.key_down(code) then
				key_seen = name
				print("keyboard: hxd.Key reports keys (first one seen: '" .. name .. "'), so ml.key_down / ml.on_key work")
				break
			end
		end
	end
end)

-- each probe runs on its own so one failure does not hide the others
local function probe(what, fn)
	local ok, res = pcall(fn)
	if ok then print("  " .. what .. ": " .. tostring(res)) else print("  " .. what .. ": FAILED: " .. tostring(res)) end
end

local function describe()
	if not ml.ready() then
		print("no gameplay layout yet (menus?)  main = " .. tostring(ml.main) .. "  game = " .. tostring(ml.game))
		return
	end
	print("layout '" .. tostring(ml.layout.name) .. "'  size " .. tostring(ml.layout.width) .. "x" .. tostring(ml.layout.height)
		.. "  frame " .. ml.tick() .. "  time scale " .. tostring(ml.time_scale()))
	local p = ml.player()
	if not p then print("  no player instance") return end
	local x, y = ml.pos(p)
	print(string.format("  player at (%.1f, %.1f)  item_selected = %s", x, y, tostring(p.item_selected)))
	probe("crosshair", function() local ax, ay = ml.aim_point(p); return tostring(ax) .. ", " .. tostring(ay) end)
	probe("tools carried", function()
		local parts = {}
		for _, t in ipairs(ml.tools()) do parts[#parts + 1] = string.format("%s (ammo %s, slot %s)", t.name, tostring(t.ammo), tostring(t.slot)) end
		return #parts > 0 and table.concat(parts, ", ") or "none"
	end)
	probe("tool in hand", function() return (ml.tool(p)) end)
	probe("item pool", function()
		local pool, added = ml.pool(), {}
		for _, t in ipairs(pool) do
			if t.added then
				local pic, text = "picture ?", "name ?"
				pcall(function() pic = mosa.class("fish.game.oclass.OClass_item_icon")._animData:exists(t.name) == true and "has a picture" or "NO PICTURE" end)
				pcall(function() text = "shown as '" .. tostring(mosa.class("fish.system.Main").localisation:loc("TOOL_" .. t.name:upper(), {})) .. "'" end)
				added[#added + 1] = string.format("%s (%s, ammo %d, %s, %s)", t.name, t.aim, t.ammo, pic, text)
			end
		end
		return #pool .. " tools" .. (#added > 0 and ("; added by mods: " .. table.concat(added, ", ")) or "; none added by mods")
	end)
	probe("object types on screen", function()
		local types = ml.types()
		return #types .. ", e.g. " .. table.concat(types, " ", 1, math.min(#types, 25))
	end)
end

-- the physics library, read-only: every line checks one assumption about fish.hdll
local function physics_report()
	if not ml.ready() then return end
	print("physics of '" .. tostring(ml.layout.name) .. "':")
	probe("world / metres per pixel / gravity", function()
		local gx, gy = b2.gravity()
		return tostring(b2.world()) .. " / " .. tostring(b2.scale()) .. " / " .. gx .. ", " .. gy
	end)
	probe("bodies in the world", function()
		local n, kinds = 0, { static = 0, kinematic = 0, dynamic = 0 }
		for _, b in ipairs(b2.bodies()) do n = n + 1; local t = b2.type(b); kinds[t] = (kinds[t] or 0) + 1 end
		return n .. " (" .. kinds.static .. " static, " .. kinds.kinematic .. " kinematic, " .. kinds.dynamic .. " dynamic)"
	end)
	probe("joints / contacts", function() return #b2.joints() .. " / " .. #b2.contacts() end)
	probe("what can move (dynamic bodies by type)", function()
		local count, names = {}, {}
		for _, inst in ipairs(ml.all()) do
			if inst.physics ~= nil and b2.body(inst) ~= nil and b2.type(inst) == "dynamic" then
				local t = tostring(inst.type)
				if not count[t] then count[t] = 0; names[#names + 1] = t end
				count[t] = count[t] + 1
			end
		end
		table.sort(names)
		for i, t in ipairs(names) do names[i] = t .. " x" .. count[t] end
		return #names > 0 and table.concat(names, ", ", 1, math.min(#names, 30)) or "nothing"
	end)
	local p = ml.player()
	if not p then return end
	probe("player body vs sprite position", function()
		local sx, sy = ml.pos(p)
		local bx, by = b2.position(p)
		return string.format("sprite (%.2f, %.2f)  body (%.2f, %.2f)%s", sx, sy, bx, by,
			(math.abs(sx - bx) < 1 and math.abs(sy - by) < 1) and "  -> they agree" or "  -> THEY DIFFER")
	end)
	probe("player body", function()
		local vx, vy = b2.velocity(p)
		return string.format("%s, mass %.3f, velocity (%.1f, %.1f), angle %.1f, fixed rotation %s, gravity scale %s",
			b2.type(p), b2.mass(p), vx, vy, b2.angle(p), tostring(b2.fixed_rotation(p)), tostring(b2.gravity_scale(p)))
	end)
	-- the game zeroes Box2D's gravity and pulls each object with a force from its own variables
	probe("gravity as the game applies it to the player", function()
		local w, m = ml.weight(p), b2.mass(p)
		return string.format("personal_gravity %s, flipModifier %s, low_grav objects %d -> force %.4f = %.1f m/s^2 on its mass",
			tostring(p.personal_gravity), tostring(p.flipModifier), ml.count("low_grav"), w, m > 0 and w / m or 0)
	end)
	probe("player fixtures", function()
		local parts = {}
		for _, f in ipairs(b2.fixtures(p)) do
			local s = b2.shape(f)
			parts[#parts + 1] = (s.type == "circle" and string.format("circle r=%.1f", s.radius)
					or s.type == "polygon" and ("polygon of " .. (#s.points // 2) .. " corners") or s.type)
				.. string.format(" density %.2f friction %.2f%s", b2.density(f), b2.friction(f), b2.is_sensor(f) and " sensor" or "")
				.. " owner " .. tostring(b2.owner(f) == p and "= player" or b2.owner(f))
		end
		return table.concat(parts, "; ")
	end)
	probe("player bounding box", function() return string.format("%.1f, %.1f .. %.1f, %.1f", b2.aabb(p)) end)
	probe("ray straight down from the player", function()
		local x, y = ml.pos(p)
		local hit = b2.raycast(x, y, x, y + 400, function(inst) return inst ~= p end)
		if not hit then return "nothing within 400 px" end
		return string.format("%s at (%.1f, %.1f), %.1f px away, normal (%.2f, %.2f)",
			tostring(hit.inst and hit.inst.type), hit.x, hit.y, hit.distance, hit.nx, hit.ny)
	end)
	probe("objects within 100 px of the player", function()
		local x, y = ml.pos(p)
		local names = {}
		for _, inst in ipairs(b2.instances_in(x - 100, y - 100, x + 100, y + 100)) do names[#names + 1] = tostring(inst.type) end
		return #names .. ": " .. table.concat(names, " ", 1, math.min(#names, 20))
	end)
	-- the Box2D layer also uses natives the game's own code never calls: check each one
	probe("natives the game never calls", function()
		local raw, body, out = b2.raw, b2.body(p), {}
		local function try(name, fn)
			local ok, res = pcall(fn)
			out[#out + 1] = name .. (ok and "=" .. tostring(res) or " FAILED(" .. tostring(res) .. ")")
		end
		try("inertia", function() return string.format("%.4f", b2.inertia(p)) end)
		try("damping", function() return table.concat({ b2.damping(p) }, "/") end)
		try("awake", function() return b2.awake(p) end)
		try("bullet", function() return b2.bullet(p) end)
		try("world_point", function() local x, y = b2.world_point(p, 0, 0); local bx, by = b2.position(p); return math.abs(x - bx) < 0.01 and math.abs(y - by) < 0.01 and "ok" or "WRONG" end)
		try("world_vector", function() return string.format("%.2f,%.2f", b2.world_vector(p, 1, 0)) end)
		try("velocity_at", function() local x, y = b2.position(p); return string.format("%.1f,%.1f", b2.velocity_at(p, x, y)) end)
		try("mass_data", function() local md = mosa.new("hlfish.box2d.B2MassData"); raw.body_get_mass_data(body, md); return string.format("%.3f", md.mass) end)
		try("fixture_get_body", function() return raw.fixture_get_body(b2.fixtures(p)[1]) == body and "ok" or "WRONG" end)
		try("friction/restitution", function() return b2.friction(p) .. "/" .. b2.restitution(p) end)
		try("is_sensor", function() return b2.is_sensor(p) end)
		try("query", function() local x, y = b2.position(p); return #b2.query(x - 5, y - 5, x + 5, y + 5) end)
		try("contact list", function() return #b2.contacts(p) end)
		try("joint list", function() return #b2.joints() end)
		return table.concat(out, "  ")
	end)
	probe("player is touching", function()
		local names = {}
		for _, inst in ipairs(ml.touching(p)) do names[#names + 1] = tostring(inst.type) end
		return #names > 0 and table.concat(names, " ") or "nothing"
	end)
end

-- contact events for the first seconds of each level
local contacts = { begin = 0, ended = 0, pre = 0, post = 0, pairs = {} }
b2.on_begin_contact(function(contact, a, b)
	contacts.begin = contacts.begin + 1
	local key = tostring(a and a.type) .. "+" .. tostring(b and b.type)
	contacts.pairs[key] = (contacts.pairs[key] or 0) + 1
end)
b2.on_end_contact(function() contacts.ended = contacts.ended + 1 end)
local pre = b2.on_pre_solve(function() contacts.pre = contacts.pre + 1 end)
local post = b2.on_post_solve(function() contacts.post = contacts.post + 1 end)
local steps = 0
mosa.after("fish@world_step", function() steps = steps + 1 end)

-- one report when a level starts (only for the level that is still running), then one every 10 seconds
local run = 0
ml.on_level(function(layout)
	if ml.replaying() then
		-- the game is playing the level again to save a GIF; mods take part, this report does not
		print("GIF replay of " .. tostring(layout.name) .. " started")
		return
	end
	print("level layout started: " .. tostring(layout.name))
	run = run + 1
	local mine = run
	mosa.delay(1, function() if mine == run then describe() end end)
	mosa.delay(2, function() if mine == run then physics_report() end end)
	mosa.delay(3, function()
		if mine ~= run then return end
		local parts = {}
		for k, n in pairs(contacts.pairs) do parts[#parts + 1] = k .. " x" .. n end
		table.sort(parts)
		print(string.format("contact callbacks so far: %d begin, %d end, %d pre-solve, %d post-solve in %d physics steps",
			contacts.begin, contacts.ended, contacts.pre, contacts.post, steps))
		print("  pairs that touched: " .. table.concat(parts, ", ", 1, math.min(#parts, 30)))
		pre.remove(); post.remove()          -- these two run for every contact every step: stop listening
	end)
end)
mosa.every(10, function()
	describe()
	if not key_seen and frames > 600 then print("keyboard: no key seen through hxd.Key so far (press any letter while in a level)") end
end)

ml.on_fire("*", function(ctx)
	shots = shots + 1
	local ax, ay = ctx.aim()
	print(string.format("shot %d: tool '%s' fired by the player at (%.1f, %.1f), crosshair (%s, %s), ammo left %s",
		shots, tostring(ctx.tool), ctx.x, ctx.y, tostring(ax), tostring(ay), tostring(ctx.item.ammo)))
end)
ml.on_explosion(function(x, y, radius, power) print(string.format("explosion at (%.1f, %.1f) radius %.1f power %s", x, y, radius, tostring(power))) end)
ml.on_player_death(function(pid) print("player_death(" .. tostring(pid) .. ")") end)
ml.on_tool_select(function(player, item)
	local ok, name = pcall(function() return item.item.type.name end)
	print("tool selected: " .. tostring(ok and name or "?"))
end)
