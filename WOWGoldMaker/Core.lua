---------------------------------------------------------------------------
-- WOWGoldMaker / Core.lua
-- 命名空间、SavedVariables、事件分发、聊天命令、游戏内设置页注册。
---------------------------------------------------------------------------

local ADDON, ns = ...

ns.ADDON   = ADDON
ns.VERSION = "0.1.0"

local function ClientVersion()
    local ok, _, _, v = pcall(GetBuildInfo)
    return ok and v or 0
end
ns.ClientVersion = ClientVersion
ns.IsForever     = ClientVersion() >= 16000 and ClientVersion() < 20000

--------------------------------------------------------------------------- 默认配置

local DEFAULTS = {
    autoShow   = false,                                   -- 登录后自动呼出
    animations = true,                                    -- 界面动画
    pos        = { point = "CENTER", relPoint = "CENTER", x = 0, y = 120 },
    greetIndex = 1,
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
            pcall(ns.BuildSettings)
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
    db.pos = { point = "CENTER", relPoint = "CENTER", x = 0, y = 120 }
    if ns.UI and ns.UI.ApplyPosition then
        ns.UI.ApplyPosition()
    end
    ns.Print("窗口位置已重置。")
end

--------------------------------------------------------------------------- 聊天命令

SLASH_WOWGOLDMAKER1 = "/wgm"
SLASH_WOWGOLDMAKER2 = "/goldmaker"

SlashCmdList["WOWGOLDMAKER"] = function(msg)
    msg = (msg or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")

    if msg == "show" then
        ns.UI.Show()
    elseif msg == "hide" then
        ns.UI.Hide()
    elseif msg == "reset" then
        ns.ResetPosition()
        ns.UI.Show()
    elseif msg == "config" or msg == "settings" then
        ns.OpenSettings()
    elseif msg == "help" then
        ns.Print("命令列表:")
        print("  |cffe8c25a/wgm|r            打开 / 关闭主界面")
        print("  |cffe8c25a/wgm show|r       显示主界面")
        print("  |cffe8c25a/wgm hide|r       隐藏主界面")
        print("  |cffe8c25a/wgm reset|r      重置窗口位置")
        print("  |cffe8c25a/wgm config|r     打开游戏内设置页")
    else
        ns.UI.Toggle()
    end
end
