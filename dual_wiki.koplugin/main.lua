--[[--
Dual-Engine Encyclopedia (Moegirlpedia + Wikipedia) Plugin for KOReader.

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

Slim build (v1.3.5) — user-directed scope reduction:

1. Two engines only: Moegirlpedia + Wikipedia. Fandom / BWiki / Wiktionary
   and the action=parse full-text adapter are removed.
2. de/fr/es/ru are recognized (LANG_MAP) but only surface when the book
   itself is that language — hidden otherwise (button plan, lang lock).
3. Settings hub: language lock per book (doc_settings) and globally,
   prewarm opt-in, cross-language bridge opt-in, session-cache clear.
4. Opt-in features (default OFF): highlight prewarm (dualwiki_prewarm),
   cross-language suggestions (dualwiki_langlink).
5. Session lookup cache: identical word/engine/lang repeats skip the
   network (LRU-capped at 32), cleared on document close or on demand.
6. Wikidata bridge (wbgetentities) and sitelink notability re-rank are
   removed — fewer cross-host round trips.

Inherits from v1.2.x — cross-device hardening (https dispatch, explicit
zh body-text variant, device-agnostic UA, differentiated transport error
hints, moegirl fast-fail), Phase 2.1 globalization (engine registry,
language-aware particles, context-aware detection, gettext i18n).

Enables seamless online search and definition lookup across:
1. ACG / Anime terms from Moegirlpedia (zh.moegirl.org.cn)
2. General knowledge from Wikipedia (zh/ja/en/de/fr/es/ru.wikipedia.org)
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
local PLUGIN_VERSION = "1.3.5"
local USER_AGENT = "dual_wiki.koplugin/" .. PLUGIN_VERSION .. " (KOReader)"

-- Retrieval pipeline tuning
local MAX_CANDIDATES = 4      -- candidates per merged request (server clamps full-text extracts to 1/page, intro mode allows all)
local MAX_SEARCH_CANDIDATES = 8 -- v1.3.3 (E5): full-text search fallback widens to 8 (intro extracts still one request)
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

local function utf8Decode(s, i)
    local b = s:byte(i)
    if not b then return nil, 0 end
    if b < 0x80 then return b, 1 end
    if b < 0xE0 then
        local b2 = s:byte(i + 1)
        if not b2 then return b, 1 end
        return (b - 0xC0) * 64 + (b2 - 0x80), 2
    end
    if b < 0xF0 then
        local b2, b3 = s:byte(i + 1), s:byte(i + 2)
        if not b2 or not b3 then return b, 1 end
        return ((b - 0xE0) * 64 + (b2 - 0x80)) * 64 + (b3 - 0x80), 3
    end
    local b2, b3, b4 = s:byte(i + 1), s:byte(i + 2), s:byte(i + 3)
    if not b2 or not b3 or not b4 then return b, 1 end
    return (((b - 0xF0) * 64 + (b2 - 0x80)) * 64 + (b3 - 0x80)) * 64 + (b4 - 0x80), 4
end

local function utf8Encode(cp)
    if cp < 0x80 then return string.char(cp) end
    if cp < 0x800 then return string.char(0xC0 + math.floor(cp / 64), 0x80 + cp % 64) end
    if cp < 0x10000 then
        return string.char(
            0xE0 + math.floor(cp / 4096),
            0x80 + math.floor(cp / 64) % 64,
            0x80 + cp % 64
        )
    end
    return string.char(
        0xF0 + math.floor(cp / 262144),
        0x80 + math.floor(cp / 4096) % 64,
        0x80 + math.floor(cp / 64) % 64,
        0x80 + cp % 64
    )
end

-- Lua :lower only folds ASCII; French É/È/À etc. and Cyrillic never fold.
-- This folds the ranges that matter for the plugin's Latin/Cyrillic wikis
-- without pulling in an external unicode library.
local function caseFold(s)
    local out = {}
    local i = 1
    while i <= #s do
        local cp, w = utf8Decode(s, i)
        if not cp then break end
        if cp >= 65 and cp <= 90 then
            cp = cp + 32
        elseif cp >= 192 and cp <= 214 then
            cp = cp + 32
        elseif cp >= 216 and cp <= 222 then
            cp = cp + 32
        elseif cp >= 1040 and cp <= 1071 then
            cp = cp + 32
        elseif cp == 1025 then
            cp = 1105
        elseif cp == 1028 then
            cp = 1108
        elseif cp == 1031 then
            cp = 1111
        elseif cp == 338 then
            cp = 339
        end
        out[#out + 1] = utf8Encode(cp)
        i = i + w
    end
    return table.concat(out)
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

-- Word-boundary good-hit rule: en always, de/fr/es/ru only when the
-- book is that language (平时隐藏，命中才生效).
local LATIN_LANGS = { en = true, de = true, fr = true, es = true, ru = true }

-- v1.3.3 (B7): sniff the dominant script of a selection for wikipedia
-- language routing (zh book + foreign-script selection → direct probe).
-- Only three UNAMBIGUOUS cases route: pure-Latin→en, pure-Cyrillic→ru,
-- pure-kana→ja. Anything mixed (灼眼のシャナ = CJK+kana), Greek/Hangul,
-- or digit-only stays put — the pipeline's own Stage 3/6 fallbacks keep
-- handling those. Codepoint walks are byte-safe via utf8Decode; letters
-- only, so digits and punctuation never tip the verdict.
local function routeLangForScript(q)
    if not q or utf8Len(q) < 2 then return nil end
    local latin, cyrillic, kana, other = 0, 0, 0, 0
    local i = 1
    while i <= #q do
        local cp, w = utf8Decode(q, i)
        if not cp then break end
        if (cp >= 0x41 and cp <= 0x5A) or (cp >= 0x61 and cp <= 0x7A)
            or ((cp >= 0xC0 and cp <= 0x24F) and cp ~= 0xD7 and cp ~= 0xF7) then
            latin = latin + 1
        elseif cp >= 0x400 and cp <= 0x4FF then
            cyrillic = cyrillic + 1
        elseif (cp >= 0x3041 and cp <= 0x309F) or (cp >= 0x30A0 and cp <= 0x30FF) then
            kana = kana + 1
        elseif (cp >= 0x3400 and cp <= 0x4DBF) or (cp >= 0x4E00 and cp <= 0x9FFF)
            or (cp >= 0x370 and cp <= 0x3FF) or (cp >= 0xAC00 and cp <= 0xD7AF) then
            other = other + 1
        end
        i = i + w
    end
    if kana > 0 and latin == 0 and cyrillic == 0 and other == 0 then return "ja" end
    if cyrillic > 0 and latin == 0 and kana == 0 and other == 0 then return "ru" end
    if latin > 0 and cyrillic == 0 and kana == 0 and other == 0 then return "en" end
    return nil
end

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
        local ql = caseFold(q)
        for _, c in ipairs(cands) do
            local tl = caseFold(c.title)
            if tl == ql then
                return true
            end
            if tl:sub(1, #ql) == ql then
                local nxt = c.title:sub(#ql + 1, #ql + 1)
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
    -- v1.3.3 (A1): a Disambiguator-flagged exact hit is a good hit — the
    -- pipeline expands it into its item list downstream. Japanese titles
    -- like シャナ are pure dab pages whose "extract" is an index, which the
    -- length/≤2-chars rule above can never bless.
    for _, c in ipairs(cands) do
        if c.dab and c.title == q then
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
        local first_word = caseFold(title):match("^(%S+)")
        if not first_word or #first_word < 3 then return false end
        return caseFold(q):sub(1, #first_word) == first_word
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
            local is_exact = (page.title == query) or (caseFold(page.title) == caseFold(query))
            local pageprops = page.pageprops
            cands[#cands + 1] = {
                title = page.title,
                extract = page.extract or "",
                index = page.index or 999,
                exact = is_exact,
                -- v1.3.3 (A1): Disambiguator flag, delivered via
                -- prop=pageprops&ppprop=disambiguation. Absent (nil) on
                -- non-dab pages and on engines that skip the prop block.
                dab = (type(pageprops) == "table" and pageprops.disambiguation ~= nil) and true or nil,
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

-- Normalize a doc-props language field ("zh-CN", "en_US", "eng", "ja"…)
-- to a plugin language key. de/fr/es/ru are recognized but only surface
-- when the book itself is that language (button plan / lang-lock routing).
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
            return string.format(_("Wikipedia (%s)"), l:upper())
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
        particleLang = function(lang) return lang or "zh" end,
        switchTarget = function() return "wikipedia" end,
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

-- v1.3.3 (E7): TLS keepalive pool (keepalive.lua). Tried FIRST for https
-- URLs; a pooled connection skips the 300-500 ms TCP+TLS handshake that
-- ssl.https.request pays per call. Contract: nil => "not handled" (module
-- unavailable, disabled, non-https, or internal anomaly) => legacy path;
-- true => response; false => DEFINITIVE transport-kind failure, trusted
-- and returned as-is (re-requesting over the legacy path would double-hit
-- 429 rate limits and double latency on dead hosts).
local keepalive = require("keepalive")
keepalive.enabled = os.getenv("DUALWIKI_NO_KEEPALIVE") == nil

-- v1.3.1: automatic bounded retry for transient server-side conditions.
-- Empirically (emu integration suite): the Wikimedia rate limiter counts
-- per-IP across ALL wikis, so rapid successive lookups can legitimately
-- hit 429. Retry once with a short backoff (honor Retry-After up to 5 s,
-- else 2 s). Unreachable hosts / TLS / timeouts still fail fast — the
-- moegirl degradation ladder depends on it, and error/timeout kinds are
-- not retried.
local function httpGetOnce(url, timeout)
    -- v1.3.3 (E7): pooled-TLS fast path. Unit tests set DUALWIKI_NO_KEEPALIVE
    -- (or keepalive.enabled=false) to pin the legacy transport.
    local ka_ok, ka_body, ka_kind, _, ka_headers = keepalive.request(
        url, timeout or 6, MAX_RESPONSE_BYTES, USER_AGENT)
    if ka_ok == true then
        return true, ka_body
    end
    if ka_ok == false then
        -- deterministic verdict from the pooled transport — do not re-hit
        -- the legacy path or we would double-limit transient 429/5xx.
        -- The headers ride along so the Retry-After backoff keeps working.
        return false, ka_kind or "error", nil, ka_headers
    end
    -- ka_ok == nil: not handled or internal anomaly — legacy path.
    local transport = socket_url.parse(url).scheme == "https" and https or http
    socketutil:set_timeout(timeout or 6, 12)
    -- v1.2.2 fix: size-capped sink. ltn12.sink.table buffered the ENTIRE
    -- body and only rejected it afterwards, so the "2 MB cap" never
    -- actually protected low-RAM devices. This sink aborts the transfer
    -- the moment the cap is crossed.
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
    -- Strip any residual HTML tags if any leaked through
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

-- v1.3.3 (B7): whether the user explicitly pinned the language (per-book or
-- global). Script routing must not override an explicit choice; auto mode
-- (metadata-detected) may be refined by the selection's own script.
function DualWiki:_isLangLocked()
    local doc_settings = self.ui and self.ui.doc_settings
    if doc_settings and doc_settings.readSetting
        and doc_settings:readSetting("dualwiki_lang_lock") then
        return true
    end
    return (G_reader_settings ~= nil
        and G_reader_settings:readSetting("dualwiki_lang") ~= nil) or false
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

-- Book-language → highlight-button plan. de/fr/es/ru only materialize
-- when the book itself is that language (LANG_MAP recognizes them, but
-- they stay hidden otherwise — per user direction "平时隐藏").
local BOOK_BUTTON_PLANS = {
    zh = { { engine = "moegirl", lang = "zh" }, { engine = "wikipedia", lang = "zh" } },
    en = { { engine = "wikipedia", lang = "en" }, { engine = "wikipedia", lang = "zh" } },
    ja = { { engine = "wikipedia", lang = "ja" }, { engine = "moegirl", lang = "ja" } },
    de = { { engine = "wikipedia", lang = "de" }, { engine = "wikipedia", lang = "en" } },
    fr = { { engine = "wikipedia", lang = "fr" }, { engine = "wikipedia", lang = "en" } },
    es = { { engine = "wikipedia", lang = "es" }, { engine = "wikipedia", lang = "en" } },
    ru = { { engine = "wikipedia", lang = "ru" }, { engine = "wikipedia", lang = "en" } },
}

local function buttonLabel(entry)
    if entry.engine == "wikipedia" then
        local l = entry.lang or "zh"
        if l == "zh" then return _("Wikipedia (ZH)") end
        if l == "en" then return _("Wikipedia (EN)") end
        if l == "ja" then return _("Wikipedia (JA)") end
        return string.format(_("Wikipedia (%s)"), l:upper())
    elseif entry.engine == "moegirl" then
        return _("Moegirlpedia")
    end
    return nil
end

function DualWiki:init()
    self:_loadPluginLocale()
    if self.ui and self.ui.highlight then
        self:_registerHighlightButtons()
        -- v1.3.5 (P1): single-word hold now lands on the selection page.
        self:_installSelectionEntry()
        -- v1.3.5 (P2): in-window ≥3s hold no longer flips to core wiki.
        self:_patchWindowDomainSwitch()
    end
    -- v1.3.5 (F1b): moegirl fullpage windows drop the Save-as-EPUB button
    -- (core's save path is wikipedia-only). Class-level patch — install
    -- unconditionally, not gated on ui.highlight/doc presence.
    self:_patchFullpageLayout()
    -- v1.3.5 (P2): same-id takeover of the core "Wikipedia" button.
    -- Core's button lives in DictQuickLookup's hardcoded pool and fired
    -- lookupWikipedia() with its OWN language memory (the "searched EN,
    -- title said ZH" split-brain). populatePluginButtons overwrites
    -- pool[spec.id] with our spec whenever shown, so this spec re-wires the
    -- same visible button into DualWiki:lookup — book-language plan, our
    -- routing, our title. Book search ("search" id) is untouched.
    -- v1.3.5 (F2): the takeover is a SETTING (default on). show_func is
    -- evaluated per window build, so flipping it restores the native
    -- button + its native fullscreen/EPUB channel on the very next lookup,
    -- no restart needed.
    -- v1.3.5 (F1b): moegirl fullpage windows drop the Save-as-EPUB button
    -- (core's save path is wikipedia-only). Class-level patch — install
    -- unconditionally, not gated on ui.highlight/doc presence.
    self:_patchFullpageLayout()
    if self.ui and self.ui.dictionary then
        self.ui.dictionary:addToDictButtons({
            id = "wikipedia",
            text = _("Wikipedia"),
            show_func = function() return self:_takeoverEnabled() end,
            callback = function(dql_window)
                local word = dql_window.lookupword or dql_window.word
                if word and word ~= "" then
                    self:lookup(word, "wikipedia", dql_window.word_boxes, self:_bookLang())
                end
            end,
        })
        -- v1.3.5 (F1/F1b): "Full article" — re-opens the
        -- currently viewed candidate as an immersive fullpage window. Core's
        -- fullpage bar is [Save as EPUB][Close] for wikipedia; moegirl gets
        -- the same fullpage reading window with the Save button stripped
        -- (_patchFullpageLayout) because core's save path can only fetch
        -- from {lang}.wikipedia.org.
        self.ui.dictionary:addToDictButtons({
            id = "dualwiki_fullpage",
            text = _("Full article"),
            show_func = function(dql_window)
                return (dql_window.dualwiki_engine == "wikipedia"
                    or dql_window.dualwiki_engine == "moegirl")
                    and not dql_window.is_wiki_fullpage
            end,
            callback = function(dql_window)
                self:showFullpageResult(
                    dql_window.lookupword or dql_window.word,
                    dql_window.definition or "",
                    dql_window.dualwiki_engine or "wikipedia",
                    dql_window.lang or self:_bookLang(),
                    dql_window.word_boxes)
            end,
        })
    end
    if self.ui and self.ui.menu then
        self.ui.menu:registerToMainMenu(self)
        -- v1.3.5 (P2): ReaderWikipedia's three menu entries are registered
        -- into Readermenu via registerToMainMenu and built lazily on menu
        -- open (menu_items may not exist at plugin init time). The reliable
        -- removal is done in addToMainMenu (below), which receives the
        -- constructed menu_items table. Nothing to do here for the menu side;
        -- the button side is already handled above in this init.
    end
end

-- v1.3.0: clear the per-session lookup cache when the document closes
-- (ReaderUI teardown also drops the whole plugin instance, so the cache is
-- freed with it; this explicit hook covers re-opening the same book without
-- a ReaderUI rebuild).
function DualWiki:onCloseDocument()
    self._lookup_cache = nil
    if self._prewarm_scheduled then
        UIManager:unschedule(self._prewarm_scheduled)
        self._prewarm_scheduled = nil
    end
    -- v1.3.3 (E7): pooled TLS sockets outlive the document; drop them so a
    -- long reader session never holds more idle sockets than needed.
    keepalive.clear()
end

-- v1.3.3 (E6): negative entries live this long — long enough to skip a
-- full dead ladder on re-selection, short enough that wiki content changes
-- still get picked up. Module-level so the E8 prewarm shares one truth.
local NEG_CACHE_TTL = 180
local CACHE_MAX_ENTRIES = 32

-- v1.3.5 (P1): unified selection entry — step 1 (收编词典，逐小步).
-- Core's single-word hold-release fired ReaderHighlight:lookupDictWord(),
-- which opened the native dictionary window directly ("diss" popup),
-- bypassing the selection page entirely. This instance-level reroute sends
-- every single-word hold to the selection page instead; the real dictionary
-- stays one tap away via the page's own Dictionary button (core
-- "06_dictionary" → lookupDict → dictionary:onLookupWord — untouched).
function DualWiki:_installSelectionEntry()
    local highlight = self.ui and self.ui.highlight
    if not highlight or highlight._dualwiki_entry_patched then return end
    highlight._dualwiki_entry_patched = true
    highlight.lookupDictWord = function(hl_self)
        hl_self:onShowHighlightMenu()
    end
    return true
end

-- v1.3.5 (P2): the ≥3s hold inside ANY result window used to flip domains
-- into core ReaderWikipedia (DictQuickLookup:lookupDictionaryOrWikipedia →
-- lookupWikipedia) — the last native-wiki door left after the button and
-- menu takeover. Same-id takeover can't reach it (it is a method call, not
-- a pool entry), so this class-level patch routes the wiki branch through
-- DualWiki:lookup instead.
-- v1.3.5 (P1 step 2): the SHORT hold inside a Dual Wiki result window is
-- also collected — it re-runs the selection through OUR search dialog
-- (word prefilled, ZH/EN/JA switch row available) instead of silently
-- bouncing into the native dictionary window again. Dictionary-origin
-- windows keep core behavior on both branches (no dualwiki_engine tag).
function DualWiki:_patchWindowDomainSwitch()
    if DictQuickLookup._dualwiki_domain_switch_patched then return end
    DictQuickLookup._dualwiki_domain_switch_patched = true
    local orig_ldow = DictQuickLookup.lookupDictionaryOrWikipedia
    DictQuickLookup.lookupDictionaryOrWikipedia = function(dql_self, selected_text, switch_domain)
        local dw = dql_self.ui and dql_self.ui.dual_wiki
        -- v1.3.5 (F2): takeover off → both hold branches fall back to core
        -- behavior (short hold re-opens native dict, ≥3s hold flips into
        -- native ReaderWikipedia with its fullscreen/EPUB channel).
        local is_ours = dw ~= nil and dql_self.dualwiki_engine ~= nil
            and dw:_takeoverEnabled()
        if is_ours and selected_text and selected_text ~= "" then
            local word = util.cleanupSelectedText(selected_text)
            if word and word ~= "" then
                if switch_domain then
                    dw:lookup(word, "wikipedia", dql_self.word_boxes, dw:_bookLang())
                else
                    local eng = dql_self.dualwiki_engine
                    local lang = dql_self.lang or dw:_bookLang()
                    dw:showSearchDialog(eng, word, dql_self.word_boxes, lang)
                end
                return true
            end
        end
        return orig_ldow(dql_self, selected_text, switch_domain)
    end
end

-- v1.3.3 (E8): single cache-write helpers shared by lookup() (positive +
-- negative paths) and the highlight prewarm (silent prefetch into the same
-- entries, so a button tap replays a cache hit verbatim).
function DualWiki:_storeCacheEntry(cache_key, cands, is_full, lang, needs_expand)
    if not cache_key then return end
    if not self._lookup_cache then self._lookup_cache = {} end
    local n = 0
    for _ in pairs(self._lookup_cache) do n = n + 1 end
    if n >= CACHE_MAX_ENTRIES then
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
    -- v1.3.5 (P3): remember which language this entry's content is actually
    -- in so cache replays title the window correctly.
    -- v1.3.5 (G2c): prewarm entries land UNEXPANDED (needs_expand) so the
    -- highlight menu never pays full-text fetches on the UI thread; the
    -- button tap expands the top candidate behind the progress message.
    self._lookup_cache[cache_key] = {
        cands = cands, is_full = is_full and true or false,
        needs_expand = needs_expand and true or nil,
        at = os.time(), lang = lang,
    }
end

function DualWiki:_storeMissEntry(cache_key)
    if not cache_key then return end
    self:_storeCacheEntry(cache_key, nil, false)
end

-- Load this plugin's .mo for the active KOReader UI language (gettext merge).
-- Normalizes common KOReader codes (zh_CN / zh-Hant / ja / ja_JP…) to the
-- bundled locale directory names.
function DualWiki:_loadPluginLocale()
    local lang = G_reader_settings and G_reader_settings:readSetting("language")
    if not lang or lang == "" then
        -- v1.3.2: KOReader follows the host environment (LANG/LC_ALL) until
        -- the user picks a language in the menu — settings then has no
        -- "language" key while the UI is still translated (GetText probes
        -- the environment at startup). Mirror the effective core language
        -- so the plugin is never left untranslated in that state.
        lang = GetText.current_lang
        if not lang or lang == "" or lang == "C" then return end
    end
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

    -- Two DYNAMIC button slots. The factories re-run on every highlight-menu
    -- invocation, reading the book language (with per-book lock applied) at
    -- that moment — button text, visibility and target engine all resolve
    -- live, so buttons always match the current book and any later lock
    -- changes. Slot A: book's own language engine; Slot B: the assist entry.
    local function registerSlot(slot_id, get_entry)
        highlight:addToHighlightDialog(slot_id, function(hl)
            return {
                text = (get_entry() and buttonLabel(get_entry())) or "",
                show_in_highlight_dialog_func = function()
                    return hl.selected_text ~= nil and get_entry() ~= nil
                end,
                callback = function()
                    local e = get_entry()
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
    registerSlot("05_a_dualwiki_primary", function() return self:_primaryButton() end)
    registerSlot("05_b_dualwiki_secondary", function() return self:_secondaryButton() end)

    -- v1.3.3 (E8): highlight prewarm. The primary-slot factory runs exactly
    -- when the highlight menu opens — that moment is the earliest signal
    -- that a lookup MIGHT happen. After a 600ms debounce (fast highlight
    -- gestures re-fire the factory; only the settled selection is worth a
    -- network round), the primary button's query is prefetched silently
    -- into the session cache, so tapping the button replays a cache hit.
    -- Never shows UI, never writes error state; transport failures simply
    -- leave no entry. OPT-IN via the settings toggle (default OFF — costs
    -- one background request per highlight; heavy users enable it).
    -- NOTE: the factory MUST return a well-formed button table — core
    -- onShowHighlightMenu indexes the return value unconditionally — so the
    -- "no prewarm" cases return a never-shown placeholder instead of nil.
    highlight:addToHighlightDialog("05_c_dualwiki_prewarm", function(hl)
        local enabled = G_reader_settings and G_reader_settings:isTrue("dualwiki_prewarm")
        local entry = enabled and self:_primaryButton() or nil
        local word = (entry and hl.selected_text) and util.cleanupSelectedText(hl.selected_text.text) or nil
        if enabled and entry and word and word ~= "" and utf8Len(word) <= 60 then
            -- The cache key MUST match lookup()'s, which routes the language
            -- (B7) BEFORE keying — otherwise a foreign-script selection in a
            -- zh book stores under wikipedia|zh|word while the tap reads
            -- wikipedia|en|word and the whole prewarm is wasted work.
            local prewarm_lang = entry.lang
            if entry.engine == "wikipedia" and prewarm_lang == "zh" and not self:_isLangLocked() then
                local routed = routeLangForScript(sanitizeQuery(word))
                if routed then prewarm_lang = routed end
            end
            if self._prewarm_scheduled then
                UIManager:unschedule(self._prewarm_scheduled)
            end
            -- NOTE: UIManager:scheduleIn returns NOTHING (core contract), so
            -- the task handle must be captured via a self-referencing closure
            -- for the later unschedule. Storing scheduleIn's return would
            -- store nil and let rapid re-highlights stack parallel prewarms.
            local scheduled
            scheduled = function()
                self._prewarm_scheduled = nil
                if not self.ui or not self.ui.dialog then return end
                local cache_key = table.concat({ entry.engine, prewarm_lang or "", word }, "|")
                local cached = self._lookup_cache and self._lookup_cache[cache_key]
                if cached and cached.cands then return end
                if cached and not cached.cands
                    and os.time() - (cached.at or 0) < NEG_CACHE_TTL then
                    return -- recently missed: don't re-burn the ladder
                end
                local ok, cands = pcall(function()
                    return self:queryPipeline(word, entry.engine, prewarm_lang)
                end)
                if ok and type(cands) == "table" and #cands > 0 and not self._last_error_kind then
                    -- v1.3.5 (P3): pipeline may have switched language
                    -- internally (Stage 3); use the effective one for the
                    -- langlink bridge AND the cache entry.
                    local effective_lang = self._last_effective_lang or prewarm_lang
                    self._last_effective_lang = nil
                    if self:_langlinkEnabled() then
                        cands = self:augmentLangLinks(cands, entry.engine, effective_lang)
                    end
                    -- v1.3.5 (G2c): the prewarm runs on the UI thread 0.6 s
                    -- after the highlight menu opens — full-text fetches here
                    -- (50 KB-1 MB JSON each) froze the menu for seconds, and
                    -- with it every tap (dictionary included). Land the cheap
                    -- probe result marked needs_expand; the button tap does
                    -- the single top-candidate expansion behind the progress
                    -- message.
                    self:_storeCacheEntry(cache_key, cands, false, effective_lang, true)
                elseif ok and not self._last_error_kind then
                    self:_storeMissEntry(cache_key)
                end
            end
            self._prewarm_scheduled = scheduled
            UIManager:scheduleIn(0.6, scheduled)
        end
        return {
            text = "",
            show_in_highlight_dialog_func = function()
                return false
            end,
            callback = function() end,
        }
    end)
end

-- v1.3.0: resolve the current book's button plan (two dynamic slots whose
-- factories re-read the book language on every highlight-menu invocation).
function DualWiki:_planButtons()
    local lang = self:_bookLang()
    local plan = BOOK_BUTTON_PLANS[lang] or BOOK_BUTTON_PLANS.zh
    local buttons = {}
    for _, entry in ipairs(plan) do
        buttons[#buttons + 1] = { engine = entry.engine, lang = entry.lang }
    end
    return buttons
end

function DualWiki:_primaryButton()
    return self:_planButtons()[1]
end

function DualWiki:_secondaryButton()
    return self:_planButtons()[2]
end

-- Core choices always visible; de/fr/es/ru surface only when the
-- current book is that language (平时隐藏，相对应的书才供应).
local LANG_LOCK_CHOICES_CORE = { "auto", "zh", "en", "ja" }
local LANG_LOCK_EU = { de = true, fr = true, es = true, ru = true }
local LANG_LOCK_NAMES = {
    zh = _("Chinese (ZH)"), en = _("English (EN)"), ja = _("Japanese (JA)"),
    de = _("German (DE)"), fr = _("French (FR)"), es = _("Spanish (ES)"), ru = _("Russian (RU)"),
}
local function langLockChoicesForThisBook(self)
    local normalized = normalizeLang(self:_rawBookLanguage())
    local choices = { unpack(LANG_LOCK_CHOICES_CORE) }
    local present = {}
    for _, c in ipairs(choices) do present[c] = true end
    local function add(code)
        if LANG_LOCK_EU[code] and not present[code] then
            present[code] = true
            choices[#choices + 1] = code
        end
    end
    add(normalized) -- the book's own language
    -- also surface any EU language the user has explicitly locked (so they
    -- can switch back without reopening a book of that language)
    local ds = self.ui and self.ui.doc_settings
    local bv = ds and ds:readSetting("dualwiki_lang_lock") or nil
    local gv = G_reader_settings and G_reader_settings:readSetting("dualwiki_lang") or nil
    add(bv ~= "auto" and bv or nil)
    add(gv ~= "auto" and gv or nil)
    return choices
end
local function langLockText(code)
    if code == "auto" then return _("Auto (detect from book)") end
    return LANG_LOCK_NAMES[code] or code
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
    -- v1.3.5 (P2/F2): remove the three legacy ReaderWikipedia
    -- entries registered by core ReaderWikipedia (lookup / history /
    -- settings) — but ONLY while takeover is enabled (default). With
    -- takeover off, core keeps its entries AND its native fullscreen +
    -- Save-as-EPUB channel; Dual Wiki then competes purely on merit.
    -- ReaderMenu materializes menu_items lazily at menu-open, and its
    -- tab_item_table cache is rebuilt after any reader restart, so a
    -- toggle takes effect on the next menu open.
    if self:_takeoverEnabled() then
        menu_items.wikipedia_lookup = nil
        menu_items.wikipedia_history = nil
        menu_items.wikipedia_settings = nil
    end

    -- "Dual Wiki" submenu: manual lookups + settings.
    local lookup_items = {
        {
            text = _("Moegirlpedia lookup"),
            callback = function()
                self:showSearchDialog("moegirl", nil, nil, "zh")
            end,
        },
        -- ONE Wikipedia search entry that follows the current book's
        -- language, resolved when the menu opens so the dialog title
        -- states it; plus fixed EN/JA entries.
        {
            text_func = function()
                return T(_("Wikipedia lookup (%1)"), self:_bookLang():upper())
            end,
            callback = function()
                self:showSearchDialog("wikipedia", nil, nil, self:_bookLang())
            end,
        },
        {
            text = _("Wikipedia lookup (English)"),
            callback = function()
                self:showSearchDialog("wikipedia", nil, nil, "en")
            end,
        },
        {
            text = _("Wikipedia lookup (Japanese)"),
            callback = function()
                self:showSearchDialog("wikipedia", nil, nil, "ja")
            end,
        },
    }

    -- v1.3.0: settings hub (兑现第五节第 3 条的语种锁定 UI).
    local settings_sub = {
        {
            text_func = function()
                -- show count hint when EU choices are surfaced, otherwise plain
                local n = #langLockChoicesForThisBook(self)
                if n > 4 then return _("Language lock (this book) *") end
                return _("Language lock (this book)")
            end,
            sub_item_table_func = function()
                local rows = {}
                for _, code in ipairs(langLockChoicesForThisBook(self)) do
                    rows[#rows + 1] = langLockRadioRow(self, code, "book")
                end
                return rows
            end,
        },
        {
            text_func = function()
                local n = #langLockChoicesForThisBook(self)
                if n > 4 then return _("Language lock (global default) *") end
                return _("Language lock (global default)")
            end,
            sub_item_table_func = function()
                local rows = {}
                for _, code in ipairs(langLockChoicesForThisBook(self)) do
                    rows[#rows + 1] = langLockRadioRow(self, code, "global")
                end
                return rows
            end,
        },
        {
            -- v1.3.5 (F1/F1b): immersive reading — wikipedia and
            -- moegirl results (which G2 already fills with full article
            -- text) open as fullpage windows. Wikipedia keeps core's
            -- [Save as EPUB][Close]; moegirl shows [Close] only (its save
            -- path is wikipedia-only, stripped by _patchFullpageLayout).
            text = _("Open results fullscreen by default"),
            checked_func = function()
                return G_reader_settings ~= nil and G_reader_settings:isTrue("dualwiki_fullpage")
            end,
            callback = function()
                if G_reader_settings:isTrue("dualwiki_fullpage") then
                    G_reader_settings:delSetting("dualwiki_fullpage")
                else
                    G_reader_settings:saveSetting("dualwiki_fullpage", true)
                end
            end,
        },
        {
            -- v1.3.5 (F2): native Wikipedia takeover, default ON. When off,
            -- core keeps its menu entries, its dict button, and its native
            -- fullscreen + EPUB channel; the change applies to the next
            -- window/menu build (no restart needed for lookups).
            text = _("Take over native Wikipedia entry points"),
            checked_func = function()
                return self:_takeoverEnabled()
            end,
            callback = function()
                if self:_takeoverEnabled() then
                    G_reader_settings:saveSetting("dualwiki_no_takeover", true)
                else
                    G_reader_settings:delSetting("dualwiki_no_takeover")
                end
            end,
        },
        {
            -- v1.3.3 (E8): highlight-menu prewarm, OPT-IN (default OFF):
            -- costs one background request per highlight; heavy users enable.
            text = _("Prewarm lookup on highlight"),
            checked_func = function()
                return G_reader_settings and G_reader_settings:isTrue("dualwiki_prewarm")
            end,
            callback = function()
                if G_reader_settings:isTrue("dualwiki_prewarm") then
                    G_reader_settings:delSetting("dualwiki_prewarm")
                else
                    G_reader_settings:saveSetting("dualwiki_prewarm", true)
                end
            end,
        },
        {
            -- v1.3.3 (E2): cross-language bridge, OPT-IN (default OFF):
            -- one langlinks request per pipeline; adds a "→ XX" pseudo-candidate.
            text = _("Cross-language suggestions"),
            checked_func = function()
                return G_reader_settings and G_reader_settings:isTrue("dualwiki_langlink")
            end,
            callback = function()
                if G_reader_settings:isTrue("dualwiki_langlink") then
                    G_reader_settings:delSetting("dualwiki_langlink")
                else
                    G_reader_settings:saveSetting("dualwiki_langlink", true)
                end
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
    menu_items.dualwiki = {
        text = _("Dual Wiki"),
        sorting_hint = "search",
        sub_item_table = (function()
            local items = {}
            for _, item in ipairs(lookup_items) do
                table.insert(items, item)
            end
            table.insert(items, {
                text = _("Dual Wiki settings"),
                sub_item_table = settings_sub,
            })
            return items
        end)(),
    }
end
-- v1.3.3 (E2): cross-language bridge gate. OPT-IN (default OFF) per user
-- direction — the extra langlinks request and the "→ XX" pseudo-candidate
-- are noise for most lookups; heavy users enable it in settings.
function DualWiki:_langlinkEnabled()
    return G_reader_settings ~= nil and G_reader_settings:isTrue("dualwiki_langlink")
end

function DualWiki:showSearchDialog(engine, initial_query, word_boxes, lang)
    local cfg = ENGINES[engine]
    if not cfg then return end
    local title = _("Article lookup") .. " · " .. cfg.label(lang)
    local input_dialog
    -- v1.3.5 (P3): explicit language switch inside the search dialog. The
    -- title's language label now always states where results come from, and
    -- the user can override it with one tap instead of fighting book-language
    -- defaults or core language memory.
    local lang_switch_row = nil
    local lang_choices = ({
        wikipedia = { "zh", "en", "ja" },
        moegirl = { "zh", "ja" },
    })[engine]
    if lang_choices and #lang_choices > 1 then
        lang_switch_row = {}
        for _, code in ipairs(lang_choices) do
            table.insert(lang_switch_row, {
                text = code:upper(),
                enabled = code ~= lang,
                callback = function()
                    local query = input_dialog:getInputText()
                    UIManager:close(input_dialog)
                    if query and strTrim(query) ~= "" then
                        self:lookup(strTrim(query), engine, word_boxes, code)
                    else
                        -- nothing typed yet: re-open with the new language
                        self:showSearchDialog(engine, initial_query, word_boxes, code)
                    end
                end,
            })
        end
    end
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
            lang_switch_row,
        },
    }
    UIManager:show(input_dialog)
    input_dialog:onShowKeyboard()
end

-- Merged probe request: one HTTP round-trip returns up to MAX_CANDIDATES
-- ranked candidates, each with a readable intro summary (exintro mode keeps
-- exlimit unclamped; full-text mode is server-clamped to 1 page).
-- mode: "prefix" (generator=prefixsearch) or "search" (generator=search).
function DualWiki:fetchCandidates(q, engine, lang, mode)
    local esc_q = socket_url.escape(q)
    local params
    if mode == "search" then
        -- v1.3.3 (A3): gsrinfo=suggestion piggybacks MediaWiki's spell
        -- correction on the same request; captured below for the retry
        -- dialog ("did you mean").
        -- v1.3.3 (E5): the search fallback widens to 8 candidates — intro
        -- extracts are not clamped, so this stays one request. True
        -- gsroffset paging is deferred: DictQuickLookup offers no clean
        -- button-extension point for a "more" affordance.
        params = string.format("&generator=search&gsrsearch=%s&gsrlimit=%d&gsrinfo=suggestion",
            esc_q, MAX_SEARCH_CANDIDATES)
    else
        params = string.format("&generator=prefixsearch&gpssearch=%s&gpslimit=%d", esc_q, MAX_CANDIDATES)
    end
    -- v1.3.3 (A1): pageprops piggybacks the Disambiguator flag on the same
    -- merged request; core prop, so moegirl tolerates it even without the
    -- extension (flag just never fires there).
    -- v1.3.3 (E5): exlimit follows the generator's limit so all 8 search
    -- candidates carry intro extracts in the same request.
    local limit = (mode == "search") and MAX_SEARCH_CANDIDATES or MAX_CANDIDATES
    params = params
        .. "&prop=extracts|pageprops&ppprop=disambiguation&explaintext=1&exintro=1&exlimit=" .. limit
        .. "&redirects=1&format=json&formatversion=2"
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
    if not ok_json or type(data) ~= "table" then
        return nil
    end
    -- v1.3.3 (A3): keep the spell-correction suggestion for the failure
    -- path (cleared per lookup; only ever consumed by showRetryDialog).
    if mode == "search" and type(data.query) == "table" and type(data.query.searchinfo) == "table" then
        self._last_suggestion = type(data.query.searchinfo.suggestion) == "string"
            and data.query.searchinfo.suggestion or nil
    end
    if not data.query or type(data.query.pages) ~= "table" then
        return nil
    end
    return parseCandidatePages(data, q)
end

-- v1.3.3 (A1): expand a disambiguation page into its items. The dab page's
-- own section-0 wikitext carries the curated "item - description" bullets
-- in MEDIAWIKI SOURCE ORDER — the editor's semantic ranking. prop=links is
-- unusable here: it is anon-capped (pllimit ≤10) and reorders entries, so
-- on ja.wp the marquee 灼眼のシャナ fell outside the slice and on en.wp
-- "Anna Kavan" outranked the planet. Bullet titles are exact article
-- titles, so ONE batched intro-extract pass fills every item's definition
-- (exintro mode allows exlimit beyond the full-text clamp of 1). Any
-- failure degrades to the original dab result set (expandDisambiguation).
function DualWiki:fetchDisambiguationItems(dab_title, engine, lang)
    -- action=parse is NOT a query action — build the URL directly instead
    -- of buildApiURL (which would emit a duplicate action=query).
    local cfg = ENGINES[engine]
    local wt_url = cfg.api(lang)
        .. "?action=parse&prop=wikitext&section=0&redirects=1&page="
        .. socket_url.escape(dab_title) .. "&format=json&formatversion=2"
    local ok, body = httpGet(wt_url, PROBE_TIMEOUT)
    if not ok or not body then
        self._last_error_kind = type(body) == "string" and body or "error"
        return nil
    end
    local ok_json, data = pcall(JSON.decode, body)
    if not ok_json or type(data) ~= "table" or type(data.parse) ~= "table"
        or type(data.parse.wikitext) ~= "string" then
        return nil
    end

    local titles = {}
    local seen = {}
    for line in data.parse.wikitext:gmatch("[^\n]+") do
        -- v1.3.3 (L3): collect up to 10; the batched extract pass handles
        -- exlimit=20 in one request, so more items cost nothing extra.
        if #titles >= 10 then break end
        local s = line:match("^%*+%s*(.*)$")
        if not s or s == "" then
            if #titles > 0 then break end
        else
            -- Leading-link rule: accept only when the bullet begins with a
            -- title link and the link is followed by punctuation/space
            -- (",", "-", "(", end-of-line). That captures curated items
            -- like "[[Mercury (planet)]], …" and "[[シャナ (フランス)]] (Chanas) - …",
            -- while rejecting prose-start bullets such as "[[英語圏]]の女性名…"
            -- where the link is part of the description, not the item title.
            local item
            local link, tail = s:match("^%[%[([^%]|#]+)%]%](.*)$")
            if link then
                local lead = (tail or "")
                if lead == "" or lead:match("^%s*[,;:%.%-–—%(%)%[%{]" ) then
                    item = link
                end
            end
            if item and not seen[item]
                and not item:match("^File:") and not item:match("^Category:")
                and not item:match("^Template:") and not item:match("^User:")
                and not item:match("^Wikipedia:") and not item:match("^Portal:")
                and not item:match("^Help:") then
                seen[item] = true
                titles[#titles + 1] = item
            end
        end
    end
    if #titles < 2 then return nil end

    -- v1.3.3: DAB_MAX_ITEMS — the batched intro-extract request tolerates
    -- exlimit=20, so ten curated items cost the same single request.
    local ext_url = buildApiURL(engine, lang,
        "&prop=extracts&explaintext=1&exintro=1&exlimit=20&redirects=1&titles="
        .. socket_url.escape(table.concat(titles, "|")) .. "&format=json&formatversion=2")
    local extracts = {}
    local missing = {}
    local ok2, body2 = httpGet(ext_url, PROBE_TIMEOUT)
    if ok2 and body2 then
        local okj2, data2 = pcall(JSON.decode, body2)
        if okj2 and type(data2) == "table" and type(data2.query) == "table"
            and type(data2.query.pages) == "table" then
            for _, page in ipairs(data2.query.pages) do
                if type(page) == "table" and type(page.title) == "string" then
                    if page.missing then
                        -- v1.3.3 (L1): red-link bullets — the wikitext links a
                        -- title that has no article yet; pencil would 404.
                        missing[caseFold(page.title)] = true
                    elseif type(page.extract) == "string" then
                        extracts[caseFold(page.title)] = page.extract
                    end
                end
            end
            -- v1.3.3 (L2): items that are redirects resolve server-side, so
            -- the response title (target) differs from the bullet title
            -- (source). Propagate extracts from target back to source so the
            -- candidate list keyed by bullet titles still finds its extract.
            if type(data2.query.redirects) == "table" then
                for _, r in ipairs(data2.query.redirects) do
                    if type(r) == "table" and type(r.from) == "string"
                        and type(r.to) == "string"
                        and not missing[caseFold(r.to)] then
                        local ext = extracts[caseFold(r.to)]
                        if ext then
                            extracts[caseFold(r.from)] = ext
                        end
                    end
                end
            end
        end
    end
    local cands = {}
    for i, t in ipairs(titles) do
        -- L1: red links never surface as candidates at all.
        if not missing[caseFold(t)] then
            cands[#cands + 1] = {
                title = t,
                extract = extracts[caseFold(t)] or "",
                index = #cands + 1,
                exact = false,
                dab_item = true,
            }
        end
    end
    return #cands > 0 and cands or nil
end

-- v1.3.3 (A1): if the winning top candidate is a disambiguation page,
-- replace the result set with the dab page's items. The dab page itself
-- carries no readable body — its link list IS the candidate set the user
-- needs. Falls back to the original list on any expansion failure.
function DualWiki:expandDisambiguation(cands, engine, lang)
    if type(cands) ~= "table" or not cands[1] or not cands[1].dab then
        return cands
    end
    local items = self:fetchDisambiguationItems(cands[1].title, engine, lang)
    if type(items) == "table" and #items > 0 then
        return items
    end
    return cands
end

-- v1.3.3 (E2): cross-language bridge. ONE langlinks request for the TOP
-- candidate resolves its equivalent article in the reader's language (book
-- language when it differs from the result language, else zh for any
-- non-zh result) and surfaces it as a trailing pseudo-candidate whose
-- pencil loads the full article directly in that language. Silent on any
-- failure — the window simply shows what it always showed.
function DualWiki:augmentLangLinks(cands, engine, lang)
    if type(cands) ~= "table" or #cands == 0 then return cands end
    if engine ~= "wikipedia" then return cands end
    -- A dab-expansion list is an index of same-topic senses in ONE language;
    -- bridging its top entry to another language is noise, not help.
    if cands[1].dab_item then return cands end
    local book_lang = self:_bookLang()
    local target
    if book_lang ~= lang then
        target = book_lang
    elseif lang ~= "zh" then
        target = "zh"
    end
    if not target or not cands[1] or not cands[1].title then return cands end
    local url = buildApiURL(engine, lang,
        "&prop=langlinks&lllang=" .. socket_url.escape(target) .. "&redirects=1&titles="
        .. socket_url.escape(cands[1].title) .. "&format=json&formatversion=2")
    local ok, body = httpGet(url, PROBE_TIMEOUT)
    if not ok or not body then return cands end
    local ok_json, data = pcall(JSON.decode, body)
    if not ok_json or type(data) ~= "table" or type(data.query) ~= "table"
        or type(data.query.pages) ~= "table" then
        return cands
    end
    local linked
    for _, page in ipairs(data.query.pages) do
        if type(page) == "table" and type(page.langlinks) == "table" then
            for _, ll in ipairs(page.langlinks) do
                if type(ll) == "table" and ll.lang == target and type(ll.title) == "string" then
                    linked = ll.title
                    break
                end
            end
        end
        if linked then break end
    end
    if not linked
        or caseFold(linked) == caseFold(cands[1].title) then
        return cands
    end
    cands[#cands + 1] = {
        title = linked,
        extract = "",
        index = 998,
        exact = false,
        langlink_lang = target,
        langlink_from = cands[1].title,
    }
    return cands
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

-- v1.3.5 (G2c, burn-in perf finding): expand ONLY the top candidate. The
-- window opens on it, so the first screen is always the full article (the
-- user-facing G2 contract), while the remaining candidates keep their cheap
-- lead summaries. A full-page response is 50 KB-1 MB of JSON to decode;
-- doing that for N candidates synchronously on the UI thread froze the
-- highlight menu for seconds (and with it the whole app — taps on any
-- button, the dictionary included, only processed after the freeze). The
-- probe stays cheap; the one heavy fetch happens behind the progress
-- dialog. A structurally failed top fetch keeps its lead; a TRANSPORT
-- failure leaves _last_error_kind set so the round is never cached (E6).
function DualWiki:_expandAllFullText(cands, engine, lang)
    if type(cands) ~= "table" or #cands == 0 then return cands, false end
    local cand = cands[1]
    local fetch_engine = engine
    local fetch_lang = lang
    if cand.langlink_lang then
        -- E2 pseudo-entry lives on the target-language wikipedia
        fetch_engine = "wikipedia"
        fetch_lang = cand.langlink_lang
    end
    local full = self:fetchDirect(cand.title, fetch_engine, fetch_lang)
    if full and full[1] and type(full[1].extract) == "string"
        and utf8Len(full[1].extract) > utf8Len(cand.extract or "") then
        cands[1] = {
            title = cand.title,
            extract = full[1].extract,
            index = cand.index or 1,
            exact = cand.exact,
            dab = cand.dab,
            dab_item = cand.dab_item,
            langlink_lang = cand.langlink_lang,
            langlink_from = cand.langlink_from,
        }
    end
    return cands, true
end

-- v1.3.3 (E2): pencil on a cross-language pseudo-candidate — fetch the
-- equivalent article's full text in the target language and show it as a
-- one-result window (full-text flow, no further network round).
function DualWiki:fetchDirectAndShow(word, engine, lang, word_boxes)
    local cands = self:fetchDirect(word, engine, lang)
    if cands then
        self:showResult(word, cands, engine, word_boxes, lang, true)
    else
        self:showRetryDialog(word, engine, word_boxes, lang)
    end
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
--   1b. bare-word elision probe (fr/it/pt), challenging Stage 1 pre-verdict
--   2. prefixsearch(query minus ONE trailing particle, language-aware)
--   3. en.wikipedia retry for pure-Latin queries on zh
--   4. top candidate carries real content (server-side redirect targets)
--   5. generator=search full-text fallback
--   6. surface whatever prefix noise we had
function DualWiki:queryPipeline(word, engine, lang)
    -- v1.3.5 (P3): every return now carries the EFFECTIVE language as a
    -- third value. Stage 3/6 may recurse into another language internally;
    -- the caller used to keep the requested lang and stamp it on the result
    -- window title ("searched EN, title said ZH"). Tail calls propagate the
    -- inner round's lang automatically.
    local q0 = sanitizeQuery(word)
    if q0 == "" then q0 = word end
    -- v1.3.3 (B7): selection script routing. A zh-defaulted book receiving a
    -- clearly non-CJK selection goes straight to the matching wikipedia
    -- language — previously a Latin selection burned the zh probe (up to 3
    -- requests) before Stage 3's fallback kicked in. Explicit language locks
    -- are honored (checked in lookup(), which owns the lock context) and
    -- Stage 3 stays as the locked-zh safety net.
    if engine == "wikipedia" and lang == "zh" and not self:_isLangLocked() then
        local routed = routeLangForScript(q0)
        if routed then
            lang = routed
        end
    end
    local plang = ENGINES[engine] and ENGINES[engine].particleLang(lang) or "zh"
    local q2 = stripTrailingParticle(q0, plang)
    -- v1.3.5 (P4): "version tail" degradation. Selections like "DLSS 5",
    -- "RTX 4090", "宝可梦 朱" are not article titles — the article lives at
    -- the head word. Build a second query with the trailing number/edition
    -- token dropped and try it AFTER the exact query misses (a real title
    -- like "Final Fantasy VII" still wins Stage 1, so nothing regresses).
    local q_number_stripped = nil
    do
        local head = q0:match("^(.-)%s+%d+[%d%.]*%s*$")
        if head and utf8Len(head) >= 2 then
            q_number_stripped = head
        end
    end
    -- v1.3.5 (P4): space-delimited CJK particle ("DLSS 5 的", "シャナ な").
    -- stripTrailingParticle only matches particles GLUED to the tail; the
    -- spaced form survived every stage and dead-ended in the retry dialog.
    local q_spaced_particle = nil
    do
        local head = q0:match("^(.-)%s+[" ..
            table.concat(PARTICLES[plang] or PARTICLES.zh) .. "]%s*$")
        if head and utf8Len(head) >= 2 then
            q_spaced_particle = head
        end
    end

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
        return self:expandDisambiguation(r1, engine, lang), false, lang
    end

    -- Stage 2: trailing-particle drop retry (量子力学的 → 量子力学,
    -- シャナの → シャナ, Oppenheimer's → Oppenheimer).
    -- Skipped when moegirl itself is unreachable (no point re-hitting it).
    -- (v1.3.2: the elision strip moved up to Stage 1b; q3 is computed there.)
    local r2 = nil
    if q2 ~= q0 and utf8Len(q2) >= 2 and not self._moegirl_unreachable then
        r2 = self:fetchCandidates(q2, engine, lang, "prefix")
        if hasGoodHit(r2, q2, plang) then
            return self:expandDisambiguation(r2, engine, lang), false, lang
        end
    end

    -- Stage 2c (v1.3.5 P4): version-tail and spaced-particle degradation.
    -- "DLSS 5" → probe "DLSS"; "DLSS 5 的" → probe "DLSS 5". Both fire only
    -- after the exact query and the glued-particle strip missed, so real
    -- titles containing numbers ("Final Fantasy VII", "娃娃 3") always win.
    -- The hasGoodHit verdict on the STRIPPED query keeps noise out; the
    -- original selection stays as the window word (what the user selected).
    for _, alt in ipairs({ q_spaced_particle, q_number_stripped }) do
        if alt and alt ~= q0 and alt ~= q2 and utf8Len(alt) >= 2 and not self._moegirl_unreachable then
            local r_alt = self:fetchCandidates(alt, engine, lang, "prefix")
            if hasGoodHit(r_alt, alt, plang) then
                return self:expandDisambiguation(r_alt, engine, lang), false, lang
            end
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
        return self:expandDisambiguation(r1, engine, lang), false, lang
    end

    -- Stage 5: full-text search fallback (catches dab-page tops like
    -- 三体 → 三體 with no content, where search resolves 三体 (小说)).
    -- Also skipped on an unreachable moegirl.
    local s = nil
    if not self._moegirl_unreachable then
        s = self:fetchCandidates(q0, engine, lang, "search")
    end
    if s and #s > 0 and sharesPrefixAny(s, q2 ~= q0 and q2 or q0, plang) then
        return self:expandDisambiguation(s, engine, lang), false, lang
    end

    -- Stage 6 (cross-engine synergy): moegirl zero-hits or transport failures
    -- degrade to wikipedia — ja-book kana queries resolve on ja.wikipedia
    -- (灼眼のシャナ), zh-book queries on zh.wikipedia. This is the v1.2.1
    -- moegirl-reachability escape hatch for DNS-poisoned regions.
    if engine == "moegirl" then
        local fallback_lang = (lang == "ja") and "ja" or "zh"
        if lang == "ja" or self._moegirl_unreachable then
            local fallback, _, fallback_used_lang = self:queryPipeline(word, "wikipedia", fallback_lang)
            if fallback and #fallback > 0 then
                return fallback, false, fallback_used_lang or fallback_lang
            end
        end
    end

    -- Stage 7: surface whatever prefix noise we had (better than nothing).
    if r1 and #r1 > 0 then
        return self:expandDisambiguation(r1, engine, lang), false, lang
    end
    if r2 and #r2 > 0 then
        return self:expandDisambiguation(r2, engine, lang), false, lang
    end

    return nil, false, lang
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
    -- v1.3.3 (A3): a suggestion is only ever valid for the query round that
    -- produced it; clear up front so a later failure can't inherit it.
    self._last_suggestion = nil

    -- v1.3.3 (B7): resolve the selection's script BEFORE showing the
    -- progress dialog, so the routed engine label (e.g. Wikipedia (EN) for a
    -- Latin selection in a zh book) is what the user sees. Idempotent with
    -- the queryPipeline-level check (which re-runs for recursive ladders);
    -- both defer to _isLangLocked so explicit locks always win.
    if engine == "wikipedia" and lang == "zh" and not self:_isLangLocked() then
        local routed = routeLangForScript(sanitizeQuery(word))
        if routed then
            lang = routed
        end
    end

    -- v1.3.0: session lookup cache — repeat lookups of the same word/engine/
    -- lang in this ReaderUI session skip the network entirely. Capped, and
    -- cleared on document close.
    -- v1.3.3 (E6): negative entries remember full-ladder misses (no zero
    -- transport involved) so re-selecting the same word skips the ladder;
    -- NEG_CACHE_TTL keeps the window short enough for wiki content to change.
    local prompt_title = string.format("%s · %s", _("Querying"), cfg.label(lang))
        .. LF .. word
    local cache_key = table.concat({ engine, lang or "", word }, "|")
    local cached = self._lookup_cache and self._lookup_cache[cache_key]
    if cached then
        if cached.cands then
            -- v1.3.5 (P3): entries remember the language their content is
            -- actually in (Stage 3/6 may have switched internally); the
            -- window title follows it instead of the requested lang.
            -- v1.3.5 (G2c): prewarm entries land UNEXPANDED (needs_expand);
            -- the tap pays ONE top-candidate full fetch behind this message
            -- instead of the highlight menu paying N fetches on the UI
            -- thread.
            local cands, is_full = cached.cands, cached.is_full
            if cached.needs_expand and not cached.is_full then
                local progress_info_cache = InfoMessage:new{ text = prompt_title, timeout = 15 }
                UIManager:show(progress_info_cache)
                cands, is_full = self:_expandAllFullText(cands, engine, cached.lang or lang)
                UIManager:close(progress_info_cache)
                if not self._last_error_kind then
                    self:_storeCacheEntry(cache_key, cands, is_full, cached.lang or lang)
                end
            end
            self:showResult(word, cands, engine, word_boxes, cached.lang or lang, is_full)
            return
        end
        if os.time() - (cached.at or 0) < NEG_CACHE_TTL then
            self:showRetryDialog(word, engine, word_boxes, lang)
            return
        end
        self._lookup_cache[cache_key] = nil -- stale miss: re-query
    end

    -- v1.3.3 (E8): a real lookup starting means the prewarm lost the race
    -- (user tapped within the 600ms debounce) — cancel it, or both a real
    -- ladder and the prefetch would burn the same queries concurrently.
    if self._prewarm_scheduled then
        UIManager:unschedule(self._prewarm_scheduled)
        self._prewarm_scheduled = nil
    end

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
                self._last_effective_lang = lang
                return self:fetchDirect(word, engine, lang), true
            end
            -- v1.3.5 (P3): queryPipeline returns (cands, is_full, effective_lang);
            -- stash the language on self (pcall multiple-return plumbing).
            local result, full_flag, used_lang = self:queryPipeline(word, engine, lang)
            self._last_effective_lang = used_lang or lang
            return result, full_flag
        end)

        UIManager:close(progress_info)

        if ok and type(cands) == "table" and #cands > 0 then
            -- v1.3.5 (P3): the language the CONTENT is in — Stage 3/6 may
            -- have switched from the requested one; the title must follow.
            local effective_lang = self._last_effective_lang or lang
            self._last_effective_lang = nil
            -- v1.3.3 (E2): cross-language bridge for fresh article queries
            -- (cache hits replay the stored list, already bridged; full-text
            -- fetches skip bridging entirely).
            -- v1.3.5 (G2): THEN expand every candidate to full article text
            -- (lead length irrelevant) and mark the round full so the
            -- pencil falls back to the edit dialog and the cache replays
            -- the expanded list.
            if not want_full and not is_full then
                if self:_langlinkEnabled() then
                    cands = self:augmentLangLinks(cands, engine, effective_lang)
                end
                cands, is_full = self:_expandAllFullText(cands, engine, effective_lang)
            end
            -- v1.3.0: store in the session cache (capped at 32 entries,
            -- oldest-evicted; showResult only reads the stored table).
            -- v1.3.3 (E8): write goes through the shared helper so the
            -- highlight prewarm lands identical entries.
            -- v1.3.5 (P3): cache entries carry their effective language.
            -- v1.3.5 (G2): a mid-expansion transport failure leaves
            -- _last_error_kind set — E6 contract, never cache that round.
            if not self._last_error_kind then
                self:_storeCacheEntry(cache_key, cands, want_full or is_full, effective_lang)
            end
            self:showResult(word, cands, engine, word_boxes, effective_lang, want_full or is_full)
        else
            -- v1.3.3 (E6): remember a clean (non-transport) miss so repeated
            -- selections of the same word skip the ladder. Transport errors
            -- (kind set) and Lua errors (not ok) are never cached.
            if ok and not self._last_error_kind then
                self:_storeMissEntry(cache_key)
            end
            -- v1.3.5 (P3): consume the stashed effective language on the
            -- miss path too, so the retry dialog reports the language the
            -- ladder actually probed (and never leaks it to a later round).
            local miss_lang = self._last_effective_lang or lang
            self._last_effective_lang = nil
            self:showRetryDialog(word, engine, word_boxes, miss_lang)
        end
    end)
end

function DualWiki:showResult(word, cands, engine, word_boxes, lang, is_full, force_fullpage)
    local self_ref = self
    local cfg = ENGINES[engine]
    if not cfg then return end
    local dict_name = cfg.label(lang)
    local result_lang = lang or "zh"
    -- v1.3.5 (F1/F1b): immersive large-window reading, a
    -- first-class Dual Wiki feature now that G2 already carries full
    -- article text. wikipedia AND moegirl qualify. The fullpage window's
    -- fixed [Save as EPUB][Close] layout calls core
    -- Wikipedia:createEpubWithUI with the window's lang — a real-wiki
    -- language requirement — so moegirl fullpage windows strip the Save
    -- button at layout build (_patchFullpageLayout) rather than losing
    -- fullscreen reading entirely.
    -- An explicit langlink pseudo-candidate is excluded: its pencil loads
    -- the real article; the stub here has nothing worth archiving.
    local allow_fullpage = engine == "wikipedia" or engine == "moegirl"
    local auto_fullpage = allow_fullpage and G_reader_settings ~= nil
        and G_reader_settings:isTrue("dualwiki_fullpage")
    self._last_fullpage = (force_fullpage or auto_fullpage) and allow_fullpage or false

    self._last_candidate_titles = {}
    self._last_langlink = {}
    self._last_was_full = is_full and true or false

    local results = {}
    for i, cand in ipairs(cands) do
        self._last_candidate_titles[cand.title] = true
        local definition
        if cand.extract and #cand.extract > 0 then
            definition = cleanWikiExtract(cand.extract)
        else
            -- G2: windows carry full text whenever the article has one; this
            -- bare label only remains for title-only engines' misses and
            -- pages whose full fetch structurally failed.
            definition = _("Candidate match.")
        end
        -- v1.3.3 (A1): dab-expansion entries are one of several senses;
        -- tag the definition line so the reader knows they are browsing an
        -- index, not the single best article.
        if cand.dab_item then
            definition = "【" .. _("Disambiguation entry") .. "】" .. LF .. definition
        end
        -- v1.3.3 (E2): cross-language pseudo-candidates.
        local cand_dict = dict_name
        local cand_lang = result_lang
        if cand.langlink_lang then
            self._last_langlink[cand.title] = cand.langlink_lang
            cand_dict = ENGINES.wikipedia.label(cand.langlink_lang)
            cand_lang = cand.langlink_lang
            definition = _("Cross-language article. Tap the pencil icon at the top right to load it.")
                .. LF .. "→ " .. cand.title
        end
        results[i] = {
            word = cand.title,
            definition = definition,
            -- v1.3.2 crash fix: DictQuickLookup:changeDictionary() reads
            -- results[index].dict (NOT .dictionary) for the window title;
            -- a nil here made scrolling past the last result (auto
            -- next-result) die on TitleBar:setText(nil). Field must match
            -- the core dictionary result contract.
            dict = cand_dict,
            dictionary = cand_dict,
            lang = cand_lang,
            rtl_lang = false,
        }
        if self._last_fullpage and not cand.dab and not cand.dab_item
            and not cand.langlink_lang
            and cand.extract and #cand.extract > 0 then
            results[i].is_wiki_fullpage = true
        end
    end

    local window
    window = DictQuickLookup:new{
        ui = self.ui,
        highlight = self.ui.highlight,
        dialog = self.dialog,
        word = word,
        word_boxes = word_boxes,
        results = results,
        -- v1.3.5 (P1 step 2): lets the in-window short-hold re-selection
        -- route back into OUR search dialog with the right engine.
        dualwiki_engine = engine,
        -- Verified by Codex: is_wiki=false decouples from core ReaderWikipedia private methods
        is_wiki = false,
        -- Pencil icon routes through the native DictQuickLookup:onLookupInputWord()
        -- method, so overriding it via constructor field must keep the
        -- (window, hint, ev) shape. On keyboard-enabled devices the same name
        -- can be dispatched as an event handler where `hint` is the key event
        -- table, so only forward real strings.
        -- Single tap prefills the original selection; long-press prefills the
        -- currently viewed candidate (self.lookupword updates on switch).
        -- v1.3.3 (E2): when the viewed candidate is a cross-language
        -- pseudo-entry, the pencil loads its full article directly in the
        -- target language instead of reopening search.
        -- v1.3.5 (G2, user direction): otherwise the pencil keeps its
        -- ORIGINAL core role — edit the queried word (search dialog). The
        -- always-full display left it nothing to expand.
        onLookupInputWord = function(dlg, hint, ev)
            if type(hint) ~= "string" then
                hint = nil
            end
            local viewed = hint or word
            local link_lang = self_ref._last_langlink and self_ref._last_langlink[viewed]
            if link_lang then
                self_ref:fetchDirectAndShow(viewed, "wikipedia", link_lang, word_boxes)
                return
            end
            self_ref:showSearchDialog(engine, viewed, word_boxes, lang)
        end,
    }
    UIManager:show(window)
end

-- v1.3.5 (F1/F1b): immersive reading — re-show the currently
-- viewed article in a fullpage window (width = screen minus margins; the
-- button bar is [Save as EPUB][Close] for wikipedia, [Close]-only for
-- moegirl via _patchFullpageLayout). The definition is ALREADY full text
-- (G2), so no network round is needed: the exact-title extract is replayed
-- from the session cache (engine-matched); a cache miss falls back to one
-- fetchDirect round. Always shows a SINGLE-candidate window for the viewed
-- title (never re-opens on the list's top entry).
function DualWiki:showFullpageResult(title, definition, engine, lang, word_boxes)
    if not title or title == "" then return end
    local extract = definition
    local cached = self:_cachedFullpageCandidates(title, engine)
    if cached then
        for _, c in ipairs(cached) do
            if c.title == title and c.extract and #c.extract > 0 then
                extract = c.extract
                break
            end
        end
    end
    if not extract or extract == "" then
        local fresh = self:fetchDirect(title, engine, lang)
        if fresh and fresh[1] and fresh[1].extract then
            extract = fresh[1].extract
        else
            self:showRetryDialog(title, engine, word_boxes, lang)
            return
        end
    end
    self:showResult(title, { { title = title, extract = extract } },
        engine, word_boxes, lang, true, true)
end

-- v1.3.5 (F1/F1b): exact-title replay from the session cache so
-- toggling fullpage never re-downloads an article already expanded by G2.
-- Returns the candidate LIST (showFullpageResult picks the viewed title's
-- entry). Entries are matched by ENGINE (cache keys are engine|lang|word):
-- a moegirl fullpage must never replay a wikipedia round — the same title
-- (初音未来) lives on both sites with different content. Prefers an
-- already-EXPANDED entry (is_full, not needs_expand — the probe-only
-- prewarm entry carries just the lead summary).
function DualWiki:_cachedFullpageCandidates(title, engine)
    if not self._lookup_cache then return nil end
    local fallback = nil
    for key, entry in pairs(self._lookup_cache) do
        local key_engine = key:match("^([^|]+)|")
        if key_engine == engine then
            local cands = entry.cands
            if type(cands) == "table" then
                for _, c in ipairs(cands) do
                    if c.title == title and c.extract and #c.extract > 0 then
                        if not entry.needs_expand or entry.is_full then
                            return cands
                        end
                        fallback = fallback or cands
                    end
                end
            end
        end
    end
    return fallback
end

-- v1.3.5 (F1b): moegirl fullpage safety. Core's fullpage layout is fixed
-- [Save as EPUB][Close]; the Save button calls Wikipedia:createEpubWithUI
-- with the window's lang, which for moegirl would fetch from
-- {lang}.wikipedia.org — the wrong site. Strip the save button from moegirl
-- fullpage windows (keep [Close]) so immersive reading survives without a
-- misleading archive action. Pure function so tests pin the layout contract.
function DualWiki:_stripSaveFromFullpageLayout(layout)
    if type(layout) ~= "table" then return layout end
    for r = #layout, 1, -1 do
        local row = layout[r]
        if type(row) == "table" then
            for b = #row, 1, -1 do
                local btn = row[b]
                if type(btn) == "table" and btn.id == "save" then
                    table.remove(row, b)
                end
            end
            if #row == 0 then table.remove(layout, r) end
        end
    end
    return layout
end

-- v1.3.5 (F1b): class-level hook into the fullpage button-layout build.
-- Only touches Dual Wiki moegirl fullpage windows; wikipedia and native
-- windows keep core's exact [Save as EPUB][Close] bar.
function DualWiki:_patchFullpageLayout()
    if DictQuickLookup._dualwiki_fullpage_layout_patched then return end
    DictQuickLookup._dualwiki_fullpage_layout_patched = true
    local orig_bbl = DictQuickLookup.buildButtonLayout
    DictQuickLookup.buildButtonLayout = function(dql_self)
        local layout = orig_bbl and orig_bbl(dql_self) or nil
        local dw = dql_self.ui and dql_self.ui.dual_wiki
        if layout and dw and dw._stripSaveFromFullpageLayout
            and dql_self.dualwiki_engine == "moegirl"
            and dql_self.is_wiki_fullpage then
            layout = dw:_stripSaveFromFullpageLayout(layout)
        end
        return layout
    end
end

-- v1.3.5 (F2): native-takeover gate, default ON. When OFF, Dual Wiki
-- completely steps aside: core ReaderWikipedia keeps its menu entries, its
-- highlight button (auto-replaced "Wikipedia"/"Full article"), and the
-- native fullscreen + Save-as-EPUB channel.
function DualWiki:_takeoverEnabled()
    return G_reader_settings == nil or not G_reader_settings:isTrue("dualwiki_no_takeover")
end

-- v1.3.3 (A3): a one-tap button that re-queries the spelling suggestion
-- MediaWiki returned on the failed round (captured in fetchCandidates,
-- cleared at each lookup start). NOTE: deliberately does NOT close any
-- dialog itself — the button table is not a widget; showRetryDialog wraps
-- this callback to close the real InputDialog first (a previous version
-- closed the button table via an identically-named local, leaving the
-- retry dialog open underneath the result window).
function DualWiki:_retrySuggestionButton(suggestion, engine, word_boxes, lang)
    return {
        text = T(_("Try \"%1\""), suggestion),
        callback = function()
            self:lookup(suggestion, engine, word_boxes, lang)
        end,
    }
end

function DualWiki:showRetryDialog(failed_word, engine, word_boxes, lang)
    local cfg = ENGINES[engine]
    if not cfg then return end
    local target = cfg.switchTarget and cfg.switchTarget()
    local target_cfg = target and ENGINES[target]
    -- v1.2.2 fix: normalize the language for BOTH the switch button label and
    -- the actual re-lookup, so the label and the query never disagree about
    -- which wiki serves the retry.
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

    -- v1.3.3 (A3): "did you mean" — a MediaWiki spelling suggestion rides
    -- the failed round; offer a one-tap re-query. Cleared on read so a stale
    -- suggestion never resurfaces for a later, unrelated failure.
    local suggestion = self._last_suggestion
    self._last_suggestion = nil
    if suggestion and suggestion ~= failed_word
        and caseFold(suggestion) ~= caseFold(failed_word) then
        local hint = T(_("Did you mean: %1?"), suggestion)
        error_description = error_description
            and (error_description .. LF .. hint) or hint
    end

    local retry_dialog
    local buttons = { {} }
    if suggestion and suggestion ~= failed_word
        and caseFold(suggestion) ~= caseFold(failed_word) then
        local suggestion_btn = self:_retrySuggestionButton(suggestion, engine, word_boxes, lang)
        local suggestion_lookup = suggestion_btn.callback
        suggestion_btn.callback = function()
            UIManager:close(retry_dialog)
            suggestion_lookup()
        end
        buttons[1] = { suggestion_btn }
    end
    table.insert(buttons, {
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
    })
    retry_dialog = InputDialog:new{
        title = string.format("%s · %s", cfg.label(lang), _("Not found, modify and retry:")),
        description = error_description,
        input = failed_word,
        input_type = "text",
        buttons = buttons,
    }
    UIManager:show(retry_dialog)
    retry_dialog:onShowKeyboard()
end

-- v1.3.3 (E7): test surface. httpGet is a file-local; the integration
-- harness needs the SAME entry point the plugin uses (keepalive on/off
-- toggling must affect it). Prefixed with _ so it never reads as API.
DualWiki._httpGet = httpGet
DualWiki._keepalive = keepalive

return DualWiki