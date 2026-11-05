/* ============================================================
   Kitnest 官网脚本
   · hash 路由（首页 / 功能 / 界面 / 下载 / 更新 / 帮助 / 安全）
   · 菜单栏模拟：点小猫展开真实面板截图
   · 界面截图切换、FAQ 折叠、移动端菜单
   · 读取 /kitnest/stable/latest.json 渲染版本、SHA-256 与下载
   页面不写入任何密钥、签名信息或用户数据。
   ============================================================ */

(function () {
  "use strict";

  var $ = function (sel, root) { return (root || document).querySelector(sel); };
  var $$ = function (sel, root) { return Array.prototype.slice.call((root || document).querySelectorAll(sel)); };

  /* ---------------- 反馈 ---------------- */

  var toastTimer = null;
  function toast(message) {
    var el = $("#toast");
    if (!el) return;
    el.textContent = message;
    el.classList.add("show");
    if (toastTimer) clearTimeout(toastTimer);
    toastTimer = setTimeout(function () { el.classList.remove("show"); }, 2400);
  }

  function formatSize(bytes) {
    var mb = bytes / 1024 / 1024;
    return mb >= 100 ? Math.round(mb) + " MiB" : mb.toFixed(1) + " MiB";
  }

  function formatDate(value) {
    if (!value) return "";
    var d = new Date(value);
    if (isNaN(d.getTime())) return String(value);
    var p = function (n) { return n < 10 ? "0" + n : String(n); };
    return d.getFullYear() + "-" + p(d.getMonth() + 1) + "-" + p(d.getDate());
  }

  /* ---------------- 视图路由 ---------------- */

  var VIEWS = ["home", "features", "showcase", "download", "changelog", "help", "privacy"];

  function currentView() {
    var hash = (location.hash || "#home").replace("#", "");
    return VIEWS.indexOf(hash) !== -1 ? hash : "home";
  }

  // 从面板里的按钮跳到官网对应章节：先切视图，再滚到锚点
  var pendingAnchor = null;

  function goTo(view, anchor) {
    pendingAnchor = anchor || null;
    if (currentView() === view) {
      render();
    } else {
      location.hash = "#" + view;      // 触发 hashchange → render()
    }
  }

  function render() {
    var view = currentView();

    VIEWS.forEach(function (name) {
      var el = document.getElementById("view-" + name);
      if (el) el.classList.toggle("active", name === view);
    });

    $$("[data-nav]").forEach(function (a) {
      var target = (a.getAttribute("href") || "").replace("#", "");
      var inMenu = a.closest(".nav-links") || a.closest(".mobile-menu");
      a.classList.toggle("active", !!inMenu && target === view);
    });

    document.title = view === "home"
      ? "Kitnest · 菜单栏里的效率工具集"
      : titleFor(view) + " · Kitnest";

    window.scrollTo({ top: 0, behavior: "auto" });

    if (pendingAnchor) {
      var anchor = pendingAnchor;
      pendingAnchor = null;
      var el = document.getElementById(anchor);
      if (el) {
        setTimeout(function () {
          el.scrollIntoView({ behavior: "smooth", block: "start" });
        }, 60);
      }
    }
    closeMobileMenu();
  }

  function titleFor(view) {
    return {
      home: "首页",
      features: "功能介绍",
      showcase: "界面展示",
      download: "下载",
      changelog: "更新记录",
      help: "帮助",
      privacy: "隐私与安全"
    }[view] || "Kitnest";
  }

  window.addEventListener("hashchange", render);
  $$("[data-nav]").forEach(function (a) {
    a.addEventListener("click", function () {
      if (a.getAttribute("href") === location.hash) render();
    });
  });

  /* ---------------- 移动端菜单 ---------------- */

  var navToggle = $("#navToggle");
  var mobileMenu = $("#mobileMenu");

  function closeMobileMenu() {
    if (mobileMenu) mobileMenu.classList.remove("open");
    if (navToggle) navToggle.setAttribute("aria-expanded", "false");
  }

  if (navToggle && mobileMenu) {
    navToggle.addEventListener("click", function () {
      var open = mobileMenu.classList.toggle("open");
      navToggle.setAttribute("aria-expanded", open ? "true" : "false");
    });
    document.addEventListener("click", function (e) {
      if (!mobileMenu.contains(e.target) && !navToggle.contains(e.target)) closeMobileMenu();
    });
  }

  /* ---------------- 菜单栏模拟 ---------------- */

  var mbIcon = $("#mbIcon");
  var panelMock = $("#panelMock");

  var panelTimer = null;

  function setPanel(open) {
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
  }

  if (mbIcon && panelMock) {
    mbIcon.addEventListener("click", function (e) {
      e.stopPropagation();
      setPanel(panelMock.hidden);
    });
    document.addEventListener("click", function (e) {
      // 真机语义：面板由菜单栏图标切换开合，「点别处就关」是失焦不是误触。
      // 所以只有点舞台（.hero-stage）之外的正文才收起，点菜单栏的部件/图标都保持面板可见。
      //
      // ⚠️ 必须用 composedPath() 而不是 e.target.closest()：点击剪贴板条目后
      // renderClipList() 会重建列表，被点的 <li> 已脱离 DOM，closest 沿「当前」
      // 父链往上找会漏掉 .hero-stage，导致面板被误收起（实测踩过）。
      // composedPath() 保留事件派发那一刻的原始路径，不受重建影响。
      var path = e.composedPath ? e.composedPath() : [];
      for (var i = 0; i < path.length; i++) {
        var node = path[i];
        if (node && node.classList && node.classList.contains("hero-stage")) return;
      }
      if (!panelMock.hidden) setPanel(false);
    });
    document.addEventListener("keydown", function (e) {
      if (e.key === "Escape") setPanel(false);
    });
  }

  /* 玻璃高光跟随指针：把指针位置写进 --lg-x / --lg-y，
     CSS 里用 radial-gradient 画反射光斑（对齐 App 玻璃的镜面感） */
  $$(".lg").forEach(function (el) {
    el.addEventListener("pointermove", function (e) {
      var r = el.getBoundingClientRect();
      el.style.setProperty("--lg-x", (e.clientX - r.left) + "px");
      el.style.setProperty("--lg-y", (e.clientY - r.top) + "px");
    });
    el.addEventListener("pointerleave", function () {
      el.style.setProperty("--lg-x", "50%");
      el.style.setProperty("--lg-y", "0%");
    });
  });

  /* ---------------- 部件浮窗 ---------------- */

  var WIDGETS = {
    cpu: {
      title: "CPU",
      value: "23%",
      html: '<div class="mb-corebars">' +
        [22, 31, 18, 46, 25, 19, 12, 9].map(function (v, i) {
          return '<i class="' + (v > 40 ? "hot" : "") + '" style="height:' + (v * 1.8) + '%"></i>';
        }).join("") +
        '</div><div class="mb-kv"><span>系统 <b>12%</b></span><span>用户 <b>9%</b></span><span>空闲 <b>79%</b></span></div>'
    },
    net: {
      title: "网络",
      value: "↓ 1.2 MB/s",
      html: '<svg class="mb-spark" viewBox="0 0 200 46" preserveAspectRatio="none" aria-hidden="true">' +
        '<polyline points="0,34 18,30 36,33 54,24 72,27 90,18 108,22 126,12 144,17 162,9 180,14 200,7" ' +
        'fill="none" stroke="#2F6BFF" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/></svg>' +
        '<div class="mb-kv"><span>上行 <b>86 KB/s</b></span><span>延迟 <b>24 ms</b></span><span>连接 <b>Wi-Fi</b></span></div>'
    },
    batt: {
      title: "电池",
      value: "87%",
      html: '<div class="mb-ring">' +
        '<svg viewBox="0 0 60 60" aria-hidden="true"><circle cx="30" cy="30" r="24" fill="none" stroke="#EDEDF2" stroke-width="7"/>' +
        '<circle cx="30" cy="30" r="24" fill="none" stroke="#1F9D63" stroke-width="7" stroke-linecap="round" ' +
        'stroke-dasharray="131 151" transform="rotate(-90 30 30)"/></svg>' +
        '<div><div style="font-size:12px;color:#8A8A94">预计剩余</div>' +
        '<div style="font-size:14px;color:#0B0B0D;font-weight:600">4 小时 12 分</div>' +
        '<div style="font-size:11px;color:#8A8A94;margin-top:2px">适配器 45W · 循环 128 次</div></div></div>'
    }
  };

  var mbPop = $("#mbPop");

  function closeWidgetPop() {
    if (!mbPop) return;
    mbPop.hidden = true;
    $$(".mb-widget").forEach(function (b) { b.setAttribute("aria-expanded", "false"); });
  }

  if (mbPop) {
    $$(".mb-widget").forEach(function (btn) {
      btn.addEventListener("click", function (e) {
        e.stopPropagation();
        var key = btn.getAttribute("data-widget");
        var w = WIDGETS[key];
        if (!w) return;
        var open = !mbPop.hidden && btn.getAttribute("aria-expanded") === "true";
        if (open) { closeWidgetPop(); return; }
        $("#mbPopTitle").textContent = w.title;
        $("#mbPopValue").textContent = w.value;
        $("#mbPopBody").innerHTML = w.html;
        mbPop.hidden = false;
        $$(".mb-widget").forEach(function (b) { b.setAttribute("aria-expanded", "false"); });
        btn.setAttribute("aria-expanded", "true");
      });
    });
    document.addEventListener("click", function (e) {
      if (!mbPop.contains(e.target)) closeWidgetPop();
    });
  }

  /* ---------------- 可交互主面板（对齐真机 PanelRootView） ---------------- */

  /*
     数据全部是写死的演示条目，对应真机里预灌进剪贴板的那几条
     （JSON / Markdown / Swift / Python / 图片 / 链接 / 文字），不碰用户真实剪贴板。
  */
  var CLIP_ITEMS = [
    { id: "c1", kind: "url", badge: "chrome", app: "Safari",
      title: "https://example.com/kitnest/release",
      meta: "今天 12:15 · 32 个字符",
      view: "link",
      preview: '<span class="pv-kind">链接</span><code>https://example.com/kitnest/release</code><br>双击条目会复制这条链接。' },
    { id: "c2", kind: "text", badge: "code", app: "备忘录",
      title: "周报草稿：第三部分的发布流程还需要补充回滚说明",
      meta: "今天 12:08 · 45 个字符",
      view: "text",
      preview: '<span class="pv-kind">文字</span>周报草稿：第三部分的发布流程还需要补充回滚说明。' },
    { id: "c3", kind: "md", badge: "md", app: "备忘录",
      title: "# Kitnest 演示仓库（示例内容）",
      meta: "今天 12:08 · 263 个字符",
      view: "markdown",
      preview: '<span class="pv-kind">Markdown</span><pre># Kitnest 演示仓库（示例内容）\n\n## 功能\n- 剪贴板历史\n- 截图标注\n- 系统监控</pre>' },
    { id: "c4", kind: "json", badge: "json", app: "访达",
      title: '{ "name": "kitnest-demo.config.json",',
      meta: "今天 12:08 · 647 个字符",
      view: "json",
      preview: '<span class="pv-kind">JSON</span><pre>{\n  "name": "kitnest-demo.config.json",\n  "app": "kitnest-demo",\n  "version": "1.0.0",\n  "features": {\n    "clipboard": { "keepDays": 30 },\n    "monitor": { "refreshSeconds": 1.5 }\n  }\n}</pre>' },
    { id: "c5", kind: "code", badge: "code", app: "Xcode",
      title: "// Sample.swift —— 演示用代码（假数据）",
      meta: "今天 12:08 · 412 个字符",
      view: "code",
      preview: '<span class="pv-kind">代码</span><pre>// Sample.swift —— 演示用代码（假数据）\nimport Foundation\n\nstruct ClipItem {\n    let kind: String\n    let title: String\n}</pre>' },
    { id: "c6", kind: "code", badge: "code", app: "PyCharm",
      title: "# sample.py —— 演示用代码（假数据）",
      meta: "今天 12:08 · 356 个字符",
      view: "code",
      preview: '<span class="pv-kind">代码</span><pre># sample.py —— 演示用代码（假数据）\nimport hashlib\n\ndef sha256(path: str) -> str:\n    h = hashlib.sha256()\n    with open(path, "rb") as f:\n        for chunk in iter(lambda: f.read(65536), b""):\n            h.update(chunk)\n    return h.hexdigest()</pre>' },
    { id: "c7", kind: "img", badge: "img", app: "预览",
      title: "屏幕快照 2026-11-05 14.32.png",
      meta: "今天 11:50 · 1024×1024 pt",
      view: "image",
      preview: '<span class="pv-kind">图片</span>1024×1024 pt。图片条目会显示缩略图，可以直接贴图或钉在屏幕上。' },
    { id: "c8", kind: "text", badge: "code", app: "备忘录",
      title: "TODO：把安装包校验写进发版脚本",
      meta: "昨天 18:24 · 26 个字符",
      view: "text",
      preview: '<span class="pv-kind">文字</span>TODO：把安装包校验写进发版脚本。' }
  ];

  /* 搜索结果源：真机是网页 / 剪贴板 / 文件 / 工具四类检索源，这里用同样的分类结构 */
  var SEARCH_SOURCES = [
    { kind: "tool", label: "工具", items: [
      { title: "/hash", sub: "计算哈希", act: "hash" },
      { title: "/qr", sub: "生成二维码", act: "qr" },
      { title: "/ip", sub: "查看本机 IP", act: "ip" },
      { title: "/convert", sub: "媒体格式转换", act: "convert" }
    ] },
    { kind: "clip", label: "剪贴板", items: [] },
    { kind: "file", label: "文件", items: [
      { title: "发布流程-checklist.md", sub: "~/Desktop", act: "file" },
      { title: "kitnest-demo.config.json", sub: "~/Desktop", act: "file" }
    ] }
  ];

  var pmList = $("#pmList");
  var pmBody = $("#pmBody");
  var pmPreview = $("#pmPreview");
  var pmSearch = $("#pmSearch");
  var pmResults = $("#pmResults");
  var pmMenu = $("#pmMenu");
  var pmMenuList = $("#pmMenuList");
  var pmCtx = $("#pmCtx");
  var pmCtxList = $("#pmCtxList");
  var pmDock = $("#pmDock");
  var pmJumpHint = $("#pmJumpHint");
  var pmCalGrid = $("#pmCalGrid");

  var clipState = {
    items: CLIP_ITEMS.slice(),
    selected: [],      // ⌘/⇧ 点击多选
    anchor: -1,
    query: "",
    calAnchor: new Date(2026, 10, 1),
    calFolded: false,
    calSelected: null,
    filter: "all",
    menuOpen: null,
    ctxItem: null
  };

  /* ---------------- 图标 ---------------- */

  var PM_ICONS = {
    text: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><path d="M6.5 3.5h8L18.5 7v13.5h-12z"/><path d="M14.5 3.5V7h4"/><path d="M9.5 11h5M9.5 14.5h5"/></svg>',
    url: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><rect x="3.5" y="5" width="17" height="14" rx="2"/><path d="M7 9.5h4M7 13h7"/><path d="M15 9.5h2"/></svg>',
    img: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><rect x="3.5" y="4.5" width="17" height="15" rx="2"/><circle cx="9" cy="10" r="1.5"/><path d="m4.5 17.5 4.5-4.5 3.5 3.5 3-3 4 4"/></svg>',
    code: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><path d="M6.5 3.5h8L18.5 7v13.5h-12z"/><path d="M14.5 3.5V7h4"/><path d="m10 12-2 2 2 2M14 12l2 2-2 2"/></svg>',
    json: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><path d="M6.5 3.5h8L18.5 7v13.5h-12z"/><path d="M14.5 3.5V7h4"/><path d="M10 11.5c-1 0-1.3.7-1.3 1.4v.8c0 .6-.4 1-1 1 .6 0 1 .4 1 1v.8c0 .7.3 1.4 1.3 1.4M14 11.5c1 0 1.3.7 1.3 1.4v.8c0 .6.4 1 1 1-.6 0-1 .4-1 1v.8c0 .7-.3 1.4-1.3 1.4"/></svg>',
    md: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><path d="M6.5 3.5h8L18.5 7v13.5h-12z"/><path d="M14.5 3.5V7h4"/><path d="M9.5 11v4.5M12 11v4.5M14.5 11v4.5"/></svg>',
    file: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><path d="M6.5 3.5h8L18.5 7v13.5h-12z"/><path d="M14.5 3.5V7h4"/></svg>',
    down: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M12 4v12m0 0 4.5-4.5M12 16l-4.5-4.5M5 20h14"/></svg>',
    paste: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M9 4.5h6v2H9z"/><path d="M9 5.5H6.5A1.5 1.5 0 0 0 5 7v12.5A1.5 1.5 0 0 0 6.5 21h11a1.5 1.5 0 0 0 1.5-1.5V7a1.5 1.5 0 0 0-1.5-1.5H15"/><path d="m9 13 3 3 3-3"/></svg>'
  };

  /* 来源应用徽章：真机是 16×16 的来源 App 图标，这里用对应的简化图形 */
  var BADGE_ICONS = {
    chrome: '<svg viewBox="0 0 24 24" fill="none"><circle cx="12" cy="12" r="9" fill="#4285F4"/><path d="M12 3a9 9 0 0 1 7.8 4.5H12a4.5 4.5 0 0 0-4 6.2L4.5 8.7A9 9 0 0 1 12 3Z" fill="#EA4335"/><path d="M3.6 9.6 8 14.8a4.5 4.5 0 0 0 6.4 1.9l-3 4.3A9 9 0 0 1 3.6 9.6Z" fill="#34A853"/><path d="M12 21a9 9 0 0 0 7.9-4.6H12.4a4.5 4.5 0 0 1-4-2.6l-3.1 4.5A9 9 0 0 0 12 21Z" fill="#FBBC05"/></svg>',
    code: '<svg viewBox="0 0 24 24" fill="none" stroke="#FFFFFF" stroke-width="2.4" stroke-linecap="round" stroke-linejoin="round"><path d="m9 8-4 4 4 4M15 8l4 4-4 4"/></svg>',
    md: '<svg viewBox="0 0 24 24" fill="none" stroke="#FFFFFF" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round"><path d="M4 6.5h16M4 12h16M4 17.5h10"/></svg>',
    json: '<svg viewBox="0 0 24 24" fill="none" stroke="#FFFFFF" stroke-width="2.2" stroke-linecap="round"><path d="M9.5 5c-1.6 0-2 1-2 2v3c0 1-.5 1.4-1.4 1.4v1.6c.9 0 1.4.4 1.4 1.4v3c0 1 .4 2 2 2"/><path d="M14.5 5c1.6 0 2 1 2 2v3c0 1 .5 1.4 1.4 1.4v1.6c-.9 0-1.4.4-1.4 1.4v3c0 1-.4 2-2 2"/></svg>',
    img: '<svg viewBox="0 0 24 24" fill="none" stroke="#FFFFFF" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><rect x="4.5" y="6" width="15" height="12" rx="1.6"/><circle cx="9.5" cy="10" r="1.2"/><path d="m5.5 16.5 4-4 3 3 2.5-2.5 3.5 3.5"/></svg>',
    url: '<svg viewBox="0 0 24 24" fill="none" stroke="#FFFFFF" stroke-width="2.2" stroke-linecap="round"><circle cx="12" cy="12" r="8"/></svg>'
  };

  var MENU_ICONS = {
    viewfinder: PM_ICONS.code,
    rect: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6"><rect x="4" y="5" width="16" height="14" rx="1.5"/></svg>',
    text: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round"><path d="M5 6.5h14M12 6.5v11M9 17.5h6"/></svg>',
    record: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6"><circle cx="12" cy="12" r="7.5"/></svg>',
    pin: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round"><path d="M12 3.5v11m0 0 4-4m-4 4-4-4M5 19.5h14"/></svg>',
    window: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6"><rect x="3.5" y="5.5" width="17" height="13" rx="1.5"/><path d="M3.5 9.5h17"/></svg>',
    pause: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round"><path d="M9.5 5.5v13M14.5 5.5v13"/></svg>',
    gear: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5"><circle cx="12" cy="12" r="3"/><path d="M12 3v2.5M12 18.5V21M3 12h2.5M18.5 12H21M5.6 5.6l1.8 1.8M16.6 16.6l1.8 1.8M18.4 5.6l-1.8 1.8M7.4 16.6l-1.8 1.8"/></svg>',
    chart: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round"><path d="M5 19V9M10 19V5M15 19v-7M20 19v-4"/></svg>',
    quit: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round"><path d="M10 5.5H6.5A1.5 1.5 0 0 0 5 7v10a1.5 1.5 0 0 0 1.5 1.5H10M14.5 8.5 18 12l-3.5 3.5M18 12h-9"/></svg>',
    doc: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round"><rect x="8" y="8" width="12" height="12" rx="1.5"/><path d="M16 8V6.5A1.5 1.5 0 0 0 14.5 5h-8A1.5 1.5 0 0 0 5 6.5v8A1.5 1.5 0 0 0 6.5 16H8"/></svg>',
    airdrop: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round"><path d="M12 4.5a7.5 7.5 0 0 1 7.5 7.5M12 8a4 4 0 0 1 4 4M12 11.5a1 1 0 0 1 1 1"/><path d="M12 16.5h.01"/></svg>',
    pencil: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"><path d="m5 19 1-3.5L16 5.5a1.8 1.8 0 0 1 2.5 2.5L8.5 18 5 19z"/></svg>',
    cursor: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round"><path d="M7 4.5 17 11l-4.2 1.2L11 17z"/></svg>',
    note: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round"><rect x="4.5" y="4.5" width="15" height="15" rx="2"/><path d="M8 9h8M8 13h5"/></svg>',
    sparkles: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"><path d="M12 4.5 13.4 9l4.6 1.4-4.6 1.4L12 16.5l-1.4-4.7L6 10.4 10.6 9z"/></svg>',
    tag: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linejoin="round"><path d="M4 7h16l-6.5 8v5l-3 2v-7z"/></svg>',
    trash: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round"><path d="M4.5 6.5h15M9 6.5V4.8A1.3 1.3 0 0 1 10.3 3.5h3.4A1.3 1.3 0 0 1 15 4.8v1.7M6.5 6.5l.8 13a1.3 1.3 0 0 0 1.3 1.2h6.8a1.3 1.3 0 0 0 1.3-1.2l.8-13"/></svg>'
  };

  /* ---------------- 剪贴板列表渲染 ---------------- */

  function visibleItems() {
    var q = clipState.query.trim().toLowerCase();
    var out = clipState.items.filter(function (it) {
      if (clipState.filter !== "all" && it.kind !== clipState.filter) return false;
      if (!q) return true;
      return (it.title + " " + it.meta).toLowerCase().indexOf(q) >= 0;
    });
    return out;
  }

  function renderClipList() {
    if (!pmList) return;
    var items = visibleItems();
    pmList.innerHTML = "";
    if (!items.length) {
      var empty = document.createElement("li");
      empty.className = "pm-empty";
      empty.innerHTML = '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.4"><rect x="4" y="5" width="16" height="15" rx="2"/><path d="M8 10h8M8 14h5"/></svg>' +
        (clipState.query ? "没有匹配的结果" : "还没有剪贴板记录");
      pmList.appendChild(empty);
      return;
    }
    items.forEach(function (it) {
      var li = document.createElement("li");
      li.className = "pm-item";
      li.setAttribute("data-id", it.id);
      if (clipState.selected.indexOf(it.id) >= 0) li.classList.add("sel");
      li.innerHTML =
        '<span class="pm-thumb ' + it.kind + '">' + PM_ICONS[it.kind] + (it.badge ?
          '<span class="pm-badge ' + it.badge + '">' + (BADGE_ICONS[it.badge] || "") + '</span>' : "") +
        '</span>' +
        '<span class="pm-main"><span class="pm-title"></span><span class="pm-meta"></span></span>' +
        '<span class="pm-rowacts">' +
          '<button type="button" data-row-act="copy" title="复制" aria-label="复制">' + PM_ICONS.down + '</button>' +
          '<button type="button" data-row-act="paste" title="复制并粘贴" aria-label="复制并粘贴">' + PM_ICONS.paste + '</button>' +
        '</span>';
      li.querySelector(".pm-title").textContent = it.title;
      li.querySelector(".pm-meta").textContent = it.meta;
      pmList.appendChild(li);
    });
  }

  /* ---------------- 预览浮层（真机：单击/悬停出，移出即关） ---------------- */

  var previewPinned = false;

  function closePreview() {
    if (!pmPreview) return;
    pmPreview.hidden = true;
    previewPinned = false;
  }

  function showPreview(item, anchorEl, pinned) {
    if (!pmPreview || !item) return;
    previewPinned = !!pinned;
    pmPreview.querySelector(".pm-preview-body").innerHTML = item.preview;
    pmPreview.hidden = false;
    // 贴着锚行：下方放得下就放下方，否则翻到上方。
    // 位置基准是内容区（.pm-body），不是列表——li.offsetTop 是相对 .pm-list 的，
    // 直接用会把预览顶到日历上（实测踩过）。这里用 rect 差值算相对内容区的偏移。
    var bodyRect = pmBody.getBoundingClientRect();
    var bodyH = pmBody.clientHeight;
    var h = pmPreview.offsetHeight || 140;
    var rowRect = anchorEl ? anchorEl.getBoundingClientRect() : null;
    var rowTop = rowRect ? (rowRect.top - bodyRect.top + pmBody.scrollTop) : 0;
    var rowH = rowRect ? rowRect.height : 0;
    var below = rowTop + rowH + 6;
    var above = rowTop - h - 6;
    var top;
    if (below + h <= bodyH - 6) {
      top = below;
    } else if (above >= 6) {
      top = above;
    } else {
      top = Math.max(6, bodyH - h - 6);
    }
    pmPreview.style.top = top + "px";
  }

  /* ---------------- 日历（真机 CalendarSectionView：两周网格 + 农历） ---------------- */

  var LUNAR = {
    "2026-11-01": "廿三", "2026-11-02": "廿四", "2026-11-03": "廿五",
    "2026-11-04": "廿六", "2026-11-05": "廿七", "2026-11-06": "廿八",
    "2026-11-07": "廿九", "2026-11-08": "三十", "2026-11-09": "初一",
    "2026-11-10": "初二", "2026-11-11": "初三", "2026-11-12": "初四",
    "2026-11-13": "初五", "2026-11-14": "初六", "2026-11-15": "初七",
    "2026-11-16": "初八", "2026-11-17": "初九", "2026-11-18": "初十",
    "2026-11-19": "十一", "2026-11-20": "十二", "2026-11-21": "十三",
    "2026-11-22": "十四", "2026-11-23": "十五", "2026-11-24": "十六",
    "2026-11-25": "十七", "2026-11-26": "十八", "2026-11-27": "十九",
    "2026-11-28": "二十", "2026-11-29": "廿一", "2026-11-30": "廿二"
  };
  var FESTIVAL = { "2026-11-07": "立冬" };

  function pad2(n) { return n < 10 ? "0" + n : String(n); }

  function dayKey(d) {
    return d.getFullYear() + "-" + pad2(d.getMonth() + 1) + "-" + pad2(d.getDate());
  }

  function renderCalendar() {
    if (!pmCalGrid) return;
    var anchor = clipState.calAnchor;
    // 归一化到所在周的周日（真机 shift(±7) 就是按周走）
    var start = new Date(anchor.getFullYear(), anchor.getMonth(), anchor.getDate());
    start.setDate(start.getDate() - start.getDay());
    var today = new Date(2026, 10, 5);
    pmCalGrid.innerHTML = "";
    // 「今天」高亮只在今天确实落在当前两周窗口里时出现
    for (var i = 0; i < 14; i++) {
      var d = new Date(start.getFullYear(), start.getMonth(), start.getDate() + i);
      var key = dayKey(d);
      var inMonth = d.getMonth() === anchor.getMonth();
      var btn = document.createElement("button");
      btn.type = "button";
      btn.className = "pm-day";
      if (!inMonth) btn.classList.add("muted");
      if (key === dayKey(today)) btn.classList.add("today");
      if (clipState.calSelected === key) btn.classList.add("sel");
      var sub = FESTIVAL[key] || LUNAR[key] || "";
      btn.innerHTML = '<span class="pm-day-in"><b>' + d.getDate() + "</b><span>" + sub + "</span></span>";
      if (FESTIVAL[key]) btn.classList.add("festival");
      btn.setAttribute("data-day", key);
      pmCalGrid.appendChild(btn);
    }
    var title = $(".pm-cal-title");
    if (title) {
      title.textContent = anchor.getFullYear() + "年" + (anchor.getMonth() + 1) + "月";
    }
    var cal = $(".pm-cal");
    if (cal) cal.classList.toggle("folded", clipState.calFolded);
  }

  /* ---------------- 悬浮菜单（真机 NSMenu） ---------------- */

  var MENUS = {
    capture: [
      { icon: "viewfinder", label: "截图", act: "cap-area" },
      { icon: "rect", label: "窗口截图", act: "cap-window" },
      { sep: true },
      { icon: "text", label: "划词翻译", act: "cap-translate" },
      { icon: "record", label: "录屏", act: "cap-record" }
    ],
    gear: [
      { icon: "pin", label: "置顶窗口", key: "⌘P", act: "pin" },
      { icon: "window", label: "悬浮剪贴板", key: "⇧⌘V", act: "float" },
      { sep: true },
      { icon: "pause", label: "暂停记录剪贴板", act: "pause" },
      { icon: "gear", label: "设置", key: "⌘,", act: "settings" },
      { icon: "chart", label: "使用统计", act: "stats" },
      { sep: true },
      { icon: "quit", label: "退出", key: "⌘Q", act: "quit" }
    ],
    filter: [
      { label: "全部", act: "filter:all" },
      { label: "文字", act: "filter:text" },
      { label: "链接", act: "filter:url" },
      { label: "图片", act: "filter:img" },
      { label: "代码", act: "filter:code" },
      { label: "JSON", act: "filter:json" },
      { label: "Markdown", act: "filter:md" }
    ]
  };

  function openMenu(kind, anchorEl) {
    if (!pmMenu || !pmMenuList) return;
    var items = MENUS[kind];
    if (!items) return;
    pmMenuList.innerHTML = "";
    items.forEach(function (m) {
      var li = document.createElement("li");
      if (m.sep) {
        li.className = "sep";
      } else {
        li.innerHTML = (m.icon ? '<span class="mi-ico">' + (MENU_ICONS[m.icon] || "") + "</span>" : "") +
          "<span>" + m.label + "</span>" +
          (m.key ? '<span class="mi-key">' + m.key + "</span>" : "");
        li.setAttribute("data-menu-act", m.act || "");
      }
      pmMenuList.appendChild(li);
    });
    pmMenu.hidden = false;
    clipState.menuOpen = kind;
    // 贴着触发按钮定位（菜单是 panelMock 的绝对定位子元素，基准用 panelMock）
    var host = pmMenu.offsetParent || panelHost();
    var hostRect = host.getBoundingClientRect();
    var r = anchorEl.getBoundingClientRect();
    var mr = pmMenu.getBoundingClientRect();
    var left = r.left - hostRect.left;
    var top = r.bottom - hostRect.top + 4;
    if (left + mr.width > hostRect.width) left = hostRect.width - mr.width;
    if (left < 0) left = 0;
    pmMenu.style.left = left + "px";
    pmMenu.style.top = top + "px";
  }

  function closeMenu() {
    if (pmMenu) pmMenu.hidden = true;
    clipState.menuOpen = null;
  }

  function menuAction(act) {
    if (!act) return;
    if (act.indexOf("filter:") === 0) {
      clipState.filter = act.slice(7);
      renderClipList();
      var btn = pmDock && pmDock.querySelector('[data-pm-menu="filter"]');
      if (btn) btn.classList.toggle("active", clipState.filter !== "all");
      toast(clipState.filter === "all" ? "已显示全部类型" : "只看" + clipState.filter);
      closeMenu();
      return;
    }
    var map = {
      "cap-area": "开始区域截图",
      "cap-window": "开始窗口截图",
      "cap-translate": "划词翻译已就绪",
      "cap-record": "开始录屏",
      "pin": "面板已置顶",
      "float": "悬浮剪贴板已打开",
      "pause": "已暂停记录剪贴板",
      "settings": "打开设置",
      "stats": "打开使用统计",
      "quit": "退出 Kitnest"
    };
    toast(map[act] || act);
    closeMenu();
  }

  /* ---------------- 右键菜单（真机 ClipboardNativeMenuPresenter） ---------------- */

  var CTX_ITEMS = [
    { icon: "doc", label: "复制", act: "copy" },
    { icon: "airdrop", label: "隔空投送", act: "airdrop", dis: true },
    { icon: "pencil", label: "编辑", act: "edit" },
    { icon: "cursor", label: "重命名", act: "rename" },
    { icon: "note", label: "标记为笔记", act: "note" },
    { icon: "sparkles", label: "AI 摘要", act: "summary" },
    { icon: "tag", label: "标签", act: "tags" },
    { sep: true },
    { icon: "trash", label: "删除", act: "delete" }
  ];

  function openCtx(item, anchorEl, clientX, clientY) {
    if (!pmCtx || !pmCtxList) return;
    clipState.ctxItem = item;
    pmCtxList.innerHTML = "";
    CTX_ITEMS.forEach(function (m) {
      var li = document.createElement("li");
      if (m.sep) {
        li.className = "sep";
      } else {
        li.innerHTML = '<span class="mi-ico">' + (MENU_ICONS[m.icon] || "") + "</span><span>" + m.label + "</span>";
        if (m.dis) li.classList.add("dis");
        li.setAttribute("data-ctx-act", m.act);
      }
      pmCtxList.appendChild(li);
    });
    pmCtx.hidden = false;
    var host = pmCtx.offsetParent || panelHost();
    var hostRect = host.getBoundingClientRect();
    var mr = pmCtx.getBoundingClientRect();
    var left = clientX - hostRect.left;
    var top = clientY - hostRect.top;
    if (left + mr.width > hostRect.width) left = hostRect.width - mr.width;
    if (top + mr.height > hostRect.height) top = Math.max(0, hostRect.height - mr.height);
    pmCtx.style.left = Math.max(0, left) + "px";
    pmCtx.style.top = Math.max(0, top) + "px";
  }

  function closeCtx() {
    if (pmCtx) pmCtx.hidden = true;
    clipState.ctxItem = null;
  }

  function ctxAction(act) {
    var item = clipState.ctxItem;
    if (!item) return;
    if (act === "delete") {
      clipState.items = clipState.items.filter(function (x) { return x.id !== item.id; });
      renderClipList();
      toast("已删除");
    } else if (act === "copy") {
      toast("已复制");
    } else if (act === "note") {
      toast("已标记为笔记");
    } else if (act === "summary") {
      toast("正在生成摘要");
    } else if (act === "tags") {
      toast("打开标签管理");
    } else if (act === "airdrop") {
      toast("隔空投送");
    } else {
      toast("打开编辑窗口");
    }
    closeCtx();
  }

  /* ---------------- 搜索区段（真机 SearchSectionView） ---------------- */

  function renderSearchResults() {
    if (!pmResults) return;
    var q = clipState.query.trim();
    if (!q) {
      pmResults.hidden = true;
      pmResults.innerHTML = "";
      return;
    }
    var isCommand = q.charAt(0) === "/";
    var token = isCommand ? q.slice(1).toLowerCase() : q.toLowerCase();
    var rows = [];

    if (isCommand) {
      // 命令模式：真机 SlashCommandCatalog —— 每行显示 /token
      SEARCH_SOURCES[0].items.forEach(function (t) {
        if (!token || t.title.toLowerCase().indexOf(token) >= 0) {
          rows.push({ kind: "code", title: t.title, sub: t.sub });
        }
      });
    } else {
      // 普通关键词：分类 chips + 结果（真机分类 = 网页 / 剪贴板 / 文件 / 工具）
      clipState.items.forEach(function (it) {
        if (it.title.toLowerCase().indexOf(token) >= 0) {
          rows.push({ kind: it.kind === "url" ? "url" : (it.kind === "img" ? "img" : (it.kind === "json" ? "json" : (it.kind === "md" ? "md" : "code"))), title: it.title, sub: it.meta });
        }
      });
      SEARCH_SOURCES[2].items.forEach(function (t) {
        if (t.title.toLowerCase().indexOf(token) >= 0) {
          rows.push({ kind: "md", title: t.title, sub: t.sub });
        }
      });
      SEARCH_SOURCES[0].items.forEach(function (t) {
        if (t.title.toLowerCase().indexOf(token) >= 0) {
          rows.push({ kind: "code", title: t.title, sub: t.sub });
        }
      });
    }

    if (!rows.length) {
      pmResults.innerHTML = '<ul><li class="dis">没有匹配的结果</li></ul>';
      pmResults.hidden = false;
      return;
    }
    var ul = document.createElement("ul");
    rows.slice(0, 8).forEach(function (r) {
      var li = document.createElement("li");
      var kd = document.createElement("span");
      kd.className = "r-kind " + r.kind;
      kd.textContent = r.kind === "url" ? "链" : r.kind === "img" ? "图" : r.kind === "json" ? "JS" : r.kind === "md" ? "MD" : "码";
      var b = document.createElement("b");
      b.textContent = r.title;
      var sp = document.createElement("span");
      sp.textContent = r.sub;
      li.appendChild(kd); li.appendChild(b); li.appendChild(sp);
      ul.appendChild(li);
    });
    pmResults.innerHTML = "";
    pmResults.appendChild(ul);
    pmResults.hidden = false;
  }

  /* ---------------- 事件绑定 ---------------- */

  if (pmSearch) {
    pmSearch.addEventListener("input", function () {
      clipState.query = pmSearch.value;
      renderClipList();
      renderSearchResults();
    });
    pmSearch.addEventListener("focus", function () {
      if (clipState.query) renderSearchResults();
    });
    pmSearch.addEventListener("keydown", function (e) {
      if (e.key === "Escape") {
        pmSearch.value = "";
        clipState.query = "";
        renderClipList();
        renderSearchResults();
        pmSearch.blur();
      }
    });
  }

  if (pmList) {
    // hover：出预览浮层（真机 hover 是临时 NSPopover，移出即关）
    pmList.addEventListener("mouseover", function (e) {
      var li = e.target.closest(".pm-item");
      if (!li) return;
      if (previewPinned) return;
      var item = findItem(li.getAttribute("data-id"));
      if (item) showPreview(item, li);
    });
    pmList.addEventListener("mouseleave", function () {
      if (previewPinned) return;
      if (!pmCtx || pmCtx.hidden) closePreview();
    });

    pmList.addEventListener("click", function (e) {
      var act = e.target.closest("[data-row-act]");
      if (act) {
        e.stopPropagation();
        var li = act.closest(".pm-item");
        var item = findItem(li.getAttribute("data-id"));
        toast(act.getAttribute("data-row-act") === "copy" ? "已复制" : "已复制并粘贴");
        return;
      }
      var li = e.target.closest(".pm-item");
      if (!li) return;
      var item = findItem(li.getAttribute("data-id"));
      if (!item) return;

      // ⌘/⇧ 点击 = 多选（真机 handleModifierClick）
      if (e.metaKey || e.ctrlKey || e.shiftKey) {
        e.preventDefault();
        var idx = clipState.selected.indexOf(item.id);
        if (e.shiftKey && clipState.anchor >= 0) {
          clipState.selected = [];
          var lo = Math.min(clipState.anchor, clipState.items.indexOf(item));
          var hi = Math.max(clipState.anchor, clipState.items.indexOf(item));
          for (var k = lo; k <= hi; k++) clipState.selected.push(clipState.items[k].id);
        } else if (idx >= 0) {
          clipState.selected.splice(idx, 1);
        } else {
          clipState.selected.push(item.id);
          clipState.anchor = clipState.items.indexOf(item);
        }
        renderClipList();
        toast("已选 " + clipState.selected.length + " 项");
        return;
      }

      // 普通单击 = 开预览（真机 v182：单击走轻量预览路径）
      clipState.selected = [item.id];
      renderClipList();
      showPreview(item, li, true);
    });

    // 键盘：⌘A 全选、Esc 清空选择（真机表格支持的多选语义）
    pmList.setAttribute("tabindex", "-1");
    document.addEventListener("keydown", function (e) {
      if (!pmList || !pmList.contains(document.activeElement) &&
          document.activeElement !== pmSearch) return;
      if ((e.metaKey || e.ctrlKey) && e.key.toLowerCase() === "a") {
        e.preventDefault();
        clipState.selected = visibleItems().map(function (it) { return it.id; });
        renderClipList();
        toast("已选 " + clipState.selected.length + " 项");
      } else if (e.key === "Escape") {
        clipState.selected = [];
        renderClipList();
      }
    });

    pmList.addEventListener("dblclick", function (e) {
      var li = e.target.closest(".pm-item");
      if (!li) return;
      var item = findItem(li.getAttribute("data-id"));
      if (item) toast("已复制：" + item.title.slice(0, 18));
    });

    pmList.addEventListener("contextmenu", function (e) {
      e.preventDefault();
      var li = e.target.closest(".pm-item");
      if (!li) return;
      var item = findItem(li.getAttribute("data-id"));
      if (item) openCtx(item, li, e.clientX, e.clientY);
    });
  }

  function panelHost() {
    var p = $("#panelMock");
    return p || document.body;
  }

  function findItem(id) {
    for (var i = 0; i < clipState.items.length; i++) {
      if (clipState.items[i].id === id) return clipState.items[i];
    }
    return null;
  }

  if (pmBody) {
    pmBody.addEventListener("mouseleave", function () {
      // 单击打开的预览是「固定」的（真机 v182：单击走轻量预览路径，移出即关；
      // 但网页里浮层会挡住指针，所以单击后保持到再点空白/切页/点别处）
      if (!previewPinned) closePreview();
      if (pmCtx && !pmCtx.hidden) closeCtx();
    });
  }

  /* 顶部工具条 / 底部工具条的按钮 */
  $$("[data-pm-menu]").forEach(function (el) {
    el.addEventListener("click", function (e) {
      e.stopPropagation();
      var kind = el.getAttribute("data-pm-menu");
      if (clipState.menuOpen === kind) { closeMenu(); return; }
      closeMenu();
      openMenu(kind, el);
    });
  });

  $$("[data-pm-act]").forEach(function (el) {
    el.addEventListener("click", function (e) {
      e.stopPropagation();
      var act = el.getAttribute("data-pm-act");
      if (act === "cal-prev" || act === "cal-next") {
        var d = clipState.calAnchor;
        clipState.calAnchor = new Date(d.getFullYear(), d.getMonth(), d.getDate() + (act === "cal-next" ? 7 : -7));
        renderCalendar();
        return;
      }
      if (act === "cal-today") {
        clipState.calAnchor = new Date(2026, 10, 1);
        clipState.calSelected = null;
        renderCalendar();
        return;
      }
      if (act === "cal-fold") {
        clipState.calFolded = !clipState.calFolded;
        renderCalendar();
        return;
      }
      if (act === "dock-search") {
        if (pmSearch) { pmSearch.focus(); pmSearch.select(); }
        return;
      }
      if (act === "dock-tag") {
        toast("打开标签管理");
        return;
      }
      if (act === "dock-top") {
        if (pmBody) pmBody.scrollTo({ top: 0, behavior: "smooth" });
        toast("已回到顶部");
        return;
      }
      if (act === "pick") { toast("取色器已就绪"); return; }
      if (act === "float") { toast("悬浮剪贴板已打开"); return; }
    });
  });

  if (pmMenuList) {
    pmMenuList.addEventListener("click", function (e) {
      var li = e.target.closest("[data-menu-act]");
      if (!li) return;
      menuAction(li.getAttribute("data-menu-act"));
    });
  }

  if (pmCtxList) {
    pmCtxList.addEventListener("click", function (e) {
      var li = e.target.closest("[data-ctx-act]");
      if (!li) return;
      ctxAction(li.getAttribute("data-ctx-act"));
    });
  }

  if (pmCalGrid) {
    pmCalGrid.addEventListener("click", function (e) {
      var btn = e.target.closest(".pm-day");
      if (!btn) return;
      var key = btn.getAttribute("data-day");
      clipState.calSelected = (clipState.calSelected === key) ? null : key;
      renderCalendar();
    });
  }

  document.addEventListener("click", function (e) {
    if (pmMenu && !pmMenu.hidden && !pmMenu.contains(e.target)) closeMenu();
    if (pmCtx && !pmCtx.hidden && !pmCtx.contains(e.target)) closeCtx();
    // 固定预览：点列表以外的区域才关（点条目是切换，不是关）
    if (previewPinned && pmPreview && !pmPreview.hidden) {
      var inList = e.target.closest && e.target.closest(".pm-item");
      if (!inList) closePreview();
    }
  });

  /* ---------------- 分段切换（真机 pageSegments） ---------------- */

  var pmSegs = $("#pmSegs");

  function switchPage(page) {
    if (!pmSegs) return;
    $$(".pm-seg", pmSegs).forEach(function (b) {
      b.classList.toggle("on", b.getAttribute("data-page") === page);
    });
    $$(".pm-page", pmBody).forEach(function (p) {
      p.hidden = p.getAttribute("data-page") !== page;
    });
    closePreview();
    closeMenu();
    closeCtx();
    if (pmBody) pmBody.scrollTop = 0;
  }

  if (pmSegs) {
    pmSegs.addEventListener("click", function (e) {
      var b = e.target.closest(".pm-seg");
      if (!b) return;
      switchPage(b.getAttribute("data-page"));
    });
  }

  /* ---------------- 页内跳转提示 ---------------- */

  var JUMP_TEXT = {
    "features:ch-clipboard": "看「剪贴板」的完整说明",
    "features:ch-capture": "看「截图与标注」的完整说明",
    "features:ch-monitor": "看「系统监控」的完整说明",
    "features:ch-transfer": "看「文件中转」的完整说明",
    "features:ch-cast": "看「安卓投屏」的完整说明",
    "features:ch-toolbox": "看「工具箱」的完整说明"
  };

  var pendingJump = null;

  $$("[data-jump]").forEach(function (el) {
    el.addEventListener("click", function (e) {
      e.preventDefault();
      var spec = el.getAttribute("data-jump");
      var parts = spec.split(":");
      if (parts[0] === "features") {
        // 面板内点击不直接跳走，先给一条提示，再由用户确认（面板不该把人踢出当前视图）
        pendingJump = spec;
        if (pmJumpHint) {
          $("#pmJumpText").textContent = JUMP_TEXT[spec] || "看完整说明";
          pmJumpHint.hidden = false;
        }
        return;
      }
      goTo(parts[0], parts[1]);
    });
  });

  if (pmJumpHint) {
    $("#pmJumpGo").addEventListener("click", function () {
      pmJumpHint.hidden = true;
      if (pendingJump) {
        var parts = pendingJump.split(":");
        goTo(parts[0], parts[1]);
        pendingJump = null;
      }
    });
  }

  /* ---------------- 初始化 ---------------- */

  renderClipList();
  renderCalendar();
  renderSearchResults();

  /* ---------------- 截图切换 ---------------- */

  $$(".shot-tabs").forEach(function (root) {
    var tabs = $$(".shot-tab", root);
    var stage = document.getElementById(root.getAttribute("data-stage"));
    if (!stage) return;
    var slides = $$("[data-shot-slide]", stage);
    var panels = $$("[data-shot-panel]", stage);

    function select(name) {
      tabs.forEach(function (t) {
        var on = t.getAttribute("data-shot") === name;
        t.classList.toggle("on", on);
        t.setAttribute("aria-selected", on ? "true" : "false");
      });
      slides.forEach(function (s) { s.hidden = s.getAttribute("data-shot-slide") !== name; });
      panels.forEach(function (p) { p.hidden = p.getAttribute("data-shot-panel") !== name; });
    }

    tabs.forEach(function (tab) {
      tab.setAttribute("role", "tab");
      tab.setAttribute("aria-selected", tab.classList.contains("on") ? "true" : "false");
      tab.addEventListener("click", function () { select(tab.getAttribute("data-shot")); });
    });
    select((tabs.filter(function (t) { return t.classList.contains("on"); })[0] || tabs[0]).getAttribute("data-shot"));
  });

  /* 截图缺失时的占位（图片尚未并入或部署漏传时给出明确提示） */
  $$("img[data-shot-file]").forEach(function (img) {
    img.addEventListener("error", function () {
      var frame = img.closest(".shot-frame") || img.parentNode;
      if (!frame) return;
      var note = document.createElement("div");
      note.className = "shot-missing";
      note.textContent = "截图未并入：" + img.getAttribute("data-shot-file");
      note.style.cssText = "padding:26px;font-size:12.5px;color:#8A8A94;border:1px dashed #DCDCE2;border-radius:10px;background:#FFF;text-align:center;width:100%";
      img.replaceWith(note);
    });
  });

  /* ---------------- 版本清单 ----------------
     清单字段与客户端 AppUpdateChecker 一致：
     build / versionName / minBuild / zipUrl / size / sha256 /
     releaseNotes / whatsNew{added,improved,fixed} / pageUrl / publishedAt
     校验不通过就停用下载，绝不给出不可靠的链接。 */

  /* 相对路径：同一份站点既可以挂在 / 根目录，也可以挂在 /kitnest-site/ 子路径下 */
  var MANIFEST_URL = "kitnest/stable/latest.json";
  if (location.hostname === "127.0.0.1" || location.hostname === "localhost") {
    try {
      var qs = new URLSearchParams(location.search).get("manifest");
      if (qs) MANIFEST_URL = qs;
    } catch (e) { /* 用默认地址 */ }
  }

  var manifest = null;
  var downloadReady = false;

  function showManifestState(state, detail) {
    var map = { loading: "#manifestLoading", error: "#manifestError", ready: "#manifestReady" };
    Object.keys(map).forEach(function (key) {
      var el = $(map[key]);
      if (el) el.hidden = key !== state;
    });
    if (state === "error" && detail) {
      var p = $("#manifestErrorDetail");
      if (p) p.textContent = detail;
    }
  }

  function isReleaseZipPath(pathname) {
    return pathname.indexOf("/kitnest/releases/") === 0 &&
      /\.zip$/.test(pathname) &&
      pathname.indexOf("..") === -1;
  }

  function resolveUrl(value) {
    try { return new URL(String(value || ""), location.href); } catch (e) { return null; }
  }

  function validateManifest(data) {
    if (!data || typeof data !== "object") return "版本清单格式不正确。";
    if (!/^\d+\.\d+\.\d+$/.test(String(data.versionName || ""))) return "清单中的版本号不符合 x.y.z 约定。";
    if (typeof data.build !== "number" || !isFinite(data.build) || data.build <= 0) return "清单缺少有效的 build 号。";
    if (!/^[0-9a-fA-F]{64}$/.test(String(data.sha256 || ""))) return "清单缺少有效的 SHA-256 校验值。";
    if (typeof data.size !== "number" || !isFinite(data.size) || data.size <= 0) return "清单缺少有效的安装包大小。";
    var url = resolveUrl(data.zipUrl);
    if (!url || !isReleaseZipPath(url.pathname)) return "清单中的安装包路径不符合发布约定。";
    return null;
  }

  function isDownloadAllowed(data) {
    if (!data) return false;
    var url = resolveUrl(data.zipUrl);
    if (!url) return false;
    if (!isReleaseZipPath(url.pathname)) return false;
    if (!/^https?:$/.test(location.protocol)) return false;
    if (location.protocol === "https:" && url.protocol !== "https:") return false;
    var h = url.hostname;
    if (h === "127.0.0.1" || h === "localhost" || h === "0.0.0.0" || h === "::1") return false;
    return true;
  }

  function whatsNewMarkup(data) {
    var groups = [
      { key: "added", label: "新增" },
      { key: "improved", label: "改进" },
      { key: "fixed", label: "修复" }
    ];
    var wn = data.whatsNew || {};
    var html = "";
    groups.forEach(function (g) {
      var items = Array.isArray(wn[g.key]) ? wn[g.key].filter(Boolean) : [];
      if (!items.length) return;
      html += "<div class=\"whatsnew-group\"><div class=\"wn-label\">" + g.label + "</div><ul>" +
        items.map(function (text) { return "<li>" + escapeHtml(String(text)) + "</li>"; }).join("") +
        "</ul></div>";
    });
    return html;
  }

  function escapeHtml(text) {
    return text.replace(/[&<>"']/g, function (c) {
      return { "&": "&amp;", "<": "&lt;", ">": "&gt;", "\"": "&quot;", "'": "&#39;" }[c];
    });
  }

  function releaseNotesText(data) {
    if (data.releaseNotes && String(data.releaseNotes).trim()) return String(data.releaseNotes).trim();
    var wn = data.whatsNew || {};
    var lines = [];
    [["added", "新增"], ["improved", "改进"], ["fixed", "修复"]].forEach(function (pair) {
      var items = Array.isArray(wn[pair[0]]) ? wn[pair[0]] : [];
      if (items.length) lines.push("【" + pair[1] + "】" + items.join("；"));
    });
    return lines.join("\n");
  }

  function renderManifest(data) {
    var sizeText = formatSize(data.size);
    var sizeLong = "约 " + sizeText;

    var set = function (id, text) { var el = document.getElementById(id); if (el) el.textContent = text; };

    set("vName", "v" + data.versionName);
    set("vBuild", "build " + data.build);
    set("vSize", sizeText);
    set("vMin", data.minBuild && data.minBuild > 1
      ? "build " + data.minBuild + " 及以上可直接覆盖；更低版本请先升级到中间版本"
      : "任意旧版本均可直接覆盖升级");
    set("vDate", formatDate(data.publishedAt) || "—");
    set("vSha", String(data.sha256).toLowerCase());
    set("vNotes", releaseNotesText(data) || "本版本未附更新说明。");

    $$("[data-pkg-size]").forEach(function (el) { el.textContent = sizeLong; });

    var heroLine = $("#heroVersionText");
    if (heroLine) {
      heroLine.textContent = "v" + data.versionName + " · build " + data.build + " · 安装包" + sizeLong;
    }

    var modalSize = $("#modalPkgSize");
    if (modalSize) modalSize.textContent = sizeText;

    var wnBody = $("#whatsNewMockBody");
    if (wnBody) {
      var wn = whatsNewMarkup(data);
      wnBody.innerHTML = wn || "<p style=\"font-size:13px;color:#8A8A94\">本版本暂无条目。</p>";
      var badge = $("#whatsNewMockBadge");
      if (badge) badge.textContent = "build " + data.build;
      var title = $("#whatsNewMockTitle");
      if (title) title.textContent = "已更新到 " + data.versionName;
    }

    var latest = $("#latestRelease");
    if (latest) {
      latest.innerHTML = "<div class=\"tl-head\"><h3>当前稳定版 · v" + escapeHtml(data.versionName) + "</h3>" +
        "<span class=\"tl-date\">build " + data.build + (data.publishedAt ? " · " + formatDate(data.publishedAt) : "") + "</span>" +
        "<span class=\"tl-badge\">最新</span></div><div class=\"tl-body\">" +
        (whatsNewMarkup(data) || "<p class=\"tl-empty\">该版本未附条目。</p>") +
        "<p style=\"margin-top:14px;font-size:12.5px;color:#8A8A94\">完整安装包 " + sizeText +
        " · SHA-256 前 12 位 <code>" + String(data.sha256).slice(0, 12) + "…</code></p></div>";
    }

    var btn = $("#dlButton");
    if (btn) {
      downloadReady = isDownloadAllowed(data);
      btn.disabled = !downloadReady;
      var note = $("#dlButtonNote");
      if (note) note.textContent = downloadReady ? "（" + sizeText + "）" : "";
      var hint = $("#dlButtonHint");
      if (hint) {
        hint.textContent = downloadReady
          ? "点击后先检查下载通道，再确认下载须知。"
          : "下载链接未通过安全校验，按钮已停用。请通过正式站点访问或稍后重试。";
      }
    }

    var dmgLink = $("#dmgLink");
    if (dmgLink) {
      if (data.dmgUrl) {
        var du = resolveUrl(data.dmgUrl);
        if (du) { dmgLink.href = du.href; dmgLink.hidden = false; }
      } else {
        dmgLink.hidden = true;
      }
    }
  }

  function loadManifest() {
    showManifestState("loading");
    var controller = new AbortController();
    var timer = setTimeout(function () { controller.abort(); }, 10000);

    fetch(MANIFEST_URL, { cache: "no-store", signal: controller.signal })
      .then(function (res) {
        clearTimeout(timer);
        if (!res.ok) throw new Error("HTTP " + res.status);
        return res.json();
      })
      .then(function (data) {
        var problem = validateManifest(data);
        if (problem) {
          showManifestState("error", problem + " 未能取得有效版本信息前，下载暂不开放。");
          return;
        }
        manifest = data;
        renderManifest(data);
        showManifestState("ready");
      })
      .catch(function (err) {
        clearTimeout(timer);
        var reason = err && err.name === "AbortError"
          ? "版本清单请求超时（10 秒无响应）。"
          : "版本清单读取失败（" + (err && err.message ? err.message : "网络异常") + "）。";
        showManifestState("error", reason + " 可能是网络异常或发布服务正在维护；应用内更新不受影响。");
      });
  }

  var retryBtn = $("#manifestRetry");
  if (retryBtn) retryBtn.addEventListener("click", loadManifest);

  /* ---------------- 下载流程 ---------------- */

  var dlModal = $("#dlModal");
  var dlButton = $("#dlButton");
  var dlConfirm = $("#dlConfirm");
  var dlCancel = $("#dlCancel");
  var modalOpener = null;
  var checking = false;

  function openModal(opener) {
    if (!dlModal) return;
    modalOpener = opener || null;
    dlModal.classList.add("open");
    var box = $(".modal", dlModal);
    if (box) box.focus();
  }

  function closeModal() {
    if (!dlModal || !dlModal.classList.contains("open")) return;
    dlModal.classList.remove("open");
    if (modalOpener && modalOpener.focus) modalOpener.focus();
    modalOpener = null;
  }

  function setHint(text) {
    var hint = $("#dlButtonHint");
    if (hint) hint.textContent = text;
  }

  function setButton(label, disabled) {
    var btn = $("#dlButton");
    if (!btn) return;
    btn.innerHTML = label;
    btn.disabled = !!disabled;
  }

  function preflight(url) {
    var controller = new AbortController();
    var timer = setTimeout(function () { controller.abort(); }, 12000);
    return fetch(url, { method: "HEAD", cache: "no-store", signal: controller.signal })
      .then(function (res) { clearTimeout(timer); return res.status; })
      .catch(function (err) { clearTimeout(timer); throw err; });
  }

  if (dlButton) {
    dlButton.addEventListener("click", function () {
      if (!downloadReady || !manifest || checking) return;
      var url = resolveUrl(manifest.zipUrl);
      if (!url) return;

      checking = true;
      setButton("正在检查下载通道…", true);
      setHint("正在确认发布通道是否可用…");

      preflight(url.href).then(function (status) {
        checking = false;
        setButton("下载安装包<span class=\"btn-note\" id=\"dlButtonNote\">（" + formatSize(manifest.size) + "）</span>", false);
        if (status === 429) {
          setHint("当前通道繁忙，请稍后重试。");
          toast("当前通道繁忙，请稍后重试");
          return;
        }
        if (status >= 400) {
          setHint("发布服务返回 HTTP " + status + "，请稍后重试。");
          toast("发布服务暂时不可用（HTTP " + status + "）");
          return;
        }
        setHint("通道已就绪，请确认下载须知。");
        openModal(dlButton);
      }).catch(function (err) {
        checking = false;
        setButton("下载安装包<span class=\"btn-note\">（" + formatSize(manifest.size) + "）</span>", false);
        setHint(err && err.name === "AbortError" ? "检查超时，请稍后重试。" : "网络连接失败，请检查网络后重试。");
        toast("暂时连不上下载服务");
      });
    });
  }

  if (dlCancel) dlCancel.addEventListener("click", closeModal);
  if (dlModal) {
    dlModal.addEventListener("click", function (e) { if (e.target === dlModal) closeModal(); });
    dlModal.addEventListener("keydown", function (e) {
      if (e.key !== "Tab") return;
      var focusables = $$("button, [href], [tabindex]:not([tabindex=\"-1\"])", dlModal).filter(function (el) { return !el.disabled; });
      if (!focusables.length) return;
      var first = focusables[0];
      var last = focusables[focusables.length - 1];
      if (e.shiftKey && document.activeElement === first) { e.preventDefault(); last.focus(); }
      else if (!e.shiftKey && document.activeElement === last) { e.preventDefault(); first.focus(); }
    });
  }
  document.addEventListener("keydown", function (e) {
    if (e.key === "Escape") { closeModal(); closeMobileMenu(); }
  });

  if (dlConfirm) {
    dlConfirm.addEventListener("click", function () {
      if (!manifest) return;
      var url = resolveUrl(manifest.zipUrl);
      if (!url) return;

      var a = document.createElement("a");
      a.href = url.href;
      a.download = "";
      a.rel = "noopener";
      document.body.appendChild(a);
      a.click();
      document.body.removeChild(a);

      closeModal();
      setButton("已开始下载<span class=\"btn-note\">浏览器接管中</span>", true);
      setHint("浏览器已开始下载。下载完成后建议核对 SHA-256 再解压。");
      toast("已开始下载，请留意浏览器下载提示");

      setTimeout(function () {
        if (!manifest) return;
        setButton("重新下载<span class=\"btn-note\">（" + formatSize(manifest.size) + "）</span>", false);
        setHint("再次点击可重新下载。");
      }, 7000);
    });
  }

  /* ---------------- SHA-256 复制 ---------------- */

  var copyBtn = $("#copySha");
  if (copyBtn) {
    copyBtn.addEventListener("click", function () {
      var node = $("#vSha");
      var text = node ? node.textContent.trim() : "";
      if (!text || text === "—") return;

      function done() {
        copyBtn.textContent = "已复制";
        copyBtn.classList.add("done");
        toast("SHA-256 已复制");
        setTimeout(function () { copyBtn.textContent = "复制"; copyBtn.classList.remove("done"); }, 2000);
      }

      function fallback() {
        var ta = document.createElement("textarea");
        ta.value = text;
        ta.style.cssText = "position:fixed;opacity:0";
        document.body.appendChild(ta);
        ta.select();
        try { document.execCommand("copy"); } catch (e) { /* 忽略 */ }
        document.body.removeChild(ta);
      }

      if (navigator.clipboard && navigator.clipboard.writeText) {
        navigator.clipboard.writeText(text).then(done, function () { fallback(); done(); });
      } else {
        fallback();
        done();
      }
    });
  }

  /* ---------------- FAQ ---------------- */

  $$(".faq-item").forEach(function (item) {
    var q = $(".faq-q", item);
    var a = $(".faq-a", item);
    if (!q || !a) return;
    q.setAttribute("aria-expanded", "false");
    q.addEventListener("click", function () {
      var open = item.classList.toggle("open");
      q.setAttribute("aria-expanded", open ? "true" : "false");
      a.style.maxHeight = open ? a.scrollHeight + "px" : "0px";
      var arrow = $(".faq-arrow", q);
      if (arrow) arrow.textContent = open ? "−" : "＋";
    });
  });

  window.addEventListener("resize", function () {
    $$(".faq-item.open .faq-a").forEach(function (a) { a.style.maxHeight = a.scrollHeight + "px"; });
  }, { passive: true });

  /* ---------------- 启动 ---------------- */

  render();
  loadManifest();
})();
