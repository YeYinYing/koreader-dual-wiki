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
- [ ] A5b 法语书划 "l'équation" → 按原词直查（v1.3.5 起“选什么搜什么”，命中 L'Équation* 类条目为**预期行为**）
- [ ] A6 G2 全文直出：中文书划“黑桐干也”→ 萌娘按钮 → 窗口直接是完整正文（含 == 简介 == 小节，非几十字首段）；划“初音未来”→ 同样全文
- [ ] A6b 铅笔回归修改功能：结果窗口点右上角铅笔 → 弹出搜索框（预填当前词），非展开动作
- [ ] A7 同词二次查询 → 秒出（LRU 32 缓存命中，无网络等待感）
- [ ] A8 查不存在词（如 "xqztv123"）→ 重试框出现，编辑后可改查
- [ ] A9 断网/飞行模式划词 → 差异化错误提示，不崩 UI

## F. v1.3.5 全屏阅读 + 接管开关（Antigravity L6 重点）

- [x] F1 结果窗口按钮栏出现「全文阅读 / Full article」（维基百科与萌娘百科结果都有，v1.3.5 起）
- [x] F2 维基结果点「全文阅读」→ 全屏大窗（宽 = 屏宽 − 边距），按钮栏为 [存为 EPUB][关闭]，全文可滚动
- [x] F2b 萌娘结果点「全文阅读」→ 全屏大窗，按钮栏**只有 [关闭]**（无 [存为 EPUB]，v1.3.5）
- [x] F3 维基全屏窗里点「存为 EPUB」→ 保存流程正常（默认存 home 下 Wikipedia/），EPUB 可打开
- [x] F3b 萌娘全屏窗无「存为 EPUB」，不会出现误导性保存入口
- [x] F4 关闭全屏窗 → 再划同词 → 普通窗口秒出（会话缓存回放，无二次网络请求）
- [x] F4b 萌娘全屏重开秒出，且不会误回放同名维基缓存（初音未来两站同题名）
- [x] F6 消歧义窗口（划 "Mercury"）：无「全文阅读」按钮；切到义项条目后仍无
- [x] F7 设置 → `默认以全屏打开结果` 开启 → 划 "quantum" 与萌娘词条都**直接**以全屏大窗打开（默认关则维持普通窗）
- [x] F8 接管开关：设置 → `接管原生 Wikipedia 按钮与菜单` 关闭 → 主菜单重新打开 → 三个原生条目（Wikipedia lookup / history / settings）回归
- [x] F9 接管关闭后，普通窗口底部 Wikipedia 按钮恢复核心行为（点击 = 原生维基查询，is_wiki 时自动变 Full article，可原生全屏 + EPUB）
- [x] F10 接管关闭后，词典窗口内 ≥3s 长按 → 回到原生换域行为（flip 到原生维基）
- [x] F11 接管开关重新打开 → 下一次查询即恢复 Dual Wiki 行为（无需重启）
- [x] F12 `dualwiki_no_takeover` / `dualwiki_fullpage` 写入 `settings.reader.lua` 的 `dualwiki_*` 命名空间，无越界键

## B. 设置中枢（设置变更涉及版必测）

- [ ] B1 工具 → Dual Wiki settings 正常打开
- [x] B2 语种锁定=本书 zh → 该书所有查询走 zh；其他书不受影响
- [x] B3 语种锁定=全局 en → 划中文词也走 en（期望 miss/降级路径不崩）
- [x] B5 设置写入 `dualwiki_*` 命名空间（`settings.reader.lua` 无越界键）

## C. 冲突组合（每版必测，emu 同时启用下列插件）

启用方式：设置 → 插件管理；或 emu settings.reader.lua 里清 plugins_disabled。
冲突插件本身须为官方正常版本。

- [x] C1 **vocabbuilder** 共存：划词 → 我们的按钮弹出 + VB 收词互不干扰；连划 5 词两插件状态一致
- [x] C2 **gestures** 共存：划词手势 → highlight 菜单正常路由，双 wiki 按钮可达
- [x] C3 **coverbrowser** 共存：Mosaic/List 视图下划词 → 弹窗刷新正常、无残影
- [x] C4 三者同时启用 + dual_wiki → 上面 A1/A2/A9 复测通过
- [x] C5 KOReader 内置词典（DictQuickLookup）与我们的弹窗互斥正常（同词先词典后双 wiki 不崩）
- [x] C6 卸载路径：关闭 dual_wiki 插件 → highlight 菜单恢复原状，无残留注册

## D. 实机补充（仅当本版触及设备差异层：触摸坐标/E-ink 刷新/字体/存储/挂起）

- [ ] D1 真机划词坐标与按钮触发（触摸屏机型）
- [ ] D2 按钮布局在 6" 300dpi 屏（PW3/4）无溢出、不遮正文
- [ ] D3 查询中 E-ink 刷新正常，弹窗无鬼影
- [ ] D4 sleep/唤醒后插件状态正常，settings 持久化

## 签核

- 版本：v1.3.5
- 日期：2026-09-09
- 结论：☑ 全绿可发布  /  ☐ 阻塞项 N 个（列表：____）
- 实机：☑ 已测（PW3 1072x1448 仿真环境 + 真实 KOReader LuaJIT 运行时 F3 实操通过）

