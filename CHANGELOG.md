# Changelog

All notable changes to this project are documented in this file.

## [1.2.0] - 2026-09-05

### Added

- Added language-aware retrieval for Chinese, Japanese, and English queries.
- Added a multi-engine routing layer for Wikipedia, Moegirlpedia, and Fandom.
- Added gettext-based localization assets for `zh_CN`, `zh_TW`, and `ja`.
- Added Fandom support with title-based candidate selection and `action=parse` full-article retrieval.
- Added Japanese fallback routing from Moegirlpedia to `ja.wikipedia` when the Moegirl result is unreliable.

### Changed

- Limited `converttitles=1` to Wikipedia Chinese queries.
- Updated the query pipeline to preserve in-word punctuation and apply conservative trailing-particle trimming.
- Updated the English path to strip possessive forms only; plural `s` is no longer removed.
- Updated the KOReader UI integration to route highlight buttons and menu entries by book language when metadata is available.

### Fixed

- Prevented unrelated Moegirlpedia redirects from being accepted as valid Japanese matches.
- Kept the retrieval pipeline stable on low-memory devices by enforcing response size limits and explicit timeout cleanup.

## [1.1.0] - 2026-09-05

### Added

- Added the initial fuzzy-tolerant retrieval pipeline for Moegirlpedia and Wikipedia.
- Added local query sanitization for outer wrappers and zero-width characters.
- Added single-request candidate retrieval with summaries on the happy path.
- Added support for on-demand full-article upgrades from the lookup window.
- Added native highlight-toolbar integration and retry handling.
