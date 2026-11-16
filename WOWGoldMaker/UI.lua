---------------------------------------------------------------------------
-- WOWGoldMaker / UI.lua
-- 主界面: 深色玻璃面板 + 金色主题 Hello 窗口。
---------------------------------------------------------------------------

local ADDON, ns = ...

local T = ns.T
local C = T.C

local W, H = 440, 268

local frame
local refs = {}          -- 需要跨函数更新的控件
local sessionStart
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

function ns.UI.RefreshStats()
    if not refs.gold then return end
    refs.gold:SetText(T.ShortGold(GetMoney()))
    refs.level:SetText(tostring(UnitLevel("player") or "--"))
end

--------------------------------------------------------------------------- 动画

local function PlayPop(region)
    if not (ns.DB().animations and region) then return end
    local ag = region.popAG
    if not ag then
        ag = region:CreateAnimationGroup()
        local up = ag:CreateAnimation("Scale")
        up:SetFromScale(1, 1)
        up:SetToScale(1.05, 1.05)
        up:SetDuration(0.10)
        up:SetOrder(1)
        local down = ag:CreateAnimation("Scale")
        down:SetFromScale(1.05, 1.05)
        down:SetToScale(1, 1)
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
        local ag = accent:CreateAnimationGroup()
        ag:SetLooping("BOUNCE")
        local tr = ag:CreateAnimation("Translation")
        tr:SetOffset(W - 48 - 52, 0)
        tr:SetDuration(6.5)
        tr:SetSmoothing("BOTH")
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
        a:SetSmoothing("BOTH")
        ag:Play()

        -- 图标轻微上下浮动
        local bob = coin:CreateAnimationGroup()
        bob:SetLooping("BOUNCE")
        local t = bob:CreateAnimation("Translation")
        t:SetOffset(0, 4)
        t:SetDuration(3.2)
        t:SetSmoothing("BOTH")
        bob:Play()
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

        local value = T.Text(card, 17, def.color)
        value:SetPoint("BOTTOMLEFT", card, "BOTTOMLEFT", 12, 10)
        value:SetText("--")

        card:SetScript("OnEnter", function(s)
            s.bg:SetVertexColor(1, 1, 1, 0.10)
            if def.key == "gold" then
                local g = math.floor(GetMoney() / 10000)
                GameTooltip:SetOwner(s, "ANCHOR_RIGHT")
                GameTooltip:AddLine("背包与银行金币", 0.9, 0.78, 0.42)
                GameTooltip:AddLine(format("%d金 %d银 %d铜",
                    g, math.floor(GetMoney() % 10000 / 100), GetMoney() % 100),
                    1, 1, 1)
                GameTooltip:Show()
            end
        end)
        card:SetScript("OnLeave", function(s)
            s.bg:SetVertexColor(1, 1, 1, 1)
            GameTooltip:Hide()
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
    s:SetFromScale(0.96, 0.96)
    s:SetToScale(1, 1)
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
    hs:SetFromScale(1, 1)
    hs:SetToScale(0.97, 0.97)
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
        UpdateGreeting()
        UpdateSignoff()
        ns.UI.RefreshStats()
    end)
    tinsert(UISpecialFrames, f:GetName())   -- ESC 关闭
    frame = f
    ns.frame = f

    -- 投影 (面板贴图之下)
    local shadow = f:CreateTexture(nil, "BACKGROUND", nil, -8)
    shadow:SetTexture(T.PATH .. "shadow")
    shadow:SetSize(486, 312)
    shadow:SetPoint("CENTER", 0, -6)

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
        local agA = glowA:CreateAnimationGroup()
        agA:SetLooping("BOUNCE")
        local trA = agA:CreateAnimation("Translation")
        trA:SetOffset(30, 12)
        trA:SetDuration(7)
        trA:SetSmoothing("BOTH")
        agA:Play()
        local agB = glowB:CreateAnimationGroup()
        agB:SetLooping("BOUNCE")
        local trB = agB:CreateAnimation("Translation")
        trB:SetOffset(-26, -10)
        trB:SetDuration(8)
        trB:SetSmoothing("BOTH")
        agB:Play()
    end

    BuildHeader(f)
    BuildHero(f)
    BuildCards(f)
    BuildFooter(f)
    BuildShowAnimations(f)

    sessionStart = GetTime()

    -- 在线时长每秒刷新
    C_Timer.NewTicker(1, function()
        if frame and frame:IsShown() and refs.time then
            refs.time:SetText(T.FormatDuration(GetTime() - sessionStart))
        end
    end)

    ns.UI.ApplyPosition()
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
    ns.UI.ApplyPosition()
    UpdateGreeting()
    UpdateSignoff()
    ns.UI.RefreshStats()
    if ns.DB().animations and frame.showAG and not frame:IsShown() then
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
