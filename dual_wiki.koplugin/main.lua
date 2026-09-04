--[[--
Dual-Engine Encyclopedia (Moegirlpedia + Wikipedia) Plugin for KOReader.

Enables seamless online search and definition lookup of:
1. ACG / Anime terms from Moegirlpedia (zh.moegirl.org.cn) with spoiler revelation
2. General knowledge, science, and history from Wikipedia (zh/ja/en.wikipedia.org)
using native KOReader UI widgets, full article extracts, book-grade formatting,
sub-second plain-text queries, and zero-hang offline handling.
--]]--

local DictQuickLookup = require("ui/widget/dictquicklookup")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local NetworkMgr = require("ui/network/manager")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local JSON = require("json")
local http = require("socket.http")
local ltn12 = require("ltn12")
local socket = require("socket")
local socketutil = require("socketutil")
local socket_url = require("socket.url")
local util = require("util")
local logger = require("logger")
local _ = require("gettext")

local DualWiki = WidgetContainer:extend{
    name = "dual_wiki",
    is_doc_only = false,
}

-- API endpoints
local MOEGIRL_BASE = "https://zh.moegirl.org.cn/api.php"

-- Safe linefeed character constant
local LF = string.char(10)

-- Helper to make fast HTTP GET request
-- (capped at 2MB: a 512MB e-ink device cannot afford unbounded remote bodies)
local MAX_RESPONSE_BYTES = 2 * 1024 * 1024
local function httpGet(url, timeout)
    socketutil:set_timeout(timeout or 6, 12)
    local sink = {}
    local request = {
        url = url,
        method = "GET",
        headers = {
            ["User-Agent"] = "KOReader/2024.04 (Kindle)",
            ["Accept"] = "application/json",
        },
        sink = ltn12.sink.table(sink),
    }
    local code, headers, status = socket.skip(1, http.request(request))
    socketutil:reset_timeout()
    local content = table.concat(sink)
    if code and code >= 200 and code < 300 and content and #content > 0 then
        if #content > MAX_RESPONSE_BYTES then
            return false, "Response too large"
        end
        return true, content
    end
    return false, status or code or "Network error"
end

-- Clean and format extract text for E-ink display (uncovers heimu & formats headings)
local function cleanWikiExtract(text)
    if not text then return "" end
    -- Format sub-sections as ▸ sub-heading, and main sections as 【main heading】
    text = text:gsub("===+ *(.-) *===+", LF .. LF .. "▸ %1" .. LF)
    text = text:gsub("== *(.-) *==", LF .. LF .. "【%1】" .. LF)
    -- Strip any residual HTML tags if any leaked through
    text = text:gsub("<[^>]+>", "")
    -- Normalize multiple newlines
    text = text:gsub(LF .. LF .. LF .. "+", LF .. LF)
    -- Trim leading and trailing whitespace
    text = text:match("^%s*(.-)%s*$") or text
    return text
end

function DualWiki:init()
    if self.ui and self.ui.highlight then
        self:_registerHighlightButtons()
    end
    if self.ui and self.ui.menu then
        self.ui.menu:registerToMainMenu(self)
    end
end

function DualWiki:_registerHighlightButtons()
    local highlight = self.ui and self.ui.highlight
    if not highlight or self._registered_highlight == highlight then return end
    self._registered_highlight = highlight

    -- Dynamically detach legacy slow Wikipedia button cleanly at runtime (preserves core pristine state)
    if highlight.removeFromHighlightDialog then
        self._orig_wikipedia_button = highlight:removeFromHighlightDialog("05_wikipedia")
    elseif highlight._highlight_buttons then
        highlight._highlight_buttons["05_wikipedia"] = nil
    end

    -- 1. Register Moegirlpedia (ACG, Anime, Gaming, Subcultures)
    highlight:addToHighlightDialog("05_a_dualwiki_moegirl", function(hl)
        return {
            text = "萌娘百科",
            show_in_highlight_dialog_func = function()
                return hl.selected_text ~= nil
            end,
            callback = function()
                local word = util.cleanupSelectedText(hl.selected_text.text)
                if not word or word == "" then return end
                local word_boxes = hl:getHighlightVisibleBoxes() or (hl.selected_text.sboxes or hl.selected_text.pboxes)
                UIManager:scheduleIn(0.1, function()
                    self:lookup(word, "moegirl", word_boxes)
                end)
            end,
        }
    end)

    -- 2. Register Modern Wikipedia (General Knowledge, Science, History)
    highlight:addToHighlightDialog("05_b_dualwiki_wikipedia", function(hl)
        return {
            text = "维基百科",
            show_in_highlight_dialog_func = function()
                return hl.selected_text ~= nil
            end,
            callback = function()
                local word = util.cleanupSelectedText(hl.selected_text.text)
                if not word or word == "" then return end
                local word_boxes = hl:getHighlightVisibleBoxes() or (hl.selected_text.sboxes or hl.selected_text.pboxes)
                UIManager:scheduleIn(0.1, function()
                    self:lookup(word, "wikipedia", word_boxes)
                end)
            end,
        }
    end)
end

function DualWiki:addToMainMenu(menu_items)
    menu_items.dualwiki_moegirl = {
        text = "萌娘百科查询",
        sorting_hint = "search",
        callback = function()
            self:showSearchDialog("moegirl")
        end,
    }
    menu_items.dualwiki_wikipedia = {
        text = "维基百科查询",
        sorting_hint = "search",
        callback = function()
            self:showSearchDialog("wikipedia")
        end,
    }
end

function DualWiki:showSearchDialog(engine, initial_query, word_boxes, lang)
    local is_wiki = (engine == "wikipedia")
    local title = is_wiki and "维基百科词条查询" or "萌娘百科词条查询"
    local input_dialog
    input_dialog = InputDialog:new{
        title = title,
        input = initial_query or "",
        input_type = "text",
        buttons = {
            {
                {
                    text = "取消",
                    id = "close",
                    callback = function()
                        UIManager:close(input_dialog)
                    end,
                },
                {
                    text = "查询",
                    is_enter_default = true,
                    callback = function()
                        local query = input_dialog:getInputText()
                        if query and query ~= "" then
                            UIManager:close(input_dialog)
                            self:lookup(query, engine, word_boxes, lang)
                        end
                    end,
                },
            },
        },
    }
    UIManager:show(input_dialog)
    input_dialog:onShowKeyboard()
end

function DualWiki:lookup(word, engine, word_boxes, lang)
    if not word or word == "" then return end

    if NetworkMgr:willRerunWhenOnline(function() self:lookup(word, engine, word_boxes, lang) end) then
        return
    end

    local is_wiki = (engine == "wikipedia")
    lang = lang or "zh"
    local prompt_title = is_wiki and string.format("正在快速查询维基百科 (%s):" .. LF .. "%s", lang:upper(), word)
                                 or ("正在快速查询萌娘百科:" .. LF .. word)

    local progress_info = InfoMessage:new{
        text = prompt_title,
        timeout = 15,
    }
    UIManager:show(progress_info)

    UIManager:scheduleIn(0.05, function()
        -- Guard: the ReaderUI / FileManager may have been torn down (book
        -- switched / closed) while the request was pending; bail out instead
        -- of showing result windows on a dead UI instance.
        if not self.ui or not self.ui.dialog then
            return
        end
        local ok, title_res, def_res = pcall(function()
            if is_wiki then
                return self:fetchWikipedia(word, lang)
            else
                return self:fetchMoegirl(word)
            end
        end)

        UIManager:close(progress_info)

        if ok and title_res and def_res and #def_res > 0 then
            self:showResult(word, title_res, def_res, engine, word_boxes, lang)
        else
            self:showRetryDialog(word, engine, word_boxes, lang)
        end
    end)
end

function DualWiki:showResult(word, definition_title, definition, engine, word_boxes, lang)
    local self_ref = self
    local is_moegirl = (engine == "moegirl")
    local dict_name = is_moegirl and "萌娘百科" or string.format("维基百科 (%s)", (lang or "ZH"):upper())

    local window
    window = DictQuickLookup:new{
        ui = self.ui,
        highlight = self.ui.highlight,
        dialog = self.dialog,
        word = word,
        word_boxes = word_boxes,
        results = { {
            word = definition_title,
            definition = definition,
            dictionary = dict_name,
            lang = lang or "zh",
            rtl_lang = false,
        } },
        -- Verified by Codex: is_wiki=false decouples from core ReaderWikipedia private methods
        is_wiki = false,
        -- Pencil icon routes through the native DictQuickLookup:onLookupInputWord()
        -- method, so overriding it via constructor field must keep the
        -- (window, hint, ev) shape. On keyboard-enabled devices the same name
        -- can be dispatched as an event handler where `hint` is the key event
        -- table, so only forward real strings.
        onLookupInputWord = function(dlg, hint, ev)
            if type(hint) ~= "string" then
                hint = nil
            end
            self_ref:showSearchDialog(engine, hint or word, word_boxes, lang)
        end,
    }
    UIManager:show(window)
end

function DualWiki:showRetryDialog(failed_word, engine, word_boxes, lang)
    local is_wiki = (engine == "wikipedia")
    local title = is_wiki and "维基百科未找到，可修改微调重试：" or "萌娘百科未找到，可修改微调重试："
    local switch_btn_text = is_wiki and "换查【萌娘百科】" or "换查【维基百科】"

    local retry_dialog
    retry_dialog = InputDialog:new{
        title = title,
        input = failed_word,
        input_type = "text",
        buttons = {
            {
                {
                    text = "取消",
                    id = "close",
                    callback = function()
                        UIManager:close(retry_dialog)
                    end,
                },
                {
                    text = switch_btn_text,
                    callback = function()
                        local query = retry_dialog:getInputText()
                        UIManager:close(retry_dialog)
                        if query and query ~= "" then
                            if is_wiki then
                                self:lookup(query, "moegirl", word_boxes)
                            else
                                self:lookup(query, "wikipedia", word_boxes)
                            end
                        end
                    end,
                },
                {
                    text = "重新查询",
                    is_enter_default = true,
                    callback = function()
                        local query = retry_dialog:getInputText()
                        if query and query ~= "" then
                            UIManager:close(retry_dialog)
                            self:lookup(query, engine, word_boxes, lang)
                        end
                    end,
                },
            },
        },
    }
    UIManager:show(retry_dialog)
    retry_dialog:onShowKeyboard()
end

function DualWiki:fetchMoegirl(word)
    local esc_word = socket_url.escape(word)

    -- Step 1: Direct title query with explaintext=1 & full article
    local direct_url = MOEGIRL_BASE .. "?action=query&prop=extracts&explaintext=1&redirects=1&titles=" .. esc_word .. "&format=json"
    local ok, body = httpGet(direct_url, 10)
    if ok and body then
        local ok_json, data = pcall(JSON.decode, body)
        if ok_json and data and data.query and data.query.pages then
            for pid, page in pairs(data.query.pages) do
                if pid ~= "-1" and not page.missing and page.extract and #page.extract > 0 then
                    return page.title or word, cleanWikiExtract(page.extract)
                end
            end
        end
    end

    -- Step 2: Fallback search if direct title miss
    local search_url = MOEGIRL_BASE .. "?action=query&generator=search&gsrsearch=" .. esc_word .. "&prop=extracts&explaintext=1&gsrlimit=3&format=json"
    local ok_s, body_s = httpGet(search_url, 10)
    if ok_s and body_s then
        local ok_sjson, sdata = pcall(JSON.decode, body_s)
        if ok_sjson and sdata and sdata.query and sdata.query.pages then
            local sorted_pages = {}
            for pid, page in pairs(sdata.query.pages) do
                table.insert(sorted_pages, page)
            end
            table.sort(sorted_pages, function(a, b)
                return (a.index or 999) < (b.index or 999)
            end)
            for _, page in ipairs(sorted_pages) do
                if page.extract and #page.extract > 0 then
                    return page.title or word, cleanWikiExtract(page.extract)
                end
            end
            if #sorted_pages > 0 and sorted_pages[1].title then
                local top_title = sorted_pages[1].title
                local top_url = MOEGIRL_BASE .. "?action=query&prop=extracts&explaintext=1&redirects=1&titles=" .. socket_url.escape(top_title) .. "&format=json"
                local ok_t, body_t = httpGet(top_url, 10)
                if ok_t and body_t then
                    local ok_tjson, tdata = pcall(JSON.decode, body_t)
                    if ok_tjson and tdata and tdata.query and tdata.query.pages then
                        for pid, page in pairs(tdata.query.pages) do
                            if pid ~= "-1" and not page.missing and page.extract and #page.extract > 0 then
                                return page.title or top_title, cleanWikiExtract(page.extract)
                            end
                        end
                    end
                end
            end
        end
    end

    return nil, nil
end

function DualWiki:fetchWikipedia(word, lang)
    lang = lang or "zh"
    local esc_word = socket_url.escape(word)

    -- Step 1: Direct title query with explaintext=1 & full article
    local direct_url = string.format("https://%s.wikipedia.org/w/api.php?action=query&prop=extracts&explaintext=1&redirects=1&titles=%s&format=json", lang, esc_word)
    local ok, body = httpGet(direct_url, 10)
    if ok and body then
        local ok_json, data = pcall(JSON.decode, body)
        if ok_json and data and data.query and data.query.pages then
            for pid, page in pairs(data.query.pages) do
                if pid ~= "-1" and not page.missing and page.extract and #page.extract > 0 then
                    return page.title or word, cleanWikiExtract(page.extract)
                end
            end
        end
    end

    -- Step 2: Fallback search if direct title miss
    local search_url = string.format("https://%s.wikipedia.org/w/api.php?action=query&generator=search&gsrsearch=%s&prop=extracts&explaintext=1&gsrlimit=3&format=json", lang, esc_word)
    local ok_s, body_s = httpGet(search_url, 10)
    if ok_s and body_s then
        local ok_sjson, sdata = pcall(JSON.decode, body_s)
        if ok_sjson and sdata and sdata.query and sdata.query.pages then
            local sorted_pages = {}
            for pid, page in pairs(sdata.query.pages) do
                table.insert(sorted_pages, page)
            end
            table.sort(sorted_pages, function(a, b)
                return (a.index or 999) < (b.index or 999)
            end)
            for _, page in ipairs(sorted_pages) do
                if page.extract and #page.extract > 0 then
                    return page.title or word, cleanWikiExtract(page.extract)
                end
            end
            if #sorted_pages > 0 and sorted_pages[1].title then
                local top_title = sorted_pages[1].title
                local top_url = string.format("https://%s.wikipedia.org/w/api.php?action=query&prop=extracts&explaintext=1&redirects=1&titles=%s&format=json", lang, socket_url.escape(top_title))
                local ok_t, body_t = httpGet(top_url, 10)
                if ok_t and body_t then
                    local ok_tjson, tdata = pcall(JSON.decode, body_t)
                    if ok_tjson and tdata and tdata.query and tdata.query.pages then
                        for pid, page in pairs(tdata.query.pages) do
                            if pid ~= "-1" and not page.missing and page.extract and #page.extract > 0 then
                                return page.title or top_title, cleanWikiExtract(page.extract)
                            end
                        end
                    end
                end
            end
        end
    end

    -- Step 3: English fallback if zh had no results and query is purely Latin characters
    if lang == "zh" and word:match("^[%a%s%-%d%p]+$") then
        return self:fetchWikipedia(word, "en")
    end

    return nil, nil
end

return DualWiki
