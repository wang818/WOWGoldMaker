---------------------------------------------------------------------------
-- WOWGoldMaker / FirstAid.lua
-- 急救专业: 可生产清单 + 所需材料。
--
-- 用法:
--   /wgm fa        完整清单 (按技能等级排序) + 材料汇总
--   /wgm fa mats   只看材料汇总
--
-- 数据来源 (三级回退):
--   1. C_TradeSkillUI (现代接口, 需打开急救专业窗口)
--   2. GetTradeSkill*  (旧式接口, 需打开急救专业窗口)
--   3. 内置配方表     (来自服端静态库, 共 32 条; 物品名称由游戏运行时按 ID 解析)
--      内置表的好处: 没学急救 / 没开窗口也能出清单, 且带技能等级。
---------------------------------------------------------------------------

local ADDON, ns = ...

local FA = {}
ns.FirstAid = FA

local GROUP_NAME = {
    Bandages = "绷带",
    Potions  = "治疗药水",
    Remedies = "药膏与解毒剂",
    Camping  = "营地用品",
}

--------------------------------------------------------------------------- 内置配方表

-- { spell=法术ID, item=产出物品ID, made=产量, req=所需技能, group=分类, mats={{材料ID,数量}} }
FA.BUILTIN = {
    { spell = 3275, item = 1251, made = 1, req = 1, group = "Bandages", mats = { { 2589, 1 } } },
    { spell = 1244431, item = 118, made = 1, req = 1, group = "Potions", mats = { { 3371, 1 }, { 2678, 1 }, { 2447, 1 } } },
    { spell = 1230117, item = 279968, made = 1, req = 20, group = "Camping", mats = { { 1251, 3 }, { 159, 1 } } },
    { spell = 3276, item = 2581, made = 1, req = 40, group = "Bandages", mats = { { 2589, 2 } } },
    { spell = 1244432, item = 858, made = 1, req = 55, group = "Potions", mats = { { 3371, 1 }, { 2678, 2 }, { 2450, 1 } } },
    { spell = 3277, item = 3530, made = 1, req = 80, group = "Bandages", mats = { { 2592, 1 } } },
    { spell = 7934, item = 6452, made = 3, req = 80, group = "Remedies", mats = { { 1475, 1 } } },
    { spell = 1259342, item = 255716, made = 3, req = 90, group = "Remedies", mats = { { 3174, 1 }, { 2678, 1 }, { 2723, 1 } } },
    { spell = 1244433, item = 929, made = 1, req = 110, group = "Potions", mats = { { 3372, 1 }, { 2692, 1 }, { 2453, 1 } } },
    { spell = 3278, item = 3531, made = 1, req = 115, group = "Bandages", mats = { { 2592, 2 } } },
    { spell = 1259347, item = 255720, made = 1, req = 120, group = "Remedies", mats = { { 2592, 2 }, { 2321, 2 } } },
    { spell = 7935, item = 6453, made = 3, req = 130, group = "Remedies", mats = { { 1288, 1 } } },
    { spell = 1259343, item = 255717, made = 3, req = 140, group = "Remedies", mats = { { 1468, 1 }, { 3713, 1 }, { 2686, 1 } } },
    { spell = 1262996, item = 279940, made = 1, req = 140, group = "Camping", mats = { { 6452, 1 }, { 8544, 2 }, { 4470, 2 } } },
    { spell = 7928, item = 6450, made = 1, req = 150, group = "Bandages", mats = { { 4306, 1 } } },
    { spell = 1244434, item = 1710, made = 1, req = 155, group = "Potions", mats = { { 3372, 1 }, { 2692, 3 }, { 3357, 1 } } },
    { spell = 7929, item = 6451, made = 1, req = 180, group = "Bandages", mats = { { 4306, 2 } } },
    { spell = 1259348, item = 255721, made = 1, req = 200, group = "Remedies", mats = { { 4304, 2 }, { 4291, 2 } } },
    { spell = 10840, item = 8544, made = 1, req = 210, group = "Bandages", mats = { { 4338, 1 } } },
    { spell = 1259344, item = 255718, made = 3, req = 210, group = "Remedies", mats = { { 7070, 1 }, { 2692, 1 }, { 2596, 1 } } },
    { spell = 1244435, item = 3928, made = 1, req = 215, group = "Potions", mats = { { 8925, 1 }, { 3713, 1 }, { 8838, 1 } } },
    { spell = 1259341, item = 255715, made = 3, req = 215, group = "Remedies", mats = { { 255645, 1 } } },
    { spell = 10841, item = 8545, made = 1, req = 240, group = "Bandages", mats = { { 4338, 2 } } },
    { spell = 18629, item = 14529, made = 1, req = 260, group = "Bandages", mats = { { 14047, 1 } } },
    { spell = 1259349, item = 255722, made = 1, req = 265, group = "Remedies", mats = { { 8170, 2 }, { 14047, 2 }, { 8343, 2 } } },
    { spell = 1244436, item = 13446, made = 1, req = 275, group = "Potions", mats = { { 8925, 1 }, { 3713, 3 }, { 13464, 1 } } },
    { spell = 1259345, item = 255719, made = 3, req = 280, group = "Remedies", mats = { { 7080, 1 }, { 2692, 1 }, { 2594, 1 } } },
    { spell = 18630, item = 14530, made = 1, req = 290, group = "Bandages", mats = { { 14047, 2 } } },
    { spell = 23787, item = 19440, made = 3, req = 300, group = "Remedies", mats = { { 19441, 1 } } },
    { spell = 30021, item = 23684, made = 4, req = 300, group = "Bandages", mats = { { 23567, 1 }, { 14047, 10 } } },
    { spell = 470349, item = 232433, made = 1, req = 300, group = "Bandages", mats = { { 14530, 2 } } },
    { spell = 1263001, item = 279951, made = 1, req = 300, group = "Camping", mats = { { 4470, 2 }, { 6453, 2 }, { 14530, 5 } } },
}

--------------------------------------------------------------------------- 工具

local missingNames = {}

local function itemName(id)
    if not id then return "?" end
    local name
    if C_Item and C_Item.GetItemNameByID then
        local ok, v = pcall(C_Item.GetItemNameByID, id)
        if ok then name = v end
    end
    if not name and GetItemInfo then
        local ok, v = pcall(GetItemInfo, id)
        if ok then name = v end
    end
    if not name then
        if C_Item and C_Item.RequestLoadItemDataByID then
            pcall(C_Item.RequestLoadItemDataByID, id)
        elseif GetItemInfo then
            pcall(function() return GetItemInfo(id) end)
        end
        missingNames[id] = true
        return "物品#" .. id
    end
    return name
end

-- 名称含 "物品#" 说明客户端还没缓存, 需要稍后重扫
local function anyNameMissing()
    return next(missingNames) ~= nil
end

local function say(msg) ns.Print(msg) end

local function fmtMats(mats)
    local parts = {}
    for _, m in ipairs(mats) do
        parts[#parts + 1] = format("%s×%d", m.name, m.count)
    end
    return table.concat(parts, "、")
end

local function summarize(recipes)
    local agg, order = {}, {}
    for _, r in ipairs(recipes) do
        for _, m in ipairs(r.mats) do
            local key = m.id and ("i" .. m.id) or ("n" .. m.name)
            if not agg[key] then
                agg[key] = { name = m.name, count = 0 }
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

--------------------------------------------------------------------------- 数据源

-- 内置表 → 统一结构
local function scanBuiltin()
    local out = {}
    for _, row in ipairs(FA.BUILTIN) do
        local entry = {
            name = itemName(row.item), item = row.item, made = row.made or 1,
            req = row.req, group = row.group, mats = {},
        }
        for _, m in ipairs(row.mats) do
            entry.mats[#entry.mats + 1] = { name = itemName(m[1]), count = m[2], id = m[1] }
        end
        out[#out + 1] = entry
    end
    return out
end

-- 现代接口: 需要在当前打开的急救专业窗口下调用
local function scanModern()
    local api = C_TradeSkillUI
    if not (api and api.GetAllRecipeIDs) then return nil end
    local ok, ids = pcall(api.GetAllRecipeIDs)
    if not ok or type(ids) ~= "table" or #ids == 0 then return nil end

    local out = {}
    for _, recipeID in ipairs(ids) do
        local okI, info = pcall(api.GetRecipeInfo, recipeID)
        if okI and type(info) == "table" and info.name then
            local entry = { name = info.name, recipeID = recipeID, made = 1, mats = {} }
            if api.GetRecipeNumItemsProduced then
                local okN, lo = pcall(api.GetRecipeNumItemsProduced, recipeID)
                if okN and type(lo) == "number" then entry.made = lo end
            end
            if api.GetRecipeSchematic then
                local okS, sch = pcall(api.GetRecipeSchematic, recipeID, false)
                if okS and type(sch) == "table" and type(sch.reagentSlotSchematics) == "table" then
                    for _, slot in ipairs(sch.reagentSlotSchematics) do
                        local r = type(slot.reagents) == "table" and slot.reagents[1] or nil
                        if r then
                            entry.mats[#entry.mats + 1] = {
                                name = itemName(r.id), count = r.quantityRequired or 1, id = r.id,
                            }
                        end
                    end
                end
            end
            out[#out + 1] = entry
        end
    end
    if #out == 0 then return nil end
    return out
end

-- 旧式接口
local function scanLegacy()
    if not (GetNumTradeSkills and GetTradeSkillInfo) then return nil end
    local okN, n = pcall(GetNumTradeSkills)
    if not okN or type(n) ~= "number" or n == 0 then return nil end

    local out = {}
    for i = 1, n do
        local okI, name, subType = pcall(GetTradeSkillInfo, i)
        if okI and type(name) == "string" and subType ~= "header" then
            local entry = { name = name, index = i, made = 1, mats = {} }
            if GetTradeSkillNumMade then
                local okM, lo = pcall(GetTradeSkillNumMade, i)
                if okM and type(lo) == "number" then entry.made = lo end
            end
            if GetTradeSkillNumReagents and GetTradeSkillReagentInfo then
                local okC, cnt = pcall(GetTradeSkillNumReagents, i)
                if okC and type(cnt) == "number" then
                    for r = 1, cnt do
                        local okR, rname, _, need = pcall(GetTradeSkillReagentInfo, i, r)
                        if okR and rname then
                            entry.mats[#entry.mats + 1] = { name = rname, count = need or 1 }
                        end
                    end
                end
            end
            out[#out + 1] = entry
        end
    end
    if #out == 0 then return nil end
    return out
end

--------------------------------------------------------------------------- 对外接口

-- 返回 recipes, 数据来源标识
function FA.Scan()
    missingNames = {}

    local recipes = scanModern() or scanLegacy()
    local source = recipes and "游戏窗口" or nil

    if not recipes then
        recipes = scanBuiltin()
        source = "内置配方表"
    end

    -- 有技能等级的 (内置表) 按等级排序, 否则按名称
    local hasReq = recipes[1] and recipes[1].req ~= nil
    if hasReq then
        table.sort(recipes, function(a, b)
            local ra, rb = a.req or 0, b.req or 0
            if ra ~= rb then return ra < rb end
            return a.name < b.name
        end)
    else
        table.sort(recipes, function(a, b) return tostring(a.name) < tostring(b.name) end)
    end

    local db = ns.DB()
    db.firstAid = db.firstAid or {}
    db.firstAid.scannedAt = date("%Y-%m-%d %H:%M:%S")
    db.firstAid.source = source
    db.firstAid.recipes = recipes
    db.firstAid.materials = summarize(recipes)

    return recipes, source
end

function FA.Report(mode)
    local recipes, source = FA.Scan()
    if not recipes then return end

    local mats = summarize(recipes)

    if mode ~= "mats" then
        say(format("|cffe8c25a[急救清单]|r %d 条配方 · 来源: %s", #recipes, source))
        for i, r in ipairs(recipes) do
            local tag = r.group and format("|cff6f7783%s|r ", GROUP_NAME[r.group] or r.group) or ""
            local made = (r.made and r.made > 1) and format(" ×%d", r.made) or ""
            local req = r.req and format(" |cff9d9d9d[%d]|r", r.req) or ""
            print(format("   %2d. %s%s%s%s  |cff6f7783←|r %s",
                i, tag, r.name, made, req, #r.mats > 0 and fmtMats(r.mats) or "无材料"))
        end
    end

    say(format("|cffe8c25a[材料汇总]|r %d 种", #mats))
    for _, m in ipairs(mats) do
        print(format("   %s ×|cffffffff%d|r", m.name, m.count))
    end

    if anyNameMissing() then
        say("|cffff9955部分物品名客户端还没缓存。|r等 2 秒再执行一次 |cffe8c25a/wgm fa|r 即可显示真实名称。")
    end
    say("|cff6f7783已存入 WOWGoldMakerDB.firstAid, 可离线导出。|r")
end
