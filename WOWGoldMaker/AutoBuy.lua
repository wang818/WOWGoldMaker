---------------------------------------------------------------------------
-- WOWGoldMaker / AutoBuy.lua
-- 自动购买: 给一样材料设「单价上限」, 拍卖行开着时按设定的间隔扫一轮 (默认 60 秒,
-- 可改成 1 秒 ~ 任意长), 只要最低单价不高于上限就买 —— 不设目标数量, 有货就吃。
--
-- **这是真花钱的功能**, 所以留了这几道闸:
--   1) 总开关 db.autoBuyOn —— 默认关闭, 必须手动开, 关窗口/重登都保持关闭状态
--   2) 每件的单价上限 —— 高于它这一轮就跳过, 这是唯一的价格闸门
-- 没有「单轮总花费上限」了: 设了单价就要买到, 不想花钱就关总开关或把物品移出列表。
--
-- 每次真下单前还会再核一次: 拍卖行窗口必须开着、金币必须够、单价必须不高于上限、
-- 背包得有地方放。
--
-- 查价复用 Auction.lua 的查询队列 (把「单个物品」当成一个没有材料的配方喂给
-- AH.CheckRecipe), 这样自动购买和界面查价共用同一条队列和同一套节流 ——
-- 自己另发 SendSearchQuery 会跟查价抢 inflight, 事件回来时对不上号。
---------------------------------------------------------------------------

local ADDON, ns = ...

local M = {}
ns.AutoBuy = M

local format = string.format

-- 每件每轮最多下单这么多个。没有目标数量、也没有单轮上限之后, 这个数是唯一的
-- 数量闸门: 碰上 1 铜的货, 不封顶就会算出上万个 (客户端吃不下, 背包也装不下)。
-- 200 约十组, 想要更多就多等几轮 (间隔能调到 1 秒, 补货很快)。
local MAX_ORDER     = 200
local BUY_TIMEOUT   = 10     -- 单笔购买最多等多久 (秒)
local CONFIRM_DELAY = 0.8    -- Start 之后隔多久补 Confirm
local MAXLOG        = 40     -- 购买日志保留条数

--------------------------------------------------------------------------- 状态 (声明一律放前面)
--
-- Lua 5.1 是词法作用域: 在 local 声明**之前**引用同名变量, 拿到的是全局的 nil。
-- 下面的函数互相调用, 所以状态和函数句柄都必须先声明, 再在后面赋值 ——
-- 否则运行时报的不是"未定义", 而是 index nil 这种更难查的错。

local scanning   = false
local roundToken = 0
local pending                -- 正在买: { id, qty, unit, name, token }
local manualDone             -- 手动买入 (材料行「买入」) 的界面回调: (ok, err)
local tokenSeq   = 0
local ticker
local lastScan   = 0
local lastNotice = -100
local bought     = {}        -- 本次会话已下单但客户端还没算进背包的数量: itemID -> n
local buyLog     = {}

-- 本轮买到一半时被 pending 打断, 记下「接着从哪继续」
local resumeList, resumeIdx

local NowT, RoundStep, RoundDone, StartPurchase, FinishPurchase

NowT = function()
    return (type(GetTime) == "function" and GetTime()) or 0
end

--------------------------------------------------------------------------- 存档

local function DB()
    return ns.DB() or {}
end

-- 自动购买表。缺字段时补成空表, 免得存档是从旧版本升上来的直接 nil 报错
local function Cfg()
    local d = DB()
    if type(d.autoBuy) ~= "table" then d.autoBuy = {} end
    return d.autoBuy
end

function M.Enabled()
    return DB().autoBuyOn == true
end

function M.SetEnabled(on)
    DB().autoBuyOn = on and true or false
    if on then M.Start() else M.Stop() end
    return DB().autoBuyOn
end

-- 扫描间隔 (秒)。最小 1 秒, 上限不设 —— 有人想 5 秒盯一次, 也有人想 10 分钟看一次,
-- 都按填的来。防呆分两种: 不是数字 (清空/乱填) 退回默认 60; 是数字但小于 1
-- (0 / 负数) 抬到 1 —— 玩家写 0 的意思是「尽快」, 不是「关掉」。
local GAP_MIN, GAP_DEFAULT = 1, 60

function M.Gap()
    local v = tonumber(DB().autoBuyGap)
    if not v or v ~= v then return GAP_DEFAULT end
    v = math.floor(v)
    if v < GAP_MIN then v = GAP_MIN end
    return v
end

-- 改间隔。计时器是按旧间隔在跑的, 不重建就要等下一次才生效 ——
-- 玩家改完盯着屏幕看不到变化, 会以为没保存。
function M.SetGap(sec)
    local v = tonumber(sec)
    if not v or v ~= v then
        v = GAP_DEFAULT                      -- 清空 / 非数字: 回默认
    else
        v = math.floor(v)
        if v < GAP_MIN then v = GAP_MIN end  -- 0 / 负数: 1 秒 (最快)
    end

    DB().autoBuyGap = v

    if ticker then
        pcall(function() ticker:Cancel() end)
        ticker = nil
        if M.Enabled() then
            -- 直接重建, 不走 Start(): Start 里那个「启动时先扫一轮」的 2 秒预热
            -- 在这里只会多打一轮查询
            ticker = C_Timer.NewTicker(v, function() M.Scan() end)
        end
    end
    return v
end

--------------------------------------------------------------------------- 列表

-- 单条: { p = 单价上限(铜) }
function M.Get(id)
    id = tonumber(id)
    if not id then return nil end
    return Cfg()[id]
end

function M.Has(id)
    return M.Get(id) ~= nil
end

function M.PriceOf(id)
    local e = M.Get(id)
    return e and e.p or nil
end

-- 加进自动购买列表 (已在列表里就是改价)。旧存档里的 q 字段直接忽略,
-- 下次 Set 时会被覆盖掉, 不用专门写迁移。
function M.Set(id, price)
    id, price = tonumber(id), tonumber(price)
    if not id or not price or price <= 0 then return nil end
    Cfg()[id] = { p = math.floor(price) }
    return Cfg()[id]
end

function M.Remove(id)
    id = tonumber(id)
    if not id then return false end
    Cfg()[id] = nil
    return true
end

function M.Count()
    local n = 0
    for _ in pairs(Cfg()) do n = n + 1 end
    return n
end

-- 按物品 ID 升序排, 保证每一轮扫描顺序稳定 (调试时好对日志)
function M.List()
    local out = {}
    for id, e in pairs(Cfg()) do
        out[#out + 1] = { id = id, p = e.p or 0 }
    end
    table.sort(out, function(a, b) return a.id < b.id end)
    return out
end

--------------------------------------------------------------------------- 背包 / 金额

-- 背包里有多少个。刚下单的那几个客户端要过一会儿才算进背包, 这段空窗期里
-- GetItemCount 还是旧数, 所以下单时记一个估算值 (下单后**应该**有多少个), 两者取大的。
-- 现在没有「目标数量」了, 这个数只用在一处: 「自动」浮窗里那句「背包已有 N 个」,
-- 让玩家刚买完就能看见数量涨了, 不用对着背包数。
--
-- 估算值带时间戳: 客户端一旦把货算进背包 (n >= 估算值) 就作废, 交给真实数量;
-- 超过 EST_TTL 也强制作废 —— 否则玩家把这批货用掉/卖掉之后, 估算值还高高挂着,
-- 浮窗里就一直显示一个虚高的「背包已有」。
local EST_TTL = 30
local bought = {}            -- itemID -> { n = 估算数量, at = 时间 }

local function Have(id)
    local n = 0
    if type(GetItemCount) == "function" then
        local ok, v = pcall(GetItemCount, id)
        if ok and type(v) == "number" then n = v end
    end

    local b = bought[id]
    if b then
        if n >= b.n or (NowT() - b.at) > EST_TTL then
            bought[id] = nil
        elseif b.n > n then
            n = b.n
        end
    end
    return n
end

local function Money()
    if type(GetMoney) == "function" then
        local ok, v = pcall(GetMoney)
        if ok and type(v) == "number" then return v end
    end
    return 0
end

-- 这件东西在客户端物品库里的堆叠数。拿不到就按 20 (最保守的堆叠) 估。
-- 只用来算「背包还能塞多少个」, 估小了最多多买几轮, 估大了会撞上背包满。
local function StackSize(id)
    if type(GetItemInfo) ~= "function" then return 20 end
    local r = { pcall(GetItemInfo, id) }
    local stack = r[9]                       -- name, link, quality, ilvl, req, class, sub, maxStack, ...
    if type(stack) == "number" and stack > 0 then return stack end
    return 20
end

-- 背包空格数。旧客户端没这个接口就返回 nil —— 表示「这一层不限制」, 不要当成 0。
local function FreeSlots()
    if type(GetNumFreeBagSlots) ~= "function" then return nil end
    local ok, n = pcall(GetNumFreeBagSlots)
    if ok and type(n) == "number" then return n end
    return nil
end

-- 这一笔下多少个 = 单笔上限 / 背包放得下 / 钱买得起, 三者取小。
-- 没有「单轮总上限」了, 所以不看「这一轮还剩多少额度」, 每件都是各自独立买满。
-- 第二个返回值说明为什么是 0 (bag = 背包满, money = 钱不够), 上层据此提示。
local function BuyQty(id, unit)
    local room = MAX_ORDER

    local free = FreeSlots()
    if free then
        room = free * StackSize(id)
        if room > MAX_ORDER then room = MAX_ORDER end
        if room < 1 then return 0, "bag" end
    end

    local afford = 0
    if unit and unit > 0 then afford = math.floor(Money() / unit) end
    if afford < 1 then return 0, "money" end
    if afford < room then room = afford end
    return room
end

M.Have = Have
M.BuyQty = BuyQty

-- 单笔上限, 给界面用 (提示里写「每件每轮 N 个」), 别在 UI 里再硬编码一个数
function M.Order()
    return MAX_ORDER
end

--------------------------------------------------------------------------- 通知 / 日志

local function Notice(msg)
    local t = NowT()
    -- 同一轮里可能连着买好几样, 每样都弹一条会很吵, 1.2 秒内只留第一条
    if t - lastNotice < 1.2 then return end
    lastNotice = t
    if ns.Print then ns.Print(msg) end
end

-- 背包满了: 不买是「没办法买」, 不提示玩家会以为是坏了。但每秒一轮的话
-- 每轮都报一条就是刷屏, 30 秒最多一次。单独一条时间线, 不占 Notice 的节流额度。
local lastBagNotice = -100
local function BagNotice()
    local t = NowT()
    if t - lastBagNotice < 30 then return end
    lastBagNotice = t
    if ns.Print then
        ns.Print("|cffff9955背包没有空格|r 自动购买先停下 —— 清出格子后会自动继续")
    end
end

function M.Log()
    return buyLog
end

local function LogBuy(id, qty, unit)
    buyLog[#buyLog + 1] = {
        id = id, qty = qty, unit = unit,
        at = (type(time) == "function") and time() or 0,
    }
    while #buyLog > MAXLOG do table.remove(buyLog, 1) end
end

local function MoneyText(v)
    local AH = ns.Auction
    if AH and AH.MoneyEx then return AH.MoneyEx(v) end
    return tostring(v)
end

-- 聊天里报「买了什么」时用的名字。物品名是异步回包的, 拿不到就退回 #ID ——
-- 这里只求玩家认得出是哪件, 不为了一个名字去发查询
local function NameText(id)
    if type(GetItemInfo) == "function" then
        local ok, n = pcall(GetItemInfo, id)
        if ok and type(n) == "string" and n ~= "" then return n end
    end
    return "#" .. tostring(id)
end

--------------------------------------------------------------------------- 购买

-- 收尾: 成功 / 失败 / 超时都走这里, 保证 pending 一定被清掉, 否则后面全卡住
FinishPurchase = function(ok, reason)
    local p = pending
    pending = nil
    if not p then return end

    if ok then
        -- 记成「下单后背包里应该有多少个」的绝对量, 不是增量:
        -- 增量会和客户端后来自己入包的数量重复计算
        bought[p.id] = { n = Have(p.id) + p.qty, at = NowT() }
        LogBuy(p.id, p.qty, p.unit)
        Notice(format("|cff4dc87a自动买入|r %s ×%d (单价 %s · 共 %s)",
            p.name or ("#" .. p.id), p.qty, MoneyText(p.unit), MoneyText(p.unit * p.qty)))
    else
        Notice(format("|cffff9955自动购买没成交|r %s ×%d%s",
            p.name or ("#" .. p.id), p.qty, reason and (" —— " .. reason) or ""))
    end

    -- 买成了就把本轮接着跑完 (列表里有好几样时, 不然一轮只能买一样);
    -- 没买成 / 超时就算了, 等下一轮, 免得在同一个物品上连着撞
    local rl, ri = resumeList, resumeIdx
    resumeList, resumeIdx = nil, nil

    -- 手动买入的界面回调: 成交/失败都通知一次, 弹窗据此关闭或显示原因
    local mc = manualDone
    manualDone = nil
    if mc then pcall(mc, ok == true, not ok and reason or nil) end

    if ok and rl then
        scanning = true
        roundToken = roundToken + 1
        local tok = roundToken
        -- 缓一下再查下一件: 让客户端先把手里的购买结果处理干净, 免得两条查询撞在一起
        C_Timer.After(0.6, function()
            if tok ~= roundToken then return end
            RoundStep(rl, ri)
        end)
    else
        if RoundDone then RoundDone() end
    end
end

M.FinishPurchase = FinishPurchase

StartPurchase = function(id, qty, unit, name)
    if pending then return false, "上一笔还在处理" end
    if qty < 1 then return false, "数量为 0" end

    local cost = unit * qty
    if Money() < cost then return false, "金币不足" end

    local api = _G.C_AuctionHouse
    if not (api and type(api.StartCommoditiesPurchase) == "function") then
        return false, "客户端没有购买接口"
    end

    -- 下单前再确认一次窗口还开着: 扫描期间玩家可能已经把拍卖行关了
    if ns.Auction and ns.Auction.CanQuery then
        local ok, why = ns.Auction.CanQuery()
        if not ok then return false, why end
    end

    tokenSeq = tokenSeq + 1
    local token = tokenSeq
    pending = { id = id, qty = qty, unit = unit, name = name, token = token, at = NowT() }

    local ok, err = pcall(api.StartCommoditiesPurchase, id, qty)
    if not ok then
        pending = nil
        local msg = tostring(err)
        local low = msg:lower()
        if low:find("restrict", 1, true) or low:find("protect", 1, true) then
            msg = "客户端禁止插件自动购买"
        end
        return false, msg
    end

    -- 这个版本的 API 是 Start(itemID, quantity) → Confirm(itemID, quantity) 两步。
    -- Confirm 万一被标成受保护, Start 一般已经锁到货了, 事件照样会来,
    -- 所以这里 pcall 掉, 失败不影响结果判定。
    C_Timer.After(CONFIRM_DELAY, function()
        if not pending or pending.token ~= token then return end
        local c = _G.C_AuctionHouse
        if c and type(c.ConfirmCommoditiesPurchase) == "function" then
            pcall(c.ConfirmCommoditiesPurchase, id, qty)
        end
    end)

    -- 兜底: 事件被吞掉 (静默失败) 也要把 pending 放掉
    C_Timer.After(BUY_TIMEOUT, function()
        if not pending or pending.token ~= token then return end
        pending = nil
        Notice("|cffff9955自动购买没有回音|r " .. (name or ("#" .. id)))
        -- 手动买入也要收尾, 否则弹窗会一直停在「处理中」
        local mc = manualDone
        manualDone = nil
        if mc then pcall(mc, false, "客户端没有回音") end
        if RoundDone then RoundDone() end
    end)

    return true
end

M.Buy = StartPurchase

--------------------------------------------------------------------------- 手动买入

-- 只查一次价, 不买: 材料行「买入」弹窗打开时用它显示当前最低价。
-- force 默认 true —— 玩家要买的那一下必须看实时行情, 不能拿半小时前的缓存充数。
function M.Quote(id, cb, force)
    id = tonumber(id)
    local AH = ns.Auction
    if not (id and AH and AH.CheckRecipe) then
        if cb then pcall(cb, nil, "拍卖行模块未加载") end
        return false
    end

    AH.CheckRecipe({ item = id, mats = {}, made = 1 }, function(out)
        local pe = out and out.unit and out.unit[id]
        local unit = pe and pe.unit
        if cb then
            if unit and unit > 0 then
                pcall(cb, unit, nil)
            else
                local w = out and out.why and out.why[1]
                pcall(cb, nil, (w and w.reason) or "拍卖行没有挂单")
            end
        end
    end, nil, force ~= false)
    return true
end

-- 手动买一次 (材料行「买入」): 查最低价 → 价格闸 → 数量/背包/金币核算 → 下单。
-- 价格闸和自动购买一致: 列表里设了单价上限就按上限卡, 没设就按市价买。
-- isAlive 可选: 查价回包时再问一次「弹窗还开着吗」, 玩家中途关掉就不要下单了。
-- 返回 false 表示连查询都没发出去; 真正的成交结果走 onDone(ok, err)。
function M.BuyNow(id, qty, name, onDone, isAlive)
    id, qty = tonumber(id), tonumber(qty)
    if not id or not qty or qty < 1 then
        return false, "数量要大于 0"
    end
    if pending then
        return false, "上一笔还在处理"
    end

    local AH = ns.Auction
    if not (AH and AH.CheckRecipe and AH.CanQuery) then
        return false, "拍卖行模块未加载"
    end
    local canQuery, why = AH.CanQuery()
    if not canQuery then return false, why end

    qty = math.floor(qty)
    if qty > MAX_ORDER then qty = MAX_ORDER end      -- 单笔上限, 和自动购买同一个数

    -- 不用 force: 弹窗打开时刚查过一次, 缓存就是最新的; 没查到的话这里会入队等回包
    AH.CheckRecipe({ item = id, mats = {}, made = 1 }, function(out)
        -- 查价期间弹窗被关掉/换成了别的物品: 取消, 别在玩家看不见的地方花钱
        if isAlive and not isAlive() then
            if onDone then pcall(onDone, false, "已取消") end
            return
        end

        local pe = out and out.unit and out.unit[id]
        local unit = pe and pe.unit
        if not unit or unit <= 0 then
            if onDone then pcall(onDone, false, "拍卖行没有挂单") end
            return
        end

        local limit = M.PriceOf(id)
        if limit and unit > limit then
            if onDone then
                pcall(onDone, false, format("最低价 %s 高于你设的上限 %s",
                    MoneyText(unit), MoneyText(limit)))
            end
            return
        end

        local room, why2 = BuyQty(id, unit)
        if room < 1 then
            if onDone then
                pcall(onDone, false, why2 == "bag" and "背包没有空格" or "金币不足")
            end
            return
        end
        if qty > room then qty = room end

        -- 回调先挂上再下单: 失败路径要立刻清掉, 成功路径交给 FinishPurchase
        manualDone = onDone
        local ok, err = StartPurchase(id, qty, unit, name or NameText(id))
        if not ok then
            manualDone = nil
            if onDone then pcall(onDone, false, err) end
        end
    end, nil, false)
    return true
end

function M.Pending()
    return pending
end

--------------------------------------------------------------------------- 一轮扫描

-- 一轮扫完 (或中途放弃) 都走这里
RoundDone = function()
    scanning = false
    roundToken = roundToken + 1
end

M.RoundDone = RoundDone

-- 逐条处理。用递归而不是 for 循环, 因为每条的查价都是异步的 ——
-- 必须等上一件的结果回来再决定下一件, 否则一轮里会并发几十条查询, 把节流额度一次吃光。
RoundStep = function(list, i)
    local tok = roundToken

    local function again()
        if tok ~= roundToken then return end        -- 期间被 Stop / 重来过
        RoundStep(list, i + 1)
    end

    if i > #list then RoundDone(); return end
    if pending then RoundDone(); return end         -- 上一笔还没结束, 下一轮再说

    local e = list[i]
    if not e.p or e.p <= 0 then again(); return end

    local AH = ns.Auction
    if not (AH and AH.CheckRecipe) then RoundDone(); return end

    -- 把「单个物品」当成一个没有材料的配方: out.unit[id].unit 就是最低单价
    AH.CheckRecipe({ item = e.id, mats = {}, made = 1 }, function(out)
        if tok ~= roundToken then return end
        local pe = out and out.unit and out.unit[e.id]
        local unit = pe and pe.unit

        if not unit or unit <= 0 then again(); return end
        if unit > e.p then again(); return end                  -- 高于上限: 不买

        -- 没有单轮总额度了: 每件各自按「单笔上限 / 背包放得下 / 钱够」算一笔。
        -- 买完这一笔, 下一轮再买 —— 间隔可以调到 1 秒, 补货不用等一分钟。
        local qty, why = BuyQty(e.id, unit)
        if qty < 1 then
            if why == "bag" then BagNotice() end
            again(); return
        end

        local name = NameText(e.id)
        local ok = StartPurchase(e.id, qty, unit, name)
        if not ok then again(); return end

        -- 下单成功: 交给 FinishPurchase 收尾, 它在购买事件回来后会从这里接着往下跑。
        -- 这里不能直接 again() —— pending 期间本轮必须停下, 否则会并发下一单。
        resumeList, resumeIdx = list, i + 1
    end, nil, true)
end

function M.Scan()
    if scanning then return false, "上一轮还没跑完" end
    if not M.Enabled() then return false, "自动购买没开" end

    local list = M.List()
    if #list == 0 then return false, "列表是空的" end

    local AH = ns.Auction
    if not (AH and AH.CanQuery) then return false, "拍卖行模块未加载" end
    local ok, why = AH.CanQuery()
    if not ok then return false, why end

    scanning = true
    roundToken = roundToken + 1
    lastScan = NowT()
    RoundStep(list, 1)
    return true
end

function M.Scanning()
    return scanning
end

function M.LastScan()
    return lastScan
end

--------------------------------------------------------------------------- 定时器

function M.Start()
    if ticker then return end
    if not M.Enabled() then return end
    if not (C_Timer and C_Timer.NewTicker) then return end

    ticker = C_Timer.NewTicker(M.Gap(), function() M.Scan() end)
    -- 启动时先扫一轮, 不用干等一分钟
    C_Timer.After(2, function() M.Scan() end)
end

function M.Stop()
    if ticker then
        pcall(function() ticker:Cancel() end)
        ticker = nil
    end
    scanning = false
    roundToken = roundToken + 1
end

function M.Running()
    return ticker ~= nil
end

--------------------------------------------------------------------------- 事件: 购买结果 + 拍卖行开关

local ev = CreateFrame("Frame")
M.Hooks = {}

local function Hook(name)
    M.Hooks[name] = pcall(function() ev:RegisterEvent(name) end) and true or false
end

Hook("COMMODITY_PURCHASE_SUCCEEDED")
Hook("COMMODITY_PURCHASE_FAILED")
Hook("COMMODITY_PURCHASED")
Hook("AUCTION_HOUSE_SHOW")
Hook("AUCTION_HOUSE_CLOSED")

ev:SetScript("OnEvent", function(_, event)
    if event == "COMMODITY_PURCHASE_SUCCEEDED" or event == "COMMODITY_PURCHASED" then
        FinishPurchase(true)
    elseif event == "COMMODITY_PURCHASE_FAILED" then
        FinishPurchase(false, "拍卖行拒绝了这一单")
    elseif event == "AUCTION_HOUSE_SHOW" then
        -- 只有开着拍卖行才启动: 关着的时候每分钟空转没意义, 查价也必然失败
        if M.Enabled() then M.Start() end
    elseif event == "AUCTION_HOUSE_CLOSED" then
        M.Stop()
    end
end)

--------------------------------------------------------------------------- 摘要

function M.Summary()
    return format("%s · %d 件 · 每 %d 秒 · 有货就买",
        M.Enabled() and "|cff4dc87a开着|r" or "|cffeb6b6b关着|r",
        M.Count(), M.Gap())
end
