---------------------------------------------------------------------------
-- WOWGoldMaker / RecipeList.lua
-- 专业配方列表窗口: 从主面板的专业卡片点进来, 显示该专业全部可生产配方。
--
-- 结构: 图标+标题 / 滚动列表 / 底部切换(配方 ↔ 材料汇总)
-- 列表用行池复用, 滚轮滚动, 右侧细指示条。
---------------------------------------------------------------------------

local ADDON, ns = ...
local T, C = ns.T, ns.T.C

local W, H      = 460, 420
local PAD       = 26          -- 左右内边距
local HEADER_H  = 66          -- 标题区高度
local FOOTER_H  = 58          -- 底部按钮区高度
local LIST_W    = W - PAD * 2 -- 408
local LIST_H    = H - HEADER_H - FOOTER_H
local ROW_H     = 34          -- 每行: 配方名 + 材料
local BAR_W     = 3

local frame, titleFS, subFS, scroll, content, track, thumb, switchBtn, closeBtn
local rows = {}               -- 行池
local curKey = "first-aid"
local curMode = "list"        -- "list" | "mats"

--------------------------------------------------------------------------- 滚动指示

local function UpdateThumb()
    if not thumb then return end
    local ch = content:GetHeight()
    local maxScroll = ch - LIST_H
    if maxScroll <= 0 then
        thumb:Hide()
        return
    end
    thumb:Show()
    local visibleRatio = LIST_H / ch
    local h = math.max(24, LIST_H * visibleRatio)
    thumb:SetHeight(h)

    local p = (scroll:GetVerticalScroll() or 0) / maxScroll
    if p < 0 then p = 0 elseif p > 1 then p = 1 end

    thumb:ClearAllPoints()
    thumb:SetPoint("TOPLEFT", track, "TOPLEFT", 0, -((LIST_H - h) * p))
end

--------------------------------------------------------------------------- 行池

local function GetRow(i)
    local r = rows[i]
    if r then return r end

    r = CreateFrame("Frame", nil, content)
    r:SetSize(LIST_W, ROW_H)

    -- 物品图标 (取自游戏内数据, 拿不到时隐藏, 文字位置保持不变)
    r.icon = r:CreateTexture(nil, "ARTWORK")
    r.icon:SetSize(22, 22)
    r.icon:SetPoint("LEFT", 1, 0)
    r.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    r.icon:Hide()

    r.title = T.Text(r, 12, C.text)
    r.title:SetPoint("TOPLEFT", 30, -4)
    r.title:SetWidth(LIST_W - 34)
    r.title:SetWordWrap(false)

    r.mats = T.Text(r, 9, C.faint)
    r.mats:SetPoint("TOPLEFT", 34, -20)
    r.mats:SetWidth(LIST_W - 38)
    r.mats:SetWordWrap(false)

    rows[i] = r
    return r
end

--------------------------------------------------------------------------- 渲染

-- 行图标: 客户端还没缓存该物品时返回 nil, 这行就先不显示图标 (文字位置不变)
local function SetRowIcon(r, itemID)
    r.itemID = itemID
    local tex = ns.Prof.ItemIcon and ns.Prof.ItemIcon(itemID)
    if tex then
        r.icon:SetTexture(tex)
        r.icon:Show()
    else
        r.icon:Hide()
    end
end

-- 物品数据回包后补上图标 (首次打开时多数物品可能还没缓存)
local function RefreshRowIcons()
    for i = 1, #rows do
        local r = rows[i]
        if r and r:IsShown() and r.itemID then SetRowIcon(r, r.itemID) end
    end
end

local function Render()
    local prof = ns.Prof.byKey[curKey]
    if not prof then return end

    titleFS:SetText(prof.name)
    frame.icon:SetTexture((ns.Prof.Icon and ns.Prof.Icon(curKey)) or "Interface\\Icons\\INV_Misc_QuestionMark")

    local recipes = ns.Prof.Get(curKey) or {}
    local items

    if curMode == "mats" then
        items = ns.Prof.Summarize(recipes)
        subFS:SetText(format("%d 种材料 · 按总用量排序", #items))
    else
        items = recipes
        subFS:SetText(format("%d 条配方 · 按技能等级排序", #items))
    end

    -- 内容高度
    content:SetHeight(math.max(LIST_H, #items * ROW_H + 6))

    -- 复用已有行, 多余的隐藏
    for i = 1, math.max(#rows, #items) do
        local r = rows[i]
        if i <= #items then
            if not r then r = GetRow(i) end
            r:SetPoint("TOPLEFT", 0, -((i - 1) * ROW_H))
            r:Show()

            if curMode == "mats" then
                local m = items[i]
                r.title:SetText(format("|cff6f7783%2d.|r  %s  |cffffffff×%d|r", i, m.name, m.count))
                r.mats:SetText("")
                SetRowIcon(r, m.id)
            else
                local rec = items[i]
                local made = (rec.made and rec.made > 1) and format(" |cff9d9d9d×%d|r", rec.made) or ""
                r.title:SetText(format("|cff6f7783%2d.|r  %s%s   |cff8a929e[%d]|r",
                    i, rec.name, made, rec.req or 0))
                r.mats:SetText(ns.Prof.MatsLine(rec.mats))
                SetRowIcon(r, rec.item)
            end
        elseif r then
            r:Hide()
        end
    end

    scroll:SetVerticalScroll(0)
    UpdateThumb()
end

--------------------------------------------------------------------------- 构建

local function Build()
    local f = CreateFrame("Frame", "WOWGoldMakerRecipes", UIParent)
    f:SetSize(W, H)
    f:SetFrameStrata("DIALOG")
    f:SetClampedToScreen(true)
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
    f:SetPoint("CENTER")
    f:Hide()

    local bg = f:CreateTexture(nil, "BACKGROUND", nil, -7)
    bg:SetAllPoints(true)
    bg:SetTexture(T.PATH .. "panel-lg")
    f.bg = bg

    -- 顶部: 专业图标 + 名称 + 说明
    local icon = f:CreateTexture(nil, "ARTWORK")
    icon:SetSize(32, 32)
    icon:SetPoint("TOPLEFT", PAD, -20)
    icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    f.icon = icon

    titleFS = T.Text(f, 17, C.text)
    titleFS:SetPoint("TOPLEFT", icon, "TOPRIGHT", 12, 1)
    titleFS:SetText("急救")

    subFS = T.Text(f, 10, C.faint)
    subFS:SetPoint("TOPLEFT", titleFS, "BOTTOMLEFT", 0, -4)
    subFS:SetText("")

    local divider = T.Line(f, W - PAD * 2, 1, C.white, 0.08)
    divider:SetPoint("TOPLEFT", PAD, -HEADER_H + 2)

    closeBtn = T.CloseButton(f, function() f:Hide() end)
    closeBtn:SetPoint("TOPRIGHT", -18, -16)

    -- 滚动区
    scroll = CreateFrame("ScrollFrame", nil, f)
    scroll:SetSize(LIST_W, LIST_H)
    scroll:SetPoint("TOPLEFT", PAD, -HEADER_H)
    scroll:EnableMouseWheel(true)

    content = CreateFrame("Frame", nil, scroll)
    content:SetSize(LIST_W, LIST_H)
    scroll:SetScrollChild(content)

    scroll:SetScript("OnMouseWheel", function(self, delta)
        local maxScroll = math.max(0, content:GetHeight() - LIST_H)
        local v = (self:GetVerticalScroll() or 0) - delta * (ROW_H * 2)
        if v < 0 then v = 0 elseif v > maxScroll then v = maxScroll end
        self:SetVerticalScroll(v)
        UpdateThumb()
    end)

    -- 右侧滚动指示条
    track = f:CreateTexture(nil, "ARTWORK")
    track:SetColorTexture(1, 1, 1, 0.05)
    track:SetSize(BAR_W, LIST_H)
    track:SetPoint("TOPLEFT", PAD + LIST_W + 10, -HEADER_H)

    thumb = f:CreateTexture(nil, "ARTWORK")
    thumb:SetColorTexture(T.rgb(C.gold, 0.5))
    thumb:SetSize(BAR_W, 24)
    thumb:SetPoint("TOPLEFT", track, "TOPLEFT", 0, 0)
    thumb:Hide()

    -- 底部: 视图切换
    switchBtn = T.Button(f, 118, 32, "材料汇总", "secondary")
    switchBtn:SetPoint("BOTTOMLEFT", PAD, 14)
    switchBtn:SetScript("OnClick", function()
        curMode = (curMode == "list") and "mats" or "list"
        switchBtn.text:SetText(curMode == "list" and "材料汇总" or "配方列表")
        Render()
    end)

    local hint = T.Text(f, 9, C.faint)
    hint:SetPoint("BOTTOMRIGHT", -PAD, 22)
    hint:SetText("滚轮滚动 · 拖动移动 · ESC 关闭")

    frame = f
    tinsert(UISpecialFrames, "WOWGoldMakerRecipes")

    -- 位置记忆
    local db = ns.DB()
    if db.recipePos then
        local p = db.recipePos
        f:ClearAllPoints()
        if p.point and p.x and p.y then
            f:SetPoint(p.point, UIParent, p.point, p.x, p.y)
        end
    end
    f:SetScript("OnDragStop", function(s)
        s:StopMovingOrSizing()
        local point, _, _, x, y = s:GetPoint()
        db.recipePos = { point = point, x = x, y = y }
    end)
end

--------------------------------------------------------------------------- 对外

local function Open(key, mode)
    if not frame then
        local ok, err = pcall(Build)
        if not ok then
            ns.Print("|cffff5555配方窗口构建失败:|r " .. tostring(err))
            pcall(geterrorhandler(), "WOWGoldMaker 配方窗口构建失败: " .. tostring(err))
            return
        end
    end
    if key and ns.Prof.byKey[key] then curKey = key end
    curMode = mode or "list"
    if switchBtn then
        switchBtn.text:SetText(curMode == "list" and "材料汇总" or "配方列表")
    end
    frame:Show()
    local ok, err = pcall(Render)
    if not ok then
        ns.Print("|cffff5555配方列表渲染失败:|r " .. tostring(err))
        pcall(geterrorhandler(), "WOWGoldMaker 配方列表渲染失败: " .. tostring(err))
    end

    -- 物品图标/名称是懒加载的, 隔两轮补一次 (只补图标, 不重置滚动位置)
    C_Timer.After(1.5, function()
        if frame and frame:IsShown() then pcall(RefreshRowIcons) end
    end)
    C_Timer.After(5, function()
        if frame and frame:IsShown() then pcall(RefreshRowIcons) end
    end)
end

ns.RecipeList = {
    Open  = Open,
    Close = function() if frame then frame:Hide() end end,
    Toggle = function(key)
        if frame and frame:IsShown() then
            frame:Hide()
        else
            Open(key)
        end
    end,
}
