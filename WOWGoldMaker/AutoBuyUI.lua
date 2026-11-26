---------------------------------------------------------------------------
-- WOWGoldMaker / AutoBuyUI.lua
-- 自动购买独立窗口: 不再挂在商人货架里。打开本窗口就开始扫描, 关闭即停。
-- 每行两排:
--   上排: 图标 名字 .......... [价格][结果][累计买到][扫 N]
--   下排: [频率]秒[确认] [单价上限][确认] [×]
-- 扫描/下单/计数全部由 AutoBuy.lua 提供; 这里只负责显示和行内编辑。
---------------------------------------------------------------------------

local ADDON, ns = ...

local T = ns.T
local C = T.C
local format = string.format

ns.AutoBuyUI = ns.AutoBuyUI or {}
local M = ns.AutoBuyUI

--------------------------------------------------------------------------- 尺寸 (设计坐标, 运行时整体缩放)

local BASE_W, BASE_H = 520, 440
local PANEL_PCT     = 0.50
local PANEL_MAX_H   = 0.80
local CONTENT_PAD   = 24
local SCALE_MAX     = 2.6

local PAD      = 20
local LIST_Y   = -62      -- 列表区顶部
local LIST_BOT = 30       -- 列表区底部 (给页脚留一行)
local ROW_H    = 34       -- 每行两排: 上排 +8, 下排 -8
local RIGHT_W  = 204      -- 上排右侧结论列的总宽 (扫N/累计/结果/价格)

local frame, content, listContent, scroll, statusText, emptyText
local rows = {}
local shownCount = 0
local rowErrShown = false

--------------------------------------------------------------------------- 小工具

local function Font(parent, size, color)
    local fs = parent:CreateFontString(nil, "OVERLAY")
    fs:SetFont(T.FontFile(), size, "")
    if color then fs:SetTextColor(T.rgb(color)) end
    fs:SetShadowColor(0, 0, 0, 0.6)
    fs:SetShadowOffset(1, -1)
    return fs
end

-- 纯文本金额 (不带颜色码): 行内 EditBox 不认 |cff... 码
local function MoneyPlain(c)
    c = math.max(0, math.floor(tonumber(c) or 0))
    local g = math.floor(c / 10000)
    local s = math.floor((c % 10000) / 100)
    local k = c % 100
    if g > 0 then return format("%d金%d银%d铜", g, s, k) end
    if s > 0 then return format("%d银%d铜", s, k) end
    return format("%d铜", k)
end

local function NameOf(rec)
    return rec.zh or rec.name or ("#" .. tostring(rec.id))
end

local function IconOf(rec)
    if rec.icon and rec.icon ~= "" then
        return "Interface\\Icons\\" .. rec.icon
    end
    local icon = ns.Prof and ns.Prof.ItemIcon and ns.Prof.ItemIcon(rec.id)
    return icon or "Interface\\Icons\\INV_Misc_QuestionMark"
end

-- 扫描结论的文字与颜色 (和 AutoBuy 里 lastInfo.tag 对应)
local SCAN_RESULT = {
    bought  = { "买到", 0.30, 0.80, 0.50 },
    pending = { "下单", 0.85, 0.75, 0.35 },
    none    = { "无货", 0.55, 0.58, 0.62 },
    over    = { "超价", 0.92, 0.42, 0.42 },
    bag     = { "满包", 0.95, 0.60, 0.35 },
    money   = { "没钱", 0.95, 0.60, 0.35 },
    fail    = { "失败", 0.92, 0.42, 0.42 },
    max     = { "够数", 0.30, 0.80, 0.50 },
    ready   = { "可买", 0.30, 0.85, 0.50 },
}

--------------------------------------------------------------------------- 数据

local function Records()
    local mer = ns.Merchant
    if mer and mer.AutoRecords then
        local ok, list = pcall(mer.AutoRecords)
        if ok and type(list) == "table" then return list end
    end
    return {}
end

local function SortRecords(list)
    table.sort(list, function(a, b)
        local pa, pb = a.autoP or 0, b.autoP or 0
        if pa ~= pb then return pa > pb end
        local ia, ib = tonumber(a.id), tonumber(b.id)
        if ia and ib then return ia < ib end
        return tostring(a.id) < tostring(b.id)
    end)
    return list
end

local function StatusLine(n)
    local parts = { format("%d 件", n) }
    local AB = ns.AutoBuy
    if AB and AB.PageActive and AB.PageActive() then
        parts[#parts + 1] = "|cff4dc87a扫描中|r"
    else
        parts[#parts + 1] = "|cff8a929e未扫描|r"
    end
    local AH = ns.Auction
    if AH and AH.CanQuery and AH.CanQuery() == false then
        parts[#parts + 1] = "|cffff9955拍卖行未打开|r"
    end
    return table.concat(parts, " · ")
end

--------------------------------------------------------------------------- 行的结论显示

local function PaintScanInfo(r, id)
    local AB = ns.AutoBuy
    if not (r and AB) then return end

    if r.scanText then
        r.scanText:SetText("扫" .. tostring((AB.Scans and AB.Scans(id)) or 0))
    end

    local info = AB.Info and AB.Info(id)
    local n = (AB.BoughtQty and AB.BoughtQty(id)) or 0
    local q = (AB.QtyOf and AB.QtyOf(id)) or 100
    local reached = n >= q

    if r.lastPrice then
        if info and info.unit then
            r.lastPrice:SetText(MoneyPlain(info.unit))
            r.lastPrice:SetTextColor(T.rgb(C.gold))
        else
            r.lastPrice:SetText("—")
            r.lastPrice:SetTextColor(T.rgb(C.faint))
        end
    end
    if r.lastResult then
        if reached then
            r.lastResult:SetText("够数")
            r.lastResult:SetTextColor(0.30, 0.80, 0.50)
        else
            local v = info and SCAN_RESULT[info.tag]
            if v then
                r.lastResult:SetText(v[1])
                r.lastResult:SetTextColor(v[2], v[3], v[4])
            else
                r.lastResult:SetText("")
            end
        end
    end
    if r.boughtTotal then
        r.boughtTotal:SetText(format("%d/%d", n, q))
        r.boughtTotal:SetTextColor(T.rgb((n > 0) and C.teal or C.faint))
    end

    -- 半自动: 只有「可买」时才亮出买入按钮
    if r.buyBtn then
        if info and info.tag == "ready" then r.buyBtn:Show() else r.buyBtn:Hide() end
    end

    -- 扫描中显示「停止」, 暂停后显示「扫描」
    if r.scanBtn then
        local on = AB.ScanOn and AB.ScanOn(id)
        r.scanBtn.txt:SetText(on and "停止" or "扫描")
        r.scanBtn.txt:SetTextColor(T.rgb(on and C.red or C.teal))
    end
end

-- 行上的「买入」: 直接复用首页材料行的买入弹窗。
-- 客户端的安全机制会拦截行内按钮直接调购买 API（提示"插件导致界面行为失效"），
-- 只有材料行那条「弹窗先查价 → 玩家点弹窗买入」的路径能成功。
local function CommitBuy(r)
    local rec = r.entry
    if not rec then return end
    if ns.UI and ns.UI.BuyItem then
        ns.UI.BuyItem(rec.id, NameOf(rec))
    else
        ns.Print("|cffff5555买入界面未加载|r")
    end
end

-- 暂停/恢复这一条的扫描
local function CommitScan(r)
    local rec = r.entry
    local AB = ns.AutoBuy
    if not (rec and AB) then return end
    AB.SetScanOn(rec.id, not AB.ScanOn(rec.id))
    PaintScanInfo(r, rec.id)
end

--------------------------------------------------------------------------- 行内编辑

local Render

local function CommitGap(r)
    local rec = r.entry
    local AB = ns.AutoBuy
    if not (rec and AB) then return end
    local n = tonumber(r.gapBox:GetText() or "")
    if not n then
        r.gapBox:SetText(tostring(AB.GapOf(rec.id)))
        return
    end
    local v = AB.SetGap(rec.id, n)
    if not v then return end
    r.gapBox:SetText(tostring(v))
    r.gapBox:ClearFocus()
    ns.Print(format("|cff4dc87a扫描频率|r %s → 每 %d 秒", NameOf(rec), v))
end

local function CommitCap(r)
    local rec = r.entry
    local AB = ns.AutoBuy
    if not (rec and AB) then return end
    local v = AB.ParseMoney(r.capBox:GetText())
    if not v then
        r.capBox:SetText(MoneyPlain(AB.PriceOf(rec.id) or 0))
        ns.Print("|cffff9955金额看不懂|r 写 1金20银 / 1.5 (金) / 纯数字按铜")
        return
    end
    AB.Set(rec.id, v)
    r.capBox:SetText(MoneyPlain(v))
    r.capBox:ClearFocus()
    if ns.UI and ns.UI.RefreshNpcAll then pcall(ns.UI.RefreshNpcAll) end
    ns.Print(format("|cff4dc87a单价上限|r %s → %s", NameOf(rec), MoneyPlain(v)))
    Render()          -- 列表按上限排序, 改完可能换位置
end

local function CommitQty(r)
    local rec = r.entry
    local AB = ns.AutoBuy
    if not (rec and AB) then return end
    local n = tonumber(r.qtyBox:GetText() or "")
    if not n then
        r.qtyBox:SetText(tostring(AB.QtyOf(rec.id)))
        return
    end
    local v = AB.SetQty(rec.id, n)
    if not v then return end
    r.qtyBox:SetText(tostring(v))
    r.qtyBox:ClearFocus()
    ns.Print(format("|cff4dc87a购买总数上限|r %s → %d 个", NameOf(rec), v))
    PaintScanInfo(r, rec.id)
end

local function DeleteRow(r)
    local rec = r.entry
    if not rec or not ns.AutoBuy then return end
    local name = NameOf(rec)
    ns.AutoBuy.Remove(rec.id)
    if ns.UI and ns.UI.RefreshNpcAll then pcall(ns.UI.RefreshNpcAll) end
    Render()
    ns.Print(format("|cff8a929e已从自动购买移除|r %s", name))
end

--------------------------------------------------------------------------- 行

local function NewRow()
    local r = CreateFrame("Frame", nil, listContent)
    r:SetHeight(ROW_H)
    r:EnableMouse(true)

    r.bg = r:CreateTexture(nil, "BACKGROUND")
    r.bg:SetAllPoints(true)
    r.bg:SetColorTexture(1, 1, 1, 0)
    r:SetScript("OnEnter", function(s) s.bg:SetColorTexture(1, 1, 1, 0.06) end)
    r:SetScript("OnLeave", function(s) s.bg:SetColorTexture(1, 1, 1, 0) end)

    r.icon = r:CreateTexture(nil, "ARTWORK")
    r.icon:SetSize(18, 18)
    r.icon:SetPoint("LEFT", r, "LEFT", 6, 8)
    r.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)

    r.name = Font(r, 10, C.text)
    r.name:SetPoint("LEFT", r, "LEFT", 30, 8)
    r.name:SetWordWrap(false)

    -- 上排右侧: 价格 / 结果 / 累计买到 / 扫 N
    r.scanText = Font(r, 8, C.faint)
    r.scanText:SetWidth(38)
    r.scanText:SetJustifyH("RIGHT")
    r.scanText:SetPoint("RIGHT", r, "RIGHT", -4, 8)
    r.scanText:SetText("扫0")

    r.boughtTotal = Font(r, 8, C.faint)
    r.boughtTotal:SetWidth(48)
    r.boughtTotal:SetJustifyH("RIGHT")
    r.boughtTotal:SetPoint("RIGHT", r, "RIGHT", -46, 8)
    r.boughtTotal:SetText("0/100")

    r.lastResult = Font(r, 8, C.muted)
    r.lastResult:SetWidth(40)
    r.lastResult:SetJustifyH("RIGHT")
    r.lastResult:SetPoint("RIGHT", r, "RIGHT", -98, 8)
    r.lastResult:SetText("")

    r.lastPrice = Font(r, 8, C.gold)
    r.lastPrice:SetWidth(58)
    r.lastPrice:SetJustifyH("RIGHT")
    r.lastPrice:SetPoint("RIGHT", r, "RIGHT", -142, 8)
    r.lastPrice:SetText("—")

    -- 下排: 频率 / 上限 / 确认 / 删除 (统一 y = -8)
    local function NewField(w)
        local cell = T.Line(r, w, 18, C.white, 0.06)
        cell:EnableMouse(true)
        cell:SetScript("OnMouseDown", function() end)
        local eb = CreateFrame("EditBox", nil, cell)
        eb:SetSize(w - 8, 14)
        eb:SetPoint("LEFT", cell, "LEFT", 4, 0)
        eb:SetFont(T.FontFile(), 10, "")
        eb:SetTextColor(T.rgb(C.text))
        eb:SetAutoFocus(false)
        eb:SetTextInsets(0, 0, 0, 0)
        return cell, eb
    end

    r.gapCell, r.gapBox = NewField(30)
    r.gapCell:SetPoint("RIGHT", r, "RIGHT", -225, -8)
    r.gapBox:SetNumeric(true)
    r.gapBox:SetMaxLetters(4)

    r.gapUnit = Font(r, 8, C.faint)
    r.gapUnit:SetPoint("RIGHT", r, "RIGHT", -212, -8)
    r.gapUnit:SetText("秒")

    local function NewTick(tip)
        local b = CreateFrame("Button", nil, r)
        b:SetSize(24, 14)
        b.txt = Font(b, 9, C.faint)
        b.txt:SetPoint("CENTER", 0, 0)
        b.txt:SetText("确认")
        b:SetScript("OnEnter", function()
            r.bg:SetColorTexture(1, 1, 1, 0.09)
            b.txt:SetTextColor(T.rgb(C.teal))
            GameTooltip:SetOwner(b, "ANCHOR_CURSOR_RIGHT")
            GameTooltip:ClearLines()
            GameTooltip:AddLine(tip, 1, 0.82, 0.35)
            GameTooltip:AddLine("|cff8a929e回车也能提交|r", 0.62, 0.65, 0.70)
            GameTooltip:Show()
        end)
        b:SetScript("OnLeave", function()
            r.bg:SetColorTexture(1, 1, 1, 0)
            b.txt:SetTextColor(T.rgb(C.faint))
            GameTooltip:Hide()
        end)
        return b
    end

    r.gapOk = NewTick("确认扫描频率")
    r.gapOk:SetPoint("RIGHT", r, "RIGHT", -184, -8)

    r.capCell, r.capBox = NewField(84)
    r.capCell:SetPoint("RIGHT", r, "RIGHT", -96, -8)
    r.capBox:SetMaxLetters(16)

    r.capOk = NewTick("确认单价上限")
    r.capOk:SetPoint("RIGHT", r, "RIGHT", -68, -8)

    -- 购买总数上限 (默认 100): 买够就停这一条
    r.qtyCell, r.qtyBox = NewField(44)
    r.qtyCell:SetPoint("RIGHT", r, "RIGHT", -287, -8)
    r.qtyBox:SetNumeric(true)
    r.qtyBox:SetMaxLetters(6)

    r.qtyOk = NewTick("确认购买总数")
    r.qtyOk:SetPoint("RIGHT", r, "RIGHT", -259, -8)

    r.delBtn = CreateFrame("Button", nil, r)
    r.delBtn:SetSize(16, 16)
    r.delBtn:SetPoint("RIGHT", r, "RIGHT", -4, -8)
    r.delTxt = Font(r.delBtn, 12, C.faint)
    r.delTxt:SetPoint("CENTER", 0, 0)
    r.delTxt:SetText("×")
    r.delBtn:SetScript("OnEnter", function()
        r.bg:SetColorTexture(1, 1, 1, 0.09)
        r.delTxt:SetTextColor(T.rgb(C.red))
        GameTooltip:SetOwner(r.delBtn, "ANCHOR_CURSOR_RIGHT")
        GameTooltip:ClearLines()
        GameTooltip:AddLine("移出自动购买", 1, 0.55, 0.55)
        GameTooltip:AddLine("|cff8a929e这一条不再自动买, 设过的上限和频率一起删掉|r", 0.62, 0.65, 0.70)
        GameTooltip:Show()
    end)
    r.delBtn:SetScript("OnLeave", function()
        r.bg:SetColorTexture(1, 1, 1, 0)
        r.delTxt:SetTextColor(T.rgb(C.faint))
        GameTooltip:Hide()
    end)
    r.delBtn:SetScript("OnClick", function() DeleteRow(r) end)

    -- 暂停/恢复这一条的扫描 (删除按钮左边)
    r.scanBtn = CreateFrame("Button", nil, r)
    r.scanBtn:SetSize(40, 18)
    r.scanBtn:SetPoint("RIGHT", r, "RIGHT", -24, -8)
    r.scanBtn.bg = r.scanBtn:CreateTexture(nil, "BACKGROUND")
    r.scanBtn.bg:SetAllPoints(true)
    r.scanBtn.bg:SetColorTexture(1, 1, 1, 0.10)
    r.scanBtn.txt = Font(r.scanBtn, 9, C.teal)
    r.scanBtn.txt:SetPoint("CENTER", 0, 0)
    r.scanBtn.txt:SetText("停止")
    r.scanBtn:SetScript("OnEnter", function()
        r.bg:SetColorTexture(1, 1, 1, 0.09)
        r.scanBtn.bg:SetColorTexture(1, 1, 1, 0.18)
    end)
    r.scanBtn:SetScript("OnLeave", function()
        r.bg:SetColorTexture(1, 1, 1, 0)
        r.scanBtn.bg:SetColorTexture(1, 1, 1, 0.10)
    end)
    r.scanBtn:SetScript("OnClick", function() CommitScan(r) end)

    -- 半自动下单: 扫描到「可买」时出现, 点击在硬件事件上下文里执行 BuyNow
    r.buyBtn = CreateFrame("Button", nil, r)
    r.buyBtn:SetSize(44, 18)
    r.buyBtn:SetPoint("LEFT", r, "LEFT", 30, -8)
    r.buyBtn.bg = r.buyBtn:CreateTexture(nil, "BACKGROUND")
    r.buyBtn.bg:SetAllPoints(true)
    r.buyBtn.bg:SetColorTexture(0.20, 0.55, 0.35, 0.40)
    r.buyBtn.txt = Font(r.buyBtn, 9, C.teal)
    r.buyBtn.txt:SetPoint("CENTER", 0, 0)
    r.buyBtn.txt:SetText("买入")
    r.buyBtn:SetScript("OnEnter", function()
        r.bg:SetColorTexture(1, 1, 1, 0.09)
        r.buyBtn.bg:SetColorTexture(0.25, 0.65, 0.40, 0.55)
    end)
    r.buyBtn:SetScript("OnLeave", function()
        r.bg:SetColorTexture(1, 1, 1, 0)
        r.buyBtn.bg:SetColorTexture(0.20, 0.55, 0.35, 0.40)
    end)
    r.buyBtn:SetScript("OnClick", function() CommitBuy(r) end)
    r.buyBtn:Hide()

    r.gapBox:SetScript("OnEnterPressed", function() CommitGap(r) end)
    r.gapBox:SetScript("OnEscapePressed", function(eb)
        if r.entry and ns.AutoBuy then eb:SetText(tostring(ns.AutoBuy.GapOf(r.entry.id))) end
        eb:ClearFocus()
    end)
    r.capBox:SetScript("OnEnterPressed", function() CommitCap(r) end)
    r.capBox:SetScript("OnEscapePressed", function(eb)
        if r.entry and ns.AutoBuy then
            eb:SetText(MoneyPlain(ns.AutoBuy.PriceOf(r.entry.id) or 0))
        end
        eb:ClearFocus()
    end)
    r.gapOk:SetScript("OnClick", function() CommitGap(r) end)
    r.capOk:SetScript("OnClick", function() CommitCap(r) end)

    r.qtyBox:SetScript("OnEnterPressed", function() CommitQty(r) end)
    r.qtyBox:SetScript("OnEscapePressed", function(eb)
        if r.entry and ns.AutoBuy then eb:SetText(tostring(ns.AutoBuy.QtyOf(r.entry.id))) end
        eb:ClearFocus()
    end)
    r.qtyOk:SetScript("OnClick", function() CommitQty(r) end)

    return r
end

local function PaintRow(r, rec)
    if not r.entry or r.entry.id ~= rec.id then
        r.searchReady = false
    end
    r.entry = rec
    r.icon:SetTexture(IconOf(rec))
    r.name:SetText(NameOf(rec))
    r.name:SetWidth(math.max(80, (r:GetWidth() or BASE_W) - 30 - RIGHT_W))

    if not r.gapBox:HasFocus() then
        r.gapBox:SetText(tostring((ns.AutoBuy and ns.AutoBuy.GapOf and ns.AutoBuy.GapOf(rec.id)) or 1))
    end
    if not r.capBox:HasFocus() then
        local p = (ns.AutoBuy and ns.AutoBuy.PriceOf and ns.AutoBuy.PriceOf(rec.id)) or rec.autoP or 0
        r.capBox:SetText(MoneyPlain(p))
    end
    if not r.qtyBox:HasFocus() then
        r.qtyBox:SetText(tostring((ns.AutoBuy and ns.AutoBuy.QtyOf and ns.AutoBuy.QtyOf(rec.id)) or 100))
    end
    PaintScanInfo(r, rec.id)
end

--------------------------------------------------------------------------- 渲染

Render = function()
    if not (frame and listContent) then return end
    local recs = SortRecords(Records())
    local w = listContent:GetWidth() or (BASE_W - PAD * 2)
    local y = 0

    -- 先按条数把内容区高度撑开: 即使某一行绘制报错, 后面的行也不会被高度裁掉
    listContent:SetHeight(math.max(1, #recs * ROW_H))

    for i, rec in ipairs(recs) do
        local r = rows[i]
        if not r then
            local okNew, newRow = pcall(NewRow)
            if not okNew then
                if not rowErrShown then
                    rowErrShown = true
                    ns.Print("|cffff5555自动购买行创建失败:|r " .. tostring(newRow))
                end
                break
            end
            r = newRow
            rows[i] = r
        end
        r:Show()
        r:ClearAllPoints()
        r:SetPoint("TOPLEFT", listContent, "TOPLEFT", 0, -y)
        r:SetWidth(w)

        -- 单行绘制失败不能拖垮整个列表 (以前一报错就停, 后面几条全消失)
        local okRow, errRow = pcall(PaintRow, r, rec)
        if not okRow and not rowErrShown then
            rowErrShown = true
            ns.Print("|cffff5555自动购买行绘制失败:|r " .. tostring(errRow))
        end
        y = y + ROW_H
    end
    for i = #recs + 1, #rows do rows[i]:Hide() end

    listContent:SetHeight(math.max(1, #recs * ROW_H))
    shownCount = #recs
    if emptyText then emptyText:SetShown(#recs == 0) end
    if statusText then statusText:SetText(StatusLine(#recs)) end
end

-- AutoBuy 每扫完一条调这里: 只刷这一行的结论, 不重排、不打断正在编辑的输入框
function M.RefreshRow(id)
    if not (frame and frame:IsShown()) then return end
    for i = 1, shownCount do
        local r = rows[i]
        if r and r:IsShown() and r.entry and r.entry.id == id then
            PaintScanInfo(r, id)
        end
    end
    if statusText then statusText:SetText(StatusLine(shownCount)) end
end

-- 列表本身变了 (材料行新增/删除条目) 时全量重画
function M.RefreshAll()
    if frame and frame:IsShown() then Render() end
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
    return math.max(320, w), math.max(280, h)
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

    local f = CreateFrame("Frame", "WOWGoldMakerAutoBuyFrame", UIParent)
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
            db.abpos = { point = point, relPoint = relPoint, x = math.floor(x), y = math.floor(y) }
        end
    end)
    tinsert(UISpecialFrames, f:GetName())
    frame = f

    -- 和商人货架同档, 但比它高 4: 两个窗口同时开时不会被压住
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
    title:SetText("自动购买")

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

    scroll:SetScript("OnSizeChanged", function(self, w)
        if listContent then listContent:SetWidth(w) end
        Render()
    end)

    scroll:SetScript("OnMouseWheel", function(_, delta)
        local max = math.max(0, (listContent:GetHeight() or 1) - (scroll:GetHeight() or 1))
        local v = (scroll:GetVerticalScroll() or 0) - (delta or 0) * 44
        if v < 0 then v = 0 elseif v > max then v = max end
        scroll:SetVerticalScroll(v)
    end)

    emptyText = T.Text(content, 9, C.faint)
    emptyText:SetPoint("CENTER", content, "CENTER", 0, 0)
    emptyText:SetText("还没有自动购买 —— 在材料行点「自动」设一个单价上限")
    emptyText:Hide()

    local hint = T.Text(content, 8, C.faint)
    hint:SetPoint("BOTTOMLEFT", content, "BOTTOMLEFT", PAD, 10)
    hint:SetText("扫描自动运行 · 行上出现「买入」时点开买入窗 · 关闭窗口即停")
    hint:SetWordWrap(false)

    local pos = db and db.abpos
    f:ClearAllPoints()
    if type(pos) == "table" and pos.point then
        f:SetPoint(pos.point, UIParent, pos.relPoint or pos.point, pos.x or 0, pos.y or 0)
    else
        f:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
    end

    -- 窗口就是扫描开关: 显示就扫, 关闭/ESC 就停
    f:SetScript("OnShow", function()
        if ns.AutoBuy and ns.AutoBuy.StartPage then ns.AutoBuy.StartPage() end
        Render()
        pcall(function() f:Raise() end)
    end)
    f:SetScript("OnHide", function()
        if ns.AutoBuy and ns.AutoBuy.StopPage then ns.AutoBuy.StopPage() end
        -- 窗口关了, 下次重开时重新走"搜索 -> 购买"
        for i = 1, #rows do rows[i].searchReady = false end
    end)

    -- 物品名字回包后重画 (快照里没有的 ID 会晚一点拿到本地化名)
    C_Timer.NewTicker(2, function()
        if frame and frame:IsShown() then pcall(Render) end
    end)

    f:Hide()
    return f
end

--------------------------------------------------------------------------- 对外

function M.Show()
    local ok, f = pcall(Build)
    if not ok then
        ns.Print("|cffff5555自动购买窗口打不开:|r " .. tostring(f))
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

function M.IsShown()
    return (frame and frame:IsShown()) and true or false
end
