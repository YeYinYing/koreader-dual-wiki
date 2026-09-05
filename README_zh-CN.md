<div align="center">

# KOReader Dual Wiki 插件 (`dual_wiki.koplugin`)

[![License: AGPL-3.0](https://img.shields.io/badge/License-AGPL_3.0-blue.svg)](LICENSE)
[![KOReader](https://img.shields.io/badge/KOReader-v2024%2B-orange.svg)](https://github.com/koreader/koreader)
[![Topic](https://img.shields.io/badge/Topic-koreader--plugin-green.svg)](https://github.com/topics/koreader-plugin)

[English](README.md) | **简体中文**

</div>

**Dual Wiki** 是为 **KOReader** 墨水屏阅读器深度定制的零延迟、双引擎百科在线查询插件（专为 Kindle、Kobo、文石、安卓电子阅读器优化）。

本项目深度整合了专攻二次元/ACG文化、动漫考据、游戏设定与网络梗的 **萌娘百科（Moegirlpedia）**，以及彻底改造为极速纯文本流的现代化 **维基百科（Wikipedia）**。

---

## 🌟 核心特性

1. **全球化多引擎矩阵（v1.2.0）**：
   - **语境感知调度**：自动读取书籍元数据语种（`doc_props.language`）——中文书显示 `[萌娘百科]+[维基百科]`，英文书显示 `[Wikipedia (EN)]+[Fandom]`，日文书显示 `[ウィキペディア (JA)]+[萌娘百科]`；
   - **Fandom 社区引擎**：新增 `{subdomain}.fandom.com` 兼容（实测该平台无 `prop=extracts`，正文改用 `action=parse` 通道）；
   - **gettext 国际化**：内置 `zh_CN / zh_TW / ja` 语言包，随 KOReader 界面语言自动切换，零硬编码残留。
2. **跨语种模糊容错检索**：
   - **语言感知助词剥离**：中文 12 助词 / 日文 `のにをはがでとへもなよね` / 英文仅安全所有格 `'s`（复数 `s` 刻意不剥，避免 `physics→physic` 误伤）；
   - **拉丁词边界好命中**：`quantum` → `Quantum mechanics`、`jedi` → `Jedi`；短前缀无词边界不误伤（`wo` 不会命中 `Wookieepedia`）；
   - **日文 moegirl 防误伤闭环**：萌百索引对日文假名词有歧义（`シャナ`→无关的 `Shanna`），已加前缀关系守卫并在零命中时自动回退 `ja.wikipedia`（`シャナ` → 灼眼的夏娜）。
3. **模糊容错智能检索（方案 A）**：
   - 告别「必须 100% 选准关键词」——书名号/引号/括号自动剥除，少选一字、多划标点自动前缀补全；
   - **单次合并请求**直达 4 个候选词条（各带可读摘要），8/10 典型场景仅需 1 次 HTTP 往返；
   - 铅笔同词确认一键升级完整正文；候选词原生左右切换，零额外 UI。
4. **双独立并列入口**：
   - 划词高亮工具栏中并列呈现 **`【萌娘百科】`** 与 **`【维基百科】`** 两个独立按钮；
   - **零侵入架构**：纯粹运行于插件沙盒，无需打补丁或修改 KOReader 核心系统文件。
5. **墨水屏黑幕自动全透视**：
   - 针对萌娘百科特色的 `#252525` 黑色恶搞/剧透遮罩（黑幕）：查询管道全程使用 `explaintext=1` 纯文本模式，黑幕作为纯 CSS 背景效果根本不会进入显示层——所有被遮盖的文字天然呈现为清晰易读的纯正中文，墨水屏上绝无实心黑块。
6. **繁体/简体无感对齐 + 实体书级排版**：
   - 服务端 `converttitles=1` 原生转换——阅读港台繁体书划词 `駭客任務` 自动命中，零本地转换词典、零额外内存；
   - 自动将维基语法标记（`== 标题 ==`）转化为出版级排版的 **`【主章节】`** 与 **`▸ 子章节`**。

---

## 📦 安装方法

### 方式一：KOReader AppStore 在线安装（推荐）
在设备端打开 `appstore.koplugin`（应用商店），搜索 **Dual Wiki**，点击安装即可。

### 方式二：手动安装
1. 在 [Releases](../../releases) 页面下载最新的 `koreader-dual-wiki-v1.2.0.zip`；
2. 连接阅读器至电脑，将压缩包解压后的 `dual_wiki.koplugin` 文件夹整体复制到设备的 `koreader/plugins/` 目录下：
   ```text
   koreader/
   └── plugins/
       └── dual_wiki.koplugin/
           ├── _meta.lua
           ├── main.lua
           └── locale/
               ├── zh_CN/LC_MESSAGES/dual_wiki.mo
               ├── zh_TW/LC_MESSAGES/dual_wiki.mo
               └── ja/LC_MESSAGES/dual_wiki.mo
   ```
3. 重启 KOReader 即可生效。

---

## ⚙️ 架构规范与兼容性

- **上游标准对齐**：代码 100% 遵循 KOReader 最新主线（v2024+）插件规范，`_meta.lua` 剔除废弃键，专为 AppStore 升级比对设计；
- **解耦隔离**：弹窗显式配置 `is_wiki = false`，彻底解耦原生 `ReaderWikipedia` 的私有依赖与语言死锁；
- **设备验证**：已在 Kindle Paperwhite 3 (i.MX6SL, 512MB RAM) 实机深度验证，内存零常驻，弱网高容错（2MB 响应体熔断 + 过期 UI 回调守卫）。

---

## 📄 许可证
本项目采用 **GNU Affero General Public License v3.0 (AGPL-3.0)** 协议开源，与 KOReader 社区生态完全保持一致。
