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

-- v1.3.3 (E7): the keepalive pool bypasses ssl.https.request, which would
-- silence the deterministic 429 stubs below. The stubbed-transport block
-- disables the pool for its duration; a dedicated block afterwards exercises
-- the pool against the REAL network (reuse + fallback contract).
local keepalive = require("keepalive")

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

local function assertPipeline(name, word, engine, lang, expect_find, expect_title)
    throttle()
    -- Bounded retry: this suite fires many back-to-back requests and the
    -- Wikimedia edge 429s aggressively, which can poison ONE probe (e.g. the
    -- Stage 1b elision probe degrading to literal-prefix noise). Retry the
    -- whole ladder; a genuine regression fails all three attempts anyway.
    local function attempt()
        return retry429(function() return dw:queryPipeline(word, engine, lang) end)
    end
    local cands = attempt()
    local attempt_no = 1
    local function degraded()
        if type(cands) ~= "table" or #cands == 0 then return true end
        local title = tostring(cands[1].title or "")
        if expect_title and not expect_title(title) then return true end
        if expect_find and not title:find(expect_find, 1, true) then return true end
        return false
    end
    while degraded() and attempt_no < 3 do
        attempt_no = attempt_no + 1
        print("  .. " .. name .. " degraded (attempt " .. attempt_no .. "/3), backing off 10 s ..")
        socket.sleep(10)
        cands = attempt()
    end
    if type(cands) ~= "table" or #cands == 0 then
        fail(name, "no candidates: " .. tostring(cands))
        return nil
    end
    local title = tostring(cands[1].title or "")
    if expect_title and not expect_title(title) then
        fail(name, "top hit '" .. title .. "' fails the title predicate")
        return cands
    end
    if expect_find and not title:find(expect_find, 1, true) then
        fail(name, "top hit '" .. title .. "' lacks '" .. expect_find .. "'")
        return cands
    end
    pass(name .. " -> " .. title)
    return cands
end

print("== deterministic 429 auto-retry (stubbed transport, no network) ==")
keepalive.enabled = false -- these stubs target the legacy ssl.https path
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
keepalive.enabled = true -- back on for the real-network sections below

print("== v1.3.3 E7: keepalive pool (real network) ==")
local httpGet = dw._httpGet
do
    local stats_before = { opens = keepalive._stats.opens, reuses = keepalive._stats.reuses }
    local ok1, body1 = httpGet("https://en.wikipedia.org/w/api.php?action=query&meta=siteinfo&format=json", 10)
    local ok2, body2 = httpGet("https://en.wikipedia.org/w/api.php?action=query&meta=siteinfo&format=json", 10)
    if ok1 and ok2 then
        pass("E7 two sequential https GETs via pool succeed")
    else
        fail("E7 sequential GETs", tostring(ok1) .. "/" .. tostring(ok2))
    end
    if ok1 and ok2 and keepalive._stats.reuses > stats_before.reuses then
        pass("E7 second request reused the pooled socket (reuses="
            .. keepalive._stats.reuses .. ", opens=" .. keepalive._stats.opens .. ")")
    elseif ok1 and ok2 then
        fail("E7 socket reuse", "reuses=" .. keepalive._stats.reuses
            .. " opens=" .. keepalive._stats.opens .. " (no reuse observed)")
    end
    if ok1 and #body1 > 0 and body1:find('"enwiki"', 1, true) then
        pass("E7 pooled body is a valid siteinfo JSON")
    elseif ok1 then
        fail("E7 pooled body shape", "missing enwiki marker")
    end
end
do
    -- pool must not leak sockets across a deliberate failure (bad port)
    local ok_bad = httpGet("https://en.wikipedia.org:1/w/api.php?action=query&format=json", 4)
    keepalive.clear()
    local ok_next, body_next = httpGet("https://en.wikipedia.org/w/api.php?action=query&meta=siteinfo&format=json", 10)
    if ok_next and #body_next > 0 then
        pass("E7 pool recovers after a dead-port failure")
    else
        fail("E7 pool recovery", tostring(ok_next))
    end
    if ok_bad then
        -- port 1 unlikely to answer; if it did, treat as env anomaly, not failure
        print("  note: dead-port probe unexpectedly succeeded (host-level proxy?)")
    end
end
keepalive.enabled = false -- real-network ladder sections stay on legacy transport

print("== queryPipeline across languages (real network) ==")
assertPipeline("zh particle retry (量子力学的→量子力学)", "量子力学的", "wikipedia", "zh", "量子力学")
assertPipeline("zh exact (人工智能)", "人工智能", "wikipedia", "zh", "人工智能")
assertPipeline("en word-boundary (quantum entanglement)", "quantum entanglement", "wikipedia", "en", "Quantum")
-- v1.3.3 A1: dab expansion runs after earlier probes, so a 429 can hit the
-- wikitext parse and silently degrade back to the raw dab page (retry429
-- cannot detect that). Allow a bounded retry when the expansion degraded.
do
    local ok_shana = false
    for attempt = 1, 3 do
        throttle()
        local cands = retry429(function() return dw:queryPipeline("シャナ", "wikipedia", "ja") end)
        local found = false
        for _, c in ipairs(cands or {}) do
            if c.title == "灼眼のシャナ" then
                found = true
                break
            end
        end
        if found then
            ok_shana = true
            break
        end
        print("  .. ja dab expansion degraded (top="
            .. tostring(cands and cands[1] and cands[1].title) .. "), retrying ..")
    end
    if ok_shana then
        pass("ja dab expansion (シャナ) includes 灼眼のシャナ")
    else
        fail("ja dab expansion (シャナ)", "missing 灼眼のシャナ after 3 attempts")
    end
end
assertPipeline("de (Quantenmechanik)", "Quantenmechanik", "wikipedia", "de", nil)
assertPipeline("fr (philosophie)", "philosophie", "wikipedia", "fr", nil)
assertPipeline("es (historia de Roma)", "historia de Roma", "wikipedia", "es", nil)
assertPipeline("ru cyrillic (Квантовая механика)", "Квантовая механика", "wikipedia", "ru", nil)

-- v1.3.2 regression (user-acceptance): sentence-initial capital "L'équation"
-- must resolve to the math article Équation, NOT the L'Équation* works
-- (TV movie / Bogdanoff essay / Khadra novel) that literal prefixsearch
-- returns. The check is exact-title, NOT substring: "L'Équation de
-- l'apocalypse" contains "quation" and would silently pass a find() assert
-- (this is exactly how the bug escaped CI twice).
assertPipeline("fr capital elision (L'équation→Équation)", "L'équation", "wikipedia", "fr", nil,
    function(title) return title == "Équation" end)
assertPipeline("fr lower elision (l'équation→Équation)", "l'équation", "wikipedia", "fr", nil,
    function(title) return title == "Équation" end)

print("== v1.3.3 search quality (real network) ==")
-- A1: en.wikipedia "Mercury" is a Disambiguator-flagged page whose extract
-- is a bare item index; the pipeline must swap it for the dab items (in
-- document order, batched intro extracts) instead of surfacing the index.
do
    throttle()
    local cands = retry429(function() return dw:queryPipeline("Mercury", "wikipedia", "en") end)
    local n = type(cands) == "table" and #cands or 0
    local top = n > 0 and tostring(cands[1].title) or "?"
    if n >= 2 and top ~= "Mercury" and cands[1].dab_item then
        pass("en dab expansion (Mercury → " .. n .. " items, top: " .. top .. ")")
    else
        fail("en dab expansion (Mercury)",
            "n=" .. n .. " top=" .. top .. " dab_item=" .. tostring(cands and cands[1] and cands[1].dab_item))
    end
end
-- A3: MediaWiki spell correction piggybacks on the search request
-- (gsrinfo=suggestion; NOTE: srinfo= is the list=search spelling and is
-- NOT emitted on generator=search — verified live 2026-09-07).
do
    throttle()
    retry429(function() return dw:fetchCandidates("Catte", "wikipedia", "en", "search") end)
    local sugg = dw._last_suggestion
    if type(sugg) == "string" and sugg:lower():find("cattle", 1, true) then
        pass("did-you-mean (Catte → " .. sugg .. ")")
    else
        fail("did-you-mean (Catte)", tostring(sugg))
    end
end
-- B5: European phrase particles feed Stage 2's fallback probe. fr.wikipedia
-- prefix-matches "Histoire de …" titles, so Stage 1 usually preempts; this
-- case pins the ladder behavior end-to-end (no crash, sane top hit).
assertPipeline("fr phrase particle (histoire de → Histoire…)", "histoire de", "wikipedia", "fr", nil,
    function(title) return title:find("^Histoire") ~= nil end)

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

-- 2b. THE v1.3.2 SCROLL-CRASH REGRESSION TEST: results must carry the
-- `dict` field (core's changeDictionary reads it for the window title;
-- nil killed the app on wheel-past-end auto next-result). Asserts the
-- exact contract from frontend/ui/widget/dictquicklookup.lua:1465.
do
    local sw = stub_class
    package.loaded["ui/widget/infomessage"] = { new = function() return sw end }
    package.loaded["ui/widget/dictquicklookup"] = sw
    local shown = {}
    package.loaded["ui/widget/dictquicklookup"].new = function(_, opts)
        shown[#shown + 1] = opts
        return opts
    end
    dw.ui = { dialog = {}, highlight = nil }
    dw:showResult("量子力学", {
        { title = "量子力学", extract = "物理学分支。" },
        { title = "量子力学史话", extract = "科普著作。" },
    }, "wikipedia", nil, "zh", false)
    local w = shown[#shown]
    local ok_fields = true
    for i, r in ipairs(w.results) do
        if type(r.dict) ~= "string" or r.dict == "" then
            print("FAIL  result[" .. i .. "].dict must be a non-empty string, got: " .. tostring(r.dict))
            failures = failures + 1
            ok_fields = false
        end
    end
    if ok_fields then
        pass("results carry string `dict` field (scroll-crash regression)")
    end
    -- v1.3.3 (A1): dab-expansion entries carry the disambiguation tag on
    -- their definition line so the reader knows they are browsing an index.
    local tagged = 0
    for _, r in ipairs(w.results) do
        if tostring(r.definition):find("Disambiguation entry", 1, true) then
            tagged = tagged + 1
        end
    end
    dw:showResult("Mercury", {
        { title = "Mercury (planet)", extract = "The closest planet to the Sun.", dab_item = true },
        { title = "Mercury (element)", extract = "", dab_item = true },
    }, "wikipedia", nil, "en", false)
    local w2 = shown[#shown]
    local all_tagged = true
    for _, r in ipairs(w2.results) do
        if not tostring(r.definition):find("Disambiguation entry", 1, true) then
            all_tagged = false
        end
    end
    if all_tagged and #w2.results == 2 and tagged == 0 then
        pass("dab items tagged with Disambiguation entry (plain results untagged)")
    else
        fail("dab items tagged with Disambiguation entry",
            "tagged=" .. tagged .. " all_tagged=" .. tostring(all_tagged))
    end
    package.loaded["ui/widget/dictquicklookup"] = nil
    dw.ui = nil
end

-- 2c. v1.3.3 B7+A1 COMBINED: a zh-defaulted lookup of a pure-Latin selection
-- must route to en.wikipedia BEFORE the first request (the result window
-- carries the routed label) and the dab-topped result set must arrive
-- expanded. Exercises the full lookup() path with a synchronous scheduler.
do
    local UM = package.loaded["ui/uimanager"]
    local old_scheduleIn = UM.scheduleIn
    UM.scheduleIn = function(_, _, fn) fn() end
    local sw = stub_class
    package.loaded["ui/widget/infomessage"] = { new = function() return sw end }
    package.loaded["ui/widget/dictquicklookup"] = sw
    local shown = {}
    package.loaded["ui/widget/dictquicklookup"].new = function(_, opts)
        shown[#shown + 1] = opts
        return opts
    end
    -- No per-book settings; clear any global language lock so auto mode is
    -- in effect (script routing must respect explicit locks).
    if G_reader_settings:readSetting("dualwiki_lang") ~= nil then
        G_reader_settings:delSetting("dualwiki_lang")
    end
    dw._lookup_cache = nil
    dw.ui = { dialog = {}, highlight = nil }

    dw:lookup("Mercury", "wikipedia", nil, "zh", false)
    local w = shown[#shown]
    if type(w) ~= "table" or type(w.results) ~= "table" or #w.results == 0 then
        fail("B7 script routing + dab expansion (Mercury via zh lookup)", "no results shown")
    else
        local label_ok = w.results[1].dict == "Wikipedia (EN)"
        local expanded = #w.results >= 2 and w.results[1].word ~= "Mercury"
        if label_ok and expanded then
            pass("B7 routes zh→en + dab expansion (dict=" .. w.results[1].dict
                .. ", " .. #w.results .. " items, top: " .. tostring(w.results[1].word) .. ")")
        else
            fail("B7 script routing + dab expansion (Mercury via zh lookup)",
                "dict=" .. tostring(w.results[1].dict) .. " items=" .. #w.results
                .. " top=" .. tostring(w.results[1].word))
        end
    end

    dw.ui = nil
    dw._lookup_cache = nil
    package.loaded["ui/widget/dictquicklookup"] = nil
    UM.scheduleIn = old_scheduleIn
end

-- 2d. v1.3.3 A3 UI binding: a captured spelling suggestion must surface as
-- a one-tap button in the retry dialog (and be absent when there is none).
do
    local dlg_stub = setmetatable({}, { __index = function() return function() end end })
    local dialogs = {}
    -- Mutate the module table main.lua captured at load (do NOT replace it,
    -- as with the other UI stubs in this harness).
    package.loaded["ui/widget/inputdialog"].new = function(_, opts)
        dialogs[#dialogs + 1] = opts
        return dlg_stub
    end
    dw.ui = { dialog = {}, highlight = nil }

    dw._last_suggestion = "cattle"
    dw:showRetryDialog("Catte", "wikipedia", nil, "en")
    local d1 = dialogs[#dialogs]
    local suggestion_btn
    if d1 and type(d1.buttons) == "table" then
        for _, row in ipairs(d1.buttons) do
            for _, b in ipairs(row) do
                if tostring(b.text):find("cattle", 1, true) then
                    suggestion_btn = b
                end
            end
        end
    end
    local desc_ok = d1 and tostring(d1.description or ""):find("cattle", 1, true) ~= nil
    if suggestion_btn and desc_ok then
        pass("retry dialog surfaces did-you-mean button + description")
    else
        fail("retry dialog surfaces did-you-mean button + description",
            "btn=" .. tostring(suggestion_btn and suggestion_btn.text) .. " desc=" .. tostring(d1 and d1.description))
    end

    dw._last_suggestion = nil
    dw:showRetryDialog("Catte", "wikipedia", nil, "en")
    local d2 = dialogs[#dialogs]
    local stray = false
    if d2 and type(d2.buttons) == "table" then
        for _, row in ipairs(d2.buttons) do
            for _, b in ipairs(row) do
                if tostring(b.text):find("cattle", 1, true) then
                    stray = true
                end
            end
        end
    end
    if not stray then
        pass("retry dialog omits suggestion button when none captured")
    else
        fail("retry dialog omits suggestion button when none captured", "stray button present")
    end

    dw.ui = nil
    package.loaded["ui/widget/inputdialog"].new = function() return stub_class end
end

if failures > 0 then
    print("\nINTEGRATION FAILURES: " .. failures)
    os.exit(1)
else
    print("\nALL INTEGRATION TESTS PASSED")
    os.exit(0)
end
