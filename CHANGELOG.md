# Changelog

## [1.3.3] - 2026-09-07 — search quality & reader ergonomics

### Added

- **Disambiguation detection and expansion** (A1): the merged candidate request now piggybacks `prop=pageprops&ppprop=disambiguation`, so a Disambiguator-flagged top hit (en `Mercury`, ja `シャナ`, …) is no longer surfaced as a bare index page. The pipeline fetches the dab page's section-0 wikitext, extracts the curated `[[Title]]` bullets in the editor's semantic order (primary topic first; plain-text and descriptive-link bullets are rejected so ja descriptions like `[[英語圏]]の女性名…` or 漫画『[[9番目のムサシ]]…' never leak in), then fills every item's definition with ONE batched intro-extract request. Items are tagged 【消歧义义项】 and pencil-load normally. `prop=links` was rejected for this: it is anon-capped (pllimit ≤10) and reordered, which dropped the marquee 灼眼のシャナ entirely on ja.wp and ranked "Anna Kavan" above the planet on en.wp.
- **"Did you mean" suggestions** (A3): the Stage-5 search request carries `gsrinfo=suggestion`; when the whole ladder misses, the retry dialog shows a translated hint line (`您是不是要找：%1？`) and a one-tap `试查"%1"` button. Captured per-lookup round and cleared on read (a stale suggestion can never attach to a later failure).
- **European phrase particles** (B5): a second, word-level trailing-stopword table (`PHRASE_PARTICLES`, fr/es/it/de) feeds Stage 2's fallback — `L'histoire de` → `L'histoire`, `Theorie der` → `Theorie`. Matched case-insensitively via `caseFold`, whole tokens only (leading space required — `de Gaulle` survives), remainder ≥2 chars. Char-level `PARTICLES` still win first.
- **Selection script routing** (B7): `routeLangForScript` sniffs pure-Latin / pure-Cyrillic / pure-kana selections; a zh-defaulted book receiving such a selection routes straight to en/ru/ja.wikipedia BEFORE the first request (the result window label follows the routed language). Previously a Latin selection burned the zh probe (up to 3 requests) before Stage 3's fallback. Explicit language locks (per-book or global) are honored — routing only refines auto-detected languages; Stage 3 stays as the locked-zh safety net.
- **Italian elision + German fusional contractions** (E3): the Stage-1b bare-word probe now also strips Italian articulated prepositions (`dell'arte` → `arte`, `sull'isola` → `isola`; longest-match keeps `dell'` ahead of `d'`) and German leading fusions as a separate word-level pass (`zum Beispiel` → `Beispiel`, `Im Wald` → `Wald`; the trailing space in each pattern stops `Immer` from matching `im`). Fallback-only — titles genuinely starting with these forms hit exactly in Stage 1 and are never disturbed.
- **Sitelink notability re-rank** (E1): when NO exact hit exists and the top candidate is content-thin (<60 chars), one batched `wbgetentities` call fetches sitelink counts for every `wikibase_item` QID (piggybacked on the same probe request) and a clearly-more-notable entity (≥2× links, ≥8 wikis) is promoted to the front — `Bande` → the disambiguated primary topic instead of stub noise. Hard red lines: exact hits and dab pages are NEVER re-ranked; any failure keeps the server order.
- **Cross-language bridge** (E2): for wikipedia results whose language differs from the book's (or any non-zh result when reading a zh book), one `prop=langlinks` call on the top candidate appends the equivalent article as a trailing pseudo-entry (`→ 目标标题`); its pencil loads the full text in the target language directly. Silent on any failure.
- **Preferred engine per book** (E9): settings gain `首选引擎（本书）/（全局默认）` radio pickers. An explicit choice pins that engine's button into slot 1 (per-book wins over global); the remaining default-plan entry fills slot 2.
- **Highlight prewarm** (E8): when the highlight menu opens, the primary button's query is prefetched silently after a 600 ms debounce into the session cache (skipped when a fresh negative entry exists), so tapping the button replays a cache hit — the result window appears near-instantly. Toggle in settings, default on; never shows UI or error state.
- **Wikidata pencil bridge** (E4): candidates now carry their `wikibase_item` QID; the pencil on such a candidate resolves the entity's sitelinks (book language → zh → en) and loads that article's full text. No usable sitelink falls back to the search dialog — the pencil never dead-ends.
- **TLS keepalive pool** (E7): new `keepalive.lua` module keeps one idle TLS connection per wiki host and speaks HTTP/1.1 (Content-Length + chunked + close-delimited bodies, lowercase-folded headers, 2 MB abort cap preserved). Reuses measured in the integration suite (`opens=1, reuses=1` for back-to-back probes) save the 300-500 ms TCP+TLS handshake per request on e-ink devices. ANY anomaly — connect failure, mid-transfer break, oversized body, internal error — discards the socket and falls back to the legacy `ssl.https` path, which remains the single source of truth; `DUALWIKI_NO_KEEPALIVE` env (and a `keepalive.enabled` toggle for tests) pins the legacy transport. The pool is dropped on document close.
- **Wider search fallback** (E5): the Stage-5 generator=search request widens from 4 to 8 candidates (`gsrlimit`/`exlimit` move together, still ONE request). True `gsroffset` paging stays deferred: DictQuickLookup offers no clean button-extension point for a "more" affordance.
- **Negative lookup cache** (E6): a clean full-ladder miss (no transport error involved) is remembered for 180 s, so re-selecting the same dead word skips the ladder instead of re-burning 3+ requests (and the rate limiter's patience). Transport errors and Lua errors are never cached.

### Fixed

- **Dab item red links** (L1): bullets linking titles with no article yet (verified: 3 of ja `シャナ`'s items are red links) are now dropped via the batched extract response's `missing` flag — a pencil tap on them would have 404'd.
- **Dab extracts for redirect items** (L2): items that are redirects resolve server-side to a different title; extracts now propagate from the response title back to the bullet title via the `redirects` map, so every kept item carries its summary.
- **Dab item cap raised** (L3): 8 → 10 curated items; the batched extract pass tolerates it at the same `exlimit=20`, so more senses cost nothing extra.

### Infrastructure

- Integration suite: dab-expansion contracts asserted against live en.wp (`Mercury → Mercury (planet)` top) and ja.wp (灼眼のシャナ present among シャナ's items), with a bounded 3-attempt retry because a 429 can silently degrade an expansion; `assertPipeline` itself retries degraded ladders (the Wikimedia edge 429s aggressively under this suite's request pattern, which once let a transient Stage-1b failure masquerade as the v1.3.2 elision regression). New E7 section exercises the pool on the real network: sequential GETs reuse the socket, bodies stay valid, and a dead-port failure recovers cleanly.
- Unit matrix: phrase-particle cases (fr/es/it/de × hit/no-hurt), `routeLangForScript` matrix (Latin/Cyrillic/kana/mixed/digits), dab-flag parsing + QID passthrough, German fusion strip, and a new `tests/test_keepalive.lua` covering the pure response-head parser (status line, header folding, chunk sizes, body-mode decision) — the socket IO itself is exercised only by the integration suite.
- Locale: 9 msgids total across zh_CN/zh_TW/ja/en (60 translated each), `messages.pot` synced, all `.mo` recompiled.

## [1.3.2] - 2026-09-07

### Added

- **Romance elision fallback** (fr/it/pt): selections like `l'amour`, `qu'il`, `l'équation` now strip the elided leading article and probe the bare word BEFORE the literal query's verdict (Stage 1b), in both ASCII (`'`) and typographic (`’`) apostrophe forms, case-insensitively (`L'Étranger` at sentence start works). Longest-match protects `jusqu'à`; a remainder under 2 characters aborts the strip. Titles that legitimately start with an article (Les Misérables) hit exactly in Stage 1 and are never disturbed.
- **Search menu follows the book language**: one `Wikipedia lookup (XX)` entry (translated, `Wikipedia lookup (%1)`) replaces the fixed zh/en/ja trio, so de/fr/es/ru books finally have a manual Wikipedia search path.
- **Non-ASCII case folding (`caseFold`)**: byte-walking UTF-8 fold for Latin-1 Supplement (É È Ç Ü …), Latin Extended-A (Œ), and Cyrillic (А-Я, Ё/Є/Ї). Codepoint-1:1 mapping keeps byte lengths stable for the existing byte-index logic; zh behavior unchanged (identity fold).

### Fixed

- **French results poisoned by accented-capital deafness** (caught in human acceptance, root-caused by stage-by-stage network probes): every case-insensitive verdict (`hasGoodHit`, `sharesPrefix`, `parseCandidatePages` exact promotion) folded with Lua's `string.lower`, which is ASCII-only — `"Équation":lower()` stays `"Équation"` and never equals the stripped probe `équation` (byte 2 `C3 89` vs `C3 A9`). The elision probe fetched the right article but the verdict rejected it, the ladder degraded to Stage 6 and surfaced the `L'Équation…` prefix noise (a TV movie, the Bogdanoff essay, a novel). All three sites now fold through `caseFold`.
- **Result-window label for European languages**: `ENGINES.wikipedia.label` returned `Wikipedia (ZH)` for every non-ja/en language since the three-language era; de/fr/es/ru windows are now titled `Wikipedia (DE/FR/ES/RU)` (matches the dynamic highlight-button labels).
- **App crash when scrolling past the last result** (caught in the same acceptance round, root-caused from a captured crash log): the result table passed to `DictQuickLookup` used a `dictionary` field, but core's `changeDictionary()` reads `results[index].dict` for the window title. The first screen tolerated the missing field, but switching to another candidate — reached by wheel-scrolling past the end of a result, or tapping ◁◁/▷▷ — called `TitleBar:setText(nil)` and killed the app. Present since v1.2.0; results now carry the contract field `dict` (kept `dictionary` alongside).
- Switching the Fandom community or Bilibili game-wiki subdomain now clears the session lookup cache. The cache key (`engine|lang|word`) does not include the subdomain, so the previous community's results would keep resurfacing for identical words after a switch.

### Infrastructure

- Integration suite elision assertions upgraded from substring `find("quation")` — which the noise titles contain; this is exactly how the accented-capital bug escaped CI twice — to exact-title predicates (`top == "Équation"`) for both capital and lowercase `L'équation` against the live fr.wikipedia.
- Unit matrix gained `caseFold` coverage (Latin-1, Œ, Cyrillic, length stability) and accented good-hit/sharesPrefix/exact-promotion regression cases.
- `messages.pot` regenerated with the new `Wikipedia lookup (%1)` msgid; `Wikipedia lookup (%1)` translated across zh_CN / zh_TW / ja / en and all `.mo` recompiled.

## [1.3.1] - 2026-09-06

### Added

- **Automatic 429/5xx retry** (polish-phase item, driven by emulator integration findings): transient server-side failures now retry once with a bounded backoff instead of surfacing a "rate limited" dialog. The Wikimedia rate limiter counts per-IP across all wikis, so rapid successive lookups could legitimately hit 429 mid-session. `Retry-After` is honored when present (capped at 5 s; default backoff 2 s). Non-retryable kinds (timeout, DNS/TLS errors, oversized bodies) still fail fast — the moegirl degradation ladder is unaffected.

### Fixed

- **Latent gettext corruption** caught by the new integration probe before release: the transport layer assigned luasocket's response headers table to the module-level gettext `_` upvalue (`code, _, status = socket.skip(1, ...)`), which would have broken every subsequent user-facing string evaluation after the first HTTP request of a session. All previously released versions (v1.2.0 – v1.3.0) used the correct binding and were **not** affected; the regression existed only in unreleased working-tree code and was intercepted by the emulator probe.

### Infrastructure

- Integration suite gained two deterministic stubbed-transport cases proving the retry layer: one 429 → success (exactly 2 requests, `Retry-After: 0` honored), persistent 429 → nil with kind `http_429` after exactly 2 requests.

## [1.3.0] - 2026-09-06

### Added

- **Phase 2.2 European languages**: German / French / Spanish / Russian Wikipedia. The five hard-coded highlight buttons collapse into two dynamic slots whose factory re-resolves the book language on every highlight-menu invocation — de/fr/es/ru books get `[Wikipedia (XX)] [Wikipedia (EN)]` automatically.
- **Settings hub** (menu → Dual Wiki settings): language lock per book (stored in the book's sdr) and globally (auto/zh/en/ja/de/fr/es/ru), Fandom community and Bilibili game wiki subdomain prompts, and a session-cache clear button. This fulfils the language-lock UI commitment from the HANDOVER section 5 architecture spec.
- **New engines**: Bilibili Game Wiki (`wiki.biligame.com`, MediaWiki, reuses the parse adapter) and Wiktionary (en/ja) for word definitions; both reachable from the search menu.
- **Two-phase parse fetch**: engines without TextExtracts (Fandom / BWiki / Wiktionary) now fetch the section=0 intro first (tens of KB) and only pull the full page when the intro is under 300 bytes — low-RAM devices no longer routinely decode 1.5 MB Fandom JSON.
- **Session lookup cache**: identical word/engine/language repeats skip the network (LRU-capped at 32 entries), cleared on document close or from the settings menu.
- **`en.po`** locale (msgid == msgstr) for translation-platform completeness; 26 new translated msgids across zh_CN / zh_TW / ja.
- **CI** (GitHub Actions): syntax check, unit tests, and a stale-`.mo` guard on every push; tag pushes automatically build and attach the release zip.
- **`tests/`** checked into the repository (previously an ad-hoc /tmp script): 59 assertions covering the sanitation matrix, cross-language particles, good-hit rules, language normalization and the zh body-variant resolver.

### Changed

- `sharesPrefix` Latin branch generalized from `[%a']+` to `%S+` so Cyrillic (Russian) titles pass the prefix-relation guard.
- `normalizeLang` extended: `ger/deu→de`, `fre/fra→fr`, `spa→es`, `rus→ru` (previously all fell back to zh).

## [1.2.2] - 2026-09-05

### Fixed

- The retry dialog's cross-engine button now passes a normalized language to the new lookup; a failed Fandom query switching to Wikipedia previously sent the Fandom community subdomain as a language and queried a nonexistent `starwars.wikipedia.org`.
- The transport error hint moved from a transient toast (hidden behind the retry dialog's tap layer, therefore never visible) into the retry dialog's own description line, and is now cleared once consumed or when a new query starts, so stale hints can no longer leak into later "not found" dialogs.
- The 2 MB response cap now aborts the transfer as soon as the limit is crossed via a size-capped sink; previously the whole multi-megabyte body was buffered first (defeating the cap on low-RAM devices) and the overflow was misreported as a server error instead of "article too large".
- A 200 response with an empty body is now reported as a transport error rather than a generic HTTP status failure.
- The Fandom community setting value is normalized (lowercase alphanumeric + hyphen) before being used in URLs.

## [1.2.1] - 2026-09-05

### Fixed

- HTTPS requests now dispatch explicitly between `socket.http` and `ssl.https` by URL scheme, matching KOReader core; fixes startup-of-request failures (`invalid scheme`) on KOReader builds whose luasocket lacks an https shim.
- Wikipedia Chinese requests now force an explicit body-text variant (`variant=zh-cn` / `zh-hant`, derived from the raw book language); `converttitles=1` alone left the extract body variant environment-dependent.
- Replaced the hard-coded `KOReader/2024.04 (Kindle)` User-Agent with a device-agnostic `dual_wiki.koplugin/1.2.1 (KOReader)`.
- Transport failures are now reported with differentiated hints (rate limited / server rejected / server error / timeout / unreachable) instead of a generic message.
- Moegirlpedia queries fast-fail after a 5 s probe timeout, skip the remaining moegirl stages, and degrade to `zh`/`ja` Wikipedia for transport-level failures (DNS-polluted regions previously burned the full retry ladder).

### Added

- AGPL-3.0 license headers in `main.lua` and `_meta.lua`.

## [1.2.0] - 2026-09-05

### Added

- Language-aware retrieval for Chinese, Japanese, and English queries.
- Multi-engine routing for Wikipedia, Moegirlpedia, and Fandom.
- gettext localization for `zh_CN`, `zh_TW`, and `ja`.
- Fandom support with title-based candidate selection and `action=parse` full-article retrieval.
- Fallback from Moegirlpedia to `ja.wikipedia` for unreliable Japanese results.

### Changed

- `converttitles=1` is now limited to Wikipedia Chinese queries.
- English queries strip possessive forms only; plural `s` is no longer removed.
- Highlight buttons and menu entries route by book language when metadata is available.

### Fixed

- Unrelated Moegirlpedia redirects are no longer accepted as valid Japanese matches.

## [1.1.0] - 2026-09-05

### Added

- Fuzzy-tolerant retrieval pipeline for Moegirlpedia and Wikipedia.
- Local query sanitization for outer wrappers and zero-width characters.
- Single-request candidate retrieval with summaries.
- On-demand full-article upgrades from the lookup window.
- Highlight-toolbar integration and retry handling.
