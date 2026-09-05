--[[--
Dual-Engine Encyclopedia (Moegirlpedia + Wikipedia) Plugin for KOReader.

v1.1.0 — Fuzzy-Tolerant Retrieval Architecture (Plan A):

1. Local query sanitation (0ms): strips outer CJK/ASCII wrapper brackets
   (《》“”【】（） etc.) and zero-width noise, never touching in-word
   punctuation (Re:…, Fate/stay night, 拿破仑·波拿巴 stay intact).
2. Single-round-trip candidate pipeline: one merged MediaWiki request
   (generator=prefixsearch + prop=extracts, intro mode) returns up to 4
   ranked candidates *with readable summaries* — no second handshake on
   the happy path, even on 2.4GHz Kindle Wi-Fi.
3. Graceful degradation ladder: prefix(q) → prefix(q minus one trailing
   particle) → generator=search full-text fallback → retry dialog.
4. On-demand full article: confirm the same word via the pencil icon to
   upgrade the summary to the uncapped full extract (single request).
5. Traditional/Simplified Chinese alignment via server-side
   converttitles=1 (no local conversion tables).

Enables seamless online search and definition lookup of:
1. ACG / Anime terms from Moegirlpedia (zh.moegirl.org.cn)
2. General knowledge, science, and history from Wikipedia (zh/ja/en.wikipedia.org)
using native KOReader UI widgets, book-grade formatting, sub-second
plain-text queries, and zero-hang offline handling.
--]]--

local DictQuickLookup = require("ui/widget/dictquicklookup")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local NetworkMgr = require("ui/network/manager")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local JSON = require("json")
local http = require("socket.http")
local ltn12 = require("ltn12")
local socket = require("socket")
local socketutil = require("socketutil")
local socket_url = require("socket.url")
local util = require("util")
local logger = require("logger")
local _ = require("gettext")

local DualWiki = WidgetContainer:extend{
    name = "dual_wiki",
    is_doc_only = false,
}

-- API endpoints
local MOEGIRL_BASE = "https://zh.moegirl.org.cn/api.php"

-- Safe linefeed character constant
local LF = string.char(10)

-- (capped at 2MB: a 512MB e-ink device cannot afford unbounded remote bodies)
local MAX_RESPONSE_BYTES = 2 * 1024 * 1024

-- Retrieval pipeline tuning
local MAX_CANDIDATES = 4      -- candidates per merged request (server clamps full-text extracts to 1/page, intro mode allows all)
local PROBE_TIMEOUT = 10      -- merged probe request timeout (seconds)
local DIRECT_TIMEOUT = 12     -- full-article request timeout (seconds)

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

-- A "good hit" is an exact match, or a title that is only slightly longer
-- than the query while sharing its full prefix (小笠原道 → 小笠原道大).
-- Long prefix-noise titles (量子力学的 → 量子力学的数学基础) do NOT qualify,
-- so the pipeline keeps degrading to the particle-stripped query.
local function hasGoodHit(cands, q)
    if not cands then return false end
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

-- Zero-width noise: U+200B/200C/200D (UTF-8: E2 80 8B/8C/8D) and U+FEFF (EF BB BF)
local ZERO_WIDTH = { "\226\128\139", "\226\128\140", "\226\128\141", "\239\187\191" }

-- Wrapper brackets eligible for stripping. CJK only for unmatched-side
-- stripping: ASCII ( ) " ' are legal in-word characters ((G)I-DLE, 1") and
-- must never be touched.
local OPEN_WRAPPERS = { ["《"] = "》", ["「"] = "」", ["『"] = "』", ["【"] = "】", ["［"] = "］", ["（"] = "）", ["〈"] = "〉", ["〔"] = "〕", ["“"] = "”", ["‘"] = "’", ["«"] = "»" }
local CLOSE_WRAPPERS = { ["》"] = true, ["」"] = true, ["』"] = true, ["】"] = true, ["］"] = true, ["）"] = true, ["〉"] = true, ["〕"] = true, ["”"] = true, ["’"] = true, ["»"] = true }

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

-- Stage-2 sanitation: drop ONE trailing Chinese particle (的地得了着过等中下里上),
-- only as a fallback after the exact query missed. Byte-exact comparison (no
-- Lua byte-class patterns) prevents false hits inside other CJK characters.
local TRAILING_PARTICLES = { "的", "地", "得", "了", "着", "过", "等", "中", "下", "里", "上", "之" }
local function stripTrailingParticle(q)
    if q == "" or utf8Len(q) <= 2 then return q end
    local tail = utf8Last(q)
    for _, p in ipairs(TRAILING_PARTICLES) do
        if tail == p then
            return q:sub(1, #q - #p)
        end
    end
    return q
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

-- A "good hit" is an exact match, or a title that is only slightly longer
-- than the query while sharing its full prefix (小笠原道 → 小笠原道大).
-- Long prefix-noise titles (量子力学的 → 量子力学的数学基础) do NOT qualify,
-- so the pipeline keeps degrading to the particle-stripped query.
local function hasGoodHit(cands, q)
    if not cands then return false end
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

-- [[ query-helpers:end ]]

-- Helper to make fast HTTP GET request
local function httpGet(url, timeout)
    socketutil:set_timeout(timeout or 6, 12)
    local sink = {}
    local request = {
        url = url,
        method = "GET",
        headers = {
            ["User-Agent"] = "KOReader/2024.04 (Kindle)",
            ["Accept"] = "application/json",
        },
        sink = ltn12.sink.table(sink),
    }
    local code, headers, status = socket.skip(1, http.request(request))
    socketutil:reset_timeout()
    local content = table.concat(sink)
    if code and code >= 200 and code < 300 and content and #content > 0 then
        if #content > MAX_RESPONSE_BYTES then
            return false, "Response too large"
        end
        return true, content
    end
    return false, status or code or "Network error"
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
    if engine == "moegirl" then
        return MOEGIRL_BASE .. "?action=query" .. params
    end
    return string.format("https://%s.wikipedia.org/w/api.php?action=query", lang or "zh") .. params
end

function DualWiki:init()
    if self.ui and self.ui.highlight then
        self:_registerHighlightButtons()
    end
    if self.ui and self.ui.menu then
        self.ui.menu:registerToMainMenu(self)
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

    -- 1. Register Moegirlpedia (ACG, Anime, Gaming, Subcultures)
    highlight:addToHighlightDialog("05_a_dualwiki_moegirl", function(hl)
        return {
            text = "萌娘百科",
            show_in_highlight_dialog_func = function()
                return hl.selected_text ~= nil
            end,
            callback = function()
                local word = util.cleanupSelectedText(hl.selected_text.text)
                if not word or word == "" then return end
                local word_boxes = hl:getHighlightVisibleBoxes() or (hl.selected_text.sboxes or hl.selected_text.pboxes)
                UIManager:scheduleIn(0.1, function()
                    self:lookup(word, "moegirl", word_boxes)
                end)
            end,
        }
    end)

    -- 2. Register Modern Wikipedia (General Knowledge, Science, History)
    highlight:addToHighlightDialog("05_b_dualwiki_wikipedia", function(hl)
        return {
            text = "维基百科",
            show_in_highlight_dialog_func = function()
                return hl.selected_text ~= nil
            end,
            callback = function()
                local word = util.cleanupSelectedText(hl.selected_text.text)
                if not word or word == "" then return end
                local word_boxes = hl:getHighlightVisibleBoxes() or (hl.selected_text.sboxes or hl.selected_text.pboxes)
                UIManager:scheduleIn(0.1, function()
                    self:lookup(word, "wikipedia", word_boxes)
                end)
            end,
        }
    end)
end

function DualWiki:addToMainMenu(menu_items)
    menu_items.dualwiki_moegirl = {
        text = "萌娘百科查询",
        sorting_hint = "search",
        callback = function()
            self:showSearchDialog("moegirl")
        end,
    }
    menu_items.dualwiki_wikipedia = {
        text = "维基百科查询",
        sorting_hint = "search",
        callback = function()
            self:showSearchDialog("wikipedia")
        end,
    }
end

function DualWiki:showSearchDialog(engine, initial_query, word_boxes, lang)
    local is_wiki = (engine == "wikipedia")
    local title = is_wiki and "维基百科词条查询" or "萌娘百科词条查询"
    local input_dialog
    input_dialog = InputDialog:new{
        title = title,
        input = initial_query or "",
        input_type = "text",
        buttons = {
            {
                {
                    text = "取消",
                    id = "close",
                    callback = function()
                        UIManager:close(input_dialog)
                    end,
                },
                {
                    text = "查询",
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
-- mode: "prefix" (generator=prefixsearch) or "search" (generator=search).
function DualWiki:fetchCandidates(q, engine, lang, mode)
    local esc_q = socket_url.escape(q)
    local params
    if mode == "search" then
        params = string.format("&generator=search&gsrsearch=%s&gsrlimit=%d", esc_q, MAX_CANDIDATES)
    else
        params = string.format("&generator=prefixsearch&gpssearch=%s&gpslimit=%d", esc_q, MAX_CANDIDATES)
    end
    params = params
        .. "&prop=extracts&explaintext=1&exintro=1&exlimit=" .. MAX_CANDIDATES
        .. "&redirects=1&format=json&formatversion=2"
    if engine == "wikipedia" and (lang or "zh") == "zh" then
        params = params .. "&converttitles=1"
    end

    local url = buildApiURL(engine, lang, params)
    local ok, body = httpGet(url, PROBE_TIMEOUT)
    if not ok or not body then
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
    if engine == "wikipedia" and (lang or "zh") == "zh" then
        params = params .. "&converttitles=1"
    end

    local url = buildApiURL(engine, lang, params)
    local ok, body = httpGet(url, DIRECT_TIMEOUT)
    if not ok or not body then
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

-- Degradation ladder (each step is a single merged request):
--   1. prefixsearch(sanitized query)
--   2. prefixsearch(query minus ONE trailing particle)
--   3. generator=search full-text fallback
--   4. en.wikipedia retry for pure-Latin queries on zh
function DualWiki:queryPipeline(word, engine, lang)
    local q0 = sanitizeQuery(word)
    if q0 == "" then q0 = word end
    local q2 = stripTrailingParticle(q0)

    -- Stage 1: merged prefixsearch probe (up to 4 ranked candidates).
    local r1 = self:fetchCandidates(q0, engine, lang, "prefix")
    if hasGoodHit(r1, q0) then
        return r1, false
    end

    -- Stage 2: trailing-particle drop retry (量子力学的 → 量子力学).
    local r2 = nil
    if q2 ~= q0 and utf8Len(q2) >= 2 then
        r2 = self:fetchCandidates(q2, engine, lang, "prefix")
        if hasGoodHit(r2, q2) then
            return r2, false
        end
    end

    -- Stage 3: English fallback for pure-Latin queries on zh.
    if engine == "wikipedia" and lang == "zh" and q0:match("^[%a%s%-%d%p]+$") then
        return self:queryPipeline(word, engine, "en")
    end

    -- Stage 4: the top candidate carries real content even without a crisp
    -- prefix match (server-side redirect targets: (G)I-DLE → I-dle,
    -- 拿破仑·波拿巴 → 拿破仑一世). Accept it and stop.
    if r1 and r1[1] and #(r1[1].extract or "") >= 60 then
        return r1, false
    end

    -- Stage 5: full-text search fallback (catches dab-page tops like
    -- 三体 → 三體 with no content, where search resolves 三体 (小说)).
    local s = self:fetchCandidates(q0, engine, lang, "search")
    if s and #s > 0 then
        return s, false
    end

    -- Stage 6: surface whatever prefix noise we had (better than nothing).
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

    if NetworkMgr:willRerunWhenOnline(function()
        self:lookup(word, engine, word_boxes, lang, want_full)
    end) then
        return
    end

    local is_wiki = (engine == "wikipedia")
    lang = lang or "zh"
    local prompt_title = is_wiki and string.format("正在快速查询维基百科 (%s):" .. LF .. "%s", lang:upper(), word)
                                 or ("正在快速查询萌娘百科:" .. LF .. word)

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
                return self:fetchDirect(word, engine, lang), true
            end
            local result, full_flag = self:queryPipeline(word, engine, lang)
            return result, full_flag
        end)

        UIManager:close(progress_info)

        if ok and type(cands) == "table" and #cands > 0 then
            self:showResult(word, cands, engine, word_boxes, lang, want_full or is_full)
        else
            self:showRetryDialog(word, engine, word_boxes, lang)
        end
    end)
end

function DualWiki:showResult(word, cands, engine, word_boxes, lang, is_full)
    local self_ref = self
    local is_moegirl = (engine == "moegirl")
    local dict_name = is_moegirl and "萌娘百科" or string.format("维基百科 (%s)", (lang or "ZH"):upper())

    self._last_candidate_titles = {}
    self._last_was_full = is_full and true or false

    local results = {}
    for i, cand in ipairs(cands) do
        self._last_candidate_titles[cand.title] = true
        local definition
        if cand.extract and #cand.extract > 0 then
            definition = cleanWikiExtract(cand.extract)
        else
            definition = "（前缀候选：暂无内容摘要。长按右上角铅笔图标可编辑并载入本词条完整正文。）"
        end
        results[i] = {
            word = cand.title,
            definition = definition,
            dictionary = dict_name,
            lang = lang or "zh",
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
    local is_wiki = (engine == "wikipedia")
    local title = is_wiki and "维基百科未找到，可修改微调重试：" or "萌娘百科未找到，可修改微调重试："
    local switch_btn_text = is_wiki and "换查【萌娘百科】" or "换查【维基百科】"

    local retry_dialog
    retry_dialog = InputDialog:new{
        title = title,
        input = failed_word,
        input_type = "text",
        buttons = {
            {
                {
                    text = "取消",
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
                            if is_wiki then
                                self:lookup(query, "moegirl", word_boxes)
                            else
                                self:lookup(query, "wikipedia", word_boxes)
                            end
                        end
                    end,
                },
                {
                    text = "重新查询",
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
