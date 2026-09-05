-- Unit tests: extract pure query helpers from main.lua and run the Plan A
-- matrix (zh) plus Phase 2.1 cross-language cases (ja/en), mishit guards,
-- and the v1.3.0 Phase 2.2 language-map extension.
--
-- Run:  lua tests/test_query_helpers.lua dual_wiki.koplugin/main.lua
-- (arg defaults to dual_wiki.koplugin/main.lua)

local src_path = arg and arg[1] or "dual_wiki.koplugin/main.lua"
local f = io.open(src_path, "r")
if not f then io.stderr:write("cannot open " .. src_path .. "\n") os.exit(1) end
local src = f:read("*a")
f:close()

local hstart = src:find("%-%- %[%[ query%-helpers:start %]%]")
local hend = src:find("%-%- %[%[ query%-helpers:end %]%]")
assert(hstart and hend, "helper markers not found")
local helpers = src:sub(hstart, hend - 1)

-- Lua 5.1's load() only accepts a function; loadstring() accepts a string.
-- LuaJIT (KOReader's runtime) accepts both via load().
local loadchunk = loadstring or load
local chunk = assert(loadchunk(helpers .. [[
return {
    sanitizeQuery = sanitizeQuery,
    stripTrailingParticle = stripTrailingParticle,
    hasGoodHit = hasGoodHit,
    parseCandidatePages = parseCandidatePages,
    normalizeLang = normalizeLang,
    zhVariantOf = zhVariantOf,
    utf8Len = utf8Len,
    strTrim = strTrim,
}
]], "helpers"))
local api = chunk()

local failures = 0
local function check(name, got, want)
    if got == want then
        print(string.format("PASS  %-40s got=%q", name, tostring(got)))
    else
        print(string.format("FAIL  %-40s got=%q want=%q", name, tostring(got), tostring(want)))
        failures = failures + 1
    end
end

print("== Phase 1 (zh) sanitation matrix ==")
check("1 书名号 《三体》", api.sanitizeQuery("《三体》"), "三体")
check("2 中文引号 “人工智能”", api.sanitizeQuery("“人工智能”"), "人工智能")
check("3 方括号 【凉宫春日的忧郁】", api.sanitizeQuery("【凉宫春日的忧郁】"), "凉宫春日的忧郁")
check("4 zh 助词剥离 量子力学的", api.stripTrailingParticle("量子力学的", "zh"), "量子力学")
check("5 间隔号保留", api.sanitizeQuery("拿破仑·波拿巴"), "拿破仑·波拿巴")
check("6 冒号保留 Re:从零…", api.sanitizeQuery("Re:从零开始的异世界生活"), "Re:从零开始的异世界生活")
check("7 少选一字 小笠原道", api.sanitizeQuery("小笠原道"), "小笠原道")
check("8 斜杠保留 Fate/stay night", api.sanitizeQuery("Fate/stay night"), "Fate/stay night")
check("9 繁体 魔戒", api.sanitizeQuery("魔戒"), "魔戒")
check("10 宽泛词 黑神话", api.sanitizeQuery("黑神话"), "黑神话")

print("== Phase 2.1 cross-language (协同改进项 1/2) ==")
check("J1 ja 引号 『…』", api.sanitizeQuery("『涼宮ハルヒの憂鬱』"), "涼宮ハルヒの憂鬱")
check("J2 ja 助词 の シャナの", api.stripTrailingParticle("シャナの", "ja"), "シャナ")
check("J3 ja 助词 の 長門有希の", api.stripTrailingParticle("長門有希の", "ja"), "長門有希")
check("J4 ja 助词 に", api.stripTrailingParticle("商店に", "ja"), "商店")
check("J5 ja 非助词尾不动 エヴァンゲリオン", api.stripTrailingParticle("新世紀エヴァンゲリオン", "ja"), "新世紀エヴァンゲリオン")
check("E1 en 引号剥离", api.sanitizeQuery("“Quantum mechanics”"), "Quantum mechanics")
check("E2 en 所有格 's", api.stripTrailingParticle("Oppenheimer's", "en"), "Oppenheimer")
check("E3 en curly 所有格", api.stripTrailingParticle("Oppenheimer\226\128\153s", "en"), "Oppenheimer")
check("E4 en 复数s 不剥离 physics", api.stripTrailingParticle("physics", "en"), "physics")
check("E5 en 复数s 不剥离 mechanics", api.stripTrailingParticle("mechanics", "en"), "mechanics")
check("E6 zh 表在 en 语境不误伤", api.stripTrailingParticle("魔法少女", "en"), "魔法少女")

print("== hasGoodHit (语言感知) ==")
local mk = function(...)
    local t = {}
    for _, title in ipairs({...}) do t[#t + 1] = { title = title, extract = "x", index = 1 } end
    return t
end
check("G1 zh 精确命中", api.hasGoodHit(mk("人工智能", "人工智能 (电影)"), "人工智能", "zh"), true)
check("G2 zh 前缀+1", api.hasGoodHit(mk("小笠原道大", "小笠原村"), "小笠原道", "zh"), true)
check("G3 zh 前缀噪音太长", api.hasGoodHit(mk("量子力学的数学基础"), "量子力学的", "zh"), false)
check("G4 ja 前缀+1", api.hasGoodHit(mk("涼宮ハルヒの憂鬱 (アニメ)", "涼宮ハルヒ"), "涼宮ハルヒ", "ja"), true)
check("L1 en 精确(大小写不敏感)", api.hasGoodHit(mk("Quantum mechanics"), "quantum mechanics", "en"), true)
check("L2 en 词边界 quantum→Quantum mechanics", api.hasGoodHit(mk("Quantum mechanics", "Quantum Leap"), "quantum", "en"), true)
check("L3 en 词边界 禁止量子前缀误伤", api.hasGoodHit(mk("Quantum Entanglement", "Quantum Leap"), "quantum ent", "en"), false)
check("L4 en 词边界 wookieepedia 不被 wo 命中", api.hasGoodHit(mk("Wookieepedia"), "wo", "en"), false)
check("L5 en 词边界 jedi", api.hasGoodHit(mk("Jedi", "Jedi Council"), "jedi", "en"), true)
check("L6 en 词边界 Jedi Purge 合法命中", api.hasGoodHit(mk("Jedi Purge"), "jedi", "en"), true)
check("L6b en 词边界 无空格不命中", api.hasGoodHit(mk("JediCouncil"), "jedi", "en"), false)
check("L7 en 精确 (G)I-DLE", api.hasGoodHit(mk("(G)I-DLE", "I-dle"), "(g)i-dle", "en"), true)

print("== normalizeLang (书籍语种探测) ==")
check("N1 zh-CN", api.normalizeLang("zh-CN"), "zh")
check("N2 zh_TW", api.normalizeLang("zh_TW"), "zh")
check("N3 en-US", api.normalizeLang("en-US"), "en")
check("N4 eng (ISO-639-2)", api.normalizeLang("eng"), "en")
check("N5 ja", api.normalizeLang("ja"), "ja")
check("N6 jpn", api.normalizeLang("jpn"), "ja")
check("N7 de-DE (v1.3.0 欧洲语)", api.normalizeLang("de-DE"), "de")
check("N7b spa→es", api.normalizeLang("spa"), "es")
check("N7c 未知语仍回 zh", api.normalizeLang("ko-KR"), "zh")
check("N8 nil", api.normalizeLang(nil), "zh")

print("== zhVariantOf (v1.2.1 正文变体) ==")
check("V1 zh-Hant → zh-hant", api.zhVariantOf("zh-Hant"), "zh-hant")
check("V2 zh_TW → zh-hant", api.zhVariantOf("zh_TW"), "zh-hant")
check("V3 zh-HK → zh-hant", api.zhVariantOf("zh-HK"), "zh-hant")
check("V4 zh-Hans-CN → zh-cn", api.zhVariantOf("zh-Hans-CN"), "zh-cn")
check("V5 zh-CN → zh-cn", api.zhVariantOf("zh-CN"), "zh-cn")
check("V6 zh (无区码) → zh-cn 兜底", api.zhVariantOf("zh"), "zh-cn")
check("V7 nil → zh-cn 兜底", api.zhVariantOf(nil), "zh-cn")
check("V8 非zh串 → zh-cn 兜底", api.zhVariantOf("en-US"), "zh-cn")

print("== Phase 1 mishit guards ==")
check("M1 (G)I-DLE 括号不动", api.sanitizeQuery("(G)I-DLE"), "(G)I-DLE")
check("M2 内部助词不动", api.stripTrailingParticle("某科学的超电磁炮", "zh"), "某科学的超电磁炮")
check("M3 数字尾不动", api.stripTrailingParticle("命运石之门 0", "zh"), "命运石之门 0")
check("M4 半侧括号", api.sanitizeQuery("《三体"), "三体")
check("M5 嵌套包裹", api.sanitizeQuery("《“X”》"), "X")
check("M6 零宽字符", api.sanitizeQuery("量子力学\226\128\139的"), "量子力学的")
check("M7 全剥空回退", api.sanitizeQuery("《》"), "《》")
check("M8 utf8Len 混合", api.utf8Len("A从零B"), 4)

if failures > 0 then
    print("\nTOTAL FAILURES: " .. failures)
    os.exit(1)
else
    print("\nALL TESTS PASSED")
    os.exit(0)
end
