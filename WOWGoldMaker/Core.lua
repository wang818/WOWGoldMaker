---------------------------------------------------------------------------
-- WOWGoldMaker / Core.lua
-- 命名空间、SavedVariables、事件分发、聊天命令、游戏内设置页注册。
---------------------------------------------------------------------------

local ADDON, ns = ...

ns.ADDON   = ADDON
-- 版本号直接从 .toc 读, 免得两处对不上 (以前这里写死 0.1.0, 设置页一直显示旧号)
ns.VERSION = (function()
    local v
    pcall(function()
        if C_AddOns and C_AddOns.GetAddOnMetadata then
            v = C_AddOns.GetAddOnMetadata(ADDON, "Version")
        end
    end)
    if not v then pcall(function() v = GetAddOnMetadata(ADDON, "Version") end) end
    return v or "0.0.0"
end)()

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
    ahAutoShow = true,                                    -- 打开拍卖行时自动呼出
    animations = true,                                    -- 界面动画
    pos        = { point = "RIGHT", relPoint = "RIGHT", x = 0, y = 0 },   -- 屏幕右侧垂直居中
    strata     = "DIALOG",                                -- 主面板层级 (DIALOG = 压在 EllesmereUI 上层)
    prices     = {},                                      -- 拍卖行价格缓存: itemID -> { unit, n, ts }
    npcBuy     = {},                                      -- NPC 购买价 (手动录入): itemID -> 铜
    vendorSeen = {},                                      -- 商人货架上实测到的价: itemID -> 铜
    favItems   = {},                                      -- 我的收藏: itemID -> 收藏时间 (os.time)
    tipExtra   = false,                                   -- 悬停是否附带配方/单价/盈亏 (默认只显示物品原来的介绍)

    -- 自动购买 (真花钱, 默认全关)
    autoBuyOn  = false,                                   -- 总开关: 拍卖行开着时按间隔扫一轮
    autoBuy    = {},                                      -- itemID -> { p = 单价上限(铜) }
    autoBuyGap = 60,                                      -- 扫描间隔 (秒), 最小 1, 上限不设
    -- 注: 旧存档里的 autoBuyCap 字段已不再使用, 留着无害 (MergeDefaults 不会删多余键)
}

local db
-- 面板是不是「跟着拍卖行自己弹出来的」。只有这种才在拍卖行关掉时替玩家收起;
-- 玩家用 /wgm 手动开的, 关拍卖行不该替他关。
local ahAuto = false

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
ev:RegisterEvent("AUCTION_HOUSE_SHOW")
-- AUCTION_HOUSE_CLOSED 在部分客户端不叫这个名字, 注册不上就算了:
-- 收不起来顶多是面板留在原地, 不影响查价
pcall(function() ev:RegisterEvent("AUCTION_HOUSE_CLOSED") end)
-- 商人货架: 打开商人时记一遍价 (拿 NPC 卖价的唯一实时来源)
pcall(function() ev:RegisterEvent("MERCHANT_SHOW") end)

-- 拍卖行开关时面板的显隐。
-- 开: 把面板叫出来 (查价、算利润都要用它, 每次手打 /wgm 太啰嗦; 设置里可以关掉);
-- 关: 只收「自己弹出来的」那个 —— 玩家用 /wgm 手动开的, 关拍卖行不该替他关。
local function OnAuctionHouseEvent(event)
    if event == "AUCTION_HOUSE_SHOW" then
        if not (db and db.ahAutoShow) then return end
        if not (ns.UI and ns.UI.Show) then return end

        if not ns.frame then
            if not ns.UI.Build then return end
            local ok, err = pcall(ns.UI.Build)
            if not ok then
                ns.Print("|cffff5555界面构建失败:|r " .. tostring(err))
                return
            end
        end

        -- 登录时已经自己弹出来的 (db.autoShow), 就别算成"跟着拍卖行走", 免得关窗口时被收走
        local wasShown = ns.frame and ns.frame:IsShown()
        ns.UI.Show()
        if not wasShown then ahAuto = true end
        return
    end

    if not ahAuto then return end
    ahAuto = false
    if ns.UI and ns.UI.Hide then ns.UI.Hide() end
end

-- 商人货架扫描: 打开商人是唯一能拿到「NPC 卖多少钱」的时机。
-- MERCHANT_SHOW 触发时货架偶尔还没填好, 所以再补一次延迟扫描 (重复扫是幂等的)。
local function ScanVendor()
    if not (ns.Vendor and ns.Vendor.Scan) then return end
    local ok, n = pcall(ns.Vendor.Scan)
    if ok and type(n) == "number" and n > 0 then
        if ns.UI and ns.UI.RefreshNpcAll then ns.UI.RefreshNpcAll() end
        -- 商人货架的价格口径也一样 (实测价优先于快照), 跟着重画
        if ns.Merchant and ns.Merchant.Refresh then pcall(ns.Merchant.Refresh) end
    end
end

local function OnMerchantShow()
    ScanVendor()
    if C_Timer and C_Timer.After then
        C_Timer.After(0.6, ScanVendor)
    end
end

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

    elseif event == "AUCTION_HOUSE_SHOW" or event == "AUCTION_HOUSE_CLOSED" then
        OnAuctionHouseEvent(event)

    elseif event == "MERCHANT_SHOW" then
        OnMerchantShow()
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
                local coin = tostring(s.gold) .. "金" .. tostring(s.silver) .. "银"
                    .. tostring(s.copper) .. "铜"
                if ns.T and ns.T.MoneyColor then coin = ns.T.MoneyColor(coin) end
                print("|cffe8c25a[WGM 数据]|r 铜=" .. tostring(s.money)
                    .. " → " .. coin .. " | 等级=" .. tostring(s.level))
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
    elseif msg == "alchemy" or msg == "炼金" or msg == "炼金术" then
        ns.OpenRecipes("alchemy")
    elseif msg == "alchemy mats" or msg == "炼金材料" then
        ns.OpenRecipes("alchemy", "mats")
    elseif msg == "prof" or msg == "专业" then
        ns.Print("可用专业 (点击主界面专业卡片也能打开):")
        for _, p in ipairs(ns.Prof.LIST) do
            print(format("  |cffe8c25a%-10s|r %s", p.key, p.name))
        end
        ns.Print("用法: /wgm prof first-aid  |  /wgm prof cooking  |  /wgm prof alchemy")
    elseif msg:match("^prof ") or msg:match("^专业 ") then
        local key = msg:match("^prof (.+)$") or msg:match("^专业 (.+)$")
        ns.OpenRecipes(key)
    elseif msg == "icons" then
        if ns.Prof and ns.Prof.DebugIcons then
            pcall(ns.Prof.DebugIcons)
        else
            ns.Print("|cffff5555专业模块未加载|r")
        end
    elseif msg:match("^ah%s+%d+$") then
        -- 把这件物品的原始挂单逐条列出来 (怀疑查价不对时用)
        if ns.Auction and ns.Auction.DumpItem then
            ns.Auction.DumpItem(tonumber(msg:match("(%d+)")))
        else
            ns.Print("|cffff5555查价模块未加载|r")
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
    elseif msg == "vendor" or msg == "商人" or msg == "货架" or msg == "商店" or msg == "stock" then
        -- 商人货架 = 独立窗口, 浏览全部货物 + 反查谁卖
        if ns.MerchantUI and ns.MerchantUI.Toggle then
            ns.MerchantUI.Toggle()
        else
            ns.Print("|cffff5555商人货架未加载|r (检查 MerchantUI.lua 是否在 .toc 里)")
        end
    elseif msg == "收藏" or msg == "我的收藏" or msg == "fav" or msg == "favorites" then
        -- 我的收藏 = 货架窗口的第二个页面, 直接打开
        if ns.MerchantUI and ns.MerchantUI.ShowFav then
            ns.MerchantUI.ShowFav()
        else
            ns.Print("|cffff5555收藏页未加载|r (检查 MerchantUI.lua 是否在 .toc 里)")
        end
    elseif msg:match("^收藏%s+(.+)$") or msg:match("^我的收藏%s+(.+)$") then
        local kw = msg:match("^收藏%s+(.+)$") or msg:match("^我的收藏%s+(.+)$")
        if ns.MerchantUI and ns.MerchantUI.ShowFav then
            ns.MerchantUI.ShowFav(kw)
        else
            ns.Print("|cffff5555收藏页未加载|r")
        end
    elseif msg:match("^货架 ") or msg:match("^商人 ") or msg:match("^vendor ") then
        local kw = msg:match("^货架 (.+)$") or msg:match("^商人 (.+)$") or msg:match("^vendor (.+)$")
        if kw == "scan" or kw == "扫描" then
            if ns.Vendor and ns.Vendor.Scan then
                local n = ns.Vendor.Scan()
                ns.Print(format("这次从商人货架上记下 %d 条价。", n))
                if n > 0 and ns.UI and ns.UI.RefreshNpcAll then ns.UI.RefreshNpcAll() end
                if ns.Merchant and ns.Merchant.Refresh then pcall(ns.Merchant.Refresh) end
            end
        elseif kw == "clear" or kw == "清空" then
            if ns.Vendor and ns.Vendor.ClearSeen then
                local n = ns.Vendor.ClearSeen()
                ns.Print(format("清掉 %d 条货架实测价, 退回离线价目表。", n))
                if ns.UI and ns.UI.RefreshNpcAll then ns.UI.RefreshNpcAll() end
                if ns.Merchant and ns.Merchant.Refresh then pcall(ns.Merchant.Refresh) end
            end
        elseif kw == "report" or kw == "报告" then
            if ns.Vendor and ns.Vendor.Report then
                ns.Vendor.Report()
            else
                ns.Print("|cffff5555商人模块未加载|r")
            end
        elseif ns.MerchantUI and ns.MerchantUI.Search then
            ns.MerchantUI.Search(kw)
        end
    elseif msg:match("^自动") or msg:match("^auto") then
        -- 自动购买: 无参数开设置窗, 带子命令直接操作
        local AB = ns.AutoBuy
        local sub = (msg:match("^自动%s*(.*)$") or msg:match("^auto%s*(.*)$") or ""):gsub("%s+$", "")
        if not AB then
            ns.Print("|cffff5555自动购买模块未加载|r (检查 AutoBuy.lua 是否在 .toc 里)")
        elseif sub == "" then
            if ns.UI and ns.UI.AutoBuyConfig then ns.UI.AutoBuyConfig() end
        elseif sub == "开" or sub == "on" then
            AB.SetEnabled(true)
            ns.Print("自动购买已开启 —— " .. AB.Summary())
            ns.Print(format("|cff8a929e打开拍卖行才会开始扫, 每 %d 秒一轮 (可调)|r", AB.Gap()))
        elseif sub == "关" or sub == "off" then
            AB.SetEnabled(false)
            ns.Print("自动购买已关闭")
        elseif sub == "扫" or sub == "scan" then
            local ok, why = AB.Scan()
            if ok then
                ns.Print("开始扫一轮, 成交会在这里报")
            else
                ns.Print("没扫: " .. tostring(why))
            end
        elseif sub == "列" or sub == "list" then
            local list = AB.List()
            if #list == 0 then
                ns.Print("自动购买列表是空的 —— 在材料行的「自动」按钮里加")
            else
                ns.Print(format("自动购买 %d 件 (%s):", #list, AB.Enabled() and "已开启" or "已关闭"))
                local AH = ns.Auction
                for _, e in ipairs(list) do
                    local p = (AH and AH.MoneyEx) and AH.MoneyEx(e.p) or tostring(e.p)
                    ns.Print(format("  #%d  ≤ %s/个  (背包已有 %d)", e.id, p, AB.Have(e.id)))
                end
            end
        elseif sub == "清空" or sub == "clear" then
            local list = AB.List()
            for _, e in ipairs(list) do AB.Remove(e.id) end
            ns.Print(format("自动购买列表已清空 (%d 件)", #list))
            if ns.MerchantUI and ns.MerchantUI.Refresh then pcall(ns.MerchantUI.Refresh) end
        elseif sub:match("^加") or sub:match("^add") then
            local id, g = sub:match("(%d+)%s+(%d+)")
            if not (id and g) then
                ns.Print("用法: /wgm 自动 加 <物品ID> <金>  (只填单价上限, 有挂单就买, 每轮最多 200 个)")
            else
                AB.Set(tonumber(id), tonumber(g) * 10000)
                ns.Print(format("已加入自动购买: #%s ≤ %s 金%s",
                    id, g, AB.Enabled() and "" or " (总开关还关着)"))
                if ns.MerchantUI and ns.MerchantUI.Refresh then pcall(ns.MerchantUI.Refresh) end
            end
        elseif sub == "面板" or sub == "page" or sub == "ui" then
            -- 图形界面: 商人货架的第三个页签, 能逐条改价/移除, 顶部还能改开关和间隔
            if ns.MerchantUI and ns.MerchantUI.ShowAuto then
                ns.MerchantUI.ShowAuto()
            else
                ns.Print("|cffff5555商人货架模块未加载|r")
            end
        elseif sub:match("^间隔") or sub:match("^频率") or sub:match("^gap") then
            -- 最小 1 秒, 上限不设: 填多少就多少, 只把 0 / 负数 / 非数字抬到 1 或退回默认
            local n = tonumber(sub:match("(%d+)"))
            if not n then
                ns.Print(format("当前扫描间隔 %d 秒 · 用法: /wgm 自动 间隔 <秒>", AB.Gap()))
            else
                ns.Print(format("扫描间隔改成 %d 秒%s", AB.SetGap(n),
                    AB.Enabled() and "" or " (总开关还关着)"))
            end
        else
            ns.Print("用法: /wgm 自动 [开|关|扫|列|面板|清空|间隔 <秒>|加 <ID> <金>]")
        end
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
        print("  |cffe8c25a/wgm alchemy|r    主界面切到炼金列表")
        print("  |cffe8c25a/wgm prof|r       列出所有专业")
        print("  |cffe8c25a/wgm icons|r      诊断专业/物品图标能否解析")
        print("  |cffe8c25a/wgm ah|r         拍卖行查价状态 (API / 是否打开 / 缓存)")
        print("  |cffe8c25a/wgm ah list|r    逐条列出缓存价格与缺价原因")
        print("  |cffe8c25a/wgm ah <ID>|r     逐条列出该物品的原始挂单 (查价对不上时用)")
        print("  |cffe8c25a/wgm ah clear|r   清空价格缓存")
        print("  |cffe8c25a/wgm search <ID>|r 在拍卖行里搜索该物品 (同左键点列表里的物品)")
        print("  |cffe8c25a/wgm npc|r        已记录的 NPC 购买价条数")
        print("  |cffe8c25a/wgm npc clear|r  清空手动录入的 NPC 购买价")
        print("  |cffe8c25a/wgm 商人|r       打开商人货架 (浏览所有商人的货, 反查谁卖)")
        print("  |cffe8c25a/wgm 货架 <词>|r  打开商人货架并搜索 (物品名或商人名)")
        print("  |cffe8c25a/wgm 收藏|r       打开「我的收藏」(货架行首点 ★ 收进来)")
        print("  |cffe8c25a/wgm 收藏 <词>|r  在我的收藏里搜索")
        print("  |cffe8c25a/wgm 自动|r       自动购买设置 (真花钱, 默认关)")
        print("  |cffe8c25a/wgm 自动 面板|r    打开自动购买列表 (可改价/移除)")
        print("  |cffe8c25a/wgm 自动 间隔 <秒>|r 改扫描间隔 (最小 1 秒, 不设上限)")
        print("  |cffe8c25a/wgm vendor report|r 商人价目表 / 当前货架报告")
        print("  |cffe8c25a/wgm stock|r      商人货架 (同 /wgm 商人)")
        print("  |cffe8c25a/wgm tip <ID>|r   诊断物品提示 (为什么只有名字 / 没有描述)")
        print("  |cffe8c25a/wgm tip extra|r  悬停改成「物品介绍 + 配方/价格」, 再输一次关掉")
        print("  |cffe8c25a/wgm strata|r     显示/切换面板层级 (默认 DIALOG, 压在 EllesmereUI 上层)")
        print("  |cffe8c25a/wgm strata medium|r  降到 MEDIUM (待在背包下面)")
        print("  |cffe8c25a/wgm strata tooltip|r 升到 TOOLTIP (压住全屏弹窗)")
    else
        ns.UI.Toggle()
    end
end
