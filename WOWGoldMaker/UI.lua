---------------------------------------------------------------------------
-- WOWGoldMaker / UI.lua
-- 单页主界面:
--   第一行  头像 · 问候 · 金币 · 等级 · 在线时长 · 设置 · 关闭
--   第二行  专业页签 (急救 / 烹饪 / 炼金术) + 配方/材料切换
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
-- 列表改成「可变高的块」: 每条配方 = 一行商品 + 若干行材料 (一样材料一行),
-- 材料行左缩进一个商品图标的宽度, 空出来的那一段画从属虚线连回商品行。
local PRODUCT_H   = 26   -- 商品行高 (商品名 + 售价 两行)
local MAT_LINE_H  = 13   -- 材料行高 (一样材料一行)
local MAT_INDENT  = 22   -- 材料行左缩进 = 商品图标列宽
local MAT_ICON    = 9    -- 材料行图标尺寸
local MAT_PRICE_W = 84   -- 材料行右侧金额宽度
local MAT_RIGHT   = 48   -- 材料行右边界: 让金额右缘与商品行的「盈亏」列对齐 (按钮 40 + 间距 8)
-- NPC 价格列 (材料行, 夹在材料名与金额之间)
--   卖价 = 客户端自带的「卖给商人」单价, 只读
--   买价 = 玩家自己录入的「从商人买」单价, 可点开编辑
local MAT_CNT_W   = 24   -- 「×3」这一列: 这个配方需要几个
local MAT_SELL_W  = 54   -- 「卖 1银2铜」列宽
local MAT_BUY_W   = 46   -- 「买 1银2铜」列宽
local MAT_TAG_GAP = 6    -- 卖价 / 买价 之间的间距 (两个 NPC 价算一组)
local MAT_PRICE_GAP = 10 -- NPC 价与「本配方金额」之间的间距 (拉开一点, 免得三个数字连成一片)
local TREE_X      = 7    -- 从属竖虚线的 x (对齐商品图标中心)
local DASH_MAX    = 26   -- 虚线小段的纹理池上限
-- 材料行的最大条数。取全专业的上限: 急救最多 3 项, 烹饪 4 项, 炼金的「点金石」要 7 项。
-- 格子是按行预建的 (用不到的隐藏), 所以这里写大的代价只是每行多几个空框。
local MAT_CELLS = 7
local BAR_W    = 3       -- 滚动指示条宽度
local BTN_W    = 40      -- 行尾查价按钮宽度
local SCROLL_STEP = 44   -- 滚轮一格滚多远 (约一个配方块)

-- 行内字号 (整体收小的那一档)
local F_TITLE  = 10      -- 商品名
local F_PROD   = 8       -- 产物售价
local F_MAT    = 7       -- 材料名 / 材料金额
local F_REQ    = 9       -- 技能等级 [300]
local F_BTN    = 8       -- 行内按钮
local F_PRICE  = 8       -- 右侧盈亏

local frame, content
local contentW = BASE_W
-- 层级排序 (BACKGROUND 最低), 声明要放在 DebugInfo 之前: Lua 里 local 只在其声明之后的
-- 位置可见, 放到文件后半段的话, 前半段函数里引用到的会是全局 nil。
local STRATA_ORDER = {
    BACKGROUND = 1, LOW = 2, MEDIUM = 3, HIGH = 4,
    DIALOG = 5, FULLSCREEN = 6, FULLSCREEN_DIALOG = 7, TOOLTIP = 8,
}

-- 每层用的 frame level: 低层 (LOW/MEDIUM) 压到最低, 方便"待在背包下面";
-- 高层 (HIGH 以上) 抬到 200, 用来盖住 EllesmereUI (背包 HIGH+100、快捷操作层 DIALOG)。
local STRATA_LEVEL = {
    BACKGROUND = 0, LOW = 1, MEDIUM = 1,
    HIGH = 200, DIALOG = 200,
    FULLSCREEN = 200, FULLSCREEN_DIALOG = 200, TOOLTIP = 200,
}
local refs = {}
local tabs = {}            -- key -> 页签按钮
local profIcons = {}       -- key -> 页签图标纹理
local rows = {}            -- 列表行池

local scroll, listContent, track, thumb, sbar
local noticeFrame, noticeText, noticeToken   -- 页面内浮层提示

local curKey  = "first-aid"   -- 当前专业
local curMode = "list"        -- "list" 配方 | "mats" 材料汇总

-- 颜色码剥离: 行内文字带 |cff... 前缀和 ×N 的灰色段, 塞进 tooltip 前要还原成纯文字
local function PlainText(s)
    if type(s) ~= "string" then return "" end
    s = s:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
    return s
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

--------------------------------------------------------------------------- 逐物提示
--
-- 提示按「谁被指着」分开: 商品名 → 配方详情, 材料行 → 该材料详情, 图标 → 原生物品提示。
-- 材料行是块的子 frame, 鼠标从商品行移到材料行上时两者会先后触发 OnLeave / OnEnter,
-- 顺序不保证, 所以用 tipOwner 记录当前归属: 离开时延时一帧, 只有归属还是自己才关,
-- 避免把刚接管提示的材料行一起关掉 (表现是「提示一闪一闪」)。

local tipOwner
local tipRebuild        -- 当前这条提示的「重建函数」, 物品数据晚到用它整条重画

local function TipBegin(owner)
    -- 每次「全新的一次悬停」都要重新给够重试次数。判据是归属变了 (tipOwner 在提示关闭
    -- 后会被置 nil), 而不是「和上次是不是同一个控件」——同一行连着悬停两次就是同一个
    -- 控件, 按后者判断的话第一次把重试次数用完, 后面每次悬停都不会再补, 表现就是
    -- 「第一次能看到物品描述, 再悬停又只剩名字」。
    if tipOwner ~= owner and type(owner) == "table" then
        owner._tipTries = 0
    end
    tipOwner = owner
    TooltipAtCursor(owner)
    pcall(GameTooltip.ClearLines, GameTooltip)
end

-- 物品数据是异步回包的: 第一次悬停往往只有一个名字, 描述/用途那几行要等下一次。
-- 这里在数据没到的时候排一次重建, 用户不用把鼠标挪开再挪回来。
-- 用 owner._tipTries 限次 (最多补两次), 免得客户端一直不给数据时反复重排。
local function TipRetry(rebuild)
    local owner = tipOwner
    if not owner or type(rebuild) ~= "function" then return end
    if not (owner._tipTries and owner._tipTries < 2) then return end
    owner._tipTries = owner._tipTries + 1
    -- 第一次快一点 (多数情况数据就在本地了), 第二次等一轮服务器往返
    local delay = (owner._tipTries == 1) and 0.4 or 1.2
    C_Timer.After(delay, function()
        if tipOwner ~= owner then return end
        if GameTooltip.IsShown and not GameTooltip:IsShown() then return end
        pcall(rebuild)
    end)
end

local function TipEnd(owner)
    if tipOwner ~= owner then return end          -- 已被别的控件接管, 别抢着关
    C_Timer.After(0, function()
        if tipOwner == owner then
            tipOwner = nil
            -- 提示真的关掉了才算这次悬停结束: 把重试次数还回去, 下次悬停重新等数据
            if type(owner) == "table" then owner._tipTries = 0 end
            GameTooltip:Hide()
        end
    end)
end

-- 物品基础信息 (名称 + 链接)。取值链收在 Npc.lua 里: 新版客户端的
-- C_Item.GetItemInfo 返回的是 ItemInfo 表, 旧的是多返回值, 两种都要认。
local function ItemInfo(itemID)
    if not itemID then return nil end
    if ns.NPC and ns.NPC.Info then
        local name, link = ns.NPC.Info(itemID)
        if name or link then return name, link end
        return nil
    end
    -- Npc.lua 没加载时的兜底 (取值链与它保持一致: 表形态 / 多返回值形态都认)
    if C_Item and type(C_Item.GetItemInfo) == "function" then
        local ok, a, b = pcall(C_Item.GetItemInfo, itemID)
        if ok then
            if type(a) == "table" then
                local n, l = a.itemName, a.itemLink
                local hasN = (type(n) == "string" and n ~= "")
                local hasL = (type(l) == "string" and l ~= "")
                if hasN or hasL then return hasN and n or nil, hasL and l or nil end
            elseif type(a) == "string" and a ~= "" then
                return a, b
            end
        end
    end
    if type(GetItemInfo) == "function" then
        local ok, name, link = pcall(GetItemInfo, itemID)
        if ok and type(name) == "string" and name ~= "" then return name, link end
    end
    return nil
end

-- 先用原生物品提示打底 (品质色标题 / 物品等级 / 使用效果 / 描述 / 售价),
-- 拿不到缓存就退化成一行手写名字, 保证提示非空。
-- 返回 true = 走的是原生提示, 调用方可以放心往后面追加自己的行。
local function NativeItemTip(itemID, fallbackName)
    local name, link = ItemInfo(itemID)
    if itemID and (name or link) then
        local lines = 0

        -- 首选 SetItemByID: 现代接口, 直接按 ID 组提示
        if GameTooltip.SetItemByID then
            if pcall(GameTooltip.SetItemByID, GameTooltip, itemID) and GameTooltip.NumLines then
                local okN, n = pcall(GameTooltip.NumLines, GameTooltip)
                lines = (okN and type(n) == "number") and n or 0
            end
        end

        -- SetItemByID 不可用 / 只塞出一行名字时, 换成带完整链接的 SetHyperlink 再试一次。
        -- 链接里带着物品 ID 与品质, 客户端才会把描述、用途、售价那些行一起填进来。
        if lines < 2 and GameTooltip.SetHyperlink then
            local hl = (type(link) == "string" and link ~= "")
                and link
                or ("item:" .. tostring(itemID) .. ":0:0:0:0:0:0:0")
            if pcall(GameTooltip.SetHyperlink, GameTooltip, hl) and GameTooltip.NumLines then
                local okN, n = pcall(GameTooltip.NumLines, GameTooltip)
                local got = (okN and type(n) == "number") and n or 0
                if got > lines then lines = got end
            end
        end

        if lines > 0 then
            -- 只有一行 = 客户端目前只认得名字, 描述/用途还没到, 排一次重建等它
            if lines < 2 then TipRetry(tipRebuild) end
            -- SetItemByID / SetHyperlink 有可能顺手改掉 owner, 重新贴回光标
            TooltipAtCursor(tipOwner)
            return true
        end
        pcall(GameTooltip.ClearLines, GameTooltip)
    end
    -- 走到这里说明物品数据不完整 (只有名字, 或者干脆还没有) —— 客户端的物品数据
    -- 是异步回包的, 排一次重建等它, 用户不用把鼠标移开再放回来。
    TipRetry(tipRebuild)
    GameTooltip:AddLine(fallbackName or (itemID and ("物品 #" .. tostring(itemID))) or "?", 1, 1, 1, true)
    if itemID then
        GameTooltip:AddLine("物品资料还在向客户端索取, 停一下再看", 0.55, 0.58, 0.63)
    end
    return false
end

-- 悬停要不要附带我们自己的行 (配方 / 单价 / 盈亏 / NPC 价)。
-- 默认关: 悬停就只给「物品原来的介绍」, 和在背包、拍卖行里看到的一模一样, 不多一行。
-- 想看额外信息用 /wgm tip extra 打开 (存进存档, 重登还在)。
local function TipExtra()
    local db = ns.DB and ns.DB()
    return (type(db) == "table" and not not db.tipExtra)
end

-- 只出「物品原来的介绍」时的入口。
-- 写法照客户端自带的「无限副本手册」(DungeonsForever/Core/ZoneOrb.lua 的 ItemTip):
--   SetOwner → SetItemByID → Show, 中间不 ClearLines, 填完内容之后也不再改 owner。
-- 我们原先那套「填完内容再 TooltipAtCursor 一次」在部分客户端上会把刚填好的行清掉,
-- 表现就是「悬停什么都不出来」。
local function TipStart(anchor)
    if tipOwner ~= anchor and type(anchor) == "table" then
        anchor._tipTries = 0            -- 新的一次悬停, 重试次数还回去
    end
    tipOwner = anchor
    if GameTooltip.SetOwner and type(anchor) == "table" then
        if not pcall(GameTooltip.SetOwner, GameTooltip, anchor, "ANCHOR_CURSOR_RIGHT") then
            pcall(GameTooltip.SetOwner, GameTooltip, anchor, "ANCHOR_RIGHT")
        end
    end
end

-- 返回 true = 客户端给足了内容 (>= 2 行), 调用方可以放心追加自己的行
local function ShowNativeTip(anchor, itemID, fallbackName)
    TipStart(anchor)

    local got = 0
    local name, link = ItemInfo(itemID)
    if itemID and (name or link) then
        if GameTooltip.SetItemByID then
            if pcall(GameTooltip.SetItemByID, GameTooltip, itemID) and GameTooltip.NumLines then
                local okN, n = pcall(GameTooltip.NumLines, GameTooltip)
                got = (okN and type(n) == "number") and n or 0
            end
        end
        -- 只吐出一行名字时换成带完整链接的 SetHyperlink 再试一次
        if got < 2 and GameTooltip.SetHyperlink then
            local hl = (type(link) == "string" and link ~= "")
                and link
                or ("item:" .. tostring(itemID) .. ":0:0:0:0:0:0:0")
            if pcall(GameTooltip.SetHyperlink, GameTooltip, hl) and GameTooltip.NumLines then
                local okN, n = pcall(GameTooltip.NumLines, GameTooltip)
                local m = (okN and type(n) == "number") and n or 0
                if m > got then got = m end
            end
        end
    end

    if got <= 0 then
        -- 客户端这一下没给出内容: 至少显示名字, 别让悬停变成空白
        pcall(GameTooltip.ClearLines, GameTooltip)
        local txt = (type(fallbackName) == "string" and fallbackName ~= "" and fallbackName)
            or (itemID and ("物品 #" .. tostring(itemID))) or "?"
        GameTooltip:AddLine(txt, 1, 1, 1, true)
        if itemID then
            GameTooltip:AddLine("物品资料还在向客户端索取, 停一下再看", 0.55, 0.58, 0.63)
        end
    end

    GameTooltip:Show()
    -- 客户端物品数据是异步回包的: 内容不全就排一次整条重画 (最多两次)
    if got < 2 then TipRetry(tipRebuild) end
    return got >= 2
end

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
    -- 层级排查用: 面板默认 MEDIUM (待在背包下面), 这里把同层的参照物一起打出来
    if frame then
        print("  层级:", tostring(frame:GetFrameStrata()), "frameLevel:", tostring(frame:GetFrameLevel()))
    end
    local function PrintStrata(label, f2)
        if not (f2 and type(f2.GetFrameStrata) == "function") then
            print("  " .. label .. ": 不存在"); return
        end
        local okS, st = pcall(f2.GetFrameStrata, f2)
        local okL, lv = pcall(f2.GetFrameLevel, f2)
        -- 只有同 strata 时 frame level 才有可比性, 跨层直接比层
        local rel = "?"
        if okS and frame then
            local a = STRATA_ORDER[st] or 0
            local b = STRATA_ORDER[frame:GetFrameStrata()] or 0
            if a ~= b then
                rel = (a > b) and "在面板之上" or "在面板之下"
            else
                rel = ((okL and lv or 0) > frame:GetFrameLevel())
                    and "在面板之上(同层)" or "在面板之下(同层)"
            end
        end
        print("  " .. label .. ":", okS and tostring(st) or "?", "level:", okL and tostring(lv) or "?", "|", rel)
    end
    PrintStrata("背包 (EUI_MainBagFrame)", _G.EUI_MainBagFrame)
    PrintStrata("背包 (ContainerFrame1)", _G.ContainerFrame1)
    PrintStrata("拍卖行窗口", _G.AuctionHouseFrame)
    PrintStrata("副本手册主窗", _G.DungeonsForever_MainFrame)
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

-- 行内分栏: 图标 / 商品名 / 技能 / 盈亏 / 查价
-- 材料不再挤在商品行里 (那样 4 样材料每样只有 30px), 改成竖排在下面, 所以商品行的
-- 剩余宽度全部给商品名, 长名字基本不会被截断了。
local ROW_ICON_W = 22    -- 图标列宽度 (含与文字的间距)
local ROW_GAP    = 8     -- 列间距
local REQ_W      = 22    -- 技能等级 [300] 的宽度

-- 前向声明: 下面几处都要用 —— 面板改宽时 RelayoutRows 要拿 RowColumns 重画金额
local ApplyPriceToRow, ApplyLivePrices, CheckRowPrice, AnchorRowRight

local function RowColumns(w)
    -- 盈亏要写「AH 盈 1金23银45铜」这种带铜位的完整金额, 比原来的「盈 12银」长一截
    local priceW = math.max(74, math.min(98, w * 0.21))
    local rightFixed = BTN_W + 2 + 6 + priceW + 6 + REQ_W     -- 按钮 + 间距 + 价格 + 间距 + 技能
    local titleW = w - ROW_ICON_W - ROW_GAP - rightFixed
    if titleW < 90 then titleW = 90 end
    return titleW, priceW
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

-- 商品行的「NPC 售价」标签: 紧跟在商品名文字后面。
-- 商品名那一列宽度是固定的 (用来截断), 标签不能锚 title 的右缘 —— 面板一宽, 标签就飘到
-- 半截空白里去了。所以按文字估算宽度算位置; 放不下先退成只写金额, 再放不下就不显示
-- (完整信息在悬停提示里, 不会丢)。
local function PlaceNpcTag(r)
    local tag = r.npcTag
    if not (tag and tag:IsShown()) then return end

    local w = r:GetWidth() or (BASE_W - PAD * 2 - 8)
    local titleW = RowColumns(w)
    local left = ROW_ICON_W + math.min(ApproxWidth(PlainText(r.title:GetText()), F_TITLE) + 8, titleW)
    local limit  = ROW_ICON_W + titleW

    local txt = tag.fullText
    if not txt or txt == "" then tag:Hide(); return end
    if left + ApproxWidth(txt, F_MAT) > limit then
        txt = tag.shortText
        if not txt or txt == "" or left + ApproxWidth(txt, F_MAT) > limit then
            tag:Hide()
            return
        end
    end

    tag:SetText(txt)
    tag:ClearAllPoints()
    tag:SetPoint("TOPLEFT", r, "TOPLEFT", left, -4)
end

-- 材料行的金额文字。
-- 数量 > 1 时真正花出去的是「单价 × 数量」, 只写单价会让人以为成本就是那么点。
-- 材料改成竖排后每行有整行的宽度, 一般直接写得出「单价×3 = 合计」; 面板被拖窄时
-- 再按可用宽度降级成「×3 合计」/「共合计」/「合计」。
local function MatPriceText(AH, unit, cnt, cw, size)
    local u = AH.MoneyEx(unit)          -- 精确到铜: 差 1 铜也是差, 不能四舍五入掉
    if not cnt or cnt <= 1 then return u end

    local t = AH.MoneyEx(unit * cnt)
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

-- 从属虚线: 从商品图标下方拖一条竖虚线, 每行材料再伸出一小段横线连到它上面
--
-- 材料行不再挤在商品行右侧 (4 样材料时每样只有 30px, 名字和金额都要砍),
-- 而是竖排在商品行下面, 每样材料独占一行、一行一样东西; 左侧空出整整一个商品图标的
-- 宽度, 那一段用虚线表示「下面这几样都属于上面那个商品」。
-- 虚线由一串 1x2 的小段拼出来 (每 5px 一段), 纹理池按需增长, 上限 DASH_MAX。
local function LayoutTree(r)
    local n = r.cellCount or 0
    local shown = 0
    if n > 0 then
        local d = PRODUCT_H - 6                                  -- 商品图标下沿再往下一点起笔
        local last = PRODUCT_H + (n - 1) * MAT_LINE_H + MAT_LINE_H * 0.5  -- 最后一行材料的中线
        while d <= last + 0.5 and shown < DASH_MAX do
            shown = shown + 1
            local t = r.dashes[shown]
            if not t then
                t = r:CreateTexture(nil, "ARTWORK")
                t:SetColorTexture(1, 1, 1, 0.20)
                t:SetSize(1, 2)
                r.dashes[shown] = t
            end
            t:ClearAllPoints()
            t:SetPoint("TOPLEFT", r, "TOPLEFT", TREE_X, -d)
            t:Show()
            d = d + 5
        end
    end
    for i = shown + 1, #r.dashes do r.dashes[i]:Hide() end
end

-- 材料行排版: 一样材料一行, 整行宽度都能用 (名字在左, 金额靠右)
local function RelayoutMats(r, w)
    w = w or r:GetWidth() or (BASE_W - PAD * 2 - 8)
    local n = r.cellCount or 0
    local cw = w - MAT_INDENT - MAT_RIGHT      -- 右缘与「盈亏」列对齐, 不越到查价按钮下面
    if cw < 90 then cw = 90 end
    -- 名字从「图标右缘 +4」起笔, 这 13px 也要从可用宽度里扣, 否则右侧那几列
    -- 会正好压住名字末尾 (差的就是这一段)
    local used = MAT_ICON + 4 + MAT_PRICE_W + MAT_SELL_W + MAT_BUY_W + MAT_CNT_W
               + MAT_TAG_GAP * 2 + MAT_PRICE_GAP * 2
    local nameW = cw - used
    if nameW < 40 then nameW = 40 end   -- 下限再低一点: 名字宁可裁, 也不能压到数量列上

    for k = 1, MAT_CELLS do
        local c = r.cells[k]
        if not c then
            -- 这一格还没被建出来 (按需创建, 见 GetCell): 没建就是从来没用到, 不必隐藏
        elseif k <= n then
            -- 材料行整行都是这一样材料的命中区 (悬停看它、左键在拍卖行搜它),
            -- 所以控件铺满整行宽度; 右侧几列仍按 cw 的右缘摆 (MAT_RIGHT 那段留白
            -- 是给商品行的按钮列对齐用的), 否则金额会跟着控件一起右移。
            c:SetSize(w - MAT_INDENT, MAT_LINE_H)
            c:ClearAllPoints()
            c:SetPoint("TOPLEFT", r, "TOPLEFT", MAT_INDENT, -(PRODUCT_H + (k - 1) * MAT_LINE_H))
            c.name:SetWidth(nameW)
            c.price:SetWidth(MAT_PRICE_W)
            c.price:ClearAllPoints()
            c.price:SetPoint("RIGHT", c, "RIGHT", -MAT_RIGHT, 0)

            -- 右侧从右往左排: 本配方金额 → NPC 买价 → NPC 卖价 → 需要几个,
            -- 左边的余量全给材料名
            c.buyTag:SetWidth(MAT_BUY_W)
            c.buyTag:ClearAllPoints()
            c.buyTag:SetPoint("RIGHT", c.price, "LEFT", -MAT_PRICE_GAP, 0)
            c.sellTag:SetWidth(MAT_SELL_W)
            c.sellTag:ClearAllPoints()
            c.sellTag:SetPoint("RIGHT", c.buyTag, "LEFT", -MAT_TAG_GAP, 0)
            c.cnt:SetWidth(MAT_CNT_W)
            c.cnt:ClearAllPoints()
            c.cnt:SetPoint("RIGHT", c.sellTag, "LEFT", -MAT_TAG_GAP, 0)
            c.buyHit:SetSize(MAT_BUY_W, MAT_LINE_H)
            c.buyHit:ClearAllPoints()
            c.buyHit:SetPoint("RIGHT", c.price, "LEFT", -MAT_PRICE_GAP, 0)
            c:Show()
        else
            c:Hide()
        end
    end
    LayoutTree(r)
end

-- 行宽 / 文本宽度随面板宽度自适应
local function RelayoutRows(w)
    if not (w and w > 0) then return end
    local titleW, priceW = RowColumns(w)
    for i = 1, #rows do
        local r = rows[i]
        r:SetWidth(w)
        r.title:SetWidth(titleW)
        r.prodPrice:SetWidth(titleW)
        r.price:SetWidth(priceW)
        r.npcPrice:SetWidth(priceW)
        RelayoutMats(r, w)
        PlaceNpcTag(r)
        -- 金额要写成「单价×数量 = 合计」还是只写合计, 取决于可用宽度, 用已有结果重画一次
        if ApplyPriceToRow and r.payload then ApplyPriceToRow(r, r.payload) end
    end
end

-- 滚动位置换算: 滚轮 / 拖滑块 / 点轨道三处共用同一套夹取
local function ScrollMax()
    local viewH = scroll:GetHeight() or 1
    local ch = listContent:GetHeight() or 1
    return math.max(0, ch - viewH)
end

-- p: 0 = 顶部, 1 = 底部
local function ScrollTo(p)
    local m = ScrollMax()
    if m <= 0 then return end
    if p < 0 then p = 0 elseif p > 1 then p = 1 end
    scroll:SetVerticalScroll(m * p)
    if UpdateThumb then UpdateThumb() end
end

local function ScrollPixels(px)
    local m = ScrollMax()
    local v = (scroll:GetVerticalScroll() or 0) + px
    if v < 0 then v = 0 elseif v > m then v = m end
    scroll:SetVerticalScroll(v)
    if UpdateThumb then UpdateThumb() end
end

UpdateThumb = function()
    if not (thumb and track and scroll and listContent) then return end
    local grab = sbar and sbar.grab
    local viewH = scroll:GetHeight() or 1
    local ch = listContent:GetHeight() or 1
    local maxScroll = ch - viewH
    if maxScroll <= 0 then
        thumb:Hide()
        if grab then grab:Hide() end   -- 没得滚: 抓取层一起收起, 免得占着鼠标
        return
    end
    thumb:Show()
    if grab then grab:Show() end
    local h = math.max(20, viewH * (viewH / ch))
    thumb:SetHeight(h)

    local p = (scroll:GetVerticalScroll() or 0) / maxScroll
    if p < 0 then p = 0 elseif p > 1 then p = 1 end

    thumb:ClearAllPoints()
    thumb:SetPoint("TOPLEFT", track, "TOPLEFT", 0, -((viewH - h) * p))
end

-- 右侧滚动条。
-- 要紧的是它得是个能吃鼠标的控件, 不能只是贴在面板上的两张纹理: 纹理收不到鼠标事件,
-- 按在滚动条上的那一下会穿到底下的主面板 (f 注册了 RegisterForDrag), 于是"拖滚动条"
-- 变成"拖整个窗口"。这里用 bar(Frame) 接过整条轨道的按下, 再在滑块位置盖一层
-- 透明 grab 专门接拖拽。
local function BuildScrollBar(f)
    local bar = CreateFrame("Frame", nil, f)
    bar:SetWidth(BAR_W + 12)   -- 装得下抓取层 (比滑块宽, 好按住)
    bar:SetPoint("TOP", scroll, "TOPRIGHT", 6, 0)
    bar:SetPoint("BOTTOM", scroll, "BOTTOMRIGHT", 6, 0)
    -- 行挂在 listContent 下, 层级跟着父级往上叠; 不抬高层级行会压住滚动条抢鼠标
    bar:SetFrameLevel((f:GetFrameLevel() or 1) + 6)
    bar:EnableMouse(true)        -- 吃掉按在滚动条上的点击
    bar:EnableMouseWheel(true)   -- 指针停在滚动条上也照样滚

    track = bar:CreateTexture(nil, "BACKGROUND")
    track:SetColorTexture(1, 1, 1, 0.05)
    track:SetWidth(BAR_W)
    track:SetPoint("TOP", bar, "TOP", 0, 0)
    track:SetPoint("BOTTOM", bar, "BOTTOM", 0, 0)

    thumb = bar:CreateTexture(nil, "ARTWORK")
    thumb:SetColorTexture(T.rgb(C.gold, 0.5))
    thumb:SetWidth(BAR_W)
    thumb:SetHeight(24)
    thumb:SetPoint("TOPLEFT", track, "TOPLEFT", 0, 0)
    thumb:Hide()

    -- 透明抓取层: 只有 Frame 能 RegisterForDrag。
    -- 宽度比 3px 的滑块放宽一些, 否则"按住滑块"这个动作根本没有命中率
    local grab = CreateFrame("Frame", nil, bar)
    grab:SetWidth(BAR_W + 12)
    grab:SetPoint("TOP", thumb, "TOP", 0, 0)
    grab:SetPoint("BOTTOM", thumb, "BOTTOM", 0, 0)
    grab:EnableMouse(true)
    grab:RegisterForDrag("LeftButton")
    grab:Hide()
    bar.grab = grab

    -- 光标 y 换算到 bar 的坐标系 (和 thumb:GetBottom() 同一套刻度)
    local function CursorY()
        local _, cy = GetCursorPosition()
        return (cy or 0) / (bar:GetEffectiveScale() or 1)
    end

    grab:SetScript("OnDragStart", function(self)
        -- 记住手抓在滑块的哪个高度, 拖动时滑块才不会跳到光标中心
        self.offset = CursorY() - (thumb:GetBottom() or 0)
        self:SetScript("OnUpdate", function(s)
            local trackH = track:GetHeight() or 1
            local h = thumb:GetHeight() or 1
            local span = trackH - h
            if span <= 1 then return end
            local bottom = CursorY() - (s.offset or 0)
            ScrollTo(((track:GetTop() or 0) - h - bottom) / span)
        end)
    end)
    grab:SetScript("OnDragStop", function(self) self:SetScript("OnUpdate", nil) end)

    -- 按在滑块上方/下方: 翻一页 (按在滑块上算拖拽, 已被 grab 接走)
    bar:SetScript("OnMouseDown", function(_, button)
        if button ~= "LeftButton" then return end
        local viewH = scroll:GetHeight() or 1
        if CursorY() > (thumb:GetTop() or 0) then
            ScrollPixels(-viewH * 0.9)
        else
            ScrollPixels(viewH * 0.9)
        end
    end)

    bar:SetScript("OnMouseWheel", function(_, delta)
        ScrollPixels(-(delta or 0) * SCROLL_STEP)
    end)

    sbar = bar
    return bar
end

local function BuildList(f)
    scroll = CreateFrame("ScrollFrame", nil, f)
    scroll:SetPoint("TOPLEFT", f, "TOPLEFT", PAD, LIST_Y)
    scroll:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -(PAD + 8), LIST_BOT)
    scroll:EnableMouseWheel(true)

    listContent = CreateFrame("Frame", nil, scroll)
    listContent:SetSize(BASE_W - PAD * 2 - 8, 1)
    scroll:SetScrollChild(listContent)

    scroll:SetScript("OnMouseWheel", function(_, delta)
        ScrollPixels(-(delta or 0) * SCROLL_STEP)
    end)

    -- 面板尺寸变化时, 行宽跟着变 (ScrollFrame 的锚点已经自动伸缩)
    scroll:SetScript("OnSizeChanged", function(self, w)
        if listContent then listContent:SetWidth(w) end
        RelayoutRows(w)
        if UpdateThumb then UpdateThumb() end
    end)

    -- 右侧滚动条 (可拖拽, 见 BuildScrollBar)
    BuildScrollBar(f)
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
-- 配方模式 = [价格][查价]; 材料汇总模式没有按钮, 价格直接靠右。
-- 这三样都只属于商品行, 所以锚在行的 TOPRIGHT 再往下压半个商品行高 —— 行高是可变的
-- (商品行 + n 个材料行), 用 RIGHT + 0 的话按钮会飘到整块的中间去。
AnchorRowRight = function(r, withBtn)
    if withBtn then r.btn:Show() else r.btn:Hide() end
    r.btn:ClearAllPoints()
    r.btn:SetPoint("TOPRIGHT", r, "TOPRIGHT", -2, -PRODUCT_H * 0.5)

    -- 盈亏两行 (拍卖行 / NPC) 右缘对齐在按钮左侧, 上下各占一行
    local right = withBtn and -(BTN_W + 2 + 6) or -4
    local pw = r.price:GetWidth() or 72
    r.price:ClearAllPoints()
    r.price:SetPoint("TOPRIGHT", r, "TOPRIGHT", right, -3)
    r.npcPrice:ClearAllPoints()
    r.npcPrice:SetPoint("TOPRIGHT", r, "TOPRIGHT", right, -14)

    -- 技能等级: 落在两行盈亏左边、商品行垂直中线 ("RIGHT" 指向 TOPRIGHT 的点 = 右缘居中)
    r.req:ClearAllPoints()
    r.req:SetPoint("RIGHT", r, "TOPRIGHT", right - pw - 6, -PRODUCT_H * 0.5)
end

-- 建一格材料行 (CreateFrame 那堆控件)。由 GetCell 按需调用 ——
-- 一个配方最多 7 样材料 (炼金的点金石), 但绝大多数只有 3~4 样,
-- 一次就把 7 格全建出来的话, 180 多条炼金配方会白建上千个空框, 切页签时卡一下。
local function MakeCell(r, k)
    local c = CreateFrame("Frame", nil, r)
    c:SetSize(200, MAT_LINE_H)
    -- 每行独立接鼠标: 鼠标停在哪样材料上就只讲那样材料, 不再整行一条大提示
    c:EnableMouse(true)

    -- 整行可悬停, 悬停时给一点底色, 明确指出「现在讲的是这一样」
    c.hl = c:CreateTexture(nil, "BACKGROUND")
    c.hl:SetAllPoints(true)
    c.hl:SetColorTexture(1, 1, 1, 0)
    c.hl:Hide()

    -- 从竖虚线伸过来的一小段横线 (画在行左侧的空白里, 所以是负偏移)
    c.branch = c:CreateTexture(nil, "ARTWORK")
    c.branch:SetColorTexture(1, 1, 1, 0.16)
    c.branch:SetSize(MAT_INDENT - TREE_X - 4, 1)
    c.branch:SetPoint("LEFT", c, "LEFT", TREE_X + 1 - MAT_INDENT, 0)

    c.icon = c:CreateTexture(nil, "ARTWORK")
    c.icon:SetSize(MAT_ICON, MAT_ICON)
    c.icon:SetPoint("LEFT", 0, 0)
    c.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    c.icon:Hide()

    c.name = T.Text(c, F_MAT, C.muted)
    c.name:SetPoint("LEFT", c.icon, "RIGHT", 4, 0)
    c.name:SetWordWrap(false)

    -- 需要几个 (×3)。单独一列而不是拼在名字后面: 名字那列宽度是按可用空间算的,
    -- 拼在末尾的话长名字会先把数字裁掉 —— 数量比名字重要, 不能丢。
    c.cnt = T.Text(c, F_MAT, C.faint)
    c.cnt:SetWordWrap(false)
    c.cnt:SetJustifyH("RIGHT")

    c.price = T.Text(c, F_MAT, C.faint)
    c.price:SetPoint("RIGHT", c, "RIGHT", 0, 0)
    c.price:SetWordWrap(false)
    c.price:SetJustifyH("RIGHT")

    -- NPC 卖价 (客户端自带, 只读)
    c.sellTag = T.Text(c, F_MAT, C.muted)
    c.sellTag:SetWordWrap(false)
    c.sellTag:SetJustifyH("RIGHT")
    c.sellTag:Hide()

    -- NPC 买价 (手动录入, 点一下开编辑框)。空着的时候显示「＋买价」当入口
    c.buyTag = T.Text(c, F_MAT, C.faint)
    c.buyTag:SetWordWrap(false)
    c.buyTag:SetJustifyH("RIGHT")
    c.buyTag:SetText("＋买价")

    -- 文字本身收不到鼠标事件, 盖一个透明小框专门接点击/悬停
    c.buyHit = CreateFrame("Frame", nil, c)
    c.buyHit:EnableMouse(true)
    c.buyHit:SetScript("OnEnter", function(s)
        c.hoverOn(s)
        c.buyTag:SetTextColor(T.rgb(C.goldHi))
    end)
    c.buyHit:SetScript("OnLeave", function(s)
        c.buyTag:SetTextColor(T.rgb(ns.NPC and ns.NPC.Buy(c.itemID) and C.teal or C.faint))
        c.hoverOff(s)
    end)
    c.buyHit:SetScript("OnMouseUp", function()
        ns.UI.EditNpcPrice(c.itemID, PlainText(c.name:GetText()), c)
    end)

    -- 悬停/离开的公共处理: 直接把锚点控件传进来, 提示归属按控件区分
    -- (买价小框和材料行是两个控件, 用同一个归属会让提示闪一下就没了)
    c.hoverOn = function(s)
        -- 材料行接管鼠标后行本身的 OnEnter 不会触发, 这里补上整块高亮,
        -- 否则鼠标一进材料区, 行的底色就"熄灭"了
        r.bg:SetColorTexture(1, 1, 1, 0.05)
        if not c.itemID then
            c.hl:Hide()
            ns.UI.ShowRowTooltip(s, r)      -- 空行不抢提示
            return
        end
        c.hl:SetColorTexture(1, 1, 1, 0.06)
        c.hl:Show()
        ns.UI.ShowMatTooltip(s, r, k)
    end
    c.hoverOff = function(s)
        c.hl:Hide()
        r.bg:SetColorTexture(1, 1, 1, r.odd and 0.025 or 0)
        TipEnd(s)
    end
    c:SetScript("OnEnter", function(s) c.hoverOn(s) end)
    c:SetScript("OnLeave", function(s) c.hoverOff(s) end)
    -- 左键点这一行 = 在拍卖行里搜这样材料 (买价那一格有自己的点击, 不冲突)
    c:SetScript("OnMouseUp", function(_, button)
        if button ~= "LeftButton" or not c.itemID then return end
        ns.UI.SearchInAH(c.itemID, c.matName or PlainText(c.name and c.name:GetText()))
    end)

    c:Hide()
    return c
end

-- 取第 k 格, 没有就现场建一个 (k 会进闭包, 供 ShowMatTooltip 定位是第几样材料)
local function GetCell(r, k)
    local c = r.cells[k]
    if not c then
        c = MakeCell(r, k)
        r.cells[k] = c
    end
    return c
end

local function GetRow(i)
    local r = rows[i]
    if r then return r end

    r = CreateFrame("Frame", nil, listContent)
    r:SetSize(BASE_W - PAD * 2 - 8, PRODUCT_H)
    r.blockH = PRODUCT_H
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

    -- 图标本身是纹理, 收不到鼠标事件, 盖一个透明小框专门接悬停 (看原生物品提示)
    r.iconHit = CreateFrame("Frame", nil, r)
    r.iconHit:SetSize(15, 15)
    r.iconHit:SetPoint("TOPLEFT", 0, -3)
    r.iconHit:EnableMouse(true)
    r.iconHit:SetScript("OnEnter", function(s)
        r.bg:SetColorTexture(1, 1, 1, 0.05)     -- 子控件接管鼠标, 补回整行高亮
        -- 图标还没解析出物品 (数据未回包) 时退回整行详情, 别让这里变成无提示的死区
        if r.itemID then
            ns.UI.ShowItemTip(s, r.itemID, PlainText(r.title and r.title:GetText()))
        else
            ns.UI.ShowRowTooltip(s, r)
        end
    end)
    r.iconHit:SetScript("OnLeave", function(s)
        r.bg:SetColorTexture(1, 1, 1, r.odd and 0.025 or 0)
        TipEnd(s)
    end)

    -- 商品行: 第一行名称, 第二行产物售价 (查价后填)
    r.title = T.Text(r, F_TITLE, C.text)
    r.title:SetPoint("TOPLEFT", ROW_ICON_W, -2)
    r.title:SetWidth(140)
    r.title:SetWordWrap(false)

    r.prodPrice = T.Text(r, F_PROD, C.muted)
    r.prodPrice:SetPoint("TOPLEFT", r.title, "BOTTOMLEFT", 0, 0)
    r.prodPrice:SetWidth(140)
    r.prodPrice:SetWordWrap(false)

    -- NPC 售价 (客户端物品库自带, 离线就有)。位置不能锚 title 的右缘 —— 商品名那列
    -- 宽度固定, 面板一宽标签就飘到空白里, 所以交给 PlaceNpcTag 按文字宽度算。
    r.npcTag = T.Text(r, F_MAT, C.muted)
    r.npcTag:SetWordWrap(false)
    r.npcTag:SetJustifyH("LEFT")
    r.npcTag:Hide()

    -- 材料行: 一样材料一行, 竖排在商品行下面 (位置/宽度由 RelayoutMats 算)
    -- 格子按需创建 (见 GetCell): 炼金有 180 多条配方, 一条预建满 7 格会白建上千个空框
    r.cells = {}
    r.cellCount = 0
    r.dashes = {}          -- 从属竖虚线的小段纹理池 (见 LayoutTree)

    r.req = T.Text(r, F_REQ, C.muted)
    r.req:SetPoint("RIGHT", -6, 0)
    r.req:SetJustifyH("RIGHT")

    -- 价格列: 查价结果。两行 —— 上面拍卖行盈亏, 下面 NPC 盈亏
    -- (材料成本共用, 差别只在成品卖给谁, 所以并排放才看得出该走哪条路)
    r.price = T.Text(r, F_PRICE, C.muted)
    r.price:SetWidth(72)
    r.price:SetWordWrap(false)
    r.price:SetJustifyH("RIGHT")

    r.npcPrice = T.Text(r, F_PRICE, C.muted)
    r.npcPrice:SetWidth(72)
    r.npcPrice:SetWordWrap(false)
    r.npcPrice:SetJustifyH("RIGHT")

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
        TipEnd(s)
    end)

    AnchorRowRight(r, true)

    -- 左键点物品 = 在拍卖行里搜索它 (产物行搜产物, 材料行搜那样材料)。
    -- 两个控件都是普通 Frame, 没有 OnClick, 所以自己接 OnMouseUp:
    --   图标小框自己吃掉了鼠标事件, 要单独挂一次, 否则点图标没反应。
    r.iconHit:SetScript("OnMouseUp", function(_, button)
        if button ~= "LeftButton" then return end
        ns.UI.SearchInAH(r.itemID,
            r.rec and r.rec.name or PlainText(r.title and r.title:GetText()))
    end)

    -- 行悬停: 只负责商品详情 (名称/技能/产出/材料/成本盈亏)。
    -- 材料行与图标各有自己的 OnEnter, 鼠标移到它们上面时由它们接管提示。
    r:SetScript("OnEnter", function(s)
        s.bg:SetColorTexture(1, 1, 1, 0.05)
        ns.UI.ShowRowTooltip(s, r)
    end)
    r:SetScript("OnMouseUp", function(_, button)
        if button ~= "LeftButton" then return end
        ns.UI.SearchInAH(r.itemID,
            r.rec and r.rec.name or PlainText(r.title and r.title:GetText()))
    end)
    r:SetScript("OnLeave", function(s)
        s.bg:SetColorTexture(1, 1, 1, s.odd and 0.025 or 0)
        TipEnd(s)
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

-- 材料行图标: 同样允许「物品数据还没回包」时先空着, 回包后由 RefreshRowIcons 补
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

-- NPC 售价标签 (商品行)。卖价来自客户端物品库, 拿不到就整条隐藏, 留位置给商品名。
local function SetRowNpc(r, itemID)
    local NPC = ns.NPC
    local sell = NPC and NPC.Sell(itemID)
    if sell then
        r.npcTag.fullText  = "NPC " .. NPC.Money(sell)
        r.npcTag.shortText = NPC.Money(sell)          -- 长商品名放不下时只留金额
        r.npcTag:Show()
    else
        r.npcTag.fullText  = nil
        r.npcTag.shortText = nil
        r.npcTag:Hide()
    end
    PlaceNpcTag(r)
end

-- 材料行的两列 NPC 价格:
--   卖 = 客户端自带 (只读), 拿不到就不显示
--   买 = 玩家自己录入的 (db.npcBuy), 没录入时留「＋买价」当入口
local function SetCellNpc(c, itemID)
    local NPC = ns.NPC
    if not NPC then return end

    local sell = NPC.Sell(itemID)
    if sell then
        c.sellTag:SetText("卖 " .. NPC.Money(sell))
        c.sellTag:Show()
    else
        c.sellTag:SetText("")
        c.sellTag:Hide()
    end

    local buy = NPC.Buy(itemID)
    if buy then
        c.buyTag:SetText("买 " .. NPC.Money(buy))
        c.buyTag:SetTextColor(T.rgb(C.teal))
    else
        c.buyTag:SetText("＋买价")
        c.buyTag:SetTextColor(T.rgb(C.faint))
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

-- NPC 售价也是要等物品数据回包的, 和图标一起补 (只补还没拿到的那几行)
local function RefreshRowNpc()
    for i = 1, #rows do
        local r = rows[i]
        if r:IsShown() then
            if r.itemID and not (r.npcTag.fullText) then
                SetRowNpc(r, r.itemID)
            end
            for k = 1, (r.cellCount or 0) do
                local c = r.cells[k]
                if c.itemID and not c.sellTag:IsShown() then
                    SetCellNpc(c, c.itemID)
                end
            end
        end
    end
end

-- 只重画某个物品的 NPC 价格格子 (改完买价用)。
-- 不能直接 RenderList: 那会把列表滚回顶部, 玩家刚记的那一行就跑没影了。
local function RefreshNpcFor(itemID)
    if type(itemID) ~= "number" then return end
    for i = 1, #rows do
        local r = rows[i]
        if r:IsShown() then
            if r.itemID == itemID then SetRowNpc(r, itemID) end
            for k = 1, (r.cellCount or 0) do
                local c = r.cells[k]
                if c.itemID == itemID then SetCellNpc(c, itemID) end
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

    -- 块高随材料数变化 (商品行 + n 个材料行), 所以位置得一条条累加, 不能再用 i * 行高
    local y = 0
    for i = 1, math.max(#rows, #items) do
        local r = rows[i]
        if i <= #items then
            if not r then r = GetRow(i) end
            r:Show()
            r:SetWidth(w)
            local titleW, priceW = RowColumns(w)
            r.title:SetWidth(titleW)
            r.prodPrice:SetWidth(titleW)
            r.price:SetWidth(priceW)
            r.npcPrice:SetWidth(priceW)

            r.odd = (i % 2 == 0)
            r.bg:SetColorTexture(1, 1, 1, r.odd and 0.025 or 0)

            if curMode == "mats" then
                local m = items[i]
                r.rec = nil
                r.cellCount = 0
                r.blockH = PRODUCT_H
                AnchorRowRight(r, false)
                r.title:SetText(m.name or "?")
                r.req:SetText(format("|cffe8c25a×%d|r", m.count or 0))
                SetRowIcon(r, m.id)
                SetRowNpc(r, m.id)

                -- 材料汇总: 单价写在材料名下方, 右侧是该材料的合计花费。
                -- 这行本身就是一样材料, 没有「成品卖给谁」的问题, 所以 NPC 盈亏那行留空。
                r.npcPrice:SetText("")
                local e = ns.Auction and ns.Auction.Price(m.id)
                if e and e.unit then
                    r.prodPrice:SetTextColor(T.rgb(C.gold))
                    r.prodPrice:SetText("单价 " .. ns.Auction.MoneyEx(e.unit) .. "/个")
                    r.price:SetTextColor(T.rgb(C.gold))
                    r.price:SetText("共 " .. ns.Auction.MoneyEx(e.unit * (m.count or 1)))
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
                SetRowNpc(r, rec.item)

                -- 材料行: 一样一行, 名字在前, 金额靠右 (金额查价后再写)
                local mats = rec.mats or {}
                r.cellCount = math.min(#mats, MAT_CELLS)
                r.blockH = PRODUCT_H + r.cellCount * MAT_LINE_H
                for k = 1, r.cellCount do
                    local m = mats[k]
                    local c = GetCell(r, k)
                    SetCellIcon(c, m.id)
                    c.matName = m.name      -- 点这一行去拍卖行搜索时用 (普通字符串, 带色码的不行)
                    SetCellNpc(c, m.id)
                    c.hl:Hide()     -- 行被复用: 上一个配方留下的悬停高亮要清掉
                    c.name:SetText(m.name or ("#" .. tostring(m.id)))
                    c.cnt:SetText(format("×%d", m.count or 1))
                    c.price:SetText("")
                end

                -- 有缓存就直接显示上次算好的售价与盈亏, 点查价按钮才重新查
                ApplyPriceToRow(r, ns.Auction and ns.Auction.Preview(rec))
            end

            r:SetHeight(r.blockH)
            r:ClearAllPoints()
            r:SetPoint("TOPLEFT", 0, -y)
            y = y + r.blockH

            RelayoutMats(r, w)
        elseif r then
            r:Hide()
        end
    end

    listContent:SetHeight(math.max(1, y + 4))

    scroll:SetVerticalScroll(0)
    if UpdateThumb then UpdateThumb() end
end

--------------------------------------------------------------------------- 查价

-- 只画「价钱」的那几处: 产物售价 (商品名下方) + 每样材料右侧的金额。
-- 单独拆出来是为了查价过程中也能先画 —— onProgress 每回来一条就调一次,
-- 玩家不用等整批查完。这很重要: 材料里只要有一项没货, 那一条就要重试到超时,
-- 十几秒里界面一动不动, 看着就像「点了查价但价格没更新」。
ApplyLivePrices = function(r, out)
    local AH = ns.Auction
    if not (AH and out) then return end
    local rec = out.rec

    -- 产物售价
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
            r.prodPrice:SetText("售价 " .. AH.MoneyEx(prod.unit) .. "/个")
        end
    elseif prod then
        r.prodPrice:SetTextColor(T.rgb(C.red))
        r.prodPrice:SetText(prod.reason or "无挂单")
    else
        r.prodPrice:SetText("")
    end

    -- 每样材料的金额 (各自那一行的右侧)。数量 > 1 写成「单价×数量 = 合计」,
    -- 一行放不下时退化成合计 (见 MatPriceText)
    for k = 1, (r.cellCount or 0) do
        local m = rec and rec.mats and rec.mats[k]
        local c = r.cells[k]
        local e = m and out.unit and out.unit[m.id]
        if e and e.unit then
            c.price:SetTextColor(T.rgb(C.gold))
            c.price:SetText(MatPriceText(AH, e.unit, m.count or 1, MAT_PRICE_W, F_MAT))
        elseif e then
            c.price:SetTextColor(T.rgb(C.red))
            c.price:SetText(e.reason or "无挂单")
        else
            c.price:SetText("")
        end
    end
end

-- 把查价结果画到行上:
--   商品行第二行 = 产物售价 (一次做多份时是整个产出), 每个材料行右侧 = 该材料花费,
--   商品行右侧 = 盈亏。数量 > 1 的材料写「单价×数量 = 合计」, 面板被拖窄时自动退化成
--   只写合计 (见 MatPriceText), 完整明细在悬停「查价」按钮的提示里。
ApplyPriceToRow = function(r, out)
    r.payload = out
    local AH = ns.Auction

    local function clear()
        r.prodPrice:SetText("")
        r.npcPrice:SetText("")
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

    -- 产物售价 + 材料金额 (查价中途也走这一段)
    ApplyLivePrices(r, out)

    -- 两行盈亏: 上 = 拍卖行 (扣 5% 税), 下 = NPC (卖给商人, 不抽成)。
    -- 金额精确到铜 (AH.MoneyEx): 1金 = 100银 = 100铜, 差 1 铜也要看得出来。
    if out.profit then
        if out.profit > 0 then
            r.price:SetTextColor(T.rgb(C.green))
            r.price:SetText("AH 盈" .. AH.MoneyEx(out.profit))
        elseif out.profit < 0 then
            r.price:SetTextColor(T.rgb(C.red))
            r.price:SetText("AH 亏" .. AH.MoneyEx(-out.profit))
        else
            r.price:SetTextColor(T.rgb(C.muted))
            r.price:SetText("AH 持平")
        end
    else
        r.price:SetTextColor(T.rgb(C.faint))
        r.price:SetText(format("缺 %d 项", #(out.missing or {})))
    end

    -- NPC 那一行: 三种状态要分清 —— 有价 / 商人不要这件东西 / 价格还没读到
    if out.npcProfit then
        if out.npcProfit > 0 then
            r.npcPrice:SetTextColor(T.rgb(C.green))
            r.npcPrice:SetText("NPC 盈" .. AH.MoneyEx(out.npcProfit))
        elseif out.npcProfit < 0 then
            r.npcPrice:SetTextColor(T.rgb(C.red))
            r.npcPrice:SetText("NPC 亏" .. AH.MoneyEx(-out.npcProfit))
        else
            r.npcPrice:SetTextColor(T.rgb(C.muted))
            r.npcPrice:SetText("NPC 持平")
        end
    elseif out.npcUnit then
        -- 有收购价但材料缺价: 差的是成本, 别说成「商人不收」
        r.npcPrice:SetTextColor(T.rgb(C.faint))
        r.npcPrice:SetText("NPC 缺价")
    elseif out.npcKnown then
        r.npcPrice:SetTextColor(T.rgb(C.faint))
        r.npcPrice:SetText("NPC 不收")
    else
        r.npcPrice:SetTextColor(T.rgb(C.faint))
        r.npcPrice:SetText("NPC 待查")
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
        r.npcPrice:SetText("")            -- 这一轮没查成, 别留上一轮的 NPC 盈亏
        return
    end

    r.busy = true
    r.btn.text:SetText("查询中")
    r.price:SetTextColor(T.rgb(C.gold))
    r.price:SetText(format("0/%d", 1 + #(rec.mats or {})))
    r.npcPrice:SetText("")                -- 查询期间只留进度, 两行都别显示旧数字
    -- 旧价钱也先擦掉: 材料里只要有一项没货, 这一轮就要重试到超时 (十几秒),
    -- 期间留着一堆上一轮的数字, 看着就像「点了查价但价格没更新」
    r.prodPrice:SetText("")
    for k = 1, (r.cellCount or 0) do
        r.cells[k].price:SetText("")
    end

    AH.CheckRecipe(rec, function(out)
        if r.rec ~= rec then return end       -- 行已被别的配方复用, 状态交给 RenderList
        r.busy = false
        r.btn.text:SetText("查价")
        ApplyPriceToRow(r, out)
        AH.Report(out)
    end, function(done, total, _, partial)
        if r.rec ~= rec then return end
        -- 已经查回来的先画上去 (管用的那几样立刻看到价钱), 没回来的照实空着。
        -- 等整批查完再一次性上屏的话, 有一条超时就要干等十几秒才见数字。
        if partial then ApplyLivePrices(r, AH.Partial(rec, partial)) end
        r.price:SetText(format("%d/%d", done, total))
    end, true)   -- force: 点一次按钮就真的去拍卖行查一次, 不用缓存顶替
end

--------------------------------------------------------------------------- 点物品 → 拍卖行搜索

-- 提示优先弹在面板里, 面板没显示时才写聊天框 (和查价那边的口径一致)
local function Say(msg, hold)
    if ns.UI.Notify and ns.UI.Notify(msg, hold or 4) then return end
    ns.Print(msg)
end

-- 自动体检只打一次: 搜不到时打一次有用, 每次都打就是刷屏
local searchDiagDone

-- 左键点物品 (产物 / 材料 / 材料汇总的任意一行) → 在拍卖行里搜索这件东西。
-- 查价队列还在跑的时候先等它跑完: 那会儿插一条浏览查询会把正在读的结果顶掉。
function ns.UI.SearchInAH(itemID, name)
    local AH = ns.Auction
    if not (AH and AH.Search) then
        Say("|cffff5555查价模块未加载, 没法在拍卖行里搜索|r")
        return
    end
    if not itemID then return end

    AH.AwaitIdle(function()
        local ok, info, way = AH.Search(itemID, name)
        if ok then
            Say(format("拍卖行已搜索: %s", tostring(info)), 2.5)

            -- 一秒后回读条数: 界面上没东西的时候, 得让玩家知道是「真没人卖」
            -- 还是「搜索没被认」。搜索栏回填了名字、列表却空着的, 基本是后者。
            C_Timer.After(1.2, function()
                local item, comm, browse = AH.SearchCount(itemID)
                local n = (item or 0) + (comm or 0)
                local any = n > 0 or (browse or 0) > 0
                local byButton = tostring(way):find("(按钮)", 1, true) ~= nil
                if any then
                    if not byButton then
                        Say(format("搜到 %d 条 (走的是%s)", math.max(n, browse or 0), tostring(way)), 3)
                    end
                    return
                end
                if byButton then
                    Say("拍卖行返回 0 条 · 这件东西现在没人卖; 若别的物品也这样, /wgm search <ID> 看诊断", 6)
                else
                    Say("拍卖行返回 0 条 (走的" .. tostring(way) .. ") · /wgm search <ID> 看诊断", 6)
                end
                -- 搜出去却是 0 条: 自动打一次体检, 省得来回问 (只打一次, 别刷屏)
                if not searchDiagDone and AH.SearchDiag then
                    searchDiagDone = true
                    AH.SearchDiag(itemID)
                end
            end)
        elseif info == "拍卖行未打开" then
            Say("拍卖行没打开 · 打开拍卖行窗口后, 点物品就能直接搜它", 4.5)
        elseif info == "物品名还没读到" then
            Say("这件物品的名字客户端还没给, 等一秒再点", 3)
        else
            Say("搜不到: " .. tostring(info), 4)
        end
    end)
end

-- 悬浮明细: 产物/材料单价 · 成本 · 税后收入 · 利润
function ns.UI.ShowPriceTooltip(anchor, r)
    local AH = ns.Auction
    local out = r.payload

    TipBegin(anchor)
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
                -- 数量 > 1 时把「单价 = 合计」都写出来, 行内被截断的信息在这里补齐
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
        GameTooltip:AddDoubleLine("成本", AH.MoneyEx(out.cost or 0),
            0.72, 0.75, 0.80, 0.92, 0.93, 0.95)
        GameTooltip:AddDoubleLine("收入 (扣 5% 税)", AH.MoneyEx(out.net or 0),
            0.72, 0.75, 0.80, 0.92, 0.93, 0.95)

        -- NPC 保底: 这一单全卖给商人的收入。AH 扣完税还不如它时, 这才是真实下限
        local npcProd = ns.NPC and ns.NPC.Sell(rec.item)
        if npcProd then
            GameTooltip:AddDoubleLine("卖商人 (保底)", AH.MoneyEx(npcProd * made),
                0.72, 0.75, 0.80, 0.82, 0.84, 0.88)
        end

        -- 两档盈亏并列: 成本相同, 只差成品卖给谁
        local function plText(v)
            if v == 0 then return "持平" end
            return (v > 0 and "+" or "-") .. AH.MoneyEx(math.abs(v))
        end
        local function plColor(v)
            if v > 0 then return 0.40, 0.80, 0.45 end
            if v < 0 then return 0.92, 0.42, 0.42 end
            return 0.72, 0.75, 0.80
        end

        if out.profit then
            GameTooltip:AddDoubleLine("拍卖行盈亏", plText(out.profit),
                1, 1, 1, plColor(out.profit))
        else
            GameTooltip:AddDoubleLine("拍卖行盈亏", "价格不全",
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

        -- NPC 盈亏: 材料仍按拍卖行价买, 成品直接卖给商人 (不抽税)。
        -- 三种状态分开写, 别把「还没读到」和「商人不收」混成一句
        if out.npcProfit then
            GameTooltip:AddDoubleLine("NPC 盈亏", plText(out.npcProfit),
                1, 1, 1, plColor(out.npcProfit))
        elseif out.npcUnit then
            GameTooltip:AddDoubleLine("NPC 盈亏", "材料缺价",
                1, 1, 1, 0.62, 0.65, 0.70)
        elseif out.npcKnown then
            GameTooltip:AddDoubleLine("NPC 盈亏", "商人收不了这个",
                1, 1, 1, 0.62, 0.65, 0.70)
        else
            GameTooltip:AddDoubleLine("NPC 盈亏", "收购价还没读到",
                1, 1, 1, 0.62, 0.65, 0.70)
        end
        GameTooltip:AddLine("两档盈亏的材料成本相同 (都按拍卖行价), 只差成品卖给谁",
            0.55, 0.58, 0.63, true)
        GameTooltip:AddLine("金额精确到 1 铜: 1金 = 100银 = 100铜",
            0.55, 0.58, 0.63, true)

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
    -- 新动作的发现入口: 放在我们自己的提示里, 不去占物品原生提示的位置
    GameTooltip:AddLine("左键点物品 = 在拍卖行里搜索它", 0.55, 0.58, 0.63)
    GameTooltip:Show()
end

-- 商品详情 (鼠标停在商品名 / 行的非材料区)
-- 里面堆的是这一条配方的完整信息: 专业与技能要求、产出、材料清单 (带已查到的单价),
-- 已经查过价时再补成本 / 税后收入 / 盈亏。材料单独一条提示, 见 ShowMatTooltip。
function ns.UI.ShowRowTooltip(anchor, r)
    if not r then return end

    local AH = ns.Auction
    local rec = r.rec
    local itemID = (rec and rec.item) or r.itemID
    local fallback = PlainText(r.title and r.title:GetText())
    tipRebuild = function() return ns.UI.ShowRowTooltip(anchor, r) end

    -- 默认: 只出物品原来的介绍 (品质色名字 / 物品等级 / 用途 / 描述 / 售价),
    -- 和在背包、拍卖行里悬停看到的完全一致, 不追加配方、单价、盈亏那些行。
    if not TipExtra() then
        ShowNativeTip(anchor, itemID, fallback)
        return
    end

    TipBegin(anchor)

    -- 材料汇总模式: 这一行本身就是一样材料, 交给材料详情
    if not rec then
        local name = PlainText(r.title and r.title:GetText()) or "?"
        NativeItemTip(r.itemID, name)
        GameTooltip:AddLine(" ")
        local e = AH and AH.Price and AH.Price(r.itemID)
        if e and e.unit then
            GameTooltip:AddLine("当前最低单价 " .. AH.Money(e.unit) .. "/个", 1, 0.82, 0.35)
        else
            GameTooltip:AddLine("还没有价格, 点右边「查价」", 0.62, 0.65, 0.70)
        end
        if ns.NPC then
            local npcSell = ns.NPC.Sell(r.itemID)
            local npcBuy  = ns.NPC.Buy(r.itemID)
            if npcSell then
                GameTooltip:AddLine("卖商人 " .. ns.NPC.Money(npcSell) .. "/个", 0.82, 0.84, 0.88)
            end
            if npcBuy then
                GameTooltip:AddLine("从商人买 " .. ns.NPC.Money(npcBuy) .. "/个", 0.29, 0.78, 0.66)
            end
        end
        GameTooltip:Show()
        return
    end

    local title = PlainText(r.title and r.title:GetText()) or ""
    if title == "" then title = rec.name or "?" end

    local made = rec.made or 1
    local profName = (ns.Prof and ns.Prof.byKey and ns.Prof.byKey[curKey]
        and ns.Prof.byKey[curKey].name) or curKey

    -- 原生物品提示打底: 品质色标题 + 物品等级 + 使用效果 + 描述 + 售价。
    -- 手写标题只剩一行白字, 看不到「这物品到底是干什么的」, 所以改由客户端来出这一段,
    -- 我们的配方信息接在它后面。物品数据还没回包时 NativeItemTip 会自己补一行名字。
    local native = NativeItemTip(rec.item, title)
    if native then GameTooltip:AddLine(" ") end

    GameTooltip:AddLine(format("%s · 技能 %s%s", tostring(profName),
        tostring(rec.req or "?"),
        made > 1 and format(" · 一次做 %d 个", made) or ""),
        0.72, 0.75, 0.80)

    local out = r.payload
    local fresh = out and out.rec == rec
    local unitOf = fresh and out.unit or nil

    -- 产出与售价
    local prod = unitOf and unitOf[rec.item]
    local prodTxt
    if prod and prod.unit then
        prodTxt = made > 1
            and format("%s/个 = %s", AH.Money(prod.unit), AH.Money(prod.unit * made))
            or  (AH.Money(prod.unit) .. "/个")
    elseif prod then
        prodTxt = prod.reason or "无挂单"
    else
        prodTxt = "未查价"
    end
    GameTooltip:AddDoubleLine(format("产出  ×%d", made), prodTxt,
        0.85, 0.86, 0.90, (prod and prod.unit) and 1 or 0.62,
        (prod and prod.unit) and 0.82 or 0.65, (prod and prod.unit) and 0.35 or 0.70)

    -- NPC 售价: 客户端物品库自带, 和拍卖行完全无关 —— AH 没挂单时也能看到保底值多少
    local npcProd = ns.NPC and ns.NPC.Sell(rec.item)
    if npcProd then
        GameTooltip:AddDoubleLine("卖商人",
            made > 1 and format("%s/个 = %s", AH.Money(npcProd), AH.Money(npcProd * made))
                      or  (AH.Money(npcProd) .. "/个"),
            0.72, 0.75, 0.80, 0.82, 0.84, 0.88)
    end

    -- 材料清单
    local mats = rec.mats or {}
    if #mats > 0 then
        GameTooltip:AddLine(" ")
        for i = 1, #mats do
            local m = mats[i]
            local name = (m.name and PlainText(m.name)) or ("物品 #" .. tostring(m.id))
            local cnt = m.count or 1
            local e = unitOf and unitOf[m.id]
            local txt, cr, cg, cb = format("×%d", cnt), 0.72, 0.75, 0.80
            if e and e.unit then
                txt = cnt > 1
                    and format("×%d   %s", cnt, AH.Money(e.unit * cnt))
                    or  format("×%d   %s", cnt, AH.Money(e.unit))
                cr, cg, cb = 1, 0.82, 0.35
            elseif e then
                txt, cr, cg, cb = format("×%d   %s", cnt, e.reason or "无挂单"), 0.86, 0.42, 0.42
            end
            GameTooltip:AddDoubleLine(name, txt, 0.85, 0.86, 0.90, cr, cg, cb)
        end
    end

    -- 已查价: 成本 / 税后收入 / 两档盈亏 (拍卖行 + NPC)
    if fresh and out then
        GameTooltip:AddLine(" ")
        GameTooltip:AddDoubleLine("材料成本", AH.MoneyEx(out.cost or 0), 0.72, 0.75, 0.80, 0.92, 0.75, 0.55)
        if out.revenue then
            GameTooltip:AddDoubleLine("税后收入", AH.MoneyEx(out.net or 0),
                0.72, 0.75, 0.80, 0.92, 0.80, 0.50)
        end
        if out.profit then
            local gain = out.profit >= 0
            GameTooltip:AddDoubleLine("拍卖行盈亏",
                format("%s%s", gain and "+" or "-", AH.MoneyEx(math.abs(out.profit))),
                0.72, 0.75, 0.80,
                gain and 0.40 or 0.92, gain and 0.86 or 0.38, gain and 0.46 or 0.42)
        else
            GameTooltip:AddLine("缺价格: " .. table.concat(out.missing or {}, ", "),
                0.86, 0.42, 0.42)
        end
        -- NPC 一侧: 材料成本同上, 成品按商人收购价算
        if out.npcProfit then
            local gain = out.npcProfit >= 0
            GameTooltip:AddDoubleLine("NPC 盈亏",
                format("%s%s", gain and "+" or "-", AH.MoneyEx(math.abs(out.npcProfit))),
                0.72, 0.75, 0.80,
                gain and 0.40 or 0.92, gain and 0.86 or 0.38, gain and 0.46 or 0.42)
        elseif out.npcKnown then
            GameTooltip:AddDoubleLine("NPC 盈亏", "商人收不了这个", 0.72, 0.75, 0.80, 0.60, 0.63, 0.68)
        else
            GameTooltip:AddDoubleLine("NPC 盈亏", "收购价还没读到", 0.72, 0.75, 0.80, 0.60, 0.63, 0.68)
        end
        -- 缓存只存在物品维度上 (db.prices), 计算结果的 unit 表里没有时间戳
        local cached = AH and AH.Price and AH.Price(rec.item)
        local line
        if cached and cached.ts then
            local ago = math.max(0, math.floor(GetTime() - cached.ts))
            -- 重新查完就是 0 分钟前, 写「0 分钟前」很怪, 单独给一句
            line = (ago < 60) and "价格是刚刚查到的"
                or format("价格取自拍卖行, %d 分钟前", math.floor(ago / 60))
        else
            line = "价格取自拍卖行缓存"
        end
        GameTooltip:AddLine(line .. " · 点「查价」重新查最新行情", 0.55, 0.58, 0.63)
    else
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine("点右边「查价」取拍卖行最低单价并算盈亏", 0.62, 0.65, 0.70, true)
    end

    GameTooltip:Show()
end

-- 材料详情 (鼠标停在某个材料行上)
-- 每格独立一条: 原生物品提示 (品质色 / 物品等级 / 描述) + 本配方要几个 + 单价与合计。
function ns.UI.ShowMatTooltip(anchor, r, idx)
    if not (r and idx) then return end
    local rec = r.rec
    local m = rec and rec.mats and rec.mats[idx]
    if not m then
        -- 材料汇总模式没有 rec.mats, 退回到行详情
        return ns.UI.ShowRowTooltip(anchor, r)
    end

    local AH = ns.Auction
    local cnt = m.count or 1
    local fallback = (m.name and PlainText(m.name)) or ("物品 #" .. tostring(m.id))
    tipRebuild = function() return ns.UI.ShowMatTooltip(anchor, r, idx) end

    -- 默认只出物品原来的介绍 (材料也一样, 和在背包里悬停没有区别)
    if not TipExtra() then
        ShowNativeTip(anchor, m.id, fallback)
        return
    end

    TipBegin(anchor)
    NativeItemTip(m.id, fallback)

    GameTooltip:AddLine(" ")
    GameTooltip:AddLine(format("本配方需要 ×%d", cnt), 0.85, 0.86, 0.90)

    local out = r.payload
    local e = (out and out.rec == rec and out.unit) and out.unit[m.id] or nil
    if e and e.unit then
        GameTooltip:AddLine(format("拍卖行最低单价 %s/个", AH.Money(e.unit)), 1, 0.82, 0.35)
        GameTooltip:AddLine(format("%d 个合计 %s", cnt, AH.Money(e.unit * cnt)), 1, 0.82, 0.35)
    elseif e then
        GameTooltip:AddLine(e.reason or "拍卖行无挂单", 0.86, 0.42, 0.42)
    else
        GameTooltip:AddLine("还没有价格, 点右边「查价」", 0.62, 0.65, 0.70)
    end

    -- NPC 两个价: 卖价是客户端自带的, 买价是玩家自己记的 (点「买价」格子录入)
    local NPC = ns.NPC
    if NPC then
        local npcSell = NPC.Sell(m.id)
        if npcSell then
            GameTooltip:AddLine(format("卖商人 %s/个 · %d 个共 %s",
                NPC.Money(npcSell), cnt, NPC.Money(npcSell * cnt)), 0.82, 0.84, 0.88)
        end
        local npcBuy = NPC.Buy(m.id)
        if npcBuy then
            GameTooltip:AddLine(format("从商人买 %s/个 (自己记的价)", NPC.Money(npcBuy)),
                0.29, 0.78, 0.66)
        else
            GameTooltip:AddLine("从商人买: 点「买价」格子自己记一个", 0.42, 0.46, 0.52)
        end
    end

    GameTooltip:Show()
end

-- 图标详情 (鼠标停在行首图标上): 原生物品提示 + 该物品的当前售价
function ns.UI.ShowItemTip(anchor, itemID, label)
    tipRebuild = function() return ns.UI.ShowItemTip(anchor, itemID, label) end

    -- 默认只出物品原来的介绍, 不多加一行
    if not TipExtra() then
        ShowNativeTip(anchor, itemID, label)
        return
    end

    TipBegin(anchor)
    NativeItemTip(itemID, label)

    local AH = ns.Auction
    local e = AH and AH.Price and AH.Price(itemID)
    GameTooltip:AddLine(" ")
    if e and e.unit then
        GameTooltip:AddLine("当前最低单价 " .. AH.Money(e.unit) .. "/个", 1, 0.82, 0.35)
    else
        GameTooltip:AddLine("还没有价格", 0.62, 0.65, 0.70)
    end

    if ns.NPC then
        local npcSell = ns.NPC.Sell(itemID)
        local npcBuy  = ns.NPC.Buy(itemID)
        if npcSell then
            GameTooltip:AddLine("卖商人 " .. ns.NPC.Money(npcSell) .. "/个", 0.82, 0.84, 0.88)
        end
        if npcBuy then
            GameTooltip:AddLine("从商人买 " .. ns.NPC.Money(npcBuy) .. "/个", 0.29, 0.78, 0.66)
        end
    end
    GameTooltip:Show()
end

-- 诊断: 为什么某件物品的提示只有名字, 没有「用途 / 描述」
-- /wgm tip <物品ID>; 不给 ID 时用当前列表第一行的产物
function ns.UI.DebugItemTip(itemID)
    if not itemID and rows[1] then itemID = rows[1].itemID end
    if not itemID then
        ns.Print("用法: /wgm tip <物品ID> (列表还没内容时只能这样给)")
        return
    end

    ns.Print(format("物品提示诊断 #%d", itemID))
    print("  全局 GetItemInfo:  " .. (type(GetItemInfo) == "function" and "有" or "|cffff5555无|r"))
    print("  C_Item.GetItemInfo: " .. ((C_Item and type(C_Item.GetItemInfo) == "function")
        and "有" or "|cffff5555无|r"))
    print("  SetItemByID: " .. (GameTooltip.SetItemByID and "有" or "|cffff5555无|r")
        .. "   SetHyperlink: " .. (GameTooltip.SetHyperlink and "有" or "|cffff5555无|r")
        .. "   NumLines: " .. (GameTooltip.NumLines and "有" or "|cffff5555无|r"))

    local name, link = ItemInfo(itemID)
    print("  读取: name=" .. tostring(name))
    print("        link=" .. tostring(link))

    local function dump(tag)
        local n = 0
        if GameTooltip.NumLines then
            local ok, v = pcall(GameTooltip.NumLines, GameTooltip)
            n = (ok and type(v) == "number") and v or 0
        end
        print(format("  %s → %d 行", tag, n))
        for i = 1, n do
            local ok, txt = pcall(GameTooltip.GetLineText, GameTooltip, i)
            print(format("    %d| %s", i, tostring(ok and txt or "?")))
        end
    end

    if GameTooltip.SetItemByID then
        pcall(GameTooltip.ClearLines, GameTooltip)
        pcall(GameTooltip.SetItemByID, GameTooltip, itemID)
        dump("SetItemByID")
    end
    if GameTooltip.SetHyperlink then
        pcall(GameTooltip.ClearLines, GameTooltip)
        local hl = (type(link) == "string" and link ~= "")
            and link or ("item:" .. tostring(itemID) .. ":0:0:0:0:0:0:0")
        pcall(GameTooltip.SetHyperlink, GameTooltip, hl)
        dump("SetHyperlink")
    end

    pcall(GameTooltip.Hide, GameTooltip)

    -- 锚点写法: 有的客户端不认 ANCHOR_CURSOR_RIGHT, SetOwner 直接报错 -> 提示根本不显示
    for _, tok in ipairs({ "ANCHOR_CURSOR_RIGHT", "ANCHOR_CURSOR", "ANCHOR_RIGHT" }) do
        local ok, err = pcall(GameTooltip.SetOwner, GameTooltip, UIParent, tok)
        print(format("  SetOwner(%s) → %s", tok,
            ok and "ok" or ("|cffff5555失败: " .. tostring(err) .. "|r")))
    end
    pcall(GameTooltip.Hide, GameTooltip)

    print("  |cff8a929e物品数据是异步回包的: 第一次可能只有名字, 数据到了悬停会自己补全|r")
end

--------------------------------------------------------------------------- NPC 买价录入

-- 「从商人买」的价格客户端查不到 (只有商人窗口开着时才能用 C_MerchantFrame 逐项读),
-- 所以改成玩家自己记一个单价: 存在 db.npcBuy[itemID], 每次渲染都读回来, 重登也在。
local editor

local function BuildNpcEditor()
    if editor then return editor end
    if not frame then return nil end

    -- 挂在主面板下: 跟着面板一起缩放/移动, 层级自然压在面板所有行上面
    -- (父控件是缩放过的, 若挂 UIParent 会和面板对不齐)
    -- 底用 panel (不透明) 而不是 card (白 5% 半透明): 弹层要盖住下面一整列材料行,
    -- 半透明底会把行文字透上来, 看着像糊在一起
    local f = T.Glass(frame, 300, 126, "panel")
    f:SetFrameStrata(ns.DB().strata or "DIALOG")
    f:SetFrameLevel((frame:GetFrameLevel() or 200) + 20)
    f:SetClampedToScreen(true)
    f:EnableMouse(true)
    f:SetMovable(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", function(s) s:StartMoving() end)
    f:SetScript("OnDragStop", function(s) s:StopMovingOrSizing() end)

    local title = T.Text(f, 11, C.gold)
    title:SetPoint("TOPLEFT", 14, -12)
    title:SetText("NPC 购买价")

    local who = T.Text(f, 9, C.muted)
    who:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -5)
    who:SetWidth(272)
    who:SetWordWrap(false)

    -- 输入框底色自己画: 用 InputBoxTemplate 会被 EllesmereUI 的皮肤改成另一个样子
    local boxBG = T.Line(f, 272, 22, C.white, 0.06)
    boxBG:SetPoint("TOPLEFT", who, "BOTTOMLEFT", 0, -8)

    local box = CreateFrame("EditBox", nil, f)
    box:SetSize(264, 18)
    box:SetPoint("LEFT", boxBG, "LEFT", 5, 0)
    box:SetFont(T.FontFile(), 11, "")
    box:SetTextColor(T.rgb(C.text))
    box:SetAutoFocus(false)
    box:SetMaxLetters(24)
    box:SetTextInsets(1, 1, 0, 0)

    local hint = T.Text(f, 8, C.faint)
    hint:SetPoint("TOPLEFT", boxBG, "BOTTOMLEFT", 0, -5)
    hint:SetWidth(272)
    hint:SetWordWrap(false)

    local HINT_DEFAULT = "1金20银5铜 / 20银 / 1.5金 / 80铜 · 只写数字按银算 · 清空则删除"

    -- 边打边把「值多少金多少银多少铜」写出来: 输入框里允许简写 (120 = 1金20银),
    -- 下面这行负责把它翻成看得懂的整钱, 免得玩家不知道自己填的到底是多少
    local function RefreshHint()
        local text = box:GetText() or ""
        if text:gsub("%s", "") == "" then
            hint:SetTextColor(T.rgb(C.faint))
            hint:SetText(HINT_DEFAULT)
            return
        end
        local copper, err = ns.NPC.ParseMoney(text)
        if not copper then
            hint:SetTextColor(T.rgb(C.red))
            hint:SetText("看不懂: " .. tostring(err))
        else
            hint:SetTextColor(T.rgb(C.gold))
            hint:SetText("= " .. ns.NPC.MoneyEx(copper))
        end
    end

    local function Save()
        local id = f.itemID
        if not id then f:Hide(); return end
        local text = box:GetText() or ""
        if text:gsub("%s", "") == "" then
            ns.NPC.SetBuy(id, 0)                    -- 清空 = 删掉这条
            f:Hide()
            RefreshNpcFor(id)
            return
        end
        local copper, err = ns.NPC.ParseMoney(text)
        if not copper then
            hint:SetTextColor(T.rgb(C.red))
            hint:SetText("看不懂: " .. tostring(err))
            return
        end
        ns.NPC.SetBuy(id, copper)
        f:Hide()
        RefreshNpcFor(id)
    end

    box:SetScript("OnTextChanged", RefreshHint)
    box:SetScript("OnEnterPressed", Save)
    box:SetScript("OnEscapePressed", function() f:Hide() end)

    local save = MakeMiniButton(f, 54, 18, "保存")
    save:SetPoint("BOTTOMRIGHT", -14, 12)
    save:SetScript("OnClick", Save)

    local clear = MakeMiniButton(f, 54, 18, "清除")
    clear:SetPoint("RIGHT", save, "LEFT", -6, 0)
    clear:SetScript("OnClick", function()
        if f.itemID then
            ns.NPC.SetBuy(f.itemID, 0)
            RefreshNpcFor(f.itemID)
        end
        f:Hide()
    end)

    local cancel = MakeMiniButton(f, 54, 18, "取消")
    cancel:SetPoint("RIGHT", clear, "LEFT", -6, 0)
    cancel:SetScript("OnClick", function() f:Hide() end)

    f.box, f.who, f.hint = box, who, hint
    f.refreshHint = RefreshHint
    f:Hide()
    editor = f
    return editor
end

-- 点材料行的「买价」格子调这里: name 只用于弹窗上说明改的是哪个物品
function ns.UI.EditNpcPrice(itemID, name, cell)
    if type(itemID) ~= "number" or itemID <= 0 then
        ns.UI.Notify("这一行还没有解析到物品, 稍等一下再点", 3)
        return
    end
    local e = BuildNpcEditor()
    if not e then return end

    e.itemID = itemID
    e.who:SetText(name or ("物品 #" .. tostring(itemID)))

    local cur = ns.NPC and ns.NPC.Buy(itemID)
    -- 输入框里直接写成完整的「多少金多少银多少铜」: 12金0银5铜 也把 0 写出来,
    -- 用 AH.Money 那种简写会把铜位和 0 银吞掉, 玩家看不出记的是不是自己想的那笔
    e.box:SetText(cur and ns.NPC.MoneyEx(cur) or "")
    e.box:SetCursorPosition(0)
    if e.refreshHint then e.refreshHint() else
        e.hint:SetTextColor(T.rgb(C.faint))
        e.hint:SetText("1金20银5铜 / 20银 / 1.5金 / 80铜 · 只写数字按银算 · 清空则删除")
    end

    e:ClearAllPoints()
    -- 居中盖在面板上: 材料行通常贴着列表顶部, 若跟着行锚会被顶出面板外面
    e:SetPoint("CENTER", frame, "CENTER", 0, 0)
    e:Show()
    e.box:SetFocus()
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

--------------------------------------------------------------------------- 层级

-- 面板层级 (可用 /wgm strata 切换, 默认 DIALOG = 压在 EllesmereUI 上层)
--
-- 客户端里 EllesmereUI 各窗口的分布 (grep 全量统计):
--   FULLSCREEN_DIALOG 47 处 (选项/弹窗/全屏面板)、DIALOG 16 处 (快捷操作层 Quickdraw 等)、
--   MEDIUM 15 处、TOOLTIP 14 处、HIGH 9 处; 背包 EUI_MainBagFrame 是 MEDIUM
--   (「窗口显示在背包之上」关掉时改 HIGH 且 frameLevel = 100)。
-- 所以:
--   * MEDIUM/LOW + level 1 —— 待在背包与常规 HUD 下面 (上一轮的做法, 会被 EllesmereUI 盖住)
--   * HIGH      + level 200 + Toplevel —— 压住背包(HIGH,100) 与 HIGH 层窗口
--   * DIALOG    + level 200 + Toplevel —— 压住 Quickdraw 等 DIALOG 层, 仍在全屏弹窗之下 (默认)
--   * FULLSCREEN_DIALOG / TOOLTIP —— 连全屏选项页/弹窗也要压住时才用
-- 顺序: BACKGROUND < LOW < MEDIUM < HIGH < DIALOG < FULLSCREEN < FULLSCREEN_DIALOG < TOOLTIP
-- (STRATA_ORDER / STRATA_LEVEL 在文件顶部声明, 前面的 DebugInfo 也要用)
ns.UI.DEFAULT_STRATA = "DIALOG"

function ns.UI.StrataExists(name)
    return STRATA_ORDER[tostring(name or ""):upper()] ~= nil
end

function ns.UI.ApplyStrata(name)
    local db = ns.DB and ns.DB()
    name = tostring(name or (db and db.strata) or ns.UI.DEFAULT_STRATA):upper()
    if not STRATA_ORDER[name] then name = ns.UI.DEFAULT_STRATA end
    if not frame then return name, false end     -- 面板还没建 (未进游戏), 只记配置

    local level = STRATA_LEVEL[name] or 200
    frame:SetFrameStrata(name)
    -- 高层才设 Toplevel: 它让面板始终待在该层最上面, 正是"压在 EllesmereUI 上层"要的效果;
    -- 低层 (LOW/MEDIUM) 反而不能开, 否则又要和背包抢同层最上。
    -- (Toplevel 只在同一 strata 内生效, 不会越过 DIALOG/FULLSCREEN_DIALOG)
    frame:SetToplevel(STRATA_ORDER[name] >= STRATA_ORDER.HIGH)
    -- 高层抬到 200: EllesmereUIBags 背包是 HIGH + level 100, 快捷操作层是 DIALOG,
    -- 200 能压住它们; 低层压到 1 (MEDIUM/LOW) 方便"待在背包下面"
    frame:SetFrameLevel(level)
    return name, true
end

function ns.UI.Build()
    if frame then return frame end

    local f = CreateFrame("Frame", "WOWGoldMakerFrame", UIParent)

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

    -- 层级必须等 frame 赋值后再设 (ApplyStrata 里要用到 frame)
    ns.UI.ApplyStrata()

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
        -- 行图标 / NPC 售价每 3 秒补一次 (物品数据回包较慢, 逐秒查会浪费)
        if tickCount % 3 == 0 then
            pcall(RefreshRowIcons)
            pcall(RefreshRowNpc)
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
