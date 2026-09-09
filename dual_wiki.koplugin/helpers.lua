-- helpers.lua — Dual Wiki pure helpers (zero KOReader deps, Lua 5.1 safe)
-- Mirrors the -- [[ query-helpers:start/end ]] block from main.lua verbatim
-- so both `lua tests/test_query_helpers.lua dual_wiki.koplugin/helpers.lua`
-- and the legacy `.../main.lua` extraction path stay green.

-- [[ query-helpers:start ]] (pure functions, unit-testable in isolation)

local function strTrim(s)
    return (s or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

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

local ZERO_WIDTH = { "\226\128\139", "\226\128\140", "\226\128\141", "\239\187\191" }

local OPEN_WRAPPERS = {
    ["《"] = "》", ["「"] = "」", ["『"] = "』", ["【"] = "】", ["［"] = "］",
    ["（"] = "）", ["〈"] = "〉", ["〔"] = "〕", ["“"] = "”", ["‘"] = "’", ["«"] = "»",
}
local CLOSE_WRAPPERS = {
    ["》"] = true, ["」"] = true, ["』"] = true, ["】"] = true, ["］"] = true,
    ["）"] = true, ["〉"] = true, ["〕"] = true, ["”"] = true, ["’"] = true, ["»"] = true,
}

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

local LATIN_LANGS = { en = true, de = true, fr = true, es = true, ru = true }

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
    for _, c in ipairs(cands) do
        if c.dab and c.title == q then
            return true
        end
    end
    return false
end

local function sharesPrefix(title, q, lang)
    if not title or not q or title == "" or q == "" then return false end
    if LATIN_LANGS[lang] then
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

local ZH_HANT_SCRIPTS = { HANT = true, TW = true, HK = true, MO = true }
local ZH_HANS_SCRIPTS = { HANS = true, CN = true, SG = true, MY = true }
local function zhVariantOf(raw)
    local script = tostring(raw or ""):upper():match("^ZH[_%-]?(%a*)")
    if ZH_HANT_SCRIPTS[script] then return "zh-hant" end
    if ZH_HANS_SCRIPTS[script] then return "zh-cn" end
    return "zh-cn"
end

-- [[ query-helpers:end ]]

return {
    strTrim = strTrim,
    utf8Len = utf8Len,
    utf8First = utf8First,
    utf8Last = utf8Last,
    utf8Chop = utf8Chop,
    utf8Decode = utf8Decode,
    utf8Encode = utf8Encode,
    caseFold = caseFold,
    sanitizeQuery = sanitizeQuery,
    stripTrailingParticle = stripTrailingParticle,
    routeLangForScript = routeLangForScript,
    hasGoodHit = hasGoodHit,
    sharesPrefix = sharesPrefix,
    sharesPrefixAny = sharesPrefixAny,
    parseCandidatePages = parseCandidatePages,
    normalizeLang = normalizeLang,
    zhVariantOf = zhVariantOf,
    ZERO_WIDTH = ZERO_WIDTH,
    OPEN_WRAPPERS = OPEN_WRAPPERS,
    CLOSE_WRAPPERS = CLOSE_WRAPPERS,
    PARTICLES = PARTICLES,
    LATIN_LANGS = LATIN_LANGS,
    LANG_MAP = LANG_MAP,
    ZH_HANT_SCRIPTS = ZH_HANT_SCRIPTS,
    ZH_HANS_SCRIPTS = ZH_HANS_SCRIPTS,
}
