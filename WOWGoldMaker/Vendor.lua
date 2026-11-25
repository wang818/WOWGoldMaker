---------------------------------------------------------------------------
-- WOWGoldMaker / Vendor.lua
-- 商人货架扫描: 打开商人时, 把「他卖什么、多少钱」记下来。
--
-- 为什么需要这个: 客户端的离线数据里没有「哪个 NPC 卖多少钱」的查询接口,
-- 只有打开商人界面时 C_MerchantFrame.GetItemInfo(i).price 才给实时价。
-- 所以:
--   * 没逛过商人 → 用 VendorData.lua 的静态快照 (HandyNotes 整理的那份)
--   * 逛到了商人 → 用真实货架价覆盖 (服务器改过价也能跟上)
--
-- 只记本插件关心的物品 (配方产物 + 材料)。商人动辄几十上百条货,
-- 全记下来 SavedVariables 会被撑大, 而且对算成本没用。
---------------------------------------------------------------------------

local ADDON, ns = ...

local format = string.format

local V = {}
ns.Vendor = V

--------------------------------------------------------------------------- 关心的物品

local wanted

-- 配方产物 + 全部材料。ProfData 是静态表, 一次遍历建好缓存即可。
local function BuildWanted()
    wanted = {}
    local data = ns.ProfData
    if type(data) ~= "table" then return wanted end
    for _, list in pairs(data) do
        if type(list) == "table" then
            for _, rec in ipairs(list) do
                if type(rec.item) == "number" then wanted[rec.item] = true end
                local mats = rec.mats
                if type(mats) == "table" then
                    for _, m in ipairs(mats) do
                        if type(m[1]) == "number" then wanted[m[1]] = true end
                    end
                end
            end
        end
    end
    return wanted
end

function V.Wanted(id)
    if not wanted then wanted = BuildWanted() end
    return wanted[id] == true
end

--------------------------------------------------------------------------- 扫描

local function SeenTable(create)
    local db = ns.DB and ns.DB()
    if type(db) ~= "table" then return nil end
    if type(db.vendorSeen) ~= "table" then
        if not create then return nil end
        db.vendorSeen = {}
    end
    return db.vendorSeen
end

-- 读当前打开商人的整张货架, 把关心的物品价记进 db.vendorSeen。
-- 返回本次「记下来的条数」(没开商人 / 没有接口时是 0)。
function V.Scan()
    local seen = SeenTable(true)
    if not seen then return 0 end
    if type(GetMerchantNumItems) ~= "function" then return 0 end

    local ok, n = pcall(GetMerchantNumItems)
    if not ok or type(n) ~= "number" or n <= 0 then return 0 end

    local count = 0
    for i = 1, n do
        local id
        if type(GetMerchantItemID) == "function" then
            local okID, v = pcall(GetMerchantItemID, i)
            if okID then id = v end
        end
        if type(id) == "number" and id > 0 and V.Wanted(id) then
            local info
            if C_MerchantFrame and type(C_MerchantFrame.GetItemInfo) == "function" then
                local okInfo, v = pcall(C_MerchantFrame.GetItemInfo, i)
                if okInfo then info = v end
            end
            local price = info and info.price
            if type(price) == "number" and price > 0 then
                -- 有的条目按整捆卖 (stackCount > 1), 价目表里记的是单价
                local stack = info.stackCount
                if type(stack) ~= "number" or stack < 1 then stack = 1 end
                local unit = math.floor(price / stack + 0.5)
                if unit > 0 then
                    seen[id] = unit
                    count = count + 1
                end
            end
        end
    end
    return count
end

-- 当前商人货架上有多少件是我们关心的 (只读, 不写存档) —— 给 /wgm vendor 用
function V.Inspect()
    local out = { rows = {} }
    if type(GetMerchantNumItems) ~= "function" then return out end
    local ok, n = pcall(GetMerchantNumItems)
    if not ok or type(n) ~= "number" then return out end

    out.total = n
    for i = 1, n do
        local id
        if type(GetMerchantItemID) == "function" then
            local okID, v = pcall(GetMerchantItemID, i)
            if okID then id = v end
        end
        if type(id) == "number" and id > 0 and V.Wanted(id) then
            local info
            if C_MerchantFrame and type(C_MerchantFrame.GetItemInfo) == "function" then
                local okInfo, v = pcall(C_MerchantFrame.GetItemInfo, i)
                if okInfo then info = v end
            end
            local price = info and info.price
            if type(price) == "number" and price > 0 then
                local stack = info.stackCount
                if type(stack) ~= "number" or stack < 1 then stack = 1 end
                out.rows[#out.rows + 1] = {
                    id = id,
                    price = math.floor(price / stack + 0.5),
                    stack = stack,
                    name = info.name,
                }
            end
        end
    end
    return out
end

--------------------------------------------------------------------------- 统计 / 清理

function V.SeenCount()
    local t = SeenTable(false)
    local n = 0
    if t then for _ in pairs(t) do n = n + 1 end end
    return n
end

function V.TableCount()
    local t = ns.VendorPrice
    local n = 0
    if type(t) == "table" then for _ in pairs(t) do n = n + 1 end end
    return n
end

function V.ClearSeen()
    local t = SeenTable(false)
    local n = 0
    if t then
        for k in pairs(t) do t[k] = nil; n = n + 1 end
    end
    return n
end

--------------------------------------------------------------------------- 报告 (/wgm vendor)

local function Money(c)
    if ns.NPC and ns.NPC.Money then return ns.NPC.Money(c) end
    return tostring(c)
end

function V.Report()
    ns.Print(format("商人价: 离线价目表 %d 条, 货架实测 %d 条。",
        V.TableCount(), V.SeenCount()))

    local info = V.Inspect()
    if not info.total or info.total <= 0 then
        ns.Print("当前没打开商人。打开任意商人, 货架价会自动记下来。")
    else
        local rows = info.rows
        ns.Print(format("当前商人共 %d 件货, 其中本插件关心的 %d 件:", info.total, #rows))
        if #rows == 0 then
            print("  |cff888888没有配方用得上的东西|r")
        else
            for _, r in ipairs(rows) do
                local name = r.name or ("物品 #" .. r.id)
                local extra = r.stack > 1 and format(" (一捆 %d 个)", r.stack) or ""
                print(format("  %s|cff888888#%d|r %s%s",
                    "|cffe8c25a·|r", r.id, name, extra .. "  " .. Money(r.price)))
            end
        end
    end

    ns.Print("用法: /wgm vendor 看报告 | /wgm vendor scan 手动扫一次 | /wgm vendor clear 清掉实测价")
end
