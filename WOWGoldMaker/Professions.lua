---------------------------------------------------------------------------
-- WOWGoldMaker / Professions.lua
-- 专业模块: 专业注册表 + 配方查询 + 材料汇总。
--
-- 数据来自 ProfData.lua (由 tools/gen_prof_data.js 从服端静态库生成),
-- 因此不需要打开专业窗口、也不要求已学会 —— 显示的是该专业"全部可生产"内容。
--
-- 加一个新专业只需要两步:
--   1. tools/gen_prof_data.js 的 WANTED 里加上专业 key, 重新生成 ProfData.lua
--   2. 在下面 P.LIST 里加一行
---------------------------------------------------------------------------

local ADDON, ns = ...

local P = {}
ns.Prof = P

--------------------------------------------------------------------------- 专业注册表

P.LIST = {
    {
        key    = "first-aid",
        name   = "急救",
        icon   = "Interface\\Icons\\Trade_FirstAid",
        note   = "绷带 · 药膏 · 解毒",
    },
    {
        key    = "cooking",
        name   = "烹饪",
        icon   = "Interface\\Icons\\Trade_Cooking",
        note   = "食物 · 饮料 · 增益",
    },
}

P.byKey = {}
for _, p in ipairs(P.LIST) do
    P.byKey[p.key] = p
end

-- 分类中文名 (各专业共用, 未收录的直接显示原 key)
local GROUP_NAME = {
    -- 急救
    Bandages = "绷带", Potions = "治疗药水", Remedies = "药膏与解毒剂", Camping = "营地用品",
    -- 烹饪
    Camp = "营地", Strength = "力量", Agility = "敏捷", Caster = "法系",
    Stamina = "耐力", Spirit = "精神", Plain = "仅生命与法力", ["Other buffs"] = "其他增益",
}

function P.GroupName(key)
    return GROUP_NAME[key] or tostring(key or "")
end

--------------------------------------------------------------------------- 物品名

-- 客户端物品名是懒加载的, 缓存成功解析过的结果, 失败的每次重试
local nameCache = {}
local missing = {}

local function itemName(id)
    if not id then return "?" end
    local hit = nameCache[id]
    if hit then return hit end

    local name
    if C_Item and C_Item.GetItemNameByID then
        local ok, v = pcall(C_Item.GetItemNameByID, id)
        if ok then name = v end
    end
    if not name and GetItemInfo then
        local ok, v = pcall(GetItemInfo, id)
        if ok then name = v end
    end

    if name then
        nameCache[id] = name
        missing[id] = nil
        return name
    end

    -- 没缓存: 发一次请求, 本次先显示占位
    missing[id] = true
    if C_Item and C_Item.RequestLoadItemDataByID then
        pcall(C_Item.RequestLoadItemDataByID, id)
    elseif GetItemInfo then
        pcall(GetItemInfo, id)
    end
    return "物品#" .. id
end

function P.AnyNameMissing()
    return next(missing) ~= nil
end

--------------------------------------------------------------------------- 查询

-- 返回该专业的配方列表 (带名称, 按最低技能升序)
-- 每次都重新解析名称, 因为首次调用后客户端才陆续回包
function P.Get(key)
    local data = ns.ProfData and ns.ProfData[key]
    if not data then return nil end

    local list = {}
    for i = 1, #data do
        local row = data[i]
        local mats = {}
        for j = 1, #row.mats do
            local m = row.mats[j]
            mats[j] = { name = itemName(m[1]), count = m[2], id = m[1] }
        end
        list[i] = {
            name  = itemName(row.item),
            item  = row.item,
            made  = row.made or 1,
            req   = row.req or 0,
            group = row.group,
            mats  = mats,
        }
    end

    table.sort(list, function(a, b)
        if a.req ~= b.req then return a.req < b.req end
        if a.name ~= b.name then return a.name < b.name end
        return false
    end)
    return list
end

-- 材料汇总: 把整个专业的材料按总用量降序聚合
function P.Summarize(recipes)
    if not recipes then return {} end
    local agg, order = {}, {}
    for i = 1, #recipes do
        local mats = recipes[i].mats
        for j = 1, #mats do
            local m = mats[j]
            local key = m.id and ("i" .. m.id) or ("n" .. m.name)
            if not agg[key] then
                agg[key] = { name = m.name, count = 0, id = m.id }
                order[#order + 1] = key
            end
            agg[key].count = agg[key].count + m.count
        end
    end

    local list = {}
    for _, k in ipairs(order) do list[#list + 1] = agg[k] end
    table.sort(list, function(a, b)
        if a.count ~= b.count then return a.count > b.count end
        return a.name < b.name
    end)
    return list
end

-- 单个配方的材料拼成一行文本 (带色码, 供列表行显示)
function P.MatsLine(mats)
    if not mats or #mats == 0 then return "|cff6f7783无材料|r" end
    local parts = {}
    for i = 1, #mats do
        local m = mats[i]
        parts[i] = format("%s|cffffffff×%d|r", m.name, m.count)
    end
    return table.concat(parts, "  ")
end

--------------------------------------------------------------------------- 聊天输出

-- /wgm fa 之类的兼容入口
function P.Report(key, mode)
    local prof = P.byKey[key]
    if not prof then
        ns.Print("|cffff5555未知专业:|r " .. tostring(key))
        return
    end

    local recipes = P.Get(key)
    if not recipes or #recipes == 0 then
        ns.Print("|cffff5555" .. prof.name .. " 没有数据|r (检查 ProfData.lua)")
        return
    end

    if mode ~= "mats" then
        ns.Print(format("|cffe8c25a[%s]|r %d 条可生产配方", prof.name, #recipes))
        local lastGroup
        for i = 1, #recipes do
            local r = recipes[i]
            if r.group ~= lastGroup then
                lastGroup = r.group
                print("  |cffe8c25a" .. P.GroupName(r.group) .. "|r")
            end
            local made = r.made > 1 and format(" ×%d", r.made) or ""
            print(format("   %2d. %s%s |cff9d9d9d[%d]|r  |cff6f7783←|r %s",
                i, r.name, made, r.req, P.MatsLine(r.mats)))
        end
    end

    local mats = P.Summarize(recipes)
    ns.Print(format("|cffe8c25a[材料汇总]|r %d 种", #mats))
    for i = 1, #mats do
        print(format("   %s ×|cffffffff%d|r", mats[i].name, mats[i].count))
    end

    if P.AnyNameMissing() then
        ns.Print("|cffff9955部分物品名客户端还没缓存|r, 等 2 秒再执行一次即可显示真实名称。")
    end
end

--------------------------------------------------------------------------- 名称预热

-- 登录后把所有专业配方涉及的物品都请求一遍, 避免首次打开列表满屏 "物品#ID"
function P.Prewarm()
    local ids, n = {}, 0
    local data = ns.ProfData
    if not data then return 0 end
    for _, rows in pairs(data) do
        for i = 1, #rows do
            local row = rows[i]
            ids[row.item] = true
            for j = 1, #row.mats do ids[row.mats[j][1]] = true end
        end
    end
    for id in pairs(ids) do
        n = n + 1
        if C_Item and C_Item.RequestLoadItemDataByID then
            pcall(C_Item.RequestLoadItemDataByID, id)
        end
        if GetItemInfo then pcall(GetItemInfo, id) end
    end
    return n
end

-- 登录后预热两次: 第一次发请求, 第二次捞已回包的数据
do
    local boot = CreateFrame("Frame")
    boot:RegisterEvent("PLAYER_ENTERING_WORLD")
    boot:SetScript("OnEvent", function(self)
        self:UnregisterEvent("PLAYER_ENTERING_WORLD")
        C_Timer.After(1, function() pcall(P.Prewarm) end)
        C_Timer.After(6, function() pcall(P.Prewarm) end)
    end)
end
