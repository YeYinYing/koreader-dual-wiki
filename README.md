<div align="center">

# Dual Wiki for KOReader

[![License: AGPL-3.0](https://img.shields.io/badge/License-AGPL_3.0-blue.svg)](LICENSE)
[![KOReader](https://img.shields.io/badge/KOReader-v2024%2B-orange.svg)](https://github.com/koreader/koreader)
[![Topic](https://img.shields.io/badge/Topic-koreader--plugin-green.svg)](https://github.com/topics/koreader-plugin)

**English** | [简体中文](README_zh-CN.md)

</div>

Encyclopedia lookup plugin for KOReader e-ink readers. Supports Wikipedia (`zh` / `en` / `ja`), Moegirlpedia, and Fandom.

## Features

- Select text and look it up from the highlight toolbar, or type a query from the main menu.
- Conservative local query sanitization: strips only outer wrappers (`《》`, `“”`, `【】`, `『』`), keeps in-word punctuation.
- Language-aware trailing-particle trimming; English strips possessive `'s` only, never plural `s`.
- Word-boundary matching for Latin queries (`quantum` → `Quantum mechanics`, not `Wookieepedia` for `wo`).
- Single-request candidate retrieval with summaries on the main path; pencil action upgrades to the full article.
- Language-aware routing from KOReader book metadata, with a manual override in settings.
- Japanese queries fall back to `ja.wikipedia` when Moegirlpedia results are unreliable.
- `converttitles=1` is used only for Wikipedia Chinese queries.
- Fandom full articles are retrieved via `action=parse`.
- gettext localization for `zh_CN`, `zh_TW`, and `ja`, loaded at startup from the active UI language.
- Response bodies capped at 2 MB; explicit timeout reset; stale UI callbacks guarded.

## Installation

Install from the KOReader AppStore (`appstore.koplugin`), or download `koreader-dual-wiki-v1.3.1.zip` from the [Releases](../../releases) page and extract it to `koreader/plugins/`:

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

Restart KOReader after installation.

## Usage

1. Select a word or phrase.
2. Open the highlight toolbar and choose a source.
3. Browse ranked candidates or refine the query.
4. Use the pencil icon to edit the query or load the full article.

## Compatibility

- KOReader v2024+.
- No runtime dependencies beyond KOReader's built-in Lua environment.

## Release & upstream boundary

- The plugin is included in the official KOReader plugin repository ([koreader/contrib](https://github.com/koreader/contrib)); the official AppStore polls this repo's GitHub Releases directly and auto-pushes updates to users.
- Routine development, bug fixes, and minor versions (v1.3.1, v1.3.2, …) are released exclusively in this repository — no upstream PRs. The contrib submodule pointer may lag personal releases without affecting user updates.
- Only a cross-generation major version (e.g. v2.0.0), at the author's explicit decision, warrants a pointer-bump PR to `koreader/contrib`.

## License

GNU Affero General Public License v3.0 (AGPL-3.0).