#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Kitnest 官网演示动图生成器（v215 / 2026-11-05）

产出：website/assets/gifs/capture-flow.gif
内容：**纯模拟画面**（不截真实屏幕、不含任何真实数据），
      演示「区域框选 → 截取 → 动作条 → 标注编辑（矩形/箭头/马赛克）→ 复制完成」全流程。

为什么要做动图：
  官网的静态截图只能说明「长什么样」，说明不了「怎么用」。
  截图/标注是 Kitnest 最高频的动作，用动图演示能在一屏内讲清操作顺序。

用法：
  python3 website/tools/make_gifs.py
"""

import os
import sys

from PIL import Image, ImageDraw, ImageFont

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
OUT_DIR = os.path.join(ROOT, "website", "assets", "gifs")

W, H = 960, 600
CJK = "/System/Library/Fonts/Hiragino Sans GB.ttc"
UI = "/System/Library/Fonts/SFNS.ttf"

# 主题色（与官网一致）
INK = (11, 11, 13)
INK2 = (74, 74, 82)
INK3 = (138, 138, 148)
LINE = (226, 226, 232)
PANEL = (255, 255, 255)
ACCENT = (47, 107, 255)
ACCENT_SOFT = (238, 243, 255)
RED = (240, 68, 56)
GREEN = (18, 183, 106)


def font(path, size, index=0):
    try:
        return ImageFont.truetype(path, size, index=index)
    except Exception:
        return ImageFont.load_default()


F_TITLE = font(CJK, 19)
F_BODY = font(CJK, 15)
F_SMALL = font(CJK, 13)
F_TINY = font(CJK, 11)
F_UI = font(UI, 13)
F_UI_BOLD = font(UI, 13)


def rrect(draw, box, radius, fill=None, outline=None, width=1):
    draw.rounded_rectangle(box, radius=radius, fill=fill, outline=outline, width=width)


def shadow(base, box, radius, blur=18, alpha=46, offset=(0, 8)):
    """给圆角矩形加一层柔和投影（返回带阴影的图层）。"""
    layer = Image.new("RGBA", base.size, (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)
    x0, y0, x1, y1 = box
    d.rounded_rectangle((x0 + offset[0], y0 + offset[1], x1 + offset[0], y1 + offset[1]),
                        radius=radius, fill=(20, 24, 40, alpha))
    from PIL import ImageFilter
    layer = layer.filter(ImageFilter.GaussianBlur(blur))
    base.alpha_composite(layer)


def wallpaper():
    """模拟桌面壁纸（纯渐变 + 柔光，不含任何真实内容）。"""
    img = Image.new("RGBA", (W, H), (255, 255, 255, 255))
    d = ImageDraw.Draw(img)
    top = (203, 216, 246)
    bottom = (236, 240, 250)
    for y in range(H):
        t = y / float(H)
        d.line([(0, y), (W, y)],
               fill=(int(top[0] + (bottom[0] - top[0]) * t),
                     int(top[1] + (bottom[1] - top[1]) * t),
                     int(top[2] + (bottom[2] - top[2]) * t), 255))
    blob = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    bd = ImageDraw.Draw(blob)
    bd.ellipse((520, -140, 1120, 420), fill=(255, 255, 255, 120))
    bd.ellipse((-180, 320, 380, 820), fill=(198, 214, 255, 110))
    from PIL import ImageFilter
    blob = blob.filter(ImageFilter.GaussianBlur(60))
    img.alpha_composite(blob)
    return img


def chat_window():
    """被截图的「示例应用窗口」——内容全部为虚构演示文本。"""
    win = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    d = ImageDraw.Draw(win)
    box = (150, 70, 830, 520)
    shadow(win, box, 16, blur=22, alpha=52)
    rrect(d, box, 16, fill=PANEL, outline=(228, 228, 234), width=1)

    x0, y0, x1, y1 = box
    # 标题栏
    d.line([(x0 + 1, y0 + 40), (x1 - 1, y0 + 40)], fill=LINE, width=1)
    for i, c in enumerate([(255, 95, 86), (255, 189, 46), (39, 201, 63)]):
        d.ellipse((x0 + 18 + i * 20, y0 + 15, x0 + 28 + i * 20, y0 + 25), fill=c)
    d.text((x0 + 92, y0 + 12), "团队群聊 · 演示窗口", font=F_BODY, fill=INK)

    # 侧栏
    d.line([(x0 + 190, y0 + 41), (x0 + 190, y1 - 1)], fill=LINE, width=1)
    for i, (name, sub) in enumerate([("产品讨论组", "3 条新消息"), ("设计评审", "昨天"),
                                     ("周报同步", "上周"), ("临时协作", "已归档")]):
        ty = y0 + 60 + i * 52
        rrect(d, (x0 + 16, ty, x0 + 174, ty + 40), 10,
              fill=ACCENT_SOFT if i == 0 else (247, 247, 250))
        d.ellipse((x0 + 28, ty + 12, x0 + 44, ty + 28), fill=(160, 178, 235))
        d.text((x0 + 54, ty + 8), name, font=F_SMALL, fill=INK)
        d.text((x0 + 54, ty + 24), sub, font=F_TINY, fill=INK3)

    # 消息区
    mx = x0 + 214
    d.ellipse((mx, y0 + 58, mx + 30, y0 + 88), fill=(186, 200, 240))
    d.text((mx + 40, y0 + 58), "小林", font=F_SMALL, fill=INK)
    d.text((mx + 40, y0 + 78), "示例内容 · 以下文字均为演示用", font=F_TINY, fill=INK3)

    rrect(d, (mx, y0 + 104, mx + 360, y0 + 156), 12, fill=(246, 247, 250))
    d.text((mx + 16, y0 + 116), "新版面板的搜索支持模糊匹配，", font=F_BODY, fill=INK2)
    d.text((mx + 16, y0 + 136), "输入 / 还能直接唤起工具。", font=F_BODY, fill=INK2)

    # 图片块（后续会被标注框住）
    rrect(d, (mx, y0 + 176, mx + 250, y0 + 316), 12, fill=(228, 233, 246))
    d.rectangle((mx + 20, y0 + 206, mx + 96, y0 + 262), fill=(186, 200, 235))
    d.polygon([(mx + 34, y0 + 262), (mx + 70, y0 + 222), (mx + 92, y0 + 262)], fill=(160, 178, 235))
    d.ellipse((mx + 178, y0 + 200, mx + 214, y0 + 236), fill=(205, 215, 240))
    d.text((mx + 16, y0 + 274), "示例图片 · 用于演示标注", font=F_TINY, fill=INK3)

    # 含「手机号」的一行（用于演示马赛克）
    d.ellipse((mx, y0 + 336, mx + 30, y0 + 366), fill=(200, 210, 238))
    d.text((mx + 40, y0 + 336), "小周", font=F_SMALL, fill=INK)
    rrect(d, (mx, y0 + 376, mx + 300, y0 + 414), 12, fill=(246, 247, 250))
    d.text((mx + 16, y0 + 386), "我的手机号是 138 0013 8000", font=F_BODY, fill=INK2)
    return win, box


def action_toolbar(d, cx, cy):
    """截图后的动作条（复制/保存/贴图/识字/翻译/编辑/美化/空投）。"""
    items = ["复制", "保存", "贴图", "识字", "翻译", "编辑", "美化", "空投"]
    w, h = 92, 62
    total = len(items) * w
    x0 = cx - total // 2
    rrect(d, (x0, cy - h // 2, x0 + total, cy + h // 2), 14, fill=PANEL,
          outline=(226, 226, 232), width=1)
    for i, name in enumerate(items):
        ix = x0 + i * w
        d.ellipse((ix + w // 2 - 11, cy - 22, ix + w // 2 + 11, cy), fill=(243, 244, 247))
        d.line([(ix + w // 2 - 5, cy - 11), (ix + w // 2 + 5, cy - 11)], fill=INK3, width=2)
        d.text((ix + w // 2, cy + 4), name, font=F_TINY, fill=INK2, anchor="ma")
    return (x0, cy - h // 2, x0 + total, cy + h // 2)


def annotate_toolbar(d, cx, cy, active=0, copy_hot=False):
    """标注编辑器底部工具条。"""
    w = 560
    x0 = cx - w // 2
    rrect(d, (x0, cy - 26, x0 + w, cy + 26), 12, fill=PANEL, outline=(224, 224, 230), width=1)
    tools = ["矩形", "椭圆", "箭头", "画笔", "文字", "马赛克"]
    colors = [(240, 68, 56), (247, 144, 9), (47, 107, 255), (18, 183, 106), (11, 11, 13)]
    x = x0 + 14
    for i, name in enumerate(tools):
        hot = (i == active)
        if hot:
            rrect(d, (x - 6, cy - 19, x + 52, cy + 19), 8, fill=ACCENT_SOFT)
        d.text((x + 23, cy), name, font=F_TINY, fill=ACCENT if hot else INK2, anchor="mm")
        x += 58
    d.line([(x + 2, cy - 16), (x + 2, cy + 16)], fill=LINE, width=1)
    x += 12
    for c in colors:
        d.ellipse((x, cy - 6, x + 12, cy + 6), fill=c)
        x += 18
    d.line([(x + 2, cy - 16), (x + 2, cy + 16)], fill=LINE, width=1)
    x += 12
    x += 40
    if copy_hot:
        rrect(d, (x - 8, cy - 15, x + 46, cy + 15), 8, fill=ACCENT)
        d.text((x + 19, cy), "复制", font=F_TINY, fill=(255, 255, 255), anchor="mm")
    else:
        d.text((x + 19, cy), "复制", font=F_TINY, fill=INK2, anchor="mm")
    return (x0, cy - 26, x0 + w, cy + 26)


def mosaic(img, box, cell=8):
    """马赛克：把 box 区域像素化。"""
    x0, y0, x1, y1 = [int(v) for v in box]
    x0, y0 = max(0, x0), max(0, y0)
    x1, y1 = min(img.width, x1), min(img.height, y1)
    if x1 - x0 < 4 or y1 - y0 < 4:
        return
    region = img.crop((x0, y0, x1, y1)).convert("RGB")
    small = region.resize((max(1, (x1 - x0) // cell), max(1, (y1 - y0) // cell)), Image.BILINEAR)
    patch = small.resize((x1 - x0, y1 - y0), Image.NEAREST)
    img.paste(patch, (x0, y0))


def frame_select(p):
    """暗屏 + 拖拽选区。"""
    img = wallpaper()
    win, box = chat_window()
    img.alpha_composite(win)
    d = ImageDraw.Draw(img, "RGBA")

    sx0, sy0, sx1, sy1 = box
    # 选区随进度增长
    gx = sx0 + int((sx1 - sx0) * p)
    gy = sy1 - int((sy1 - sy0) * p)
    # 选区外压暗：遮罩在选区内为 0（透明），选区外为 255（压暗）
    mask = Image.new("L", (W, H), 255)
    md = ImageDraw.Draw(mask)
    md.rectangle((gx, gy, sx1, sy1), fill=0)
    img.paste(Image.new("RGBA", (W, H), (14, 16, 26, 96)), (0, 0), mask)
    # 选区描边 + 手柄
    d.rectangle((gx, gy, sx1, sy1), outline=ACCENT + (255,), width=2)
    for hx, hy in [(gx, gy), (sx1, gy), (gx, sy1), (sx1, sy1)]:
        d.rectangle((hx - 4, hy - 4, hx + 4, hy + 4), fill=(255, 255, 255, 255),
                    outline=ACCENT + (255,), width=2)
    d.text((gx + 12, gy + 12), "⌥S 区域截图", font=F_TINY, fill=(255, 255, 255, 235))
    return img


def frame_captured():
    """截取完成：画面 + 动作条。"""
    img = Image.new("RGBA", (W, H), (244, 244, 247, 255))
    d = ImageDraw.Draw(img, "RGBA")
    win, box = chat_window()
    crop = win.crop(box)
    shadow(img, (170, 60, 170 + crop.width, 60 + crop.height), 14, blur=20, alpha=40)
    img.alpha_composite(crop, (170, 60))
    action_toolbar(d, W // 2, H - 84)
    d.text((W // 2, 34), "已截取 · 动作条可直接执行", font=F_SMALL, fill=INK3, anchor="ma")
    return img


def frame_annotate(stage):
    """标注编辑器：矩形 → 箭头 → 马赛克 → 复制完成。"""
    img = Image.new("RGBA", (W, H), (238, 239, 243, 255))
    d = ImageDraw.Draw(img, "RGBA")
    win, box = chat_window()
    crop = win.crop(box)
    ox, oy = 170, 56
    shadow(img, (ox, oy, ox + crop.width, oy + crop.height), 14, blur=20, alpha=40)
    img.alpha_composite(crop, (ox, oy))

    # 画布坐标换算（窗口内 → 画布）
    wx0, wy0, wx1, wy1 = box
    sx = ox + (wx1 - wx0) // 2

    if stage >= 1:  # 矩形标注（部分画出）
        p = min(1.0, stage)
        rx0, ry0 = ox + 200, oy + 172
        rx1 = rx0 + int(250 * p)
        ry1 = ry0 + int(140 * p)
        d.rectangle((rx0, ry0, rx1, ry1), outline=RED + (255,), width=3)
        d.ellipse((rx0 - 9, ry0 - 9, rx0 + 9, ry0 + 9), fill=RED + (255,))
        d.ellipse((rx0 - 28, ry0 - 27, rx0 - 8, ry0 - 7), fill=RED + (255,))
        d.text((rx0 - 18, ry0 - 26), "1", font=F_TINY, fill=(255, 255, 255), anchor="ma")

    if stage >= 2:  # 箭头
        ay0, ay1 = oy + 320, oy + 250
        ax0, ax1 = ox + 470, ox + 430
        d.line((ax0, ay0, ax1, ay1), fill=RED + (255,), width=3)
        d.polygon([(ax1, ay1), (ax1 - 14, ay1 - 4), (ax1 - 4, ay1 + 12)], fill=RED + (255,))

    if stage >= 3:  # 马赛克遮住手机号
        mb = (ox + 318, oy + 376, ox + 452, oy + 400)
        mosaic(img, mb, cell=6)
        d.rectangle(mb, outline=RED + (110,), width=1)

    annotate_toolbar(d, W // 2, H - 40, active=(2 if stage >= 2 else 0),
                     copy_hot=(stage >= 4))

    if stage >= 4:  # 复制完成
        rrect(d, (W - 268, H - 168, W - 44, H - 132), 12, fill=(24, 24, 28, 240))
        d.text((W - 156, H - 150), "已复制到剪贴板", font=F_SMALL, fill=(255, 255, 255), anchor="mm")
    return img


def build():
    os.makedirs(OUT_DIR, exist_ok=True)
    frames = []
    durations = []

    # 1) 框选 6 帧
    for i in range(6):
        frames.append(frame_select((i + 1) / 6.0))
        durations.append(130)

    # 2) 截取完成 2 帧
    for _ in range(2):
        frames.append(frame_captured())
        durations.append(320)

    # 3) 标注 4 个阶段（矩形渐进 + 箭头 + 马赛克 + 复制）
    for st in (1, 1, 2, 3, 4, 4):
        frames.append(frame_annotate(st))
        durations.append(320)

    # 转 GIF（统一调色板，减小体积）
    # 调色板必须包含标注帧里的红色 —— 用标注完成帧做基准，否则红框会被量化成灰色
    pal = frames[-1].convert("P", palette=Image.ADAPTIVE, colors=200)
    out = [f.convert("RGB").quantize(palette=pal) for f in frames]
    path = os.path.join(OUT_DIR, "capture-flow.gif")
    out[0].save(path, save_all=True, append_images=out[1:], loop=0,
                duration=durations, optimize=True, disposal=2)
    print("  ✓ %s（%d 帧，%.1f KB）" % (os.path.relpath(path, ROOT), len(out),
                                        os.path.getsize(path) / 1024))
    return path


if __name__ == "__main__":
    sys.exit(0 if build() else 1)
