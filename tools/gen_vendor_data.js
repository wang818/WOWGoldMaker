#!/usr/bin/env node
/**
 * 从客户端 HandyNotes_NPCs 的 forever 数据里抽出「NPC 商人卖价」,
 * 生成 WOWGoldMaker/VendorData.lua —— 只保留本插件配方会用到的物品。
 *
 * 输入 (客户端插件自带, 已按 infinite/forever 服整理过):
 *   vendorData.lua  t[npcID] = "itemID, itemID, ..."   谁卖什么
 *   itemData.lua    t[itemID] = { buyPrice = 铜, ... }  商人买价
 * 我们只关心 ProfData.lua 里出现过的物品 (材料 + 产物), 别的不要 ——
 * 全表 1600+ 条塞进插件会白白变大。
 *
 * 用法: node tools/gen_vendor_data.js
 */
const fs = require('fs');

const HN = 'D:/wow/client/World of Warcraft/_forever_/Interface/AddOns/HandyNotes_NPCs (Classic)/forever';
const PROF = 'D:/works/wow/WOWGoldMaker/WOWGoldMaker/ProfData.lua';
const OUT = 'D:/works/wow/WOWGoldMaker/WOWGoldMaker/VendorData.lua';

// ---- 1) 我们要的物品: 配方产物 + 材料 ----
const prof = fs.readFileSync(PROF, 'utf8');
const wanted = new Set();
for (const line of prof.split('\n')) {
  const m = /mats = \{(.*)\}\s*,?\s*$/.exec(line.trim());
  if (m) for (const p of m[1].matchAll(/\{\s*(\d+),\s*(\d+)\s*\}/g)) wanted.add(+p[1]);
  const it = /item = (\d+)/.exec(line);
  if (it) wanted.add(+it[1]);
}

// ---- 2) itemData: 商人买价 ----
const itemSrc = fs.readFileSync(HN + '/itemData.lua', 'utf8');
const name = new Map(), buy = new Map();
for (const m of itemSrc.matchAll(/t\[(\d+)\] = \{\s+name = L\["([^"]*)"\]/g)) {
  const id = +m[1];
  const block = itemSrc.slice(m.index, itemSrc.indexOf('}', m.index));
  const bp = /buyPrice = (\d+)/.exec(block);
  name.set(id, m[2]);
  if (bp) buy.set(id, +bp[1]);
}

// ---- 3) vendorData: 多少商人卖 + 反查 NPC (只统计数量, 体积小) ----
const vendSrc = fs.readFileSync(HN + '/vendorData.lua', 'utf8');
const npcCount = new Map();
let vendors = 0;
for (const m of vendSrc.matchAll(/t\[(\d+)\] = "([^"]*)"/g)) {
  vendors++;
  const seen = new Set();
  for (const s of m[2].split(',')) {
    const id = +s.trim();
    if (id && wanted.has(id)) seen.add(id);
  }
  for (const id of seen) npcCount.set(id, (npcCount.get(id) || 0) + 1);
}

// ---- 4) 只留「有商人 + 有买价」的 ----
const rows = [];
for (const id of wanted) {
  const p = buy.get(id), n = npcCount.get(id) || 0;
  if (p && n > 0) rows.push({ id, p, n, name: name.get(id) || '' });
}
rows.sort((a, b) => a.id - b.id);

if (!rows.length) {
  console.error('一条都没匹配到, 检查数据源路径');
  process.exit(1);
}

// ---- 5) 输出 ----
const lines = [];
lines.push('---------------------------------------------------------------------------');
lines.push('-- WOWGoldMaker / VendorData.lua');
lines.push('-- NPC 商人价目表 (离线快照)。由 tools/gen_vendor_data.js 生成, 不要手改。');
lines.push('-- 来源: 客户端 Interface/AddOns/HandyNotes_NPCs (Classic)/forever 的');
lines.push('--       vendorData (谁卖什么) + itemData (商人买价)。');
lines.push('--');
lines.push('-- 只收了本插件配方会用到的物品 —— 全库有 ' + (vendors) + ' 个商人卖 1600+ 种货,');
lines.push('-- 其中属于我们材料/产物的就下面这些; 剩下的材料 (布、草、矿) 商人根本不卖,');
lines.push('-- 只能去拍卖行。');
lines.push('--');
lines.push('-- 值是商人买价 (铜/个)。游戏里打开商人时还会用真实货架价覆盖');
lines.push('-- (db.vendorSeen), 这里只是「没逛过商人时也能算成本」的兜底。');
lines.push('---------------------------------------------------------------------------');
lines.push('');
lines.push('local ADDON, ns = ...');
lines.push('');
lines.push('-- 物品ID -> 商人买价 (铜/个)');
lines.push('ns.VendorPrice = {');
for (const r of rows) {
  const pad = ' '.repeat(Math.max(1, 7 - String(r.id).length));
  lines.push('    [' + r.id + '] = ' + r.p + ',' + pad + '-- ' + r.name + ', ' + r.n + ' 个商人有售');
}
lines.push('}');
lines.push('');
lines.push('-- 物品ID -> 卖这件的商人数 (提示里显示「N 个商人有售」用)');
lines.push('ns.VendorNPCs = {');
for (const r of rows) {
  const pad = ' '.repeat(Math.max(1, 7 - String(r.id).length));
  lines.push('    [' + r.id + '] = ' + r.n + ',' + pad + '-- ' + r.name);
}
lines.push('}');
lines.push('');

fs.writeFileSync(OUT, lines.join('\n'), 'utf8');
console.log('wrote', OUT);
console.log('材料/产物', wanted.size, '→ 商人有售', rows.length, '条 (共扫描', vendors, '个商人)');
for (const r of rows.slice(0, 8)) console.log('  ', r.id, r.name, r.p, '铜 ×', r.n, '商人');
