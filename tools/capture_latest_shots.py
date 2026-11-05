#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""抓取最新版 Kitnest 真机界面 → 脱敏 → 官网 shots/（v236 / 2026-11-06）。

流程：
  1. 完整备份系统剪贴板（含多格式图片），见 pasteboard_backup.swift；
  2. 临时把主面板置顶（panel.pinned），否则 App 失焦收起、只能抓到 alpha=0 的白窗；
  3. 灌 6 条与官网一致的演示文本，让剪贴板列表顶部不出现真实内容；
  4. shotkit.swift 按窗口抓 6 张（面板 3 页签 + 标注 / CPU 独立窗 / 设置）；
  5. 按区域裁切 / 遮罩脱敏，写 FRONT/assets/shots/；
  6. 还原系统剪贴板与 panel.pinned 原值。

v237：主面板（home）不再抓静态真机图。剪贴板列表即使灌了演示文本，
App 仍会把更早的真实截图 / 图片 / 链接排在前面，区域遮罩挡不干净。
官网主面板改由 record_demos.mjs 录真实 DOM 交互帧（demo-view-panel.gif），
既和 App 1:1，也不会把真实剪贴板内容带进公开素材。shots/ 只作本地
重建 GIF 的源素材，部署时整个目录被排除，不上线。

用法：python3 tools/capture_latest_shots.py
"""
import os
import subprocess
import sys
import time
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter

ROOT = Path(__file__).resolve().parents[1]
FRONT = ROOT / 'FRONT'
OUT = FRONT / 'assets' / 'shots'
RAW = Path('/tmp/kitnest-latest-raw')
PB = Path('/tmp/kitnest-pb-backup')
SHOTKIT = ROOT / 'tools' / 'shotkit.swift'
PBKIT = ROOT / 'tools' / 'pasteboard_backup.swift'
BUNDLE = 'com.sxyq.frsetnext'

# 与 FRONT/assets/site.js 的 CLIP_ITEMS 同源，截出来才和官网可交互面板一致
FAKE = [
    'https://calorieai.sxyq27.online/kitnest-site/',
    '周报草稿：第三部分的发布流程还需要补充回滚说明。',
    '# Kitnest 发布检查清单\n\n## 发版前\n- 跑 `bash tools/check.sh`\n- 构建并签名，记录 build 号与包体大小\n- 计算 SHA-256，写进 stable/latest.json',
    '{\n  "name": "kitnest.config.json",\n  "app": "kitnest",\n  "version": "1.0.0",\n  "features": {\n    "clipboard": { "keepDays": 30 },\n    "monitor": { "refreshSeconds": 1.5 }\n  }\n}',
    '// ClipGroup.swift\nimport Foundation\n\n/// 把剪贴板条目按类型分组\nstruct ClipItem {\n    let kind: String\n    let title: String\n}',
    '# verify_sha.py\nimport hashlib\n\ndef sha256(path: str) -> str:\n    h = hashlib.sha256()\n    with open(path, "rb") as f:\n        for chunk in iter(lambda: f.read(65536), b""):\n            h.update(chunk)\n    return h.hexdigest()',
]

JOBS = [
    ('panel_perf', 'kitnest://panel?page=performance', ''),
    ('panel_transfer', 'kitnest://panel?page=transfer', ''),
    ('panel_cast', 'kitnest://panel?page=cast', ''),
    ('monitor_cpu', 'kitnest://monitor?module=cpu', '性能监测'),
    ('annotate', 'kitnest://annotate?demo=1', '标注截图'),
    ('settings', 'kitnest://settings?pane=general', '设置'),
]


def run(cmd, **kw):
    return subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True, **kw)


def defaults(*args):
    run(['defaults', *args])


def shoot(name, link, title, settle='1.0', retries=3):
    out = RAW / (name + '.png')
    for i in range(retries):
        r = run(['swift', str(SHOTKIT), str(out), link, title, settle])
        if out.exists() and out.stat().st_size > 50000:
            print('  ✓ %-16s %6d KB  %s' % (name, out.stat().st_size // 1024,
                                            r.stdout.strip().split('文件=')[-1]))
            return out
        print('  ! %s 第 %d 次失败：%s' % (name, i + 1,
              (r.stdout + r.stderr).strip().splitlines()[-1][:110]))
        time.sleep(0.8)
    raise SystemExit('抓取失败：' + name)


def blur_box(img, box, radius=9, alpha=200):
    x0, y0, x1, y1 = [int(v) for v in box]
    x0, y0 = max(0, x0), max(0, y0)
    x1, y1 = min(img.width, x1), min(img.height, y1)
    if x1 - x0 < 4 or y1 - y0 < 4:
        return
    region = img.crop((x0, y0, x1, y1)).filter(ImageFilter.GaussianBlur(radius=radius))
    mask = Image.new('L', region.size, alpha)
    white = Image.new('RGB', region.size, (255, 255, 255))
    img.paste(Image.composite(white, region, mask), (x0, y0))


def cover_box(img, box, sample):
    """用相邻区域的实色盖住隐私文字：比白模糊更贴合原界面（不会在蓝按钮上糊一块白）。"""
    x0, y0, x1, y1 = [int(v) for v in box]
    color = img.getpixel((int(sample[0] * img.width), int(sample[1] * img.height)))
    ImageDraw.Draw(img).rectangle((x0, y0, x1, y1), fill=color)


def trim_dark_edges(img):
    """窗口抓图偶发右侧一条未渲染的黑边（整窗合成还没收敛），裁掉它。"""
    w, h = img.size
    gray = img.convert('L')
    for x in range(w - 1, w - int(w * 0.15), -1):
        col = [gray.getpixel((x, y)) for y in range(0, h, max(1, h // 200))]
        if sum(1 for v in col if v < 25) / len(col) < 0.9:
            return img.crop((0, 0, x + 1, h))
    return img


def save(img, name):
    img = trim_dark_edges(img)
    img.save(OUT / name, optimize=True)
    print('  → shots/%s %dx%d' % (name, img.width, img.height))


def redact(raw):
    print('== 脱敏并写入官网 ==')
    OUT.mkdir(parents=True, exist_ok=True)

    # 主面板 home 不落盘：真实剪贴板内容无法可靠脱敏，见文件头 v237 说明
    save(Image.open(raw['panel_perf']).convert('RGB'), 'panel-performance.png')

    # 文件中转：下方「本地暂存」是真实文件名，裁掉
    im = Image.open(raw['panel_transfer']).convert('RGB')
    save(im.crop((0, 0, im.width, int(im.height * 0.335))), 'panel-transfer.png')

    # 投屏：按钮里的局域网 IP + 「上次连接」整行（用按钮蓝 / 页面灰实色盖，不留白块）
    im = Image.open(raw['panel_cast']).convert('RGB')
    w, h = im.size
    cover_box(im, (w * 0.468, h * 0.339, w * 0.747, h * 0.391), (0.25, 0.365))
    cover_box(im, (w * 0.210, h * 0.471, w * 0.922, h * 0.503), (0.50, 0.525))
    save(im, 'panel-cast.png')

    # CPU 独立窗：下方进程榜会列出本机正在跑的 App
    im = Image.open(raw['monitor_cpu']).convert('RGB')
    blur_box(im, (0, im.height * 0.735, im.width, im.height * 0.960), radius=11, alpha=185)
    save(im, 'popout-cpu.png')

    # 标注编辑器打开的是演示图，缩小到 1600 宽
    im = Image.open(raw['annotate']).convert('RGB')
    if im.width > 1600:
        im = im.resize((1600, round(im.height * 1600 / im.width)), Image.LANCZOS)
    save(im, 'annotate.png')

    save(Image.open(raw['settings']).convert('RGB'), 'settings.png')


def main():
    RAW.mkdir(parents=True, exist_ok=True)
    print('== 1/5 备份系统剪贴板 ==')
    r = run(['swift', str(PBKIT), 'save', str(PB)])
    print(' ', (r.stdout + r.stderr).strip()[:160])
    if not (PB / 'meta.json').exists():
        raise SystemExit('剪贴板备份失败，终止（不改用户剪贴板）')

    print('== 2/5 临时置顶主面板 ==')
    defaults('write', BUNDLE, 'panel.pinned', '-bool', 'YES')

    try:
        print('== 3/5 灌入 6 条演示文本（每条等 2.2s 让轮询吃到）==')
        for i, text in enumerate(FAKE, 1):
            subprocess.run(['pbcopy'], input=text.encode('utf-8'))
            time.sleep(2.2)
            print('  %d/6' % i)

        print('== 4/5 按窗口抓 6 张最新真机界面 ==')
        raw = {}
        for name, link, title in JOBS:
            raw[name] = shoot(name, link, title)
        redact(raw)
    finally:
        print('== 5/5 还原剪贴板与置顶设置 ==')
        r = run(['swift', str(PBKIT), 'restore', str(PB)])
        print(' ', (r.stdout + r.stderr).strip()[:160])
        defaults('delete', BUNDLE, 'panel.pinned')
    print('✓ 完成')
    return 0


if __name__ == '__main__':
    sys.exit(main())
