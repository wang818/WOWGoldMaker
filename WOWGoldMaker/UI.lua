---------------------------------------------------------------------------
-- WOWGoldMaker / UI.lua
-- 主界面: 深色玻璃面板 + 金色主题 Hello 窗口。
---------------------------------------------------------------------------

local ADDON, ns = ...

local T = ns.T
local C = T.C

ns.UI = ns.UI or {}

local W, H = 440, 268

local frame
local refs = {}          -- 需要跨函数更新的控件
local sessionStart
local selfCheckDone
local SIGNOFFS = {
    "愿你的背包永不爆满。",
    "今天的拍卖行是你的舞台。",
    "金币在召唤, 勇士。",
    "捡起那枚没人要的金币吧。",
    "稳住, 我们能搬空整个副本。",
    "先定一个小目标: 背包里全是金币。",
}

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
    refs.greeting:SetText(format("%s, |cff%s%s|r。",
        GreetingByHour(), ClassColorHex(), name))
end

local function UpdateSignoff()
    if not refs.signoff then return end
    local db = ns.DB()
    refs.signoff:SetText(SIGNOFFS[((db.greetIndex - 1) % #SIGNOFFS) + 1])
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
        if lastErr.build ~= "nocards" then
            lastErr.build = "nocards"
            ns.Print("|cffff5555金币卡片未创建 (refs.gold = nil)|r")
        end
        return
    end
    lastErr.build = nil

    local money = PlayerMoney()
    local gold   = math.floor(money / 10000)
    local silver = math.floor((money % 10000) / 100)
    local copper = money % 100

    -- 金额: 格式化失败则退回纯数字, 不让一处出错吞掉整张卡
    local okS, goldText = pcall(MoneyLine, money)
    if not okS or type(goldText) ~= "string" then
        goldText = tostring(gold)
    end

    SetText(refs.gold, goldText, "gold")

    local lvl = PlayerLevel()
    SetText(refs.level, lvl and tostring(lvl) or "?", "level")

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
    print("  frame:", tostring(frame ~= nil), "| showAG:", tostring(frame and frame.showAG ~= nil))
    print("  db:", tostring(ns.DB() ~= nil))
    local okM, money = pcall(GetMoney)
    print("  GetMoney 存在:", tostring(type(GetMoney) == "function"), "| 调用:", tostring(okM), "=", tostring(money))
    local okL, lvl = pcall(UnitLevel, "player")
    print("  UnitLevel:", tostring(okL), "=", tostring(lvl), "| PlayerLevel():", tostring(PlayerLevel()))
    -- 控件上真实的文本, 区分「没写进去」和「写进去但看不见」
    for _, k in ipairs({ "gold", "level", "time" }) do
        local fs = refs[k]
        local txt = "nil"
        if fs then local ok2, t = pcall(fs.GetText, fs); txt = ok2 and tostring(t) or "ERR" end
        print("  " .. k .. ".text:", txt)
    end
    -- 最近一次刷新解析出的原始数据
    local s = ns.UI.lastStats
    if s then
        print("  lastStats: money=" .. tostring(s.money) .. " 金=" .. tostring(s.gold)
            .. " 银=" .. tostring(s.silver) .. " 铜=" .. tostring(s.copper)
            .. " 等级=" .. tostring(s.level) .. " 文本=" .. tostring(s.goldText))
    else
        print("  lastStats: nil (刷新函数从未成功执行)")
    end
end

--------------------------------------------------------------------------- 动画

local function PlayPop(region)
    if not (ns.DB().animations and region) then return end
    local ag = region.popAG
    if not ag then
        ag = region:CreateAnimationGroup()
        local up = ag:CreateAnimation("Scale")
        up:SetScaleFrom(1, 1)
        up:SetScaleTo(1.05, 1.05)
        up:SetDuration(0.10)
        up:SetOrder(1)
        local down = ag:CreateAnimation("Scale")
        down:SetScaleFrom(1.05, 1.05)
        down:SetScaleTo(1, 1)
        down:SetDuration(0.22)
        down:SetSmoothing("OUT")
        down:SetOrder(2)
        region.popAG = ag
    end
    if not ag:IsPlaying() then ag:Play() end
end

local function FlashGlow(glow)
    if not (ns.DB().animations and glow) then return end
    local ag = glow.flashAG
    if not ag then
        ag = glow:CreateAnimationGroup()
        local a1 = ag:CreateAnimation("Alpha")
        a1:SetFromAlpha(glow:GetAlpha())
        a1:SetToAlpha(0.65)
        a1:SetDuration(0.12)
        a1:SetOrder(1)
        local a2 = ag:CreateAnimation("Alpha")
        a2:SetToAlpha(glow:GetAlpha())
        a2:SetDuration(0.45)
        a2:SetSmoothing("OUT")
        a2:SetOrder(2)
        glow.flashAG = ag
    end
    if not ag:IsPlaying() then ag:Play() end
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

local function BuildHeader(f)
    -- 标题
    local title = T.Text(f, 17, C.gold)
    title:SetPoint("TOPLEFT", f, "TOPLEFT", 24, -20)
    title:SetText("金币工坊")
    refs.title = title

    -- 版本徽标
    local chip = T.Glass(f, 52, 19, "sq")
    chip:SetPoint("LEFT", title, "RIGHT", 10, 1)
    chip.bg:SetVertexColor(1, 1, 1, 0.10)
    local chipText = T.Text(chip, 10, C.muted)
    chipText:SetPoint("CENTER")
    chipText:SetText("v" .. ns.VERSION)

    -- 关闭按钮
    local close = T.CloseButton(f, function() ns.UI.Hide() end)
    close:SetPoint("TOPRIGHT", f, "TOPRIGHT", -16, -14)

    -- 分隔线 + 滑动的金色高亮
    local divider = T.Line(f, W - 48, 1, C.white, 0.08)
    divider:SetPoint("TOPLEFT", f, "TOPLEFT", 24, -52)

    local accent = f:CreateTexture(nil, "BACKGROUND")
    accent:SetTexture(T.WHITE)
    accent:SetSize(52, 2)
    accent:SetPoint("TOPLEFT", f, "TOPLEFT", 24, -51)
    accent:SetVertexColor(T.rgb(C.gold, 0.85))
    if ns.DB().animations then
        -- 呼吸式明暗 (不用 Translation 循环: 该客户端会累积偏移导致元素逐渐漂走)
        local ag = accent:CreateAnimationGroup()
        ag:SetLooping("BOUNCE")
        local a = ag:CreateAnimation("Alpha")
        a:SetFromAlpha(0.35)
        a:SetToAlpha(1.0)
        a:SetDuration(3.2)
        a:SetSmoothing("IN_OUT")
        ag:Play()
    end
end

local function BuildHero(f)
    -- 金币图标 (圆形蒙版)
    local coin = f:CreateTexture(nil, "ARTWORK")
    coin:SetTexture("Interface\\Icons\\INV_Misc_Coin_01")
    coin:SetSize(44, 44)
    coin:SetPoint("TOPLEFT", f, "TOPLEFT", 26, -68)
    coin:SetMask(T.PATH .. "circle")
    refs.coin = coin

    local coinGlow = T.Glow(f, 96, C.gold, 0.16, "glow-soft")
    coinGlow:SetPoint("CENTER", coin, "CENTER")
    refs.coinGlow = coinGlow
    if ns.DB().animations then
        local ag = coinGlow:CreateAnimationGroup()
        ag:SetLooping("BOUNCE")
        local a = ag:CreateAnimation("Alpha")
        a:SetFromAlpha(0.10)
        a:SetToAlpha(0.24)
        a:SetDuration(2.8)
        a:SetSmoothing("IN_OUT")
        ag:Play()

        -- 图标呼吸: 只用 Alpha
        -- 注意: 本客户端循环播放 Scale / Translation 时会把每轮增量累加到当前变换上
        -- (不是从基准值重来), 几轮后图标会持续放大直至铺满屏幕。Alpha 是覆盖式标量且被
        -- clamp 在 0-1, 循环安全。见 2026-11-16 笔记「禁用循环 Scale/Translation」。
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

    -- 问候语
    local greeting = T.Text(f, 19, C.text)
    greeting:SetPoint("TOPLEFT", coin, "TOPRIGHT", 15, -4)
    refs.greeting = greeting

    -- 金句
    local signoff = T.Text(f, 12, C.muted)
    signoff:SetPoint("TOPLEFT", greeting, "BOTTOMLEFT", 0, -7)
    refs.signoff = signoff

    local hero = CreateFrame("Frame", nil, f)
    hero:SetAllPoints(true)
    hero:SetFrameLevel(f:GetFrameLevel() + 1)
    hero.greeting = greeting
    hero.signoff = signoff
    refs.hero = hero
end

local function BuildCards(f)
    local defs = {
        { key = "gold",  title = "金币", color = C.gold },
        { key = "level", title = "等级", color = C.text },
        { key = "time",  title = "在线", color = C.text },
    }

    local cards = {}
    for i, def in ipairs(defs) do
        local card = T.Glass(f, 126, 58, "card")
        card:SetPoint("TOPLEFT", f, "TOPLEFT", 24 + (i - 1) * 137, -136)

        local label = T.Text(card, 10, C.faint)
        label:SetPoint("TOPLEFT", card, "TOPLEFT", 12, -9)
        label:SetText(def.title)

        -- 金币一行放金银铜三段, 字体略小; 其余卡片单值
        local value = T.Text(card, def.key == "gold" and 11 or 17, def.color)
        value:SetPoint("BOTTOMLEFT", card, "BOTTOMLEFT", 11, def.key == "gold" and 11 or 10)
        value:SetText(def.key == "gold" and "读取中" or "--")

        card:SetScript("OnEnter", function(s)
            s.bg:SetVertexColor(1, 1, 1, 0.10)
        end)
        card:SetScript("OnLeave", function(s)
            s.bg:SetVertexColor(1, 1, 1, 1)
        end)

        cards[def.key] = value
    end

    refs.gold, refs.level, refs.time = cards.gold, cards.level, cards.time
end

local function BuildFooter(f)
    local db = ns.DB()

    local primary = T.Button(f, 132, 36, "打个招呼", "primary")
    primary:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -24, 24)
    primary:SetScript("OnClick", function()
        db.greetIndex = (db.greetIndex % #SIGNOFFS) + 1
        UpdateSignoff()
        PlayPop(refs.hero)
        FlashGlow(refs.coinGlow)
    end)

    local settingsBtn = T.Button(f, 84, 36, "设置", "secondary")
    settingsBtn:SetPoint("RIGHT", primary, "LEFT", -10, 0)
    settingsBtn:SetScript("OnClick", function()
        ns.OpenSettings()
    end)

    local hint = T.Text(f, 10, C.faint)
    hint:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 26, 27)
    hint:SetText("按住拖动 · /wgm 呼出")
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

--------------------------------------------------------------------------- 主入口

function ns.UI.Build()
    if frame then return frame end

    local f = CreateFrame("Frame", "WOWGoldMakerFrame", UIParent)
    f:SetFrameStrata("DIALOG")
    f:SetSize(W, H)
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
        SafeStep(UpdateSignoff, "UpdateSignoff")
        SafeStep(ns.UI.RefreshStats, "RefreshStats")
    end)
    tinsert(UISpecialFrames, f:GetName())   -- ESC 关闭
    frame = f
    ns.frame = f

    -- 面板
    local bg = f:CreateTexture(nil, "BACKGROUND", nil, -7)
    bg:SetAllPoints(true)
    bg:SetTexture(T.PATH .. "panel")

    -- 双色氛围光斑 (避开圆角, 靠内放置)
    local glowA = T.Glow(f, 250, C.gold, 0.07, "glow-soft")
    glowA:SetPoint("CENTER", f, "TOPLEFT", 150, -80)
    local glowB = T.Glow(f, 230, C.teal, 0.06, "glow-soft")
    glowB:SetPoint("CENTER", f, "BOTTOMRIGHT", -130, 60)
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

    SafeStep(BuildHeader, "Header", f)
    SafeStep(BuildHero, "Hero", f)
    SafeStep(BuildCards, "Cards", f)
    SafeStep(BuildFooter, "Footer", f)
    SafeStep(BuildShowAnimations, "Animations", f)

    sessionStart = GetTime()

    -- 每秒刷新: 在线时长 + 金币/等级 (不依赖 Show() 路径, 保证数据一定被写入)
    C_Timer.NewTicker(1, function()
        if not (frame and frame:IsShown()) then return end
        if refs.time then
            pcall(function() refs.time:SetText(T.FormatDuration(GetTime() - sessionStart)) end)
        end
        pcall(ns.UI.RefreshStats)

        -- 兜底: 金币图标不该有任何缩放。一旦被动画改成别的值(该客户端循环动画会累积
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
        ns.Print(format("自检 · 卡片=%s 刷新=%s | 金币文本=%s 等级文本=%s",
            refs.gold and "已创建" or "缺失",
            s and "已执行" or "未执行",
            txt("gold"), txt("level")))
    end)

    return f
end

function ns.UI.ApplyPosition()
    if not frame then return end
    local db = ns.DB()
    frame:ClearAllPoints()
    frame:SetPoint(db.pos.point, UIParent, db.pos.relPoint or db.pos.point,
        db.pos.x, db.pos.y)
end

function ns.UI.Show()
    if not frame then return end
    SafeStep(function() ns.UI.ApplyPosition() end, "ApplyPosition")
    SafeStep(UpdateGreeting, "UpdateGreeting")
    SafeStep(UpdateSignoff, "UpdateSignoff")
    SafeStep(ns.UI.RefreshStats, "RefreshStats")
    local animOK, animations = pcall(function() return ns.DB().animations end)
    if animations and frame.showAG and not frame:IsShown() then
        frame:Show()
        frame.showAG:Play()
    else
        frame:Show()
    end
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
