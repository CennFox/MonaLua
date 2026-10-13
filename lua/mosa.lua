-- mosa.lua -- the modding API that mods see.  Embedded in mosalua.hdll.
-- A copy placed at mods/_runtime/mosa.lua overrides the embedded one.
--
-- `hl`   low level bridge implemented in C (reflection on the game's objects)
-- `mosa` everything a mod normally needs: hooks, events, timers, helpers

local hl = hl
local mosa = { version = hl.version, hl = hl, shared = {} }
_G.mosa = mosa

local sep = hl.sep
local home = hl.home()
local mods_dir = home .. sep .. "mods"
mosa.home, mosa.mods_dir = home, mods_dir

local unpack, pack = table.unpack, table.pack
local raw_loadfile, raw_load, raw_open = loadfile, load, io.open
local traceback = debug.traceback

---------------------------------------------------------------- logging

local function fmt_args(...)
	local t = pack(...)
	for i = 1, t.n do t[i] = tostring(t[i]) end
	return table.concat(t, "\t", 1, t.n)
end

local current_mod = nil     -- mod being loaded / whose callback is running

function mosa.log(...)
	local prefix = current_mod and ("[" .. current_mod.name .. "] ") or ""
	hl.log(prefix .. fmt_args(...))
end
print = mosa.log

local function sys_log(...) hl.log(fmt_args(...)) end

---------------------------------------------------------------- config

local config = { dev = false, unsafe = false, disabled = {}, tick = nil, native_libs = {} }
do
	local path = mods_dir .. sep .. "config.lua"
	local chunk = raw_loadfile(path, "t", {})
	if chunk then
		local ok, res = pcall(chunk)
		if ok and type(res) == "table" then
			for k, v in pairs(res) do config[k] = v end
		elseif not ok then
			sys_log("ERROR in mods/config.lua: " .. tostring(res))
		end
	end
end
mosa.config = config

---------------------------------------------------------------- sandbox

-- Mods are other people's code.  By default they cannot run programs, load
-- native libraries or touch files outside the mods folder.  This is a
-- seatbelt, not a security boundary; set unsafe = true in mods/config.lua
-- to switch it off.
local function mods_path(p)
	if type(p) ~= "string" then error("path must be a string", 3) end
	if p:find("%.%.") or p:find("^[/\\]") or p:find("^%a:") then
		error("mods can only access files inside the mods folder: " .. p, 3)
	end
	return mods_dir .. sep .. p
end

if not config.unsafe then
	os.execute, os.exit, os.remove, os.rename, os.tmpname, os.setlocale = nil, nil, nil, nil, nil, nil
	io.popen, io.tmpfile, io.input, io.output = nil, nil, nil, nil
	package.loadlib, package.cpath = nil, ""
	package.searchers[3], package.searchers[4] = nil, nil
	debug = { traceback = debug.traceback, getinfo = debug.getinfo }
	local rawlines = io.lines
	io.open = function(p, mode) return raw_open(mods_path(p), mode) end
	io.lines = function(p, ...) return rawlines(mods_path(p), ...) end
	loadfile = function(p, mode, ...) return raw_loadfile(mods_path(p), "t", ...) end
	dofile = function(p)
		local f, err = raw_loadfile(mods_path(p), "t")
		if not f then error(err, 2) end
		return f()
	end
	load = function(chunk, name, mode, ...) return raw_load(chunk, name, "t", ...) end
end
package.path = mods_dir .. sep .. "?.lua;" .. mods_dir .. sep .. "?" .. sep .. "init.lua;"
	.. mods_dir .. sep .. "_lib" .. sep .. "?.lua"

local blocked_classes = { ["Sys"] = true }
local function class_allowed(name)
	if config.unsafe then return true end
	return not (blocked_classes[name] or name:find("^sys%."))
end

---------------------------------------------------------------- native functions

-- The game's own native functions (its C/C++ libraries), by "lib@name".  The physics
-- library is always available; other libraries (sdl, openal, steam, std, ...) only when
-- listed in native_libs in mods/config.lua, or with unsafe = true.
local raw_native, raw_natives = hl.native, hl.natives
local native_cache = {}
local native_libs = { fish = true }
local native_names = { ["std@alloc_carray"] = true }
for _, l in ipairs(config.native_libs or {}) do native_libs[l] = true end

--- mosa.native("fish@body_get_angle") -> callable native function, or nil when the game has none of that name
function mosa.native(name)
	local c = native_cache[name]
	if c == nil then
		if type(name) ~= "string" then error("native name must be a string like 'lib@name'", 2) end
		local lib = name:match("^([^@]+)@")
		if not lib then error("native name must look like 'lib@name': " .. name, 2) end
		if not (config.unsafe or native_libs[lib] or native_names[name]) then
			error("native library '" .. lib .. "' is not enabled: add native_libs = { \"" .. lib
				.. "\" } to mods/config.lua", 2)
		end
		c = raw_native(name) or false
		native_cache[name] = c
	end
	return c or nil
end
hl.native = mosa.native

--- mosa.natives([filter]) -> sorted "lib@name" list, optionally filtered by a plain substring
function mosa.natives(filter)
	local out = {}
	filter = filter and filter:lower()
	for _, n in ipairs(raw_natives()) do
		if not filter or n:lower():find(filter, 1, true) then out[#out + 1] = n end
	end
	table.sort(out)
	return out
end

---------------------------------------------------------------- classes & values

local class_cache = {}

--- mosa.class("pkg.Name") -> the class (static fields/functions, callable as constructor) or nil
function mosa.class(name)
	local c = class_cache[name]
	if c == nil then
		c = class_allowed(name) and hl.class(name) or false
		class_cache[name] = c
	end
	return c or nil
end

--- mosa.new("pkg.Name", ...) or mosa.new(class, ...)
function mosa.new(cls, ...)
	if type(cls) == "string" then
		local c = mosa.class(cls)
		if not c then error("unknown class '" .. cls .. "'", 2) end
		cls = c
	end
	return hl.new(cls, ...)
end

mosa.typeof = hl.typeof          -- kind, type name
mosa.classof = hl.classof        -- class object of an instance
mosa.struct = hl.struct          -- Lua table -> anonymous game object  { x = 1 }
mosa.enum = hl.enum              -- mosa.enum("pkg.Enum", "Constructor", params...)
mosa.throw = hl.throw            -- raise an exception inside the game
mosa.NULL = setmetatable({}, { __tostring = function() return "mosa.NULL" end })
mosa.SKIP = setmetatable({}, { __tostring = function() return "mosa.SKIP" end })

--- mosa.is(obj, "pkg.Class") -> true when obj is an instance of the class (or a subclass)
function mosa.is(obj, cls)
	if type(obj) ~= "userdata" then return false end
	return hl.is(obj, cls)
end

--- mosa.classname(obj) -> "pkg.Class" (nil for non objects)
function mosa.classname(obj)
	local kind, name = hl.typeof(obj)
	if kind == "obj" or kind == "enum" or kind == "struct" then return (name:gsub("%$([^.]*)$", "%1")) end
	return nil
end

--- sorted list of class names, optionally filtered by a plain substring
function mosa.classes(filter)
	local out = {}
	filter = filter and filter:lower()
	for _, n in ipairs(hl.classes()) do
		if not filter or n:lower():find(filter, 1, true) then out[#out + 1] = n end
	end
	table.sort(out)
	return out
end

local ArrayDyn

--- mosa.array{1, 2, 3} -> a real Haxe Array the game can use
-- (a dynamic array: the game converts it to Array<Int>, Array<String>, ... where needed)
function mosa.array(t)
	if ArrayDyn == nil then ArrayDyn = hl.class("hl.types.ArrayDyn") or false end
	t = t or {}
	if not ArrayDyn then return hl.narray(t) end
	local arr = hl.new(ArrayDyn)
	local inner = arr.array
	if inner ~= nil and #t > 0 then
		inner.array = hl.narray(t)
		inner.length = #t
	end
	return arr
end

--- mosa.totable(haxeArray) -> Lua list (1 based)
function mosa.totable(arr)
	local out = {}
	if arr == nil then return out end
	for i = 0, #arr - 1 do out[i + 1] = arr[i] end
	return out
end

--- for i, v in mosa.each(x)  -- Haxe arrays (0 based index), native arrays, iterators, Lua tables
function mosa.each(x)
	if type(x) == "table" then return ipairs(x) end
	if x == nil then return function() end end
	local kind = hl.typeof(x)
	if kind ~= "array" then
		local it = x
		if x.hasNext == nil and x.iterator ~= nil then it = x.iterator() end
		if it.hasNext ~= nil then
			local i = -1
			return function()
				if it.hasNext() then
					i = i + 1
					return i, it.next()
				end
			end
		end
	end
	local i, n = -1, #x
	return function()
		i = i + 1
		if i < n then return i, x[i] end
	end
end

hl.setconvert(function(t, hint)
	-- Lua list -> Haxe array, keyed table -> anonymous object
	if #t > 0 or (next(t) == nil and hint == 11) then return mosa.array(t) end
	return hl.struct(t)
end)

--- mosa.fields(obj_or_class) -> sorted list of { name=, type=, method=, class= }
function mosa.fields(obj, statics)
	local f = hl.fields(obj, statics)
	table.sort(f, function(a, b) return a.name < b.name end)
	return f
end

--- mosa.dump(obj [, depth]) -> multi-line description of an object's fields
function mosa.dump(obj, depth, indent, seen)
	depth, indent, seen = depth or 1, indent or "", seen or {}
	if type(obj) ~= "userdata" or hl.isexception(obj) then return tostring(obj) end
	local kind, name = hl.typeof(obj)
	if kind ~= "obj" and kind ~= "dynobj" and kind ~= "virtual" and kind ~= "struct" then return tostring(obj) end
	if seen[obj] or depth < 0 then return "<" .. tostring(name) .. ">" end
	seen[obj] = true
	local lines = { "<" .. tostring(name) .. "> {" }
	for _, f in ipairs(mosa.fields(obj, true)) do
		if not f.method then
			local ok, v = pcall(function() return obj[f.name] end)
			local s
			if not ok then s = "<error>"
			elseif type(v) == "string" then s = string.format("%q", v)
			else s = mosa.dump(v, depth - 1, indent .. "  ", seen) end
			lines[#lines + 1] = indent .. "  " .. f.name .. " = " .. s
		end
	end
	lines[#lines + 1] = indent .. "}"
	return table.concat(lines, "\n")
end

---------------------------------------------------------------- hooks

local hooks = {}      -- id -> { entries... }
local chains = {}     -- id -> function(orig, ...)
local all_names       -- name -> id (built on first use)
local short_names     -- "Class.method" -> { ids }

local function index_names()
	if all_names then return end
	all_names, short_names = {}, {}
	for id = 0, hl.nhooks() - 1 do
		local n = hl.hookname(id)
		all_names[n] = id
		-- "Class.method" for methods, "File:line" for anonymous functions
		local short = n:find(":", 1, true) and n:match("([^.]+)$") or n:match("([^.]+%.[^.]+)$")
		if short and short ~= n then
			local l = short_names[short]
			if not l then l = {}; short_names[short] = l end
			l[#l + 1] = id
		end
	end
end

--- mosa.find("jump") -> sorted list of hookable function names containing the text
function mosa.find(text)
	index_names()
	local out = {}
	text = (text or ""):lower()
	for n in pairs(all_names) do
		if n:lower():find(text, 1, true) then out[#out + 1] = n end
	end
	table.sort(out)
	return out
end

--- mosa.hookable("pkg.Class.method") -> true when that function can be hooked
function mosa.hookable(name)
	index_names()
	return all_names[name] ~= nil or (short_names[name] ~= nil and #short_names[name] == 1)
end

local function resolve(name)
	if type(name) ~= "string" then error("hook name must be a string", 3) end
	index_names()
	local id = all_names[name]
	if id then return id, name end
	local l = short_names[name]
	if l and #l == 1 then return l[1], hl.hookname(l[1]) end
	if l then
		local c = {}
		for i = 1, math.min(#l, 8) do c[i] = hl.hookname(l[i]) end
		error("'" .. name .. "' is ambiguous, use the full name: " .. table.concat(c, ", "), 3)
	end
	local method = name:match("([^.]+)$") or name
	local near = mosa.find("." .. method)
	local hint = ""
	if #near > 0 then
		hint = " -- did you mean: " .. table.concat(near, ", ", 1, math.min(#near, 6))
	end
	error("no hookable function named '" .. name .. "'" .. hint, 3)
end

local function err_handler(e)
	if hl.isexception(e) then return e end
	return traceback(tostring(e), 2)
end

local rebuild

local function report(entry, err)
	entry.errors = entry.errors + 1
	err = tostring(err)
	if entry.errors > 1 then err = err:match("^[^\n]*") end   -- full traceback only the first time
	hl.log(string.format("ERROR in hook %s (mod %s): %s", entry.name, entry.mod and entry.mod.name or "?", err))
	if entry.errors >= 5 and not entry.removed then
		hl.log(string.format("hook %s of mod %s disabled after %d errors", entry.name, entry.mod and entry.mod.name or "?", entry.errors))
		entry.remove()
	end
end

local function compose(list)
	local chain = function(orig, ...) return orig(...) end
	for i = 1, #list do
		local entry, inner = list[i], chain
		local fn = entry.fn
		chain = function(orig, ...)
			local called, result = false, nil
			local function nxt(...)
				called = true
				result = inner(orig, ...)
				return result
			end
			local prev = current_mod
			current_mod = entry.mod
			local ok, r = xpcall(fn, err_handler, nxt, ...)
			current_mod = prev
			if ok then
				if r == mosa.NULL then return nil end
				-- a hook that ran the original but returned nothing passes the result through
				if r == nil and called then return result end
				return r
			end
			if hl.isexception(r) then error(r, 0) end
			report(entry, r)
			if called then return result end
			return inner(orig, ...)
		end
	end
	return chain
end

rebuild = function(id)
	local list = hooks[id]
	if not list or #list == 0 then
		hooks[id], chains[id] = nil, nil
		hl.sethook(id, false)
		return
	end
	table.sort(list, function(a, b)
		if a.priority ~= b.priority then return a.priority < b.priority end
		return a.seq < b.seq
	end)
	chains[id] = compose(list)
	hl.sethook(id, true)
end

hl.setdispatch(function(id, orig, ...)
	local c = chains[id]
	if c then return c(orig, ...) end
	return orig(...)
end)

local seq = 0
local function add_hook(name, fn, opts, kind)
	if type(fn) ~= "function" then error("hook needs a function", 3) end
	local id, full = resolve(name)
	seq = seq + 1
	local entry = { fn = fn, name = full, id = id, mod = current_mod, kind = kind, errors = 0,
		priority = opts and opts.priority or 0, seq = seq }
	function entry.remove()
		if entry.removed then return end
		entry.removed = true
		local list = hooks[id]
		if list then
			for i = #list, 1, -1 do
				if list[i] == entry then table.remove(list, i) end
			end
			rebuild(id)
		end
	end
	local list = hooks[id]
	if not list then list = {}; hooks[id] = list end
	list[#list + 1] = entry
	rebuild(id)
	return entry
end

--- mosa.hook(name, function(orig, self, ...) ... return orig(self, ...) end [, {priority=n}])
-- Wraps a game function.  Call orig(...) to run the game's own code (or the next
-- mod's hook); skip the call to replace it.  The value you return is what the game gets.
function mosa.hook(name, fn, opts)
	return add_hook(name, fn, opts, "wrap")
end

--- mosa.before(name, function(self, ...) end)
-- Runs before the game function.  `return mosa.SKIP, value` cancels the call.
function mosa.before(name, fn, opts)
	return add_hook(name, function(nxt, ...)
		local a, b = fn(...)
		if a == mosa.SKIP then return b end
		return nxt(...)
	end, opts, "before")
end

--- mosa.after(name, function(result, self, ...) end)
-- Runs after the game function.  Return a value to replace the result
-- (mosa.NULL to replace it with null); return nothing to leave it alone.
function mosa.after(name, fn, opts)
	return add_hook(name, function(nxt, ...)
		local ret = nxt(...)
		local r = fn(ret, ...)
		if r ~= nil then return r end
		return ret
	end, opts, "after")
end

--- mosa.replace(name, function(self, ...) end) -- the game function no longer runs
function mosa.replace(name, fn, opts)
	return add_hook(name, function(_, ...) return fn(...) end, opts, "replace")
end

--- mosa.unhook(handle)
function mosa.unhook(entry)
	if entry and entry.remove then entry.remove() end
end

--- mosa.trace(name) -- log every call of a game function with its arguments (debug aid)
function mosa.trace(name)
	return add_hook(name, function(nxt, ...)
		local ret = nxt(...)
		hl.log("TRACE " .. name .. "(" .. fmt_args(...) .. ") -> " .. tostring(ret))
		return ret
	end, { priority = 1000 }, "trace")
end

---------------------------------------------------------------- events

local listeners = {}

local function safe_call(mod, what, fn, ...)
	local prev = current_mod
	current_mod = mod
	local ok, r = xpcall(fn, err_handler, ...)
	current_mod = prev
	if not ok then
		if hl.isexception(r) then
			hl.log(string.format("ERROR in %s (mod %s): %s", what, mod and mod.name or "?", tostring(r)))
		else
			hl.log(string.format("ERROR in %s (mod %s): %s", what, mod and mod.name or "?", tostring(r)))
		end
		return nil
	end
	return r
end

local ensure_tick

--- mosa.on(event, fn) -> handle with :remove()
function mosa.on(event, fn)
	if type(fn) ~= "function" then error("mosa.on needs a function", 2) end
	local l = listeners[event]
	if not l then l = {}; listeners[event] = l end
	local entry = { fn = fn, mod = current_mod, event = event }
	function entry.remove()
		for i = #l, 1, -1 do if l[i] == entry then table.remove(l, i) end end
	end
	l[#l + 1] = entry
	if event == "tick" then ensure_tick() end
	return entry
end

--- mosa.bind(fn [, what]) -> a function that runs fn on behalf of the calling mod: errors are
-- logged with the mod's name instead of propagating (libraries wrap the callbacks mods give them)
function mosa.bind(fn, what)
	if type(fn) ~= "function" then error("mosa.bind needs a function", 2) end
	local mod = current_mod
	what = what or "callback"
	return function(...) return safe_call(mod, what, fn, ...) end
end

--- mosa.current_mod() -> info table of the mod whose code is running (nil for library code)
function mosa.current_mod() return current_mod end

--- mosa.emit(event, ...) -- call every listener; mods can use this to talk to each other
function mosa.emit(event, ...)
	local l = listeners[event]
	if not l then return end
	for _, e in ipairs({ unpack(l) }) do
		safe_call(e.mod, "event '" .. tostring(event) .. "'", e.fn, ...)
	end
end

---------------------------------------------------------------- frame tick & timers

local timers = {}
local tick_hook, tick_warned
local last_clock = os.clock()
local now = 0
local dev_poll

local function on_frame()
	local c = os.clock()
	local dt = c - last_clock
	last_clock = c
	local T = mosa.class("hxd.Timer")
	if T then
		local ok, v = pcall(function() return T.dt end)
		if ok and type(v) == "number" and v > 0 then dt = v end
	end
	now = now + dt
	if #timers > 0 then
		for _, t in ipairs({ unpack(timers) }) do
			if not t.cancelled and now >= t.at then
				if t.interval then t.at = now + t.interval else t.cancelled = true end
				safe_call(t.mod, "timer", t.fn)
			end
		end
		for i = #timers, 1, -1 do
			if timers[i].cancelled then table.remove(timers, i) end
		end
	end
	mosa.emit("tick", dt)
	if dev_poll then dev_poll(dt) end
end

ensure_tick = function()
	if tick_hook then return true end
	local candidates = { config.tick, "hxd.App.mainLoop", "hxd.App.update", "haxe.MainLoop.tick" }
	local saved = current_mod
	current_mod = nil
	for i = 1, 4 do
		local name = candidates[i]
		if name and mosa.hookable(name) then
			tick_hook = add_hook(name, function(nxt, ...)
				local r = nxt(...)
				on_frame()
				return r
			end, { priority = -1000 }, "tick")
			sys_log("frame tick attached to " .. tick_hook.name)
			break
		end
	end
	current_mod = saved
	if not tick_hook and not tick_warned then
		tick_warned = true
		sys_log("WARNING: no per-frame function found; timers and 'tick' events will not fire. "
			.. "Set tick = \"pkg.Class.method\" in mods/config.lua")
	end
	return tick_hook ~= nil
end

local function add_timer(seconds, fn, interval)
	if type(fn) ~= "function" then error("timer needs a function", 3) end
	ensure_tick()
	local t = { at = now + seconds, fn = fn, interval = interval, mod = current_mod }
	function t.cancel() t.cancelled = true end
	timers[#timers + 1] = t
	return t
end

--- mosa.delay(seconds, fn) -> handle with :cancel()
function mosa.delay(seconds, fn) return add_timer(seconds, fn, nil) end
--- mosa.every(seconds, fn) -> handle with :cancel()
function mosa.every(seconds, fn) return add_timer(seconds, fn, seconds) end
--- mosa.next_frame(fn)
function mosa.next_frame(fn) return add_timer(0, fn, nil) end
--- seconds of game time since startup (advances with the frame tick)
function mosa.time() return now end

---------------------------------------------------------------- mod loading

local mods = {}
mosa.mods = mods

local function scan()
	local found = {}
	local entries = hl.listdir(mods_dir)
	table.sort(entries, function(a, b) return a.name:lower() < b.name:lower() end)
	for _, e in ipairs(entries) do
		local n = e.name
		local first = n:sub(1, 1)
		if first ~= "_" and first ~= "." then
			if e.dir then
				for _, main in ipairs({ "init.lua", "main.lua" }) do
					local p = mods_dir .. sep .. n .. sep .. main
					if hl.mtime(p) then
						found[#found + 1] = { name = n, path = p, dir = mods_dir .. sep .. n }
						break
					end
				end
			elseif n:match("%.lua$") and n ~= "config.lua" then
				found[#found + 1] = { name = n:sub(1, -5), path = mods_dir .. sep .. n, dir = mods_dir }
			end
		end
	end
	return found
end

local function load_mod(info)
	if config.disabled then
		for _, d in ipairs(config.disabled) do
			if d == info.name then
				sys_log("mod " .. info.name .. " is disabled in config.lua")
				return
			end
		end
	end
	local env = setmetatable({ MOD = info }, { __index = _G })
	local chunk, err = raw_loadfile(info.path, "t", env)
	if not chunk then
		sys_log("ERROR loading mod " .. info.name .. ": " .. tostring(err))
		info.error = err
		return
	end
	info.env = env
	local prev = current_mod
	current_mod = info
	local ok, res = xpcall(chunk, err_handler)
	current_mod = prev
	if not ok then
		sys_log("ERROR in mod " .. info.name .. ": " .. tostring(res))
		info.error = tostring(res)
	else
		if type(res) == "table" then info.exports = res end
		sys_log("loaded mod " .. info.name)
	end
	mods[#mods + 1] = info
	mods[info.name] = info
end

local function load_lib()
	local dir = mods_dir .. sep .. "_lib"
	local entries = hl.listdir(dir)
	table.sort(entries, function(a, b) return a.name:lower() < b.name:lower() end)
	for _, e in ipairs(entries) do
		if not e.dir and e.name:match("%.lua$") then
			local chunk, err = raw_loadfile(dir .. sep .. e.name, "t")
			if not chunk then
				sys_log("ERROR loading _lib/" .. e.name .. ": " .. tostring(err))
			else
				local ok, res = xpcall(chunk, err_handler)
				if not ok then sys_log("ERROR in _lib/" .. e.name .. ": " .. tostring(res)) end
			end
		end
	end
end

local std_loaded = {}
for k in pairs(package.loaded) do std_loaded[k] = true end

local function unload_all()
	mosa.emit("unload")
	for _, m in ipairs(mods) do
		if m.exports and type(m.exports.unload) == "function" then
			safe_call(m, "unload", m.exports.unload)
		end
	end
	for id, list in pairs(hooks) do
		for i = #list, 1, -1 do
			if list[i].mod ~= nil or list[i].kind ~= "tick" then
				list[i].removed = true
				table.remove(list, i)
			end
		end
	end
	for id in pairs(hooks) do rebuild(id) end
	for ev, l in pairs(listeners) do
		for i = #l, 1, -1 do table.remove(l, i) end
	end
	for i = #timers, 1, -1 do table.remove(timers, i) end
	for k in pairs(package.loaded) do
		if not std_loaded[k] then package.loaded[k] = nil end
	end
	for i = #mods, 1, -1 do mods[mods[i].name] = nil; mods[i] = nil end
	mosa.shared = {}
end

local function load_all()
	load_lib()
	for _, info in ipairs(scan()) do load_mod(info) end
	mosa.emit("ready")
end

--- mosa.reload() -- drop every hook/timer/listener and load all mods again
function mosa.reload()
	sys_log("reloading mods")
	unload_all()
	load_all()
end

--- mosa.mod(name) -> the table a mod returned from its main file (lets mods offer an API)
function mosa.mod(name)
	local m = mods[name]
	return m and m.exports or nil
end

---------------------------------------------------------------- dev mode

-- dev = true in mods/config.lua:
--   * saving any .lua file in the mods folder reloads all mods
--   * saving mods/_console.lua runs it once inside the running game
if config.dev then
	local stamps, console_stamp, acc = {}, nil, 0
	local function snapshot()
		local s = {}
		local function walk(dir, depth)
			for _, e in ipairs(hl.listdir(dir)) do
				local p = dir .. sep .. e.name
				if e.dir then
					if depth < 2 and e.name:sub(1, 1) ~= "." then walk(p, depth + 1) end
				elseif e.name:match("%.lua$") and e.name ~= "_console.lua" then
					s[p] = hl.mtime(p)
				end
			end
		end
		walk(mods_dir, 0)
		return s
	end
	stamps = snapshot()
	console_stamp = hl.mtime(mods_dir .. sep .. "_console.lua")
	dev_poll = function(dt)
		acc = acc + dt
		if acc < 0.5 then return end
		acc = 0
		local cpath = mods_dir .. sep .. "_console.lua"
		local cs = hl.mtime(cpath)
		if cs and cs ~= console_stamp then
			console_stamp = cs
			local chunk, err = raw_loadfile(cpath, "t", setmetatable({}, { __index = _G }))
			if not chunk then
				sys_log("console: " .. tostring(err))
			else
				local ok, res = xpcall(chunk, err_handler)
				if not ok then sys_log("console ERROR: " .. tostring(res))
				elseif res ~= nil then sys_log("console => " .. tostring(res)) end
			end
		end
		local s = snapshot()
		local changed = false
		for p, t in pairs(s) do if stamps[p] ~= t then changed = true end end
		for p in pairs(stamps) do if s[p] == nil then changed = true end end
		if changed then
			stamps = s
			mosa.reload()
		end
	end
end

---------------------------------------------------------------- start

sys_log(string.format("runtime ready: %d hookable functions, %d native functions, %d classes%s%s", hl.nhooks(), #raw_natives(), #hl.classes(),
	config.dev and ", dev mode" or "", config.unsafe and ", UNSAFE" or ""))
load_all()
if config.dev then ensure_tick() end
