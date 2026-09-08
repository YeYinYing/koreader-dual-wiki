-- Unit tests: keepalive.lua pure response-head parsing (v1.3.3 E7).
-- The socket/TLS IO cannot run in the bare test runtime; the parser and
-- body-mode decision logic are extracted as pure functions precisely so
-- they can be verified here.
--
-- Run:  lua tests/test_keepalive.lua dual_wiki.koplugin/keepalive.lua

local src_path = arg and arg[1] or "dual_wiki.koplugin/keepalive.lua"
local chunk = assert(loadfile(src_path))
local M = chunk()

local failures = 0
local function check(name, got, want)
    if got == want then
        print(string.format("PASS  %-44s got=%q", name, tostring(got)))
    else
        print(string.format("FAIL  %-44s got=%q want=%q", name, tostring(got), tostring(want)))
        failures = failures + 1
    end
end

print("== parse_status_line ==")
do
    local code, reason = M.parse_status_line("HTTP/1.1 200 OK")
    check("K1 200 OK", code, 200)
    check("K2 reason", reason, "OK")
    local c2 = M.parse_status_line("HTTP/1.1 429 Too Many Requests")
    check("K3 429 code", c2, 429)
    check("K4 garbage -> nil", M.parse_status_line("BLAH"), nil)
    check("K5 http/1.0 200", M.parse_status_line("HTTP/1.0 200 OK"), 200)
    check("K6 empty reason ok", select(2, M.parse_status_line("HTTP/1.1 204")), "")
end

print("== parse_header_block ==")
do
    local lines = { "Content-Type: application/json", "Retry-After: 3", "" }
    local h, next_i = M.parse_header_block(lines, 1)
    check("K7 content-type", h["content-type"], "application/json")
    check("K8 retry-after", h["retry-after"], "3")
    check("K9 next index after blank", next_i, 4)
    local h2 = M.parse_header_block({ "A: 1", "a: 2", "" }, 1)
    check("K10 lowercase keys fold", h2["a"], "2")
    local h3, n3 = M.parse_header_block({ "X: 1" }, 1)
    check("K11 no blank terminator", h3["x"], "1")
    check("K12 index past end", n3, 2)
end

print("== parse_chunk_size ==")
do
    check("K13 hex 1f", M.parse_chunk_size("1f;ignore=usd"), 31)
    check("K14 plain 2a", M.parse_chunk_size("2a"), 42)
    check("K15 zero", M.parse_chunk_size("0"), 0)
    check("K16 garbage", M.parse_chunk_size("xyz"), nil)
    check("K17 nil", M.parse_chunk_size(nil), nil)
end

print("== body_mode ==")
do
    local m1, l1 = M.body_mode({ ["content-length"] = "1234" })
    check("K18 length mode", m1, "length")
    check("K19 length value", l1, 1234)
    local m2 = M.body_mode({ ["transfer-encoding"] = "chunked" })
    check("K20 chunked mode", m2, "chunked")
    local m3 = M.body_mode({})
    check("K21 close mode fallback", m3, "close")
    local m4, l4 = M.body_mode({ ["content-length"] = "0" })
    check("K22 zero length ok", m4 .. ":" .. tostring(l4), "length:0")
    local m5 = M.body_mode({ ["transfer-encoding"] = "Chunked" })
    check("K23 case-insensitive chunked", m5, "chunked")
end

print("== module shape ==")
check("K24 request exists", type(M.request), "function")
check("K25 clear exists", type(M.clear), "function")
check("K26 pure fns exported", type(M.parse_status_line), "function")

print("== make_reader cap semantics (2MB abort) ==")
do
    local r = M.make_reader(10)
    check("K27 under cap accepted", r.add("12345"), true)
    check("K28 at cap accepted", r.add("12345"), true)
    check("K29 over cap rejected", r.add("1"), false)
    check("K30 stays rejected", r.add(""), false) -- overflow latches
    local r2 = M.make_reader(4)
    check("K31 single big chunk rejected", r2.add("12345"), false)
    local r3 = M.make_reader(1024 * 1024)
    check("K32 exactly-at-boundary ok", r3.add(string.rep("x", 1024 * 1024)), true)
end

print("== is_trusted_host whitelist (v1.3.3 hardening) ==")
do
    -- Every host the plugin's ENGINES table can produce must pass…
    check("K33 en.wikipedia.org", M.is_trusted_host("en.wikipedia.org"), true)
    check("K34 zh.wikipedia.org", M.is_trusted_host("zh.wikipedia.org"), true)
    check("K35 en.wiktionary.org", M.is_trusted_host("en.wiktionary.org"), true)
    check("K36 www.wikidata.org", M.is_trusted_host("www.wikidata.org"), true)
    check("K37 zh.moegirl.org.cn", M.is_trusted_host("zh.moegirl.org.cn"), true)
    check("K38 starwars.fandom.com", M.is_trusted_host("starwars.fandom.com"), true)
    check("K39 wiki.biligame.com", M.is_trusted_host("wiki.biligame.com"), true)
    -- …suffix impostors and foreign hosts must NOT (the custom HTTP reader
    -- is only regression-tested against MediaWiki; anything else must fall
    -- back to the legacy ssl.https transport).
    check("K40 evil-wikipedia.org", M.is_trusted_host("evil-wikipedia.org"), false)
    check("K41 wikipedia.org.evil.io", M.is_trusted_host("wikipedia.org.evil.io"), false)
    check("K42 fandom.com.evil.io", M.is_trusted_host("fandom.com.evil.io"), false)
    check("K43 moegirl.org.cn.evil.io", M.is_trusted_host("moegirl.org.cn.evil.io"), false)
    check("K44 wikipedia.org (bare)", M.is_trusted_host("wikipedia.org"), false)
    check("K45 wiki.biligame.com.evil.io", M.is_trusted_host("wiki.biligame.com.evil.io"), false)
    check("K46 github.com", M.is_trusted_host("github.com"), false)
    check("K47 nil", M.is_trusted_host(nil), false)
    check("K48 empty", M.is_trusted_host(""), false)
end

if failures == 0 then
    print("ALL TESTS PASSED")
else
    print(string.format("TOTAL FAILURES: %d", failures))
    os.exit(1)
end
