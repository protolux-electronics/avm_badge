#!/usr/bin/env python3
"""Convert the Goatmire logo into raw rgba8888 for the splash screen.

The wordmark and the futhark line under it, stacked as goatmire.com shows
them. Stdlib only, sharing the PNG decoder with icons.py. Each part is
cropped to its opaque bounds, box-filtered down, and composited onto black
with every pixel opaque, which is the only path AtomGL draws without blending.

Usage:
  python3 tools/logo.py                 # assets/logo/goatmire@120xH.rgba, drawn at 2x
  python3 tools/logo.py --width 100 --runes 75 --gap 5
"""

import argparse
import os

from icons import decode_png

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, "assets", "src", "logo")
WORDMARK = os.path.join(SRC, "goatmire.png")
RUNES = os.path.join(SRC, "futhark.png")
OUT = os.path.join(ROOT, "assets", "logo")

# Space between the wordmark and the runes, in output pixels.
GAP = 6


def opaque_bounds(width, height, pixels):
    left, top, right, bottom = width, height, 0, 0
    for y in range(height):
        row = y * width * 4
        for x in range(width):
            if pixels[row + x * 4 + 3]:
                left, right = min(left, x), max(right, x)
                top, bottom = min(top, y), max(bottom, y)
    return left, top, right + 1, bottom + 1


def box_resize(width, pixels, box, target_w):
    """Averages source blocks, alpha-weighted, onto black."""
    left, top, right, bottom = box
    src_w, src_h = right - left, bottom - top
    target_h = max(1, round(src_h * target_w / src_w))
    out = bytearray(target_w * target_h * 4)

    for ty in range(target_h):
        y0 = top + ty * src_h // target_h
        y1 = max(y0 + 1, top + (ty + 1) * src_h // target_h)
        for tx in range(target_w):
            x0 = left + tx * src_w // target_w
            x1 = max(x0 + 1, left + (tx + 1) * src_w // target_w)
            r = g = b = count = 0
            for sy in range(y0, y1):
                row = sy * width
                for sx in range(x0, x1):
                    o = (row + sx) * 4
                    a = pixels[o + 3]
                    r += pixels[o] * a
                    g += pixels[o + 1] * a
                    b += pixels[o + 2] * a
                    count += 255
            o = (ty * target_w + tx) * 4
            out[o], out[o + 1], out[o + 2], out[o + 3] = r // count, g // count, b // count, 0xFF

    return target_w, target_h, bytes(out)


def scaled(path, target_w):
    width, height, pixels = decode_png(path)
    return box_resize(width, pixels, opaque_bounds(width, height, pixels), target_w)


def stack(parts, gap):
    """Centres each part horizontally on a black canvas, one under the next."""
    width = max(w for w, _h, _d in parts)
    height = sum(h for _w, h, _d in parts) + gap * (len(parts) - 1)
    out = bytearray(width * height * 4)
    for i in range(3, len(out), 4):
        out[i] = 0xFF

    y = 0
    for w, h, data in parts:
        x0 = (width - w) // 2
        for row in range(h):
            src = row * w * 4
            dst = ((y + row) * width + x0) * 4
            out[dst : dst + w * 4] = data[src : src + w * 4]
        y += h + gap

    return width, height, bytes(out)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--width", type=int, default=120, help="wordmark width in pixels")
    parser.add_argument("--runes", type=int, default=90, help="rune line width in pixels")
    parser.add_argument("--gap", type=int, default=GAP, help="pixels between wordmark and runes")
    parser.add_argument("--out", default=OUT)
    args = parser.parse_args()

    target_w, target_h, data = stack([scaled(WORDMARK, args.width), scaled(RUNES, args.runes)], args.gap)

    os.makedirs(args.out, exist_ok=True)
    for stale in os.listdir(args.out):
        if stale.endswith(".rgba"):
            os.remove(os.path.join(args.out, stale))

    name = f"goatmire@{target_w}x{target_h}.rgba"
    with open(os.path.join(args.out, name), "wb") as handle:
        handle.write(data)

    print(f"{name} {len(data)} bytes")


if __name__ == "__main__":
    main()
