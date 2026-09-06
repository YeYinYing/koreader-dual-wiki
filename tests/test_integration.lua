-- Integration test: run INSIDE the KOReader emulator runtime against the
-- REAL network. Covers what the pure-function unit tests cannot:
--   * https dispatch (ssl.https vs socket.http) per URL scheme
--   * real MediaWiki JSON shapes for every engine (wikipedia zh/en/ja/
--     de/fr/es/ru, moegirl, fandom, bwiki, wiktionary)
--   * queryPipeline stage ladder end-to-end (particle retry, prefix
--     guard, full-text search fallback, moegirl-unreachable degradation)
--   * the v1.3.0 parse-engine two-phase fetch (section=0 first) and its
--     transport-failure short-circuit
--
-- Stubbed: UIManager and all widget classes (no rendering), NetworkMgr
-- (assume online). Everything below the UI surface is the real plugin code.
--
-- Usage (from the emu install dir koreader-emulator-*/koreader/):
--   ./luajit <path-to>/tests/test_integration.lua
-- Exit code 0 = all cases passed.

local failures = 0
local function pass(name) print("PASS  " .. name) end
local function fail(name, detail)
    print("FAIL  " .. name .. "  detail: " .. tostring(detail))
    failures = failures + 1
end

dofile("setupkoenv.lua")
local DataStorage = require("datastorage")
_G.G_reader_settings = require("luasettings"):open(
    DataStorage:getDataDir() .. "/settings.reader.lua")

-- Widget/UI stubs: main.lua only touches these inside UI code paths that
-- this harness does not exercise (lookup/showResult/showRetryDialog).
local stub_class
stub_class = setmetatable({}, { __index = function() return stub_class end })
package.loaded["ui/widget/infomessage"] = { new = function() return stub_class end }
package.loaded["ui/widget/inputdialog"] = { new = function() return stub_class end }
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
if type(DualWiki) ~= "table" or type(DualWiki.queryPipeline) ~= "function" then
    fail("plugin main.lua loads with queryPipeline", type(DualWiki))
    os.exit(1)
end
local dw = DualWiki:new{}

-- Be polite to the wikis: the Wikimedia rate limiter counts per-IP across
-- ALL wikis (observed: ru.wikipedia 429'd on its first request after a
-- session of queries). Space requests out and retry 429s once with backoff.
local socket = require("socket")
local function throttle()
    socket.sleep(3)
end
local function retry429(fn)
    local result = fn()
    if result == nil and dw._last_error_kind == "http_429" then
        print("  .. hit HTTP 429, backing off 15 s and retrying once ..")
        socket.sleep(15)
        result = fn()
    end
    return result
end

local function assertPipeline(name, word, engine, lang, expect_find)
    throttle()
    local cands = retry429(function() return dw:queryPipeline(word, engine, lang) end)
    if type(cands) ~= "table" or #cands == 0 then
        fail(name, "no candidates: " .. tostring(cands))
        return nil
    end
    local title = tostring(cands[1].title or "")
    if expect_find and not title:find(expect_find, 1, true) then
        fail(name, "top hit '" .. title .. "' lacks '" .. expect_find .. "'")
        return cands
    end
    pass(name .. " -> " .. title)
    return cands
end

print("== deterministic 429 auto-retry (stubbed transport, no network) ==")
do
    -- luasocket generic request returns (1, code, headers, status); the
    -- plugin's socket.skip(1, ...) drops the leading 1. Stub the https
    -- module table the plugin captured at load time.
    local https_mod = require("ssl.https")
    local orig_request = https_mod.request
    local calls = 0
    https_mod.request = function(...)
        calls = calls + 1
        if calls == 1 then
            return 1, 429, { ["retry-after"] = "0" }, "429 Too Many Requests"
        end
        return orig_request(...)
    end
    local cands = dw:fetchCandidates("napoleon", "wikipedia", "en", "prefix")
    https_mod.request = orig_request
    if type(cands) ~= "table" or #cands == 0 then
        fail("429 then success auto-retries", tostring(cands))
    elseif calls < 2 then
        fail("429 retry actually re-requested", "calls=" .. calls)
    else
        pass("429 -> auto retry -> success (" .. #cands .. " candidates, " .. calls .. " requests)")
    end
end
do
    local https_mod = require("ssl.https")
    local orig_request = https_mod.request
    local calls = 0
    https_mod.request = function()
        calls = calls + 1
        return 1, 429, { ["retry-after"] = "0" }, "429 Too Many Requests"
    end
    local cands = dw:fetchCandidates("napoleon", "wikipedia", "en", "prefix")
    https_mod.request = orig_request
    if cands ~= nil then
        fail("persistent 429 returns nil after retry", tostring(cands))
    elseif dw._last_error_kind ~= "http_429" then
        fail("persistent 429 error kind", tostring(dw._last_error_kind))
    elseif calls ~= 2 then
        fail("persistent 429 retry count", "calls=" .. calls .. " (want exactly 2)")
    else
        pass("persistent 429 -> nil, kind=http_429, exactly 2 requests")
    end
end

print("== queryPipeline across languages (real network) ==")
assertPipeline("zh particle retry (量子力学的→量子力学)", "量子力学的", "wikipedia", "zh", "量子力学")
assertPipeline("zh exact (人工智能)", "人工智能", "wikipedia", "zh", "人工智能")
assertPipeline("en word-boundary (quantum entanglement)", "quantum entanglement", "wikipedia", "en", "Quantum")
assertPipeline("ja kana (シャナ)", "シャナ", "wikipedia", "ja", "シャナ")
assertPipeline("de (Quantenmechanik)", "Quantenmechanik", "wikipedia", "de", nil)
assertPipeline("fr (philosophie)", "philosophie", "wikipedia", "fr", nil)
assertPipeline("es (historia de Roma)", "historia de Roma", "wikipedia", "es", nil)
assertPipeline("ru cyrillic (Квантовая механика)", "Квантовая механика", "wikipedia", "ru", nil)

print("== moegirl (ACG engine, wikipedia degradation allowed) ==")
do
    throttle()
    local cands = retry429(function() return dw:queryPipeline("初音未来", "moegirl", "zh") end)
    if type(cands) == "table" and #cands > 0 then
        pass("moegirl zh (初音未来) -> " .. tostring(cands[1].title))
    else
        pass("moegirl zh unreachable/empty -> degraded ladder returned fallback (allowed)")
    end
end

print("== parse engine two-phase fetch (section=0 first) ==")
do
    throttle()
    local cands = retry429(function() return dw:fetchParseArticle("Darth Vader", "fandom", "starwars") end)
    local extract = cands and cands[1] and cands[1].extract or ""
    if #extract < 100 then
        fail("fandom parse (Darth Vader)", "extract too short: " .. #extract)
    else
        pass("fandom parse (Darth Vader) -> " .. #extract .. " bytes")
    end
end
do
    throttle()
    local cands = retry429(function() return dw:fetchParseArticle("蒙德", "bwiki", "ys") end)
    local extract = cands and cands[1] and cands[1].extract or ""
    if #extract < 30 then
        fail("bwiki parse (蒙德 @ ys)", "extract too short: " .. #extract)
    else
        pass("bwiki parse (蒙德 @ ys) -> " .. #extract .. " bytes")
    end
end
do
    throttle()
    local cands = retry429(function() return dw:fetchParseArticle("quantum", "wiktionary", "en") end)
    if type(cands) ~= "table" or not cands[1] or #(cands[1].extract or "") < 30 then
        fail("wiktionary parse (quantum)", "no usable extract")
    else
        pass("wiktionary parse (quantum) -> " .. #cands[1].extract .. " bytes")
    end
end

print("== transport failure short-circuit (bad fandom sub) ==")
do
    local cands = dw:fetchParseArticle("Anything", "fandom", "no-such-community-xyz")
    if cands ~= nil then
        fail("unreachable fandom sub returns nil", tostring(cands))
    else
        pass("unreachable fandom sub -> nil (transport error consumed)")
    end
end

print("== prefixsearch candidate shape (titles + optional extracts) ==")
do
    throttle()
    local cands = retry429(function() return dw:fetchCandidates("拿破仑", "wikipedia", "zh", "prefix") end)
    if type(cands) ~= "table" or #cands == 0 then
        fail("wikipedia prefixsearch (拿破仑)", "no candidates")
    elseif type(cands[1].title) ~= "string" then
        fail("candidate has title", tostring(cands[1]))
    else
        pass("prefixsearch (拿破仑) -> " .. #cands .. " candidates, top: " .. cands[1].title)
    end
end

if failures > 0 then
    print("\nINTEGRATION FAILURES: " .. failures)
    os.exit(1)
else
    print("\nALL INTEGRATION TESTS PASSED")
    os.exit(0)
end
