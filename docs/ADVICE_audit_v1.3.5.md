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

## 10组划词矩阵回归 (P2-8)

| 序号 | 用例 | 期望 |
|---|---|---|
|1|《三体》|去书名号后 zh.wikipedia 三体|
|2|“人工智能”|去引号后百科首条|
|3|【凉宫春日的忧郁】|去括号后日文/中文命中|
|4|量子力学的|去末尾助词 `的` 后仍命中|
|5|拿破仑·波拿巴|中点保留，全名命中|
|6|Re:从零开始|含冒号标题直达|
|7|小笠原道|萌娘/维基分流正确|
|8|Fate/stay night|斜杠保留|
|9|魔戒(繁)|繁简 variant 分流|
|10|黑神话|moegirl 首选|

> 真机/L6: L6 headless 26项已绿；真机 §F 14 项拟在 P2 收尾前复跑签字。

