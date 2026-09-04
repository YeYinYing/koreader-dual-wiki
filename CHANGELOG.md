# Changelog

All notable changes to this project will be documented in this file.

## [1.0.0] - 2026-09-05

### Added
- **Moegirlpedia Engine**: Ultra-fast plain-text online queries via the MediaWiki Action API, with zero thumbnail downloads (`explaintext=1`, no `pageimages`).
- **Spoiler Revelation**: Moegirlpedia CSS black spoiler bars (黑幕) never reach the display layer because the pipeline is pure plain text — covered text is fully readable on E-ink.
- **Modern Wikipedia Engine**: Full article loading without introduction-only truncation or HTTP 429 throttling stalls.
- **Book-grade Typography**: Automatic parsing and formatting of MediaWiki headings (`==` / `===` markers) into `【Chapter】` and `▸ Sub-section` lines.
- **Dual-Engine Co-existence**: Seamless parallel highlight buttons in the KOReader text selection toolbar.
- **Smart Cross-Engine Fallback**: Instant one-tap switching between Moegirlpedia and Wikipedia on query misses.
- **Interactive Calibration**: DictQuickLookup pencil icon routes to a pre-filled retry dialog for trimming stray punctuation and re-querying.
