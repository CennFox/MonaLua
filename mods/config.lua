-- Settings for the Lua runtime.  Delete a line to get its default.
return {
	-- dev mode: saving any .lua file in this folder reloads all mods while the game runs,
	-- and saving _console.lua runs that file once inside the game (results go to mosalua.log)
	dev = true,

	-- mods to skip, by name (file name without .lua, or folder name)
	disabled = {},

	-- function called once per frame, used for timers and the "tick" event.
	-- Leave unset to auto-detect (hxd.App.mainLoop on Heaps games).
	-- tick = "hxd.App.mainLoop",

	-- native libraries of the game that mods may call besides the physics library ("fish"),
	-- e.g. { "sdl", "openal" }.  mods\natives.txt lists every native function.
	native_libs = {},

	-- true removes the sandbox (lets mods run programs, touch any file, call any native). Leave off for mods you did not write.
	unsafe = false,
}
