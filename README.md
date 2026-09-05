<div align="center">

# Dual Wiki for KOReader

[![License: AGPL-3.0](https://img.shields.io/badge/License-AGPL_3.0-blue.svg)](LICENSE)
[![KOReader](https://img.shields.io/badge/KOReader-v2024%2B-orange.svg)](https://github.com/koreader/koreader)
[![Topic](https://img.shields.io/badge/Topic-koreader--plugin-green.svg)](https://github.com/topics/koreader-plugin)

**English** | [简体中文](README_zh-CN.md)

</div>

**Dual Wiki** is a zero-delay, dual-engine online encyclopedia lookup plugin for **KOReader** e-ink readers (Kindle, Kobo, Onyx Boox, Android).

It integrates **Moegirlpedia** — the wiki dedicated to anime, manga, gaming lore and internet culture — alongside a modernized, plain-text-streaming **Wikipedia** engine.

---

## 🌟 Key Features

1. **Dual Independent Entries**
   - Two side-by-side buttons, `萌娘百科` (Moegirlpedia) and `维基百科` (Wikipedia), appear in the text-selection highlight toolbar.
   - **Zero-invasive architecture**: runs entirely inside the plugin sandbox. No patches to KOReader core files.
2. **Spoiler Bar Revelation (Heimu)**
   - Moegirlpedia's signature `#252525` black spoiler bars are a pure CSS effect. Because the pipeline uses the MediaWiki `explaintext=1` plain-text mode, they never reach the display layer — covered text is always fully readable, with no solid black blocks on e-ink.
3. **Full-Length Uncapped Articles**
   - No more introduction-only snippets (`exintro`). Each request loads the entire article — thousands of words of biography, timelines or full plot analysis — with smooth pagination in the dictionary window.
4. **Sub-second Plain-Text Pipeline (~0.4s - 0.8s)**
   - Thumbnail fetching (`pageimages`) is stripped entirely, eliminating SSL handshake timeouts and HTTP 429 throttling stalls on slow Wi-Fi e-ink devices.
5. **Book-grade Typography**
   - MediaWiki markup headings (`== Chapter ==`, `=== Sub-section ===`) are automatically converted into elegant **`【Chapter】`** and **`▸ Sub-section`** lines.
6. **Cross-Engine Switching & Keyword Calibration**
   - When a query misses, a pre-filled retry dialog appears with **one-tap switching** to the other engine.
   - The native pencil icon in the lookup window opens a pre-filled edit dialog for trimming stray punctuation and re-querying.

---

## 📦 Installation

### Option A: KOReader AppStore (recommended)
Open `appstore.koplugin` on your device, search for **Dual Wiki**, and install.

### Option B: Manual Installation
1. Download the latest `koreader-dual-wiki-v1.0.0.zip` from the [Releases](../../releases) page.
2. Connect your reader to a computer, then copy the extracted `dual_wiki.koplugin` folder into the device's `koreader/plugins/` directory:
   ```text
   koreader/
   └── plugins/
       └── dual_wiki.koplugin/
           ├── _meta.lua
           └── main.lua
   ```
3. Restart KOReader.

---

## ⚙️ Architecture & Compatibility

- **Upstream-standard**: 100% aligned with current KOReader (v2024+) plugin guidelines; `_meta.lua` ships only `fullname` / `description` / `version` (no deprecated keys), designed for AppStore upgrade comparison.
- **Decoupled lookup window**: result windows explicitly use `is_wiki = false`, fully decoupled from the core `ReaderWikipedia` private methods and language handling.
- **Hardware-verified**: deeply tested on a Kindle Paperwhite 3 (i.MX6SL, 512 MB RAM) — zero resident memory footprint, resilient on weak networks (2 MB response cap, stale-UI callback guards).

---

## 📄 License

Released under the **GNU Affero General Public License v3.0 (AGPL-3.0)**, consistent with the KOReader ecosystem.
