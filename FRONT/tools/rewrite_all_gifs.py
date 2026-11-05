#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""v237：官网「更多实机截图」与设置窗口的 7 张静态图统一换成演示 GIF。

六个功能演示 + 主面板演示 = 7 段真实 DOM 交互 GIF；
监测 / 中转 / 投屏 / 标注 / CPU 独立窗 / 设置 = 6 段最新真机界面导览 GIF。
"""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
HTML = ROOT / 'FRONT' / 'index.html'

PAIRS = [
    ('<img src="assets/shots/panel.png" alt="主面板实机截图" loading="lazy">',
     '<img src="assets/gifs/demo-view-panel.gif" alt="主面板 操作演示动图" loading="lazy">'),
    ('<img src="assets/shots/panel-performance.png" alt="监测页实机截图" loading="lazy">',
     '<img src="assets/gifs/demo-view-monitor.gif" alt="监测页 操作演示动图" loading="lazy">'),
    ('<img src="assets/shots/panel-transfer.png" alt="文件中转实机截图" loading="lazy">',
     '<img src="assets/gifs/demo-view-transfer.gif" alt="文件中转 操作演示动图" loading="lazy">'),
    ('<img src="assets/shots/panel-cast.png" alt="投屏实机截图" loading="lazy">',
     '<img src="assets/gifs/demo-view-cast.gif" alt="投屏 操作演示动图" loading="lazy">'),
    ('<img src="assets/shots/annotate.png" alt="标注编辑器实机截图" loading="lazy">',
     '<img src="assets/gifs/demo-view-annotate.gif" alt="标注编辑器 操作演示动图" loading="lazy">'),
    ('<img src="assets/shots/popout-cpu.png" alt="CPU 详情窗实机截图" loading="lazy">',
     '<img src="assets/gifs/demo-view-popout.gif" alt="CPU 详情窗 操作演示动图" loading="lazy">'),
    ('<img src="assets/shots/settings.png" alt="Kitnest 设置窗口实机截图" data-shot-file="assets/shots/settings.png">',
     '<img src="assets/gifs/demo-view-settings.gif" alt="Kitnest 设置窗口 操作演示动图" data-shot-file="assets/gifs/demo-view-settings.gif">'),
]


def main():
    text = HTML.read_text()
    for old, new in PAIRS:
        n = text.count(old)
        if n != 1:
            raise SystemExit('替换目标不唯一（%d 处）：%s' % (n, old[:70]))
        text = text.replace(old, new)
    HTML.write_text(text)
    print('✓ 7 张静态界面图已换成 GIF')
    left = [k for k in ('shots/panel.png', 'shots/panel-performance.png',
                        'shots/panel-transfer.png', 'shots/panel-cast.png',
                        'shots/annotate.png', 'shots/popout-cpu.png',
                        'shots/settings.png') if k in text]
    print('  残留静态引用：', left or '无')


if __name__ == '__main__':
    main()
