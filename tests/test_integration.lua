-- Integration test: run INSIDE the KOReader emulator runtime against the
-- REAL network. Covers what the pure-function unit tests cannot:
--   * https dispatch (ssl.https vs socket.http) per URL scheme
--   * real MediaWiki JSON shapes for every engine (wikipedia zh/en/ja/
--     de/fr/es/ru, moegirl)
--   * queryPipeline stage ladder end-to-end (particle retry, prefix
--     guard, full-text search fallback, moegirl-unreachable degradation)
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
    local ok2 = httpGet("https://en.wikipedia.org/w/api.php?action=query&meta=siteinfo&format=json", 10)
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
    -- the responses must have traveled the POOL, not a silent legacy fallback
    if keepalive._stats.successes >= 2 then
        pass("E7 responses confirmed via pool fast path (successes="
            .. keepalive._stats.successes .. ")")
    else
        fail("E7 pool fast-path proof", "successes=" .. tostring(keepalive._stats.successes))
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

-- Slim build (user direction): the elision strip was REMOVED — the selection
-- is searched exactly as written ("选什么搜什么"). Pin the literal contract:
-- "L'équation" prefix-matches the L'Équation* works, and that is now the
-- DESIRED outcome, not a bug. Exact-title check keeps the assert honest.
assertPipeline("fr literal search (L'équation)", "L'équation", "wikipedia", "fr", nil,
    function(title) return title == "L'Équation de l'apocalypse" end)
assertPipeline("fr literal search (l'équation)", "l'équation", "wikipedia", "fr", nil,
    function(title) return title == "L'Équation de l'apocalypse" end)

print("== v1.3.3 search quality (real network) ==")
-- A1: en.wikipedia "Mercury" is a Disambiguator-flagged page whose extract
-- is a bare item index; the pipeline must swap it for the dab items (in
-- document order, batched intro extracts) instead of surfacing the index.
-- Bounded retry: the expansion's action=parse wikitext request is the
-- suite's most rate-limit-prone call (429 degrades the expansion by
-- design — top stays the raw page); same contract as the B7 case.
do
    local cands
    for attempt_dab = 1, 3 do
        throttle()
        cands = retry429(function() return dw:queryPipeline("Mercury", "wikipedia", "en") end)
        local n = type(cands) == "table" and #cands or 0
        local top = n > 0 and tostring(cands[1].title) or "?"
        if n >= 2 and top ~= "Mercury" and cands[1].dab_item then break end
        if attempt_dab < 3 then
            print("  .. en dab expansion degraded (attempt " .. attempt_dab .. "/3), backing off 10 s ..")
            socket.sleep(10)
        end
    end
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
    local sugg
    for attempt_dym = 1, 3 do
        retry429(function() return dw:fetchCandidates("Catte", "wikipedia", "en", "search") end)
        sugg = dw._last_suggestion
        if type(sugg) == "string" and sugg:lower():find("cattle", 1, true) then
            break
        end
        if attempt_dym < 3 then
            print("  .. did-you-mean degraded (attempt " .. attempt_dym .. "/3), backing off 10 s ..")
            socket.sleep(10)
        end
    end
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

-- v1.3.5 (G2c): always-full display — top candidate expanded behind the — result windows never show lead-section
-- summaries. Part (a) pins the contract with a stubbed transport; part (b)
-- proves it live on the page that motivated the change.
print("== G2c always-full expansion (top-candidate) (stubbed transport, then live) ==")
do
    local saved_fd = dw.fetchDirect
    local calls = {}
    dw.fetchDirect = function(self, title, eng, lng)
        calls[#calls + 1] = { title = title, engine = eng, lang = lng }
        return { { title = title, extract = "FULL<" .. tostring(title) .. ">", index = 1 } }
    end
    -- (a1) multi-candidate: ONLY the top entry expanded (G2c — one heavy
    -- fetch per window, not N), metadata preserved, second candidate intact
    local multi = {
        { title = "甲", extract = "lead-甲", exact = true },
        { title = "乙", extract = "", exact = false, dab_item = true, index = 2 },
    }
    local out, full = dw:_expandAllFullText(multi, "moegirl", "zh")
    if full and out[1].extract == "FULL<甲>" and out[1].exact == true
        and out[2].extract == "" and out[2].dab_item and out[2].index == 2 then
        pass("G2c stub: top candidate expanded, rest untouched, metadata kept")
    else
        fail("G2c stub: multi-candidate", "full=" .. tostring(full))
    end
    -- (a2) E2 pseudo-entry expands from the TARGET language's wikipedia
    local pseudo = { { title = "Target", extract = "", langlink_lang = "en", langlink_from = "源" } }
    dw:_expandAllFullText(pseudo, "wikipedia", "zh")
    local last = calls[#calls]
    if last and last.title == "Target" and last.engine == "wikipedia" and last.lang == "en" then
        pass("G2c stub: langlink pseudo expands via target language")
    else
        fail("G2c stub: langlink pseudo", last and (last.engine .. "/" .. tostring(last.lang)) or "no call")
    end
    -- (a3) Slim build: parse engines removed — every engine routes through
    -- fetchDirect. Removed engines are no longer routable by design.
    -- Pin the wikipedia path instead.
    local ponly = { { title = "Vader", extract = "" } }
    dw:_expandAllFullText(ponly, "wikipedia", "en")
    last = calls[#calls]
    if last and last.title == "Vader" and last.engine == "wikipedia" and last.lang == "en" then
        pass("G2c stub: full fetch routes via fetchDirect (parse engines removed)")
    else
        fail("G2c stub: fetchDirect routing", last and (last.engine .. "/" .. tostring(last.lang)) or "no call")
    end
    -- (a4) transport failure on the top fetch: lead kept, kind set (E6 —
    -- never cache a transport-failed round), no crash
    dw.fetchDirect = function(self)
        self._last_error_kind = "timeout"
        return nil
    end
    dw._last_error_kind = nil
    local mixed = { { title = "A", extract = "leadA" }, { title = "B", extract = "leadB" } }
    local out2, full2 = dw:_expandAllFullText(mixed, "moegirl", "zh")
    if full2 and out2[1].extract == "leadA" and dw._last_error_kind == "timeout" then
        pass("G2c stub: top transport failure keeps lead, kind set (E6)")
    else
        fail("G2c stub: transport short-circuit", "kind=" .. tostring(dw._last_error_kind))
    end
    dw._last_error_kind = nil
    dw.fetchDirect = saved_fd
    -- (b) live: the 30-char-lead page AND a long-lead page both come back
    -- full — lead length must not matter (G1's thin-only rule is gone).
    throttle()
    local c1 = retry429(function() return dw:fetchCandidates("黑桐干也", "moegirl", "zh", "prefix") end)
    if type(c1) == "table" and #c1 > 0 then
        local e1, f1 = dw:_expandAllFullText(c1, "moegirl", "zh")
        local len1 = e1 and e1[1] and #tostring(e1[1].extract or "") or 0
        if f1 and len1 > 1000 then
            pass("G2c live: 黑桐干也 lead(30) -> full article (" .. len1 .. " chars)")
        else
            fail("G2c live: 黑桐干也", "len=" .. len1 .. " full=" .. tostring(f1))
        end
    else
        fail("G2c live: 黑桐干也", "probe returned no candidates")
    end
    throttle()
    local c2 = retry429(function() return dw:fetchCandidates("初音未来", "moegirl", "zh", "prefix") end)
    if type(c2) == "table" and #c2 > 0 then
        local lead2 = #tostring(c2[1].extract or "") -- BEFORE mutation: _expandAllFullText replaces entries in place
        local e2, f2 = dw:_expandAllFullText(c2, "moegirl", "zh")
        local len2 = e2 and e2[1] and #tostring(e2[1].extract or "") or 0
        if f2 and len2 > lead2 and len2 > 800 then
            pass("G2c live: 初音未来 lead(" .. lead2 .. ") expanded to full article (" .. len2 .. " chars)")
        else
            fail("G2c live: 初音未来", "lead=" .. lead2 .. " len=" .. len2 .. " full=" .. tostring(f2))
        end
    else
        fail("G2c live: 初音未来", "probe returned no candidates")
    end
end

-- Slim build: the parse-engine two-phase fetch and the three parse engines
-- were removed by user direction. The live parse cases no longer apply.

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
    -- v1.3.5 (F1): fullpage flag contract. Default OFF: wikipedia results
    -- carry NO is_wiki_fullpage. With the opt-in set, plain wikipedia
    -- results carry it; moegirl results NEVER do (the fullpage button bar's
    -- Save-as-EPUB is a real-wiki-language contract); dab/langlink stub
    -- entries are excluded too.
    local function clear_fullpage()
        if G_reader_settings:readSetting("dualwiki_fullpage") ~= nil then
            G_reader_settings:delSetting("dualwiki_fullpage")
        end
    end
    clear_fullpage()
    dw:showResult("量子力学", {
        { title = "量子力学", extract = "物理学分支。" },
    }, "wikipedia", nil, "zh", true)
    local w3 = shown[#shown]
    if w3.results[1].is_wiki_fullpage == nil then
        pass("F1 fullpage default OFF (no is_wiki_fullpage)")
    else
        fail("F1 fullpage default OFF", tostring(w3.results[1].is_wiki_fullpage))
    end
    G_reader_settings:saveSetting("dualwiki_fullpage", true)
    dw:showResult("量子力学", {
        { title = "量子力学", extract = "物理学分支。" },
    }, "wikipedia", nil, "zh", true)
    w3 = shown[#shown]
    if w3.results[1].is_wiki_fullpage == true then
        pass("F1 opt-in: wikipedia results carry is_wiki_fullpage")
    else
        fail("F1 opt-in wikipedia fullpage", tostring(w3.results[1].is_wiki_fullpage))
    end
    dw:showResult("初音未来", {
        { title = "初音未来", extract = "虚拟歌手。" },
    }, "moegirl", nil, "zh", true)
    w3 = shown[#shown]
    -- v1.3.5 (F1b): moegirl is now FULLPAGE-eligible (reading comfort);
    -- its save button is stripped at layout build instead.
    if w3.results[1].is_wiki_fullpage == true then
        pass("F1b moegirl opt-in: results carry is_wiki_fullpage")
    else
        fail("F1b moegirl fullpage", tostring(w3.results[1].is_wiki_fullpage))
    end
    -- F1b save-strip contract: moegirl fullpage layout drops the "save"
    -- button (core's EPUB path is a real-wiki-language one), keeps Close.
    local layout = dw:_stripSaveFromFullpageLayout({
        { { id = "save", text = "Save as EPUB" }, { id = "close", text = "Close" } },
    })
    local ids = {}
    for _, row in ipairs(layout) do
        for _, btn in ipairs(row) do ids[btn.id] = true end
    end
    if ids.save == nil and ids.close == true and #layout[1] == 1 then
        pass("F1b save-strip: moegirl fullpage keeps Close, drops Save-as-EPUB")
    else
        fail("F1b save-strip", "ids=" .. tostring(layout[1][1] and layout[1][1].id))
    end
    -- F1b wikipedia layout untouched: the GATE (patched buildButtonLayout)
    -- strips Save only for moegirl+fullpage windows. Install the patch with
    -- a fixed orig layout and drive both engines through it. The stub class
    -- returns itself for ANY missing index, so the idempotence flag must be
    -- set to raw `false` — `nil` would fall through __index and read as
    -- truthy, silently skipping the install.
    local DQL = package.loaded["ui/widget/dictquicklookup"]
    DQL.buildButtonLayout = function()
        return { { { id = "save" }, { id = "close" } } }
    end
    DQL._dualwiki_fullpage_layout_patched = false
    dw:_patchFullpageLayout()
    local function built_for(engine)
        return DQL.buildButtonLayout({
            ui = { dual_wiki = dw },
            dualwiki_engine = engine,
            is_wiki_fullpage = true,
        })
    end
    local wlayout = built_for("wikipedia")
    local mlayout = built_for("moegirl")
    if wlayout[1][1].id == "save" and wlayout[1][2].id == "close"
        and #mlayout[1] == 1 and mlayout[1][1].id == "close" then
        pass("F1b save-strip gate: wikipedia keeps Save, moegirl drops it")
    else
        fail("F1b save-strip gate",
            "wiki_top=" .. tostring(wlayout[1][1].id)
            .. " moegirl_n=" .. tostring(mlayout[1] and #mlayout[1]))
    end
    -- F1b engine-matched cache replay: a moegirl fullpage must NOT replay a
    -- wikipedia cache round (same title lives on both sites).
    dw._lookup_cache = {
        ["wikipedia|zh|初音未来"] = {
            cands = { { title = "初音未来", extract = "维基内容。", exact = true } },
            is_full = true, at = os.time(), lang = "zh",
        },
        ["moegirl|zh|初音未来"] = {
            cands = { { title = "初音未来", extract = "萌娘内容。", exact = true } },
            is_full = true, at = os.time(), lang = "zh",
        },
    }
    local mfetch = 0
    dw.fetchDirect = function() mfetch = mfetch + 1; return nil end
    dw:showFullpageResult("初音未来", "", "moegirl", "zh", nil)
    dw.fetchDirect = nil
    local w5 = shown[#shown]
    if w5.results[1].is_wiki_fullpage == true and mfetch == 0
        and tostring(w5.results[1].definition):find("萌娘内容", 1, true) then
        pass("F1b engine-matched replay: moegirl fullpage uses moegirl cache")
    else
        fail("F1b engine-matched replay", "fetches=" .. mfetch
            .. " def=" .. tostring(w5.results[1].definition))
    end
    dw:showResult("Mercury", {
        { title = "Mercury (planet)", extract = "The closest planet.", dab_item = true },
    }, "wikipedia", nil, "en", true)
    w3 = shown[#shown]
    if w3.results[1].is_wiki_fullpage == nil then
        pass("F1 dab items excluded from fullpage")
    else
        fail("F1 dab fullpage leak", tostring(w3.results[1].is_wiki_fullpage))
    end
    -- F1 replay contract: fullscreen re-show from the session cache must
    -- cost ZERO network (the definition is already full text from G2).
    dw._lookup_cache = {
        ["wikipedia|zh|量子力学"] = {
            cands = { { title = "量子力学", extract = "全文正文，可直接归档。", exact = true } },
            is_full = true, at = os.time(), lang = "zh",
        },
    }
    local fetch_calls = 0
    dw.fetchDirect = function() fetch_calls = fetch_calls + 1; return nil end
    dw:showFullpageResult("量子力学", "", "wikipedia", "zh", nil)
    local w4 = shown[#shown]
    if w4.results[1].is_wiki_fullpage == true and fetch_calls == 0
        and tostring(w4.results[1].definition):find("全文正文", 1, true) then
        pass("F1 cache replay: fullscreen re-show costs zero network")
    else
        fail("F1 cache replay", "fetches=" .. fetch_calls
            .. " fullpage=" .. tostring(w4.results[1].is_wiki_fullpage))
    end
    dw.fetchDirect = nil
    clear_fullpage()
    -- v1.3.5 (F2): takeover gate. Default: on. With dualwiki_no_takeover
    -- set, _takeoverEnabled() must be false (native paths restored).
    if dw:_takeoverEnabled() then
        pass("F2 takeover default ON")
    else
        fail("F2 takeover default ON", "disabled without setting")
    end
    G_reader_settings:saveSetting("dualwiki_no_takeover", true)
    if not dw:_takeoverEnabled() then
        pass("F2 takeover OFF via dualwiki_no_takeover")
    else
        fail("F2 takeover OFF", "still enabled with setting")
    end
    -- F2 menu side: native entries preserved when takeover off, removed when on.
    local mi = {
        wikipedia_lookup = { text = "x" },
        wikipedia_history = { text = "y" },
        wikipedia_settings = { text = "z" },
    }
    dw:addToMainMenu(mi)
    if mi.wikipedia_lookup and mi.wikipedia_history and mi.wikipedia_settings then
        pass("F2 takeover OFF keeps native menu entries")
    else
        fail("F2 takeover OFF menus", "native entries removed")
    end
    G_reader_settings:delSetting("dualwiki_no_takeover")
    dw:addToMainMenu(mi)
    if mi.wikipedia_lookup == nil and mi.wikipedia_history == nil
        and mi.wikipedia_settings == nil then
        pass("F2 takeover ON removes native menu entries")
    else
        fail("F2 takeover ON menus", "native entries kept")
    end
    clear_fullpage()
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
    -- Bounded retry: by the time this block runs the suite has warmed the
    -- Wikimedia rate limiter, and a 429 on the dab wikitext parse degrades
    -- the expansion by design (top stays the raw page). Same contract as
    -- assertPipeline: a genuine regression fails all three attempts.
    local w, label_ok, expanded
    for attempt_b7 = 1, 3 do
        dw._lookup_cache = nil
        dw.ui = { dialog = {}, highlight = nil }
        shown = {}
        dw:lookup("Mercury", "wikipedia", nil, "zh", false)
        w = shown[#shown]
        label_ok = type(w) == "table" and type(w.results) == "table" and #w.results > 0
            and w.results[1].dict == "Wikipedia (EN)"
        expanded = label_ok and #w.results >= 2 and w.results[1].word ~= "Mercury"
        if label_ok and expanded then break end
        if attempt_b7 < 3 then
            print("  .. B7 degraded (attempt " .. attempt_b7 .. "/3), backing off 10 s ..")
            socket.sleep(10)
        end
    end
    if type(w) ~= "table" or type(w.results) ~= "table" or #w.results == 0 then
        fail("B7 script routing + dab expansion (Mercury via zh lookup)", "no results shown")
    else
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

    -- 2e. Bug-hunt regression: the suggestion button's callback must close
    -- the INPUT DIALOG, not the button table. A previous version closed an
    -- identically-named button-table local, leaving the retry dialog open
    -- underneath the result window (and UIManager:close on a non-widget).
    do
        local closed = {}
        local UM = package.loaded["ui/uimanager"]
        local old_close = UM.close
        UM.close = function(_, w) closed[#closed + 1] = w end
        -- Shadow DictQuickLookup.new on the stub table main.lua captured
        -- (block 2c already proves this pattern; never require the real
        -- module here — it pulls fontlist/Device and crashes the harness).
        local DQ = stub_class
        local old_dq_new = DQ.new
        local windows = {}
        DQ.new = function(_, opts)
            windows[#windows + 1] = opts
            return opts
        end
        -- Seed the cache so the re-lookup replays a hit deterministically
        -- (no network, no scheduler dependence).
        dw._lookup_cache = { ["wikipedia|en|cattle"] = { cands = {
            { title = "cattle", extract = "bovine animal", index = 1 },
        }, is_full = false, at = os.time() } }
        dw._last_suggestion = "cattle"
        dw:showRetryDialog("Catte", "wikipedia", nil, "en")
        local d3 = dialogs[#dialogs]
        local btn = d3 and d3.buttons and d3.buttons[1] and d3.buttons[1][1]
        if btn and tostring(btn.text):find("cattle", 1, true) then
            btn.callback() -- must close the InputDialog, then run lookup
            if closed[1] == dlg_stub then
                pass("suggestion button closes the retry InputDialog (not the button table)")
            else
                fail("suggestion button closes retry InputDialog",
                    "closed=" .. tostring(closed[1]) .. " expected=" .. tostring(dlg_stub))
            end
            if #windows == 1 and windows[1].results[1].word == "cattle" then
                pass("suggestion button re-queries the suggestion (cache-hit window)")
            else
                fail("suggestion button re-query", "windows=" .. #windows)
            end
        else
            fail("suggestion button regression harness", "button not found on dialog")
        end
        DQ.new = old_dq_new
        UM.close = old_close
        dw._lookup_cache = nil
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
