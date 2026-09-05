# Changelog

All notable changes to this project will be documented in this file.

## [1.1.0] - 2026-09-05

### Added — Fuzzy-Tolerant Retrieval Architecture (Plan A)

- **Single-merged-request candidate pipeline**: one `generator=prefixsearch + prop=extracts` round-trip returns up to 4 ranked candidates, each with a readable intro summary. No second handshake on the happy path (8/10 official matrix cases resolve in exactly one HTTP round-trip even on 2.4GHz Kindle Wi-Fi).
- **Local query sanitation (0 ms)**: strips only outermost CJK wrapper brackets (`《》 “ ” 【】（）`…), zero-width noise and stray whitespace. In-word punctuation is never touched — `Re:从零开始的异世界生活`, `Fate/stay night`, `拿破仑·波拿巴` and `(G)I-DLE` pass through intact.
- **Graceful degradation ladder**: exact prefixsearch → trailing-particle drop (`量子力学的` → `量子力学`) → top-candidate content acceptance (server-side redirect targets such as `拿破仑·波拿巴` → `拿破仑一世`) → full-text `generator=search` fallback (resolves dab-page tops like `三体` → `三体 (小说)`) → en.wikipedia retry for pure-Latin zh queries → retry dialog.
- **On-demand full-article upgrade**: confirming an already-listed candidate word via the pencil icon upgrades the summary window to the uncapped full extract in one direct request (long-press pencil prefills the currently viewed candidate).
- **Traditional/Simplified alignment**: server-side `converttitles=1` on zh.wikipedia — no local conversion dictionary; variant redirects (`三体`→`三體`) resolve through the server.
- **Native multi-candidate switching**: candidates render as multiple DictQuickLookup results with the built-in left/right switcher — no custom UI, zero added memory.

### Fixed

- Prefix-search hits were previously only reachable through a two-step search-then-fetch flow; exact-title misses (少选一字/多划标点) failed into the retry dialog instead of self-healing.

## [1.0.0] - 2026-09-05

### Added
- **Moegirlpedia Engine**: Ultra-fast plain-text online queries via the MediaWiki Action API, with zero thumbnail downloads (`explaintext=1`, no `pageimages`).
- **Spoiler Revelation**: Moegirlpedia CSS black spoiler bars (黑幕) never reach the display layer because the pipeline is pure plain text — covered text is fully readable on E-ink.
- **Modern Wikipedia Engine**: Full article loading without introduction-only truncation or HTTP 429 throttling stalls.
- **Book-grade Typography**: Automatic parsing and formatting of MediaWiki headings (`==` / `===` markers) into `【Chapter】` and `▸ Sub-section` lines.
- **Dual-Engine Co-existence**: Seamless parallel highlight buttons in the KOReader text selection toolbar.
- **Smart Cross-Engine Fallback**: Instant one-tap switching between Moegirlpedia and Wikipedia on query misses.
- **Interactive Calibration**: DictQuickLookup pencil icon routes to a pre-filled retry dialog for trimming stray punctuation and re-querying.
