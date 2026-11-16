---------------------------------------------------------------------------
-- WOWGoldMaker / Core.lua
-- 命名空间、SavedVariables、事件分发、聊天命令、游戏内设置页注册。
---------------------------------------------------------------------------

local ADDON, ns = ...

ns.ADDON   = ADDON
ns.VERSION = "0.1.0"

local function ClientVersion()
    -- 兼容处理: 部分客户端 (含无限服) 第 4 个返回值可能是字符串, 统一 tonumber
    local ok, v = pcall(function()
        return select(4, GetBuildInfo())
    end)
    return (ok and tonumber(v)) or 0
end
ns.ClientVersion = ClientVersion
ns.IsForever     = ClientVersion() >= 16000 and ClientVersion() < 20000

--------------------------------------------------------------------------- 默认配置

local DEFAULTS = {
    autoShow   = false,                                   -- 登录后自动呼出
    animations = true,                                    -- 界面动画
    pos        = { point = "CENTER", relPoint = "CENTER", x = 0, y = 0 },
}

local db

local function MergeDefaults(t, defaults)
    for k, v in pairs(defaults) do
        if t[k] == nil then
            t[k] = (type(v) == "table") and CopyTable(v) or v
        elseif type(v) == "table" and type(t[k]) == "table" then
            MergeDefaults(t[k], v)
        end
    end
end

function ns.DB()
    return db
end

--------------------------------------------------------------------------- 输出

local PREFIX = "|cffe8c25a金币工坊|r"

function ns.Print(msg)
    print(PREFIX, msg)
end

-- 专业入口。现在配方列表内嵌在主面板里 (单页), 所以这里只负责切页签 + 呼出面板。
-- 早期版本 Core 直接调 ns.FAReport (并不存在的名字), 结果是静默无反应 —— 现在缺模块
-- 或渲染失败都会明确报出来。
function ns.OpenRecipes(key, mode)
    key = key or "first-aid"
    if not (ns.Prof and ns.Prof.byKey and ns.Prof.byKey[key]) then
        ns.Print("|cffff5555未知专业:|r " .. tostring(key))
        return
    end
    if ns.UI and ns.UI.ShowProf then
        ns.UI.ShowProf(key, mode)
    elseif ns.Prof.Report then
        -- 兜底: 界面模块没加载出来时退回聊天输出
        ns.Prof.Report(key, mode)
    else
        ns.Print("|cffff5555界面模块未加载:|r ns.UI.ShowProf 不存在, 检查 UI.lua")
    end
end

--------------------------------------------------------------------------- 事件

local ev = CreateFrame("Frame")
ns.Events = ev

ev:RegisterEvent("ADDON_LOADED")
ev:RegisterEvent("PLAYER_ENTERING_WORLD")
ev:RegisterEvent("PLAYER_MONEY")
ev:RegisterEvent("PLAYER_LEVEL_UP")

ev:SetScript("OnEvent", function(_, event, arg1, arg2, arg3)
    if event == "ADDON_LOADED" and arg1 == ADDON then
        WOWGoldMakerDB = WOWGoldMakerDB or {}
        MergeDefaults(WOWGoldMakerDB, DEFAULTS)
        db = WOWGoldMakerDB

        if ns.BuildSettings then
            local ok, err = pcall(ns.BuildSettings)
            if not ok then
                ns.Print("|cffff5555设置页注册失败:|r " .. tostring(err))
                pcall(geterrorhandler(), "WOWGoldMaker 设置页注册失败: " .. tostring(err))
            end
        end

    elseif event == "PLAYER_ENTERING_WORLD" then
        if ns.UI and ns.UI.Build then
            ns.UI.Build()
            if db and db.autoShow then
                ns.UI.Show()
            end
        end

    elseif event == "PLAYER_MONEY" or event == "PLAYER_LEVEL_UP" then
        if ns.UI and ns.UI.RefreshStats then
            ns.UI.RefreshStats()
        end
    end
end)

--------------------------------------------------------------------------- 窗口位置

function ns.SavePosition(f)
    if not (db and f and f:GetNumPoints() > 0) then return end
    local point, _, relPoint, x, y = f:GetPoint(1)
    db.pos = { point = point, relPoint = relPoint, x = math.floor(x), y = math.floor(y) }
end

function ns.ResetPosition()
    if not db then return end
    db.pos = { point = "CENTER", relPoint = "CENTER", x = 0, y = 0 }
    if ns.UI and ns.UI.ApplyPosition then
        ns.UI.ApplyPosition()
    end
    ns.Print("窗口位置已重置。")
end

--------------------------------------------------------------------------- 聊天命令

SLASH_WOWGOLDMAKER1 = "/wgm"
SLASH_WOWGOLDMAKER2 = "/goldmaker"

SlashCmdList["WOWGOLDMAKER"] = function(msg)
    msg = (msg or ""):lower():gsub("^%s+", ""):gsub("%s+$", ""):gsub("%s+", " ")

    if msg == "show" then
        ns.UI.Show()
    elseif msg == "hide" then
        ns.UI.Hide()
    elseif msg == "reset" then
        ns.ResetPosition()
        ns.UI.Show()
    elseif msg == "config" or msg == "settings" then
        ns.OpenSettings()
    elseif msg == "debug" then
        if ns.UI and ns.UI.DebugInfo then
            ns.UI.DebugInfo()
        end
    elseif msg == "stats" then
        -- 强制刷新一次并打印解析结果
        if ns.UI and ns.UI.RefreshStats then
            ns.UI.RefreshStats()
            local s = ns.UI.lastStats
            if s then
                print("|cffe8c25a[WGM 数据]|r 铜=" .. tostring(s.money)
                    .. " → " .. tostring(s.gold) .. "金" .. tostring(s.silver) .. "银"
                    .. tostring(s.copper) .. "铜 | 等级=" .. tostring(s.level))
            else
                print("|cffff5555[WGM 数据]|r 刷新未产生数据, 输 /wgm debug 看详情")
            end
        end
    elseif msg == "fa" or msg == "firstaid" or msg == "first-aid"
        or msg == "急救" then
        ns.OpenRecipes("first-aid")
    elseif msg == "fa mats" or msg == "急救材料" then
        ns.OpenRecipes("first-aid", "mats")
    elseif msg == "cooking" or msg == "烹饪" then
        ns.OpenRecipes("cooking")
    elseif msg == "prof" or msg == "专业" then
        ns.Print("可用专业 (点击主界面专业卡片也能打开):")
        for _, p in ipairs(ns.Prof.LIST) do
            print(format("  |cffe8c25a%-10s|r %s", p.key, p.name))
        end
        ns.Print("用法: /wgm prof first-aid  |  /wgm prof cooking")
    elseif msg:match("^prof ") or msg:match("^专业 ") then
        local key = msg:match("^prof (.+)$") or msg:match("^专业 (.+)$")
        ns.OpenRecipes(key)
    elseif msg == "icons" then
        if ns.Prof and ns.Prof.DebugIcons then
            pcall(ns.Prof.DebugIcons)
        else
            ns.Print("|cffff5555专业模块未加载|r")
        end
    elseif msg == "help" then
        ns.Print("命令列表:")
        print("  |cffe8c25a/wgm|r            打开 / 关闭主界面")
        print("  |cffe8c25a/wgm show|r       显示主界面")
        print("  |cffe8c25a/wgm hide|r       隐藏主界面")
        print("  |cffe8c25a/wgm reset|r      重置窗口位置")
        print("  |cffe8c25a/wgm config|r     打开游戏内设置页")
        print("  |cffe8c25a/wgm fa|r         主界面切到急救列表")
        print("  |cffe8c25a/wgm cooking|r    主界面切到烹饪列表")
        print("  |cffe8c25a/wgm prof|r       列出所有专业")
        print("  |cffe8c25a/wgm icons|r      诊断专业/物品图标能否解析")
    else
        ns.UI.Toggle()
    end
end
