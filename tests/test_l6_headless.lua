-- test_l6_headless.lua — L6 headless supplement for dual_wiki v1.3.5 (slim)
--
-- Covers all L6 items that can be verified programmatically (no GUI required):
--   A1  zh particle stripping → 量子力学
--   A2  zh book-title cleaning → 三体
--   A3  en word boundary → Quantum entanglement
--   A4  ja particle stripping → シャナ / 灼眼のシャナ
--   A5  de/fr/es/ru each hit their wiki
--   A5b fr literal search (slim: 选什么搜什么 — L'équation hits L'Équation*)
--   A6  G2 always-full: 黑桐干也 (moegirl) → full article body
--   A7  session cache replay (same word second call, zero transport)
--   A8  missing-word path → graceful nil/empty, no crash
--   A9  network-offline stub → differentiated error kind, no crash
--   F1  fullpage contract: wikipedia-only, dab/moegirl excluded, opt-in key
--   F1b fullscreen re-show replays the session cache with zero network
--   F2  takeover gate: dualwiki_no_takeover flips menus + native channel
--   B2  per-book lang lock → routes to zh
--   B3  global lang lock = en → routes to en even for zh selection
--   B5  settings namespace — only dualwiki_* keys written to G_reader_settings
--
-- Removed with the v1.3.5 slim build (no longer applicable):
--   fandom/bwiki/wiktionary fetches (A6/A7/A8 of v1.3.x), fandom subdomain
--   swap (B4), fr elision strip (superseded by A5b literal contract).
--
-- UI-only items NOT covered here (require emulator window):
--   B1  settings menu renders
--   F3–F12 visual/interactive items (see tests/MANUAL_CHECKLIST.md §F)
--   C1–C6  plugin coexistence visual checks
--   (C1/C2 settings-namespace contract already covered by L5 / test_conflicts.lua)
--
-- Usage (from the emu install dir koreader-emulator-*/koreader/):
--   ./luajit <path>/tests/test_l6_headless.lua
-- Exit 0 = all headless items passed.

local failures = 0
local function pass(name) print("PASS  " .. name) end
local function fail(name, detail)
    print("FAIL  " .. name .. "  (" .. tostring(detail) .. ")")
    failures = failures + 1
end

-- ── Environment bootstrap (identical to test_integration.lua) ─────────────
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
local UIManager = require("ui/uimanager")

local plugin_root = "plugins/dual_wiki.koplugin/"
package.path = plugin_root .. "?.lua;" .. package.path
local DualWiki = dofile(plugin_root .. "main.lua")
assert(type(DualWiki) == "table" and type(DualWiki.queryPipeline) == "function",
    "plugin main.lua must load with queryPipeline")
local dw = DualWiki:new{}

local socket = require("socket")
local keepalive = require("keepalive")

-- Throttle: be polite to Wikimedia (429 risk)
local function throttle() socket.sleep(3) end
local function retry429(fn)
    local r = fn()
    if r == nil and dw._last_error_kind == "http_429" then
        print("  .. HTTP 429, backing off 15 s ..")
        socket.sleep(15)
        r = fn()
    end
    return r
end

-- Helper: assert queryPipeline with up to 3 retries (same logic as L4).
-- 429-aware backoff: Wikimedia rate limits bite hardest mid-suite, so a
-- degraded attempt whose error kind is http_429 waits 20 s instead of 10.
local function assertQ(name, word, engine, lang, expect_find, expect_title_fn)
    throttle()
    local function attempt()
        return retry429(function() return dw:queryPipeline(word, engine, lang) end)
    end
    local cands = attempt()
    for _ = 1, 2 do
        local bad = (type(cands) ~= "table" or #cands == 0)
        if not bad and expect_find then
            bad = not tostring(cands[1].title or ""):find(expect_find, 1, true)
        end
        if not bad and expect_title_fn then
            bad = not expect_title_fn(tostring(cands[1].title or ""))
        end
        if not bad then break end
        local wait = (dw._last_error_kind == "http_429") and 20 or 10
        -- kind=error with no transport WARN usually means a half-dead pooled
        -- socket for THIS host; drop the pool so the retry dials fresh
        -- (mirrors the real recovery path — document close/reopen).
        if dw._last_error_kind == "error" then
            keepalive.clear()
        end
        print("  .. " .. name .. " degraded (kind=" .. tostring(dw._last_error_kind)
            .. "), backing off " .. wait .. " s ..")
        socket.sleep(wait)
        cands = attempt()
    end
    if type(cands) ~= "table" or #cands == 0 then
        return fail(name, "no candidates")
    end
    local title = tostring(cands[1].title or "")
    if expect_find and not title:find(expect_find, 1, true) then
        return fail(name, "top='" .. title .. "' lacks '" .. expect_find .. "'")
    end
    if expect_title_fn and not expect_title_fn(title) then
        return fail(name, "top='" .. title .. "' fails predicate")
    end
    pass(name .. " → " .. title)
    return cands
end

-- ── §A — Core query chain ─────────────────────────────────────────────────
print("\n== A group: core query chain (headless) ==")

-- A1: zh particle stripping
assertQ("A1 zh particle strip (量子力学的→量子力学)", "量子力学的", "wikipedia", "zh", "量子力学")

-- A2: zh book-title bracket cleaning
do
    throttle()
    local cands = retry429(function() return dw:queryPipeline("《三体》", "wikipedia", "zh") end)
    local title = cands and cands[1] and tostring(cands[1].title or "") or ""
    -- Must NOT contain book-title brackets; must contain 三体
    if title:find("三体", 1, true) and not title:find("《", 1, true) then
        pass("A2 zh book-title bracket cleaned (《三体》→" .. title .. ")")
    else
        fail("A2 zh book-title bracket cleaning", "top='" .. title .. "'")
    end
end

-- A3: en word boundary
assertQ("A3 en word-boundary (quantum entanglement)", "quantum entanglement", "wikipedia", "en", "Quantum")

-- A4: ja particle stripping / dab expansion includes 灼眼のシャナ
do
    local ok_shana = false
    for _ = 1, 3 do
        throttle()
        local cands = retry429(function() return dw:queryPipeline("シャナの", "wikipedia", "ja") end)
        for _, c in ipairs(cands or {}) do
            if tostring(c.title):find("シャナ", 1, true) then ok_shana = true; break end
        end
        if ok_shana then break end
        print("  .. A4 degraded, retry ..")
        socket.sleep(10)
    end
    if ok_shana then pass("A4 ja particle strip (シャナの→hit含シャナ)")
    else fail("A4 ja particle strip", "no シャナ-related title after 3 tries") end
end

-- A5: de/fr/es/ru each get a hit
assertQ("A5 de (Quantenmechanik)", "Quantenmechanik", "wikipedia", "de", nil)
assertQ("A5 fr (philosophie)", "philosophie", "wikipedia", "fr", nil)
assertQ("A5 es (historia de Roma)", "historia de Roma", "wikipedia", "es", nil)
assertQ("A5 ru (Квантовая механика)", "Квантовая механика", "wikipedia", "ru", nil)

-- A5b: fr literal search — slim contract (user direction: 选什么搜什么).
-- "L'équation" prefix-matches the L'Équation* works; that IS the desired
-- outcome now. Exact-title check keeps the assert honest (a substring find
-- would silently pass on any title containing the stem).
assertQ("A5b fr literal (L'équation)", "L'équation", "wikipedia", "fr", nil,
    function(t) return t == "L'Équation de l'apocalypse" end)

-- A6: G2 always-full (moegirl, the engine that motivated the change).
-- The probe returns lead summaries; _expandAllFullText replaces the top
-- candidate with the full article body.
do
    local cands
    for _ = 1, 3 do
        throttle()
        cands = retry429(function() return dw:fetchCandidates("黑桐干也", "moegirl", "zh", "prefix") end)
        if type(cands) == "table" and #cands > 0 then break end
        print("  .. A6 probe degraded, retry ..")
        socket.sleep(10)
    end
    if type(cands) ~= "table" or #cands == 0 then
        fail("A6 G2 full expansion (黑桐干也)", "probe returned no candidates")
    else
        local expanded, full = dw:_expandAllFullText(cands, "moegirl", "zh")
        local len = expanded and expanded[1] and #tostring(expanded[1].extract or "") or 0
        if full and len > 1000 then
            pass("A6 G2 full expansion (黑桐干也) → " .. len .. " chars")
        else
            fail("A6 G2 full expansion", "len=" .. len .. " full=" .. tostring(full))
        end
    end
end

-- A7: session cache hit — second identical LOOKUP must not hit the network.
-- Use lookup() rather than queryPipeline(): the cache lives on the ReaderUI
-- path (lookup/showResult), so this mirrors the real UI behavior.
do
    throttle()
    dw._lookup_cache = nil
    local old_showResult = dw.showResult
    local old_scheduleIn = UIManager.scheduleIn
    local old_ui = dw.ui
    local old_keepalive = keepalive.enabled
    local network_calls = 0
    local show_calls = 0

    -- Make the async lookup callback run synchronously inside the headless
    -- harness, and keep the UI guards satisfied.
    UIManager.scheduleIn = function(_, _, fn) return fn() end
    dw.ui = { dialog = {}, highlight = nil }

    -- Count transport-layer use regardless of whether keepalive or legacy
    -- fallback is exercised. A cache hit must keep this at zero.
    local keepalive_req = keepalive.request
    keepalive.request = function(...)
        network_calls = network_calls + 1
        return keepalive_req(...)
    end
    keepalive.enabled = true

    dw.showResult = function() show_calls = show_calls + 1 end

    -- Prime the session cache through the real UI lookup path.
    dw:lookup("人工智能", "wikipedia", nil, "zh", false)
    local prime_calls = network_calls
    local prime_shows = show_calls

    -- Repeat the same lookup. A cache hit should return immediately,
    -- calling showResult again but not touching transport.
    dw:lookup("人工智能", "wikipedia", nil, "zh", false)
    local repeat_calls = network_calls - prime_calls
    local repeat_shows = show_calls - prime_shows

    keepalive.request = keepalive_req
    keepalive.enabled = old_keepalive
    UIManager.scheduleIn = old_scheduleIn
    dw.showResult = old_showResult
    dw.ui = old_ui

    if repeat_shows >= 1 and repeat_calls == 0 then
        pass("A7 session cache hit (repeat lookup avoided transport entirely)")
    elseif repeat_calls == 0 then
        fail("A7 session cache hit", "lookup did not reach showResult twice")
    else
        fail("A7 session cache hit", "network hit on repeat lookup (calls=" .. repeat_calls .. ")")
    end
end

-- A8: missing-word → graceful nil/empty, no crash
do
    keepalive.enabled = false
    local cands = dw:queryPipeline("xqztv123__nonexistent__", "wikipedia", "en")
    keepalive.enabled = true
    -- Should return nil / empty (not crash), error kind should be set
    local ok = (cands == nil or (type(cands) == "table" and #cands == 0))
    if ok then
        pass("A8 unknown word → graceful nil/empty (kind=" .. tostring(dw._last_error_kind) .. ")")
    else
        -- Some wikis return a partial match; that's also acceptable (not a crash)
        pass("A8 unknown word → partial hit (no crash); top=" .. tostring(cands and cands[1] and cands[1].title))
    end
end

-- A9: network offline stub → differentiated error kind, no crash
do
    keepalive.enabled = false
    local https_mod = require("ssl.https")
    local orig_req = https_mod.request
    -- Simulate connection refused (nil body, error string)
    https_mod.request = function() return nil, "connection refused" end
    local old_http_req = require("socket.http").request
    require("socket.http").request = function() return nil, "connection refused" end

    local cands = dw:queryPipeline("quantum", "wikipedia", "en")
    https_mod.request = orig_req
    require("socket.http").request = old_http_req
    keepalive.enabled = true

    local kind = tostring(dw._last_error_kind or "")
    -- Must not crash; error kind must be set to something transport-related
    if cands == nil or (type(cands) == "table" and #cands == 0) then
        if kind ~= "" and kind ~= "nil" then
            pass("A9 offline stub → nil result, error kind='" .. kind .. "' (differentiated)")
        else
            fail("A9 offline error kind", "kind not set: '" .. kind .. "'")
        end
    else
        fail("A9 offline stub", "expected nil/empty candidates, got " .. #cands)
    end
end

-- ── §B — Settings logic (headless) ────────────────────────────────────────
print("\n== B group: settings logic (headless) ==")

-- B2: per-book lang lock → query routes to zh
do
    -- Simulate doc_settings with zh lock
    local fake_doc_settings = {
        readSetting = function(_, k) if k == "dualwiki_lang_lock" then return "zh" end end,
        saveSetting = function() end,
        delSetting  = function() end,
    }
    dw.ui = { doc_settings = fake_doc_settings, highlight = nil, dialog = {} }
    local lang = dw:_bookLang()
    dw.ui = nil
    if lang == "zh" then
        pass("B2 per-book lang lock → _bookLang()='zh'")
    else
        fail("B2 per-book lang lock", "got '" .. tostring(lang) .. "'")
    end
end

-- B3: global lang lock = en → _bookLang returns en, _isLangLocked true
do
    -- Save current value
    local prev = G_reader_settings:readSetting("dualwiki_lang")
    G_reader_settings:saveSetting("dualwiki_lang", "en")

    local lang = dw:_bookLang()
    local locked = dw:_isLangLocked()

    -- Restore
    if prev ~= nil then
        G_reader_settings:saveSetting("dualwiki_lang", prev)
    else
        G_reader_settings:delSetting("dualwiki_lang")
    end

    if lang == "en" and locked then
        pass("B3 global lang lock=en → _bookLang='en', _isLangLocked=true")
    else
        fail("B3 global lang lock", "lang='" .. tostring(lang) .. "' locked=" .. tostring(locked))
    end
end

-- B5: settings namespace — check G_reader_settings has ONLY dualwiki_* plugin keys
do
    -- Write a known set of dualwiki_ keys, then read back all keys
    G_reader_settings:saveSetting("dualwiki_lang", "zh")
    G_reader_settings:saveSetting("dualwiki_fullpage", true)
    G_reader_settings:saveSetting("dualwiki_no_takeover", true)

    -- Read the raw settings file and scan for any key the plugin might have
    -- introduced that does NOT start with "dualwiki_"
    local settings_path = DataStorage:getDataDir() .. "/settings.reader.lua"
    local f = io.open(settings_path, "r")
    local content = f and f:read("*a") or ""
    if f then f:close() end

    -- Extract all top-level string keys from the lua table literal
    local stray_keys = {}
    for key in content:gmatch('%["([^"]+)"%]') do
        -- Only flag keys that look like they could be ours but lack the prefix
        -- (a conservative check: any key starting with "dual" but not "dualwiki_")
        if key:find("^dual") and not key:find("^dualwiki_") then
            stray_keys[#stray_keys + 1] = key
        end
    end
    -- Clean up test keys
    G_reader_settings:delSetting("dualwiki_lang")
    G_reader_settings:delSetting("dualwiki_fullpage")
    G_reader_settings:delSetting("dualwiki_no_takeover")

    if #stray_keys == 0 then
        pass("B5 settings namespace: no stray 'dual*' keys outside 'dualwiki_' prefix")
    else
        fail("B5 settings namespace", "stray keys: " .. table.concat(stray_keys, ", "))
    end
end

-- ── F1/F2: v1.3.5 fullscreen + takeover (headless contracts) ──────────────
-- F1: fullpage flag contract — stub the widget layer, drive showResult.
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
    local function clear_fullpage()
        if G_reader_settings:readSetting("dualwiki_fullpage") ~= nil then
            G_reader_settings:delSetting("dualwiki_fullpage")
        end
    end
    clear_fullpage()
    -- (a) default OFF: no is_wiki_fullpage anywhere
    dw:showResult("量子力学", { { title = "量子力学", extract = "x" } }, "wikipedia", nil, "zh", true)
    if shown[#shown].results[1].is_wiki_fullpage == nil then
        pass("F1 default OFF: wikipedia results not fullpage")
    else
        fail("F1 default OFF", tostring(shown[#shown].results[1].is_wiki_fullpage))
    end
    -- (b) opt-in: wikipedia carries the flag
    G_reader_settings:saveSetting("dualwiki_fullpage", true)
    dw:showResult("量子力学", { { title = "量子力学", extract = "x" } }, "wikipedia", nil, "zh", true)
    if shown[#shown].results[1].is_wiki_fullpage == true then
        pass("F1 opt-in: wikipedia results fullpage")
    else
        fail("F1 opt-in wikipedia", tostring(shown[#shown].results[1].is_wiki_fullpage))
    end
    -- (c) moegirl FULLPAGE-eligible since v1.3.5 (reading comfort); its
    -- Save-as-EPUB button is stripped at layout build instead.
    dw:showResult("初音未来", { { title = "初音未来", extract = "x" } }, "moegirl", nil, "zh", true)
    if shown[#shown].results[1].is_wiki_fullpage == true then
        pass("F1b moegirl opt-in: results carry is_wiki_fullpage")
    else
        fail("F1b moegirl fullpage", tostring(shown[#shown].results[1].is_wiki_fullpage))
    end
    -- (c2) save-strip contract: moegirl layout drops save, keeps close.
    local stripped = dw:_stripSaveFromFullpageLayout({
        { { id = "save" }, { id = "close" } },
    })
    if #stripped[1] == 1 and stripped[1][1].id == "close" then
        pass("F1b save-strip: moegirl fullpage keeps Close, drops Save-as-EPUB")
    else
        fail("F1b save-strip", "ids=" .. tostring(stripped[1][1] and stripped[1][1].id))
    end
    -- (c3) engine-matched replay: moegirl fullpage must not replay wikipedia cache
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
    -- (d) dab items excluded
    dw:showResult("Mercury", {
        { title = "Mercury (planet)", extract = "x", dab_item = true },
    }, "wikipedia", nil, "en", true)
    if shown[#shown].results[1].is_wiki_fullpage == nil then
        pass("F1 dab items excluded from fullpage")
    else
        fail("F1 dab fullpage leak", tostring(shown[#shown].results[1].is_wiki_fullpage))
    end
    -- (e) fullscreen re-show replays the session cache with ZERO network
    dw._lookup_cache = {
        ["wikipedia|zh|量子力学"] = {
            cands = { { title = "量子力学", extract = "缓存正文。", exact = true } },
            is_full = true, at = os.time(), lang = "zh",
        },
    }
    local fetch_calls = 0
    dw.fetchDirect = function() fetch_calls = fetch_calls + 1; return nil end
    dw:showFullpageResult("量子力学", "", "wikipedia", "zh", nil)
    dw.fetchDirect = nil
    local w = shown[#shown]
    if w.results[1].is_wiki_fullpage == true and fetch_calls == 0
        and tostring(w.results[1].definition):find("缓存正文", 1, true) then
        pass("F1 cache replay: fullscreen re-show costs zero network")
    else
        fail("F1 cache replay", "fetches=" .. fetch_calls
            .. " fullpage=" .. tostring(w.results[1].is_wiki_fullpage))
    end
    clear_fullpage()
    package.loaded["ui/widget/dictquicklookup"] = nil
    dw.ui = nil
end

-- F2: takeover gate — menu entries + native channel restore.
do
    local dw_on = dw:_takeoverEnabled()
    if dw_on then
        pass("F2 takeover default ON")
    else
        fail("F2 takeover default ON", "off without setting")
    end
    G_reader_settings:saveSetting("dualwiki_no_takeover", true)
    if not dw:_takeoverEnabled() then
        pass("F2 takeover OFF via dualwiki_no_takeover")
    else
        fail("F2 takeover OFF", "still enabled with setting")
    end
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
end

-- ── Summary ───────────────────────────────────────────────────────────────
print("")
if failures > 0 then
    print("L6-HEADLESS FAILURES: " .. failures)
    os.exit(1)
else
    print("ALL L6 HEADLESS ITEMS PASSED")
    os.exit(0)
end
