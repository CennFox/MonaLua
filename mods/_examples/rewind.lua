-- rewind.lua -- a new tool for the item pool: Rewind.
--
-- Fire it and the last five seconds run backwards: you, every loose object, everything that was
-- thrown, pushed, dropped or sent flying travels back along the way it came, at double speed,
-- and carries on from there with the speed and spin it had at that moment.  Jump into a pit and
-- take it back; throw a box, ride it, and call it home.
--
-- What it cannot bring back: things that were destroyed in those five seconds (collected fruit
-- stays collected, a blown-up tile stays blown up), and things made in them are not unmade.

local SECONDS  = 5         -- how far back it goes
local SPEED    = 2         -- how fast the film runs backwards (2 = five seconds in two and a half)
local EVERY    = 2         -- a snapshot is taken every this many frames
local TRY_KEY  = "y"       -- gives you the tool at once, for trying it out; nil switches that off
local TINT     = 0x5AA0FF  -- the colour of the screen while time runs backwards

local TOOL = "rewind"

if not ml.add_tool then
	print("this mod needs the Lua kit 1.4.0 or later: unzip the new files into the game folder first")
	return
end

ml.add_tool{ name = TOOL, label = "Rewind", aim = "mid2", ammo = 2, icon = "rotater" }

local function state()
	local v = ml.vars()
	if v.film == nil then v.film, v.frame, v.back = {}, 0, nil end
	return v
end

-- one snapshot: where every loose thing is and how it moves
local function snapshot()
	local shot = { t = ml.time() }
	for _, inst in ipairs(ml.instances("physics_obj")) do
		local sp, ph = inst.sprite, inst.physics
		if ph ~= nil and sp.destroyed == false then
			local ok, kind = pcall(b2.type, inst)
			if ok and kind == "dynamic" then
				local p = sp.position
				shot[#shot + 1] = { inst, sp, ph, p.x, p.y, sp.angle, ph:getVelocityX(), ph:getVelocityY(), ph:getAngularVelocity() }
			end
		end
	end
	return shot
end

-- put everything where a snapshot has it; moving = with its speed of then, else held still
local function apply(shot, moving)
	for i = 1, #shot do
		local e = shot[i]
		local sp, ph = e[2], e[3]
		if sp.destroyed == false then
			sp:setPos(e[4], e[5])
			sp:setAngle(e[6])
			pcall(function() ph:syncPosWithSprite() end)
			if moving then
				ph:setVelocity(e[7], e[8]); ph:setAngularVelocity(e[9])
			else
				ph:setVelocity(0, 0); ph:setAngularVelocity(0)
			end
		end
	end
end

local function overlay(v, strength)
	if v.gfx == nil then
		local ok = pcall(function()
			local g = mosa.new("h2d.Graphics")
			local top = 0
			for _, inst in ipairs(ml.instances("physics_obj")) do
				local l = inst.sprite.layer
				if l > top then top = l end
			end
			ml.layout.scene:add(g, top, nil)
			v.gfx = g
		end)
		if not ok then v.gfx = false end
	end
	local g = v.gfx
	if not g then return end
	pcall(function()
		g:clear()
		if strength <= 0 then return end
		local l = ml.layout
		g:beginFill(TINT, 0.16 * strength)
		g:drawRect(0, 0, l.width, l.height)
		g:endFill()
		-- lines running up the screen, like a tape played backwards
		g:beginFill(0xFFFFFF, 0.10 * strength)
		local off = (v.frame * 3) % 24
		for y = l.height - off, 0, -24 do g:drawRect(0, y, l.width, 1) end
		g:endFill()
	end)
end

ml.on_fire(TOOL, function()
	local v = state()
	if v.back or #v.film < 2 then return end
	local film = v.film
	local stop = film[#film].t - SECONDS
	local first = 1
	for i = #film, 1, -1 do
		if film[i].t <= stop then first = i; break end
	end
	v.back = { at = #film, first = first, carry = 0 }
	print(string.format("rewinding %.1f seconds (%d snapshots, %d loose things)", film[#film].t - film[first].t, #film - first + 1, #film[#film]))
end)

ml.on_update(function()
	if not ml.gameplay() then return end
	local v = state()
	v.frame = v.frame + 1
	local back = v.back
	if back then
		-- the film runs backwards: SPEED frames of the past per frame
		back.carry = back.carry + SPEED / EVERY
		local steps = math.floor(back.carry)
		back.carry = back.carry - steps
		back.at = math.max(back.first, back.at - steps)
		local shot = v.film[back.at]
		if back.at > back.first then
			apply(shot, false)
			overlay(v, 1)
		else
			-- arrived: everything goes on from here as it did then
			apply(shot, true)
			for i = #v.film, back.first + 1, -1 do v.film[i] = nil end
			v.back = nil
			overlay(v, 0)
		end
		return
	end
	if v.frame % EVERY == 0 then
		local film = v.film
		film[#film + 1] = snapshot()
		-- keep a little more than is needed
		local keep = film[#film].t - SECONDS - 1
		if film[1].t < keep and #film > 4 then
			local drop = 0
			while film[drop + 2] and film[drop + 1].t < keep do drop = drop + 1 end
			if drop > 30 then table.move(film, drop + 1, #film, 1); for i = #film, #film - drop + 1, -1 do film[i] = nil end end
		end
	end
end)

if TRY_KEY then
	ml.on_key(TRY_KEY, function()
		if not ml.gameplay() or ml.player() == nil then return end
		local ok, err = pcall(ml.give_tool, TOOL)
		if not ok then print("could not hand out Rewind: " .. tostring(err)) end
	end)
end

print("Rewind is in the item pool" .. (TRY_KEY and (" (press " .. TRY_KEY:upper() .. " in a level to get one at once)") or ""))
