---------------------------------------------------------------------------
-- WOWGoldMaker / Auction.lua
-- 拍卖行查价: 把配方产物 + 每样材料逐个丢给拍卖行搜索, 取最低单价算盈亏。
--
-- 接口版本 (关键): 本客户端是 12.1 引擎 (WoWForever 1.60.1), 拍卖行走的是
-- 现代 C_AuctionHouse 命名空间, **没有**经典式全局函数。
--   ✗ QueryAuctionItems / GetAuctionItemInfo / GetNumAuctionItems / CanSendAuctionQuery
--   ✓ C_AuctionHouse.MakeItemKey / SendSearchQuery
--     GetNumCommoditySearchResults + GetCommoditySearchResultInfo  (可堆叠商品)
--     GetNumItemSearchResults      + GetItemSearchResultInfo       (单件拍卖)
-- 一开始按经典 API 写, 实测点了就提示「无 AH 接口」—— 在 Wow.exe 里查字符串也确认
-- 那四个旧函数一个都不存在, 所以这里改为按 ID 搜索的现代接口。
--
-- 约定:
--   * 搜索用 itemID (ItemKey), 不再按物品名做文本搜索, 因此不需要等物品名缓存;
--   * 商品结果里 unitPrice 本身就是单价; 单件结果里 buyoutAmount 是整叠总价,
--     要除以 quantity 才是单价;
--   * 查询必须拍卖行窗口打开 (AuctionHouseFrame:IsShown());
--   * 搜索频率有上限 (约 100 次/分钟), 所以全部查询串行排队, 一次只发一条,
--     等不到回包就重试。
--
-- 价格口径:
--   单价 = 该挂单的买断价 / 数量
--   成本 = Σ 材料单价 × 用量
--   收入 = 产物单价 × 产量 × (1 - 5% 拍卖行抽成)
--   利润 = 收入 - 成本
---------------------------------------------------------------------------

local ADDON, ns = ...

local AH = {}
ns.Auction = AH
ns.AH = AH          -- 短别名, 方便游戏内手敲

local format = string.format

-- 缓存 / 节奏参数
local TTL       = 30 * 60   -- 有价格: 30 分钟内直接复用
local TTL_MISS  = 5 * 60    -- 查不到货: 5 分钟后重查
local TIMEOUT   = 3.5       -- 单次查询等回包的上限 (秒)
local RETRY     = 0.6       -- 超时后重试间隔
local RETRY_MAX = 3         -- 单条最多发几次
local CUT       = 0.05      -- 拍卖行抽成

--------------------------------------------------------------------------- 小工具

local function Now()
    return (type(time) == "function" and time()) or 0
end

-- 铜 → 简短中文金额 (12金34银 / 3银 / 45铜)。会丢掉铜位, 用在「够看就行」的地方。
function AH.Money(copper)
    local c = math.floor(math.abs(tonumber(copper) or 0))
    local g = math.floor(c / 10000)
    local s = math.floor((c % 10000) / 100)
    if g >= 10000 then
        return format("%.1f万金", g / 10000)
    end
    if g > 0 then
        if s > 0 and g < 1000 then
            return format("%d金%d银", g, s)
        end
        return format("%d金", g)
    end
    if s > 0 then return format("%d银", s) end
    return format("%d铜", c)
end

-- 铜 → 精确到 1 铜的金额 (1金23银45铜)。盈亏用它: 1金 = 100银 = 100铜,
-- 所有计算都是整数铜, 显示也不该把铜位四舍五入掉 (差 99 铜也是差)。
function AH.MoneyEx(copper)
    local c = math.floor(math.abs(tonumber(copper) or 0))
    local g = math.floor(c / 10000)
    local s = math.floor((c % 10000) / 100)
    local k = c % 100
    if g >= 100000 then
        -- 十万金以上才用「万」缩写, 且四舍五入到 0.1 万金 = 1000 金, 已经无法精确到铜,
        -- 前面加 ≈ 让「这是约数」看得出来
        return format("≈%.1f万金", g / 10000)
    end
    local parts = {}
    if g > 0 then parts[#parts + 1] = format("%d金", g) end
    if s > 0 then parts[#parts + 1] = format("%d银", s) end
    -- 有金/银时, 铜为 0 就不写; 只有铜时一定要写
    if k > 0 or #parts == 0 then parts[#parts + 1] = format("%d铜", k) end
    return table.concat(parts)
end

local function Cache()
    local db = ns.DB()
    if not db then return {} end
    db.prices = db.prices or {}
    return db.prices
end

--------------------------------------------------------------------------- 缓存

-- 取缓存价格: 返回 { unit=每片价(铜), n=挂单数, ts=时间戳 } 或 nil
-- unit 为 nil 表示上次查了但没有挂单 (TTL_MISS 内不再重查)
function AH.Price(itemID, allowStale)
    if not itemID then return nil end
    local e = Cache()[itemID]
    if not e then return nil end
    local age = Now() - (e.ts or 0)
    local ttl = e.unit and TTL or TTL_MISS
    if allowStale or age <= ttl then return e end
    return nil
end

function AH.Age(itemID)
    local e = Cache()[itemID]
    if not e then return nil end
    return Now() - (e.ts or 0)
end

function AH.Clear()
    local c = Cache()
    for k in pairs(c) do c[k] = nil end
    ns.Print("价格缓存已清空。")
end

--------------------------------------------------------------------------- 接口探测

-- 本客户端的拍卖行命名空间; 缺函数时返回 nil
local function AHAPI()
    local c = _G.C_AuctionHouse
    if type(c) == "table" and type(c.SendSearchQuery) == "function" then return c end
    return nil
end

function AH.Available()
    local c = AHAPI()
    if not c then return false end
    return type(c.GetCommoditySearchResultInfo) == "function"
        or type(c.GetItemSearchResultInfo) == "function"
end

-- 拍卖行窗口; 现代客户端是 AuctionHouseFrame, 保险起见两个都看
local function AHFrame()
    return _G.AuctionHouseFrame or _G.AuctionFrame
end

local function AHOpen()
    local f = AHFrame()
    if not f then return true end      -- 没有 UI 对象时不拦, 让查询自己去报错
    local ok, shown = pcall(f.IsShown, f)
    if not ok then return true end
    return shown and true or false
end

-- 能不能立刻发一条查询; 不能时返回原因
function AH.CanQuery()
    if not AH.Available() then
        return false, "客户端缺少拍卖行查询 API"
    end
    if not AHOpen() then
        return false, "拍卖行未打开"
    end
    return true
end

-- 排序: 价格升序, 第一条就是最便宜的
local sorts
local function Sorts()
    if sorts then return sorts end
    sorts = {}
    local e = _G.Enum and _G.Enum.AuctionHouseSortOrder
    if e and e.Price ~= nil then
        sorts[1] = { sortOrder = e.Price, reverseSort = false }
    end
    return sorts
end

-- ItemKey 可以复用, 每个物品只 MakeItemKey 一次。
-- 注意: 不要往 MakeItemKey 返回的表里写字段 —— 那会给它打上 taint 标记,
-- 而 SendSearchQuery 是受限函数, 带 taint 的参数有可能污染拍卖行。
local keys = {}
local function ItemKey(id)
    local k = keys[id]
    if k then return k end
    local ok, key = pcall(function()
        return _G.C_AuctionHouse.MakeItemKey(id)
    end)
    if not (ok and type(key) == "table") then
        key = { itemID = id, itemLevel = 0, itemSuffix = 0, battlePetSpeciesID = 0 }
    end
    keys[id] = key
    return key
end

--------------------------------------------------------------------------- 读结果

-- 兼容两种签名: 带 itemID/itemKey 的和不带参数的
local function CallID(fn, id, idx)
    if type(fn) ~= "function" then return nil end
    local ok, a, b = pcall(fn, id, idx)
    if ok and a ~= nil then return a, b end
    if idx == nil then
        ok, a, b = pcall(fn)
        if ok then return a, b end
    elseif ok then
        -- GetXxxResultInfo(id, i) 失败时再试 (i), 老一点的点法
        ok, a, b = pcall(fn, idx)
        if ok then return a, b end
    end
    return nil
end

-- 这条挂单到底是不是我们要的那件物品。
-- 拍卖行的名字搜索是「包含」匹配: 搜「亚麻布」会连「亚麻布卷」「亚麻布手套」一起
-- 列出来。不认 ID 就会把别人的最低价当自己的, 算出来的成本/盈亏全是假的。
-- 结果项里有 ID 就核对; 一个字段都取不到才按老样子用 (那说明接口本身按 key 过滤过)。
local function ResultID(r)
    if type(r) ~= "table" then return nil end

    local k = r.itemKey
    if type(k) == "table" then
        local v = tonumber(k.itemID) or tonumber(k[1])
        if v then return v end
    end

    local v = tonumber(r.itemID)
    if v then return v end

    local link = r.itemLink or r.itemHyperlink
    if type(link) == "string" then
        local s = link:match("item:(%d+)")
        if s then return tonumber(s) end
    end
    return nil
end

-- 可堆叠商品: 单价字段在各版本叫法不一样 (unitPrice / minPrice 都是单价),
-- 万一给的是整叠总价再用数量折算。老代码只认 unitPrice, 新版客户的 minPrice
-- 一条都读不到 —— 这类物品就一直显示「无挂单」。
local function ReadCommodity(id)
    local c = AHAPI()
    if not c then return nil, 0 end
    local n = tonumber(CallID(c.GetNumCommoditySearchResults, id)) or 0

    local best, count, other = nil, 0, 0
    for i = 1, n do
        local r = CallID(c.GetCommoditySearchResultInfo, id, i)
        if type(r) == "table" then
            local rid = ResultID(r)
            if rid and id and rid ~= id then
                other = other + 1          -- 名字相近的别的物品, 不算
            else
                local unit = tonumber(r.unitPrice) or tonumber(r.minPrice)
                if not unit then
                    local total = tonumber(r.buyoutAmount)
                        or tonumber(r.buyout)
                        or tonumber(r.price)
                    local qty = tonumber(r.quantity)
                        or tonumber(r.totalQuantity) or 1
                    if total and qty > 0 then unit = total / qty end
                end
                if unit and unit > 0 then
                    count = count + 1
                    if not best or unit < best then best = unit end
                end
            end
        end
    end
    return best, count, other
end

-- 单件拍卖: buyoutAmount 是整叠总价, 除以数量才是单价
local function ReadItems(key, id)
    local c = AHAPI()
    if not c then return nil, 0 end
    local n = tonumber(CallID(c.GetNumItemSearchResults, key)) or 0

    local best, count, other = nil, 0, 0
    for i = 1, n do
        local r = CallID(c.GetItemSearchResultInfo, key, i)
        if type(r) == "table" then
            local rid = ResultID(r)
            if rid and id and rid ~= id then
                other = other + 1          -- 名字相近的别的物品, 不算
            else
                local qty = tonumber(r.quantity) or tonumber(r.totalQuantity) or 1
                if qty < 1 then qty = 1 end
                local total = tonumber(r.buyoutAmount)
                    or tonumber(r.bidAmount)
                    or tonumber(r.minBid)
                    or tonumber(r.buyout)
                    or tonumber(r.price)
                if total and total > 0 then
                    local unit = total / qty
                    count = count + 1
                    if not best or unit < best then best = unit end
                end
            end
        end
    end
    return best, count, other
end

-- 不知道这个物品是可堆叠商品还是单件拍卖, 两种都读一次 (谁有价用谁)
local function ReadAny(id, key)
    local best, n, o1 = ReadCommodity(id)
    if best then return best, n, o1 end
    local b2, n2, o2 = ReadItems(key, id)
    if b2 then return b2, n2, o2 end
    return nil, (n or 0) + (n2 or 0), (o1 or 0) + (o2 or 0)
end

--------------------------------------------------------------------------- 计算

-- 用给定的单价表算一次配方的盈亏
-- res: itemID -> { unit = 每片价 }
local function Calculate(rec, res)
    local made = rec.made or 1
    local prod = res[rec.item]
    local unit = prod and prod.unit or nil
    local revenue = unit and (unit * made) or nil

    -- missing 只放名字 (界面直接拼字符串用), why 放"名字 + 原因", 排查时用
    local cost, missing, why = 0, {}, {}
    for i = 1, #(rec.mats or {}) do
        local m = rec.mats[i]
        local e = res[m.id]
        local nm = m.name or ("物品#" .. tostring(m.id))
        if e and e.unit then
            cost = cost + e.unit * (m.count or 1)
        else
            missing[#missing + 1] = nm
            why[#why + 1] = { name = nm, id = m.id, reason = (e and e.reason) or "无挂单" }
        end
    end
    if not unit then
        local nm = rec.name or "产物"
        missing[#missing + 1] = nm
        why[#why + 1] = { name = nm, id = rec.item, reason = (prod and prod.reason) or "无挂单" }
    end

    -- 抽成算完取整到铜: 游戏里收的是整铜, 结果带 0.95 个铜没有意义,
    -- 而且盈亏是给玩家看的数, 内部留着小数容易和显示的金额对不上
    local net = revenue and math.floor(revenue * (1 - CUT)) or nil
    local profit = (net and #missing == 0) and (net - cost) or nil

    -- NPC 保底口径: 成本不动 (材料照拍卖行价买), 收入换成把成品卖给商人。
    -- 两个盈亏放在一起看, 才能回答「这批货卖玩家还是直接甩商人」;
    -- 材料成本两边共用, 所以差的只是销售渠道。
    local NPC = ns.NPC
    local npcUnit = (NPC and NPC.Sell) and NPC.Sell(rec.item) or nil
    local npcKnown = (NPC and NPC.SellKnown) and NPC.SellKnown(rec.item) or false
    local npcRevenue = npcUnit and (npcUnit * made) or nil
    local npcProfit = (npcRevenue and #missing == 0) and (npcRevenue - cost) or nil

    return {
        rec     = rec,
        unit    = res,
        made    = made,
        revenue = revenue,
        tax     = revenue and (revenue - net) or nil,
        net     = net,
        cost    = cost,
        profit  = profit,
        -- NPC 一侧: unit 是收购单价, known 区分「还没读到」和「商人不要这件东西」
        npcUnit    = npcUnit,
        npcKnown   = npcKnown,
        npcRevenue = npcRevenue,
        npcProfit  = npcProfit,
        missing = missing,
        why     = why,
    }
end

-- 只用缓存算, 不发查询; 任一价格缺失返回 nil
function AH.Preview(rec)
    if not (rec and rec.item) then return nil end
    local res = {}
    local p = AH.Price(rec.item)
    if not (p and p.unit) then return nil end
    res[rec.item] = p
    for i = 1, #(rec.mats or {}) do
        local m = rec.mats[i]
        local e = AH.Price(m.id)
        if not (e and e.unit) then return nil end
        res[m.id] = e
    end
    return Calculate(rec, res)
end

--------------------------------------------------------------------------- 查询队列

local scanQueue = {}   -- 待查: { id }
local queued    = {}   -- id -> entry (排队中或正在查, 用于去重)
local inflight         -- 当前正在查的 entry
local waiters   = {}   -- id -> { task, ... } 等这条价格的任务

local Pump, StartQuery, FinishEntry, AbortEntry

-- 单条查询结束 (成功或失败) 后通知等它的任务
local function Notify(id, entry)
    local list = waiters[id]
    waiters[id] = nil
    if not list then return end

    for i = 1, #list do
        local t = list[i]
        t.res[id] = entry
        local done = 0
        for j = 1, #t.ids do
            if t.res[t.ids[j]] then done = done + 1 end
        end
        if t.onProgress then
            pcall(t.onProgress, done, #t.ids, id)
        end
        if done >= #t.ids then
            local out = Calculate(t.rec, t.res)
            if t.onDone then pcall(t.onDone, out) end
        end
    end
end

FinishEntry = function(e, unit, n, other)
    -- unit 为 nil = 搜索成功但一条挂单都没有, 记成「无挂单」而不是留空,
    -- 否则界面上只能显示"缺 N 项", 分不清是没货还是查询出问题
    -- other = 结果里混进来的、名字相近的别的物品条数 (已排除, 不算价)
    local entry = { unit = unit, n = n or 0, ts = Now() }
    if (other or 0) > 0 then entry.other = other end
    if not unit then
        entry.reason = (other or 0) > 0
            and format("无挂单 (另有 %d 条名字相近的物品, 已排除)", other)
            or "无挂单"
    end
    Cache()[e.id] = entry
    queued[e.id] = nil
    if inflight == e then inflight = nil end
    Notify(e.id, entry)
    Pump()
end

local lastNoticeAt = -100

-- 同一批查询里只提示一次, 免得 4 样材料各刷一行
-- 优先弹在插件界面里 (查价是界面操作, 反馈也该留在界面上); 界面没显示时才退回聊天框
local function Notice(msg)
    local t = (type(GetTime) == "function" and GetTime()) or 0
    if t - lastNoticeAt < 3 then return end
    lastNoticeAt = t
    if ns.UI and ns.UI.Notify and ns.UI.Notify(msg, 5) then return end
    ns.Print(msg)
end

AbortEntry = function(e, reason)
    queued[e.id] = nil
    if inflight == e then inflight = nil end
    -- 只在会打断整轮查询的情况下提示, 且同一批只提示一次
    if reason == "拍卖行未打开" then
        Notice("|cffff9955拍卖行已关闭, 查价中断|r")
    elseif reason == "客户端缺少拍卖行查询 API" then
        Notice("|cffff9955客户端没有拍卖行查询接口, 无法查价|r")
    elseif type(reason) == "string" and reason:match("^查询失败") then
        Notice("|cffff5555" .. reason .. "|r")
    elseif reason == "查询超时" then
        Notice("|cffff9955拍卖行没有回包, 稍后再试|r")
    end
    Notify(e.id, { unit = nil, ts = Now(), reason = reason })
    Pump()
end

StartQuery = function(e)
    if inflight ~= e then return end

    local ok, reason = AH.CanQuery()
    if not ok then
        AbortEntry(e, reason)      -- 这两个原因都是终态, 重试没用
        return
    end

    e.tries = (e.tries or 0) + 1
    e.token = (e.token or 0) + 1
    local token = e.token
    e.key = ItemKey(e.id)

    local okSend, err = pcall(_G.C_AuctionHouse.SendSearchQuery,
        e.key, Sorts(), false)
    if not okSend then
        -- 这个函数在正式服标了 restricted: 插件调用被拦截时错误文案里会出现这些词
        local msg = tostring(err)
        local low = msg:lower()
        if low:find("restrict", 1, true) or low:find("protect", 1, true)
            or low:find("taint", 1, true) then
            msg = "客户端禁止插件调用拍卖行搜索"
        end
        AbortEntry(e, "查询失败: " .. msg)
        return
    end

    C_Timer.After(TIMEOUT, function()
        if inflight ~= e or e.token ~= token then return end

        -- 事件没来但数据已经在本地 (同一物品之前查过、客户端认为"没变化"就不再发事件):
        -- 直接读一次, 别白白重试
        local best, n, other = ReadAny(e.id, e.key)
        if best then
            FinishEntry(e, best, n, other)
            return
        end

        if e.tries >= RETRY_MAX then
            AbortEntry(e, "查询超时")
        else
            C_Timer.After(RETRY, function() StartQuery(e) end)
        end
    end)
end

Pump = function()
    if inflight then return end
    local e = table.remove(scanQueue, 1)
    if not e then return end
    inflight = e
    StartQuery(e)
end

--------------------------------------------------------------------------- 事件: 拍卖行回包

-- 可堆叠商品 → COMMODITY_SEARCH_RESULTS_UPDATED(itemID)
-- 单件拍卖   → ITEM_SEARCH_RESULTS_UPDATED(itemKey)
-- 分别注册: 万一某个事件名在这版客户端不存在, 另一个还能挂上
local ev = CreateFrame("Frame")

-- 记录注册结果, /wgm ah 里能看出事件名在这版客户端是否有效
local Hooks = { commodity = false, item = false }
Hooks.commodity = pcall(function() ev:RegisterEvent("COMMODITY_SEARCH_RESULTS_UPDATED") end) and true or false
Hooks.item      = pcall(function() ev:RegisterEvent("ITEM_SEARCH_RESULTS_UPDATED") end) and true or false
Hooks.ahShow    = pcall(function() ev:RegisterEvent("AUCTION_HOUSE_SHOW") end) and true or false

ev:SetScript("OnEvent", function(_, event, arg)
    -- 主面板现在在 MEDIUM 层 (待在背包下面), 拍卖行窗口在更高层, 必定盖住面板右侧,
    -- 所以这里不再 Raise —— 一边 SetFrameLevel(1) 压到同层最低、一边 Raise 顶到最上,
    -- 两者是矛盾的。查价时靠页面浮层提示, 不依赖面板可见。
    if event == "AUCTION_HOUSE_SHOW" then
        -- 窗口重开时控件可能重建, 搜索栏的缓存作废, 下次重新探
        if AH.SearchUI then AH.SearchUI(true) end
        return
    end

    local e = inflight
    if not e then return end

    if event == "COMMODITY_SEARCH_RESULTS_UPDATED" then
        if tonumber(arg) ~= e.id then return end
        e.gotComm = true
    elseif event == "ITEM_SEARCH_RESULTS_UPDATED" then
        -- arg 是 ItemKey, 各版本字段名不一致 (itemID / [1] / 甚至没有)。
        -- 队列串行, 同时只有一条 inflight, 所以取不到 ID 时也按它自己读一次:
        -- ReadItems 用的是我们这次搜索的 key, 不会串到拍卖行窗口自己的搜索结果上。
        local id = (type(arg) == "table")
            and (tonumber(arg.itemID) or tonumber(arg[1])) or tonumber(arg)
        if id and id ~= e.id then return end
        e.gotItem = true
    else
        return
    end

    -- 商品和单件是两套结果, 两个事件各来一次。只读来的那一套会出错:
    -- 先到的若是空的那套, 就会把结论锁成「无挂单」, 后面有货的那套来了也不管了。
    -- 所以每次事件都两边读一遍, 而且要等两套都回过话才算数。
    local best, n, other = ReadAny(e.id, e.key)

    -- 某个事件名在这版客户端注册不上时, 收到另一个就能定论
    local settled = best ~= nil
        or (e.gotItem and (e.gotComm or not Hooks.commodity))
        or (e.gotComm and not Hooks.item)
    if not settled then return end    -- 等另一套回包; 实在不来还有超时兜底

    FinishEntry(e, best, n, other)
end)

--------------------------------------------------------------------------- 对外: 查一个配方

-- rec: ns.Prof.Get() 里的一条 (含 item / made / mats)
-- onDone(out): out 见 Calculate
-- onProgress(done, total)
-- force: true = 无视缓存, 全部重新发查询
--   「查价」按钮走的就是 force —— 按钮的语义是「现在的行情是多少」, 拿半小时前的缓存
--   回显等于骗人: 挂单被扫光了、价格翻了倍, 界面上还是旧数字, 而且看起来"查过了"。
--   已经在队列里排着的物品不再重复入队 (那本身就是刚发出去、还没回包的查询)。
function AH.CheckRecipe(rec, onDone, onProgress, force)
    if not (rec and rec.item) then return end

    -- 收集要查的物品: 产物 + 全部材料 (按 id 去重)
    local ids, seen = {}, {}
    local function add(id)
        if not id or seen[id] then return end
        seen[id] = true
        ids[#ids + 1] = id
    end
    add(rec.item)
    for i = 1, #(rec.mats or {}) do
        add(rec.mats[i].id)
    end

    local res = {}
    if not force then
        for i = 1, #ids do
            local e = AH.Price(ids[i])
            if e then res[ids[i]] = e end
        end
    end

    local pending = 0
    for i = 1, #ids do
        if not res[ids[i]] then pending = pending + 1 end
    end

    if pending == 0 then
        if onDone then pcall(onDone, Calculate(rec, res)) end
        return
    end

    local task = { rec = rec, ids = ids, res = res, onDone = onDone, onProgress = onProgress }

    for i = 1, #ids do
        local id = ids[i]
        if not res[id] then
            waiters[id] = waiters[id] or {}
            table.insert(waiters[id], task)
            if not queued[id] then
                local entry = { id = id }
                queued[id] = entry
                scanQueue[#scanQueue + 1] = entry
            end
        end
    end

    Pump()
end

--------------------------------------------------------------------------- 对外: 状态 / 调试 / 输出

function AH.Busy()
    return inflight ~= nil or #scanQueue > 0
end

-- 一行聊天结论
function AH.Report(out)
    if not out then return end
    local rec = out.rec or {}
    local name = rec.name or "?"

    if not out.profit then
        -- 带上每项的原因: 无挂单 / 查询超时 / 查询失败: xxx, 一眼能看出是"没货"还是"接口出问题"
        local parts = {}
        for i = 1, #(out.why or {}) do
            local w = out.why[i]
            parts[#parts + 1] = format("%s(%s)", w.name, w.reason or "?")
        end
        if #parts == 0 then parts[1] = table.concat(out.missing or {}, ", ") end
        ns.Print(format("|cffe8c25a[查价]|r %s |cffff9955价格不全|r: %s",
            name, table.concat(parts, ", ")))
        return
    end

    local sign = out.profit >= 0
    local color = sign and "|cff66cc73" or "|cffeb6b6b"
    ns.Print(format("|cffe8c25a[查价]|r %s → %s%s%s|r  (收 %s · 本 %s)",
        name, color, sign and "盈 " or "亏 ", AH.MoneyEx(math.abs(out.profit)),
        AH.MoneyEx(out.net or 0), AH.MoneyEx(out.cost or 0)))

    -- NPC 那一档跟着播一行: 拍卖行亏但商人赚的时候, 这单其实还能做
    if out.npcProfit then
        local ok = out.npcProfit >= 0
        local c2 = ok and "|cff66cc73" or "|cffeb6b6b"
        ns.Print(format("|cffe8c25a[查价]|r %s → NPC %s%s%s|r  (商人收 %s)",
            name, c2, ok and "盈 " or "亏 ", AH.MoneyEx(math.abs(out.npcProfit)),
            AH.MoneyEx(out.npcRevenue or 0)))
    elseif out.npcKnown then
        ns.Print(format("|cffe8c25a[查价]|r %s → NPC 商人收不了这个", name))
    end
end

function AH.Debug()
    local frames = 0
    for _ in pairs(Cache()) do frames = frames + 1 end
    local f = AHFrame()
    local exists = f and true or false
    local shown = exists and AHOpen() and true or false

    ns.Print("拍卖行查价状态:")
    print("  接口:", AH.Available() and "C_AuctionHouse 可用" or "|cffff5555缺失")
    print("  窗口:", exists and (shown and "已打开" or "未打开") or "无此框架")
    local ch = AHAPI()
    local function fn(name)
        return (ch and type(ch[name]) == "function") and "有" or "|cffff5555无"
    end
    print("  函数: SendSearchQuery=" .. fn("SendSearchQuery")
        .. " GetCommoditySearchResultInfo=" .. fn("GetCommoditySearchResultInfo")
        .. " GetItemSearchResultInfo=" .. fn("GetItemSearchResultInfo"))
    print(format("  缓存 %d 条 · 队列 %d 条 · %s", frames, #scanQueue,
        inflight and ("正在查 #" .. tostring(inflight.id)) or "空闲"))
    if #scanQueue > 0 then
        local ids = {}
        for i = 1, #scanQueue do ids[i] = scanQueue[i].id end
        print("  待查:", table.concat(ids, ", "))
    end
    if Hooks then   -- 事件名是否真的挂上了
        print("  事件: 商品=" .. (Hooks.commodity and "已注册" or "|cffff5555未注册")
            .. " 单件=" .. (Hooks.item and "已注册" or "|cffff5555未注册")
            .. " 拍卖行打开=" .. (Hooks.ahShow and "已注册" or "|cffff5555未注册"))
    end

    -- 「点物品直接在拍卖行搜索」用的接口: 浏览查询 + 拍卖行自己的搜索框
    local t = _G.C_AuctionHouse
    print("  浏览查询: " .. ((t and type(t.SendBrowseQuery) == "function")
        and "有" or "|cffff5555无|r")
        .. "   GetBrowseResults=" .. ((t and type(t.GetBrowseResults) == "function")
        and "有" or "|cffff5555无|r"))
    local sb, how = (AH.SearchBox and AH.SearchBox())
    print("  搜索框: " .. (sb and ("有 (" .. tostring(how) .. ")") or "|cffff5555无|r"))
end

--------------------------------------------------------------------------- 对外: 缓存清单

local function Ago(sec)
    sec = math.max(0, math.floor(sec or 0))
    if sec < 60 then return format("%d 秒前", sec) end
    if sec < 3600 then return format("%d 分钟前", sec / 60) end
    return format("%d 小时前", sec / 3600)
end

local function ItemName(id)
    local ok, n = pcall(function()
        if _G.C_Item and _G.C_Item.GetItemInfo then return _G.C_Item.GetItemInfo(id) end
        if _G.GetItemInfo then return _G.GetItemInfo(id) end
    end)
    if ok and type(n) == "string" and n ~= "" then return n end
    return "物品#" .. tostring(id)
end

-- 把缓存里每条价格 / 缺价原因列出来: 排查"缺 N 项价格"时不用翻日志
function AH.Dump()
    local c = Cache()
    local ids = {}
    for id in pairs(c) do ids[#ids + 1] = id end
    table.sort(ids)

    if #ids == 0 then
        ns.Print("价格缓存是空的, 先点一次「查价」。")
        return
    end

    local now, hit, miss = Now(), 0, 0
    for i = 1, #ids do
        if c[ids[i]].unit then hit = hit + 1 else miss = miss + 1 end
    end

    ns.Print(format("价格缓存 %d 条 (有价 %d · 缺价 %d):", #ids, hit, miss))
    for i = 1, #ids do
        local id = ids[i]
        local e = c[id]
        local price
        if e.unit then
            price = format("|cffe8c25a%s|r · 挂单 %d%s", AH.Money(e.unit), e.n or 0,
                e.other and format(" (另有 %d 条别的物品, 已排除)", e.other) or "")
        else
            price = "|cffff9955" .. (e.reason or "无挂单") .. "|r"
        end
        print(format("  %s  #%d  %s  (%s)",
            ItemName(id), id, price, Ago(now - (e.ts or now))))
    end
    print("  |cff8a929e提示: 缺价大多是拍卖行里确实没人卖; 若写着「查询超时/查询失败」才是接口问题|r")
end

--------------------------------------------------------------------------- 对外: 在拍卖行里搜索某件物品

-- 手动搜索会顶掉「正在读的那条查询」的结果 (拍卖行一次只保存一轮搜索结果),
-- 所以先让路: 主动放弃队列里那几条, 别让它们等满超时再弹一句
-- 「拍卖行没有回包」—— 那是我们自己造成的, 不是拍卖行的问题。
-- 返回放弃了几条。
function AH.Interrupt(reason)
    reason = reason or "已改为手动搜索"
    local dropped = 0

    local function drop(e)
        if not e then return end
        queued[e.id] = nil
        dropped = dropped + 1
        Notify(e.id, { unit = nil, ts = Now(), reason = reason })
    end

    if inflight then
        local e = inflight
        inflight = nil
        drop(e)
    end
    while #scanQueue > 0 do
        drop(table.remove(scanQueue, 1))
    end
    return dropped
end

-- 等查询队列空下来再干活; 等不到就让队列让路 (手动操作优先)。
-- 为什么必须等: 我们查价是「发 itemKey 查询 → 读这一件的搜索结果」, 中途插一条
-- 浏览查询会把结果换成别的物品的, 正在读的那条就永远等不到数据了。
function AH.AwaitIdle(fn, wait)
    if type(fn) ~= "function" then return end
    local step = 0.2
    local tries = math.max(1, math.floor((wait or 3) / step))

    local function tick(n)
        if not AH.Busy() then
            pcall(fn)
            return
        end
        if n <= 0 then
            AH.Interrupt("被手动搜索打断")
            pcall(fn)
            return
        end
        C_Timer.After(step, function() tick(n - 1) end)
    end

    tick(tries)
end

-- 浏览查询用的排序表: 每次新建。sorts 是查询表的一部分, 复用同一个表会和
-- 上一次查询的引用搅在一起 (查价的 Sorts() 是共享的, 这里不能用它)
local function SortList()
    local s = {}
    local e = _G.Enum and _G.Enum.AuctionHouseSortOrder
    if e and e.Price ~= nil then
        s[1] = { sortOrder = e.Price, reverseSort = false }
    end
    return s
end

-- 搜索词: 优先用调用方给的 (界面上已经显示出来的名字), 否则现查客户端。
-- 界面上的名字可能带 |cff... 色码或 "×3" 后缀, 也可能只是 "物品 #123", 这些都不能拿去搜。
local function SearchName(itemID, name)
    if type(name) == "string" then
        local t = name:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
            :gsub("^%s+", ""):gsub("%s+$", "")
        if t ~= "" and not t:match("^物品%s*#") and not t:match("^#") then
            return t
        end
    end
    local n = ItemName(itemID)
    if type(n) == "string" and n ~= "" and not n:match("^物品#") then return n end
    return nil
end

local lastSearch     -- { id, at, way, text } 连点去重 + 诊断

--------------------------------------------------------------------------- 找搜索栏

-- 这一步是整件事的关键, 也是之前踩坑的地方: 控件名猜错等于什么都没做
-- (字没填进真框里、按钮没点到), 界面上就是「搜索框空的 + 列表空的」。
-- Frame 是 userdata, 不能 pairs 遍历, 只能问它要子控件再按类型筛:
-- 拍卖行窗口里能填字的输入框就那么一个, 找得到。

local function Children(o)
    if (type(o) ~= "userdata" and type(o) ~= "table") or type(o.GetChildren) ~= "function" then
        return nil
    end
    local ok, list = pcall(function() return { o:GetChildren() } end)
    if ok and type(list) == "table" and #list > 0 then return list end
    return nil
end

local function ObjType(o)
    if (type(o) ~= "userdata" and type(o) ~= "table") or type(o.GetObjectType) ~= "function" then
        return nil
    end
    local ok, t = pcall(o.GetObjectType, o)
    if ok then return t end
    return nil
end

local function CtlName(o)
    if not o or type(o.GetName) ~= "function" then return nil end
    local ok, n = pcall(o.GetName, o)
    if ok and type(n) == "string" and n ~= "" then return n end
    return nil
end

local function CtlShown(o)
    if not o or type(o.IsShown) ~= "function" then return true end
    local ok, v = pcall(o.IsShown, o)
    if ok then return v and true or false end
    return true
end

local function CtlParent(o)
    if not o or type(o.GetParent) ~= "function" then return nil end
    local ok, p = pcall(o.GetParent, o)
    if ok then return p end
    return nil
end

-- 名字里含 want 的先要; 没给 want 就要第一个看得见的同类控件
local function FindCtl(root, kind, want, depth)
    depth = depth or 3
    if not root or depth < 0 then return nil end
    local list = Children(root)
    if not list then return nil end

    local first
    for i = 1, #list do
        local c = list[i]
        if ObjType(c) == kind then
            if not want then
                if CtlShown(c) then return c end
                first = first or c
            else
                local n = CtlName(c)
                if n and n:lower():find(want, 1, true) then return c end
            end
        end
    end
    if first then return first end
    for i = 1, #list do
        local got = FindCtl(list[i], kind, want, depth - 1)
        if got then return got end
    end
    return nil
end

-- 老式界面把搜索框做成全局 EditBox; SearchBar 找不到时再看这些名字
local SEARCHBOX_NAMES = {
    "AuctionHouseFrameSearchBox", "AuctionHouseFrameSearchBar",
    "AuctionFrameBrowse_SearchBox", "AuctionFrameSearchBox",
}

-- 窗口对象的全局名也可能不一样: 在 UIParent 的直接子级里找名字含 Auction 的那个。
-- 拍卖行窗口有且只有一个, 顶多再撞到"拍卖行小助手"之类的插件面板, 那些不叫这个名。
local function FindAuctionFrame()
    local f = AHFrame()
    if f then return f end
    local kids = Children(_G.UIParent)
    if not kids then return nil end
    for i = 1, #kids do
        local n = CtlName(kids[i])
        if n and n:lower():find("auction", 1, true) and CtlShown(kids[i]) then
            return kids[i]
        end
    end
    return nil
end

local searchUI

-- 找一次就缓存 (rebuild 时重探: 界面配置换了控件会重建)
-- 返回 { box=EditBox, btn=搜索按钮, bar=搜索栏容器, how=从哪找到的 } / nil
function AH.SearchUI(rebuild)
    if searchUI and not rebuild then
        -- 上次没摸到按钮就别一直用那份缓存: 窗口第一次构建时按钮可能还没出来
        if searchUI.btn or not searchUI.bar then return searchUI end
        rebuild = true
    end
    searchUI = nil

    local f = FindAuctionFrame()
    local bars = {}
    local function add(o, tag) if o then bars[#bars + 1] = { o = o, tag = tag } end end
    if f then
        add(f.SearchBar, "SearchBar")
        local bf = f.BrowseFrame
        if bf then add(bf.SearchBar, "BrowseFrame.SearchBar") end
    end
    for i = 1, #SEARCHBOX_NAMES do add(_G[SEARCHBOX_NAMES[i]], SEARCHBOX_NAMES[i]) end

    for i = 1, #bars do
        local b, tag = bars[i].o, bars[i].tag
        local box = (ObjType(b) == "EditBox") and b or nil
        if not box then
            local cand = b.SearchBox
            if cand and type(cand.SetText) == "function" then box = cand end
        end
        if not box then box = FindCtl(b, "EditBox", "search", 3) end
        if not box then box = FindCtl(b, "EditBox", nil, 3) end

        if box and type(box.SetText) == "function" then
            local btn, bar
            if ObjType(b) == "EditBox" then
                -- 全局名给出来就是个 EditBox: 按钮在它父层
                bar = CtlParent(box)
                if bar then btn = FindCtl(bar, "Button", "search", 2) end
            else
                bar = b
                btn = b.SearchButton
                if not btn then btn = FindCtl(b, "Button", "search", 2) end
            end
            searchUI = { box = box, btn = btn, bar = bar, how = tag }
            return searchUI
        end
    end

    -- 兜底: 在整个拍卖行窗口里挖
    if f then
        local box = FindCtl(f, "EditBox", "search", 4)
        if box then
            searchUI = { box = box, btn = FindCtl(f, "Button", "search", 4), bar = nil, how = "窗口内探测" }
            return searchUI
        end
    end
    return nil
end

-- 旧的取法留着 (诊断和别处按「框 + 来源」用)
function AH.SearchBox()
    local ui = AH.SearchUI()
    if not ui then return nil end
    return ui.box, ui.how
end

-- 填搜索框 + 点搜索按钮 —— 玩家自己敲名字回车走的那条路。
-- 填完必须回读确认: 有的框受保护, SetText 静默失败, 不确认就是「什么都没发生」,
-- 而界面上只留一句「未发现物品」, 看着像搜过了其实一次都没发出去。
local function ClickSearch(ui, text)
    local box = ui.box
    if not (box and type(box.SetText) == "function") then return false, "没有搜索框" end
    if not pcall(box.SetText, box, text) then return false, "填不进去" end
    if type(box.GetText) == "function" then
        local ok, v = pcall(box.GetText, box)
        if not (ok and v == text) then return false, "填不进去" end
    end

    -- 搜索框空着时按钮是灰的, 点下去等于没点, 先强行启用
    local btn = ui.btn
    if btn and type(btn.Click) == "function" then
        if type(btn.Enable) == "function" then pcall(btn.Enable, btn) end
        if pcall(btn.Click, btn) then return true, "按钮" end
    end

    local bar = ui.bar
    if bar then
        if type(bar.OnSearchButtonClicked) == "function"
            and pcall(bar.OnSearchButtonClicked, bar) then
            return true, "按钮回调"
        end
        if type(bar.OnEnterPressed) == "function" and pcall(bar.OnEnterPressed, bar) then
            return true, "回车"
        end
    end
    return false, "按钮点不动"
end

-- 点物品 → 在拍卖行里「搜索这件东西」。
--   1. 首选: 填搜索框 + 点搜索按钮 (玩家的路, 查询表由 UI 自己拼, 不会不匹配)
--   2. 再退: 直接发 browse query (老式客户端, 或者按钮点了没动静)
--   3. 最后: 按 itemKey 精确查 —— 查价走的就是这条, 一定通; 只是结果不经过搜索框
-- 不用 exactMatch: 宁可多列几个名字相近的, 也别因为一个字不同就给个空列表
-- 返回 true, 搜索词, 走的路 / false, 原因
function AH.Search(itemID, name)
    if not itemID then return false, "没有物品 ID" end
    local api = _G.C_AuctionHouse
    if type(api) ~= "table"
        or (type(api.SendBrowseQuery) ~= "function" and type(api.SendSearchQuery) ~= "function") then
        return false, "客户端缺少拍卖行查询 API"
    end
    if not AHOpen() then return false, "拍卖行未打开" end

    local text = SearchName(itemID, name)
    if not text then return false, "物品名还没读到" end

    -- 连点两下别发两条 (拍卖行有频率上限, 而且第二条会顶掉第一条的结果)
    local t = (type(GetTime) == "function" and GetTime()) or 0
    if lastSearch and lastSearch.id == itemID and (t - lastSearch.at) < 1 then
        return true, text, "连点去重"
    end

    local ok, way, err = false, nil, nil

    local ui = AH.SearchUI()
    if ui then
        local fired, how = ClickSearch(ui, text)
        if fired then
            ok, way = true, ui.how .. "(" .. tostring(how) .. ")"
        else
            err = "搜索栏按钮点不动 (" .. ui.how .. ")"
        end
    end

    if not ok and type(api.SendBrowseQuery) == "function" then
        local q = {
            searchString     = text,
            minLevel         = 0,
            maxLevel         = 0,
            itemClassFilters = {},
            usableOnly       = false,
            exactMatch       = false,
            sorts            = SortList(),
        }
        ok, err = pcall(api.SendBrowseQuery, q)
        if ok then
            way = "browse 查询"
        else
            -- sorts 结构万一对不上, 退一步不要排序 (服务器给默认)
            q.sorts = {}
            ok, err = pcall(api.SendBrowseQuery, q)
            if ok then way = "browse 查询(不排序)" end
        end
    end

    if not ok and type(api.SendSearchQuery) == "function" then
        ok, err = pcall(api.SendSearchQuery, ItemKey(itemID), SortList(), false)
        if ok then way = "itemKey 查询" end
    end

    if not ok then
        local msg = tostring(err)
        local low = msg:lower()
        if low:find("restrict", 1, true) or low:find("protect", 1, true)
            or low:find("taint", 1, true) then
            msg = "客户端禁止插件搜索拍卖行"
        end
        return false, "搜索失败: " .. msg
    end

    lastSearch = { id = itemID, at = t, way = way, text = text }
    return true, text, way
end

-- 搜索发出后回读条数: 界面到底有没有东西, 用数字说话。
-- 「未发现物品」既可能是真没人卖, 也可能是查询压根没被认 —— 这两种得分开。
-- 返回 单件条数, 商品条数, 浏览结果条数 (拿不到的给 nil)
function AH.SearchCount(itemID)
    local c = AHAPI()
    if not (c and itemID) then return nil end

    local item = tonumber(CallID(c.GetNumItemSearchResults, ItemKey(itemID)))
    local comm = tonumber(CallID(c.GetNumCommoditySearchResults, itemID))

    local browse
    if type(c.GetBrowseResults) == "function" then
        local ok, res = pcall(c.GetBrowseResults)
        if ok then
            if type(res) == "table" then
                browse = #res
            elseif type(res) == "number" then
                browse = res
            end
        end
        if browse == nil then
            -- 有些版本是一次一条: GetBrowseResults(i)
            browse = 0
            for i = 1, 200 do
                local ok2, row = pcall(c.GetBrowseResults, i)
                if not (ok2 and row) then break end
                browse = browse + 1
            end
        end
    end

    return item, comm, browse
end

-- 把某件物品的原始挂单逐条打出来: 结果项里到底有哪些字段, 一眼看清。
-- 怀疑「查价不对」时先看这个 —— 混进来的别的物品、读不到的字段都藏在这里。
function AH.DumpItem(itemID)
    itemID = tonumber(itemID)
    if not itemID then return end
    local c = AHAPI()
    if not c then ns.Print("|cffff5555客户端缺少拍卖行 API|r") return end
    if not AHOpen() then ns.Print("|cffff5555拍卖行没打开|r") return end

    local key = ItemKey(itemID)
    pcall(c.SendSearchQuery, key, SortList(), false)   -- 现查, 不吃缓存

    C_Timer.After(1.5, function()
        local nI = tonumber(CallID(c.GetNumItemSearchResults, key)) or 0
        local nC = tonumber(CallID(c.GetNumCommoditySearchResults, itemID)) or 0
        ns.Print(format("物品 #%d %s · 单件 %d 条 / 商品 %d 条",
            itemID, tostring(ItemName(itemID) or "?"), nI, nC))

        local hasID, mixed = false, 0
        local function dump(tag, getter, n)
            local shown = 0
            for i = 1, n do
                if shown >= 6 then break end
                local r = getter(i)
                if type(r) == "table" then
                    shown = shown + 1
                    local rid = ResultID(r)
                    if rid then
                        hasID = true
                        if rid ~= itemID then mixed = mixed + 1 end
                    end
                    local keys = {}
                    for k in pairs(r) do keys[#keys + 1] = tostring(k) end
                    table.sort(keys)
                    print(format("  %s#%d id=%s qty=%s 价=%s |cff8a929e%s|r",
                        tag, i, tostring(rid),
                        tostring(r.quantity or r.totalQuantity),
                        tostring(r.buyoutAmount or r.minPrice or r.unitPrice or r.bidAmount),
                        table.concat(keys, ",")))
                end
            end
        end

        dump("单件", function(i) return CallID(c.GetItemSearchResultInfo, key, i) end, nI)
        dump("商品", function(i) return CallID(c.GetCommoditySearchResultInfo, itemID, i) end, nC)

        local best, cnt, other = ReadAny(itemID, key)
        print(format("  → 单价 %s · %d 条可用 · 排除 %d 条名字相近的别的物品",
            best and AH.Money(best) or "无", cnt or 0, other or 0))

        if not hasID then
            print("  |cffff5555结果项里没有物品 ID 字段|r: 没法核对, 只能按接口的 key 认")
        elseif mixed > 0 then
            print("  |cffff5555前几条里就有别的物品|r: 就是这个原因, 已按 ID 排除 (见上面的 id=)")
        else
            print("  |cff5ad46a结果项都带物品 ID, 前几条也都是这一件|r")
        end
    end)
end

-- 搜索这条路的体检: 哪一环通、哪一环不通, 一条条列出来。
-- 界面上只回一句「未发现物品」的时候, 靠这个分清「没搜出去」和「真没人卖」。
function AH.SearchDiag(itemID)
    itemID = tonumber(itemID)
    ns.Print("拍卖行搜索诊断 · 物品 #" .. tostring(itemID))

    local c = _G.C_AuctionHouse
    local function has(n)
        return (type(c) == "table" and type(c[n]) == "function")
            and "|cff5ad46a有|r" or "|cffff5555无|r"
    end

    print("  API: SendBrowseQuery=" .. has("SendBrowseQuery")
        .. " SendSearchQuery=" .. has("SendSearchQuery")
        .. " GetBrowseResults=" .. has("GetBrowseResults"))
    local f = FindAuctionFrame()
    print("  窗口: " .. (f and (CtlShown(f) and "已打开" or "|cffff5555未打开|r")
        or "|cffff5555找不到窗口对象|r")
        .. "   控件=" .. tostring(CtlName(f) or "|cffff5555无名字|r")
        .. "   物品名=" .. tostring(ItemName(itemID) or "?"))

    -- 重探一次: 诊断要的是此刻的真实结构, 不吃缓存
    local ui = AH.SearchUI(true)
    if ui then
        print("  搜索控件: 来源=" .. tostring(ui.how)
            .. "   框=" .. tostring(CtlName(ui.box) or "(无名字)")
            .. "   按钮=" .. (ui.btn and tostring(CtlName(ui.btn) or "(无名字)") or "|cffff5555无|r"))
        -- 顺手验一下字到底填不填得进去 (填完再读回来对比)
        if type(ui.box.GetText) == "function" then
            local okG, before = pcall(ui.box.GetText, ui.box)
            local okS = pcall(ui.box.SetText, ui.box, "测试")
            local okG2, after = pcall(ui.box.GetText, ui.box)
            pcall(ui.box.SetText, ui.box, okG and before or "")
            print("  填字测试: 设成「测试」读回「" .. tostring(after)
                .. "」" .. ((okS and okG2 and after == "测试") and " |cff5ad46a可以|r" or " |cffff5555不行|r"))
        end
    else
        print("  搜索控件: |cffff5555一个都没找到|r (只能直接发查询, 窗口里不会有回填的名字)")
    end

    if lastSearch and lastSearch.id == itemID then
        print("  上次搜索: 「" .. tostring(lastSearch.text) .. "」走的是 "
            .. tostring(lastSearch.way))
    end

    local item, comm, browse = AH.SearchCount(itemID)
    print(format("  结果: 单件=%s 商品=%s 浏览=%s",
        tostring(item), tostring(comm), tostring(browse)))
    if type(c) == "table" and type(c.HasSearchResults) == "function" then
        local ok, v = pcall(c.HasSearchResults)
        print("  HasSearchResults: " .. (ok and tostring(v) or "调用失败"))
    end
    print("  |cff8a929e三个都是 0 而拍卖行里明明有这件东西 → 把这几行整段发我|r")
end
