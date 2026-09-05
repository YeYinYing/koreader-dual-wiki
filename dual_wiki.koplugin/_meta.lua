-- _meta.lua
local _ = require("gettext")
return {
    fullname = _("Dual Wiki"),
    description = _([[Lookup selected text on Moegirlpedia, Wikipedia and Fandom. Fuzzy-tolerant retrieval: one merged request returns ranked candidates with summaries; same-word pencil confirm upgrades to the full article. Context-aware language routing and gettext i18n are bundled for zh/en/ja books.]]),
    version = "1.2.0",
}
