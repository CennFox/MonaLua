# Lua modding API reference

Four globals:

- `ml`: Mosa Lina itself (levels, objects, tools, collisions, behaviours).
- `b2`: the game's Box2D physics.
- `mosa`: the generic engine: hooks, events, timers, class access. Tested.
- `hl`: the low-level bridge underneath.

`print(...)` writes to `mods/mosalua.log`.

Contents: [Mods](#mods) · [ml](#ml-mosa-lina) · [b2](#b2-box2d) · [Hooks](#hooks) · [Game objects](#game-objects) · [Native functions](#native-functions) · [Events and timers](#events-and-timers) · [Pitfalls](#pitfalls)

## Mods

| Layout | Mod name |
|---|---|
| `mods/name.lua` | `name` |
| `mods/name/init.lua` (or `main.lua`) | `name`, other files via `require("name.other")` |

- Loaded in alphabetical order. Names starting with `_` or `.` are ignored. `mods/_lib/*.lua` loads before all mods, in the shared global scope (that is where `ml` and `b2` come from).
- Each mod has its own globals. `MOD.name`, `MOD.path`, `MOD.dir` describe the running mod.
- Share between mods with `mosa.shared` (a plain table), `mosa.emit` / `mosa.on`, or by returning a table from the main file, which others read with `mosa.mod("name")`. A returned `unload` function is called before a reload.
- `mods/config.lua` returns `{ dev = bool, disabled = { "name", ... }, tick = "pkg.Class.method", native_libs = { "sdl", ... }, unsafe = bool }`.
- `.json` files in the same folder are ignored by Lua, so a tool's `name.json` and `name.lua` can sit side by side.
- Handlers you register (`ml.on_*`, `b2.on_*`, behaviours, timers) are protected: an error is logged with your mod's name and the game carries on.

## ml: Mosa Lina

Units: pixels, degrees, pixels per second; y grows downward.

### The running game

```lua
ml.main        -- the application (fish.system.Main)          ml.game    -- the game it runs
ml.layout      -- the layout being played: a level or a menu screen (nil before the first one)
ml.ev          -- the gameplay event sheet
ml.ready()     -- true once a layout exists                  ml.gameplay()  -- true when it is a level
```

### Selectors

Wherever the API takes "which objects":

| Selector | Matches |
|---|---|
| `"frog"` | an object type |
| `"physics_obj"` | a family (the game's groups of types; `inst.families` lists an object's) |
| `"*"` | everything |
| an object | that one object |
| `function(inst) return ... end` | whatever returns `true` |
| a name given to `ml.define` | objects spawned as that kind |

### Objects

```lua
ml.instances("coin")             -- Lua list of live instances of a type, family or kind
ml.all()                         -- every instance in the layout
ml.first("portal")               ml.count("coin")
ml.each("tile_box", function(inst) end)
ml.types()                       -- types and families present right now
ml.player([playerId])            ml.players()
ml.by_uid(uid)                   ml.alive(inst)
ml.is(inst, selector)            ml.kind(inst)      -- its ml.define name, else its type
ml.nearest(selector, x, y [, max_distance]) -> inst, distance
```

Every instance also exposes the engine's own parts directly:

```lua
inst.type, inst.uid, inst.families, inst.layout
inst.sprite.position.x              -- position is a small struct with x, y
inst.sprite:setAnim("name"), :setVisible(0|1), :setOpacity(n), :setScale(n), :setMirrored(0|1)
inst.physics                        -- nil for objects without a body
inst.physics:setDensity(n), :setFriction(n), :setElasticity(n), :setBullet(0|1), :setPreventRotate(0|1)
inst.someVariable                   -- the object's own variables, e.g. player.item_selected, b_item.ammo
```

### Position, size, motion

```lua
ml.pos(inst) -> x, y             ml.set_pos(inst, x, y)             -- teleports body and sprite
ml.size(inst) -> w, h            ml.set_size(inst, w, h)            -- the collision shape follows next frame
ml.angle(inst)                   ml.set_angle(inst, deg)
ml.distance(a, b)
ml.velocity(inst) -> vx, vy      ml.set_velocity(inst, vx, vy)      -- these need inst.physics
ml.impulse(inst, strength, angle_deg)       ml.force(inst, strength, angle_deg)
ml.spin(inst, degrees_per_second)
ml.freeze(inst [, false])        -- immovable like terrain / loose again
```

Gravity. The game zeroes Box2D's world gravity and pulls every moving `physics_obj` itself,
each frame, with a force from the object's own `personal_gravity` (see the guide). These work
with that, without changing the game's variables:

```lua
ml.set_gravity_scale(f)          -- everything, in every level: 1 normal, 0.3 moon, 0 weightless, -1 falls up
ml.gravity_scale() -> f
ml.gravity(inst, f)              -- one object, on top of the scale: 0 floats, 1 normal;  ml.gravity(inst) -> f
ml.set_density(inst, d)          -- heavier / lighter to push and falling as before (weight does not follow mass by itself)
ml.weight(inst) -> force         -- what pulls on it this frame (Box2D units; 0 without weight, negative: up)
                                 -- b2.force(inst, 0, -ml.weight(inst)) every frame makes it hover
```

For anything finer use `b2` on the same object.

### Creating and removing

```lua
ml.spawn("frog", x, y [, { layer = 0, init = function(inst) end }]) -> inst
ml.destroy(inst)                 -- the game removes it at the end of the frame
ml.spawnable()                   -- every type name (about 680)      ml.can_spawn(name)
ml.explode(x, y, radius [, power])   -- the game's own explosion (its tools use power 0.3)
ml.sfx("name")                   -- one of the game's sound effects
ml.picker(inst, ...)             -- a fish.system.Picker, for game functions that take "some objects"
```

`init` runs before the object is added to the level: its body does not exist yet. `ml.spawn`
and `ml.explode` refuse to run inside a physics callback (see [contact events](#contact-events-inside-the-step)).

### Level events

```lua
ml.on_level(function(layout) end)        -- a level started: its first frame, everything exists
ml.on_layout(function(layout) end)       -- any layout started, menu screens included
ml.on_level_end(function(layout) end)    -- the layout that was running is being replaced
ml.on_update(function(dt, layout) end)   -- every frame, right before the game updates the layout
ml.each_frame(selector, function(inst, dt) end)     -- every frame, per matching object
```

`ml.layout` moves to the next layout as soon as the game starts building it, so `ml.on_create`
handlers for its objects already see it; `on_level` follows at its first frame.

### Object events

```lua
ml.on_create(selector, function(inst) end)       -- added to the level; its body exists
ml.on_destroy(selector, function(inst) end)      -- destroyed by the game or a mod; still readable
```

Objects that simply go away with their level are not reported as destroyed.

### Collisions

```lua
ml.on_collision(selA, selB, function(a, b, hit) end)     -- started touching
ml.on_separate(selA, selB, function(a, b) end)           -- stopped touching
ml.on_impact(selA, selB, min_strength, function(a, b, hit) end)   -- pressed together at least that hard
```

- `a` matches `selA`, `b` matches `selB`, whichever way round Box2D reported them.
- `hit.x, hit.y`: where (nil for sensors). `hit.nx, hit.ny`: direction from `a` to `b`. `hit.speed`: how fast they closed in, pixels per second. `hit.strength` (on_impact): the impulse Box2D needed to keep them apart.
- These handlers run **right after the physics step**: spawning, destroying and joints are all fine.
- `on_impact` is judged every step while two things touch; pick `min_strength` so resting contact stays below it (`diag`-style logging of `hit.strength` shows the range).

```lua
ml.no_collide(selA, selB)                 -- these never collide (decided when they first come near)
ml.pass_through(selA, selB [, function(a, b, contact) return true end])
                                          -- go through each other while the function says true; asked every step
ml.ignore(a, b)                           -- two objects, using the game's own ignore list
ml.touching(inst [, selector])            -- list of objects in contact with it right now
```

All of these return a handle with `.remove()` (except `ml.ignore` and `ml.touching`).

### Behaviours and new kinds of objects

```lua
ml.attach(inst, {
    tick = function(inst, dt) end,               -- every frame, before the physics step
    collide = function(inst, other, hit) end,    -- as ml.on_collision, from this object's side
    separate = function(inst, other) end,
    destroy = function(inst) end,
})
ml.detach(inst [, behaviour])

ml.define("sticky_bomb", {
    base = "bomb",                               -- a spawnable game type
    setup = function(inst, opts) end,            -- before it is added: set the base type's fields
    init = function(inst, opts) end,             -- just created: body exists; reshape, add joints
    tick = ..., collide = ..., separate = ..., destroy = ...,
})
ml.spawn("sticky_bomb", x, y, { anything = 1 })  -- opts reaches setup and init
```

A defined name works in every selector and in `ml.instances`, `ml.count`, `ml.first`. Behaviours
end with their object, and with the level.

### Tools

```lua
ml.tool([player]) -> name, b_item          -- tool in hand
ml.tools() -> { {name=, ammo=, slot=, item=}, ... }
ml.set_ammo("bomb", 5)                     -- -1 = unlimited
ml.aim_point([player [, "crosshair"|"short"|"mid"|"max"]]) -> x, y
ml.on_fire("toolname" or "*", function(ctx) end)
--   ctx.tool, ctx.player, ctx.item (the b_item), ctx.x, ctx.y, ctx.aim([which]) -> x, y, ctx.angle()
ml.on_tool_select(function(player, b_item) end)
```

`b_item.item` is `{ locked, wins, type = { name, aimType, baseAmmo, secondLayer } }`.
`ml.on_fire` runs right after the game fired the tool: the ammo is taken, and the game's own
code for that tool, if it has any, has run.

**A new tool:**

```lua
ml.add_tool{
    name = "black_hole",        -- the game's name for it: b_item.item.type.name, ml.on_fire, ml.give_tool
    label = "Black Hole",       -- shown on screen (default: the name, underscores as spaces)
    aim = "long",               -- shoot (default), short, short2, mid, mid2, long, long2, remote
    ammo = 1,                   -- shots per level, 1..255 (default 1)
    icon = "vortex",            -- a game tool whose picture it borrows (default "nothing")
    second_layer = false,       -- true: only drawn in second layer runs
    fire = function(ctx) end,   -- the same as ml.on_fire(name, fire)
}
ml.pool() -> { {name=, aim=, ammo=, second_layer=, added=}, ... }   -- every tool the game can draw
ml.give_tool("black_hole" [, slot [, ammo]]) -> b_item             -- into the player's hand, for this level
```

`ml.add_tool` belongs at the top level of a mod, so that it runs while the mod loads. When the
game is starting, the tool goes in right behind the game's own: an `item` object in a free
square of the tool grid, and the pool entry made from it by the game's `initBaseItems`. Called
later (a mod switched on in the mod menu), the pool entry is made at once and the grid square
at the next start. Loading the same definition again changes nothing; a changed `aim` or
`ammo` is taken over. A name the game already uses is refused.

Things to know: the pool is longer by one tool, so a seed draws other tools than without the
mod. An added tool stays until the game is closed, also when its mod is switched off; fired
without its mod it takes the ammo and does nothing. `icon` is the name of a tool the game
has a picture for (`ml.pool()` lists the tools); an unknown name falls back to another picture
and says so in the log. `ml.give_tool` replaces what is in
the slot (default: the slot in hand) and gives the tool's normal ammo; it is replayed in a GIF
when it is called from level code (`ml.on_key`, `ml.on_update`, a timer).

### The game's own functions as events

The gameplay sheet's named functions (`ml.game_functions()` lists all 78) by name:

```lua
ml.on_game("jump", function(player_id) end)             -- after it ran; gets its arguments
ml.before_game("jump", function(player_id) return false end)   -- false: it does not happen
```

Optional number arguments arrive as plain values, `nil` where the game left them out. Three
have ready-made forms because their arguments were worked out from the code:

```lua
ml.on_explosion(function(x, y, radius, power, explosion_inst) end)
ml.on_player_death(function(player_id) end)   -- -1 = all players; the game then revives the player
                                              -- at a checkpoint or removes it; return false to prevent
ml.on_tool_select(function(player, b_item) end)
```

Anything else in the game is reachable with `mosa.hook` and friends.

### Time and input

```lua
ml.dt()   ml.tick()   ml.time()                 -- frame time, frame number, seconds of this layout
ml.time_scale()   ml.set_time_scale(0.25)       -- the game's own slow motion
ml.after(seconds, fn) -> handle with .cancel()  -- on the layout's clock; dropped when it ends

ml.key_down("space")   ml.key_pressed("e")   ml.key_released("e")
ml.on_key("g", function() end)                  -- each time it goes down
-- Inside a level's frame the keyboard is read once, when the frame starts: every question in
-- that frame gets the same answer, and "pressed" means down in this frame, not in the last.
-- names: a-z, 0-9, f1-f12, space, enter, escape, shift, ctrl, alt, tab, left, up, right, down,
-- mouse_left, mouse_right, mouse_middle; or a key code.  ml.keys is the table.
```

### GIF replays

Saving a GIF makes the game play the level again in a private copy of itself. `ml` follows
that copy for as long as it runs (see "GIFs" in the guide), so handlers work in the replay as
they did in the level, and the `ml` key functions return what was pressed then.

```lua
ml.replaying() -> bool           -- true while the game is replaying a level for a GIF
ml.vars() -> table               -- your mod's variables for this run of the level: empty when a
                                 -- level starts; a replay has its own and leaves the level's alone
```

### The mod menu

`LUA MODS` in the pause menu is built by `mods/_lib/modmenu.lua` from the game's own menu
library. Mods can use the same functions:

```lua
modmenu.mods() -> { { name =, enabled =, error = }, ... }      -- every mod in the folder, in load order
modmenu.enabled(name) -> bool
modmenu.set(name, enabled)       -- switch one mod; all mods are reloaded at the next frame
modmenu.reload()                 -- run every mod file again at the next frame
```

## b2: Box2D

Mosa Lina's physics is Box2D 2.3 with double precision. `b2` speaks the game's units: pixels,
degrees, pixels per second, y down. Forces, impulses, torques and masses are Box2D's own
(newtons, kilograms; one metre is 50 pixels), exactly as in the game's physics code.

A **thing** below is a game object, its `physics` behaviour, a `b2Body` or a `b2Fixture`.

```lua
b2.available()                  b2.has("world_query_aabb")
b2.world()                      b2.scale()          -- metres per pixel: 0.02
b2.gravity() -> gx, gy          b2.set_gravity(gx, gy)        -- the world's own gravity, Box2D units. In a level
                                                              -- the game sets it to (0, 0) and applies weight itself: see ml.gravity
b2.locked()                     b2.after_step(fn)             -- see contact events
```

### Bodies

```lua
b2.body(thing) -> b2Body or nil            b2.instance(thing) -> the game object it belongs to
b2.bodies() -> every body in the world

b2.position(thing) -> x, y                 b2.set_position(thing, x, y [, degrees])
b2.angle(thing)                            b2.set_angle(thing, degrees)
b2.velocity(thing) -> vx, vy               b2.set_velocity(thing, vx, vy)
b2.speed(thing)                            b2.velocity_at(thing, x, y)      -- spin included
b2.angular_velocity(thing)                 b2.set_angular_velocity(thing, degrees_per_second)
b2.center(thing) -> x, y                   -- centre of mass
b2.world_point(thing, lx, ly)              b2.local_point(thing, x, y)
b2.world_vector(thing, lx, ly)             b2.local_vector(thing, vx, vy)

b2.impulse(thing, ix, iy [, x, y])         -- instant; at a level point or the centre of mass
b2.force(thing, fx, fy [, x, y])           -- continuous: apply every frame (ml.on_update)
b2.launch(thing, vx, vy)                   -- adds velocity in pixels/second, whatever the mass
b2.push(thing, degrees, strength)          -- impulse in a direction
b2.torque(thing, t)                        b2.angular_impulse(thing, i)

b2.mass(thing)   b2.inertia(thing)         b2.set_mass(thing, kg)
b2.type(thing) -> "static" | "kinematic" | "dynamic"       b2.set_type(thing, name)
b2.gravity_scale(thing)                    b2.set_gravity_scale(thing, f)   -- scales the world's gravity only (0, 0 in a level)
b2.damping(thing) -> linear, angular       b2.set_damping(thing, linear [, angular])
b2.bullet(thing)                           b2.set_bullet(thing [, false])
b2.fixed_rotation(thing)                   b2.set_fixed_rotation(thing [, false])
b2.active(thing)                           b2.set_active(thing [, false])
b2.awake(thing)                            b2.wake(thing)
```

Moving a body directly and moving its sprite (`ml.set_pos`) both work: the game copies whichever
changed to the other each frame.

### Fixtures and shapes

```lua
b2.fixtures(thing) -> { b2Fixture, ... }           b2.owner(fixture) -> game object
b2.density(x)  b2.friction(x)  b2.restitution(x)  b2.is_sensor(x)     -- a fixture, or a thing's first
b2.set_density(thing, d)        -- all its fixtures; the mass follows (the game's weight for it does not: ml.set_density)
b2.set_friction(thing, f)       -- 0 ice .. 1 rubber
b2.set_restitution(thing, r)    -- 0 no bounce .. 1 keeps all its speed
b2.set_sensor(thing [, false])  -- detects overlaps, collides with nothing

b2.add_box(thing, width, height [, opts]) -> fixture
b2.add_circle(thing, radius [, opts]) -> fixture
b2.add_polygon(thing, { x1, y1, x2, y2, ... } [, opts]) -> fixture     -- 3 to 16 corners; the convex outline is used
--   opts: x, y (offset from the body origin), angle (boxes), density (1), friction (0.3),
--         restitution (0), sensor (false), owner (the game object contact events report)
b2.remove_fixture(fixture)

b2.shape(x) -> { type = "circle", radius =, x =, y = } | { type = "polygon", points = { x1, y1, ... } }
b2.aabb(thing) -> x1, y1, x2, y2
```

A shape added to a game object belongs to it: collisions of that shape are reported as
collisions of the object. Do not `ml.set_size` an object afterwards (the game rebuilds its fixtures).

### Bodies without a game object

```lua
b2.create_body{ type = "dynamic", x =, y =, angle =, vx =, vy =, angular_velocity =,
                linear_damping =, angular_damping =, fixed_rotation =, bullet =, gravity_scale =, active = } -> b2Body
b2.destroy_body(body)           b2.own_bodies()
```

Invisible and unknown to the game; gone when the level ends. Usually `ml.spawn` plus reshaping
is what you want. While such bodies exist, the game's own pre/post-solve handlers are skipped
for contacts that involve them (they expect every fixture to carry a game object).

### Joints

```lua
b2.revolute(a, b, x, y [, { lower =, upper =, motor_speed =, max_torque =, collide = }])   -- hinge at a level point
b2.distance(a, b [, { ax =, ay =, bx =, by =, length =, frequency =, damping =, collide = }])   -- rod; a spring with frequency
b2.prismatic(a, b, x, y, axis_x, axis_y [, { lower =, upper =, motor_speed =, max_force =, collide = }])   -- slider
b2.weld(a, b [, x, y])                        -- a hinge that cannot turn
b2.destroy_joint(joint)                       b2.joint_alive(joint)

b2.joints([thing]) -> list                    b2.joint_type(joint)      b2.joint_bodies(joint)
b2.set_motor(joint, speed [, max])            -- degrees/s + torque, or pixels/s + force; nil = off
b2.set_limits(joint, lower, upper)            -- degrees or pixels; nil, nil = none
b2.set_length(joint, pixels [, frequency, damping])       -- distance joints
b2.joint_angle(joint)                         b2.reaction_force(joint)   b2.reaction_torque(joint)
```

`a` and `b` are things. A joint dies with either of its bodies; `b2.joint_alive` knows. The
game's own joints (`inst.physics:createRevoluteJoint(...)`, hinges, ropes) show up in `b2.joints` too.
These three are the joint types the game's library has.

### Looking around

```lua
b2.raycast(x1, y1, x2, y2 [, filter]) -> hit or nil        -- the first thing the line touches
b2.raycast_all(x1, y1, x2, y2 [, filter]) -> hits, nearest first
--   hit.inst, hit.fixture, hit.body, hit.x, hit.y, hit.nx, hit.ny, hit.fraction, hit.distance
--   filter(inst, fixture): return false to let the ray pass
b2.query(x1, y1, x2, y2 [, filter]) -> fixtures       -- by bounding box (padded a few pixels by Box2D)
b2.instances_in(x1, y1, x2, y2) -> game objects, each once
b2.fixtures_at(x, y [, radius]) -> fixtures whose shape really contains the point
b2.instance_at(x, y [, radius]) -> inst, fixture
b2.contacts([thing]) -> { { contact =, a =, b =, touching = }, ... }
b2.touching(a, b) -> bool
```

### Contact events (inside the step)

```lua
b2.on_begin_contact(function(contact, a, b) end)
b2.on_end_contact(function(contact, a, b) end)
b2.on_pre_solve(function(contact, a, b, manifold) end)      -- return false: no collision this step
b2.on_post_solve(function(contact, a, b, impulse) end)
b2.on_should_collide(function(a, b, fixtureA, fixtureB) end)    -- return false: never collide
```

`a`, `b`: the game objects (nil for fixtures without one). Each returns a handle with `.remove()`.

These run **in the middle of the Box2D step**, for every pair, whatever the objects. The world
is locked: `b2.create_body`, `add_*`, joints, `set_type`, `ml.spawn` refuse; `b2.after_step(fn)`
runs `fn` the moment the step is over. Reading, velocities, forces and everything below are fine.

```lua
b2.contact_instances(contact) -> a, b, fixtureA, fixtureB
b2.contact_point(contact) -> x, y, nx, ny, points       -- normal from A to B; points = 0 for sensors
b2.contact_touching(contact)    b2.contact_enabled(contact)    b2.disable_contact(contact)
b2.set_contact_friction(contact, f)    b2.set_contact_restitution(contact, r)
b2.set_tangent_speed(contact, pixels_per_second)        -- a conveyor belt
b2.impulse_of(impulse) -> normal, tangent               -- strongest push of a post-solve report
```

### The natives themselves

```lua
b2.raw.body_get_angle(b2.body(inst))        -- radians
b2.raw.body_set_linear_velocity(body, { x = 1, y = 0 })     -- metres per second; a table works as a vector
```

All 126 are in `mods/natives.txt` with their signatures, and all are hookable as `fish@<name>`.
40 of them the game itself never calls (`world_query_aabb`, `body_get_gravity_scale`,
`fixture_set_user_data`, ...): the friendly layer uses several, and the first-run diagnostics
exercise them. Values a native returns as a vector or struct may be reused by the library on
the next call: read the fields at once.

## Hooks

Names are `package.Class.method`; constructors are `package.Class.new`; anonymous functions are
`package.File:line` (a second one on the same line is `...:line#2`); natives are `lib@name`. The
short forms `Class.method` and `File:line` work when unambiguous. Methods receive the object as
first argument; anonymous functions that capture variables receive a `captured-vars` record first.

```lua
mosa.hook(name, function(orig, ...) ... end [, { priority = n }])   -- wrap
mosa.before(name, function(...) end)                               -- observe / cancel
mosa.after(name, function(result, ...) end)                        -- observe / change the result
mosa.replace(name, function(...) end)                              -- the game's code never runs
mosa.unhook(handle)             -- every function above returns a handle (also handle.remove())
mosa.trace(name)                -- log every call with arguments and result
mosa.find("text")               -- hookable names containing the text
mosa.hookable(name)             -- true / false
```

- **wrap**: call `orig(...)` to run the game's code (or the next mod's hook). What you return is what the caller gets. If you called `orig` and return nothing, its result is passed through. Return `mosa.NULL` to force a null result.
- **before**: `return mosa.SKIP` cancels the call; `return mosa.SKIP, value` cancels and makes the call return `value`.
- **after**: return a value to replace the result, nothing to keep it, `mosa.NULL` for null.
- Several hooks on one function nest; later registered (or higher `priority`) runs outermost.
- A subclass that overrides a method has its own function: hook `Child.update`, `Parent.update`, or both.
- Calls you make from Lua go through hooks too. Inside a hook, `orig` skips only that function's hooks once.
- Exceptions thrown by the game pass through hooks to the game's own `catch`. `mosa.throw(value)` throws one.
- A hook that errors is logged, the game's own code runs instead, and after 5 errors the hook is retired.

## Game objects

```lua
local Cls = mosa.class("pkg.Class")     -- nil if there is no such class
Cls.staticVar = 3                       -- static variables
Cls.staticFunction(a, b)                -- static functions (dot)
local obj = mosa.new("pkg.Class", ...)  -- or  Cls(...)
obj.field = obj.field + 1               -- fields
obj:method(a, b)                        -- methods (colon); trailing optional arguments may be omitted
mosa.is(obj, "pkg.Class")               -- instance-of test (subclasses count)
mosa.classname(obj)                     -- "pkg.Class"
mosa.classof(obj)                       -- the class object
obj1 == obj2                            -- same game object
tostring(obj)                           -- the game's own toString
```

Values convert automatically:

| Game | Lua |
|---|---|
| `Int`, `Float`, `Bool`, `String`, `null` | integer, number, boolean, string, `nil` |
| objects, arrays, enums, functions, structs, native pointers | a reference (userdata) |
| function parameter / field | a Lua function works as the callback |
| `Array<T>` parameter / field | a Lua list `{1, 2, 3}` works |
| anonymous structure `{x:1}` | a Lua table `{x = 1}` works, or `mosa.struct{...}` |
| struct parameter / field (`Vector2Default`, `B2BodyDef`, ...) | a Lua table works: `{ x = 1, y = 2 }` or `{ 1, 2 }` |
| enum parameter / field | a constructor name `"Red"` works for constructors without parameters |
| optional `Int`/`Float`/`Bool` with a default, `hl.Ref<T>` | pass a plain value, or omit / `nil` for the default |

Arrays are **0-based**, like in the game:

```lua
arr[0], #arr, arr:push(v), arr:pop()
for i, v in mosa.each(arr) do ... end    -- also iterates Haxe iterators, e.g. map:keys()
mosa.totable(arr)                        -- copy into a 1-based Lua list
mosa.array{1, 2, 3}                      -- make a Haxe array explicitly
hl.narray({1, 2, 3}, "i32")              -- hl.NativeArray; element kind "dyn" (default), "i32", "f64", "f32", "bool"
```

Maps: `map:get(k)`, `map:set(k, v)`, `map:exists(k)`, `map:keys()` (whatever methods the game itself uses).

Structs (value types such as `hxmath.math.Vector2Default`, used for positions, and every
`hlfish.box2d.*` type):

```lua
local p = inst.sprite.position      -- a view of the struct: writes go to the object
p.x = p.x + 10
inst.sprite.position = { 100, 200 } -- a table is copied into it
local v = mosa.new("hxmath.math.Vector2Default", 1, 2)
def:initialize(bodyA, bodyB, { x = 1, y = 2 })     -- structs have methods too
```

Native pointers (`b2Body`, `b2World`, ...): opaque references. `a == b` compares the pointers;
`hl.ptr(v)` gives a number usable as a table key.

By-reference parameters arrive in hooks as a reference object: `r.value` reads it, `r.value = x` writes back into the caller's variable.

Enums:

```lua
local e = obj.color
e.name, e.index, e.nparams, e.args       -- "Rgb", 3, 3, {1, 2, 3}
e[0]                                     -- first parameter
mosa.enum("pkg.Color", "Rgb", 1, 2, 3)   -- create a value
hl.enum_names("pkg.Color")               -- {"Red", "Green", ...}
```

Errors from the game arrive as Lua errors: `local ok, err = pcall(function() obj:risky() end)`,
then `err.message` (text) and `err.value` (the thrown value); `hl.isexception(err)` tells them apart from Lua errors.

## Native functions

The functions the game imports from its C/C++ libraries (`mods/natives.txt` lists all 884):

```lua
local f = mosa.native("fish@body_get_mass")     -- nil if the game has none of that name
f(body)
mosa.natives("sdl@")                            -- names containing the text
```

- The physics library (`fish`) is always available, and its natives are hookable.
- Other libraries (`sdl`, `openal`, `steam`, `std`, ...) are callable only when listed in `native_libs` in `mods/config.lua` (or with `unsafe = true`); to make their functions hookable as well, run the patcher with `--natives fish,sdl` (`mosalua_patcher.py` or `install.py`).
- Arguments convert as for any game function; at most 9.

## Looking around

```lua
mosa.classes("text")       -- class names containing the text
mosa.fields(obj_or_class)  -- { {name=, type=, method=, class=}, ... }; pass true as 2nd argument for a class's statics
mosa.dump(obj [, depth])   -- printable description of an object's fields
hl.typeof(v)               -- kind, type name       ("obj", "pkg.Class")  ("abstract", "b2Body")  ("struct", ...)
hl.super(obj_or_class)     -- parent class name
```

## Events and timers

```lua
mosa.on("tick", function(dt) end)   -- every frame, menus included
mosa.on("ready", fn)                -- all mods loaded
mosa.on("unload", fn)               -- about to reload
mosa.on("anything", fn); mosa.emit("anything", ...)   -- your own events
mosa.delay(seconds, fn); mosa.every(seconds, fn); mosa.next_frame(fn)   -- real time; handles have .cancel()
mosa.time()                         -- seconds since startup
mosa.reload()                       -- reload all mods now
mosa.bind(fn [, what])              -- for libraries: wraps fn so its errors are logged under the calling mod's name
```

## Pitfalls

- Call methods with a colon. `obj.method(x)` also works, except when `x` is `obj` itself.
- Static functions use a dot: `Cls.fn(x)`.
- A method the game never calls may have been removed by the compiler; `obj.missing` is `nil`.
- The game can be called with at most 9 arguments (8 plus the object for methods).
- File access (`io.open`) is relative to the `mods` folder and confined to it unless `unsafe = true`.
- Hooked calls cost about 2 microseconds each: keep hooks off functions that run thousands of times per frame.
- Objects you keep in Lua variables stay valid in memory, but the game may have destroyed them: check `ml.alive(inst)`.
- Bodies, fixtures, joints and contacts are raw pointers into the physics library and are **not** kept valid: use them and let go. Keep the game object and ask `b2.body(inst)` again; check `b2.joint_alive(j)`.
- Nothing can be created or destroyed while Box2D is stepping (`b2.locked()`): use `ml.on_collision` and friends, or `b2.after_step`.
