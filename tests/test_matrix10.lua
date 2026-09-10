-- test_matrix10.lua — P2-8: 10组划词矩阵回归 (方案A 模糊容错审计, v1.3.5)
--
-- The 10 selections from the P2 checklist run through the REAL queryPipeline
-- (same entry the plugin uses) inside the emulator runtime, against the real
-- network. Offline sanitation for the same 10 selections lives in
-- tests/test_query_helpers.lua (cases 1-10); this file is the online half.
--
--   1  《三体》                  书名号剥离 → 三体
--   2  “人工智能”                中文引号剥离 → 人工智能
--   3  【凉宫春日的忧郁】        方头括号剥离 → 凉宫春日*  (moegirl ACG 引擎)
--   4  量子力学的                末尾助词降级 → 量子力学
--   5  拿破仑·波拿巴             间隔号保留 → 拿破仑*
--   6  Re:从零开始的异世界生活   冒号保留 → Re:从零*/从零
--   7  小笠原道                  少选一字 → 降级不崩（前缀噪音可接受）
--   8  Fate/stay night           斜杠保留 → Fate*
--   9  魔戒 (book lang zh-Hant)  繁体 variant 路径 → 魔戒
--   10 黑神话                   宽泛词 → 黑神话*          (moegirl ACG 引擎)
--
-- Usage (from the emu install dir koreader-emulator-*/koreader/):
--   ./luajit <path>/tests/test_matrix10.lua
-- Exit 0 = all 10 matrix cases passed.

local failures = 0
local passed = 0
local function pass(name) print("PASS  " .. name) passed = passed + 1 end
local function fail(name, detail)
    print("FAIL  " .. name .. "  (" .. tostring(detail) .. ")")
    failures = failures + 1
end

-- ── Environment bootstrap (identical to test_l6_headless.lua) ─────────────
dofile("setupkoenv.lua")
local DataStorage = require("datastorage")
_G.G_reader_settings = require("luasettings"):open(
    DataStorage:getDataDir() .. "/settings.reader.lua")

local stub_class
stub_class = setmetatable({}, { __index = function() return stub_class end })
package.loaded["ui/widget/infomessage"]  = { new = function() return stub_class end }
package.loaded["ui/widget/inputdialog"]  = { new = function() return stub_class end }
package.loaded["ui/widget/dictquicklookup"] = stub_class
package.loaded["ui/uimanager"] = {
    show = function() end, close = function() end,
    scheduleIn = function() end, broadcastEvent = function() end,
}
package.loaded["ui/network/manager"] = {
    willRerunWhenOnline = function() return false end,
    isOnline = function() return true end,
    beforeWifiAction = function() return true end,
}

local plugin_root = "plugins/dual_wiki.koplugin/"
package.path = plugin_root .. "?.lua;" .. package.path
local DualWiki = dofile(plugin_root .. "main.lua")
assert(type(DualWiki) == "table" and type(DualWiki.queryPipeline) == "function",
    "plugin main.lua must load with queryPipeline (facade intact)")
local dw = DualWiki:new{}

local socket = require("socket")
local keepalive = require("keepalive")

-- ── rate-limit-aware helpers (same policy as L6/L4) ───────────────────────
local function throttle() socket.sleep(3) end

local function attempt(name, word, engine, lang)
    throttle()
    local cands = dw:queryPipeline(word, engine, lang)
    if cands == nil and dw._last_error_kind == "http_429" then
        print("  .. " .. name .. " hit HTTP 429, backing off 20 s ..")
        socket.sleep(20)
        cands = dw:queryPipeline(word, engine, lang)
    end
    if cands == nil and dw._last_error_kind ~= nil then
        -- half-dead pooled socket for this host: drop pool, one fresh dial
        keepalive.clear()
        socket.sleep(10)
        cands = dw:queryPipeline(word, engine, lang)
    end
    return cands
end

-- any-of-top-N title match: redirect naming varies (三体/三体 (小说),
-- 拿破仑一世/拿破仑·波拿巴, 黑神话：悟空/黑神话), so rank-1-only asserts
-- would be flaky without being more honest.
local function topTitles(cands, n)
    local titles = {}
    for i = 1, math.min(n or 3, cands and #cands or 0) do
        titles[i] = tostring(cands[i].title or "")
    end
    return titles
end

local function checkCase(cfg)
    local cands = attempt(cfg.name, cfg.word, cfg.engine, cfg.lang)
    if type(cands) ~= "table" or #cands == 0 then
        return fail(cfg.name, "no candidates (kind=" .. tostring(dw._last_error_kind) .. ")")
    end
    if cfg.lenient then
        -- 少选一字 contract: graceful degradation, ANY candidate is a pass
        return pass(cfg.name .. " → " .. (topTitles(cands, 1)[1] or "?"))
    end
    local any = cfg.any or 3
    for _, t in ipairs(topTitles(cands, any)) do
        if t:find(cfg.expect, 1, true) and (not cfg.not_expect or not t:find(cfg.not_expect, 1, true)) then
            return pass(cfg.name .. " → " .. t)
        end
    end
    return fail(cfg.name, "top" .. any .. "=" .. table.concat(topTitles(cands, any), " / ")
        .. " lack '" .. cfg.expect .. "'")
end

print("\n== P2-8: 10-group selection matrix (real pipeline, real network) ==")

-- 1 《三体》 — 书名号剥离, 不带书名号命中
checkCase{
    name = "M1 《三体》", word = "《三体》", engine = "wikipedia", lang = "zh",
    expect = "三体", not_expect = "《",
}

-- 2 “人工智能” — 中文引号剥离
checkCase{
    name = "M2 “人工智能”", word = "“人工智能”", engine = "wikipedia", lang = "zh",
    expect = "人工智能",
}

-- 3 【凉宫春日的忧郁】 — ACG 词条走 moegirl (不可达时自动降级 wikipedia)
checkCase{
    name = "M3 【凉宫春日的忧郁】", word = "【凉宫春日的忧郁】", engine = "moegirl", lang = "zh",
    expect = "凉宫春日",
}

-- 4 量子力学的 — 末尾助词降级, 不误伤内部助词
checkCase{
    name = "M4 量子力学的", word = "量子力学的", engine = "wikipedia", lang = "zh",
    expect = "量子力学",
}

-- 5 拿破仑·波拿巴 — 间隔号保留 (redirect 命名为 拿破仑一世)
checkCase{
    name = "M5 拿破仑·波拿巴", word = "拿破仑·波拿巴", engine = "wikipedia", lang = "zh",
    expect = "拿破仑",
}

-- 6 Re:从零开始的异世界生活 — 冒号保留
checkCase{
    name = "M6 Re:从零…", word = "Re:从零开始的异世界生活", engine = "wikipedia", lang = "zh",
    expect = "从零",
}

-- 7 小笠原道 — 少选一字: 前缀噪音可接受, 但管线必须优雅降级 (非 nil 不崩)
checkCase{
    name = "M7 小笠原道 (少选一字, lenient)", word = "小笠原道", engine = "wikipedia", lang = "zh",
    lenient = true,
}

-- 8 Fate/stay night — 斜杠保留
checkCase{
    name = "M8 Fate/stay night", word = "Fate/stay night", engine = "wikipedia", lang = "zh",
    expect = "Fate",
}

-- 9 魔戒 (繁体书目) — zh-Hant 书目走 converttitles+variant=zh-hant 服务端转换
do
    local old_ui = dw.ui
    dw.ui = { document = { getProps = function()
        return { language = "zh-Hant" }
    end } }
    checkCase{
        name = "M9 魔戒 (繁, book=zh-Hant)", word = "魔戒", engine = "wikipedia", lang = "zh",
        expect = "魔戒",
    }
    dw.ui = old_ui
end

-- 10 黑神话 — 宽泛词走 moegirl (黑神话：悟空)
checkCase{
    name = "M10 黑神话", word = "黑神话", engine = "moegirl", lang = "zh",
    expect = "黑神话",
}

print(string.format("\n== matrix10 summary: %d passed, %d failed ==", passed, failures))
if failures > 0 then
    print("MATRIX10 FAILURES: " .. failures)
    os.exit(1)
end
print("ALL 10 MATRIX CASES PASSED")
os.exit(0)
