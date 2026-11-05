#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""v238 品牌页收口：对照 CalorieAI 品牌页补齐结构、清理说明性文案。

一次性、可复跑的改写脚本（幂等：已改过就直接跳过并报告）。做的事：
  1. 删掉 #view-showcase 里被复制进去的第二份下载区（15 个重复 DOM id 的根因）；
  2. 13 段 GIF 从 <details> 折叠里放出来，改成常驻「界面一览」；
  3. 清掉说明性 / 演示性文案；
  4. 首屏与功能区之间补信任行 + 01/13 界面演示入口；
  5. 帮助页补「初次使用」三步；页脚补收尾 CTA；
  6. 版本行默认态不再写死过期数值。
"""
import re
import sys
from collections import Counter
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
HTML = ROOT / 'FRONT' / 'index.html'


def rep(text, old, new, label, required=True):
    if old not in text:
        if new in text:
            print('  · 已完成  %s' % label)
            return text
        if required:
            raise SystemExit('✗ 找不到改写锚点：' + label)
        return text
    print('  ✓ %s' % label)
    return text.replace(old, new, 1)


def main():
    text = HTML.read_text(encoding='utf-8')
    original = text

    # ---- 1. 删除界面页里重复的下载 section（按行界，前后各校验一行） ----
    lines = text.splitlines(keepends=True)
    if 'id="view-download"' in text and lines[657].strip() == '<div class="section">':
        assert lines[731].strip() == '</div>', lines[731]
        assert lines[732].strip() == '</section>', lines[732]
        assert 'Download' in ''.join(lines[658:664]), '删除区间不含下载标题'
        del lines[657:732]
        text = ''.join(lines)
        print('  ✓ 删除界面页内重复的下载 section（75 行）')
    else:
        print('  · 已完成  重复下载区已删除')

    text = rep(text,
               '<!-- ======================= 更新记录 ======================= -->\n    <section class="view" id="view-download">',
               '<!-- ======================= 下载 ======================= -->\n    <section class="view" id="view-download">',
               '修正下载视图上方错误的章节注释')

    # ---- 2. 13 段 GIF 全部显式展示 ----
    text = rep(text,
               '          <details class="more-shots">\n'
               '            <summary>更多实机截图</summary>\n'
               '            <div class="more-shots-grid">',
               '          <div class="shot-gallery" data-reveal>\n'
               '            <div class="gallery-head">\n'
               '              <span class="kicker">Interface</span>\n'
               '              <h3>界面一览</h3>\n'
               '              <p class="lede">主面板、监测页、文件中转、投屏、标注编辑器、CPU 详情窗与设置窗口。</p>\n'
               '            </div>\n'
               '            <div class="more-shots-grid">',
               '折叠区改成常驻「界面一览」')
    text = rep(text,
               '            </div>\n          </details>',
               '            </div>\n          </div>',
               '闭合 shot-gallery')

    # ---- 3. 说明性 / 演示性文案 ----
    text = rep(text,
               '<p class="lede">六个功能，各有一段真实操作动图。点标签切换。</p>',
               '<p class="lede">从主面板、监测页到设置窗口，界面按最新版整理。</p>',
               '界面页导语去掉「点标签切换」')
    text = rep(text,
               '              <p class="preview-note">工具区、颜色与粗细、撤销与导出，三段排布。</p>\n',
               '',
               '删掉工具条排版的说明文字')
    text = rep(text,
               '<figcaption>完整流程动图：⌥S 框选 → 动作条 → 标注 → 复制。画面为模拟内容，不含任何真实数据。</figcaption>',
               '<figcaption>⌥S 框选 → 动作条 → 标注 → 复制。</figcaption>',
               '删掉「画面为模拟内容」自述')
    text = rep(text,
               '<figcaption>设置里能调面板分段（主页 / 监测 / 中转 / 投屏），剪贴板保留期和部件样式也能改，更新源同样在这里。</figcaption>',
               '<figcaption>面板分段、剪贴板保留期、部件样式与更新源。</figcaption>',
               '设置窗口图注改成产品陈述')
    text = rep(text,
               '<p class="preview-note" id="dlButtonHint">下载前会先检查通道，再确认下载须知。</p>',
               '<p class="preview-note" id="dlButtonHint">官方发布源 · SHA-256 校验</p>',
               '下载提示改成客观规格')

    # ---- 4. 版本行不再写死过期数值 ----
    text = rep(text,
               '<span id="heroVersionText">v1.0.0 · 安装包约 40 MiB</span>',
               '<span id="heroVersionText">正在读取版本信息…</span>',
               '版本行默认态改为读取中')

    # ---- 5. 首屏与功能区之间的品牌衔接 ----
    bridge = '''      <!-- v238：首屏与功能区之间的品牌衔接（信任行 + 界面演示入口） -->
      <div class="hero-bridge" data-reveal>
        <div class="wrap">
          <div class="bridge-trust">
            <span>无账号</span><span>无埋点统计</span><span>数据留在本机</span>
            <span>SHA-256 校验</span><span>独立分发</span>
          </div>
          <a class="bridge-demo" href="#showcase" data-nav>
            <div class="bridge-demo-copy">
              <span class="bridge-no">01 / 13</span>
              <h3>主面板 · 剪贴板历史</h3>
              <p>复制过的文字、图片、文件和链接，都留在这里。</p>
              <span class="bridge-go">看全部界面 →</span>
            </div>
            <div class="bridge-demo-shot">
              <img src="assets/gifs/demo-view-panel.gif" alt="主面板 操作演示动图" loading="lazy">
            </div>
          </a>
        </div>
      </div>

'''
    anchor = ('      <div class="section">\n        <div class="wrap">\n'
              '          <div class="section-head" data-reveal>\n'
              '            <span class="kicker">One icon, six jobs</span>')
    if 'class="hero-bridge"' not in text:
        text = rep(text, anchor, bridge + anchor, '首屏下方补信任行 + 01/13 界面入口')
    else:
        print('  · 已完成  首屏衔接区已存在')

    # ---- 6. 帮助页上手指南 ----
    onboard = '''          <div class="onboard" data-reveal>
            <span class="kicker">Getting started</span>
            <h3>装好之后的三分钟</h3>
            <ol class="onboard-steps">
              <li><b>授权</b><span>欢迎窗里点「权限引导」，勾上屏幕录制与辅助功能。</span></li>
              <li><b>呼出</b><span>按 <kbd>⌥A</kbd> 打开主面板；复制任意一段文字，它已经在列表里。</span></li>
              <li><b>按需打开</b><span>在设置里决定哪些分段常驻、菜单栏显示哪几个部件。</span></li>
            </ol>
          </div>

'''
    if 'class="onboard"' not in text:
        text = rep(text, '          <div class="help-grid">', onboard + '          <div class="help-grid">',
                   '帮助页补「初次使用」三步')
    else:
        print('  · 已完成  上手指南已存在')

    # ---- 7. 页脚收尾 CTA ----
    footer_cta = '''      <div class="footer-cta">
        <div>
          <h3>一个图标，六件事。</h3>
          <p>macOS 13+ · Apple Silicon / Intel · 独立分发</p>
        </div>
        <a class="btn btn-primary" href="#download" data-nav>下载 for macOS →</a>
      </div>
'''
    if 'class="footer-cta"' not in text:
        text = rep(text, '      <div class="footer-bottom">', footer_cta + '      <div class="footer-bottom">',
                   '页脚补下载 CTA')
    else:
        print('  · 已完成  页脚 CTA 已存在')

    if text == original:
        print('\n（无需改动）')
        return 0
    HTML.write_text(text, encoding='utf-8')

    # ---- 校验 ----
    ids = re.findall(r'\bid="([^"]+)"', text)
    dup = [(k, v) for k, v in Counter(ids).items() if v > 1]
    gifs = sorted(set(re.findall(r'assets/gifs/(demo-[\w-]+\.gif)', text)))
    banned = ['模拟内容', '点标签切换', '更多实机截图', '画面为', '演示用', '假数据', '示例截图']
    left = [w for w in banned if w in text]
    print('\n  DOM id %d 个，重复 %d 个 %s' % (len(ids), len(dup), dup[:5]))
    print('  引用 GIF %d 段：%s' % (len(gifs), ', '.join(gifs)))
    print('  残留 <details> %d 个 / 说明性文案 %s' % (text.count('<details'), left or '无'))
    print('  #view-download 出现 %d 次 / Download kicker 出现 %d 次' %
          (text.count('id="view-download"'), text.count('<span class="kicker">Download</span>')))
    if dup or len(gifs) != 13 or left or text.count('<details') != 0:
        raise SystemExit('✗ 校验未通过')
    print('\n✓ v238 品牌页结构改写完成')
    return 0


if __name__ == '__main__':
    sys.exit(main())
