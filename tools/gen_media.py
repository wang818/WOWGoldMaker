#!/usr/bin/env python3
"""WOWGoldMaker 皮肤素材生成器

生成 32 位未压缩 TGA（给魔兽世界客户端用）以及同款 PNG（给本地预览用）。
纯标准库实现，不依赖 PIL。

用法:  python tools/gen_media.py
"""

import math
import os
import struct
import zlib

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MEDIA = os.path.join(ROOT, "WOWGoldMaker", "Media")


# ---------------------------------------------------------------- 写文件

def write_tga(path, w, h, rows):
    """rows: 从上到下的行, 每行是 (b, g, r, a) 元组列表。TGA 原点左下, 所以倒序写。"""
    header = struct.pack("<BBBHHBHHHHBB", 0, 0, 2, 0, 0, 0, 0, 0, w, h, 32, 0x08)
    buf = bytearray(header)
    for row in reversed(rows):
        for b, g, r, a in row:
            buf += bytes((b, g, r, a))
    with open(path, "wb") as f:
        f.write(buf)


def write_png(path, w, h, rows):
    raw = bytearray()
    for row in rows:
        raw.append(0)
        for b, g, r, a in row:
            raw += bytes((r, g, b, a))

    def chunk(tag, data):
        return (struct.pack(">I", len(data)) + tag + data
                + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF))

    ihdr = struct.pack(">IIBBBBB", w, h, 8, 6, 0, 0, 0)
    png = (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", ihdr)
           + chunk(b"IDAT", zlib.compress(bytes(raw), 9)) + chunk(b"IEND", b""))
    with open(path, "wb") as f:
        f.write(png)


# ---------------------------------------------------------------- 几何

def rounded_rect_sd(px, py, x0, y0, x1, y1, r):
    """圆角矩形的有符号距离, 内部为负。"""
    dx = max(x0 + r - px, 0.0, px - (x1 - r))
    dy = max(y0 + r - py, 0.0, py - (y1 - r))
    return math.hypot(dx, dy) - r


def coverage(sd):
    """把距离转成抗锯齿覆盖度。"""
    return min(max(0.5 - sd, 0.0), 1.0)


def lerp(a, b, t):
    return a + (b - a) * t


# ---------------------------------------------------------------- 素材

def make_panel(path_base, w, h, radius, top_rgb, bot_rgb, border_alpha=0.10,
               highlight=0.10):
    rows = []
    for y in range(h):
        t = y / (h - 1)
        # 轻微的上亮下暗，再叠一点垂直方向的非线性让顶部更通透
        k = t ** 0.85
        cr = lerp(top_rgb[0], bot_rgb[0], k)
        cg = lerp(top_rgb[1], bot_rgb[1], k)
        cb = lerp(top_rgb[2], bot_rgb[2], k)
        row = []
        for x in range(w):
            sd = rounded_rect_sd(x + 0.5, y + 0.5, 0, 0, w, h, radius)
            a = coverage(sd)
            if a <= 0:
                row.append((0, 0, 0, 0))
                continue

            r, g, b = cr, cg, cb

            # 外描边: 距离边框 1.4px 以内提亮
            if -1.6 < sd < 0:
                fa = border_alpha * coverage(sd + 1.6)
                r = lerp(r, 255, fa)
                g = lerp(g, 255, fa)
                b = lerp(b, 255, fa)

            # 顶部内侧高光, 横向两端衰减
            if -3.2 < sd < -1.2:
                hx = 1.0 - abs(2.0 * x / (w - 1) - 1.0)
                fa = highlight * (hx ** 1.6) * coverage(sd + 3.2)
                r = lerp(r, 255, fa)
                g = lerp(g, 255, fa)
                b = lerp(b, 255, fa)

            row.append((int(b), int(g), int(r), int(255 * a)))
        rows.append(row)
    write_tga(path_base + ".tga", w, h, rows)
    write_png(path_base + ".png", w, h, rows)


def make_shadow(path_base, w, h, radius, sigma, strength):
    rows = []
    for y in range(h):
        row = []
        for x in range(w):
            sd = rounded_rect_sd(x + 0.5, y + 0.5, 0, 0, w, h, radius)
            d = max(sd, 0.0)
            a = strength * math.exp(-((d / sigma) ** 2))
            row.append((0, 0, 0, int(255 * min(a, 1.0))))
        rows.append(row)
    write_tga(path_base + ".tga", w, h, rows)
    write_png(path_base + ".png", w, h, rows)


def make_glass(path_base, w, h, radius, fill_alpha, border_alpha,
               grad_top=1.0, grad_bot=1.0):
    """白色蒙版: 运行时用 SetVertexColor 上色。"""
    rows = []
    for y in range(h):
        t = y / (h - 1)
        row = []
        for x in range(w):
            sd = rounded_rect_sd(x + 0.5, y + 0.5, 0, 0, w, h, radius)
            a = coverage(sd)
            if a <= 0:
                row.append((0, 0, 0, 0))
                continue
            alpha = fill_alpha * lerp(grad_top, grad_bot, t)
            if -1.8 < sd < 0:
                alpha = max(alpha, border_alpha * coverage(sd + 1.8))
            row.append((255, 255, 255, int(255 * min(alpha, 1.0) * a)))
        rows.append(row)
    write_tga(path_base + ".tga", w, h, rows)
    write_png(path_base + ".png", w, h, rows)


def make_glow(path_base, size, power=2.2):
    rows = []
    c = size / 2.0
    for y in range(size):
        row = []
        for x in range(size):
            d = math.hypot(x + 0.5 - c, y + 0.5 - c) / c
            a = math.exp(-((d * power) ** 2)) if d < 1.0 else 0.0
            row.append((255, 255, 255, int(255 * a)))
        rows.append(row)
    write_tga(path_base + ".tga", size, size, rows)
    write_png(path_base + ".png", size, size, rows)


def make_disc(path_base, size):
    rows = []
    c = size / 2.0
    for y in range(size):
        row = []
        for x in range(size):
            d = math.hypot(x + 0.5 - c, y + 0.5 - c) - (c - 1.0)
            a = coverage(d)
            row.append((255, 255, 255, int(255 * a)))
        rows.append(row)
    write_tga(path_base + ".tga", size, size, rows)
    write_png(path_base + ".png", size, size, rows)


def main():
    os.makedirs(MEDIA, exist_ok=True)

    # 主面板 440x268 -> 512x312 (约 0.86 缩放)
    make_panel(os.path.join(MEDIA, "panel"), 512, 312, 19,
               (27, 30, 41), (10, 11, 16), border_alpha=0.11, highlight=0.09)

    # 配方列表大面板 460x420 -> 536x490 (同比例, 避免拉伸把圆角拉变形)
    make_panel(os.path.join(MEDIA, "panel-lg"), 536, 490, 20,
               (27, 30, 41), (10, 11, 16), border_alpha=0.11, highlight=0.09)

    # 投影
    make_shadow(os.path.join(MEDIA, "shadow"), 512, 328, 26, 15.0, 0.62)

    # 数据卡片 126x58 -> 256x118
    make_glass(os.path.join(MEDIA, "card"), 256, 118, 20,
               fill_alpha=0.055, border_alpha=0.16)

    # 按钮 132x36 -> 268x74
    make_glass(os.path.join(MEDIA, "btn"), 268, 74, 22,
               fill_alpha=0.95, border_alpha=1.0, grad_top=1.0, grad_bot=0.82)

    # 小方框(勾选框/徽标) 22x22 -> 64x64
    make_glass(os.path.join(MEDIA, "sq"), 64, 64, 20,
               fill_alpha=0.16, border_alpha=0.55)

    # 柔光
    make_glow(os.path.join(MEDIA, "glow"), 256, power=2.0)
    make_glow(os.path.join(MEDIA, "glow-soft"), 256, power=1.2)

    # 圆点(启动球 / 状态灯)
    make_disc(os.path.join(MEDIA, "circle"), 128)

    for f in sorted(os.listdir(MEDIA)):
        p = os.path.join(MEDIA, f)
        print("%-16s %8.1f KB" % (f, os.path.getsize(p) / 1024.0))


if __name__ == "__main__":
    main()
