---------------------------------------------------------------------------
-- WOWGoldMaker / Npc.lua
--
-- NPC 的两个价格, 来源完全不同:
--
--   Sell (卖给商人) —— 客户端物品库里的静态字段, **离线可查**: 不用开拍卖行、
--     不用站在 NPC 旁边、也不用商人窗口。取值链与「无限副本手册」一致:
--       C_Item.GetItemSellPrice → C_Item.GetItemInfo → GetItemInfo 第 11 个返回值
--     (sellPrice, 就是物品提示里那行「售价」)。同客户端的 EllesmereUI 背包
--     「商人出售价格」用的也是这条。
--
--   Buy (从商人买) —— 客户端没有这个接口: 只有商人窗口打开时才能用
--     C_MerchantFrame.GetItemInfo(index).price 逐项读到, 面板里根本没这个机会。
--     所以改成玩家手动录入一个单价, 存进 SavedVariables, 下次打开自动显示。
---------------------------------------------------------------------------

local ADDON, ns = ...

ns.NPC = ns.NPC or {}
local NPC = ns.NPC

local function Num(v)
    return type(v) == "number" and v == v and v >= 0 and v < math.huge
end

-- 金额格式化统一走查价模块 (12金34银 / 3银 / 45铜)
local function Money(c)
    if ns.Auction and ns.Auction.Money then return ns.Auction.Money(c) end
    return tostring(c)
end
NPC.Money = Money

-- 精确到铜的写法 (1金20银0铜 / 20银0铜 / 5铜)。录买价这类"要看清每一位"的地方用它:
-- Money 会把铜位、以及 0 银 0 铜 吞掉, 玩家看不出到底是 12金 还是 12金34银5铜
local function MoneyEx(c)
    if ns.Auction and ns.Auction.MoneyEx then return ns.Auction.MoneyEx(c) end
    return Money(c)
end
NPC.MoneyEx = MoneyEx

--------------------------------------------------------------------------- 卖给商人

local sellCache = {}    -- itemID -> 铜 (false = 已知不可卖给商人)
local askedAt   = {}    -- itemID -> 上次向客户端要数据的时间

local function RequestItem(id)
    if C_Item and type(C_Item.RequestLoadItemDataByID) == "function" then
        pcall(C_Item.RequestLoadItemDataByID, id)
    end
    -- 有的客户端没有上面那个函数, 或者它不真的发包; 顺手再查一次老的 GetItemInfo,
    -- 它在没缓存时会自己去服务器要 (有 2 秒节流兜着, 不会造成请求风暴)
    if type(GetItemInfo) == "function" then
        pcall(GetItemInfo, id)
    end
end

-- GetItemInfo 的返回值顺序 (多返回值形态):
--   1 名称  2 链接  3 品质  4 物品等级  5 需求等级  6 类型  7 子类型  8 堆叠数
--   9 装备位  10 图标  11 sellPrice  12 classID  13 subClassID  14 bindType ...
--
-- 但新版客户端的 C_Item.GetItemInfo 返回的是一个 ItemInfo **表** (字段 itemName /
-- sellPrice / ...), 不是多返回值。两种形态都得认 —— 否则表形态下第 11 个返回值是 nil,
-- 会被当成「售价 0 = 不可卖」, 整个面板的 NPC 价格就全是空的了。
--
-- 物品数据还没回包时这组函数一律返回 nil —— 所以「读不到」不能写缓存, 下一帧还要再试,
-- 否则第一次打开面板时物品还没缓存, 价格就永远变成空的了。
local function ReadFrom(fn, id)
    local r = { pcall(fn, id) }
    if not r[1] then return nil end

    if type(r[2]) == "table" then                 -- 新 API: ItemInfo 表
        local it = r[2]
        if it.itemName or it.itemID or it.itemLink then
            local sell = it.sellPrice or it.SellPrice
            if sell == nil then return nil end     -- 表里没这个字段: 让下一条路去试
            return (Num(sell) and math.floor(sell)) or 0, true
        end
        return nil
    end
    if type(r[2]) == "string" then                -- 旧 API: 多返回值
        return (Num(r[12]) and math.floor(r[12])) or 0, true
    end
    return nil
end

local function ReadSell(id)
    if C_Item and type(C_Item.GetItemInfo) == "function" then
        local v, known = ReadFrom(C_Item.GetItemInfo, id)
        if known then return v, true end
    end
    if type(GetItemInfo) == "function" then
        local v, known = ReadFrom(GetItemInfo, id)
        if known then return v, true end
    end
    if C_Item and type(C_Item.GetItemSellPrice) == "function" then
        local ok, v = pcall(C_Item.GetItemSellPrice, id)
        if ok and Num(v) then return math.floor(v), true end
    end
    return nil, false
end

-- 卖给商人的单价 (铜)。取不到返回 nil: 数据还没回包, 或者这物品卖不了 (售价 0)
function NPC.Sell(id)
    if type(id) ~= "number" or id <= 0 then return nil end

    local hit = sellCache[id]
    if hit ~= nil then
        if hit then return hit end
        return nil
    end

    local v, known = ReadSell(id)
    if known then
        local price = (v and v > 0) and v or false
        sellCache[id] = price
        return price or nil
    end

    -- 没有数据: 顺手向客户端要一次。同一个物品 2 秒内只请求一次,
    -- 免得每帧 (列表几十行) 都发一遍请求。
    local now = GetTime()
    local last = askedAt[id]
    if not last or now - last > 2 then
        askedAt[id] = now
        RequestItem(id)
    end
    return nil
end

-- 已经拿到 (或确认没有) 卖价了吗 —— 界面用它决定还要不要重画
function NPC.SellKnown(id)
    local hit = sellCache[id]
    return hit ~= nil
end

function NPC.ResetSell()
    for k in pairs(sellCache) do sellCache[k] = nil end
    for k in pairs(askedAt) do askedAt[k] = nil end
end

--------------------------------------------------------------------------- 物品基础信息

-- 名称 + 链接。链接是给 GameTooltip:SetHyperlink 用的: 只有带上完整链接, 客户端才会
-- 把「用途 / 使用效果 / 描述 / 售价」那些行一起吐出来; 很多客户端上光给 itemID
-- (SetItemByID) 只出一行名字, 这也是插件里看不到「这物品是干什么的」的常见原因。
function NPC.Info(id)
    if type(id) ~= "number" or id <= 0 then return nil end

    local name, link
    local function take(v, l)
        if type(v) == "table" then
            local n = v.itemName or v.name
            if type(n) == "string" and n ~= "" then name = name or n end
            local k = v.itemLink or v.itemHyperlink
            if type(k) == "string" and k ~= "" then link = link or k end
        elseif type(v) == "string" and v ~= "" then
            name = name or v
            if type(l) == "string" and l ~= "" then link = link or l end
        end
    end

    if C_Item and type(C_Item.GetItemInfo) == "function" then
        local ok, a, b = pcall(C_Item.GetItemInfo, id)
        if ok then take(a, b) end
    end
    if type(GetItemInfo) == "function" and (not name or not link) then
        local ok, a, b = pcall(GetItemInfo, id)
        if ok then take(a, b) end
    end

    if name or link then return name, link end

    -- 还没有数据: 顺手向客户端要一次 (同一个物品 2 秒内只请求一次)。
    -- 悬停时调用, 于是第一次悬停可能只有名字, 数据回包后再悬停就全了 (UI 那边会重试一次)。
    local now = GetTime()
    if not askedAt[id] or now - askedAt[id] > 2 then
        askedAt[id] = now
        RequestItem(id)
    end
    return nil
end

--------------------------------------------------------------------------- 从商人买 (手动录入)

-- 存在 db.npcBuy[itemID] = 铜。用 db 持久化, 下次登录/重开面板直接显示。
local function BuyTable(create)
    local db = ns.DB and ns.DB()
    if type(db) ~= "table" then return nil end
    if not db.npcBuy then
        if not create then return nil end
        db.npcBuy = {}
    end
    return db.npcBuy
end

function NPC.Buy(id)
    local t = BuyTable(false)
    if not t or type(id) ~= "number" then return nil end
    local v = t[id]
    if Num(v) and v > 0 then return math.floor(v) end
    return nil
end

-- copper 为空/<=0 表示删掉这条记录
function NPC.SetBuy(id, copper)
    local t = BuyTable(true)
    if not t or type(id) ~= "number" or id <= 0 then return false end
    if not Num(copper) or copper <= 0 then
        t[id] = nil
        return true
    end
    t[id] = math.floor(copper)
    return true
end

function NPC.BuyCount()
    local t = BuyTable(false)
    local n = 0
    if t then for _ in pairs(t) do n = n + 1 end end
    return n
end

function NPC.ClearBuy()
    local t = BuyTable(false)
    local n = 0
    if t then
        for k in pairs(t) do t[k] = nil; n = n + 1 end
    end
    return n
end

--------------------------------------------------------------------------- 金额输入解析

-- 单位对照: 金/银/铜 与 g/s/c 都认, 大小写不敏感 (gsub 后统一小写再查)
local UNIT = {
    ["金"] = 10000, gold = 10000, g = 10000,
    ["银"] = 100,   silver = 100, s = 100,
    ["铜"] = 1,     copper = 1,   c = 1,
}

-- 解析玩家输入, 返回 铜 或 nil+原因:
--   "1金20银30铜" / "1g20s30c" / "20银" / "1.5金" / "20" (= 20银)
-- 纯数字按银算 —— 记 NPC 买价时最常见的量级就是银, 而且提示里会写明。
function NPC.ParseMoney(text)
    if type(text) ~= "string" then return nil, "没有输入" end
    local s = text:gsub("[%s,，]", "")
    if s == "" then return nil, "没有输入" end

    local total, count = 0, 0
    local i, len = 1, #s
    while i <= len do
        -- 数字 (可带小数) + 单位 (中文/字母, 允许没有)
        local numStr, unit, nextPos = s:match("^(%d+%.?%d*)([%a\128-\255]*)()", i)
        if not numStr then return nil, "看不懂这个写法" end
        local n = tonumber(numStr)
        if not n then return nil, "看不懂这个写法" end

        local mult
        if unit == "" then
            mult = UNIT["银"]
        else
            mult = UNIT[unit] or UNIT[unit:lower()]
            if not mult then return nil, "单位只认 金/银/铜 (或 g/s/c)" end
        end

        total = total + n * mult
        count = count + 1
        i = nextPos
    end

    if count == 0 then return nil, "没有输入" end
    total = math.floor(total + 0.5)
    if total <= 0 then return nil, "要大于 0" end
    return total
end
