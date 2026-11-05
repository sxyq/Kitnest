/* ============================================================
   Kitnest 官网脚本
   · hash 路由（首页 / 功能 / 界面 / 下载 / 更新 / 帮助 / 安全）
   · 可交互主面板：常驻展示，进场播一次 WindowReveal 展开
   · 界面截图切换、FAQ 折叠、移动端菜单
   · 读取 /kitnest/stable/latest.json 渲染版本、SHA-256 与下载
   页面不写入任何密钥、签名信息或用户数据。
   ============================================================ */

(function () {
  "use strict";

  var Motion = window.KitnestMotion;

  var $ = function (sel, root) { return (root || document).querySelector(sel); };
  var $$ = function (sel, root) { return Array.prototype.slice.call((root || document).querySelectorAll(sel)); };

  /* ---------------- 反馈 ---------------- */

  /* MenuBarToastManager（Toast.swift:134-195）：代际防串台、3.0s 自动隐藏、
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

  /* ---------------- 可交互主面板（常驻展示） ---------------- */

  var panelMock = $("#panelMock");

  /* 模拟的 Mac 状态栏已整条删除（用户：「需要完全删掉」），
     所以没有小猫开关、没有 CPU/网络/电池假部件，也没有部件详情浮窗。
     面板常驻可见；进场时仍播一次 WindowReveal 展开，锚点 (1,0)＝状态栏右侧，
     与 App 的 PanelController.revealUnit 兜底值一致。
     收起动画由预览浮层继续复用同一套 revealOut 参数（closePreview）。 */
  if (panelMock) {
    panelMock.hidden = false;
    Motion.revealIn(panelMock, {
      unit: Motion.panelAnchor(null, panelMock),
      scale: Motion.tokens.revealScale.panel,
      duration: Motion.openDuration(),
      timing: "caEaseOut"
    });
    document.addEventListener("keydown", function (e) {
      if (e.key === "Escape") closePreview();
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

  /* ---------------- 可交互主面板（对齐真机 PanelRootView） ---------------- */

  /*
     数据全部是写死的演示条目，对应真机里预灌进剪贴板的那几条
     （JSON / Markdown / Swift / Python / 图片 / 链接 / 文字），不碰用户真实剪贴板。
  */
  /*
     剪贴板条目：内容是**真实可渲染的样例**（JSON / Markdown / Swift / Python / 图片 / 链接），
     预览按真机 PreviewPopoverContentModel.classify 的分态渲染。
     数据全部虚构，不含任何真实用户内容。
  */
  var CLIP_ITEMS = [
    { id: "c1", kind: "url", badge: "chrome",
      title: "https://calorieai.sxyq27.online/kitnest-site/",
      meta: "今天 12:15 · 47 个字符",
      view: "url",
      text: "https://calorieai.sxyq27.online/kitnest-site/" },
    { id: "c2", kind: "text", badge: "code",
      title: "周报草稿：第三部分的发布流程还需要补充回滚说明",
      meta: "今天 12:08 · 45 个字符",
      view: "text",
      text: "周报草稿：第三部分的发布流程还需要补充回滚说明。" },
    { id: "c3", kind: "md", badge: "md",
      title: "# Kitnest 发布检查清单",
      meta: "今天 12:08 · 224 个字符",
      view: "markdown",
      text: "# Kitnest 发布检查清单\n\n## 发版前\n\n- 跑 `bash tools/check.sh`\n- 构建并签名，记录 build 号与包体大小\n- 计算 SHA-256，写进 stable/latest.json\n\n## 发布\n\n1. `bash tools/publish_update.sh`\n2. `bash tools/deploy_site.sh`\n3. 重启客户端，确认检查更新能读到新清单\n\n## 回滚\n\n保留上一版 zip 与清单快照，回滚时把 latest.json 指回旧 build。" },
    { id: "c4", kind: "json", badge: "json",
      title: '{ "name": "kitnest.config.json",',
      meta: "今天 12:08 · 647 个字符",
      view: "json",
      text: '{\n  "name": "kitnest.config.json",\n  "app": "kitnest",\n  "version": "1.0.0",\n  "features": {\n    "clipboard": { "keepDays": 30, "maxSizeMB": 2048 },\n    "monitor": { "refreshSeconds": 1.5, "widgets": ["cpu", "net", "batt"] },\n    "update": { "channel": "stable", "autoCheck": true }\n  },\n  "screenshot": {\n    "hotkeys": { "region": "⌥S", "window": "⇧⌥W", "longshot": "⇧⌥L" },\n    "annotateTools": ["rect", "ellipse", "arrow", "pen", "text", "mosaic"]\n  }\n}' },
    { id: "c5", kind: "code", badge: "code",
      title: "// ClipGroup.swift —— 按类型分组剪贴板条目",
      meta: "今天 12:08 · 398 个字符",
      view: "code",
      lang: "swift",
      text: '// ClipGroup.swift\nimport Foundation\n\n/// 把剪贴板条目按类型分组\nstruct ClipItem {\n    let kind: String\n    let title: String\n}\n\nfunc groupByKind(_ items: [ClipItem]) -> [String: [ClipItem]] {\n    items.reduce(into: [:]) { result, item in\n        result[item.kind, default: []].append(item)\n    }\n}\n\nlet recent = [\n    ClipItem(kind: "text", title: "周报草稿"),\n    ClipItem(kind: "code", title: "ClipGroup.swift"),\n]\nprint(groupByKind(recent))' },
    { id: "c6", kind: "code", badge: "code",
      title: "# verify_sha.py —— 安装包校验",
      meta: "今天 12:08 · 341 个字符",
      view: "code",
      lang: "python",
      text: '# verify_sha.py\nimport hashlib\n\n\ndef sha256(path: str) -> str:\n    """计算文件的 SHA-256。""".\n    h = hashlib.sha256()\n    with open(path, "rb") as f:\n        for chunk in iter(lambda: f.read(65536), b""):\n            h.update(chunk)\n    return h.hexdigest()\n\n\nif __name__ == "__main__":\n    print(sha256("Kitnest-1.0.0.dmg"))' },
    { id: "c7", kind: "img", badge: "img",
      title: "会议室现场 2026-11-05.jpg",
      meta: "今天 11:50 · 1400×935 px",
      view: "image",
      img: "assets/demo/meeting-room.jpg",
      text: "1400×935 px · JPG",
      ocr: {
        text: [
          { tag: "段落 1 · 会议信息", lines: ["Q4 产品评审会", "11 月 5 日 14:00 · 3 号会议室", "参会：产品、设计、客户端、测试"] },
          { tag: "段落 2 · 结论与待办", lines: ["结论：v1.0.0 先走稳定通道", "待办：回滚清单与 SHA-256 校验", "官网下载页与更新清单同步"] }
        ],
        en: [
          { tag: "Paragraph 1 · Meeting", lines: ["Q4 Product Review", "Nov 5, 14:00 · Meeting Room 3", "Attendees: PM, Design, Client, QA"] },
          { tag: "Paragraph 2 · Decision", lines: ["Decision: ship v1.0.0 on the stable channel", "TODO: rollback plan and SHA-256 verification", "Sync the download page and update feed"] }
        ]
      } },
    { id: "c8", kind: "text", badge: "code",
      title: "TODO：把安装包校验写进发版脚本",
      meta: "昨天 18:24 · 26 个字符",
      view: "text",
      text: "TODO：把安装包校验写进发版脚本，顺便把官网的下载页也更新一下。" }
  ];

  /*
     搜索：真机有网页 / 剪贴板 / 文件 / 工具四路检索源 + 分类 chips，
     网页版做个**够用的简化版**——
       · 输入普通关键词 → 过滤剪贴板列表 + 匹配工具命令（两段结果）
       · 输入 /        → 只出工具命令（真机 SlashCommandCatalog 的形态）
     不做网页检索、不做分类 chips，交互一眼看得懂。
  */
  /* ---------------- 面板元素引用 ---------------- */

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

  var TOOL_COMMANDS = [
    { token: "/hash", title: "计算哈希", sub: "文本 / 文件 → SHA-256" },
    { token: "/qr", title: "生成二维码", sub: "文本 → 二维码" },
    { token: "/ip", title: "查看本机 IP", sub: "局域网地址" },
    { token: "/convert", title: "媒体格式转换", sub: "图片 / 视频 / 音频" },
    { token: "/time", title: "时间与时区", sub: "世界时钟 / 转换" },
    { token: "/color", title: "取色", sub: "屏幕取色 ⌥C" }
  ];

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

  function closePreview(onClosed) {
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
  }

  var previewAnchorId = null;
  var previewRevealUnit = { x: 1, y: 0.5 };

  /* ---------------- 预览渲染器（v229：对齐真机 PreviewPopoverContentView） ---------------- */

  function esc(t) {
    return String(t == null ? "" : t)
      .replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
      .replace(/"/g, "&quot;");
  }

  /* JSON：树形视图（真机 JSONInspectorView），键与值分色 */
  function renderJSONTree(text) {
    var data;
    try {
      data = JSON.parse(text);
    } catch (e) {
      return '<pre class="pv-raw">' + esc(text) + "</pre>";
    }
    var out = '<div class="pv-tree">';
    (function walk(v, depth) {
      var pad = depth * 10;
      if (Array.isArray(v)) {
        out += '<div class="pv-row" style="padding-left:' + pad + 'px"><span class="pv-bracket">[</span></div>';
        v.forEach(function (item, i) {
          walk(item, depth + 1);
          if (i < v.length - 1) out += '<div class="pv-row" style="padding-left:' + (depth + 1) * 12 + 'px"><span class="pv-comma">,</span></div>';
        });
        out += '<div class="pv-row" style="padding-left:' + pad + 'px"><span class="pv-bracket">]</span></div>';
        return;
      }
      if (v && typeof v === "object") {
        out += '<div class="pv-row" style="padding-left:' + pad + 'px"><span class="pv-bracket">{</span></div>';
        var keys = Object.keys(v);
        keys.forEach(function (k, i) {
          out += '<div class="pv-row" style="padding-left:' + (depth + 1) * 12 + 'px">'
            + '<span class="pv-key">"' + esc(k) + '"</span><span class="pv-colon">:</span>';
          walk(v[k], depth + 1);
          if (i < keys.length - 1) out += '<span class="pv-comma">,</span>';
          out += "</div>";
        });
        out += '<div class="pv-row" style="padding-left:' + pad + 'px"><span class="pv-bracket">}</span></div>';
        return;
      }
      var cls = "pv-val";
      if (typeof v === "string") cls = "pv-str";
      else if (typeof v === "number") cls = "pv-num";
      else if (typeof v === "boolean") cls = "pv-bool";
      else if (v === null) cls = "pv-null";
      out += '<span class="' + cls + '">' + esc(String(v)) + "</span>";
    })(data, 0);
    return out + "</div>";
  }

  /* 代码：行号 + 语法高亮（真机 CodePreviewView） */
  var CODE_KW = {
    swift: ["import", "struct", "func", "let", "var", "return", "for", "in", "if", "else", "print", "default", "class", "enum", "self", "nil", "true", "false", "while", "guard", "init", "static", "public", "private"],
    python: ["import", "from", "def", "return", "for", "in", "if", "else", "with", "as", "print", "class", "None", "True", "False", "lambda", "try", "except", "while", "break", "continue", "self", "not", "and", "or", "yield", "pass"],
    json: [], text: [], md: []
  };

    function highlightLine(line, lang) {
    var html = esc(line);
    // 注释（# 与 //）
    html = html.replace(/(#[^\n]*)$/g, '<span class="c-com">$1</span>');
    html = html.replace(/(\/\/[^\n]*)$/g, '<span class="c-com">$1</span>');
    // 字符串
    html = html.replace(/("(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*')/g, '<span class="c-str">$1</span>');
    // 数字
    html = html.replace(/\b(\d+(?:\.\d+)?)\b/g, '<span class="c-num">$1</span>');
    // 关键字
    var kws = CODE_KW[lang] || [];
    kws.forEach(function (k) {
      html = html.replace(new RegExp("\\b(" + k + ")\\b", "g"), '<span class="c-kw">$1</span>');
    });
    return html;
  }

  function renderCode(text, lang) {
    var lines = String(text).split("\n");
    var out = '<div class="pv-code"><table>';
    lines.forEach(function (ln, i) {
      out += '<tr><td class="c-ln">' + (i + 1) + '</td><td class="c-src">'
        + (highlightLine(ln, lang) || "&nbsp;") + "</td></tr>";
    });
    return out + "</table></div>";
  }

  /* v229 Markdown：目录 + 正文（真机 MarkdownPreviewBody，目录可点跳转） */
  function inlineMD(t) {
    var html = esc(t);
    html = html.replace(/`([^`]+)`/g, '<code class="md-code">$1</code>');
    html = html.replace(/\*\*([^*]+)\*\*/g, "<strong>$1</strong>");
    html = html.replace(/\[([^\]]+)\]\(([^)]+)\)/g, '<a href="$2" target="_blank" rel="noopener">$1</a>');
    return html;
  }

  function renderMarkdown(text) {
    var lines = String(text).split("\n");
    var body = "";
    var toc = [];
    var inList = false, inQuote = false;
    function closeList() { if (inList) { body += "</ul>"; inList = false; } }
    function closeQuote() { if (inQuote) { body += "</blockquote>"; inQuote = false; } }
    lines.forEach(function (ln) {
      var t = ln.trim();
      if (!t) { closeList(); closeQuote(); return; }
      var h = t.match(/^(#{1,4})\s+(.*)$/);
      if (h) {
        closeList(); closeQuote();
        var lvl = Math.min(h[1].length, 4);
        var id = "pv-h-" + (toc.length + 1);
        toc.push({ id: id, lvl: lvl, text: h[2].replace(/[*`\[\]]/g, "") });
        body += "<h" + lvl + ' id="' + id + '">' + inlineMD(h[2]) + "</h" + lvl + ">";
        return;
      }
      if (/^(---+|\*\*\*+)$/.test(t)) { closeList(); closeQuote(); body += '<hr class="md-hr">'; return; }
      if (t.charAt(0) === ">") {
        closeList();
        if (!inQuote) { body += "<blockquote>"; inQuote = true; }
        body += "<p>" + inlineMD(t.replace(/^>\s*/, "")) + "</p>";
        return;
      }
      var li = t.match(/^[-*]\s+(.*)$/);
      if (li) {
        closeQuote();
        if (!inList) { body += "<ul>"; inList = true; }
        body += "<li>" + inlineMD(li[1]) + "</li>";
        return;
      }
      var oli = t.match(/^\d+\.\s+(.*)$/);
      if (oli) {
        closeQuote();
        if (!inList) { body += "<ol>"; inList = true; }
        body += "<li>" + inlineMD(oli[1]) + "</li>";
        return;
      }
      closeList(); closeQuote();
      body += "<p>" + inlineMD(t) + "</p>";
    });
    closeList(); closeQuote();

    // 目录不走 href="#..." —— hash 是官网的视图路由，点了会跳页
    var tocHTML = "";
    if (toc.length > 1) {
      tocHTML = '<nav class="pv-md-toc"><span>目录 · ' + toc.length + " 节</span><ul>"
        + toc.map(function (h, i) {
            return '<li class="lvl-' + h.lvl + '"><a href="#" data-md-target="' + h.id + '"'
              + (i === 0 ? ' class="on"' : "") + ">" + esc(h.text) + "</a></li>";
          }).join("")
        + "</ul></nav>";
    }
    return '<div class="pv-md">' + tocHTML
      + '<div class="pv-md-body">' + body + "</div></div>";
  }

  /* v229 图片：真实照片 + 文件信息 + 真机「识别文本 / 翻译」分段结果 */
  function ocrBlocks(list) {
    return (list || []).map(function (b) {
      return '<section class="pv-ocr-block"><span class="pv-ocr-tag">' + esc(b.tag) + "</span>"
        + "<p>" + (b.lines || []).map(esc).join("<br>") + "</p></section>";
    }).join("");
  }

  function renderImage(item) {
    var o = item.ocr || {};
    return '<div class="pv-img">'
      + '<figure class="pv-img-shot">'
      +   '<img src="' + esc(item.img || "assets/demo/meeting-room.jpg") + '" alt="会议场景照片">'
      +   '<figcaption><span class="pv-img-badge">JPG</span>' + esc(item.text || "") + "</figcaption>"
      + "</figure>"
      + '<div class="pv-img-file"><b>' + esc(item.title) + "</b><span>照片 · 本机</span></div>"
      + '<div class="pv-ocr" hidden>'
      +   '<div class="pv-ocr-tabs">'
      +     '<button type="button" class="on" data-pv-tab="text">识别文本</button>'
      +     '<button type="button" data-pv-tab="trans">翻译</button>'
      +   "</div>"
      +   '<div class="pv-ocr-pane" data-pv-pane="text">' + ocrBlocks(o.text) + "</div>"
      +   '<div class="pv-ocr-pane" data-pv-pane="trans" hidden>' + ocrBlocks(o.en) + "</div>"
      + "</div>"
      + "</div>";
  }

  /* 预览底部动作行：真机预览可复制，图片可识别 / 翻译 */
  function renderPreviewFoot(item) {
    var acts = [];
    if (item.view === "image") {
      acts.push('<button type="button" data-pv-act="ocr">识别文字</button>');
      acts.push('<button type="button" data-pv-act="translate">翻译</button>');
    }
    acts.push('<button type="button" data-pv-act="copy">复制</button>');
    return acts.join("");
  }

  var PREVIEW_KIND = {
    text: "文字", url: "链接", markdown: "Markdown", md: "Markdown",
    json: "JSON", code: "代码", image: "图片", img: "图片", file: "文件"
  };

  function renderPreviewBody(item) {
    if (item.view === "json") return renderJSONTree(item.text);
    if (item.view === "code") return renderCode(item.text, item.lang || "text");
    if (item.view === "markdown") return renderMarkdown(item.text);
    if (item.view === "image") return renderImage(item);
    if (item.view === "url") {
      return '<div class="pv-text"><span class="pv-url">' + esc(item.text) + "</span></div>";
    }
    return '<div class="pv-text">' + esc(item.text || item.title) + "</div>";
  }

  function showPreview(item, anchorEl, pinned) {
    if (!pmPreview || !item) return;
    // 同一行且已显示 → 不重算（真机也有 hover 抑制，避免闪）
    if (previewAnchorId === item.id && !pmPreview.hidden && !pinned) return;
    var isSameItem = previewAnchorId === item.id && !pmPreview.hidden;
    previewAnchorId = item.id;
    previewPinned = !!pinned;
    pmPreview.querySelector(".pm-preview-kind").textContent =
      PREVIEW_KIND[item.view] || "内容";
    pmPreview.querySelector(".pm-preview-title").textContent = item.title;
    pmPreview.querySelector(".pm-preview-body").innerHTML = renderPreviewBody(item);
    pmPreview.querySelector(".pm-preview-foot").innerHTML = renderPreviewFoot(item);
    pmPreview.hidden = false;

    // 预览像真机那样飘在**面板左侧**（真机是独立 NSWindow，网页版放在舞台里）：
    //   右缘贴着面板左缘，向左延伸 width；
    //   左边越界就贴到舞台左缘（被舞台裁住，不溢出外框）；
    //   垂直方向与该行对齐。
    var stage = panelStage();
    if (!stage) return;
    var stageRect = stage.getBoundingClientRect();
    var panelRect = panelMock ? panelMock.getBoundingClientRect() : stageRect;
    var w = pmPreview.offsetWidth || 258;
    var h = pmPreview.offsetHeight || 240;
    var rowRect = anchorEl ? anchorEl.getBoundingClientRect() : null;
    if (!rowRect) return;

    // 用 right 定位：面板是 margin-left:auto 靠右，right 定位不受 padding 基准影响。
    // 预览右缘 = 面板左缘 - gap。
    var stageCS = getComputedStyle(stage);
    var padRight = parseFloat(stageCS.paddingRight) || 0;
    var borderRight = parseFloat(stageCS.borderRightWidth) || 0;
    var gap = 10;
    // 预览右缘要落在「面板左缘 - gap」：
    // 舞台内容宽 = 舞台宽 - padding - border；
    // 面板左缘距舞台内容右缘 = 舞台内容宽 - (面板左缘 - 内容左缘)
    // absolute 定位的 containing block 是定位祖先的 **padding box**：
    // right:0 对应「border 内侧」，padding 不参与。
    var borderLeft = parseFloat(stageCS.borderLeftWidth) || 0;
    var contentLeft = stageRect.left + borderLeft;
    var contentWidth = stageRect.width - borderLeft - borderRight;
    var panelOffsetInContent = panelRect.left - contentLeft;
    var right = contentWidth - panelOffsetInContent + gap;
    pmPreview.style.right = Math.round(right) + "px";
    pmPreview.style.left = "auto";

    // 垂直：与行心对齐，箭头指向行
    var top = rowRect.top - stageRect.top + rowRect.height / 2 - 22;
    var maxTop = stageRect.height - h - 6 - padTop(stageCS);
    if (top + h > maxTop) top = maxTop;
    if (top < 6) top = 6;

    pmPreview.style.top = Math.round(top) + "px";
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
    // 格子里依次淡入（真机是整体 transition，这里用 stagger 模拟）
    $$(".pm-day", pmCalGrid).forEach(function (d, i) {
      d.style.animationDelay = (i * 10) + "ms";
    });
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

    // 工具命令：/ 开头时只出命令；普通关键词也把匹配的工具带上
    var cmds = TOOL_COMMANDS.filter(function (c) {
      if (isCommand) return c.token.toLowerCase().indexOf(token) >= 0;
      return (c.token + c.title + c.sub).toLowerCase().indexOf(token) >= 0;
    });

    // 剪贴板匹配（/ 模式下不匹配剪贴板）
    var clips = [];
    if (!isCommand) {
      clips = clipState.items.filter(function (it) {
        return it.title.toLowerCase().indexOf(token) >= 0;
      });
    }

    if (!cmds.length && !clips.length) {
      pmResults.innerHTML = '<div class="pm-result-empty">没有匹配的结果</div>';
      pmResults.hidden = false;
      return;
    }

    var html = "";
    if (cmds.length) {
      html += '<div class="pm-result-group">命令</div><ul>';
      cmds.forEach(function (c) {
        html += '<li data-result-token="' + c.token + '"><span class="r-kind code">' + c.token.charAt(1) + "</span><b></b><span></span></li>";
      });
      html += "</ul>";
    }
    if (clips.length) {
      html += '<div class="pm-result-group">剪贴板</div><ul>';
      clips.forEach(function (it) {
        html += '<li data-result-id="' + it.id + '"><span class="r-kind ' + it.kind + '"></span><b></b><span></span></li>';
      });
      html += "</ul>";
    }
    pmResults.innerHTML = html;

    // 用 textContent 填内容，避免标题里的引号破坏 HTML
    var lis = pmResults.querySelectorAll("li");
    var k = 0;
    cmds.forEach(function (c) {
      if (!lis[k]) return;
      lis[k].querySelector("b").textContent = c.token + " " + c.title;
      lis[k].querySelector("span:last-child").textContent = c.sub;
      k++;
    });
    clips.forEach(function (it) {
      if (!lis[k]) return;
      lis[k].querySelector("b").textContent = it.title;
      lis[k].querySelector("span:last-child").textContent = it.meta;
      k++;
    });

    pmResults.hidden = false;
  }

  /* ---------------- 事件绑定 ---------------- */

  if (pmResults) {
    pmResults.addEventListener("click", function (e) {
      var li = e.target.closest("li");
      if (!li) return;
      var token = li.getAttribute("data-result-token");
      if (token) {
        toast("已执行 " + token);
        pmSearch.value = token;
        clipState.query = token;
        renderSearchResults();
        return;
      }
      var id = li.getAttribute("data-result-id");
      if (id) {
        var item = findItem(id);
        if (item) {
          var row = pmList.querySelector('[data-id="' + id + '"]');
          if (row) {
            row.scrollIntoView({ behavior: "smooth", block: "center" });
            showPreview(item, row, true);
          }
        }
      }
    });
  }

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

  function padTop(cs) {
    return parseFloat(cs.paddingTop) || 0;
  }

  function panelStage() {
    var p = $("#panelMock");
    return p ? p.parentElement : null;
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

  /* v229：目录跳转、识别文本 / 翻译分段、复制 */
  function selectPvTab(root, name) {
    $$("[data-pv-tab]", root).forEach(function (b) {
      b.classList.toggle("on", b.getAttribute("data-pv-tab") === name);
    });
    $$("[data-pv-pane]", root).forEach(function (p) {
      p.hidden = p.getAttribute("data-pv-pane") !== name;
    });
  }

  if (pmPreview) {
    pmPreview.addEventListener("click", function (e) {
      var md = e.target.closest("[data-md-target]");
      if (md) {
        e.preventDefault();
        e.stopPropagation();
        var target = pmPreview.querySelector("#" + md.getAttribute("data-md-target"));
        var body = pmPreview.querySelector(".pm-preview-body");
        if (target && body) {
          // 只滚预览自己的内容区：scrollIntoView 会连带滚动面板/页面，
          // 触发 pmBody 的 scroll 监听把预览收掉（v229 实测踩过）。
          var delta = target.getBoundingClientRect().top - body.getBoundingClientRect().top;
          body.scrollTop += delta - 8;
        }
        $$("[data-md-target]", pmPreview).forEach(function (a) {
          a.classList.toggle("on", a === md);
        });
        return;
      }
      var tab = e.target.closest("[data-pv-tab]");
      if (tab) {
        e.stopPropagation();
        selectPvTab(pmPreview, tab.getAttribute("data-pv-tab"));
        return;
      }
      var btn = e.target.closest("[data-pv-act]");
      if (!btn) return;
      e.stopPropagation();
      var act = btn.getAttribute("data-pv-act");
      if (act === "ocr" || act === "translate") {
        var box = pmPreview.querySelector(".pv-ocr");
        if (box) {
          box.hidden = false;
          selectPvTab(pmPreview, act === "translate" ? "trans" : "text");
        }
        return;
      }
      if (act === "copy") { toast("已复制"); return; }
    });
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
      if (act === "mod-refresh") { toast("已刷新监测数据"); return; }
      if (act === "mod-tuner") { toast("打开监测设置"); return; }
      if (act === "mod-settings") { toast("打开设置"); return; }
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

  // 预览是 fixed 浮层：面板滚动或窗口变化时要跟着重新定位
  window.addEventListener("resize", function () {
    if (!pmPreview || pmPreview.hidden) return;
    var li = pmList && pmList.querySelector(".pm-item.open");
    if (!li) return;
    var item = findItem(li.getAttribute("data-id"));
    if (item) showPreview(item, li, previewPinned);
  });
  if (pmBody) {
    pmBody.addEventListener("scroll", function () {
      if (!pmPreview || pmPreview.hidden || previewPinned) return;
      closePreview();
    }, { passive: true });
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

  /* ---------------- 性能监测页（真机 MonitorDetailView 逐模块还原） ---------------- */

  /*
     每个模块的内容按真机截图还原。数值是**演示数据**（真机读的是真实传感器），
     但结构、配色、排版、交互都跟真机一致。
  */

  var MON_MODULES = ["power", "battery", "cpu", "memory", "network", "disk", "sensors", "gpu"];
  var monState = { mod: "cpu" };

  /* 环：真机的占用环（圆环 + 中心大数字 + 小标签） */
  function ring(pct, color, big, small) {
    var r = 34, c = 2 * Math.PI * r;
    var off = c * (1 - Math.max(0, Math.min(1, pct / 100)));
    return '<span class="mon-ring" style="--ring-c:' + color + '">'
      + '<svg viewBox="0 0 84 84"><circle class="ring-bg" cx="42" cy="42" r="' + r + '"/>'
      + '<circle class="ring-fg" cx="42" cy="42" r="' + r + '" stroke-dasharray="' + c.toFixed(1) + '" stroke-dashoffset="' + off.toFixed(1) + '"/></svg>'
      + '<span class="mon-ring-in"><b>' + big + '</b>' + (small ? '<i>' + small + '</i>' : "") + '</span></span>';
  }

  /* 面积曲线：真机的历史曲线（蓝线 + 浅色填充） */
  function spark(values, color, w, h) {
    w = w || 300; h = h || 62;
    var max = Math.max.apply(null, values);
    var min = Math.min.apply(null, values);
    var span = (max - min) || 1;
    var pts = values.map(function (v, i) {
      var x = (i / (values.length - 1)) * w;
      var y = h - ((v - min) / span) * (h - 8) - 4;
      return x.toFixed(1) + "," + y.toFixed(1);
    });
    var line = pts.join(" ");
    var area = "0," + h + " " + line + " " + w + "," + h;
    return '<svg class="mon-spark" viewBox="0 0 ' + w + ' ' + h + '" preserveAspectRatio="none">'
      + '<polygon points="' + area + '" fill="' + color + '" opacity="0.16"/>'
      + '<polyline points="' + line + '" fill="none" stroke="' + color + '" stroke-width="1.8" '
      + 'stroke-linecap="round" stroke-linejoin="round"/></svg>';
  }

  /* 分区小标题：真机居中灰字 + 两侧细线 */
  function monTitle(text) {
    return '<div class="mon-title"><span>' + text + "</span></div>";
  }

  /* 流向图：与 App 的 MonitorFlowCard 同一套几何
     apps/FrsetNext/Sources/Features/Monitor/Views/MonitorFlow.swift
     · 左 88pt 来源格 │ 中间流带 │ 右 134pt 分支格，卡片 padding 8 / radius 10
     · 高度 = max(116, n*34 + (n-1)*4)，分支格间距 4
     · 流带厚 = max(2, value/max*34)，零值 1.5；带间距 2；末端厚 = max(2, start*0.88)
     · FlowRibbon 控制点：x0+0.45w / x1-0.35w，bend 首条 -4、其余 4
     · 渐变 0.72 → 0.42 + 0.22 发丝描边；分支底色 0.16 → 0.06 + 0.22 发丝边 */
  var MF_C = {
    download: "#4DB3E6", upload: "#F28C59", compressed: "#F2B84D",
    wired: "#9973D9", battery: "#66C773", system: "#E64047",
    discharge: "#F29E2E", power: "#388CF2"
  };
  var mfUid = 0;

  function mfRGBA(hex, a) {
    var h = hex.replace("#", "");
    return "rgba(" + parseInt(h.slice(0, 2), 16) + "," + parseInt(h.slice(2, 4), 16)
      + "," + parseInt(h.slice(4, 6), 16) + "," + a + ")";
  }

  function mfAttr(s) {
    return String(s).replace(/&/g, "&amp;").replace(/"/g, "&quot;")
      .replace(/</g, "&lt;").replace(/>/g, "&gt;");
  }

  /* 12pt SF Symbol / 14pt 应用图标（真机网络分支取 NSApplication 图标） */
  function mfIcon(icon, color) {
    if (!icon) return "";
    if (icon.k === "app") {
      return '<span class="mf-app-ico" style="background:' + icon.bg + '">'
        + (icon.glyph || "") + "</span>";
    }
    var paths = {
      updown: '<path d="M4 1.5v9M2 4l2-2 2 2M8 10.5v-9M6 8l2 2 2-2"/>',
      display: '<rect x="1.5" y="2.5" width="9" height="6.5" rx="1"/><path d="M4.5 11h3M6 9v2"/>',
      connector: '<path d="M2 5h4M2 7h4M6 4.5v3"/><rect x="7" y="3" width="3.5" height="6" rx="1"/>',
      bolt: '<path d="M7 1 3 7h3l-1 4 4-6H6z"/>',
      app: '<rect x="2" y="2" width="8" height="8" rx="2"/><path d="M4.5 6h3M6 4.5v3"/>'
    };
    return '<svg class="mf-sf" viewBox="0 0 12 12" fill="none" stroke="' + color
      + '" stroke-width="1.1" stroke-linecap="round" stroke-linejoin="round">'
      + (paths[icon.name] || paths.app) + "</svg>";
  }

  function monFlowCard(cfg) {
    var branches = cfg.branches || [];
    var n = Math.max(1, branches.length);
    var H = Math.max(116, n * 34 + (n - 1) * 4);
    var tileH = (H - (n - 1) * 4) / n;
    var maxV = Math.max(0.001, cfg.input.value || 0,
      branches.reduce(function (s, b) { return s + (b.value || 0); }, 0));
    var widths = branches.map(function (b) {
      return b.value > 0 ? Math.max(2, (b.value / maxV) * 34) : 1.5;
    });
    var total = widths.reduce(function (s, w) { return s + w; }, 0) + 2 * (n - 1);
    var cursor = H / 2 - total / 2;
    var uid = "mf" + (++mfUid);
    var defs = "", bands = "";
    branches.forEach(function (b, i) {
      var w = widths[i];
      var start = cursor + w / 2;
      cursor += w + 2;
      var end = i * (tileH + 4) + tileH / 2;
      var ew = Math.max(2, w * 0.88);
      var bend = n === 1 ? 6 : (i === 0 ? -4 : 4);
      var s0 = start - w / 2, s1 = start + w / 2;
      var e0 = end - ew / 2, e1 = end + ew / 2;
      var f = function (v) { return v.toFixed(2); };
      var d = "M0 " + f(s0) + " C45 " + f(s0 + bend) + " 65 " + f(e0 + bend)
        + " 100 " + f(e0) + " L100 " + f(e1) + " C65 " + f(e1 + bend)
        + " 45 " + f(s1 + bend) + " 0 " + f(s1) + " Z";
      defs += '<linearGradient id="' + uid + "-g" + i + '" x1="0" y1="0" x2="1" y2="0">'
        + '<stop offset="0" stop-color="' + b.color + '" stop-opacity="0.72"/>'
        + '<stop offset="1" stop-color="' + b.color + '" stop-opacity="0.42"/></linearGradient>';
      bands += '<path d="' + d + '" fill="url(#' + uid + "-g" + i + ')" stroke="'
        + b.color + '" stroke-opacity="0.22" stroke-width="0.5"/>';
    });

    var src = '<div class="mf-src"><div class="mf-src-in">'
      + mfIcon(cfg.input.icon || { k: "sf", name: "updown" }, cfg.input.color)
      + '<b style="color:' + cfg.input.color + '">' + cfg.input.text + "</b>"
      + "<span>" + cfg.input.title + "</span></div></div>";

    var tiles = branches.map(function (b) {
      return '<div class="mf-tile" style="background:linear-gradient(135deg,'
        + mfRGBA(b.color, 0.16) + "," + mfRGBA(b.color, 0.06) + ');border-color:'
        + mfRGBA(b.color, 0.22) + '"'
        + (b.detail ? ' title="' + mfAttr(b.detail) + '"' : "") + '>'
        + '<div class="mf-tile-top">' + mfIcon(b.icon, b.color)
        + "<b>" + b.text + "</b>"
        + (b.active ? '<i class="mf-live" style="background:' + b.color
          + '" title="当前正在传输"></i>' : "")
        + '</div><span class="mf-tile-name">' + b.name + "</span></div>";
    }).join("");

    return '<div class="mf-card' + (cfg.compact ? " mf-compact" : "")
      + (cfg.plate === "gridded" ? " mf-plate-grid" : "")
      + '" style="--mf-h:' + H + 'px;--mf-rows:' + n + '">'
      + (cfg.plate === "gridded"
        ? '<div class="mf-grid-lines"><i></i><i></i><i></i></div>' : "")
      + src
      + '<div class="mf-ribbon"><svg viewBox="0 0 100 ' + H
      + '" preserveAspectRatio="none"><defs>' + defs + "</defs>" + bands + "</svg></div>"
      + '<div class="mf-dst">' + tiles + "</div></div>"
      + (cfg.coverage ? '<div class="mf-coverage">' + cfg.coverage + "</div>" : "");
  }

  /* 键值行：左标签右数值（数值可带颜色） */
  function monRows(rows) {
    return '<div class="mon-rows">' + rows.map(function (r) {
      return '<div class="mon-row' + (r.strong ? " strong" : "") + '">'
        + '<span class="mon-k">' + r.k + '</span>'
        + '<span class="mon-v' + (r.c ? " " + r.c : "") + '">' + r.v + '</span></div>';
    }).join("") + "</div>";
  }

  /* 分段条：真机的构成条（多色段 + 下方图例） */
  function monBar(segments, legend) {
    var bar = '<div class="mon-segbar">' + segments.map(function (s) {
      return '<i style="width:' + s.w + '%;background:' + s.c + '"></i>';
    }).join("") + "</div>";
    var lg = '<div class="mon-legend">' + legend.map(function (l) {
      return '<span><i style="background:' + l.c + '"></i>' + l.t + "</span>";
    }).join("") + "</div>";
    return bar + lg;
  }

  /* 进程表：真机的「App 图标 + 名称 + 进程数 + 数值 + 关闭按钮」 */
  function monProcs(list, col2) {
    return '<div class="mon-procs"><div class="mon-proc-head"><span>进程</span>'
      + (col2 ? '<span>读</span><span>写</span>' : '<span>' + (list[0] && list[0].unit || "内存") + '</span>')
      + "</div>" + list.map(function (p) {
        return '<div class="mon-proc">'
          + '<span class="mon-proc-ico" style="background:' + p.c + '"></span>'
          + '<span class="mon-proc-name">' + p.n + (p.cnt ? ' <em>' + p.cnt + " 进程</em>" : "") + "</span>"
          + (col2 ? '<span class="mon-proc-v">' + p.r + '</span><span class="mon-proc-v">' + p.w + "</span>" : '<span class="mon-proc-v">' + p.v + "</span>")
          + '<span class="mon-proc-x">✕</span></div>';
      }).join("") + "</div>";
  }

  var MON_DATA = {
    power: function () {
      return '<div class="mon-power-top">'
        + '<span class="mon-bolt"><svg viewBox="0 0 24 24" fill="none" stroke="#2F6BFF" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"><path d="M13 3 5.5 13.5H11l-1 7.5L18 10.5h-5.5z"/></svg></span>'
        + '<div><span class="mon-cap">输出（电池供电）</span><b class="mon-big">26.2W</b></div></div>'
        + monTitle("电源流向")
        + monFlowCard({
          input: { text: "26.24 W", title: "电池放电", value: 26.24,
            color: MF_C.discharge, icon: { k: "sf", name: "bolt" } },
          branches: [
            { name: "系统供电", text: "26.24 W", value: 26.24, color: MF_C.power,
              icon: { k: "sf", name: "display" } },
            { name: "USB", text: "1.25 W", value: 1.25, color: MF_C.wired,
              icon: { k: "sf", name: "connector" } }
          ]
        })
        + '<div class="mon-sub">CPU 能耗影响<span class="mon-sub-right">近 2 秒</span></div>'
        + monProcs([
          { n: "wechatwebdevtools", v: "1.01 W", c: "#8A8A8E" },
          { n: "ChatGPT", v: "487.0 mW", c: "#7A5AF8" },
          { n: "log", v: "265.6 mW", c: "#1F9D63" },
          { n: "Microsoft Edge", v: "183.5 mW", c: "#4285F4" },
          { n: "Kitnest", v: "139.8 mW", c: "#2F6BFF" }
        ]);
    },

    battery: function () {
      return '<div class="mon-batt-top">'
        + ring(32, "#F5A623", "32%", "电量")
        + '<div class="mon-batt-cap"><b>电池供电</b><span>预计还可使用 32 分钟</span></div></div>'
        + '<div class="mon-batt-health"><div><span class="mon-cap">电池健康</span><b class="mon-big orange">88%</b></div>'
        + '<span class="mon-cap">循环 105 次</span></div>'
        + '<div class="mon-progress"><i style="width:88%"></i></div>'
        + monRows([
          { k: "当前最大容量", v: "4053 mAh / 4629 mAh" },
          { k: "当前电量容量", v: "1266 mAh" },
          { k: "数据更新", v: "16:37:19" }
        ])
        + monTitle("电池状态")
        + monRows([
          { k: "电压", v: "11.06 V" },
          { k: "电流", v: "-2.37 A" },
          { k: "放电功率", v: "26.24 W" },
          { k: "电池温度", v: "35.3 °C" }
        ])
        + '<div class="mon-toggle"><span>低电量模式</span><i class="off"></i></div>'
        + '<p class="mon-note">使用电池时，降低屏幕亮度、关闭后台高耗电 App 可以延长续航。</p>'
        + '<div class="mon-links"><a>打开系统电源设置</a><a>打开应用电池设置</a></div>';
    },

    cpu: function () {
      var cores = [];
      for (var i = 0; i < 10; i++) {
        cores.push({ n: "C" + (i + 1), p: i < 5 ? 100 : 100, hot: true });
      }
      return '<div class="mon-cpu-top">'
        + ring(85, "#F5A623", "85°")
        + ring(100, "#2F6BFF", "100%", "总占用")
        + '<div class="mon-cpu-kv">'
        + '<div><span>系统</span><b class="red">13%</b></div>'
        + '<div><span>用户</span><b class="blue">87%</b></div>'
        + '<div><span>空闲</span><b>0%</b></div>'
        + '<div><span>启动时间</span><b>9 天 9 小时</b></div>'
        + "</div></div>"
        + '<div class="mon-chip-row"><span class="mon-chip-ico">▣</span>Apple M5 · 10 核 (…E6) · macOS 27.0'
        + '<span class="mon-thermal">● 热压力 偏热</span></div>'
        + monTitle("使用历史")
        + '<div class="mon-hist-head"><span class="blue">当前 100%</span><span>均值 37% · 峰值 100%</span></div>'
        + spark([12, 18, 9, 22, 14, 30, 46, 22, 16, 11, 14, 40, 62, 30, 18, 14, 11, 13, 34, 52, 28, 16, 12, 44, 66, 40, 22, 16, 13, 40, 58, 34, 20, 15, 12, 18, 44, 60, 38, 22, 16, 13, 36, 52, 30, 18], "#2F6BFF")
        + monTitle("核心占用（10 核）")
        + '<div class="mon-cores">' + cores.map(function (c) {
          return '<div class="mon-core"><div class="mon-core-box hot"></div><span>' + c.n + '</span><b class="red">100%</b></div>';
        }).join("") + "</div>"
        + '<div class="mon-clusters"><div><span><i style="background:#2F6BFF"></i>性能核 P4</span><b>58%</b></div>'
        + '<div><span><i style="background:#5AC8FA"></i>能效核 E6</span><b>68%</b></div></div>'
        + monTitle("平均负载");
    },

    memory: function () {
      return '<div class="mon-mem-top">'
        + ring(95, "#3FCB7F", "95%", "已用")
        + '<div class="mon-mem-kv">'
        + '<div><span>已用</span><b>12.7 GB</b></div>'
        + '<div><span>总量</span><b>16.0 GB</b></div>'
        + '<div><span>Swap</span><b>17.0 GB</b></div>'
        + '<div><span>压缩</span><b class="orange">6.1 GB</b></div>'
        + "</div></div>"
        + '<div class="mon-memory-cta"><span><i></i>内存维护</span><button type="button">释放内存</button></div>'
        + monTitle("内存构成")
        + monBar([
          { w: 22, c: "#3FCB7F" }, { w: 26, c: "#F5A623" },
          { w: 28, c: "#A78BFA" }, { w: 24, c: "#D8D8DE" }
        ], [
          { c: "#3FCB7F", t: "应用" }, { c: "#F5A623", t: "压缩" },
          { c: "#A78BFA", t: "联动" }, { c: "#D8D8DE", t: "空闲" }
        ])
        + '<p class="mon-note">可回收 ≈ 6.1 GB</p>'
        + monTitle("使用历史")
        + spark([88, 90, 89, 92, 91, 93, 90, 92, 94, 93, 91, 92, 94, 95, 93, 92, 91, 93, 95, 94, 92, 93, 91, 95, 94, 93, 92, 94, 95, 93, 92, 94, 95, 93, 91, 92], "#3FCB7F")
        + '<div class="mon-pressure"><span>内存压力</span><b>94.9%</b></div>'
        + monTitle("内存占用进程")
        + monProcs([
          { n: "ChatGPT", cnt: 120, v: "12.7 GB", c: "#7A5AF8" },
          { n: "Microsoft Edge", cnt: 30, v: "6.9 GB", c: "#4285F4" },
          { n: "WorkBuddy", cnt: 29, v: "2.8 GB", c: "#1F9D63" },
          { n: "node", cnt: 45, v: "2.2 GB", c: "#2F6BFF" },
          { n: "QQ", cnt: 9, v: "1.2 GB", c: "#F5A623" },
          { n: "WeChat", cnt: 14, v: "1.1 GB", c: "#3FCB7F" },
          { n: "omp", cnt: 6, v: "872 MB", c: "#2F6BFF" },
          { n: "chrome-…-less-shell", cnt: 16, v: "612 MB", c: "#8A8A8E" }
        ]);
    },

    network: function () {
      return '<div class="mon-net-card">'
        + '<div class="mon-net-top"><div><span class="mon-cap down">↓ 下载</span><b>72.0 KB/s</b></div>'
        + '<div><span class="mon-cap up">↑ 上传</span><b>26.0 KB/s</b></div></div>'
        + '<div class="mon-net-chart">' + spark([4, 6, 3, 8, 5, 12, 9, 20, 60, 95, 40, 22, 30, 18], "#F5A623", 280, 74) + "</div>"
        + '<div class="mon-net-legend"><span>97.7 KB/s</span><span>60 秒前</span><span>现在</span></div>'
        + "</div>"
        + monTitle("流量去哪了")
        + monFlowCard({
          compact: true,
          coverage: "最近 10 分钟",
          input: { text: "239 MB", title: "合计", value: 239,
            color: MF_C.download, icon: { k: "sf", name: "updown" } },
          branches: [
            { name: "verge-mihomo", text: "141 MB", value: 141, color: MF_C.download,
              icon: { k: "app", bg: "#5B8DEF", glyph: "V" }, active: true,
              detail: "10 分钟 141 MB · 当前 ↓1.2 MB/s ↑80 KB/s" },
            { name: "WorkBuddy", text: "50.2 MB", value: 50.2, color: MF_C.upload,
              icon: { k: "app", bg: "#1F9D63", glyph: "W" }, active: true,
              detail: "10 分钟 50.2 MB · 当前 ↓320 KB/s ↑46 KB/s" },
            { name: "python3.10", text: "23.9 MB", value: 23.9, color: MF_C.compressed,
              icon: { k: "app", bg: "#3776AB", glyph: "Py" },
              detail: "10 分钟 23.9 MB · 当前 ↓0 B/s ↑0 B/s" },
            { name: "adb", text: "23.9 MB", value: 23.9, color: MF_C.wired,
              icon: { k: "sf", name: "app" },
              detail: "10 分钟 23.9 MB · 当前 ↓0 B/s ↑0 B/s" }
          ]
        })
        + monRows([
          { k: "峰值下载", v: "6.1 MB/s", c: "blue" },
          { k: "峰值上传", v: "4.0 MB/s", c: "orange" },
          { k: "累计下载", v: "1.7 GB" },
          { k: "累计上传", v: "666 MB" }
        ])
        + monTitle("网络连接")
        + '<div class="mon-net-state"><span class="dot-red"></span>未连接</div>'
        + '<div class="mon-pinggrid">' + Array.apply(null, Array(60)).map(function (_, i) {
          return '<i class="' + (i === 34 ? "red" : (i > 26 && i < 36 ? "orange" : (i % 7 === 0 ? "green" : ""))) + '"></i>';
        }).join("") + "</div>"
        + monRows([
          { k: "延迟", v: "253.19 ms" },
          { k: "抖动", v: "3.76 ms" }
        ])
        + monTitle("接口")
        + monRows([
          { k: "主接口", v: "en0" },
          { k: "本地 IP", v: "192.168.31.254" }
        ]);
    },

    disk: function () {
      return monTitle("读写历史")
        + '<div class="mon-disk-chart">' + spark([12, 30, 18, 60, 20, 14, 40, 90, 25, 16, 60, 30, 18, 80, 26, 14, 44, 96, 30, 18, 62, 24, 14, 50, 86, 28, 16, 58, 22, 12], "#3FCB7F", 300, 66) + "</div>"
        + '<div class="mon-disk-two"><span class="green">峰值读取&nbsp;&nbsp;1.5 GB/s</span><span class="red">峰值写入&nbsp;&nbsp;911 MB/s</span></div>'
        + monTitle("容量构成")
        + monBar([
          { w: 70, c: "#3FCB7F" }, { w: 5, c: "#F5A623" }, { w: 25, c: "#C8C8CE" }
        ], [
          { c: "#3FCB7F", t: "已用 320 GB" }, { c: "#F5A623", t: "可清除 20.1 GB" }, { c: "#C8C8CE", t: "空闲 141 GB" }
        ])
        + '<div class="mon-pressure"><span>总量</span><b>460 GB</b></div>'
        + monTitle("NVMe SMART")
        + monRows([
          { k: "温度", v: "50 °C", c: "orange" },
          { k: "健康度", v: "97 %", c: "green" },
          { k: "上电次数", v: "137" },
          { k: "上电小时", v: "1486 h" },
          { k: "严重警告", v: "无" },
          { k: "可用备用", v: "100 %" },
          { k: "终身读取", v: "312 TB" },
          { k: "终身写入", v: "77.1 TB" }
        ])
        + monTitle("磁盘占用进程")
        + monProcs([
          { n: "ChatGPT", cnt: 120, r: "6.8 MB/s", w: "2.2 MB/s", c: "#7A5AF8" },
          { n: "Micr...Edge", cnt: 30, r: "3.7 MB/s", w: "16.7 KB/s", c: "#4285F4" },
          { n: "Toke...onitor", cnt: 3, r: "1.7 MB/s", w: "3.3 KB/s", c: "#2F6BFF" },
          { n: "node", cnt: 6, r: "1.6 MB/s", w: "0 B/s", c: "#1F9D63" },
          { n: "Kitnest", cnt: 0, r: "791 KB/s", w: "0 B/s", c: "#2F6BFF" },
          { n: "QQ", cnt: 9, r: "616 KB/s", w: "0 B/s", c: "#F5A623" },
          { n: "Finder", cnt: 0, r: "299 KB/s", w: "0 B/s", c: "#4285F4" },
          { n: "WeChat", cnt: 14, r: "187 KB/s", w: "0 B/s", c: "#3FCB7F" }
        ], true);
    },

    sensors: function () {
      return monTitle("热区")
        + '<div class="mon-zones">'
        + '<div class="mon-zone"><span class="mon-zone-ico cpu">▣</span><span class="mon-zone-name">CPU</span>'
        + '<span class="mon-zone-bar"><i class="hot" style="width:83%"></i></span><b class="red">83°</b></div>'
        + '<div class="mon-zone"><span class="mon-zone-ico gpu">◈</span><span class="mon-zone-name">GPU</span>'
        + '<span class="mon-zone-bar"><i class="warm" style="width:72%"></i></span><b class="orange">72°</b></div>'
        + '<div class="mon-zone"><span class="mon-zone-ico batt">▬</span><span class="mon-zone-name">电池</span>'
        + '<span class="mon-zone-bar"><i class="cool" style="width:36%"></i></span><b class="green">36°</b></div>'
        + "</div>"
        + '<div class="mon-legend"><span><i style="background:#3FCB7F"></i>正常 &lt;60°</span>'
        + '<span><i style="background:#F5A623"></i>偏热 60–80°</span>'
        + '<span><i style="background:#E8443B"></i>过热 &gt;80°</span></div>'
        + '<div class="mon-disclosure">› 全部温度传感器 (117)</div>'
        + monTitle("电压 (34)")
        + monRows([
          { k: "电压传感器 (Vb0f)", v: "0.011 V" },
          { k: "电压传感器 (Vb1f)", v: "0.011 V" },
          { k: "12V 供电电压", v: "0.011 V" }
        ])
        + monTitle("电流 (43)")
        + monRows([
          { k: "电流传感器 (Ib8f)", v: "0.01 A" },
          { k: "供电轨电流 (IP0b)", v: "0.00 A" },
          { k: "3.8V 轨电流", v: "0.00 A" }
        ])
        + monTitle("功率 (55)")
        + monRows([
          { k: "功率传感器 (PHPB)", v: "200.00 W" },
          { k: "系统总功耗", v: "27.65 W" },
          { k: "电池功耗", v: "27.23 W" }
        ])
        + monTitle("能耗 (95)")
        + monRows([
          { k: "能耗传感器 (BC1V)", v: "27662.00 Wh" },
          { k: "能耗传感器 (BCMV)", v: "27662.00 Wh" },
          { k: "能耗传感器 (B0CT)", v: "26880.00 Wh" }
        ])
        + '<div class="mon-pressure"><span>电池电量</span><b class="green">31%</b></div>';
    },

    gpu: function () {
      return '<div class="mon-gpu-top">'
        + ring(63, "#2F6BFF", "63%", "GPU 占用")
        + '<div class="mon-mem-kv">'
        + '<div><span>型号</span><b>Apple M5</b></div>'
        + '<div><span>渲染利用率</span><b class="blue">60%</b></div>'
        + '<div><span>平铺利用率</span><b class="green">37%</b></div>'
        + '<div><span>GPU 温度</span><b class="orange">83°</b></div>'
        + "</div></div>"
        + monTitle("使用历史")
        + spark([22, 26, 30, 28, 34, 32, 38, 36, 30, 34, 42, 40, 46, 44, 38, 42, 40, 36, 34, 38, 36, 32, 30, 34, 38, 42, 40, 44, 42, 38, 34, 32, 36, 40, 44, 42], "#2F6BFF");
    }
  };

  function renderMonitorModule() {
    var body = $("#pmModBody");
    if (!body) return;
    var fn = MON_DATA[monState.mod];
    body.innerHTML = fn ? fn() : "";
  }

  function switchMonitorModule(mod) {
    if (MON_MODULES.indexOf(mod) < 0) return;
    monState.mod = mod;
    $$("#pmModBar button").forEach(function (b) {
      b.classList.toggle("on", b.getAttribute("data-mod") === mod);
    });
    renderMonitorModule();
    // 重播入场动效（真机靠 .id(module) 让 transition 重新开始）
    var body = $("#pmModBody");
    if (body) {
      body.style.animation = "none";
      void body.offsetWidth;
      body.style.animation = "";
    }
  }

  var pmModBar = $("#pmModBar");
  if (pmModBar) {
    pmModBar.addEventListener("click", function (e) {
      var b = e.target.closest("button[data-mod]");
      if (!b) return;
      switchMonitorModule(b.getAttribute("data-mod"));
    });
  }

  var pmModBody = $("#pmModBody");
  if (pmModBody) {
    pmModBody.addEventListener("click", function (e) {
      if (e.target.closest(".mon-memory-cta button")) { toast("正在释放内存"); return; }
      if (e.target.closest(".mon-links a")) { toast("在系统设置里打开"); return; }
      if (e.target.closest(".mon-proc-x")) {
        e.stopPropagation();
        toast("已结束该进程");
        return;
      }
      if (e.target.closest(".mon-disclosure")) { toast("展开全部温度传感器"); return; }
    });
  }

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
    if (page === "monitor") renderMonitorModule();
    // 页签内容重播淡入（真机 .transition(.opacity)）
    $$(".pm-page", pmBody).forEach(function (p) {
      if (p.hidden) return;
      p.style.animation = "none";
      void p.offsetWidth;
      p.style.animation = "";
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
      slides.forEach(function (s) {
        var on = s.getAttribute("data-shot-slide") === name;
        s.hidden = !on;
        // 切到这个标签才立刻拉对应动图：lazy 会让大 GIF 在切换后还空一拍
        if (on) $$("img", s).forEach(function (im) { im.removeAttribute("loading"); });
      });
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

  /* ---------------- v230 首页动效（参数全部来自 motion.js） ---------------- */
  (function () {
    var Motion = window.KitnestMotion;
    document.documentElement.classList.add("js-motion");

    // 首屏舞台按 WindowReveal 的口径从右上角展开（与真机主面板一致）
    var stage = $(".hero-stage");
    if (stage && Motion) {
      Motion.revealIn(stage, {
        unit: { x: 1, y: 0 },
        scale: Motion.tokens.revealScale.preview,
        duration: Motion.openDuration(),
        timing: "caEaseOut"
      });
    }

    // 滚动揭示：进入视口才播，只播一次
    var els = $$("[data-reveal]");
    if ("IntersectionObserver" in window) {
      var io = new IntersectionObserver(function (entries) {
        entries.forEach(function (e) {
          if (!e.isIntersecting) return;
          e.target.classList.add("in");
          io.unobserve(e.target);
        });
      }, { threshold: 0.1, rootMargin: "0px 0px -40px 0px" });
      els.forEach(function (el) { io.observe(el); });
    } else {
      els.forEach(function (el) { el.classList.add("in"); });
    }

    // 预览不常驻：悬停条目出现、移出列表自动收起（真机 NSPopover 行为）。
    // 界面页「打开可交互预览」只做一次演示：展开后定时自动消失，不留常驻浮层。
    $$("[data-home-demo]").forEach(function (a) {
      a.addEventListener("click", function () {
        location.hash = "#home";
        setTimeout(function () {
          var st = $(".hero-stage");
          if (st) st.scrollIntoView({ behavior: "smooth", block: "center" });
          var li = $(".pm-item[data-id='c3']");
          if (!li) return;
          var item = findItem(li.getAttribute("data-id"));
          if (!item) return;
          showPreview(item, li, false);
          setTimeout(function () {
            if (previewAnchorId === item.id && !previewPinned) closePreview();
          }, 3200);
        }, 100);
      });
    });

    // 六个功能卡片的「看演示」跳到界面页对应动图
    $$("[data-demo-jump]").forEach(function (btn) {
      btn.addEventListener("click", function () {
        var name = btn.getAttribute("data-demo-jump");
        location.hash = "#showcase";
        setTimeout(function () {
          var tab = $('.shot-tab[data-shot="' + name + '"]');
          if (tab) tab.click();
          var st = $("#shotStage");
          if (st) st.scrollIntoView({ behavior: "smooth", block: "center" });
        }, 60);
      });
    });
  })();

})();
