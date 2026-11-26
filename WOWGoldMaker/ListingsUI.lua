---------------------------------------------------------------------------
-- WOWGoldMaker / ListingsUI.lua
-- 在售商品管理: 列出自己在拍卖行的挂单, 显示我的售价 / 拍卖行最低价 / 排名,
-- 并提供从背包快速上架 (按拍卖行最低价预填)。
-- 数据来自 C_AuctionHouse.GetOwnedAuctionInfo / GetOwnedAuctionInfo,
-- 排名用商品搜索结果按价格档累加数量估算。
---------------------------------------------------------------------------

local ADDON, ns = ...

local T = ns.T
local C = T.C
local format = string.format

ns.ListingsUI = ns.ListingsUI or {}
local M = ns.ListingsUI

local BASE_W, BASE_H = 520, 460
local PANEL_PCT     = 0.55
local PANEL_MAX_H   = 0.86
local CONTENT_PAD   = 24
local SCALE_MAX     = 2.6
local PAD           = 20
local LIST_Y        = -62
local LIST_BOT      = 34
local ROW_H         = 24

local frame, content, listContent, scroll, statusText
local rows = {}
local shownCount = 0
local queryRun = 0

--------------------------------------------------------------------------- 小工具

local function Font(parent, size, color)
    local fs = parent:CreateFontString(nil, "OVERLAY")
    fs:SetFont(T.FontFile(), size, "")
    if color then fs:SetTextColor(T.rgb(color)) end
    fs:SetShadowColor(0, 0, 0, 0.6)
    fs:SetShadowOffset(1, -1)
    return fs
end

local function MakeMiniButton(parent, w, h, label)
    local b = CreateFrame("Button", nil, parent)
    b:SetSize(w, h)
    b.bg = b:CreateTexture(nil, "BACKGROUND")
    b.bg:SetAllPoints(true)
    b.bg:SetColorTexture(1, 1, 1, 0.10)
    b.text = T.Text(b, 9, C.muted)
    b.text:SetPoint("CENTER")
    b.text:SetText(label)
    b:SetScript("OnEnter", function()
        b.bg:SetColorTexture(1, 1, 1, 0.18)
        b.text:SetTextColor(T.rgb(C.text))
    end)
    b:SetScript("OnLeave", function()
        b.bg:SetColorTexture(1, 1, 1, 0.10)
        b.text:SetTextColor(T.rgb(C.muted))
    end)
    return b
end

local function MoneyPlain(c)
    c = math.max(0, math.floor(tonumber(c) or 0))
    local g = math.floor(c / 10000)
    local s = math.floor((c % 10000) / 100)
    local k = c % 100
    if g > 0 then return format("%d金%d银%d铜", g, s, k) end
    if s > 0 then return format("%d银%d铜", s, k) end
    return format("%d铜", k)
end

local function ItemName(id, link)
    -- itemLink 里一定带着名字, 最可靠 (Forever 的 GetItemInfo 常还没缓存到)
    if type(link) == "string" then
        local n = link:match("%[(.-)%]")
        if n and n ~= "" then return n end
    end
    if type(GetItemInfo) == "function" then
        local n = select(1, GetItemInfo(id))
        if n and n ~= "" then return n end
        if link then
            local n2 = select(1, GetItemInfo(link))
            if n2 and n2 ~= "" then return n2 end
        end
    end
    if _G.C_Item and type(_G.C_Item.GetItemNameByID) == "function" then
        local ok, n = pcall(_G.C_Item.GetItemNameByID, id)
        if ok and type(n) == "string" and n ~= "" then return n end
    end
    return id and ("物品 #" .. tostring(id)) or "未知物品"
end

local function ItemIcon(id, link)
    -- Forever 客户端的 GetItemInfo 返回值个数/顺序和正式服不一致, 第 10 个
    -- 不一定是图标; 先试专门的取图标接口, 再退回 GetItemInfo。
    if type(GetItemIcon) == "function" then
        local ok, icon = pcall(GetItemIcon, link or id)
        if ok and icon then return icon end
        ok, icon = pcall(GetItemIcon, id)
        if ok and icon then return icon end
    end
    if _G.C_Item and type(_G.C_Item.GetItemIconByID) == "function" then
        local ok, icon = pcall(_G.C_Item.GetItemIconByID, id)
        if ok and icon then return icon end
    end
    if type(GetItemInfoInstant) == "function" then
        local ok, _, _, _, _, icon = pcall(GetItemInfoInstant, id)
        if ok and icon then return icon end
    end
    if type(GetItemInfo) == "function" then
        local icon = select(10, GetItemInfo(id))
        if icon then return icon end
        if link then
            icon = select(10, GetItemInfo(link))
            if icon then return icon end
        end
    end
    return "Interface\\Icons\\INV_Misc_QuestionMark"
end

local function AH()
    return _G.C_AuctionHouse
end

local function OwnedAuctions()
    local api = AH()
    if not (api and type(api.GetNumOwnedAuctions) == "function"
        and type(api.GetOwnedAuctionInfo) == "function") then
        return nil
    end
    local out = {}
    local n = tonumber(api.GetNumOwnedAuctions()) or 0
    for i = 1, n do
        local ok, info = pcall(api.GetOwnedAuctionInfo, i)
        if ok and type(info) == "table" then
            -- status: 0 = 在售, 1 = 已售出 (与 Auctionator 的判断一致)。
            -- 不能拿剩余时间判断: 已售出的记录同样带剩余时间。
            local status = tonumber(info.status)
            if status == nil or status == 0 then
                out[#out + 1] = info
            end
        end
    end
    return out, n
end

-- 商品搜索结果按价格档返回 { {unit=单价, qty=数量}, ... } (升序)
local function CommodityTiers(itemID, cb)
    local api = AH()
    if not (api and type(api.GetNumCommoditySearchResults) == "function") then
        cb(nil)
        return
    end
    local auction = ns.Auction
    if not (auction and auction.CheckRecipe) then
        cb(nil)
        return
    end

    auction.CheckRecipe({ item = itemID, mats = {}, made = 1 }, function()
        local n = tonumber(api.GetNumCommoditySearchResults(itemID)) or 0
        local tiers = {}
        for i = 1, n do
            local ok, r = pcall(api.GetCommoditySearchResultInfo, itemID, i)
            if ok and type(r) == "table" then
                local unit = tonumber(r.unitPrice) or tonumber(r.minPrice)
                local qty = tonumber(r.quantity) or tonumber(r.totalQuantity) or 0
                if unit and unit > 0 and qty > 0 then
                    tiers[#tiers + 1] = { unit = unit, qty = qty }
                end
            end
        end
        table.sort(tiers, function(a, b) return a.unit < b.unit end)
        cb(tiers)
    end, nil, true)
end

-- 排名: 按价格档数 (一个价格档算一单), 同价视为我刚上架, 排在同价最前面。
-- 商品搜索结果只按价格聚合成档, 看不到同价其他卖家的挂单条数和上架时间,
-- 所以这里只能用「价格档数」近似单数; 同价按「后上架优先」处理 (不计入我前面)。
local function RankOf(tiers, myUnit)
    if not tiers or #tiers == 0 or not myUnit or myUnit <= 0 then return nil, 0, 0 end
    local beforeTiers, qtyBefore = 0, 0
    for _, t in ipairs(tiers) do
        if t.unit < myUnit then
            beforeTiers = beforeTiers + 1
            qtyBefore = qtyBefore + t.qty
        end
    end
    return beforeTiers + 1, #tiers, qtyBefore
end

--------------------------------------------------------------------------- 行

local function NewRow()
    local r = CreateFrame("Frame", nil, listContent)
    r:SetHeight(ROW_H)
    r:EnableMouse(true)

    r.bg = r:CreateTexture(nil, "BACKGROUND")
    r.bg:SetAllPoints(true)
    r.bg:SetColorTexture(1, 1, 1, 0)

    r.icon = r:CreateTexture(nil, "ARTWORK")
    r.icon:SetSize(18, 18)
    r.icon:SetPoint("LEFT", r, "LEFT", 6, 0)
    r.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)

    r.title = Font(r, 9, C.text)
    r.title:SetPoint("LEFT", r, "LEFT", 30, 0)
    r.title:SetWidth(106)
    r.title:SetWordWrap(false)

    r.qty = Font(r, 8, C.muted)
    r.qty:SetWidth(50)
    r.qty:SetJustifyH("RIGHT")
    r.qty:SetPoint("RIGHT", r, "RIGHT", -280, 0)

    r.mine = Font(r, 8, C.gold)
    r.mine:SetWidth(80)
    r.mine:SetJustifyH("RIGHT")
    r.mine:SetPoint("RIGHT", r, "RIGHT", -190, 0)

    r.low = Font(r, 8, C.teal)
    r.low:SetWidth(80)
    r.low:SetJustifyH("RIGHT")
    r.low:SetPoint("RIGHT", r, "RIGHT", -100, 0)

    r.rank = Font(r, 8, C.faint)
    r.rank:SetWidth(80)
    r.rank:SetJustifyH("RIGHT")
    r.rank:SetPoint("RIGHT", r, "RIGHT", -10, 0)

    -- 悬停看排名明细: 按价格档算, 同价视为后上架排前面
    r:SetScript("OnEnter", function(s)
        if not (GameTooltip and s.entry) then return end
        GameTooltip:SetOwner(s, "ANCHOR_CURSOR")
        GameTooltip:ClearLines()
        GameTooltip:AddLine(ItemName(s.itemID, s.entry.itemLink), 1, 0.82, 0.35)
        local mine = s.entry.buyoutAmount or s.entry.buyoutPrice or s.entry.minBid
        if mine then
            GameTooltip:AddLine("我的单价: " .. MoneyPlain(mine), 0.9, 0.9, 0.9)
        end
        if s.rankInfo then
            GameTooltip:AddLine(format("排名: 第 %d 位 (按价格档)", s.rankInfo.pos), 0.9, 0.9, 0.9)
            GameTooltip:AddLine(format("我前面 %d 件 · 共 %d 档", s.rankInfo.qtyBefore, s.rankInfo.totalTiers), 0.7, 0.7, 0.7)
            GameTooltip:AddLine("同价视为后上架, 排在同价最前", 0.55, 0.58, 0.62)
        end
        GameTooltip:Show()
    end)
    r:SetScript("OnLeave", function()
        if GameTooltip then GameTooltip:Hide() end
    end)

    return r
end

local function PaintRow(r, a)
    local id = a.itemKey and a.itemKey.itemID
    if not id and a.itemLink then
        id = tonumber(a.itemLink:match("item:(%d+)"))
    end
    r.entry = a
    r.itemID = id
    r.rankInfo = nil
    if id then
        r.icon:SetTexture(ItemIcon(id, a.itemLink))
        r.icon:Show()
    else
        r.icon:Hide()
    end
    r.title:SetText(ItemName(id, a.itemLink))
    r.qty:SetText("×" .. tostring(a.quantity or 0))
    local mine = a.buyoutAmount or a.buyoutPrice or a.minBid
    r.mine:SetText(mine and MoneyPlain(mine) or "—")
    r.low:SetText("…")
    r.rank:SetText("…")
end

local function QueryNext()
    -- 逐行查拍卖行最低价/排名 (串行, 共用拍卖行查询队列)
    local run = queryRun
    local i = 1
    local function step()
        if run ~= queryRun or not frame or not frame:IsShown() then return end
        local r = rows[i]
        if not r or not r:IsShown() or not r.itemID then
            if i < shownCount then i = i + 1; step(); return end
            return
        end
        local id = r.itemID
        CommodityTiers(id, function(tiers)
            if run ~= queryRun or not r:IsShown() or r.itemID ~= id then return end
            local low = tiers and tiers[1] and tiers[1].unit
            r.low:SetText(low and MoneyPlain(low) or "无挂单")
            local e = r.entry
            local myUnit = e and (e.buyoutAmount or e.buyoutPrice or e.minBid)
            local pos, totalTiers, qtyBefore = RankOf(tiers, myUnit)
            if pos then
                r.rank:SetText(format("第 %d 位", pos))
                r.rankInfo = { pos = pos, totalTiers = totalTiers, qtyBefore = qtyBefore }
            else
                r.rank:SetText("—")
                r.rankInfo = nil
            end
            i = i + 1
            if i <= shownCount then C_Timer.After(0.15, step) end
        end)
    end
    step()
end

--------------------------------------------------------------------------- 渲染

local function Render()
    if not (frame and listContent) then return end
    local auctions, totalOwned = OwnedAuctions()
    if not auctions then
        shownCount = 0
        for i = 1, #rows do rows[i]:Hide() end
        if statusText then statusText:SetText("|cffff9955客户端没有在售接口 (或拍卖行未打开)|r") end
        return
    end

    local w = listContent:GetWidth() or (BASE_W - PAD * 2)
    local y = 0
    for i, a in ipairs(auctions) do
        local r = rows[i]
        if not r then
            r = NewRow()
            rows[i] = r
        end
        r:Show()
        r:ClearAllPoints()
        r:SetPoint("TOPLEFT", listContent, "TOPLEFT", 0, -y)
        r:SetWidth(w)
        PaintRow(r, a)
        y = y + ROW_H
    end
    for i = #auctions + 1, #rows do rows[i]:Hide() end

    listContent:SetHeight(math.max(1, y))
    shownCount = #auctions
    if statusText then
        statusText:SetText(format("%d 件在售 (共 %d 条记录) · 拍卖行%s", #auctions, totalOwned or #auctions,
            (ns.Auction and ns.Auction.CanQuery and ns.Auction.CanQuery()) and "已打开" or "|cffff9955未打开|r"))
    end

    queryRun = queryRun + 1
    QueryNext()
end

local function RefreshIcons()
    for i = 1, shownCount do
        local r = rows[i]
        if r and r:IsShown() and r.itemID then
            r.icon:SetTexture(ItemIcon(r.itemID, r.entry and r.entry.itemLink))
        end
    end
end

--------------------------------------------------------------------------- 快速上架

local function BagCommodities()
    local out = {}
    local function slots(bag)
        if _G.C_Container and type(_G.C_Container.GetContainerNumSlots) == "function" then
            return _G.C_Container.GetContainerNumSlots(bag)
        elseif type(GetContainerNumSlots) == "function" then
            return GetContainerNumSlots(bag)
        end
        return 0
    end
    local function info(bag, slot)
        if _G.C_Container and type(_G.C_Container.GetContainerItemInfo) == "function" then
            return _G.C_Container.GetContainerItemInfo(bag, slot)
        elseif type(GetContainerItemInfo) == "function" then
            local texture, count, _, _, _, _, link = GetContainerItemInfo(bag, slot)
            if not count then return nil end
            local id = link and tonumber(link:match("item:(%d+)"))
            return { iconFileID = texture, stackCount = count, hyperlink = link, itemID = id }
        end
    end

    for bag = 0, 4 do
        local n = slots(bag) or 0
        for slot = 1, n do
            local it = info(bag, slot)
            if it and (it.stackCount or 0) > 0 then
                local id = it.itemID
                if not id and it.hyperlink then
                    id = tonumber(it.hyperlink:match("item:(%d+)"))
                end
                if id then
                    local _, _, _, _, _, _, _, maxStack = GetItemInfo(id)
                    if maxStack and maxStack > 1 then
                        out[#out + 1] = { bag = bag, slot = slot, id = id, count = it.stackCount, link = it.hyperlink }
                    end
                end
            end
        end
    end
    return out
end

local function PostCommodity(bag, slot, qty, price)
    local api = AH()
    if not (api and type(api.PostCommodity) == "function") then
        return false, "客户端没有上架接口"
    end
    if not (_G.ItemLocation and type(_G.ItemLocation.CreateFromBagAndSlot) == "function") then
        return false, "客户端没有 ItemLocation"
    end
    local ok, loc = pcall(_G.ItemLocation.CreateFromBagAndSlot, bag, slot)
    if not (ok and loc) then return false, "取不到背包位置" end
    local okPost, res = pcall(api.PostCommodity, loc, 2, qty, price)   -- 2 = 24 小时
    if not okPost then return false, tostring(res) end
    if not res then return false, "拍卖行拒绝上架" end
    return true
end

local sellFrame, sellList, sellScroll, sellContent
local sellRows = {}
local sellSelected
local sellQty, sellPrice, sellHint

local function SellRender()
    if not sellFrame then return end
    local items = BagCommodities()
    local w = sellContent:GetWidth() or 300
    local y = 0
    for i, it in ipairs(items) do
        local r = sellRows[i]
        if not r then
            r = CreateFrame("Button", nil, sellContent)
            r:SetHeight(20)
            r:RegisterForClicks("LeftButtonUp")
            r.bg = r:CreateTexture(nil, "BACKGROUND")
            r.bg:SetAllPoints(true)
            r.bg:SetColorTexture(1, 1, 1, 0)
            r.txt = Font(r, 9, C.text)
            r.txt:SetPoint("LEFT", 6, 0)
            r.txt:SetWidth(220)
            r.txt:SetWordWrap(false)
            r.cnt = Font(r, 8, C.muted)
            r.cnt:SetPoint("RIGHT", -6, 0)
            r:SetScript("OnClick", function(s)
                sellSelected = s.item
                sellQty:SetText(tostring(s.item.count))
                sellHint:SetText("已选: " .. ItemName(s.item.id, s.item.link))
                local api = AH()
                if api and type(api.GetNumCommoditySearchResults) == "function" then
                    CommodityTiers(s.item.id, function(tiers)
                        if sellSelected ~= s.item then return end
                        local low = tiers and tiers[1] and tiers[1].unit
                        if low then sellPrice:SetText(tostring(low)) end
                    end)
                end
            end)
            r:SetScript("OnEnter", function(s) s.bg:SetColorTexture(1, 1, 1, 0.08) end)
            r:SetScript("OnLeave", function(s) s.bg:SetColorTexture(1, 1, 1, 0) end)
            sellRows[i] = r
        end
        r:Show()
        r.item = it
        r:ClearAllPoints()
        r:SetPoint("TOPLEFT", sellContent, "TOPLEFT", 0, -y)
        r:SetWidth(w)
        r.txt:SetText(ItemName(it.id, it.link))
        r.cnt:SetText("×" .. tostring(it.count))
        y = y + 20
    end
    for i = #items + 1, #sellRows do sellRows[i]:Hide() end
    sellContent:SetHeight(math.max(1, y))
end

local function BuildSell()
    if sellFrame then return sellFrame end
    if not UIParent then return nil end

    local f = T.Glass(UIParent, 360, 420, "panel")
    f:SetFrameStrata(ns.DB().strata or "DIALOG")
    local baseLevel = (frame and frame.GetFrameLevel) and frame:GetFrameLevel() or 200
    f:SetFrameLevel(baseLevel + 30)
    f:SetToplevel(true)
    f:SetClampedToScreen(true)
    f:EnableMouse(true)
    f:SetMovable(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", function(s) s:StartMoving() end)
    f:SetScript("OnDragStop", function(s) s:StopMovingOrSizing() end)

    local title = T.Text(f, 11, C.gold)
    title:SetPoint("TOPLEFT", 14, -12)
    title:SetText("快速上架")

    local close = T.CloseButton(f, function() f:Hide() end)
    close:SetPoint("TOPRIGHT", f, "TOPRIGHT", -10, -10)

    sellScroll = CreateFrame("ScrollFrame", nil, f)
    sellScroll:SetPoint("TOPLEFT", 14, -40)
    sellScroll:SetPoint("BOTTOMRIGHT", -14, 120)
    sellScroll:EnableMouseWheel(true)
    sellContent = CreateFrame("Frame", nil, sellScroll)
    sellContent:SetSize(320, 1)
    sellScroll:SetScrollChild(sellContent)
    sellScroll:SetScript("OnMouseWheel", function(_, d)
        local max = math.max(0, (sellContent:GetHeight() or 1) - (sellScroll:GetHeight() or 1))
        local v = (sellScroll:GetVerticalScroll() or 0) - (d or 0) * 40
        if v < 0 then v = 0 elseif v > max then v = max end
        sellScroll:SetVerticalScroll(v)
    end)

    local qlabel = T.Text(f, 9, C.faint)
    qlabel:SetPoint("TOPLEFT", sellScroll, "BOTTOMLEFT", 0, -8)
    qlabel:SetText("数量")

    sellQty = CreateFrame("EditBox", nil, f)
    sellQty:SetSize(60, 16)
    sellQty:SetPoint("LEFT", qlabel, "RIGHT", 8, 0)
    sellQty:SetFont(T.FontFile(), 10, "")
    sellQty:SetTextColor(T.rgb(C.text))
    sellQty:SetAutoFocus(false)
    sellQty:SetNumeric(true)
    sellQty:SetMaxLetters(6)
    sellQty:SetTextInsets(1, 1, 0, 0)

    local plabel = T.Text(f, 9, C.faint)
    plabel:SetPoint("LEFT", sellQty, "RIGHT", 12, 0)
    plabel:SetText("单价")

    sellPrice = CreateFrame("EditBox", nil, f)
    sellPrice:SetSize(90, 16)
    sellPrice:SetPoint("LEFT", plabel, "RIGHT", 8, 0)
    sellPrice:SetFont(T.FontFile(), 10, "")
    sellPrice:SetTextColor(T.rgb(C.gold))
    sellPrice:SetAutoFocus(false)
    sellPrice:SetNumeric(true)
    sellPrice:SetMaxLetters(9)
    sellPrice:SetTextInsets(1, 1, 0, 0)

    local unit = T.Text(f, 8, C.faint)
    unit:SetPoint("LEFT", sellPrice, "RIGHT", 4, 0)
    unit:SetText("铜/个")

    sellHint = T.Text(f, 8, C.faint)
    sellHint:SetPoint("TOPLEFT", qlabel, "BOTTOMLEFT", 0, -8)
    sellHint:SetWidth(330)
    sellHint:SetWordWrap(false)
    sellHint:SetText("点上面的物品选中; 单价默认拍卖行最低价")

    local post = MakeMiniButton(f, 70, 20, "上架")
    post:SetPoint("BOTTOMRIGHT", -14, 12)
    post:SetScript("OnClick", function()
        local it = sellSelected
        if not it then
            sellHint:SetText("|cffff9955先点一个物品|r")
            return
        end
        local qty = tonumber(sellQty:GetText() or "")
        local price = tonumber(sellPrice:GetText() or "")
        if not qty or qty < 1 or not price or price < 1 then
            sellHint:SetText("|cffff9955数量和单价都要大于 0|r")
            return
        end
        local ok, why = PostCommodity(it.bag, it.slot, qty, price)
        if ok then
            ns.Print(format("|cff4dc87a已上架|r %s ×%d · 单价 %s",
                ItemName(it.id, it.link), qty, MoneyPlain(price)))
            f:Hide()
            Render()
        else
            sellHint:SetText("|cffff9955上架失败: " .. tostring(why) .. "|r")
        end
    end)

    local cancel = MakeMiniButton(f, 54, 18, "取消")
    cancel:SetPoint("RIGHT", post, "LEFT", -6, 1)
    cancel:SetScript("OnClick", function() f:Hide() end)

    f:Hide()
    sellFrame = f
    return sellFrame
end

function M.OpenSell()
    local f = BuildSell()
    if not f then return end
    sellSelected = nil
    sellQty:SetText("")
    sellPrice:SetText("")
    sellHint:SetText("点上面的物品选中; 单价默认拍卖行最低价")
    f:ClearAllPoints()
    f:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
    f:Show()
    SellRender()
end

--------------------------------------------------------------------------- 窗口

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
    return math.max(360, w), math.max(300, h)
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

local function Build()
    if frame then return frame end

    local f = CreateFrame("Frame", "WOWGoldMakerListingsFrame", UIParent)
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
            db.lspos = { point = point, relPoint = relPoint, x = math.floor(x), y = math.floor(y) }
        end
    end)
    tinsert(UISpecialFrames, f:GetName())
    frame = f

    local db = ns.DB()
    local STRATA_LEVEL = {
        BACKGROUND = 0, LOW = 1, MEDIUM = 1, HIGH = 200,
        DIALOG = 200, FULLSCREEN = 200, FULLSCREEN_DIALOG = 200, TOOLTIP = 200,
    }
    local strata = (db and db.strata) or "DIALOG"
    if not STRATA_LEVEL[strata] then strata = "DIALOG" end
    pcall(function()
        f:SetFrameStrata(strata)
        f:SetFrameLevel((STRATA_LEVEL[strata] or 200) + 4)
        f:SetToplevel(true)
    end)

    local k, cw, ch = ComputeLayout(pw, ph)
    content = CreateFrame("Frame", nil, f)
    content:SetPoint("CENTER", f, "CENTER", 0, 0)
    content:SetSize(cw, ch)
    content:SetScale(k)

    local bg = f:CreateTexture(nil, "BACKGROUND", nil, -7)
    bg:SetAllPoints(true)
    bg:SetTexture(T.PATH .. "panel")
    pcall(function()
        bg:SetTextureSliceMargins(24, 24, 24, 24)
        bg:SetTextureSliceMode(Enum.UITextureSliceMode.Stretched)
    end)

    local title = T.Text(content, 13, C.gold)
    title:SetPoint("TOPLEFT", content, "TOPLEFT", PAD, -8)
    title:SetText("在售商品")

    local close = T.CloseButton(content, function() M.Hide() end)
    close:SetPoint("TOPRIGHT", content, "TOPRIGHT", -(PAD - 6), -12)

    statusText = T.Text(content, 8, C.muted)
    statusText:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -8)
    statusText:SetWordWrap(false)

    scroll = CreateFrame("ScrollFrame", nil, content)
    scroll:SetPoint("TOPLEFT", content, "TOPLEFT", PAD, LIST_Y)
    scroll:SetPoint("BOTTOMRIGHT", content, "BOTTOMRIGHT", -PAD, LIST_BOT)
    scroll:EnableMouseWheel(true)
    listContent = CreateFrame("Frame", nil, scroll)
    listContent:SetSize(cw - PAD * 2, 1)
    scroll:SetScrollChild(listContent)
    scroll:SetScript("OnMouseWheel", function(_, d)
        local max = math.max(0, (listContent:GetHeight() or 1) - (scroll:GetHeight() or 1))
        local v = (scroll:GetVerticalScroll() or 0) - (d or 0) * 40
        if v < 0 then v = 0 elseif v > max then v = max end
        scroll:SetVerticalScroll(v)
    end)

    local sell = MakeMiniButton(content, 70, 20, "快速上架")
    sell:SetPoint("BOTTOMLEFT", content, "BOTTOMLEFT", PAD, 10)
    sell:SetScript("OnClick", function() M.OpenSell() end)

    -- 刷新: 重新读在售列表, 并重新查每行的拍卖行最低价/排名
    local refresh = MakeMiniButton(content, 50, 20, "刷新")
    refresh:SetPoint("BOTTOMRIGHT", content, "BOTTOMRIGHT", -PAD, 10)
    refresh:SetScript("OnClick", function()
        if scroll then scroll:SetVerticalScroll(0) end
        Render()
    end)

    local hint = T.Text(content, 8, C.faint)
    hint:SetPoint("BOTTOMLEFT", content, "BOTTOMLEFT", PAD + 78, 14)
    hint:SetWidth(math.max(80, cw - PAD * 2 - 78 - 60))
    hint:SetWordWrap(false)
    hint:SetText("售价 = 我的挂单买断价 · 排名按价格档估算 · 需打开拍卖行")

    local pos = db and db.lspos
    f:ClearAllPoints()
    if type(pos) == "table" and pos.point then
        f:SetPoint(pos.point, UIParent, pos.relPoint or pos.point, pos.x or 0, pos.y or 0)
    else
        f:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
    end

    f:SetScript("OnShow", function()
        Render()
        pcall(function() f:Raise() end)
        -- 物品图标是异步回包的: 等一下再补一次
        C_Timer.After(1.5, function()
            if frame and frame:IsShown() then RefreshIcons() end
        end)
    end)
    f:SetScript("OnHide", function()
        queryRun = queryRun + 1
    end)

    f:Hide()
    return f
end

--------------------------------------------------------------------------- 对外

function M.Show()
    local ok, f = pcall(Build)
    if not ok then
        ns.Print("|cffff5555在售窗口打不开:|r " .. tostring(f))
        return
    end
    f:Show()
    pcall(function() f:Raise() end)
end

function M.Hide()
    if frame then frame:Hide() end
end

function M.Toggle()
    if frame and frame:IsShown() then M.Hide() else M.Show() end
end

-- 重新读在售列表并重查最低价/排名 (窗口底部「刷新」按钮也走这里)
function M.Refresh()
    if frame and frame:IsShown() then Render() end
end
