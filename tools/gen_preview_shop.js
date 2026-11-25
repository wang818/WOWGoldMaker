#!/usr/bin/env node
/**
 * 为 preview.html 生成「商人货架」演示数据, 写进页面里两个标记之间。
 *
 * 用全量 (985 种货 / 829 位商人 / 10903 条关系, 约 130KB): 抽样版本会让大部分
 * 真实物品名搜不到, 用户会以为搜索坏了。预览页是本地文件, 这点体积无所谓。
 *
 * 用法: node tools/gen_preview_shop.js
 */
const fs = require('fs');

const DATA = 'D:/works/wow/WOWGoldMaker/WOWGoldMaker/MerchantData.lua';
const HTML = 'D:/works/wow/WOWGoldMaker/preview.html';

const src = fs.readFileSync(DATA, 'utf8');

// ---- 三张表 ----
function block(name) {
  const start = src.indexOf('\n' + name + ' = {');
  if (start < 0) throw new Error('找不到 ' + name);
  const end = src.indexOf('\n}', start);
  return src.slice(start, end);
}
const parseMap = (text) => {
  const out = {};
  for (const m of text.matchAll(/\[(\d+)\] = "([^"]*)"/g)) out[+m[1]] = m[2];
  return out;
};
const ZONES = parseMap(block('ns.ZoneNames'));
const NPCS = parseMap(block('ns.Merchants'));
const STOCK = parseMap(block('ns.MerchantStock'));
const GOODS = parseMap(block('ns.MerchantGoods'));

// ---- 物品 -> 商人 ----
const byItem = new Map();
for (const [npcID, s] of Object.entries(STOCK)) {
  for (const id of s.split(',')) {
    const it = +id;
    if (!byItem.has(it)) byItem.set(it, []);
    byItem.get(it).push(+npcID);
  }
}

const rows = [...byItem.entries()].map(([id, npcs]) => {
  const [name, price, icon] = (GOODS[id] || '||').split('|');
  return { id, name, price: +price || 0, icon, npcs };
});

// 本插件配方要用的材料 (和 Vendor.lua 的 Wanted 同一套: 产物 + 材料)
const wanted = new Set();
{
  const prof = fs.readFileSync('D:/works/wow/WOWGoldMaker/WOWGoldMaker/ProfData.lua', 'utf8');
  for (const line of prof.split('\n')) {
    const m = /mats = \{(.*)\}\s*,?\s*$/.exec(line.trim());
    if (m) for (const p of m[1].matchAll(/\{\s*(\d+),\s*(\d+)\s*\}/g)) wanted.add(+p[1]);
    const it = /item = (\d+)/.exec(line);
    if (it) wanted.add(+it[1]);
  }
}

// ---- 全量 ----
const sample = [...rows].sort((a, b) => b.price - a.price);

// ---- 涉及的商人 ----
const npcIDs = new Set();
for (const r of sample) for (const id of r.npcs) npcIDs.add(id);

const esc = (s) => String(s).replace(/\\/g, '\\\\').replace(/"/g, '\\"');

const zonesUsed = new Set([...npcIDs].map((id) => +(NPCS[id] || '').split('|')[1] || 0));

const lines = [];
lines.push('/* SHOP_DATA_BEGIN (由 tools/gen_preview_shop.js 生成, 不要手改) */');
lines.push('const SHOP_ZONES = {');
for (const z of [...zonesUsed].sort((a, b) => a - b)) {
  if (ZONES[z]) lines.push(`  ${z}: "${esc(ZONES[z])}",`);
}
lines.push('};');
lines.push('const SHOP_NPCS = {');
for (const id of [...npcIDs].sort((a, b) => a - b)) {
  lines.push(`  ${id}: "${esc(NPCS[id] || '')}",`);
}
lines.push('};');
lines.push('/* [物品ID, 英文名, 买价(铜), 图标名, "商人ID,商人ID", 是否本插件材料] */');
lines.push('const SHOP_GOODS = [');
for (const r of sample) {
  lines.push(`  [${r.id}, "${esc(r.name)}", ${r.price}, "${esc(r.icon)}", "${r.npcs.join(',')}", ${wanted.has(r.id) ? 1 : 0}],`);
}
lines.push('];');
lines.push('/* SHOP_DATA_END */');
const js = lines.join('\n');

let html = fs.readFileSync(HTML, 'utf8');
const a = html.indexOf('/* SHOP_DATA_BEGIN');
const b = html.indexOf('/* SHOP_DATA_END */');
if (a < 0 || b < 0 || b <= a) {
  console.error('preview.html 里找不到 SHOP_DATA 标记');
  process.exit(1);
}
html = html.slice(0, a) + js + html.slice(b + '/* SHOP_DATA_END */'.length);
fs.writeFileSync(HTML, html, 'utf8');

console.log('注入预览数据: %d 件货 / %d 位商人 / %d 张地图 (%d KB)',
  sample.length, npcIDs.size, zonesUsed.size, (js.length / 1024).toFixed(1));
