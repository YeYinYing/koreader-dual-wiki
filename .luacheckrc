-- luacheck configuration for the Dual Wiki KOReader plugin.
-- Run: luacheck dual_wiki.koplugin tests
std = "lua51"

-- KOReader runtime globals (injected by the host app, not defined here).
globals = {
    "G_reader_settings",
    "G_defaults",
}

-- Method tables are built via WidgetContainer:extend{}; unused callback
-- parameters (fn_button, index, touchmenu_instance placeholders) are part
-- of the KOReader plugin API shape and must stay.
unused_args = false

-- Keep reports focused on real defects; style noise is out of scope.
max_line_length = 140
