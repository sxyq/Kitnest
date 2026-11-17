/* ============================================================
   Kitnest 手册 · 演示场景库
   ------------------------------------------------------------
   每个场景 = 迷你界面 HTML + 预设时间轴。
   时间轴里的选择器都指向本场景 body 内的元素。
   文案保持「功能有什么用 / 怎么用」两句以内，不堆术语。
   ============================================================ */
window.KDEMOS = {

  /* ------------------------------------------------ 主面板与首页 */
  panel: {
    title: "主面板：四个页签与搜索",
    stage: 460,
    body: `
      <div class="kui-panel">
        <div class="kui-panelbar">
          <span class="kui-seg on" data-page="home">主页</span>
          <span class="kui-seg" data-page="monitor">监测</span>
          <span class="kui-seg" data-page="transfer">中转</span>
          <span class="kui-seg" data-page="cast">投屏</span>
          <span class="kui-spacer"></span>
          <span class="kui-ico">⚙</span>
        </div>
        <div class="kui-search"><span>⌕</span><span class="kui-q"></span></div>
        <div class="kui-list" data-view="home">
          <div class="kui-row"><div class="kui-thumb t-text">T</div><div class="kui-meta"><div class="kui-t1">README 安装说明</div><div class="kui-t2">刚复制 · 纯文本</div></div><span class="kui-badge">文本</span></div>
          <div class="kui-row"><div class="kui-thumb t-img">▣</div><div class="kui-meta"><div class="kui-t1">Screenshot 2026-11-18</div><div class="kui-t2">1920 × 1080 · 图片</div></div><span class="kui-badge">图片</span></div>
          <div class="kui-row"><div class="kui-thumb t-link">↗</div><div class="kui-meta"><div class="kui-t1">kitnest.sxyq27.online</div><div class="kui-t2">链接</div></div><span class="kui-badge">链接</span></div>
          <div class="kui-row"><div class="kui-thumb t-file">▤</div><div class="kui-meta"><div class="kui-t1">素材包.zip</div><div class="kui-t2">12.4 MB · 文件</div></div><span class="kui-badge">文件</span></div>
        </div>
        <div class="kui-list kui-hidden" data-view="monitor">
          <div class="kui-row"><div class="kui-thumb t-code">C</div><div class="kui-meta"><div class="kui-t1">CPU 12%</div><div class="kui-t2">10 核 · 温度 46°C</div></div></div>
          <div class="kui-row"><div class="kui-thumb t-text">M</div><div class="kui-meta"><div class="kui-t1">内存 9.2 / 16 GB</div><div class="kui-t2">可释放缓存 1.8 GB</div></div></div>
        </div>
        <div class="kui-list kui-hidden" data-view="transfer">
          <div class="kui-row"><div class="kui-thumb t-file">⇪</div><div class="kui-meta"><div class="kui-t1">隔空投送</div><div class="kui-t2">发给附近的 Apple 设备</div></div></div>
          <div class="kui-row"><div class="kui-thumb t-link">▦</div><div class="kui-meta"><div class="kui-t1">扫码直传</div><div class="kui-t2">手机扫码上传 / 下载</div></div></div>
        </div>
        <div class="kui-list kui-hidden" data-view="cast">
          <div class="kui-row"><div class="kui-thumb t-code">▤</div><div class="kui-meta"><div class="kui-t1">安卓投屏</div><div class="kui-t2">USB / 无线连接</div></div></div>
        </div>
        <div class="kui-dock"><span>筛选</span><span>标签</span><span>编辑</span><span class="kui-spacer"></span><span>⌥A 呼出</span></div>
      </div>`,
    steps: [
      { cap: "主面板四个页签：主页看剪贴板，监测看系统，中转发文件，投屏连手机。", hold: 1200 },
      { move: '.kui-seg[data-page="monitor"]', ms: 620 },
      { click: '.kui-seg[data-page="monitor"]' },
      { run: function () { this.show = function () {}; this.stage.querySelectorAll(".kui-list").forEach(function (l) { l.classList.add("kui-hidden"); }); this.stage.querySelector('[data-view="monitor"]').classList.remove("kui-hidden"); this.stage.querySelectorAll(".kui-seg").forEach(function (s) { s.classList.toggle("on", s.dataset.page === "monitor"); }); }, hold: 780 },
      { cap: "监测页直接看 CPU、内存等实时状态。", hold: 980 },
      { move: '.kui-seg[data-page="transfer"]', ms: 560 },
      { click: '.kui-seg[data-page="transfer"]' },
      { run: function () { this.stage.querySelectorAll(".kui-list").forEach(function (l) { l.classList.add("kui-hidden"); }); this.stage.querySelector('[data-view="transfer"]').classList.remove("kui-hidden"); this.stage.querySelectorAll(".kui-seg").forEach(function (s) { s.classList.toggle("on", s.dataset.page === "transfer"); }); }, hold: 760 },
      { cap: "中转页把文件发给手机、平板或另一台 Mac。", hold: 900 },
      { move: '.kui-seg[data-page="home"]', ms: 540 },
      { click: '.kui-seg[data-page="home"]' },
      { run: function () { this.stage.querySelectorAll(".kui-list").forEach(function (l) { l.classList.add("kui-hidden"); }); this.stage.querySelector('[data-view="home"]').classList.remove("kui-hidden"); this.stage.querySelectorAll(".kui-seg").forEach(function (s) { s.classList.toggle("on", s.dataset.page === "home"); }); }, hold: 620 },
      { cap: "回到主页，在搜索框里直接输入就能搜文件、应用和剪贴板。", hold: 900 },
      { move: ".kui-search", ms: 480 },
      { click: ".kui-search" },
      { type: ".kui-q", text: "README" },
      { cap: "搜索框就是入口：不用先选分类，输入即搜。", hold: 1200 }
    ],
    hit: {
      ".kui-seg": function (node, d) {
        d.stage.querySelectorAll(".kui-list").forEach(function (l) { l.classList.add("kui-hidden"); });
        var v = d.stage.querySelector('[data-view="' + node.dataset.page + '"]');
        if (v) v.classList.remove("kui-hidden");
        d.stage.querySelectorAll(".kui-seg").forEach(function (s) { s.classList.toggle("on", s === node); });
      }
    }
  },

  /* ------------------------------------------------ 剪贴板历史 */
  clipboard: {
    title: "剪贴板历史：滚动、悬停、筛选",
    stage: 450,
    body: `
      <div class="kui-panel">
        <div class="kui-search"><span>⌕</span><span class="kui-q">按内容搜索…</span></div>
        <div class="kui-list" style="max-height:300px">
          <div class="kui-row"><div class="kui-thumb t-text">T</div><div class="kui-meta"><div class="kui-t1">会议纪要：11 月迭代排期</div><div class="kui-t2">今天 09:41 · 文本 · 1.2 KB</div></div><div class="kui-acts"><span class="kui-act">⎘</span><span class="kui-act">↵</span></div></div>
          <div class="kui-row"><div class="kui-thumb t-img">▣</div><div class="kui-meta"><div class="kui-t1">Screenshot 2026-11-18-0940</div><div class="kui-t2">1920 × 1080 · 图片</div></div><div class="kui-acts"><span class="kui-act">⎘</span><span class="kui-act">↵</span></div></div>
          <div class="kui-row"><div class="kui-thumb t-link">↗</div><div class="kui-meta"><div class="kui-t1">https://kitnest.sxyq27.online</div><div class="kui-t2">今天 09:12 · 链接</div></div><div class="kui-acts"><span class="kui-act">⎘</span><span class="kui-act">↵</span></div></div>
          <div class="kui-row"><div class="kui-thumb t-file">▤</div><div class="kui-meta"><div class="kui-t1">素材包.zip</div><div class="kui-t2">昨天 18:22 · 12.4 MB</div></div><div class="kui-acts"><span class="kui-act">⎘</span><span class="kui-act">↵</span></div></div>
          <div class="kui-row"><div class="kui-thumb t-code">C</div><div class="kui-meta"><div class="kui-t1">swiftc -O -parse-as-library …</div><div class="kui-t2">昨天 16:05 · 代码</div></div><div class="kui-acts"><span class="kui-act">⎘</span><span class="kui-act">↵</span></div></div>
          <div class="kui-row"><div class="kui-thumb t-text">T</div><div class="kui-meta"><div class="kui-t1">颜色值 #2F6BFF</div><div class="kui-t2">昨天 14:30 · 颜色</div></div><div class="kui-acts"><span class="kui-act">⎘</span><span class="kui-act">↵</span></div></div>
          <div class="kui-row"><div class="kui-thumb t-img">▣</div><div class="kui-meta"><div class="kui-t1">设计稿-深色.png</div><div class="kui-t2">11-17 10:18 · 图片</div></div><div class="kui-acts"><span class="kui-act">⎘</span><span class="kui-act">↵</span></div></div>
        </div>
        <div class="kui-dock"><span>筛选</span><span>标签</span><span>编辑</span><span class="kui-spacer"></span><span>已暂停</span></div>
      </div>`,
    steps: [
      { cap: "复制过的内容按时间倒序排在这里，类型自动识别。", hold: 1100 },
      { move: ".kui-list", ms: 500 },
      { scroll: ".kui-list", dy: 190, ms: 820 },
      { cap: "滚轮往下翻更早的记录，30 天内的都在。", hold: 800 },
      { move: ".kui-row:nth-child(4)", ms: 560 },
      { cap: "悬停一行，右侧浮出「粘贴 / 复制」两个动作。", hold: 900 },
      { move: ".kui-dock span:nth-child(1)", ms: 520 },
      { click: ".kui-dock span:nth-child(1)" },
      { run: function () {}, hold: 500 },
      { html: ".kui-list", value: `
          <div class="kui-menu" style="position:static;margin:2px 4px;box-shadow:none;border-color:#EDEDF1">
            <b class="on">全部类型</b><b>文本</b><b>图片</b><b>链接</b><b>文件</b><b class="sep"></b><b>只看置顶</b>
          </div>` , hold: 1000 },
      { cap: "底部的「筛选」按类型过滤，长列表里找东西靠它。", hold: 1300 },
      { html: ".kui-list", value: `
          <div class="kui-row on"><div class="kui-thumb t-img">▣</div><div class="kui-meta"><div class="kui-t1">Screenshot 2026-11-18-0940</div><div class="kui-t2">1920 × 1080 · 图片</div></div></div>
          <div class="kui-row"><div class="kui-thumb t-img">▣</div><div class="kui-meta"><div class="kui-t1">设计稿-深色.png</div><div class="kui-t2">11-17 10:18 · 图片</div></div></div>` , hold: 900 },
      { cap: "选中「图片」后只剩图片条目，筛选就是这样用的。", hold: 1200 }
    ]
  },

  /* ------------------------------------------------ 截图与动作条 */
  capture: {
    title: "截图：选区 → 动作条 → 钉住",
    stage: 430,
    body: `
      <div class="kui-screen">
        <div style="position:absolute;left:22px;top:18px;font-size:11px;color:#98A0AD">桌面</div>
        <div class="kui-select kui-hidden" style="left:120px;top:64px;width:210px;height:118px">
          <span class="kui-size">210 × 118</span>
        </div>
        <div class="kui-toolbar kui-hidden" style="position:absolute;left:120px;top:192px">
          <span>✎</span><span>▢</span><span>◯</span><span>→</span><span>▦</span><span style="background:#EEF3FF;color:#1E52D6">📌 钉住</span><span>↗</span><span>⤓</span>
          <span class="kui-spacer"></span><span>⎘</span><span>✓</span>
        </div>
        <div class="kui-menu kui-hidden" style="left:236px;top:224px;z-index:56">
          <b>钉在屏幕上</b><b>钉到右侧</b><b>钉到角落</b><b class="sep"></b><b>描边卡片</b><b>白边</b>
        </div>
      </div>`,
    steps: [
      { cap: "按 ⌥S 进入截图，屏幕暗下来，拖出要截的区域。", hold: 1000 },
      { move: { x: 120, y: 64 }, ms: 460 },
      { run: function () { this.stage.querySelector(".kui-select").classList.remove("kui-hidden"); }, hold: 420 },
      { move: { x: 330, y: 182 }, ms: 760 },
      { cap: "松手后出现动作条：标注、马赛克、钉住、复制都在这一条上。", hold: 1200 },
      { run: function () { this.stage.querySelector(".kui-toolbar").classList.remove("kui-hidden"); }, hold: 380 },
      { move: ".kui-toolbar span:nth-child(6)", ms: 620 },
      { click: ".kui-toolbar span:nth-child(6)" },
      { run: function () { this.stage.querySelector(".kui-menu").classList.remove("kui-hidden"); }, hold: 760 },
      { cap: "「钉住」还能选位置和外观，截完的图直接留在屏幕上对照。", hold: 1400 },
      { run: function () { this.stage.querySelector(".kui-menu").classList.add("kui-hidden"); }, hold: 300 },
      { move: ".kui-toolbar span:nth-child(9)", ms: 560 },
      { click: ".kui-toolbar span:nth-child(9)" },
      { run: function () { var t = document.createElement("div"); t.className = "kui-toast"; t.textContent = "已复制到剪贴板"; this.stage.appendChild(t); setTimeout(function () { t.remove(); }, 1400); }, hold: 1500 },
      { cap: "不钉图就直接复制或保存，全流程不用离开键盘。", hold: 1200 }
    ]
  },

  /* ------------------------------------------------ 监测 */
  monitor: {
    title: "系统监测：环形图、曲线与温度",
    stage: 470,
    body: `
      <div class="kui-win" style="width:430px">
        <div class="kui-titlebar"><div class="kui-lights"><i></i><i></i><i></i></div><span class="kui-wtitle">性能监测</span></div>
        <div class="kui-wbody">
          <div style="display:flex;gap:16px;align-items:center">
            <div class="kui-ring">
              <svg width="96" height="96" viewBox="0 0 96 96">
                <circle cx="48" cy="48" r="40" fill="none" stroke="#EEF0F4" stroke-width="9"></circle>
                <circle class="kui-ring-v" cx="48" cy="48" r="40" fill="none" stroke="#2F6BFF" stroke-width="9"
                        stroke-linecap="round" stroke-dasharray="251.3" stroke-dashoffset="221"></circle>
              </svg>
              <div class="kui-ring-c"><b>12%</b><i>CPU</i></div>
            </div>
            <div style="flex:1;display:flex;flex-direction:column;gap:9px">
              <div style="display:flex;justify-content:space-between;font-size:11.6px"><span>内存</span><b>9.2 / 16 GB</b></div>
              <div style="height:6px;border-radius:3px;background:#EEF0F4;overflow:hidden"><div class="kui-mem" style="width:57%;height:100%;background:#2F6BFF;border-radius:3px;transition:width .8s ease"></div></div>
              <div style="display:flex;justify-content:space-between;font-size:11.6px"><span>磁盘</span><b>412 / 994 GB</b></div>
              <div style="height:6px;border-radius:3px;background:#EEF0F4;overflow:hidden"><div style="width:41%;height:100%;background:#1F9D63;border-radius:3px"></div></div>
            </div>
          </div>
          <div style="margin-top:16px">
            <div style="display:flex;justify-content:space-between;font-size:11px;color:#7A7A84;margin-bottom:5px"><span>CPU 近 30 秒</span><span>46°C · 风扇 1800 rpm</span></div>
            <svg class="kui-spark" viewBox="0 0 380 56" preserveAspectRatio="none">
              <polyline class="kui-sparkline" fill="none" stroke="#2F6BFF" stroke-width="1.8"
                points="0,38 24,34 48,40 72,26 96,30 120,18 144,24 168,20 192,32 216,14 240,22 264,12 288,26 312,18 336,28 360,16 380,22"></polyline>
            </svg>
          </div>
          <div style="display:flex;gap:7px;margin-top:14px;flex-wrap:wrap">
            <span class="kui-chip on">CPU</span><span class="kui-chip">内存</span><span class="kui-chip">网络</span><span class="kui-chip">磁盘</span><span class="kui-chip">温度</span><span class="kui-chip">GPU</span>
          </div>
        </div>
      </div>`,
    steps: [
      { cap: "监测窗把所有硬件状态放在一屏：环形图看 CPU，进度条看内存和磁盘。", hold: 1350 },
      { move: ".kui-ring", ms: 620 },
      { run: function () {
          var v = this.stage.querySelector(".kui-ring-v");
          if (v) { v.style.transition = "stroke-dashoffset .9s ease"; v.setAttribute("stroke-dashoffset", "150"); }
          var b = this.stage.querySelector(".kui-ring-c b");
          if (b) b.textContent = "41%";
        }, hold: 900 },
      { cap: "负载变化时环形图和读数实时更新，不用打开活动监视器。", hold: 1000 },
      { move: ".kui-spark", ms: 560 },
      { cap: "下面的曲线保留最近 30 秒，尖峰一眼能看出来。", hold: 1000 },
      { move: ".kui-chip:nth-child(3)", ms: 500 },
      { click: ".kui-chip:nth-child(3)" },
      { run: function () {
          this.stage.querySelectorAll(".kui-chip").forEach(function (c) { c.classList.remove("on"); });
          this.stage.querySelectorAll(".kui-chip")[2].classList.add("on");
          var p = this.stage.querySelector(".kui-sparkline");
          if (p) { p.setAttribute("points", "0,42 24,40 48,36 72,38 96,30 120,34 144,26 168,30 192,22 216,28 240,20 264,24 288,18 312,22 336,16 360,20 380,14"); p.setAttribute("stroke", "#1F9D63"); }
        }, hold: 820 },
      { cap: "点上方标签切换模块，网络、温度、GPU 都在同一套视图里。", hold: 1250 }
    ],
    hit: {
      ".kui-chip": function (node, d) {
        d.stage.querySelectorAll(".kui-chip").forEach(function (c) { c.classList.remove("on"); });
        node.classList.add("on");
      }
    }
  },

  /* ------------------------------------------------ 菜单栏与图标 */
  menubar: {
    title: "菜单栏图标：面板从图标下展开",
    stage: 420,
    body: `
      <div style="width:100%;max-width:470px">
        <div class="kui-menubar">
          <span class="kui-glyph"></span>
          <span class="kui-mi">Kitnest</span>
          <span class="kui-spacer"></span>
          <span class="kui-mi">􀊫</span><span class="kui-mi">􀉉</span><span class="kui-mi">9:41</span>
        </div>
        <div class="kui-panel kui-hidden" style="margin-top:8px;width:340px;margin-left:8px">
          <div class="kui-panelbar">
            <span class="kui-ico">✂</span><span class="kui-ico">◎</span><span class="kui-ico">▤</span>
            <span class="kui-spacer"></span>
            <span class="kui-seg on">主页</span><span class="kui-seg">监测</span><span class="kui-seg">中转</span><span class="kui-seg">投屏</span>
            <span class="kui-spacer"></span><span class="kui-ico">⚙</span>
          </div>
          <div class="kui-search"><span>⌕</span><span class="kui-q" style="color:#8A8A94">搜索文件、应用、剪贴板…</span></div>
          <div class="kui-list" style="max-height:190px">
            <div class="kui-row"><div class="kui-thumb t-text">T</div><div class="kui-meta"><div class="kui-t1">会议纪要 11-18</div><div class="kui-t2">刚复制 · 文本</div></div></div>
            <div class="kui-row"><div class="kui-thumb t-img">▣</div><div class="kui-meta"><div class="kui-t1">Screenshot 09:40</div><div class="kui-t2">1920 × 1080 · 图片</div></div></div>
            <div class="kui-row"><div class="kui-thumb t-link">↗</div><div class="kui-meta"><div class="kui-t1">kitnest.sxyq27.online</div><div class="kui-t2">链接</div></div></div>
          </div>
          <div class="kui-dock"><span>筛选</span><span>标签</span><span>编辑</span><span class="kui-spacer"></span><span>⇧⌘V 悬浮</span></div>
        </div>
      </div>`,
    steps: [
      { cap: "Kitnest 常驻菜单栏，不占 Dock、不抢焦点，点图标就下来。", hold: 1100 },
      { move: ".kui-glyph", ms: 700 },
      { click: ".kui-glyph" },
      { run: function () { this.stage.querySelector(".kui-panel").classList.remove("kui-hidden"); }, hold: 900 },
      { cap: "面板从图标正下方展开，顶部一排动作：截图、取色、悬浮剪贴板、设置。", hold: 1200 },
      { move: ".kui-panelbar .kui-ico:nth-child(1)", ms: 560 },
      { cap: "截图（⌥S）不用先进面板，快捷键随时起手；这里是入口之一。", hold: 1000 },
      { move: '.kui-seg:nth-child(6)', ms: 600 },
      { cap: "右侧四个页签切主页 / 监测 / 中转 / 投屏，齿轮进设置。", hold: 1050 },
      { move: ".kui-ico:last-child", ms: 560 },
      { click: ".kui-ico:last-child" },
      { cap: "「设置」也从这里进；所有功能都能在设置里找到说明。", hold: 1100 }
    ]
  },

  /* ------------------------------------------------ 使用统计 */
  statistics: {
    title: "使用统计：计数、柱图、热力矩阵",
    stage: 460,
    body: `
      <div class="kui-win" style="width:430px">
        <div class="kui-titlebar"><div class="kui-lights"><i></i><i></i><i></i></div><span class="kui-wtitle">使用统计</span></div>
        <div class="kui-wbody">
          <div style="display:grid;grid-template-columns:repeat(5,1fr);gap:6px">
            <div class="kui-card" style="padding:8px 6px;text-align:center"><div class="kui-stat" style="font-size:16px;font-weight:650">128</div><div style="font-size:9px;color:#8A8A94">复制</div></div>
            <div class="kui-card" style="padding:8px 6px;text-align:center"><div style="font-size:16px;font-weight:650">47</div><div style="font-size:9px;color:#8A8A94">截图</div></div>
            <div class="kui-card" style="padding:8px 6px;text-align:center"><div style="font-size:16px;font-weight:650">19</div><div style="font-size:9px;color:#8A8A94">识别</div></div>
            <div class="kui-card" style="padding:8px 6px;text-align:center"><div style="font-size:16px;font-weight:650">86</div><div style="font-size:9px;color:#8A8A94">工具</div></div>
            <div class="kui-card" style="padding:8px 6px;text-align:center"><div style="font-size:16px;font-weight:650">312</div><div style="font-size:9px;color:#8A8A94">监测</div></div>
          </div>
          <div class="kui-sect">
            <div class="kui-sect-t">近 30 天</div>
            <div class="kui-bars">
              <i style="height:28%"></i><i style="height:44%"></i><i style="height:22%"></i><i style="height:58%"></i><i style="height:36%"></i><i style="height:66%"></i><i style="height:30%"></i><i style="height:74%"></i><i style="height:52%"></i><i style="height:88%"></i><i style="height:40%"></i><i style="height:62%"></i>
            </div>
          </div>
          <div class="kui-sect">
            <div class="kui-sect-t">活动矩阵</div>
            <div style="display:grid;grid-template-columns:repeat(18,1fr);gap:3px">
              ${Array.from({length:36}).map((_,i)=>`<span style="aspect-ratio:1;border-radius:2px;background:${['#EEF1F5','#DCE6FA','#B9CDF7','#7CA0FF','#2F6BFF'][[0,1,1,2,0,3,1,0,2,1,4,0,1,2,1,0,3,2][i%18]||0]}"></span>`).join('')}
            </div>
          </div>
        </div>
      </div>`,
    steps: [
      { cap: "统计窗三段：五个计数、近 30 天柱图、按天着色的活动矩阵。", hold: 1300 },
      { move: ".kui-stat", ms: 620 },
      { cap: "计数是累计值：复制、截图、识别、工具、监测各算各的。", hold: 1050 },
      { move: ".kui-bars", ms: 560 },
      { cap: "柱图看最近 30 天每天用了多少次，高低一眼能对比。", hold: 1000 },
      { move: ".kui-sect:last-child .kui-sect-t", ms: 520 },
      { cap: "矩阵按天着色，颜色越深用得越多；数据只存本机，不上传。", hold: 1300 }
    ]
  },

  /* ------------------------------------------------ 悬浮剪贴板工作台 */
  floatdesk: {
    title: "悬浮剪贴板：卡片网格 + 预览",
    stage: 460,
    body: `
      <div class="kui-win" style="width:470px">
        <div class="kui-titlebar"><div class="kui-lights"><i></i><i></i><i></i></div><span class="kui-wtitle">剪贴板工作台</span></div>
        <div class="kui-wbody" style="padding:0">
          <div class="kui-split" style="gap:0">
            <div style="flex:1.25;border-right:1px solid #F0F0F3">
              <div style="display:flex;gap:5px;padding:9px 10px 4px;flex-wrap:wrap">
                <span class="kui-chip on">全部</span><span class="kui-chip">文本</span><span class="kui-chip">图片</span><span class="kui-chip">链接</span><span class="kui-chip">文件</span><span class="kui-chip">代码</span>
              </div>
              <div class="kui-grid" style="grid-template-columns:repeat(2,1fr)">
                <div class="kui-cell"><span>会议纪要</span></div>
                <div class="kui-cell"><span>Screenshot</span></div>
                <div class="kui-cell"><span>颜色值</span></div>
                <div class="kui-cell"><span>README</span></div>
              </div>
            </div>
            <div style="flex:1;padding:12px">
              <div style="font-size:10.6px;color:#8A8A94;margin-bottom:6px">预览</div>
              <div style="font-size:11.4px;line-height:1.65;color:#33333B" class="kui-pv">
                会议纪要：11 月迭代排期<br><br>1. 手册重构完成交互演示<br>2. 截图域补充 OCR 用例<br>3. 下周一验收
              </div>
            </div>
          </div>
          <div class="kui-dock"><span>小</span><span>中</span><span>大</span><span class="kui-spacer"></span><span>⇧⌘V</span></div>
        </div>
      </div>`,
    steps: [
      { cap: "悬浮剪贴板是独立工作台：左边卡片网格，右边内容预览。", hold: 1200 },
      { move: ".kui-chip:nth-child(3)", ms: 560 },
      { click: ".kui-chip:nth-child(3)" },
      { run: function () {
          this.stage.querySelectorAll(".kui-chip").forEach(function (c) { c.classList.remove("on"); });
          this.stage.querySelectorAll(".kui-chip")[2].classList.add("on");
          var g = this.stage.querySelector(".kui-grid");
          if (g) g.innerHTML = '<div class="kui-cell"><span>Screenshot 09:40</span></div><div class="kui-cell"><span>设计稿-深色</span></div><div class="kui-cell"><span>截图 11-17</span></div>';
        }, hold: 820 },
      { cap: "点「图片」标签，只剩图片；类型标签就是过滤器。", hold: 1000 },
      { move: ".kui-cell:nth-child(2)", ms: 520 },
      { click: ".kui-cell:nth-child(2)" },
      { run: function () {
          var pv = this.stage.querySelector(".kui-pv");
          if (pv) pv.innerHTML = '<div style="height:112px;border-radius:8px;background:linear-gradient(135deg,#DDE7F7,#F0F4FB);border:1px solid #E1E5EC"></div><div style="font-size:10.4px;color:#8A8A94;margin-top:6px">1920 × 1080 · 昨天 09:40</div>';
        }, hold: 900 },
      { cap: "点卡片换右侧预览；图片直接看大图，不用打开文件。", hold: 1100 },
      { move: ".kui-dock span:nth-child(3)", ms: 520 },
      { click: ".kui-dock span:nth-child(3)" },
      { cap: "右下角切小 / 中 / 大三档，卡片密度跟着变。", hold: 1150 }
    ]
  },

  /* ------------------------------------------------ 预览与编辑 */
  preview: {
    title: "悬停预览：内容随类型变",
    stage: 430,
    body: `
      <div style="position:relative;width:100%;max-width:460px">
        <div class="kui-panel" style="width:340px">
          <div class="kui-list" style="max-height:250px">
            <div class="kui-row"><div class="kui-thumb t-text">T</div><div class="kui-meta"><div class="kui-t1">会议纪要 11-18</div><div class="kui-t2">文本 · 1.2 KB</div></div></div>
            <div class="kui-row"><div class="kui-thumb t-link">↗</div><div class="kui-meta"><div class="kui-t1">kitnest.sxyq27.online</div><div class="kui-t2">链接</div></div></div>
            <div class="kui-row"><div class="kui-thumb t-img">▣</div><div class="kui-meta"><div class="kui-t1">Screenshot 09:40</div><div class="kui-t2">图片 · 1920×1080</div></div></div>
            <div class="kui-row"><div class="kui-thumb t-file">▤</div><div class="kui-meta"><div class="kui-t1">素材包.zip</div><div class="kui-t2">文件 · 12.4 MB</div></div></div>
          </div>
        </div>
        <div class="kui-card kui-hidden" style="position:absolute;right:0;top:26px;width:220px;box-shadow:0 18px 40px rgba(11,11,13,.16);z-index:40">
          <div style="display:flex;align-items:center;gap:8px;border-bottom:1px solid #F0F0F3;padding-bottom:7px;margin-bottom:7px">
            <b style="font-size:11.4px">预览</b><span class="kui-spacer"></span>
            <span class="kui-btn" style="padding:2px 7px">编辑</span>
          </div>
          <div class="kui-pvx" style="font-size:10.8px;line-height:1.6;color:#44444C">会议纪要：11 月迭代排期<br>1. 手册重构完成交互演示<br>2. 截图域补充 OCR 用例</div>
          <div class="kui-pvacts" style="display:flex;gap:6px;margin-top:9px">
            <span class="kui-btn" style="padding:3px 8px">复制</span><span class="kui-btn" style="padding:3px 8px">粘贴</span>
          </div>
        </div>
      </div>`,
    steps: [
      { cap: "列表里悬停任意一条，旁边弹出预览卡，不用双击打开。", hold: 1150 },
      { move: ".kui-row:nth-child(1)", ms: 640 },
      { run: function () { this.stage.querySelector(".kui-card").classList.remove("kui-hidden"); }, hold: 820 },
      { cap: "文本直接读，底部是复制 / 粘贴；标题栏还能进编辑。", hold: 1050 },
      { move: ".kui-row:nth-child(2)", ms: 560 },
      { run: function () {
          var pv = this.stage.querySelector(".kui-pvx");
          var acts = this.stage.querySelector(".kui-pvacts");
          if (pv) pv.innerHTML = '<div style="font-size:10.6px;color:#2F6BFF">kitnest.sxyq27.online</div><div style="font-size:10px;color:#8A8A94;margin-top:5px">官网 · 更新记录 · 用户手册</div>';
          if (acts) acts.innerHTML = '<span class="kui-btn" style="padding:3px 8px">复制链接</span><span class="kui-btn" style="padding:3px 8px">打开</span><span class="kui-btn" style="padding:3px 8px">解析下载</span>';
        }, hold: 900 },
      { cap: "换到链接，预览变成「复制链接 / 打开 / 解析下载」。", hold: 1000 },
      { move: ".kui-row:nth-child(3)", ms: 560 },
      { run: function () {
          var pv = this.stage.querySelector(".kui-pvx");
          var acts = this.stage.querySelector(".kui-pvacts");
          if (pv) pv.innerHTML = '<div style="height:96px;border-radius:7px;background:linear-gradient(135deg,#DDE7F7,#F0F4FB);border:1px solid #E4E8EF"></div>';
          if (acts) acts.innerHTML = '<span class="kui-btn" style="padding:3px 8px">复制图片</span><span class="kui-btn" style="padding:3px 8px">钉住</span>';
        }, hold: 900 },
      { cap: "图片条目显示大图 + 尺寸，可以直接钉在屏幕上。", hold: 1200 }
    ]
  },

  /* ------------------------------------------------ 标注编辑器 */
  annotate: {
    title: "标注：对象化箭头与马赛克",
    stage: 440,
    body: `
      <div style="position:relative;width:100%;max-width:470px">
        <div class="kui-screen" style="height:270px">
          <div style="position:absolute;left:26px;top:26px;width:200px;padding:14px;border-radius:9px;background:#fff;border:1px solid #E7EAF0;box-shadow:0 8px 20px rgba(11,11,13,.06)">
            <div style="font-size:10px;color:#8A8A94;margin-bottom:7px">转账详情</div>
            <div style="display:flex;justify-content:space-between;font-size:11px;margin:5px 0"><span>收款方</span><b>示例商户</b></div>
            <div style="display:flex;justify-content:space-between;font-size:11px;margin:5px 0"><span>金额</span><b class="kui-amount" style="color:#C0392B">¥ 1,280.00</b></div>
            <div style="display:flex;justify-content:space-between;font-size:10px;color:#8A8A94;margin-top:8px"><span>订单号</span><span>20261118094012</span></div>
          </div>
          <svg class="kui-arrow" width="120" height="80" style="position:absolute;left:236px;top:64px;opacity:0;transition:opacity .25s ease">
            <defs><marker id="ah" markerWidth="8" markerHeight="8" refX="6" refY="3" orient="auto"><path d="M0,0 L6,3 L0,6 z" fill="#2F6BFF"/></marker></defs>
            <path d="M6 66 C 40 12, 80 12, 112 34" fill="none" stroke="#2F6BFF" stroke-width="2.4" marker-end="url(#ah)"/>
          </svg>
          <div class="kui-annot-bar" style="position:absolute;left:14px;top:88px;display:flex;flex-direction:column;gap:4px;padding:6px;border-radius:10px;background:#fff;border:1px solid #E7EAF0;box-shadow:0 10px 24px rgba(11,11,13,.10);font-size:11px;opacity:0;transition:opacity .25s ease">
            <span style="padding:3px 5px;border-radius:5px">▭</span><span style="padding:3px 5px;border-radius:5px">◯</span><span style="padding:3px 5px;border-radius:5px;background:#EEF3FF;color:#1E52D6">▦</span><span style="padding:3px 5px;border-radius:5px">T</span><span style="padding:3px 5px;border-radius:5px">✎</span>
          </div>
        </div>
      </div>`,
    steps: [
      { cap: "标注是「对象」不是像素：画上去的箭头、马赛克都能随时撤销重调。", hold: 1250 },
      { move: ".kui-screen", ms: 520 },
      { run: function () { this.stage.querySelector(".kui-annot-bar").style.opacity = 1; this.stage.querySelector(".kui-annot-bar").style.transition = "opacity .25s ease"; }, hold: 600 },
      { move: ".kui-annot-bar span:nth-child(5)", ms: 460 },
      { click: ".kui-annot-bar span:nth-child(5)" },
      { run: function () { var a = this.stage.querySelector(".kui-arrow"); a.style.opacity = 1; }, hold: 700 },
      { cap: "选箭头工具，直接在截图上一拖就是一条带箭头的标注。", hold: 1000 },
      { move: ".kui-annot-bar span:nth-child(3)", ms: 520 },
      { click: ".kui-annot-bar span:nth-child(3)" },
      { run: function () {
          var amt = this.stage.querySelector(".kui-amount");
          if (amt) { amt.style.background = "repeating-conic-gradient(#B9BEC9 0% 25%, #E3E6EC 0% 50%) 0 0/8px 8px"; amt.style.color = "transparent"; amt.style.borderRadius = "3px"; }
        }, hold: 800 },
      { cap: "马赛克刷过金额那一列，敏感信息就盖住了；原件不动。", hold: 1200 },
      { run: function () {
          var amt = this.stage.querySelector(".kui-amount");
          if (amt) { amt.style.background = ""; amt.style.color = "#C0392B"; }
        }, hold: 500 },
      { cap: "⌘Z 一按就恢复——这就是「对象化」的好处。", hold: 1250 }
    ]
  },

  /* ------------------------------------------------ 美化与物体擦除 */
  beautify: {
    title: "美化：背景、圆角、投影",
    stage: 460,
    body: `
      <div class="kui-win" style="width:450px">
        <div class="kui-titlebar"><div class="kui-lights"><i></i><i></i><i></i></div><span class="kui-wtitle">美化截图</span></div>
        <div class="kui-wbody" style="display:flex;gap:14px">
          <div class="kui-beauty" style="flex:1;border-radius:10px;padding:16px;background:#F3F5F9;transition:background .4s ease">
            <div class="kui-shot-lg" style="border-radius:8px;background:linear-gradient(135deg,#DCE7F8,#EFF3FA);box-shadow:0 10px 26px rgba(11,11,13,.10);height:150px;border:1px solid #E2E7EF;transition:border-radius .3s ease, box-shadow .3s ease"></div>
          </div>
          <div style="width:150px">
            <div class="kui-sect-t">背景</div>
            <div style="display:flex;gap:5px;margin-bottom:10px">
              <span class="kui-chip kui-bg" data-bg="none">无</span><span class="kui-chip on kui-bg" data-bg="solid">纯色</span><span class="kui-chip kui-bg" data-bg="grad">渐变</span>
            </div>
            <div class="kui-sect-t">颜色</div>
            <div style="display:flex;gap:5px;margin-bottom:10px">
              <span class="kui-swatch" style="width:16px;height:16px;border-radius:5px;background:#F3F5F9;border:1px solid #DDE1E8"></span>
              <span class="kui-swatch" style="width:16px;height:16px;border-radius:5px;background:#2F6BFF"></span>
              <span class="kui-swatch" style="width:16px;height:16px;border-radius:5px;background:#1F9D63"></span>
              <span class="kui-swatch" style="width:16px;height:16px;border-radius:5px;background:#111"></span>
            </div>
            <div class="kui-sect-t">圆角</div>
            <div class="kui-field" style="border:0;padding:2px 0"><div class="kui-slider"><i style="width:20%"></i><b style="left:20%"></b></div></div>
            <div class="kui-sect-t" style="margin-top:8px">投影</div>
            <div class="kui-field" style="border:0;padding:2px 0"><div class="kui-slider"><i style="width:45%"></i><b style="left:45%"></b></div></div>
            <div style="display:flex;gap:6px;margin-top:12px">
              <span class="kui-btn" style="flex:1;justify-content:center">复制</span><span class="kui-btn primary" style="flex:1;justify-content:center">保存</span>
            </div>
          </div>
        </div>
      </div>`,
    steps: [
      { cap: "美化给截图换背景、调圆角投影，发出去更体面。", hold: 1150 },
      { move: '.kui-bg[data-bg="grad"]', ms: 560 },
      { click: '.kui-bg[data-bg="grad"]' },
      { run: function () {
          var b = this.stage.querySelector(".kui-beauty");
          if (b) b.style.background = "linear-gradient(135deg,#DCE8FB,#F6EEFF 55%,#E8F5EE)";
          this.stage.querySelectorAll(".kui-bg").forEach(function (c) { c.classList.remove("on"); });
          this.stage.querySelector('.kui-bg[data-bg="grad"]').classList.add("on");
        }, hold: 800 },
      { cap: "背景三档：无 / 纯色 / 渐变；点一下就换。", hold: 1000 },
      { move: ".kui-swatch:nth-child(2)", ms: 520 },
      { click: ".kui-swatch:nth-child(2)" },
      { run: function () { this.stage.querySelector(".kui-beauty").style.background = "linear-gradient(135deg,#E7EEFF,#F4F8FF 60%,#E9F1FF)"; }, hold: 760 },
      { move: ".kui-field:nth-of-type(1) .kui-slider", ms: 520 },
      { run: function () {
          var s = this.stage.querySelectorAll(".kui-slider");
          if (s[0]) { s[0].querySelector("i").style.width = "62%"; s[0].querySelector("b").style.left = "62%"; }
          var im = this.stage.querySelector(".kui-shot-lg");
          if (im) im.style.borderRadius = "16px";
        }, hold: 900 },
      { cap: "拖圆角滑杆，截图的圆角实时变；投影同理。", hold: 1050 },
      { move: ".kui-btn.primary", ms: 520 },
      { click: ".kui-btn.primary" },
      { run: function () { var t = document.createElement("div"); t.className = "kui-toast"; t.textContent = "已保存到下载目录"; this.stage.appendChild(t); setTimeout(function () { t.remove(); }, 1400); }, hold: 1450 },
      { cap: "右下角复制 / 保存 / 钉住，处理完直接拿走。", hold: 1150 }
    ]
  },

  /* ------------------------------------------------ 长截图 */
  longshot: {
    title: "长截图：滚动合成，接缝无重影",
    stage: 440,
    body: `
      <div class="kui-win" style="width:250px">
        <div class="kui-titlebar"><div class="kui-lights"><i></i><i></i><i></i></div><span class="kui-wtitle">长截图预览</span></div>
        <div class="kui-lscroll" style="height:290px;overflow:auto;scrollbar-width:thin">
          <div style="padding:12px 14px;font-size:10.4px;line-height:1.7;color:#44444C">
            <div style="font-weight:650;font-size:12px;margin-bottom:8px">Kitnest 用户手册</div>
            <div style="height:64px;border-radius:6px;background:linear-gradient(135deg,#E4EDFB,#F4F7FC);margin-bottom:10px"></div>
            <p style="margin:0 0 8px">第一章 · 菜单栏与图标。Kitnest 常驻菜单栏，点图标展开主面板……</p>
            <p style="margin:0 0 8px">第二章 · 主面板与首页。四个页签分别是主页、监测、中转、投屏……</p>
            <p style="margin:0 0 8px">第三章 · 剪贴板历史。复制过的文本、图片、文件、链接都会记录……</p>
            <p style="margin:0 0 8px">第四章 · 截图主流程。⌥S 起手，拖出选区后出现动作条……</p>
            <p style="margin:0 0 8px">第五章 · 标注编辑器。箭头、矩形、马赛克都是对象……</p>
            <p style="margin:0 0 8px">第六章 · 长截图。滚动合成一张完整长图，接缝处没有重影……</p>
            <p style="margin:0 0 8px">第七章 · 录屏。整屏或选区录制，可选画中画与按键显示……</p>
            <p style="margin:0 0 8px">第八章 · 系统监测。CPU、内存、磁盘、网络、温度一屏看完……</p>
          </div>
        </div>
        <div class="kui-dock"><span>保存</span><span>复制</span><span class="kui-spacer"></span><span>关闭</span></div>
      </div>`,
    steps: [
      { cap: "长截图把滚动内容合成一张长图，适合文档、聊天记录、网页。", hold: 1200 },
      { move: ".kui-lscroll", ms: 500 },
      { scroll: ".kui-lscroll", dy: 220, ms: 900 },
      { cap: "上下滚动预览：内容连续、接缝处没有重影。", hold: 950 },
      { scroll: ".kui-lscroll", dy: 220, ms: 900 },
      { cap: "滚到底就是完整长图；保存 / 复制 / 关闭在底部。", hold: 1000 },
      { move: ".kui-dock span:nth-child(1)", ms: 480 },
      { click: ".kui-dock span:nth-child(1)" },
      { run: function () { var t = document.createElement("div"); t.className = "kui-toast"; t.textContent = "长图已保存"; this.stage.appendChild(t); setTimeout(function () { t.remove(); }, 1400); }, hold: 1500 },
      { cap: "合成在本地完成，不上传；超长内容会自动分段提示。", hold: 1150 }
    ]
  },

  /* ------------------------------------------------ 钉图 */
  pin: {
    title: "钉图：四种形态与不透明度",
    stage: 440,
    body: `
      <div class="kui-win" style="width:440px">
        <div class="kui-titlebar"><div class="kui-lights"><i></i><i></i><i></i></div><span class="kui-wtitle">设置 · 钉图</span></div>
        <div class="kui-wbody">
          <div class="kui-sect-t">形态预览</div>
          <div style="display:grid;grid-template-columns:repeat(4,1fr);gap:8px;margin-bottom:12px">
            <div class="kui-pin on" style="height:66px;border-radius:8px;background:linear-gradient(135deg,#E1EAF9,#F3F6FC);border:2px solid #2F6BFF;position:relative"></div>
            <div class="kui-pin" style="height:66px;border-radius:8px;background:linear-gradient(135deg,#E1EAF9,#F3F6FC);border:1px solid #E3E6EC;box-shadow:0 4px 10px rgba(11,11,13,.08)"></div>
            <div class="kui-pin" style="height:66px;border-radius:4px;background:linear-gradient(135deg,#E1EAF9,#F3F6FC);border:3px solid #fff;box-shadow:0 4px 10px rgba(11,11,13,.10)"></div>
            <div class="kui-pin" style="height:66px;border-radius:0;background:linear-gradient(135deg,#E1EAF9,#F3F6FC)"></div>
          </div>
          <div style="display:flex;gap:5px;margin-bottom:12px">
            <span class="kui-chip on">描边</span><span class="kui-chip">卡片</span><span class="kui-chip">白边</span><span class="kui-chip">无边框</span>
          </div>
          <div class="kui-field"><span class="kui-fl">默认不透明度</span><div class="kui-slider"><i style="width:100%"></i><b style="left:100%"></b></div><span class="kui-fv">100%</span></div>
          <div class="kui-field"><span class="kui-fl">置顶显示</span><span class="kui-spacer"></span><span class="kui-sw on"></span></div>
          <div class="kui-field"><span class="kui-fl">快捷键</span><span class="kui-fv"><span class="kui-kbd">⌥P</span> 钉住选区</span></div>
        </div>
      </div>`,
    steps: [
      { cap: "钉图把截图钉在桌面最上层当参考，窗口本身不出现在录屏里。", hold: 1250 },
      { move: ".kui-pin:nth-child(2)", ms: 560 },
      { click: ".kui-pin:nth-child(2)" },
      { run: function () {
          this.stage.querySelectorAll(".kui-pin").forEach(function (p) { p.style.border = "1px solid #E3E6EC"; p.style.boxShadow = "none"; });
          var p = this.stage.querySelector(".kui-pin:nth-child(2)");
          if (p) { p.style.border = "2px solid #2F6BFF"; }
          this.stage.querySelectorAll(".kui-chip").forEach(function (c) { c.classList.remove("on"); });
          this.stage.querySelectorAll(".kui-chip")[1].classList.add("on");
        }, hold: 820 },
      { cap: "四种形态：描边 / 卡片 / 白边 / 无边框，点缩略图就换。", hold: 1100 },
      { move: ".kui-slider", ms: 520 },
      { run: function () {
          var s = this.stage.querySelector(".kui-slider");
          if (s) { s.querySelector("i").style.width = "72%"; s.querySelector("b").style.left = "72%"; }
          var fv = this.stage.querySelector(".kui-fv");
          if (fv) fv.textContent = "72%";
        }, hold: 760 },
      { cap: "不透明度调到 72%，钉住的图半透明，不挡下面的内容。", hold: 1150 },
      { move: ".kui-field:last-child .kui-kbd", ms: 500 },
      { cap: "默认 ⌥P 把选区直接钉住；快捷键可在设置里改。", hold: 1250 }
    ]
  },

  /* ------------------------------------------------ 图帘 */
  curtain: {
    title: "图帘：截图先挂在顶边",
    stage: 400,
    body: `
      <div style="width:100%;max-width:470px">
        <div class="kui-menubar" style="margin-bottom:0">
          <span class="kui-glyph"></span><span class="kui-mi">Kitnest</span><span class="kui-spacer"></span><span class="kui-mi">9:41</span>
        </div>
        <div style="background:linear-gradient(160deg,#EAF0FA 0%,#F6F8FC 55%,#EEF2F8 100%);height:250px;border-radius:0 0 10px 10px;position:relative;border:1px solid #E7EAF0;border-top:0">
          <div class="kui-ladder" style="position:absolute;left:50%;top:8px;transform:translateX(-50%);padding:7px 10px;box-shadow:0 8px 20px rgba(11,11,13,.08)">
            <div class="kui-shot"></div><div class="kui-shot"></div><div class="kui-shot"></div>
          </div>
          <div style="position:absolute;left:24px;bottom:26px;width:150px;height:88px;border-radius:9px;background:#fff;border:1px solid #E7EAF0;box-shadow:0 10px 24px rgba(11,11,13,.08);padding:10px;font-size:10px;color:#8A8A94">桌面文件</div>
          <div style="position:absolute;right:24px;bottom:26px;width:150px;height:88px;border-radius:9px;background:#fff;border:1px solid #E7EAF0;box-shadow:0 10px 24px rgba(11,11,13,.08);padding:10px;font-size:10px;color:#8A8A94">项目目录</div>
        </div>
      </div>`,
    steps: [
      { cap: "截图后不落地：先挂在屏幕顶边那条「图帘」上，需要时再拖走。", hold: 1300 },
      { move: ".kui-shot:nth-child(1)", ms: 620 },
      { cap: "光标移上去，缩略图浮起；点一下可以打开、拖走或删除。", hold: 1150 },
      { move: ".kui-shot:nth-child(2)", ms: 560 },
      { cap: "连拍几张都挂在帘子上，不打断当前工作流。", hold: 1000 },
      { move: ".kui-shot:nth-child(3)", ms: 560 },
      { click: ".kui-shot:nth-child(3)" },
      { run: function () { var t = document.createElement("div"); t.className = "kui-toast"; t.textContent = "已拖入当前文稿"; this.stage.appendChild(t); setTimeout(function () { t.remove(); }, 1400); }, hold: 1500 },
      { cap: "鼠标离开一段时间，帘子自动收起；桌面恢复干净。", hold: 1250 }
    ]
  },

  /* ------------------------------------------------ 截图历史 */
  history: {
    title: "截图历史：网格与搜索",
    stage: 450,
    body: `
      <div class="kui-win" style="width:440px">
        <div class="kui-titlebar"><div class="kui-lights"><i></i><i></i><i></i></div><span class="kui-wtitle">截图历史</span></div>
        <div class="kui-wbody" style="padding:10px 12px">
          <div class="kui-search" style="margin:0 0 10px"><span>⌕</span><span class="kui-q" style="color:#8A8A94">搜索截图（日期、尺寸、OCR 文本）</span></div>
          <div class="kui-hgrid" style="display:grid;grid-template-columns:repeat(3,1fr);gap:8px">
            <div class="kui-cell"><span>11-18 09:40</span></div>
            <div class="kui-cell"><span>11-18 09:12</span></div>
            <div class="kui-cell"><span>11-17 18:22</span></div>
            <div class="kui-cell"><span>11-17 16:05</span></div>
            <div class="kui-cell"><span>11-17 10:18</span></div>
            <div class="kui-cell"><span>11-16 21:30</span></div>
          </div>
        </div>
        <div class="kui-dock"><span>全部</span><span>今天</span><span>本周</span><span class="kui-spacer"></span><span>6 张</span></div>
      </div>`,
    steps: [
      { cap: "截图历史按时间倒序排，缩略图网格一眼看到最近的截图。", hold: 1200 },
      { move: ".kui-search", ms: 520 },
      { click: ".kui-search" },
      { type: ".kui-q", text: "2026-11" },
      { run: function () {
          var cells = this.stage.querySelectorAll(".kui-cell");
          Array.prototype.forEach.call(cells, function (c, i) { c.style.display = i < 4 ? "" : "none"; });
          var n = this.stage.querySelector(".kui-dock span:last-child");
          if (n) n.textContent = "4 张";
        }, hold: 800 },
      { cap: "搜索框支持日期、尺寸和 OCR 文本；敲「2026-11」就从 6 张过滤到 4 张。", hold: 1350 },
      { move: ".kui-cell:nth-child(1)", ms: 520 },
      { click: ".kui-cell:nth-child(1)" },
      { cap: "点缩略图看原图，右键能复制、标注、钉住或删除。", hold: 1250 }
    ]
  },

  /* ------------------------------------------------ OCR */
  ocr: {
    title: "文字识别：左图右文，可翻译",
    stage: 450,
    body: `
      <div class="kui-win" style="width:470px">
        <div class="kui-titlebar"><div class="kui-lights"><i></i><i></i><i></i></div><span class="kui-wtitle">识别结果</span></div>
        <div class="kui-wbody" style="display:flex;gap:12px;padding:12px">
          <div style="flex:1">
            <div style="height:190px;border-radius:8px;border:1px solid #E7EAF0;background:linear-gradient(135deg,#E9EFF9,#F6F8FC);position:relative;overflow:hidden">
              <div style="position:absolute;left:14px;top:16px;font-size:10px;line-height:1.7;color:#5A6473">
                出行提示<br>11 月 18 日 09:40<br>登机口 B12<br>请提前 30 分钟到达
              </div>
            </div>
            <div style="display:flex;gap:5px;margin-top:8px">
              <span class="kui-chip on">中文</span><span class="kui-chip">英文</span><span class="kui-chip">翻译</span>
            </div>
          </div>
          <div style="flex:1;display:flex;flex-direction:column">
            <div class="kui-ocrtext" style="flex:1;font-size:10.8px;line-height:1.8;color:#33333B;border:1px solid #F0F0F3;border-radius:8px;padding:9px">
              出行提示<br>11 月 18 日 09:40<br>登机口 B12<br>请提前 30 分钟到达
            </div>
            <div style="display:flex;gap:6px;margin-top:8px">
              <span class="kui-btn" style="flex:1;justify-content:center">复制</span><span class="kui-btn" style="flex:1;justify-content:center">翻译</span>
            </div>
          </div>
        </div>
      </div>`,
    steps: [
      { cap: "识别（OCR）把截图里的字提出来：左边原图，右边可选中文本。", hold: 1250 },
      { move: ".kui-chip:nth-child(2)", ms: 560 },
      { click: ".kui-chip:nth-child(2)" },
      { run: function () {
          this.stage.querySelectorAll(".kui-chip").forEach(function (c) { c.classList.remove("on"); });
          this.stage.querySelectorAll(".kui-chip")[1].classList.add("on");
          var t = this.stage.querySelector(".kui-ocrtext");
          if (t) t.innerHTML = "Travel notice<br>Nov 18, 09:40<br>Gate B12<br>Please arrive 30 min early";
        }, hold: 820 },
      { cap: "切「英文」按英文模型重新识别，代码、票据都更准。", hold: 1050 },
      { move: ".kui-chip:nth-child(3)", ms: 520 },
      { click: ".kui-chip:nth-child(3)" },
      { run: function () {
          this.stage.querySelectorAll(".kui-chip").forEach(function (c) { c.classList.remove("on"); });
          this.stage.querySelectorAll(".kui-chip")[2].classList.add("on");
          var t = this.stage.querySelector(".kui-ocrtext");
          if (t) t.innerHTML = "出行提示<br>11 月 18 日 09:40<br>登机口 B12<br>请提前 30 分钟到达<br><span style='color:#8A8A94'>—— 译文 ——</span><br>Travel notice … Gate B12 …";
        }, hold: 860 },
      { cap: "「翻译」在识别结果上直接出译文，不用复制到别处。", hold: 1150 },
      { move: ".kui-btn:nth-of-type(1)", ms: 500 },
      { click: ".kui-btn" },
      { run: function () { var t = document.createElement("div"); t.className = "kui-toast"; t.textContent = "已复制识别结果"; this.stage.appendChild(t); setTimeout(function () { t.remove(); }, 1400); }, hold: 1500 },
      { cap: "复制走系统剪贴板，历史里也能找回；二维码同样能识别。", hold: 1250 }
    ]
  },

  /* ------------------------------------------------ 截图增强设置 */
  captureplus: {
    title: "截图设置：比例、命名、静默识别",
    stage: 440,
    body: `
      <div class="kui-win" style="width:450px">
        <div class="kui-titlebar"><div class="kui-lights"><i></i><i></i><i></i></div><span class="kui-wtitle">设置 · 截图</span></div>
        <div class="kui-wbody">
          <div class="kui-field"><span class="kui-fl">固定比例</span><span class="kui-fv">
            <span class="kui-chip on">自由</span> <span class="kui-chip">16:9</span> <span class="kui-chip">4:3</span> <span class="kui-chip">1:1</span>
          </span></div>
          <div class="kui-field"><span class="kui-fl">文件名模板</span><span class="kui-fv"><code style="font-size:10.4px">Screenshot-{date}-{time}</code></span></div>
          <div class="kui-field"><span class="kui-fl">静默识别</span><span class="kui-fv">截图后自动 OCR</span><span class="kui-sw on"></span></div>
          <div class="kui-field"><span class="kui-fl">仅文本马赛克</span><span class="kui-fv">只盖文字，保留背景</span><span class="kui-sw"></span></div>
          <div class="kui-field"><span class="kui-fl">窗口多选</span><span class="kui-fv">框选时可加选多个窗口</span><span class="kui-sw on"></span></div>
          <div class="kui-sect-t" style="margin-top:10px">模板占位符</div>
          <div style="display:flex;gap:5px;flex-wrap:wrap">
            <span class="kui-kbd">{date}</span><span class="kui-kbd">{time}</span><span class="kui-kbd">{app}</span><span class="kui-kbd">{mode}</span><span class="kui-kbd">{w}×{h}</span><span class="kui-kbd">{ocr}</span>
          </div>
        </div>
      </div>`,
    steps: [
      { cap: "截图设置管「怎么截、存成什么名、截完自动做什么」。", hold: 1200 },
      { move: ".kui-chip:nth-child(2)", ms: 540 },
      { click: ".kui-chip:nth-child(2)" },
      { run: function () {
          this.stage.querySelectorAll(".kui-chip").forEach(function (c) { c.classList.remove("on"); });
          this.stage.querySelectorAll(".kui-chip")[1].classList.add("on");
        }, hold: 760 },
      { cap: "固定比例 16:9 后，拖选区时宽高锁定，做封面图很方便。", hold: 1100 },
      { move: ".kui-field:nth-child(2) code", ms: 520 },
      { cap: "文件名模板支持 16 个占位符：日期、时间、来源 App、尺寸、OCR 摘要……", hold: 1300 },
      { move: ".kui-field:nth-child(3) .kui-sw", ms: 520 },
      { click: ".kui-field:nth-child(3) .kui-sw" },
      { run: function () { this.stage.querySelector(".kui-field:nth-child(3) .kui-sw").classList.remove("on"); }, hold: 760 },
      { cap: "「静默识别」关掉后只截图不 OCR，省电、也不打断流程。", hold: 1200 },
      { move: ".kui-field:nth-child(5) .kui-sw", ms: 500 },
      { cap: "「窗口多选」开启后，框选时可以按住加选多个窗口一起截。", hold: 1250 }
    ]
  },

  /* ------------------------------------------------ 录屏 */
  recording: {
    title: "录屏：控制条、画中画、剪辑",
    stage: 470,
    body: `
      <div style="width:100%;max-width:470px">
        <div style="height:230px;border-radius:10px;background:linear-gradient(135deg,#E8EEF9,#F6F8FC);border:1px solid #E3E6EC;position:relative;overflow:hidden">
          <div style="position:absolute;left:26px;top:24px;width:170px;height:100px;border-radius:8px;background:#fff;border:1px solid #E7EAF0;box-shadow:0 8px 20px rgba(11,11,13,.06);padding:10px;font-size:10px;color:#5A6473">演示窗口</div>
          <div class="kui-cam" style="position:absolute;right:18px;bottom:16px;width:78px;height:102px;border-radius:8px;background:linear-gradient(145deg,#C9D6EA,#E7EDF7);border:1px solid #DDE3ED;opacity:0;transition:opacity .3s ease"></div>
          <div class="kui-recbar" style="position:absolute;left:50%;top:12px;transform:translateX(-50%);display:flex;align-items:center;gap:10px;padding:7px 12px;border-radius:20px;background:rgba(24,24,28,.86);color:#fff;font-size:11px;backdrop-filter:blur(10px);opacity:0;transition:opacity .3s ease">
            <span class="kui-reddot" style="width:8px;height:8px;border-radius:50%;background:#FF5F57;display:inline-block"></span>
            <span class="kui-timer">00:12</span><span style="opacity:.6">|</span><span>⏸</span><span>⏹</span>
          </div>
        </div>
        <div class="kui-panel" style="width:100%;margin-top:10px">
          <div class="kui-sect" style="padding:10px 12px">
            <div class="kui-field"><span class="kui-fl">录制源</span><span class="kui-fv">
              <span class="kui-chip on">整屏</span> <span class="kui-chip">区域</span> <span class="kui-chip">窗口</span>
            </span></div>
            <div class="kui-field"><span class="kui-fl">帧率</span><span class="kui-fv">
              <span class="kui-chip">15</span> <span class="kui-chip on">30</span> <span class="kui-chip">60</span>
            </span></div>
            <div class="kui-field"><span class="kui-fl">摄像头画中画</span><span class="kui-fv">右下 · 20%</span><span class="kui-sw on"></span></div>
            <div class="kui-field"><span class="kui-fl">按键与点击</span><span class="kui-fv">显示键帽条与点击动画</span><span class="kui-sw on"></span></div>
          </div>
        </div>
      </div>`,
    steps: [
      { cap: "录屏支持整屏 / 区域 / 窗口，帧率、声音、画中画都能选。", hold: 1200 },
      { move: ".kui-chip:nth-child(2)", ms: 520 },
      { click: ".kui-chip:nth-child(2)" },
      { run: function () {
          var chips = this.stage.querySelectorAll(".kui-field:first-child .kui-chip");
          chips.forEach(function (c) { c.classList.remove("on"); });
          if (chips[1]) chips[1].classList.add("on");
        }, hold: 780 },
      { cap: "选「区域」后拖框录制，只录你要展示的那一块。", hold: 1000 },
      { move: ".kui-reddot", ms: 480 },
      { click: ".kui-reddot" },
      { run: function () {
          this.stage.querySelector(".kui-recbar").style.opacity = 1;
          this.stage.querySelector(".kui-cam").style.opacity = 1;
          var t = this.stage.querySelector(".kui-timer");
          var n = 12;
          var self = this;
          this._timer = setInterval(function () { n++; if (t) t.textContent = "00:" + String(n).padStart(2, "0"); }, 380);
          setTimeout(function () { clearInterval(self._timer); }, 3000);
        }, hold: 1300 },
      { cap: "开始后顶部一条控制条：红点、计时、暂停、停止；控制条不会被录进画面。", hold: 1400 },
      { move: ".kui-recbar span:nth-child(4)", ms: 460 },
      { click: ".kui-recbar span:nth-child(4)" },
      { run: function () { clearInterval(this._timer); this.stage.querySelector(".kui-recbar").style.opacity = 0; }, hold: 900 },
      { cap: "停止后自动弹出剪辑窗：拖滑块选取保留区间，可静音导出。", hold: 1200 },
      { move: ".kui-field:last-child .kui-sw", ms: 500 },
      { cap: "「按键与点击」开启时，键盘按键和鼠标点击会以动画出现在画面里。", hold: 1300 }
    ]
  },

  /* ------------------------------------------------ 内存维护 */
  memory: {
    title: "内存维护：环形图与深度释放",
    stage: 450,
    body: `
      <div class="kui-panel" style="width:380px">
        <div class="kui-panelbar"><span class="kui-seg on">内存</span><span class="kui-spacer"></span><span class="kui-ico">↻</span></div>
        <div class="kui-wbody" style="display:flex;gap:16px;align-items:center">
          <div class="kui-ring" style="width:110px;height:110px">
            <svg width="110" height="110" viewBox="0 0 110 110">
              <circle cx="55" cy="55" r="46" fill="none" stroke="#EEF0F4" stroke-width="10"></circle>
              <circle class="kui-memring" cx="55" cy="55" r="46" fill="none" stroke="#2F6BFF" stroke-width="10"
                      stroke-linecap="round" stroke-dasharray="289" stroke-dashoffset="120" style="transition:stroke-dashoffset .9s ease"></circle>
            </svg>
            <div class="kui-ring-c"><b class="kui-mempct">9.2</b><i>GB 已用</i></div>
          </div>
          <div style="flex:1;font-size:11px;line-height:1.9;color:#4A4A52">
            <div style="display:flex;justify-content:space-between"><span>已用</span><b>9.2 GB</b></div>
            <div style="display:flex;justify-content:space-between"><span>缓存可释放</span><b style="color:#1F9D63">1.8 GB</b></div>
            <div style="display:flex;justify-content:space-between"><span>交换区</span><b>0 MB</b></div>
          </div>
        </div>
        <div class="kui-sect" style="padding:4px 14px 12px">
          <div class="kui-release" style="display:none">
            <div style="font-size:10.6px;color:#8A8A94;margin-bottom:6px">释放明细</div>
            <div style="display:flex;justify-content:space-between;font-size:10.8px;padding:3px 0"><span>文件缓存</span><span>820 MB</span></div>
            <div style="display:flex;justify-content:space-between;font-size:10.8px;padding:3px 0"><span>压缩内存</span><span>560 MB</span></div>
            <div style="display:flex;justify-content:space-between;font-size:10.8px;padding:3px 0"><span>闲置应用</span><span>420 MB</span></div>
          </div>
          <div style="display:flex;gap:7px;margin-top:10px">
            <span class="kui-btn" style="flex:1;justify-content:center">刷新</span>
            <span class="kui-btn primary kui-deep" style="flex:1;justify-content:center">深度释放</span>
          </div>
        </div>
      </div>`,
    steps: [
      { cap: "内存页一眼看清：已用多少、缓存能放多少、交换区有没有压力。", hold: 1250 },
      { move: ".kui-memring", ms: 600 },
      { cap: "环形图会随采样更新；数字是实时的，不是估算。", hold: 1000 },
      { move: ".kui-deep", ms: 520 },
      { click: ".kui-deep" },
      { run: function () {
          var r = this.stage.querySelector(".kui-memring");
          if (r) r.setAttribute("stroke-dashoffset", "196");
          var p = this.stage.querySelector(".kui-mempct");
          if (p) p.textContent = "6.4";
          var rel = this.stage.querySelector(".kui-release");
          if (rel) rel.style.display = "block";
        }, hold: 900 },
      { cap: "「深度释放」清掉可回收缓存，报告会写清每一项释放了多少。", hold: 1300 },
      { move: ".kui-release", ms: 520 },
      { cap: "释放只动缓存，不杀你正在用的应用；闲置应用可单独选择。", hold: 1300 }
    ]
  },

  /* ------------------------------------------------ 存储管理 */
  storage: {
    title: "存储管理：气泡堆块与清单",
    stage: 460,
    body: `
      <div class="kui-win" style="width:460px">
        <div class="kui-titlebar"><div class="kui-lights"><i></i><i></i><i></i></div><span class="kui-wtitle">存储管理</span></div>
        <div class="kui-wbody" style="display:flex;gap:12px;padding:12px">
          <div style="flex:1.1;display:grid;grid-template-columns:repeat(3,1fr);grid-template-rows:repeat(2,1fr);gap:6px;height:190px">
            <div class="kui-bubble" style="grid-column:span 2;grid-row:span 1;font-size:11px">可用 412 GB<br><span style="font-size:9px;opacity:.7">35% 面积</span></div>
            <div class="kui-bubble on" style="font-size:10px">缓存<br>18.2 G</div>
            <div class="kui-bubble" style="font-size:10px">下载<br>9.6 G</div>
            <div class="kui-bubble" style="font-size:10px">归档<br>6.1 G</div>
            <div class="kui-bubble" style="font-size:10px">其他<br>3.4 G</div>
          </div>
          <div style="flex:1;font-size:10.8px">
            <div style="display:flex;justify-content:space-between;color:#8A8A94;font-size:10px;margin-bottom:6px"><span>候选清单</span><span class="kui-selinfo">已选 0 项</span></div>
            <div class="kui-row" style="padding:5px 6px"><span class="kui-cb" style="width:12px;height:12px;border-radius:4px;border:1px solid #D5D8E0;display:inline-block"></span><div class="kui-meta"><div class="kui-t1" style="font-size:10.8px">~/Library/Caches</div><div class="kui-t2" style="font-size:9.6px">18.2 GB</div></div></div>
            <div class="kui-row" style="padding:5px 6px"><span class="kui-cb" style="width:12px;height:12px;border-radius:4px;border:1px solid #D5D8E0;display:inline-block"></span><div class="kui-meta"><div class="kui-t1" style="font-size:10.8px">~/Downloads/旧素材</div><div class="kui-t2" style="font-size:9.6px">9.6 GB</div></div></div>
            <div class="kui-row" style="padding:5px 6px"><span class="kui-cb" style="width:12px;height:12px;border-radius:4px;border:1px solid #D5D8E0;display:inline-block"></span><div class="kui-meta"><div class="kui-t1" style="font-size:10.8px">Xcode DerivedData</div><div class="kui-t2" style="font-size:9.6px">6.1 GB</div></div></div>
            <div style="margin-top:8px;padding-top:7px;border-top:1px solid #F0F0F3;display:flex;justify-content:space-between;font-size:10.6px"><span>合计</span><b class="kui-total">0 GB</b></div>
          </div>
        </div>
      </div>`,
    steps: [
      { cap: "存储管理把磁盘按体积画成气泡，谁占地方一眼看出来。", hold: 1250 },
      { move: ".kui-bubble:nth-child(2)", ms: 560 },
      { cap: "悬停气泡会浮起，右上角写着这一块的体积。", hold: 1000 },
      { move: ".kui-row:nth-child(2) .kui-cb", ms: 500 },
      { click: ".kui-row:nth-child(2) .kui-cb" },
      { run: function () {
          var cb = this.stage.querySelector(".kui-row:nth-child(2) .kui-cb");
          if (cb) { cb.style.background = "#2F6BFF"; cb.style.borderColor = "#2F6BFF"; }
          var info = this.stage.querySelector(".kui-selinfo");
          if (info) info.textContent = "已选 1 项";
          var total = this.stage.querySelector(".kui-total");
          if (total) total.textContent = "18.2 GB";
        }, hold: 800 },
      { cap: "候选清单逐项勾选，底部「已选 / 合计」实时累加。", hold: 1050 },
      { move: ".kui-row:nth-child(3) .kui-cb", ms: 480 },
      { click: ".kui-row:nth-child(3) .kui-cb" },
      { run: function () {
          var cb = this.stage.querySelector(".kui-row:nth-child(3) .kui-cb");
          if (cb) { cb.style.background = "#2F6BFF"; cb.style.borderColor = "#2F6BFF"; }
          var info = this.stage.querySelector(".kui-selinfo");
          if (info) info.textContent = "已选 2 项";
          var total = this.stage.querySelector(".kui-total");
          if (total) total.textContent = "27.8 GB";
        }, hold: 820 },
      { cap: "勾够了一键移到废纸篓；不会直接删除，随时可恢复。", hold: 1300 }
    ]
  },

  /* ------------------------------------------------ 网络诊断 */
  network: {
    title: "网络：实时曲线与进程排行",
    stage: 450,
    body: `
      <div class="kui-win" style="width:440px">
        <div class="kui-titlebar"><div class="kui-lights"><i></i><i></i><i></i></div><span class="kui-wtitle">网络</span></div>
        <div class="kui-wbody">
          <div style="display:flex;gap:14px;font-size:10.6px;color:#7A7A84;margin-bottom:6px">
            <span><i style="display:inline-block;width:7px;height:7px;border-radius:2px;background:#2F6BFF;margin-right:4px"></i>下载</span>
            <span><i style="display:inline-block;width:7px;height:7px;border-radius:2px;background:#1F9D63;margin-right:4px"></i>上传</span>
            <span class="kui-spacer"></span><span>连接数 24</span>
          </div>
          <svg class="kui-spark kui-netspark" viewBox="0 0 380 64" preserveAspectRatio="none" style="height:64px">
            <polyline fill="none" stroke="#2F6BFF" stroke-width="1.7" points="0,46 24,40 48,44 72,30 96,34 120,20 144,26 168,18 192,30 216,14 240,22 264,12 288,26 312,16 336,24 360,12 380,18"></polyline>
            <polyline fill="none" stroke="#1F9D63" stroke-width="1.4" opacity=".8" points="0,52 24,50 48,48 72,46 96,48 120,42 144,44 168,40 192,44 216,38 240,40 264,34 288,38 312,32 336,36 360,30 380,32"></polyline>
          </svg>
          <div class="kui-sect-t" style="margin-top:10px">按进程</div>
          <div class="kui-row" style="padding:5px 6px"><div class="kui-thumb" style="width:22px;height:22px;font-size:9px">S</div><div class="kui-meta"><div class="kui-t1" style="font-size:10.8px">Safari</div><div class="kui-t2" style="font-size:9.6px">下载 1.2 MB/s · 上传 80 KB/s</div></div><b style="font-size:10px;color:#2F6BFF">1.28 MB/s</b></div>
          <div class="kui-row" style="padding:5px 6px"><div class="kui-thumb" style="width:22px;height:22px;font-size:9px">K</div><div class="kui-meta"><div class="kui-t1" style="font-size:10.8px">Kitnest</div><div class="kui-t2" style="font-size:9.6px">下载 240 KB/s · 上传 12 KB/s</div></div><b style="font-size:10px;color:#2F6BFF">252 KB/s</b></div>
          <div class="kui-row" style="padding:5px 6px"><div class="kui-thumb" style="width:22px;height:22px;font-size:9px">M</div><div class="kui-meta"><div class="kui-t1" style="font-size:10.8px">Mail</div><div class="kui-t2" style="font-size:9.6px">下载 40 KB/s</div></div><b style="font-size:10px;color:#2F6BFF">40 KB/s</b></div>
        </div>
      </div>`,
    steps: [
      { cap: "网络模块：上下行实时曲线 + 连接数 + 按进程的流量排行。", hold: 1300 },
      { move: ".kui-netspark", ms: 600 },
      { cap: "曲线保留最近 30 秒，下载（蓝）与上传（绿）分开画。", hold: 1100 },
      { move: ".kui-row:nth-child(1)", ms: 520 },
      { cap: "进程排行按速率排序，找出「谁在偷偷下载」只用一眼。", hold: 1100 },
      { move: ".kui-row:nth-child(2)", ms: 500 },
      { cap: "Kitnest 自己的流量也在里面，透明可查。", hold: 1000 },
      { move: ".kui-spark", ms: 560 },
      { cap: "端口诊断与连通性测试在同页下方，排查网络问题时用。", hold: 1300 }
    ]
  },

  /* ------------------------------------------------ 文件中转 */
  transfer: {
    title: "文件中转：三种方式发文件",
    stage: 460,
    body: `
      <div class="kui-panel" style="width:390px">
        <div class="kui-panelbar">
          <span class="kui-seg">主页</span><span class="kui-seg">监测</span><span class="kui-seg on">中转</span><span class="kui-seg">投屏</span>
          <span class="kui-spacer"></span><span class="kui-ico">⚙</span>
        </div>
        <div class="kui-sect">
          <div style="display:flex;gap:6px;margin-bottom:10px">
            <span class="kui-chip on">发送</span><span class="kui-chip">接收</span><span class="kui-chip">云端</span>
          </div>
          <div style="display:grid;grid-template-columns:repeat(3,1fr);gap:7px">
            <div class="kui-card kui-exit" style="text-align:center;padding:9px 6px"><div style="font-size:16px">⇪</div><div style="font-size:10.4px;margin-top:3px">隔空投送</div><div style="font-size:8.8px;color:#8A8A94">Apple 设备</div></div>
            <div class="kui-card kui-exit" style="text-align:center;padding:9px 6px"><div style="font-size:16px">▦</div><div style="font-size:10.4px;margin-top:3px">扫码直传</div><div style="font-size:8.8px;color:#8A8A94">任意设备</div></div>
            <div class="kui-card kui-exit" style="text-align:center;padding:9px 6px"><div style="font-size:16px">⇄</div><div style="font-size:10.4px;margin-top:3px">ADB 互传</div><div style="font-size:8.8px;color:#8A8A94">安卓</div></div>
          </div>
          <div class="kui-sect-t" style="margin-top:10px">待发送</div>
          <div class="kui-row" style="padding:5px 6px"><div class="kui-thumb t-file" style="width:24px;height:24px">▤</div><div class="kui-meta"><div class="kui-t1" style="font-size:10.8px">素材包.zip</div><div class="kui-t2" style="font-size:9.6px">12.4 MB</div></div></div>
          <div class="kui-row" style="padding:5px 6px"><div class="kui-thumb t-img" style="width:24px;height:24px">▣</div><div class="kui-meta"><div class="kui-t1" style="font-size:10.8px">Screenshot 09:40</div><div class="kui-t2" style="font-size:9.6px">1.8 MB</div></div></div>
          <div class="kui-qr" style="display:none;margin-top:10px;padding:12px;border:1px dashed #D9DEE8;border-radius:10px;text-align:center">
            <div style="width:74px;height:74px;margin:0 auto;border-radius:6px;background:repeating-conic-gradient(#222 0% 25%, #fff 0% 50%) 0 0/10px 10px"></div>
            <div style="font-size:8.8px;color:#8A8A94;margin-top:5px">手机扫码即可收发</div>
          </div>
        </div>
        <div class="kui-dock"><span>+ 添加文件</span><span class="kui-spacer"></span><span>本地暂存 2 项</span></div>
      </div>`,
    steps: [
      { cap: "中转页把文件发给别的设备：苹果、安卓、任何手机都能收。", hold: 1250 },
      { move: ".kui-exit:nth-child(2)", ms: 560 },
      { click: ".kui-exit:nth-child(2)" },
      { run: function () { this.stage.querySelector(".kui-qr").style.display = "block"; }, hold: 820 },
      { cap: "「扫码直传」弹出二维码，手机扫一下就能上传或下载，对方零安装。", hold: 1350 },
      { move: ".kui-exit:nth-child(1)", ms: 520 },
      { cap: "「隔空投送」走苹果原生通道，给附近 Mac / iPhone。", hold: 1050 },
      { move: ".kui-exit:nth-child(3)", ms: 500 },
      { cap: "「ADB 互传」连着数据线给安卓，推文件、拉文件都行。", hold: 1100 },
      { move: ".kui-row:nth-child(1)", ms: 500 },
      { cap: "勾选待发送的文件，再点上面的出口；传输进度在底部。", hold: 1250 }
    ]
  },

  /* ------------------------------------------------ 手机投屏 */
  cast: {
    title: "投屏：安卓与 iPhone 分栏",
    stage: 450,
    body: `
      <div class="kui-panel" style="width:390px">
        <div class="kui-panelbar">
          <span class="kui-seg">主页</span><span class="kui-seg">监测</span><span class="kui-seg">中转</span><span class="kui-seg on">投屏</span>
          <span class="kui-spacer"></span><span class="kui-ico">⚙</span>
        </div>
        <div class="kui-split" style="padding:10px 12px;gap:10px">
          <div style="flex:1;border:1px solid #EDEDF1;border-radius:10px;padding:10px">
            <div style="font-size:11px;font-weight:620;margin-bottom:6px">安卓</div>
            <div style="height:86px;border-radius:8px;background:linear-gradient(135deg,#E8EEF9,#F5F8FC);display:flex;align-items:center;justify-content:center;font-size:10px;color:#7A7A84">未连接</div>
            <div style="display:flex;gap:5px;margin-top:7px">
              <span class="kui-btn" style="flex:1;justify-content:center;padding:3px 6px;font-size:10px">USB</span>
              <span class="kui-btn primary kui-conn" style="flex:1;justify-content:center;padding:3px 6px;font-size:10px">扫码连接</span>
            </div>
          </div>
          <div style="flex:1;border:1px solid #EDEDF1;border-radius:10px;padding:10px">
            <div style="font-size:11px;font-weight:620;margin-bottom:6px">iPhone</div>
            <div style="height:86px;border-radius:8px;background:linear-gradient(135deg,#F3EEFB,#F9F6FD);display:flex;align-items:center;justify-content:center;font-size:10px;color:#7A7A84">未连接</div>
            <div style="display:flex;gap:5px;margin-top:7px">
              <span class="kui-btn" style="flex:1;justify-content:center;padding:3px 6px;font-size:10px">同网发现</span>
            </div>
          </div>
        </div>
        <div class="kui-qr" style="display:none;margin:0 12px 10px;padding:12px;border:1px dashed #D9DEE8;border-radius:10px;text-align:center">
          <div style="width:72px;height:72px;margin:0 auto;border-radius:6px;background:repeating-conic-gradient(#222 0% 25%, #fff 0% 50%) 0 0/10px 10px"></div>
          <div style="font-size:8.8px;color:#8A8A94;margin-top:5px">手机扫码后开始镜像</div>
        </div>
        <div class="kui-dock"><span>继续连接上次设备</span><span class="kui-spacer"></span><span>应用库</span></div>
      </div>`,
    steps: [
      { cap: "投屏页分左右两栏：安卓与 iPhone 各走各的连接方式。", hold: 1250 },
      { move: ".kui-conn", ms: 560 },
      { click: ".kui-conn" },
      { run: function () { this.stage.querySelector(".kui-qr").style.display = "block"; }, hold: 820 },
      { cap: "安卓扫码直连，不需要装任何 App；连上后开始镜像。", hold: 1250 },
      { move: ".kui-dock span:nth-child(1)", ms: 520 },
      { click: ".kui-dock span:nth-child(1)" },
      { cap: "「继续连接上次设备」一键回到常用机，省掉重新扫码。", hold: 1250 },
      { move: ".kui-dock span:last-child", ms: 500 },
      { cap: "应用库可以按包名启动手机 App，调试时用。", hold: 1250 }
    ]
  },

  /* ------------------------------------------------ 归档压缩 */
  archive: {
    title: "归档：浏览、预览、解压",
    stage: 450,
    body: `
      <div class="kui-win" style="width:460px">
        <div class="kui-titlebar"><div class="kui-lights"><i></i><i></i><i></i></div><span class="kui-wtitle">素材包.zip · 共 2 项</span></div>
        <div class="kui-wbody" style="display:flex;gap:12px;padding:12px">
          <div style="flex:1;border-right:1px solid #F0F0F3;padding-right:10px">
            <div class="kui-row on" style="padding:5px 6px"><div class="kui-thumb t-file" style="width:24px;height:24px">▤</div><div class="kui-meta"><div class="kui-t1" style="font-size:10.8px">说明.md</div><div class="kui-t2" style="font-size:9.6px">2.1 KB</div></div></div>
            <div class="kui-row" style="padding:5px 6px"><div class="kui-thumb t-img" style="width:24px;height:24px">▣</div><div class="kui-meta"><div class="kui-t1" style="font-size:10.8px">cover.png</div><div class="kui-t2" style="font-size:9.6px">1.8 MB</div></div></div>
            <div style="display:flex;gap:6px;margin-top:10px">
              <span class="kui-btn" style="flex:1;justify-content:center;padding:3px 6px;font-size:10px">解压到…</span>
              <span class="kui-btn" style="padding:3px 7px;font-size:10px">⋯</span>
            </div>
          </div>
          <div style="flex:1.1">
            <div class="kui-preview" style="font-size:10.4px;line-height:1.7;color:#44444C;border:1px solid #F0F0F3;border-radius:8px;padding:9px;min-height:150px">
              # 素材包说明<br><br>1. cover.png 用作封面<br>2. 本文件为示例内容<br>3. 支持 40+ 种压缩格式
            </div>
          </div>
        </div>
      </div>`,
    steps: [
      { cap: "压缩包双击直接用 Kitnest 打开，不跳第三方工具。", hold: 1200 },
      { move: ".kui-row:nth-child(1)", ms: 520 },
      { click: ".kui-row:nth-child(1)" },
      { cap: "点条目右侧直接预览：文本、图片、HTML、代码都支持。", hold: 1100 },
      { move: ".kui-row:nth-child(2)", ms: 500 },
      { click: ".kui-row:nth-child(2)" },
      { run: function () {
          var p = this.stage.querySelector(".kui-preview");
          if (p) p.innerHTML = '<div style="height:130px;border-radius:7px;background:linear-gradient(135deg,#DDE7F7,#F0F4FB);border:1px solid #E2E7EF"></div><div style="font-size:9.6px;color:#8A8A94;margin-top:5px">cover.png · 1200 × 800</div>';
        }, hold: 900 },
      { cap: "图片直接看，不用先解压；大文件按需加载，不卡界面。", hold: 1100 },
      { move: ".kui-btn:nth-of-type(1)", ms: 500 },
      { click: ".kui-btn" },
      { cap: "「解压到…」选目录；也能压缩、编辑回写、加入任务队列。", hold: 1350 }
    ]
  },

  /* ------------------------------------------------ 工具箱 */
  toolbox: {
    title: "工具箱：输入 / 切命令模式",
    stage: 440,
    body: `
      <div class="kui-panel" style="width:390px">
        <div class="kui-search"><span>⌕</span><span class="kui-q">/</span><span class="kui-spacer"></span><span style="font-size:9.6px;color:#8A8A94">命令模式</span></div>
        <div class="kui-list" style="max-height:280px">
          <div class="kui-sect-t" style="padding:4px 8px 2px">命令</div>
          <div class="kui-row" style="padding:5px 7px"><div class="kui-thumb" style="width:22px;height:22px;font-size:10px;background:#EEF3FF;color:#2F6BFF">⌘</div><div class="kui-meta"><div class="kui-t1" style="font-size:10.8px">截图</div><div class="kui-t2" style="font-size:9.6px">区域截图 ⌥S</div></div></div>
          <div class="kui-row" style="padding:5px 7px"><div class="kui-thumb" style="width:22px;height:22px;font-size:10px;background:#EEF3FF;color:#2F6BFF">⌘</div><div class="kui-meta"><div class="kui-t1" style="font-size:10.8px">录屏</div><div class="kui-t2" style="font-size:9.6px">开始整屏录制</div></div></div>
          <div class="kui-row" style="padding:5px 7px"><div class="kui-thumb" style="width:22px;height:22px;font-size:10px;background:#EEF3FF;color:#2F6BFF">⌘</div><div class="kui-meta"><div class="kui-t1" style="font-size:10.8px">取色</div><div class="kui-t2" style="font-size:9.6px">屏幕取色器</div></div></div>
          <div class="kui-sect-t" style="padding:7px 8px 2px">应用</div>
          <div class="kui-row" style="padding:5px 7px"><div class="kui-thumb" style="width:22px;height:22px;font-size:10px">S</div><div class="kui-meta"><div class="kui-t1" style="font-size:10.8px">Safari</div><div class="kui-t2" style="font-size:9.6px">应用</div></div></div>
          <div class="kui-row" style="padding:5px 7px"><div class="kui-thumb" style="width:22px;height:22px;font-size:10px">X</div><div class="kui-meta"><div class="kui-t1" style="font-size:10.8px">Xcode</div><div class="kui-t2" style="font-size:9.6px">应用</div></div></div>
          <div class="kui-sect-t" style="padding:7px 8px 2px">文件</div>
          <div class="kui-row" style="padding:5px 7px"><div class="kui-thumb t-file" style="width:22px;height:22px;font-size:10px">▤</div><div class="kui-meta"><div class="kui-t1" style="font-size:10.8px">素材包.zip</div><div class="kui-t2" style="font-size:9.6px">Downloads</div></div></div>
        </div>
      </div>`,
    steps: [
      { cap: "输入 / 进入命令模式：工具按「命令 / 应用 / 文件 / 剪贴板」分组列出。", hold: 1350 },
      { move: ".kui-row:nth-child(2)", ms: 540 },
      { click: ".kui-row:nth-child(2)" },
      { run: function () { var t = document.createElement("div"); t.className = "kui-toast"; t.textContent = "开始整屏录制"; this.stage.appendChild(t); setTimeout(function () { t.remove(); }, 1400); }, hold: 1500 },
      { cap: "回车直接执行；不用记路径，也不用打开别的地方。", hold: 1100 },
      { move: ".kui-q", ms: 480 },
      { run: function () { var q = this.stage.querySelector(".kui-q"); if (q) q.textContent = "/截"; }, hold: 700 },
      { cap: "继续输入就过滤，敲「/截」只剩截图相关命令。", hold: 1200 },
      { move: ".kui-row:nth-child(1)", ms: 500 },
      { cap: "工具箱 40+ 个小工具都在这里：取色、二维码、JSON 格式化、哈希……", hold: 1300 }
    ]
  },

  /* ------------------------------------------------ 全局搜索 */
  search: {
    title: "全局搜索：文件与应用一起搜",
    stage: 440,
    body: `
      <div class="kui-panel" style="width:390px">
        <div class="kui-search"><span>⌕</span><span class="kui-q">image-html</span></div>
        <div class="kui-list" style="max-height:270px">
          <div class="kui-sect-t" style="padding:4px 8px 2px">文件</div>
          <div class="kui-row" style="padding:5px 7px"><div class="kui-thumb t-file" style="width:22px;height:22px;font-size:10px">▤</div><div class="kui-meta"><div class="kui-t1" style="font-size:10.8px">image-html-deck/</div><div class="kui-t2" style="font-size:9.6px">~/.workbuddy/skills</div></div></div>
          <div class="kui-row" style="padding:5px 7px"><div class="kui-thumb t-file" style="width:22px;height:22px;font-size:10px">MD</div><div class="kui-meta"><div class="kui-t1" style="font-size:10.8px">SKILL.md</div><div class="kui-t2" style="font-size:9.6px">image-html-deck</div></div></div>
          <div class="kui-row" style="padding:5px 7px"><div class="kui-thumb t-file" style="width:22px;height:22px;font-size:10px">MD</div><div class="kui-meta"><div class="kui-t1" style="font-size:10.8px">README.md</div><div class="kui-t2" style="font-size:9.6px">image-html-deck</div></div></div>
          <div class="kui-sect-t" style="padding:7px 8px 2px">应用</div>
          <div class="kui-row" style="padding:5px 7px"><div class="kui-thumb" style="width:22px;height:22px;font-size:10px">P</div><div class="kui-meta"><div class="kui-t1" style="font-size:10.8px">Preview</div><div class="kui-t2" style="font-size:9.6px">应用</div></div></div>
          <div class="kui-sect-t" style="padding:7px 8px 2px">剪贴板</div>
          <div class="kui-row" style="padding:5px 7px"><div class="kui-thumb t-text" style="width:22px;height:22px;font-size:10px">T</div><div class="kui-meta"><div class="kui-t1" style="font-size:10.8px">image-html-deck 使用说明</div><div class="kui-t2" style="font-size:9.6px">昨天复制</div></div></div>
        </div>
      </div>`,
    steps: [
      { cap: "搜索框不止搜剪贴板：本地文件、应用、历史记录一起搜。", hold: 1250 },
      { move: ".kui-q", ms: 500 },
      { cap: "敲「image-html」就能找到 Spotlight 不索引的隐藏目录内容。", hold: 1200 },
      { move: ".kui-row:nth-child(2)", ms: 520 },
      { click: ".kui-row:nth-child(2)" },
      { run: function () { var t = document.createElement("div"); t.className = "kui-toast"; t.textContent = "已在 Finder 中显示"; this.stage.appendChild(t); setTimeout(function () { t.remove(); }, 1400); }, hold: 1500 },
      { cap: "回车打开或定位到 Finder；也可以直接预览内容。", hold: 1100 },
      { move: ".kui-sect-t:nth-of-type(3)", ms: 500 },
      { cap: "结果按类型分组，先看文件还是剪贴板由你定。", hold: 1250 }
    ]
  },

  /* ------------------------------------------------ 命令面板 */
  command: {
    title: "命令面板：45 条命令一屏",
    stage: 450,
    body: `
      <div class="kui-win" style="width:470px">
        <div class="kui-titlebar"><div class="kui-lights"><i></i><i></i><i></i></div><span class="kui-wtitle">命令面板 · ⌥K</span></div>
        <div class="kui-wbody" style="padding:10px 12px">
          <div class="kui-search" style="margin:0 0 9px"><span>⌕</span><span class="kui-q" style="color:#8A8A94">输入命令名…</span></div>
          <div class="kui-cmds" style="display:grid;grid-template-columns:repeat(3,1fr);gap:6px;font-size:10.6px">
            <div style="padding:7px 8px;border:1px solid #EDEDF1;border-radius:7px">开始录屏</div>
            <div style="padding:7px 8px;border:1px solid #EDEDF1;border-radius:7px">区域截图</div>
            <div style="padding:7px 8px;border:1px solid #EDEDF1;border-radius:7px">打开剪贴板</div>
            <div style="padding:7px 8px;border:1px solid #EDEDF1;border-radius:7px;background:#EEF3FF;border-color:#B9CDF7;color:#1E52D6">取色器</div>
            <div style="padding:7px 8px;border:1px solid #EDEDF1;border-radius:7px">存储管理</div>
            <div style="padding:7px 8px;border:1px solid #EDEDF1;border-radius:7px">网络诊断</div>
            <div style="padding:7px 8px;border:1px solid #EDEDF1;border-radius:7px">内存释放</div>
            <div style="padding:7px 8px;border:1px solid #EDEDF1;border-radius:7px">截图历史</div>
            <div style="padding:7px 8px;border:1px solid #EDEDF1;border-radius:7px">打开设置</div>
            <div style="padding:7px 8px;border:1px solid #EDEDF1;border-radius:7px">悬浮剪贴板</div>
            <div style="padding:7px 8px;border:1px solid #EDEDF1;border-radius:7px">录屏设置</div>
            <div style="padding:7px 8px;border:1px solid #EDEDF1;border-radius:7px">检查更新</div>
          </div>
          <div style="display:flex;gap:10px;margin-top:10px;font-size:9.8px;color:#8A8A94">
            <span><span class="kui-kbd">↑↓</span> 选择</span><span><span class="kui-kbd">↵</span> 执行</span><span><span class="kui-kbd">Esc</span> 关闭</span>
          </div>
        </div>
      </div>`,
    steps: [
      { cap: "⌥K 唤出命令面板，所有命令一屏铺开，不用记菜单层级。", hold: 1300 },
      { move: ".kui-cmds div:nth-child(4)", ms: 560 },
      { click: ".kui-cmds div:nth-child(4)" },
      { run: function () { var t = document.createElement("div"); t.className = "kui-toast"; t.textContent = "取色器已打开"; this.stage.appendChild(t); setTimeout(function () { t.remove(); }, 1400); }, hold: 1500 },
      { cap: "↑↓ 选中，回车执行；执行完面板自动收起。", hold: 1100 },
      { move: ".kui-q", ms: 480 },
      { type: ".kui-q", text: "录" },
      { run: function () {
          var nodes = this.stage.querySelectorAll(".kui-cmds div");
          Array.prototype.forEach.call(nodes, function (n, i) { n.style.display = i === 0 || i === 10 ? "" : "none"; });
        }, hold: 800 },
      { cap: "输入即过滤，敲「录」只剩录屏相关命令。", hold: 1250 }
    ]
  },

  /* ------------------------------------------------ 日历 */
  calendar: {
    title: "日历：翻周与回到今天",
    stage: 430,
    body: `
      <div class="kui-panel" style="width:372px">
        <div class="kui-sect" style="padding:12px 14px">
          <div style="display:flex;align-items:center;gap:8px;margin-bottom:9px">
            <span class="kui-cal-prev" style="font-size:13px;color:#5A5A64;cursor:pointer">‹</span>
            <b class="kui-cal-title" style="font-size:12.4px">11 月 2026</b>
            <span class="kui-cal-next" style="font-size:13px;color:#5A5A64;cursor:pointer">›</span>
            <span class="kui-spacer"></span>
            <span style="font-size:9.6px;color:#8A8A94">农历 · 节气</span>
          </div>
          <div class="kui-cal-week" style="display:grid;grid-template-columns:repeat(7,1fr);gap:4px;text-align:center;font-size:10px">
            ${["一","二","三","四","五","六","日"].map(d=>`<div style="color:#8A8A94">${d}</div>`).join('')}
            ${["16","17","18","19","20","21","22"].map((d,i)=>`<div style="padding:7px 0;border-radius:7px;${i===2?'background:#2F6BFF;color:#fff;font-weight:650':''}">${d}<div style="font-size:8px;${i===2?'color:#DCE6FA':'color:#B0B0B8'}">${["初七","初八","初九","初十","十一","十二","十三"][i]}</div></div>`).join('')}
          </div>
          <div style="margin-top:10px;padding:9px 10px;border-radius:9px;background:#F7F8FA;font-size:10.4px;color:#4A4A52">
            <div style="display:flex;justify-content:space-between"><span>今天 · 11 月 18 日</span><span style="color:#8A8A94">周三</span></div>
            <div style="margin-top:4px;color:#8A8A94">农历十月初九 · 无节气</div>
          </div>
        </div>
      </div>`,
    steps: [
      { cap: "首页日历卡显示本周与农历，点「‹ ›」翻周。", hold: 1200 },
      { move: ".kui-cal-prev", ms: 560 },
      { click: ".kui-cal-prev" },
      { run: function () {
          var t = this.stage.querySelector(".kui-cal-title");
          if (t) t.textContent = "11 月 2026 · 上周";
          var cells = this.stage.querySelectorAll(".kui-cal-week div");
          var days = ["9","10","11","12","13","14","15"];
          Array.prototype.forEach.call(cells, function (c, i) {
            if (i >= 7) { c.innerHTML = days[i-7] + '<div style="font-size:8px;color:#B0B0B8">农历</div>'; c.style.background = ""; c.style.color = ""; }
          });
        }, hold: 860 },
      { cap: "翻到上一周，日期与农历同步更新。", hold: 1000 },
      { move: ".kui-cal-title", ms: 520 },
      { click: ".kui-cal-title" },
      { run: function () {
          var t = this.stage.querySelector(".kui-cal-title");
          if (t) t.textContent = "11 月 2026";
          var cells = this.stage.querySelectorAll(".kui-cal-week div");
          var days = ["16","17","18","19","20","21","22"];
          Array.prototype.forEach.call(cells, function (c, i) {
            if (i >= 7) { c.innerHTML = days[i-7] + '<div style="font-size:8px;color:#B0B0B8">农历</div>'; }
          });
          var d = cells[9]; if (d) { d.style.background = "#2F6BFF"; d.style.color = "#fff"; }
        }, hold: 860 },
      { cap: "点月份标题回到今天，不用一周一周翻回来。", hold: 1150 },
      { move: ".kui-cal-week", ms: 500 },
      { cap: "农历、节气、节假日都在格子里；跨年也能查。", hold: 1250 }
    ]
  },

  /* ------------------------------------------------ 快捷键 */
  shortcuts: {
    title: "快捷键：点一下就能改绑",
    stage: 440,
    body: `
      <div class="kui-win" style="width:450px">
        <div class="kui-titlebar"><div class="kui-lights"><i></i><i></i><i></i></div><span class="kui-wtitle">设置 · 快捷键</span></div>
        <div class="kui-wbody" style="padding:10px 12px">
          <div class="kui-sect-t">全部功能绑定</div>
          <div class="kui-scut" style="font-size:11px">
            <div class="kui-field"><span class="kui-fl" style="width:150px">打开主面板</span><span class="kui-spacer"></span><span class="kui-kbd kui-key">⌥A</span></div>
            <div class="kui-field"><span class="kui-fl" style="width:150px">区域截图</span><span class="kui-spacer"></span><span class="kui-kbd kui-key">⌥S</span></div>
            <div class="kui-field"><span class="kui-fl" style="width:150px">悬浮剪贴板</span><span class="kui-spacer"></span><span class="kui-kbd kui-key">⇧⌘V</span></div>
            <div class="kui-field"><span class="kui-fl" style="width:150px">开始/停止录屏</span><span class="kui-spacer"></span><span class="kui-kbd kui-key">⌃⌥R</span></div>
            <div class="kui-field"><span class="kui-fl" style="width:150px">命令面板</span><span class="kui-spacer"></span><span class="kui-kbd kui-key">⌥K</span></div>
            <div class="kui-field"><span class="kui-fl" style="width:150px">钉住选区</span><span class="kui-spacer"></span><span class="kui-kbd kui-key">⌥P</span></div>
          </div>
        </div>
      </div>`,
    steps: [
      { cap: "快捷键页列出全部默认热键，每一行都能改。", hold: 1150 },
      { move: ".kui-key:nth-of-type(2)", ms: 520 },
      { click: ".kui-field:nth-child(2) .kui-key" },
      { run: function () {
          var k = this.stage.querySelector(".kui-field:nth-child(2) .kui-key");
          if (k) { k.textContent = "按下新组合…"; k.style.background = "#EEF3FF"; k.style.borderColor = "#2F6BFF"; k.style.color = "#1E52D6"; }
        }, hold: 900 },
      { cap: "点某行的快捷键进入录制态，直接按新的组合就改好了。", hold: 1150 },
      { run: function () {
          var k = this.stage.querySelector(".kui-field:nth-child(2) .kui-key");
          if (k) { k.textContent = "⇧⌥S"; k.style.background = ""; k.style.borderColor = ""; k.style.color = ""; }
        }, hold: 800 },
      { cap: "想恢复默认就点「恢复默认」；Esc 取消本次修改。", hold: 1100 },
      { move: ".kui-scut", ms: 500 },
      { cap: "也可以开启「双击修饰键」模式，单手就能触发。", hold: 1250 }
    ]
  },

  /* ------------------------------------------------ 代码预览 */
  codepreview: {
    title: "代码预览：高亮与语言切换",
    stage: 440,
    body: `
      <div class="kui-win" style="width:460px">
        <div class="kui-titlebar"><div class="kui-lights"><i></i><i></i><i></i></div><span class="kui-wtitle">Preview · main.swift</span></div>
        <div class="kui-wbody" style="padding:12px">
          <div style="display:flex;gap:6px;margin-bottom:9px">
            <span class="kui-chip on">Swift</span><span class="kui-chip">Python</span><span class="kui-chip">JavaScript</span><span class="kui-spacer"></span><span class="kui-chip kui-theme">深色主题</span>
          </div>
          <pre class="kui-code" style="margin:0;background:#FBFBFD;border:1px solid #EDEDF1;border-radius:9px;padding:10px;font-size:10.2px;line-height:1.7;overflow:auto;max-height:200px"><code><span style="color:#8A8A94">1</span>  <span style="color:#8A2BE2">import</span> SwiftUI
<span style="color:#8A8A94">2</span>
<span style="color:#8A8A94">3</span>  <span style="color:#8A2BE2">struct</span> <span style="color:#1E52D6">PanelView</span>: View {
<span style="color:#8A8A94">4</span>      <span style="color:#8A2BE2">var</span> body: <span style="color:#8A2BE2">some</span> View {
<span style="color:#8A8A94">5</span>          VStack {
<span style="color:#8A8A94">6</span>              Text(<span style="color:#C0392B">"Kitnest"</span>)
<span style="color:#8A8A94">7</span>              Button(<span style="color:#C0392B">"截图"</span>) { capture() }
<span style="color:#8A8A94">8</span>          }
<span style="color:#8A8A94">9</span>      }
<span style="color:#8A8A94">10</span> }
</code></pre>
          <div style="display:flex;gap:7px;margin-top:9px">
            <span class="kui-btn" style="flex:1;justify-content:center;padding:3px 8px">复制代码</span><span class="kui-btn" style="flex:1;justify-content:center;padding:3px 8px">在编辑器打开</span>
          </div>
        </div>
      </div>`,
    steps: [
      { cap: "剪贴板里的代码会自动高亮，带行号；不用打开 IDE 就能看。", hold: 1250 },
      { move: ".kui-chip:nth-child(2)", ms: 540 },
      { click: ".kui-chip:nth-child(2)" },
      { run: function () {
          this.stage.querySelectorAll(".kui-chip").forEach(function (c) { c.classList.remove("on"); });
          this.stage.querySelectorAll(".kui-chip")[1].classList.add("on");
          var code = this.stage.querySelector(".kui-code code");
          if (code) code.innerHTML = '<span style="color:#8A8A94">1</span>  <span style="color:#8A2BE2">def</span> <span style="color:#1E52D6">capture</span>():<br><span style="color:#8A8A94">2</span>      <span style="color:#8A2BE2">return</span> kitnest.<span style="color:#1E52D6">screenshot</span>()<br><span style="color:#8A8A94">3</span><br><span style="color:#8A8A94">4</span>  <span style="color:#8A2BE2">if</span> __name__ == <span style="color:#C0392B">"__main__"</span>:<br><span style="color:#8A8A94">5</span>      capture()';
        }, hold: 860 },
      { cap: "切到 Python，语言识别和高亮跟着变。", hold: 1050 },
      { move: ".kui-theme", ms: 520 },
      { click: ".kui-theme" },
      { run: function () {
          var pre = this.stage.querySelector(".kui-code");
          if (pre) { pre.style.background = "#1F2430"; pre.style.borderColor = "#2A3140"; pre.style.color = "#D8DEE9"; }
        }, hold: 860 },
      { cap: "深色主题适合长时间看代码；复制走系统剪贴板。", hold: 1200 },
      { move: ".kui-btn:nth-of-type(1)", ms: 500 },
      { click: ".kui-btn" },
      { cap: "一键复制整段代码，行号不会带上。", hold: 1250 }
    ]
  },

  /* ------------------------------------------------ 网盘解析 */
  cloudlink: {
    title: "网盘解析：链接与提取码",
    stage: 450,
    body: `
      <div class="kui-win" style="width:440px">
        <div class="kui-titlebar"><div class="kui-lights"><i></i><i></i><i></i></div><span class="kui-wtitle">解析下载</span></div>
        <div class="kui-wbody">
          <div class="kui-field"><span class="kui-fl">分享链接</span><span class="kui-fv" style="color:#33333B">https://pan.example.com/s/1AbCdEf</span></div>
          <div class="kui-field"><span class="kui-fl">提取码</span><span class="kui-fv"><span class="kui-code" style="font-family:monospace;background:#F5F5F8;padding:1px 7px;border-radius:5px">x7k2</span></span></div>
          <div style="display:flex;gap:7px;margin:10px 0">
            <span class="kui-btn primary kui-parse" style="flex:1;justify-content:center">开始解析</span>
            <span class="kui-btn" style="padding:5px 10px">粘贴</span>
          </div>
          <div class="kui-parseout kui-hidden">
            <div class="kui-sect-t">解析结果</div>
            <div class="kui-row" style="padding:5px 6px"><div class="kui-thumb t-file" style="width:24px;height:24px">▤</div><div class="kui-meta"><div class="kui-t1" style="font-size:10.8px">设计素材包-2026.zip</div><div class="kui-t2" style="font-size:9.6px">1.2 GB · 原画</div></div></div>
            <div class="kui-field" style="margin-top:6px"><span class="kui-fl">保存到</span><span class="kui-fv" style="color:#33333B">~/Downloads</span></div>
            <div style="display:flex;gap:7px;margin-top:8px">
              <span class="kui-btn primary" style="flex:1;justify-content:center">开始下载</span>
            </div>
          </div>
        </div>
      </div>`,
    steps: [
      { cap: "复制网盘分享链接，Kitnest 能识别并直接解析下载。", hold: 1200 },
      { move: ".kui-parse", ms: 540 },
      { click: ".kui-parse" },
      { run: function () { this.stage.querySelector(".kui-parseout").classList.remove("kui-hidden"); }, hold: 900 },
      { cap: "解析出文件名、大小、清晰度；确认是你要的那个再下。", hold: 1200 },
      { move: ".kui-parseout .kui-btn.primary", ms: 520 },
      { click: ".kui-parseout .kui-btn.primary" },
      { run: function () { var t = document.createElement("div"); t.className = "kui-toast"; t.textContent = "开始下载 · 1.2 GB"; this.stage.appendChild(t); setTimeout(function () { t.remove(); }, 1400); }, hold: 1500 },
      { cap: "下载走系统网络，进度在面板底部；不用打开浏览器。", hold: 1250 },
      { move: ".kui-field:nth-child(2)", ms: 500 },
      { cap: "提取码可以自动带出，也能手动填；链接失效会明确提示。", hold: 1250 }
    ]
  },

  /* ------------------------------------------------ AI 助手 */
  ai: {
    title: "AI 助手：服务商、模型与密钥",
    stage: 450,
    body: `
      <div class="kui-win" style="width:450px">
        <div class="kui-titlebar"><div class="kui-lights"><i></i><i></i><i></i></div><span class="kui-wtitle">设置 · AI</span></div>
        <div class="kui-wbody">
          <div class="kui-field"><span class="kui-fl">服务商</span><span class="kui-fv">
            <span class="kui-chip on">OpenAI</span> <span class="kui-chip">Anthropic</span> <span class="kui-chip">本地</span>
          </span></div>
          <div class="kui-field"><span class="kui-fl">模型</span><span class="kui-fv">gpt-4o-mini</span></div>
          <div class="kui-field"><span class="kui-fl">API 密钥</span><span class="kui-fv">•••••••••••• <span style="color:#1F9D63">已加密存储</span></span></div>
          <div class="kui-field"><span class="kui-fl">默认行为</span><span class="kui-fv">选中文本后显示「问 AI」</span><span class="kui-sw on"></span></div>
          <div class="kui-field"><span class="kui-fl">自动总结剪贴板</span><span class="kui-fv">复制长文时提示</span><span class="kui-sw"></span></div>
          <div class="kui-sect-t" style="margin-top:10px">最近对话</div>
          <div class="kui-card" style="font-size:10.6px;line-height:1.7;color:#4A4A52">
            <b style="color:#33333B">总结这段会议纪要</b><br>
            <span style="color:#8A8A94">3 个行动项：手册重构、OCR 用例、下周一验收……</span>
          </div>
        </div>
      </div>`,
    steps: [
      { cap: "AI 助手接四类服务商：填一次密钥，之后在面板里直接用。", hold: 1250 },
      { move: '.kui-chip:nth-child(2)', ms: 540 },
      { click: '.kui-chip:nth-child(2)' },
      { run: function () {
          this.stage.querySelectorAll(".kui-chip").forEach(function (c) { c.classList.remove("on"); });
          this.stage.querySelectorAll(".kui-chip")[1].classList.add("on");
          var f = this.stage.querySelector(".kui-field:nth-child(2) .kui-fv");
          if (f) f.textContent = "claude-3-5-sonnet";
        }, hold: 860 },
      { cap: "换服务商模型跟着换；不用的服务商不会发请求。", hold: 1050 },
      { move: ".kui-field:nth-child(3)", ms: 520 },
      { cap: "密钥本地加密存储，只存在这台机器上。", hold: 1100 },
      { move: ".kui-field:nth-child(4) .kui-sw", ms: 520 },
      { click: ".kui-field:nth-child(4) .kui-sw" },
      { run: function () { this.stage.querySelector(".kui-field:nth-child(4) .kui-sw").classList.remove("on"); }, hold: 780 },
      { cap: "「选中文本后显示问 AI」可以关掉，保持界面干净。", hold: 1150 },
      { move: ".kui-card", ms: 500 },
      { cap: "对话记录留在本机，可随时清空；不会同步到云端。", hold: 1250 }
    ]
  },

  /* ------------------------------------------------ 设置 */
  settings: {
    title: "设置：13 类 42 页",
    stage: 470,
    body: `
      <div class="kui-win" style="width:470px">
        <div class="kui-titlebar"><div class="kui-lights"><i></i><i></i><i></i></div><span class="kui-wtitle">设置</span></div>
        <div class="kui-wbody" style="padding:0;display:flex;height:300px">
          <div class="kui-setnav" style="width:132px;border-right:1px solid #F0F0F3;padding:9px 7px;font-size:10.6px;overflow:auto">
            <div style="padding:5px 8px;border-radius:6px;background:#EEF3FF;color:#1E52D6;font-weight:600">常规</div>
            <div style="padding:5px 8px;color:#5A5A64">外观</div>
            <div style="padding:5px 8px;color:#5A5A64">菜单栏</div>
            <div style="padding:5px 8px;color:#5A5A64">剪贴板</div>
            <div style="padding:5px 8px;color:#5A5A64">截图与钉图</div>
            <div style="padding:5px 8px;color:#5A5A64">录屏</div>
            <div style="padding:5px 8px;color:#5A5A64">监测</div>
            <div style="padding:5px 8px;color:#5A5A64">快捷键</div>
            <div style="padding:5px 8px;color:#5A5A64">AI</div>
            <div style="padding:5px 8px;color:#5A5A64">工作流</div>
            <div style="padding:5px 8px;color:#5A5A64">关于</div>
          </div>
          <div class="kui-setbody" style="flex:1;padding:12px 14px;overflow:auto">
            <div style="font-size:12.4px;font-weight:650;margin-bottom:9px">常规</div>
            <div class="kui-field"><span class="kui-fl">开机自启动</span><span class="kui-spacer"></span><span class="kui-sw on"></span></div>
            <div class="kui-field"><span class="kui-fl">显示菜单栏图标</span><span class="kui-spacer"></span><span class="kui-sw on"></span></div>
            <div class="kui-field"><span class="kui-fl">主面板宽度</span><span class="kui-spacer"></span><span class="kui-fv">400 pt</span></div>
            <div class="kui-field"><span class="kui-fl">语言</span><span class="kui-spacer"></span><span class="kui-fv">简体中文</span></div>
            <div class="kui-sect-t" style="margin-top:10px">功能开关</div>
            <div class="kui-field"><span class="kui-fl">剪贴板历史</span><span class="kui-spacer"></span><span class="kui-sw on"></span></div>
            <div class="kui-field"><span class="kui-fl">日历卡片</span><span class="kui-spacer"></span><span class="kui-sw on"></span></div>
            <div class="kui-field"><span class="kui-fl">文件中转</span><span class="kui-spacer"></span><span class="kui-sw on"></span></div>
          </div>
        </div>
        <div class="kui-dock"><span>恢复默认</span><span class="kui-spacer"></span><span class="kui-btn primary" style="padding:3px 12px;font-size:10.6px">保存</span></div>
      </div>`,
    steps: [
      { cap: "设置分 13 类 42 页，左侧导航、右侧表单，改完点保存。", hold: 1300 },
      { move: ".kui-setnav div:nth-child(3)", ms: 540 },
      { click: ".kui-setnav div:nth-child(3)" },
      { run: function () {
          this.stage.querySelectorAll(".kui-setnav div").forEach(function (n) { n.style.background = ""; n.style.color = "#5A5A64"; n.style.fontWeight = ""; });
          var n = this.stage.querySelector(".kui-setnav div:nth-child(3)");
          if (n) { n.style.background = "#EEF3FF"; n.style.color = "#1E52D6"; n.style.fontWeight = "600"; }
          var t = this.stage.querySelector(".kui-setbody > div:first-child");
          if (t) t.textContent = "菜单栏";
        }, hold: 800 },
      { cap: "切到「菜单栏」：部件、颜色、更新间隔都在这一页。", hold: 1150 },
      { move: ".kui-field:nth-child(2) .kui-sw", ms: 500 },
      { click: ".kui-field:nth-child(2) .kui-sw" },
      { run: function () { this.stage.querySelector(".kui-field:nth-child(2) .kui-sw").classList.toggle("on"); }, hold: 780 },
      { cap: "开关即时预览；改动先进草稿，点「保存」才真正生效。", hold: 1250 },
      { move: ".kui-dock .kui-btn.primary", ms: 520 },
      { click: ".kui-dock .kui-btn.primary" },
      { run: function () { var t = document.createElement("div"); t.className = "kui-toast"; t.textContent = "设置已保存"; this.stage.appendChild(t); setTimeout(function () { t.remove(); }, 1400); }, hold: 1500 },
      { cap: "切页不丢草稿；「恢复默认」只重置当前页。", hold: 1250 }
    ]
  },

  /* ------------------------------------------------ 新手引导 */
  onboarding: {
    title: "首次启动：权限与能力卡",
    stage: 450,
    body: `
      <div class="kui-win" style="width:450px">
        <div class="kui-titlebar"><div class="kui-lights"><i></i><i></i><i></i></div><span class="kui-wtitle">欢迎使用 Kitnest</span></div>
        <div class="kui-wbody">
          <div style="font-size:14px;font-weight:650;margin-bottom:3px">你好，这是你的效率工具集</div>
          <div style="font-size:10.6px;color:#8A8A94;margin-bottom:12px">三步开始：看一眼能做什么、给必要权限、开始用。</div>
          <div style="display:grid;grid-template-columns:repeat(3,1fr);gap:7px;margin-bottom:12px">
            <div class="kui-card" style="text-align:center;padding:9px 6px"><div style="font-size:16px">▤</div><div style="font-size:10.2px;margin-top:3px">剪贴板</div><div style="font-size:8.8px;color:#8A8A94">复制过的都记着</div></div>
            <div class="kui-card" style="text-align:center;padding:9px 6px"><div style="font-size:16px">▣</div><div style="font-size:10.2px;margin-top:3px">截图</div><div style="font-size:8.8px;color:#8A8A94">标注、识字、钉住</div></div>
            <div class="kui-card" style="text-align:center;padding:9px 6px"><div style="font-size:16px">◫</div><div style="font-size:10.2px;margin-top:3px">图帘</div><div style="font-size:8.8px;color:#8A8A94">截图先挂顶边</div></div>
          </div>
          <div class="kui-sect-t">权限状态</div>
          <div class="kui-field"><span class="kui-fl">屏幕录制</span><span class="kui-fv" style="color:#1F9D63">已允许</span></div>
          <div class="kui-field"><span class="kui-fl">辅助功能</span><span class="kui-fv" style="color:#D97706">待授权</span><span class="kui-btn" style="padding:2px 8px;font-size:10px">去开启</span></div>
          <div class="kui-field"><span class="kui-fl">通知</span><span class="kui-fv" style="color:#8A8A94">可选</span></div>
        </div>
        <div class="kui-dock"><span>稍后再说</span><span class="kui-spacer"></span><span class="kui-btn primary kui-start" style="padding:3px 14px;font-size:10.6px">开始使用</span></div>
      </div>`,
    steps: [
      { cap: "首次启动是一张欢迎卡：能做什么、要什么权限、一步开始。", hold: 1300 },
      { move: ".kui-card:nth-child(2)", ms: 560 },
      { cap: "三张能力卡对应最常用的三件事：剪贴板、截图、图帘。", hold: 1100 },
      { move: ".kui-field:nth-child(2) .kui-btn", ms: 520 },
      { click: ".kui-field:nth-child(2) .kui-btn" },
      { run: function () {
          var f = this.stage.querySelector(".kui-field:nth-child(2) .kui-fv");
          if (f) { f.textContent = "已允许"; f.style.color = "#1F9D63"; }
          var b = this.stage.querySelector(".kui-field:nth-child(2) .kui-btn");
          if (b) b.style.display = "none";
        }, hold: 860 },
      { cap: "「辅助功能」点「去开启」跳到系统设置，授权后回来状态就变绿。", hold: 1350 },
      { move: ".kui-start", ms: 520 },
      { click: ".kui-start" },
      { cap: "点「开始使用」进主面板；权限随时能在设置里补。", hold: 1300 }
    ]
  },

  /* ------------------------------------------------ 内置用户手册 */
  manual: {
    title: "内置手册：树形目录与搜索",
    stage: 450,
    body: `
      <div class="kui-win" style="width:460px">
        <div class="kui-titlebar"><div class="kui-lights"><i></i><i></i><i></i></div><span class="kui-wtitle">使用手册</span></div>
        <div class="kui-wbody" style="padding:0;display:flex;height:290px">
          <div class="kui-tree" style="width:150px;border-right:1px solid #F0F0F3;overflow:auto">
            <div style="display:flex;align-items:center;gap:5px;padding:6px 8px;border:1px solid #EDEDF1;border-radius:7px;margin-bottom:6px;font-size:10px;color:#8A8A94"><span>⌕</span><span>搜索手册…</span></div>
            <b>界面与入口</b>
            <i>菜单栏与图标</i>
            <i class="on">主面板与首页</i>
            <i>使用统计</i>
            <b>剪贴板</b>
            <i>剪贴板历史</i>
            <i>悬浮剪贴板</i>
            <b>截图与录屏</b>
            <i>截图主流程</i>
            <i>标注编辑器</i>
            <b>系统监测</b>
            <i>系统监测</i>
            <i>内存维护</i>
          </div>
          <div style="flex:1;padding:12px 14px;overflow:auto">
            <div style="font-size:13px;font-weight:650;margin-bottom:7px">主面板与首页</div>
            <div style="font-size:10.6px;color:#8A8A94;margin-bottom:8px">功能是什么</div>
            <div style="font-size:10.4px;line-height:1.75;color:#44444C">面板是 Kitnest 的主入口：四个页签、搜索框、剪贴板列表和底部工具条。按 ⌥A 随时呼出，Esc 收起。</div>
            <div style="font-size:10.6px;color:#8A8A94;margin:10px 0 6px">演示</div>
            <div class="kui-mini" style="border:1px solid #EDEDF1;border-radius:8px;padding:8px;background:#FAFBFC">
              <div style="height:64px;border-radius:6px;background:linear-gradient(135deg,#E8EEF9,#F6F8FC)"></div>
              <div style="font-size:9px;color:#8A8A94;margin-top:5px">预设动画 · 可点按体验</div>
            </div>
          </div>
        </div>
      </div>`,
    steps: [
      { cap: "手册内嵌在设置里：左边树形目录，右边正文，随包离线可用。", hold: 1300 },
      { move: ".kui-tree i:nth-of-type(4)", ms: 560 },
      { click: ".kui-tree i:nth-of-type(4)" },
      { run: function () {
          this.stage.querySelectorAll(".kui-tree i").forEach(function (n) { n.classList.remove("on"); });
          var n = this.stage.querySelector(".kui-tree i:nth-of-type(4)");
          if (n) n.classList.add("on");
          var t = this.stage.querySelector(".kui-win .kui-wbody > div:last-child > div:first-child");
          if (t) t.textContent = "剪贴板历史";
        }, hold: 860 },
      { cap: "点目录跳到对应章节，上/下一节按钮连着读。", hold: 1100 },
      { move: ".kui-tree div:first-child", ms: 520 },
      { click: ".kui-tree div:first-child" },
      { cap: "搜索框支持标题和正文：敲关键词自动展开命中路径。", hold: 1250 },
      { move: ".kui-mini", ms: 500 },
      { cap: "正文里的演示和在线版一致：预设动画，可重播。", hold: 1300 }
    ]
  },

  /* ------------------------------------------------ 更新与诊断 */
  update: {
    title: "关于：版本、更新与诊断",
    stage: 440,
    body: `
      <div class="kui-win" style="width:430px">
        <div class="kui-titlebar"><div class="kui-lights"><i></i><i></i><i></i></div><span class="kui-wtitle">关于 Kitnest</span></div>
        <div class="kui-wbody" style="text-align:center">
          <div style="width:54px;height:54px;margin:6px auto 8px;border-radius:13px;background:linear-gradient(145deg,#FFB25E,#FF7A59);display:flex;align-items:center;justify-content:center;font-size:22px;color:#fff">K</div>
          <div style="font-size:14px;font-weight:650">Kitnest</div>
          <div style="font-size:10.4px;color:#8A8A94;margin-top:2px">版本 1.0.0（build 271）</div>
          <div style="display:flex;gap:7px;justify-content:center;margin:12px 0 8px">
            <span class="kui-btn kui-check" style="padding:4px 14px">检查更新</span>
            <span class="kui-btn" style="padding:4px 14px">诊断</span>
          </div>
          <div class="kui-upd" style="display:none;margin:0 auto;padding:8px 12px;border-radius:9px;background:#EEF3FF;border:1px solid #D5E1FF;font-size:10.4px;color:#1E52D6;max-width:280px">
            发现新版本 · build 272<br><span style="font-size:9.4px;opacity:.8">[改进] 手册交互演示 · [修复] 若干细节</span>
          </div>
          <div style="font-size:9.6px;color:#A8A8B0;margin-top:14px">自签分发 · 未公证 · 首次打开需右键</div>
        </div>
      </div>`,
    steps: [
      { cap: "关于页看版本号、检查更新和诊断入口。", hold: 1150 },
      { move: ".kui-check", ms: 540 },
      { click: ".kui-check" },
      { run: function () { this.stage.querySelector(".kui-upd").style.display = "block"; }, hold: 900 },
      { cap: "有新版时列出 build 号与更新说明，点一下就能升级。", hold: 1250 },
      { run: function () {
          var b = this.stage.querySelector(".kui-check");
          if (b) { b.textContent = "立即更新"; b.classList.add("primary"); }
        }, hold: 800 },
      { cap: "更新走整包替换：下载、校验、备份、重启，失败自动回滚。", hold: 1300 },
      { move: ".kui-btn:nth-of-type(2)", ms: 500 },
      { cap: "「诊断」导出日志与运行状态，排查问题发给开发者。", hold: 1250 }
    ]
  },

  /* ------------------------------------------------ 工作流 */
  workflow: {
    title: "工作流：截图后自动做事",
    stage: 460,
    body: `
      <div class="kui-win" style="width:450px">
        <div class="kui-titlebar"><div class="kui-lights"><i></i><i></i><i></i></div><span class="kui-wtitle">设置 · 工作流</span></div>
        <div class="kui-wbody">
          <div class="kui-sect-t">三档预设</div>
          <div style="display:grid;grid-template-columns:repeat(3,1fr);gap:7px;margin-bottom:10px">
            <div class="kui-card kui-wf on" style="text-align:center;padding:8px 6px"><div style="font-size:12px">⤓</div><div style="font-size:10px;margin-top:2px">保存到下载</div></div>
            <div class="kui-card kui-wf" style="text-align:center;padding:8px 6px"><div style="font-size:12px">⎘</div><div style="font-size:10px;margin-top:2px">复制到剪贴板</div></div>
            <div class="kui-card kui-wf" style="text-align:center;padding:8px 6px"><div style="font-size:12px">🔔</div><div style="font-size:10px;margin-top:2px">发通知</div></div>
          </div>
          <div class="kui-sect-t">添加工作流</div>
          <div class="kui-card" style="margin-bottom:9px">
            <div class="kui-field" style="border:0;padding:3px 0"><span class="kui-fl">触发</span><span class="kui-fv">截图完成后</span></div>
            <div class="kui-field" style="border:0;padding:3px 0"><span class="kui-fl">动作</span><span class="kui-fv">OCR → 上传图床 → 复制 Markdown</span></div>
          </div>
          <div class="kui-sect-t">凭据</div>
          <div class="kui-field"><span class="kui-fl">GitHub Token</span><span class="kui-fv">未设置</span><span class="kui-btn" style="padding:2px 8px;font-size:10px">添加</span></div>
          <div class="kui-field"><span class="kui-fl">Linear Token</span><span class="kui-fv">未设置</span><span class="kui-btn" style="padding:2px 8px;font-size:10px">添加</span></div>
        </div>
        <div class="kui-dock"><span class="kui-spacer"></span><span class="kui-btn primary" style="padding:3px 12px;font-size:10.6px">保存</span></div>
      </div>`,
    steps: [
      { cap: "工作流让截图之后自动接着做事：保存、复制、发通知、建 issue。", hold: 1300 },
      { move: ".kui-wf:nth-child(2)", ms: 540 },
      { click: ".kui-wf:nth-child(2)" },
      { run: function () {
          this.stage.querySelectorAll(".kui-wf").forEach(function (c) { c.style.borderColor = ""; c.style.boxShadow = ""; });
          var c = this.stage.querySelector(".kui-wf:nth-child(2)");
          if (c) { c.style.borderColor = "#2F6BFF"; c.style.boxShadow = "0 0 0 2px rgba(47,107,255,.22)"; }
        }, hold: 800 },
      { cap: "三档预设一键切换：存到下载、复制到剪贴板、发通知。", hold: 1100 },
      { move: ".kui-card:nth-of-type(4)", ms: 520 },
      { cap: "也能自己搭：截图完成后 OCR → 上传图床 → 复制 Markdown 一条链。", hold: 1400 },
      { move: ".kui-field:nth-child(1) .kui-btn", ms: 500 },
      { click: ".kui-field:nth-child(1) .kui-btn" },
      { cap: "GitHub / Linear 凭据同样是本地加密存储，不写进日志。", hold: 1300 }
    ]
  }
};
