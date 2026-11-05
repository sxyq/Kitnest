/* ============================================================
   Kitnest 官网动效层 —— macOS App 源码的 1:1 网页镜像

   唯一真源（改这里之前先改 App，或两边一起改）：
     · apps/FrsetNext/Sources/Core/UI/Support.swift            Theme.Motion (319-346)
     · apps/FrsetNext/Sources/Core/Runtime/Personalization.swift (49-71, 100, 216)
     · apps/FrsetNext/Sources/Core/Runtime/WindowReveal.swift   (26-119, 159-186)
     · apps/FrsetNext/Sources/Features/Panel/Presentation/PanelController.swift (257-259, 326-338)
     · apps/FrsetNext/Sources/Features/Clipboard/UI/ClipboardPreviewWindow.swift (139-205)
     · apps/FrsetNext/Sources/Features/Monitor/Window/MonitorPopoutWindow.swift (299-334)
     · apps/FrsetNext/Sources/Core/UI/Toast.swift               (98-100, 111-117, 171-195)
     · apps/FrsetNext/Sources/Core/UI/LiquidGlass.swift         (417-440)

   铁律：除本文件外，官网任何 CSS / JS 都不许写死动画时长或曲线，只引用
   这里注入的 CSS 变量。校验：python3 FRONT/tools/front_motion_audit.py

   曲线分两套，不能混：
     · SwiftUI `.easeOut(duration:)` → CA 系统 easeOut = cubic-bezier(0,0,.58,1)，用于按钮、
       页签、列表等视图内过渡；
     · AppKit / CoreAnimation 的 Theme.Motion.ca* → 自定义控制点，只用于窗口级
       WindowReveal（主面板 / 剪贴板预览 / 监测独立窗）的开合。
   ============================================================ */

(function () {
  "use strict";

  var M = {
    /* ---- Theme.Motion：SwiftUI 单次交互（.easeOut(duration:)） ---- */
    tap: 0.12,
    fast: 0.16,
    page: 0.22,
    slow: 0.45,

    /* ---- Theme.Motion：弹簧四档 .spring(response:dampingFraction:) ---- */
    springs: {
      springSnappy: { response: 0.22, dampingFraction: 0.85 },
      spring:       { response: 0.28, dampingFraction: 0.86 },
      springSoft:   { response: 0.34, dampingFraction: 0.86 },
      springBouncy: { response: 0.24, dampingFraction: 0.62 }
    },

    /* ---- Theme.Motion：连续循环（必须线性，App 源码注释明确禁止缓动） ---- */
    loop: 0.9,
    progress: 0.2,

    /* ---- Theme.Motion：AppKit / CoreAnimation 侧 ---- */
    dTap: 0.12,
    dFast: 0.16,
    dPage: 0.22,
    caEaseOut:      [0.22, 0, 0, 1],
    caEaseIn:       [0.42, 0, 1, 1],
    caEaseInEaseOut:[0.42, 0, 0.58, 1],
    caBackOut:      [0.22, 1.05, 0.36, 1],
    caLinear:       [0, 0, 1, 1],
    swiftUIEaseOut: [0, 0, 0.58, 1],

    /* ---- PersonalizationOpenAnimation.duration（默认 .standard） ---- */
    openDuration: { snappy: 0.18, standard: 0.22, soft: 0.28 },
    openPreset: "standard",

    /* ---- WindowReveal / 各窗口的 scale 与时长 ---- */
    revealScale: { panel: 0.90, preview: 0.94, popoutIn: 0.90, popoutOut: 0.96 },
    popoutAppear: { duration: 0.28, timing: "caBackOut" },
    popoutDismiss:{ duration: 0.16, timing: "caEaseIn" },
    popoutResize: { duration: 0.22, timing: "caEaseOut" },

    /* ---- MenuBarToastManager ---- */
    toast: { displayDuration: 3.0, orderOutDelay: 0.4, scale: 0.5 },

    /* ---- SpringyIconButtonStyle / HoverLift ---- */
    pressed: { scale: 0.88, opacity: 0.65 },
    hoverLift: 1.02
  };

  function bezier(cp) { return "cubic-bezier(" + cp.join(", ") + ")"; }
  function sec(v) { return (Math.round(v * 1000) / 1000) + "s"; }

  /* SwiftUI spring 的解析解（欠阻尼简谐振子）。
     SwiftUI 的 response = 无阻尼时的振动周期，故 w0 = 2π / response；
     dampingFraction = 阻尼比 ζ。取标准初值 x(0)=0、v(0)=0：
       x(t) = 1 - e^(-ζ·w0·t) · [ cos(wd·t) + (ζ·w0/wd)·sin(wd·t) ]
     收敛时长由包络 e^(-ζ·w0·t)·√(1+k²) < 0.1% 解出，实测约为 response 的
     1.6–2 倍，与 Support.swift 的注释一致（弹簧不能按 response 直接截断）。
     采样点直接作为 CSS linear() / WAAPI easing 输出，过冲值 >1 原样保留，
     不再用 cubic-bezier 近似。 */
  function solveSpring(response, dampingFraction, samples) {
    samples = samples || 64;
    var w0 = 2 * Math.PI / response;
    var z = dampingFraction;
    var wd = w0 * Math.sqrt(Math.max(1e-9, 1 - z * z));
    var k = z * w0 / wd;
    var amp = Math.sqrt(1 + k * k);
    var settle = Math.log(Math.max(amp / 0.001, 2)) / (z * w0);
    settle = Math.max(settle, response * 1.2);

    function value(t) {
      if (z >= 1) return 1 - Math.exp(-w0 * t) * (1 + w0 * t);
      return 1 - Math.exp(-z * w0 * t) *
        (Math.cos(wd * t) + k * Math.sin(wd * t));
    }

    var list = [];
    for (var i = 0; i <= samples; i++) {
      var v = value(settle * i / samples);
      if (i === 0) v = 0;
      if (i === samples) v = 1;
      list.push(Math.round(v * 10000) / 10000);
    }
    return {
      response: response,
      dampingFraction: dampingFraction,
      duration: settle,
      easing: "linear(" + list.join(", ") + ")",
      samples: list
    };
  }

  var solvedSprings = {};
  Object.keys(M.springs).forEach(function (key) {
    var s = M.springs[key];
    solvedSprings[key] = solveSpring(s.response, s.dampingFraction);
  });

  /* ---- 把令牌注入 :root，CSS 里只允许 var(--...) 引用 ---- */
  function installTokens() {
    var root = document.documentElement;
    var set = function (k, v) { root.style.setProperty(k, v); };

    set("--m-tap", sec(M.tap));
    set("--m-fast", sec(M.fast));
    set("--m-page", sec(M.page));
    set("--m-slow", sec(M.slow));
    set("--m-loop", sec(M.loop));
    set("--m-progress", sec(M.progress));
    set("--m-open", sec(M.openDuration[M.openPreset]));

    set("--m-ease-out", bezier(M.swiftUIEaseOut));
    set("--m-ca-ease-out", bezier(M.caEaseOut));
    set("--m-ca-ease-in", bezier(M.caEaseIn));
    set("--m-ca-ease-in-out", bezier(M.caEaseInEaseOut));
    set("--m-ca-back-out", bezier(M.caBackOut));
    set("--m-linear", "linear");

    var supportsLinear = !!(window.CSS && CSS.supports &&
      CSS.supports("transition-timing-function", "linear(0, 1)"));
    if (!supportsLinear) root.setAttribute("data-motion-linear-fallback", "1");

    Object.keys(solvedSprings).forEach(function (key) {
      var s = solvedSprings[key];
      var name = key.replace(/([A-Z])/g, "-$1").toLowerCase(); // springSnappy → spring-snappy
      set("--d-" + name, sec(s.duration));
      set("--" + name, supportsLinear ? s.easing : bezier(M.swiftUIEaseOut));
    });

    set("--m-pressed-scale", String(M.pressed.scale));
    set("--m-pressed-opacity", String(M.pressed.opacity));
    set("--m-toast-scale", String(M.toast.scale));
    set("--m-hover-lift", String(M.hoverLift));
    set("--m-reveal-panel", String(M.revealScale.panel));
    set("--m-reveal-preview", String(M.revealScale.preview));
    set("--m-reveal-popout-in", String(M.revealScale.popoutIn));
    set("--m-reveal-popout-out", String(M.revealScale.popoutOut));
    set("--m-popout-appear", sec(M.popoutAppear.duration));
    set("--m-popout-dismiss", sec(M.popoutDismiss.duration));
  }

  /* ---- WindowReveal 的网页等价实现 ----
     App：layer.transform = T(d)·S(scale)·T(-d)，d 由归一化锚点 (u,v) 决定，
     同时叠加 opacity 0→1（入场）/1→0（出场）；模型值先设终态，动画从初态插值。
     CSS：transform-origin = (u·100%, v·100%) 与 T(d)·S·T(-d) 完全等价，
     因此这里只动 transform + opacity，同样不触发布局。 */
  function reveal(el, direction, opts) {
    opts = opts || {};
    if (!el) return null;
    var isIn = direction === "in";
    var scale = opts.scale != null ? opts.scale : M.revealScale.preview;
    var duration = (opts.duration != null
      ? opts.duration
      : M.openDuration[M.openPreset]) * 1000;
    var timingKey = opts.timing || (isIn ? "caEaseOut" : "caEaseIn");
    var easing = bezier(M[timingKey]);
    var unit = opts.unit || { x: 1, y: 0 };

    el.style.transformOrigin =
      (unit.x * 100).toFixed(2) + "% " + (unit.y * 100).toFixed(2) + "%";

    // 对应 WindowReveal 的 layer.removeAllAnimations()：只取消自己的在途动画；
    // 同时撤销它的收尾定时器，否则上一轮的 hidden=true 会把新一轮入场直接关掉。
    if (el.getAnimations) {
      el.getAnimations().forEach(function (a) {
        if (a.id !== "kitnest-reveal") return;
        if (a._kitnestCancel) a._kitnestCancel(); else a.cancel();
      });
    }

    var from = isIn
      ? { opacity: 0, transform: "scale(" + scale + ")" }
      : { opacity: 1, transform: "none" };
    var to = isIn
      ? { opacity: 1, transform: "none" }
      : { opacity: 0, transform: "scale(" + scale + ")" };

    // 模型值 = 终态（App 在 CATransaction 里把 layer 属性直接设成终态）
    el.style.opacity = isIn ? "1" : "0";
    el.style.transform = "none";

    if (!el.animate) {
      if (!isIn && opts.hide) el.hidden = true;
      if (opts.complete) opts.complete();
      return null;
    }

    var anim = el.animate([from, to], {
      duration: duration,
      easing: easing,
      fill: "forwards"
    });
    anim.id = "kitnest-reveal";

    var finished = false;
    var cancelled = false;
    var timer = null;
    var finish = function () {
      if (finished || cancelled) return;
      finished = true;
      if (timer) clearTimeout(timer);
      try { anim.cancel(); } catch (e) { /* 已被取消 */ }
      // WindowReveal.reset：orderOut / close 之后把层复位，避免下次带着缩放态
      if (!isIn && opts.hide) el.hidden = true;
      el.style.opacity = "1";
      el.style.transform = "none";
      if (opts.complete) opts.complete();
    };
    anim.onfinish = finish;
    // 与 App 一样的兜底：动画回调被系统跳过时也一定收尾
    timer = setTimeout(finish, duration + 80);
    anim._kitnestCancel = function () {
      cancelled = true;
      if (timer) clearTimeout(timer);
      try { anim.cancel(); } catch (e) { /* 已被取消 */ }
    };
    return anim;
  }

  function revealIn(el, opts) { return reveal(el, "in", opts); }
  function revealOut(el, opts) { return reveal(el, "out", opts); }

  /* 主面板展开锚点：PanelController.revealUnit —— 菜单栏图标中心投影到面板宽度，y=0；
     无锚点时退回 (1, 0)（状态栏右侧）。 */
  function panelAnchor(iconEl, panelEl) {
    if (!iconEl || !panelEl) return { x: 1, y: 0 };
    var icon = iconEl.getBoundingClientRect();
    var panel = panelEl.getBoundingClientRect();
    if (!panel.width) return { x: 1, y: 0 };
    var u = (icon.left + icon.width / 2 - panel.left) / panel.width;
    return { x: Math.min(1, Math.max(0, u)), y: 0 };
  }

  /* 预览窗锚点：ClipboardPreviewWindow.place —— 预览在面板左侧时取预览右边缘 x=1，
     y = 锚条目中心在预览窗内从上往下的归一化位置。 */
  function previewAnchor(rowRect, previewRect) {
    if (!rowRect || !previewRect || !previewRect.height) return { x: 1, y: 0.5 };
    var v = (rowRect.top + rowRect.height / 2 - previewRect.top) / previewRect.height;
    return { x: 1, y: Math.min(1, Math.max(0, v)) };
  }

  installTokens();

  window.KitnestMotion = {
    tokens: M,
    springs: solvedSprings,
    bezier: bezier,
    solveSpring: solveSpring,
    revealIn: revealIn,
    revealOut: revealOut,
    panelAnchor: panelAnchor,
    previewAnchor: previewAnchor,
    openDuration: function () { return M.openDuration[M.openPreset]; },
    spring: function (name) { return solvedSprings[name] || solvedSprings.spring; }
  };
})();
