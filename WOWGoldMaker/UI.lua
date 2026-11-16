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

-- 设计稿基准: 内部坐标全按 440x440 写, 运行时整体等比缩放
-- 高度从 356 提到 440 是为了给列表行腾出两行文字的空间 (商品名+售价 / 材料+单价),
-- 只加高行不增高画布的话, 可见行数会从 8 行掉到 5 行。
local BASE_W, BASE_H  = 440, 440
local PANEL_PCT       = 0.50   -- 面板宽度 = 游戏窗口宽度的 50%
local PANEL_MAX_H     = 0.90   -- 面板高度上限 = 窗口高度的 90%
local PANEL_MARGIN    = 24     -- 面板右边缘离屏幕右边的距离
local CONTENT_PAD     = 24     -- 面板内边距
local SCALE_MAX       = 2.6    -- 缩放上限, 防止 4K 下贴图糊成一片

-- 单页布局 (设计坐标)
-- 0.5.3 起整块内容收窄了一档 (字号 -1, 行高 40→32, 顶栏/页签各收 10px):
-- 一屏可见行数从 8 行提到 11 行, 代价是行标题更容易被截断, 所以行悬停补了完整提示。
local PAD      = 20      -- 左右内边距
local TOP_Y    = -10     -- 顶栏顶部
local TAB_Y    = -44     -- 页签行顶部
local TAB_H    = 20      -- 页签 / 小按钮高度
local TAB_W    = 78      -- 专业页签宽度
local LIST_Y   = -72     -- 列表区顶部
local LIST_BOT = 10      -- 列表区距面板底部
local ROW_H    = 32      -- 列表行高 (商品两行; 材料格是图标+名字+金额三行)
local MAT_CELLS = 4      -- 材料最多 4 项 (烹饪里最多的配方就是 4 项)
local BAR_W    = 3       -- 滚动指示条宽度
local BTN_W    = 40      -- 行尾查价按钮宽度

-- 行内字号 (整体收小的那一档)
local F_TITLE  = 10      -- 商品名
local F_PROD   = 8       -- 产物售价
local F_MAT    = 7       -- 材料名 / 材料金额
local F_REQ    = 9       -- 技能等级 [300]
local F_BTN    = 8       -- 行内按钮
local F_PRICE  = 8       -- 右侧盈亏

local frame, content
local contentW = BASE_W
local refs = {}
local tabs = {}            -- key -> 页签按钮
local profIcons = {}       -- key -> 页签图标纹理
local rows = {}            -- 列表行池

local scroll, listContent, track, thumb
local noticeFrame, noticeText, noticeToken   -- 页面内浮层提示

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
    -- 层级排查用: 我们固定 HIGH (在 EllesmereUI 快捷操作层 DIALOG 下面)
    if frame then
        print("  层级:", tostring(frame:GetFrameStrata()), "frameLevel:", tostring(frame:GetFrameLevel()))
    end
    local ah = _G.AuctionHouseFrame
    if ah and type(ah.GetFrameStrata) == "function" then
        local ok, st = pcall(ah.GetFrameStrata, ah)
        print("  拍卖行窗口层级:", ok and tostring(st) or "取不到")
    end
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

-- 面板目标尺寸: 宽度 = 窗口宽度 x 50%, 高度按设计稿比例 (440:356) 算, 太高的窗口也不超过 90%
-- 只固定宽度不固定高度, 是为了避免右半屏变成一根又窄又长的竖条
local function PanelSize()
    local sw, sh = WindowSize()
    local w = math.floor(sw * PANEL_PCT)
    local h = math.floor(w * (BASE_H / BASE_W))
    local maxH = math.floor(sh * PANEL_MAX_H)
    if h > maxH then h = maxH end
    return math.max(320, w), math.max(280, h)
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

    local txt = T.Text(b, 9, C.muted)
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
    coin:SetSize(22, 22)
    coin:SetPoint("TOPLEFT", f, "TOPLEFT", PAD, TOP_Y)
    coin:SetMask(T.PATH .. "circle")
    refs.coin = coin

    local coinGlow = T.Glow(f, 52, C.gold, 0.16, "glow-soft")
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
    local greeting = T.Text(f, 11, C.text)
    greeting:SetPoint("LEFT", coin, "RIGHT", 8, 0)
    greeting:SetWidth(104)
    greeting:SetWordWrap(false)
    refs.greeting = greeting

    -- 金币 (三段配色, 单行)
    local gold = T.Text(f, 10, C.gold)
    gold:SetPoint("LEFT", greeting, "RIGHT", 12, 0)
    refs.gold = gold

    -- 右侧: 关闭 / 设置 / 在线 / 等级 (从右往左排, 不受左侧文字长度影响)
    local close = T.CloseButton(f, function() ns.UI.Hide() end)
    close:SetPoint("TOPRIGHT", f, "TOPRIGHT", -(PAD - 6), TOP_Y)

    local settingsBtn = MakeMiniButton(f, 46, 18, "设置")
    settingsBtn:SetPoint("RIGHT", close, "LEFT", -6, 0)
    settingsBtn:SetScript("OnClick", function() ns.OpenSettings() end)

    -- 在线时长 / 等级从右往左排, 不受左侧名字长度影响
    local time = T.Text(f, 10, C.muted)
    time:SetPoint("RIGHT", settingsBtn, "LEFT", -12, 0)
    refs.time = time

    local level = T.Text(f, 10, C.text)
    level:SetPoint("RIGHT", time, "LEFT", -10, 0)
    refs.level = level

    -- 分隔线
    local divider = T.Line(f, BASE_W - PAD * 2, 1, C.white, 0.07)
    divider:SetPoint("TOPLEFT", f, "TOPLEFT", PAD, TAB_Y + 8)
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
        icon:SetSize(12, 12)
        icon:SetPoint("LEFT", 7, 0)
        icon:SetTexture((ns.Prof.Icon and ns.Prof.Icon(prof.key))
            or "Interface\\Icons\\INV_Misc_QuestionMark")
        icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
        profIcons[prof.key] = icon

        local txt = T.Text(tab, 10, C.muted)
        txt:SetPoint("LEFT", icon, "RIGHT", 4, 0)
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
    local sw = MakeMiniButton(f, 66, TAB_H, "材料汇总")
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

-- 行内分栏: 图标 / 商品 / 材料 / 技能 / 价格 / 按钮
-- 右侧一整套是固定宽的, 先把它们扣掉再把剩下的按 36:64 分给商品和材料,
-- 否则材料格会顶到技能列上 (4 样材料时尤其明显)
local ROW_ICON_W = 22    -- 图标列宽度 (含与文字的间距)
local ROW_GAP    = 8     -- 列间距
local REQ_W      = 22    -- 技能等级 [300] 的宽度

-- 前向声明: 下面几处都要用 —— 面板改宽时 RelayoutRows 要拿 RowColumns/CellWidth
-- 重画金额 (数量>1 的材料显示成「单价×数量 = 合计」还是只显示合计, 取决于格宽)
local ApplyPriceToRow, CheckRowPrice, AnchorRowRight

local function RowColumns(w)
    local priceW = math.max(56, math.min(120, w * 0.17))
    local rightFixed = BTN_W + 2 + 6 + priceW + 6 + REQ_W     -- 按钮 + 间距 + 价格 + 间距 + 技能
    local rest = w - ROW_ICON_W - ROW_GAP - rightFixed
    if rest < 150 then rest = 150 end
    local titleW = math.max(72, rest * 0.36)
    local matsW  = math.max(84, rest - titleW - ROW_GAP)
    return titleW, matsW, priceW, ROW_ICON_W + titleW + ROW_GAP
end

-- 单个材料格的实际宽度 (与 RelayoutCells 同一套算法, 供金额排版选择写法)
local function CellWidth(r)
    local w = (r and r:GetWidth()) or 0
    if w <= 0 then w = BASE_W - PAD * 2 - 8 end
    local _, matsW = RowColumns(w)
    local n = (r and r.cellCount) or 1
    if n < 1 then n = 1 end
    local cw = matsW / n
    if cw < 30 then cw = 30 end
    return cw
end

-- 粗略文字宽度 (中文 ≈ 字号, 数字/字母 ≈ 字号 x 0.55)
-- 只用来在几种金额写法之间挑一个放得下的, 不需要精确, 所以不做 FontString 实测 ——
-- 列表可能有上千行, 每格都 GetStringWidth 一次会让渲染明显变卡。
local function ApproxWidth(s, size)
    size = size or F_MAT
    local wide, ascii = size, size * 0.55
    local w, i, len = 0, 1, #s
    while i <= len do
        local b = s:byte(i)
        if b >= 0xE0 then            -- 3 字节: 中日韩字符
            w = w + wide
            i = i + 3
        elseif b >= 0xC0 then        -- 2 字节: 带音标的拉丁字母等
            w = w + wide * 0.75
            i = i + 2
        else
            w = w + ascii
            i = i + 1
        end
    end
    return w
end

-- 材料格的金额文字。
-- 数量 > 1 时真正花出去的是「单价 × 数量」, 只写单价会让人以为成本就是那么点,
-- 但材料格的宽度很紧 (4 样材料时只剩 ~30px, 刚够放一个 "3金60银"), 所以按格宽分档:
--   宽格   单价×3 = 合计
--   中格   ×3 合计
--   窄格   共合计
--   极窄   合计
local function MatPriceText(AH, unit, cnt, cw, size)
    local u = AH.Money(unit)
    if not cnt or cnt <= 1 then return u end

    local t = AH.Money(unit * cnt)
    local avail = (cw or 0) - 2

    local full = format("%s×%d = %s", u, cnt, t)
    if ApproxWidth(full, size) <= avail then
        -- 前半段 "单价×数量 =" 压暗, 一眼看到的是最后的合计
        return format("|cff8a929e%s×%d =|r %s", u, cnt, t)
    end

    local mid = format("×%d %s", cnt, t)
    if ApproxWidth(mid, size) <= avail then
        return format("|cff8a929e×%d|r %s", cnt, t)
    end

    local tot = "共" .. t
    if ApproxWidth(tot, size) <= avail then return tot end

    return t
end

-- 材料格子: 横向等分材料区, 每格三段 —— 图标 / 材料名×数量 / 金额
--
-- 图标为什么单独占一行而不是挤在名字左边: 材料 3~4 样时格子只剩 30 多像素,
-- 名字本身就要贴满, 塞不下 9px 的图标; 纵向还有富余, 横向没有。所有格子统一
-- 用同一套纵向位置, 这样相邻两行即使材料数不同, 名字和金额也在同一水平线上。
local CELL_ICON = 8      -- 材料图标尺寸
local CELL_ICON_Y  = -2  -- 图标顶边
local CELL_NAME_Y  = -11 -- 材料名顶边
local CELL_PRICE_Y = -21 -- 金额顶边

local function RelayoutCells(r, matsX, matsW)
    local n = r.cellCount or 0
    for k = 1, MAT_CELLS do
        local c = r.cells[k]
        if k <= n then
            local cw = matsW / n
            -- 4 样材料时 matsW 只有 ~113, 下限 30 刚好不越到右边的技能/盈亏列
            if cw < 30 then cw = 30 end
            c:SetSize(cw, ROW_H)
            c:ClearAllPoints()
            c:SetPoint("TOPLEFT", r, "TOPLEFT", matsX + (k - 1) * cw, 0)
            c.name:SetWidth(cw)
            c.price:SetWidth(cw)
            c:Show()
        else
            c:Hide()
        end
    end
end

-- 行宽 / 文本宽度随面板宽度自适应
local function RelayoutRows(w)
    if not (w and w > 0) then return end
    local titleW, matsW, priceW, matsX = RowColumns(w)
    for i = 1, #rows do
        local r = rows[i]
        r:SetWidth(w)
        r.title:SetWidth(titleW)
        r.prodPrice:SetWidth(titleW)
        r.price:SetWidth(priceW)
        RelayoutCells(r, matsX, matsW)
        -- 格子宽度变了, 金额要不要写成「单价×数量 = 合计」也跟着变, 用已有结果重画一次
        if ApplyPriceToRow and r.payload then ApplyPriceToRow(r, r.payload) end
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

--------------------------------------------------------------------------- 构建: 页面提示

-- 页面内浮层提示 (替代聊天框): 查价失败、拍卖行没开这类反馈属于界面自身状态,
-- 丢进聊天流里很容易被刷掉, 也看不到是哪一行触发的。浮层贴在列表底部, 淡入,
-- 几秒后自动收起, 点一下可以提前关掉。
local function BuildNotice(f)
    local n = CreateFrame("Frame", nil, f)
    n:SetSize(240, 26)
    n:SetPoint("BOTTOM", f, "BOTTOM", 0, LIST_BOT + 10)
    n:SetFrameLevel((f:GetFrameLevel() or 1) + 20)
    n:EnableMouse(true)

    local bg = n:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints(true)
    bg:SetTexture(T.PATH .. "card")
    bg:SetVertexColor(0.06, 0.07, 0.09, 0.96)

    local accent = n:CreateTexture(nil, "ARTWORK")
    accent:SetColorTexture(T.rgb(C.gold))
    accent:SetSize(3, 14)
    accent:SetPoint("LEFT", 9, 0)

    local txt = T.Text(n, 10, C.gold)
    txt:SetPoint("LEFT", accent, "RIGHT", 8, 0)
    txt:SetPoint("RIGHT", n, "RIGHT", -10, 0)
    txt:SetWordWrap(false)
    txt:SetJustifyH("LEFT")

    -- 淡入只用 Alpha: 这个客户端循环 Scale / Translation 会把增量累加到当前变换上
    if ns.DB().animations then
        local ag = n:CreateAnimationGroup()
        local a = ag:CreateAnimation("Alpha")
        a:SetFromAlpha(0)
        a:SetToAlpha(1)
        a:SetDuration(0.15)
        a:SetSmoothing("OUT")
        n.fadeAG = ag
    end

    n:SetScript("OnMouseUp", function(s) s:Hide() end)
    n:Hide()

    noticeFrame, noticeText = n, txt
end

-- 在页面里弹一条提示; 界面没构建/没显示时返回 false, 调用方可以退回聊天框
function ns.UI.Notify(msg, hold)
    if not (noticeFrame and noticeText and frame and frame:IsShown()) then return false end
    if type(msg) ~= "string" or msg == "" then return false end

    noticeToken = (noticeToken or 0) + 1
    local token = noticeToken

    pcall(noticeText.SetText, noticeText, msg)

    -- 浮层宽度按文字长度收, 但不超过内容宽度
    local maxW = math.max(200, (contentW or BASE_W) - PAD * 2)
    local w = maxW
    local okW, sw = pcall(noticeText.GetStringWidth, noticeText)
    if okW and type(sw) == "number" and sw > 0 then
        w = sw + 42
    end
    if w < 180 then w = 180 elseif w > maxW then w = maxW end
    noticeFrame:SetWidth(w)

    if noticeFrame.fadeAG then
        noticeFrame:SetAlpha(0)
        pcall(function()
            noticeFrame.fadeAG:Stop()
            noticeFrame.fadeAG:Play()
        end)
    else
        noticeFrame:SetAlpha(1)
    end
    noticeFrame:Show()

    C_Timer.After(hold or 4.5, function()
        if token ~= noticeToken then return end      -- 期间又弹了新提示, 让它自己计时
        if noticeFrame then pcall(function() noticeFrame:Hide() end) end
    end)
    return true
end

--------------------------------------------------------------------------- 行池与渲染

-- 行尾三件套 (价格 / 查价按钮 / 技能) 的锚点切换:
-- 配方模式 = [价格][查价]; 材料汇总模式没有按钮, 价格直接靠右
AnchorRowRight = function(r, withBtn)
    if withBtn then r.btn:Show() else r.btn:Hide() end
    r.price:ClearAllPoints()
    if withBtn then
        r.price:SetPoint("RIGHT", r.btn, "LEFT", -6, 0)
    else
        r.price:SetPoint("RIGHT", r, "RIGHT", -4, 0)
    end
    r.req:ClearAllPoints()
    r.req:SetPoint("RIGHT", r.price, "LEFT", -6, 0)
end

local function GetRow(i)
    local r = rows[i]
    if r then return r end

    r = CreateFrame("Frame", nil, listContent)
    r:SetSize(BASE_W - PAD * 2 - 8, ROW_H)
    r:EnableMouse(true)

    r.bg = r:CreateTexture(nil, "BACKGROUND")
    r.bg:SetAllPoints(true)
    r.bg:SetColorTexture(1, 1, 1, 0)

    -- 物品图标: 与第一行文字对齐
    r.icon = r:CreateTexture(nil, "ARTWORK")
    r.icon:SetSize(15, 15)
    r.icon:SetPoint("TOPLEFT", 0, -3)
    r.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    r.icon:Hide()

    -- 商品列: 第一行名称, 第二行产物售价 (查价后填)
    r.title = T.Text(r, F_TITLE, C.text)
    r.title:SetPoint("TOPLEFT", ROW_ICON_W, -3)
    r.title:SetWidth(140)
    r.title:SetWordWrap(false)

    r.prodPrice = T.Text(r, F_PROD, C.muted)
    r.prodPrice:SetPoint("TOPLEFT", r.title, "BOTTOMLEFT", 0, -1)
    r.prodPrice:SetWidth(140)
    r.prodPrice:SetWordWrap(false)

    -- 材料列: 每样材料一格, 图标 / 名字×数量 / 金额 (纵向位置三行固定, 见上方 CELL_*_Y)
    r.cells = {}
    r.cellCount = 0
    for k = 1, MAT_CELLS do
        local c = CreateFrame("Frame", nil, r)
        c:SetSize(48, ROW_H)

        c.icon = c:CreateTexture(nil, "ARTWORK")
        c.icon:SetSize(CELL_ICON, CELL_ICON)
        c.icon:SetPoint("TOPLEFT", 0, CELL_ICON_Y)
        c.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
        c.icon:Hide()

        c.name = T.Text(c, F_MAT, C.muted)
        c.name:SetPoint("TOPLEFT", 0, CELL_NAME_Y)
        c.name:SetWordWrap(false)
        c.price = T.Text(c, F_MAT, C.faint)
        c.price:SetPoint("TOPLEFT", 0, CELL_PRICE_Y)
        c.price:SetWordWrap(false)
        c:Hide()
        r.cells[k] = c
    end

    r.req = T.Text(r, F_REQ, C.muted)
    r.req:SetPoint("RIGHT", -6, 0)
    r.req:SetJustifyH("RIGHT")

    -- 价格列: 查价结果 (盈/亏) 或材料单价
    r.price = T.Text(r, F_PRICE, C.muted)
    r.price:SetWidth(72)
    r.price:SetWordWrap(false)
    r.price:SetJustifyH("RIGHT")

    -- 查价按钮 (每行一个, 点一下查该配方产物 + 全部材料的拍卖行价)
    r.btn = MakeMiniButton(r, BTN_W, 14, "查价")
    r.btn:SetPoint("RIGHT", -2, 0)
    r.btn:SetScript("OnClick", function() CheckRowPrice(r) end)
    r.btn:SetScript("OnEnter", function(s)
        s.bg:SetVertexColor(1, 1, 1, 0.20)
        s.text:SetTextColor(T.rgb(C.text))
        ns.UI.ShowPriceTooltip(s, r)
    end)
    r.btn:SetScript("OnLeave", function(s)
        s.bg:SetVertexColor(1, 1, 1, 0.10)
        s.text:SetTextColor(T.rgb(C.muted))
        GameTooltip:Hide()
    end)

    AnchorRowRight(r, true)

    -- 行悬停: 高亮 + 完整标题提示
    -- 整块 UI 收小一档后, 商品名和材料名都更容易被截断 (尤其 4 样材料的行),
    -- 所以悬停时把整行文字原样吐到 tooltip 里, 顺带列出全部材料。
    r:SetScript("OnEnter", function(s)
        s.bg:SetColorTexture(1, 1, 1, 0.05)
        ns.UI.ShowRowTooltip(s, r)
    end)
    r:SetScript("OnLeave", function(s)
        s.bg:SetColorTexture(1, 1, 1, s.odd and 0.025 or 0)
        GameTooltip:Hide()
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

-- 材料格图标: 同样允许「物品数据还没回包」时先空着, 回包后由 RefreshRowIcons 补
local function SetCellIcon(c, itemID)
    c.itemID = itemID
    local tex = (ns.Prof and ns.Prof.ItemIcon and ns.Prof.ItemIcon(itemID)) or nil
    if tex then
        c.icon:SetTexture(tex)
        c.icon:Show()
    else
        c.icon:Hide()
    end
end

-- 物品数据回包后补上图标 (首次打开时多数物品可能还没缓存)
local function RefreshRowIcons()
    for i = 1, #rows do
        local r = rows[i]
        if r:IsShown() then
            if r.itemID and not r.icon:IsShown() then
                SetRowIcon(r, r.itemID)
            end
            for k = 1, (r.cellCount or 0) do
                local c = r.cells[k]
                if c.itemID and not c.icon:IsShown() then
                    SetCellIcon(c, c.itemID)
                end
            end
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
            local titleW, matsW, priceW, matsX = RowColumns(w)
            r.title:SetWidth(titleW)
            r.prodPrice:SetWidth(titleW)
            r.price:SetWidth(priceW)

            r.odd = (i % 2 == 0)
            r.bg:SetColorTexture(1, 1, 1, r.odd and 0.025 or 0)

            if curMode == "mats" then
                local m = items[i]
                r.rec = nil
                r.cellCount = 0
                AnchorRowRight(r, false)
                r.title:SetText(m.name or "?")
                r.req:SetText(format("|cffe8c25a×%d|r", m.count or 0))
                SetRowIcon(r, m.id)

                -- 材料汇总: 单价写在材料名下方, 右侧是该材料的合计花费
                local e = ns.Auction and ns.Auction.Price(m.id)
                if e and e.unit then
                    r.prodPrice:SetTextColor(T.rgb(C.gold))
                    r.prodPrice:SetText("单价 " .. ns.Auction.Money(e.unit) .. "/个")
                    r.price:SetTextColor(T.rgb(C.gold))
                    r.price:SetText("共 " .. ns.Auction.Money(e.unit * (m.count or 1)))
                else
                    r.prodPrice:SetTextColor(T.rgb(C.faint))
                    r.prodPrice:SetText("未查价")
                    r.price:SetText("")
                end
                r.payload = nil
            else
                local rec = items[i]
                local made = (rec.made and rec.made > 1)
                    and format(" |cff9d9d9d×%d|r", rec.made) or ""
                r.rec = rec
                AnchorRowRight(r, true)
                r.btn.busy = false
                r.btn.text:SetText("查价")
                r.title:SetText((rec.name or "?") .. made)
                r.req:SetText(format("|cff8a929e[%d]|r", rec.req or 0))
                SetRowIcon(r, rec.item)

                -- 材料格: 图标 + 「名字×数量」 + 单价 (单价查价后再写)
                local mats = rec.mats or {}
                r.cellCount = math.min(#mats, MAT_CELLS)
                for k = 1, r.cellCount do
                    local m = mats[k]
                    local c = r.cells[k]
                    SetCellIcon(c, m.id)
                    c.name:SetText(format("%s|cff8a929e×%d|r",
                        m.name or ("#" .. tostring(m.id)), m.count or 1))
                    c.price:SetText("")
                end

                -- 有缓存就直接显示上次算好的售价与盈亏, 点查价按钮才重新查
                ApplyPriceToRow(r, ns.Auction and ns.Auction.Preview(rec))
            end

            RelayoutCells(r, matsX, matsW)
        elseif r then
            r:Hide()
        end
    end

    scroll:SetVerticalScroll(0)
    if UpdateThumb then UpdateThumb() end
end

--------------------------------------------------------------------------- 查价

-- 把查价结果画到行上:
--   商品列第二行 = 产物售价 (一次做多份时是整个产出), 每个材料格第三行 = 该材料花费,
--   右侧 = 盈亏。数量 > 1 的材料写「单价×数量 = 合计」, 格子窄了自动退化成只写合计
--   (见 MatPriceText), 完整明细在悬停「查价」按钮的提示里。
ApplyPriceToRow = function(r, out)
    r.payload = out
    local AH = ns.Auction

    local function clear()
        r.prodPrice:SetText("")
        for k = 1, (r.cellCount or 0) do
            r.cells[k].price:SetText("")
        end
    end

    if not out then
        r.price:SetText("")
        clear()
        return
    end

    local rec = out.rec

    -- 产物售价 (商品名下方)
    -- 一次做多份 (made > 1) 时, 盈亏里的收入是按 made 份算的, 这里也写成整份的售价,
    -- 否则会出现「成本 30 银 / 售价 20 银 / 却显示赚钱」的对不上
    local prod = rec and out.unit and out.unit[rec.item]
    local made = (rec and rec.made) or 1
    if prod and prod.unit then
        r.prodPrice:SetTextColor(T.rgb(C.gold))
        if made > 1 then
            r.prodPrice:SetText("售价 " .. MatPriceText(AH, prod.unit, made,
                (r.title:GetWidth() or 72) - 20, F_PROD))
        else
            r.prodPrice:SetText("售价 " .. AH.Money(prod.unit) .. "/个")
        end
    elseif prod then
        r.prodPrice:SetTextColor(T.rgb(C.red))
        r.prodPrice:SetText(prod.reason or "无挂单")
    else
        r.prodPrice:SetText("")
    end

    -- 每样材料的金额 (材料名下方)。数量 > 1 写成「单价×数量 = 合计」或退化成合计,
    -- 具体写哪一种由格宽决定 (见 MatPriceText)
    local cw = CellWidth(r)
    for k = 1, (r.cellCount or 0) do
        local m = rec and rec.mats and rec.mats[k]
        local c = r.cells[k]
        local e = m and out.unit and out.unit[m.id]
        if e and e.unit then
            c.price:SetTextColor(T.rgb(C.gold))
            c.price:SetText(MatPriceText(AH, e.unit, m.count or 1, cw, F_MAT))
        elseif e then
            c.price:SetTextColor(T.rgb(C.red))
            c.price:SetText(e.reason or "无挂单")
        else
            c.price:SetText("")
        end
    end

    if out.profit then
        if out.profit > 0 then
            r.price:SetTextColor(T.rgb(C.green))
            r.price:SetText("盈 " .. AH.Money(out.profit))
        elseif out.profit < 0 then
            r.price:SetTextColor(T.rgb(C.red))
            r.price:SetText("亏 " .. AH.Money(-out.profit))
        else
            r.price:SetTextColor(T.rgb(C.muted))
            r.price:SetText("持平")
        end
    else
        r.price:SetTextColor(T.rgb(C.faint))
        r.price:SetText(format("缺 %d 项价格", #(out.missing or {})))
    end
end

CheckRowPrice = function(r)
    local AH = ns.Auction
    local rec = r.rec
    if not (AH and rec) then return end
    if r.busy then return end

    -- 限流不算错误: 排队后会自动等下一次窗口; 只有拍卖行没开才值得拦下来提示
    local ok, reason = AH.CanQuery()
    if not ok and (reason == "拍卖行未打开" or reason == "客户端缺少拍卖行查询 API") then
        local noAH = (reason == "拍卖行未打开")
        -- 提示落在页面上 (聊天框会被其它信息刷掉, 也看不出是哪一行触发的)
        ns.UI.Notify(noAH
            and "查价需要先打开拍卖行 · 打开拍卖行窗口后再点「查价」"
            or  "客户端缺少拍卖行查询 API, 无法查价", 5)
        -- 提示会自动消失, 行上同时留个标记, 免得过一会儿忘了为什么没查
        r.price:SetTextColor(T.rgb(C.gold))
        r.price:SetText(noAH and "需开拍卖行" or "无查价接口")
        return
    end

    r.busy = true
    r.btn.text:SetText("查询中")
    r.price:SetTextColor(T.rgb(C.gold))
    r.price:SetText(format("0/%d", 1 + #(rec.mats or {})))

    AH.CheckRecipe(rec, function(out)
        if r.rec ~= rec then return end       -- 行已被别的配方复用, 状态交给 RenderList
        r.busy = false
        r.btn.text:SetText("查价")
        ApplyPriceToRow(r, out)
        AH.Report(out)
    end, function(done, total)
        if r.rec ~= rec then return end
        r.price:SetText(format("%d/%d", done, total))
    end)
end

-- tooltip 贴鼠标
--
-- 原来用 ANCHOR_RIGHT 锚在控件右边: 面板本身贴在屏幕右缘、宽度又占半屏, 鼠标停在行中间时
-- 提示会盖住材料列, 或者干脆被挤到屏幕外。改成跟随鼠标后, 提示永远出现在光标旁边。
-- ANCHOR_CURSOR_RIGHT 让提示落在光标右下方一点, 不压住光标; 万一客户端不认这个锚点
-- (老版本只有 ANCHOR_CURSOR), 用 pcall 退回到最通用的 ANCHOR_CURSOR。
local function TooltipAtCursor(anchor)
    anchor = anchor or ns.frame or UIParent
    local ok = pcall(GameTooltip.SetOwner, GameTooltip, anchor, "ANCHOR_CURSOR_RIGHT")
    if not ok then
        pcall(GameTooltip.SetOwner, GameTooltip, anchor, "ANCHOR_CURSOR")
    end
end

-- 悬浮明细: 产物/材料单价 · 成本 · 税后收入 · 利润
function ns.UI.ShowPriceTooltip(anchor, r)
    local AH = ns.Auction
    local out = r.payload

    TooltipAtCursor(anchor)
    GameTooltip:AddLine("拍卖行查价", 1, 0.89, 0.55)

    if out and out.unit and out.rec == r.rec then
        local rec = out.rec
        local prod = out.unit[rec.item]
        local made = out.made or 1
        local prodTxt = "无货"
        if prod and prod.unit then
            prodTxt = made > 1
                and format("%s/个 = %s", AH.Money(prod.unit), AH.Money(prod.unit * made))
                or  (AH.Money(prod.unit) .. "/个")
        end
        GameTooltip:AddDoubleLine(
            format("产出  %s ×%d", rec.name or "?", made),
            prodTxt,
            0.85, 0.86, 0.90, 1, 0.82, 0.35)

        for i = 1, #(rec.mats or {}) do
            local m = rec.mats[i]
            local e = out.unit[m.id]
            local cnt = m.count or 1
            local txt, r2, g2, b2
            if e and e.unit then
                -- 数量 > 1 时把「单价 = 合计」都写出来, 行内格子放不下的信息在这里补齐
                txt = cnt > 1
                    and format("%s/个 = %s", AH.Money(e.unit), AH.Money(e.unit * cnt))
                    or  (AH.Money(e.unit) .. "/个")
                r2, g2, b2 = 0.82, 0.84, 0.88
            elseif e and e.reason and e.reason ~= "无挂单" then
                -- 查询超时 / 查询失败 才是真问题, 单独标红
                txt, r2, g2, b2 = e.reason, 0.92, 0.48, 0.42
            else
                txt, r2, g2, b2 = "无挂单", 0.88, 0.72, 0.35
            end
            GameTooltip:AddDoubleLine(
                format("材料  %s ×%d", m.name or "?", m.count or 1),
                txt, 0.85, 0.86, 0.90, r2, g2, b2)
        end

        GameTooltip:AddLine(" ")
        GameTooltip:AddDoubleLine("成本", AH.Money(out.cost or 0),
            0.72, 0.75, 0.80, 0.92, 0.93, 0.95)
        GameTooltip:AddDoubleLine("收入 (扣 5% 税)", AH.Money(out.net or 0),
            0.72, 0.75, 0.80, 0.92, 0.93, 0.95)

        if out.profit then
            local txt = (out.profit >= 0 and "+" or "-") .. AH.Money(math.abs(out.profit))
            local rr, gg, bb = 0.40, 0.80, 0.45
            if out.profit < 0 then rr, gg, bb = 0.92, 0.42, 0.42 end
            GameTooltip:AddDoubleLine("利润", txt, 1, 1, 1, rr, gg, bb)
        else
            GameTooltip:AddDoubleLine("利润", "价格不全",
                1, 1, 1, 0.92, 0.55, 0.40)
            local parts = {}
            for i = 1, #(out.why or {}) do
                local w = out.why[i]
                parts[#parts + 1] = format("%s(%s)", w.name, w.reason or "?")
            end
            if #parts == 0 then parts[1] = table.concat(out.missing or {}, ", ") end
            GameTooltip:AddLine("缺: " .. table.concat(parts, ", "),
                0.92, 0.55, 0.40, true)
            GameTooltip:AddLine("「无挂单」= 拍卖行里没人卖, 不是接口故障",
                0.55, 0.58, 0.63, true)
        end

        local age = AH.Age(rec.item)
        if age then
            GameTooltip:AddLine(" ")
            GameTooltip:AddLine(format("价格取自 %d 分钟前", math.floor(age / 60)),
                0.55, 0.58, 0.63)
        end
    else
        GameTooltip:AddLine("查询产物与材料在拍卖行的最低单价,", 0.85, 0.86, 0.90)
        GameTooltip:AddLine("算出做一次是盈利还是亏本。", 0.85, 0.86, 0.90)
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine("需要拍卖行窗口打开才查得到。", 0.62, 0.65, 0.70, true)
    end

    GameTooltip:AddLine(" ")
    GameTooltip:AddLine("取拍卖行当前最低单价 · 缓存 30 分钟", 0.55, 0.58, 0.63)
    GameTooltip:Show()
end

-- 颜色码剥离: 行内文字带 |cff... 前缀和 ×N 的灰色段, 塞进 tooltip 前要还原成纯文字
local function PlainText(s)
    if type(s) ~= "string" then return "" end
    s = s:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
    return s
end

-- 行悬停提示: 补全被截断的标题, 并列出全部材料
-- 整块 UI 收小一档后 (行高 40→32, 商品名 11→10pt), 长名字更容易被截成省略号,
-- 这里把完整名字和材料清单原样给出来; 价格明细仍归「查价」按钮的提示。
function ns.UI.ShowRowTooltip(anchor, r)
    if not r then return end

    TooltipAtCursor(anchor)

    local title = PlainText(r.title and r.title:GetText()) or ""
    if title == "" then return end
    GameTooltip:AddLine(title, 1, 1, 1, true)

    local rec = r.rec
    if rec then
        local req = rec.req and format(" · 技能 %d", rec.req) or ""
        local made = (rec.made and rec.made > 1)
            and format(" · 一次做 %d 个", rec.made) or ""
        GameTooltip:AddLine("材料配方" .. req .. made, 0.72, 0.75, 0.80)

        local mats = rec.mats or {}
        if #mats > 0 then
            GameTooltip:AddLine(" ")
            for i = 1, #mats do
                local m = mats[i]
                local name = (m.name and PlainText(m.name)) or "?"
                GameTooltip:AddDoubleLine(
                    name, format("×%d", m.count or 1),
                    0.85, 0.86, 0.90, 0.72, 0.75, 0.80)
            end
        end
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine("点右边的「查价」看拍卖行价格与盈亏", 0.55, 0.58, 0.63)
    else
        -- 材料汇总模式: 这一行本身就是一样材料
        local e = ns.Auction and ns.Auction.Price and ns.Auction.Price(r.itemID)
        if e and e.unit then
            GameTooltip:AddLine("当前最低单价 " .. ns.Auction.Money(e.unit) .. "/个",
                1, 0.82, 0.35)
        end
    end

    GameTooltip:Show()
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
    -- 层级: 和无限副本手册 (DungeonsForever 主窗 Core/MainFrame.lua) 保持一致 —— HIGH。
    -- 客户端里 EllesmereUI 的快捷操作层 (Quickdraw live frame) 是 DIALOG, 我们原来也用
    -- DIALOG, 同层下谁后显示谁在上面, 血条/快捷操作常被这块大面板盖住。放到 HIGH 就固定
    -- 待在操作层下面, 同时又高于动作条 (MEDIUM) 那类常规 HUD。
    f:SetFrameStrata("HIGH")
    f:SetToplevel(true)

    -- 面板尺寸 = 窗口宽度的 50%, 高度按设计稿比例
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
    SafeStep(BuildNotice, "Notice", content)
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

-- 定位: 屏幕右侧、垂直居中。宽度固定为窗口 50%, 所以只需记一个拖动偏移
function ns.UI.ApplyPosition()
    if not frame then return end
    local db = ns.DB()
    local sw, sh = WindowSize()
    local fw = frame:GetWidth() or 0
    local fh = frame:GetHeight() or 0

    -- 右下角留一点边距, 小窗口按比例收窄
    local margin = math.min(PANEL_MARGIN, math.floor(sw * 0.03))
    if fw + margin * 2 > sw then margin = 0 end

    -- 旧存档是 CENTER 锚点时代的偏移 (x=-117 / y=-95 之类), 会直接把面板从右侧拽偏,
    -- 首次升级到右侧布局时一次性归位
    if not db.pos or db.pos.point ~= "RIGHT" then
        db.pos = db.pos or {}
        db.pos.point, db.pos.relPoint = "RIGHT", "RIGHT"
        db.pos.x, db.pos.y = 0, 0
    end
    db.pos.relPoint = "RIGHT"

    -- 存档里的 x 是「含右边距的合成值」(GetPoint 拿到的就是 SetPoint 传进去的),
    -- 先还原成相对右边缘的额外偏移再夹紧, 否则每算一次都会多减一次边距
    local dx = (db.pos.x or 0) + (db.pos.margin or margin)
    local minX = -(sw - fw - margin)     -- 最多拖到左边缘贴屏幕左边
    if minX > 0 then minX = 0 end
    local x = math.max(minX, math.min(0, dx))   -- 正数会把面板推出屏幕右侧
    local halfY = math.max(0, (sh - fh) / 2)
    local y = math.max(-halfY, math.min(halfY, db.pos.y or 0))

    db.pos.x, db.pos.y = math.floor(-margin + x), math.floor(y)
    db.pos.margin = math.floor(margin)

    frame:ClearAllPoints()
    frame:SetPoint("RIGHT", UIParent, "RIGHT", -margin + x, y)
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
