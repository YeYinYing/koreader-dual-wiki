#!/usr/bin/env luajit
-- Local luacheck runner that mirrors the CI step (luacheck 0.26.x, lua51 std).
-- CI installs luacheck via luarocks; locally we run it against the 5.1-ABI
-- LuaJIT plus KOReader's own lfs module. Env: LUACHECK_SRC (luacheck source
-- tree), LFS_SO (path to libkoreader-lfs.so). Usage:
--   luajit tools/luacheck_runner.lua
package.cpath = os.getenv("LFS_SO") .. ";" .. package.cpath
package.path = os.getenv("LUACHECK_SRC") .. "/src/?.lua;" ..
    os.getenv("LUACHECK_SRC") .. "/src/?/init.lua;" .. package.path

local luacheck = require("luacheck")
local config = require("luacheck.config")

-- Load .luacheckrc relative to this repo root (parent of tools/).
local root = arg[0]:match("^(.*)/tools/luacheck_runner%.lua$") or "."
local rc = config.load_config(root .. "/.luacheckrc")
if not rc then
    io.stderr:write("cannot load .luacheckrc from " .. root .. "\n")
    os.exit(2)
end

local files = {}
for _, pattern in ipairs({"dual_wiki.koplugin", "tests"}) do
    local p = io.popen("find '" .. root .. "/" .. pattern .. "' -name '*.lua' -not -path '*/locale/*'")
    for path in p:lines() do
        table.insert(files, path)
    end
    p:close()
end

local report = luacheck.check_files(files, {std = "lua51", globals = {"G_reader_settings", "G_defaults"},
    unused_args = false, max_line_length = 140})

local ok = true
for i, file_report in ipairs(report) do
    for _, issue in ipairs(file_report) do
        ok = false
        print(string.format("%s:%d:%d: (%s) %s",
            files[i], issue.line, issue.column, issue.code, issue.msg or issue.name or "issue"))
    end
end

if ok then
    print("luacheck: " .. #files .. " files, no issues")
    os.exit(0)
else
    io.stderr:write("luacheck found issues\n")
    os.exit(1)
end
