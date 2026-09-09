# ADVICE — v1.4.0 三层零损解耦设计 (refactor/three-layer)

> 8.5 人天排期，单 commit 可 `git revert`，ZIP 锚点 v1.3.5 保留。

## 目标

- `main.lua 2220行` → `helpers.lua ~380 + pipeline.lua ~720 + main.lua ~1250 + keepalive.lua 428 (不动)`
- 零损: `DualWiki.queryPipeline/fetchCandidates/fetchDirect + _httpGet/_keepalive` 签名 100% 不变，1837行自动化零改动绿。

## 切分

- `helpers.lua` 纯函数零依赖: `sanitizeQuery/stripTrailingParticle/hasGoodHit/sharesPrefix/caseFold/routeLangForScript/parseCandidatePages/normalizeLang/zhVariantOf`，保留 `-- [[ query-helpers:start/end ]]` 标记兼容旧截取。
- `pipeline.lua` 侧效边界: `ENGINES/httpGet/fetchCandidates/fetchDirect/fetchDisambiguationItems/queryPipeline/_expandAllFullText`。
- `main.lua` 仅 UI: `DualWiki/_bookLang/_registerHighlightButtons/lookup/showResult/showFullpageResult/showRetryDialog/addToMainMenu`，末尾 `Facade Re-export` 保持外部契约。

## 验收

五套测试 + luacheck 全绿 + `unzip -l` 含 `_meta.lua/main.lua/helpers.lua/pipeline.lua/keepalive.lua` + 512MB 秒开 + Release 可被 AppStore 轮询。

## 节奏

- D1-2 helpers 抽离 + 标记兼容 + L2 绿
- D3-5 pipeline 抽离 + Facade + L2b/L4 绿
- D6 main 瘦身 + 菜单/手势回归 + L3/L5/L6 绿
- D7-8 文档/CHANGELOG 联动 + ZIP 校验 + 切回 main 合并

