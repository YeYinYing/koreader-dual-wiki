<div align="center">

# KOReader Dual Wiki 插件 — `dual_wiki.koplugin`

[![License: AGPL-3.0](https://img.shields.io/badge/License-AGPL_3.0-blue.svg)](LICENSE)
[![KOReader](https://img.shields.io/badge/KOReader-v2024%2B-orange.svg)](https://github.com/koreader/koreader)
[![Topic](https://img.shields.io/badge/Topic-koreader--plugin-green.svg)](https://github.com/topics/koreader-plugin)

[English](README.md) | **简体中文**

</div>

Dual Wiki 是一款为 KOReader 设计的多引擎百科查询插件，面向电子墨水屏设备，重点控制内存占用、网络往返和界面干扰。

当前支持的来源：

- 维基百科 `zh / en / ja`
- 萌娘百科（Moegirlpedia）
- Fandom 社区百科

---

## 概述

插件提供几种固定的查询方式：

- 在划词高亮工具栏中直接选择来源查询；
- 在主菜单中输入关键词查询；
- 当未能精确命中时，查看候选词条列表；
- 通过铅笔编辑入口继续微调查询或载入完整正文。

检索流程采用保守策略：只剥离外层包装符号和安全噪音，保留词内标点，并在查询不完整或有歧义时逐级降级。

---

## 功能

### 检索行为
- 仅剥离外层书名号、引号、括号等包装符号。
- 保守处理安全的末尾助词。
- 对拉丁字母查询使用词边界匹配。
- 当来源支持时，在主路径返回带摘要的候选词条。
- 通过铅笔编辑入口可将候选词条升级为完整正文。

### 来源处理
- 维基百科按语种路由，支持 `zh / en / ja`。
- 萌娘百科作为独立来源处理。
- Fandom 通过其 MediaWiki API 支持，完整正文使用 `action=parse` 获取。
- `converttitles=1` 仅用于维基百科中文查询。

### 语境感知路由
- 优先使用 KOReader 的书籍元数据判断当前语种。
- 也可以在设置中手动锁定语种。
- 当日文书在萌娘百科上出现不可靠结果时，可回退到 `ja.wikipedia`。

### 本地化
- 内置 `zh_CN`、`zh_TW`、`ja` 翻译文件。
- 所有面向用户的字符串都已接入 gettext。
- 启动时会按当前 KOReader 界面语言加载 locale 文件。

### 运行约束
- 响应体上限为 2 MB。
- 每次请求结束后显式重置网络超时。
- 对过期 UI 回调做了保护，避免在页面切换后弹出旧结果。

---

## 安装方法

### KOReader AppStore
在 `appstore.koplugin` 中搜索 **Dual Wiki** 并安装。

### 手动安装
1. 在 [Releases](../../releases) 页面下载 `koreader-dual-wiki-v1.2.0.zip`。
2. 解压压缩包。
3. 将 `dual_wiki.koplugin` 复制到设备的 `koreader/plugins/` 目录中。
4. 重启 KOReader。

目录结构应如下所示：

```text
koreader/
└── plugins/
    └── dual_wiki.koplugin/
        ├── _meta.lua
        ├── main.lua
        └── locale/
            ├── messages.pot
            ├── ja.po
            ├── zh_CN.po
            ├── zh_TW.po
            ├── ja/LC_MESSAGES/dual_wiki.mo
            ├── zh_CN/LC_MESSAGES/dual_wiki.mo
            └── zh_TW/LC_MESSAGES/dual_wiki.mo
```

---

## 使用方法

### 从划词入口使用
1. 选中一个词或短语。
2. 打开高亮工具栏。
3. 选择对应来源按钮。
4. 通过候选词条列表切换条目或继续微调查询。
5. 使用铅笔图标编辑当前查询，或载入完整正文。

### 从主菜单使用
插件也提供了各来源的直接搜索入口。

---

## 兼容性

- 适用于 KOReader v2024 及以上版本。
- 适合 Kindle 级电子墨水屏设备和其他低资源阅读器。
- 除 KOReader 自带的 Lua 环境外，不依赖额外运行时组件。

---

## 发布说明

- 当前版本：`v1.2.0`
- 本次主要新增：语种感知检索、多引擎路由、gettext 本地化、Fandom 支持、以及日文萌娘百科回退。

---

## 许可证

本项目采用 **GNU Affero General Public License v3.0（AGPL-3.0）**。
