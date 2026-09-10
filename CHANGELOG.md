# Changelog

## [1.3.6] - 2026-09-10 — three-layer decoupling complete, P0-P2 green anchor

### Changed — architecture (v1.4.0 groundwork, frozen as a stable anchor)

- **Three-layer split of the 2399-line god file**: `main.lua` 2399→1374 (UI only),
  `helpers.lua` 349 (pure functions, zero deps — single source of truth for the
  former `query-helpers` block), `pipeline.lua` 548 (ENGINES / httpGet with
  2 MB cap + 429 backoff + keepalive pool / fetchCandidates / fetchDirect /
  fetchDisambiguationItems / expandDisambiguation / augmentLangLinks /
  _expandAllFullText / queryPipeline), `keepalive.lua` 428 unchanged.
  `main.lua` consumes helpers via `local H = require("helpers")`.
- **Zero-loss facade**: `DualWiki.queryPipeline / fetchCandidates / fetchDirect /
  fetchDisambiguationItems / expandDisambiguation / augmentLangLinks /
  _expandAllFullText / fetchDirectAndShow` signatures 100% invariant;
  `DualWiki._httpGet / _keepalive` re-export `pipeline.httpGet / pipeline.keepalive`.
  The 1837-line automation suite passes unmodified.
- `tests/test_query_helpers.lua` now defaults to `dual_wiki.koplugin/helpers.lua`
  (the inline mirror in main.lua — and the legacy main.lua extraction path — is gone).
- Defensive: `onShowKeyboard` calls are pcall-guarded so headless harnesses with
  widget stubs no longer abort (real InputDialog unaffected).

### Verified — release gate (all green on this anchor)

- L1 luacheck 0 warnings / 0 errors · L2 helpers unit · L2b keepalive unit ·
  L3 emulator smoke (plugin loads, plugins=33) · L4 real-network integration
  ALL PASSED · L5 coexistence conflicts ALL PASSED · L6 headless 26 items ALL PASSED.
- P2-8 10-group selection matrix 10/10 (offline helpers + online pipeline,
  `tests/test_matrix10.lua`): 《三体》→三体 (小说) · “人工智能” · 【凉宫春日的忧郁】 ·
  量子力学的→量子力学 · 拿破仑·波拿巴→拿破仑一世 · Re:从零… · 小笠原道→小笠原道大 ·
  Fate/stay night→Fate/Stay Night · 魔戒 (book lang zh-Hant → variant=zh-hant) ·
  黑神话→黑神话：悟空.
- Release ZIP now ships 5 Lua modules (`_meta/main/helpers/pipeline/keepalive`)
  plus the 4 bundled `.mo` locales.

## [1.3.5] - 2026-09-09 — slim build, immersive reading & native takeover

### Removed — slim build (user-directed scope reduction)

- **Engines: Fandom / BWiki / Wiktionary** and the `action=parse` full-text adapter (`fetchParseArticle`, `fullTextViaParse`, `_engineSub`): the plugin is now Moegirlpedia + Wikipedia only. The `ENGINES` registry shrinks 5→2; every parse-engine branch (`fetchCandidates` title-only params, dab `action=parse` wikitext path, `_expandAllFullText` routing, `want_full` routing) is gone; the 1.5 MB Fandom full-page decode risk is eliminated structurally.
- **Wikidata round trips**: the sitelink notability re-rank (E1, `wbgetentities` over candidate QIDs) and the Wikidata bridge (E4, pencil-on-QID → sitelink → target-language article) are removed — `qid` no longer rides `pageprops`, `_last_candidate_qids` is gone, and `www.wikidata.org` drops off the keepalive whitelist.
- **Query rewriting for European selections** (user direction "选什么搜什么"): the leading-elision strip (`l'amour→amour`, fr/it/pt), German fusional contractions (`zum Beispiel→Beispiel`), European phrase-particle trailing strips (`L'histoire de→L'histoire`, `historia del→historia`, `Theorie der→Theorie`), and the Stage 1b competition probe are removed. The selection is searched exactly as written; only CJK/JA/EN possessive-particle handling remains. L2/L4 regression cases re-pinned to the literal-search contract (`L'équation` → `L'Équation de l'apocalypse` is now the DESIRED result).
- **Preferred-engine picker** (E9): `_preferredEngine` / `ENGINE_CHOICES` / `engineRadioRow(s)` and both menu submenus are gone; the button plan is purely book-language-driven (`BOOK_BUTTON_PLANS`).

### Added

- **Immersive fullpage reading, restored as a first-class Dual Wiki feature** (F1): v1.3.5's takeover of the native Wikipedia button silently removed KOReader's "read Wikipedia in a fullscreen window" experience (core's `is_wiki_fullpage` channel: window at `Screen:getWidth() - 2*margin`, button bar fixed to `[Save as EPUB][Close]`). Dual Wiki now provides the same channel natively:
  - New `Full article` button in Dual Wiki result windows: re-opens the currently viewed candidate as a fullpage window via core's `is_wiki_fullpage` contract. The definition is already full text (G2), so the common path needs zero network — an exact-title replay from the session cache (`_cachedFullpageCandidates`); a cache miss falls back to one `fetchDirect` round, mirroring native semantics. Native `Save as EPUB` works inside wikipedia fullpage windows untouched (core code path, `Wikipedia:createEpubWithUI`).
  - New setting `默认以全屏打开结果 / Open results fullscreen by default` (`dualwiki_fullpage`, default OFF): when enabled, plain candidates carry `is_wiki_fullpage` on their result entries, so windows open fullscreen directly. Hard exclusions keep the EPUB contract safe: dab/disambiguation index entries, cross-language pseudo-candidates, and candidates without a real extract.
- **Moegirlpedia now fullscreen-eligible** (F1b): the F1 fullpage channel extends to the moegirl engine — 萌娘百科 long articles get the same comfortable full-window reading. The epub-save red line is kept via a class-level hook (`_patchFullpageLayout` → `_stripSaveFromFullpageLayout`): core's fixed `[Save as EPUB][Close]` fullpage bar has the Save button stripped from moegirl windows only (its path, `Wikipedia:createEpubWithUI`, can only fetch from `{lang}.wikipedia.org` — the wrong site for moegirl titles). Wikipedia windows keep `[Save as EPUB][Close]` untouched.
- **Engine-matched cache replay**: `_cachedFullpageCandidates` now matches session-cache entries by engine (`engine|lang|word` keys), so a moegirl `Full article` re-show can never replay a wikipedia round — the same title (初音未来) lives on both sites with different content.
- **Native-takeover switch** (F2): the P2 takeover (dict button rewire + removal of the three core menu entries + in-window hold routing) is now gated on a setting, `接管原生 Wikipedia 按钮与菜单 / Take over native Wikipedia entry points` (default ON — existing behavior unchanged). With `dualwiki_no_takeover = true` (set via the toggle): core keeps its `wikipedia_lookup` / `wikipedia_history` / `wikipedia_settings` menu entries, the dict-window `Wikipedia` button reverts to core's own spec (auto-replacing `Full article` with its native fullscreen + EPUB channel), and the ≥3s in-window hold flips domains into native `ReaderWikipedia` again. The dict button uses `show_func`, so the reversion applies from the very next window build without restarting.

### Changed (user acceptance round 3, problems 1–5 + slim follow-ups)

- **Unified selection entry, step 1** (P1): a single-word hold-release no longer jumps straight into the native dictionary window (the `diss` popup). `ReaderHighlight:lookupDictWord` is rerouted to the highlight selection page; the real dictionary stays one tap away via the page's own `Dictionary` button (core `06_dictionary` → `lookupDict` is untouched). Dictionary windows reached through that button keep core behavior.
- **Native Wikipedia takeover** (P2 / F2): the core `Wikipedia` button inside every DictQuickLookup window is re-wired to `DualWiki:lookup` via the same-id button-spec override (`ui.dictionary:addToDictButtons`), so it now runs the book-language plan with our routing and our title instead of core's private `wikipedia_last_language` memory — the "searched EN, title said ZH" split-brain source. The ≥3s in-window hold that flipped domains into core `ReaderWikipedia` is routed through Dual Wiki as well (`DictQuickLookup.lookupDictionaryOrWikipedia` wiki branch). Book search (`Search` id) is untouched. The three core menu entries (`wikipedia_lookup` / `wikipedia_history` / `wikipedia_settings`) are removed from the search menu — but only while the F2 takeover toggle is ON (default).
- **Effective-language propagation** (P3): `queryPipeline` now returns the language its content is actually in as a third value (Stage 3's zh→en fallback and Stage 6's moegirl→wikipedia degrade used to switch language internally while the caller kept stamping the requested one on the window title). `lookup` threads the effective language through the result window title, the langlink bridge, and the session cache (entries carry `lang`), and the miss path consumes it for the retry dialog too.
- **In-dialog language switch** (P3): the article-search dialog grows a `ZH / EN / JA` row (per engine: wikipedia 3, moegirl 2). Tapping a language searches with that language immediately, or re-opens the dialog with the new title when the input is still empty.
- **Version-tail and spaced-particle degradation** (P4): two new fallback variants between Stage 2 and Stage 3 — a trailing space+digit edition token is dropped (`DLSS 5` → probe `DLSS`), and a space-delimited trailing particle is stripped (`DLSS 5 的` → probe `DLSS 5`, then `DLSS`). Fallback-only: exact hits in Stage 1 (titles genuinely containing numbers, e.g. `Final Fantasy VII`) always win, and the window word stays what the user selected.
- **Single "Dual Wiki" menu** (P5): the seven flat top-level search entries collapse into one `Dual Wiki` submenu containing the lookups plus `Dual Wiki settings`. Grouping is a preference surface to iterate on; the wiring is unchanged.
- **de/fr/es/ru surface per book** (user direction "只自动供应给相对应的书"): the four European languages stay in `LANG_MAP` (`ger/deu`, `fre/fra`, `spa`, `rus`) and `BOOK_BUTTON_PLANS` gets 4 plans (`[Wikipedia (XX)] [Wikipedia (EN)]`), but plans materialize only when the book itself is that language; `LATIN_LANGS` re-includes them so word-boundary good-hits work in their own books only; the language-lock menu is dynamic (`sub_item_table_func`): core `auto/zh/en/ja` always, an EU code appears only when the current book is that language OR the user has explicitly locked it.
- **Prewarm and cross-language bridge are opt-in** (user direction "藏设置"): `dualwiki_prewarm` (default OFF) and `dualwiki_langlink` (default OFF, gating `augmentLangLinks`) — heavy users enable them in settings.
- Main menu is now 4 entries (Moegirl / Wikipedia (book lang) / Wikipedia EN / Wikipedia JA) + settings; settings hub is 8 entries (2 language locks, fullscreen, takeover, prewarm, cross-lang, cache clear).
- `main.lua` ~2600 → ~2220 lines; keepalive whitelist is `.wikipedia.org` + `.moegirl.org.cn` only.
- `showResult` drops the `fandom→en` result-language special case.

### Fixed (burn-in)

- **Always-full result windows** (G2, user direction during burn-in): result windows no longer show the probe's lead-section summary at all — every accepted candidate (exact hits, redirect winners, dab-expansion senses, search-fallback entries, cross-language pseudo-entries) is swapped for its FULL article text before display, regardless of lead length. The pipeline keeps its exact role (find the right titles; all stage logic unchanged); the new display step fetches one prop=extracts per title. A structurally failed fetch keeps the lead (graceful); a transport failure short-circuits and the round is never cached (E6 contract), so a healed network re-fetches. Replaces the earlier G1 thin-only upgrade and G1b pencil-expansion experiments (same unreleased version, superseded before any release). Motivation: moegirl's 黑桐干也 carries a 30-char lead with the body in `== 简介 ==`, and long-lead pages were equally summary-only — verified live that both now return multi-KB bodies (9738 chars for 黑桐干也). The highlight prewarm performs the same expansion so the button tap replays a full-text cache hit; candidate windows therefore cost 1 probe + N full fetches for N candidates.
- **Pencil restored to query editing** (user direction): the pencil icon keeps its v1.3.4 behavior — cross-language branches still load those full articles directly, everything else reopens the search dialog prefilled for editing the query. With G2 there is nothing left for a plain candidate's pencil to expand. The empty-extract candidate label drops the stale "tap the pencil to load the full article" wording (it described pencil behavior that no longer exists and never matched the dialog fallback).
- **Perf: highlight-menu freeze eliminated** (G2c, burn-in finding): the first G2 cut expanded EVERY candidate of a window synchronously — up to 4 (prefix) / 8 (search fallback) / 10 (dab senses) full-page JSON decodes of 50 KB-1 MB each — and the highlight prewarm did the same on the UI thread 0.6 s after the menu opened. On-device effect: the whole app froze for seconds at every highlight (taps on any button — the dictionary included — only processed after the freeze; no crash, just main-thread starvation). Now the prewarm lands only the cheap probe result (cache entry marked needs_expand) and the TOP candidate — the one the window opens on — is expanded behind the "Querying" progress message at button-tap time: one heavy request, visible feedback, highlight-menu latency back to the v1.3.4 baseline. Remaining candidates keep their lead summaries; wanting more goes through the pencil (edit query).

### Tests

- L4 integration (stubbed UI): new cases — F1 fullpage default OFF / opt-in fullpage (wikipedia + moegirl) / dab excluded / zero-network cache replay (engine-matched); F2 takeover default ON / OFF gate / native menu entries kept when OFF / removed when ON.
- L6 headless supplement (`tests/test_l6_headless.lua`) re-pinned to the slim contract: fandom/bwiki/wiktionary fetches and the B4 subdomain swap are gone, A5b re-pinned to the literal-search contract, and new headless cases cover the F1/F2 contracts (fullpage flag matrix, save-strip contract, engine-matched replay, takeover gate) — headless suite green in the emulator runtime.
- L1–L5 all green (L4 live-network suite passed after the F1/F2 additions; the en-dab expansion case got the standard bounded-retry hardening against 429 flakiness).

### Infrastructure

- Locale: `Dual Wiki` and `Wikipedia` msgids added, plus 3 new msgids (`Full article`, `Open results fullscreen by default`, `Take over native Wikipedia entry points`) in `messages.pot` + zh_CN/zh_TW/ja/en with translations, all `.mo` recompiled.

## [1.3.4] - 2026-09-08 — release hardening & manual QA

### Added

- **Keepalive host whitelist**: the hand-rolled HTTP/1.1 reader now only speaks to the MediaWiki hosts the ENGINES table can produce (`*.wikipedia.org`, `*.wiktionary.org`, `*.wikidata.org`, `*.moegirl.org.cn`, `*.fandom.com`, `wiki.biligame.com`). Any other host returns nil from `request()` and falls back to the untouched legacy `ssl.https` path. Suffix impostors (`evil-wikipedia.org`, `wikipedia.org.evil.io`, bare `wikipedia.org`) are rejected; a 16-case matrix pins the contract in `tests/test_keepalive.lua` (K33–K48).
- **Opt-in strict TLS verification**: setting `dualwiki_tls_strict = true` in `settings.reader.lua` switches the pooled transport to `verify="peer"` with a probed CA bundle (Debian/Kobo, RHEL, macOS, FreeBSD paths). Default remains `verify="none"` — e-ink devices boot with wrong clocks and stale CA bundles, and mandatory peer verification would break lookups for most users. When no CA bundle is locatable the mode degrades to lenient with a one-time logged warning. No menu entry: advanced, settings-file-only.
- **Standard testing pipeline**: `tests/TESTING_SOP.md` documents the six-layer release gate (L1 static → L2/L2b unit → L3 smoke → L4 real-network integration → L5 coexistence → L6 manual on-device) with per-layer pass criteria, a change-type → minimum-layers matrix, and flaky-handling rules. `run_full_suite.sh` orchestrates L1–L5 in one command with per-layer logs under `/tmp/dw_test_logs/` and a timing summary.
- **L6 headless supplement**: `tests/test_l6_headless.lua` covers the programmatically checkable manual-checklist items (A1–A11 core chain, B2–B5 settings logic) inside the emulator runtime. A9 asserts the session-cache contract through the real `lookup()`/`showResult()` path — a repeat lookup must complete with zero transport calls.

### Fixed

- **Subdomain hardening on every read path**: fandom and BWiki subdomain values are now capped at the 63-character DNS label limit on save AND on every read-back (`_defaultFandomSub`, `ENGINES.bwiki.defaultSub`), so hand-edited `settings.reader.lua` values cannot produce malformed URLs.

### Infrastructure

- **CI tag/version gate**: tag builds fail fast when the tag doesn't match `_meta.lua`'s `version`, blocking wrong-version release zips.
- **Full manual QA round (L6)**: all A/B/C checklist items passed in the macOS emulator (real frontend, PW3 viewport) with screenshots under `docs/screenshots/v1.3.3-l6/`; see `tests/L6_HANDOFF_TO_ANTIGRAVITY.md` for the signed report. L1–L5 all green the same day (integration 33/33 under 26 rate-limit events).

## [1.3.3] - 2026-09-07 — search quality & reader ergonomics

### Added

- **Disambiguation detection and expansion** (A1): the merged candidate request now piggybacks `prop=pageprops&ppprop=disambiguation`, so a Disambiguator-flagged top hit (en `Mercury`, ja `シャナ`, …) is no longer surfaced as a bare index page. The pipeline fetches the dab page's section-0 wikitext, extracts the curated `[[Title]]` bullets in the editor's semantic order (primary topic first; plain-text and descriptive-link bullets are rejected so ja descriptions like `[[英語圏]]の女性名…` or 漫画『[[9番目のムサシ]]…' never leak in), then fills every item's definition with ONE batched intro-extract request. Items are tagged 【消歧义义项】 and pencil-load normally. `prop=links` was rejected for this: it is anon-capped (pllimit ≤10) and reordered, which dropped the marquee 灼眼のシャナ entirely on ja.wp and ranked "Anna Kavan" above the planet on en.wp.
- **"Did you mean" suggestions** (A3): the Stage-5 search request carries `gsrinfo=suggestion`; when the whole ladder misses, the retry dialog shows a translated hint line (`您是不是要找：%1？`) and a one-tap `试查"%1"` button. Captured per-lookup round and cleared on read (a stale suggestion can never attach to a later failure).
- **European phrase particles** (B5): a second, word-level trailing-stopword table (`PHRASE_PARTICLES`, fr/es/it/de) feeds Stage 2's fallback — `L'histoire de` → `L'histoire`, `Theorie der` → `Theorie`. Matched case-insensitively via `caseFold`, whole tokens only (leading space required — `de Gaulle` survives), remainder ≥2 chars. Char-level `PARTICLES` still win first.
- **Selection script routing** (B7): `routeLangForScript` sniffs pure-Latin / pure-Cyrillic / pure-kana selections; a zh-defaulted book receiving such a selection routes straight to en/ru/ja.wikipedia BEFORE the first request (the result window label follows the routed language). Previously a Latin selection burned the zh probe (up to 3 requests) before Stage 3's fallback. Explicit language locks (per-book or global) are honored — routing only refines auto-detected languages; Stage 3 stays as the locked-zh safety net.
- **Italian elision + German fusional contractions** (E3): the Stage-1b bare-word probe now also strips Italian articulated prepositions (`dell'arte` → `arte`, `sull'isola` → `isola`; longest-match keeps `dell'` ahead of `d'`) and German leading fusions as a separate word-level pass (`zum Beispiel` → `Beispiel`, `Im Wald` → `Wald`; the trailing space in each pattern stops `Immer` from matching `im`). Fallback-only — titles genuinely starting with these forms hit exactly in Stage 1 and are never disturbed.
- **Sitelink notability re-rank** (E1): when NO exact hit exists and the top candidate is content-thin (<60 chars), one batched `wbgetentities` call fetches sitelink counts for every `wikibase_item` QID (piggybacked on the same probe request) and a clearly-more-notable entity (≥2× links, ≥8 wikis) is promoted to the front — `Bande` → the disambiguated primary topic instead of stub noise. Hard red lines: exact hits and dab pages are NEVER re-ranked; any failure keeps the server order.
- **Cross-language bridge** (E2): for wikipedia results whose language differs from the book's (or any non-zh result when reading a zh book), one `prop=langlinks` call on the top candidate appends the equivalent article as a trailing pseudo-entry (`→ 目标标题`); its pencil loads the full text in the target language directly. Silent on any failure.
- **Preferred engine per book** (E9): settings gain `首选引擎（本书）/（全局默认）` radio pickers. An explicit choice pins that engine's button into slot 1 (per-book wins over global); the remaining default-plan entry fills slot 2.
- **Highlight prewarm** (E8): when the highlight menu opens, the primary button's query is prefetched silently after a 600 ms debounce into the session cache (skipped when a fresh negative entry exists), so tapping the button replays a cache hit — the result window appears near-instantly. Toggle in settings, default on; never shows UI or error state.
- **Wikidata pencil bridge** (E4): candidates now carry their `wikibase_item` QID; the pencil on such a candidate resolves the entity's sitelinks (book language → zh → en) and loads that article's full text. No usable sitelink falls back to the search dialog — the pencil never dead-ends.
- **TLS keepalive pool** (E7): new `keepalive.lua` module keeps one idle TLS connection per wiki host and speaks HTTP/1.1 (Content-Length + chunked + close-delimited bodies, lowercase-folded headers, 2 MB abort cap preserved). Reuses measured in the integration suite (`opens=1, reuses=1` for back-to-back probes) save the 300-500 ms TCP+TLS handshake per request on e-ink devices. ANY anomaly — connect failure, mid-transfer break, oversized body, internal error — discards the socket and falls back to the legacy `ssl.https` path, which remains the single source of truth; `DUALWIKI_NO_KEEPALIVE` env (and a `keepalive.enabled` toggle for tests) pins the legacy transport. The pool is dropped on document close.
- **Wider search fallback** (E5): the Stage-5 generator=search request widens from 4 to 8 candidates (`gsrlimit`/`exlimit` move together, still ONE request). True `gsroffset` paging stays deferred: DictQuickLookup offers no clean button-extension point for a "more" affordance.
- **Negative lookup cache** (E6): a clean full-ladder miss (no transport error involved) is remembered for 180 s, so re-selecting the same dead word skips the ladder instead of re-burning 3+ requests (and the rate limiter's patience). Transport errors and Lua errors are never cached.

### Fixed

- **Dab item red links** (L1): bullets linking titles with no article yet (verified: 3 of ja `シャナ`'s items are red links) are now dropped via the batched extract response's `missing` flag — a pencil tap on them would have 404'd.
- **Dab extracts for redirect items** (L2): items that are redirects resolve server-side to a different title; extracts now propagate from the response title back to the bullet title via the `redirects` map, so every kept item carries its summary.
- **Dab item cap raised** (L3): 8 → 10 curated items; the batched extract pass tolerates it at the same `exlimit=20`, so more senses cost nothing extra.

### Infrastructure

- Integration suite: dab-expansion contracts asserted against live en.wp (`Mercury → Mercury (planet)` top) and ja.wp (灼眼のシャナ present among シャナ's items), with a bounded 3-attempt retry because a 429 can silently degrade an expansion; `assertPipeline` itself retries degraded ladders (the Wikimedia edge 429s aggressively under this suite's request pattern, which once let a transient Stage-1b failure masquerade as the v1.3.2 elision regression). New E7 section exercises the pool on the real network: sequential GETs reuse the socket, bodies stay valid, and a dead-port failure recovers cleanly.
- Unit matrix: phrase-particle cases (fr/es/it/de × hit/no-hurt), `routeLangForScript` matrix (Latin/Cyrillic/kana/mixed/digits), dab-flag parsing + QID passthrough, German fusion strip, and a new `tests/test_keepalive.lua` covering the pure response-head parser (status line, header folding, chunk sizes, body-mode decision) — the socket IO itself is exercised only by the integration suite.
- Locale: 9 msgids total across zh_CN/zh_TW/ja/en (60 translated each), `messages.pot` synced, all `.mo` recompiled.

## [1.3.2] - 2026-09-07

### Added

- **Romance elision fallback** (fr/it/pt): selections like `l'amour`, `qu'il`, `l'équation` now strip the elided leading article and probe the bare word BEFORE the literal query's verdict (Stage 1b), in both ASCII (`'`) and typographic (`’`) apostrophe forms, case-insensitively (`L'Étranger` at sentence start works). Longest-match protects `jusqu'à`; a remainder under 2 characters aborts the strip. Titles that legitimately start with an article (Les Misérables) hit exactly in Stage 1 and are never disturbed.
- **Search menu follows the book language**: one `Wikipedia lookup (XX)` entry (translated, `Wikipedia lookup (%1)`) replaces the fixed zh/en/ja trio, so de/fr/es/ru books finally have a manual Wikipedia search path.
- **Non-ASCII case folding (`caseFold`)**: byte-walking UTF-8 fold for Latin-1 Supplement (É È Ç Ü …), Latin Extended-A (Œ), and Cyrillic (А-Я, Ё/Є/Ї). Codepoint-1:1 mapping keeps byte lengths stable for the existing byte-index logic; zh behavior unchanged (identity fold).

### Fixed

- **French results poisoned by accented-capital deafness** (caught in human acceptance, root-caused by stage-by-stage network probes): every case-insensitive verdict (`hasGoodHit`, `sharesPrefix`, `parseCandidatePages` exact promotion) folded with Lua's `string.lower`, which is ASCII-only — `"Équation":lower()` stays `"Équation"` and never equals the stripped probe `équation` (byte 2 `C3 89` vs `C3 A9`). The elision probe fetched the right article but the verdict rejected it, the ladder degraded to Stage 6 and surfaced the `L'Équation…` prefix noise (a TV movie, the Bogdanoff essay, a novel). All three sites now fold through `caseFold`.
- **Result-window label for European languages**: `ENGINES.wikipedia.label` returned `Wikipedia (ZH)` for every non-ja/en language since the three-language era; de/fr/es/ru windows are now titled `Wikipedia (DE/FR/ES/RU)` (matches the dynamic highlight-button labels).
- **App crash when scrolling past the last result** (caught in the same acceptance round, root-caused from a captured crash log): the result table passed to `DictQuickLookup` used a `dictionary` field, but core's `changeDictionary()` reads `results[index].dict` for the window title. The first screen tolerated the missing field, but switching to another candidate — reached by wheel-scrolling past the end of a result, or tapping ◁◁/▷▷ — called `TitleBar:setText(nil)` and killed the app. Present since v1.2.0; results now carry the contract field `dict` (kept `dictionary` alongside).
- Switching the Fandom community or Bilibili game-wiki subdomain now clears the session lookup cache. The cache key (`engine|lang|word`) does not include the subdomain, so the previous community's results would keep resurfacing for identical words after a switch.

### Infrastructure

- Integration suite elision assertions upgraded from substring `find("quation")` — which the noise titles contain; this is exactly how the accented-capital bug escaped CI twice — to exact-title predicates (`top == "Équation"`) for both capital and lowercase `L'équation` against the live fr.wikipedia.
- Unit matrix gained `caseFold` coverage (Latin-1, Œ, Cyrillic, length stability) and accented good-hit/sharesPrefix/exact-promotion regression cases.
- `messages.pot` regenerated with the new `Wikipedia lookup (%1)` msgid; `Wikipedia lookup (%1)` translated across zh_CN / zh_TW / ja / en and all `.mo` recompiled.

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
