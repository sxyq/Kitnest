#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Kitnest 官网截图脱敏（v203 / 2026-11-05）

为什么需要：
  实机面板截图里，剪贴板历史区会显示**用户真实复制过的内容**
  （聊天消息、链接、文件名……）。官网是公开页面，直接放原图等于泄露用户隐私。

做法：
  只对剪贴板条目的**文字区域**做「高斯模糊 + 白色遮罩」，
  保留图标、布局、间距与配色，视觉上像打码后的剪贴板列表；
  面板上方的页签、搜索框、日历、底部工具条全部保持原样。

用法：
  python3 website/tools/sanitize_shots.py
  （输入：apps/FrsetNext/Resources/Manual/shots/*.png
    输出：website/assets/shots/*.png，已就地脱敏）
"""

import os
import sys

from PIL import Image, ImageDraw, ImageFilter

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
SRC_DIR = os.path.join(ROOT, "apps", "FrsetNext", "Resources", "Manual", "shots")
OUT_DIR = os.path.join(ROOT, "website", "assets", "shots")

# (源文件, 输出名)
JOBS = [
    ("panel.png", "panel.png"),
    ("panel-anchored.png", "panel-anchored.png"),
    ("v75-panel-performance.png", "panel-performance.png"),
    ("popout-unified-cpu.png", "popout-cpu.png"),
    ("popout-unified-sensors.png", "popout-sensors.png"),
]

# 剪贴板条目文字带（图片坐标 720x1260 基准）
# 格式：(y_top, y_bottom)，x 固定取右侧文字栏，避开左侧图标
TEXT_BANDS = [
    (490, 585),    # 条目 1：GitHub 链接
    (645, 740),    # 条目 2：图片
    (790, 885),    # 条目 3：工程消息
    (940, 1035),   # 条目 4：英文长句
    (1085, 1145),  # 条目 5：当前状态（下方被工具条压住）
]

TEXT_X = (140, 665)
BLUR_RADIUS = 11
WHITE_ALPHA = 176


def sanitize(src_path: str, out_path: str) -> None:
    im = Image.open(src_path).convert("RGB")
    if im.size != (720, 1260):
        # 非基准尺寸（例如 840x1520 的独立窗）按比例换算坐标
        sx = im.width / 720.0
        sy = im.height / 1260.0
    else:
        sx = sy = 1.0

    for y0, y1 in TEXT_BANDS:
        box = (int(TEXT_X[0] * sx), int(y0 * sy), int(TEXT_X[1] * sx), int(y1 * sy))
        region = im.crop(box)
        region = region.filter(ImageFilter.GaussianBlur(radius=BLUR_RADIUS))
        mask = Image.new("L", region.size, WHITE_ALPHA)
        white = Image.new("RGB", region.size, (255, 255, 255))
        region = Image.composite(white, region, mask)
        im.paste(region, box)

    im.save(out_path, optimize=True)
    print("  ✓ %s → %s (%d bytes)" % (os.path.basename(src_path),
                                       os.path.relpath(out_path, ROOT),
                                       os.path.getsize(out_path)))


def main() -> int:
    if not os.path.isdir(SRC_DIR):
        print("✗ 找不到源截图目录：%s" % SRC_DIR)
        return 1
    os.makedirs(OUT_DIR, exist_ok=True)
    print("== 脱敏并导出官网截图 ==")
    for src_name, out_name in JOBS:
        src = os.path.join(SRC_DIR, src_name)
        if not os.path.exists(src):
            print("  - 跳过缺失源文件：%s" % src_name)
            continue
        sanitize(src, os.path.join(OUT_DIR, out_name))
    print("✓ 完成")
    return 0


if __name__ == "__main__":
    sys.exit(main())
