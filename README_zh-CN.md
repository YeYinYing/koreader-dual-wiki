<div align="center">

# KOReader Dual Wiki 插件 — `dual_wiki.koplugin`

[![License: AGPL-3.0](https://img.shields.io/badge/License-AGPL_3.0-blue.svg)](LICENSE)
[![KOReader](https://img.shields.io/badge/KOReader-v2024%2B-orange.svg)](https://github.com/koreader/koreader)
[![Topic](https://img.shields.io/badge/Topic-koreader--plugin-green.svg)](https://github.com/topics/koreader-plugin)

[English](README.md) | **简体中文**

</div>

KOReader 电子墨水屏阅读器的百科查询插件，支持维基百科（`zh` / `en` / `ja`）、萌娘百科与 Fandom。

## 功能

- 可在划词高亮工具栏中选择来源查询，也可在主菜单中直接输入关键词查询。
- 保守的本地查询清洗：仅剥离外层包装符号（`《》`、`“”`、`【】`、`『』`），保留词内标点。
- 语言感知的末尾助词处理；英文仅剥离所有格 `'s`，不处理复数 `s`。
- 拉丁字母查询使用词边界匹配（`quantum` 可命中 `Quantum mechanics`，`wo` 不会误命中 `Wookieepedia`）。
- 主路径单次请求返回带摘要的候选词条；铅笔操作可升级为完整正文。
- 根据 KOReader 书籍元数据自动路由语种，也可在设置中手动覆盖。
- 日文查询在萌娘百科结果不可靠时自动回退 `ja.wikipedia`。
- `converttitles=1` 仅用于维基百科中文查询。
- Fandom 完整正文通过 `action=parse` 获取。
- 内置 `zh_CN`、`zh_TW`、`ja` gettext 本地化，启动时按当前界面语言加载。
- 响应体上限 2 MB；请求结束后显式重置超时；已对过期 UI 回调做保护。

## 安装

可通过 KOReader AppStore（`appstore.koplugin`）安装，或在 [Releases](../../releases) 页面下载 `koreader-dual-wiki-v1.2.1.zip` 解压到 `koreader/plugins/`：

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

安装后重启 KOReader。

## 使用方法

1. 选中一个词或短语。
2. 打开高亮工具栏并选择来源。
3. 浏览候选词条或继续微调查询。
4. 使用铅笔图标编辑查询或载入完整正文。

## 兼容性

- KOReader v2024 及以上版本。
- 除 KOReader 自带的 Lua 环境外，不依赖额外运行时组件。

## 许可证

GNU Affero General Public License v3.0（AGPL-3.0）。