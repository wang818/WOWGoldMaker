---------------------------------------------------------------------------
-- WOWGoldMaker / MerchantUI.lua
-- 商人货架 —— 独立窗口: 浏览所有商人卖的东西, 并反查「这个物品谁卖」。
--
-- 数据: MerchantData.lua (客户端 HandyNotes forever 快照, 829 位商人 / 985 种货 /
-- 10903 条「谁卖什么」)。客户端的离线库里没有 npc_vendor 表, 也没有「查某商人卖什么」
-- 的接口 —— 这份快照是唯一能离线反查的来源。
--
-- 价格口径 (与材料汇总一致, 从可信到兜底):
--   db.npcBuy (手动录入) > db.vendorSeen (开商人时实测) > 快照买价
--
-- 列表是虚拟化的: 只建几十个行控件, 滚动时复用到新位置。全部展开后最多一万多行,
-- 一行一个 Frame 会直接卡死。
---------------------------------------------------------------------------

local ADDON, ns = ...

local T = ns.T
local C = T.C
local format = string.format

ns.MerchantUI = ns.MerchantUI or {}

-- 数据 / 查询接口 (不依赖界面, 可以单独测)
local M = {}
ns.Merchant = M
M.onlyMats = false

--------------------------------------------------------------------------- 尺寸 (设计坐标 440x500, 运行时整体等比缩放)

local BASE_W, BASE_H = 440, 500
local PANEL_PCT       = 0.50   -- 窗口宽度的 50%
local PANEL_MAX_H     = 0.86
local CONTENT_PAD     = 24
local SCALE_MAX       = 2.6

local PAD      = 20      -- 左右内边距
local TITLE_Y  = -6      -- 标题行
local SEARCH_Y = -30     -- 搜索框顶部
local SEARCH_H = 22
local LIST_Y   = -58     -- 列表区顶部
local LIST_BOT = 26      -- 列表区距面板底部 (给页脚留位)
local ITEM_H   = 24      -- 物品行高
local NPC_H    = 17      -- 商人子行高
local BAR_W    = 3       -- 滚动条宽
local SCROLL_STEP = 60   -- 滚轮一格
local ROW_INDENT  = 26   -- 商人子行缩进

-- 行内列宽 (设计像素): 价格列要放得下「1000金0银0铜」这种四位数金额,
-- 商人数列只需要塞下「27 家」
local PRICE_W = 96
local CNT_W   = 44

local F_TITLE = 13
local F_ITEM  = 10
local F_NPC   = 9
local F_TIP   = 8

local frame, content, contentW
local scroll, listContent, track, thumb, sbar
local searchEdit, searchHint, clearBtn
local sortBtn, filterBtn, countText, emptyText
local shopTab, favTab, autoTab, autoSetBtn, footerHint
local itemPool, npcPool = {}, {}
local itemUsed, npcUsed = 0, 0

local view = { entries = {}, off = {}, n = 0, height = 0 }   -- 当前渲染用的扁平行表
local filtered = {}          -- 当前筛选结果 (物品记录数组)
local expanded = {}          -- itemID -> true (展开了商人子行)
local page = "shop"          -- "shop" = 全部货架, "fav" = 我的收藏, "auto" = 自动购买

-- 前向声明 (下面几处互相引用)
local Render, UpdateThumb, RefreshCount, ApplyQuery, SetPage, PaintTabs, PaintStar

--------------------------------------------------------------------------- 数据: 名字 / 区域

local zoneNameCache = {}
local itemNameCache = {}
local NPC_FACTION = { A = "联盟", H = "部落", N = "中立" }

-- "中文|英文" 里挑一个
local function Localized(s)
    if type(s) ~= "string" or s == "" then return nil end
    local zh, en = s:match("^(.-)|(.*)$")
    if not zh then return s end
    local loc = (GetLocale and GetLocale()) or "enUS"
    if loc == "zhCN" or loc == "zhTW" then
        return (zh ~= "" and zh) or en
    end
    return (en ~= "" and en) or zh
end

-- 地图ID -> 区域名。客户端本地化名优先, 取不到用快照里的中英对照。
function M.ZoneName(mapID)
    mapID = tonumber(mapID) or 0
    if mapID <= 0 then return nil end
    local hit = zoneNameCache[mapID]
    if hit ~= nil then return hit ~= false and hit or nil end

    local name
    if C_Map and type(C_Map.GetMapInfo) == "function" then
        local ok, info = pcall(C_Map.GetMapInfo, mapID)
        if ok and type(info) == "table" and type(info.name) == "string" and info.name ~= "" then
            name = info.name
        end
    end
    if not name and type(GetMapNameByID) == "function" then
        local ok, v = pcall(GetMapNameByID, mapID)
        if ok and type(v) == "string" and v ~= "" then name = v end
    end
    if not name and type(ns.ZoneNames) == "table" then
        name = Localized(ns.ZoneNames[mapID])
    end

    zoneNameCache[mapID] = name or false
    return name
end

-- 商人名字: 客户端 NPC 数据是本地化的, 快照里是英文源串
local function NpcName(rec)
    if rec.locName then return rec.locName end
    local name
    if C_CreatureInfo and type(C_CreatureInfo.GetCreatureInfo) == "function" then
        local ok, info = pcall(C_CreatureInfo.GetCreatureInfo, rec.id)
        if ok and type(info) == "table" and type(info.name) == "string" and info.name ~= "" then
            name = info.name
        end
    end
    if type(name) ~= "string" or name == "" then name = rec.name end
    if type(name) ~= "string" or name == "" then name = "#" .. tostring(rec.id) end
    rec.locName = name
    return name
end
M.NpcName = NpcName

-- 客户端回包拿到的本地化名顺手存进存档: 浏览过的物品下次还能按中文搜到,
-- 不用等客户端再回一次包 (985 件名字全存下来也就几十 KB)。
local function PersistedName(id)
    local db = ns.DB and ns.DB()
    local t = db and db.itemNames
    return t and t[id]
end

local function RememberName(id, name)
    local db = ns.DB and ns.DB()
    if not db then return end
    db.itemNames = db.itemNames or {}
    db.itemNames[id] = name
end

-- 物品名字: 只在「正在画这一行」时向客户端要, 不要在筛选/排序里调 ——
-- 那会对 985 件物品同时发查询, 服务器直接给你限流。
-- 每件物品 30 秒最多问一次: 列表每 2 秒重画一遍, 光靠 NPC.Info 自带的 2 秒节流
-- 会变成「每 2 秒给一屏物品各发一次查询」, 太吵。
local nameAskedAt = {}
local pendingName = 0        -- 本轮有几行还没拿到本地化名 (ticker 靠它决定要不要重画)

local function ItemName(rec, allowRequest)
    local hit = itemNameCache[rec.id] or PersistedName(rec.id)
    if hit then return hit end
    pendingName = pendingName + 1
    if allowRequest and ns.NPC and ns.NPC.Info then
        local now = GetTime() or 0
        local last = nameAskedAt[rec.id]
        if not last or now - last > 30 then
            nameAskedAt[rec.id] = now
            local n = ns.NPC.Info(rec.id)
            if type(n) == "string" and n ~= "" then
                itemNameCache[rec.id] = n    -- 只缓存真名, 英文兜底不缓存 (等本地化名回包)
                RememberName(rec.id, n)
                return n
            end
        end
    end
    -- 内置中文名排在英文前面: 中文客户端看到的就是中文, 也不用等客户端回包
    if type(rec.zh) == "string" and rec.zh ~= "" then return rec.zh end
    if type(rec.name) == "string" and rec.name ~= "" then return rec.name end
    return "#" .. tostring(rec.id)
end
M.ItemName = function(rec) return ItemName(rec, true) end

-- 已经知道的名字, 不向客户端发查询 (提示框 / 右键搜拍卖行 / 收藏回执用)。
-- 早先这两个地方直接调了一个不存在的全局 KnownName, 物品名还没回包时点右键会报错。
local function KnownName(rec) return ItemName(rec, false) end

-- 搜索要比三串名字: 客户端回包的本地化名、内置中文名、快照英文名。
-- 只比其中一个的话, 中文客户端搜英文搜不到、搜中文又搜不到英文, 两边都得试。
local function NameHas(rec, q)
    local loc = itemNameCache[rec.id] or PersistedName(rec.id)
    if type(loc) == "string" and loc ~= "" and loc:lower():find(q, 1, true) then return true end
    if type(rec.zh) == "string" and rec.zh ~= "" and rec.zh:lower():find(q, 1, true) then return true end
    local raw = rec.name
    if type(raw) == "string" and raw ~= "" and raw:lower():find(q, 1, true) then return true end
    return false
end

--------------------------------------------------------------------------- 数据: 建索引

local function Fields(s)
    local out = {}
    for part in (s .. "|"):gmatch("([^|]*)|") do out[#out + 1] = part end
    return out
end

local idx

-- 解析 MerchantData 的三张字符串表, 建成「物品 -> 商人列表」+「商人 -> 资料」。
-- 只做一次 (第一次打开窗口时), 一万条关系, 几毫秒。
function M.Index()
    if idx then return idx end

    local goods = type(ns.MerchantGoods) == "table" and ns.MerchantGoods or nil
    local stock = type(ns.MerchantStock) == "table" and ns.MerchantStock or nil
    local mlist = type(ns.Merchants) == "table" and ns.Merchants or nil

    idx = { items = {}, byID = {}, npcs = {}, npcCount = 0, pairs = 0 }
    if not (goods and stock and mlist) then
        idx.err = "数据文件缺失 (MerchantData.lua 没加载)"
        return idx
    end

    for id, s in pairs(mlist) do
        local f = Fields(s)
        idx.npcs[id] = {
            id    = id,
            name  = f[1] or "",
            zone  = tonumber(f[2]) or 0,
            coord = f[3] or "",
            fac   = (f[4] ~= "" and f[4]) or "N",
        }
        idx.npcCount = idx.npcCount + 1
    end

    for id, s in pairs(goods) do
        local f = Fields(s)
        local rec = {
            id    = id,
            name  = f[1] or "",
            price = tonumber(f[2]) or 0,
            icon  = f[3] or "",
            zh    = f[4] or "",      -- 中文名 (生成时从 RDbItems 抽的, 少数物品没有)
            npcs  = {},
        }
        idx.items[#idx.items + 1] = rec
        idx.byID[id] = rec
    end

    for npcID, s in pairs(stock) do
        for itemID in s:gmatch("%d+") do
            local rec = idx.byID[tonumber(itemID)]
            if rec then
                rec.npcs[#rec.npcs + 1] = npcID
                idx.pairs = idx.pairs + 1
            end
        end
    end

    -- 同一物品的商人按「地图 -> 名字」排, 展开后看起来有秩序
    for _, rec in ipairs(idx.items) do
        table.sort(rec.npcs, function(a, b)
            local A, B = idx.npcs[a], idx.npcs[b]
            if not A then return false end
            if not B then return true end
            if A.zone ~= B.zone then
                if A.zone == 0 then return false end
                if B.zone == 0 then return true end
                return A.zone < B.zone
            end
            return (A.name or "") < (B.name or "")
        end)
    end

    return idx
end

--------------------------------------------------------------------------- 数据: 收藏

-- 收藏 = 货架上的「想要清单」。存 itemID -> 收藏时间 (os.time), 按时间倒序就能
-- 让最近收的排在最前面; 用 true/false 存的话「我的收藏」页只能按买价排。
local function FavStore()
    local db = ns.DB and ns.DB()
    if not db then return nil end
    db.favItems = db.favItems or {}
    return db.favItems
end

local function Stamp()
    if os and os.time then return os.time() end
    return math.floor(GetTime() or 0)
end

function M.IsFav(id)
    local t = FavStore()
    return (t and t[id] ~= nil) and true or false
end

-- 返回收藏后的状态 (true = 现在已收藏)
function M.ToggleFav(id)
    local t = FavStore()
    if not t or not id then return false end
    if t[id] then
        t[id] = nil
        return false
    end
    t[id] = Stamp()
    return true
end

function M.FavCount()
    local t = FavStore()
    local n = 0
    if t then for _ in pairs(t) do n = n + 1 end end
    return n
end

-- 收藏记录: 按收藏时间倒序。收藏了但快照里已经没有的 id 直接跳过 (数据换版时不至于崩)。
function M.FavRecords()
    local d = M.Index()
    local t = FavStore()
    local out = {}
    if not t then return out end
    for id in pairs(t) do
        local rec = d.byID[id]
        if rec then out[#out + 1] = rec end
    end
    local function when(r) return t[r.id] or 0 end
    table.sort(out, function(a, b)
        local ta, tb = when(a), when(b)
        if ta ~= tb then return ta > tb end
        return a.id < b.id
    end)
    return out
end

-- 自动购买页的记录: 从 AutoBuy 的列表拼出和货架记录同形的 rec, 好复用同一套行池。
-- 快照里有这件就借它的名字/图标; 通过 /wgm 自动 加 进来的 ID 不一定在货架快照里,
-- 这时退到客户端的 GetItemInfo, 再不行显示 #ID, 但不能让这一页变空白。
function M.AutoRecords()
    local AB = ns.AutoBuy
    local out = {}
    if not (AB and AB.List) then return out end

    local d = M.Index()
    for _, e in ipairs(AB.List()) do
        local snap = d.byID[e.id]
        local name
        if not snap and type(GetItemInfo) == "function" then
            local ok, n = pcall(GetItemInfo, e.id)
            if ok and type(n) == "string" and n ~= "" then name = n end
        end
        out[#out + 1] = {
            id = e.id,
            name = (snap and snap.name) or name,
            zh = snap and snap.zh or nil,
            icon = snap and snap.icon or nil,
            npcs = (snap and snap.npcs) or {},
            -- price 字段给通用的「买价」排序用, 在自动购买页它表示单价上限
            price = e.p,
            autoP = e.p,
        }
    end
    return out
end

--------------------------------------------------------------------------- 数据: 筛选 / 排序

local SORTS = {
    { key = "price", label = "买价 ↓" },
    { key = "name",  label = "名字" },
    { key = "npcs",  label = "商人 ↓" },
    { key = "fav",   label = "最近收藏", favOnly = true },
}
local sortMode = "price"

local function SortLabel(key)
    -- 自动购买页的 price 字段装的是「单价上限」, 按钮别再写「买价」
    if page == "auto" and key == "price" then return "上限 ↓" end
    for _, v in ipairs(SORTS) do
        if v.key == key then return v.label end
    end
    return "排序"
end

-- 当前页可用的排序方式: 「最近收藏」只在收藏页有意义, 货架页循环时跳过它
local function SortModes()
    local out = {}
    for _, v in ipairs(SORTS) do
        if not v.favOnly or page == "fav" then out[#out + 1] = v end
    end
    return out
end

-- q: 关键词 (物品名 / 商人名, 不区分大小写); onlyMats: 只看本插件配方用得到的;
-- base: 只在给定记录里筛 (收藏页传收藏列表)。不传就是全量货架。
-- 注意: 命中商人时会把「该商人的货物」一起算进来 —— 这个扩展天然被 base 限制住,
-- 收藏页搜商人名只会捞出「我收藏的、这个商人卖的」那几件, 不会冒出全店的货。
function M.Filter(q, onlyMats, base)
    local d = M.Index()
    q = (q or ""):gsub("^%s+", ""):gsub("%s+$", ""):lower()

    -- 先看关键词命中了哪些商人, 命中商人的货物一并算进来 (反查「谁卖」的入口)
    local npcHit
    if q ~= "" then
        npcHit = {}
        for id, npc in pairs(d.npcs) do
            local hit = false
            local loc = NpcName(npc)
            if type(loc) == "string" and loc:lower():find(q, 1, true) then
                hit = true
            else
                -- 商人名同理: 本地化名之外也认快照里的英文名
                local raw = npc.name
                if type(raw) == "string" and raw ~= "" and raw:lower():find(q, 1, true) then
                    hit = true
                end
            end
            if hit then npcHit[id] = true end
        end
    end

    local wanted = (onlyMats and ns.Vendor and ns.Vendor.Wanted) or nil
    local out = {}
    for _, rec in ipairs(base or d.items) do
        if not wanted or wanted(rec.id) then
            local hit = true
            if q ~= "" then
                hit = false
                if NameHas(rec, q) then
                    hit = true
                elseif npcHit then
                    for _, npcID in ipairs(rec.npcs) do
                        if npcHit[npcID] then hit = true; break end
                    end
                end
            end
            if hit then out[#out + 1] = rec end
        end
    end
    return out
end

function M.Sort(list, mode)
    mode = mode or sortMode
    if mode == "fav" then
        -- 最近收的排前面 (同一秒收的按 id 兜底, 保证顺序稳定)
        local t = FavStore() or {}
        table.sort(list, function(a, b)
            local ta, tb = t[a.id] or 0, t[b.id] or 0
            if ta ~= tb then return ta > tb end
            return a.id < b.id
        end)
    elseif mode == "price" then
        table.sort(list, function(a, b)
            if a.price ~= b.price then return a.price > b.price end
            return a.id < b.id
        end)
    elseif mode == "npcs" then
        table.sort(list, function(a, b)
            if #a.npcs ~= #b.npcs then return #a.npcs > #b.npcs end
            return a.id < b.id
        end)
    else
        -- 名字排序用「内置中文名优先」的稳定键: 客户端回包的名字会变, 拿它当键
        -- 会让列表边滚边重排 (行会跳)。中文按 UTF-8 字节序比较 (同部首的字相邻)。
        local function key(r)
            local zh = r.zh
            if type(zh) == "string" and zh ~= "" then return zh:lower() end
            return (r.name or ""):lower()
        end
        table.sort(list, function(a, b)
            local na, nb = key(a), key(b)
            if na ~= nb then return na < nb end
            return a.id < b.id
        end)
    end
    return list
end

-- 扁平行表: 物品行 + (展开时) 商人子行。纯计算, 不碰界面。
function M.BuildView(list, openSet)
    local v = { entries = {}, off = {}, n = 0, height = 0 }
    local d = M.Index()
    local y = 0
    for _, rec in ipairs(list) do
        v.n = v.n + 1
        v.entries[v.n] = { rec = rec }
        v.off[v.n] = y
        y = y + ITEM_H

        if openSet[rec.id] then
            for _, npcID in ipairs(rec.npcs) do
                v.n = v.n + 1
                v.entries[v.n] = {
                    rec = rec,
                    npc = d.npcs[npcID] or { id = npcID, name = "", zone = 0, coord = "", fac = "N" },
                }
                v.off[v.n] = y
                y = y + NPC_H
            end
        end
    end
    v.height = y
    return v
end

--------------------------------------------------------------------------- 价格

-- 金币写法统一走查价模块 (带金/银/铜分色)
local function Money(c)
    if ns.NPC and ns.NPC.MoneyEx then return ns.NPC.MoneyEx(c) end
    return tostring(c)
end

local function MoneyShort(c)
    if ns.NPC and ns.NPC.Money then return ns.NPC.Money(c) end
    return tostring(c)
end

-- 粗略文字宽度 (中文 ≈ 字号, 数字/字母 ≈ 字号 x 0.55), 跳过 |cffRRGGBB 颜色码。
-- 和 UI.lua 里那个是同一套算法: 只用来判断一段金额放不放得下, 不必精确。
local function ApproxWidth(s, size)
    size = size or F_ITEM
    local wide, ascii = size, size * 0.55
    local w, i, len = 0, 1, #s
    while i <= len do
        local b = s:byte(i)
        if b == 0x7C then
            local nxt = s:byte(i + 1)
            if nxt == 0x63 then i = i + 10
            elseif nxt == 0x72 then i = i + 2
            else i = i + 1 end
        elseif b >= 0xE0 then
            w = w + wide
            i = i + 3
        elseif b >= 0xC0 then
            w = w + wide * 0.75
            i = i + 2
        else
            w = w + ascii
            i = i + 1
        end
    end
    return w
end

-- 价格列的文字: 优先「1金20银5铜」这种精确写法; 四位数金额 (1000金0银0铜) 在 96px 里
-- 放不下, 退回短写 (1000金 / 12金34银)。完整金额在悬停提示里。
local function PriceText(price)
    local exact = Money(price)
    if ApproxWidth(exact, F_ITEM) <= PRICE_W - 6 then return exact end
    return MoneyShort(price)
end

-- 显示用价格: 手动录入 > 货架实测 > 快照
local function PriceOf(rec)
    if ns.NPC and ns.NPC.BuyWithSource then
        local p, src = ns.NPC.BuyWithSource(rec.id)
        if p and p > 0 then return p, src end
    end
    if rec.price and rec.price > 0 then return rec.price, "table" end
    return nil, nil
end

--------------------------------------------------------------------------- 小控件

-- 小胶囊按钮 (排序 / 筛选)。active 状态要能盖住悬停效果 —— 选了「材料」之后
-- 鼠标移开不能又变回灰的, 否则看不出当前筛选是开着的。
local function NewChip(parent, w, h, label)
    local b = CreateFrame("Button", nil, parent)
    b:SetSize(w, h)

    local bg = b:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints(true)
    bg:SetTexture(T.PATH .. "btn")
    b.bg = bg

    local txt = T.Text(b, F_TIP + 2, C.muted)
    txt:SetPoint("CENTER")
    txt:SetText(label)
    txt:SetWordWrap(false)
    b.text = txt

    local function Paint()
        if b.active then
            bg:SetVertexColor(T.rgb(C.gold, 0.85))
            txt:SetTextColor(T.rgb(C.ink))
        elseif b.hover then
            bg:SetVertexColor(1, 1, 1, 0.20)
            txt:SetTextColor(T.rgb(C.text))
        else
            bg:SetVertexColor(1, 1, 1, 0.10)
            txt:SetTextColor(T.rgb(C.muted))
        end
    end
    b.Paint = Paint

    b:SetScript("OnEnter", function() b.hover = true; Paint() end)
    b:SetScript("OnLeave", function() b.hover = false; Paint() end)

    -- 注意形参: 外面是 b:SetActive(x) 冒号调用, 第一个参数是按钮自己。
    -- 写成 function(on) 的话 on 收到的是一个表 (恒为真), 永远高亮 —— 材料按钮
    -- 之前「选了材料却看不出是开着的」就是这个原因。
    b.SetActive = function(_, on)
        b.active = on and true or false
        Paint()
    end

    Paint()
    return b
end

local function Font(parent, size, color)
    local fs = T.Text(parent, size, color)
    fs:SetWordWrap(false)
    return fs
end

--------------------------------------------------------------------------- 尺寸计算

local function WindowSize()
    local w, h = 1024, 768
    local okW, vw = pcall(function() return UIParent:GetWidth() end)
    if okW and type(vw) == "number" and vw > 0 then w = vw end
    local okH, vh = pcall(function() return UIParent:GetHeight() end)
    if okH and type(vh) == "number" and vh > 0 then h = vh end
    return w, h
end

local function PanelSize()
    local sw, sh = WindowSize()
    local w = math.floor(sw * PANEL_PCT)
    local h = math.floor(w * (BASE_H / BASE_W))
    local maxH = math.floor(sh * PANEL_MAX_H)
    if h > maxH then h = maxH end
    return math.max(320, w), math.max(300, h)
end

local function ComputeLayout(pw, ph)
    local innerW = pw - CONTENT_PAD * 2
    local innerH = ph - CONTENT_PAD * 2
    local k = math.min(innerH / BASE_H, innerW / BASE_W)
    if not (type(k) == "number" and k > 0) then k = 1 end
    if k > SCALE_MAX then k = SCALE_MAX end
    local cw = innerW / k
    if cw < BASE_W then cw = BASE_W end
    return k, cw, BASE_H
end

--------------------------------------------------------------------------- 滚动

local function ScrollMax()
    local viewH = scroll:GetHeight() or 1
    local ch = listContent:GetHeight() or 1
    return math.max(0, ch - viewH)
end

local function ScrollPixels(px)
    local m = ScrollMax()
    local v = (scroll:GetVerticalScroll() or 0) + px
    if v < 0 then v = 0 elseif v > m then v = m end
    scroll:SetVerticalScroll(v)
    Render()
end

UpdateThumb = function()
    if not (thumb and track) then return end
    local grab = sbar and sbar.grab
    local viewH = scroll:GetHeight() or 1
    local ch = listContent:GetHeight() or 1
    local maxScroll = ch - viewH
    if maxScroll <= 0 then
        thumb:Hide()
        if grab then grab:Hide() end
        return
    end
    thumb:Show()
    if grab then grab:Show() end

    local h = math.max(20, viewH * (viewH / ch))
    thumb:SetHeight(h)
    local p = (scroll:GetVerticalScroll() or 0) / maxScroll
    if p < 0 then p = 0 elseif p > 1 then p = 1 end
    thumb:ClearAllPoints()
    thumb:SetPoint("TOPLEFT", track, "TOPLEFT", 0, -((viewH - h) * p))
end

-- 滚动条: 轨道只是 Texture, 收不到鼠标, 所以底下用 Frame 接点击翻页,
-- 滑块上再盖一层透明 grab 专门接拖拽 (同主面板, 那边踩过「拖滚动条变拖窗口」的坑)。
local function BuildScrollBar(parent)
    local bar = CreateFrame("Frame", nil, parent)
    bar:SetWidth(BAR_W + 12)
    bar:SetPoint("TOP", scroll, "TOPRIGHT", 6, 0)
    bar:SetPoint("BOTTOM", scroll, "BOTTOMRIGHT", 6, 0)
    bar:SetFrameLevel((parent:GetFrameLevel() or 1) + 6)
    bar:EnableMouse(true)
    bar:EnableMouseWheel(true)

    track = bar:CreateTexture(nil, "BACKGROUND")
    track:SetColorTexture(1, 1, 1, 0.05)
    track:SetWidth(BAR_W)
    track:SetPoint("TOP", bar, "TOP", 0, 0)
    track:SetPoint("BOTTOM", bar, "BOTTOM", 0, 0)

    thumb = bar:CreateTexture(nil, "ARTWORK")
    thumb:SetColorTexture(T.rgb(C.gold, 0.5))
    thumb:SetWidth(BAR_W)
    thumb:SetHeight(24)
    thumb:SetPoint("TOPLEFT", track, "TOPLEFT", 0, 0)
    thumb:Hide()

    local grab = CreateFrame("Frame", nil, bar)
    grab:SetWidth(BAR_W + 12)
    grab:SetPoint("TOP", thumb, "TOP", 0, 0)
    grab:SetPoint("BOTTOM", thumb, "BOTTOM", 0, 0)
    grab:EnableMouse(true)
    grab:RegisterForDrag("LeftButton")
    grab:Hide()
    bar.grab = grab

    local function CursorY()
        local _, cy = GetCursorPosition()
        return (cy or 0) / (bar:GetEffectiveScale() or 1)
    end

    grab:SetScript("OnDragStart", function(self)
        self.offset = CursorY() - (thumb:GetBottom() or 0)
        self:SetScript("OnUpdate", function(s)
            local trackH = track:GetHeight() or 1
            local h = thumb:GetHeight() or 1
            local span = trackH - h
            if span <= 1 then return end
            local bottom = CursorY() - (s.offset or 0)
            local m = ScrollMax()
            local v = ((track:GetTop() or 0) - h - bottom) / span * m
            if v < 0 then v = 0 elseif v > m then v = m end
            scroll:SetVerticalScroll(v)
            Render()
        end)
    end)
    grab:SetScript("OnDragStop", function(self) self:SetScript("OnUpdate", nil) end)

    bar:SetScript("OnMouseDown", function(_, button)
        if button ~= "LeftButton" then return end
        local viewH = scroll:GetHeight() or 1
        if CursorY() > (thumb:GetTop() or 0) then
            ScrollPixels(-viewH * 0.9)
        else
            ScrollPixels(viewH * 0.9)
        end
    end)
    bar:SetScript("OnMouseWheel", function(_, delta) ScrollPixels(-(delta or 0) * SCROLL_STEP) end)

    sbar = bar
    return bar
end

--------------------------------------------------------------------------- 行池

-- 图标: 优先快照里记的图标名 (离线就有), 再退到客户端
local function IconOf(rec)
    if rec.icon and rec.icon ~= "" then
        return "Interface\\Icons\\" .. rec.icon
    end
    local icon = ns.Prof and ns.Prof.ItemIcon and ns.Prof.ItemIcon(rec.id)
    return icon or "Interface\\Icons\\INV_Misc_QuestionMark"
end

local function TooltipAtCursor(anchor)
    local ok = pcall(GameTooltip.SetOwner, GameTooltip, anchor, "ANCHOR_CURSOR_RIGHT")
    if not ok then pcall(GameTooltip.SetOwner, GameTooltip, anchor, "ANCHOR_CURSOR") end
end

local function ItemTooltip(anchor, rec)
    local name, link
    if ns.NPC and ns.NPC.Info then name, link = ns.NPC.Info(rec.id) end
    name = name or KnownName(rec)

    TooltipAtCursor(anchor)
    GameTooltip:ClearLines()

    if page == "auto" then
        GameTooltip:AddLine(name, 1, 1, 1)
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine(format("单价上限 %s/个", Money(rec.autoP or 0)), 1, 0.82, 0.35)
        local have = (ns.AutoBuy and ns.AutoBuy.Have and ns.AutoBuy.Have(rec.id)) or 0
        GameTooltip:AddLine(format("背包 %d 个 · 拍卖行低于上限就买", have), 0.82, 0.84, 0.88)
        GameTooltip:AddLine("|cff8a929e左键改价 / 移除 · 右键在拍卖行搜索|r", 0.55, 0.58, 0.62)
        GameTooltip:Show()
        return
    end

    if link then
        pcall(GameTooltip.SetHyperlink, GameTooltip, link)
    else
        GameTooltip:AddLine(name, 1, 1, 1)
    end

    local price, src = PriceOf(rec)
    local srcText = (src == "manual" and "手动录入") or (src == "vendor" and "货架实测")
        or (src == "table" and "价目表") or nil
    GameTooltip:AddLine(" ")
    if price then
        GameTooltip:AddLine(format("商人售价 %s%s", Money(price),
            srcText and ("  |cff8a929e(" .. srcText .. ")|r") or ""), 1, 0.82, 0.35)
    else
        GameTooltip:AddLine("快照里没有买价", 0.62, 0.65, 0.70)
    end
    GameTooltip:AddLine(format("|cff8a929e%d 位商人有售|r", #rec.npcs), 0.82, 0.84, 0.88)
    GameTooltip:AddLine("|cff8a929e左键展开名单 · 右键在拍卖行搜索|r", 0.55, 0.58, 0.62)
    GameTooltip:Show()
end

local function NewItemRow()
    local r = CreateFrame("Button", nil, listContent)
    r:SetHeight(ITEM_H)
    r:RegisterForClicks("LeftButtonUp", "RightButtonUp")

    r.bg = r:CreateTexture(nil, "BACKGROUND")
    r.bg:SetAllPoints(true)
    r.bg:SetColorTexture(1, 1, 1, 0)

    -- 行首星标: 收藏 / 取消收藏。它自己是个 Button, 点它不会顺带把行展开 ——
    -- 子控件吃掉了鼠标事件, 父按钮收不到 OnClick。
    r.star = CreateFrame("Button", nil, r)
    r.star:SetSize(14, 16)
    r.star:SetPoint("LEFT", 0, 0)
    r.starText = Font(r.star, 11, C.muted)
    r.starText:SetPoint("CENTER", 0, 0)
    r.starText:SetText("☆")

    r.caret = Font(r, F_NPC, C.muted)
    r.caret:SetPoint("LEFT", 16, 0)

    r.icon = r:CreateTexture(nil, "ARTWORK")
    r.icon:SetSize(14, 14)
    r.icon:SetPoint("LEFT", 27, 0)
    r.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)

    r.title = Font(r, F_ITEM, C.text)
    r.title:SetPoint("LEFT", 45, 0)

    r.cnt = Font(r, F_TIP, C.faint)
    r.cnt:SetWidth(CNT_W)
    r.cnt:SetJustifyH("RIGHT")

    r.price = Font(r, F_ITEM, C.gold)
    r.price:SetWidth(PRICE_W)
    r.price:SetJustifyH("RIGHT")

    r:SetScript("OnEnter", function(s)
        s.bg:SetColorTexture(1, 1, 1, 0.06)
        if s.entry then ItemTooltip(s, s.entry.rec) end
    end)
    r:SetScript("OnLeave", function(s)
        s.bg:SetColorTexture(1, 1, 1, s.open and 0.05 or 0)
        GameTooltip:Hide()
    end)
    r:SetScript("OnClick", function(s, button)
        if not s.entry then return end
        local rec = s.entry.rec
        if button == "RightButton" then
            if ns.UI and ns.UI.SearchInAH then ns.UI.SearchInAH(rec.id, KnownName(rec)) end
            return
        end
        if page == "auto" then
            -- 自动购买页左键 = 改这条的单价上限 / 移除, 不展开商人子行
            if ns.UI and ns.UI.EditAutoBuy then ns.UI.EditAutoBuy(rec.id, KnownName(rec), r) end
            return
        end
        if expanded[rec.id] then
            expanded[rec.id] = nil
        else
            expanded[rec.id] = true
        end
        ApplyQuery()
    end)

    -- 星标: 收藏 / 取消收藏。子按钮吃掉了鼠标事件, 所以不会顺带把行展开。
    r.star:SetScript("OnEnter", function()
        r.bg:SetColorTexture(1, 1, 1, r.open and 0.09 or 0.06)
        r.starText:SetTextColor(T.rgb(C.goldHi))
        local on = r.entry and M.IsFav(r.entry.rec.id)
        TooltipAtCursor(r.star)
        GameTooltip:ClearLines()
        GameTooltip:AddLine(on and "取消收藏" or "加入收藏", 1, 0.82, 0.35)
        GameTooltip:AddLine("|cff8a929e收藏的东西都在「我的收藏」页, 打开就等于先筛了一遍|r",
            0.62, 0.65, 0.70)
        GameTooltip:Show()
    end)
    r.star:SetScript("OnLeave", function()
        r.bg:SetColorTexture(1, 1, 1, r.open and 0.05 or 0)
        GameTooltip:Hide()
        PaintStar(r)
    end)
    r.star:SetScript("OnClick", function()
        if not r.entry then return end
        local rec = r.entry.rec
        local on = M.ToggleFav(rec.id)
        ns.Print(format(on and "|cffe8c25a★ 已收藏|r %s  |cff8a929e(/wgm 收藏 查看)|r"
            or "|cff8a929e已取消收藏|r %s", KnownName(rec)))
        -- 收藏页里取消收藏, 这一行就该消失; 货架页只要把星标刷成空心
        if page == "fav" then ApplyQuery() else Render() end
        RefreshCount()
        PaintTabs()
    end)
    return r
end

local function NewNpcRow()
    local r = CreateFrame("Button", nil, listContent)
    r:SetHeight(NPC_H)
    r:RegisterForClicks("LeftButtonUp")

    r.bg = r:CreateTexture(nil, "BACKGROUND")
    r.bg:SetAllPoints(true)
    r.bg:SetColorTexture(1, 1, 1, 0)

    -- 从属竖线: 让子行看得出挂在上面那个物品下面
    r.stem = r:CreateTexture(nil, "BACKGROUND")
    r.stem:SetColorTexture(1, 1, 1, 0.10)
    r.stem:SetWidth(1)
    r.stem:SetPoint("TOPLEFT", ROW_INDENT - 8, 0)
    r.stem:SetPoint("BOTTOMLEFT", ROW_INDENT - 8, 0)

    r.title = Font(r, F_NPC, C.text)
    r.title:SetPoint("LEFT", ROW_INDENT, 0)

    r.zone = Font(r, F_NPC, C.muted)

    r.fac = Font(r, F_NPC, C.faint)
    r.fac:SetWidth(30)
    r.fac:SetJustifyH("RIGHT")
    r.fac:SetPoint("RIGHT", r, "RIGHT", -6, 0)

    r:SetScript("OnEnter", function(s)
        s.bg:SetColorTexture(1, 1, 1, 0.05)
        if not s.entry then return end
        local npc = s.entry.npc
        local zone = M.ZoneName(npc.zone)
        TooltipAtCursor(s)
        GameTooltip:ClearLines()
        GameTooltip:AddLine(NpcName(npc), 1, 0.82, 0.35)
        GameTooltip:AddLine(zone and format("%s %s", zone, npc.coord) or "位置未知", 0.82, 0.84, 0.88)
        GameTooltip:AddLine(NPC_FACTION[npc.fac] or "中立", 0.62, 0.65, 0.70)
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine("|cff8a929e左键设置路径点 (装了 TomTom 直接标图)|r", 0.55, 0.58, 0.62)
        GameTooltip:Show()
    end)
    r:SetScript("OnLeave", function(s)
        s.bg:SetColorTexture(1, 1, 1, 0)
        GameTooltip:Hide()
    end)
    r:SetScript("OnClick", function(s, button)
        if button ~= "LeftButton" or not s.entry then return end
        local npc = s.entry.npc
        local zone = M.ZoneName(npc.zone) or "未知区域"
        local x, y = (npc.coord or ""):match("^([%d%.]+),([%d%.]+)$")
        local name = NpcName(npc)

        -- 快照里的坐标已经是地图百分比 (61.4 = 61.4%), 和 TomTom 收的同一单位,
        -- 不要再除 100 —— 除完点会跑到地图左上角
        local wx, wy = tonumber(x), tonumber(y)
        local marked = false
        if TomTom and TomTom.AddWaypoint and wx and wy and npc.zone and npc.zone > 0 then
            marked = pcall(function()
                TomTom:AddWaypoint(npc.zone, wx, wy, { title = name })
            end)
        end
        if marked then
            ns.Print(format("|cff29c7a8已标点|r %s · %s %s", name, zone, npc.coord))
        else
            -- /way 吃 0-100 的整数, 四舍五入到整格
            local cmd = "坐标未知"
            if wx and wy then
                cmd = format("/way %d %d", math.floor(wx + 0.5), math.floor(wy + 0.5))
            end
            ns.Print(format("%s |cff8a929e·|r %s %s |cff8a929e%s|r",
                name, zone, npc.coord, cmd))
        end
    end)
    return r
end

-- 取行一定要 Show(): 上一轮渲染结束时把没用到的行全 Hide() 了, 池子是循环使用的。
-- 少了这一句, 只要中途筛出过 0 条 (中文输入法打拼音就会), 之后所有行都保持隐藏 ——
-- 标题写着「筛出 7 种货」, 列表却一片空白。
local function GetItemRow()
    itemUsed = itemUsed + 1
    local r = itemPool[itemUsed]
    if not r then
        r = NewItemRow()
        itemPool[itemUsed] = r
    end
    r:Show()
    return r
end

local function GetNpcRow()
    npcUsed = npcUsed + 1
    local r = npcPool[npcUsed]
    if not r then
        r = NewNpcRow()
        npcPool[npcUsed] = r
    end
    r:Show()
    return r
end

--------------------------------------------------------------------------- 渲染

local function ContentWidth()
    return listContent:GetWidth() or (BASE_W - PAD * 2 - 8)
end

local function PlaceRow(r, y, w)
    r:ClearAllPoints()
    r:SetPoint("TOPLEFT", listContent, "TOPLEFT", 0, -y)
    r:SetWidth(w)
end

-- 星标: 实心金色 = 已收藏, 空心灰 = 没收藏
PaintStar = function(r)
    if not r.starText or not r.entry then return end
    local on = M.IsFav(r.entry.rec.id)
    r.starText:SetText(on and "★" or "☆")
    -- 没收藏的星用 muted 而不是 faint: 深色面板上 faint 太暗, 玩家看不出这儿能点
    r.starText:SetTextColor(T.rgb(on and C.gold or C.muted))
end

local function PaintItem(r, e, y, cw)
    local rec = e.rec
    r.entry = e
    r.open = expanded[rec.id] and true or false
    PlaceRow(r, y, cw)

    r.bg:SetColorTexture(1, 1, 1, r.open and 0.05 or 0)
    PaintStar(r)
    local isAuto = (page == "auto")
    r.caret:SetText((not isAuto and #rec.npcs > 0) and (r.open and "-" or "+") or "")
    r.icon:SetTexture(IconOf(rec))
    r.title:SetText(ItemName(rec, true))

    -- 右侧先摆价格, 再让「N 家 / 背包 N」贴在价格左边, 最后把剩下的宽度给名字
    r.price:ClearAllPoints()
    r.price:SetPoint("RIGHT", r, "RIGHT", -8, 0)
    r.cnt:ClearAllPoints()
    r.cnt:SetPoint("RIGHT", r.price, "LEFT", -6, 0)

    if isAuto then
        -- 自动购买页的「价格」是玩家设的单价上限, 右边挂背包数量而不是商人数
        local have = (ns.AutoBuy and ns.AutoBuy.Have and ns.AutoBuy.Have(rec.id)) or 0
        r.cnt:SetText(format("背包 %d", have))
        r.price:SetText((rec.autoP and rec.autoP > 0) and PriceText(rec.autoP)
            or "|cff8a929e无上限|r")
    else
        r.cnt:SetText(format("%d 家", #rec.npcs))
        local price = PriceOf(rec)
        r.price:SetText(price and PriceText(price) or "|cff8a929e无价|r")
    end

    -- 45 = 星标 14 + 展开符 + 图标 + 间隙; 剩下给名字 (再留 16 给「N 家」前的空)
    local titleW = cw - 45 - PRICE_W - CNT_W - 16
    if titleW < 80 then titleW = 80 end
    r.title:SetWidth(titleW)
end

local function PaintNpc(r, e, y, cw)
    local npc = e.npc
    r.entry = e
    PlaceRow(r, y, cw)

    local nameW = math.min(150, cw * 0.32)
    r.title:SetWidth(nameW)
    r.title:SetText(NpcName(npc))

    local zone = M.ZoneName(npc.zone)
    r.zone:ClearAllPoints()
    r.zone:SetPoint("LEFT", r.title, "RIGHT", 8, 0)
    r.zone:SetText(zone and format("%s %s", zone, npc.coord ~= "" and npc.coord or "")
        or "位置未知")
    r.zone:SetWidth(math.max(60, cw - nameW - 34 - 40))

    r.fac:SetText(NPC_FACTION[npc.fac] or "中立")
    if npc.fac == "A" then
        r.fac:SetTextColor(0.45, 0.65, 1.0)
    elseif npc.fac == "H" then
        r.fac:SetTextColor(0.92, 0.42, 0.42)
    else
        r.fac:SetTextColor(T.rgb(C.faint))
    end
end

-- 二分找第一个「顶部还没滚过去」的行
local function FirstVisible(top)
    local lo, hi, ans = 1, view.n, 1
    while lo <= hi do
        local mid = math.floor((lo + hi) / 2)
        if view.off[mid] <= top then
            ans = mid
            lo = mid + 1
        else
            hi = mid - 1
        end
    end
    return ans
end

Render = function()
    if not (scroll and listContent) then return end
    itemUsed, npcUsed = 0, 0
    pendingName = 0

    local top = scroll:GetVerticalScroll() or 0
    local h = scroll:GetHeight() or 400
    local cw = ContentWidth()
    local i = FirstVisible(top)
    while i <= view.n do
        local y = view.off[i] - top
        if y > h then break end
        local e = view.entries[i]
        if e.npc then
            PaintNpc(GetNpcRow(), e, view.off[i], cw)
        else
            PaintItem(GetItemRow(), e, view.off[i], cw)
        end
        i = i + 1
    end

    for j = itemUsed + 1, #itemPool do itemPool[j]:Hide() end
    for j = npcUsed + 1, #npcPool do npcPool[j]:Hide() end

    if emptyText then
        local d = M.Index()
        local q = (searchEdit and searchEdit:GetText() or ""):gsub("^%s+", ""):gsub("%s+$", "")
        if d.err then
            emptyText:SetText(d.err)
        elseif q ~= "" then
            if page == "fav" then
                emptyText:SetText(format("收藏里没有「%s」 —— 清空搜索看看全部收藏", q))
            elseif page == "auto" then
                emptyText:SetText(format("自动购买里没有「%s」 —— 清空搜索看看全部", q))
            else
                emptyText:SetText(format("没找到「%s」 —— 试试英文名, 或输入商人名", q))
            end
        elseif page == "auto" then
            emptyText:SetText("还没有自动购买 —— 在材料行点「自动」设一个单价上限")
        elseif page == "fav" then
            -- 收藏页空着分两种: 一件都没收 / 收了但被「材料」筛掉了
            if M.FavCount() == 0 then
                emptyText:SetText("还没有收藏 —— 在货架上点每行开头的 ☆ 收进来")
            elseif M.onlyMats then
                emptyText:SetText("收藏里没有材料 —— 点「材料」切回全部")
            else
                emptyText:SetText("没有匹配的物品 —— 换个关键词试试")
            end
        elseif M.onlyMats then
            emptyText:SetText("这批货里没有材料 —— 点「材料」切回全部")
        else
            emptyText:SetText("没有匹配的物品 —— 换个关键词试试")
        end
        emptyText:SetShown(view.n == 0)
    end
    UpdateThumb()
end

RefreshCount = function()
    if not countText then return end
    if page == "auto" then
        local AB = ns.AutoBuy
        local total = (AB and AB.Count and AB.Count()) or 0
        if #filtered == total and AB and AB.Summary then
            countText:SetText(AB.Summary())       -- 开关/件数/间隔一眼看全
        elseif #filtered == 0 then
            countText:SetText(format("|cffeb6b6b筛出 0|r |cff8a929e/ %d 件自动购买|r", total))
        else
            countText:SetText(format("筛出 %d |cff8a929e/ %d 件自动购买|r", #filtered, total))
        end
        return
    end
    if page == "fav" then
        local total = M.FavCount()
        if total == 0 then
            countText:SetText("|cff8a929e一件都没收|r")
        elseif #filtered == total then
            countText:SetText(format("%d 件收藏", total))
        elseif #filtered == 0 then
            countText:SetText(format("|cffeb6b6b筛出 0|r |cff8a929e/ %d 件收藏|r", total))
        else
            countText:SetText(format("筛出 %d |cff8a929e/ %d 件收藏|r", #filtered, total))
        end
        return
    end

    local d = M.Index()
    local total = #d.items
    if #filtered == total then
        countText:SetText(format("%d 种货 · %d 位商人 · %d 条货架", total, d.npcCount, d.pairs))
    elseif #filtered == 0 then
        -- 0 条时把数字标红, 和列表里的空状态对上, 免得只看到「筛出」两个字
        countText:SetText(format("|cffeb6b6b筛出 0 种货|r |cff8a929e/ 共 %d|r", total))
    else
        countText:SetText(format("筛出 %d 种货 |cff8a929e/ 共 %d|r", #filtered, total))
    end
end

-- 页签高亮 + 收藏数量。收藏数量挂在页签上, 不点进去也知道收了几件。
PaintTabs = function()
    if shopTab then shopTab:SetActive(page == "shop") end
    if favTab then
        favTab:SetActive(page == "fav")
        favTab.text:SetText(format("收藏 %d", M.FavCount()))
    end
    if autoTab then
        autoTab:SetActive(page == "auto")
        autoTab.text:SetText(format("自动 %d",
            (ns.AutoBuy and ns.AutoBuy.Count and ns.AutoBuy.Count()) or 0))
    end
    if autoSetBtn then autoSetBtn:SetShown(page == "auto") end
    if footerHint then
        footerHint:SetText(page == "auto"
            and "左键改单价上限 / 移除 · 右键在拍卖行搜索 · 右上角「设置」改开关和间隔"
            or "★ 收藏 · 左键物品展开商人 · 左键商人设路径点 · 右键物品在拍卖行搜索")
    end
end

-- 切页: 换页时清掉搜索词 (从货架搜「瓶」切到收藏, 不该把关键词带过去),
-- 排序方式如果在新页不存在 (最近收藏), 退回买价。
SetPage = function(p)
    page = (p == "fav" or p == "auto") and p or "shop"
    -- 自动购买页进来就按「上限 ↓」排, 不然沿用上页的「最近收藏」会排不动
    if page == "auto" then sortMode = "price" end
    if page ~= "fav" and sortMode == "fav" then sortMode = "price" end
    if sortBtn then sortBtn.text:SetText(SortLabel(sortMode)) end
    PaintTabs()
    if searchEdit and (searchEdit:GetText() or "") ~= "" then
        searchEdit:ClearFocus()
        searchEdit:SetText("")      -- OnTextChanged 里会 ApplyQuery(true)
        return
    end
    ApplyQuery(true)
end

-- 重新算筛选 + 视图, 然后画
ApplyQuery = function(resetScroll)
    local q = searchEdit and searchEdit:GetText() or ""
    local base
    if page == "fav" then base = M.FavRecords()
    elseif page == "auto" then base = M.AutoRecords() end
    filtered = M.Sort(M.Filter(q, M.onlyMats, base), sortMode)
    view = M.BuildView(filtered, expanded)

    if listContent then
        listContent:SetHeight(math.max(1, view.height))
    end
    if scroll then
        if resetScroll then
            scroll:SetVerticalScroll(0)
        else
            -- 折叠/展开后总高变了, 原来的位置可能越界
            local m = ScrollMax()
            if (scroll:GetVerticalScroll() or 0) > m then scroll:SetVerticalScroll(m) end
        end
    end
    RefreshCount()
    Render()
end
-- 外部改了自动购买列表 / 收藏后调这个: 页签上的件数和当前页内容一起刷新
M.Refresh = function()
    if not frame then return end
    PaintTabs()
    ApplyQuery()
end

--------------------------------------------------------------------------- 界面

local function BuildTitle(parent)
    local title = T.Text(parent, F_TITLE, C.gold)
    title:SetPoint("TOPLEFT", parent, "TOPLEFT", PAD, TITLE_Y)
    title:SetText("商人货架")

    local close = T.CloseButton(parent, function() ns.MerchantUI.Hide() end)
    close:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -(PAD - 6), TITLE_Y - 4)

    -- 三个页签就是「三个页面」: 全部货架 / 我的收藏 / 自动购买。件数直接写在页签上。
    shopTab = NewChip(parent, 46, 18, "货架")
    shopTab:SetPoint("LEFT", title, "RIGHT", 10, 0)
    shopTab:SetScript("OnClick", function() SetPage("shop") end)

    favTab = NewChip(parent, 62, 18, "收藏 0")
    favTab:SetPoint("LEFT", shopTab, "RIGHT", 4, 0)
    favTab:SetScript("OnClick", function() SetPage("fav") end)

    autoTab = NewChip(parent, 68, 18, "自动 0")
    autoTab:SetPoint("LEFT", favTab, "RIGHT", 4, 0)
    autoTab:SetScript("OnClick", function() SetPage("auto") end)

    countText = T.Text(parent, F_TIP + 1, C.muted)
    countText:SetPoint("RIGHT", close, "LEFT", -10, 0)
    countText:SetWordWrap(false)
    countText:SetText("")

    -- 「设置」只在自动购买页出现: 开关和扫描间隔在那里改 (真花钱的功能, 别藏太深)
    autoSetBtn = NewChip(parent, 44, 16, "设置")
    autoSetBtn:SetPoint("RIGHT", countText, "LEFT", -8, 0)
    autoSetBtn:SetScript("OnClick", function()
        if ns.UI and ns.UI.AutoBuyConfig then ns.UI.AutoBuyConfig() end
    end)

    footerHint = T.Text(parent, F_TIP, C.faint)
    footerHint:SetPoint("BOTTOMLEFT", parent, "BOTTOMLEFT", PAD, 11)
    footerHint:SetText("★ 收藏 · 左键物品展开商人 · 左键商人设路径点 · 右键物品在拍卖行搜索")
    footerHint:SetWordWrap(false)
end

local function BuildSearch(parent)
    local boxW = 190
    local box = T.Glass(parent, boxW, SEARCH_H, "card")
    box:SetPoint("TOPLEFT", parent, "TOPLEFT", PAD, SEARCH_Y)
    box.bg:SetVertexColor(1, 1, 1, 0.06)
    box:EnableMouse(true)

    searchHint = T.Text(box, F_ITEM, C.faint)
    searchHint:SetPoint("LEFT", 9, 0)
    searchHint:SetText("搜索物品 / 商人")
    searchHint:SetWordWrap(false)

    local eb = CreateFrame("EditBox", nil, box)
    eb:SetPoint("LEFT", 8, 0)
    eb:SetPoint("RIGHT", -22, 0)
    eb:SetHeight(SEARCH_H - 6)
    eb:SetAutoFocus(false)
    eb:SetFont(T.FontFile(), F_ITEM, "")
    eb:SetTextColor(T.rgb(C.text))
    eb:SetScript("OnEscapePressed", function(s) s:ClearFocus() end)
    eb:SetScript("OnEnterPressed", function(s) s:ClearFocus() end)
    eb:SetScript("OnTextChanged", function(s)
        local t = s:GetText() or ""
        searchHint:SetShown(t == "")
        if clearBtn then clearBtn:SetShown(t ~= "") end
        ApplyQuery(true)
    end)
    searchEdit = eb

    clearBtn = T.IconButton(box, 16)
    clearBtn:SetPoint("RIGHT", -3, 0)
    for _, rot in ipairs({ 0.785398, -0.785398 }) do
        local t = clearBtn:CreateTexture(nil, "OVERLAY")
        t:SetTexture(T.WHITE)
        t:SetSize(7, 1.2)
        t:SetPoint("CENTER")
        t:SetRotation(rot)
        t:SetVertexColor(T.rgb(C.muted))
    end
    clearBtn:SetScript("OnClick", function()
        searchEdit:SetText("")
        searchEdit:ClearFocus()
    end)
    clearBtn:Hide()

    box:SetScript("OnMouseUp", function() searchEdit:SetFocus() end)

    -- 排序 / 筛选
    local x = PAD + boxW + 10
    sortBtn = NewChip(parent, 78, SEARCH_H, SortLabel(sortMode))
    sortBtn:SetPoint("TOPLEFT", parent, "TOPLEFT", x, SEARCH_Y)
    sortBtn:SetScript("OnClick", function()
        local modes = SortModes()
        local i = 1
        for k, v in ipairs(modes) do if v.key == sortMode then i = k end end
        i = i % #modes + 1
        sortMode = modes[i].key
        sortBtn.text:SetText(modes[i].label)
        ApplyQuery()
    end)

    filterBtn = NewChip(parent, 60, SEARCH_H, "全部")
    filterBtn:SetPoint("TOPLEFT", parent, "TOPLEFT", x + 86, SEARCH_Y)
    filterBtn:SetScript("OnClick", function()
        M.onlyMats = not M.onlyMats
        filterBtn.text:SetText(M.onlyMats and "材料" or "全部")
        filterBtn:SetActive(M.onlyMats)
        ApplyQuery(true)
    end)
end

local function BuildList(parent)
    scroll = CreateFrame("ScrollFrame", nil, parent)
    scroll:SetPoint("TOPLEFT", parent, "TOPLEFT", PAD, LIST_Y)
    scroll:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", -(PAD + 8), LIST_BOT)
    scroll:EnableMouseWheel(true)

    listContent = CreateFrame("Frame", nil, scroll)
    listContent:SetSize(BASE_W - PAD * 2 - 8, 1)
    scroll:SetScrollChild(listContent)

    scroll:SetScript("OnMouseWheel", function(_, delta) ScrollPixels(-(delta or 0) * SCROLL_STEP) end)
    scroll:SetScript("OnVerticalScroll", function() Render() end)
    scroll:SetScript("OnSizeChanged", function(self, w)
        if listContent then listContent:SetWidth(w) end
        Render()
    end)

    -- 空状态挂在列表区外面: listContent 的高度 = 视图总高, 筛不出货时只有 1px,
    -- 挂在里面会被 ScrollFrame 裁掉 —— 表现就是「页面一片空白, 却写着筛出 N 种货」
    emptyText = T.Text(parent, F_ITEM, C.muted)
    emptyText:SetPoint("CENTER", parent, "CENTER", -4, -16)
    emptyText:SetJustifyH("CENTER")
    emptyText:SetWordWrap(false)
    emptyText:SetText("没有匹配的物品 —— 换个关键词试试")
    emptyText:Hide()

    BuildScrollBar(parent)
end

function ns.MerchantUI.Build()
    if frame then return frame end

    local f = CreateFrame("Frame", "WOWGoldMakerMerchantFrame", UIParent)
    local pw, ph = PanelSize()
    f:SetSize(pw, ph)
    f:SetMovable(true)
    f:EnableMouse(true)
    f:SetClampedToScreen(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", function(s)
        s:StopMovingOrSizing()
        local point, _, relPoint, x, y = s:GetPoint(1)
        local db = ns.DB()
        if db and point then
            db.mpos = { point = point, relPoint = relPoint, x = math.floor(x), y = math.floor(y) }
        end
    end)
    tinsert(UISpecialFrames, f:GetName())
    frame = f
    ns.merchantFrame = f

    -- 和主面板同一层级, 否则会被 EllesmereUI (背包 / 快捷操作层) 盖住。
    -- 级别比主面板高 2, 免得两个窗口叠在一起时被主面板压住。
    local db = ns.DB()
    local STRATA_LEVEL = {
        BACKGROUND = 0, LOW = 1, MEDIUM = 1, HIGH = 200,
        DIALOG = 200, FULLSCREEN = 200, FULLSCREEN_DIALOG = 200, TOOLTIP = 200,
    }
    local strata = (db and db.strata) or "DIALOG"
    if not STRATA_LEVEL[strata] then strata = "DIALOG" end
    pcall(function()
        f:SetFrameStrata(strata)
        f:SetFrameLevel((STRATA_LEVEL[strata] or 200) + 2)
        f:SetToplevel(true)
    end)

    local k, cw, ch = ComputeLayout(pw, ph)
    contentW = cw
    content = CreateFrame("Frame", nil, f)
    content:SetPoint("CENTER", f, "CENTER", 0, 0)
    content:SetSize(cw, ch)
    content:SetScale(k)
    f.content = content

    local bg = f:CreateTexture(nil, "BACKGROUND", nil, -7)
    bg:SetAllPoints(true)
    bg:SetTexture(T.PATH .. "panel")
    pcall(function()
        bg:SetTextureSliceMargins(24, 24, 24, 24)
        bg:SetTextureSliceMode(Enum.UITextureSliceMode.Stretched)
    end)
    f.bg = bg

    local glow = T.Glow(f, 240 * k, C.teal, 0.06, "glow-soft")
    glow:SetPoint("CENTER", f, "TOPRIGHT", -pw * 0.25, -ph * 0.2)
    f.glow = glow

    local ok, err = pcall(function()
        BuildTitle(content)
        BuildSearch(content)
        BuildList(content)
    end)
    if not ok then
        ns.Print("|cffff5555商人货架构建失败:|r " .. tostring(err))
    end

    -- 位置: 第一次默认居中偏左 (主面板贴右边), 之后跟着拖动记
    local pos = db and db.mpos
    f:ClearAllPoints()
    if type(pos) == "table" and pos.point then
        f:SetPoint(pos.point, UIParent, pos.relPoint or pos.point, pos.x or 0, pos.y or 0)
    else
        f:SetPoint("CENTER", UIParent, "CENTER", -math.floor(pw * 0.25), 0)
    end

    f:SetScript("OnShow", function() ApplyQuery() end)

    -- 物品名字要等客户端数据回包, 回包前先用快照里的英文名。
    -- 只有「还有行没拿到本地化名」时才重画 (pendingName), 否则什么都不做。
    C_Timer.NewTicker(2, function()
        if frame and frame:IsShown() and pendingName > 0 then pcall(Render) end
    end)

    return f
end

--------------------------------------------------------------------------- 对外

-- p: 打开哪一页 ("shop" 全部货架 / "fav" 我的收藏 / "auto" 自动购买), 不传就留在当前页
function ns.MerchantUI.Show(p)
    if not frame then
        local ok, err = pcall(ns.MerchantUI.Build)
        if not ok then
            ns.Print("|cffff5555商人货架打不开:|r " .. tostring(err))
            return
        end
    end
    if p then
        page = (p == "fav" or p == "auto") and p or "shop"
        if page == "auto" then sortMode = "price" end
        if page ~= "fav" and sortMode == "fav" then sortMode = "price" end
    end
    frame:Show()
    pcall(function() frame:Raise() end)
    if sortBtn then sortBtn.text:SetText(SortLabel(sortMode)) end
    PaintTabs()
    -- 每次打开都是新的一次浏览: 上次的搜索词跟过去只会让人困惑
    -- (ShowFav 传了关键词的话会在下面重新填上)
    if searchEdit and (searchEdit:GetText() or "") ~= "" then searchEdit:SetText("") end
    ApplyQuery(true)
end

-- 我的收藏页。q 可选: /wgm 收藏 <词> 直接带关键词
function ns.MerchantUI.ShowFav(q)
    ns.MerchantUI.Show("fav")
    if q and q ~= "" and searchEdit then
        searchEdit:SetText(q)
        searchEdit:SetFocus()
        searchEdit:HighlightText()
    end
end

-- 自动购买列表页。q 可选: 打开时直接带关键词筛名字
function ns.MerchantUI.ShowAuto(q)
    ns.MerchantUI.Show("auto")
    if q and q ~= "" and searchEdit then
        searchEdit:SetText(q)
        searchEdit:SetFocus()
        searchEdit:HighlightText()
    end
end

function ns.MerchantUI.Hide()
    if frame then
        GameTooltip:Hide()
        frame:Hide()
    end
end

function ns.MerchantUI.Toggle()
    if frame and frame:IsShown() then
        ns.MerchantUI.Hide()
    else
        ns.MerchantUI.Show("shop")
    end
end

-- 打开并直接搜某个关键词 (给 /wgm 货架 <关键词> 用)
function ns.MerchantUI.Search(text)
    ns.MerchantUI.Show("shop")
    if searchEdit then
        searchEdit:SetText(text or "")
        searchEdit:SetFocus()
        searchEdit:HighlightText()
    end
end
