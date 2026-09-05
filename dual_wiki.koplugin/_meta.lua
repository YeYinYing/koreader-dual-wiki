-- _meta.lua
local _ = require("gettext")
return {
    fullname = _("Dual Wiki"),
    description = _([[Lookup selected text on Moegirlpedia (spoiler-reveal) and Wikipedia. Fuzzy-tolerant retrieval: one merged request returns ranked candidates with summaries; same-word pencil confirm upgrades to the full article.]]),
    version = "1.1.0",
}
