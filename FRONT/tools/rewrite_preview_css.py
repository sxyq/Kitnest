#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""预览浮层的样式（真实渲染）+ 舞台加宽。

真机预览（PreviewPopoverContentView）的视觉：
  · 独立浮窗，飘在面板左侧
  · JSON 走树形检视器（键分色、缩进）
  · 代码走行号 + 语法高亮
  · Markdown 渲染成正文（标题、列表、粗体、行内码、引用、分隔线）
  · 图片显示缩略图 + 「识别文字 / 翻译」按钮
"""
import io, os, re, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PATH = os.path.join(ROOT, 'assets', 'site.css')
s = io.open(PATH, encoding='utf-8').read()

# ---------- 1) 替换预览浮层样式 ----------
i = s.find('/* 预览浮层：真机是独立 NSWindow 飘在面板外')
if i < 0:
    sys.exit('预览浮层样式锚点没找到')
j = s.find('/* ---------- 悬浮菜单（真机 NSMenu） ---------- */')
if j < 0 or j < i:
    sys.exit('菜单锚点没找到')

NEW = u'''/* 预览浮层：真机是独立 NSWindow 飘在面板左侧，网页版放在舞台里、贴着面板左缘向左展开，
   被舞台的 overflow:hidden 裁住，保证不溢出外框。 */
.pm-preview {
  position: absolute;
  z-index: 30;
  width: 244px;
  border-radius: 12px;
  background: rgba(252, 252, 253, 0.97);
  -webkit-backdrop-filter: blur(28px) saturate(1.9);
  backdrop-filter: blur(28px) saturate(1.9);
  box-shadow:
    0 22px 52px rgba(11, 11, 13, 0.22),
    0 3px 10px rgba(11, 11, 13, 0.12),
    inset 0 0 0 0.5px rgba(0, 0, 0, 0.08),
    inset 0 0.5px 0 0 rgba(255, 255, 255, 0.8);
  animation: preview-in var(--m-page) var(--m-back) both;
  overflow: hidden;
  pointer-events: auto;
}
@keyframes preview-in {
  from { opacity: 0; transform: translateX(10px) scale(0.96); }
  to { opacity: 1; transform: none; }
}
/* 箭头：指向面板那一侧 */
.pm-preview::after {
  content: "";
  position: absolute;
  right: -5px;
  top: 22px;
  width: 9px;
  height: 9px;
  background: rgba(252, 252, 253, 0.97);
  transform: rotate(45deg);
  border-top: 0.5px solid rgba(0, 0, 0, 0.08);
  border-right: 0.5px solid rgba(0, 0, 0, 0.08);
}

/* 标题栏：类型 + 标题（真机预览有头部信息） */
.pm-preview-bar {
  display: flex;
  align-items: center;
  gap: 7px;
  padding: 9px 11px 7px;
  border-bottom: 0.5px solid rgba(0, 0, 0, 0.07);
}
.pm-preview-kind {
  flex: 0 0 auto;
  font-size: 9.5px;
  letter-spacing: 0.03em;
  color: var(--accent);
  background: rgba(47, 107, 255, 0.1);
  border-radius: 4px;
  padding: 1px 5px;
}
.pm-preview-title {
  min-width: 0;
  font-size: 11.5px;
  font-weight: 550;
  color: var(--ink);
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}

/* 内容区 */
.pm-preview-body {
  padding: 9px 11px;
  max-height: 300px;
  overflow: auto;
  font-size: 11px;
  line-height: 1.55;
  color: var(--ink-2);
}
.pm-preview-body::-webkit-scrollbar { width: 5px; }
.pm-preview-body::-webkit-scrollbar-thumb { background: rgba(0, 0, 0, 0.14); border-radius: 3px; }

/* 底部动作行 */
.pm-preview-foot {
  display: flex;
  gap: 6px;
  padding: 7px 11px 9px;
  border-top: 0.5px solid rgba(0, 0, 0, 0.07);
  background: rgba(0, 0, 0, 0.02);
}
.pm-preview-foot:empty { display: none; }
.pm-preview-foot button {
  border: 0.5px solid rgba(0, 0, 0, 0.1);
  background: rgba(255, 255, 255, 0.8);
  border-radius: 6px;
  padding: 3px 9px;
  font-size: 11px;
  color: var(--ink-2);
  cursor: pointer;
  font-family: inherit;
  transition: background-color var(--m-tap) var(--m-ease), color var(--m-tap) var(--m-ease), transform var(--m-tap) var(--m-ease);
}
.pm-preview-foot button:hover { background: #FFFFFF; color: var(--ink); }
.pm-preview-foot button:active { transform: scale(0.94); }

/* ---- JSON 树形（真机 JSONInspectorView） ---- */
.pv-tree { font-family: var(--mono); font-size: 10.5px; line-height: 1.6; }
.pv-row { white-space: pre-wrap; word-break: break-all; }
.pv-key { color: #7A5AF8; }
.pv-colon { color: var(--ink-3); margin: 0 1px; }
.pv-bracket { color: var(--ink-3); }
.pv-comma { color: var(--ink-3); }
.pv-str { color: #1F9D63; }
.pv-num { color: #D97706; }
.pv-bool { color: #2F6BFF; }
.pv-null { color: var(--ink-3); font-style: italic; }

/* ---- 代码（真机 CodePreviewView：行号 + 高亮） ---- */
.pv-code { font-family: var(--mono); font-size: 10px; line-height: 1.55; }
.pv-code table { border-collapse: collapse; width: 100%; }
.pv-code td { vertical-align: top; }
.pv-code .c-ln {
  width: 22px;
  padding-right: 7px;
  text-align: right;
  color: rgba(0, 0, 0, 0.24);
  user-select: none;
  font-variant-numeric: tabular-nums;
}
.pv-code .c-src { white-space: pre-wrap; word-break: break-all; color: var(--ink-2); }
.c-kw { color: #2F6BFF; }
.c-str { color: #1F9D63; }
.c-num { color: #D97706; }
.c-com { color: #9A9AA2; font-style: italic; }

/* ---- Markdown（真机渲染成正文） ---- */
.pv-md { font-size: 11px; line-height: 1.6; color: var(--ink-2); }
.pv-md h1 { font-size: 14px; font-weight: 650; color: var(--ink); margin: 0 0 6px; line-height: 1.35; }
.pv-md h2 { font-size: 12.5px; font-weight: 620; color: var(--ink); margin: 9px 0 4px; }
.pv-md h3 { font-size: 11.5px; font-weight: 600; color: var(--ink); margin: 8px 0 3px; }
.pv-md h4 { font-size: 11px; font-weight: 600; color: var(--ink-2); margin: 6px 0 3px; }
.pv-md p { margin: 0 0 5px; }
.pv-md ul, .pv-md ol { margin: 0 0 6px; padding-left: 17px; }
.pv-md li { margin-bottom: 2px; }
.pv-md strong { font-weight: 620; color: var(--ink); }
.pv-md code.md-code {
  font-family: var(--mono);
  font-size: 10px;
  background: rgba(0, 0, 0, 0.055);
  border-radius: 3px;
  padding: 0 3px;
  color: var(--ink);
}
.pv-md blockquote {
  margin: 0 0 6px;
  padding: 2px 0 2px 8px;
  border-left: 2px solid rgba(47, 107, 255, 0.35);
  color: var(--ink-3);
}
.pv-md hr.md-hr { border: none; border-top: 0.5px solid var(--line); margin: 8px 0; }
.pv-md a { color: #2F6BFF; text-decoration: none; }
.pv-md a:hover { text-decoration: underline; }

/* ---- 图片（真机 PreviewImageView：缩略图 + 识别文本） ---- */
.pv-img { display: grid; gap: 7px; }
.pv-img-thumb {
  height: 96px;
  border-radius: 8px;
  background:
    linear-gradient(135deg, rgba(122, 90, 248, 0.14), rgba(47, 107, 255, 0.1)),
    rgba(0, 0, 0, 0.035);
  display: flex;
  align-items: center;
  justify-content: center;
  color: rgba(0, 0, 0, 0.28);
}
.pv-img-thumb svg { width: 30px; height: 30px; }
.pv-img-meta { font-size: 10.5px; color: var(--ink-3); font-family: var(--mono); }
.pv-img-acts { display: flex; gap: 6px; }
.pv-img-acts button {
  border: 0.5px solid rgba(0, 0, 0, 0.1);
  background: rgba(255, 255, 255, 0.8);
  border-radius: 6px;
  padding: 3px 9px;
  font-size: 11px;
  color: var(--ink-2);
  cursor: pointer;
  font-family: inherit;
}
.pv-img-acts button:hover { background: #FFFFFF; color: var(--ink); }
.pv-ocr {
  margin-top: 2px;
  border-top: 0.5px solid rgba(0, 0, 0, 0.07);
  padding-top: 7px;
}
.pv-ocr-title {
  display: block;
  font-size: 10px;
  color: var(--ink-3);
  margin-bottom: 4px;
}
.pv-ocr pre {
  margin: 0;
  font-family: var(--mono);
  font-size: 10px;
  line-height: 1.5;
  white-space: pre-wrap;
  color: var(--ink-2);
}

/* ---- 纯文本 / 链接 ---- */
.pv-text { white-space: pre-wrap; word-break: break-word; }
.pv-url { font-family: var(--mono); font-size: 10.5px; color: #2F6BFF; word-break: break-all; }

'''

s = s[:i] + NEW + s[j:]

# ---------- 2) 舞台加宽，给预览留出左侧空间 ----------
old_hero = '''.hero-inner {
  max-width: var(--maxw);
  margin: 0 auto;
  padding: 0 24px;
  display: grid;
  grid-template-columns: minmax(0, 1.02fr) minmax(0, 0.98fr);
  gap: 56px;
  align-items: center;
}'''
new_hero = '''.hero-inner {
  max-width: var(--maxw);
  margin: 0 auto;
  padding: 0 24px;
  display: grid;
  /* 右栏加宽：预览浮层要飘在面板左侧（真机就是这样），得有地方放 */
  grid-template-columns: minmax(0, 0.84fr) minmax(0, 1.16fr);
  gap: 44px;
  align-items: center;
}'''
if old_hero in s:
    s = s.replace(old_hero, new_hero)
else:
    print('（hero-inner 未匹配，检查媒体查询里的同名规则）')

# 舞台要有 overflow: hidden（裁住预览）+ 足够的左侧空间
old_stage = '''.hero-stage {
  position: relative;
  border: 1px solid var(--line);
  border-radius: var(--radius-lg);'''
new_stage = '''.hero-stage {
  position: relative;
  overflow: hidden;            /* 预览浮层被舞台裁住，不溢出外框 */
  border: 1px solid var(--line);
  border-radius: var(--radius-lg);'''
if old_stage in s:
    s = s.replace(old_stage, new_stage)
else:
    print('（hero-stage 未匹配）')

io.open(PATH, 'w', encoding='utf-8').write(s)
print('预览样式与舞台布局已写入，CSS %d 行' % len(s.split('\n')))
