#!/usr/bin/env node
/**
 * 生成 WOWGoldMaker/MerchantData.lua —— 「商人图鉴」全量数据。
 *
 * 和 gen_vendor_data.js 的区别:
 *   gen_vendor_data.js  只抽本插件配方用得上的几十件 (给成本计算当兜底价)
 *   gen_merchant_data.js 全量抽 (给「商人货架」独立页面浏览 / 反查谁卖)
 *
 * 输入 (客户端 HandyNotes_NPCs forever 数据, 已按本服整理过):
 *   vendorData.lua  t[npcID]  = "itemID, itemID, ..."     谁卖什么
 *   itemData.lua    t[itemID] = { name, icon, buyPrice }  货名 / 图标 / 买价
 *   data.lua        nodes[mapID][坐标] = { name, npcID }  商人叫什么 / 在哪
 *
 * 第四段中文名的来源: tools/data/itemnames_zh.txt (由 tools/extract_item_names.js
 * 从 RDbItems 中英物品名库抽出, 980/985 件有)。快照只有英文名, 没有这一列的话
 * 中文客户端搜「亚麻布」一条都搜不到。
 *
 * 输出三张表 (字符串打包, 比嵌套表省一半体积, 打开页面时才解析):
 *   ns.Merchants     [npcID]  = "名字|地图ID|x.x,y.y|阵营"
 *   ns.MerchantStock [npcID]  = "itemID,itemID,..."
 *   ns.MerchantGoods [itemID] = "名字|买价|图标|中文名"
 *
 * 用法: node tools/gen_merchant_data.js
 */
const fs = require('fs');

const HN = 'D:/wow/client/World of Warcraft/_forever_/Interface/AddOns/HandyNotes_NPCs (Classic)/forever';
const OUT = 'D:/works/wow/WOWGoldMaker/WOWGoldMaker/MerchantData.lua';

const norm = (s) => s.replace(/\r/g, '');

// 物品ID -> 中文名 (可能缺件, 缺了就只显示英文)
const ZH_FILE = 'D:/works/wow/WOWGoldMaker/tools/data/itemnames_zh.txt';
const ZH = new Map();
if (fs.existsSync(ZH_FILE)) {
  for (const line of norm(fs.readFileSync(ZH_FILE, 'utf8')).split('\n')) {
    const [id, cn] = line.split('\t');
    if (id && cn) ZH.set(+id, cn.trim());
  }
}

// 地图ID -> [中文名, 英文名] (经典旧世 1-60 的全部区域, 商人在这些地图上)
const ZONES = {
  1411: ['杜隆塔尔', 'Durotar'],
  1412: ['莫高雷', 'Mulgore'],
  1413: ['贫瘠之地', 'The Barrens'],
  1416: ['奥特兰克山脉', 'Alterac Mountains'],
  1417: ['阿拉希高地', 'Arathi Highlands'],
  1418: ['荒芜之地', 'Badlands'],
  1419: ['诅咒之地', 'Blasted Lands'],
  1420: ['提瑞斯法林地', 'Tirisfal Glades'],
  1421: ['银松森林', 'Silverpine Forest'],
  1422: ['西瘟疫之地', 'Western Plaguelands'],
  1423: ['东瘟疫之地', 'Eastern Plaguelands'],
  1424: ['希尔斯布莱德丘陵', 'Hillsbrad Foothills'],
  1425: ['辛特兰', 'The Hinterlands'],
  1426: ['丹莫罗', 'Dun Morogh'],
  1427: ['灼热峡谷', 'Searing Gorge'],
  1428: ['燃烧平原', 'Burning Steppes'],
  1429: ['艾尔文森林', 'Elwynn Forest'],
  1430: ['逆风小径', 'Deadwind Pass'],
  1431: ['暮色森林', 'Duskwood'],
  1432: ['洛克莫丹', 'Loch Modan'],
  1433: ['赤脊山', 'Redridge Mountains'],
  1434: ['荆棘谷', 'Stranglethorn Vale'],
  1435: ['悲伤沼泽', 'Swamp of Sorrows'],
  1436: ['西部荒野', 'Westfall'],
  1437: ['湿地', 'Wetlands'],
  1438: ['泰达希尔', 'Teldrassil'],
  1439: ['黑海岸', 'Darkshore'],
  1440: ['灰谷', 'Ashenvale'],
  1441: ['千针石林', 'Thousand Needles'],
  1442: ['石爪山脉', 'Stonetalon Mountains'],
  1443: ['凄凉之地', 'Desolace'],
  1444: ['菲拉斯', 'Feralas'],
  1445: ['尘泥沼泽', 'Dustwallow Marsh'],
  1446: ['塔纳利斯', 'Tanaris'],
  1447: ['艾萨拉', 'Azshara'],
  1448: ['费伍德森林', 'Felwood'],
  1449: ['安戈洛环形山', "Un'Goro Crater"],
  1450: ['月光林地', 'Moonglade'],
  1451: ['希利苏斯', 'Silithus'],
  1452: ['冬泉谷', 'Winterspring'],
  1453: ['暴风城', 'Stormwind City'],
  1454: ['奥格瑞玛', 'Orgrimmar'],
  1455: ['铁炉堡', 'Ironforge'],
  1456: ['雷霆崖', 'Thunder Bluff'],
  1457: ['达纳苏斯', 'Darnassus'],
  1458: ['幽暗城', 'Undercity'],
};

// ---------------------------------------------------------------- 1) 谁卖什么
const vendSrc = norm(fs.readFileSync(HN + '/vendorData.lua', 'utf8'));
const stock = new Map();          // npcID -> [itemID]
for (const m of vendSrc.matchAll(/t\[(\d+)\] = "([^"]*)"/g)) {
  const npc = +m[1];
  const seen = new Set();
  for (const s of m[2].split(',')) {
    const id = +s.trim();
    if (id > 0) seen.add(id);
  }
  if (seen.size) stock.set(npc, [...seen]);
}

// ---------------------------------------------------------------- 2) 货名/买价/图标
const itemSrc = norm(fs.readFileSync(HN + '/itemData.lua', 'utf8'));
const goods = new Map();          // itemID -> { name, price, icon }
// 名字里会有转义引号 (BKP 2700 \"Enforcer\"), 不能简单用 [^"]*
for (const m of itemSrc.matchAll(/t\[(\d+)\] = \{\s+name = L\["((?:[^"\\]|\\.)*)"\],([\s\S]*?)\n\}/g)) {
  const id = +m[1];
  const body = m[3];
  const price = /buyPrice = (\d+)/.exec(body);
  const icon = /icon = "([^"]*)"/.exec(body);
  goods.set(id, {
    name: m[2].replace(/\\(["\\])/g, '$1').replace(/[\r\n\t]/g, ' '),
    price: price ? +price[1] : 0,
    icon: icon ? icon[1] : '',
  });
}

// ---------------------------------------------------------------- 3) 商人叫什么 / 在哪
const dataSrc = norm(fs.readFileSync(HN + '/data.lua', 'utf8'));
const zoneStarts = [...dataSrc.matchAll(/nodes\[(\d+)\] = \{/g)].map((m) => [+m[1], m.index]);
const where = new Map();          // npcID -> { name, zone, coord, faction }
for (let i = 0; i < zoneStarts.length; i++) {
  const mapId = zoneStarts[i][0];
  const body = dataSrc.slice(zoneStarts[i][1],
    i + 1 < zoneStarts.length ? zoneStarts[i + 1][1] : dataSrc.length);
  // 每条: \n\t[61403720] = {\n\t\tname = L["..."],\n ... \n\t},
  const parts = body.split(/\n\t\[(\d{8})\] = \{/).slice(1);
  for (let j = 0; j < parts.length; j += 2) {
    const coord = parts[j];
    const ent = parts[j + 1];
    const nm = /name = L\["([^"]*)"\]/.exec(ent);
    const npc = /npcID = (\d+)/.exec(ent);
    if (!nm || !npc) continue;
    const fac = (/faction = "([^"]*)"/.exec(ent) || [])[1] || '';
    const id = +npc[1];
    if (where.has(id)) continue;                  // 同一个 NPC 多处出现, 只留第一处
    where.set(id, { name: nm[1], zone: mapId, coord, fac });
  }
}

// 坐标 key 是 8 位: xxxx yyyy, 每 4 位是「百分比 x100」(即 6140 = 61.40%)
// "61403720" -> "61.4,37.2"   (之前按 2 位取, 结果全被缩小 10 倍, TomTom 标点全错)
const prettyCoord = (c) => (c.slice(0, 4) / 100).toFixed(1) + ',' + (c.slice(4, 8) / 100).toFixed(1);
const facCode = (f) => (f === 'Alliance' ? 'A' : f === 'Horde' ? 'H' : 'N');
// ---------------------------------------------------------------- 4) 输出
// 只留「真的有商人卖」的货: itemData 里还混着 600 多件没人卖的东西 (任务/掉落),
// 收进来既占体积, 又会让清单里一半条目查不到商人。
const sold = new Set();
for (const list of stock.values()) for (const id of list) sold.add(id);
const itemIds = [...sold].sort((a, b) => a - b);
const noName = itemIds.filter((id) => !goods.has(id)).length;
const npcIds = [...stock.keys()].sort((a, b) => a - b);
const pairs = [...stock.values()].reduce((n, a) => n + a.length, 0);

const lines = [];
const P = (s) => lines.push(s);
P('---------------------------------------------------------------------------');
P('-- WOWGoldMaker / MerchantData.lua');
P('-- 商人图鉴全量数据 (离线快照)。由 tools/gen_merchant_data.js 生成, 不要手改。');
P('--');
P('-- 来源: 客户端 Interface/AddOns/HandyNotes_NPCs (Classic)/forever');
P('--       vendorData (谁卖什么) + itemData (货名/图标/买价) + data.lua (商人位置)');
P('--');
P('-- 规模: ' + npcIds.length + ' 位商人 / ' + itemIds.length + ' 种货 / ' + pairs + ' 条「谁卖」关系。');
P('--');
P('-- 打包成字符串是为了体积: 拆成嵌套表要多占一倍内存, 而且加载时全量构造。');
P('-- 这里只在第一次打开「商人货架」时解析一次 (见 MerchantUI.lua)。');
P('--');
P('--   ns.Merchants     [npcID]  = "名字|地图ID|x.x,y.y|阵营"');
P('--   ns.MerchantStock [npcID]  = "itemID,itemID,..."');
P('--   ns.MerchantGoods [itemID] = "名字|买价(铜)|图标|中文名"');
P('--');
P('-- 名字都是英文源串: 进了游戏会先用 GetItemInfo / C_CreatureInfo 换成本地化名字,');
P('-- 取不到才回退到这里 (这些物品不一定在客户端缓存里, 有兜底才不会显示成 #1234)。');
P('---------------------------------------------------------------------------');
P('');
P('local ADDON, ns = ...');
P('');
P('-- 商人: npcID -> 名字|地图ID|坐标|阵营 (N=中立 A=联盟 H=部落)');
P('ns.Merchants = {');
for (const id of npcIds) {
  const w = where.get(id);
  const val = w
    ? w.name + '|' + w.zone + '|' + prettyCoord(w.coord) + '|' + facCode(w.fac)
    : '|0||N';
  P('    [' + id + '] = "' + val.replace(/"/g, '\\"') + '",');
}
P('}');
P('');
P('-- 商人货架: npcID -> 卖的物品ID');
P('ns.MerchantStock = {');
for (const id of npcIds) {
  P('    [' + id + '] = "' + stock.get(id).join(',') + '",');
}
P('}');
P('');
P('-- 地图ID -> 区域名 (中文|英文)。运行时优先用 C_Map.GetMapInfo 的本地化名字,');
P('-- 取不到才回退到这里 —— 老客户端/私服不一定有 C_Map, 有兜底才不会显示成一串数字。');
P('ns.ZoneNames = {');
for (const [id, pair] of Object.entries(ZONES).sort((a, b) => +a[0] - +b[0])) {
  P('    [' + id + '] = "' + pair[0] + '|' + pair[1] + '",');
}
P('}');
P('');
P('-- 货物: itemID -> 名字|买价(铜)|图标|中文名');
P('ns.MerchantGoods = {');
for (const id of itemIds) {
  const g = goods.get(id) || { name: '', price: 0, icon: '' };
  const zh = ZH.get(id) || '';
  P('    [' + id + '] = "' + g.name.replace(/"/g, '\\"') + '|' + g.price + '|' + g.icon
    + '|' + zh.replace(/"/g, '\\"') + '",');
}
P('}');
P('');

fs.writeFileSync(OUT, lines.join('\n'), 'utf8');

const kb = (fs.statSync(OUT).size / 1024).toFixed(1);
console.log('wrote', OUT, kb + ' KB');
console.log('商人', npcIds.length, '/ 有位置', [...where.keys()].filter((k) => stock.has(k)).length,
  '/ 货物', itemIds.length, '/ 关系', pairs);
console.log('缺位置的商人:', npcIds.filter((id) => !where.has(id)).length,
  '/ 缺名字的货:', noName,
  '/ 有中文名:', itemIds.filter((id) => ZH.has(id)).length + '/' + itemIds.length);
