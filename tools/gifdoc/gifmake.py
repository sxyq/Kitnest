#!/usr/bin/env python3
"""frames → 高清 GIF：全局调色板（防闪烁）+ 等长帧（防忽快忽慢）+ 可选速度角标。"""
import argparse
import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont


def load_frames(d: Path):
    files = sorted(d.glob("*.png"))
    if not files:
        sys.exit(f"no frames in {d}")
    return [Image.open(f).convert("RGB") for f in files]


def global_palette(frames, colors: int):
    """从均匀抽样的帧拼一张图，中位切分求一套共用调色板；各帧只做子集量化。"""
    picks = frames[:: max(1, len(frames) // 12)][:12]
    small = []
    for im in picks:
        w = 320
        h = max(1, round(im.height * w / im.width))
        small.append(im.resize((w, h), Image.LANCZOS))
    cols = 3
    rows = (len(small) + cols - 1) // cols
    cw = max(i.width for i in small)
    ch = max(i.height for i in small)
    sheet = Image.new("RGB", (cw * cols, ch * rows), "white")
    for i, im in enumerate(small):
        sheet.paste(im, ((i % cols) * cw, (i // cols) * ch))
    return sheet.quantize(colors=colors, method=Image.MEDIANCUT)


def badge(im: Image.Image, text: str):
    im = im.copy()
    d = ImageDraw.Draw(im, "RGBA")
    try:
        font = ImageFont.truetype("/System/Library/Fonts/PingFang.ttc", max(13, im.width // 55))
    except Exception:
        font = ImageFont.load_default()
    pad = max(6, im.width // 160)
    l, t, r, b = d.textbbox((0, 0), text, font=font)
    tw, th = r - l, b - t
    x1, y1 = im.width - tw - pad * 3, im.height - th - pad * 3
    d.rounded_rectangle([x1, y1, im.width - pad, im.height - pad],
                        radius=pad + 2, fill=(0, 0, 0, 150))
    d.text((x1 + pad, y1 + pad * 0.4), text, font=font, fill=(255, 255, 255, 235))
    return im


def trim_static_tail(frames, min_keep=6):
    last = len(frames) - 1
    while last > min_keep and frames[last].tobytes() == frames[last - 1].tobytes():
        last -= 1
    return frames[: last + 1]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("frames")
    ap.add_argument("out")
    ap.add_argument("--ms", type=int, default=100, help="每帧时长 ms")
    ap.add_argument("--colors", type=int, default=176)
    ap.add_argument("--badge", default="")
    ap.add_argument("--hold", type=int, default=0, help="末尾停留帧数")
    ap.add_argument("--trim-tail", action="store_true")
    a = ap.parse_args()

    frames = load_frames(Path(a.frames))
    if a.trim_tail:
        frames = trim_static_tail(frames)
    if a.badge:
        frames = [badge(f, a.badge) for f in frames]
    if a.hold:
        frames += [frames[-1]] * a.hold

    pal = global_palette(frames, a.colors)
    qs = [f.quantize(palette=pal, dither=Image.NONE) for f in frames]
    qs[0].save(a.out, save_all=True, append_images=qs[1:], duration=a.ms,
               loop=0, optimize=True, disposal=1)
    kb = Path(a.out).stat().st_size // 1024
    print(f"OK {a.out} {kb} KB  {len(frames)}f @{a.ms}ms  {a.colors}c  {qs[0].width}×{qs[0].height}")


if __name__ == "__main__":
    main()
