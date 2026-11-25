---------------------------------------------------------------------------
-- WOWGoldMaker / VendorData.lua
-- NPC 商人价目表 (离线快照)。由 tools/gen_vendor_data.js 生成, 不要手改。
-- 来源: 客户端 Interface/AddOns/HandyNotes_NPCs (Classic)/forever 的
--       vendorData (谁卖什么) + itemData (商人买价)。
--
-- 只收了本插件配方会用到的物品 —— 全库有 829 个商人卖 1600+ 种货,
-- 其中属于我们材料/产物的就下面这些; 剩下的材料 (布、草、矿) 商人根本不卖,
-- 只能去拍卖行。
--
-- 值是商人买价 (铜/个)。游戏里打开商人时还会用真实货架价覆盖
-- (db.vendorSeen), 这里只是「没逛过商人时也能算成本」的兜底。
---------------------------------------------------------------------------

local ADDON, ns = ...

-- 物品ID -> 商人买价 (铜/个)
ns.VendorPrice = {
    [159] = 25,    -- Refreshing Spring Water, 169 个商人有售
    [765] = 40,    -- Silverleaf, 3 个商人有售
    [785] = 80,    -- Mageroyal, 8 个商人有售
    [787] = 25,    -- Slitherskin Mackerel, 21 个商人有售
    [858] = 100,    -- Lesser Healing Potion, 6 个商人有售
    [929] = 300,    -- Healing Potion, 12 个商人有售
    [1179] = 125,   -- Ice Cold Milk, 131 个商人有售
    [1205] = 500,   -- Melon Juice, 138 个商人有售
    [1645] = 2000,   -- Moonberry Juice, 128 个商人有售
    [1708] = 1000,   -- Sweet Nectar, 128 个商人有售
    [1710] = 500,   -- Greater Healing Potion, 6 个商人有售
    [2321] = 100,   -- Fine Thread, 87 个商人有售
    [2447] = 40,   -- Peacebloom, 3 个商人有售
    [2449] = 80,   -- Earthroot, 8 个商人有售
    [2453] = 100,   -- Bruiseweed, 8 个商人有售
    [2455] = 40,   -- Minor Mana Potion, 2 个商人有售
    [2594] = 1500,   -- Flagon of Dwarven Honeymead, 16 个商人有售
    [2596] = 120,   -- Skin of Dwarven Stout, 15 个商人有售
    [2678] = 10,   -- Mild Spices, 63 个商人有售
    [2686] = 50,   -- Thunder Ale, 3 个商人有售
    [2692] = 40,   -- Hot Spices, 55 个商人有售
    [2723] = 50,   -- Bottle of Dalaran Noir, 15 个商人有售
    [2894] = 50,   -- Rhapsody Malt, 3 个商人有售
    [3355] = 200,   -- Wild Steelbloom, 6 个商人有售
    [3356] = 120,   -- Kingsblood, 6 个商人有售
    [3357] = 300,   -- Liferoot, 6 个商人有售
    [3371] = 20,   -- Empty Vial, 98 个商人有售
    [3372] = 200,   -- Leaded Vial, 86 个商人有售
    [3385] = 120,   -- Lesser Mana Potion, 7 个商人有售
    [3713] = 160,   -- Soothing Spices, 47 个商人有售
    [3827] = 480,   -- Mana Potion, 6 个商人有售
    [3928] = 1000,   -- Superior Healing Potion, 6 个商人有售
    [4291] = 500,   -- Silken Thread, 79 个商人有售
    [4342] = 2500,   -- Purple Dye, 71 个商人有售
    [4470] = 38,   -- Simple Wood, 62 个商人有售
    [4536] = 25,   -- Shiny Red Apple, 13 个商人有售
    [4592] = 20,   -- Longjaw Mud Snapper, 21 个商人有售
    [4593] = 500,   -- Bristle Whisker Catfish, 21 个商人有售
    [4594] = 1000,   -- Rockscale Cod, 21 个商人有售
    [6149] = 480,   -- Greater Mana Potion, 6 个商人有售
    [8343] = 2000,   -- Heavy Silken Thread, 71 个商人有售
    [8766] = 4000,   -- Morning Glory Dew, 108 个商人有售
    [8925] = 2500,   -- Crystal Vial, 74 个商人有售
    [8957] = 4000,   -- Spinefin Halibut, 21 个商人有售
    [11291] = 4500,  -- Star Wood, 8 个商人有售
    [18256] = 30000,  -- Imbued Vial, 27 个商人有售
}

-- 物品ID -> 卖这件的商人数 (提示里显示「N 个商人有售」用)
ns.VendorNPCs = {
    [159] = 169,    -- Refreshing Spring Water
    [765] = 3,    -- Silverleaf
    [785] = 8,    -- Mageroyal
    [787] = 21,    -- Slitherskin Mackerel
    [858] = 6,    -- Lesser Healing Potion
    [929] = 12,    -- Healing Potion
    [1179] = 131,   -- Ice Cold Milk
    [1205] = 138,   -- Melon Juice
    [1645] = 128,   -- Moonberry Juice
    [1708] = 128,   -- Sweet Nectar
    [1710] = 6,   -- Greater Healing Potion
    [2321] = 87,   -- Fine Thread
    [2447] = 3,   -- Peacebloom
    [2449] = 8,   -- Earthroot
    [2453] = 8,   -- Bruiseweed
    [2455] = 2,   -- Minor Mana Potion
    [2594] = 16,   -- Flagon of Dwarven Honeymead
    [2596] = 15,   -- Skin of Dwarven Stout
    [2678] = 63,   -- Mild Spices
    [2686] = 3,   -- Thunder Ale
    [2692] = 55,   -- Hot Spices
    [2723] = 15,   -- Bottle of Dalaran Noir
    [2894] = 3,   -- Rhapsody Malt
    [3355] = 6,   -- Wild Steelbloom
    [3356] = 6,   -- Kingsblood
    [3357] = 6,   -- Liferoot
    [3371] = 98,   -- Empty Vial
    [3372] = 86,   -- Leaded Vial
    [3385] = 7,   -- Lesser Mana Potion
    [3713] = 47,   -- Soothing Spices
    [3827] = 6,   -- Mana Potion
    [3928] = 6,   -- Superior Healing Potion
    [4291] = 79,   -- Silken Thread
    [4342] = 71,   -- Purple Dye
    [4470] = 62,   -- Simple Wood
    [4536] = 13,   -- Shiny Red Apple
    [4592] = 21,   -- Longjaw Mud Snapper
    [4593] = 21,   -- Bristle Whisker Catfish
    [4594] = 21,   -- Rockscale Cod
    [6149] = 6,   -- Greater Mana Potion
    [8343] = 71,   -- Heavy Silken Thread
    [8766] = 108,   -- Morning Glory Dew
    [8925] = 74,   -- Crystal Vial
    [8957] = 21,   -- Spinefin Halibut
    [11291] = 8,  -- Star Wood
    [18256] = 27,  -- Imbued Vial
}
