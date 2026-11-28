---------------------------------------------------------------------------
-- WOWGoldMaker / BagUI.lua
-- 背包列表: 把背包里所有物品列出来 (图标/名字/品质色/数量/位置),
-- 点一行直接在拍卖行搜索该物品。数据来自 C_Container / GetContainerItemInfo。
---------------------------------------------------------------------------

local ADDON, ns = ...

local T = ns.T
local C = T.C
local format = string.format

ns.BagUI = ns.BagUI or {}
local M = ns.BagUI

local BASE_W, BASE_H = 460, 500
local ROW_H = 22
local PAD = 14

local frame, scroll, content, statusText
local rows = {}

local QCOLOR = {
    [0] = { 0.62, 0.62, 0.62 }, [1] = { 1.00, 1.00, 1.00 }, [2] = { 0.12, 1.00, 0.00 },
    [3] = { 0.00, 0.44, 0.87 }, [4] = { 0.64, 0.21, 0.93 }, [5] = { 1.00, 0.50, 0.00 },
    [6] = { 0.90, 0.80, 0.50 }, [7] = { 0.90, 0.80, 0.50 },
}

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

local function ItemInfo(id, link)
    local name, quality, icon
    if type(link) == "string" then
        name = link:match("%[(.-)%]")
    end
    if type(GetItemInfo) == "function" then
        local n, _, q = GetItemInfo(id)
        if (not name or name == "") and n and n ~= "" then name = n end
        quality = q
        local ic = select(10, GetItemInfo(id))
        if ic then icon = ic end
    end
    if not icon and type(GetItemIcon) == "function" then
        local ok, ic = pcall(GetItemIcon, link or id)
        if ok and ic then icon = ic end
    end
    if not icon and _G.C_Item and type(_G.C_Item.GetItemIconByID) == "function" then
        local ok, ic = pcall(_G.C_Item.GetItemIconByID, id)
        if ok and ic then icon = ic end
    end
    return name or ("物品 #" .. tostring(id)), tonumber(quality) or 1,
        icon or "Interface\\Icons\\INV_Misc_QuestionMark"
end

local function BagItems()
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
            return { iconFileID = texture, stackCount = count, hyperlink = link }
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
                    out[#out + 1] = {
                        bag = bag, slot = slot, id = id,
                        count = it.stackCount or 1, link = it.hyperlink,
                    }
                end
            end
        end
    end
    return out
end

--------------------------------------------------------------------------- 行

local function NewRow()
    local r = CreateFrame("Button", nil, content)
    r:SetHeight(ROW_H)
    r.bg = r:CreateTexture(nil, "BACKGROUND")
    r.bg:SetAllPoints(true)
    r.bg:SetColorTexture(1, 1, 1, 0)
    r.icon = r:CreateTexture(nil, "ARTWORK")
    r.icon:SetSize(16, 16)
    r.icon:SetPoint("LEFT", r, "LEFT", 4, 0)
    r.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    r.title = Font(r, 9, C.text)
    r.title:SetPoint("LEFT", r, "LEFT", 24, 0)
    r.title:SetWidth(260)
    r.title:SetWordWrap(false)
    r.cnt = Font(r, 8, C.muted)
    r.cnt:SetWidth(60)
    r.cnt:SetJustifyH("RIGHT")
    r.cnt:SetPoint("RIGHT", r, "RIGHT", -80, 0)
    r.pos = Font(r, 8, C.faint)
    r.pos:SetWidth(70)
    r.pos:SetJustifyH("RIGHT")
    r.pos:SetPoint("RIGHT", r, "RIGHT", -4, 0)
    r:SetScript("OnClick", function(s)
        if s.itemID and ns.UI and ns.UI.SearchInAH then
            ns.UI.SearchInAH(s.itemID, s.itemName)
        end
    end)
    r:SetScript("OnEnter", function(s)
        s.bg:SetColorTexture(1, 1, 1, 0.08)
        if GameTooltip and s.itemID then
            GameTooltip:SetOwner(s, "ANCHOR_CURSOR")
            GameTooltip:ClearLines()
            GameTooltip:AddLine(s.itemName or "?", 1, 0.82, 0.35)
            GameTooltip:AddLine("|cff8a929e点击到拍卖行搜索|r", 0.55, 0.58, 0.62)
            GameTooltip:Show()
        end
    end)
    r:SetScript("OnLeave", function(s)
        s.bg:SetColorTexture(1, 1, 1, 0)
        if GameTooltip then GameTooltip:Hide() end
    end)
    return r
end

--------------------------------------------------------------------------- 渲染

local function Render()
    if not (frame and content) then return end
    local items = BagItems()
    local w = content:GetWidth() or (BASE_W - PAD * 2)
    local y = 0
    for i, it in ipairs(items) do
        local r = rows[i]
        if not r then
            r = NewRow()
            rows[i] = r
        end
        r:Show()
        r:ClearAllPoints()
        r:SetPoint("TOPLEFT", content, "TOPLEFT", 0, -y)
        r:SetWidth(w)
        local name, q, icon = ItemInfo(it.id, it.link)
        local col = QCOLOR[q] or QCOLOR[1]
        r.icon:SetTexture(icon)
        r.title:SetText(name)
        r.title:SetTextColor(col[1], col[2], col[3])
        r.cnt:SetText("×" .. tostring(it.count))
        r.pos:SetText(format("%d-%d", (it.bag or 0) + 1, it.slot or 0))
        r.itemID = it.id
        r.itemName = name
        y = y + ROW_H
    end
    for i = #items + 1, #rows do rows[i]:Hide() end
    content:SetHeight(math.max(1, y))
    if statusText then
        statusText:SetText(format("背包 %d 件 · 点击一行到拍卖行搜索", #items))
    end
end

--------------------------------------------------------------------------- 窗口

local function Build()
    if frame then return frame end

    local f = T.Glass(UIParent, BASE_W, BASE_H, "panel")
    f:SetFrameStrata("DIALOG")
    f:SetFrameLevel(210)
    f:SetToplevel(true)
    f:SetClampedToScreen(true)
    f:EnableMouse(true)
    f:SetMovable(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", function(s) s:StartMoving() end)
    f:SetScript("OnDragStop", function(s) s:StopMovingOrSizing() end)
    frame = f

    local title = T.Text(f, 12, C.gold)
    title:SetPoint("TOPLEFT", PAD, -12)
    title:SetText("背包")

    local close = T.CloseButton(f, function() M.Hide() end)
    close:SetPoint("TOPRIGHT", f, "TOPRIGHT", -10, -10)

    statusText = T.Text(f, 8, C.muted)
    statusText:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -6)
    statusText:SetWordWrap(false)

    scroll = CreateFrame("ScrollFrame", nil, f)
    scroll:SetPoint("TOPLEFT", PAD, -46)
    scroll:SetPoint("BOTTOMRIGHT", -PAD, 36)
    scroll:EnableMouseWheel(true)
    content = CreateFrame("Frame", nil, scroll)
    content:SetSize(BASE_W - PAD * 2, 1)
    scroll:SetScrollChild(content)
    scroll:SetScript("OnMouseWheel", function(_, d)
        local max = math.max(0, (content:GetHeight() or 1) - (scroll:GetHeight() or 1))
        local v = (scroll:GetVerticalScroll() or 0) - (d or 0) * 40
        if v < 0 then v = 0 elseif v > max then v = max end
        scroll:SetVerticalScroll(v)
    end)

    local refresh = MakeMiniButton(f, 50, 20, "刷新")
    refresh:SetPoint("BOTTOMLEFT", PAD, 10)
    refresh:SetScript("OnClick", function() Render() end)

    f:RegisterEvent("BAG_UPDATE_DELAYED")
    f:SetScript("OnEvent", function(s)
        if s:IsShown() then Render() end
    end)

    f:SetScript("OnShow", function()
        Render()
        pcall(function() f:Raise() end)
    end)
    f:Hide()
    return f
end

--------------------------------------------------------------------------- 对外

function M.Show()
    local ok, f = pcall(Build)
    if not ok then
        ns.Print("|cffff5555背包窗口打不开:|r " .. tostring(f))
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

function M.Refresh()
    if frame and frame:IsShown() then Render() end
end
