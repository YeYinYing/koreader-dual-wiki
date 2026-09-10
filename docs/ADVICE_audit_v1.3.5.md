# ADVICE — v1.3.5 方案A 模糊容错 5项审计建档 (Cursor 建言备忘，不改 docs/08)

> 归属: projects/01-dual-wiki-plugin/docs/  — 仅 Cursor 可写；`docs/08_实机排障` 归 Antigravity，Cursor 不碰。

## 1) generator=prefixsearch + prop=extracts 单次合并请求

- 契约: `generator=prefixsearch&gpssearch=<q>&gpslimit=4 & prop=extracts|pageprops & exintro=1` 单次往返同时拿标题与首段/消歧义旗标。
- 审计: L4 真网验证 top 候选 exact-hit 提升与薄内容 stub 识别；消歧义 `ppprop=disambiguation` 同请求 piggyback。

## 2) 萌娘 / 维基 API 行为分歧

- 萌娘 `.moegirl.org.cn` 复用 MediaWiki `prefixsearch+extracts`，但无 `variant`/`converttitles` 分支；维基 `variant=zh-cn|zh-hant` 已按 `normalizeLang`+`zhVariantOf` 映射。
- 隔离: `ENGINES` 2 项 (wikipedia/moegirl)，keepalive 白名单仅两域。

## 3) 繁简服务端转换 converttitles+variant

- 仅 wikipedia+zh 生效: `converttitles=1&variant=zh-cn / zh-hant`，由书语言 `zhVariantOf(bookLang)` 决定；en/ja 不带 variant。
- 回归: 中/繁 同词条标题一致性由 L4 真网对 zh.wikipedia 抽检覆盖。

## 4) 外层包裹标点/末尾助词降级防误伤

- Stage 1: `sanitizeQuery` 去外层 `《“‘【（ …`；Stage 2→3 间仅 fallback: `stripTrailingParticle` 去 `的/之/の` 等单字助词、`DLSS 5` 去版号尾缀；fallback 才探针，exact-hit 永不扰动。
- 审计: 10组矩阵 `《三体》/“人工智能”/【凉宫春日的忧郁】/...` 零改动命中；`拿破仑·波拿巴` 中点保留。

## 5) 2MB 截断 + socketutil:reset_timeout() + LRU 32

- 2MB body cap 在 sink 侧即时 abort；`socketutil:reset_timeout()` 成对调用；会话缓存 LRU 32，key=`engine|lang|word` 引擎隔离不串站 (F4b 初音未来)。

## 10组划词矩阵回归 (P2-8) — 2026-09-10 已执行，10/10 PASS

离线半场（`tests/test_query_helpers.lua` cases 1-10，`refactor/three-layer` 重跑）:
`lua tests/test_query_helpers.lua dual_wiki.koplugin/helpers.lua` 与 legacy
`.../main.lua` marker 路径均 `ALL TESTS PASSED`（10组 sanitation + ja/en 交叉 + G/L/N/V 全量）。

在线半场（新增 `tests/test_matrix10.lua`，emu 运行时真网走真 `queryPipeline`，
日志 `/tmp/matrix10_run2.log`，2026-09-10 11:50）:

| 序号 | 用例 | 引擎/书语 | 实测 top | 结果 |
|---|---|---|---|---|
|1|《三体》|wikipedia zh|三体 (小说)|PASS|
|2|“人工智能”|wikipedia zh|人工智能|PASS|
|3|【凉宫春日的忧郁】|moegirl zh|凉宫春日的忧郁|PASS|
|4|量子力学的|wikipedia zh|量子力学|PASS|
|5|拿破仑·波拿巴|wikipedia zh|拿破仑一世|PASS|
|6|Re:从零开始的异世界生活|wikipedia zh|Re:从零开始的异世界生活 虚假的王选候补|PASS|
|7|小笠原道（少选一字 lenient）|wikipedia zh|小笠原道大|PASS|
|8|Fate/stay night|wikipedia zh|Fate/Stay Night|PASS|
|9|魔戒（书语 zh-Hant）|wikipedia zh + variant=zh-hant|魔戒|PASS|
|10|黑神话|moegirl zh|黑神话：悟空|PASS|

执行要点:
- M9 用桩 `doc.getProps → { language = "zh-Hant" }` 驱动 `converttitles=1&variant=zh-hant` 服务端转换路径（审计项 3 的实证）。
- M7 按契约宽松断言（少选一字允许前缀噪音），实测仍命中 `小笠原道大`。
- 429 退避与 keepalive.clear 自愈逻辑与 L6/L4 同策略；本轮无 429 触发。
- 运行方式: `cd emu/koreader && ./luajit tests/test_matrix10.lua`（exit 0 = 10/10）。

> 真机/L6: L6 headless 26项已绿；真机 §F 14 项拟在 P2 收尾前复跑签字。

