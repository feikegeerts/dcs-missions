-- Lists every global name a Lua file reads or writes, from luac5.1 bytecode.
--
-- luacheck is the project's configured linter, but its luafilesystem dependency
-- does not build on this machine (no MSVC toolchain for the rock), so this is
-- the fallback used to prove a file introduces no accidental globals.
--
-- Usage (from the repository root):
--   lua5.1 tests/lua/check-globals.lua src/missions/helicopter-training/*.lua
--
-- Compare the output against read_globals in .luacheckrc. Anything else is a
-- typo or an undeclared dependency.

local names = {}

local function scan(path)
  local pipe = io.popen(string.format('luac5.1 -l -p "%s" 2>&1', path))
  assert(pipe, "cannot run luac5.1")
  for line in pipe:lines() do
    local global = line:match("GETGLOBAL%s+%d+%s+%-?%d+%s*;%s*([%w_]+)")
      or line:match("SETGLOBAL%s+%d+%s+%-?%d+%s*;%s*([%w_]+)")
    if global then
      names[global] = true
    end
  end
  pipe:close()
end

for _, path in ipairs(arg) do
  scan(path)
end

local sorted = {}
for name in pairs(names) do
  sorted[#sorted + 1] = name
end
table.sort(sorted)
print(table.concat(sorted, "\n"))
