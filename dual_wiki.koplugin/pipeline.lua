-- pipeline.lua — Dual Wiki network / candidate pipeline (side-effect boundary)
-- Extracted from main.lua 2399-line god file. Zero UI deps beyond DualWiki instance (self).
-- Helpers are pure (helpers.lua); keepalive is 428-line pooled TLS.

local JSON = require("json")
local http = require("socket.http")
local https = require("ssl.https")
local socket = require("socket")
local socketutil = require("socketutil")
local socket_url = require("socket.url")
local logger = require("logger")
local keepalive = require("keepalive")

local H = require("helpers")
local sanitizeQuery = H.sanitizeQuery
local stripTrailingParticle = H.stripTrailingParticle
local routeLangForScript = H.routeLangForScript
local hasGoodHit = H.hasGoodHit
local sharesPrefix = H.sharesPrefix
local sharesPrefixAny = H.sharesPrefixAny
local parseCandidatePages = H.parseCandidatePages
local normalizeLang = H.normalizeLang -- luacheck: ignore 211
local zhVariantOf = H.zhVariantOf
local caseFold = H.caseFold
local utf8Len = H.utf8Len
local PARTICLES = H.PARTICLES
-- luacheck: push ignore 211
local LANG_MAP = H.LANG_MAP

local LF = string.char(10)
local MAX_RESPONSE_BYTES = 2 * 1024 * 1024
-- luacheck: pop
local PLUGIN_VERSION = "1.3.6"
local USER_AGENT = "dual_wiki.koplugin/" .. PLUGIN_VERSION .. " (KOReader)"
local MAX_CANDIDATES = 4
local MAX_SEARCH_CANDIDATES = 8
local PROBE_TIMEOUT = 10
local DIRECT_TIMEOUT = 12
local MOEGIRL_TIMEOUT = 5

local ENGINES = {
    wikipedia = {
        api = function(lang)
            return string.format("https://%s.wikipedia.org/w/api.php", lang or "zh")
        end,
        label = function(lang)
            local _ = require("gettext")
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
            local _ = require("gettext")
            return _("Moegirlpedia")
        end,
        needsConverttitles = function() return false end,
        particleLang = function(lang) return lang or "zh" end,
        switchTarget = function() return "wikipedia" end,
    },
}

local HTTP_RETRY_BACKOFF_S = 2
local HTTP_RETRY_CAP_S = 5
local HTTP_RETRIES = 1

keepalive.enabled = os.getenv("DUALWIKI_NO_KEEPALIVE") == nil

local function httpGetOnce(url, timeout)
    local ka_ok, ka_body, ka_kind, _, ka_headers = keepalive.request(
        url, timeout or 6, MAX_RESPONSE_BYTES, USER_AGENT)
    if ka_ok == true then
        return true, ka_body
    end
    if ka_ok == false then
        return false, ka_kind or "error", nil, ka_headers
    end
    local transport = socket_url.parse(url).scheme == "https" and https or http
    socketutil:set_timeout(timeout or 6, 12)
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

local function cleanWikiExtract(text)
    if not text then return "" end
    text = text:gsub("===+ *(.-) *===+", LF .. LF .. "▸ %1" .. LF)
    text = text:gsub("== *(.-) *==", LF .. LF .. "【%1】" .. LF)
    text = text:gsub("<[^>]+>", "")
    text = text:gsub(LF .. LF .. LF .. "+", LF .. LF)
    text = text:match("^%s*(.-)%s*$") or text
    return text
end

local function buildApiURL(engine, lang, params)
    local cfg = ENGINES[engine]
    if not cfg then return nil end
    return cfg.api(lang) .. "?action=query" .. params
end

local function fetchCandidates(self, q, engine, lang, mode)
    local esc_q = socket_url.escape(q)
    local params
    if mode == "search" then
        params = string.format("&generator=search&gsrsearch=%s&gsrlimit=%d&gsrinfo=suggestion",
            esc_q, MAX_SEARCH_CANDIDATES)
    else
        params = string.format("&generator=prefixsearch&gpssearch=%s&gpslimit=%d", esc_q, MAX_CANDIDATES)
    end
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
    if mode == "search" and type(data.query) == "table" and type(data.query.searchinfo) == "table" then
        self._last_suggestion = type(data.query.searchinfo.suggestion) == "string"
            and data.query.searchinfo.suggestion or nil
    end
    if not data.query or type(data.query.pages) ~= "table" then
        return nil
    end
    return parseCandidatePages(data, q)
end

local function fetchDisambiguationItems(self, dab_title, engine, lang)
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
        if #titles >= 10 then break end
        local s = line:match("^%*+%s*(.*)$")
        if not s or s == "" then
            if #titles > 0 then break end
        else
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
                        missing[caseFold(page.title)] = true
                    elseif type(page.extract) == "string" then
                        extracts[caseFold(page.title)] = page.extract
                    end
                end
            end
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
    for _, t in ipairs(titles) do
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

local function expandDisambiguation(self, cands, engine, lang)
    if type(cands) ~= "table" or not cands[1] or not cands[1].dab then
        return cands
    end
    local items = self:fetchDisambiguationItems(cands[1].title, engine, lang)
    if type(items) == "table" and #items > 0 then
        return items
    end
    return cands
end

local function augmentLangLinks(self, cands, engine, lang)
    if type(cands) ~= "table" or #cands == 0 then return cands end
    if engine ~= "wikipedia" then return cands end
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
    if not linked or caseFold(linked) == caseFold(cands[1].title) then
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

local function fetchDirect(self, word, engine, lang)
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

local function _expandAllFullText(self, cands, engine, lang)
    if type(cands) ~= "table" or #cands == 0 then return cands, false end
    local cand = cands[1]
    local fetch_engine = engine
    local fetch_lang = lang
    if cand.langlink_lang then
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

local function fetchDirectAndShow(self, word, engine, lang, word_boxes)
    local cands = self:fetchDirect(word, engine, lang)
    if cands then
        self:showResult(word, cands, engine, word_boxes, lang, true)
    else
        self:showRetryDialog(word, engine, word_boxes, lang)
    end
end

local ERROR_HINTS = {
    http_429    = "Rate limited by the wiki server. Wait a minute and retry.",
    http_4xx    = "The wiki server rejected the request.",
    http_5xx    = "The wiki server is having trouble. Retry later.",
    timeout     = "The request timed out.",
    error       = "The site may be unreachable or blocked on this network.",
    too_large   = "The article is too large to display on this device.",
}

local function queryPipeline(self, word, engine, lang)
    local q0 = sanitizeQuery(word)
    if q0 == "" then q0 = word end
    if engine == "wikipedia" and lang == "zh" and not self:_isLangLocked() then
        local routed = routeLangForScript(q0)
        if routed then
            lang = routed
        end
    end
    local plang = ENGINES[engine] and ENGINES[engine].particleLang(lang) or "zh"
    local q2 = stripTrailingParticle(q0, plang)
    local q_number_stripped = nil
    do
        local head = q0:match("^(.-)%s+%d+[%d%.]*%s*$")
        if head and utf8Len(head) >= 2 then
            q_number_stripped = head
        end
    end
    local q_spaced_particle = nil
    do
        local head = q0:match("^(.-)%s+[" .. table.concat(PARTICLES[plang] or PARTICLES.zh) .. "]%s*$")
        if head and utf8Len(head) >= 2 then
            q_spaced_particle = head
        end
    end
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
    local r2 = nil
    if q2 ~= q0 and utf8Len(q2) >= 2 and not self._moegirl_unreachable then
        r2 = self:fetchCandidates(q2, engine, lang, "prefix")
        if hasGoodHit(r2, q2, plang) then
            return self:expandDisambiguation(r2, engine, lang), false, lang
        end
    end
    for _, alt in ipairs({ q_spaced_particle, q_number_stripped }) do
        if alt and alt ~= q0 and alt ~= q2 and utf8Len(alt) >= 2 and not self._moegirl_unreachable then
            local r_alt = self:fetchCandidates(alt, engine, lang, "prefix")
            if hasGoodHit(r_alt, alt, plang) then
                return self:expandDisambiguation(r_alt, engine, lang), false, lang
            end
        end
    end
    if engine == "wikipedia" and lang == "zh" and q0:match("^[%a%s%-%d%p]+$") then
        return self:queryPipeline(word, engine, "en")
    end
    if r1 and r1[1] and #(r1[1].extract or "") >= 60
        and sharesPrefix(r1[1].title, q0, plang) then
        return self:expandDisambiguation(r1, engine, lang), false, lang
    end
    local s = nil
    if not self._moegirl_unreachable then
        s = self:fetchCandidates(q0, engine, lang, "search")
    end
    if s and #s > 0 and sharesPrefixAny(s, q2 ~= q0 and q2 or q0, plang) then
        return self:expandDisambiguation(s, engine, lang), false, lang
    end
    if engine == "moegirl" then
        local fallback_lang = (lang == "ja") and "ja" or "zh"
        if lang == "ja" or self._moegirl_unreachable then
            local fallback, _, fallback_used_lang = self:queryPipeline(word, "wikipedia", fallback_lang)
            if fallback and #fallback > 0 then
                return fallback, false, fallback_used_lang or fallback_lang
            end
        end
    end
    if r1 and #r1 > 0 then
        return self:expandDisambiguation(r1, engine, lang), false, lang
    end
    if r2 and #r2 > 0 then
        return self:expandDisambiguation(r2, engine, lang), false, lang
    end
    return nil, false, lang
end

return {
    ENGINES = ENGINES,
    keepalive = keepalive,
    httpGet = httpGet,
    httpGetOnce = httpGetOnce,
    cleanWikiExtract = cleanWikiExtract,
    buildApiURL = buildApiURL,
    fetchCandidates = fetchCandidates,
    fetchDisambiguationItems = fetchDisambiguationItems,
    expandDisambiguation = expandDisambiguation,
    augmentLangLinks = augmentLangLinks,
    fetchDirect = fetchDirect,
    _expandAllFullText = _expandAllFullText,
    fetchDirectAndShow = fetchDirectAndShow,
    queryPipeline = queryPipeline,
    ERROR_HINTS = ERROR_HINTS,
    MAX_CANDIDATES = MAX_CANDIDATES,
    MAX_SEARCH_CANDIDATES = MAX_SEARCH_CANDIDATES,
    PROBE_TIMEOUT = PROBE_TIMEOUT,
    DIRECT_TIMEOUT = DIRECT_TIMEOUT,
    MOEGIRL_TIMEOUT = MOEGIRL_TIMEOUT,
    MAX_RESPONSE_BYTES = MAX_RESPONSE_BYTES,
    USER_AGENT = USER_AGENT,
    PLUGIN_VERSION = PLUGIN_VERSION,
    LF = LF,
}
