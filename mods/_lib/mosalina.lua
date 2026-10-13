-- mosalina.lua -- the Mosa Lina modding API (`ml`), on top of the generic `mosa` engine and
-- the Box2D layer `b2`.  Loaded before every mod.
--
-- Written from the game's bytecode (build of October 2026), tested on a stand-in engine with
-- the same class names running real Box2D (tests/fishgame), and confirmed in the real game.
-- Each part still checks what it finds and logs a clear message instead of failing silently.
--
-- How the game is built (useful when exploring):
--   * A Construct-style engine.  Every object on screen is an instance of
--     fish.game.oclass.OClass_<type>: inst.type (name), inst.families, inst.sprite (position,
--     size, angle, animation), inst.physics (may be nil; inst.physics.body is its Box2D body),
--     inst.uid, plus the object's own variables.
--   * A layout (fish.system.Layout) is one level or menu screen: layout.insts maps a type or
--     family name to the array of its instances, layout.world is its Box2D world.  Each frame
--     Layout.update ticks the objects, runs the layout's event sheet, steps the physics and
--     removes destroyed objects.  game.layouts.mainLayout is the one being played.
--   * Game logic lives in "event sheets".  fish.game.evsheet.EvSheet_gameplay has named
--     functions (shoot, jump, player_death, explosion_fn, ...) and thousands of anonymous
--     event blocks hookable as "EvSheet_gameplay:<line>".
--   * Tools: the player carries b_item instances.  b_item.item.type.name is the tool's name,
--     b_item.ammo its shots left, b_item.nr its slot; player.item_selected is the slot in hand.

local ml = {}
_G.ml = ml

local EV = "fish.game.evsheet.EvSheet_gameplay"
local warned = {}
local function warn_once(key, msg)
	if not warned[key] then
		warned[key] = true
		hl.log("[ml] " .. msg)
	end
end

local function hook_if(name, kind, fn, what, opts)
	if mosa.hookable(name) then return mosa[kind](name, fn, opts) end
	warn_once(name, "cannot find " .. name .. ": " .. what .. " will not work in this version of the game")
	return nil
end

local function check_fn(fn, what)
	if type(fn) ~= "function" then error(what .. " needs a function", 3) end
end

---------------------------------------------------------------- the running game

-- The game's own per-frame function drives mosa's timers and "tick" event.
mosa.config.tick = mosa.config.tick or "fish.system.Main.mainLoop"

-- ml.main    the application object (fish.system.Main)
-- ml.game    the game it is running (not the throw-away games used for level previews)
-- ml.layout  the layout being played: a level, or one of the menu screens
-- ml.ev      the gameplay event sheet (fish.game.evsheet.EvSheet_gameplay)
if mosa.hookable("fish.system.Main.mainLoop") then
	local h
	h = mosa.before("fish.system.Main.mainLoop", function(self)
		ml.main = self
		local g = self.game
		if g ~= nil then
			ml.game = g
			h.remove()
		end
	end)
end

-- The engine also builds layouts for other games: level previews, and the private copy of
-- the game in which a level is played again when a GIF is saved.  Normally only the main game's
-- layouts count; while a GIF is rendered it is the other way round (see "GIF replays" below).
local in_replay = false
local function is_main(layout)
	local main = ml.main
	if main == nil or layout == nil then return true end
	local g = main.game
	if g == nil then return true end
	if in_replay then return layout.game ~= g end
	return layout.game == g
end

-- How the game changes layout (read from its bytecode): the next one is built completely --
-- Layout.initialise creates its physics world and adds its objects -- while the current one is
-- still in the middle of its frame; at the end of that frame the game switches and runs the
-- new layout's first update.  ml.layout follows the same order: it moves to the new layout
-- when it is built, so code reacting to its objects being created already sees it, and
-- on_layout / on_level run at its first frame, when everything is in place.
local started = false           -- has ml_layout been emitted for ml.layout?
local previous, previous_frames = nil, 0

local function set_game(layout)
	local g = layout.game
	if g ~= nil then
		ml.game = g
		local ev = g.ev_gameplay
		if ev ~= nil then ml.ev = ev end
	end
end

local function begin_layout(layout)
	local old = ml.layout
	if old ~= nil and started then
		previous, previous_frames = old, 0
		mosa.emit("ml_layout_end", old)
	end
	ml.layout = layout
	started = false
	set_game(layout)
end

hook_if("fish.system.Layout.initialise", "before", function(layout)
	if is_main(layout) then begin_layout(layout) end
end, "early level detection")

--- ml.gameplay() -> true when the current layout is a level (it runs the gameplay event sheet)
function ml.gameplay()
	local l = ml.layout
	if l == nil then return false end
	local ev = ml.ev
	return ev ~= nil and l.sheet == ev
end

local update_handlers = {}
local begin_frame               -- keyboard sampling / playback for the frame that starts (defined with the keys)

local function on_layout_update(layout, dt)
	if layout ~= ml.layout then
		if not is_main(layout) then return end
		if layout == previous and not started then
			-- the layout that was running when the next one was built is finishing its frame
			previous_frames = previous_frames + 1
			if previous_frames <= 3 then return end
			-- ... or the new one was never switched to: carry on with this one
			ml.layout, started, previous = layout, true, nil
		else
			begin_layout(layout)
		end
	end
	if not started then
		started, previous = true, nil
		if ml.game == nil then set_game(layout) end
		mosa.emit("ml_layout", layout)
		if ml.gameplay() then mosa.emit("ml_level", layout) end
	end
	begin_frame(layout)
	local n = #update_handlers
	if n > 0 then
		dt = (dt or 0) * (layout.timeScale or 1)
		for i = 1, n do
			local h = update_handlers[i]
			if h then h(dt, layout) end
		end
	end
end
hook_if("fish.system.Layout.update", "before", on_layout_update, "ml.layout / level events / ml.on_update")

--- true once a level is running and the helpers below can work
function ml.ready() return ml.layout ~= nil end

local function need_layout(what)
	if not ml.layout then error(what .. ": no level is running yet (ml.ready() is false)", 3) end
	return ml.layout
end

---------------------------------------------------------------- selectors

-- A selector says which objects something applies to:
--   "crate"            an object type          "solid"   a family (group of types)
--   "*"                everything              inst      that one object
--   function(inst)     your own test           a name given to ml.define

local names_cache = {}       -- type -> set of names (type + families)
local kind_of = {}           -- uid -> custom kind (ml.define)
local kind_members = {}      -- custom kind -> { uid -> inst }

-- an object reference in Lua always stands for the same game object, so the answer can be
-- remembered per reference (weak keys: it goes when the reference does)
local inst_names = setmetatable({}, { __mode = "k" })

local function names_of(inst)
	local set = inst_names[inst]
	if set then return set end
	local t = inst.type
	set = names_cache[t]
	if not set then
		set = { ["*"] = true }
		if t ~= nil then set[t] = true end
		local fams = inst.families
		if fams ~= nil then
			for _, f in mosa.each(fams) do set[f] = true end
		end
		if t ~= nil then names_cache[t] = set end
	end
	inst_names[inst] = set
	return set
end

local function matches(sel, inst)
	if inst == nil then return false end
	local ts = type(sel)
	if ts == "string" then
		if names_of(inst)[sel] then return true end
		return kind_of[inst.uid] == sel
	elseif ts == "function" then
		return sel(inst) == true
	end
	return sel == inst
end
ml.matches = matches

local function check_sel(sel, what)
	local ts = type(sel)
	if ts ~= "string" and ts ~= "function" and ts ~= "userdata" then
		error(what .. ": expected an object type name, \"*\", an object or a function, got " .. ts, 3)
	end
end

---------------------------------------------------------------- instances

--- ml.instances("bomb") -> Lua list of the live instances of that type, family or ml.define kind
function ml.instances(name)
	local members = kind_members[name]
	if members then
		local out = {}
		for _, inst in pairs(members) do out[#out + 1] = inst end
		table.sort(out, function(a, b) return a.uid < b.uid end)
		return out
	end
	local layout = ml.layout
	if not layout then return {} end
	return mosa.totable(layout.insts:get(name))
end

--- ml.all() -> Lua list of every instance in the level
function ml.all()
	local layout = ml.layout
	if not layout then return {} end
	return mosa.totable(layout.allInstances)
end

--- ml.first("player") -> one instance or nil
function ml.first(name)
	if kind_members[name] then return ml.instances(name)[1] end
	local layout = ml.layout
	if not layout then return nil end
	local arr = layout.insts:get(name)
	if arr == nil or #arr == 0 then return nil end
	return arr[0]
end

--- ml.count("coin")
function ml.count(name)
	if kind_members[name] then return #ml.instances(name) end
	local layout = ml.layout
	if not layout then return 0 end
	local arr = layout.insts:get(name)
	return arr and #arr or 0
end

--- ml.each("tile_box", function(inst) ... end)
function ml.each(name, fn)
	for _, inst in ipairs(ml.instances(name)) do fn(inst) end
end

--- ml.types() -> sorted names (types and families) that have at least one instance right now
function ml.types()
	local out = {}
	if ml.layout then
		for _, k in mosa.each(ml.layout.insts:keys()) do
			if ml.count(k) > 0 then out[#out + 1] = k end
		end
	end
	table.sort(out)
	return out
end

--- ml.by_uid(uid) -> the instance with that uid, or nil
function ml.by_uid(uid)
	local g = ml.game
	if g == nil then return nil end
	return g.instsByUid:get(uid)
end

--- ml.kind(inst) -> its ml.define name when it has one, else its type
function ml.kind(inst) return kind_of[inst.uid] or inst.type end

--- ml.is(inst, selector) -> does the object match ("crate", a family, "*", a function ...)
function ml.is(inst, sel) return matches(sel, inst) end

--- ml.player([playerId]) -> the player instance (first one by default)
function ml.player(id)
	for _, p in ipairs(ml.instances("player")) do
		if id == nil or p.playerId == id then return p end
	end
	return nil
end

function ml.players() return ml.instances("player") end

--- ml.alive(inst) -> false once the game has destroyed it
function ml.alive(inst)
	if inst == nil then return false end
	local ok, d = pcall(function() return inst.sprite.destroyed end)
	return ok and d == false
end

--- ml.nearest(selector, x, y [, max_distance]) -> instance, distance
function ml.nearest(sel, x, y, max)
	local best, bd = nil, max or math.huge
	local list = (type(sel) == "string" and sel ~= "*") and ml.instances(sel) or ml.all()
	for _, inst in ipairs(list) do
		if matches(sel, inst) and ml.alive(inst) then
			local p = inst.sprite.position
			local d = math.sqrt((p.x - x) ^ 2 + (p.y - y) ^ 2)
			if d <= bd then best, bd = inst, d end
		end
	end
	return best, best and bd or nil
end

---------------------------------------------------------------- position, size, motion

--- ml.pos(inst) -> x, y
function ml.pos(inst)
	local p = inst.sprite.position
	return p.x, p.y
end

--- ml.set_pos(inst, x, y) -- teleports the object; its physics body moves with it
function ml.set_pos(inst, x, y)
	inst.sprite:setPos(x, y)
	local ph = inst.physics
	-- the game copies sprite -> body at the start of every frame; do it now when that is allowed
	if ph ~= nil and not b2.locked() then pcall(function() ph:syncPosWithSprite() end) end
end

--- ml.distance(a, b) between two instances
function ml.distance(a, b)
	local ax, ay = ml.pos(a)
	local bx, by = ml.pos(b)
	return math.sqrt((ax - bx) ^ 2 + (ay - by) ^ 2)
end

--- ml.size(inst) -> width, height        ml.set_size(inst, w, h)  (the collision shape follows)
function ml.size(inst) return inst.sprite.width, inst.sprite.height end
function ml.set_size(inst, w, h) inst.sprite:setSize(w, h) end

--- ml.angle(inst) in degrees             ml.set_angle(inst, degrees)
function ml.angle(inst) return inst.sprite.angle end
function ml.set_angle(inst, deg) inst.sprite:setAngle(deg) end

local function physics(inst, what)
	local ph = inst.physics
	if not ph then error(what .. ": this " .. tostring(inst.type) .. " has no physics body", 3) end
	return ph
end

--- ml.velocity(inst) -> vx, vy           ml.set_velocity(inst, vx, vy)     pixels per second
function ml.velocity(inst)
	local ph = physics(inst, "ml.velocity")
	return ph:getVelocityX(), ph:getVelocityY()
end
function ml.set_velocity(inst, vx, vy) physics(inst, "ml.set_velocity"):setVelocity(vx, vy) end

--- ml.impulse(inst, strength, angle_degrees) -- a shove; 0 = right, 90 = down (screen coordinates)
function ml.impulse(inst, strength, angle) physics(inst, "ml.impulse"):applyImpulseAtAngle(strength, angle, 0) end
--- ml.force(inst, strength, angle_degrees)   -- continuous push, call every frame
function ml.force(inst, strength, angle) physics(inst, "ml.force"):applyForceAtAngle(strength, angle, 0) end
--- ml.spin(inst, degrees_per_second)
function ml.spin(inst, av) physics(inst, "ml.spin"):setAngularVelocity(av) end
--- ml.freeze(inst [, frozen=true]) -- immovable like level terrain; false makes it loose
function ml.freeze(inst, frozen) physics(inst, "ml.freeze"):setImmovable((frozen == false) and 0 or 1) end
-- (gravity: ml.weight, ml.gravity, ml.set_gravity_scale are further down, after the per-frame handlers)

---------------------------------------------------------------- creating and removing

local factories
local function factory_map()
	if factories == nil then
		local OC = mosa.class("fish.game.ObjectClasses")
		factories = OC and OC.createInstance or false
		if not factories then warn_once("factories", "fish.game.ObjectClasses.createInstance not found: ml.spawn disabled") end
	end
	return factories or nil
end

local defs = {}              -- ml.define: name -> definition

--- ml.spawnable() -> sorted list of every object type name the game can create (about 680)
function ml.spawnable()
	local out, f = {}, factory_map()
	if f then for _, k in mosa.each(f:keys()) do out[#out + 1] = k end end
	table.sort(out)
	return out
end

--- ml.can_spawn("bomb") -> true for game types and for names given to ml.define
function ml.can_spawn(name)
	if defs[name] then return true end
	local f = factory_map()
	return f ~= nil and f:exists(name) == true
end

local attach_def

--- ml.spawn("bomb", x, y [, { layer = 0, init = function(inst) end, ... }]) -> the new instance
-- init runs before the object is added to the level (set fields there that its setup reads;
-- its physics body does not exist yet).  For a name from ml.define the whole options table is
-- also handed to that definition's functions.  Not possible inside a physics callback: there,
-- use ml.on_collision (runs after the step) or b2.after_step.
function ml.spawn(name, x, y, opts)
	local layout = need_layout("ml.spawn")
	opts = opts or {}
	local def = defs[name]
	local base = def and def.base or name
	local f = factory_map()
	if not (f ~= nil and f:exists(base) == true) then
		error("ml.spawn: the game has no object type '" .. tostring(base) .. "' (see ml.spawnable())", 2)
	end
	if b2.locked() then
		error("ml.spawn: the physics world is being stepped; spawn from ml.on_collision or inside b2.after_step(function() ... end)", 2)
	end
	local init = opts.init
	if def and def.setup then
		local user = init
		init = function(inst)
			def.setup(inst, opts)
			if user then user(inst) end
		end
	end
	local inst = layout:createObject(base, opts.layer or 0, x, y, false, "", init)
	if def and inst ~= nil then attach_def(inst, name, def, opts) end
	return inst
end

--- ml.destroy(inst) -- the game removes it at the end of the frame
function ml.destroy(inst)
	if ml.alive(inst) then inst.sprite:destroy(nil) end
end

--- ml.sfx("name") -- play one of the game's sound effects by name
function ml.sfx(name)
	local sheet = ml.layout and ml.layout.sheet or ml.ev
	if not sheet then return end
	return sheet:sfx(name)
end

--- ml.explode(x, y, radius [, power]) -> the game's own explosion: an "explosion" object of
-- that radius that shoves the physics objects it touches (the game's tools use power 0.3)
function ml.explode(x, y, radius, power)
	local ev = ml.ev
	if not ev or not ml.gameplay() then error("ml.explode: no level is running (explosions belong to the gameplay sheet)", 2) end
	if b2.locked() then error("ml.explode: not inside a physics callback; use b2.after_step", 2) end
	return ev:explosion_fn(radius, x, y, power or 0.3, 0)
end

--- ml.picker(inst, ...) -> a fish.system.Picker holding those instances (what the game's own
-- functions take when they want "some objects", e.g. physics:createRevoluteJoint)
function ml.picker(...)
	return mosa.new("fish.system.Picker", mosa.array({ ... }))
end

---------------------------------------------------------------- time

--- ml.dt() -> seconds of game time the current frame covers
function ml.dt()
	local l = ml.layout
	return l and l._dt or 0
end

--- ml.tick() -> frame number of the level      ml.time() -> seconds the level has been running
function ml.tick()
	local l = ml.layout
	return l and l.currentTick or 0
end
function ml.time()
	local l = ml.layout
	return l and l.gameTime or 0
end

--- ml.time_scale() -> factor      ml.set_time_scale(f)   0.25 = slow motion, 1 = normal
function ml.time_scale()
	local l = ml.layout
	return l and l.timeScale or 1
end
function ml.set_time_scale(f) need_layout("ml.set_time_scale").timeScale = f end

local add_update

local level_timers, timers_hooked = {}, false

--- ml.after(seconds, fn) -> handle with .cancel()
-- Like mosa.delay, but on the level's clock: it follows slow motion, pauses with the game and
-- is dropped when the level ends.
function ml.after(seconds, fn)
	check_fn(fn, "ml.after")
	local t = { at = ml.time() + seconds, fn = mosa.bind(fn, "ml.after") }
	function t.cancel() t.cancelled = true end
	level_timers[#level_timers + 1] = t
	if not timers_hooked then
		timers_hooked = true
		add_update(function()
			if #level_timers == 0 then return end
			local due, level_time = {}, ml.time()
			for i = #level_timers, 1, -1 do
				local x = level_timers[i]
				if x.cancelled or level_time >= x.at then
					table.remove(level_timers, i)
					if not x.cancelled then due[#due + 1] = x end
				end
			end
			for i = #due, 1, -1 do due[i].fn() end
		end)
	end
	return t
end

mosa.on("ml_layout_end", function()
	for i = #level_timers, 1, -1 do level_timers[i] = nil end
end)

---------------------------------------------------------------- tools

--- ml.tool([player]) -> name, b_item of the tool in hand (nil when there is none)
function ml.tool(player)
	player = player or ml.player()
	if not player then return nil end
	local slot = player.item_selected
	for _, it in ipairs(ml.instances("b_item")) do
		if it.nr == slot then
			local def = it.item
			local ty = def and def.type
			return ty and ty.name or nil, it
		end
	end
	return nil
end

--- ml.tools() -> list of { name=, ammo=, slot=, item= } the player currently carries
function ml.tools()
	local out = {}
	for _, it in ipairs(ml.instances("b_item")) do
		local def = it.item
		local ty = def and def.type
		out[#out + 1] = { name = ty and ty.name or "?", ammo = it.ammo, slot = it.nr, item = it }
	end
	table.sort(out, function(a, b) return a.slot < b.slot end)
	return out
end

--- ml.aim_point([player [, which]]) -> x, y of an aiming marker
-- which: "crosshair" (default), "short", "mid", "max"
function ml.aim_point(player, which)
	player = player or ml.player()
	if not player then return nil end
	local names = { crosshair = "crosshair_point", short = "short_aim_point", mid = "mid_aim_point", max = "max_aim_point" }
	local name = names[which or "crosshair"] or which
	local c = player.container
	local inst = c and c.insts and c.insts:get(name)
	if inst == nil then inst = ml.first(name) end
	if inst == nil then return nil end
	return ml.pos(inst)
end

local fire_handlers = {}     -- tool name (or "*") -> list of functions
local shoot_hooked = false

local function run_fire(name, player, item)
	local list = {}
	for _, fn in ipairs(fire_handlers[name] or {}) do list[#list + 1] = fn end
	for _, fn in ipairs(fire_handlers["*"] or {}) do list[#list + 1] = fn end
	if #list == 0 then return end
	local x, y = ml.pos(player)
	local ctx = { tool = name, player = player, item = item, x = x, y = y }
	function ctx.aim(which) return ml.aim_point(player, which) end
	--- angle in degrees from the player to the crosshair
	function ctx.angle()
		local ax, ay = ml.aim_point(player)
		if not ax then return 0 end
		return math.deg(math.atan(ay - y, ax - x))
	end
	for _, fn in ipairs(list) do fn(ctx) end
end

local function hook_shoot()
	if shoot_hooked then return end
	shoot_hooked = true
	-- shoot(playerId) fires the tool in hand if it has ammo.  We look at the ammo before and
	-- after the game's own code runs to know whether a shot really happened.
	hook_if(EV .. ".shoot", "hook", function(orig, self, player_id)
		local player = ml.player(player_id)
		local name, item, ammo
		if player then
			local ok, a, b = pcall(ml.tool, player)
			if ok then name, item = a, b end
			if item then ammo = item.ammo end
		end
		local blocked = player and player.digging == true
		local result = orig(self, player_id)
		if name and item and not blocked then
			local fired = (ammo == -1) or (ammo ~= nil and ammo > 0 and item.ammo == ammo - 1)
			if fired then run_fire(name, player, item) end
		end
		return result
	end, "ml.on_fire")
end

--- ml.on_fire("toolname", function(ctx) ... end)        "*" = every tool
-- Runs right after the game fired that tool (ammo already taken).
--   ctx.tool    tool name            ctx.player  the player instance
--   ctx.item    the b_item (ammo…)   ctx.x, ctx.y  player position
--   ctx.aim([which]) -> x, y of the crosshair / "short" / "mid" / "max" aim point
--   ctx.angle() -> degrees from the player to the crosshair
-- For a brand-new tool see ml.add_tool below: the game does nothing itself when a tool it
-- does not know is fired, and this handler supplies the behaviour.
function ml.on_fire(name, fn)
	check_fn(fn, "ml.on_fire")
	hook_shoot()
	local l = fire_handlers[name]
	if not l then l = {}; fire_handlers[name] = l end
	l[#l + 1] = mosa.bind(fn, "ml.on_fire handler")
end

--- ml.set_ammo(tool_name, n)  -- n = -1 means unlimited
function ml.set_ammo(tool_name, n)
	for _, t in ipairs(ml.tools()) do
		if t.name == tool_name then t.item.ammo = n end
	end
end

---------------------------------------------------------------- new tools

-- How the game knows its tools (read from its bytecode):
--   * When it starts, its first layout creates one "item" object per tool (variables NAME, ammo,
--     aim_type, secondLayer); they are the squares of the tool grid.  Then
--     game.itemManager:initBaseItems(those objects) appends one entry per object to
--     itemManager.itemPool: { name, baseAmmo, aimType (a number), secondLayer }.
--   * itemManager:pick draws the three tools in hand from the pool (pinned ones first); a carried
--     b_item points to { type = <pool entry>, locked, wins }.
--   * The picture of a tool is the animation of that name of the "item_icon" objects (one table
--     for all of them, OClass_item_icon._animData, made with the first icon).  A name without
--     one crashes the game.
--   * The name on screen is the text "TOOL_<NAME IN CAPITALS>" of the language in use; a missing
--     text is shown as that key.
--   * Firing takes one ammo whatever the tool is called, then looks the name up in its own list;
--     an unknown name does nothing more, which leaves the behaviour to ml.on_fire.
-- ml.add_tool does the same steps for a tool of your own: an "item" object in a free square of
-- the grid (when the game is just starting), the pool entry through initBaseItems, a picture
-- borrowed from an existing tool, and the text.

local AIM_TYPES = { shoot = 0, short = 1, short2 = 2, mid = 3, mid2 = 4, long = 5, long2 = 6, remote = 7 }
local AIM_NAMES = {}
for k, v in pairs(AIM_TYPES) do AIM_NAMES[v] = k end

-- which pool entries are ours: kept across a reload of the mods (the game object lives on)
local tool_state = rawget(_G, "__ml_tools")
if not tool_state then
	tool_state = { added = {} }
	rawset(_G, "__ml_tools", tool_state)
end
local my_tools, my_tool_names = {}, {}       -- what this load's mods asked for
local tools_hooked, adding_tools = false, false

local function main_item_manager()
	local main = ml.main
	if main == nil then
		local Main = mosa.class("fish.system.Main")
		main = Main and Main.i
	end
	local g = main and main.game
	return g and g.itemManager or nil
end

local function pool_entry(mgr, name)
	local t = mgr:findItem(name)
	if t ~= nil and t.name == name then return t end
	return nil
end

-- free squares of the tool grid, in the order the tool patcher fills them: the columns right of
-- the game's own tools, then left of them, then rows below and above (600 x 338 screen)
local function grid_squares()
	local seq = {}
	for _, x in ipairs({ 505, 535, 565 }) do for _, y in ipairs({ 140, 170, 200, 230 }) do seq[#seq + 1] = { x, y } end end
	for _, x in ipairs({ 125, 95, 65, 35 }) do for _, y in ipairs({ 140, 170, 200, 230 }) do seq[#seq + 1] = { x, y } end end
	for _, y in ipairs({ 260, 290, 110 }) do for x = 35, 565, 30 do seq[#seq + 1] = { x, y } end end
	return seq
end

local function free_square(taken)
	for _, s in ipairs(grid_squares()) do
		local free = true
		for _, t in ipairs(taken) do
			if math.abs(t[1] - s[1]) < 15 and math.abs(t[2] - s[2]) < 15 then free = false; break end
		end
		if free then
			taken[#taken + 1] = s
			return s[1], s[2]
		end
	end
	return 300, 320
end

-- The table of tool pictures is made by the first item_icon the game creates.  Its constructor
-- takes too many arguments to be hooked, so when a tool of ours needs its picture before the
-- game has shown any, one icon is made here (through the game's own factory) and thrown away.
local function tool_pictures(make)
	local Icon = mosa.class("fish.game.oclass.OClass_item_icon")
	if Icon == nil then return nil end
	local anims = Icon._animData
	if anims == nil and make then
		local f = factory_map()
		local new_icon = f and f:get("item_icon")
		if new_icon ~= nil then
			local ok, err = pcall(new_icon)
			if not ok then warn_once("icon table", "ml.add_tool: could not make the game's table of tool pictures: " .. tostring(err)) end
			anims = Icon._animData
		end
	end
	return anims
end

-- the pictures and the texts: cheap to repeat, so this runs whenever something may have changed.
-- make_pictures: the game is up, and a tool of ours may be shown from now on
local function sync_tool_looks(make_pictures)
	if #my_tool_names == 0 then return end
	local anims = tool_pictures(make_pictures)
	if anims ~= nil then
		for _, name in ipairs(my_tool_names) do
			local def = my_tools[name]
			if anims:exists(name) ~= true then
				local donor = anims:get(def.icon)
				if donor == nil then
					warn_once("icon " .. name, "ml.add_tool: the game has no tool picture called '" .. tostring(def.icon) .. "' (tool " .. name .. "); using another one")
					donor = anims:get("nothing")
					if donor == nil then
						for _, k in mosa.each(anims:keys()) do donor = anims:get(k); break end
					end
				end
				if donor ~= nil then anims:set(name, donor) end
			end
		end
	end
	local Main = mosa.class("fish.system.Main")
	local loc = Main and Main.localisation
	local lines = loc and loc.lines
	if lines ~= nil then
		for _, lang in mosa.each(lines:keys()) do
			local texts = lines:get(lang)
			if texts ~= nil then
				for _, name in ipairs(my_tool_names) do
					local key = "TOOL_" .. name:upper()
					if texts:exists(key) ~= true then texts:set(key, my_tools[name].label) end
				end
			end
		end
	end
end

local function looks(make_pictures)
	local ok, err = pcall(sync_tool_looks, make_pictures)
	if not ok then warn_once("looks", "ml.add_tool: pictures and names: " .. tostring(err)) end
end

local function fill_item(obj, def)
	obj.NAME = def.name
	obj.ammo = def.ammo
	obj.aim_type = def.aim
	obj.unlocked = 1
	obj.secondLayer = def.second_layer
end

-- puts the tools of this load that the pool does not have yet into it.  `items` is the array
-- the game itself just built its pool from (nil later on): its objects tell which layout holds
-- the tool grid and which squares are taken.
local function sync_tool_pool(mgr, items)
	if #my_tool_names == 0 or mgr == nil then return end
	local missing = {}
	for _, name in ipairs(my_tool_names) do
		local def = my_tools[name]
		local entry = pool_entry(mgr, name)
		if entry == nil then
			missing[#missing + 1] = def
		elseif tool_state.added[name] then
			-- ours from an earlier load of the mods: follow what the mod says now
			entry.aimType, entry.baseAmmo, entry.secondLayer = AIM_TYPES[def.aim], def.ammo, def.second_layer
		else
			warn_once("clash " .. name, "ml.add_tool: the game already has a tool called '" .. name .. "'; it is left as it is (ml.on_fire can still change what it does)")
		end
	end
	if #missing == 0 then return end
	local layout, taken = nil, {}
	if items ~= nil then
		for _, it in mosa.each(items) do
			if it ~= nil then
				if layout == nil then layout = it.layout end
				local p = it.sprite.position
				taken[#taken + 1] = { p.x, p.y }
			end
		end
	end
	local objs = {}
	for _, def in ipairs(missing) do
		local obj
		if layout ~= nil then
			local x, y = free_square(taken)
			local ok, made = pcall(function() return layout:createObject("item", 0, x, y, true, "", nil) end)
			if ok then obj = made else warn_once("grid", "ml.add_tool: could not add a square to the tool grid: " .. tostring(made)) end
		end
		if obj == nil then
			-- an "item" object that is in no layout: enough to make the pool entry from
			local f = factory_map()
			local make = f and f:get("item")
			if make ~= nil then obj = make() end
		end
		if obj == nil then
			warn_once("item " .. def.name, "ml.add_tool: the game has no 'item' objects in this version: cannot add " .. def.name)
		else
			fill_item(obj, def)
			objs[#objs + 1] = obj
		end
	end
	if #objs == 0 then return end
	adding_tools = true
	local ok, err = pcall(function() mgr:initBaseItems(objs) end)
	adding_tools = false
	if not ok then
		hl.log("[ml] ml.add_tool: the game's initBaseItems failed: " .. tostring(err))
		return
	end
	local names = {}
	for _, def in ipairs(missing) do
		if pool_entry(mgr, def.name) ~= nil then
			tool_state.added[def.name] = true
			names[#names + 1] = def.name
		end
	end
	if #names > 0 then
		hl.log("[ml] added to the item pool: " .. table.concat(names, ", ") .. (layout ~= nil and " (and to the tool grid)" or " (the tool grid gets them when the game is started again)"))
	end
end

local function hook_tools()
	if tools_hooked then return end
	tools_hooked = true
	-- the game builds its pool once, while it starts: ours go in right behind its own
	hook_if("fish.system.ItemManager.initBaseItems", "after", function(_, mgr, items)
		if adding_tools then return end
		looks(true)
		sync_tool_pool(mgr, items)
	end, "ml.add_tool")
	mosa.on("ready", function()
		local mgr = main_item_manager()
		local up = mgr ~= nil and mgr.initialized == true
		looks(up)
		if up then sync_tool_pool(mgr, nil) end
	end)
	mosa.on("ml_layout", function() if not in_replay then looks(true) end end)
end

--- ml.add_tool{ name = "black_hole", label = "Black Hole", aim = "long", ammo = 1, icon = "vortex",
---              fire = function(ctx) ... end }
-- A new tool in the game's item pool: it is drawn like the game's own, sits in the tool grid and
-- can be pinned there.  Call it while your mod loads.
--   name          how the game knows it (b_item.item.type.name, ml.on_fire, ml.give_tool)
--   label         the name shown on screen (default: the name, with spaces for underscores)
--   aim           "shoot" (default), "short", "short2", "mid", "mid2", "long", "long2" or "remote"
--   ammo          shots per level, 1..255 (default 1)
--   icon          the name of a game tool whose picture it borrows (default "nothing")
--   second_layer  true = only drawn in second layer runs, like the game's second layer tools
--   fire          what it does: the same as ml.on_fire(name, fire)
-- Seeded runs: the pool is one tool longer, so a seed draws other tools than without the mod.
-- A tool stays in the pool until the game is closed, also when its mod is switched off (it then
-- does nothing when fired).
function ml.add_tool(def)
	if type(def) ~= "table" then error("ml.add_tool needs a table: ml.add_tool{ name = ..., aim = ..., ammo = ... }", 2) end
	local name = def.name
	if type(name) ~= "string" or name == "" or #name > 60 or name == "nothing" then
		error("ml.add_tool: name must be a short text (and not 'nothing')", 2)
	end
	local aim = def.aim or "shoot"
	if AIM_TYPES[aim] == nil then
		error("ml.add_tool: aim '" .. tostring(aim) .. "' is not one of shoot, short, short2, mid, mid2, long, long2, remote", 2)
	end
	local ammo = def.ammo == nil and 1 or def.ammo
	if math.type(ammo) ~= "integer" or ammo < 1 or ammo > 255 then error("ml.add_tool: ammo must be a whole number from 1 to 255", 2) end
	if def.fire ~= nil then check_fn(def.fire, "ml.add_tool: fire") end
	local mgr = main_item_manager()
	if mgr ~= nil and mgr.initialized == true and not tool_state.added[name] and pool_entry(mgr, name) ~= nil then
		error("ml.add_tool: the game already has a tool called '" .. name .. "' (ml.on_fire changes what a game tool does)", 2)
	end
	if my_tools[name] == nil then my_tool_names[#my_tool_names + 1] = name end
	table.sort(my_tool_names)                -- one order whatever the mods' load order, for seeded runs
	my_tools[name] = {
		name = name, aim = aim, ammo = ammo, icon = def.icon or "nothing", second_layer = def.second_layer == true,
		label = def.label or (name:gsub("_", " ")),
	}
	hook_tools()
	local up = mgr ~= nil and mgr.initialized == true
	looks(up)
	if up then sync_tool_pool(mgr, nil) end
	if def.fire ~= nil then ml.on_fire(name, def.fire) end
end

--- ml.pool() -> list of { name=, aim=, ammo=, second_layer=, added= } : every tool the game can draw
-- (added = true for the ones that came from ml.add_tool)
function ml.pool()
	local out = {}
	local g = ml.game
	local mgr = g and g.itemManager or main_item_manager()
	if mgr == nil then return out end
	for _, t in mosa.each(mgr.itemPool) do
		if t ~= nil then
			local name = t.name
			out[#out + 1] = { name = name, aim = AIM_NAMES[t.aimType] or "shoot", ammo = t.baseAmmo,
				second_layer = t.secondLayer == true, added = tool_state.added[name] == true }
		end
	end
	return out
end

--- ml.give_tool("black_hole" [, slot [, ammo]]) -> the b_item
-- Puts a tool of the pool into the player's hand, in place of the one in that slot (default:
-- the slot in hand), with its normal ammo unless you say otherwise.  For this level only.
function ml.give_tool(name, slot, ammo)
	local layout = need_layout("ml.give_tool")
	local g = ml.game
	local mgr = g and g.itemManager
	if mgr == nil then error("ml.give_tool: the game's item manager was not found", 2) end
	local entry = mgr:findPicked(name)
	if entry == nil then
		local ty = pool_entry(mgr, name)
		if ty == nil then error("ml.give_tool: there is no tool called '" .. tostring(name) .. "' in the item pool (see ml.pool())", 2) end
		entry = { locked = false, type = ty, wins = 0 }
	end
	if slot == nil then
		local p = ml.player()
		slot = p and p.item_selected or 0
	end
	for _, it in ipairs(ml.instances("b_item")) do
		if it.nr == slot then
			it.item = entry
			it.ammo = ammo or it.item.type.baseAmmo
			-- the game redraws the tool pictures at the screen edge after a shot; the same here
			local edge = g.ev_edge_ev
			if edge ~= nil then pcall(function() edge:item_icon_graphic_update() end) end
			return it
		end
	end
	error("ml.give_tool: the player carries no tool in slot " .. tostring(slot), 2)
end

---------------------------------------------------------------- level events

--- ml.on_level(function(layout) end) -- a level started: runs at its first frame, when everything
-- in it exists.  (A "level" is a layout that runs the gameplay event sheet.)
function ml.on_level(fn)
	check_fn(fn, "ml.on_level")
	return mosa.on("ml_level", fn)
end

--- ml.on_layout(function(layout) end) -- any layout started: levels and menu screens alike
-- (layout.name tells them apart; every layout has its own physics world)
function ml.on_layout(fn)
	check_fn(fn, "ml.on_layout")
	return mosa.on("ml_layout", fn)
end

--- ml.on_level_end(function(layout) end) -- the layout that was running is being replaced
function ml.on_level_end(fn)
	check_fn(fn, "ml.on_level_end")
	return mosa.on("ml_layout_end", fn)
end

add_update = function(fn)
	update_handlers[#update_handlers + 1] = fn
	local entry = {}
	function entry.remove()
		for i = #update_handlers, 1, -1 do
			if update_handlers[i] == fn then table.remove(update_handlers, i) end
		end
	end
	return entry
end

--- ml.on_update(function(dt, layout) end) -> handle with .remove()
-- Every frame of the running layout, right before the game updates it (object ticks, event
-- sheet, physics step).  dt is game time (slow motion included).  The place for forces and steering.
function ml.on_update(fn)
	check_fn(fn, "ml.on_update")
	return add_update(mosa.bind(fn, "ml.on_update handler"))
end

--- ml.each_frame(selector, function(inst, dt) end) -> handle
-- Runs for every live object matching the selector, every frame.
function ml.each_frame(sel, fn)
	check_sel(sel, "ml.each_frame")
	check_fn(fn, "ml.each_frame")
	fn = mosa.bind(fn, "ml.each_frame handler")
	return add_update(function(dt)
		local ts = type(sel)
		if ts == "userdata" then
			if ml.alive(sel) then fn(sel, dt) end
			return
		end
		local list = (ts == "string" and sel ~= "*") and ml.instances(sel) or ml.all()
		for i = 1, #list do
			local inst = list[i]
			if (ts == "string" or matches(sel, inst)) and inst.sprite.destroyed == false then fn(inst, dt) end
		end
	end)
end

---------------------------------------------------------------- gravity

-- How the game does gravity (read from its bytecode and confirmed in a real run): the gameplay
-- sheet sets Box2D's own world gravity to zero when a level starts.  Then, every frame, it pulls
-- each moving object of the "physics_obj" family down itself, with a force of
--     personal_gravity * flipModifier * 1.05
-- (0.05 instead of 1.05 while a "low_grav" object exists, x 0.4 in water, nothing inside a
-- no-gravity zone).  An object's weight is one of its own variables: it does not follow its
-- mass, and b2.set_gravity / b2.set_gravity_scale only add something on top of it.
-- The functions here leave the game's variables alone: every frame they read what the game is
-- about to apply and add the difference, so they keep working when a tool flips or switches
-- off an object's gravity.

local function num(v) return type(v) == "number" and v or 0 end

local factor_layout, factor_tick, sheet_factor = nil, -1, 1.05
local function gravity_factor()
	local l = ml.layout
	local tick = l and l.currentTick or 0
	if tick ~= factor_tick or l ~= factor_layout then
		factor_layout, factor_tick = l, tick
		sheet_factor = ml.count("low_grav") > 0 and 0.05 or 1.05
	end
	return sheet_factor
end

local function game_weight(inst)
	local pg = inst.personal_gravity
	if type(pg) ~= "number" then return 0 end
	local body = b2.body(inst)
	if body == nil or b2.type(body) == "static" then return 0 end
	local flip = inst.flipModifier
	if type(flip) ~= "number" then flip = 1 end
	local water, off = 1, 0
	if inst.is_overlap_water == true then water, off = 0.4, -0.03 end
	local keep = 1 - num(inst.is_overlap_nograv)
	local up = num(inst.is_overlap_z_up)
	local fy = 0
	if keep ~= 0 and (up == 0 or ((up > 0) ~= (flip > 0))) then
		fy = (pg * flip * water * gravity_factor() + off) * keep
	end
	if up ~= 0 then fy = fy - b2.mass(body) / b2.scale() * up * water * 0.065 end
	return fy
end

local gravity_scale, gravity_of, gravity_insts, gravity_hooked = 1, {}, {}, false

--- ml.weight(inst) -> the downward force (Box2D units) that pulls on it this frame: the game's
-- own gravity for this object, times the scales set below.  0 for objects without weight (no
-- personal_gravity, no body, a static body); negative when it falls up.
-- b2.force(inst, 0, -ml.weight(inst)) every frame makes an object hover.
function ml.weight(inst)
	return game_weight(inst) * gravity_scale * (gravity_of[inst.uid] or 1)
end

local old_gravity_of, old_gravity_insts = {}, {}     -- of the level that is finishing its last frame

local function gravity_update(layout, of, insts)
	if gravity_scale == 1 then
		for uid, inst in pairs(insts) do
			if inst.sprite.destroyed == false then
				local w = game_weight(inst)
				if w ~= 0 then b2.force(inst, 0, (of[uid] - 1) * w) end
			else
				insts[uid], of[uid] = nil, nil
			end
		end
		return
	end
	local list = mosa.totable(layout.insts:get("physics_obj"))
	for i = 1, #list do
		local inst = list[i]
		local f = gravity_scale * (of[inst.uid] or 1)
		if f ~= 1 and inst.sprite.destroyed == false then
			local w = game_weight(inst)
			if w ~= 0 then b2.force(inst, 0, (f - 1) * w) end
		end
	end
end

-- The difference is added right before the level's physics step: after the game has applied
-- its own force for this frame, and after every mod's per-frame code, so a change made anywhere
-- in the frame counts for that frame.
local function need_gravity_update()
	if not gravity_hooked then
		gravity_hooked = true
		hook_if("fish@world_step", "before", function(world)
			local l = ml.layout
			if l == nil then return end
			if world == l.world then return gravity_update(l, gravity_of, gravity_insts) end
			-- in a level's last frame the next one is already built and current: still its step
			local p = previous
			if p ~= nil and world == p.world then gravity_update(p, old_gravity_of, old_gravity_insts) end
		end, "ml.gravity / ml.set_gravity_scale")
	end
end

--- ml.set_gravity_scale(f) -- gravity of everything, in every level, until changed:
-- 1 normal, 0.3 moon, 0 weightless, -1 everything falls up.     ml.gravity_scale() -> f
function ml.set_gravity_scale(f)
	if type(f) ~= "number" then error("ml.set_gravity_scale: expected a number, got " .. type(f), 2) end
	gravity_scale = f
	if f ~= 1 then need_gravity_update() end
end
function ml.gravity_scale() return gravity_scale end

--- ml.gravity(inst [, f]) -- the same for one object, on top of the scale above; without f
-- it returns the object's factor.  ml.gravity(inst, 0) makes it float, 1 gives it back its weight.
function ml.gravity(inst, f)
	if f == nil then return gravity_of[inst.uid] or 1 end
	if type(f) ~= "number" then error("ml.gravity: expected a number, got " .. type(f), 2) end
	physics(inst, "ml.gravity")
	local uid = inst.uid
	if f == 1 then
		gravity_of[uid], gravity_insts[uid] = nil, nil
	else
		gravity_of[uid], gravity_insts[uid] = f, inst
		need_gravity_update()
	end
end

--- ml.set_density(inst, d) -- heavier or lighter in every respect: harder or easier to push, and
-- falling as before.  (b2.set_density alone changes the mass only: the game's weight for the
-- object stays what it was, so a denser object would fall more slowly.)
function ml.set_density(inst, d)
	physics(inst, "ml.set_density")
	local before = b2.mass(inst)
	b2.set_density(inst, d)
	local after = b2.mass(inst)
	if before > 0 and after > 0 then ml.gravity(inst, ml.gravity(inst) * after / before) end
end

mosa.on("ml_layout_end", function()
	old_gravity_of, old_gravity_insts = gravity_of, gravity_insts
	gravity_of, gravity_insts = {}, {}
end)

---------------------------------------------------------------- object events

local function typed_event()
	local ev = { list = {} }
	function ev.add(sel, fn)
		local entry = { sel = sel, fn = fn }
		function entry.remove()
			for i = #ev.list, 1, -1 do if ev.list[i] == entry then table.remove(ev.list, i) end end
		end
		ev.list[#ev.list + 1] = entry
		return entry
	end
	function ev.fire(inst, ...)
		local list = ev.list
		for i = 1, #list do
			local e = list[i]
			if e and matches(e.sel, inst) then e.fn(inst, ...) end
		end
	end
	return ev
end

local created, destroyed = typed_event(), typed_event()
local create_hooked, destroy_hooked = false, false
local attached = {}          -- uid -> { inst =, list = { behaviour, ... } }

--- ml.on_create(selector, function(inst) end) -> handle
-- Runs whenever the game adds an object to the level: its physics body exists by then.
function ml.on_create(sel, fn)
	check_sel(sel, "ml.on_create")
	check_fn(fn, "ml.on_create")
	if not create_hooked then
		create_hooked = true
		hook_if("fish.system.Layout.addInstance", "after", function(_, layout, inst)
			if inst ~= nil and is_main(layout) then created.fire(inst) end
		end, "ml.on_create")
	end
	return created.add(sel, mosa.bind(fn, "ml.on_create handler"))
end

local function hook_destroy()
	if destroy_hooked then return end
	destroy_hooked = true
	hook_if("fish.system.Sprite.destroy", "before", function(sprite)
		if sprite.destroyed then return end       -- the game ignores a second destroy
		local inst = sprite.owner
		if inst == nil then return end
		local uid = inst.uid
		-- handlers may want to spawn things, which cannot happen during a physics step
		b2.after_step(function()
			destroyed.fire(inst)
			local a = attached[uid]
			if a then
				attached[uid] = nil
				for _, beh in ipairs(a.list) do
					if beh.destroy then beh.destroy(inst) end
				end
			end
			local k = kind_of[uid]
			if k then
				kind_of[uid] = nil
				if kind_members[k] then kind_members[k][uid] = nil end
			end
		end)
	end, "ml.on_destroy")
end

--- ml.on_destroy(selector, function(inst) end) -> handle
-- Runs when an object is destroyed (by the game or by a mod); the object can still be read.
function ml.on_destroy(sel, fn)
	check_sel(sel, "ml.on_destroy")
	check_fn(fn, "ml.on_destroy")
	hook_destroy()
	return destroyed.add(sel, mosa.bind(fn, "ml.on_destroy handler"))
end

---------------------------------------------------------------- collisions

local collide_list, separate_list, impact_list = {}, {}, {}
local collide_hooked, separate_hooked, impact_hooked = false, false, false

local function pair_order(e, a, b)
	-- returns 1 when (a, b) fits the entry's (selA, selB), 2 when (b, a) does
	if matches(e.a, a) and matches(e.b, b) then return 1 end
	if matches(e.a, b) and matches(e.b, a) then return 2 end
	return nil
end

local function hit_info(contact, a, b)
	local x, y, nx, ny, n = b2.contact_point(contact)
	local hit = { nx = nx, ny = ny }
	if n > 0 then hit.x, hit.y = x, y end
	local ba, bb = b2.body(a), b2.body(b)
	if ba ~= nil and bb ~= nil then
		local avx, avy = b2.velocity(ba)
		local bvx, bvy = b2.velocity(bb)
		local approach = (avx - bvx) * nx + (avy - bvy) * ny
		hit.speed = approach > 0 and approach or 0
	else
		hit.speed = 0
	end
	return hit
end

local function flipped(hit)
	return { x = hit.x, y = hit.y, nx = -hit.nx, ny = -hit.ny, speed = hit.speed, strength = hit.strength }
end

local function deliver_collision(contact, a, b)
	if a == nil or b == nil then return end
	local hit, jobs, ua, ub
	if next(attached) ~= nil then ua, ub = attached[a.uid], attached[b.uid] end
	for i = 1, #collide_list do
		local e = collide_list[i]
		local order = pair_order(e, a, b)
		if order then
			hit = hit or hit_info(contact, a, b)
			jobs = jobs or {}
			if order == 1 then jobs[#jobs + 1] = { e.fn, a, b, hit } else jobs[#jobs + 1] = { e.fn, b, a, flipped(hit) } end
		end
	end
	if ua or ub then
		for side = 1, 2 do
			local att = ua
			if side == 2 then att = ub end
			if att then
				for _, beh in ipairs(att.list) do
					if beh.collide then
						hit = hit or hit_info(contact, a, b)
						jobs = jobs or {}
						if side == 1 then jobs[#jobs + 1] = { beh.collide, a, b, hit } else jobs[#jobs + 1] = { beh.collide, b, a, flipped(hit) } end
					end
				end
			end
		end
	end
	if jobs then
		b2.after_step(function()
			for i = 1, #jobs do
				local j = jobs[i]
				j[1](j[2], j[3], j[4])
			end
		end)
	end
end

local function hook_collisions()
	if collide_hooked then return end
	collide_hooked = true
	b2.on_begin_contact(deliver_collision)
end

--- ml.on_collision(selectorA, selectorB, function(a, b, hit) end) -> handle
-- Two objects started touching.  a matches selectorA, b selectorB.
--   hit.x, hit.y   where (nil for sensors)        hit.nx, hit.ny   direction from a to b
--   hit.speed      how fast they closed in on each other, pixels per second
-- The handler runs right after the physics step, so it may spawn and destroy freely.
function ml.on_collision(sel_a, sel_b, fn)
	check_sel(sel_a, "ml.on_collision"); check_sel(sel_b, "ml.on_collision"); check_fn(fn, "ml.on_collision")
	hook_collisions()
	local entry = { a = sel_a, b = sel_b, fn = mosa.bind(fn, "ml.on_collision handler") }
	function entry.remove()
		for i = #collide_list, 1, -1 do if collide_list[i] == entry then table.remove(collide_list, i) end end
	end
	collide_list[#collide_list + 1] = entry
	return entry
end

local function hook_separate()
	if separate_hooked then return end
	separate_hooked = true
	b2.on_end_contact(function(contact, a, b)
		if a == nil or b == nil then return end
		local jobs
		for i = 1, #separate_list do
			local e = separate_list[i]
			local order = pair_order(e, a, b)
			if order then
				jobs = jobs or {}
				if order == 1 then jobs[#jobs + 1] = { e.fn, a, b } else jobs[#jobs + 1] = { e.fn, b, a } end
			end
		end
		if next(attached) ~= nil then
			for side = 1, 2 do
				local x, y = a, b
				if side == 2 then x, y = b, a end
				local att = attached[x.uid]
				if att then
					for _, beh in ipairs(att.list) do
						if beh.separate then
							jobs = jobs or {}
							jobs[#jobs + 1] = { beh.separate, x, y }
						end
					end
				end
			end
		end
		if jobs then
			b2.after_step(function()
				for i = 1, #jobs do jobs[i][1](jobs[i][2], jobs[i][3]) end
			end)
		end
	end)
end

--- ml.on_separate(selectorA, selectorB, function(a, b) end) -> handle   they stopped touching
function ml.on_separate(sel_a, sel_b, fn)
	check_sel(sel_a, "ml.on_separate"); check_sel(sel_b, "ml.on_separate"); check_fn(fn, "ml.on_separate")
	hook_separate()
	local entry = { a = sel_a, b = sel_b, fn = mosa.bind(fn, "ml.on_separate handler") }
	function entry.remove()
		for i = #separate_list, 1, -1 do if separate_list[i] == entry then table.remove(separate_list, i) end end
	end
	separate_list[#separate_list + 1] = entry
	return entry
end

--- ml.on_impact(selectorA, selectorB, min_strength, function(a, b, hit) end) -> handle
-- Like on_collision, but judged by how hard Box2D had to push the two apart (hit.strength, an
-- impulse): runs every step in which that reaches min_strength.  Good for "breaks when hit hard".
function ml.on_impact(sel_a, sel_b, min, fn)
	check_sel(sel_a, "ml.on_impact"); check_sel(sel_b, "ml.on_impact"); check_fn(fn, "ml.on_impact")
	if type(min) ~= "number" then error("ml.on_impact: min_strength must be a number", 2) end
	if not impact_hooked then
		impact_hooked = true
		b2.on_post_solve(function(contact, a, b, impulse)
			if a == nil or b == nil then return end
			local strength
			for i = 1, #impact_list do
				local e = impact_list[i]
				local order = pair_order(e, a, b)
				if order then
					strength = strength or b2.impulse_of(impulse)
					if strength >= e.min then
						local hit = hit_info(contact, a, b)
						hit.strength = strength
						local fn2, x, y = e.fn, a, b
						if order == 2 then x, y, hit = b, a, flipped(hit) end
						b2.after_step(function() fn2(x, y, hit) end)
					end
				end
			end
		end)
	end
	local entry = { a = sel_a, b = sel_b, min = min, fn = mosa.bind(fn, "ml.on_impact handler") }
	function entry.remove()
		for i = #impact_list, 1, -1 do if impact_list[i] == entry then table.remove(impact_list, i) end end
	end
	impact_list[#impact_list + 1] = entry
	return entry
end

local filter_list, filter_hooked = {}, false

--- ml.no_collide(selectorA, selectorB) -> handle
-- The two kinds of object no longer collide at all (decided when they first come near each
-- other, so pairs already touching keep colliding until they separate).
function ml.no_collide(sel_a, sel_b)
	check_sel(sel_a, "ml.no_collide"); check_sel(sel_b, "ml.no_collide")
	if not filter_hooked then
		filter_hooked = true
		b2.on_should_collide(function(a, b)
			if a == nil or b == nil then return end
			for i = 1, #filter_list do
				if pair_order(filter_list[i], a, b) then return false end
			end
		end)
	end
	local entry = { a = sel_a, b = sel_b }
	function entry.remove()
		for i = #filter_list, 1, -1 do if filter_list[i] == entry then table.remove(filter_list, i) end end
	end
	filter_list[#filter_list + 1] = entry
	return entry
end

local pass_list, pass_hooked = {}, false

--- ml.pass_through(selectorA, selectorB [, function(a, b, contact) end]) -> handle
-- While the function returns true (always, without one) the two objects go through each
-- other, although they still report collisions.  Asked every step: one-way platforms, ghosts,
-- doors that let only some things pass.
function ml.pass_through(sel_a, sel_b, fn)
	check_sel(sel_a, "ml.pass_through"); check_sel(sel_b, "ml.pass_through")
	if fn ~= nil then check_fn(fn, "ml.pass_through") end
	if not pass_hooked then
		pass_hooked = true
		b2.on_pre_solve(function(contact, a, b)
			if a == nil or b == nil then return end
			for i = 1, #pass_list do
				local e = pass_list[i]
				local order = pair_order(e, a, b)
				if order then
					local yes = true
					if e.fn then
						if order == 1 then yes = e.fn(a, b, contact) else yes = e.fn(b, a, contact) end
					end
					if yes == true then return false end
				end
			end
		end)
	end
	local entry = { a = sel_a, b = sel_b, fn = fn and mosa.bind(fn, "ml.pass_through test") }
	function entry.remove()
		for i = #pass_list, 1, -1 do if pass_list[i] == entry then table.remove(pass_list, i) end end
	end
	pass_list[#pass_list + 1] = entry
	return entry
end

--- ml.ignore(a, b) -- these two objects stop colliding with each other (the game's own list)
function ml.ignore(a, b)
	a.sprite.ignoreCollisionsInsts:push(b)
end

--- ml.touching(inst [, selector]) -> list of the objects it is in physical contact with
function ml.touching(inst, sel)
	local out, seen = {}, {}
	for _, c in ipairs(b2.contacts(inst)) do
		if c.touching then
			local other = c.a
			if other == inst then other = c.b end
			if other ~= nil and not seen[other.uid] and (sel == nil or matches(sel, other)) then
				seen[other.uid] = true
				out[#out + 1] = other
			end
		end
	end
	return out
end

---------------------------------------------------------------- behaviours and custom objects

local attach_update

--- ml.attach(inst, behaviour) -> behaviour
-- Gives one object its own code.  Any of these functions may be present:
--   tick(inst, dt)            every frame, before the physics step
--   collide(inst, other, hit) it started touching another object (see ml.on_collision)
--   separate(inst, other)     it stopped touching it
--   destroy(inst)             it was destroyed
-- The behaviour goes away with the object.  ml.detach(inst [, behaviour]) removes it earlier.
function ml.attach(inst, beh)
	if type(beh) ~= "table" then error("ml.attach needs a table of functions", 2) end
	if inst == nil then error("ml.attach: object is nil", 2) end
	local b = {}
	for _, k in ipairs({ "tick", "collide", "separate", "destroy" }) do
		if beh[k] ~= nil then
			check_fn(beh[k], "ml.attach: " .. k)
			b[k] = mosa.bind(beh[k], "behaviour " .. k)
		end
	end
	b.source = beh
	local uid = inst.uid
	local a = attached[uid]
	if not a then a = { inst = inst, uid = uid, list = {} }; attached[uid] = a end
	a.list[#a.list + 1] = b
	hook_destroy()
	if b.collide then hook_collisions() end
	if b.separate then hook_separate() end
	if b.tick and not attach_update then
		attach_update = add_update(function(dt)
			-- a snapshot in creation order: behaviours may attach, detach, spawn and destroy
			local snap = {}
			for _, att in pairs(attached) do snap[#snap + 1] = att end
			table.sort(snap, function(a, b) return a.uid < b.uid end)
			for n = 1, #snap do
				local att = snap[n]
				local i = att.inst
				if attached[att.uid] == att and i.sprite.destroyed == false then
					local list = att.list
					for k = 1, #list do
						local x = list[k]
						if x and x.tick then x.tick(i, dt) end
					end
				end
			end
		end)
	end
	return beh
end

--- ml.detach(inst [, behaviour]) -- removes one behaviour given to ml.attach, or all of them
function ml.detach(inst, beh)
	local a = attached[inst.uid]
	if not a then return end
	if beh == nil then attached[inst.uid] = nil; return end
	for i = #a.list, 1, -1 do
		if a.list[i].source == beh then table.remove(a.list, i) end
	end
	if #a.list == 0 then attached[inst.uid] = nil end
end

attach_def = function(inst, name, def, opts)
	local uid = inst.uid
	kind_of[uid] = name
	kind_members[name][uid] = inst
	hook_destroy()
	if def.tick or def.collide or def.separate or def.destroy then
		ml.attach(inst, { tick = def.tick, collide = def.collide, separate = def.separate, destroy = def.destroy })
	end
	if def.init then mosa.bind(def.init, "ml.define init")(inst, opts) end
end

--- ml.define("sticky_bomb", { base = "bomb", ... }) -- a new kind of object built on a game type
--   base                     the game object type it is made from (must be spawnable)
--   setup(inst, opts)        before it is added to the level: set the base type's own fields
--   init(inst, opts)         right after it was created: body exists, reshape it, add joints
--   tick / collide / separate / destroy    as in ml.attach
-- ml.spawn("sticky_bomb", x, y, opts) then creates one, and the name works wherever an object
-- type does: ml.instances, ml.count, ml.on_collision, ml.on_destroy, ml.each_frame ...
function ml.define(name, def)
	if type(name) ~= "string" or name == "" or name == "*" then error("ml.define: name must be a non-empty string", 2) end
	if type(def) ~= "table" or type(def.base) ~= "string" then error("ml.define: definition needs base = \"<game object type>\"", 2) end
	local f = factory_map()
	if f ~= nil and f:exists(name) == true then error("ml.define: '" .. name .. "' is already a game object type", 2) end
	for _, k in ipairs({ "setup", "init", "tick", "collide", "separate", "destroy" }) do
		if def[k] ~= nil then check_fn(def[k], "ml.define: " .. k) end
	end
	defs[name] = def
	kind_members[name] = kind_members[name] or {}
	return def
end

mosa.on("ml_layout_end", function()
	-- the objects of the old level are gone with it
	for k in pairs(attached) do attached[k] = nil end
	for k in pairs(kind_of) do kind_of[k] = nil end
	for _, m in pairs(kind_members) do for k in pairs(m) do m[k] = nil end end
end)

---------------------------------------------------------------- the game's own functions as events

local function unref(...)
	local n = select("#", ...)
	if n == 0 then return end
	local t = { ... }
	for i = 1, n do
		local v = t[i]
		if type(v) == "userdata" and hl.typeof(v) == "ref" then t[i] = v.value end
	end
	return table.unpack(t, 1, n)
end

--- ml.game_functions() -> sorted names of the gameplay sheet's named functions
function ml.game_functions()
	local out = {}
	for _, n in ipairs(mosa.find(EV .. ".")) do
		local short = n:sub(#EV + 2)
		if n:sub(1, #EV + 1) == EV .. "." and not short:find("[.:]") then out[#out + 1] = short end
	end
	return out
end

--- ml.on_game("player_death", function(...) end) -> handle
-- Runs after the gameplay sheet's function of that name; the handler gets its arguments
-- (optional numbers arrive as plain values, nil when the game left them out).
function ml.on_game(name, fn)
	check_fn(fn, "ml.on_game")
	if not mosa.hookable(EV .. "." .. name) then error("ml.on_game: the gameplay sheet has no function '" .. tostring(name) .. "' (see ml.game_functions())", 2) end
	fn = mosa.bind(fn, "ml.on_game('" .. name .. "') handler")
	return mosa.after(EV .. "." .. name, function(_, _, ...) fn(unref(...)) end)
end

--- ml.before_game("jump", function(...) end) -> handle
-- Runs before it; `return false` stops the game's function from running at all.
function ml.before_game(name, fn)
	check_fn(fn, "ml.before_game")
	if not mosa.hookable(EV .. "." .. name) then error("ml.before_game: the gameplay sheet has no function '" .. tostring(name) .. "' (see ml.game_functions())", 2) end
	fn = mosa.bind(fn, "ml.before_game('" .. name .. "') handler")
	return mosa.before(EV .. "." .. name, function(_, ...)
		if fn(unref(...)) == false then return mosa.SKIP end
	end)
end

--- ml.on_explosion(function(x, y, radius, power, explosion) end) -- the game made an explosion
function ml.on_explosion(fn)
	check_fn(fn, "ml.on_explosion")
	fn = mosa.bind(fn, "ml.on_explosion handler")
	return hook_if(EV .. ".explosion_fn", "after", function(result, _, radius, x, y, power)
		radius, x, y, power = unref(radius, x, y, power)
		fn(x or 0, y or 0, radius or 0, power or 0, result)
	end, "ml.on_explosion")
end

--- ml.on_player_death(function(player_id) end) -- the game is killing a player (-1: all of them);
-- it then either moves the player back to a checkpoint or removes it.  `return false` prevents it.
function ml.on_player_death(fn)
	check_fn(fn, "ml.on_player_death")
	fn = mosa.bind(fn, "ml.on_player_death handler")
	return hook_if(EV .. ".player_death", "before", function(_, id)
		local pid = unref(id)
		if fn(pid == nil and -1 or pid) == false then return mosa.SKIP end
	end, "ml.on_player_death")
end

--- ml.on_tool_select(function(player, b_item) end) -- the game switched the tool in a player's hand
function ml.on_tool_select(fn)
	check_fn(fn, "ml.on_tool_select")
	fn = mosa.bind(fn, "ml.on_tool_select handler")
	return hook_if(EV .. ".onToolSelect", "after", function(_, _, player, item) fn(player, item) end, "ml.on_tool_select")
end

---------------------------------------------------------------- keyboard and mouse

local KEYS = {
	backspace = 8, tab = 9, enter = 13, shift = 16, ctrl = 17, alt = 18, escape = 27, space = 32,
	pageup = 33, pagedown = 34, ["end"] = 35, home = 36, left = 37, up = 38, right = 39, down = 40,
	insert = 45, delete = 46, mouse_left = 0, mouse_right = 1, mouse_middle = 2,
}
for i = 0, 9 do KEYS[tostring(i)] = 48 + i end
for i = 0, 25 do KEYS[string.char(97 + i)] = 65 + i end
for i = 1, 12 do KEYS["f" .. i] = 111 + i end
ml.keys = KEYS

local Key
local function key_class()
	if Key == nil then
		Key = mosa.class("hxd.Key") or false
		if not Key then warn_once("key", "hxd.Key not found: ml.key_down / key_pressed will always be false") end
	end
	return Key or nil
end

local function key_code(k)
	if type(k) == "number" then return k end
	local c = KEYS[tostring(k):lower()]
	if not c then error("unknown key '" .. tostring(k) .. "' (use a name from ml.keys or a key code)", 3) end
	return c
end

-- Inside a level's frame the keyboard is read once, when the frame starts, for the keys mods
-- have asked about: every piece of mod code in that frame gets the same answer, "pressed" means
-- "down in this frame and not in the one before", and what was read is written down next to
-- the game's own input recording.  When the game plays a level again to save a GIF, mods are
-- given those answers back, so they do in the replay what they did in the level.
-- Outside a level's frame (mosa.on("tick"), menus) the keyboard is asked directly.
local watched = {}                       -- key code -> true, once a mod asked about it in a level frame
local key_now, key_prev = {}, {}         -- what was read for the current frame / the one before
local in_frame, frame_no = false, 0      -- inside Layout.update of the running layout; its tick when it began
local recording                          -- { layout =, events = { [frame] = { code, now, prev, ... } }, fresh = }
local gif_recording                      -- the recording that belongs to the attempt the game can export
local playback                           -- while a GIF is rendered: { events =, now = {}, prev = {} }

local function note(frame, code, now, prev)
	local r = recording
	if not r then return end
	local e = r.events[frame]
	if not e then e = {}; r.events[frame] = e end
	e[#e + 1] = code; e[#e + 1] = now; e[#e + 1] = prev
end

begin_frame = function(layout)
	in_frame, frame_no = true, layout.currentTick or 0
	if playback then
		local now, prev = playback.now, playback.prev
		for code, v in pairs(now) do prev[code] = v end
		local e = playback.events[frame_no]
		if e then
			for i = 1, #e, 3 do now[e[i]], prev[e[i]] = e[i + 1], e[i + 2] end
		end
		return
	end
	local K = key_class()
	if K == nil then return end
	local r = recording
	if r and r.layout ~= layout then r = nil end
	local all = r and r.fresh
	if all then r.fresh = false end
	for code in pairs(watched) do
		local was = key_now[code] == true
		local is = K.isDown(code) == true
		key_prev[code], key_now[code] = was, is
		if r and (all or is ~= was) then note(frame_no, code, is, was) end
	end
end

hook_if("fish.system.Layout.update", "after", function(_, layout)
	if layout == ml.layout then in_frame = false end
end, "telling a level's frame from the rest (keyboard)")

-- now, prev for a key code, as the current frame sees it
local function key_state(code)
	if playback then return playback.now[code] == true, playback.prev[code] == true end
	if not watched[code] then
		-- first question about this key: read it now, and take "pressed" from the engine once
		watched[code] = true
		local K = key_class()
		local is = K ~= nil and K.isDown(code) == true
		local was = is and not (K.isPressed(code) == true)
		key_now[code], key_prev[code] = is, was
		if recording and recording.layout == ml.layout then note(frame_no, code, is, was) end
	end
	return key_now[code] == true, key_prev[code] == true
end

--- ml.key_down("space") -> held right now       names: a-z, 0-9, f1-f12, space, enter, left ...
--- ml.key_pressed("e")  -> went down this frame  mouse_left / mouse_right / mouse_middle, or a key code
--- ml.key_released("e") -> went up this frame
function ml.key_down(k)
	local c = key_code(k)
	if in_frame or playback then return (key_state(c)) end
	local K = key_class()
	return K ~= nil and K.isDown(c) == true
end
function ml.key_pressed(k)
	local c = key_code(k)
	if in_frame or playback then
		local now, prev = key_state(c)
		return now and not prev
	end
	local K = key_class()
	return K ~= nil and K.isPressed(c) == true
end
function ml.key_released(k)
	local c = key_code(k)
	if in_frame or playback then
		local now, prev = key_state(c)
		return prev and not now
	end
	local K = key_class()
	return K ~= nil and K.isReleased(c) == true
end

--- ml.on_key("g", function() end) -> handle   runs once each time the key goes down during a level
function ml.on_key(k, fn)
	check_fn(fn, "ml.on_key")
	local c = key_code(k)
	fn = mosa.bind(fn, "ml.on_key handler")
	return add_update(function()
		if ml.key_pressed(c) then fn() end
	end)
end

---------------------------------------------------------------- GIF replays

-- Saving a GIF does not show what happened: the game plays the level again, in one go, in a
-- private copy of itself (Main.saveGif: a "detached" Game, the level's saved start state, the
-- recorded inputs) and films that.  For the film to show what mods did, they have to do it
-- again.  So for the time of that replay ml simply follows the copy: ml.layout, ml.game and
-- ml.ev are the replay's, ml.on_level runs when it starts and ml.on_level_end when it is over,
-- per-frame handlers, collisions, timers and the gravity scale work in it, and the keys are
-- the ones that were pressed in the level.  Afterwards everything points at the real game
-- again, with the level's own timers, behaviours and object kinds as they were.
-- What cannot be replayed: math.random, the clock, and anything a mod did outside a level's
-- frame (mosa.on("tick"), mosa.delay): keep gameplay in ml.on_update and the ml events.

--- ml.replaying() -> true while the game is playing a level again to save a GIF
function ml.replaying() return in_replay end

local level_vars = {}                    -- mod name -> table, for the level being simulated

--- ml.vars() -> a table for your mod's own per-level variables.  It is empty when a level
-- starts and belongs to that run of the level only: a GIF replay gets its own, and the level
-- being played finds its table untouched afterwards.  (Plain local variables are shared by both.)
function ml.vars()
	local mod = mosa.current_mod()
	local key = mod and mod.name or "?"
	local t = level_vars[key]
	if not t then t = {}; level_vars[key] = t end
	return t
end

mosa.on("ml_layout_end", function() level_vars = {} end)

local function fresh_kinds()
	local t = {}
	for name in pairs(defs) do t[name] = {} end
	return t
end

local function swap_level_state(to)
	local was = {
		layout = ml.layout, game = ml.game, ev = ml.ev, started = started, previous = previous,
		previous_frames = previous_frames, timers = level_timers, attached = attached, kind_of = kind_of,
		kind_members = kind_members, gravity_of = gravity_of, gravity_insts = gravity_insts,
		in_frame = in_frame, frame_no = frame_no, vars = level_vars,
	}
	ml.layout, ml.game, ml.ev = to.layout, to.game, to.ev
	started, previous, previous_frames = to.started or false, to.previous, to.previous_frames or 0
	level_timers, attached, kind_of = to.timers or {}, to.attached or {}, to.kind_of or {}
	kind_members = to.kind_members or fresh_kinds()
	gravity_of, gravity_insts = to.gravity_of or {}, to.gravity_insts or {}
	in_frame, frame_no = to.in_frame or false, to.frame_no or 0
	level_vars = to.vars or {}
	factor_tick = -1
	return was
end

hook_if("fish.system.Main.saveGif", "hook", function(orig, self)
	if in_replay then return orig(self) end
	local live = swap_level_state({ game = ml.game, ev = ml.ev })
	in_replay = true
	playback = { events = gif_recording and gif_recording.events or {}, now = {}, prev = {} }
	local ok, err = pcall(orig, self)
	-- the replayed level is over: mods clean up what they made in it
	if ml.layout ~= nil and started then pcall(mosa.emit, "ml_layout_end", ml.layout) end
	in_replay, playback = false, nil
	swap_level_state(live)
	if not ok then error(err, 0) end
end, "mods taking part in GIF replays")

-- the game starts a new input recording when a level is set up ...
hook_if("fish.system.Replay.record", "after", function()
	if in_replay then return end
	recording = { layout = ml.layout, events = {}, fresh = true }
end, "recording the keys mods use (GIF replays)")

-- ... and puts the attempt aside for export when the level is left (or when a GIF of the
-- level in progress is asked for)
hook_if("fish.system.Main.copyGifState", "after", function()
	local r = recording
	local events = {}
	if r then
		for frame, e in pairs(r.events) do
			local c = {}
			for i = 1, #e do c[i] = e[i] end
			events[frame] = c
		end
	end
	gif_recording = r and { events = events } or nil
	-- a GIF of the level in progress: saveGif takes the attempt so far at its very start, when
	-- the replay is already being set up; these are the keys that belong to it
	if playback then playback.events = events end
end, "recording the keys mods use (GIF replays)")

---------------------------------------------------------------- start

local nspawn = #ml.spawnable()
ml.version = "1.4.0"          -- of these Lua layers (mosa.version is the runtime in mosalua.hdll)
hl.log("[ml] Mosa Lina API " .. ml.version .. " loaded (" .. nspawn .. " spawnable object types)")
