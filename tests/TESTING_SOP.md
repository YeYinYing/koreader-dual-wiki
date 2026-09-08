# DualWiki 标准测试流程 SOP（v2）

> 目标：任何一次改动，从"改完代码"到"可以发布"，走同一条可重复的流水线。
> 每一层是下一层的前置门禁；上层失败时不继续跑下层。
> 模拟器 = KOReader macOS emulator（真实前端 LuaJIT 2.1 + LuaSec + SDL3），行为与真机一致。

---

## 0. 环境前置（一次性）

| 依赖 | 检查命令 | 期望 |
|---|---|---|
| KOReader emu 源码+构建 | `ls /tmp/koreader-emusrc/koreader-emulator-*/koreader/reader.lua` | 存在 |
| emu LuaJIT | `/tmp/koreader-emusrc/base/build/*/luajit -v` | LuaJIT 2.1 |
| gnu-getopt/findutils | `which getopt`（PATH 含 homebrew gnu 版） | deploy-emu.sh 依赖 |
| 测试书库 | `ls /tmp/koreader-emu-home/library/ | wc -l` | 8 本多语言 epub |
| 网络 | 能访问 wikipedia/moegirl/fandom/biligame/wiktionary | 集成层需要 |

环境坏了重建：`cd /tmp/koreader-emusrc && ./kodev build`。

---

## 1. 测试层级总表

| 层 | 名称 | 命令 | 时长 | 网络 | 通过门禁 |
|---|---|---|---|---|---|
| L1 | 静态检查 | `luacheck dual_wiki.koplugin tests`（本地等价 `tools/luacheck_runner.lua`） | ~5s | 无 | 0 error / 0 warning |
| L2 | 语法+单测 | `./deploy-emu.sh test`（test_query_helpers.lua） | ~2s | 无 | ALL TESTS PASSED |
| L2b | 传输层单测 | `luajit tests/test_keepalive.lua dual_wiki.koplugin/keepalive.lua` | ~1s | 无 | ALL TESTS PASSED（含白名单矩阵） |
| L3 | 部署+冒烟 | `./deploy-emu.sh deploy && ./deploy-emu.sh smoke 15` | ~25s | 无 | "SMOKE OK: dual_wiki loaded" |
| L4 | 集成测试（真实网络） | `./deploy-emu.sh integration` | **5–7 min** | **需要** | 33 项全 PASS，exit 0 |
| L5 | 共存冲突测试 | `./deploy-emu.sh conflicts` | ~10s | 无 | ALL CONFLICT TESTS PASSED |
| L6 | 在机人工验收 | `./deploy-emu.sh run` + `tests/MANUAL_CHECKLIST.md` | 15–30 min | 需要 | 清单全 ✅，签署 |

一键编排（L1→L5，L6 人工）：**`./run_full_suite.sh`**。
CI（GitHub Actions）固定跑 L1/L2/L2b/locale 一致性；L3–L6 为本机流程。

---

## 2. 各层详细说明

### L1 静态检查
- 覆盖：`dual_wiki.koplugin/` + `tests/` 全部 Lua。
- 判定：任何 error/warning 都算失败；豁免必须写进 `.luacheckrc` 并注明理由。
- CI 同步：CI 用 luacheck 0.26.1 + lua51 std，与本地 runner 同版本。

### L2 语法 + 单元测试
- `test_query_helpers.lua`：纯函数层（sanitize/particles/elision/caseFold/
  routeLangForScript/hasGoodHit/sharesPrefix/parseCandidatePages/…）。
- `test_keepalive.lua`：HTTP 头解析、chunked、2MB cap、**host 白名单矩阵**（K33–K48）。
- 判定：`ALL TESTS PASSED`；任何 FAIL 即回退修复，禁止带病进 L3。

### L3 部署 + 冒烟
- `deploy` 把插件拷入 emu 运行时并重建 8 本测试书。
- `smoke 15`：无头启动完整 reader 15s，断言日志出现 `Plugin loaded dual_wiki`。
- 判定：SMOKE OK；出现 Lua error traceback 即失败（即使加载成功）。
  检查方式：`tail -50 /tmp/ko_smoke.log`。

### L4 集成测试（真实网络，本 SOP 的核心层）
- 覆盖（33 项）：
  - 确定性 429 stub（自动重试语义：恰好 2 次请求）
  - keepalive 连接池：顺序复用、死端口恢复、fast-path 证明
  - queryPipeline 七语言真实命中 + B7 脚本路由
  - fr 省音大小写两形态精确命中 Équation（v1.3.2 回归）
  - dab 展开（Mercury/シャナ）、did-you-mean（Catte→cattle）
  - moegirl 降级、三引擎 parse 两段式、坏 fandom 子域短路
  - dict 字段滚动崩溃回归、B7+A1 组合 lookup、A3 建议按钮关闭目标
- 已知环境噪声（非 bug，测试内置韧性）：
  - Wikimedia 限流 429 风暴 → 套件自带 throttle + 最多 3 次重试
  - moegirl 在部分网络不可达 → 断言允许降级路径
- 判定：`ALL INTEGRATION TESTS PASSED`，exit 0。
  有任何 FAIL：修复 → 从 L1 重跑全链（不许只重跑 L4）。

### L5 共存冲突
- 在 emu 内与 vocabbuilder + gestures + coverbrowser 共同加载真实代码。
- 断言：settings 命名空间不越界（只写 `dualwiki*`）、事件不吞噬、菜单表不 clobber。
- 判定：ALL CONFLICT TESTS PASSED。

### L6 在机人工验收
- `./deploy-emu.sh run` 打开 PW3 视口（1072×1448@300dpi）窗口。
- 逐项执行 `tests/MANUAL_CHECKLIST.md`：
  - A 组 11 项核心查询链路（每版必测）
  - B 组 5 项设置中枢（设置变更涉及版必测）
  - C 组 6 项冲突组合（每版必测）
  - D 组 4 项实机补充（仅当本版触及设备差异层）
- 结论三种：✅ / ⛔ 本版阻塞（回 L1 修） / 📝 记入后续 patch。
- 签核：版本号 + 日期 + 结论写入清单尾部。

---

## 3. 变更类型 → 最低必跑层

| 变更类型 | 最低必跑 | 说明 |
|---|---|---|
| 纯注释/文档 | L2 | 语法兜底 |
| 查询辅助函数（query-helpers 区） | L1+L2+L2b → L4 | 纯函数改动的行为验证在 L4 |
| 传输层（httpGet/keepalive） | L1+L2+L2b+L3 → **L4 全程必跑** | 池化改动风险最高 |
| UI/弹窗/菜单 | L1–L3 + L5 → L6（A 组全项） | 渲染与交互只在 L6 露出 |
| 设置/存储 | L1–L3 + L5 → L6（B 组） | 命名空间在 L5 机器验证 |
| 新引擎/新 host | L1–L3 + L4 + L5 → L6（A6–A8） | host 白名单矩阵同步补 K 项 |
| 发布（tag） | **全链 L1–L6** + CI 绿 + zip 内容核对 | 见 §4 |

---

## 4. 发布前完整链（release gate）

1. `_meta.lua` version 与拟定 tag 一致（CI 会硬校验）。
2. `./run_full_suite.sh` 全绿（L1–L5）。
3. `tests/MANUAL_CHECKLIST.md` L6 逐项 ✅ 并签署。
4. 打 tag → CI 绿 → 下载 release zip 与 HEAD 内容核对（SHA）。
5. 真机冒烟（可选，视变更类型是否触及 D 组）。

---

## 5. 失败处理约定

- L4 网络类 FAIL：先看是否 429 风暴尾流（套件日志有 retry 打印）；
  单独重跑该 case 前**必须**整链重跑确认。
- 任何层 FAIL 后修复：从 **L1** 开始重跑全链，禁止从失败层续跑
  （层级间有状态依赖：deploy 重建书库、stub 互斥等）。
- flaky 判定：同一 case 三次全链中失败 ≥2 次才算真 flaky，需开 issue
  加韧性重试或标注环境依赖；单次失败不修测试。

---

## 6. 本 SOP 维护

- 新增测试文件时：登记进 §1 总表 + `run_full_suite.sh` 编排 + （如适用）CI。
- 改动 deploy-emu.sh 行为时：同步本 SOP §2。
- 版本记录：
  - v2 (2026-09-08)：一体化 SOP + run_full_suite.sh 编排（含 L4 计时与日志归档）。
  - v1：MANUAL_CHECKLIST.md（人工部分，仍为 L6 载体）。
