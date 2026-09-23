#!/usr/bin/env python3
"""把 src-tauri/icons/icon.svg 的几何栅格化成 macOS appiconset 需要的各个尺寸。

这个脚本存在的原因：本机没有任何 SVG 渲染器，而图标只有一个圆角矩形、两段圆头
线和三个圆——直接按距离场画比装一套渲染链便宜。几何值全部抄自 icon.svg，改那边
就得同步改这里。

关键的一条：画布外圈必须保持透明。Tauri 版的图标按 macOS 图标栅格内缩
（transform translate(42 42) scale(0.8359375)），压平到白底会让它在程序坞里比
邻居大一圈，而且没有圆角。
"""
import math, struct, zlib
from pathlib import Path

# --- icon.svg 里的几何 ---
CANVAS = 512.0
OFFSET, SCALE = 42.0, 0.8359375
RADIUS = 103.0            # 圆角
STROKE_HALF = 12.0        # stroke-width 24
NODE_R = 43.0
TRUNK = ((200.0, 143.5), (200.0, 367.5))
BRANCH = ((200.0, 257.0), (312.0, 317.5))
NODES = [(200.0, 143.5), (200.0, 367.5), (312.0, 317.5)]


def rounded_rect_sdf(x, y):
    """到 [0,512]² 圆角矩形边界的有符号距离，内部为负。"""
    hx = hy = CANVAS / 2
    dx = abs(x - hx) - (hx - RADIUS)
    dy = abs(y - hy) - (hy - RADIUS)
    outside = math.hypot(max(dx, 0.0), max(dy, 0.0))
    return outside + min(max(dx, dy), 0.0) - RADIUS


def segment_sdf(x, y, a, b):
    ax, ay = a
    bx, by = b
    vx, vy = bx - ax, by - ay
    t = ((x - ax) * vx + (y - ay) * vy) / (vx * vx + vy * vy)
    t = min(max(t, 0.0), 1.0)
    return math.hypot(x - ax - t * vx, y - ay - t * vy)


def glyph_sdf(x, y):
    d = min(
        segment_sdf(x, y, *TRUNK) - STROKE_HALF,
        segment_sdf(x, y, *BRANCH) - STROKE_HALF,
    )
    for cx, cy in NODES:
        d = min(d, math.hypot(x - cx, y - cy) - NODE_R)
    return d


def render(size):
    s = size / CANVAS
    px_per_local = SCALE * s          # 1 个局部单位等于多少个输出像素
    rows = []
    for py in range(size):
        row = bytearray()
        cy = (py + 0.5) / s
        ly = (cy - OFFSET) / SCALE
        for px in range(size):
            cx = (px + 0.5) / s
            lx = (cx - OFFSET) / SCALE
            # 覆盖率按「到边界还有几个输出像素」线性估计，够这种纯几何图形用。
            alpha = min(max(0.5 - rounded_rect_sdf(lx, ly) * px_per_local, 0.0), 1.0)
            ink = min(max(0.5 - glyph_sdf(lx, ly) * px_per_local, 0.0), 1.0)
            v = round(255 * (1.0 - ink))
            a = round(255 * alpha)
            # 预乘会让 macOS 把半透明边缘画灰，所以保持直通，颜色写满。
            row += bytes((v, v, v, a))
        rows.append(bytes(row))
    return rows


def write_png(path, size, rows):
    raw = b"".join(b"\x00" + r for r in rows)          # filter type 0
    def chunk(tag, body):
        c = tag + body
        return struct.pack(">I", len(body)) + c + struct.pack(">I", zlib.crc32(c))
    png = (
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", struct.pack(">IIBBBBB", size, size, 8, 6, 0, 0, 0))
        + chunk(b"IDAT", zlib.compress(raw, 9))
        + chunk(b"IEND", b"")
    )
    Path(path).write_bytes(png)


if __name__ == "__main__":
    out = Path(__file__).resolve().parent.parent / "macos/Runner/Assets.xcassets/AppIcon.appiconset"
    for size in (16, 32, 64, 128, 256, 512, 1024):
        write_png(out / f"app_icon_{size}.png", size, render(size))
        print(f"app_icon_{size}.png")
