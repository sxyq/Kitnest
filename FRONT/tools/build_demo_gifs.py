#!/usr/bin/env python3
"""v230：把真实交互截帧合成节奏统一的高清 GIF。

规则（针对旧 GIF 的毛病）：
  · 所有帧 duration 完全相同（100ms），停顿只靠重复帧，不混用 50/360/540/800ms；
  · 全局 192 色调色板，所有帧共用，避免逐帧量化导致的偏色与闪烁；
  · 2x 截帧缩到 760px 宽，画面裁到真实元素，不画大白框、不画假箭头；
  · 六个功能各一段，截图标注段用真机实拍的 annotate.png 做平移导览。
"""
import sys
from pathlib import Path

from PIL import Image, ImageOps, ImageSequence

ROOT = Path(__file__).resolve().parents[2]
FRAMES = Path(sys.argv[1]) if len(sys.argv) > 1 else Path('/tmp/kitnest-demo-frames')
OUTDIR = ROOT / 'FRONT/assets/gifs'
SHOTS = ROOT / 'FRONT/assets/shots'
FRAME_MS = 400          # 所有帧严格等长，节奏不忽快忽慢
WIDTH = 760
COLORS = 192
NAMES = ['clipboard', 'capture', 'monitor', 'transfer', 'cast', 'toolbox',
         'view-panel', 'view-monitor', 'view-transfer', 'view-cast',
         'view-annotate', 'view-popout', 'view-settings']

# 六段「真机界面导览」：从最新版实机截图（已脱敏）做平移导览。
# view-panel 不用静态图——它由 record_demos.mjs 录官网可交互主面板的真实 DOM 帧。
VIEW_FILES = {
    'view-monitor': 'panel-performance.png',
    'view-transfer': 'panel-transfer.png',
    'view-cast': 'panel-cast.png',
    'view-annotate': 'annotate.png',
    'view-popout': 'popout-cpu.png',
    'view-settings': 'settings.png',
}
VIEW_H = 560


def letterbox_free(im: Image.Image) -> Image.Image:
    """去掉四周纯白/近白留白，避免旧 GIF 那种无用白框。"""
    gray = im.convert('L')
    # 找非白区域的边界（阈值 250，容忍极淡背景）
    mask = gray.point(lambda p: 255 if p < 250 else 0)
    box = mask.getbbox()
    if not box:
        return im
    pad = 4
    box = (max(0, box[0] - pad), max(0, box[1] - pad),
           min(im.width, box[2] + pad), min(im.height, box[3] + pad))
    if box[2] - box[0] < im.width * 0.6 or box[3] - box[1] < im.height * 0.6:
        return im  # 背景本身很浅，别把内容裁没了
    return im.crop(box)


def resize(im: Image.Image) -> Image.Image:
    if im.width > WIDTH:
        h = round(im.height * WIDTH / im.width)
        im = im.resize((WIDTH, h), Image.LANCZOS)
    return im


def capture_frames() -> list:
    """截图标注：用真机实拍的标注编辑器做平移导览，UI 全部真实。
    所有裁剪窗口保持同一宽高比，缩放到同一画幅后不需要补边（旧 GIF 的上下白框就是补出来的）。"""
    src = Image.open(SHOTS / 'annotate.png').convert('RGB')
    src = letterbox_free(src)
    w, h = src.size
    ratio = WIDTH / 560
    windows = [
        (0, 0, w, h),                                                  # 全景
        (0, 0, int(w * 0.52), int(h * 0.62)),                         # 左侧工具栏
        (int(w * 0.16), int(h * 0.10), int(w * 0.94), int(h * 0.66)), # 画布
        (0, int(h * 0.62), w, h),                                     # 底部动作条
        (int(w * 0.10), int(h * 0.20), int(w * 0.82), int(h * 0.82)), # 中景
        (0, 0, w, h),                                                  # 回到全景
    ]
    frames = []
    for x0, y0, x1, y1 in windows:
        cw, ch = x1 - x0, y1 - y0
        if cw / ch > ratio:
            ch = round(cw / ratio)
        else:
            cw = round(ch * ratio)
        cx, cy = (x0 + x1) / 2, (y0 + y1) / 2
        x0 = max(0, min(w - cw, round(cx - cw / 2)))
        y0 = max(0, min(h - ch, round(cy - ch / 2)))
        crop = src.crop((x0, y0, x0 + cw, y0 + ch))
        frames.append(crop.resize((WIDTH, 560), Image.LANCZOS))
    return frames


def pan_frames(name: str) -> list:
    """最新真机界面 → 6 帧镜头平移，每帧铺满 760×560。

    v237.1：旧版首/末帧用 contain + pad 做「全景」，真机窗是竖长条时会变成
    「中间一条窄图、左右两大片浅色留白」，正是要去掉的无用白框。改成先 cover
    缩放（缩放后宽高必定 >= 画幅），再沿主轴平移取窗：每一帧都是真实界面本身，
    不补边、不画假箭头，横向窗则沿横轴平移并轻微推近看细节。
    """
    src = letterbox_free(Image.open(SHOTS / VIEW_FILES[name]).convert('RGB'))
    w, h = src.size
    ratio = WIDTH / VIEW_H
    scale = max(WIDTH / w, VIEW_H / h)
    big = src.resize((max(WIDTH, round(w * scale)),
                      max(VIEW_H, round(h * scale))), Image.LANCZOS)
    bw, bh = big.size
    vertical = (bh / bw) > ratio
    # (主轴位置 0→1, 裁窗尺寸系数；<1 即镜头推近看细节)
    stops = [(0.00, 1.00), (0.30, 0.94), (0.60, 1.00),
             (0.86, 0.88), (1.00, 0.96), (0.00, 1.00)]
    frames = []
    for t, zoom in stops:
        cw = round(WIDTH * zoom)
        ch = round(VIEW_H * zoom)
        if vertical:
            x0 = (bw - cw) // 2
            y0 = round((bh - ch) * t)
        else:
            x0 = round((bw - cw) * t)
            y0 = (bh - ch) // 2
        crop = big.crop((x0, y0, x0 + cw, y0 + ch))
        frames.append(crop.resize((WIDTH, VIEW_H), Image.LANCZOS))
    return frames


def build(name: str) -> dict:
    if name == 'capture':
        frames = [resize(f) for f in capture_frames()]
    else:
        d = FRAMES / name
        files = sorted(d.glob('*.png'))
        if not files:
            raise SystemExit('缺少截帧：' + str(d))
        frames = []
        for p in files:
            im = Image.open(p).convert('RGB')
            # 导览帧已经是统一画幅且带浅色留白，再做去白边会把画幅裁歪
            if not name.startswith('view-'):
                im = letterbox_free(im)
            frames.append(resize(im))
        # 统一画幅（不同状态下元素高度可能差几像素）
        w = max(f.width for f in frames)
        h = max(f.height for f in frames)
        frames = [ImageOps.pad(f, (w, h), color=(250, 251, 253), method=Image.LANCZOS)
                  for f in frames]

    # 每帧等长；连续完全相同的画面去重，避免 GIF 编码器把同画面帧合并成不等长帧
    seq = [frames[0]]
    for f in frames[1:]:
        if f.tobytes() != seq[-1].tobytes():
            seq.append(f)

    # 全局调色板：所有帧缩略图拼一张量化，避免逐帧偏色/闪烁
    thumb_w = 64
    thumbs = []
    for f in seq[::max(1, len(seq) // 12)]:
        thumbs.append(f.resize((thumb_w, max(1, round(f.height * thumb_w / f.width))), Image.LANCZOS))
    sheet_w = thumb_w * len(thumbs)
    sheet_h = max(t.height for t in thumbs)
    sheet = Image.new('RGB', (sheet_w, sheet_h))
    x = 0
    for t in thumbs:
        sheet.paste(t, (x, 0))
        x += thumb_w
    palette = sheet.quantize(colors=COLORS, method=Image.MEDIANCUT)
    qframes = [f.quantize(palette=palette, dither=Image.Dither.FLOYDSTEINBERG)
               for f in seq]

    out = OUTDIR / ('demo-' + name + '.gif')
    # optimize=False：不让编码器把相邻帧合并成不等长的帧，保证严格统一节奏
    qframes[0].save(
        out, save_all=True, append_images=qframes[1:],
        duration=FRAME_MS, loop=0, optimize=False, disposal=2)

    # 读回实际 GIF 校验帧数、帧时长
    with Image.open(out) as g:
        actual = []
        for f in ImageSequence.Iterator(g):
            actual.append(f.info.get('duration'))
        n_frames = getattr(g, 'n_frames', len(actual))
    assert len(actual) == len(seq), '%s 帧数被合并：%d → %d' % (name, len(seq), len(actual))
    assert set(actual) == {FRAME_MS}, '%s 帧时长不统一：%s' % (name, sorted(set(actual)))
    return {
        'name': name, 'states': len(frames), 'frames': n_frames,
        'size': qframes[0].size, 'ms': len(seq) * FRAME_MS,
        'kb': round(out.stat().st_size / 1024),
        'durations': set(actual),
    }


def main() -> int:
    OUTDIR.mkdir(parents=True, exist_ok=True)
    # 六段真机界面导览帧：直接从最新版 shots/ 生成，不经过浏览器截帧
    for name in VIEW_FILES:
        d = FRAMES / name
        d.mkdir(parents=True, exist_ok=True)
        for old in d.glob('*.png'):
            old.unlink()
        for i, frame in enumerate(pan_frames(name)):
            frame.save(d / ('%03d.png' % i))
        print('  frames %-16s %d' % (name, len(list(d.glob('*.png')))))
    results = [build(n) for n in NAMES]
    print('%-12s %7s %7s %10s %8s %8s' %
          ('demo', 'states', 'frames', 'size(px)', 'ms', 'KB'))
    for r in results:
        print('%-12s %7d %7d %10s %8d %8d' %
              (r['name'], r['states'], r['frames'],
               '%dx%d' % r['size'], r['ms'], r['kb']))
    durs = set().union(*(r['durations'] for r in results))
    assert durs == {FRAME_MS}, '帧时长不统一：%s' % durs
    print('\n✅ 十三段动图节奏统一（每帧 %dms），共 %.1f MB' %
          (FRAME_MS, sum(r['kb'] for r in results) / 1024))
    return 0


if __name__ == '__main__':
    sys.exit(main())
