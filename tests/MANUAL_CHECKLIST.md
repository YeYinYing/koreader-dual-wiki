# DualWiki Manual Checklist（人工验收清单）

每版发布前，在 emu（`./deploy-emu.sh run`）里逐项勾选；实机补充项见 §D。
截图（F12）存 `docs/screenshots/vX.Y.Z/`，release notes 引用有代表性的一两张。
结论三种：✅ 通过 / ⛔ 本版阻塞（回 Stage 0 修）/ 📝 记入后续 patch。

测试书：emu 启动后打开 `/tmp/koreader-emu-home/library/`（8 本多语言书）。

## A. 核心查询链路（每版必测）

- [ ] A1 中文书划“量子力学的” → 助词剥离 → 命中「量子力学」（zh wiki）
- [ ] A2 中文书划“《三体》” → 书名号清洗 → 命中「三体」
- [ ] A3 英文书划 "quantum entanglement" → 词边界 → 命中
- [ ] A4 日文书划「シャナの」→ 助词剥离 → 降级 ja wiki 命中
- [ ] A5 德/法/西/俄书各划一词 → 动态语种槽位 + 命中
- [ ] A6 Fandom：英文书划 "Darth Vader" → 段落快出（section=0）→ 铅笔 → 全文（两段式）
- [ ] A7 BWiki：划「蒙德」→ 原神 wiki 命中
- [ ] A8 Wiktionary：划 "quantum" → 释义出
- [ ] A9 同词二次查询 → 秒出（LRU 32 缓存命中，无网络等待感）
- [ ] A10 查不存在词（如 "xqztv123"）→ 重试框出现，编辑后可改查
- [ ] A11 断网/飞行模式划词 → 差异化错误提示，不崩 UI

## B. 设置中枢（设置变更涉及版必测）

- [ ] B1 工具 → Dual Wiki settings 正常打开
- [ ] B2 语种锁定=本书 zh → 该书所有查询走 zh；其他书不受影响
- [ ] B3 语种锁定=全局 en → 划中文词也走 en（期望 miss/降级路径不崩）
- [ ] B4 Fandom 子域编辑 → `starwars` ↔ `genshin-impact` 切换即时生效
- [ ] B5 设置写入 `dualwiki_*` 命名空间（`settings.reader.lua` 无越界键）

## C. 冲突组合（每版必测，emu 同时启用下列插件）

启用方式：设置 → 插件管理；或 emu settings.reader.lua 里清 plugins_disabled。
冲突插件本身须为官方正常版本。

- [ ] C1 **vocabbuilder** 共存：划词 → 我们的按钮弹出 + VB 收词互不干扰；连划 5 词两插件状态一致
- [ ] C2 **gestures** 共存：划词手势 → highlight 菜单正常路由，双 wiki 按钮可达
- [ ] C3 **coverbrowser** 共存：Mosaic/List 视图下划词 → 弹窗刷新正常、无残影
- [ ] C4 三者同时启用 + dual_wiki → 上面 A1/A2/A9 复测通过
- [ ] C5 KOReader 内置词典（DictQuickLookup）与我们的弹窗互斥正常（同词先词典后双 wiki 不崩）
- [ ] C6 卸载路径：关闭 dual_wiki 插件 → highlight 菜单恢复原状，无残留注册

## D. 实机补充（仅当本版触及设备差异层：触摸坐标/E-ink 刷新/字体/存储/挂起）

- [ ] D1 真机划词坐标与按钮触发（触摸屏机型）
- [ ] D2 按钮布局在 6" 300dpi 屏（PW3/4）无溢出、不遮正文
- [ ] D3 查询中 E-ink 刷新正常，弹窗无鬼影
- [ ] D4 sleep/唤醒后插件状态正常，settings 持久化

## 签核

- 版本：v____
- 日期：____
- 结论：☐ 全绿可发布  /  ☐ 阻塞项 N 个（列表：____）
- 实机：☐ 跳过（理由：____）/ ☐ 已测
