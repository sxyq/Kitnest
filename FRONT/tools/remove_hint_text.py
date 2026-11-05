#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""排查官网里「界面操作引导」式的说明性文字。

用户要求（2026-11-05）：「排查所有这种说明性文字」——
指的是教用户「这个界面可以点这里、悬停会出预览」这类引导语，
不是产品说明、参数、隐私条款这类实质信息。

处理原则：删掉纯操作引导；保留有信息量的参数与事实；
把「示意 / 点击后…」这类元描述改成直白的说法。
"""
import io, os, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PATH = os.path.join(ROOT, 'index.html')
s = io.open(PATH, encoding='utf-8').read()

REPL = [
    # 1) 首屏舞台提示（用户点名的那句）
    ('            <p class="stage-hint">面板可以直接点：悬停条目出预览，搜索框能过滤，页签能切换</p>\n', ''),
    # 2) 部件浮窗的「点空白处关闭」
    ('              <p class="mb-pop-note">点空白处关闭</p>\n', ''),
    # 3) 展示页 shot-points 里的操作引导
    ('                  <li><b>搜索</b>输入关键词直接过滤，输入 / 变工具启动器</li>\n', ''),
    ('                  <li><b>马赛克</b>按住涂抹即可，圈会跟着光标走</li>\n', ''),
    # 4) 元描述
    ('<p class="preview-note">标注工具条示意，分成工具区、颜色与粗细、撤销与导出三段。</p>',
     '<p class="preview-note">工具区、颜色与粗细、撤销与导出，三段排布。</p>'),
    ('<p class="preview-note">点击后先检查下载通道，再确认下载须知。</p>',
     '<p class="preview-note">下载前会先检查通道，再确认下载须知。</p>'),
    ('<p class="preview-note">更早的版本没有公开分发，不在此列出。应用内「检查更新…」看到的条目与这里同源。</p>',
     '<p class="preview-note">更早的版本没有公开分发。应用内「检查更新…」与此同源。</p>'),
    # 5) 界面页里的「图里这些条目是预先灌进去的演示数据」一类
    ('<li><b>剪贴板</b>图里是 JSON、Markdown、Swift、Python、图片和链接</li>',
     '<li><b>剪贴板</b>JSON、Markdown、Swift、Python、图片和链接</li>'),
]

hit = 0
for a, b in REPL:
    if a in s:
        s = s.replace(a, b, 1)
        hit += 1
    else:
        print('✗ 没匹配：', a.strip()[:56])

io.open(PATH, 'w', encoding='utf-8').write(s)
print('已处理 %d / %d 处' % (hit, len(REPL)))
