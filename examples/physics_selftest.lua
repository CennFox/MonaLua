-- physics_selftest.lua -- checks the parts of the Box2D layer that CHANGE the world, inside the
-- real game.  Copy into mods\, start a level, wait five seconds, read mods\mosalua.log, delete.
-- Everything it makes is placed far outside the level and removed again.
local function check(what, fn)
	local ok, res = pcall(fn)
	if ok and res ~= false then print("PASS " .. what .. (res ~= nil and res ~= true and (": " .. tostring(res)) or ""))
	else print("FAIL " .. what .. ": " .. tostring(res)) end
	return ok and res ~= false
end

ml.on_level(function()
	ml.after(2, function()
		print("physics self-test in '" .. tostring(ml.layout.name) .. "'")
		local X, Y = -3000, -3000                    -- far away from the level
		local anchor, bob, hinge
		if not check("create a static body", function() anchor = b2.create_body{ type = "static", x = X, y = Y }; return true end) then return end
		check("add a box to it", function() b2.add_box(anchor, 40, 10); return #b2.fixtures(anchor) == 1 end)
		check("create a dynamic body with a circle", function()
			bob = b2.create_body{ x = X + 100, y = Y }
			b2.add_circle(bob, 10, { density = 2 })
			return string.format("mass %.4f (expected %.4f)", b2.mass(bob), 2 * math.pi * (10 * b2.scale()) ^ 2)
		end)
		check("add a triangle to it", function()
			local f = b2.add_polygon(bob, { -10, 5, 10, 5, 0, -15 }, { density = 0 })
			local n = #b2.shape(f).points // 2
			b2.remove_fixture(f)
			return n == 3
		end)
		check("position / velocity round trip", function()
			b2.set_velocity(bob, 30, -40)
			local vx, vy = b2.velocity(bob)
			b2.set_velocity(bob, 0, 0)
			return math.abs(vx - 30) < 1e-6 and math.abs(vy + 40) < 1e-6
		end)
		check("hinge the two together", function() hinge = b2.revolute(anchor, bob, X, Y); return b2.joint_type(hinge) == "revolute" and #b2.joints(bob) == 1 end)
		check("query finds them", function() return #b2.query(X - 50, Y - 50, X + 150, Y + 50) >= 2 end)
		check("ray hits the circle", function()
			local hit = b2.raycast(X + 100, Y - 100, X + 100, Y + 100)
			return hit ~= nil and math.abs(hit.y - (Y - 10)) < 2
		end)
		-- the game switches Box2D's own gravity off, so the test brings its own: 10 m/s^2 on the bob
		local pull = ml.on_update(function() if bob then b2.force(bob, 0, b2.mass(bob) * 10) end end)
		ml.after(1, function()
			pull.remove()
			check("the pendulum swung down on its hinge", function()
				local x, y = b2.position(bob)
				local d = math.sqrt((x - X) ^ 2 + (y - Y) ^ 2)
				local where = string.format("now at (%.1f, %.1f) from the pivot, %.1f px away", x - X, y - Y, d)
				if not (y > Y + 5 and math.abs(d - 100) < 3) then error(where .. " (expected below it, 100 px away)", 0) end
				return where
			end)
			check("motor", function() b2.set_motor(hinge, 90, 1e6); return true end)
			check("destroy the joint", function() b2.destroy_joint(hinge); return #b2.joints(bob) == 0 end)
			check("destroy the bodies", function() local b = bob; bob = nil; b2.destroy_body(b); b2.destroy_body(anchor); return #b2.own_bodies() == 0 end)
			print("physics self-test done")
		end)
	end)
end)
