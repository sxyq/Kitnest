#!/usr/bin/env python3
"""把官网动效整体换成 App 源码 Theme.Motion / WindowReveal 的 1:1 镜像。

真源见 FRONT/assets/motion.js 头部；本脚本只做一次性的字面量清理，
之后所有改动都应在 motion.js + site.css 的令牌引用里进行。

用法：python3 FRONT/tools/rewrite_motion_exact.py
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
CSS = ROOT / "FRONT" / "assets" / "site.css"
JS = ROOT / "FRONT" / "assets" / "site.js"
HTML = ROOT / "FRONT" / "index.html"

MARK = "/* ---------- 动效体系（App 源码 1:1） ---------- */"

NEW_BLOCK = r"""/* ---------- 动效体系（App 源码 1:1） ----------
   唯一真源：assets/motion.js（镜像 Sources/Core/UI/Support.swift 的 Theme.Motion、
   PersonalizationSwiftUI 打开时长、WindowReveal 的锚点缩放、Toast 的弹簧）。
   本文件只允许引用 var(--...)，不写死时长/曲线；下面 :root 里的值是同一套真源的
   静态兜底（JS 注入优先级更高）。守卫：python3 FRONT/tools/front_motion_audit.py

   语义对照（官网 → App 消费点 → 令牌）：
     通用按钮按压        SpringyIconButtonStyle            springBouncy / scale .88 / opacity .65
     通用 hover / 底色    Theme.Motion.fast                 .easeOut(0.16)
     页签切换            PanelRootView:688                 fast + .transition(.opacity)
     监测模块切换        MonitorDetailView:75,101          springSoft + opacity/.offset(y:8)
     日历翻页            CalendarSectionView:132-134       fast + opacity
     搜索结果            SearchSectionView:709             spring(response:.28,damping:.86)
     循环扫描 / 进度      Theme.Motion.loop / progress       linear(0.9) / linear(0.2)
     通知卡              MenuBarToastManager               springBouncy + 3.0s 停留 + 0.4s 收尾
     主面板开合          PanelController:259,337           WindowReveal scale .90 / openDuration
     剪贴板预览开合      ClipboardPreviewWindow:156,203    WindowReveal scale .94 / 邻边锚点
     监测独立窗入场      MonitorPopoutWindow:302           scale .90 / 0.28 / caBackOut
     监测独立窗收起      MonitorPopoutWindow:333           scale .96 / 0.16 / caEaseIn
   SwiftUI 的 .easeOut = CA 系统 easeOut = cubic-bezier(0,0,.58,1)；
   caEaseOut(.22,0,0,1) / caEaseIn(.42,0,1,1) / caBackOut(.22,1.05,.36,1)
   只用于窗口级 WindowReveal，不能混到视图过渡里。
*/
:root {
  --m-tap: 0.12s;
  --m-fast: 0.16s;
  --m-page: 0.22s;
  --m-slow: 0.45s;
  --m-loop: 0.9s;
  --m-progress: 0.2s;
  --m-open: 0.22s;
  --m-ease-out: cubic-bezier(0, 0, 0.58, 1);
  --m-ca-ease-out: cubic-bezier(0.22, 0, 0, 1);
  --m-ca-ease-in: cubic-bezier(0.42, 0, 1, 1);
  --m-ca-back-out: cubic-bezier(0.22, 1.05, 0.36, 1);
  --m-linear: linear;
  /* 弹簧收敛时长由 motion.js 的解析解注入；这里是同一公式的静态兜底 */
  --d-spring-snappy: 0.311s;
  --spring-snappy: var(--m-ease-out);
  --d-spring: 0.393s;
  --spring: var(--m-ease-out);
  --d-spring-soft: 0.477s;
  --spring-soft: var(--m-ease-out);
  --d-spring-bouncy: 0.441s;
  --spring-bouncy: var(--m-ease-out);
  --m-pressed-scale: 0.88;
  --m-pressed-opacity: 0.65;
  --m-toast-scale: 0.5;
  --m-hover-lift: 1.02;
  --m-reveal-panel: 0.90;
  --m-reveal-preview: 0.94;
  --m-reveal-popout-in: 0.90;
  --m-reveal-popout-out: 0.96;
  --m-popout-appear: 0.28s;
  --m-popout-dismiss: 0.16s;
}

/* 通用按钮：SpringyIconButtonStyle —— 按下 springBouncy 缩到 .88 / 透明度 .65，
   抬起同一条弹簧回弹；底色/描边这类单次交互走 fast（.easeOut 0.16）。 */
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
    transform var(--d-spring-bouncy) var(--spring-bouncy),
    opacity var(--d-spring-bouncy) var(--spring-bouncy),
    background-color var(--m-fast) var(--m-ease-out),
    color var(--m-fast) var(--m-ease-out),
    box-shadow var(--m-fast) var(--m-ease-out);
}
.pm-seg:active,
.pm-modbar button:active,
.pm-ico:active,
.pm-dock button:active,
.pm-cal-nav:active,
.pm-cal-collapse:active,
.pm-navkeys button:active,
button:active {
  transform: scale(var(--m-pressed-scale));
  opacity: var(--m-pressed-opacity);
}

/* 分段选中态：pageSegments 是普通条件填充，无过冲，走 fast */
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
    transform var(--m-fast) var(--m-ease-out),
    opacity var(--m-fast) var(--m-ease-out);
  pointer-events: none;
}
.pm-seg.on::before { opacity: 1; transform: none; }
.pm-seg.on { color: var(--accent); font-weight: 600; }

.pm-modbar button { position: relative; }
.pm-modbar button.on {
  background: rgba(47, 107, 255, 0.18);
  box-shadow: inset 0 0 0 0.5px rgba(47, 107, 255, 0.5);
  color: var(--ink);
  font-weight: 600;
}

/* 面板页签切换：PanelRootView.swift:688 .animation(Theme.Motion.fast, value: page)
   + .transition(.opacity) —— 纯淡入，没有位移。 */
.pm-page {
  animation: page-fade var(--m-fast) var(--m-ease-out) both;
}
@keyframes page-fade {
  from { opacity: 0; }
  to { opacity: 1; }
}
/* 监测模块切换：MonitorDetailView.swift:75 .transition(.opacity.combined(with:
   .offset(y: 8))) + :101 withAnimation(Theme.Motion.springSoft) */
.pm-mod {
  animation: mod-slide var(--d-spring-soft) var(--spring-soft) both;
}
@keyframes mod-slide {
  from { opacity: 0; transform: translateY(8px); }
  to { opacity: 1; transform: none; }
}

/* 剪贴板行：hover 底色 fast；动作条 ClipboardSectionView.swift:188 .transition(.opacity) */
.pm-item {
  transition: background-color var(--m-fast) var(--m-ease-out);
}
.pm-rowacts {
  opacity: 0;
  transition: opacity var(--m-fast) var(--m-ease-out);
}
.pm-item:hover .pm-rowacts { opacity: 1; }

/* 预览浮层：真机是独立 NSWindow，开合由 WindowReveal 的锚点缩放 + opacity 承担，
   网页版由 assets/motion.js 的 revealIn/revealOut 驱动，此处不设 CSS 动画。 */
.pm-preview { will-change: transform, opacity; }

/* 悬浮菜单 / 右键菜单：App 侧是 NSMenu 系统弹出，对齐到最快的单次交互 fast */
.pm-menu,
.pm-ctx {
  animation: menu-in var(--m-fast) var(--m-ease-out) both;
}
@keyframes menu-in {
  from { opacity: 0; }
  to { opacity: 1; }
}
.pm-menu-list li,
.pm-ctx-list li {
  transition:
    background-color var(--m-tap) var(--m-ease-out),
    color var(--m-tap) var(--m-ease-out);
}

/* 日历翻页：CalendarSectionView.swift:132-134 withAnimation(Theme.Motion.fast)，
   整块一起淡入（真机没有逐格 stagger）。 */
.pm-day {
  animation: day-in var(--m-fast) var(--m-ease-out) both;
}
@keyframes day-in {
  from { opacity: 0; }
  to { opacity: 1; }
}

/* 搜索结果：SearchSectionView.swift:709 .animation(Theme.Motion.spring,
   value: listContentHeight) —— 用真实 spring(.28/.86) 采样曲线，不再用贝塞尔近似。 */
.pm-results {
  animation: results-in var(--d-spring) var(--spring) both;
}
@keyframes results-in {
  from { opacity: 0; }
  to { opacity: 1; }
}

/* Toast：Toast.swift:98-100 scaleEffect(0.5→1, anchor:.center) + opacity，
   :117 springBouncy；停留 3.0s、收尾 0.4s 由 site.js 按 :111/:115 控制。 */
.toast {
  transition:
    opacity var(--d-spring-bouncy) var(--spring-bouncy),
    transform var(--d-spring-bouncy) var(--spring-bouncy);
}

/* 跳转提示条：单次淡入 */
.pm-jump-hint {
  animation: results-in var(--m-fast) var(--m-ease-out) both;
}

/* 底部胶囊 hover：LiquidGlass.swift:431-440 HoverLift scale 1.02 + Theme.Motion.spring */
.pm-dock {
  transition:
    transform var(--d-spring) var(--spring),
    box-shadow var(--m-fast) var(--m-ease-out);
}
.pm-dock:hover {
  transform: translateX(-50%) scale(var(--m-hover-lift));
  box-shadow:
    0 16px 30px rgba(11, 11, 13, 0.2),
    inset 0 0 0 0.6px rgba(255, 255, 255, 0.6);
}

/* 数值/进度：Theme.Motion.progress = linear(0.2)（连续量只能线性），
   颜色与显隐这类单次交互走 fast / tap。 */
.mon-ring .ring-fg {
  transition:
    stroke-dashoffset var(--m-progress) var(--m-linear),
    stroke var(--m-fast) var(--m-ease-out);
}
.mon-spark polygon,
.mon-spark polyline {
  transition: opacity var(--m-fast) var(--m-ease-out);
}
.mon-segbar i,
.mon-zone-bar i {
  transition:
    width var(--m-fast) var(--m-ease-out),
    background-color var(--m-fast) var(--m-ease-out);
}
.mon-core-box {
  transition:
    background-color var(--m-fast) var(--m-ease-out),
    transform var(--d-spring) var(--spring);
}
.mon-core:hover .mon-core-box { transform: scaleY(1.06); }

.mon-proc-x {
  opacity: 0.35;
  transition:
    opacity var(--m-fast) var(--m-ease-out),
    transform var(--m-tap) var(--m-ease-out);
}
.mon-proc:hover .mon-proc-x { opacity: 0.9; }
.mon-proc-x:hover { transform: scale(var(--m-hover-lift)); }

/* 展示页截图切换：纯淡入 */
.shot-frame > div:not([hidden]) {
  animation: page-fade var(--m-fast) var(--m-ease-out) both;
}

/* 尊重系统的「减弱动态效果」设置 */
@media (prefers-reduced-motion: reduce) {
  *, *::before, *::after {
    animation-duration: 0.01ms !important;
    animation-iteration-count: 1 !important;
    transition-duration: 0.01ms !important;
  }
}

"""

# 动效区块之外散落的字面量清理（键 = 精确原文，值 = 替换文本）
REPLACES = [
    ("transition: color 0.16s ease, background 0.16s ease;",
     "transition: color var(--m-fast) var(--m-ease-out), background var(--m-fast) var(--m-ease-out);"),
    ("transition: border-color 0.16s ease, background 0.16s ease, transform 0.16s ease;",
     "transition: border-color var(--m-fast) var(--m-ease-out), background var(--m-fast) var(--m-ease-out), transform var(--m-fast) var(--m-ease-out);"),
    ("transition: opacity 0.18s ease;",
     "transition: opacity var(--m-fast) var(--m-ease-out);"),
    ("transition: opacity 0.2s ease, transform 0.22s cubic-bezier(0.22, 0.8, 0.3, 1), visibility 0.2s;",
     "transition: opacity var(--m-fast) var(--m-ease-out), transform var(--d-spring) var(--spring), visibility var(--m-fast) var(--m-ease-out);"),
    ("  transition: opacity 0.22s ease;",
     "  transition: opacity var(--m-fast) var(--m-ease-out);"),
    ("transition: background 0.14s ease, color 0.14s ease;",
     "transition:\n    transform var(--d-spring-bouncy) var(--spring-bouncy),\n    opacity var(--d-spring-bouncy) var(--spring-bouncy),\n    background var(--m-fast) var(--m-ease-out),\n    color var(--m-fast) var(--m-ease-out);"),
    ("  animation: pop-in 0.18s cubic-bezier(0.22, 0, 0, 1);",
     "  animation: pop-in var(--m-popout-appear) var(--m-ca-back-out) both;\n  transform-origin: top center;"),
    ("@keyframes pop-in {\n  from { opacity: 0; transform: translateY(-4px); }\n  to { opacity: 1; transform: none; }\n}",
     "@keyframes pop-in {\n  from { opacity: 0; transform: scale(var(--m-reveal-popout-in)); }\n  to { opacity: 1; transform: none; }\n}"),
    ("transition: color 0.12s ease, background 0.12s ease;",
     "transition: color var(--m-tap) var(--m-ease-out), background var(--m-tap) var(--m-ease-out);"),
    ("transition: background 0.12s ease;",
     "transition: background var(--m-tap) var(--m-ease-out);"),
    ("transition: border-color 0.12s ease, background 0.12s ease;",
     "transition: border-color var(--m-tap) var(--m-ease-out), background var(--m-tap) var(--m-ease-out);"),
    ("  animation: shimmer 1.4s ease infinite;",
     "  animation: shimmer var(--m-loop) var(--m-linear) infinite;"),
    (".faq-arrow { color: var(--ink-3); font-size: 15px; transition: transform 0.18s ease; }",
     ".faq-arrow { color: var(--ink-3); font-size: 15px; transition: transform var(--m-fast) var(--m-ease-out); }"),
    (".faq-a { max-height: 0; overflow: hidden; transition: max-height 0.24s ease; }",
     ".faq-a { max-height: 0; overflow: hidden; transition: max-height var(--m-page) var(--m-ease-out); }"),
    ("  transition: opacity 0.2s ease, transform 0.2s ease;",
     "  transition:\n    opacity var(--d-spring-bouncy) var(--spring-bouncy),\n    transform var(--d-spring-bouncy) var(--spring-bouncy);"),
    ("  transform: translate(-50%, 14px);",
     "  transform: translate(-50%, 0) scale(var(--m-toast-scale));\n  transform-origin: center;"),
    (".toast.show { opacity: 1; transform: translate(-50%, 0); }",
     ".toast.show { opacity: 1; transform: translate(-50%, 0) scale(1); }"),
    ("  animation: preview-in 0.13s cubic-bezier(0.22, 0, 0, 1) both;",
     "  animation: page-fade var(--m-tap) var(--m-ease-out) both;"),
    ("  animation: preview-in 0.12s cubic-bezier(0.22, 0, 0, 1) both;",
     "  animation: page-fade var(--m-tap) var(--m-ease-out) both;"),
    ("  animation: preview-in 0.16s cubic-bezier(0.22, 0, 0, 1) both;",
     "  animation: page-fade var(--m-fast) var(--m-ease-out) both;"),
    ("  background 0.14s ease, color 0.14s ease;",
     "  background var(--m-fast) var(--m-ease-out), color var(--m-fast) var(--m-ease-out);"),
    ("  transition: background-color var(--m-tap) var(--m-ease), color var(--m-tap) var(--m-ease), transform var(--m-tap) var(--m-ease);",
     "  transition:\n    background-color var(--m-tap) var(--m-ease-out),\n    color var(--m-tap) var(--m-ease-out),\n    transform var(--d-spring-bouncy) var(--spring-bouncy);"),
    (".pm-preview-foot button:active { transform: scale(0.94); }",
     ".pm-preview-foot button:active { transform: scale(var(--m-pressed-scale)); opacity: var(--m-pressed-opacity); }"),
    ("  animation: preview-in var(--m-page) var(--m-back) both;\n", ""),
    ("  animation: preview-in var(--m-page) var(--m-ca-back-out) both;\n", ""),
    ("@keyframes preview-in {\n  from { opacity: 0; transform: translateX(10px) scale(0.96); }\n  to { opacity: 1; transform: none; }\n}\n", ""),
    ("  animation: menu-in var(--m-fast) var(--m-back) both;",
     "  animation: menu-in var(--m-fast) var(--m-ease-out) both;"),
    ("  animation: preview-in var(--m-page) var(--m-back) both;", ""),
    (".panel-mock.is-open { animation: panel-open 0.22s cubic-bezier(0.22, 0, 0, 1) both; }\n.panel-mock.is-closing { animation: panel-close 0.22s cubic-bezier(0.42, 0, 1, 1) both; }\n\n@keyframes panel-open {\n  from { opacity: 0; transform: translateY(-10px) scale(0.94); }\n  to { opacity: 1; transform: none; }\n}\n@keyframes panel-close {\n  from { opacity: 1; transform: none; }\n  to { opacity: 0; transform: translateY(-8px) scale(0.96); }\n}\n",
     "/* 开合由 assets/motion.js 的 WindowReveal 等价实现驱动（scale .90、\n   锚点 = 菜单栏图标投影、开 caEaseOut / 收 caEaseIn、时长 = openDuration）。 */\n"),
    ("  transition: background-color var(--m-tap) var(--m-ease), color var(--m-tap) var(--m-ease);",
     "  transition: background-color var(--m-tap) var(--m-ease-out), color var(--m-tap) var(--m-ease-out);"),
]


def rewrite_css() -> None:
    text = CSS.read_text(encoding="utf-8")
    if MARK in text:
        print("site.css: 已是新版动效，跳过")
        return
    start = text.index("/* ---------- 动效体系")
    end = text.index("/* ---------- 网页版 Liquid Glass ---------- */")
    text = text[:start] + NEW_BLOCK + text[end:]

    for old, new in REPLACES:
        if old not in text:
            print("  ! 未命中（可能已改）：" + old[:70].replace("\n", "\\n"))
            continue
        text = text.replace(old, new)

    # 旧变量别名（动效区块之外的引用）
    text = text.replace("var(--m-ease)", "var(--m-ease-out)")
    text = text.replace("var(--m-ease-in)", "var(--m-ca-ease-in)")
    text = text.replace("var(--m-back)", "var(--m-ca-back-out)")
    text = text.replace("var(--m-spring)", "var(--spring)")

    # mb-pop 的两处动画声明：保留 .mb-pop 块里的 pop-in，删掉动效区里那条
    text = text.replace(
        ".mb-pop {\n  animation: menu-in var(--m-fast) var(--m-ca-back-out) both;\n}\n", "")

    CSS.write_text(text, encoding="utf-8")
    print("site.css: 动效区块已替换为 App 1:1 令牌")


def rewrite_js() -> None:
    text = JS.read_text(encoding="utf-8")
    if "KitnestMotion" in text:
        print("site.js: 已接入动效层，跳过")
        return

    # Toast：MenuBarToastManager 代际 + 3.0s 停留 + 0.4s 收尾；几何由 CSS springBouncy 承担
    old_toast = '''  var toastTimer = null;
  function toast(message) {
    var el = $("#toast");
    if (!el) return;
    el.textContent = message;
    el.classList.add("show");
    if (toastTimer) clearTimeout(toastTimer);
    toastTimer = setTimeout(function () { el.classList.remove("show"); }, 2400);
  }'''
    new_toast = '''  /* MenuBarToastManager（Toast.swift:134-195）：代际防串台、3.0s 自动隐藏、
     隐藏动画收尾 0.4s；scale 0.5→1 + opacity 由 CSS 的 springBouncy 承担。 */
  var toastTimer = null;
  var toastOrderOut = null;
  var toastGeneration = 0;
  function toast(message) {
    var el = $("#toast");
    if (!el) return;
    toastGeneration += 1;
    if (toastTimer) clearTimeout(toastTimer);
    if (toastOrderOut) clearTimeout(toastOrderOut);
    el.textContent = message;
    el.classList.add("show");
    var generation = toastGeneration;
    toastTimer = setTimeout(function () {
      if (generation !== toastGeneration) return;
      el.classList.remove("show");
      toastOrderOut = setTimeout(function () {
        if (generation !== toastGeneration) return;
        el.style.visibility = "hidden";
      }, Motion.tokens.toast.orderOutDelay * 1000);
    }, Motion.tokens.toast.displayDuration * 1000);
    el.style.visibility = "";
  }'''
    assert old_toast in text, "toast 块未命中"
    text = text.replace(old_toast, new_toast)

    # 动效层引用
    text = text.replace('  var $ = function (sel, root)',
                        '  var Motion = window.KitnestMotion;\n\n  var $ = function (sel, root)', 1)

    # 主面板开合：PanelController.show/hide + WindowReveal
    old_panel = '''  function setPanel(open) {
    if (!panelMock || !mbIcon) return;
    mbIcon.setAttribute("aria-expanded", open ? "true" : "false");
    mbIcon.setAttribute("aria-label", open ? "收起主面板" : "展开主面板");
    if (panelTimer) { clearTimeout(panelTimer); panelTimer = null; }
    if (open) {
      panelMock.hidden = false;
      panelMock.classList.remove("is-closing");
      // 强制重排，让开合动画每次都重放
      void panelMock.offsetWidth;
      panelMock.classList.add("is-open");
    } else {
      panelMock.classList.remove("is-open");
      panelMock.classList.add("is-closing");
      panelTimer = setTimeout(function () {
        panelMock.hidden = true;
        panelMock.classList.remove("is-closing");
      }, 220);
    }
  }'''
    new_panel = '''  /* PanelController.swift:247-259 / 323-340 + WindowReveal.swift:43-105
     · 已在屏上重复打开：取消在途收回动画、直接回到可见态，不重播；
     · 展开：从菜单栏图标投影的锚点 (u,0) 缩放到 scale .90 → 1 + opacity 0 → 1；
     · 收起：先等剪贴板预览关闭（hide() 的 dismiss(reason:.panelCollapse)），
       再缩回同一锚点 + 淡出，动画结束才 hidden。 */
  function setPanel(open) {
    if (!panelMock || !mbIcon) return;
    mbIcon.setAttribute("aria-expanded", open ? "true" : "false");
    mbIcon.setAttribute("aria-label", open ? "收起主面板" : "展开主面板");
    if (panelTimer) { clearTimeout(panelTimer); panelTimer = null; }
    var unit = Motion.panelAnchor(mbIcon, panelMock);
    if (open) {
      var wasVisible = !panelMock.hidden;
      panelMock.hidden = false;
      if (wasVisible) {
        // 取消在途收回动画，模型值拉回终态（App 的 removeAllAnimations + reset）
        if (panelMock.getAnimations) {
          panelMock.getAnimations().forEach(function (a) {
            if (a.id !== "kitnest-reveal") return;
            if (a._kitnestCancel) a._kitnestCancel(); else a.cancel();
          });
        }
        panelMock.style.opacity = "1";
        panelMock.style.transform = "none";
        return;
      }
      Motion.revealIn(panelMock, {
        unit: unit,
        scale: Motion.tokens.revealScale.panel,
        duration: Motion.openDuration(),
        timing: "caEaseOut"
      });
    } else {
      if (panelMock.hidden) return;
      var done = false;
      var collapse = function () {
        if (done) return;
        done = true;
        Motion.revealOut(panelMock, {
          unit: unit,
          scale: Motion.tokens.revealScale.panel,
          duration: Motion.openDuration(),
          timing: "caEaseIn",
          hide: true
        });
      };
      // PanelController.hide() 第一段：先等预览窗收回，再执行面板收回
      closePreview(collapse);
    }
  }'''
    assert old_panel in text, "setPanel 块未命中"
    text = text.replace(old_panel, new_panel)

    # 预览关闭：ClipboardPreviewWindow.closeAnimated —— 缩回锚点再真正隐藏
    old_close = '''  function closePreview() {
    if (!pmPreview) return;
    pmPreview.hidden = true;
    previewPinned = false;
    previewAnchorId = null;
  }'''
    new_close = '''  function closePreview(onClosed) {
    previewPinned = false;
    previewAnchorId = null;
    if (!pmPreview || pmPreview.hidden) {
      if (onClosed) onClosed();
      return;
    }
    // WindowReveal.playOut：缩回本次展开的锚点并淡出，complete 里才 close()
    Motion.revealOut(pmPreview, {
      unit: previewRevealUnit,
      scale: Motion.tokens.revealScale.preview,
      duration: Motion.openDuration(),
      timing: "caEaseIn",
      hide: true,
      complete: onClosed
    });
  }'''
    assert old_close in text, "closePreview 块未命中"
    text = text.replace(old_close, new_close)
    text = text.replace("  var previewAnchorId = null;",
                        "  var previewAnchorId = null;\n  var previewRevealUnit = { x: 1, y: 0.5 };", 1)

    # 预览入场：换条目才播入场，锚点 = 预览右边缘 (x=1) 与锚条目的投影
    # sameItem 必须在 previewAnchorId 被覆盖之前算（ClipboardPreviewWindow.show 同款顺序）
    old_head = '''    if (previewAnchorId === item.id && !pmPreview.hidden && !pinned) return;
    previewAnchorId = item.id;'''
    new_head = '''    if (previewAnchorId === item.id && !pmPreview.hidden && !pinned) return;
    var isSameItem = previewAnchorId === item.id && !pmPreview.hidden;
    previewAnchorId = item.id;'''
    assert old_head in text, "showPreview 开头未命中"
    text = text.replace(old_head, new_head)

    old_tail = '''    pmPreview.style.top = Math.round(top) + "px";
    pmPreview.setAttribute("data-side", "left");
  }'''
    new_tail = '''    pmPreview.style.top = Math.round(top) + "px";
    pmPreview.setAttribute("data-side", "left");

    // ClipboardPreviewWindow.swift:149-158 / 180-188
    // 同条目反复 hover 不重播入场；换条目才从邻边锚点 (1, v) 以 scale .94 展开。
    previewRevealUnit = Motion.previewAnchor(rowRect, pmPreview.getBoundingClientRect());
    if (!isSameItem) {
      Motion.revealIn(pmPreview, {
        unit: previewRevealUnit,
        scale: Motion.tokens.revealScale.preview,
        duration: Motion.openDuration(),
        timing: "caEaseOut"
      });
    }
  }'''
    assert old_tail in text, "showPreview 结尾未命中"
    text = text.replace(old_tail, new_tail)

    # 日历格 stagger 不是真机行为（CalendarSectionView 整块 withAnimation(fast)）
    old_stagger = '''    // 日历格也逐个淡入
    if (pmCalGrid) {
      $$(".pm-day", pmCalGrid).forEach(function (d, i) {
        d.style.animationDelay = (i * 12) + "ms";
      });
    }
'''
    assert old_stagger in text, "日历 stagger 未命中"
    text = text.replace(old_stagger, "")

    JS.write_text(text, encoding="utf-8")
    print("site.js: Toast / 主面板 / 预览 / 日历已接入 App 动效")


def rewrite_html() -> None:
    text = HTML.read_text(encoding="utf-8")
    if "assets/motion.js" in text:
        print("index.html: 已引入动效层，跳过")
        return
    old = '  <script src="assets/site.js"></script>'
    assert old in text, "site.js 引用未命中"
    text = text.replace(old, '  <script src="assets/motion.js"></script>\n' + old)
    HTML.write_text(text, encoding="utf-8")
    print("index.html: 已引入 assets/motion.js")


def main() -> int:
    rewrite_css()
    rewrite_js()
    rewrite_html()
    print("完成。请跑：python3 FRONT/tools/front_motion_audit.py")
    return 0


if __name__ == "__main__":
    sys.exit(main())
