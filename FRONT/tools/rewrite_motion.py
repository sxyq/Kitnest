#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""给官网各组件补动效，参数直接抄真机 Theme.Motion。

真机令牌（apps/FrsetNext/Sources/Core/UI/Support.swift）：
  tap        .easeOut(duration: 0.12)
  fast       .easeOut(duration: 0.16)
  page       .easeOut(duration: 0.22)
  slow       .easeOut(duration: 0.45)
  springSnappy  .spring(response: 0.22, dampingFraction: 0.85)
  spring         .spring(response: 0.28, dampingFraction: 0.86)
  springSoft     .spring(response: 0.34, dampingFraction: 0.86)
  springBouncy   .spring(response: 0.24, dampingFraction: 0.62)
  caEaseOut      cubic-bezier(0.22, 0, 0, 1)
  caEaseIn       cubic-bezier(0.42, 0, 1, 1)
  caBackOut      cubic-bezier(0.22, 1.05, 0.36, 1)   ← 入场「略冲过」
  页面切换      .transition(.opacity)
  模块切换      .transition(.opacity.combined(with: .offset(y: 8)))
"""
import io, os, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CSS = os.path.join(ROOT, 'assets', 'site.css')
JS = os.path.join(ROOT, 'assets', 'site.js')

MOTION = u'''
/* ---------- 动效体系（参数抄真机 Theme.Motion） ---------- */
/*
   tap 0.12 / fast 0.16 / page 0.22 / slow 0.45
   caEaseOut cubic-bezier(.22,0,0,1)   —— 通用出场
   caEaseIn  cubic-bezier(.42,0,1,1)   —— 收起
   caBackOut cubic-bezier(.22,1.05,.36,1) —— 入场「略冲过」
   springSoft 用 cubic-bezier(.34,1.3,.64,1) 近似 SwiftUI 的 spring(response:.34, damping:.86)
*/

:root {
  --m-tap: 0.12s;
  --m-fast: 0.16s;
  --m-page: 0.22s;
  --m-slow: 0.45s;
  --m-ease: cubic-bezier(0.22, 0, 0, 1);
  --m-ease-in: cubic-bezier(0.42, 0, 1, 1);
  --m-back: cubic-bezier(0.22, 1.05, 0.36, 1);
  --m-spring: cubic-bezier(0.34, 1.28, 0.64, 1);
}

/* 通用按钮：按下有轻微回弹（tap 0.12） */
.pm-seg,
.pm-modbar button,
.pm-ico,
.pm-dock button,
.pm-cal-nav,
.pm-cal-title,
.pm-cal-collapse,
.pm-navkeys button,
.pm-exit,
.pm-memory-cta button,
.pm-rowacts button,
.pm-searchwrap,
button {
  transition:
    transform var(--m-tap) var(--m-ease),
    background-color var(--m-fast) var(--m-ease),
    color var(--m-fast) var(--m-ease),
    opacity var(--m-fast) var(--m-ease),
    box-shadow var(--m-fast) var(--m-ease);
}
.pm-seg:active,
.pm-modbar button:active,
.pm-ico:active,
.pm-dock button:active,
.pm-cal-nav:active,
.pm-cal-collapse:active,
.pm-navkeys button:active,
button:active {
  transform: scale(0.94);
}

/* 分段切换：真机 pageSegments 选中态是 accent 胶囊 + semibold，
   切换时底色从中间「洇」开（用伪元素的 scale 模拟） */
.pm-seg { position: relative; }
.pm-seg::before {
  content: "";
  position: absolute;
  inset: 0;
  border-radius: 999px;
  background: rgba(47, 107, 255, 0.16);
  transform: scaleX(0.4) scaleY(0.6);
  opacity: 0;
  transition:
    transform var(--m-page) var(--m-back),
    opacity var(--m-fast) var(--m-ease);
  pointer-events: none;
}
.pm-seg.on::before { opacity: 1; transform: none; }
.pm-seg.on { color: var(--accent); font-weight: 600; }

/* 模块切换条（监测页）：真机 FlowHStack，选中胶囊 + 描边 */
.pm-modbar button { position: relative; }
.pm-modbar button.on {
  background: rgba(47, 107, 255, 0.18);
  box-shadow: inset 0 0 0 0.5px rgba(47, 107, 255, 0.5);
  color: var(--ink);
  font-weight: 600;
}

/* 面板内容切换：真机 .transition(.opacity)（页签）/ .opacity + .offset(y:8)（模块） */
.pm-page {
  animation: page-fade var(--m-page) var(--m-ease) both;
}
@keyframes page-fade {
  from { opacity: 0; }
  to { opacity: 1; }
}
/* 监测模块切换：真机 offset(y: 8) */
.pm-mod {
  animation: mod-slide var(--m-page) var(--m-ease) both;
}
@keyframes mod-slide {
  from { opacity: 0; transform: translateY(8px); }
  to { opacity: 1; transform: none; }
}

/* 剪贴板条目：hover 高亮 + 右侧动作图标滑入 */
.pm-item {
  transition: background-color var(--m-fast) var(--m-ease);
}
.pm-rowacts {
  opacity: 0;
  transform: translateX(6px);
  transition:
    opacity var(--m-fast) var(--m-ease),
    transform var(--m-page) var(--m-back);
}
.pm-item:hover .pm-rowacts {
  opacity: 1;
  transform: none;
}

/* 预览浮层：入场「略冲过」（caBackOut） */
.pm-preview {
  animation: preview-in var(--m-page) var(--m-back) both;
}
@keyframes preview-in {
  from { opacity: 0; transform: translateX(10px) scale(0.96); }
  to { opacity: 1; transform: none; }
}

/* 悬浮菜单 / 右键菜单：真机 NSMenu 弹出是快速淡入 + 轻微放大 */
.pm-menu {
  animation: menu-in var(--m-fast) var(--m-back) both;
}
.pm-ctx {
  animation: menu-in var(--m-fast) var(--m-back) both;
}
@keyframes menu-in {
  from { opacity: 0; transform: scale(0.96) translateY(-4px); }
  to { opacity: 1; transform: none; }
}
.pm-menu-list li,
.pm-ctx-list li {
  transition: background-color var(--m-tap) var(--m-ease), color var(--m-tap) var(--m-ease);
}

/* 日历翻页：格子里依次淡入 */
.pm-day {
  animation: day-in var(--m-fast) var(--m-ease) both;
}
@keyframes day-in {
  from { opacity: 0; transform: translateY(3px); }
  to { opacity: 1; transform: none; }
}

/* 搜索结果区：展开时从上方落下 */
.pm-results {
  animation: results-in var(--m-page) var(--m-back) both;
  transform-origin: top center;
}
@keyframes results-in {
  from { opacity: 0; transform: translateY(-6px) scaleY(0.96); }
  to { opacity: 1; transform: none; }
}

/* Toast：从下往上滑入（真机 Toast 是从底部浮起） */
.toast {
  transition:
    opacity var(--m-page) var(--m-ease),
    transform var(--m-page) var(--m-back);
}
.toast.show {
  opacity: 1;
  transform: none;
}

/* 跳转提示条：同上 */
.pm-jump-hint {
  animation: results-in var(--m-page) var(--m-back) both;
}

/* 底部胶囊：hover 时轻微上浮 */
.pm-dock {
  transition: transform var(--m-page) var(--m-back), box-shadow var(--m-page) var(--m-ease);
}
.pm-dock:hover {
  transform: translateX(-50%) translateY(-2px);
  box-shadow:
    0 16px 30px rgba(11, 11, 13, 0.2),
    inset 0 0 0 0.6px rgba(255, 255, 255, 0.6);
}

/* 环形图的进度：数值变化时平滑过渡 */
.mon-ring .ring-fg {
  transition: stroke-dashoffset var(--m-slow) var(--m-ease), stroke var(--m-page) var(--m-ease);
}

/* 曲线与构成条 */
.mon-spark polygon,
.mon-spark polyline {
  transition: opacity var(--m-page) var(--m-ease);
}
.mon-segbar i {
  transition: width var(--m-slow) var(--m-ease), background-color var(--m-page) var(--m-ease);
}
.mon-zone-bar i {
  transition: width var(--m-slow) var(--m-ease), background-color var(--m-page) var(--m-ease);
}
.mon-core-box {
  transition: background-color var(--m-page) var(--m-ease), transform var(--m-page) var(--m-back);
}
.mon-core:hover .mon-core-box { transform: scaleY(1.06); }

/* 进程行的关闭按钮：hover 才显形 */
.mon-proc-x {
  opacity: 0.35;
  transition: opacity var(--m-fast) var(--m-ease), transform var(--m-tap) var(--m-ease);
}
.mon-proc:hover .mon-proc-x { opacity: 0.9; }
.mon-proc-x:hover { transform: scale(1.15); }

/* 部件浮窗（菜单栏）：真机 popover 是快速淡入 */
.mb-pop {
  animation: menu-in var(--m-fast) var(--m-back) both;
}

/* 展示页截图切换：淡入 */
.shot-frame > div:not([hidden]) {
  animation: page-fade var(--m-page) var(--m-ease) both;
}

/* 尊重系统的「减弱动态效果」设置 */
@media (prefers-reduced-motion: reduce) {
  *, *::before, *::after {
    animation-duration: 0.01ms !important;
    animation-iteration-count: 1 !important;
    transition-duration: 0.01ms !important;
  }
}
'''

s = io.open(CSS, encoding='utf-8').read()
if '--m-back' in s:
    print('动效体系已存在，跳过')
else:
    anchor = '/* ---------- 网页版 Liquid Glass ---------- */'
    if anchor not in s:
        sys.exit('锚点没找到')
    s = s.replace(anchor, MOTION + '\n' + anchor, 1)
    io.open(CSS, 'w', encoding='utf-8').write(s)
    print('动效体系已写入 CSS，%d 行' % len(s.split('\n')))
