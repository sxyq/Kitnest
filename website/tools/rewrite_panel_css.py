#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""把官网 mock 主面板的 CSS 重写成与真机 PanelRootView 对齐的版本。

真机依据（apps/FrsetNext/Sources）：
  PanelRootView.toolbar          顶部工具条 40pt，左右 padding 14，图标 22×22，间距 12
  PanelRootView.segmentItem      分段字号 11，选中 accent 0.16 胶囊，内边距 9/3
  ClipboardSectionView           主页顺序 = 搜索 → 日历 → 剪贴板列表
  CalendarSectionView            白玻璃卡圆角 14，标题 14 semibold，日期 14/农历 11，今天 32×32 胶囊
  ClipboardRow                   缩略图 + 来源徽章 16×16，标题 13，副行 11，分隔线内缩 14/10
  PanelRootView.bottomToolbar    底部胶囊浮在列表底部居中，padding 12/7，5 个图标位
  PanelRootView.pageSegments     分段顺序 = 主页 / 监测 / 中转 / 投屏
"""
import io, os, re, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PATH = os.path.join(ROOT, 'assets', 'site.css')

s = io.open(PATH, encoding='utf-8').read()

# 旧块起点：.pm-tabs 开头；终点：模拟界面（更新提示）注释之前
start = s.find('.pm-tabs {')
end = s.find('/* ---------- 模拟界面（更新提示） ---------- */')
if start < 0 or end < 0 or end < start:
    sys.exit('锚点没找到 start=%d end=%d' % (start, end))

NEW = u'''/* ---------- 主面板 mock（按真机 PanelRootView 1:1） ---------- */
/* 尺寸依据真机：面板 400pt 宽（窄屏 320），顶部工具条 40pt，日历卡圆角 14，
   剪贴板行 58pt（标准密度），底部胶囊 padding 12/7。网页按 1/1.16 缩放呈现。 */

.pm-bar {
  display: flex;
  align-items: center;
  gap: 8px;
  padding: 0 14px;
  height: 40px;
  flex: 0 0 auto;
}
.pm-bar-left { display: flex; align-items: center; gap: 12px; }
.pm-ico {
  width: 22px;
  height: 22px;
  display: inline-flex;
  align-items: center;
  justify-content: center;
  border: none;
  background: none;
  padding: 0;
  cursor: pointer;
  color: var(--ink-3);
  border-radius: 6px;
  transition: color 0.12s ease, background 0.12s ease;
}
.pm-ico svg { width: 15px; height: 15px; }
.pm-ico:hover { color: var(--ink); background: rgba(0, 0, 0, 0.045); }

/* 分段：真机 segmentItem —— 11px 字号，选中 accent 胶囊（0.16） */
.pm-segs {
  display: flex;
  align-items: center;
  gap: 0;
  margin: 0 auto;
  padding: 0 14px;
  min-width: 0;
}
.pm-seg {
  border: none;
  background: none;
  cursor: pointer;
  padding: 3px 9px;
  border-radius: 999px;
  font-size: 11px;
  line-height: 1.4;
  color: var(--ink-3);
  white-space: nowrap;
  transition: background 0.14s ease, color 0.14s ease;
}
.pm-seg:hover { color: var(--ink-2); }
.pm-seg.on {
  background: rgba(47, 107, 255, 0.16);
  color: var(--accent);
  font-weight: 600;
}

/* 搜索区段（真机 SearchSectionView） */
.pm-searchwrap {
  flex: 0 0 auto;
  padding: 2px 14px 0;
  position: relative;
}
.pm-search {
  display: flex;
  align-items: center;
  gap: 8px;
  padding: 7px 10px;
  border-radius: 8px;
  background: rgba(255, 255, 255, 0.62);
  border: 0.5px solid rgba(0, 0, 0, 0.055);
  box-shadow: inset 0 0.5px 0 rgba(255, 255, 255, 0.6);
}
.pm-search:focus-within {
  background: rgba(255, 255, 255, 0.86);
  border-color: rgba(47, 107, 255, 0.28);
}
.pm-search svg { width: 14px; height: 14px; color: var(--ink-3); flex: 0 0 auto; }
.pm-search input {
  flex: 1;
  min-width: 0;
  border: none;
  background: none;
  outline: none;
  font-size: 12.5px;
  color: var(--ink);
  font-family: inherit;
}
.pm-search input::placeholder { color: var(--ink-3); }
.pm-slash {
  flex: 0 0 auto;
  font-size: 10.5px;
  color: var(--ink-3);
  background: rgba(0, 0, 0, 0.05);
  border-radius: 4px;
  padding: 1px 5px;
  font-family: var(--mono);
}

/* 搜索结果区（真机：输入关键词后才展开） */
.pm-results {
  margin-top: 6px;
  border-radius: 10px;
  background: rgba(255, 255, 255, 0.72);
  border: 0.5px solid rgba(0, 0, 0, 0.055);
  overflow: hidden;
}
.pm-results ul { list-style: none; }
.pm-results li {
  display: flex;
  gap: 8px;
  align-items: center;
  padding: 7px 10px;
  font-size: 12px;
  cursor: pointer;
  border-bottom: 0.5px solid rgba(0, 0, 0, 0.05);
}
.pm-results li:last-child { border-bottom: none; }
.pm-results li:hover { background: rgba(47, 107, 255, 0.07); }
.pm-results li b { font-weight: 550; color: var(--ink); }
.pm-results li span { font-size: 10.5px; color: var(--ink-3); margin-left: auto; }
.pm-results .r-kind {
  flex: 0 0 auto;
  width: 20px;
  height: 20px;
  border-radius: 6px;
  background: rgba(0, 0, 0, 0.05);
  color: var(--ink-3);
  display: flex;
  align-items: center;
  justify-content: center;
  font-size: 9.5px;
}
.pm-results .r-kind.code { background: #EAF1FF; color: #2F6BFF; }
.pm-results .r-kind.md { background: #EAF7F0; color: #1F9D63; }
.pm-results .r-kind.json { background: #F3EEFF; color: #7A5AF8; }
.pm-results .r-kind.img { background: #FFF2E4; color: #D97706; }
.pm-results .r-kind.url { background: #E8F6FB; color: #0284C7; }

.pm-body {
  position: relative;
  flex: 1;
  min-height: 0;
  overflow-y: auto;
  overflow-x: hidden;
  padding: 0 0 52px;
}
.pm-body::-webkit-scrollbar { width: 6px; }
.pm-body::-webkit-scrollbar-thumb { background: rgba(0, 0, 0, 0.12); border-radius: 3px; }
.pm-page { padding: 0 0 6px; }

/* ---------- 日历卡（真机 CalendarSectionView） ---------- */
.pm-cal {
  margin: 12px 8px 0;
  border-radius: 14px;
  padding: 10px;
  background: rgba(255, 255, 255, 0.787);
  border: 0.5px solid rgba(0, 0, 0, 0.062);
  box-shadow: inset 0 0.5px 0 rgba(255, 255, 255, 0.7);
}
.pm-cal-head {
  display: flex;
  align-items: center;
  gap: 8px;
  margin-bottom: 8px;
}
.pm-cal-nav {
  width: 18px;
  height: 18px;
  display: inline-flex;
  align-items: center;
  justify-content: center;
  border: none;
  background: none;
  padding: 0;
  cursor: pointer;
  color: var(--ink-3);
  border-radius: 4px;
}
.pm-cal-nav svg { width: 12px; height: 12px; }
.pm-cal-nav:hover { color: var(--ink); background: rgba(0, 0, 0, 0.045); }
.pm-cal-title {
  border: none;
  background: none;
  padding: 0;
  cursor: pointer;
  font-size: 14px;
  font-weight: 600;
  color: var(--ink);
  min-width: 92px;
  text-align: left;
  font-family: inherit;
}
.pm-cal-title:hover { color: var(--accent); }
.pm-cal-collapse {
  margin-left: auto;
  width: 18px;
  height: 18px;
  display: inline-flex;
  align-items: center;
  justify-content: center;
  border: none;
  background: none;
  padding: 0;
  cursor: pointer;
  color: var(--ink-3);
  border-radius: 4px;
}
.pm-cal-collapse svg { width: 12px; height: 12px; }
.pm-cal-collapse:hover { color: var(--ink); background: rgba(0, 0, 0, 0.045); }
.pm-cal.folded .pm-cal-week,
.pm-cal.folded .pm-cal-grid { display: none; }

.pm-cal-week,
.pm-cal-grid {
  display: grid;
  grid-template-columns: repeat(7, 1fr);
  text-align: center;
}
.pm-cal-week { margin-bottom: 2px; }
.pm-cal-week span { font-size: 10.5px; color: var(--ink-3); }
.pm-cal-grid { row-gap: 1px; }
.pm-day {
  height: 34px;
  display: flex;
  flex-direction: column;
  align-items: center;
  justify-content: center;
  gap: 0;
  cursor: pointer;
  border: none;
  background: none;
  padding: 0;
  font-family: inherit;
}
.pm-day b {
  font-size: 14px;
  font-weight: 400;
  color: var(--ink);
  line-height: 18px;
  height: 18px;
  display: flex;
  align-items: center;
}
.pm-day span {
  font-size: 11px;
  color: var(--ink-3);
  line-height: 12px;
  height: 12px;
  display: flex;
  align-items: center;
}
.pm-day.muted b { color: #C9C9D2; }
.pm-day.festival span { color: #E8833A; }
.pm-day.today b { color: #FFFFFF; font-weight: 600; }
.pm-day.today span { color: rgba(255, 255, 255, 0.92); }
.pm-day.today .pm-day-in {
  width: 32px;
  height: 32px;
  border-radius: 8px;
  background: var(--accent);
  display: flex;
  flex-direction: column;
  align-items: center;
  justify-content: center;
}
.pm-day.sel .pm-day-in {
  width: 32px;
  height: 32px;
  border-radius: 8px;
  border: 1.5px solid rgba(47, 107, 255, 0.55);
  display: flex;
  flex-direction: column;
  align-items: center;
  justify-content: center;
}

/* ---------- 剪贴板行（真机 ClipboardRow） ---------- */
.pm-list { list-style: none; }
.pm-item {
  display: flex;
  align-items: center;
  gap: 12px;
  padding: 6px 14px;
  min-height: 58px;
  position: relative;
  cursor: default;
  border-radius: 8px;
  margin: 0 6px;
  transition: background 0.12s ease;
}
.pm-item:hover { background: rgba(0, 0, 0, 0.035); }
.pm-item.sel { background: rgba(47, 107, 255, 0.09); }
.pm-item::after {
  content: "";
  position: absolute;
  left: 14px;
  right: 10px;
  bottom: 0;
  height: 0.5px;
  background: rgba(0, 0, 0, 0.07);
}
.pm-item:last-child::after { display: none; }

/* 缩略图：真机 50pt（密度档位 32/40/52），圆角 8 */
.pm-thumb {
  position: relative;
  flex: 0 0 auto;
  width: 50px;
  height: 50px;
  border-radius: 8px;
  background: rgba(255, 255, 255, 0.9);
  border: 0.5px solid rgba(0, 0, 0, 0.05);
  display: flex;
  align-items: center;
  justify-content: center;
  color: var(--ink-3);
  overflow: visible;
}
.pm-thumb svg { width: 22px; height: 22px; }
.pm-thumb.img {
  background:
    linear-gradient(135deg, rgba(122, 90, 248, 0.16), rgba(47, 107, 255, 0.14)),
    rgba(255, 255, 255, 0.92);
  color: #7A5AF8;
}
.pm-thumb.code { background: rgba(234, 241, 255, 0.9); color: #2F6BFF; }
.pm-thumb.json { background: rgba(243, 238, 255, 0.9); color: #7A5AF8; }
.pm-thumb.md { background: rgba(234, 247, 240, 0.9); color: #1F9D63; }
.pm-thumb.url { background: rgba(232, 246, 251, 0.9); color: #0284C7; }
.pm-thumb.file { background: rgba(255, 242, 228, 0.9); color: #D97706; }

/* 来源应用徽章：真机 16×16，贴右下角，偏移 3/3 */
.pm-badge {
  position: absolute;
  right: -3px;
  bottom: -3px;
  width: 16px;
  height: 16px;
  border-radius: 5px;
  display: flex;
  align-items: center;
  justify-content: center;
  font-size: 8.5px;
  font-weight: 600;
  color: #FFFFFF;
  border: 0.75px solid rgba(255, 255, 255, 0.85);
  box-shadow: 0 1.5px 3px rgba(0, 0, 0, 0.18);
}
.pm-badge.chrome { background: #4285F4; }
.pm-badge.code { background: #2F6BFF; }
.pm-badge.md { background: #1F9D63; }
.pm-badge.json { background: #7A5AF8; }
.pm-badge.img { background: #D97706; }
.pm-badge.url { background: #0284C7; }

.pm-main { min-width: 0; flex: 1; }
.pm-title {
  display: block;
  font-size: 13px;
  color: var(--ink);
  line-height: 1.3;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}
.pm-meta {
  display: block;
  font-size: 11px;
  color: var(--ink-3);
  margin-top: 3px;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}

/* hover 时右侧两个动作：↓ 复制 / ↵ 复制并粘贴（真机行为） */
.pm-rowacts {
  flex: 0 0 auto;
  display: none;
  align-items: center;
  gap: 10px;
}
.pm-item:hover .pm-rowacts { display: flex; }
.pm-rowacts button {
  width: 20px;
  height: 20px;
  border: none;
  background: none;
  padding: 0;
  cursor: pointer;
  color: var(--ink-3);
  border-radius: 5px;
  display: inline-flex;
  align-items: center;
  justify-content: center;
}
.pm-rowacts button svg { width: 13px; height: 13px; }
.pm-rowacts button:hover { color: var(--accent); background: rgba(47, 107, 255, 0.1); }

/* ---------- 底部悬浮工具条（真机 bottomToolbar：胶囊浮在底部居中） ---------- */
.pm-dock {
  position: absolute;
  left: 50%;
  bottom: 14px;
  transform: translateX(-50%);
  display: flex;
  align-items: center;
  gap: 5px;
  padding: 7px 12px;
  border-radius: 999px;
  background: rgba(252, 252, 253, 0.86);
  -webkit-backdrop-filter: blur(20px) saturate(1.8);
  backdrop-filter: blur(20px) saturate(1.8);
  box-shadow:
    0 12px 24px rgba(11, 11, 13, 0.18),
    inset 0 0 0 0.6px rgba(255, 255, 255, 0.55);
  z-index: 5;
}
.pm-dock button {
  width: 26px;
  height: 26px;
  border: none;
  background: none;
  padding: 0;
  cursor: pointer;
  color: var(--ink-3);
  border-radius: 50%;
  display: inline-flex;
  align-items: center;
  justify-content: center;
  transition: color 0.12s ease, background 0.12s ease;
}
.pm-dock button svg { width: 14px; height: 14px; }
.pm-dock button:hover { color: var(--ink); background: rgba(0, 0, 0, 0.05); }
.pm-dock button.active { color: var(--accent); }

/* ---------- 预览浮层（真机 MainPanelPreviewPopover：无标题栏，移出即关） ---------- */
.pm-preview {
  position: absolute;
  left: 10px;
  right: 10px;
  z-index: 8;
  border-radius: 10px;
  padding: 11px 12px;
  background: rgba(252, 252, 253, 0.95);
  -webkit-backdrop-filter: blur(26px) saturate(1.9);
  backdrop-filter: blur(26px) saturate(1.9);
  box-shadow:
    0 18px 44px rgba(11, 11, 13, 0.2),
    0 2px 6px rgba(11, 11, 13, 0.1),
    inset 0 0 0 0.5px rgba(0, 0, 0, 0.07),
    inset 0 0.5px 0 0 rgba(255, 255, 255, 0.72);
  animation: preview-in 0.18s cubic-bezier(0.22, 0, 0, 1) both;
  max-height: 240px;
  overflow: auto;
}
@keyframes preview-in {
  from { opacity: 0; transform: translateY(-4px) scale(0.985); }
  to { opacity: 1; transform: none; }
}
.pm-preview-body { font-size: 11.8px; line-height: 1.62; color: var(--ink-2); }
.pm-preview-body code {
  font-family: var(--mono);
  font-size: 11px;
  background: rgba(0, 0, 0, 0.05);
  padding: 1px 5px;
  border-radius: 4px;
}
.pm-preview-body pre {
  margin: 0;
  font-family: var(--mono);
  font-size: 10.5px;
  line-height: 1.55;
  white-space: pre-wrap;
  word-break: break-all;
  color: var(--ink-2);
}
.pm-preview-body .pv-kind {
  display: inline-block;
  font-size: 9.5px;
  letter-spacing: 0.04em;
  color: var(--ink-3);
  border: 0.5px solid rgba(0, 0, 0, 0.08);
  border-radius: 4px;
  padding: 0 4px;
  margin-bottom: 5px;
}

/* ---------- 悬浮菜单（真机 NSMenu） ---------- */
.pm-menu {
  position: absolute;
  z-index: 20;
  min-width: 172px;
  border-radius: 8px;
  padding: 4px;
  background: rgba(252, 252, 253, 0.96);
  -webkit-backdrop-filter: blur(24px) saturate(1.8);
  backdrop-filter: blur(24px) saturate(1.8);
  box-shadow:
    0 14px 36px rgba(11, 11, 13, 0.2),
    inset 0 0 0 0.5px rgba(0, 0, 0, 0.08);
  animation: preview-in 0.13s cubic-bezier(0.22, 0, 0, 1) both;
}
.pm-menu-list, .pm-ctx-list { list-style: none; }
.pm-menu-list li, .pm-ctx-list li {
  display: flex;
  align-items: center;
  gap: 8px;
  padding: 4px 8px;
  border-radius: 5px;
  font-size: 12px;
  color: var(--ink);
  cursor: default;
  white-space: nowrap;
}
.pm-menu-list li:hover, .pm-ctx-list li:hover { background: var(--accent); color: #FFFFFF; }
.pm-menu-list li.dis, .pm-ctx-list li.dis { color: var(--ink-3); pointer-events: none; }
.pm-menu-list li.dis:hover, .pm-ctx-list li.dis:hover { background: none; color: var(--ink-3); }
.pm-menu-list li.sep, .pm-ctx-list li.sep {
  height: 0.5px;
  padding: 0;
  margin: 4px 6px;
  background: rgba(0, 0, 0, 0.09);
  border-radius: 0;
}
.pm-menu-list li.sep:hover, .pm-ctx-list li.sep:hover { background: rgba(0, 0, 0, 0.09); }
.pm-menu-list li .mi-ico, .pm-ctx-list li .mi-ico {
  width: 14px;
  height: 14px;
  flex: 0 0 auto;
  opacity: 0.75;
}
.pm-menu-list li .mi-ico svg, .pm-ctx-list li .mi-ico svg { width: 14px; height: 14px; }
.pm-menu-list li .mi-key, .pm-ctx-list li .mi-key {
  margin-left: auto;
  font-size: 10.5px;
  color: var(--ink-3);
  padding-left: 14px;
}
.pm-menu-list li:hover .mi-key { color: rgba(255, 255, 255, 0.75); }
.pm-ctx-list li .mi-check { width: 12px; flex: 0 0 auto; color: var(--accent); }
.pm-ctx-list li:hover .mi-check { color: #FFFFFF; }

/* ---------- 右键菜单 ---------- */
.pm-ctx {
  position: absolute;
  z-index: 21;
  min-width: 168px;
  border-radius: 8px;
  padding: 4px;
  background: rgba(252, 252, 253, 0.96);
  -webkit-backdrop-filter: blur(24px) saturate(1.8);
  backdrop-filter: blur(24px) saturate(1.8);
  box-shadow:
    0 14px 36px rgba(11, 11, 13, 0.2),
    inset 0 0 0 0.5px rgba(0, 0, 0, 0.08);
  animation: preview-in 0.12s cubic-bezier(0.22, 0, 0, 1) both;
}

/* ---------- 跳转提示 ---------- */
.pm-jump-hint {
  position: absolute;
  left: 10px;
  right: 10px;
  bottom: 48px;
  z-index: 9;
  display: flex;
  align-items: center;
  gap: 8px;
  padding: 7px 10px;
  border-radius: 9px;
  background: rgba(252, 252, 253, 0.94);
  -webkit-backdrop-filter: blur(20px) saturate(1.8);
  backdrop-filter: blur(20px) saturate(1.8);
  box-shadow:
    0 10px 28px rgba(11, 11, 13, 0.16),
    inset 0 0 0 0.5px rgba(0, 0, 0, 0.06);
  font-size: 11.5px;
  color: var(--ink-2);
  animation: preview-in 0.16s cubic-bezier(0.22, 0, 0, 1) both;
}
.pm-jump-hint button {
  margin-left: auto;
  border: none;
  background: var(--accent);
  color: #FFFFFF;
  border-radius: 6px;
  padding: 3px 10px;
  font-size: 11px;
  cursor: pointer;
  font-family: inherit;
}
.pm-jump-hint button:hover { background: #2560E8; }

/* ---------- 监测 / 中转 / 投屏 页内元素 ---------- */
.pm-modbar {
  display: flex;
  gap: 6px;
  flex-wrap: wrap;
  margin: 12px 14px 0;
  cursor: pointer;
}
.pm-modbar span {
  font-size: 11px;
  padding: 3px 9px;
  border-radius: 999px;
  background: rgba(0, 0, 0, 0.045);
  color: var(--ink-3);
}
.pm-modbar span.on { background: rgba(47, 107, 255, 0.16); color: var(--accent); }
.pm-metrics {
  display: grid;
  grid-template-columns: repeat(3, 1fr);
  gap: 8px;
  margin: 12px 14px 14px;
}
.pm-metrics div {
  border: 0.5px solid rgba(0, 0, 0, 0.062);
  border-radius: 9px;
  padding: 8px 10px;
  background: rgba(255, 255, 255, 0.787);
}
.pm-metrics b { display: block; font-size: 10.5px; color: var(--ink-3); font-weight: 500; }
.pm-metrics span { font-family: var(--mono); font-size: 14px; color: var(--ink); }
.pm-bars { display: grid; gap: 7px; margin: 0 14px; }
.pm-bar { display: grid; grid-template-columns: 46px 1fr 34px; align-items: center; gap: 8px; font-size: 11px; }
.pm-bar i {
  display: block;
  height: 8px;
  border-radius: 4px;
  background: linear-gradient(90deg, #7CA0FF, #2F6BFF);
}
.pm-bar em { font-style: normal; font-family: var(--mono); color: var(--ink-2); text-align: right; }

.pm-sect-title {
  font-size: 11px;
  letter-spacing: 0.08em;
  color: var(--ink-3);
  margin: 14px 14px 8px;
}
.pm-exits { display: grid; gap: 6px; margin: 0 14px; }
.pm-exit {
  text-align: left;
  border: 0.5px solid rgba(0, 0, 0, 0.062);
  background: rgba(255, 255, 255, 0.787);
  border-radius: 9px;
  padding: 8px 10px;
  cursor: pointer;
  transition: border-color 0.12s ease, background 0.12s ease;
}
.pm-exit:hover { border-color: var(--accent); background: rgba(47, 107, 255, 0.06); }
.pm-exit b { display: block; font-size: 12.5px; font-weight: 600; }
.pm-exit span { font-size: 10.8px; color: var(--ink-3); }
.pm-files { display: grid; grid-template-columns: 1fr 1fr; gap: 8px; margin: 0 14px; }
.pm-file {
  display: flex;
  align-items: center;
  gap: 8px;
  border: 0.5px solid rgba(0, 0, 0, 0.062);
  border-radius: 9px;
  padding: 7px 9px;
  background: rgba(255, 255, 255, 0.787);
}
.pm-file b { display: block; font-size: 11.5px; font-weight: 550; }
.pm-file span { font-size: 10px; color: var(--ink-3); }
.pm-file-ico {
  flex: 0 0 auto;
  width: 26px;
  height: 26px;
  border-radius: 7px;
  background: rgba(0, 0, 0, 0.05);
  display: flex;
  align-items: center;
  justify-content: center;
  font-size: 8.5px;
  font-weight: 600;
  color: var(--ink-3);
}

.pm-device {
  margin: 12px 14px 0;
  border: 0.5px solid rgba(0, 0, 0, 0.062);
  border-radius: 10px;
  padding: 11px 12px;
  background: rgba(255, 255, 255, 0.787);
}
.pm-device-top { display: flex; gap: 9px; align-items: center; }
.pm-device b { display: block; font-size: 12.5px; }
.pm-device span { font-size: 10.5px; color: var(--ink-3); }
.pm-dot {
  width: 8px;
  height: 8px;
  border-radius: 50%;
  background: var(--green);
  box-shadow: 0 0 0 3px rgba(31, 157, 99, 0.16);
}
.pm-navkeys { display: flex; gap: 6px; margin-top: 10px; }
.pm-navkeys button {
  flex: 1;
  border: 0.5px solid rgba(0, 0, 0, 0.062);
  background: rgba(0, 0, 0, 0.036);
  border-radius: 8px;
  padding: 6px 0;
  font-size: 12px;
  cursor: pointer;
  color: var(--ink-2);
}
.pm-navkeys button:hover { background: var(--ink); color: #FFFFFF; border-color: var(--ink); }
.pm-notify { list-style: none; display: grid; gap: 6px; margin: 0 14px; }
.pm-notify li {
  border: 0.5px solid rgba(0, 0, 0, 0.062);
  border-radius: 9px;
  padding: 8px 10px;
  background: rgba(255, 255, 255, 0.787);
}
.pm-notify b { display: block; font-size: 12px; }
.pm-notify span { font-size: 10.8px; color: var(--ink-3); }

'''

s = s[:start] + NEW + s[end:]
io.open(PATH, 'w', encoding='utf-8').write(s)
print('CSS 已重写，%d 行' % len(s.split('\n')))
