-- explore.lua -- copy to the mods folder to write reference files next to it:
--   explore_classes.txt   every class in the game with its fields and methods
--   explore_hooks.txt     hookable functions whose name contains one of the words below
--   explore_objects.txt   every object type ml.spawn() can create
-- Folders and files starting with "_" are never loaded, which is why this one is inactive here.
local words = { "tool", "item", "spawn", "player", "level", "fire", "shoot" }

local out = io.open("explore_classes.txt", "w")
for _, name in ipairs(mosa.classes()) do
	local cls = mosa.class(name)
	if cls then
		out:write(name, hl.super(cls) and (" extends " .. hl.super(cls)) or "", "\n")
		local ok, fields = pcall(mosa.fields, cls)
		if ok then
			for _, f in ipairs(fields) do
				if f.class == name then
					out:write("    ", f.name, f.method and "()" or (": " .. tostring(f.type)), "\n")
				end
			end
		end
	end
end
out:close()

out = io.open("explore_hooks.txt", "w")
for _, w in ipairs(words) do
	out:write("== ", w, "\n")
	for _, n in ipairs(mosa.find(w)) do out:write("    ", n, "\n") end
end
out:close()
out = io.open("explore_objects.txt", "w")
for _, n in ipairs(ml.spawnable()) do out:write(n, "\n") end
out:close()
print("explore: wrote explore_classes.txt, explore_hooks.txt and explore_objects.txt")
