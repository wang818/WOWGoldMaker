---------------------------------------------------------------------------
-- WOWGoldMaker / Theme.lua
-- 设计系统: 配色、字体、通用控件工厂。所有界面元素都从这里拿, 保证风格统一。
---------------------------------------------------------------------------

local ADDON, ns = ...

local T = {}
ns.T = T

T.PATH  = "Interface\\AddOns\\" .. ADDON .. "\\Media\\"
T.WHITE = "Interface\\Buttons\\WHITE8x8"

-- ------------------------------------------------------------------ 配色
-- 金色主题: 深色玻璃面板 + 金色主色 + 青色点缀
T.C = {
    gold    = { 0.91, 0.76, 0.35 },   -- 主色
    goldHi  = { 1.00, 0.87, 0.52 },   -- 主色高亮
    goldLo  = { 0.72, 0.58, 0.26 },   -- 主色按压
    teal    = { 0.29, 0.78, 0.66 },   -- 点缀色
    text    = { 0.92, 0.93, 0.95 },
    muted   = { 0.58, 0.61, 0.67 },
    faint   = { 0.40, 0.43, 0.49 },
    ink     = { 0.13, 0.11, 0.06 },   -- 金色底上的深色文字
    green   = { 0.40, 0.80, 0.45 },
    red     = { 0.92, 0.42, 0.42 },
    white   = { 1.00, 1.00, 1.00 },
}

function T.rgb(c, a)
    if type(c) ~= "table" then c = T.C.white end
    return c[1], c[2], c[3], a or c[4] or 1
end

function T.hex(c)
    if type(c) ~= "table" then c = T.C.white end
    return format("%02x%02x%02x", c[1] * 255, c[2] * 255, c[3] * 255)
end

-- ------------------------------------------------------------------ 字体
-- 跟随客户端本地化字体, 保证中文渲染正确
local fontFile

function T.FontFile()
    if not fontFile then
        local ok, file = pcall(function()
            return (GameFontHighlight and GameFontHighlight:GetFont())
        end)
        fontFile = (ok and type(file) == "string" and file)
            or STANDARD_TEXT_FONT
            or "Fonts\\FRIZQT__.TTF"
    end
    return fontFile
end

function T.Text(parent, size, color, flags, layer)
    local fs = parent:CreateFontString(nil, layer or "OVERLAY")
    fs:SetFont(T.FontFile(), size, flags or "")
    if color then
        fs:SetTextColor(T.rgb(color))
    end
    fs:SetShadowColor(0, 0, 0, 0.6)
    fs:SetShadowOffset(1, -1)
    fs:SetJustifyH("LEFT")
    fs:SetJustifyV("MIDDLE")
    return fs
end

-- ------------------------------------------------------------------ 基础件

-- 深色渐变圆角面板 (颜色已烘焙进贴图)
function T.Panel(parent, w, h)
    local f = CreateFrame("Frame", nil, parent)
    f:SetSize(w, h)
    local bg = f:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints(true)
    bg:SetTexture(T.PATH .. "panel")
    f.bg = bg
    return f
end

-- 玻璃卡片 (白色蒙版, 运行时上色)
function T.Glass(parent, w, h, tex)
    local f = CreateFrame("Frame", nil, parent)
    f:SetSize(w, h)
    local bg = f:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints(true)
    local file = tex or "card"
    bg:SetTexture(T.PATH .. file)
    -- card / panel 都是带圆角的贴图, 会随尺寸横向拉伸, 用九宫格保住圆角
    -- (sq 是纯色块, 不需要; 硬套九宫格反而会把纯色块切出接缝)
    if file ~= "sq" then
        pcall(function()
            bg:SetTextureSliceMargins(24, 24, 24, 24)
            bg:SetTextureSliceMode(Enum.UITextureSliceMode.Stretched)
        end)
    end
    f.bg = bg
    return f
end

-- 纯色细线 / 色块
function T.Line(parent, w, h, color, alpha)
    local f = CreateFrame("Frame", nil, parent)
    f:SetSize(w, h)
    local t = f:CreateTexture(nil, "BACKGROUND")
    t:SetAllPoints(true)
    t:SetTexture(T.WHITE)
    t:SetVertexColor(T.rgb(color, alpha))
    return f
end

-- 柔光斑
function T.Glow(parent, size, color, alpha, tex)
    local t = parent:CreateTexture(nil, "BORDER", nil, -2)
    t:SetTexture(T.PATH .. (tex or "glow"))
    t:SetSize(size, size)
    if color then t:SetVertexColor(T.rgb(color)) end
    t:SetAlpha(alpha or 0.15)
    return t
end

-- ------------------------------------------------------------------ 按钮
-- kind: "primary" 金色实心 | "secondary" 玻璃
function T.Button(parent, w, h, label, kind)
    kind = kind or "secondary"
    local c = T.C
    local b = CreateFrame("Button", nil, parent)
    b:SetSize(w, h)

    -- 悬停时从边缘透出的柔光
    local glow = b:CreateTexture(nil, "BACKGROUND", nil, -1)
    glow:SetTexture(T.PATH .. "glow")
    glow:SetSize(w * 1.9, h * 2.8)
    glow:SetPoint("CENTER")
    glow:SetVertexColor(T.rgb(kind == "primary" and c.gold or c.teal))
    glow:SetAlpha(0)
    b.glow = glow

    local bg = b:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints(true)
    bg:SetTexture(T.PATH .. "btn")
    if kind == "primary" then
        bg:SetVertexColor(T.rgb(c.gold))
    else
        bg:SetVertexColor(1, 1, 1, 0.14)
    end
    b.bg = bg

    local txt = T.Text(b, 13, kind == "primary" and c.ink or c.muted)
    txt:SetPoint("CENTER")
    txt:SetText(label or "")
    b.text = txt

    b:SetScript("OnEnter", function(s)
        glow:SetAlpha(kind == "primary" and 0.45 or 0.30)
        if kind == "primary" then
            bg:SetVertexColor(T.rgb(c.goldHi))
        else
            bg:SetVertexColor(1, 1, 1, 0.22)
            txt:SetTextColor(T.rgb(c.text))
        end
    end)
    b:SetScript("OnLeave", function(s)
        glow:SetAlpha(0)
        if kind == "primary" then
            bg:SetVertexColor(T.rgb(c.gold))
        else
            bg:SetVertexColor(1, 1, 1, 0.14)
            txt:SetTextColor(T.rgb(c.muted))
        end
    end)
    b:SetScript("OnMouseDown", function(s)
        if kind == "primary" then bg:SetVertexColor(T.rgb(c.goldLo)) end
    end)
    b:SetScript("OnMouseUp", function(s)
        if kind == "primary" then bg:SetVertexColor(T.rgb(c.goldHi)) end
    end)

    return b
end

-- 带悬停底色的方形图标按钮 (关闭 / 小图标)
function T.IconButton(parent, size, drawIcon)
    local c = T.C
    local b = CreateFrame("Button", nil, parent)
    b:SetSize(size, size)

    local bg = b:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints(true)
    bg:SetTexture(T.PATH .. "sq")
    bg:SetVertexColor(1, 1, 1, 0)
    b.bg = bg

    if drawIcon then drawIcon(b) end

    b:SetScript("OnEnter", function(s)
        bg:SetVertexColor(1, 1, 1, 0.14)
        if b.SetIconsColor then b:SetIconsColor(c.text[1], c.text[2], c.text[3]) end
    end)
    b:SetScript("OnLeave", function(s)
        bg:SetVertexColor(1, 1, 1, 0)
        if b.SetIconsColor then b:SetIconsColor(T.rgb(c.muted)) end
    end)
    return b
end

-- 关闭按钮 (两条 45° 细线拼出 X, 不依赖贴图)
function T.CloseButton(parent, onClick)
    local b = T.IconButton(parent, 24)
    local c = T.C

    local lines = {}
    for i, rot in ipairs({ 0.785398, -0.785398 }) do
        local t = b:CreateTexture(nil, "OVERLAY")
        t:SetTexture(T.WHITE)
        t:SetSize(10, 1.6)
        t:SetPoint("CENTER")
        t:SetRotation(rot)
        t:SetVertexColor(T.rgb(c.muted))
        lines[i] = t
    end
    b.SetIconsColor = function(_, r, g, bl)
        for _, t in ipairs(lines) do t:SetVertexColor(r, g, bl, 1) end
    end

    b:SetScript("OnClick", onClick)
    return b
end

-- ------------------------------------------------------------------ 勾选框
function T.Checkbox(parent, label, get, set)
    local c = T.C
    local b = CreateFrame("Button", nil, parent)
    b:SetSize(20, 20)

    local box = b:CreateTexture(nil, "BACKGROUND")
    box:SetAllPoints(true)
    box:SetTexture(T.PATH .. "sq")
    box:SetVertexColor(1, 1, 1, 0.35)

    local check = b:CreateTexture(nil, "ARTWORK")
    check:SetSize(13, 13)
    check:SetPoint("CENTER")
    check:SetTexture("Interface\\Buttons\\UI-CheckBox-Check")
    check:SetVertexColor(T.rgb(c.gold))

    local txt = T.Text(b, 12, c.text)
    txt:SetPoint("LEFT", b, "RIGHT", 9, 0)
    txt:SetJustifyV("MIDDLE")
    txt:SetText(label)

    -- 命中区域扩大到整行文字
    b:SetHitRectInsets(0, -(txt:GetWidth() or 60) - 9, -3, -3)

    local function Refresh()
        check:SetShown(get() and true or false)
        box:SetVertexColor(T.rgb(get() and c.gold or c.white, get() and 0.75 or 0.35))
    end

    b:SetScript("OnClick", function()
        set(not get())
        Refresh()
    end)
    b:SetScript("OnEnter", function() box:SetVertexColor(T.rgb(c.goldHi, 0.9)) end)
    b:SetScript("OnLeave", Refresh)

    Refresh()
    b.Refresh = Refresh
    return b
end

-- ------------------------------------------------------------------ 工具

-- 金币数量缩写: 1234567 -> 123.5w / 1234 -> 1,234
function T.ShortGold(copper)
    local gold = math.floor((copper or 0) / 10000)
    if gold >= 10000 then
        return format("%.1fw", gold / 10000)
    end
    local s = tostring(gold)
    local rev = s:reverse():gsub("(%d%d%d)", "%1,")
    return (rev:reverse():gsub("^,", ""))
end

-- 会话时长 mm:ss / h:mm:ss
function T.FormatDuration(sec)
    sec = math.max(0, math.floor(sec))
    if sec >= 3600 then
        return format("%d:%02d:%02d", sec / 3600, (sec % 3600) / 60, sec % 60)
    end
    return format("%02d:%02d", sec / 60, sec % 60)
end
