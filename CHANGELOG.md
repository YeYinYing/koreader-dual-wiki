# Changelog

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
