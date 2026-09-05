# Changelog

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
