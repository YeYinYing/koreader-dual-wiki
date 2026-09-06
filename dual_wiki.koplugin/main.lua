--[[--
Dual-Engine Encyclopedia (Moegirlpedia + Wikipedia + Fandom + more) Plugin for KOReader.

Copyright (C) 2026 YeYinYing

This program is free software: you can redistribute it and/or modify
it under the terms of the GNU Affero General Public License as
published by the Free Software Foundation, either version 3 of the
License, or (at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU Affero General Public License for more details.

You should have received a copy of the GNU Affero General Public License
along with this program.  If not, see <https://www.gnu.org/licenses/>.

v1.3.0 — Phase 2.2 European Languages, Settings & Infrastructure:

1. Phase 2.2 languages: German / French / Spanish / Russian Wikipedia via
   dynamic button slots — the five hard-coded highlight buttons collapse
   into two slots whose factory re-resolves the book language on every
   highlight-menu invocation (button text, visibility and target engine
   all live). de/fr/es/ru books get [Wikipedia (XX)] [Wikipedia (EN)].
2. Settings hub (menu → Dual Wiki settings): language lock per book
   (doc_settings) and globally, Fandom community / BWiki game subdomain
   prompts, session-cache clear. This fulfils the HANDOVER section 5
   language-lock UI commitment.
3. Engine matrix growth: Bilibili Game Wiki (wiki.biligame.com, MediaWiki,
   parse adapter) and Wiktionary (en/ja) join via the fullTextViaParse flag.
4. parse-engine two-phase fetch: section=0 intro first (tens of KB);
   auto-upgrade to the full page only when the intro is < 300 bytes —
   low-RAM devices no longer decode 1.5 MB Fandom pages routinely.
5. Session lookup cache: identical word/engine/lang repeats skip the
   network (LRU-capped at 32), cleared on document close or on demand.
6. sharesPrefix Latin branch generalized to %S+ so Cyrillic (ru) titles
   pass the prefix-relation guard.
7. normalizeLang extended: ger/deu→de, fre/fra→fr, spa→es, rus→ru.

Inherits from v1.2.x — cross-device hardening (https dispatch, explicit
zh body-text variant, device-agnostic UA, differentiated transport error
hints, moegirl fast-fail), Phase 2.1 globalization (engine registry,
language-aware particles, context-aware detection, gettext i18n).

Enables seamless online search and definition lookup across:
1. ACG / Anime terms from Moegirlpedia (zh.moegirl.org.cn)
2. General knowledge from Wikipedia (zh/ja/en/de/fr/es/ru.wikipedia.org)
3. Pop-culture from Fandom communities (starwars, genshin-impact, ...)
4. Game lore from Bilibili game wikis (wiki.biligame.com)
5. Word definitions from Wiktionary (en/ja.wiktionary.org)
--]]--

local DictQuickLookup = require("ui/widget/dictquicklookup")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local NetworkMgr = require("ui/network/manager")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local JSON = require("json")
local http = require("socket.http")
local https = require("ssl.https")
local socket = require("socket")
local socketutil = require("socketutil")
local socket_url = require("socket.url")
local util = require("util")
local logger = require("logger")
local ffiUtil = require("ffi/util")
local T = ffiUtil.template
local _ = require("gettext")
local GetText = require("gettext")

local DualWiki = WidgetContainer:extend{
    name = "dual_wiki",
    is_doc_only = false,
}

-- Plugin directory (for locale loading), derived from this module's path.
local PLUGIN_DIR = (debug.getinfo(1, "S").source or ""):match("^@?(.*)/[^/]*$") or ""

-- Safe linefeed character constant
local LF = string.char(10)

-- (capped at 2MB: a 512MB e-ink device cannot afford unbounded remote bodies)
local MAX_RESPONSE_BYTES = 2 * 1024 * 1024

-- v1.2.1 (M1-A3): device-agnostic User-Agent. The old hard-coded
-- "KOReader/2024.04 (Kindle)" misrepresented every device as a Kindle and
-- skewed per-platform statistics. Bump alongside _meta.lua on release.
local PLUGIN_VERSION = "1.3.1"
local USER_AGENT = "dual_wiki.koplugin/" .. PLUGIN_VERSION .. " (KOReader)"

-- Retrieval pipeline tuning
local MAX_CANDIDATES = 4      -- candidates per merged request (server clamps full-text extracts to 1/page, intro mode allows all)
local PROBE_TIMEOUT = 10      -- merged probe request timeout (seconds)
local DIRECT_TIMEOUT = 12     -- full-article request timeout (seconds)
local MOEGIRL_TIMEOUT = 5     -- v1.2.1 (M1-A5): fast-fail for moegirl (DNS-poisoned in some regions)

-- [[ query-helpers:start ]] (pure functions, unit-testable in isolation)

local function strTrim(s)
    return (s or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

-- Minimal UTF-8 helpers (byte-walking, no external deps, Lua 5.1 safe)
local function utf8Len(s)
    local n, i = 0, 1
    while i <= #s do
        n = n + 1
        local b = s:byte(i)
        if b < 0x80 then i = i + 1
        elseif b < 0xE0 then i = i + 2
        elseif b < 0xF0 then i = i + 3
        else i = i + 4 end
    end
    return n
end

local function utf8First(s)
    if #s == 0 then return "" end
    local b = s:byte(1)
    local w = b < 0x80 and 1 or (b < 0xE0 and 2 or (b < 0xF0 and 3 or 4))
    return s:sub(1, w)
end

local function utf8Last(s)
    if #s == 0 then return "" end
    local i = #s
    while i > 1 do
        local b = s:byte(i)
        if b < 0x80 or b >= 0xC0 then break end
        i = i - 1
    end
    return s:sub(i)
end

-- which: "head" | "tail" | "both"
local function utf8Chop(s, which)
    if #s == 0 then return s end
    if which == "head" then
        return s:sub(#utf8First(s) + 1)
    elseif which == "tail" then
        return s:sub(1, #s - #utf8Last(s))
    else
        return s:sub(#utf8First(s) + 1, #s - #utf8Last(s))
    end
end

-- Zero-width noise: U+200B/200C/200D (UTF-8: E2 80 8B/8C/8D) and U+FEFF (EF BB BF)
local ZERO_WIDTH = { "\226\128\139", "\226\128\140", "\226\128\141", "\239\187\191" }

-- Wrapper brackets eligible for stripping. CJK only for unmatched-side
-- stripping: ASCII ( ) " ' are legal in-word characters ((G)I-DLE, 1") and
-- must never be touched.
local OPEN_WRAPPERS = {
    ["《"] = "》", ["「"] = "」", ["『"] = "』", ["【"] = "】", ["［"] = "］",
    ["（"] = "）", ["〈"] = "〉", ["〔"] = "〕", ["“"] = "”", ["‘"] = "’", ["«"] = "»",
}
local CLOSE_WRAPPERS = {
    ["》"] = true, ["」"] = true, ["』"] = true, ["】"] = true, ["］"] = true,
    ["）"] = true, ["〉"] = true, ["〕"] = true, ["”"] = true, ["’"] = true, ["»"] = true,
}

-- Stage-1 sanitation: wrapper brackets + zero-width noise + whitespace.
-- Audit rule (mishit guard): only the OUTERMOST pairing is stripped, never
-- any in-word punctuation (: / · - etc. are untouched).
local function sanitizeQuery(raw)
    local q = raw or ""
    for _, zw in ipairs(ZERO_WIDTH) do
        q = q:gsub(zw, "")
    end
    q = q:gsub("^%s+", ""):gsub("%s+$", "")
    q = q:gsub("%s+", " ")
    for _ = 1, 4 do
        if q == "" then break end
        local head, tail = utf8First(q), utf8Last(q)
        if OPEN_WRAPPERS[head] == tail then
            q = utf8Chop(q, "both")
        elseif CLOSE_WRAPPERS[tail] and not OPEN_WRAPPERS[head] then
            q = utf8Chop(q, "tail")
        elseif OPEN_WRAPPERS[head] and not CLOSE_WRAPPERS[tail] then
            if utf8Len(q) > 2 then
                q = utf8Chop(q, "head")
            else
                break
            end
        else
            break
        end
    end
    if q == "" then q = raw or "" end
    return q
end

-- Stage-2 sanitation (协同改进项 1): language-aware trailing-particle drop,
-- only as a fallback after the exact query missed. Byte-exact comparison (no
-- Lua byte-class patterns) prevents false hits inside other CJK characters.
-- English plural-s is deliberately absent: "physics" → "physic" would be a
-- regression; only the possessive 's is a safe particle.
local PARTICLES = {
    zh = { "的", "地", "得", "了", "着", "过", "等", "中", "下", "里", "上", "之" },
    ja = { "の", "に", "を", "は", "が", "で", "と", "へ", "も", "な", "よ", "ね" },
    en = { "'s", "’s" },
}
local function stripTrailingParticle(q, lang)
    local list = PARTICLES[lang] or PARTICLES.zh
    if q == "" or utf8Len(q) <= 2 then return q end
    for _, p in ipairs(list) do
        if q:sub(-#p) == p then
            local stripped = q:sub(1, #q - #p)
            if utf8Len(stripped) >= 2 then
                return stripped
            end
        end
    end
    return q
end

-- v1.3.2: French/Romance elision (l'amour → amour, qu'il → il). An elided
-- article at the head of the selection breaks prefixsearch (the article
-- lives under the bare word). This is strictly a FALLBACK strip: the exact
-- query always runs first, so titles that legitimately begin with an
-- article ("Les Misérables") are safe — their case-insensitive exact form
-- hits in Stage 1 and this strip never executes. Longest-match wins so
-- "jusqu'à" is never mangled into "jus" by the "qu'" entry; a remainder
-- shorter than 2 characters aborts the strip. Each stem is tried with both
-- the ASCII apostrophe and the typographic one (U+2019).
local ELISION_STEMS = { "jusqu", "qu", "l", "d", "n", "s", "j", "c", "m", "t", "un" }
local ELISION_LANGS = { fr = true, it = true, pt = true }
local ELISION_APOSTROPHES = { "'", "\226\128\153" }
local function stripLeadingElision(q, lang)
    if not ELISION_LANGS[lang] then return q end
    if utf8Len(q) < 4 then return q end
    -- Match case-insensitively: sentence-initial selections arrive as
    -- "L'Étranger", "Qu'il" etc. Stems are pure ASCII, so lowercasing the
    -- first few bytes never shifts byte boundaries — the match length can
    -- be applied to the original string directly.
    local probe = q:sub(1, 10):lower()
    local best
    for _, stem in ipairs(ELISION_STEMS) do
        for _, apos in ipairs(ELISION_APOSTROPHES) do
            local head = stem .. apos
            if probe:sub(1, #head) == head and (not best or #head > #best) then
                best = head
            end
        end
    end
    if not best then return q end
    local stripped = q:sub(#best + 1)
    if utf8Len(stripped) < 2 then return q end
    return stripped
end

-- Latin script languages get the word-boundary good-hit rule (协同改进项 2).
local LATIN_LANGS = { en = true, de = true, fr = true, es = true, ru = true, it = true, pt = true }

-- A "good hit" is an exact match, or:
--   CJK: a title sharing the query's full prefix and ≤2 chars longer
--        (小笠原道 → 小笠原道大); long prefix-noise (量子力学的数学基础)
--        does NOT qualify, so the pipeline keeps degrading.
--   Latin: case-insensitive exact or word-boundary prefix
--        (quantum → Quantum mechanics; jedi → Jedi; wookieepedia is not
--        matched by "wookie" — next char must be space/end).
local function hasGoodHit(cands, q, lang)
    if not cands then return false end
    if LATIN_LANGS[lang] then
        local ql = q:lower()
        for _, c in ipairs(cands) do
            local tl = c.title:lower()
            if tl == ql then
                return true
            end
            if tl:sub(1, #ql) == ql then
                local nxt = c.title:sub(#q + 1, #q + 1)
                if nxt == "" or nxt == " " then
                    return true
                end
            end
        end
        return false
    end
    local q_len = utf8Len(q)
    for _, c in ipairs(cands) do
        if c.title == q then
            return true
        end
        if q_len >= 2 and c.title:sub(1, #q) == q and utf8Len(c.title) - q_len <= 2 then
            return true
        end
    end
    return false
end

-- Prefix-relation guard for content acceptance (Stage 4/5): only accept a
-- top candidate that demonstrably relates to the query — CJK: ≥2 shared
-- leading characters (拿破仑一世 ↔ 拿破仑·波拿巴); Latin: the query's first
-- word appears at the title's start (word length ≥3). Rejects moegirl's
-- kana-index quirk where シャナ surfaces the unrelated "Shanna".
local function sharesPrefix(title, q, lang)
    if not title or not q or title == "" or q == "" then return false end
    if LATIN_LANGS[lang] then
        -- v1.3.0: %a only matches ASCII letters, which fails for Cyrillic
        -- (ru) titles; %S+ accepts any non-space script's first word.
        local first_word = title:lower():match("^(%S+)")
        if not first_word or #first_word < 3 then return false end
        return q:lower():sub(1, #first_word) == first_word
    end
    local n, i = 0, 1
    while i <= #title and i <= #q do
        local bt, bq = title:byte(i), q:byte(i)
        if bt ~= bq then break end
        local w = bt < 0x80 and 1 or (bt < 0xE0 and 2 or (bt < 0xF0 and 3 or 4))
        if title:sub(i, i + w - 1) ~= q:sub(i, i + w - 1) then break end
        n = n + 1
        i = i + w
    end
    return n >= 2
end

local function sharesPrefixAny(cands, q, lang)
    if not cands then return false end
    for _, c in ipairs(cands) do
        if sharesPrefix(c.title, q, lang) then
            return true
        end
    end
    return false
end

-- Rank merged-request candidates. Server index order (already
-- redirect-expanded and prefix-relevance sorted) is authoritative; we only
-- promote an EXACT title match to the front. Byte-prefix re-ranking is
-- deliberately avoided: zh.wikipedia redirects (三体→三體) would otherwise be
-- pushed below longer prefix-noise titles.
local function parseCandidatePages(data, query)
    local pages = data.query.pages
    if type(pages) ~= "table" then return nil end
    local cands = {}
    for _, page in ipairs(pages) do
        if type(page) == "table" and page.title and page.ns == 0 and not page.missing then
            cands[#cands + 1] = {
                title = page.title,
                extract = page.extract or "",
                index = page.index or 999,
                exact = (page.title == query),
            }
        end
    end
    table.sort(cands, function(a, b)
        if a.exact ~= b.exact then
            return a.exact
        end
        return a.index < b.index
    end)
    return #cands > 0 and cands or nil
end

-- Normalize a doc-props language field ("zh-CN", "en_US", "eng", "ja"…) to a
-- plugin language key. v1.3.0 (Phase 2.2) extends the map to the European
-- tier-two languages; anything unknown still defaults to zh.
local LANG_MAP = {
    zh = "zh", zho = "zh", chi = "zh", cn = "zh",
    en = "en", eng = "en",
    ja = "ja", jpn = "ja", jp = "ja",
    de = "de", ger = "de", deu = "de",
    fr = "fr", fre = "fr", fra = "fr",
    es = "es", spa = "es",
    ru = "ru", rus = "ru",
}
local function normalizeLang(raw)
    if not raw then return "zh" end
    local base = raw:lower():match("^([a-z]+)")
    return LANG_MAP[base] or "zh"
end

-- v1.2.1 (M1): resolve the explicit zh body-text variant from the raw doc
-- language metadata. converttitles=1 only aligns TITLES server-side; the
-- extract BODY stays in an environment-dependent variant (measured:
-- zh.wikipedia served traditional text for a simplified book) unless
-- variant=zh-cn|zh-hant is forced on every wikipedia+zh request.
local ZH_HANT_SCRIPTS = { HANT = true, TW = true, HK = true, MO = true }
local ZH_HANS_SCRIPTS = { HANS = true, CN = true, SG = true, MY = true }
local function zhVariantOf(raw)
    local script = tostring(raw or ""):upper():match("^ZH[_%-]?(%a*)")
    if ZH_HANT_SCRIPTS[script] then return "zh-hant" end
    if ZH_HANS_SCRIPTS[script] then return "zh-cn" end
    return "zh-cn"
end

-- [[ query-helpers:end ]]

-- Engine registry (多百科矩阵): MediaWiki-native endpoints with per-engine
-- URL/label/variant/particle policies. converttitles=1 is STRICTLY isolated
-- to wikipedia+zh (协同改进项 3).
local ENGINES = {
    wikipedia = {
        api = function(lang)
            return string.format("https://%s.wikipedia.org/w/api.php", lang or "zh")
        end,
        label = function(lang)
            local l = lang or "zh"
            if l == "ja" then return _("Wikipedia (JA)") end
            if l == "en" then return _("Wikipedia (EN)") end
            return _("Wikipedia (ZH)")
        end,
        needsConverttitles = function(lang) return (lang or "zh") == "zh" end,
        particleLang = function(lang) return lang or "zh" end,
        switchTarget = function() return "moegirl" end,
    },
    moegirl = {
        api = function()
            return "https://zh.moegirl.org.cn/api.php"
        end,
        label = function()
            return _("Moegirlpedia")
        end,
        needsConverttitles = function() return false end,
        -- zh.moegirl serves Japanese terms too (シャナ etc.); particles follow
        -- the query/book language rather than the site language.
        particleLang = function(lang) return lang or "zh" end,
        switchTarget = function() return "wikipedia" end,
    },
    fandom = {
        api = function(sub)
            return string.format("https://%s.fandom.com/api.php", sub or "starwars")
        end,
        label = function(sub)
            return string.format(_("Fandom (%s)"), sub or "starwars")
        end,
        needsConverttitles = function() return false end,
        particleLang = function() return "en" end,
        switchTarget = function() return "wikipedia" end,
        -- v1.3.0: parse-engine flag — Fandom ships no TextExtracts, so
        -- candidates are title-only and full articles go through action=parse.
        fullTextViaParse = true,
    },
    -- v1.3.0 (Phase 2.2+): Bilibili game wikis (Genshin Impact, Minecraft…).
    -- Same MediaWiki core as Fandom, same missing TextExtracts adapter.
    bwiki = {
        api = function(sub)
            return string.format("https://wiki.biligame.com/%s/api.php", sub or "ys")
        end,
        label = function(sub)
            return string.format(_("Bilibili Game Wiki (%s)"), sub or "ys")
        end,
        needsConverttitles = function() return false end,
        particleLang = function() return "zh" end,
        switchTarget = function() return "wikipedia" end,
        fullTextViaParse = true,
        defaultSub = function()
            if G_reader_settings then
                local sub = G_reader_settings:readSetting("dualwiki_bwiki_sub")
                if sub and sub ~= "" then
                    sub = tostring(sub):lower():gsub("[^%a%d%-]", "")
                    if sub ~= "" then return sub end
                end
            end
            return "ys"
        end,
    },
    -- v1.3.0: Wiktionary for foreign-language reading (word definitions,
    -- etymology, pronunciation). MediaWiki-native; no TextExtracts either.
    wiktionary = {
        api = function(lang)
            return string.format("https://%s.wiktionary.org/w/api.php", lang or "en")
        end,
        label = function(lang)
            local l = lang or "en"
            if l == "ja" then return _("Wiktionary (JA)") end
            return _("Wiktionary (EN)")
        end,
        needsConverttitles = function() return false end,
        particleLang = function(lang) return "en" end,
        switchTarget = function() return "wikipedia" end,
        fullTextViaParse = true,
    },
}

-- Helper to make fast HTTP GET request. v1.2.1 (M1-A1): dispatch by URL
-- scheme — socket.http silently mangles https URLs on KOReader builds whose
-- luasocket lacks the https table shim; ssl.https is what KOReader core uses.
-- Returns ok, content_or_error_kind, detail. Error kinds let callers render a
-- differentiated message (M1-A4) instead of a generic "network error":
--   "http_429"  rate limited (respect Retry-After)
--   "http_4xx"/"http_5xx"  other HTTP statuses
--   "timeout"   socket timeout
--   "error"     transport failure (DNS / refused / TLS)
local HTTP_RETRY_BACKOFF_S = 2
local HTTP_RETRY_CAP_S = 5
local HTTP_RETRIES = 1

-- v1.3.1: automatic bounded retry for transient server-side conditions.
-- Empirically (emu integration suite): the Wikimedia rate limiter counts
-- per-IP across ALL wikis, so rapid successive lookups can legitimately
-- hit 429. Retry once with a short backoff (honor Retry-After up to 5 s,
-- else 2 s). Unreachable hosts / TLS / timeouts still fail fast — the
-- moegirl degradation ladder depends on it, and error/timeout kinds are
-- not retried.
local function httpGetOnce(url, timeout)
    local transport = socket_url.parse(url).scheme == "https" and https or http
    socketutil:set_timeout(timeout or 6, 12)
    -- v1.2.2 fix: size-capped sink. ltn12.sink.table buffered the ENTIRE
    -- body (potentially multi-MB on Fandom parse) and only rejected it
    -- afterwards, so the "2 MB cap" never actually protected low-RAM
    -- devices. This sink aborts the transfer the moment the cap is crossed.
    local sink = {}
    local received, overflow = 0, false
    local capped_sink = function(chunk)
        if chunk then
            received = received + #chunk
            if received > MAX_RESPONSE_BYTES then
                overflow = true
                return nil, "response exceeds 2 MB cap"
            end
            table.insert(sink, chunk)
        end
        return true
    end
    local code, headers, status
    local req_ok, req_err = pcall(function()
        -- socket.skip(1, ...) drops the leading "1" that luasocket's
        -- generic request form prepends, yielding (code, headers, status).
        -- NOTE: the middle value is the headers table — it MUST be bound to
        -- a dedicated variable, never to the module-level `_` (gettext);
        -- a previous version assigned it to `_`, silently corrupting the
        -- translation function after the very first HTTP request.
        code, headers, status = socket.skip(1, transport.request({
            url = url,
            method = "GET",
            headers = {
                ["User-Agent"] = USER_AGENT,
                ["Accept"] = "application/json",
            },
            sink = capped_sink,
        }))
    end)
    socketutil:reset_timeout()
    if overflow then
        logger.warn("dual_wiki: 2 MB cap exceeded, aborted transfer:", url)
        return false, "too_large", "Response exceeds the 2 MB cap"
    end
    if not req_ok then
        local msg = tostring(req_err or ""):lower()
        logger.warn("dual_wiki: transport raised for", url, "->", tostring(req_err))
        if msg:find("timeout") then
            return false, "timeout", req_err
        end
        return false, "error", req_err
    end
    local content = table.concat(sink)
    if type(code) == "number" and code >= 200 and code < 300 then
        if #content == 0 then
            -- v1.2.2 fix: a 200 with an empty body is a transport-level
            -- truncation, not an HTTP status error.
            logger.warn("dual_wiki: HTTP 200 with empty body:", url)
            return false, "error", "Empty response body"
        end
        logger.dbg("dual_wiki: GET", url, "->", code, "bytes:", #content)
        return true, content
    end
    if code == 429 then
        logger.warn("dual_wiki: HTTP 429 rate limited:", url)
        return false, "http_429", status, headers
    elseif type(code) == "number" then
        logger.dbg("dual_wiki: HTTP", code, "for", url)
        return false, code >= 500 and "http_5xx" or "http_4xx", status or code
    end
    local msg = tostring(status or code or ""):lower()
    if msg:find("timeout") then
        return false, "timeout", status or code
    end
    logger.warn("dual_wiki: request failed for", url, "->", tostring(status or code))
    return false, "error", status or code or "Network error"
end

-- Retry wrapper: only http_429 / http_5xx earn an automatic retry.
local function httpGet(url, timeout, retries)
    local ok, content_or_kind, detail, headers = httpGetOnce(url, timeout)
    if ok then return true, content_or_kind end
    retries = retries or HTTP_RETRIES
    if retries < 1 or (content_or_kind ~= "http_429" and content_or_kind ~= "http_5xx") then
        return false, content_or_kind, detail
    end
    local delay = HTTP_RETRY_BACKOFF_S
    if content_or_kind == "http_429" and type(headers) == "table" then
        local retry_after = tonumber(headers["retry-after"])
        if retry_after and retry_after >= 0 and retry_after <= HTTP_RETRY_CAP_S then
            delay = retry_after
        end
    end
    logger.warn("dual_wiki: retrying after", delay, "s (", content_or_kind, "):", url)
    socket.sleep(delay)
    return httpGetOnce(url, timeout)
end

-- Clean and format extract text for E-ink display (uncovers heimu & formats headings)
local function cleanWikiExtract(text)
    if not text then return "" end
    -- Format sub-sections as ▸ sub-heading, and main sections as 【main heading】
    text = text:gsub("===+ *(.-) *===+", LF .. LF .. "▸ %1" .. LF)
    text = text:gsub("== *(.-) *==", LF .. LF .. "【%1】" .. LF)
    -- Strip any residual HTML tags if any leaked through (Fandom action=parse)
    text = text:gsub("<[^>]+>", "")
    -- Normalize multiple newlines
    text = text:gsub(LF .. LF .. LF .. "+", LF .. LF)
    -- Trim leading and trailing whitespace
    text = text:match("^%s*(.-)%s*$") or text
    return text
end

-- Unified MediaWiki API URL builder (both engines are MediaWiki-native)
local function buildApiURL(engine, lang, params)
    local cfg = ENGINES[engine]
    if not cfg then return nil end
    return cfg.api(lang) .. "?action=query" .. params
end

-- 强制语言锁定：优先 per-book 锁定（doc_settings，v1.3.0），其次全局锁，
-- 最后回落书籍元数据探测（上下文感知调度的用户 override 链）。
function DualWiki:_bookLang()
    local locked
    local doc_settings = self.ui and self.ui.doc_settings
    if doc_settings and doc_settings.readSetting then
        locked = doc_settings:readSetting("dualwiki_lang_lock")
        if locked and LANG_MAP[locked] then
            return locked
        end
    end
    locked = G_reader_settings and G_reader_settings:readSetting("dualwiki_lang")
    if locked and LANG_MAP[locked] then
        return locked
    end
    local doc = self.ui and self.ui.document
    if doc and doc.getProps then
        local ok, props = pcall(doc.getProps, doc)
        if ok and props and props.language then
            return normalizeLang(props.language)
        end
    end
    return "zh"
end

-- v1.2.1 (M1): raw (un-normalized) doc language string, e.g. "zh-Hant" /
-- "zh_CN" — needed to pick the zh body-text variant. Empty when unknown.
function DualWiki:_rawBookLanguage()
    local doc = self.ui and self.ui.document
    if doc and doc.getProps then
        local ok, props = pcall(doc.getProps, doc)
        if ok and props and type(props.language) == "string" then
            return props.language
        end
    end
    return ""
end

function DualWiki:_defaultFandomSub()
    if G_reader_settings then
        local sub = G_reader_settings:readSetting("dualwiki_fandom_community")
        if sub and sub ~= "" then
            -- v1.2.2: defensive normalization — fandom subdomains are
            -- lowercase alphanumeric + hyphen; strip anything else so a
            -- stray setting value can't produce a malformed URL.
            sub = tostring(sub):lower():gsub("[^%a%d%-]", "")
            if sub ~= "" then return sub end
        end
    end
    return "starwars"
end

-- v1.3.0: resolve the engine lookup subdomain (Fandom community / BWiki game)
-- from the lang parameter slot, which carries the subdomain for those engines.
function DualWiki:_engineSub(engine, lang)
    if engine == "fandom" then
        return (lang and lang ~= "") and lang or self:_defaultFandomSub()
    elseif engine == "bwiki" then
        return (lang and lang ~= "") and lang or ENGINES.bwiki.defaultSub()
    end
    return lang
end

-- v1.3.0 (Phase 2.2): book-language → highlight-button plan. Two dynamic
-- slots replace the five hard-coded buttons; each slot's factory re-reads
-- the book language on every highlight-menu invocation, so buttons follow
-- the book (and the language lock) without re-registration.
--   zh book: [Moegirlpedia] [Wikipedia (ZH)]
--   en book: [Wikipedia (EN)] [Fandom]
--   ja book: [Wikipedia (JA)] [Moegirlpedia]
--   de/fr/es/ru book: [Wikipedia (XX)] [Wikipedia (EN)]   (cross-language assist)
local BOOK_BUTTON_PLANS = {
    zh = { { engine = "moegirl", lang = "zh" }, { engine = "wikipedia", lang = "zh" } },
    en = { { engine = "wikipedia", lang = "en" }, { engine = "fandom", lang = "fandom-sub" } },
    ja = { { engine = "wikipedia", lang = "ja" }, { engine = "moegirl", lang = "ja" } },
    de = { { engine = "wikipedia", lang = "de" }, { engine = "wikipedia", lang = "en" } },
    fr = { { engine = "wikipedia", lang = "fr" }, { engine = "wikipedia", lang = "en" } },
    es = { { engine = "wikipedia", lang = "es" }, { engine = "wikipedia", lang = "en" } },
    ru = { { engine = "wikipedia", lang = "ru" }, { engine = "wikipedia", lang = "en" } },
}

-- Button labels: the three core languages keep their translated msgids;
-- Phase 2.2 languages use the "Wikipedia (%s)" format msgid (proper names
-- are conventionally not translated further).
local function buttonLabel(entry)
    if entry.engine == "wikipedia" then
        local l = entry.lang or "zh"
        if l == "zh" then return _("Wikipedia (ZH)") end
        if l == "en" then return _("Wikipedia (EN)") end
        if l == "ja" then return _("Wikipedia (JA)") end
        return string.format(_("Wikipedia (%s)"), l:upper())
    elseif entry.engine == "moegirl" then
        return _("Moegirlpedia")
    elseif entry.engine == "fandom" then
        return _("Fandom")
    elseif entry.engine == "bwiki" then
        return _("Bilibili Game Wiki")
    elseif entry.engine == "wiktionary" then
        return _("Wiktionary")
    end
    return nil
end

function DualWiki:init()
    self:_loadPluginLocale()
    if self.ui and self.ui.highlight then
        self:_registerHighlightButtons()
    end
    if self.ui and self.ui.menu then
        self.ui.menu:registerToMainMenu(self)
    end
end

-- v1.3.0: clear the per-session lookup cache when the document closes
-- (ReaderUI teardown also drops the whole plugin instance, so the cache is
-- freed with it; this explicit hook covers re-opening the same book without
-- a ReaderUI rebuild).
function DualWiki:onCloseDocument()
    self._lookup_cache = nil
end

-- Load this plugin's .mo for the active KOReader UI language (gettext merge).
-- Normalizes common KOReader codes (zh_CN / zh-Hant / ja / ja_JP…) to the
-- bundled locale directory names.
function DualWiki:_loadPluginLocale()
    if not G_reader_settings then return end
    local lang = G_reader_settings:readSetting("language")
    if not lang or lang == "" then return end
    if lang:match("^en") or lang:match("^C") then return end
    lang = lang:gsub("%.utf8$", ""):gsub("%.UTF%-8$", "")
    local base, script = lang:match("^([a-zA-Z]+)[_%-]([a-zA-Z]+)$")
    local dir
    if base then
        base = base:lower()
        if base == "zh" then
            local s = script:lower()
            dir = (s == "tw" or s == "hant" or s == "hk") and "zh_TW" or "zh_CN"
        else
            dir = base
        end
    elseif lang:lower() == "zh" then
        dir = "zh_CN"
    else
        dir = lang:lower()
    end
    local mo = PLUGIN_DIR .. "locale/" .. dir .. "/LC_MESSAGES/dual_wiki.mo"
    local f = io.open(mo, "r")
    if f then
        f:close()
        GetText:loadMO(mo)
    end
end

function DualWiki:_registerHighlightButtons()
    local highlight = self.ui and self.ui.highlight
    if not highlight or self._registered_highlight == highlight then return end
    self._registered_highlight = highlight

    -- Dynamically detach legacy slow Wikipedia button cleanly at runtime (preserves core pristine state)
    if highlight.removeFromHighlightDialog then
        self._orig_wikipedia_button = highlight:removeFromHighlightDialog("05_wikipedia")
    elseif highlight._highlight_buttons then
        highlight._highlight_buttons["05_wikipedia"] = nil
    end

    -- v1.3.0: two DYNAMIC button slots (replacing the five hard-coded ones).
    -- The factory re-runs on every highlight-menu invocation, reading the
    -- book language (with per-book / global lock applied) at that moment —
    -- button text, visibility and target engine all resolve live, so buttons
    -- always match the current book and any later lock changes.
    -- Slot A: book's own language engine.
    highlight:addToHighlightDialog("05_a_dualwiki_primary", function(hl)
        local entry = self:_primaryButton()
        return {
            text = (entry and buttonLabel(entry)) or "",
            show_in_highlight_dialog_func = function()
                return hl.selected_text ~= nil and self:_primaryButton() ~= nil
            end,
            callback = function()
                local e = self:_primaryButton()
                if not e or not hl.selected_text then return end
                local word = util.cleanupSelectedText(hl.selected_text.text)
                if not word or word == "" then return end
                local word_boxes = hl:getHighlightVisibleBoxes() or (hl.selected_text.sboxes or hl.selected_text.pboxes)
                UIManager:scheduleIn(0.1, function()
                    self:lookup(word, e.engine, word_boxes, e.lang)
                end)
            end,
        }
    end)
    -- Slot B: secondary engine (cross-language assist / pop-culture).
    highlight:addToHighlightDialog("05_b_dualwiki_secondary", function(hl)
        local entry = self:_secondaryButton()
        return {
            text = (entry and buttonLabel(entry)) or "",
            show_in_highlight_dialog_func = function()
                return hl.selected_text ~= nil and self:_secondaryButton() ~= nil
            end,
            callback = function()
                local e = self:_secondaryButton()
                if not e or not hl.selected_text then return end
                local word = util.cleanupSelectedText(hl.selected_text.text)
                if not word or word == "" then return end
                local word_boxes = hl:getHighlightVisibleBoxes() or (hl.selected_text.sboxes or hl.selected_text.pboxes)
                UIManager:scheduleIn(0.1, function()
                    self:lookup(word, e.engine, word_boxes, e.lang)
                end)
            end,
        }
    end)
end

-- v1.3.0: resolve the current book's button plan. lang == "fandom-sub" means
-- the lang slot carries the Fandom community subdomain (resolved at lookup
-- time so a settings change applies immediately).
function DualWiki:_planButtons()
    local lang = self:_bookLang()
    local plan = BOOK_BUTTON_PLANS[lang] or BOOK_BUTTON_PLANS.zh
    local buttons = {}
    for _, entry in ipairs(plan) do
        local e = {
            engine = entry.engine,
            lang = entry.lang == "fandom-sub" and self:_defaultFandomSub() or entry.lang,
        }
        buttons[#buttons + 1] = e
    end
    return buttons
end

function DualWiki:_primaryButton()
    return self:_planButtons()[1]
end

function DualWiki:_secondaryButton()
    return self:_planButtons()[2]
end

-- v1.3.0: language-lock picker rows shared by the global and per-book menus.
-- value nil means "auto" (context-aware detection).
local LANG_LOCK_CHOICES = { "auto", "zh", "en", "ja", "de", "fr", "es", "ru" }
local function langLockText(code)
    if code == "auto" then return _("Auto (detect from book)") end
    local names = {
        zh = _("Chinese (ZH)"), en = _("English (EN)"), ja = _("Japanese (JA)"),
        de = _("German (DE)"), fr = _("French (FR)"), es = _("Spanish (ES)"),
        ru = _("Russian (RU)"),
    }
    return names[code] or code
end

local function langLockRadioRow(self, code, scope)
    local get, save
    if scope == "book" then
        get = function()
            local ds = self.ui and self.ui.doc_settings
            return ds and ds:readSetting("dualwiki_lang_lock") or "auto"
        end
        save = function(value)
            local ds = self.ui and self.ui.doc_settings
            if not ds then return end
            if value == "auto" then
                ds:delSetting("dualwiki_lang_lock")
            else
                ds:saveSetting("dualwiki_lang_lock", value)
            end
        end
    else
        get = function()
            return G_reader_settings:readSetting("dualwiki_lang") or "auto"
        end
        save = function(value)
            if value == "auto" then
                G_reader_settings:delSetting("dualwiki_lang")
            else
                G_reader_settings:saveSetting("dualwiki_lang", value)
            end
        end
    end
    return {
        text = langLockText(code),
        checked_func = function() return get() == code end,
        radio = true,
        callback = function() save(code) end,
    }
end

function DualWiki:addToMainMenu(menu_items)
    menu_items.dualwiki_moegirl = {
        text = _("Moegirlpedia lookup"),
        sorting_hint = "search",
        callback = function()
            self:showSearchDialog("moegirl", nil, nil, "zh")
        end,
    }
    menu_items.dualwiki_wikipedia_zh = {
        text = _("Wikipedia lookup (Chinese)"),
        sorting_hint = "search",
        callback = function()
            self:showSearchDialog("wikipedia", nil, nil, "zh")
        end,
    }
    menu_items.dualwiki_wikipedia_en = {
        text = _("Wikipedia lookup (English)"),
        sorting_hint = "search",
        callback = function()
            self:showSearchDialog("wikipedia", nil, nil, "en")
        end,
    }
    menu_items.dualwiki_wikipedia_ja = {
        text = _("Wikipedia lookup (Japanese)"),
        sorting_hint = "search",
        callback = function()
            self:showSearchDialog("wikipedia", nil, nil, "ja")
        end,
    }
    menu_items.dualwiki_wiktionary = {
        text = _("Wiktionary lookup"),
        sorting_hint = "search",
        callback = function()
            self:showSearchDialog("wiktionary", nil, nil, "en")
        end,
    }
    menu_items.dualwiki_fandom = {
        text = _("Fandom lookup"),
        sorting_hint = "search",
        callback = function()
            self:showSearchDialog("fandom", nil, nil, self:_defaultFandomSub())
        end,
    }
    menu_items.dualwiki_bwiki = {
        text = _("Bilibili Game Wiki lookup"),
        sorting_hint = "search",
        callback = function()
            self:showSearchDialog("bwiki", nil, nil, ENGINES.bwiki.defaultSub())
        end,
    }

    -- v1.3.0: settings hub (兑现第五节第 3 条的语种锁定 UI).
    local settings_sub = {
        {
            text = _("Language lock (this book)"),
            sub_item_table = (function()
                local rows = {}
                for _, code in ipairs(LANG_LOCK_CHOICES) do
                    rows[#rows + 1] = langLockRadioRow(self, code, "book")
                end
                return rows
            end)(),
        },
        {
            text = _("Language lock (global default)"),
            sub_item_table = (function()
                local rows = {}
                for _, code in ipairs(LANG_LOCK_CHOICES) do
                    rows[#rows + 1] = langLockRadioRow(self, code, "global")
                end
                return rows
            end)(),
        },
        {
            text_func = function()
                return T(_("Fandom community: %1"), self:_defaultFandomSub())
            end,
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                self:_promptForSubdomain("dualwiki_fandom_community", "starwars", touchmenu_instance)
            end,
        },
        {
            text_func = function()
                local sub = ENGINES.bwiki.defaultSub()
                return T(_("Bilibili game wiki: %1"), sub)
            end,
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                self:_promptForSubdomain("dualwiki_bwiki_sub", "ys", touchmenu_instance)
            end,
        },
        {
            text = _("Clear session lookup cache"),
            keep_menu_open = true,
            callback = function()
                self._lookup_cache = nil
                UIManager:show(InfoMessage:new{
                    text = _("Session lookup cache cleared."),
                    timeout = 2,
                })
            end,
        },
    }
    menu_items.dualwiki_settings = {
        text = _("Dual Wiki settings"),
        sorting_hint = "search",
        sub_item_table = settings_sub,
    }
end

-- v1.3.0: subdomain prompt shared by Fandom community / BWiki game settings.
function DualWiki:_promptForSubdomain(setting_key, default_value, touchmenu_instance)
    local dialog
    dialog = InputDialog:new{
        title = _("Enter wiki subdomain"),
        description = T(_("e.g. %1"), default_value),
        input = G_reader_settings:readSetting(setting_key) or default_value,
        input_type = "text",
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function()
                        UIManager:close(dialog)
                    end,
                },
                {
                    text = _("Save"),
                    is_enter_default = true,
                    callback = function()
                        local value = tostring(dialog:getInputText() or ""):lower():gsub("[^%a%d%-]", "")
                        if value == "" then value = default_value end
                        G_reader_settings:saveSetting(setting_key, value)
                        -- v1.3.2: the lookup cache key is engine|lang|word — it
                        -- does NOT include the subdomain. Without this clear, a
                        -- subdomain switch keeps serving the previous
                        -- community's cached results for identical words.
                        self._lookup_cache = nil
                        UIManager:close(dialog)
                        if touchmenu_instance then touchmenu_instance:updateItems() end
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function DualWiki:showSearchDialog(engine, initial_query, word_boxes, lang)
    local cfg = ENGINES[engine]
    if not cfg then return end
    local title = _("Article lookup") .. " · " .. cfg.label(lang)
    local input_dialog
    input_dialog = InputDialog:new{
        title = title,
        input = initial_query or "",
        input_type = "text",
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function()
                        UIManager:close(input_dialog)
                    end,
                },
                {
                    text = _("Search"),
                    is_enter_default = true,
                    callback = function()
                        local query = input_dialog:getInputText()
                        if query and query ~= "" then
                            UIManager:close(input_dialog)
                            -- Confirming a currently listed candidate upgrades it
                            -- to the full article; a modified word re-runs the
                            -- fuzzy pipeline instead.
                            local trimmed = strTrim(query)
                            local want_full = trimmed ~= ""
                                and self._last_candidate_titles ~= nil
                                and self._last_candidate_titles[trimmed] ~= nil
                                and not self._last_was_full
                            self:lookup(query, engine, word_boxes, lang, want_full)
                        end
                    end,
                },
            },
        },
    }
    UIManager:show(input_dialog)
    input_dialog:onShowKeyboard()
end

-- Merged probe request: one HTTP round-trip returns up to MAX_CANDIDATES
-- ranked candidates, each with a readable intro summary (exintro mode keeps
-- exlimit unclamped; full-text mode is server-clamped to 1 page).
-- Fandom lacks TextExtracts, so candidates there are title-only.
-- mode: "prefix" (generator=prefixsearch) or "search" (generator=search).
function DualWiki:fetchCandidates(q, engine, lang, mode)
    local esc_q = socket_url.escape(q)
    local params
    if mode == "search" then
        params = string.format("&generator=search&gsrsearch=%s&gsrlimit=%d", esc_q, MAX_CANDIDATES)
    else
        params = string.format("&generator=prefixsearch&gpssearch=%s&gpslimit=%d", esc_q, MAX_CANDIDATES)
    end
    if ENGINES[engine] and ENGINES[engine].fullTextViaParse then
        -- v1.3.0: parse engines (Fandom / BWiki / Wiktionary) ship no
        -- TextExtracts — request title-only candidates, skip the extracts
        -- block entirely (avoids per-wiki "Unrecognized parameter" noise).
        params = params .. "&redirects=1&format=json&formatversion=2"
    else
        params = params
            .. "&prop=extracts&explaintext=1&exintro=1&exlimit=" .. MAX_CANDIDATES
            .. "&redirects=1&format=json&formatversion=2"
    end
    if ENGINES[engine] and ENGINES[engine].needsConverttitles(lang) then
        params = params .. "&converttitles=1&variant=" .. zhVariantOf(self:_rawBookLanguage())
    end

    local url = buildApiURL(engine, lang, params)
    local ok, body = httpGet(url, (engine == "moegirl") and MOEGIRL_TIMEOUT or PROBE_TIMEOUT)
    if not ok or not body then
        self._last_error_kind = type(body) == "string" and body or "error"
        return nil
    end
    local ok_json, data = pcall(JSON.decode, body)
    if not ok_json or type(data) ~= "table" or not data.query or type(data.query.pages) ~= "table" then
        return nil
    end
    return parseCandidatePages(data, q)
end

-- Direct single-page full-article fetch (used by same-word pencil confirm).
-- formatversion=2 returns pages as an array; redirects are server-expanded.
function DualWiki:fetchDirect(word, engine, lang)
    local q = sanitizeQuery(word)
    if q == "" then q = word end
    local params = "&prop=extracts&explaintext=1&redirects=1&titles="
        .. socket_url.escape(q) .. "&format=json&formatversion=2"
    if ENGINES[engine] and ENGINES[engine].needsConverttitles(lang) then
        params = params .. "&converttitles=1&variant=" .. zhVariantOf(self:_rawBookLanguage())
    end

    local url = buildApiURL(engine, lang, params)
    local ok, body = httpGet(url, DIRECT_TIMEOUT)
    if not ok or not body then
        self._last_error_kind = type(body) == "string" and body or "error"
        return nil
    end
    local ok_json, data = pcall(JSON.decode, body)
    if not ok_json or type(data) ~= "table" or not data.query or type(data.query.pages) ~= "table" then
        return nil
    end
    for _, page in ipairs(data.query.pages) do
        if type(page) == "table" and page.title and not page.missing
            and page.extract and #page.extract > 0 then
            return { { title = page.title, extract = page.extract, index = 1 } }
        end
    end
    return nil
end

-- v1.3.0: generalized action=parse adapter for engines without TextExtracts
-- (Fandom, BWiki, Wiktionary). Two-phase to protect low-RAM devices: fetch
-- the intro first (section=0, tens of KB); auto-upgrade to the full page only
-- when the intro is too thin to be useful. Previously the Fandom full-page
-- parse shipped up to 1.5 MB of JSON through JSON.decode on every request.
function DualWiki:fetchParseArticle(word, engine, sub)
    local q = sanitizeQuery(word)
    if q == "" then q = word end
    local cfg = ENGINES[engine]
    if not cfg then return nil end
    local base = cfg.api(sub)
        .. "?action=parse&page=" .. socket_url.escape(q)
        .. "&prop=text&disablepp=1&format=json&formatversion=2"

    local function fetchSection(section_suffix, timeout)
        local url = base .. section_suffix
        local ok, body = httpGet(url, timeout)
        if not ok or not body then
            self._last_error_kind = type(body) == "string" and body or "error"
            return nil, true -- transport-level failure
        end
        local ok_json, data = pcall(JSON.decode, body)
        if not ok_json or type(data) ~= "table" or not data.parse or type(data.parse.text) ~= "string" then
            return nil, false -- structural: treat as empty, allow phase 2
        end
        local text = data.parse.text
        if type(text) ~= "string" or #text == 0 then return nil, false end
        return text, false
    end

    -- Phase 1: intro only. A transport failure short-circuits (no point
    -- re-hitting a dead host with the full-page request).
    local text, transport_failed = fetchSection("&section=0", MOEGIRL_TIMEOUT + 2)
    if transport_failed then return nil end
    if not text or #text < 300 then
        -- Phase 2: intro missing or too thin (sections live in the body) —
        -- pull the full page under the standard cap.
        local full = fetchSection("", DIRECT_TIMEOUT)
        if full then text = full end
    end
    if not text then return nil end
    return { { title = q, extract = text, index = 1 } }
end

-- v1.2.1 (M1-A4): human-readable hint per transport error kind, so users can
-- self-diagnose (rate limited vs offline vs slow site) instead of seeing a
-- generic "network error".
local ERROR_HINTS = {
    http_429    = _("Rate limited by the wiki server. Wait a minute and retry."),
    http_4xx    = _("The wiki server rejected the request."),
    http_5xx    = _("The wiki server is having trouble. Retry later."),
    timeout     = _("The request timed out."),
    error       = _("The site may be unreachable or blocked on this network."),
    too_large   = _("The article is too large to display on this device."),
}

-- Degradation ladder (each step is a single merged request):
--   1. prefixsearch(sanitized query)
--   2. prefixsearch(query minus ONE trailing particle, language-aware)
--   3. en.wikipedia retry for pure-Latin queries on zh
--   4. top candidate carries real content (server-side redirect targets)
--   5. generator=search full-text fallback
--   6. surface whatever prefix noise we had
function DualWiki:queryPipeline(word, engine, lang)
    local q0 = sanitizeQuery(word)
    if q0 == "" then q0 = word end
    local plang = ENGINES[engine] and ENGINES[engine].particleLang(lang) or "zh"
    local q2 = stripTrailingParticle(q0, plang)

    -- Stage 1: merged prefixsearch probe (up to 4 ranked candidates).
    -- v1.2.1 (M1-A5): moegirl fast-fails at MOEGIRL_TIMEOUT; a transport-level
    -- failure (timeout/error, NOT a mere zero-hit) skips the remaining moegirl
    -- stages and hands straight to the cross-engine fallback ladder.
    local r1 = self:fetchCandidates(q0, engine, lang, "prefix")
    if r1 == nil and engine == "moegirl"
        and (self._last_error_kind == "timeout" or self._last_error_kind == "error") then
        self._moegirl_unreachable = true
    else
        self._moegirl_unreachable = false
    end
    if hasGoodHit(r1, q0, plang) then
        return r1, false
    end

    -- Stage 2: trailing-particle drop retry (量子力学的 → 量子力学,
    -- シャナの → シャナ, Oppenheimer's → Oppenheimer).
    -- Skipped when moegirl itself is unreachable (no point re-hitting it).
    local r2 = nil
    if q2 ~= q0 and utf8Len(q2) >= 2 and not self._moegirl_unreachable then
        r2 = self:fetchCandidates(q2, engine, lang, "prefix")
        if hasGoodHit(r2, q2, plang) then
            return r2, false
        end
    end

    -- Stage 2b (v1.3.2): leading elision strip for fr/it/pt (l'amour →
    -- amour, l'équation → équation). Own fallback tier: a Stage-1 exact
    -- hit on article-titled works (Les Misérables) is never disturbed.
    local q3 = stripLeadingElision(q0, plang)
    if q3 ~= q0 and q3 ~= q2 and not self._moegirl_unreachable then
        local r3 = self:fetchCandidates(q3, engine, lang, "prefix")
        if hasGoodHit(r3, q3, plang) then
            return r3, false
        end
    end

    -- Stage 3: English fallback for pure-Latin queries on zh.
    if engine == "wikipedia" and lang == "zh" and q0:match("^[%a%s%-%d%p]+$") then
        return self:queryPipeline(word, engine, "en")
    end

    -- Stage 4: the top candidate carries real content AND relates to the
    -- query (server-side redirect targets: 拿破仑·波拿巴 → 拿破仑一世,
    -- 涼宮ハルヒの憂鬱 → 涼宮ハルヒの憂鬱 (アニメ)). The prefix-relation
    -- guard rejects moegirl's kana quirk (シャナの → Shanna).
    if r1 and r1[1] and #(r1[1].extract or "") >= 60
        and sharesPrefix(r1[1].title, q0, plang) then
        return r1, false
    end

    -- Stage 5: full-text search fallback (catches dab-page tops like
    -- 三体 → 三體 with no content, where search resolves 三体 (小说)).
    -- Also skipped on an unreachable moegirl.
    local s = nil
    if not self._moegirl_unreachable then
        s = self:fetchCandidates(q0, engine, lang, "search")
    end
    if s and #s > 0 and sharesPrefixAny(s, q2 ~= q0 and q2 or q0, plang) then
        return s, false
    end

    -- Stage 6 (cross-engine synergy): moegirl zero-hits or transport failures
    -- degrade to wikipedia — ja-book kana queries resolve on ja.wikipedia
    -- (灼眼のシャナ), zh-book queries on zh.wikipedia. This is the v1.2.1
    -- moegirl-reachability escape hatch for DNS-poisoned regions.
    if engine == "moegirl" then
        local fallback_lang = (lang == "ja") and "ja" or "zh"
        if lang == "ja" or self._moegirl_unreachable then
            local fallback = self:queryPipeline(word, "wikipedia", fallback_lang)
            if fallback and #fallback > 0 then
                return fallback, false
            end
        end
    end

    -- Stage 7: surface whatever prefix noise we had (better than nothing).
    if r1 and #r1 > 0 then
        return r1, false
    end
    if r2 and #r2 > 0 then
        return r2, false
    end

    return nil, false
end

function DualWiki:lookup(word, engine, word_boxes, lang, want_full)
    if not word or word == "" then return end
    local cfg = ENGINES[engine]
    if not cfg then return end

    if NetworkMgr:willRerunWhenOnline(function()
        self:lookup(word, engine, word_boxes, lang, want_full)
    end) then
        return
    end

    -- v1.2.2 fix: clear the previous round's transport error kind here (not
    -- only on display), otherwise a stale "timeout" hint from an earlier
    -- failed query would be attached to a later zero-hit "not found" dialog.
    self._last_error_kind = nil

    -- v1.3.0: session lookup cache — repeat lookups of the same word/engine/
    -- lang in this ReaderUI session skip the network entirely. Capped, and
    -- cleared on document close.
    local cache_key = table.concat({ engine, lang or "", word }, "|")
    local cached = self._lookup_cache and self._lookup_cache[cache_key]
    if cached then
        self:showResult(word, cached.cands, engine, word_boxes, lang, cached.is_full)
        return
    end

    local prompt_title = string.format("%s · %s", _("Querying"), cfg.label(lang))
        .. LF .. word

    local progress_info = InfoMessage:new{
        text = prompt_title,
        timeout = 15,
    }
    UIManager:show(progress_info)

    UIManager:scheduleIn(0.05, function()
        -- Guard: the ReaderUI / FileManager may have been torn down (book
        -- switched / closed) while the request was pending; bail out instead
        -- of showing result windows on a dead UI instance.
        if not self.ui or not self.ui.dialog then
            return
        end
        local ok, cands, is_full = pcall(function()
            if want_full then
                if ENGINES[engine] and ENGINES[engine].fullTextViaParse then
                    return self:fetchParseArticle(word, engine, self:_engineSub(engine, lang)), true
                end
                return self:fetchDirect(word, engine, lang), true
            end
            local result, full_flag = self:queryPipeline(word, engine, lang)
            return result, full_flag
        end)

        UIManager:close(progress_info)

        if ok and type(cands) == "table" and #cands > 0 then
            -- v1.3.0: store in the session cache (capped at 32 entries,
            -- oldest-evicted; showResult only reads the stored table).
            if not self._lookup_cache then self._lookup_cache = {} end
            local n = 0
            for _ in pairs(self._lookup_cache) do n = n + 1 end
            if n >= 32 then
                local oldest_key
                local oldest_time = math.huge
                for k, v in pairs(self._lookup_cache) do
                    if v.at < oldest_time then
                        oldest_time = v.at
                        oldest_key = k
                    end
                end
                if oldest_key then self._lookup_cache[oldest_key] = nil end
            end
            self._lookup_cache[cache_key] = { cands = cands, is_full = want_full or is_full, at = os.time() }
            self:showResult(word, cands, engine, word_boxes, lang, want_full or is_full)
        else
            self:showRetryDialog(word, engine, word_boxes, lang)
        end
    end)
end

function DualWiki:showResult(word, cands, engine, word_boxes, lang, is_full)
    local self_ref = self
    local cfg = ENGINES[engine]
    if not cfg then return end
    local dict_name = cfg.label(lang)
    -- DictQuickLookup consumes `lang` per result for font shaping; Fandom's
    -- community subdomain is not a language code, so map it to en.
    local result_lang = (engine == "fandom") and "en" or (lang or "zh")

    self._last_candidate_titles = {}
    self._last_was_full = is_full and true or false

    local results = {}
    for i, cand in ipairs(cands) do
        self._last_candidate_titles[cand.title] = true
        local definition
        if cand.extract and #cand.extract > 0 then
            definition = cleanWikiExtract(cand.extract)
        else
            definition = _("Candidate match: press and hold the pencil icon to load the full article.")
        end
        results[i] = {
            word = cand.title,
            definition = definition,
            -- v1.3.2 crash fix: DictQuickLookup:changeDictionary() reads
            -- results[index].dict (NOT .dictionary) for the window title;
            -- a nil here made scrolling past the last result (auto
            -- next-result) die on TitleBar:setText(nil). Field must match
            -- the core dictionary result contract.
            dict = dict_name,
            dictionary = dict_name,
            lang = result_lang,
            rtl_lang = false,
        }
    end

    local window
    window = DictQuickLookup:new{
        ui = self.ui,
        highlight = self.ui.highlight,
        dialog = self.dialog,
        word = word,
        word_boxes = word_boxes,
        results = results,
        -- Verified by Codex: is_wiki=false decouples from core ReaderWikipedia private methods
        is_wiki = false,
        -- Pencil icon routes through the native DictQuickLookup:onLookupInputWord()
        -- method, so overriding it via constructor field must keep the
        -- (window, hint, ev) shape. On keyboard-enabled devices the same name
        -- can be dispatched as an event handler where `hint` is the key event
        -- table, so only forward real strings.
        -- Single tap prefills the original selection; long-press prefills the
        -- currently viewed candidate (self.lookupword updates on switch).
        onLookupInputWord = function(dlg, hint, ev)
            if type(hint) ~= "string" then
                hint = nil
            end
            self_ref:showSearchDialog(engine, hint or word, word_boxes, lang)
        end,
    }
    UIManager:show(window)
end

function DualWiki:showRetryDialog(failed_word, engine, word_boxes, lang)
    local cfg = ENGINES[engine]
    if not cfg then return end
    local target = cfg.switchTarget and cfg.switchTarget()
    local target_cfg = target and ENGINES[target]
    -- v1.2.2 fix: normalize the language for BOTH the switch button label and
    -- the actual re-lookup. Previously the label used a ja/en/zh-normalized
    -- value while the lookup call passed the raw lang through — a Fandom
    -- failure switching to Wikipedia sent "starwars" as a language and
    -- queried the nonexistent starwars.wikipedia.org.
    local switch_lang = (lang == "ja" or lang == "en") and lang or "zh"
    local switch_btn_text = target_cfg and string.format("%s → %s", _("Switch to"), target_cfg.label(
        switch_lang
    )) or _("Retry")

    -- v1.2.2 fix: surface the transport failure kind via the dialog's
    -- description (title-bar info line). The previous immediate InfoMessage
    -- was hidden behind this dialog's fullscreen tap layer, so users never
    -- saw it.
    local kind = self._last_error_kind
    local error_description = kind and ERROR_HINTS[kind] or nil
    self._last_error_kind = nil

    local retry_dialog
    retry_dialog = InputDialog:new{
        title = string.format("%s · %s", cfg.label(lang), _("Not found, modify and retry:")),
        description = error_description,
        input = failed_word,
        input_type = "text",
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function()
                        UIManager:close(retry_dialog)
                    end,
                },
                {
                    text = switch_btn_text,
                    callback = function()
                        local query = retry_dialog:getInputText()
                        UIManager:close(retry_dialog)
                        if query and query ~= "" then
                            self:lookup(query, target or "wikipedia", word_boxes, switch_lang)
                        end
                    end,
                },
                {
                    text = _("Retry"),
                    is_enter_default = true,
                    callback = function()
                        local query = retry_dialog:getInputText()
                        if query and query ~= "" then
                            UIManager:close(retry_dialog)
                            self:lookup(query, engine, word_boxes, lang)
                        end
                    end,
                },
            },
        },
    }
    UIManager:show(retry_dialog)
    retry_dialog:onShowKeyboard()
end

return DualWiki