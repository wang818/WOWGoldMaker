---------------------------------------------------------------------------
-- WOWGoldMaker / AutoBuy.lua
-- 自动购买: 给一样材料设「单价上限」和「扫描频率」, 打开自动购买列表页后按频率扫,
-- 关掉页面立即停。默认频率 1 秒 —— 页面开着时每秒 tick 一次, 只把到了自己频率的
-- 条目拎出来查价, 所以每个商品可以设不同的间隔。
--
-- **这是真花钱的功能**, 所以留了这几道闸:
--   1) 只有自动购买列表页开着才扫 (页面关闭/切走 = 停)
--   2) 每件的单价上限 —— 高于它这一轮就跳过, 这是唯一的价格闸门
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
local pageActive = false     -- 自动购买页是否开着 (开着才扫)
local buying     = false     -- 买入弹窗开着: 暂停扫描, 免得查询结果把购买上下文冲掉
local lastScan   = 0
local lastNotice = -100
local bought     = {}        -- 本次会话已下单但客户端还没算进背包的数量: itemID -> n
local buyLog     = {}
local scans      = {}        -- 本次会话每个条目的扫描次数: itemID -> n (不写存档)
local lastAt     = {}        -- 上一次扫描的时间: itemID -> GetTime()
local lastInfo   = {}        -- 最近一次扫描结论: itemID -> { unit = 价格, tag = 结果 }

-- 购买链路诊断: 客户端不保证有 COMMODITY_PURCHASE_* 事件, 没有时只能靠背包变化判断。
-- 这些数据由 /wgm 自动 诊断 打印出来。
local diag = {
    events = {},             -- 事件名 -> 收到次数
    lastEvent = nil,
    lastStart = nil,
    lastConfirm = nil,
    lastTimeout = nil,
    lastFail = nil,          -- { at, id, reason } 最近一次没买成的原因
}

-- 本轮买到一半时被 pending 打断, 记下「接着从哪继续」
local resumeList, resumeIdx

local NowT, RoundStep, RoundDone, StartPurchase, FinishPurchase

NowT = function()
    return (type(GetTime) == "function" and GetTime()) or 0
end

-- 记下最近一次没买成的原因 (诊断用)
local function NoteFail(id, reason)
    diag.lastFail = { at = NowT(), id = tonumber(id) or 0, reason = tostring(reason) }
end

--------------------------------------------------------------------------- 存档

local function DB()
    return ns.DB() or {}
end

-- 自动购买表。缺字段时补成空表, 免得存档是从旧版本升上来的直接 nil 报错。
-- 存档里的键有时会被序列化成字符串 ("12345"): 统一迁回数字键。
-- 不迁的话 M.List 排序会拿字符串和数字比较、整张表直接报错, 界面就只剩/丢掉条目。
local function Cfg()
    local d = DB()
    if type(d.autoBuy) ~= "table" then d.autoBuy = {} end

    local t = d.autoBuy
    local needFix = false
    for k in pairs(t) do
        if type(k) ~= "number" then needFix = true; break end
    end
    if needFix then
        local fixed = {}
        for k, v in pairs(t) do
            local n = tonumber(k)
            if n then fixed[n] = v end
        end
        d.autoBuy = fixed
        return fixed
    end
    return t
end

-- 购买总数存存档 (跨重载累计): itemID -> 已买数量。
-- 每一条有自己的上限 (默认 100), 买够就跳过。
-- 注意: 必须定义在 DB()/Cfg() 之后 —— Lua 5.1 是词法作用域, 提前引用 DB 会拿到全局 nil。
local function Bought()
    local d = DB()
    if type(d.autoBuyBought) ~= "table" then d.autoBuyBought = {} end
    return d.autoBuyBought
end

-- 扫描频率 (秒): 每个条目单独设, 默认 1 秒 (每秒都扫), 上限 1 小时。
local GAP_MIN, GAP_MAX, GAP_DEFAULT = 1, 3600, 1

-- 购买总数上限: 每条单独设, 默认 100 个; 买到这个数就不再扫这一条。
local QTY_MIN, QTY_MAX, QTY_DEFAULT = 1, 999999, 100

-- 这一次会话里每条扫了几次 / 上次扫描时间。不写存档 —— 重载后从 0 重新数。
function M.Scans(id)
    return scans[tonumber(id) or 0] or 0
end

-- 最近一次扫描的结论: { unit = 查到的最低价 (铜, 可能 nil), tag = none/over/bag/money/fail/pending/bought }
function M.Info(id)
    return lastInfo[tonumber(id) or 0]
end

-- 这一条累计买了多少个 (跨重载, 存 db.autoBuyBought)
function M.BoughtQty(id)
    return tonumber(Bought()[tonumber(id) or 0]) or 0
end

-- 扫描结论变了就刷一下自动购买窗口对应行 (价格 / 结果 / 累计买到)
local function RefreshInfo(id)
    if ns.AutoBuyUI and ns.AutoBuyUI.RefreshRow then
        pcall(ns.AutoBuyUI.RefreshRow, id)
    elseif ns.MerchantUI and ns.MerchantUI.RefreshScan then
        pcall(ns.MerchantUI.RefreshScan, id)
    end
end

-- 这一条的扫描频率 (秒)。旧存档没有 gap 字段 -> 默认 1 秒。
function M.GapOf(id)
    id = tonumber(id)
    local e = id and Cfg()[id]
    local v = tonumber(e and e.gap) or GAP_DEFAULT
    v = math.floor(v)
    if v < GAP_MIN then v = GAP_MIN end
    if v > GAP_MAX then v = GAP_MAX end
    return v
end

-- 改这一条的频率。返回实际生效的值; 条目不在列表里就返回 nil。
function M.SetGap(id, sec)
    id = tonumber(id)
    local e = id and Cfg()[id]
    if not e then return nil end
    local v = tonumber(sec)
    if not v or v ~= v then v = GAP_DEFAULT end
    v = math.floor(v)
    if v < GAP_MIN then v = GAP_MIN end
    if v > GAP_MAX then v = GAP_MAX end
    e.gap = v
    return v
end

-- 这一条最多买多少个 (默认 100, 跨重载累计)
function M.QtyOf(id)
    id = tonumber(id)
    local e = id and Cfg()[id]
    local v = tonumber(e and e.q) or QTY_DEFAULT
    v = math.floor(v)
    if v < QTY_MIN then v = QTY_MIN end
    if v > QTY_MAX then v = QTY_MAX end
    return v
end

-- 改这一条的购买总数上限。返回实际生效的值; 条目不在列表里就返回 nil。
function M.SetQty(id, n)
    id = tonumber(id)
    local e = id and Cfg()[id]
    if not e then return nil end
    local v = tonumber(n)
    if not v or v ~= v then v = QTY_DEFAULT end
    v = math.floor(v)
    if v < QTY_MIN then v = QTY_MIN end
    if v > QTY_MAX then v = QTY_MAX end
    e.q = v
    return v
end

-- 这一条是否参与扫描 (默认开; 暂停后行上显示「扫描」)
function M.ScanOn(id)
    id = tonumber(id)
    local e = id and Cfg()[id]
    if not e then return false end
    return e.on ~= false
end

function M.SetScanOn(id, on)
    id = tonumber(id)
    local e = id and Cfg()[id]
    if not e then return nil end
    e.on = on and true or false
    return e.on
end

-- 行内金额输入框的解析。接受三种写法:
--   1金20银5铜 / 20银 / 5铜  -> 按单位精确换算
--   1.5                      -> 小数按「金」(1.5 金 = 1金50银)
--   15000                    -> 纯整数按「铜」(内部单位, 也不容易把上限误设成天价)
-- 解析不出来返回 nil。
function M.ParseMoney(s)
    s = tostring(s or ""):gsub("%s", "")
    if s == "" then return nil end

    local g = s:match("(%d+)金")
    local si = s:match("(%d+)银")
    local c = s:match("(%d+)铜")
    if g or si or c then
        local v = (tonumber(g) or 0) * 10000 + (tonumber(si) or 0) * 100 + (tonumber(c) or 0)
        return v > 0 and v or nil
    end

    local plain = s:match("^%d+%.?%d*$")
    if plain then
        local v = tonumber(plain)
        if plain:find("%.", 1, true) then
            v = math.floor(v * 10000 + 0.5)
        else
            v = math.floor(v)
        end
        return v > 0 and v or nil
    end
    return nil
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
-- 下次 Set 时会被覆盖掉, 不用专门写迁移。改成时不丢这一条自己的扫描频率。
function M.Set(id, price)
    id, price = tonumber(id), tonumber(price)
    if not id or not price or price <= 0 then return nil end
    local old = Cfg()[id]
    Cfg()[id] = {
        p = math.floor(price),
        gap = (old and tonumber(old.gap)) or GAP_DEFAULT,
        q = (old and tonumber(old.q)) or QTY_DEFAULT,
        on = old and old.on,      -- nil = 扫描开着; false = 玩家暂停了这一条
    }
    return Cfg()[id]
end

function M.Remove(id)
    id = tonumber(id)
    if not id then return false end
    Cfg()[id] = nil
    -- 连同这一条的扫描状态一起清掉: 以后再加回来时从干净的 0 开始
    lastInfo[id] = nil
    lastAt[id] = nil
    scans[id] = nil
    Bought()[id] = nil
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
        out[#out + 1] = {
            id = tonumber(id) or id, p = e.p or 0,
            gap = tonumber(e.gap) or GAP_DEFAULT,
            q = tonumber(e.q) or QTY_DEFAULT,
        }
    end
    table.sort(out, function(a, b)
        local na, nb = tonumber(a.id), tonumber(b.id)
        if na and nb then return na < nb end
        return tostring(a.id) < tostring(b.id)
    end)
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
    -- 拿不到金币数就不拦 (无穷大): 以前返回 0, 会把每一单都误判成「金币不足」
    return math.huge
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
        local b = Bought()
        b[p.id] = (b[p.id] or 0) + p.qty
        local info = lastInfo[p.id]
        if info then info.tag = "bought" end
        RefreshInfo(p.id)
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

-- 事件丢了时用背包数量判断货有没有真的进包 (下单前记了 before)。
-- 只有单笔 pending 时才会用到, 其他来源同时改这个物品数量的概率很低。
local function Delivered(p)
    if not (p and p.before and type(GetItemCount) == "function") then return false end
    local ok, n = pcall(GetItemCount, p.id)
    return ok and type(n) == "number" and n > p.before
end

StartPurchase = function(id, qty, unit, name)
    if pending then return false, "上一笔还在处理" end
    if qty < 1 then return false, "数量为 0" end

    local cost = unit * qty
    if Money() < cost then
        NoteFail(id, "金币不足")
        return false, "金币不足"
    end

    local api = _G.C_AuctionHouse
    if not (api and type(api.StartCommoditiesPurchase) == "function") then
        NoteFail(id, "客户端没有购买接口")
        return false, "客户端没有购买接口"
    end

    -- 下单前再确认一次窗口还开着: 扫描期间玩家可能已经把拍卖行关了
    if ns.Auction and ns.Auction.CanQuery then
        local ok, why = ns.Auction.CanQuery()
        if not ok then
            NoteFail(id, why)
            return false, why
        end
    end

    tokenSeq = tokenSeq + 1
    local token = tokenSeq

    -- 下单前背包里有多少个: 事件丢了时用它判断货到底有没有进包
    local before
    if type(GetItemCount) == "function" then
        local okN, n = pcall(GetItemCount, id)
        if okN and type(n) == "number" then before = n end
    end

    pending = {
        id = id, qty = qty, unit = unit, name = name,
        token = token, at = NowT(), before = before,
    }

    local ok, err = pcall(api.StartCommoditiesPurchase, id, qty)
    diag.lastStart = { at = NowT(), id = id, qty = qty, ok = ok, ret = tostring(err) }
    if not ok then
        pending = nil
        local msg = tostring(err)
        local low = msg:lower()
        if low:find("restrict", 1, true) or low:find("protect", 1, true) then
            msg = "客户端禁止插件自动购买"
        end
        NoteFail(id, msg)
        return false, msg
    end

    -- 这个版本的 API 是 Start(itemID, quantity) → Confirm(itemID, quantity) 两步。
    -- Confirm 万一被标成受保护, Start 一般已经锁到货了, 事件照样会来,
    -- 所以这里 pcall 掉, 失败不影响结果判定。
    C_Timer.After(CONFIRM_DELAY, function()
        if not pending or pending.token ~= token then return end
        local c = _G.C_AuctionHouse
        if c and type(c.ConfirmCommoditiesPurchase) == "function" then
            local okC, retC = pcall(c.ConfirmCommoditiesPurchase, id, qty)
            diag.lastConfirm = { at = NowT(), id = id, qty = qty, ok = okC, ret = tostring(retC) }
        end
    end)

    -- 没有购买事件的客户端: 靠背包数量变化尽早判定成交 (不用干等 10 秒超时)
    local function poll()
        if pending and pending.token == token and Delivered(pending) then
            FinishPurchase(true)
        end
    end
    C_Timer.After(1.5, poll)
    C_Timer.After(4, poll)

    -- 兜底: 事件被吞掉 (静默失败) 也要把 pending 放掉
    C_Timer.After(BUY_TIMEOUT, function()
        if not pending or pending.token ~= token then return end

        -- 事件没来, 但货可能已经进背包: 数量增加就当成功, 别误报「没有回音」
        if Delivered(pending) then
            FinishPurchase(true)
            return
        end

        pending = nil
        diag.lastTimeout = { at = NowT(), id = id, qty = qty }
        Notice("|cffff9955自动购买没有回音|r " .. (name or ("#" .. id)))
        local info = lastInfo[id]
        if info then info.tag = "fail" end
        RefreshInfo(id)
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

    -- 页面已经关掉: 正在飞的那一单成交后也不许把剩下的条目接着扫完
    if not pageActive then RoundDone(); return end
    if i > #list then RoundDone(); return end
    if pending then RoundDone(); return end         -- 上一笔还没结束, 下一轮再说

    local e = list[i]
    if not e.p or e.p <= 0 then again(); return end
    if e.on == false then again(); return end          -- 这一条被暂停扫描了

    -- 本轮排队之后可能又成交了几单: 买够上限就跳过
    if M.BoughtQty(e.id) >= M.QtyOf(e.id) then
        local info = lastInfo[e.id]
        if info then info.tag = "max" end
        RefreshInfo(e.id)
        again(); return
    end

    local AH = ns.Auction
    if not (AH and AH.CheckRecipe) then RoundDone(); return end

    local info = lastInfo[e.id]
    if not info then info = {}; lastInfo[e.id] = info end

    -- 优先用查价缓存 (界面查价 / 手动买入 / 上次扫描留下的价; 有价缓存 30 分钟)。
    -- 不要每次都 force 重查: 有些客户端重复查同一物品会返回空, 表现就是「无货」,
    -- 但手动买入用缓存却能成功。缓存有价就直接走手动买入那条链。
    local cached = AH.Price and AH.Price(e.id)
    local unit = cached and cached.unit

    if unit and unit > 0 then
        info.unit = unit
        info.at = NowT()
        info.tag = "none"

        lastAt[e.id] = NowT()
        scans[e.id] = (scans[e.id] or 0) + 1

        -- 只评估能不能买, 不在这里下单 (客户端只接受玩家点击上下文里的购买)
        if M.BoughtQty(e.id) >= M.QtyOf(e.id) then
            info.tag = "max"
        elseif unit > e.p then
            info.tag = "over"
            NoteFail(e.id, "最低价高于上限")
        else
            local room, why = BuyQty(e.id, unit)
            if room < 1 then
                info.tag = (why == "bag") and "bag" or "money"
                NoteFail(e.id, (why == "bag") and "背包满" or "金币不够")
            else
                info.tag = "ready"      -- 可买: 等玩家点行上的「买入」
            end
        end

        RefreshInfo(e.id)
        again(); return
    end

    -- 缓存里没有价: 查一次, 本轮只记录, 下一轮用缓存价
    AH.CheckRecipe({ item = e.id, mats = {}, made = 1 }, function(out)
        if tok ~= roundToken then return end

        -- 这一条算扫过一次 (不管有没有挂单、买没买成); 行上的「扫 N」和频率判定都用它
        lastAt[e.id] = NowT()
        scans[e.id] = (scans[e.id] or 0) + 1

        local pe = out and out.unit and out.unit[e.id]
        local u = pe and pe.unit

        info.unit = u
        info.at = NowT()
        info.tag = "none"

        if not u or u <= 0 then
            NoteFail(e.id, "拍卖行没有挂单")
        elseif u > e.p then
            info.tag = "over"
            NoteFail(e.id, "最低价高于上限")
        end
        RefreshInfo(e.id)
        again()
    end, nil, true)
end

--------------------------------------------------------------------------- 页面驱动的扫描

-- 只有自动购买列表页开着才扫: 打开页面调 StartPage, 关页面/切页调 StopPage。
-- ticker 一秒一次, 只把「到了自己频率」的条目拎出来查价, 所以每个商品可以设不同间隔。

local function Tick()
    if not pageActive then return end
    if buying then return end          -- 买入弹窗开着: 别发查询覆盖拍卖行的当前搜索结果

    -- 兜底: 购买/查询回调万一丢了, 别让 pending / scanning 永远卡住扫描
    local t = NowT()
    if pending and t - (pending.at or 0) > BUY_TIMEOUT + 5 then
        local p = pending
        pending = nil
        scanning = false
        roundToken = roundToken + 1
        NoteFail(p.id, "购买超时")
        local mc = manualDone
        manualDone = nil
        if mc then pcall(mc, false, "超时") end
        Notice("|cffff9955自动购买请求超时|r 已跳过这一笔")
    end
    if scanning and t - lastScan > 30 then
        scanning = false
        roundToken = roundToken + 1
    end

    if scanning or pending then return end          -- 上一轮 / 上一笔还没收尾

    local AH = ns.Auction
    if not (AH and AH.CanQuery) then return end
    local can = AH.CanQuery()
    if not can then return end                       -- 拍卖行没开: 等下一次 tick

    local now = NowT()
    local due = {}
    local bought = Bought()
    for id, e in pairs(Cfg()) do
        if (e.p or 0) > 0 and e.on ~= false then
            -- 买够总数上限的条目不再进队列 (行上会显示「够数」)
            local q = tonumber(e.q) or QTY_DEFAULT
            if q < QTY_MIN then q = QTY_MIN end
            if (tonumber(bought[id]) or 0) < q then
                local gap = tonumber(e.gap) or GAP_DEFAULT
                if gap < GAP_MIN then gap = GAP_MIN end
                local last = lastAt[id]
                if not last or now - last >= gap then
                    due[#due + 1] = { id = id, p = e.p, gap = gap }
                end
            end
        end
    end
    if #due == 0 then return end
    table.sort(due, function(a, b) return a.id < b.id end)

    scanning = true
    roundToken = roundToken + 1
    lastScan = now
    RoundStep(due, 1)
end

function M.StartPage()
    pageActive = true
    if ticker then return end
    if not (C_Timer and C_Timer.NewTicker) then return end
    ticker = C_Timer.NewTicker(1, Tick)              -- 每秒调度一次
    C_Timer.After(0.2, Tick)                         -- 打开页面先扫一轮, 不用干等 1 秒
end

function M.StopPage()
    pageActive = false
    buying = false
    if ticker then
        pcall(function() ticker:Cancel() end)
        ticker = nil
    end
    -- 让正在飞的那一轮作废: 页面关了就不再往下查/下单
    scanning = false
    roundToken = roundToken + 1
end

function M.PageActive()
    return pageActive
end

-- 买入弹窗打开期间暂停扫描 (弹窗的查价/购买是同一套拍卖行上下文)
function M.SetBuying(on)
    buying = on and true or false
end

-- 手动触发一次调度 (调试用; 页面没开就不做)
function M.Scan()
    if not pageActive then return false, "自动购买页没开" end
    Tick()
    return true
end

function M.Scanning()
    return scanning
end

function M.LastScan()
    return lastScan
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
Hook("BAG_UPDATE_DELAYED")

ev:SetScript("OnEvent", function(_, event)
    diag.events[event] = (diag.events[event] or 0) + 1
    diag.lastEvent = { at = NowT(), name = event }

    if event == "COMMODITY_PURCHASE_SUCCEEDED" or event == "COMMODITY_PURCHASED" then
        FinishPurchase(true)
    elseif event == "COMMODITY_PURCHASE_FAILED" then
        local why = "拍卖行拒绝了这一单"
        if pending then
            if Money() < (pending.unit or 0) * (pending.qty or 1) then
                why = "金币不足"
            elseif type(GetNumFreeBagSlots) == "function" then
                local ok, free = pcall(GetNumFreeBagSlots)
                if ok and free == 0 then why = "背包没有空格" end
            end
        end
        FinishPurchase(false, why)
    elseif event == "BAG_UPDATE_DELAYED" then
        -- 没有购买事件的客户端: 背包里这件数量涨了就当这一单成交
        if pending and Delivered(pending) then FinishPurchase(true) end
    end
end)

--------------------------------------------------------------------------- 诊断

-- /wgm 自动 诊断: 看客户端到底有没有购买接口/事件, 以及最近一单卡在哪一步
function M.Diag()
    local api = _G.C_AuctionHouse
    ns.Print("自动购买诊断:")
    print(format("  自动购买条目: %d", M.Count()))

    local kinds = {}
    for k in pairs(Cfg()) do
        kinds[type(k)] = (kinds[type(k)] or 0) + 1
    end
    for k, n in pairs(kinds) do
        print(format("    键类型 %s: %d", k, n))
    end

    print("  C_AuctionHouse: " .. (api and "有" or "|cffff5555无"))

    print(format("  页面: %s · 扫描中: %s · ticker: %s",
        M.PageActive() and "开着" or "|cffff9955关着|r",
        M.Scanning() and "是" or "否",
        ticker and "在" or "|cffff5555无|r"))

    local auction = ns.Auction
    if auction and auction.CanQuery then
        local okQuery = auction.CanQuery()
        print("  拍卖行: " .. (okQuery and "可查询" or "|cffff9955未打开|r"))
    end

    local function has(n)
        return (api and type(api[n]) == "function") and "有" or "|cffff5555无"
    end
    print("  StartCommoditiesPurchase: " .. has("StartCommoditiesPurchase"))
    print("  ConfirmCommoditiesPurchase: " .. has("ConfirmCommoditiesPurchase"))
    print("  SendSearchQuery: " .. has("SendSearchQuery"))

    local names = {
        "COMMODITY_PURCHASE_SUCCEEDED",
        "COMMODITY_PURCHASE_FAILED",
        "COMMODITY_PURCHASED",
        "BAG_UPDATE_DELAYED",
    }
    for _, name in ipairs(names) do
        print(format("  事件 %s: %s · 收到 %d 次", name,
            M.Hooks[name] and "已注册" or "|cffff5555注册失败",
            diag.events[name] or 0))
    end

    local ls = diag.lastStart
    if ls then
        print(format("  最近下单: #%d ×%d · %s · 返回 %s",
            ls.id, ls.qty, ls.ok and "成功" or "|cffff5555报错", ls.ret))
    else
        print("  最近下单: 无")
    end

    local lc = diag.lastConfirm
    if lc then
        print(format("  最近确认: #%d ×%d · %s · 返回 %s",
            lc.id, lc.qty, lc.ok and "成功" or "|cffff5555报错", lc.ret))
    else
        print("  最近确认: 无")
    end

    local le = diag.lastEvent
    print("  最近事件: " .. (le and (le.name .. format(" (%.1fs)", le.at)) or "无"))
    local lt = diag.lastTimeout
    if lt then print(format("  最近超时: #%d ×%d", lt.id, lt.qty)) end
    if pending then print(format("  当前 pending: #%d ×%d", pending.id, pending.qty)) end

    local money = Money()
    local free = FreeSlots()
    print(format("  金币: %s · 背包空格: %s",
        (money == math.huge) and "接口不可用" or tostring(money),
        free and tostring(free) or "接口不可用"))

    local lf = diag.lastFail
    if lf then
        print(format("  最近失败: #%d · %s (%.1f 秒前)", lf.id, lf.reason, NowT() - lf.at))
    else
        print("  最近失败: 无")
    end

    local now = NowT()
    for _, e in ipairs(M.List()) do
        local last = lastAt[e.id]
        print(format("  #%d ≤ %s/个 · 每 %d 秒 · 已买 %d/%d · 上次扫描 %s",
            e.id, MoneyText(e.p), e.gap, M.BoughtQty(e.id), e.q,
            last and format("%.1f 秒前", now - last) or "从未"))
    end
end

--------------------------------------------------------------------------- 摘要

function M.Summary()
    return format("%d 件 · 页面开着就按每行频率扫描", M.Count())
end
