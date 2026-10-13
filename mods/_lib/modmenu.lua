-- modmenu.lua -- "LUA MODS" in the game's own pause menu: switch single mods on and off and
-- reload them, without leaving the game.  Loaded before every mod, like the other libraries.
--
-- The pause menu is the game's (fish.system.PauseMenu, built on its small menu library "bib"):
-- menu:addItem(text) adds a line, menu:addSub(parent, text) a line of that item's sub-menu, and
-- every item carries the functions the menu calls: item.exec when it is chosen, item.back to
-- leave.  So the mod list looks and works like the rest of the menu, pauses the game with it,
-- and follows whatever keys or pad the player uses there.
--
-- Which mods are off is kept in mods/_modmenu.txt ("off <name>" / "on <name>" lines, on top of
-- the `disabled` list in config.lua).  Switching one reloads all mods: hooks, handlers and
-- timers of the old set are dropped and the files are run again.

local M = {}
_G.modmenu = M

local ROOT, STATE_FILE = "LUA MODS", "_modmenu.txt"
local sep = package.config:sub(1, 1)

-- what has to survive a reload of the mods: the items we put into the menu, and config.lua's own list
local state = rawget(_G, "__modmenu_state")
if not state then
	state = { base = {}, items = {} }
	for _, name in ipairs(mosa.config.disabled or {}) do state.base[name] = true end
	rawset(_G, "__modmenu_state", state)
end

local function log(msg) hl.log("[mods] " .. msg) end

-- this file is loaded before mosalina.lua, which would otherwise name the game's frame function
mosa.config.tick = mosa.config.tick or "fish.system.Main.mainLoop"

local ready = false                      -- have the mods been loaded (so a missing one failed to load)

---------------------------------------------------------------- which mods are on

local function state_path()
	-- with the sandbox on, io.open takes paths inside the mods folder
	if mosa.config.unsafe then return mosa.mods_dir .. sep .. STATE_FILE end
	return STATE_FILE
end

local function read_choices()
	local off, on = {}, {}
	local f = io.open(state_path(), "r")
	if f then
		for line in f:lines() do
			local what, name = line:match("^(%a+)%s+(.-)%s*$")
			if what == "off" and name ~= "" then off[name] = true elseif what == "on" and name ~= "" then on[name] = true end
		end
		f:close()
	end
	return off, on
end

local function write_choices(off, on)
	local lines = { "# Written by the mod menu (LUA MODS in the game's pause menu).  Delete this file to forget it." }
	local names = {}
	for name in pairs(off) do names[#names + 1] = "off " .. name end
	for name in pairs(on) do names[#names + 1] = "on " .. name end
	table.sort(names)
	for _, l in ipairs(names) do lines[#lines + 1] = l end
	local f, err = io.open(state_path(), "w")
	if not f then log("cannot write " .. STATE_FILE .. ": " .. tostring(err)); return false end
	f:write(table.concat(lines, "\n"), "\n")
	f:close()
	return true
end

local off, on = read_choices()

local function is_off(name)
	if on[name] then return false end
	return off[name] == true or state.base[name] == true
end

--- modmenu.mods() -> every mod in the mods folder, in load order: { name =, enabled =, error = }
function M.mods()
	local out = {}
	local entries = hl.listdir(mosa.mods_dir)
	table.sort(entries, function(a, b) return a.name:lower() < b.name:lower() end)
	for _, e in ipairs(entries) do
		local n = e.name
		local first = n:sub(1, 1)
		local name
		if first ~= "_" and first ~= "." then
			if e.dir then
				if hl.mtime(mosa.mods_dir .. sep .. n .. sep .. "init.lua") or hl.mtime(mosa.mods_dir .. sep .. n .. sep .. "main.lua") then name = n end
			elseif n:match("%.lua$") and n ~= "config.lua" then
				name = n:sub(1, -5)
			end
		end
		if name then
			local loaded, enabled = mosa.mods[name], not is_off(name)
			local err = loaded and loaded.error or nil
			if ready and enabled and not loaded then err = "did not load" end       -- e.g. a syntax error
			out[#out + 1] = { name = name, enabled = enabled, error = err }
		end
	end
	return out
end

--- modmenu.enabled(name) -> is that mod switched on
function M.enabled(name) return not is_off(name) end

local reload_wanted = false

--- modmenu.set(name, enabled) -- switch one mod; all mods are reloaded at the next frame
function M.set(name, enabled)
	if enabled then
		off[name] = nil
		on[name] = state.base[name] and true or nil      -- only needed to overrule config.lua
	else
		on[name] = nil
		off[name] = true
	end
	write_choices(off, on)
	reload_wanted = true
end

--- modmenu.reload() -- run every mod file again at the next frame
function M.reload() reload_wanted = true end

-- the loader skips what is in config.disabled: hand it our list before it loads the mods
do
	local list, names = {}, {}
	for _, m in ipairs(M.mods()) do
		if not m.enabled then
			list[#list + 1] = m.name
			if not state.base[m.name] then names[#names + 1] = m.name end
		end
	end
	mosa.config.disabled = list
	if #names > 0 then log("switched off in the mod menu (the loader reports them as disabled): " .. table.concat(names, ", ")) end
end

---------------------------------------------------------------- the menu

-- the menu font is the game's: capitals, digits and little else are certain to be in it
local function label(text)
	return (text:upper():gsub("[^A-Z0-9 ]", " "):gsub("%s+", " "):gsub("^ ", ""):gsub(" $", ""))
end

local function mod_label(m)
	return label(m.name) .. (m.error and "  ERROR" or (m.enabled and "  ON" or "  OFF"))
end

local function find_menu()
	local Main = mosa.class("fish.system.Main")
	local main = Main and Main.i
	if main == nil and rawget(_G, "ml") then main = ml.main end
	return main and main.menu or nil
end

local function index_of(menu, item)
	if item == nil then return -1 end
	return menu.items:indexOf(item, nil)
end

-- what one of our sub-menu lines does: set anew at every load, since the functions of the load
-- before are gone
local function bind(i, it, mods)
	local leave = state.leaves[i]                -- the menu's own "leave this sub-menu", kept from when the line was made
	local function back(item) state.open = false; leave(item) end
	it.back = back
	local kind = state.kinds[i]
	local run
	if kind == "reload" then
		run = function() log("reload asked for in the menu"); M.reload() end
	elseif kind == "back" then
		it.exec = back                           -- choosing it leaves, like the game's own BACK lines
		return
	else
		local m
		for _, x in ipairs(mods) do if x.name == kind then m = x end end
		if m == nil then
			it:set_text(label(kind) .. "  GONE")
			run = function() end
		else
			it:set_text(mod_label(m))
			run = function(item)
				local now = not M.enabled(m.name)
				m.enabled, m.error = now, nil
				item:set_text(mod_label(m))
				log((now and "on: " or "off: ") .. m.name)
				M.set(m.name, now)
			end
		end
	end
	it.exec = function(item)
		local ok, err = pcall(run, item)
		if not ok then log("menu: " .. tostring(err)) end
	end
end

--- modmenu.install(menu) -- builds the LUA MODS entry in that menu; returns its root item.
-- The lines are made once per game session.  After a reload of the mods the same lines are
-- kept and only given their new functions and texts: taking lines out of the game's menu and
-- putting new ones in upsets it.  (A mod file added while the game runs gets its line at the
-- next start; until then it is simply loaded.)
function M.install(menu)
	local mods = M.mods()
	if state.menu == menu and state.items[1] ~= nil then
		for i = 2, #state.items do bind(i, state.items[i], mods) end
		local open = state.open_fn
		state.items[1].exec = function(item) state.open = true; open(item) end
		return state.items[1]
	end
	local items, leaves, kinds = {}, {}, {}
	local root = menu:addItem(ROOT)
	items[1] = root
	-- above the credits rather than below EXIT, when the menu has that line
	local at = index_of(menu, menu.credits)
	if at >= 0 then
		menu.items:remove(root)
		menu.items:insert(at, root)
		if menu.selection >= at then
			menu.items[menu.selection].selected = false
			menu.selection = menu.selection + 1
			menu.items[menu.selection].selected = true
		end
	end
	local function sub(text, kind)
		local it = menu:addSub(ROOT, text)
		local n = #items + 1
		items[n], leaves[n], kinds[n] = it, it.back, kind
	end
	for _, m in ipairs(mods) do sub(mod_label(m), m.name) end
	sub("RELOAD ALL", "reload")
	sub("BACK", "back")
	state.items, state.leaves, state.kinds, state.menu = items, leaves, kinds, menu
	state.open_fn = root.exec                    -- addSub made the root open its sub-menu
	state.open = false
	for i = 2, #items do bind(i, items[i], mods) end
	local open = state.open_fn
	root.exec = function(item) state.open = true; open(item) end
	return root
end

-- The menu exists once the game has built its main object; try when the mods are loaded and
-- then every frame until it worked.  A reload asked for from the menu happens here too, at
-- the start of a frame, outside the menu's own code.
local installed = false
local function try_install()
	if installed then return end
	local ok, menu = pcall(find_menu)
	if not ok or menu == nil then return end
	installed = true
	local ok2, err = pcall(M.install, menu)
	if not ok2 then log("could not add the mod list to the pause menu: " .. tostring(err)) end
end

mosa.on("ready", function()
	ready = true
	try_install()
end)
mosa.on("tick", function()
	if reload_wanted then
		reload_wanted = false
		mosa.reload()                            -- runs this file again, which gives the menu lines their new functions
		return
	end
	try_install()
end)
