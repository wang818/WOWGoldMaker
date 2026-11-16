---------------------------------------------------------------------------
-- WOWGoldMaker / UI.lua
-- 单页主界面:
--   第一行  头像 · 问候 · 金币 · 等级 · 在线时长 · 设置 · 关闭
--   第二行  专业页签 (急救 / 烹饪) + 配方/材料切换
--   其余    当前专业的可生产列表 (默认急救), 直接内嵌, 不再开二级窗口
---------------------------------------------------------------------------

local ADDON, ns = ...

local T = ns.T
local C = T.C

ns.UI = ns.UI or {}

-- 设计稿基准: 内部坐标全按 440x356 写, 运行时整体等比缩放
local BASE_W, BASE_H  = 440, 356
local PANEL_PCT       = 0.90   -- 面板宽高 = 游戏窗口宽高的 90%
local CONTENT_PAD     = 24     -- 面板内边距
local SCALE_MAX       = 2.6    -- 缩放上限, 防止 4K 下贴图糊成一片

-- 单页布局 (设计坐标)
local PAD      = 20      -- 左右内边距
local TOP_Y    = -14     -- 顶栏顶部
local TAB_Y    = -56     -- 页签行顶部
local TAB_H    = 24      -- 页签 / 小按钮高度
local TAB_W    = 84      -- 专业页签宽度
local LIST_Y   = -90     -- 列表区顶部
local LIST_BOT = 14      -- 列表区距面板底部
local ROW_H    = 30      -- 列表行高
local BAR_W    = 3       -- 滚动指示条宽度

local frame, content
local contentW = BASE_W
local refs = {}
local tabs = {}            -- key -> 页签按钮
local profIcons = {}       -- key -> 页签图标纹理
local rows = {}            -- 列表行池

local scroll, listContent, track, thumb

local curKey  = "first-aid"   -- 当前专业
local curMode = "list"        -- "list" 配方 | "mats" 材料汇总

local iconsPending = true
local iconsTries = 0
local tickCount = 0
local sessionStart
local selfCheckDone

local UpdateTabs, RenderList, UpdateThumb

--------------------------------------------------------------------------- 数据

local function ClassColorHex()
    local ok, _, classFile = pcall(UnitClass, "player")
    local cc = (ok and classFile and RAID_CLASS_COLORS[classFile]) or nil
    if cc then
        return format("%02x%02x%02x", cc.r * 255, cc.g * 255, cc.b * 255)
    end
    return "e8c25a"
end

local function GreetingByHour()
    local h = tonumber(date("%H")) or 12
    if h < 5 then return "夜深了"
    elseif h < 12 then return "早上好"
    elseif h < 14 then return "中午好"
    elseif h < 19 then return "下午好"
    end
    return "晚上好"
end

local function UpdateGreeting()
    if not refs.greeting then return end
    local name = UnitName("player") or "冒险者"
    refs.greeting:SetText(format("%s, |cff%s%s|r",
        GreetingByHour(), ClassColorHex(), name))
end

-- 取玩家等级: 这个客户端的 UnitLevel 可能缺失或返回 nil, 逐级回退
local function PlayerLevel()
    if type(UnitLevel) == "function" then
        local ok, v = pcall(UnitLevel, "player")
        if ok and type(v) == "number" and v > 0 then return v end
    end
    if type(UnitEffectiveLevel) == "function" then
        local ok, v = pcall(UnitEffectiveLevel, "player")
        if ok and type(v) == "number" and v > 0 then return v end
    end
    return nil
end

-- 取背包金币(铜), 失败返回 0
local function PlayerMoney()
    if type(GetMoney) ~= "function" then return 0 end
    local ok, v = pcall(GetMoney)
    if ok and type(v) == "number" then return v end
    return 0
end

-- 写文本并暴露错误: 同一错误只提示一次, 避免刷屏
local lastErr = {}
local function SetText(fs, txt, tag)
    if not fs then
        if lastErr[tag] ~= "nil" then
            lastErr[tag] = "nil"
            ns.Print("|cffff5555[" .. tag .. "] 控件不存在|r")
        end
        return false
    end
    local ok, err = pcall(fs.SetText, fs, txt)
    if not ok then
        local msg = tostring(err)
        if lastErr[tag] ~= msg then
            lastErr[tag] = msg
            ns.Print("|cffff5555[" .. tag .. "] 写入失败: " .. msg .. "|r")
            pcall(geterrorhandler(), "WOWGoldMaker [" .. tag .. "] " .. msg)
        end
        return false
    end
    lastErr[tag] = nil
    return true
end

-- 货币配色: 金=亮黄, 银=银白, 铜=古铜
local MONEY_C = {
    gold   = "|cffffd100",
    silver = "|cffe6edf5",
    copper = "|cffb87333",
}

local function Comma(n)
    local s = tostring(math.floor(n or 0))
    local rev = s:reverse():gsub("(%d%d%d)", "%1,")
    return (rev:reverse():gsub("^,", ""))
end

-- 一行显示: 1,234金 56银 78铜 (三段各自配色)
local function MoneyLine(money)
    local g = math.floor(money / 10000)
    local s = math.floor((money % 10000) / 100)
    local c = money % 100
    local gText = g >= 100000 and format("%.1f万", g / 10000) or Comma(g)
    return format("%s%s|r|cffffffff金|r %s%d|r|cffffffff银|r %s%d|r|cffffffff铜|r",
        MONEY_C.gold, gText, MONEY_C.silver, s, MONEY_C.copper, c)
end

function ns.UI.RefreshStats()
    if not refs.gold then
        if lastErr.build ~= "notopbar" then
            lastErr.build = "notopbar"
            ns.Print("|cffff5555顶栏未创建 (refs.gold = nil)|r")
        end
        return
    end
    lastErr.build = nil

    local money = PlayerMoney()
    local gold   = math.floor(money / 10000)
    local silver = math.floor((money % 10000) / 100)
    local copper = money % 100

    -- 金额: 格式化失败则退回纯数字, 不让一处出错吞掉整行
    local okS, goldText = pcall(MoneyLine, money)
    if not okS or type(goldText) ~= "string" then
        goldText = tostring(gold)
    end

    SetText(refs.gold, goldText, "gold")

    local lvl = PlayerLevel()
    SetText(refs.level, lvl and ("Lv." .. lvl) or "Lv.?", "level")

    -- 供 /wgm debug 使用
    ns.UI.lastStats = {
        money = money, gold = gold, silver = silver, copper = copper,
        level = lvl, goldText = goldText,
    }
end

-- /wgm debug: 打印内部状态
function ns.UI.DebugInfo()
    print("|cffe8c25a[WGM 调试]|r")
    print("  refs.gold:", tostring(refs.gold), "| greeting:", tostring(refs.greeting))
    print("  frame:", tostring(frame ~= nil), "| content:", tostring(content ~= nil))
    print("  当前专业:", tostring(curKey), "| 模式:", tostring(curMode),
        "| 行池:", tostring(#rows))
    print("  db:", tostring(ns.DB() ~= nil))
    local okM, money = pcall(GetMoney)
    print("  GetMoney 存在:", tostring(type(GetMoney) == "function"), "| 调用:", tostring(okM), "=", tostring(money))
    local okL, lvl = pcall(UnitLevel, "player")
    print("  UnitLevel:", tostring(okL), "=", tostring(lvl), "| PlayerLevel():", tostring(PlayerLevel()))
    for _, k in ipairs({ "gold", "level", "time" }) do
        local fs = refs[k]
        local txt = "nil"
        if fs then local ok2, t = pcall(fs.GetText, fs); txt = ok2 and tostring(t) or "ERR" end
        print("  " .. k .. ".text:", txt)
    end
    local s = ns.UI.lastStats
    if s then
        print("  lastStats: money=" .. tostring(s.money) .. " 金=" .. tostring(s.gold)
            .. " 银=" .. tostring(s.silver) .. " 铜=" .. tostring(s.copper)
            .. " 等级=" .. tostring(s.level))
    else
        print("  lastStats: nil (刷新函数从未成功执行)")
    end
end

--------------------------------------------------------------------------- 尺寸

-- 游戏窗口尺寸 (UIParent 的实际像素宽高, 已包含 UI 缩放)
local function WindowSize()
    local w, h = 1024, 768
    local okW, vw = pcall(function() return UIParent:GetWidth() end)
    if okW and type(vw) == "number" and vw > 0 then w = vw end
    local okH, vh = pcall(function() return UIParent:GetHeight() end)
    if okH and type(vh) == "number" and vh > 0 then h = vh end
    return w, h
end

-- 面板目标尺寸 = 窗口宽高 x 90%
local function PanelSize()
    local sw, sh = WindowSize()
    return math.max(320, math.floor(sw * PANEL_PCT)),
           math.max(280, math.floor(sh * PANEL_PCT))
end

-- 内容布局: 高度方向填满为准, 宽度不足时以宽度为准
-- 返回: 缩放比 k, 内容宽度 cw (未缩放的本地坐标), 内容高度 ch
local function ComputeLayout(pw, ph)
    local innerW = pw - CONTENT_PAD * 2
    local innerH = ph - CONTENT_PAD * 2
    local kH = innerH / BASE_H
    local kW = innerW / BASE_W
    local k = math.min(kH, kW)
    if not (type(k) == "number" and k > 0) then k = 1 end
    if k > SCALE_MAX then k = SCALE_MAX end

    -- 面板比设计稿宽时, 把多出来的横向空间交给内容 (列表跟着变宽), 而不是留白
    local cw = innerW / k
    if cw < BASE_W then cw = BASE_W end

    return k, cw, BASE_H
end

--------------------------------------------------------------------------- 小控件

-- 顶栏 / 页签用的小按钮 (比 T.Button 更矮更紧凑)
local function MakeMiniButton(parent, w, h, label)
    local b = CreateFrame("Button", nil, parent)
    b:SetSize(w, h)

    local bg = b:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints(true)
    bg:SetTexture(T.PATH .. "btn")
    bg:SetVertexColor(1, 1, 1, 0.10)
    b.bg = bg

    local txt = T.Text(b, 10, C.muted)
    txt:SetPoint("CENTER")
    txt:SetText(label)
    b.text = txt

    b:SetScript("OnEnter", function()
        bg:SetVertexColor(1, 1, 1, 0.17)
        txt:SetTextColor(T.rgb(C.text))
    end)
    b:SetScript("OnLeave", function()
        bg:SetVertexColor(1, 1, 1, 0.10)
        txt:SetTextColor(T.rgb(C.muted))
    end)
    return b
end

--------------------------------------------------------------------------- 构建: 顶栏

local function BuildTopBar(f)
    -- 头像 (圆形蒙版)
    local coin = f:CreateTexture(nil, "ARTWORK")
    coin:SetTexture("Interface\\Icons\\INV_Misc_Coin_01")
    coin:SetSize(26, 26)
    coin:SetPoint("TOPLEFT", f, "TOPLEFT", PAD, TOP_Y)
    coin:SetMask(T.PATH .. "circle")
    refs.coin = coin

    local coinGlow = T.Glow(f, 62, C.gold, 0.16, "glow-soft")
    coinGlow:SetPoint("CENTER", coin, "CENTER")
    refs.coinGlow = coinGlow
    if ns.DB().animations then
        local ag = coinGlow:CreateAnimationGroup()
        ag:SetLooping("BOUNCE")
        local a = ag:CreateAnimation("Alpha")
        a:SetFromAlpha(0.10)
        a:SetToAlpha(0.22)
        a:SetDuration(2.8)
        a:SetSmoothing("IN_OUT")
        ag:Play()

        -- 图标呼吸: 只用 Alpha
        -- 本客户端循环播放 Scale / Translation 会把每轮增量累加到当前变换上, 几轮后图标
        -- 会持续放大直至铺满屏幕。Alpha 是覆盖式标量且被 clamp 在 0-1, 循环安全。
        local bob = coin:CreateAnimationGroup()
        bob:SetLooping("BOUNCE")
        local sc = bob:CreateAnimation("Alpha")
        sc:SetFromAlpha(0.82)
        sc:SetToAlpha(1)
        sc:SetDuration(3.2)
        sc:SetSmoothing("IN_OUT")
        bob:Play()
        coin.bobAG = bob
    end

    -- 问候 (限宽, 名字过长时截断, 不把后面的金币挤出去)
    local greeting = T.Text(f, 12, C.text)
    greeting:SetPoint("LEFT", coin, "RIGHT", 9, 0)
    greeting:SetWidth(120)
    greeting:SetWordWrap(false)
    refs.greeting = greeting

    -- 金币 (三段配色, 单行)
    local gold = T.Text(f, 11, C.gold)
    gold:SetPoint("LEFT", greeting, "RIGHT", 14, 0)
    refs.gold = gold

    -- 右侧: 关闭 / 设置 / 在线 / 等级 (从右往左排, 不受左侧文字长度影响)
    local close = T.CloseButton(f, function() ns.UI.Hide() end)
    close:SetPoint("TOPRIGHT", f, "TOPRIGHT", -(PAD - 6), TOP_Y)

    local settingsBtn = MakeMiniButton(f, 52, 20, "设置")
    settingsBtn:SetPoint("RIGHT", close, "LEFT", -8, 0)
    settingsBtn:SetScript("OnClick", function() ns.OpenSettings() end)

    -- 在线时长 / 等级从右往左排, 不受左侧名字长度影响
    local time = T.Text(f, 11, C.muted)
    time:SetPoint("RIGHT", settingsBtn, "LEFT", -14, 0)
    refs.time = time

    local level = T.Text(f, 11, C.text)
    level:SetPoint("RIGHT", time, "LEFT", -12, 0)
    refs.level = level

    -- 分隔线
    local divider = T.Line(f, BASE_W - PAD * 2, 1, C.white, 0.07)
    divider:SetPoint("TOPLEFT", f, "TOPLEFT", PAD, TAB_Y + 9)
    refs.divider = divider
end

--------------------------------------------------------------------------- 构建: 页签行

local function BuildTabs(f)
    local list = (ns.Prof and ns.Prof.LIST) or {}
    local x = PAD

    for _, prof in ipairs(list) do
        local tab = CreateFrame("Button", nil, f)
        tab:SetSize(TAB_W, TAB_H)
        tab:SetPoint("TOPLEFT", f, "TOPLEFT", x, TAB_Y)
        x = x + TAB_W + 6

        local bg = tab:CreateTexture(nil, "BACKGROUND")
        bg:SetAllPoints(true)
        bg:SetTexture(T.PATH .. "btn")
        bg:SetVertexColor(1, 1, 1, 0.07)
        tab.bg = bg

        local icon = tab:CreateTexture(nil, "ARTWORK")
        icon:SetSize(14, 14)
        icon:SetPoint("LEFT", 9, 0)
        icon:SetTexture((ns.Prof.Icon and ns.Prof.Icon(prof.key))
            or "Interface\\Icons\\INV_Misc_QuestionMark")
        icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
        profIcons[prof.key] = icon

        local txt = T.Text(tab, 11, C.muted)
        txt:SetPoint("LEFT", icon, "RIGHT", 5, 0)
        txt:SetText(prof.name)
        tab.text = txt

        tab:SetScript("OnClick", function()
            curKey = prof.key
            if UpdateTabs then UpdateTabs() end
            if RenderList then RenderList() end
        end)
        tab:SetScript("OnEnter", function()
            if curKey ~= prof.key then bg:SetVertexColor(1, 1, 1, 0.13) end
        end)
        tab:SetScript("OnLeave", function()
            if curKey ~= prof.key then bg:SetVertexColor(1, 1, 1, 0.07) end
        end)

        tabs[prof.key] = tab
    end

    -- 右侧: 配方 / 材料汇总 切换
    local sw = MakeMiniButton(f, 76, TAB_H, "材料汇总")
    sw:SetPoint("TOPRIGHT", f, "TOPRIGHT", -(PAD - 6), TAB_Y)
    sw:SetScript("OnClick", function()
        curMode = (curMode == "list") and "mats" or "list"
        sw.text:SetText(curMode == "list" and "材料汇总" or "配方列表")
        if RenderList then RenderList() end
    end)
    refs.switchBtn = sw
end

UpdateTabs = function()
    for key, tab in pairs(tabs) do
        local on = (key == curKey)
        if on then
            tab.bg:SetVertexColor(T.rgb(C.gold))
            tab.text:SetTextColor(T.rgb(C.ink))
        else
            tab.bg:SetVertexColor(1, 1, 1, 0.07)
            tab.text:SetTextColor(T.rgb(C.muted))
        end
    end
end

--------------------------------------------------------------------------- 构建: 列表

-- 行宽 / 文本宽度随面板宽度自适应
local function RelayoutRows(w)
    if not (w and w > 0) then return end
    for i = 1, #rows do
        local r = rows[i]
        r:SetWidth(w)
        r.title:SetWidth(math.max(80, w * 0.34))
        r.mats:SetWidth(math.max(60, w * 0.44))
    end
end

UpdateThumb = function()
    if not (thumb and track and scroll and listContent) then return end
    local viewH = scroll:GetHeight() or 1
    local ch = listContent:GetHeight() or 1
    local maxScroll = ch - viewH
    if maxScroll <= 0 then
        thumb:Hide()
        return
    end
    thumb:Show()
    local h = math.max(20, viewH * (viewH / ch))
    thumb:SetHeight(h)

    local p = (scroll:GetVerticalScroll() or 0) / maxScroll
    if p < 0 then p = 0 elseif p > 1 then p = 1 end

    thumb:ClearAllPoints()
    thumb:SetPoint("TOPLEFT", track, "TOPLEFT", 0, -((viewH - h) * p))
end

local function BuildList(f)
    scroll = CreateFrame("ScrollFrame", nil, f)
    scroll:SetPoint("TOPLEFT", f, "TOPLEFT", PAD, LIST_Y)
    scroll:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -(PAD + 8), LIST_BOT)
    scroll:EnableMouseWheel(true)

    listContent = CreateFrame("Frame", nil, scroll)
    listContent:SetSize(BASE_W - PAD * 2 - 8, 1)
    scroll:SetScrollChild(listContent)

    scroll:SetScript("OnMouseWheel", function(self, delta)
        local maxScroll = math.max(0, (listContent:GetHeight() or 0) - (self:GetHeight() or 0))
        local v = (self:GetVerticalScroll() or 0) - delta * (ROW_H * 2)
        if v < 0 then v = 0 elseif v > maxScroll then v = maxScroll end
        self:SetVerticalScroll(v)
        if UpdateThumb then UpdateThumb() end
    end)

    -- 面板尺寸变化时, 行宽跟着变 (ScrollFrame 的锚点已经自动伸缩)
    scroll:SetScript("OnSizeChanged", function(self, w)
        if listContent then listContent:SetWidth(w) end
        RelayoutRows(w)
        if UpdateThumb then UpdateThumb() end
    end)

    -- 右侧滚动指示条
    track = f:CreateTexture(nil, "ARTWORK")
    track:SetColorTexture(1, 1, 1, 0.05)
    track:SetWidth(BAR_W)
    track:SetPoint("TOP", scroll, "TOPRIGHT", 6, 0)
    track:SetPoint("BOTTOM", scroll, "BOTTOMRIGHT", 6, 0)

    thumb = f:CreateTexture(nil, "ARTWORK")
    thumb:SetColorTexture(T.rgb(C.gold, 0.5))
    thumb:SetWidth(BAR_W)
    thumb:SetHeight(24)
    thumb:SetPoint("TOPLEFT", track, "TOPLEFT", 0, 0)
    thumb:Hide()
end

--------------------------------------------------------------------------- 行池与渲染

local function GetRow(i)
    local r = rows[i]
    if r then return r end

    r = CreateFrame("Frame", nil, listContent)
    r:SetSize(BASE_W - PAD * 2 - 8, ROW_H)
    r:EnableMouse(true)

    r.bg = r:CreateTexture(nil, "BACKGROUND")
    r.bg:SetAllPoints(true)
    r.bg:SetColorTexture(1, 1, 1, 0)

    -- 物品图标 (拿不到时隐藏, 文字位置保持不变)
    r.icon = r:CreateTexture(nil, "ARTWORK")
    r.icon:SetSize(18, 18)
    r.icon:SetPoint("LEFT", 0, 0)
    r.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    r.icon:Hide()

    r.title = T.Text(r, 11, C.text)
    r.title:SetPoint("LEFT", 24, 0)
    r.title:SetWidth(140)
    r.title:SetWordWrap(false)

    r.mats = T.Text(r, 9, C.faint)
    r.mats:SetPoint("LEFT", r.title, "RIGHT", 10, 0)
    r.mats:SetWidth(180)
    r.mats:SetWordWrap(false)

    r.req = T.Text(r, 10, C.muted)
    r.req:SetPoint("RIGHT", -8, 0)
    r.req:SetJustifyH("RIGHT")

    r:SetScript("OnEnter", function(s)
        s.bg:SetColorTexture(1, 1, 1, 0.05)
    end)
    r:SetScript("OnLeave", function(s)
        s.bg:SetColorTexture(1, 1, 1, s.odd and 0.025 or 0)
    end)

    rows[i] = r
    return r
end

-- 行图标: 客户端还没缓存该物品时返回 nil, 这行就先不显示图标 (文字位置不变)
local function SetRowIcon(r, itemID)
    r.itemID = itemID
    local tex = (ns.Prof and ns.Prof.ItemIcon and ns.Prof.ItemIcon(itemID)) or nil
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
        if r:IsShown() and r.itemID and not r.icon:IsShown() then
            SetRowIcon(r, r.itemID)
        end
    end
end

RenderList = function()
    if not listContent or not scroll then return end
    if not (ns.Prof and ns.Prof.byKey and ns.Prof.byKey[curKey]) then return end

    local recipes = (ns.Prof.Get and ns.Prof.Get(curKey)) or {}
    local items

    if curMode == "mats" then
        items = (ns.Prof.Summarize and ns.Prof.Summarize(recipes)) or {}
    else
        items = recipes
    end

    local w = scroll:GetWidth() or (contentW - PAD * 2 - 8)
    if w < 100 then w = contentW - PAD * 2 - 8 end
    listContent:SetWidth(w)
    listContent:SetHeight(math.max(1, #items * ROW_H + 4))

    for i = 1, math.max(#rows, #items) do
        local r = rows[i]
        if i <= #items then
            if not r then r = GetRow(i) end
            r:SetPoint("TOPLEFT", 0, -((i - 1) * ROW_H))
            r:Show()
            r:SetWidth(w)
            r.title:SetWidth(math.max(80, w * 0.34))
            r.mats:SetWidth(math.max(60, w * 0.44))

            r.odd = (i % 2 == 0)
            r.bg:SetColorTexture(1, 1, 1, r.odd and 0.025 or 0)

            if curMode == "mats" then
                local m = items[i]
                r.title:SetText(m.name or "?")
                r.mats:SetText("")
                r.req:SetText(format("|cffe8c25a×%d|r", m.count or 0))
                SetRowIcon(r, m.id)
            else
                local rec = items[i]
                local made = (rec.made and rec.made > 1)
                    and format(" |cff9d9d9d×%d|r", rec.made) or ""
                r.title:SetText((rec.name or "?") .. made)
                r.mats:SetText(ns.Prof.MatsLine and ns.Prof.MatsLine(rec.mats) or "")
                r.req:SetText(format("|cff8a929e[%d]|r", rec.req or 0))
                SetRowIcon(r, rec.item)
            end
        elseif r then
            r:Hide()
        end
    end

    scroll:SetVerticalScroll(0)
    if UpdateThumb then UpdateThumb() end
end

--------------------------------------------------------------------------- 专业图标补全

local QUESTION = "Interface\\Icons\\INV_Misc_QuestionMark"

local function RefreshProfIcons()
    if not (ns.Prof and ns.Prof.Icon) then return true end
    local resolved = true
    for key, tex in pairs(profIcons) do
        local path = ns.Prof.Icon(key)
        if path then
            if path == QUESTION then
                resolved = false
            else
                pcall(tex.SetTexture, tex, path)
            end
        else
            resolved = false
        end
    end
    return resolved
end

function ns.UI.RefreshProfIcons()
    iconsPending = true
    iconsTries = 0
    return RefreshProfIcons()
end

--------------------------------------------------------------------------- 开关与动画

local function BuildShowAnimations(f)
    local showAG = f:CreateAnimationGroup()
    local a = showAG:CreateAnimation("Alpha")
    a:SetFromAlpha(0)
    a:SetToAlpha(1)
    a:SetDuration(0.18)
    a:SetSmoothing("OUT")
    local s = showAG:CreateAnimation("Scale")
    s:SetScaleFrom(0.96, 0.96)
    s:SetScaleTo(1, 1)
    s:SetDuration(0.18)
    s:SetSmoothing("OUT")
    f.showAG = showAG

    local hideAG = f:CreateAnimationGroup()
    local ha = hideAG:CreateAnimation("Alpha")
    ha:SetFromAlpha(1)
    ha:SetToAlpha(0)
    ha:SetDuration(0.14)
    ha:SetSmoothing("IN")
    local hs = hideAG:CreateAnimation("Scale")
    hs:SetScaleFrom(1, 1)
    hs:SetScaleTo(0.97, 0.97)
    hs:SetDuration(0.14)
    hs:SetSmoothing("IN")
    hideAG:SetScript("OnFinished", function()
        f:SetAlpha(1)
        f:Hide()
    end)
    f.hideAG = hideAG
end

--------------------------------------------------------------------------- 构建

-- 分步构建: 单步失败提示到聊天框, 并转发给客户端错误处理器写入 General.log ([E][Lua])
local function SafeStep(fn, name, ...)
    local ok, err = pcall(fn, ...)
    if not ok then
        local msg = "WOWGoldMaker 构建 " .. name .. " 失败: " .. tostring(err)
        ns.Print("|cffff5555构建 " .. name .. " 失败:|r " .. tostring(err))
        pcall(geterrorhandler(), msg)
    end
end

function ns.UI.Build()
    if frame then return frame end

    local f = CreateFrame("Frame", "WOWGoldMakerFrame", UIParent)
    f:SetFrameStrata("DIALOG")

    -- 面板尺寸 = 游戏窗口宽高的 90%
    local pw, ph = PanelSize()
    f:SetSize(pw, ph)
    f:SetMovable(true)
    f:EnableMouse(true)
    f:SetClampedToScreen(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", function(s)
        s:StopMovingOrSizing()
        ns.SavePosition(s)
    end)
    f:SetScript("OnShow", function()
        SafeStep(UpdateGreeting, "UpdateGreeting")
        SafeStep(ns.UI.RefreshStats, "RefreshStats")
        if RenderList then SafeStep(RenderList, "RenderList") end
    end)
    tinsert(UISpecialFrames, f:GetName())   -- ESC 关闭
    frame = f
    ns.frame = f

    -- 内容容器: 高度固定为设计稿, 宽度随面板宽度伸展, 整体等比缩放居中
    content = CreateFrame("Frame", nil, f)
    content:SetPoint("CENTER", f, "CENTER", 0, 0)
    ns.UI.content = content

    local k, cw, ch = ComputeLayout(pw, ph)
    contentW = cw
    content:SetSize(cw, ch)
    content:SetScale(k)

    -- 面板背景 (九宫格拉伸: 圆角不会被拉变形)
    local bg = f:CreateTexture(nil, "BACKGROUND", nil, -7)
    bg:SetAllPoints(true)
    bg:SetTexture(T.PATH .. "panel")
    pcall(function()
        bg:SetTextureSliceMargins(24, 24, 24, 24)
        bg:SetTextureSliceMode(Enum.UITextureSliceMode.Stretched)
    end)
    f.bg = bg

    -- 双色氛围光斑 (按面板比例定位, 面板变大时跟着放大)
    local glowA = T.Glow(f, 250 * k, C.gold, 0.07, "glow-soft")
    glowA:SetPoint("CENTER", f, "TOPLEFT", pw * 0.22, -ph * 0.26)
    local glowB = T.Glow(f, 230 * k, C.teal, 0.06, "glow-soft")
    glowB:SetPoint("CENTER", f, "BOTTOMRIGHT", -pw * 0.22, ph * 0.20)
    f.glowA, f.glowB = glowA, glowB
    if ns.DB().animations then
        -- 明暗呼吸代替位移: Translation 循环在该客户端会累积偏移, 光斑会慢慢飘出屏幕
        local agA = glowA:CreateAnimationGroup()
        agA:SetLooping("BOUNCE")
        local aA = agA:CreateAnimation("Alpha")
        aA:SetFromAlpha(0.05)
        aA:SetToAlpha(0.10)
        aA:SetDuration(7)
        aA:SetSmoothing("IN_OUT")
        agA:Play()

        local agB = glowB:CreateAnimationGroup()
        agB:SetLooping("BOUNCE")
        local aB = agB:CreateAnimation("Alpha")
        aB:SetFromAlpha(0.04)
        aB:SetToAlpha(0.09)
        aB:SetDuration(8)
        aB:SetSmoothing("IN_OUT")
        agB:Play()
    end

    -- 内容全部挂到居中缩放的容器上; 显隐动画留在面板本体,
    -- 否则动画的 Scale 会把容器的缩放比覆盖成 1, 内容瞬间缩回 440。
    SafeStep(BuildTopBar, "TopBar", content)
    SafeStep(BuildTabs, "Tabs", content)
    SafeStep(BuildList, "List", content)
    SafeStep(BuildShowAnimations, "Animations", f)

    sessionStart = GetTime()

    -- 每秒刷新: 在线时长 + 金币/等级 (不依赖 Show() 路径, 保证数据一定被写入)
    C_Timer.NewTicker(1, function()
        if not (frame and frame:IsShown()) then return end
        tickCount = tickCount + 1

        if refs.time then
            pcall(function() refs.time:SetText(T.FormatDuration(GetTime() - sessionStart)) end)
        end
        pcall(ns.UI.RefreshStats)

        -- 页签图标延迟补全 (首次解析可能是问号占位, 最多重试 20 次)
        if iconsPending and iconsTries < 20 then
            iconsTries = iconsTries + 1
            pcall(function() iconsPending = not RefreshProfIcons() end)
        end
        -- 行图标每 3 秒补一次 (物品数据回包较慢, 逐秒查会浪费)
        if tickCount % 3 == 0 then
            pcall(RefreshRowIcons)
        end

        -- 兜底: 头像不该有任何缩放。一旦被动画改成别的值(该客户端循环动画会累积
        -- 增量, 表现为图标持续放大直至铺满屏幕), 立即停掉动画并归位。
        if refs.coin then
            pcall(function()
                local s = refs.coin:GetScale()
                if s and math.abs(s - 1) > 0.001 then
                    if refs.coin.bobAG then refs.coin.bobAG:Stop() end
                    refs.coin:SetScale(1)
                end
            end)
        end
    end)

    ns.UI.ApplyPosition()

    -- 分辨率 / UI 缩放变化后重算面板尺寸
    local watcher = CreateFrame("Frame")
    local okReg = pcall(function()
        watcher:RegisterEvent("UI_SCALE_CHANGED")
        watcher:RegisterEvent("DISPLAY_SIZE_CHANGED")
    end)
    if okReg then
        watcher:SetScript("OnEvent", function()
            pcall(ns.UI.ApplyResponsiveSize)
        end)
    end

    -- 首次渲染 (默认急救清单, 不必等 Show)
    SafeStep(function()
        if UpdateTabs then UpdateTabs() end
        if RenderList then RenderList() end
    end, "FirstRender")

    -- 一次性自检: 构建后 2 秒把真实状态打到聊天框, 省得再去查
    C_Timer.After(2, function()
        if selfCheckDone then return end
        selfCheckDone = true
        local s = ns.UI.lastStats
        local function txt(k)
            local fs = refs[k]
            if not fs then return "无控件" end
            local ok, t = pcall(fs.GetText, fs)
            return ok and tostring(t) or "读取失败"
        end
        ns.Print(format("自检 · 顶栏=%s 列表=%s 行=%d | 金币=%s 等级=%s",
            refs.gold and "已创建" or "缺失",
            listContent and "已创建" or "缺失",
            #rows,
            txt("gold"), txt("level")))
        if s then
            ns.Print(format("自检 · 铜=%d 等级=%s 专业=%s 模式=%s",
                s.money or 0, tostring(s.level), curKey, curMode))
        end
    end)

    return f
end

--------------------------------------------------------------------------- 对外

function ns.UI.ApplyPosition()
    if not frame then return end
    local db = ns.DB()
    local sw, sh = WindowSize()
    local fw = frame:GetWidth() or 0
    local fh = frame:GetHeight() or 0

    -- 面板已经占满窗口大半, 保存的偏移要收进剩余空间, 否则会被顶出屏幕
    local maxX = math.max(0, (sw - fw) / 2)
    local maxY = math.max(0, (sh - fh) / 2)
    local x = math.max(-maxX, math.min(maxX, db.pos.x or 0))
    local y = math.max(-maxY, math.min(maxY, db.pos.y or 0))

    -- 接近全屏时偏移没有意义, 直接居中
    if fw >= sw * 0.8 or fh >= sh * 0.8 then
        x, y = 0, 0
    end

    -- 锚点一律归一成 CENTER: 旧存档里可能存着 point="TOP" / relPoint="TOP"
    -- (老版本默认 y=120 拖动留下的), 只把偏移归零而锚点仍是 TOP 时, 面板会
    -- 顶部贴屏幕顶端 —— 表现就是"默认显示在顶部"。归一后偏移才是相对屏幕中心的。
    if db.pos.point ~= "CENTER" or db.pos.relPoint ~= "CENTER" then
        db.pos.point, db.pos.relPoint = "CENTER", "CENTER"
    end

    frame:ClearAllPoints()
    frame:SetPoint("CENTER", UIParent, "CENTER", x, y)
end

-- 按当前面板尺寸重排内容 (缩放比 + 内容宽度 + 分隔线 + 列表行)
function ns.UI.ApplyLayout()
    if not (frame and content) then return end
    local pw, ph = frame:GetWidth(), frame:GetHeight()
    if not (type(pw) == "number" and pw > 0) then
        pw, ph = PanelSize()
    end

    local k, cw, ch = ComputeLayout(pw, ph)
    contentW = cw
    content:SetSize(cw, ch)
    content:SetScale(k)

    if refs.divider then
        refs.divider:SetSize(cw - PAD * 2, 1)
    end
    if scroll and listContent then
        listContent:SetWidth(scroll:GetWidth() or (cw - PAD * 2 - 8))
        RelayoutRows(scroll:GetWidth())
    end
end

-- 重算面板尺寸与内容布局 (窗口大小、UI 缩放变化时调用)
function ns.UI.ApplyResponsiveSize()
    if not frame then return end
    local pw, ph = PanelSize()
    frame:SetSize(pw, ph)

    ns.UI.ApplyLayout()

    local k = content and content:GetScale() or 1
    if frame.glowA then
        frame.glowA:SetSize(250 * k, 250 * k)
        frame.glowA:ClearAllPoints()
        frame.glowA:SetPoint("CENTER", frame, "TOPLEFT", pw * 0.22, -ph * 0.26)
    end
    if frame.glowB then
        frame.glowB:SetSize(230 * k, 230 * k)
        frame.glowB:ClearAllPoints()
        frame.glowB:SetPoint("CENTER", frame, "BOTTOMRIGHT", -pw * 0.22, ph * 0.20)
    end

    ns.UI.ApplyPosition()
end

function ns.UI.Show()
    if not frame then return end
    SafeStep(function() ns.UI.ApplyPosition() end, "ApplyPosition")
    SafeStep(UpdateGreeting, "UpdateGreeting")
    SafeStep(ns.UI.RefreshStats, "RefreshStats")
    SafeStep(function()
        if UpdateTabs then UpdateTabs() end
        if RenderList then RenderList() end
    end, "RenderList")

    local animOK, animations = pcall(function() return ns.DB().animations end)
    if animations and frame.showAG and not frame:IsShown() then
        frame:Show()
        frame.showAG:Play()
    else
        frame:Show()
    end
end

-- 打开主面板并切到指定专业 (供 /wgm fa、专业页签、Core.OpenRecipes 使用)
function ns.UI.ShowProf(key, mode)
    if key and ns.Prof and ns.Prof.byKey and ns.Prof.byKey[key] then
        curKey = key
    end
    if mode == "list" or mode == "mats" then
        curMode = mode
        if refs.switchBtn then
            refs.switchBtn.text:SetText(curMode == "list" and "材料汇总" or "配方列表")
        end
    end
    ns.UI.Show()
end

function ns.UI.Hide()
    if not frame or not frame:IsShown() then return end
    if ns.DB().animations and frame.hideAG then
        frame.hideAG:Play()
    else
        frame:Hide()
    end
end

function ns.UI.Toggle()
    if frame and frame:IsShown() then
        ns.UI.Hide()
    else
        ns.UI.Show()
    end
end
