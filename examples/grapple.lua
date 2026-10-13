-- grapple.lua -- press R to shoot a springy rope from the player towards the crosshair; it
-- catches the first thing in the way (terrain included).  R again lets go.  Copy into mods\ to use.
-- Shows: ray casts, joints between game objects, per-level variables.

-- The rope is kept in ml.vars(): a table that starts empty in every level, and that a GIF
-- replay of the level gets a copy of its own of (see "GIF replays" in the guide).
local function release(v)
	if v.rope and b2.joint_alive(v.rope) then b2.destroy_joint(v.rope) end
	v.rope = nil
end

ml.on_key("r", function()
	local v = ml.vars()
	if v.rope then release(v); return end
	local p = ml.player()
	if not p or not p.physics then return end
	local x, y = ml.pos(p)
	local ax, ay = ml.aim_point(p)
	if not ax then return end
	local dx, dy = ax - x, ay - y
	local len = math.sqrt(dx * dx + dy * dy)
	if len == 0 then return end
	local hit = b2.raycast(x, y, x + dx / len * 700, y + dy / len * 700, function(inst) return inst ~= p end)
	if not hit or not hit.inst then return end
	v.rope = b2.distance(p, hit.inst, {
		ax = x, ay = y, bx = hit.x, by = hit.y,      -- from the player to the exact point that was hit
		length = hit.distance * 0.6,                 -- shorter than the gap: it pulls
		frequency = 2, damping = 0.5,                -- soft, like elastic
	})
	print(string.format("rope to a %s %.0f px away", tostring(hit.inst.type), hit.distance))
end)

-- nothing to clean up when a level ends: its joints go with it, and so does ml.vars()
