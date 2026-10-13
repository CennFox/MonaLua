# Contributing

Mods, fixes and documentation are all welcome.

## Adding an example mod

1. Fork the repository and make a branch.
2. Put the mod in `examples/` as one `.lua` file. Follow the files already there:
   - a comment at the top that says what the mod does and which keys it uses;
   - tuning values as named constants right below it;
   - use `ml` and `b2` where they cover what you need, `mosa.hook` where they do not;
   - anything a level creates must be gone when the level ends (`ml.on_level_end`, `ml.vars()`).
3. Add a line for it to the table in `README.md`.
4. Try it in the game, including a restart of the level, a mod reload and a GIF export.
5. Open a pull request and say what you tested.

## Changing the runtime or the Lua layers

- `mods/_lib/` holds `mosalina.lua` (`ml`), `b2.lua` and `modmenu.lua`;
  `src/` and `lua/` hold the native runtime and `mosa.lua`; `patcher/` the bytecode patcher.
- Run the suites before opening a pull request: `tests/run_all.sh linux` (see `tests/README.md`
  for what they need). New behaviour should come with checks.
- A change to `mods/`, `examples/`, `docs/` or `patcher/` needs `mosalua_patcher.py` rebuilt
  (`python standalone/build_standalone.py`).
- Document new API in `docs/API.md`.

## Reporting a bug

Open an issue with the game version, what you did, and `mods\mosalua.log` from that run.

## What does not belong here

No game files: no `hlboot.dat` (patched or not), no decompiled game code, no game art or
sound. The SDK patches the copy of the game a player owns and ships nothing of the game itself.
