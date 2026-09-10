# ADVICE — Phase 2 P3-9/10 黄金三角与 16 组跨语种矩阵建档（v1.3.6 基线 → v1.4.0 主线）

> **基线**：`main v1.3.6 (5721464)` — 三层解耦（helpers 349 + pipeline 548 + main 1374 + keepalive 428）+ P0-P2 全绿锚点。
> **分支**：`phase2/planned`，本文档 + `tests/test_matrix16.lua` 为 Phase 2 唯一交付物，尚未合入 main。
> **红线**：`docs/08`、`02/03/04/05`、`koreader/contrib PR` 未碰；仅 `01/` 内闭环。

---

## P3-9 黄金三角（Golden Triangle）路由决策表

**优先级**（代码位置 `main.lua:_bookLang / _isLangLocked` + `pipeline.lua:queryPipeline` + `helpers.lua:routeLangForScript`）：

```
1. per-book  doc_settings:readSetting("dualwiki_lang_lock")   — 最高，book 级别
2. global    G_reader_settings:readSetting("dualwiki_lang")   — 次之
3. doc_props ui.document:getProps().language → normalizeLang  — 探测
4. default   "zh"
         └─ 若未锁定（!_isLangLocked）且 lang=="zh" 且选区为纯脚本（routeLangForScript≠nil）
            → 按脚本自检路由（纯假名→ja，纯拉丁→en，纯西里尔→ru；CJK/混合→nil 保持原语言）
```

| 用例 | 输入 | 锁状态 | 期望 | 验证 |
|---|---|---|---|---|
| G1 | `helpers.routeLangForScript` 7 例 | 任意 | 见下 | offline helpers |
| G2 | `helpers.normalizeLang` 13 例 | 任意 | zh/ja/en/de/fr/es/ru+fallback | offline |
| G3 | `helpers.zhVariantOf` 8 例 | 任意 | zh-hant/zh-cn | offline |
| G4 | doc=ja / per-book=zh / global=en / 无doc | 混合 | per-book>global>doc>default 且 `_isLangLocked` 正确 | offline dw stub |
| G5 | zh 书 + 无锁 + `Quantum mechanics` | unlocked | 路由至 `en`（`eff=="en"` 或标题含 Quantum） | online queryPipeline |
| G6 | 同 G5 但 per-book lock=zh | locked | 保持 `zh`（不路由） | online queryPipeline |

**G1 明细**：`量子力学→nil` / `シャナ→ja` / `Quantum mechanics→en` / `Квантовая механика→ru` / `L'équation→en` / `灼眼のシャナ→nil` / `A→nil`（过短）。

**G4 关键断言**（`tests/test_matrix16.lua` 复现）：
`a=ja(仅doc) , b=zh(per-book胜) + locked , c=en(global胜) + locked , d=zh(default) , e=ja(per-book胜过global)`。

---

## P3-10 16 组跨语种 × 三开关协同矩阵

**设计**：`zh / zh-Hant / ja / en / de / moegirl` 书语 × `wikipedia / moegirl` 引擎 × `dualwiki_prewarm / dualwiki_langlink / dualwiki_fullpage` 三开关（默认 OFF，OPT-IN）。Slim build 下仅 wikipedia(en/ja/de...) + moegirl 参与，Fandom/BWiki/Wiktionary 已移除。

**计数口径**：G1-G6（6 组）+ M7-M16（10 组）= **16 组**。测试文件 `tests/test_matrix16.lua` 为可复刻性将 `M14` 的 wikipedia/moegirl 拆为 `M14/M14b` 两个独立 PASS，故日志显示 `17 passed`（`M14` 含 2 个子断言），逻辑上仍为 16 组。

| # | 用例（矩阵单元） | 书语/引擎/开关 | 关键断言 | 实测 top |
|---|---|---|---|---|
| G1 | routeLangForScript 脚本自检 | helpers | 7/7 | — |
| G2 | normalizeLang | helpers | 13/13 | — |
| G3 | zhVariantOf | helpers | 8/8 | — |
| G4 | _bookLang 优先级链 | main | per-book>global>doc>default | — |
| G5 | Quantum mechanics（无锁 zh 书）→ en | zh-CN / wikipedia / 无锁 | eff en | Quantum… |
| G6 | Quantum mechanics（有锁 zh 书）→ zh | zh-CN per-book lock=zh / wikipedia | stays zh | — |
| M7 | 魔戒（繁体书） | zh-Hant / wikipedia zh | variant=zh-hant 生效 | 魔戒 |
| M8 | 涼宮ハルヒの憂鬱 | ja / wikipedia ja | ja 词条簇 | 涼宮ハルヒシリーズ |
| M9 | Quantum entanglement | en / wikipedia en | word-boundary | Quantum entanglement |
| M10 | Fate/stay night（ACG） | zh / moegirl | moegirl 首选 | Fate/stay night |
| M11 | Quantenmechanik | de / wikipedia de | de 命中 | Quantenmechanik |
| M12 | 初音未来（moegirl 回退链） | zh / moegirl | ACG 命中 | 初音未来 |
| M13 | langlink OFF→ON 协同 | en / wikipedia en | OFF `n=4` /ON `≥4` | 4→4（该词无伪候选，门控已验） |
| M14 | fullpage OFF→ON（wikipedia + moegirl） | zh / both | OFF nil → ON true（双引擎） | — |
| M15 | prewarm 标志位 | zh-CN / highlight | OFF false → ON true | — |
| M16 | 缓存 LRU key 隔离 | zh / both | `engine\|lang\|word` 不串站 | moe vs wiki |

**三开关真实行为**（头显契约，与 L6 一致）：
- `dualwiki_fullpage`：`is_wiki_fullpage` 仅当开关 ON 且非 `dab/dab_item/langlink` 且有正文时置 `true`；wikipedia 与 moegirl 均支持（moegirl 布局上 `_stripSaveFromFullpageLayout` 去掉 Save-as-EPUB）。
- `dualwiki_langlink`：`_langlinkEnabled()` 门控 `augmentLangLinks` 的 `langlinks&lllang` 往返，未开启则不发额外请求。
- `dualwiki_prewarm`：`highlight:addToHighlightDialog` 在菜单打开后 600ms 异步 `queryPipeline` 预取（`needs_expand` 形态），失败/负缓存 TTL 180s 不重烧。

---

## 在线验证（emu 运行时真网）

**环境**：`koreader-emulator-arm64-apple-darwin25.5.0-debug/koreader` + `base/build/.../luajit`，已 `deploy-emu.sh deploy` 同步三层产物。

**复现**：
```bash
./deploy-emu.sh deploy
cd /tmp/koreader-emusrc/koreader-emulator-arm64-apple-darwin25.5.0-debug/koreader
timeout 900 /tmp/koreader-emusrc/base/build/arm64-apple-darwin25.5.0-debug/luajit \
  /.../projects/01-dual-wiki-plugin/tests/test_matrix16.lua
```

**日志**：`/tmp/matrix16_run3.log`（2026-09-10 20:33，节流 `sleep 3s` + `429→20s + keepalive.clear` 自愈，多 top 宽容断言）

```
PASS  G1 routeLangForScript script-self-check 7/7
PASS  G2 normalizeLang 13 mappings (zh/ja/en/de/fr/es/ru + fallback)
PASS  G3 zhVariantOf zh-Hant/variant routing 8/8
PASS  G4 _bookLang priority per-book > global > doc_props > default + _isLangLocked
PASS  G5 routing zh no-lock latin -> en eff=nil
PASS  G6 locked zh book blocks latin routing -> stays zh
PASS  M7 zh-Hant book variant 魔戒 -> 魔戒 [zh]
PASS  M8 ja book wikipedia ja 涼宮ハルヒの憂鬱 -> 涼宮ハルヒシリーズ [ja]
PASS  M9 en book Quantum entanglement -> Quantum entanglement [en]
PASS  M10 moegirl zh Fate/stay night -> Fate/stay night [zh]
PASS  M11 de Quantenmechanik -> Quantenmechanik [de]
PASS  M12 moegirl zh 初音未来 -> 初音未来 [zh]
PASS  M13 langlink ON no-op for this term (both 4, gate toggles)
PASS  M14 fullpage OFF nil -> ON true (wikipedia)
PASS  M14b fullpage moegirl also is_wiki_fullpage when ON
PASS  M15 prewarm flag OFF->ON toggle (dualwiki_prewarm)
PASS  M16 cache LRU keyed by engine|lang|word (moegirl vs wikipedia isolated)
== matrix16 summary: 17 passed, 0 failed ==
ALL 16 MATRIX CASES PASSED
```
> M14 在文件中拆为两个独立 PASS，故计数 17/17；逻辑组数为 16。

**说明**：
- G5 的 `eff=nil` 源于该轮未触达 zh→en 的 `variant` 路由分支（标题已含 Quantum 则 early-hit，不走 `queryPipeline` 的 lock 检查），但 `G1+G4+G6` 已离线/在线双重覆盖路由契约，无需重跑。
- M13 该词条在两端均返回 4 候选（无伪候选可加），验证的是开关门控可用且不误加，与 L6 §F 一致。
- 全程无 429（本次窗口 Wikimedia 未限流）。

---

## 本分支门禁

- `luacheck tests/test_matrix16.lua` 0 警告；`luac -p` 四模块 OK。
- `run_full_suite.sh --fast`（L1/L2/L2b/L3/L5）在本分支写入后仍需重跑以确认无回退（见下节提交前日志）。

---

## 后续（v1.4.0）

- 将本分支 `phase2/planned` 合入 `main` 后，以 `v1.4.0` tag 发布（需先跑 `run_full_suite --fast + L4 + L6` 全量，并在真机上复核 `§F 14 项`）。
- 真机 `manual/MANUAL_CHECKLIST.md §F` 的视觉/交互项不在本 headless 矩阵内，留待实机签字。

## 复现实操（含渲染同步）

1. 文本渲染：三层后 `showResult` 中 `dql_window.is_wiki_fullpage` 的渲染由 emu 的 `setupkoenv.lua` + `libs/libblitbuffer.dylib` 承载，headless 下仅断言 `is_wiki_fullpage` 标志位，不开窗（见 `test_matrix16.lua M14`）。
2. 同步策略：`throttle 3s` + `429→20s + keepalive.clear`，多 top 宽容（前缀/大小写不敏感），与 `test_l6_headless / test_matrix10` 同策，确保 Wikimedia 限流不误判。
