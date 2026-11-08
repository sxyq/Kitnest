#!/usr/bin/env python3
"""frames → 高清 GIF：全局调色板（防闪烁）+ 等长帧（防忽快忽慢）+ 增量帧（压体积）。

体积控制：--max-kb 会依次降色数（160 → 128 → 96 → 64）重编，直到达标。
"""
import argparse
import sys
from pathlib import Path

from PIL import Image, ImageChops, ImageDraw, ImageFont


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


def merge_still(frames, th, ms):
    """把「看着一样」的连续帧并成一帧，时长累加。

    录屏本身带 H.264 噪声，镜头停住时逐帧仍会差几个色阶；按阈值合并后
    静止段只留一帧，GIF 体积能掉一个数量级，而节奏不变（用 duration 记）。
    """
    if th <= 0:
        return frames, [ms] * len(frames)
    keep, durs = [frames[0]], [ms]
    for f in frames[1:]:
        d = ImageChops.difference(f, keep[-1]).convert("L")
        if d.getextrema()[1] <= th:
            durs[-1] += ms
        else:
            keep.append(f)
            durs.append(ms)
    return keep, durs


def encode(frames, colors, dst, ms, delta_th, durs=None):
    """增量帧：只有和上一帧不同的地方贴像素，其余填透明索引，体积可降一个数量级。"""
    pal = global_palette(frames, colors)
    base = pal.getpalette() or []
    idx = max(1, min(255, len(base) // 3))      # 透明索引紧接调色板末尾
    full = base + [0, 0, 0] * (max(0, 768 - len(base)) // 3)
    qs = []
    prev = None
    for f in frames:
        q = f.quantize(palette=pal)
        if prev is not None and delta_th >= 0:
            m = ImageChops.difference(f, prev).convert("L") \
                .point(lambda v, t=delta_th: 255 if v > t else 0)
            out = Image.new("P", q.size, idx)
            out.putpalette(full)
            out.paste(q, (0, 0), m)
            q = out
        qs.append(q)
        prev = f
    kw = dict(save_all=True, append_images=qs[1:], duration=durs or ms, loop=0, disposal=1)
    if delta_th >= 0:
        kw["transparency"] = idx
    qs[0].save(dst, **kw)
    return Path(dst).stat().st_size // 1024


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("frames")
    ap.add_argument("out")
    ap.add_argument("--ms", type=int, default=100, help="每帧时长 ms")
    ap.add_argument("--colors", type=int, default=176)
    ap.add_argument("--badge", default="")
    ap.add_argument("--hold", type=int, default=0, help="末尾停留帧数")
    ap.add_argument("--trim-tail", action="store_true")
    ap.add_argument("--max-kb", type=int, default=0, help="体积上限，超了自动降色数")
    ap.add_argument("--no-delta", action="store_true", help="关闭增量帧")
    ap.add_argument("--merge-th", type=int, default=0,
                    help="静止帧合并阈值（0=关；建议 4，够吸掉编码噪声）")
    a = ap.parse_args()

    frames = load_frames(Path(a.frames))
    if a.trim_tail:
        frames = trim_static_tail(frames)
    if a.badge:
        frames = [badge(f, a.badge) for f in frames]
    if a.hold:
        frames += [frames[-1]] * a.hold

    durs = None
    if a.merge_th:
        frames, durs = merge_still(frames, a.merge_th, a.ms)
        print(f"  merge≤{a.merge_th}: {len(durs)} 帧（原 {len(durs) + 0}）")
    delta_th = -1 if a.no_delta else 8
    ladder = [a.colors] + [c for c in (160, 128, 96, 64) if c < a.colors]
    for i, colors in enumerate(ladder):
        kb = encode(frames, colors, a.out, a.ms, delta_th, durs)
        print(f"  try {colors}c delta={delta_th} → {kb} KB")
        if not a.max_kb or kb <= a.max_kb:
            break
    print(f"OK {a.out} {kb} KB  {len(frames)}f @{a.ms}ms  {colors}c  {frames[0].width}×{frames[0].height}")


if __name__ == "__main__":
    main()
