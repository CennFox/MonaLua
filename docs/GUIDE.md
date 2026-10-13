# Lua mods for Mosa Lina

Write mods as plain `.lua` files. You patch once; after that mods are just files in the game's
`mods\` folder, and saving a file reloads it while the game is running. A mod has three layers
to work with:

| Layer | What it gives you |
|---|---|
| `mosa` | **Hooks on everything.** Wrap, observe, cancel or replace any of the game's ~10,000 functions, anonymous event blocks included, and the 126 native functions of its physics library. Read and change any object, call any function. |
| `b2` | **The game's Box2D, directly.** Bodies, shapes, forces, joints, ray casts, area queries, contact events, collision filtering, gravity, in the game's units. Or the raw natives. |
| `ml` | **Mosa Lina itself.** Levels, objects, tools, collisions between kinds of objects, behaviours attached to objects, new kinds of objects, the game's own functions as events, keys, level-time timers. |

```lua
-- everything bounces, and the player's bombs stick to what they hit
ml.on_create("*", function(inst)
    if inst.physics then b2.set_restitution(inst, 0.7) end
end)

ml.on_collision("bomb", "*", function(bomb, other, hit)
    if bomb.physics and other.physics and other.type ~= "player" and #b2.joints(bomb) == 0 then
        b2.weld(other, bomb, hit.x, hit.y)
    end
end)

-- half-speed physics while T is held: a hook on the physics library's own step function
mosa.hook("fish@world_step", function(orig, world, dt, vel_iter, pos_iter)
    if ml.key_down("t") then dt = dt / 2 end
    return orig(world, dt, vel_iter, pos_iter)
end)
```

## Test coverage

| Area | How it is tested |
|---|---|
| Lua engine (hooks, objects, callbacks, structs, natives) | 337 automated checks on a small stand-in game: Linux HashLink 1.14 and 1.16, Windows HashLink 1.13 and 1.14 under Wine (257 on 1.11 / 1.12) |
| `ml` and `b2` | 1426 checks on a second test game that has the real game's class names, level flow and gravity model and runs real Box2D behind the game's 126 native signatures: Linux and Windows HashLink 1.14 and 1.16 |
| The game's `hlboot.dat` | patches cleanly (9989 hookable functions, 884 natives callable) and loads in HashLink with the Lua runtime up. A further suite runs against the patched file: every game name and variable the Lua layers use exists, the Box2D suite runs with the game's own structs, constructors, joint code and contact callbacks, and the mod menu is built on the game's own menu library |
| The game's `libhl.dll` | a 64-bit HashLink 1.16 development build. It exports all 40 functions the runtime imports; the suites above pass with it loaded under Wine |
| In the game itself | checked by hand: the runtime, levels, tools, the probes of `diag.lua`, new tools in the item pool (`black_hole.lua`, `rewind.lua`), explosions and drawing into the level (`destruction.lua`), forces and gravity (`moon.lua`, `gravity_gun.lua`), replacing an anonymous event block (`no_backflips.lua`) |
| GIF replays and the mod menu | covered on the test game, which exports a replay the way the game does and has the game's menu classes |

Keep the unpatched file. `mods\diag.lua` logs what every layer sees, one assumption per line.

The game needs HashLink 1.14 or later (its own shape code uses an instruction that crashes on
1.13) and ships 1.16. The same `mosalua.hdll` runs on all of them: where versions
differ it tests the running HashLink at start-up instead of assuming a version.

## Install

Close the game first.

Run `mosalua_patcher.py` (one file, needs only Python 3.6+): double-click it. It finds the game
through Steam (or asks you to drag the game folder in), keeps the current `hlboot.dat` as
`hlboot.dat.pre_lua`, patches it, and puts `mosalua.hdll` and the `mods\` folder next to it.
Run it again to update, or to remove the patch. From a terminal:
`python mosalua_patcher.py "<game folder>"`, `--uninstall` to undo.

If you also add tools with the tool patcher GUI, patch your tools first and run
`mosalua_patcher.py` afterwards.

The Lua patch has to be the last thing done to `hlboot.dat`: it moves code inside the
functions it makes hookable, and other patchers rely on the original positions. After a game
update, or after patching tools again, run the patcher again.

Then start the game, play a level for half a minute, fire a tool, quit, and open
`mods\mosalua.log`.

**If the game does not start:** put the unpatched `hlboot.dat` back. The error text and
`mods\mosalua.log` (if it exists) say what went wrong; attach both to a bug report.

## First run

`mods\diag.lua` only reads. After a level it has logged lines like these (the values here are
made up):

```
physics of 'level_x':
  world / metres per pixel / gravity: <b2World 0x...> / 0.02 / 0.0, 0.0
  bodies in the world: 212 (180 static, 0 kinematic, 32 dynamic)
  player body vs sprite position: sprite (412.00, 300.25)  body (412.00, 300.25)  -> they agree
  player fixtures: polygon of 4 corners density 1.00 friction 0.30 owner = player
  ray straight down from the player: tile_box at (412.0, 316.0), 15.7 px away, normal (0.00, -1.00)
contact callbacks so far: 41 begin, 12 end, 3100 pre-solve, 3100 post-solve in 180 physics steps
```

Any line that says `FAILED` or `THEY DIFFER` points at a problem and belongs in a bug report. The report also
says what can move in the level, how gravity is applied to the player, and, once you have
pressed a key, whether key presses reach Lua. Once that log looks sane, `mods\_examples\physics_selftest.lua` (copy it into `mods\`) checks the parts that
change the world: it builds a small pendulum far outside the level and prints `PASS` / `FAIL`.

## Writing mods

### Hook anything

```lua
mosa.hook("EvSheet_gameplay.jump", function(orig, self, player_id)
    print("jump", player_id)
    return orig(self, player_id)          -- leave this out and nobody jumps
end)
mosa.before(name, fn)   mosa.after(name, fn)   mosa.replace(name, fn)   mosa.trace(name)
```

`mods\hookable.txt` lists every hookable function with its argument types: named methods
(`fish.system.Sprite.destroy`), anonymous event blocks named after their source line
(`EvSheet_gameplay:1141` is the block that fires the tool in hand), and natives (`fish@body_apply_force`).
`mosa.find("text")` searches the same list from Lua.

### React to the game

```lua
ml.on_level(function(layout) end)                       -- a level started
ml.on_update(function(dt) end)                          -- every frame, before the game's own update
ml.on_create("frog", function(inst) end)                -- objects appearing / disappearing
ml.on_destroy("coin", function(inst) end)
ml.on_collision("frog", "player", function(frog, player, hit) end)
ml.on_fire("bomb", function(ctx) end)                   -- a tool was fired
ml.on_game("player_death", function(player_id) end)     -- any named function of the gameplay sheet
ml.on_key("g", function() end)
```

A selector such as `"frog"` can be an object type, a family (the game's groups of types, e.g.
`"physics_obj"`), `"*"`, one object, a function, or a name you defined yourself.

### Use the physics

```lua
ml.set_gravity_scale(0.3)                               -- gravity of everything: 1 normal, 0 weightless, -1 up
b2.launch(inst, 0, -400)                                -- change an object's velocity
b2.set_restitution(inst, 0.9)   ml.set_density(inst, 5)   ml.gravity(inst, 0)   -- this one floats
local hit = b2.raycast(x1, y1, x2, y2)                  -- hit.inst, hit.x, hit.y, hit.distance
local rope = b2.distance(player, hit.inst, { length = 80, frequency = 2 })
b2.add_circle(inst, 60, { sensor = true })              -- an extra shape: here, a detector around it
b2.on_pre_solve(function(contact, a, b) return false end)   -- false: these two pass through each other
```

Pixels, degrees and pixels per second, as everywhere else in the game; forces, impulses and
masses in Box2D's own units, as in the game's physics code. `b2.raw.<native>(...)` is the
library itself (metres, radians) for anything the friendly layer does not cover.

### Give an object its own code, or make a new kind

```lua
ml.attach(inst, {
    tick = function(inst, dt) end,
    collide = function(inst, other, hit) end,
    destroy = function(inst) end,
})

ml.define("heavy_frog", {
    base = "frog",                                      -- the game object it is made from
    init = function(inst) ml.set_density(inst, 20) end,
    collide = function(inst, other, hit) if hit.speed > 300 then ml.explode(hit.x, hit.y, 40) end end,
})
ml.spawn("heavy_frog", x, y)                            -- and "heavy_frog" works in every selector
```

### A tool of your own

A mod can add a tool to the game by itself. `ml.add_tool` puts it into the item pool, so it is
drawn at random like the game's tools, gives it a square in the tool grid, where it can be
pinned, a picture borrowed from one of the game's tools, and its name on screen. What it does
when fired is a function:

```lua
ml.add_tool{
    name = "frog_rain", label = "Frog Rain",       -- the game's name for it / the one shown
    aim = "long", ammo = 2, icon = "frog",         -- cursor mode, shots per level, whose picture
    fire = function(ctx)
        local ax, ay = ctx.aim()                   -- the cursor
        for i = -1, 1 do
            local frog = ml.spawn("frog", ax + i * 24, ay)
            if frog.physics then ml.set_velocity(frog, i * 120, -200) end
        end
    end,
}
```

- `aim` is one of the game's cursor modes: `shoot`, `short`, `short2`, `mid`, `mid2`, `long`,
  `long2`, `remote`. `short`, `mid` and `long` put the cursor at that distance from the player;
  with `shoot` the game also plays its shot sound.
- The pool entry and the picture work at once. The square in the tool grid appears when the
  game is started with the mod in place, since the game builds the grid while it starts.
- `ml.give_tool("frog_rain")` puts a tool into the player's hand, which is the quick way to
  try one. `black_hole.lua` binds that to a key.
- A seeded run draws from a pool that is one tool longer, so a seed gives other tools than it
  does without the mod.
- A tool stays in the pool until the game is closed, also when its mod is switched off in the
  mod menu. Fired without its mod it takes the ammo and does nothing.

`ml.on_fire("bomb", function(ctx) ... end)` adds to what an existing tool does (`"*"` for every
tool). Tools made with the tool patcher GUI work the same way: a combo tool without effects
does nothing by itself, and `ml.on_fire` gives it its behaviour.

### Examples to copy

In `mods\_examples\` (nothing in there is loaded; copy a file into `mods\` to switch it on):

| File | Shows |
|---|---|
| `gravity_gun.lua` | hold G to carry the loose object nearest the crosshair, F to throw it. A fresh level has nothing loose (terrain is fixed, coins are skipped), so shoot a box or a ball first. What you carry turns half transparent and every grab is logged: per-frame code, keys, forces |
| `grapple.lua` | R shoots an elastic rope at whatever is in the way: ray casts, joints between game objects |
| `moon.lua` | low gravity, bouncy objects, slow-motion physics on T: the game's gravity, a hook on a native |
| `black_hole.lua` | a new tool in the item pool, the Black Hole: long aim, one shot. For ten seconds it slowly pulls every tile and object towards the cursor and deletes what reaches its centre; then everything freezes where it is. The player and the fruit are left alone (the exit needs every fruit). B hands you one at once. Shows `ml.add_tool`, letting terrain go and fixing it again, drawing into the level |
| `destruction.lua` | explosions bite round holes out of the tiles: a tile that is hit is rebuilt from small `tile_tiny` objects, solid pieces for what is left and loose pixels for the crater. Shows reading collision shapes, spawning sized objects, copying a tile's colour |
| `extrude3d.lua` | the level with depth: walls drawn behind every solid thing, from its real collision shape, towards a vanishing point (F3 switches it). Shows reading shapes, drawing under the game's own pictures |
| `rewind.lua` | a second new tool, Rewind: the last five seconds run backwards for you and every loose object, at double speed, and carry on from there (Y hands you one). Shows recording and restoring positions and speeds |
| `ink.lua` | a third new tool, Ink: after firing, the cursor draws a solid line into the level for a few seconds (U hands you one). Shows hidden resized tiles for collision with the picture drawn by the mod |
| `avalanche.lua` | a stress test: hold K and balls and boxes pour out of the mouse pointer, each a real body, with a meter for the count and the time every frame takes; L sweeps them away |
| `trip.lua` | hides the game's rotating background and draws an endless colour-cycling tunnel of flower-shaped rings in its place, every frame (F4 switches it) |
| `no_backflips.lua` | switches backflips off the way Director's Cut does, without Director's Cut: replacing one of the game's anonymous event blocks |
| `physics_selftest.lua` | the second-run check described above |
| `patterns.lua` | short cut-and-paste pieces for every part of the API |
| `explore.lua` | writes `explore_classes.txt` (every class with its fields), `explore_objects.txt`, a keyword search of hooks |

All of them run in the automated tests on the physics test game.

## Working on mods

- **The mod menu.** Pause the game: its menu has a new line, **LUA MODS**. Inside is one line
  per mod (`GRAVITY GUN  ON`, `MOON  OFF`, ...): choose one to switch that mod on or off. It
  takes effect at once, and you stay on the same line to switch the next one. `RELOAD ALL`
  runs every mod file again, `BACK` leaves. A mod that failed to load shows `ERROR` (the reason
  is in `mosalua.log`). What you switch off is remembered in `mods\_modmenu.txt`.
- `mods\config.lua` has `dev = true`: saving any `.lua` in `mods\` reloads all mods in the
  running game. The level, its objects and its physics world carry on; your hooks and handlers
  start over.
- Save `mods\_console.lua` to run it once inside the live game; whatever it returns is logged:

  ```lua
  return mosa.dump(ml.player())
  ```
- `mods\hookable.txt`: every hookable function. `mods\natives.txt`: every native function.
- A mod that errors is logged with a traceback and the game carries on; a hook that keeps
  failing is switched off after five errors.
- `API.md` is the full reference.

## How the game is put together

Read from the bytecode; useful when you go beyond the helpers.

- **Objects.** Every object is an instance of `fish.game.oclass.OClass_<type>` with `inst.type`,
  `inst.families`, `inst.uid`, `inst.sprite` (position, size, angle, animation), `inst.physics`
  (or nil) and its own variables (`player.item_selected`, `b_item.ammo`, ...).
- **Layouts.** A level or menu screen is a `fish.system.Layout`: `layout.insts` (type or family
  name to instances), `layout.world` (its Box2D world), `layout.worldScale` (0.02: 50 pixels are
  one metre), `layout.timeScale`. `game.layouts.mainLayout` is the one being played. The next
  layout is built completely, objects included, while the current one is finishing its frame;
  then the game switches.
- **A frame** (`Layout.update`): object ticks, the layout's event sheet, sprite positions copied
  to bodies where game code moved a sprite, the Box2D step (4 velocity and 2 position
  iterations), body positions copied back to sprites, destroyed objects removed.
- **Physics.** Stock Box2D 2.3 with double precision in `fish.hdll`. `inst.physics.body` is the
  object's `b2Body`; each fixture's user data is the game object it belongs to. The game
  installs one contact listener and one contact filter whose callbacks are ordinary static
  functions (`fish.system.ContactListener.beginContact`, ...), which is what makes contact
  events hookable. Objects can also carry their own contact callbacks (`sprite.onBeginContact`,
  ...); explosions, for instance, are objects whose pre-solve callback disables every contact
  and whose begin-contact callback shoves what they touch.
- **Gravity is the game's own, not Box2D's.** When a level starts, the gameplay sheet sets the
  world's gravity to zero. Every frame it then pulls each moving object of the `physics_obj`
  family down with a force taken from the object's own variables:
  `personal_gravity * flipModifier * 1.05` (0.05 while a `low_grav` object exists, less in
  water, nothing in a no-gravity zone). Weight is a property of the object and does not follow
  its mass, which is why `b2.gravity()` says 0, 0 in a level and why `b2.set_gravity` only
  adds to what the game does. Use `ml.set_gravity_scale`, `ml.gravity(inst, f)` and
  `ml.weight(inst)`. Bodies you create yourself with `b2.create_body` have no weight.
- **What can move.** Level tiles are static bodies. Coins have a dynamic body too, although
  they just hang there. In a fresh level usually only the player and the coins are dynamic;
  loose things appear when tools are used.
- **Logic.** Event sheets: `fish.game.evsheet.EvSheet_gameplay` has 78 named functions (`shoot`,
  `jump`, `player_death`, `explosion_fn`, `onToolSelect`, ...) and about 3400 anonymous event
  blocks. A level is a layout whose sheet is the gameplay sheet.
- **Tools.** The tools the player carries are `b_item` instances; `b_item.item.type.name` is the
  tool name, `b_item.ammo` the shots left. The game's first layout holds one `item` object per
  tool (the tool grid); `game.itemManager:initBaseItems` turns them into the item pool
  (`itemManager.itemPool`: name, base ammo, aim type as a number, second layer), and
  `itemManager:pick` draws the three tools in hand from it, pinned ones first. A tool's picture
  is the animation of that name in the table all `item_icon` objects share; its name on screen
  is the text `TOOL_<NAME>`. Firing takes one ammo for any tool, then runs the code for that
  name; a name the game does not know has none. There is no unlock system: every tool is in
  the one pool (second layer tools only in second layer runs).

## GIFs

When you save a GIF the game does not show a recording: it plays the level again, in one go,
in a private copy of itself, from the inputs it recorded, and films that. A mod that changed
what happened has to change it again in that replay, or the film shows a different story (and
usually ends with the player dying somewhere).

So during a replay `ml` follows the copy. `ml.on_level` runs when the replay starts and
`ml.on_level_end` when it is over; per-frame handlers, collisions, level timers, tools,
behaviours and the gravity scale work in it; and `ml.key_down` / `ml.key_pressed` / `ml.on_key`
answer with the keys that were pressed in the level, frame by frame. For that, inside a level's
frame the keyboard is read once per frame for the keys your mods ask about, and written down
next to the game's own recording. `ml.replaying()` is true while it runs. Afterwards `ml`
points at the real game again and the level you were in is as you left it.

A mod replays correctly when everything it does to a level comes from the `ml` events and
`ml.on_update`. Three things are not replayed:

- `math.random` and the clock: the replay would roll different numbers.
- Anything done from `mosa.on("tick")`, `mosa.delay` or `mosa.every`: those follow the real
  frame loop, which does not run during a replay. Use `ml.on_update` and `ml.after`.
- Keys read some other way than through `ml`.

Variables your mod keeps about the current level belong in `ml.vars()`: a table that starts
empty with each level and that a replay gets a fresh copy of, so the replay neither sees nor
clears what belongs to the level being played. `gravity_gun.lua` and `grapple.lua` do this.

## How the patch works

- `mosalua.hdll` is Lua 5.4 plus a bridge that uses HashLink's own runtime reflection.
- Every hookable function gets three instructions at its start: "does a mod hook me?".
  If not, one cheap native call (1 to 3 ns) and the function runs as before.
- Each native of the physics library gets a one-call wrapper function that takes over its place
  in the function table, so the game's calls go through it and it can be hooked like anything
  else. Every other native (SDL, OpenAL, Steam, ...) is handed to the runtime as it is.
- A call that starts Lua is added at the top of the game's `main()`.
- Nothing else changes. With no mods, and also with a do-nothing Lua hook on every single
  function and native, the patched test games produce exactly the output of the unpatched ones.

Hookable: every named method and static function of the game's own code, anonymous
functions, and the physics natives. Left alone by default: the engine and standard library
(`hxd`, `h2d`, `h3d`, `haxe`, `hl`, ...) and functions with more than 9 arguments (mostly object
constructors; use `ml.on_create` instead).

## Limits and things to know

- **Inside a contact callback the physics world is locked.** `b2.on_begin_contact`, `on_pre_solve`
  and the like run in the middle of the Box2D step: nothing can be created or destroyed there
  (the functions refuse with a clear message; `b2.after_step(fn)` defers). `ml.on_collision`,
  `ml.on_separate`, `ml.on_impact` and behaviours run right after the step, where everything is allowed.
- **Bodies, fixtures, joints and contacts are raw pointers** into the physics library. Keep the
  game object, not its body; ask `b2.joint_alive(j)` before using a joint you stored.
- **Do not resize an object you added your own shapes to** (`ml.set_size`): the game rebuilds
  every fixture of a resized object from its sprite and does not know yours.
- Pre-solve and post-solve handlers run for every touching pair, every step: a few
  microseconds each. Begin / end events cost nothing while nothing changes.
- A hooked call costs about 2 microseconds. Fine for a few hundred calls per frame.
- Lua runs on the main thread only.
- Online play and replays: mods that change gameplay will desync. Keep modded play offline.
- Hook names of anonymous functions contain source line numbers, so a game update can shift them.
- The sandbox (no running programs, files only inside `mods\`, only the physics natives) is a
  seatbelt, not a security boundary. Only install mods you trust.
- A game update replaces `hlboot.dat`: patch again.

## What is where

```
<game folder>\hlboot.dat            the patched game code (hlboot.dat.pre_lua: the file it replaced)
<game folder>\mosalua.hdll          the Lua runtime
<game folder>\mods\                 your mods: any .lua file or folder with an init.lua
    config.lua                      settings (dev mode, disabled mods, sandbox)
    diag.lua                        first-run diagnostics; delete it once things work
    luademo.lua                     behaviour for the patcher GUI's "luademo" tool; does nothing without it
    _lib\mosalina.lua, b2.lua       the ml and b2 layers
    _lib\modmenu.lua                LUA MODS in the pause menu
    _modmenu.txt                    which mods you switched off there (written by the menu)
    _examples\                      copy one into mods\ to switch it on
    _docs\                          this guide and API.md
    hookable.txt, natives.txt       every function you can hook, every native you can call
    mosalua.log                     written by the game on every start
```

Names starting with `_` are never loaded as mods. The source of the runtime, the patcher and
the test suites are in the SDK repository.
