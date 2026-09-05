# Changelog

All notable changes to this project will be documented in this file.

## [1.2.0] - 2026-09-05

### Added — Phase 2.1 Globalization & Multi-Engine Matrix

- **Language-aware retrieval**: zh / ja / en trailing-particle tables now route per query language. Chinese keeps the original 12 particles; Japanese adds `の/に/を/は/が/で/と/へ/も/な/よ/ね`; English only strips possessive `’s / 's` and deliberately never strips plural `s`.
- **Latin word-boundary good-hit logic**: `quantum` now matches `Quantum mechanics`; `jedi` matches `Jedi`; short prefixes without a word boundary are rejected, so `wo` does not hijack `Wookieepedia`.
- **Context-aware engine registry**: KOReader book metadata `doc_props.language` now drives the visible highlight buttons and menu entries for Wikipedia (ZH/EN/JA), Moegirlpedia and Fandom.
- **Fandom adapter**: verified Fandom wikis do not support `prop=extracts`; full-article paths use `action=parse` with HTML stripping, while candidate selection still uses title search/prefix search.
- **gettext i18n**: bundled `messages.pot`, `zh_CN.po`, `zh_TW.po`, `ja.po` and compiled `.mo` files are loaded at startup when the active KOReader UI language is available.
- **Cross-language synergy**: Japanese moegirl misses now fall back to `ja.wikipedia` instead of returning unrelated moegirl redirect targets.

### Fixed

- Stage-4 content acceptance is now guarded by a prefix-relation check, preventing moegirl's kana-index quirk from accepting unrelated redirects.
- The English retrieval path no longer strips plural `s`, avoiding regressions such as `physics` → `physic`.

## [1.1.0] - 2026-09-05

### Added
- **Moegirlpedia Engine**: Ultra-fast plain-text online queries via the MediaWiki Action API, with zero thumbnail downloads (`explaintext=1`, no `pageimages`).
- **Spoiler Revelation**: Moegirlpedia CSS black spoiler bars (黑幕) never reach the display layer because the pipeline is pure plain text — covered text is fully readable on E-ink.
- **Modern Wikipedia Engine**: Full article loading without introduction-only truncation or HTTP 429 throttling stalls.
- **Book-grade Typography**: Automatic parsing and formatting of MediaWiki headings (`==` / `===` markers) into `【Chapter】` and `▸ Sub-section` lines.
- **Dual-Engine Co-existence**: Seamless parallel highlight buttons in the KOReader text selection toolbar.
- **Smart Cross-Engine Fallback**: Instant one-tap switching between Moegirlpedia and Wikipedia on query misses.
- **Interactive Calibration**: DictQuickLookup pencil icon routes to a pre-filled retry dialog for trimming stray punctuation and re-querying.
