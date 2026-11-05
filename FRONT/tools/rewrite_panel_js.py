#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""把官网 mock 主面板的 JS 重写成与真机 1:1 的交互。

真机行为依据（apps/FrsetNext/Sources）：
  PanelRootView.pageSegments       分段切换（主页 / 监测 / 中转 / 投屏）
  PanelRootView.captureAction       截图菜单：截图 / 窗口截图 / ─ / 划词翻译 / 录屏
  PanelRootView.toolbar(齿轮 Menu)  置顶窗口 ⌘P / 悬浮剪贴板 ⇧⌘V / ─ / 暂停记录剪贴板 /
                                   设置 ⌘, / 使用统计 / ─ / 退出 ⌘Q
  PanelRootView.bottomToolbar       底部胶囊 4 图标：搜索 / 分类筛选 / 标签 / 回到顶部
  SearchSectionView                 输入关键词出分类 chips + 结果；输入 / 出命令列表
  ClipboardRow                      缩略图 + 来源徽章 + 标题 + 副行
  ClipboardTableHostView            hover 出 ↓/↵；单击开预览；双击复制；⌘/⇧ 点击多选；右键出菜单
  ClipboardNativeMenuPresenter       右键菜单：复制 / 隔空投送 / 编辑 / 重命名 / 标记为笔记 /
                                   AI 摘要 / 标签▸ / ─ / 删除
  CalendarSectionView               ←/→ 切周，点标题回今天，右上折叠；日期点选描边环
"""
import io, os, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PATH = os.path.join(ROOT, 'assets', 'site.js')

s = io.open(PATH, encoding='utf-8').read()

start = s.find('  /* ---------------- 可交互主面板 ---------------- */')
end = s.find('  /* ---------------- 截图切换 ---------------- */')
if start < 0 or end < 0 or end < start:
    sys.exit('锚点没找到 start=%d end=%d' % (start, end))

NEW = u'''  /* ---------------- 可交互主面板（对齐真机 PanelRootView） ---------------- */

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
      preview: '<span class="pv-kind">Markdown</span><pre># Kitnest 演示仓库（示例内容）\\n\\n## 功能\\n- 剪贴板历史\\n- 截图标注\\n- 系统监控</pre>' },
    { id: "c4", kind: "json", badge: "json", app: "访达",
      title: '{ "name": "kitnest-demo.config.json",',
      meta: "今天 12:08 · 647 个字符",
      view: "json",
      preview: '<span class="pv-kind">JSON</span><pre>{\\n  "name": "kitnest-demo.config.json",\\n  "app": "kitnest-demo",\\n  "version": "1.0.0",\\n  "features": {\\n    "clipboard": { "keepDays": 30 },\\n    "monitor": { "refreshSeconds": 1.5 }\\n  }\\n}</pre>' },
    { id: "c5", kind: "code", badge: "code", app: "Xcode",
      title: "// Sample.swift —— 演示用代码（假数据）",
      meta: "今天 12:08 · 412 个字符",
      view: "code",
      preview: '<span class="pv-kind">代码</span><pre>// Sample.swift —— 演示用代码（假数据）\\nimport Foundation\\n\\nstruct ClipItem {\\n    let kind: String\\n    let title: String\\n}</pre>' },
    { id: "c6", kind: "code", badge: "code", app: "PyCharm",
      title: "# sample.py —— 演示用代码（假数据）",
      meta: "今天 12:08 · 356 个字符",
      view: "code",
      preview: '<span class="pv-kind">代码</span><pre># sample.py —— 演示用代码（假数据）\\nimport hashlib\\n\\ndef sha256(path: str) -> str:\\n    h = hashlib.sha256()\\n    with open(path, "rb") as f:\\n        for chunk in iter(lambda: f.read(65536), b""):\\n            h.update(chunk)\\n    return h.hexdigest()</pre>' },
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
    text: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"><path d="M6 3.5h8.5L19 8v12.5H6z"/><path d="M14.5 3.5V8H19"/><path d="M9 12h7M9 15.5h7M9 8.5h3"/></svg>',
    url: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"><path d="M10.5 13.5a4 4 0 0 0 5.7 0l2.3-2.3a4 4 0 0 0-5.7-5.7l-1.3 1.3"/><path d="M13.5 10.5a4 4 0 0 0-5.7 0l-2.3 2.3a4 4 0 1 0 5.7 5.7l1.3-1.3"/></svg>',
    img: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"><rect x="3.5" y="4.5" width="17" height="15" rx="2"/><circle cx="9" cy="10" r="1.6"/><path d="m4.5 17 4.5-4.5 3.5 3.5 3-3 4 4"/></svg>',
    code: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round"><path d="m9 8-4 4 4 4M15 8l4 4-4 4"/></svg>',
    json: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"><path d="M9 3.5c-2 0-2.6 1-2.6 2.6v3.3c0 1.3-.6 1.9-1.9 1.9v3.4c1.3 0 1.9.6 1.9 1.9v3.3c0 1.6.6 2.6 2.6 2.6"/><path d="M15 3.5c2 0 2.6 1 2.6 2.6v3.3c0 1.3.6 1.9 1.9 1.9v3.4c-1.3 0-1.9.6-1.9 1.9v3.3c0 1.6-.6 2.6-2.6 2.6"/></svg>',
    md: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"><rect x="2.5" y="5.5" width="19" height="13" rx="2"/><path d="M6 15.5v-7l3 3.5 3-3.5v7M15.5 8.5v7M15.5 15.5l3-3.5"/></svg>',
    file: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"><path d="M6 3.5h8.5L19 8v12.5H6z"/><path d="M14.5 3.5V8H19"/></svg>',
    down: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M12 4v12m0 0 4.5-4.5M12 16l-4.5-4.5M5 20h14"/></svg>',
    paste: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M9 4.5h6v2H9z"/><path d="M9 5.5H6.5A1.5 1.5 0 0 0 5 7v12.5A1.5 1.5 0 0 0 6.5 21h11a1.5 1.5 0 0 0 1.5-1.5V7a1.5 1.5 0 0 0-1.5-1.5H15"/><path d="m9 13 3 3 3-3"/></svg>'
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
          '<span class="pm-badge ' + it.badge + '">' + (it.badge === "chrome" ? "C" : it.badge.charAt(0).toUpperCase()) + '</span>' : "") +
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

  function closePreview() {
    if (!pmPreview) return;
    pmPreview.hidden = true;
  }

  function showPreview(item, anchorEl) {
    if (!pmPreview || !item) return;
    pmPreview.querySelector(".pm-preview-body").innerHTML = item.preview;
    pmPreview.hidden = false;
    // 贴着锚点行：下方放得下就放下方，否则翻到上方
    var bodyH = pmBody.clientHeight;
    var h = pmPreview.offsetHeight || 140;
    var rowTop = anchorEl ? anchorEl.offsetTop : 0;
    var rowH = anchorEl ? anchorEl.offsetHeight : 0;
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
    "2026-11-01": ["十月", "初八"], "2026-11-02": ["十月", "初九"], "2026-11-03": ["十月", "初十"],
    "2026-11-04": ["十月", "十一"], "2026-11-05": ["十月", "十二"], "2026-11-06": ["十月", "十三"],
    "2026-11-07": ["十月", "十四"], "2026-11-08": ["十月", "十五"], "2026-11-09": ["十月", "十六"],
    "2026-11-10": ["十月", "十七"], "2026-11-11": ["十月", "十八"], "2026-11-12": ["十月", "十九"],
    "2026-11-13": ["十月", "二十"], "2026-11-14": ["十月", "廿一"], "2026-11-15": ["十月", "廿二"],
    "2026-11-16": ["十月", "廿三"], "2026-11-17": ["十月", "廿四"], "2026-11-18": ["十月", "廿五"],
    "2026-11-19": ["十月", "廿六"], "2026-11-20": ["十月", "廿七"], "2026-11-21": ["十月", "廿八"],
    "2026-11-22": ["十月", "廿九"], "2026-11-23": ["十月", "三十"], "2026-11-24": ["冬月", "初一"],
    "2026-11-25": ["冬月", "初二"], "2026-11-26": ["冬月", "初三"], "2026-11-27": ["冬月", "初四"],
    "2026-11-28": ["冬月", "初五"], "2026-11-29": ["冬月", "初六"], "2026-11-30": ["冬月", "初七"]
  };
  var FESTIVAL = { "2026-11-07": "立冬", "2026-11-23": "小雪" };

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
      var lunar = LUNAR[key];
      var sub = FESTIVAL[key] || (lunar ? lunar[1] : "");
      var inner = '<span class="pm-day-in"><b>' + d.getDate() + "</b><span>" + sub + "</span></span>";
      btn.innerHTML = inner;
      if (FESTIVAL[key]) btn.classList.add("festival");
      btn.setAttribute("data-day", key);
      pmCalGrid.appendChild(btn);
    }
    var title = $(".pm-cal-title");
    if (title) {
      title.textContent = anchor.getFullYear() + " 年 " + (anchor.getMonth() + 1) + " 月";
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
    // 贴着触发按钮定位
    var panelRect = pmBody.getBoundingClientRect();
    var r = anchorEl.getBoundingClientRect();
    var mr = pmMenu.getBoundingClientRect();
    var left = r.left - panelRect.left + pmBody.scrollLeft;
    var top = r.bottom - panelRect.top + pmBody.scrollTop + 4;
    if (left + mr.width > pmBody.clientWidth) left = pmBody.clientWidth - mr.width;
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
    var panelRect = pmBody.getBoundingClientRect();
    var mr = pmCtx.getBoundingClientRect();
    var left = clientX - panelRect.left + pmBody.scrollLeft;
    var top = clientY - panelRect.top + pmBody.scrollTop;
    if (left + mr.width > pmBody.clientWidth) left = pmBody.clientWidth - mr.width;
    if (top + mr.height > pmBody.clientHeight) top = Math.max(0, pmBody.clientHeight - mr.height);
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
    var html = "<ul>";
    rows.slice(0, 8).forEach(function (r) {
      html += '<li><span class="r-kind ' + r.kind + '">' +
        (r.kind === "url" ? "链" : r.kind === "img" ? "图" : r.kind === "json" ? "JS" : r.kind === "md" ? "MD" : "码") +
        '</span><b></b><span></span></li>';
    });
    html += "</ul>";
    pmResults.innerHTML = html;
    var lis = pmResults.querySelectorAll("li");
    rows.slice(0, 8).forEach(function (r, i) {
      if (!lis[i]) return;
      lis[i].querySelector("b").textContent = r.title;
      lis[i].querySelector("span:last-child").textContent = r.sub;
    });
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
      var item = findItem(li.getAttribute("data-id"));
      if (item) showPreview(item, li);
    });
    pmList.addEventListener("mouseleave", function () {
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
      showPreview(item, li);
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

  function findItem(id) {
    for (var i = 0; i < clipState.items.length; i++) {
      if (clipState.items[i].id === id) return clipState.items[i];
    }
    return null;
  }

  if (pmBody) {
    pmBody.addEventListener("mouseleave", function () {
      closePreview();
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

'''

s = s[:start] + NEW + s[end:]
io.open(PATH, 'w', encoding='utf-8').write(s)
print('JS 已重写，%d 行' % len(s.split('\n')))
