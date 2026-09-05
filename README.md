<div align="center">

# Dual Wiki for KOReader

[![License: AGPL-3.0](https://img.shields.io/badge/License-AGPL_3.0-blue.svg)](LICENSE)
[![KOReader](https://img.shields.io/badge/KOReader-v2024%2B-orange.svg)](https://github.com/koreader/koreader)
[![Topic](https://img.shields.io/badge/Topic-koreader--plugin-green.svg)](https://github.com/topics/koreader-plugin)

**English** | [简体中文](README_zh-CN.md)

</div>

Dual Wiki is a KOReader plugin for looking up encyclopedia entries from multiple MediaWiki-based sources while reading.
It is designed for e-ink devices and prioritizes predictable behavior, low memory usage, and minimal UI disruption.

Supported sources:

- Wikipedia in `zh / en / ja`
- Moegirlpedia
- Fandom community wikis

---

## Overview

The plugin provides a small set of focused lookup flows:

- select text and open a source from the highlight toolbar;
- search by typing directly from the main menu;
- review ranked candidates when the exact title is not known;
- open the pencil edit action to refine a query or load the full article.

The retrieval pipeline is intentionally conservative. It removes only outer wrappers and other safe noise, keeps in-word punctuation intact, and falls back gradually when a query is ambiguous or incomplete.

---

## Features

### Retrieval behavior
- Removes only outer wrappers such as `《》`, `“”`, `【】`, `『』`, and similar pairs.
- Trims safe trailing particles conservatively.
- Uses word-boundary matching for Latin queries.
- Returns ranked candidates with summaries on the main path when the source supports it.
- Upgrades a candidate to the full article from the pencil edit action.

### Source handling
- Wikipedia is routed per language (`zh`, `en`, `ja`).
- Moegirlpedia is used as a separate source for ACG-related entries.
- Fandom is supported through its MediaWiki API, with full-article retrieval handled through `action=parse`.
- `converttitles=1` is enabled only for Wikipedia Chinese queries.

### Language-aware routing
- KOReader book metadata is used when available to determine the preferred language.
- The plugin can also be pinned to a specific language from settings.
- Japanese Moegirlpedia misses can fall back to `ja.wikipedia` when a result is not reliable.

### Localization
- Bundled translation files are provided for `zh_CN`, `zh_TW`, and `ja`.
- User-facing strings are wrapped with gettext.
- Locale files are loaded at startup for the active KOReader UI language.

### Runtime constraints
- Response bodies are capped at 2 MB.
- Network timeouts are reset explicitly after each request.
- Stale UI callbacks are guarded to avoid showing results after the reader view has changed.

---

## Installation

### KOReader AppStore
Search for **Dual Wiki** in `appstore.koplugin` and install it.

### Manual installation
1. Download `koreader-dual-wiki-v1.2.0.zip` from the [Releases](../../releases) page.
2. Extract the archive.
3. Copy `dual_wiki.koplugin` into your device's `koreader/plugins/` directory.
4. Restart KOReader.

Expected directory layout:

```text
koreader/
└── plugins/
    └── dual_wiki.koplugin/
        ├── _meta.lua
        ├── main.lua
        └── locale/
            ├── messages.pot
            ├── ja.po
            ├── zh_CN.po
            ├── zh_TW.po
            ├── ja/LC_MESSAGES/dual_wiki.mo
            ├── zh_CN/LC_MESSAGES/dual_wiki.mo
            └── zh_TW/LC_MESSAGES/dual_wiki.mo
```

---

## Usage

### From selected text
1. Select a word or phrase.
2. Open the highlight toolbar.
3. Choose the appropriate source button.
4. Use the candidate list to switch entries or refine the query.
5. Use the pencil icon to edit the current query or load the full article.

### From the main menu
The plugin also provides direct search entries for each supported source.

---

## Compatibility

- KOReader v2024 or newer.
- Designed for Kindle-class e-ink devices and similar low-resource readers.
- No runtime dependencies beyond KOReader's built-in Lua environment.

---

## Release notes

- Current version: `v1.2.0`
- Main additions in this release: language-aware retrieval, multi-engine routing, gettext localization, Fandom support, and Japanese Moegirlpedia fallback.

---

## License

Released under the **GNU Affero General Public License v3.0 (AGPL-3.0)**.
