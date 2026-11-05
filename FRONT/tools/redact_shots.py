#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Kitnest 官网截图处理（v216 / 2026-11-05）

输入：docs/assets/website-shots/*.png（真机整窗截图，ScreenCaptureKit 抓的完整窗口）
输出：website/assets/shots/*.png（可直接上图）

跟上一版 sanitize_shots.py 的区别：
  · 上一版是「先截真机图、再把剪贴板文字整片打码」，结果官网图上根本看不清内容；
  · 这一版改成**先灌假数据再截图**：剪贴板里放的是 JSON / Markdown / Swift / Python /
    示例图片 / 示例链接，截图里就是这些干净内容，因此**不再需要打码**；
  · 剩下确实带私人信息的区域（局域网 IP、正在运行的进程名、暂存区真实文件名），
    由本脚本**按区域裁剪/遮罩**，而不是整片模糊。

用法：
  python3 website/tools/redact_shots.py
"""

import os
import sys

from PIL import Image, ImageDraw, ImageFilter

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
SRC = os.path.join(ROOT, "docs", "assets", "website-shots")
OUT = os.path.join(ROOT, "website", "assets", "shots")


def blur_box(img, box, radius=9, alpha=200):
    """把 box 区域做模糊 + 白遮罩（保留一点底纹，看得出这里原本有东西）。"""
    x0, y0, x1, y1 = [int(v) for v in box]
    x0, y0 = max(0, x0), max(0, y0)
    x1, y1 = min(img.width, x1), min(img.height, y1)
    if x1 - x0 < 4 or y1 - y0 < 4:
        return
    region = img.crop((x0, y0, x1, y1)).filter(ImageFilter.GaussianBlur(radius=radius))
    mask = Image.new("L", region.size, alpha)
    white = Image.new("RGB", region.size, (255, 255, 255))
    img.paste(Image.composite(white, region, mask), (x0, y0))


def build():
    os.makedirs(OUT, exist_ok=True)
    print("== 处理官网截图 ==")

    # 1) 主面板（剪贴板里是灌好的假数据，直接用）
    im = Image.open(os.path.join(SRC, "panel_home.png")).convert("RGB")
    im.save(os.path.join(OUT, "panel.png"), optimize=True)
    print("  ✓ panel.png（%dx%d，剪贴板为演示数据，无需打码）" % im.size)

    # 2) 性能监测页
    im = Image.open(os.path.join(SRC, "panel_perf.png")).convert("RGB")
    im.save(os.path.join(OUT, "panel-performance.png"), optimize=True)
    print("  ✓ panel-performance.png（%dx%d）" % im.size)

    # 3) 文件中转页：只保留「发送 / 接收 / 云端 + 三个出口」，
    #    下方「本地暂存」里有用户真实文件名，**裁掉**。
    im = Image.open(os.path.join(SRC, "panel_transfer.png")).convert("RGB")
    cut = int(im.height * 0.335)          # 暂存区标题之上
    im.crop((0, 0, im.width, cut)).save(os.path.join(OUT, "panel-transfer.png"), optimize=True)
    print("  ✓ panel-transfer.png（%dx%d，裁掉暂存区真实文件名）" % (im.width, cut))

    # 4) 投屏页：遮住局域网 IP（两个位置）
    im = Image.open(os.path.join(SRC, "panel_cast.png")).convert("RGB")
    # 「继续连接 192.168.31.161」按钮里的 IP（保留「继续连接」四个字）
    blur_box(im, (335, 424, 535, 490), radius=7, alpha=170)
    # 「上次连接：192.168.31.161:42171」整行
    blur_box(im, (150, 590, 660, 630), radius=7, alpha=170)
    im.save(os.path.join(OUT, "panel-cast.png"), optimize=True)
    print("  ✓ panel-cast.png（%dx%d，已遮局域网 IP）" % im.size)

    # 5) CPU 独立窗：遮住「CPU 占用进程」列表（会列出本机正在跑的 App）
    im = Image.open(os.path.join(SRC, "monitor_cpu.png")).convert("RGB")
    blur_box(im, (0, int(im.height * 0.735), im.width, int(im.height * 0.960)), radius=11, alpha=185)
    im.save(os.path.join(OUT, "popout-cpu.png"), optimize=True)
    print("  ✓ popout-cpu.png（%dx%d，已遮进程列表）" % im.size)

    # 6) 传感器独立窗
    im = Image.open(os.path.join(SRC, "monitor_sensors.png")).convert("RGB")
    im.save(os.path.join(OUT, "popout-sensors.png"), optimize=True)
    print("  ✓ popout-sensors.png（%dx%d）" % im.size)

    # 7) 标注编辑器（打开的是我们自己画的示例图片，画面全是虚构内容）
    im = Image.open(os.path.join(SRC, "annotate.png")).convert("RGB")
    if im.width > 1600:
        im = im.resize((1600, int(im.height * 1600 / im.width)), Image.LANCZOS)
    im.save(os.path.join(OUT, "annotate.png"), optimize=True)
    print("  ✓ annotate.png（%dx%d，标注编辑器）" % im.size)

    # 8) 设置窗
    im = Image.open(os.path.join(SRC, "settings.png")).convert("RGB")
    im.save(os.path.join(OUT, "settings.png"), optimize=True)
    print("  ✓ settings.png（%dx%d）" % im.size)

    print("✓ 完成")
    return 0


if __name__ == "__main__":
    sys.exit(build())
