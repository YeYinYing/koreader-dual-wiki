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

1. **双独立并列入口**：
   - 划词高亮工具栏中并列呈现 **`【萌娘百科】`** 与 **`【维基百科】`** 两个独立按钮；
   - **零侵入架构**：纯粹运行于插件沙盒，无需打补丁或修改 KOReader 核心系统文件。
2. **墨水屏黑幕自动全透视**：
   - 针对萌娘百科特色的 `#252525` 黑色恶搞/剧透遮罩（黑幕）：查询管道全程使用 `explaintext=1` 纯文本模式，黑幕作为纯 CSS 背景效果根本不会进入显示层——所有被遮盖的文字天然呈现为清晰易读的纯正中文，墨水屏上绝无实心黑块。
3. **彻底解除篇幅腰斩限制**：
   - 告别只给看两句摘要的割裂体验。单次请求一次性完整载入整篇数千字至上万字长文（生平、年表、全剧情推演），支持顺畅翻页。
4. **毫秒级纯文本直出管道 (0.4s - 0.8s)**：
   - 彻底剔除图片缩略图抓取（`pageimages`），杜绝在弱网墨水屏设备上因图片加载导致的 SSL 握手超时与 HTTP 429 限流卡死。
5. **实体书级章节标题重排**：
   - 自动将维基语法标记（`== 标题 ==` 与 `=== 子节 ===`）转化为出版级排版的 **`【主章节】`** 与 **`▸ 子章节`**。
6. **双擎跨引擎一键互切与关键词微调**：
   - 划词查询未收录时，自动弹出预填微调弹窗，并提供 **`[换查萌娘百科]`** 或 **`[换查维基百科]`** 按钮，一键无缝跳转；
   - 查询弹窗右上角铅笔图标直通当前词编辑，随时删去多选的标点重搜。

---

## 📦 安装方法

### 方式一：KOReader AppStore 在线安装（推荐）
在设备端打开 `appstore.koplugin`（应用商店），搜索 **Dual Wiki**，点击安装即可。

### 方式二：手动安装
1. 在 [Releases](../../releases) 页面下载最新的 `koreader-dual-wiki-v1.0.0.zip`；
2. 连接阅读器至电脑，将压缩包解压后的 `dual_wiki.koplugin` 文件夹整体复制到设备的 `koreader/plugins/` 目录下：
   ```text
   koreader/
   └── plugins/
       └── dual_wiki.koplugin/
           ├── _meta.lua
           └── main.lua
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
