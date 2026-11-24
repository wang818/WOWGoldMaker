#!/usr/bin/env node
/**
 * 从客户端 DungeonsForeverProf 的静态配方库抽取指定专业的数据,
 * 生成 WOWGoldMaker/ProfData.lua。
 *
 * 行结构 (各专业一致):
 *   f[0] spellID, f[1] 产出物品ID, f[2] 产量, f[3] 分类组,
 *   f[6] 最低技能, f[11] 材料表 { {itemID, count}, ... }
 *
 * 用法: node tools/gen_prof_data.js
 */
const fs = require('fs');
const path = require('path');

const SRC = 'D:/wow/client/World of Warcraft/_forever_/Interface/AddOns/DungeonsForeverProf/Core/Data/Data_ProfRecipes.lua';
const OUT = 'D:/works/wow/WOWGoldMaker/WOWGoldMaker/ProfData.lua';

// 要导出的专业
const WANTED = ['first-aid', 'cooking', 'alchemy'];

// 括号平衡读取, 正确处理字符串里的括号
function readBalanced(s, i) {
    let depth = 0, out = '', inStr = false;
    for (; i < s.length; i++) {
        const c = s[i];
        if (inStr) {
            out += c;
            if (c === '"' && s[i - 1] !== '\\') inStr = false;
            continue;
        }
        if (c === '"') { inStr = true; out += c; continue; }
        if (c === '{') depth++;
        if (c === '}') { depth--; out += c; if (depth === 0) return out; continue; }
        out += c;
    }
    return out;
}

// 按顶层逗号切分一个表的字段
function splitFields(body) {
    const out = [];
    let d = 0, cur = '', inStr = false;
    for (let k = 0; k < body.length; k++) {
        const c = body[k];
        if (inStr) {
            cur += c;
            if (c === '"' && body[k - 1] !== '\\') inStr = false;
            continue;
        }
        if (c === '"') { inStr = true; cur += c; continue; }
        if (c === '{' || c === '(') { d++; cur += c; continue; }
        if (c === '}' || c === ')') { d--; cur += c; continue; }
        if (c === ',' && d === 0) { out.push(cur.trim()); cur = ''; continue; }
        cur += c;
    }
    if (cur.trim()) out.push(cur.trim());
    return out;
}

// 从一个表源码中取出所有 { a, b } 对 (材料表用)
function pairsOf(tblSrc) {
    const res = [];
    const re = /\{\s*(\d+)\s*,\s*(\d+)\s*\}/g;
    let m;
    while ((m = re.exec(tblSrc))) res.push([parseInt(m[1], 10), parseInt(m[2], 10)]);
    return res;
}

const src = fs.readFileSync(SRC, 'utf8');

const profData = {};

for (const key of WANTED) {
    const startIdx = src.indexOf(`PARTS["${key}"]`);
    if (startIdx < 0) { console.error(`找不到专业 ${key}`); process.exit(1); }

    // 只在下一个 PARTS 之前搜索, 避免越界
    const nextIdx = src.indexOf('PARTS["', startIdx + 10);
    const seg = src.slice(startIdx, nextIdx > 0 ? nextIdx : src.length);

    const rowsIdx = seg.indexOf('rows = {');
    if (rowsIdx < 0) { console.error(`${key} 找不到 rows`); process.exit(1); }

    // 从 rows = 之后的第一个 { 开始做括号平衡
    const braceStart = seg.indexOf('{', rowsIdx);
    const outer = readBalanced(seg, braceStart);

    // 拆顶层行
    const rows = [];
    let d = 0, buf = '', inStr = false;
    for (let k = 1; k < outer.length; k++) {
        const c = outer[k];
        if (inStr) {
            buf += c;
            if (c === '"' && outer[k - 1] !== '\\') inStr = false;
            continue;
        }
        if (c === '"') { inStr = true; buf += c; continue; }
        if (c === '{') { d++; if (d === 1) { buf = '{'; continue; } }
        if (c === '}') { d--; buf += c; if (d === 0) { rows.push(buf); buf = ''; } continue; }
        if (d >= 1) buf += c;
    }

    const parsed = [];
    const pending = [];   // 未实装 (静态库里带 nip = "..." 标记的那几行)
    for (const rowSrc of rows) {
        const body = rowSrc.trim().replace(/^\{/, '').replace(/\}$/, '');
        const f = splitFields(body);
        if (/^\s*nip\s*=/.test(body)) {           // 客户端里不存在这条配方, 收了也只会有假材料
            pending.push(body.slice(0, 60));
            continue;
        }
        const spell = parseInt(f[0], 10);
        const item = parseInt(f[1], 10);
        if (!spell || !item) continue;           // 跳过非配方行
        const made = parseInt(f[2], 10) || 1;
        const group = (f[3] || '').replace(/"/g, '');
        const req = parseInt(f[6], 10);
        const mats = pairsOf(f[11] || '{}');
        parsed.push({ spell, item, made, group, req: isNaN(req) ? 0 : req, mats });
    }

    // 去重 (spellID 唯一)
    const seen = new Set();
    const uniq = parsed.filter(p => !seen.has(p.spell) && seen.add(p.spell));
    profData[key] = uniq;
    console.log(`${key.padEnd(12)} ${String(uniq.length).padStart(4)} 条  (原始 ${parsed.length}, 去重 ${parsed.length - uniq.length}, 未实装 ${pending.length})`);
    for (const p of pending) console.log(`  跳过未实装: ${p}`);
}

// 生成 Lua
const luaLines = [];
luaLines.push('---------------------------------------------------------------------------');
luaLines.push('-- WOWGoldMaker / ProfData.lua');
luaLines.push('-- 专业配方静态数据。由 tools/gen_prof_data.js 从客户端静态库自动生成。');
luaLines.push('-- 结构: { spell=法术ID, item=产出物品ID, made=产量, req=最低技能, group=分类, mats={{物品ID,数量},...} }');
luaLines.push('-- 注意: 物品名称不在这里 —— 名称必须由游戏运行时按 ID 解析, 见 Professions.lua。');
luaLines.push('---------------------------------------------------------------------------');
luaLines.push('');
luaLines.push('local ADDON, ns = ...');
luaLines.push('');
luaLines.push('ns.ProfData = {}');
luaLines.push('');

for (const key of WANTED) {
    const rows = profData[key];
    luaLines.push(`ns.ProfData["${key}"] = {`);
    for (const r of rows) {
        const mats = r.mats.map(([id, n]) => `{ ${id}, ${n} }`).join(', ');
        luaLines.push(`    { spell = ${r.spell}, item = ${r.item}, made = ${r.made}, req = ${r.req}, group = "${r.group}", mats = { ${mats} } },`);
    }
    luaLines.push('}');
    luaLines.push('');
}

fs.writeFileSync(OUT, luaLines.join('\n'), 'utf8');
console.log(`\n已生成 ${OUT}  (${(fs.statSync(OUT).size / 1024).toFixed(1)} KB)`);

// 顺手打印分类, 供 UI 分组显示
for (const key of WANTED) {
    const g = {};
    for (const r of profData[key]) g[r.group] = (g[r.group] || 0) + 1;
    console.log(`  ${key} 分类: ${JSON.stringify(g)}`);
}
