# Changelog

## [Unreleased] — v1.3.2 candidate

### Added

- **Romance elision fallback** (fr/it/pt): selections like `l'amour`, `qu'il`, `l'équation` now strip the elided leading article and retry when the exact query misses, in both ASCII (`'`) and typographic (`’`) apostrophe forms, case-insensitively (`L'Étranger` at sentence start works). Longest-match protects `jusqu'à`; a remainder under 2 characters aborts the strip. Strictly a fallback tier — titles that legitimately start with an article (Les Misérables) hit exactly in Stage 1 and are never disturbed.

### Fixed

- **App crash when scrolling past the last result** (caught in human acceptance, root-caused from a captured crash log): the result table passed to `DictQuickLookup` used a `dictionary` field, but core's `changeDictionary()` reads `results[index].dict` for the window title. The first screen tolerated the missing field, but switching to another candidate — reached by wheel-scrolling past the end of a result, or swiping left/right — called `TitleBar:setText(nil)` and killed the app. Present since v1.2.0; results now carry the contract field `dict` (kept `dictionary` alongside), with a permanent integration regression case.
- Switching the Fandom community or Bilibili game-wiki subdomain now clears the session lookup cache. The cache key (`engine|lang|word`) does not include the subdomain, so the previous community's results would keep resurfacing for identical words after a switch.

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
