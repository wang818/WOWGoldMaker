---------------------------------------------------------------------------
-- WOWGoldMaker / Settings.lua
-- 注册到游戏内「设置 → 插件」的画布面板。
-- 使用 pcall 包裹 Settings API, 旧客户端缺接口时静默降级。
---------------------------------------------------------------------------

local ADDON, ns = ...

local T = ns.T
local C = T.C

local categoryID

function ns.OpenSettings()
    if not categoryID then return end
    if Settings and Settings.OpenToCategory then
        local ok = pcall(Settings.OpenToCategory, categoryID)
        if ok then return end
    end
    ns.Print("当前客户端不支持游戏内设置页。")
end

function ns.BuildSettings()
    if categoryID then return end
    if not (Settings and Settings.RegisterCanvasLayoutCategory
            and Settings.RegisterAddOnCategory) then
        return
    end

    local db = ns.DB()
    local panel = CreateFrame("Frame", nil, UIParent)
    panel:Hide()

    -- 标题
    local title = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 16, -16)
    title:SetText("|cffe8c25a金币工坊|r |cffffffffv" .. ns.VERSION .. "|r")

    local note = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    note:SetPoint("TOPLEFT", 16, -44)
    note:SetText("魔兽世界无限服 · 金币工具箱 (Hello 骨架)")
    note:SetTextColor(T.rgb(C.muted))

    -- 分隔线
    local line = panel:CreateTexture(nil, "ARTWORK")
    line:SetTexture(T.WHITE)
    line:SetSize(600, 1)
    line:SetPoint("TOPLEFT", 16, -72)
    line:SetVertexColor(1, 1, 1, 0.15)

    -- 勾选项
    local cb1 = T.Checkbox(panel, "登录后自动呼出主界面",
        function() return db.autoShow end,
        function(v) db.autoShow = v end)
    cb1:SetPoint("TOPLEFT", 20, -92)

    local cb3 = T.Checkbox(panel, "打开拍卖行时自动显示 (关掉拍卖行一起收起)",
        function() return db.ahAutoShow end,
        function(v) db.ahAutoShow = v end)
    cb3:SetPoint("TOPLEFT", 20, -124)

    local cb2 = T.Checkbox(panel, "启用界面动画",
        function() return db.animations end,
        function(v) db.animations = v end)
    cb2:SetPoint("TOPLEFT", 20, -156)

    -- 重置按钮
    local reset = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    reset:SetSize(140, 24)
    reset:SetPoint("TOPLEFT", 20, -192)
    reset:SetText("重置窗口位置")
    reset:SetScript("OnClick", function()
        ns.ResetPosition()
        ns.UI.Show()
    end)

    local open = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    open:SetSize(140, 24)
    open:SetPoint("LEFT", reset, "RIGHT", 10, 0)
    open:SetText("打开主界面")
    open:SetScript("OnClick", function()
        if SettingsPanel and HideUIPanel then
            pcall(HideUIPanel, SettingsPanel)
        end
        ns.UI.Show()
    end)

    -- 命令说明
    local help = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    help:SetPoint("TOPLEFT", 20, -240)
    help:SetJustifyH("LEFT")
    help:SetTextColor(T.rgb(C.muted))
    help:SetText("|cffe8c25a/wgm|r        开关主界面\n|cffe8c25a/wgm reset|r  重置位置\n|cffe8c25a/wgm config|r 打开本设置页")

    local ok, cat = pcall(Settings.RegisterCanvasLayoutCategory, panel, "金币工坊")
    if ok and cat then
        pcall(Settings.RegisterAddOnCategory, cat)
        -- OpenToCategory 需要的是数字 ID, 不是类目对象
        local okID, id = pcall(function() return cat:GetID() end)
        categoryID = okID and id or nil
    end
end
