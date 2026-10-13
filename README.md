# Mosa Lina Lua modding SDK

[![check](../../actions/workflows/check.yml/badge.svg)](../../actions/workflows/check.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

Write mods for Mosa Lina as plain
`.lua` files. The game is patched once; after that a mod is a file in the game's `mods\` folder,
and saving it reloads it while the game runs.

```lua
-- everything bounces, and bombs stick to what they hit
ml.on_create("*", function(inst)
    if inst.physics then b2.set_restitution(inst, 0.7) end
end)

ml.on_collision("bomb", "*", function(bomb, other, hit)
    if bomb.physics and other.physics and other.type ~= "player" and #b2.joints(bomb) == 0 then
        b2.weld(other, bomb, hit.x, hit.y)
    end
end)
```

A mod can hook any of the game's functions (`mosa`), use the game's Box2D directly (`b2`), and
work with levels, objects, tools, collisions and keys through a game-level API (`ml`), including
new tools in the item pool.

This is an unofficial, community project. It contains no game code and no game assets: the
patcher changes the copy of the game you own, and keeps a backup.

## Install

1. Download [`mosalua_patcher.py`](mosalua_patcher.py) (needs Python 3.6 or later).
2. Close the game and run it: double-click, or `python mosalua_patcher.py "<game folder>"`.
   It keeps the current `hlboot.dat` as `hlboot.dat.pre_lua`, patches it and installs
   `mosalua.hdll` and the `mods\` folder. `--uninstall` puts everything back.
3. Copy a file from [`examples/`](examples) into the game's `mods\` folder (the patcher also
   puts them in `mods\_examples`) and start the game.

`mods\mosalua.log` is written on every start; a mod's errors are in there. Run the patcher again
after a game update.

## Examples

| File | Key | What it is |
|---|---|---|
| [`black_hole.lua`](examples/black_hole.lua) | B | new tool: pulls the whole level into a point for ten seconds, then freezes it |
| [`rewind.lua`](examples/rewind.lua) | Y | new tool: the last five seconds run backwards |
| [`ink.lua`](examples/ink.lua) | U | new tool: draw solid lines into the level with the mouse |
| [`destruction.lua`](examples/destruction.lua) | V | explosions break tiles into pixels that keep the tile's colour |
| [`extrude3d.lua`](examples/extrude3d.lua) | F3 | draws the level and the player with depth |
| [`trip.lua`](examples/trip.lua) | F4 | replaces the rotating background with an animated tunnel |
| [`avalanche.lua`](examples/avalanche.lua) | K / L | stress test: pours bodies out of the mouse pointer, with a frame-time meter |
| [`gravity_gun.lua`](examples/gravity_gun.lua) | G / F | carry and throw loose objects |
| [`grapple.lua`](examples/grapple.lua) | R | elastic rope: ray casts and joints |
| [`moon.lua`](examples/moon.lua) | T | low gravity, bouncy objects, slow motion |
| [`no_backflips.lua`](examples/no_backflips.lua) | | replaces one of the game's anonymous event blocks |
| [`patterns.lua`](examples/patterns.lua) | | short snippets for every part of the API |
| [`physics_selftest.lua`](examples/physics_selftest.lua) | | builds a pendulum outside the level and prints PASS / FAIL |
| [`explore.lua`](examples/explore.lua) | | dumps the game's classes, fields and object types to text files |

The keys and tuning values are constants at the top of each file.

## Documentation

- [Guide](docs/GUIDE.md): writing mods, how the game is put together, GIF replays, how the patch works, limits
- [API reference](docs/API.md): `mosa`, `b2` and `ml`

## Repository layout

```
mosalua_patcher.py      the installer: one file, everything it needs is inside
examples/               example mods
docs/                   guide and API reference
mods/                   what goes into the game's mods folder: the Lua layers (_lib), config.lua, diag.lua
prebuilt/mosalua.hdll   the runtime, built for Windows
src/, lua/, build.sh    source of the runtime
patcher/                the bytecode patcher and the installer
standalone/             builds mosalua_patcher.py from the above
tests/                  the test games and suites (tests/README.md)
```

## Building

- `python standalone/build_standalone.py` rebuilds `mosalua_patcher.py` after a change to
  `mods/`, `examples/`, `docs/` or `patcher/`. It needs nothing but Python.
- `build.sh` builds `mosalua.hdll` from source (needs the Lua 5.4 and HashLink sources and
  MinGW; see the top of the file).
- `tests/run_all.sh linux` runs the suites; `tests/README.md` lists what they need.

## Contributing

Mods, fixes and documentation are welcome: see [CONTRIBUTING.md](CONTRIBUTING.md).

## License

[MIT](LICENSE). The runtime contains Lua; see [THIRD_PARTY.md](THIRD_PARTY.md).
