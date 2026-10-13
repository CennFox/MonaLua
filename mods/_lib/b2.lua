-- b2.lua -- Box2D for Mosa Lina mods.  Loaded before every mod.
--
-- Mosa Lina's physics is Box2D 2.3 (double precision), reached through 126 native functions
-- in fish.hdll.  The patcher makes every one of them callable and hookable from Lua:
--
--   b2.raw.<name>(...)                 the native itself, Box2D units (metres, radians)
--   mosa.hook("fish@<name>", fn)       hook it like any game function
--
-- Everything else in this file is a friendlier layer over those natives that speaks the
-- game's units: pixels, degrees, y pointing down.  Forces, impulses, torques and masses
-- stay in Box2D units, as in the game's own physics code.
--
-- "thing" below means: a game object (instance), its physics behaviour, a b2Body or a
-- b2Fixture.  Bodies, fixtures, joints and contacts are raw pointers into the physics
-- library: use them and let go.  Keep the game object instead and ask again next frame.
--
-- Tested against real Box2D behind the same native signatures (tests/fish); the game's own
-- fish.hdll has not been run with it yet.

local b2 = {}
_G.b2 = b2

local typeof, ptr = hl.typeof, hl.ptr
local sqrt, rad, deg, cos, sin, huge = math.sqrt, math.rad, math.deg, math.cos, math.sin, math.huge

-- state that survives a mod reload (the physics world does not restart when mods do)
local state = rawget(_G, "__b2_state")
if not state then
	state = { gravity = {}, bodies = {}, joints = {}, locked = 0 }
	rawset(_G, "__b2_state", state)
end

---------------------------------------------------------------- raw natives

--- b2.raw.body_get_angle(body) ...  every native of the physics library, by its name
local raw = setmetatable({}, { __index = function(t, k)
	local f = mosa.native("fish@" .. k)
	if not f then error("the game has no physics native 'fish@" .. tostring(k) .. "' (was it patched with Lua support?)", 2) end
	rawset(t, k, f)
	return f
end })
b2.raw = raw

--- b2.available() -> true when the physics natives can be reached
function b2.available() return mosa.native("fish@create_world") ~= nil end

--- b2.has("world_query_aabb") -> true when the game has that native
function b2.has(name) return mosa.native("fish@" .. name) ~= nil end

---------------------------------------------------------------- world and units

local use_world, use_scale        -- set by b2.use()

local function cur_layout()
	local m = rawget(_G, "ml")
	return m and m.layout or nil
end

--- b2.world() -> the b2World of the running level (nil when there is none)
function b2.world()
	if use_world then return use_world end
	local l = cur_layout()
	return l and l.world or nil
end

--- b2.scale() -> metres per pixel (the level's worldScale)
function b2.scale()
	if use_scale then return use_scale end
	local l = cur_layout()
	return l and l.worldScale or 0.02
end

--- b2.use(world, metres_per_pixel) -- work on another world; b2.use() goes back to the level's
function b2.use(world, scale)
	use_world, use_scale = world, scale
end

local function need_world(what)
	local w = b2.world()
	if not w then error(what .. ": no physics world yet (no level is running)", 3) end
	return w
end

--- b2.locked() -> true while Box2D is stepping (inside contact callbacks).  Bodies, fixtures
-- and joints cannot be created or destroyed then: use b2.after_step.
function b2.locked() return state.locked > 0 end

local after = {}

--- b2.after_step(fn) -- run fn as soon as the current physics step is over (at once when no step is running)
function b2.after_step(fn)
	if type(fn) ~= "function" then error("b2.after_step needs a function", 2) end
	fn = mosa.bind(fn, "b2.after_step")
	if state.locked > 0 then after[#after + 1] = fn else fn() end
end

local function unlocked(what)
	if state.locked > 0 then
		error(what .. ": the physics world is being stepped (you are inside a contact callback); wrap this in b2.after_step(function() ... end)", 3)
	end
end

if mosa.hookable("fish@world_step") then
	mosa.hook("fish@world_step", function(orig, world, dt, vel_it, pos_it)
		state.locked = state.locked + 1
		local ok, err = pcall(orig, world, dt, vel_it, pos_it)
		state.locked = state.locked - 1
		if state.locked == 0 and #after > 0 then
			local list = after
			after = {}
			for i = 1, #list do list[i]() end
		end
		if not ok then error(err, 0) end
	end, { priority = -100 })
end

-- gravity cannot be read back from the library, so it is remembered as it is set
if mosa.hookable("fish@create_world") then
	mosa.after("fish@create_world", function(world, gx, gy)
		if world ~= nil then state.gravity[ptr(world)] = { gx, gy } end
	end)
	mosa.before("fish@world_set_gravity", function(world, g)
		if world ~= nil and g ~= nil then state.gravity[ptr(world)] = { g.x, g.y } end
	end)
end

--- b2.gravity() -> gx, gy of the world itself, in Box2D units.  The game creates its worlds
-- with (0, 10) and sets them to (0, 0) when a level starts: it applies every object's weight
-- itself (ml.weight, ml.gravity, ml.set_gravity_scale).
function b2.gravity()
	local w = b2.world()
	local g = w and state.gravity[ptr(w)]
	if g then return g[1], g[2] end
	return 0, 10
end

--- b2.set_gravity(gx, gy) -- the world's own gravity: acts on every dynamic body, on top of
-- the weight the game gives its objects
function b2.set_gravity(gx, gy)
	raw.world_set_gravity(need_world("b2.set_gravity"), { gx, gy })
end

---------------------------------------------------------------- finding bodies

local function body_of(x)
	local kind, name = typeof(x)
	if kind == "abstract" then
		if name == "b2Body" then return x end
		if name == "b2Fixture" then return raw.fixture_get_body(x) end
	elseif kind == "obj" then
		local ph = x.physics
		if ph == nil then ph = x end
		local ok, b = pcall(function() return ph.body end)
		if ok and b ~= nil then return b end
	end
	return nil
end

local function need_body(x, what)
	local b = body_of(x)
	if b == nil then
		local kind, name = typeof(x)
		if kind == "obj" then
			local t = x.type
			error(what .. ": this " .. tostring(t or name) .. " has no physics body", 3)
		end
		error(what .. ": expected a game object, a b2Body or a b2Fixture, got " .. tostring(kind or type(x)), 3)
	end
	return b
end

--- b2.body(thing) -> its b2Body, or nil when it has none
b2.body = body_of

--- b2.owner(fixture) -> the game object that fixture belongs to (its user data), or nil
function b2.owner(fixture) return raw.fixture_get_user_data(fixture) end

--- b2.instance(thing) -> the game object a body or fixture belongs to, or nil
function b2.instance(x)
	local kind, name = typeof(x)
	if kind == "abstract" and name == "b2Fixture" then return raw.fixture_get_user_data(x) end
	local body = body_of(x)
	if body == nil then return nil end
	local f = raw.body_get_fixture_list(body)
	while f ~= nil do
		local o = raw.fixture_get_user_data(f)
		if o ~= nil then return o end
		f = raw.fixture_get_next(f)
	end
	return nil
end

--- b2.bodies() -> list of every b2Body in the world
function b2.bodies()
	local out = {}
	local w = b2.world()
	if not w then return out end
	local b = raw.world_get_body_list(w)
	while b ~= nil do
		out[#out + 1] = b
		b = raw.body_get_next(b)
	end
	return out
end

---------------------------------------------------------------- position and motion

local TYPE_NAMES = { [0] = "static", [1] = "kinematic", [2] = "dynamic" }
local TYPE_IDS = { static = 0, kinematic = 1, dynamic = 2 }

--- b2.position(thing) -> x, y in pixels (the body origin: the sprite position for game objects)
function b2.position(x)
	local p = raw.body_get_position(need_body(x, "b2.position"))
	local inv = 1 / b2.scale()
	return p.x * inv, p.y * inv
end

--- b2.set_position(thing, x, y [, degrees]) -- teleports the body; keeps its angle unless given
function b2.set_position(x, px, py, angle)
	local body = need_body(x, "b2.set_position")
	local s = b2.scale()
	raw.body_set_transform(body, { px * s, py * s }, angle and rad(angle) or raw.body_get_angle(body))
end

--- b2.angle(thing) -> degrees           b2.set_angle(thing, degrees)
function b2.angle(x) return deg(raw.body_get_angle(need_body(x, "b2.angle"))) end
function b2.set_angle(x, angle)
	local body = need_body(x, "b2.set_angle")
	local p = raw.body_get_position(body)
	raw.body_set_transform(body, { p.x, p.y }, rad(angle))
end

--- b2.velocity(thing) -> vx, vy in pixels per second
function b2.velocity(x)
	local v = raw.body_get_linear_velocity(need_body(x, "b2.velocity"))
	local inv = 1 / b2.scale()
	return v.x * inv, v.y * inv
end

--- b2.set_velocity(thing, vx, vy)
function b2.set_velocity(x, vx, vy)
	local s = b2.scale()
	raw.body_set_linear_velocity(need_body(x, "b2.set_velocity"), { vx * s, vy * s })
end

--- b2.speed(thing) -> pixels per second
function b2.speed(x)
	local vx, vy = b2.velocity(x)
	return sqrt(vx * vx + vy * vy)
end

--- b2.velocity_at(thing, x, y) -> velocity of the body at a world point (spin included)
function b2.velocity_at(x, px, py)
	local s = b2.scale()
	local v = raw.body_get_linear_velocity_from_world_point(need_body(x, "b2.velocity_at"), { px * s, py * s })
	return v.x / s, v.y / s
end

--- b2.angular_velocity(thing) -> degrees per second      b2.set_angular_velocity(thing, dps)
function b2.angular_velocity(x) return deg(raw.body_get_angular_velocity(need_body(x, "b2.angular_velocity"))) end
function b2.set_angular_velocity(x, v)
	raw.body_set_angular_velocity(need_body(x, "b2.set_angular_velocity"), rad(v))
end

--- b2.center(thing) -> x, y of the centre of mass in pixels
function b2.center(x)
	local p = raw.body_get_world_center(need_body(x, "b2.center"))
	local inv = 1 / b2.scale()
	return p.x * inv, p.y * inv
end

--- b2.world_point(thing, lx, ly) -> a point given relative to the body, in level coordinates
function b2.world_point(x, lx, ly)
	local s = b2.scale()
	local p = raw.body_get_world_point(need_body(x, "b2.world_point"), { lx * s, ly * s })
	return p.x / s, p.y / s
end

--- b2.local_point(thing, x, y) -> a level point relative to the body (rotation undone)
function b2.local_point(x, px, py)
	local s = b2.scale()
	local p = raw.body_get_local_point(need_body(x, "b2.local_point"), { px * s, py * s })
	return p.x / s, p.y / s
end

--- b2.world_vector(thing, lx, ly) / b2.local_vector(thing, x, y) -- directions instead of points
function b2.world_vector(x, lx, ly)
	local p = raw.body_get_world_vector(need_body(x, "b2.world_vector"), { lx, ly })
	return p.x, p.y
end
function b2.local_vector(x, vx, vy)
	local p = raw.body_get_local_vector(need_body(x, "b2.local_vector"), { vx, vy })
	return p.x, p.y
end

---------------------------------------------------------------- forces

local function at_point(body, px, py)
	if px == nil then
		local c = raw.body_get_world_center(body)
		return { c.x, c.y }
	end
	local s = b2.scale()
	return { px * s, py * s }
end

--- b2.impulse(thing, ix, iy [, x, y]) -- instant shove at a level point (centre of mass by default)
-- Box2D units, like the game's own applyImpulse: velocity changes by impulse / mass.
function b2.impulse(x, ix, iy, px, py)
	local body = need_body(x, "b2.impulse")
	raw.body_apply_linear_impulse(body, { ix, iy }, at_point(body, px, py), true)
end

--- b2.force(thing, fx, fy [, x, y]) -- continuous push; call it every frame while it should act
function b2.force(x, fx, fy, px, py)
	local body = need_body(x, "b2.force")
	raw.body_apply_force(body, { fx, fy }, at_point(body, px, py), true)
end

--- b2.push(thing, degrees, strength) -- impulse in a direction: 0 right, 90 down, -90 up
function b2.push(x, angle, strength)
	local a = rad(angle)
	b2.impulse(x, cos(a) * strength, sin(a) * strength)
end

--- b2.launch(thing, vx, vy) -- changes the velocity by (vx, vy) pixels/second whatever the mass
function b2.launch(x, vx, vy)
	local body = need_body(x, "b2.launch")
	local s, m = b2.scale(), raw.body_get_mass(body)
	local c = raw.body_get_world_center(body)
	raw.body_apply_linear_impulse(body, { vx * s * m, vy * s * m }, { c.x, c.y }, true)
end

--- b2.torque(thing, t) -- continuous twist      b2.angular_impulse(thing, i) -- instant twist
function b2.torque(x, t) raw.body_apply_torque(need_body(x, "b2.torque"), t, true) end
function b2.angular_impulse(x, i) raw.body_apply_angular_impulse(need_body(x, "b2.angular_impulse"), i, true) end

---------------------------------------------------------------- body properties

--- b2.mass(thing) -> kilograms (0 for static bodies)      b2.inertia(thing)
function b2.mass(x) return raw.body_get_mass(need_body(x, "b2.mass")) end
function b2.inertia(x) return raw.body_get_inertia(need_body(x, "b2.inertia")) end

--- b2.set_mass(thing, kg) -- overrides the mass computed from the fixtures (rotation inertia scales along)
function b2.set_mass(x, mass)
	local body = need_body(x, "b2.set_mass")
	local md = mosa.new("hlfish.box2d.B2MassData")
	raw.body_get_mass_data(body, md)
	local old = md.mass
	md.I = old > 0 and md.I * (mass / old) or mass
	md.mass = mass
	raw.body_set_mass_data(body, md)
	-- the game recomputes the mass when an object is resized unless it is told not to
	if typeof(x) == "obj" then pcall(function() (x.physics or x).fixedMass = true end) end
end

--- b2.type(thing) -> "static" | "kinematic" | "dynamic"
function b2.type(x) return TYPE_NAMES[raw.body_get_type(need_body(x, "b2.type"))] end

--- b2.set_type(thing, "static" | "kinematic" | "dynamic")
-- static: never moves (level terrain).  kinematic: moves at the velocity you set, unaffected by
-- forces and collisions (moving platforms).  dynamic: a normal physical object.
function b2.set_type(x, name)
	local id = TYPE_IDS[name]
	if not id then error("b2.set_type: type must be 'static', 'kinematic' or 'dynamic'", 2) end
	unlocked("b2.set_type")
	raw.body_set_type(need_body(x, "b2.set_type"), id)
end

--- b2.gravity_scale(thing) -> factor      b2.set_gravity_scale(thing, f)   0 floats, -1 falls up
function b2.gravity_scale(x) return raw.body_get_gravity_scale(need_body(x, "b2.gravity_scale")) end
function b2.set_gravity_scale(x, f)
	raw.body_set_gravity_scale(need_body(x, "b2.set_gravity_scale"), f)
end

--- b2.damping(thing) -> linear, angular      b2.set_damping(thing, linear [, angular])  (air drag)
function b2.damping(x)
	local body = need_body(x, "b2.damping")
	return raw.body_get_linear_damping(body), raw.body_get_angular_damping(body)
end
function b2.set_damping(x, linear, angular)
	local body = need_body(x, "b2.set_damping")
	if linear then raw.body_set_linear_damping(body, linear) end
	if angular then raw.body_set_angular_damping(body, angular) end
end

--- b2.bullet(thing) / b2.set_bullet(thing, on)   continuous collision for fast small objects
function b2.bullet(x) return raw.body_is_bullet(need_body(x, "b2.bullet")) end
function b2.set_bullet(x, on) raw.body_set_bullet(need_body(x, "b2.set_bullet"), on ~= false) end

--- b2.fixed_rotation(thing) / b2.set_fixed_rotation(thing, on)   the body never rotates
function b2.fixed_rotation(x) return raw.body_is_fixed_rotation(need_body(x, "b2.fixed_rotation")) end
function b2.set_fixed_rotation(x, on) raw.body_set_fixed_rotation(need_body(x, "b2.set_fixed_rotation"), on ~= false) end

--- b2.active(thing) / b2.set_active(thing, on)   an inactive body takes no part in the simulation
function b2.active(x) return raw.body_is_active(need_body(x, "b2.active")) end
function b2.set_active(x, on)
	unlocked("b2.set_active")
	raw.body_set_active(need_body(x, "b2.set_active"), on ~= false)
end

--- b2.awake(thing) / b2.wake(thing)   (the game switches sleeping off for its worlds: bodies stay awake)
function b2.awake(x) return raw.body_is_awake(need_body(x, "b2.awake")) end
function b2.wake(x) raw.body_set_awake(need_body(x, "b2.wake"), true) end

---------------------------------------------------------------- fixtures and shapes

local guard_installed = false

-- The game's own pre/post-solve handlers expect every fixture to carry a game object.
-- Fixtures created here without an owner would crash them, so those contacts skip the handlers.
local function install_guard()
	if guard_installed then return end
	guard_installed = true
	for _, name in ipairs({ "fish.system.ContactListener.preSolve", "fish.system.ContactListener.postSolve" }) do
		if mosa.hookable(name) then
			mosa.hook(name, function(orig, contact, data)
				if raw.fixture_get_user_data(raw.contact_get_fixture_a(contact)) == nil
					or raw.fixture_get_user_data(raw.contact_get_fixture_b(contact)) == nil then
					return
				end
				return orig(contact, data)
			end, { priority = -50 })
		end
	end
end

local function fixture_list(x, what)
	local kind, name = typeof(x)
	if kind == "abstract" and name == "b2Fixture" then return { x } end
	local out = {}
	local f = raw.body_get_fixture_list(need_body(x, what))
	while f ~= nil do
		out[#out + 1] = f
		f = raw.fixture_get_next(f)
	end
	return out
end

--- b2.fixtures(thing) -> list of its b2Fixtures (the collision shapes attached to the body)
function b2.fixtures(x) return fixture_list(x, "b2.fixtures") end

local function first_fixture(x, what)
	local kind, name = typeof(x)
	if kind == "abstract" and name == "b2Fixture" then return x end
	local f = raw.body_get_fixture_list(need_body(x, what))
	if f == nil then error(what .. ": the body has no fixtures", 3) end
	return f
end

--- b2.density(thing) b2.friction(thing) b2.restitution(thing) b2.is_sensor(thing)
-- of a fixture, or of the first fixture of a body
function b2.density(x) return raw.fixture_get_density(first_fixture(x, "b2.density")) end
function b2.friction(x) return raw.fixture_get_friction(first_fixture(x, "b2.friction")) end
function b2.restitution(x) return raw.fixture_get_restitution(first_fixture(x, "b2.restitution")) end
function b2.is_sensor(x) return raw.fixture_is_sensor(first_fixture(x, "b2.is_sensor")) end

--- b2.set_density(thing, d) -- every fixture of the body (or one fixture); the mass follows
function b2.set_density(x, d)
	local body
	for _, f in ipairs(fixture_list(x, "b2.set_density")) do
		raw.fixture_set_density(f, d)
		body = raw.fixture_get_body(f)
	end
	if body ~= nil then raw.body_reset_mass_data(body) end
end

--- b2.set_friction(thing, f)   0 = ice, 1 = rubber
function b2.set_friction(x, v)
	for _, f in ipairs(fixture_list(x, "b2.set_friction")) do raw.fixture_set_friction(f, v) end
end

--- b2.set_restitution(thing, r)   bounciness: 0 = none, 1 = keeps all its speed
function b2.set_restitution(x, v)
	for _, f in ipairs(fixture_list(x, "b2.set_restitution")) do raw.fixture_set_restitution(f, v) end
end

--- b2.set_sensor(thing, on) -- a sensor detects overlaps (contact events) but collides with nothing
function b2.set_sensor(x, on)
	for _, f in ipairs(fixture_list(x, "b2.set_sensor")) do raw.fixture_set_sensor(f, on ~= false) end
end

local VEC = "hxmath.math.Vector2Default"
local scratch_poly      -- never attached: its vertex buffer carries points into polygon_shape_set

local function fixture_def(body, shape, opts, what)
	local def = mosa.new("hlfish.box2d.B2FixtureDef")
	def.shape = shape
	def.density = opts.density or 1
	def.friction = opts.friction or 0.3
	def.restitution = opts.restitution or 0
	def.isSensor = opts.sensor == true
	local owner = opts.owner
	if owner == nil then owner = b2.instance(body) end
	if owner ~= nil then def.userData = owner else install_guard() end
	local f = raw.body_create_fixture(body, def)
	if f == nil then error(what .. ": the physics library refused the fixture", 3) end
	return f
end

-- Box2D turns a bad polygon into a 1 x 1 metre box (or stops the game in a debug build),
-- so the corners are checked here first: merged when closer than Box2D can tell apart,
-- reduced to their convex outline, and refused when no area is left.
local function convex_outline(points, s, what)
	local n = #points // 2
	if #points % 2 ~= 0 or n < 3 then error(what .. ": points must be { x1, y1, x2, y2, x3, y3, ... } with at least 3 corners", 4) end
	local pts = {}
	for i = 0, n - 1 do
		local x, y = points[i * 2 + 1], points[i * 2 + 2]
		if type(x) ~= "number" or type(y) ~= "number" then error(what .. ": corner " .. (i + 1) .. " is not a pair of numbers", 4) end
		x, y = x * s, y * s
		local dup = false
		for _, q in ipairs(pts) do
			if (q[1] - x) ^ 2 + (q[2] - y) ^ 2 < 0.0025 ^ 2 then dup = true; break end
		end
		if not dup then pts[#pts + 1] = { x, y } end
	end
	table.sort(pts, function(a, b) if a[1] ~= b[1] then return a[1] < b[1] end return a[2] < b[2] end)
	local function cross(o, a, b) return (a[1] - o[1]) * (b[2] - o[2]) - (a[2] - o[2]) * (b[1] - o[1]) end
	local hull = {}
	for i = 1, #pts do
		while #hull >= 2 and cross(hull[#hull - 1], hull[#hull], pts[i]) <= 1e-12 do hull[#hull] = nil end
		hull[#hull + 1] = pts[i]
	end
	local lower = #hull + 1
	for i = #pts - 1, 1, -1 do
		while #hull >= lower and cross(hull[#hull - 1], hull[#hull], pts[i]) <= 1e-12 do hull[#hull] = nil end
		hull[#hull + 1] = pts[i]
	end
	hull[#hull] = nil
	local area = 0
	for i = 1, #hull do
		local p, q = hull[i], hull[i % #hull + 1]
		area = area + p[1] * q[2] - q[1] * p[2]
	end
	if #hull < 3 or math.abs(area) / 2 < 1e-5 then error(what .. ": the corners do not enclose an area", 4) end
	if #hull > 16 then error(what .. ": a polygon can have at most 16 corners (split the shape into several fixtures)", 4) end
	return hull
end

local function make_polygon(points, s, what)
	local hull = convex_outline(points, s, what)
	scratch_poly = scratch_poly or raw.create_polygon_shape()
	local buf = scratch_poly.m_vertices
	for i, p in ipairs(hull) do
		local v = hl.celem(buf, VEC, i - 1)
		v.x, v.y = p[1], p[2]
	end
	local shape = raw.create_polygon_shape()
	raw.polygon_shape_set(shape, buf, #hull)
	return shape
end

--- b2.add_box(thing, width, height [, opts]) -> fixture
-- Adds a box to the body.  opts: x, y (centre offset from the body origin, pixels), angle
-- (degrees), density (1), friction (0.3), restitution (0), sensor (false), owner (the game
-- object contact events report; default: the object the body already belongs to).
function b2.add_box(x, w, h, opts)
	unlocked("b2.add_box")
	opts = opts or {}
	local body = need_body(x, "b2.add_box")
	local cx, cy, hw, hh = opts.x or 0, opts.y or 0, w / 2, h / 2
	local a = rad(opts.angle or 0)
	local ca, sa = cos(a), sin(a)
	local pts = {}
	for i, c in ipairs({ { -hw, -hh }, { hw, -hh }, { hw, hh }, { -hw, hh } }) do
		pts[i * 2 - 1] = cx + c[1] * ca - c[2] * sa
		pts[i * 2] = cy + c[1] * sa + c[2] * ca
	end
	return fixture_def(body, make_polygon(pts, b2.scale(), "b2.add_box"), opts, "b2.add_box")
end

--- b2.add_circle(thing, radius [, opts]) -> fixture      opts as for add_box (x, y = centre offset)
function b2.add_circle(x, radius, opts)
	unlocked("b2.add_circle")
	opts = opts or {}
	local body = need_body(x, "b2.add_circle")
	local s = b2.scale()
	local shape = raw.create_circle_shape()
	shape.m_radius = radius * s
	local p = shape.m_p
	p.x, p.y = (opts.x or 0) * s, (opts.y or 0) * s
	return fixture_def(body, shape, opts, "b2.add_circle")
end

--- b2.add_polygon(thing, { x1, y1, x2, y2, ... } [, opts]) -> fixture
-- A convex polygon of 3 to 16 corners, relative to the body origin, in pixels.
function b2.add_polygon(x, points, opts)
	unlocked("b2.add_polygon")
	local body = need_body(x, "b2.add_polygon")
	return fixture_def(body, make_polygon(points, b2.scale(), "b2.add_polygon"), opts or {}, "b2.add_polygon")
end

--- b2.remove_fixture(fixture)
function b2.remove_fixture(fixture)
	unlocked("b2.remove_fixture")
	local kind, name = typeof(fixture)
	if kind ~= "abstract" or name ~= "b2Fixture" then error("b2.remove_fixture: expected a b2Fixture", 2) end
	raw.body_destroy_fixture(raw.fixture_get_body(fixture), fixture)
end

--- b2.shape(fixture_or_thing) -> { type = "circle", radius =, x =, y = }  or
--                               { type = "polygon", points = { x1, y1, ... } }   (pixels, body-relative)
function b2.shape(x)
	local shape = raw.fixture_get_shape(first_fixture(x, "b2.shape"))
	local inv = 1 / b2.scale()
	if shape.m_type == 0 then
		local c = raw.shape_to_circle_shape(shape)
		return { type = "circle", radius = c.m_radius * inv, x = c.m_p.x * inv, y = c.m_p.y * inv }
	elseif shape.m_type == 2 then
		local p = raw.shape_to_polygon_shape(shape)
		local pts, buf = {}, p.m_vertices
		for i = 0, p.m_count - 1 do
			local v = hl.celem(buf, VEC, i)
			pts[#pts + 1] = v.x * inv
			pts[#pts + 1] = v.y * inv
		end
		return { type = "polygon", points = pts }
	end
	return { type = "other", id = shape.m_type }
end

--- b2.aabb(thing) -> x1, y1, x2, y2: the bounding box of all its fixtures, in pixels
function b2.aabb(x)
	local body = need_body(x, "b2.aabb")
	local xf = raw.body_get_transform(body)
	local box = mosa.new("hlfish.box2d.B2AABB")
	local x1, y1, x2, y2 = huge, huge, -huge, -huge
	local f = raw.body_get_fixture_list(body)
	while f ~= nil do
		raw.shape_compute_AABB(raw.fixture_get_shape(f), box, xf, 0)
		local lo, hi = box.lowerBound, box.upperBound
		if lo.x < x1 then x1 = lo.x end
		if lo.y < y1 then y1 = lo.y end
		if hi.x > x2 then x2 = hi.x end
		if hi.y > y2 then y2 = hi.y end
		f = raw.fixture_get_next(f)
	end
	if x1 == huge then return nil end
	local inv = 1 / b2.scale()
	return x1 * inv, y1 * inv, x2 * inv, y2 * inv
end

---------------------------------------------------------------- bodies without a game object

--- b2.create_body{ ... } -> b2Body
-- A bare body: nothing draws it and the game does not know it.  Usually you want
-- ml.spawn(...) and then reshape that object instead.  Fields (all optional):
--   type ("dynamic"), x, y, angle, vx, vy, angular_velocity, linear_damping, angular_damping,
--   fixed_rotation, bullet, gravity_scale, active
-- Add shapes with b2.add_box / add_circle / add_polygon.  It is gone when the level ends.
function b2.create_body(opts)
	unlocked("b2.create_body")
	opts = opts or {}
	local world = need_world("b2.create_body")
	local s = b2.scale()
	local def = mosa.new("hlfish.box2d.B2BodyDef")
	local id = TYPE_IDS[opts.type or "dynamic"]
	if not id then error("b2.create_body: type must be 'static', 'kinematic' or 'dynamic'", 2) end
	def.type = id
	def.position = { (opts.x or 0) * s, (opts.y or 0) * s }
	def.angle = rad(opts.angle or 0)
	def.linearVelocity = { (opts.vx or 0) * s, (opts.vy or 0) * s }
	def.angularVelocity = rad(opts.angular_velocity or 0)
	def.linearDamping = opts.linear_damping or 0
	def.angularDamping = opts.angular_damping or 0
	def.fixedRotation = opts.fixed_rotation == true
	def.bullet = opts.bullet == true
	def.gravityScale = opts.gravity_scale or 1
	def.active = opts.active ~= false
	local body = raw.world_create_body(world, def)
	if body == nil then error("b2.create_body: the physics library refused the body", 2) end
	state.bodies[ptr(body)] = ptr(world)
	return body
end

--- b2.destroy_body(body) -- only for bodies made by b2.create_body (the game removes its own)
function b2.destroy_body(body)
	unlocked("b2.destroy_body")
	local key = body ~= nil and ptr(body)
	local wp = key and state.bodies[key]
	if not wp then error("b2.destroy_body: not a body created by b2.create_body (destroy game objects with ml.destroy)", 2) end
	state.bodies[key] = nil
	local world = b2.world()
	if world ~= nil and ptr(world) == wp then raw.world_destroy_body(world, body) end
end

--- b2.own_bodies() -> the bodies created by b2.create_body that are still in the current world
function b2.own_bodies()
	local out, world = {}, b2.world()
	if world == nil then return out end
	local wp = ptr(world)
	local b = raw.world_get_body_list(world)
	while b ~= nil do
		if state.bodies[ptr(b)] == wp then out[#out + 1] = b end
		b = raw.body_get_next(b)
	end
	return out
end

mosa.on("ml_layout", function()
	-- a new level has a new world: the old bodies and joints went with the old one
	local world = b2.world()
	local wp = world and ptr(world)
	for k, v in pairs(state.bodies) do if v ~= wp then state.bodies[k] = nil end end
	for k, v in pairs(state.joints) do if v ~= wp then state.joints[k] = nil end end
end)

---------------------------------------------------------------- joints

local JOINT_NAMES = { [1] = "revolute", [2] = "prismatic", [3] = "distance" }

local function track(joint, world, what)
	if joint == nil then error(what .. ": the physics library refused the joint", 3) end
	state.joints[ptr(joint)] = ptr(world)
	return joint
end

-- joints die with either of their bodies; the game tells us through its destruction listener
if mosa.hookable("fish.system.DestructionListener.sayGoodbyeJoint") then
	mosa.before("fish.system.DestructionListener.sayGoodbyeJoint", function(joint)
		if joint ~= nil then state.joints[ptr(joint)] = nil end
	end)
end

--- b2.joint_alive(joint) -> false once a joint made here was destroyed (also when one of its bodies was)
function b2.joint_alive(joint) return joint ~= nil and state.joints[ptr(joint)] ~= nil end

local function live(joint, what)
	if joint == nil then error(what .. ": joint is nil", 3) end
	return joint
end

local function two_bodies(a, b, what)
	local ba, bb = need_body(a, what), need_body(b, what)
	if ba == bb then error(what .. ": a joint needs two different bodies", 3) end
	return ba, bb
end

--- b2.revolute(a, b, x, y [, opts]) -> joint
-- Pins two things together at a level point: a hinge, an axle, a pendulum pivot.
-- opts: lower, upper (degrees, limits the swing), motor_speed (degrees/second),
--       max_torque (motor strength), collide (may the two bodies still hit each other; false)
function b2.revolute(a, b, x, y, opts)
	unlocked("b2.revolute")
	opts = opts or {}
	local ba, bb = two_bodies(a, b, "b2.revolute")
	local world, s = need_world("b2.revolute"), b2.scale()
	local def = mosa.new("hlfish.box2d.B2RevoluteJointDef")
	def:initialize(ba, bb, { x * s, y * s })
	def.collideConnected = opts.collide == true
	if opts.lower or opts.upper then
		def.enableLimit = true
		def.lowerAngle = rad(opts.lower or 0)
		def.upperAngle = rad(opts.upper or 0)
	end
	if opts.motor_speed then
		def.enableMotor = true
		def.motorSpeed = rad(opts.motor_speed)
		def.maxMotorTorque = opts.max_torque or 1000
	end
	return track(raw.world_create_joint(world, def), world, "b2.revolute")
end

--- b2.distance(a, b [, opts]) -> joint
-- Keeps two points a fixed distance apart: a rod, or a spring when frequency is set.
-- opts: ax, ay, bx, by (anchor points in level coordinates; default: the body origins),
--       length (pixels; default: the current distance), frequency (Hz, 0 = rigid),
--       damping (0..1), collide (true)
function b2.distance(a, b, opts)
	unlocked("b2.distance")
	opts = opts or {}
	local ba, bb = two_bodies(a, b, "b2.distance")
	local world, s = need_world("b2.distance"), b2.scale()
	local pa, pb = raw.body_get_position(ba), nil
	local ax, ay = opts.ax and opts.ax * s or pa.x, opts.ay and opts.ay * s or pa.y
	pb = raw.body_get_position(bb)
	local bx, by = opts.bx and opts.bx * s or pb.x, opts.by and opts.by * s or pb.y
	local def = mosa.new("hlfish.box2d.B2DistanceJointDef")
	def:initialize(ba, bb, { ax, ay }, { bx, by })
	if opts.length then def.length = opts.length * s end
	def.frequencyHz = opts.frequency or 0
	def.dampingRatio = opts.damping or 0
	def.collideConnected = opts.collide ~= false
	return track(raw.world_create_joint(world, def), world, "b2.distance")
end

--- b2.prismatic(a, b, x, y, axis_x, axis_y [, opts]) -> joint
-- Lets b slide along one axis relative to a, without rotating: a piston, a lift, a drawer.
-- opts: lower, upper (pixels along the axis), motor_speed (pixels/second), max_force, collide (false)
function b2.prismatic(a, b, x, y, axis_x, axis_y, opts)
	unlocked("b2.prismatic")
	opts = opts or {}
	local ba, bb = two_bodies(a, b, "b2.prismatic")
	local world, s = need_world("b2.prismatic"), b2.scale()
	local len = sqrt(axis_x * axis_x + axis_y * axis_y)
	if len == 0 then error("b2.prismatic: the axis cannot be (0, 0)", 2) end
	local def = mosa.new("hlfish.box2d.B2PrismaticJointDef")
	def:initialize(ba, bb, { x * s, y * s }, { axis_x / len, axis_y / len })
	def.collideConnected = opts.collide == true
	if opts.lower or opts.upper then
		def.enableLimit = true
		def.lowerTranslation = (opts.lower or 0) * s
		def.upperTranslation = (opts.upper or 0) * s
	end
	if opts.motor_speed then
		def.enableMotor = true
		def.motorSpeed = opts.motor_speed * s
		def.maxMotorForce = opts.max_force or 1000
	end
	return track(raw.world_create_joint(world, def), world, "b2.prismatic")
end

--- b2.weld(a, b [, x, y]) -> joint   a hinge that cannot turn: glues two things together
function b2.weld(a, b, x, y)
	if x == nil then x, y = b2.position(b) end
	return b2.revolute(a, b, x, y, { lower = 0, upper = 0 })
end

--- b2.destroy_joint(joint)
function b2.destroy_joint(joint)
	unlocked("b2.destroy_joint")
	live(joint, "b2.destroy_joint")
	local world = need_world("b2.destroy_joint")
	local known = state.joints[ptr(joint)]
	if known and known ~= ptr(world) then state.joints[ptr(joint)] = nil; return end   -- its world is gone
	local DL = mosa.class("fish.system.DestructionListener")
	if DL and DL.sayGoodbyeJoint then DL.sayGoodbyeJoint(joint) end    -- as the game's own removeJoint does
	state.joints[ptr(joint)] = nil
	raw.world_destroy_joint(world, joint)
end

--- b2.joints([thing]) -> list of the joints attached to a thing (or every joint in the world)
function b2.joints(x)
	local out = {}
	if x == nil then
		local w = b2.world()
		local j = w and raw.world_get_joint_list(w)
		while j ~= nil do
			out[#out + 1] = j
			j = j.m_next
		end
		return out
	end
	local e = raw.body_get_joint_list(need_body(x, "b2.joints"))
	while e ~= nil do
		out[#out + 1] = e.joint
		e = e.next
	end
	return out
end

--- b2.joint_type(joint) -> "revolute" | "prismatic" | "distance"
function b2.joint_type(joint) return JOINT_NAMES[raw.joint_get_type(live(joint, "b2.joint_type"))] or "other" end

--- b2.joint_bodies(joint) -> bodyA, bodyB
function b2.joint_bodies(joint)
	live(joint, "b2.joint_bodies")
	return raw.joint_get_body_a(joint), raw.joint_get_body_b(joint)
end

--- b2.set_motor(joint, speed [, max]) -- revolute: degrees/second and torque; prismatic:
-- pixels/second and force.  speed = nil switches the motor off.
function b2.set_motor(joint, speed, max)
	local t = b2.joint_type(joint)
	if t == "revolute" then
		local j = raw.joint_to_revolute_joint(joint)
		j.m_enableMotor = speed ~= nil
		if speed then j.m_motorSpeed = rad(speed) end
		if max then j.m_maxMotorTorque = max end
	elseif t == "prismatic" then
		local j = raw.joint_to_prismatic_joint(joint)
		j.m_enableMotor = speed ~= nil
		if speed then j.m_motorSpeed = speed * b2.scale() end
		if max then j.m_maxMotorForce = max end
	else
		error("b2.set_motor: only revolute and prismatic joints have a motor", 2)
	end
end

--- b2.set_limits(joint, lower, upper) -- degrees (revolute) or pixels (prismatic); nil, nil removes them
function b2.set_limits(joint, lower, upper)
	local t = b2.joint_type(joint)
	local on = lower ~= nil and upper ~= nil
	if t == "revolute" then
		local j = raw.joint_to_revolute_joint(joint)
		if on then j.m_lowerAngle, j.m_upperAngle = rad(lower), rad(upper) end
		j.m_enableLimit = on
		j.m_impulse.z = 0
	elseif t == "prismatic" then
		local j = raw.joint_to_prismatic_joint(joint)
		local s = b2.scale()
		if on then j.m_lowerTranslation, j.m_upperTranslation = lower * s, upper * s end
		j.m_enableLimit = on
		j.m_impulse.z = 0
	else
		error("b2.set_limits: only revolute and prismatic joints have limits", 2)
	end
end

--- b2.set_length(joint, pixels [, frequency, damping]) -- distance joints: reel a rope in or out
function b2.set_length(joint, length, frequency, damping)
	if b2.joint_type(joint) ~= "distance" then error("b2.set_length: not a distance joint", 2) end
	local j = raw.joint_to_distance_joint(joint)
	j.m_length = length * b2.scale()
	if frequency then j.m_frequencyHz = frequency end
	if damping then j.m_dampingRatio = damping end
end

--- b2.joint_angle(joint) -> degrees a revolute joint has turned from where it was created
function b2.joint_angle(joint)
	if b2.joint_type(joint) ~= "revolute" then error("b2.joint_angle: not a revolute joint", 2) end
	local j = raw.joint_to_revolute_joint(joint)
	return deg(raw.body_get_angle(raw.joint_get_body_b(joint)) - raw.body_get_angle(raw.joint_get_body_a(joint)) - j.m_referenceAngle)
end

--- b2.reaction_force(joint [, dt]) -> fx, fy the joint applied to its second body in the last step
function b2.reaction_force(joint, dt)
	local f = raw.joint_get_reaction_force(live(joint, "b2.reaction_force"), 1 / (dt or 1 / 60))
	return f.x, f.y
end

--- b2.reaction_torque(joint [, dt])
function b2.reaction_torque(joint, dt)
	return raw.joint_get_reaction_torque(live(joint, "b2.reaction_torque"), 1 / (dt or 1 / 60))
end

---------------------------------------------------------------- looking around

local function vec_xy(v, inv) return v.x * inv, v.y * inv end

--- b2.raycast(x1, y1, x2, y2 [, filter]) -> hit or nil
-- The first thing a line from (x1, y1) to (x2, y2) touches.
--   hit.inst (game object or nil), hit.fixture, hit.body, hit.x, hit.y, hit.nx, hit.ny (surface
--   normal), hit.fraction (0..1 along the line), hit.distance (pixels)
-- filter(inst, fixture) -> return false to let the ray pass through that fixture
-- (sensors are hit like anything else: filter with b2.is_sensor(fixture) to skip them).
function b2.raycast(x1, y1, x2, y2, filter)
	local world = need_world("b2.raycast")
	local s = b2.scale()
	local inv = 1 / s
	local best
	raw.world_ray_cast(world, function(fixture, point, normal, fraction)
		local inst = raw.fixture_get_user_data(fixture)
		if filter and filter(inst, fixture) == false then return -1 end
		local px, py = vec_xy(point, inv)
		best = { inst = inst, fixture = fixture, x = px, y = py, nx = normal.x, ny = normal.y, fraction = fraction }
		return fraction      -- clip the ray here: only closer hits are reported from now on
	end, { x1 * s, y1 * s }, { x2 * s, y2 * s })
	if best then
		best.body = raw.fixture_get_body(best.fixture)
		best.distance = best.fraction * sqrt((x2 - x1) ^ 2 + (y2 - y1) ^ 2)
	end
	return best
end

--- b2.raycast_all(x1, y1, x2, y2 [, filter]) -> list of hits, nearest first
function b2.raycast_all(x1, y1, x2, y2, filter)
	local world = need_world("b2.raycast_all")
	local s = b2.scale()
	local inv = 1 / s
	local len = sqrt((x2 - x1) ^ 2 + (y2 - y1) ^ 2)
	local hits = {}
	raw.world_ray_cast(world, function(fixture, point, normal, fraction)
		local inst = raw.fixture_get_user_data(fixture)
		if filter and filter(inst, fixture) == false then return -1 end
		local px, py = vec_xy(point, inv)
		hits[#hits + 1] = { inst = inst, fixture = fixture, body = raw.fixture_get_body(fixture), x = px, y = py,
			nx = normal.x, ny = normal.y, fraction = fraction, distance = fraction * len }
		return 1             -- keep going to the end of the line
	end, { x1 * s, y1 * s }, { x2 * s, y2 * s })
	table.sort(hits, function(a, b) return a.fraction < b.fraction end)
	return hits
end

--- b2.query(x1, y1, x2, y2 [, filter]) -> list of fixtures whose bounding box touches the rectangle
function b2.query(x1, y1, x2, y2, filter)
	local world = need_world("b2.query")
	local s = b2.scale()
	if x1 > x2 then x1, x2 = x2, x1 end
	if y1 > y2 then y1, y2 = y2, y1 end
	local out = {}
	raw.world_query_aabb(world, function(fixture)
		if not filter or filter(raw.fixture_get_user_data(fixture), fixture) ~= false then out[#out + 1] = fixture end
		return true
	end, { lowerBound = { x1 * s, y1 * s }, upperBound = { x2 * s, y2 * s } })
	return out
end

--- b2.instances_in(x1, y1, x2, y2) -> list of game objects in the rectangle (each one once)
function b2.instances_in(x1, y1, x2, y2)
	local out, seen = {}, {}
	for _, f in ipairs(b2.query(x1, y1, x2, y2)) do
		local inst = raw.fixture_get_user_data(f)
		if inst ~= nil then
			local key = ptr(inst)
			if not seen[key] then
				seen[key] = true
				out[#out + 1] = inst
			end
		end
	end
	return out
end

local probe_circle, probe_xf

--- b2.fixtures_at(x, y [, radius]) -> fixtures whose shape really contains the point (or touches the circle)
function b2.fixtures_at(x, y, radius)
	local s = b2.scale()
	radius = radius or 0.5
	probe_circle = probe_circle or raw.create_circle_shape()
	probe_circle.m_radius = radius * s
	if not probe_xf then
		probe_xf = mosa.new("hlfish.box2d.B2Transform")
		probe_xf.q.c = 1          -- no rotation
	end
	probe_xf.p.x, probe_xf.p.y = x * s, y * s
	local out = {}
	for _, f in ipairs(b2.query(x - radius, y - radius, x + radius, y + radius)) do
		local xf = raw.body_get_transform(raw.fixture_get_body(f))
		if raw.collision_test_overlap(raw.fixture_get_shape(f), probe_circle, xf, probe_xf) then out[#out + 1] = f end
	end
	return out
end

--- b2.instance_at(x, y [, radius]) -> the first game object whose shape contains the point, or nil
function b2.instance_at(x, y, radius)
	for _, f in ipairs(b2.fixtures_at(x, y, radius)) do
		local inst = raw.fixture_get_user_data(f)
		if inst ~= nil then return inst, f end
	end
	return nil
end

---------------------------------------------------------------- contacts

--- b2.contact_instances(contact) -> instA, instB, fixtureA, fixtureB
function b2.contact_instances(contact)
	local fa, fb = raw.contact_get_fixture_a(contact), raw.contact_get_fixture_b(contact)
	return raw.fixture_get_user_data(fa), raw.fixture_get_user_data(fb), fa, fb
end

local wm

--- b2.contact_point(contact) -> x, y, nx, ny, points
-- Where the two shapes touch (pixels), the normal pointing from A to B, and the number of
-- contact points (0 while the shapes only overlap by their bounding boxes, or for sensors).
function b2.contact_point(contact)
	wm = wm or mosa.new("hlfish.box2d.B2WorldManifold")
	raw.contact_get_world_manifold(contact, wm)
	local n = raw.contact_get_manifold(contact).pointCount
	local inv = 1 / b2.scale()
	local n0, p0 = wm.normal, wm.point0
	local x, y = p0.x, p0.y
	if n >= 2 then
		local p1 = wm.point1
		x, y = (x + p1.x) / 2, (y + p1.y) / 2
	end
	return x * inv, y * inv, n0.x, n0.y, n
end

--- b2.contact_touching(contact)      b2.contact_enabled(contact)
function b2.contact_touching(contact) return raw.contact_is_touching(contact) end
function b2.contact_enabled(contact) return raw.contact_is_enabled(contact) end

--- b2.disable_contact(contact) -- in a pre-solve handler: the two shapes pass through each
-- other for this step (one-way platforms, ghosts).  Must be repeated every step.
function b2.disable_contact(contact) raw.contact_set_enabled(contact, false) end

--- b2.set_contact_friction(contact, f)   b2.set_contact_restitution(contact, r)
--- b2.set_tangent_speed(contact, pixels_per_second)   -- a conveyor belt
function b2.set_contact_friction(contact, v) raw.contact_set_friction(contact, v) end
function b2.set_contact_restitution(contact, v) raw.contact_set_restitution(contact, v) end
function b2.set_tangent_speed(contact, v) raw.contact_set_tangent_speed(contact, v * b2.scale()) end

--- b2.contacts([thing]) -> list of { contact =, a =, b =, touching = } currently in the world
-- (with a thing: only the ones it takes part in; a / b are the game objects)
function b2.contacts(x)
	local out = {}
	local w = b2.world()
	if not w then return out end
	local body = x ~= nil and need_body(x, "b2.contacts") or nil
	local c = raw.world_get_contact_list(w)
	while c ~= nil do
		local fa, fb = raw.contact_get_fixture_a(c), raw.contact_get_fixture_b(c)
		if body == nil or raw.fixture_get_body(fa) == body or raw.fixture_get_body(fb) == body then
			out[#out + 1] = { contact = c, a = raw.fixture_get_user_data(fa), b = raw.fixture_get_user_data(fb),
				touching = raw.contact_is_touching(c) }
		end
		c = raw.contact_get_next(c)
	end
	return out
end

--- b2.touching(a, b) -> true when the two things are in contact right now
function b2.touching(a, b)
	local bb = need_body(b, "b2.touching")
	local ba = need_body(a, "b2.touching")
	local w = b2.world()
	local c = w and raw.world_get_contact_list(w)
	while c ~= nil do
		if raw.contact_is_touching(c) then
			local x, y = raw.fixture_get_body(raw.contact_get_fixture_a(c)), raw.fixture_get_body(raw.contact_get_fixture_b(c))
			if (x == ba and y == bb) or (x == bb and y == ba) then return true end
		end
		c = raw.contact_get_next(c)
	end
	return false
end

-- Contact events.  The game gives Box2D four static functions as callbacks; hooking those
-- shows every contact of every object without touching the game's own handling.
local handlers = { begin = {}, ["end"] = {}, pre = {}, post = {}, filter = {} }
local hooked = {}
local GAME_FN = {
	begin = "fish.system.ContactListener.beginContact",
	["end"] = "fish.system.ContactListener.endContact",
	pre = "fish.system.ContactListener.preSolve",
	post = "fish.system.ContactListener.postSolve",
	filter = "fish.system.ContactFilter.shouldCollide",
}

local function subscribe(kind, fn, what)
	if type(fn) ~= "function" then error(what .. " needs a function", 3) end
	local list = handlers[kind]
	local entry = { fn = mosa.bind(fn, what) }
	function entry.remove()
		for i = #list, 1, -1 do if list[i] == entry then table.remove(list, i) end end
	end
	list[#list + 1] = entry
	if not hooked[kind] then
		hooked[kind] = true
		local name = GAME_FN[kind]
		if not mosa.hookable(name) then
			hl.log("[b2] cannot find " .. name .. ": " .. what .. " handlers will never run")
		elseif kind == "filter" then
			mosa.hook(name, function(orig, fa, fb)
				local a, b = raw.fixture_get_user_data(fa), raw.fixture_get_user_data(fb)
				for i = 1, #list do
					local r = list[i].fn(a, b, fa, fb)
					if r == false then return false end
				end
				return orig(fa, fb)
			end, { priority = -40 })
		else
			mosa.before(name, function(contact, data)
				local fa, fb = raw.contact_get_fixture_a(contact), raw.contact_get_fixture_b(contact)
				local a, b = raw.fixture_get_user_data(fa), raw.fixture_get_user_data(fb)
				for i = 1, #list do
					if list[i].fn(contact, a, b, data) == false and kind == "pre" then
						raw.contact_set_enabled(contact, false)
					end
				end
			end, { priority = -40 })
		end
	end
	return entry
end

--- b2.on_begin_contact(function(contact, a, b) end) -- two fixtures started touching
-- a, b: the game objects (nil for fixtures without one).  Runs inside the physics step: the
-- world is locked, so create and destroy through b2.after_step (ml.on_collision does that for you).
function b2.on_begin_contact(fn) return subscribe("begin", fn, "b2.on_begin_contact") end

--- b2.on_end_contact(function(contact, a, b) end) -- they stopped touching
function b2.on_end_contact(fn) return subscribe("end", fn, "b2.on_end_contact") end

--- b2.on_pre_solve(function(contact, a, b, manifold) end) -- every step while they touch, before
-- Box2D resolves the collision.  `return false` (or b2.disable_contact) lets them pass through
-- each other this step; set_contact_friction / restitution / tangent_speed work here too.
function b2.on_pre_solve(fn) return subscribe("pre", fn, "b2.on_pre_solve") end

--- b2.on_post_solve(function(contact, a, b, impulse) end) -- every step while they touch, after
-- the collision was resolved.  b2.impulse_of(impulse) tells how hard they pressed.
function b2.on_post_solve(fn) return subscribe("post", fn, "b2.on_post_solve") end

--- b2.on_should_collide(function(a, b, fixtureA, fixtureB) end) -- asked once when two fixtures
-- first come near each other: `return false` and they never collide; nothing to let the game decide.
function b2.on_should_collide(fn) return subscribe("filter", fn, "b2.on_should_collide") end

--- b2.impulse_of(impulse) -> normal, tangent: the strongest push (and rub) of a post-solve report
function b2.impulse_of(impulse)
	local n, t = impulse.normalImpulses0, impulse.tangentImpulses0
	if impulse.count > 1 then
		if impulse.normalImpulses1 > n then n = impulse.normalImpulses1 end
		if math.abs(impulse.tangentImpulses1) > math.abs(t) then t = impulse.tangentImpulses1 end
	end
	return n, t
end

if b2.available() then
	hl.log("[b2] Box2D layer ready: " .. #mosa.natives("fish@") .. " physics natives")
else
	hl.log("[b2] the physics natives are not available: this hlboot.dat was patched by an older patcher")
end
