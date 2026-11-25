#!/usr/bin/env node
/**
 * 从 RDbItems (1.12 中英物品名库) 里抽出「货架上这些货」的中文名,
 * 写成 tools/data/itemnames_zh.txt (每行 "物品ID\t中文名")。
 *
 * 为什么要这一步: 快照 (HandyNotes) 里只有英文名, 中文客户端搜「亚麻布」
 * 一条都搜不到。把中文名随插件带一份, 打开窗口就能搜中文, 不用等客户端回包。
 *
 * 源文件不入库 (900KB), 只在需要重生成时手动下载:
 *   curl -sL https://raw.githubusercontent.com/likesc/RDbItems/master/RDbItems.lua -o tools/data/rdbitems.lua
 *
 * 用法: node tools/extract_item_names.js [RDbItems.lua 路径]
 */
const fs = require('fs');
const path = require('path');

const ROOT = 'D:/works/wow/WOWGoldMaker';
const SRC = process.argv[2] || path.join(ROOT, 'tools/data/rdbitems.lua');
const OUT = path.join(ROOT, 'tools/data/itemnames_zh.txt');

if (!fs.existsSync(SRC)) {
  console.error('找不到 ' + SRC + ' —— 先按文件头注释下载 RDbItems.lua');
  process.exit(1);
}

// RDbItems 的条目: {25, "Worn Shortsword", "破损的短剑", 2, 7},
const rdb = fs.readFileSync(SRC, 'utf8');
const zh = new Map();
for (const m of rdb.matchAll(/\{\s*(\d+),\s*"((?:[^"\\]|\\.)*)",\s*"((?:[^"\\]|\\.)*)"/g)) {
  zh.set(+m[1], m[3]);
}
console.log('RDbItems 条目: %d', zh.size);

// 只留货架上真有的物品 (从已经生成好的 MerchantData.lua 里数)
const data = fs.readFileSync(path.join(ROOT, 'WOWGoldMaker/MerchantData.lua'), 'utf8');
const goods = data.slice(data.indexOf('ns.MerchantGoods = {'));
const ids = [...goods.matchAll(/\[(\d+)\] = "/g)].map((m) => +m[1]);

const lines = [];
const missing = [];
for (const id of ids) {
  const cn = zh.get(id);
  if (cn) lines.push(id + '\t' + cn.replace(/\t/g, ' '));
  else missing.push(id);
}

fs.mkdirSync(path.dirname(OUT), { recursive: true });
fs.writeFileSync(OUT, lines.join('\n') + '\n', 'utf8');

console.log('货架物品 %d 件, 拿到中文名 %d 件 (%.1f%%), 缺 %d 件: %s',
  ids.length, lines.length, (100 * lines.length) / ids.length, missing.length, missing.join(','));
