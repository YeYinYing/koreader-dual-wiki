-- dual_wiki.koplugin/keepalive.lua — TLS connection pool for https GETs.
--
-- v1.3.3 (E7): ssl.https.request tears down the TLS session after every
-- call, so each MediaWiki probe pays a fresh TCP + TLS handshake (measured
-- 300-500 ms on e-ink devices). This module keeps ONE idle connection per
-- host and speaks HTTP/1.1 by hand; any failure at any stage discards the
-- pooled socket and reports the failure so the caller can fall back to the
-- legacy path. The pool is intentionally tiny: the plugin talks to a
-- handful of wiki hosts, serially, from one UI thread.
--
-- Design contract with main.lua's httpGetOnce:
--   request(url, timeout, max_bytes, user_agent)
--     -> nil                       module unavailable, non-https URL, or an
--                                  internal (pcall-caught) anomaly — the
--                                  ONLY signal that triggers the legacy
--                                  fallback in the caller
--     -> true, body, nil, headers  HTTP 2xx (body guaranteed non-empty)
--     -> false, kind, detail, hdrs definitive verdict, trusted by the
--                                  caller: same error kinds as httpGetOnce
--                                  ("http_429" carries the headers table so
--                                  Retry-After keeps working)
-- A definitive verdict is never re-requested over the legacy path — that
-- would double-hit 429 rate limits and double the latency on dead hosts.
-- A stale REUSED socket (server closed it during idle) is absorbed inside:
-- one silent retry on a fresh connection before any verdict is reported.
--
-- Test switch: set keepalive.enabled = false to force the legacy path.
-- The response-head parser is a pure function, unit-tested directly.

local M = {
    enabled = true,
    IDLE_TIMEOUT_S = 60,   -- pooled sockets die after this much quiet time
    POOL_MAX = 4,          -- one entry per host we actually talk to
}

-- luasec/luasocket may be absent in the bare unit-test runtime; degrade to
-- "unavailable" instead of failing to load.
local ok_socket, socket = pcall(require, "socket")
local ok_ssl, ssl = pcall(require, "ssl")
local ok_url, socket_url = pcall(require, "socket.url")
M.available = ok_socket and ok_ssl and ok_url

-- ---------------------------------------------------------------- trust ----
-- The hand-rolled HTTP/1.1 reader below is tuned and regression-tested
-- against the MediaWiki hosts this plugin actually talks to (main.lua's
-- ENGINES table). Anything else returns nil from request() and falls back
-- to the legacy ssl.https path untouched — the custom protocol code never
-- sees a host it was not built for.
local TRUSTED_HOST_SUFFIXES = {
    ".wikipedia.org",
    ".wiktionary.org",
    ".wikidata.org",
    ".moegirl.org.cn",
    ".fandom.com",
}
local TRUSTED_HOSTS = {
    ["wiki.biligame.com"] = true,
}
function M.is_trusted_host(host)
    if type(host) ~= "string" or host == "" then return false end
    if TRUSTED_HOSTS[host] then return true end
    for _, suffix in ipairs(TRUSTED_HOST_SUFFIXES) do
        if host:sub(-#suffix) == suffix then return true end
    end
    return false
end

-- TLS parameters mirror KOReader's bundled ssl.https defaults (LuaSec 1.3.2
-- cfg table) so pooled handshakes behave identically to the legacy path.
--
-- Strict certificate verification is a deliberate OPT-IN, never the default:
-- e-ink devices often boot with a wrong clock (1970 reset) and carry stale or
-- missing CA bundles, so verify="peer" would break lookups for most users.
-- Advanced users can set dualwiki_tls_strict = true in settings.reader.lua;
-- the switch only engages when a CA bundle is actually locatable, and
-- degrades to the default lenient mode otherwise (logged once).
local TLS_PARAMS = {
    protocol = "any",
    options = { "all", "no_sslv2", "no_sslv3", "no_tlsv1" },
    verify = "none",
    mode = "client",
}
local CA_CANDIDATES = {
    "/etc/ssl/certs/ca-certificates.crt", -- Debian/Ubuntu/Kobo
    "/etc/pki/tls/certs/ca-bundle.crt",   -- Fedora/RHEL style
    "/etc/ssl/cert.pem",                  -- macOS
    "/usr/local/share/certs/ca-root-nss.crt", -- FreeBSD
}
local strict_warned = false
local function resolve_tls_params()
    local params = {
        protocol = TLS_PARAMS.protocol,
        options = TLS_PARAMS.options,
        verify = TLS_PARAMS.verify,
        mode = TLS_PARAMS.mode,
    }
    if type(G_reader_settings) == "table"
        and G_reader_settings.isTrue
        and G_reader_settings:isTrue("dualwiki_tls_strict") then
        local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
        if ok_lfs then
            for _, ca in ipairs(CA_CANDIDATES) do
                if lfs.attributes(ca, "mode") == "file" then
                    params.cafile = ca
                    params.verify = "peer"
                    return params
                end
            end
        end
        if not strict_warned then
            strict_warned = true
            local ok_logger, logger = pcall(require, "logger")
            if ok_logger then
                logger.warn("dual_wiki: dualwiki_tls_strict is set but no CA bundle found; using lenient TLS")
            end
        end
    end
    return params
end

if M.available then
    M._pool = {}   -- "host:port" -> { sock = <ssl socket>, idle_since = t }
    -- successes counts responses that traveled over the pool (NOT the
    -- legacy path) — lets the integration suite prove the fast path was
    -- actually exercised instead of silently falling back.
    M._stats = { opens = 0, reuses = 0, stale_retries = 0, successes = 0 }
end

-- ------------------------------------------------------------------ pure --
-- "HTTP/1.1 200 OK" -> 200, "OK" (nil on garbage)
function M.parse_status_line(line)
    if type(line) ~= "string" then return nil end
    local code = line:match("^HTTP/%d%.%d%s+(%d%d%d)")
    if not code then return nil end
    local reason = line:match("^HTTP/%d%.%d%s+%d%d%d%s*(.-)$")
    return tonumber(code), reason
end

-- Header block lines (array, inclusive of the terminating empty string) ->
-- lowercase-keyed table, index of the first line AFTER the block.
-- Duplicate headers keep the LAST value (MediaWiki never sends meaningful
-- duplicates; Retry-After cannot repeat).
function M.parse_header_block(lines, start_idx)
    local headers = {}
    local i = start_idx or 1
    while i <= #lines do
        local line = lines[i]
        if line == nil or line == "" then
            return headers, i + 1
        end
        local key, value = line:match("^([^:]+):%s*(.-)%s*$")
        if key then
            headers[key:lower()] = value
        end
        i = i + 1
    end
    return headers, i
end

-- "1f;ignore=usd" chunk-size line -> 31 (nil on garbage)
function M.parse_chunk_size(line)
    if type(line) ~= "string" then return nil end
    local hex = line:match("^(%x+)")
    if not hex or hex == "" then return nil end
    return tonumber(hex, 16)
end

-- Content-Length / Connection decision from a parsed header table.
-- Returns body_mode: "length" | "chunked" | "close", body_length.
function M.body_mode(headers)
    if headers["transfer-encoding"] and headers["transfer-encoding"]:lower():find("chunked", 1, true) then
        return "chunked", nil
    end
    local n = tonumber(headers["content-length"])
    if n and n >= 0 then
        return "length", n
    end
    return "close", nil
end

-- ------------------------------------------------------------------- io --

local function pool_get(key)
    local entry = M._pool[key]
    if not entry then return nil end
    if os.time() - entry.idle_since > M.IDLE_TIMEOUT_S then
        pcall(function() entry.sock:close() end)
        M._pool[key] = nil
        return nil
    end
    return entry.sock
end

local function pool_put(key, sock)
    local n = 0
    for _ in pairs(M._pool) do n = n + 1 end
    if n >= M.POOL_MAX then
        -- evict an arbitrary entry (pool size ~= distinct host count)
        local evict_key, evicted = next(M._pool)
        if evict_key then
            pcall(function() evicted.sock:close() end)
            M._pool[evict_key] = nil
        end
    end
    M._pool[key] = { sock = sock, idle_since = os.time() }
end

local function pool_drop(key, sock)
    local entry = M._pool[key]
    if entry and entry.sock == sock then
        M._pool[key] = nil
    end
    pcall(function() sock:close() end)
end

-- Establish (or reuse) a TLS connection. Returns sock or nil.
-- CONNECT_TIMEOUT_S bounds TCP + handshake so a DNS-poisoned host fails
-- as fast as the legacy path would (the moegirl fast-fail contract).
local CONNECT_TIMEOUT_S = 5
local function connect(host, port, key)
    local sock = pool_get(key)
    if sock then
        M._stats.reuses = M._stats.reuses + 1
        return sock
    end
    local tcp = socket.tcp()
    if not tcp then return nil end
    tcp:settimeout(CONNECT_TIMEOUT_S)
    if not select(1, tcp:connect(host, port)) then
        pcall(function() tcp:close() end)
        return nil
    end
    local tls = ssl.wrap(tcp, resolve_tls_params())
    if not tls then
        pcall(function() tcp:close() end)
        return nil
    end
    tls:sni(host)
    tls:settimeout(CONNECT_TIMEOUT_S)
    if not select(1, tls:dohandshake()) then
        pcall(function() tcp:close() end)
        return nil
    end
    M._stats.opens = M._stats.opens + 1
    return tls
end

-- Accumulating reader with the 2 MB abort semantics of the legacy sink.
-- NOTE: dot-call discipline — the closure takes ONLY the chunk; callers
-- must use reader.add(chunk), never reader:add(chunk) (which would pass
-- the reader table as the chunk and silently neuter the cap).
local function make_reader(max_bytes)
    local received = 0
    local overflow = false
    return {
        add = function(chunk)
            if overflow then return false end
            received = received + #chunk
            if received > max_bytes then
                overflow = true
                return false
            end
            return true
        end,
    }
end
M.make_reader = make_reader -- exported pure-ish for the unit matrix

-- Read the body per body_mode. Returns body string, keepalive_ok(boolean),
-- error_kind(string|nil).
local function read_body(sock, mode, length, max_bytes)
    local reader = make_reader(max_bytes)
    local parts = {}
    local add = function(chunk)
        if not reader.add(chunk) then return false end
        parts[#parts + 1] = chunk
        return true
    end
    if mode == "chunked" then
        while true do
            local line, err = sock:receive("*l")
            if not line then return nil, false, "error", err end
            local size = M.parse_chunk_size(line)
            if not size then return nil, false, "error", "bad chunk size" end
            if size == 0 then
                -- trailers until blank line (usually none)
                while true do
                    local tl = sock:receive("*l")
                    if not tl then return nil, false, "error", "truncated trailers" end
                    if tl == "" then break end
                end
                break
            end
            local data, cerr = sock:receive(size)
            if not data then return nil, false, "error", cerr end
            if not add(data) then return nil, false, "too_large", nil end
            sock:receive(2) -- trailing CRLF
        end
    elseif mode == "length" then
        if length > 0 then
            local data, rerr = sock:receive(length)
            if not data then return nil, false, "error", rerr end
            if not add(data) then return nil, false, "too_large", nil end
        end
    else -- "close": read until the peer hangs up
        while true do
            local data, rerr = sock:receive(8192)
            if data then
                if not add(data) then return nil, false, "too_large", nil end
            elseif rerr == "closed" then
                break
            else
                return nil, false, "error", rerr
            end
        end
    end
    return table.concat(parts), true, nil
end

-- Single request over an established socket. Returns the request() contract.
local function request_once(sock, url_parts, timeout, max_bytes, user_agent)
    local path = url_parts.path or "/"
    if url_parts.query then path = path .. "?" .. url_parts.query end
    local host_header = url_parts.host
    if url_parts.port and url_parts.port ~= 443 then
        host_header = host_header .. ":" .. url_parts.port
    end
    local req = table.concat({
        "GET " .. path .. " HTTP/1.1",
        "Host: " .. host_header,
        "User-Agent: " .. user_agent,
        "Accept: application/json",
        "Connection: keep-alive",
        "", "",
    }, "\r\n")
    -- Bound the send AND the reads by the request timeout — a pooled socket
    -- still carries the 60 s idle timeout from pool_put, and send() must
    -- never outlive the caller's budget.
    sock:settimeout(timeout or 10)
    local sent, serr = sock:send(req)
    if not sent then return nil, nil, serr end
    -- Read the head line-by-line until the blank terminator.
    local lines = {}
    while true do
        local line, err = sock:receive("*l")
        if not line then return nil, nil, err end
        if line == "" then break end
        lines[#lines + 1] = line
    end
    local code = M.parse_status_line(lines[1])
    if not code then return nil, nil, "bad status line" end
    local headers = M.parse_header_block(lines, 2)

    local mode, length = M.body_mode(headers)
    local body, reuse_ok, kind, detail = read_body(sock, mode, length, max_bytes)
    if not body then
        return nil, false, kind, detail
    end
    local can_keep = reuse_ok
        and (headers["connection"] == nil
            or headers["connection"]:lower():find("keep%-alive", 1, true) ~= nil)
    return code, can_keep, nil, headers, body
end

-- Public entry. See the module contract above.
function M.request(url, timeout, max_bytes, user_agent)
    if not M.enabled or not M.available then return nil end
    local parts = socket_url.parse(url)
    if not parts or parts.scheme ~= "https" or not parts.host or not M.is_trusted_host(parts.host) then
        return nil
    end
    local port = tonumber(parts.port) or 443
    local key = parts.host .. ":" .. port

    -- attempt() runs one full request round. A REUSED socket that died
    -- during idle gets ONE silent retry on a fresh connection (stale-socket
    -- absorption); a fresh-connection failure reports immediately — a dead
    -- host must fail fast, not loop.
    local function attempt(is_retry)
        local reused = pool_get(key) ~= nil
        local sock = connect(parts.host, port, key)
        if not sock then return false, "error", "connect failed" end
        local code, can_keep, kind, headers, body =
            request_once(sock, parts, timeout, max_bytes, user_agent)
        if code == nil then
            -- broken in-flight: never re-queue a suspect socket
            pool_drop(key, sock)
            if reused and not is_retry then
                -- stale idle socket (server closed it during the quiet
                -- window): absorb the failure, retry once on a fresh one
                M._stats.reuses = M._stats.reuses - 1
                M._stats.stale_retries = M._stats.stale_retries + 1
                return attempt(true)
            end
            return false, kind or "error", headers or "broken connection"
        end
        if can_keep then
            sock:settimeout(M.IDLE_TIMEOUT_S)
            pool_put(key, sock)
        else
            pool_drop(key, sock)
        end
        if code >= 200 and code < 300 then
            if #body == 0 then
                return false, "error", "Empty response body"
            end
            M._stats.successes = M._stats.successes + 1
            return true, body, nil, headers
        elseif code == 429 then
            return false, "http_429", nil, headers
        elseif code >= 500 then
            return false, "http_5xx", nil, headers
        else
            return false, "http_4xx", nil, headers
        end
    end

    local ok, r1, r2, r3, r4 = pcall(attempt, false)
    if not ok or r1 == nil then
        -- internal error or in-flight break: caller falls back to legacy
        return nil
    end
    return r1, r2, r3, r4
end

function M.clear()
    if M._pool then
        for k, e in pairs(M._pool) do
            pcall(function() e.sock:close() end)
            M._pool[k] = nil
        end
    end
end

return M
