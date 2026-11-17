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
    pos        = { point = "RIGHT", relPoint = "RIGHT", x = 0, y = 0 },   -- 屏幕右侧垂直居中
    strata     = "DIALOG",                                -- 主面板层级 (DIALOG = 压在 EllesmereUI 上层)
    prices     = {},                                      -- 拍卖行价格缓存: itemID -> { unit, n, ts }
    npcBuy     = {},                                      -- NPC 购买价 (手动录入): itemID -> 铜
    tipExtra   = false,                                   -- 悬停是否附带配方/单价/盈亏 (默认只显示物品原来的介绍)
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

        -- 一次性迁移: 0.5.7 把默认层级改成 MEDIUM (待在背包下面), 0.5.8 又要压在
        -- EllesmereUI 上层, 默认改 DIALOG。老存档里已是 MEDIUM 的视为旧默认值, 跟着改;
        -- 玩家自己用 /wgm strata 指定的其它值不动。
        if (db.strataRev or 0) < 1 then
            if db.strata == "MEDIUM" then db.strata = "DIALOG" end
            db.strataRev = 1
        end

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
    db.pos = { point = "RIGHT", relPoint = "RIGHT", x = 0, y = 0 }
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
    elseif msg == "ah" or msg == "price" or msg == "查价" then
        if ns.Auction then
            ns.Auction.Debug()
        else
            ns.Print("|cffff5555查价模块未加载|r (检查 Auction.lua 是否在 .toc 里)")
        end
    elseif msg == "ah list" or msg == "ah dump" or msg == "查价 明细" then
        if ns.Auction then
            ns.Auction.Dump()
        else
            ns.Print("|cffff5555查价模块未加载|r")
        end
    elseif msg == "ah clear" or msg == "查价 清空" then
        if ns.Auction then ns.Auction.Clear() end
    elseif msg:match("^search") or msg:match("^搜索") then
        -- 手动试一下「在拍卖行里搜索某件物品」, 不用去列表里点
        local id = tonumber(msg:match("(%d+)") or "")
        if not id then
            ns.Print("用法: /wgm search <物品ID>  (等同左键点列表里的这件物品)")
        elseif ns.UI and ns.UI.SearchInAH then
            ns.UI.SearchInAH(id)
            -- 顺带把这条路的体检打出来: 点了没反应的时候不用来回问
            if ns.Auction and ns.Auction.SearchDiag then
                C_Timer.After(2.5, function() ns.Auction.SearchDiag(id) end)
            end
        else
            ns.Print("|cffff5555界面模块未加载|r")
        end
    elseif msg == "npc" or msg == "npc buy" then
        -- NPC 收购价是客户端自带的, 不用管; 这里只管玩家手记的「购买价」
        local n = (ns.NPC and ns.NPC.BuyCount()) or 0
        ns.Print(format("已记录 %d 条 NPC 购买价 (材料行点「买价」格子录入)", n))
        if ns.NPC then
            print("  |cff8a929e/wgm npc clear|r 清空这些记录")
        end
    elseif msg == "npc clear" or msg == "npc 清空" then
        local n = (ns.NPC and ns.NPC.ClearBuy()) or 0
        ns.Print(format("已清空 %d 条 NPC 购买价", n))
    elseif msg == "tip extra" or msg == "提示 额外" then
        -- 悬停默认只给物品原来的介绍 (和背包一致); 这里开/关我们自己的那些行
        local d = ns.DB()
        d.tipExtra = not d.tipExtra
        if d.tipExtra then
            ns.Print("悬停: |cff29c7a8物品介绍 + 配方 / 单价 / 盈亏 / NPC 价|r")
        else
            ns.Print("悬停: |cff8a929e只显示物品原来的介绍|r")
        end
    elseif msg:match("^tip") or msg:match("^物品") then
        -- 物品提示里为什么只有名字: 逐项打印接口形态 / 名称 / 链接 / 每种取法的行数
        local id = tonumber(msg:match("(%d+)") or "")
        if ns.UI and ns.UI.DebugItemTip then
            ns.UI.DebugItemTip(id)
        else
            ns.Print("|cffff5555界面模块未加载|r")
        end
    elseif msg == "strata" or msg == "层级" then        local cur, live = ns.UI.ApplyStrata()
        ns.Print("当前层级: " .. cur .. (live and "" or " (面板未创建, 登录后生效)"))
        print("  |cff8a929e可选: background / low / medium / high / dialog / fullscreen / fullscreen_dialog / tooltip|r")
        print("  |cff8a929e默认 DIALOG: 压在 EllesmereUI (快捷操作层/背包) 上面, 全屏弹窗仍在其上|r")
        print("  |cff8a929e想待在背包下面: /wgm strata medium  · 想连全屏弹窗都压住: /wgm strata tooltip|r")
    elseif msg:match("^strata ") or msg:match("^层级 ") then
        local want = (msg:match("^strata (.+)$") or msg:match("^层级 (.+)$")):upper():gsub(" ", "_")
        if not ns.UI.StrataExists or not ns.UI.StrataExists(want) then
            ns.Print("|cffff5555未知层级:|r " .. want)
            print("  可用: BACKGROUND / LOW / MEDIUM / HIGH / DIALOG / FULLSCREEN / FULLSCREEN_DIALOG / TOOLTIP")
        else
            ns.DB().strata = want
            local applied, live = ns.UI.ApplyStrata(want)
            ns.Print("层级已切到 " .. applied
                .. (live and "，已保存" or "，面板未创建, 登录后生效"))
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
        print("  |cffe8c25a/wgm ah|r         拍卖行查价状态 (API / 是否打开 / 缓存)")
        print("  |cffe8c25a/wgm ah list|r    逐条列出缓存价格与缺价原因")
        print("  |cffe8c25a/wgm ah clear|r   清空价格缓存")
        print("  |cffe8c25a/wgm search <ID>|r 在拍卖行里搜索该物品 (同左键点列表里的物品)")
        print("  |cffe8c25a/wgm npc|r        已记录的 NPC 购买价条数")
        print("  |cffe8c25a/wgm npc clear|r  清空手动录入的 NPC 购买价")
        print("  |cffe8c25a/wgm tip <ID>|r   诊断物品提示 (为什么只有名字 / 没有描述)")
        print("  |cffe8c25a/wgm tip extra|r  悬停改成「物品介绍 + 配方/价格」, 再输一次关掉")
        print("  |cffe8c25a/wgm strata|r     显示/切换面板层级 (默认 DIALOG, 压在 EllesmereUI 上层)")
        print("  |cffe8c25a/wgm strata medium|r  降到 MEDIUM (待在背包下面)")
        print("  |cffe8c25a/wgm strata tooltip|r 升到 TOOLTIP (压住全屏弹窗)")
    else
        ns.UI.Toggle()
    end
end
