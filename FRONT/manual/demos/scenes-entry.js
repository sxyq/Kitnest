/* ============================================================
   Kitnest 手册 · 演示场景库 · 界面与入口（按需加载）
   ------------------------------------------------------------
   由 tools/split_manual_scenes.py 从 scenes.js 拆分生成。
   只有读者滚到本域的演示块时，demo.js 才会 fetch 这个文件；
   首屏不会加载全部场景。
   ============================================================ */
Object.assign(window.KDEMOS = window.KDEMOS || {}, {
  menubar: {
    title: "菜单栏图标：面板从图标下展开",
    stage: 353,
    body: `
      <div style="width:100%;max-width:470px">
        <div class="kui-menubar">
          <span class="kui-glyph"></span>
          <span class="kui-mi">Kitnest</span>
          <span class="kui-spacer"></span>
          <span class="kui-mi">􀊫</span><span class="kui-mi">􀉉</span><span class="kui-mi">9:41</span>
        </div>
        <div class="kui-panel" style="margin-top:8px;width:340px;margin-left:8px">
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
      { cap: "Kitnest 常驻菜单栏，不占 Dock、不抢焦点；点图标展开或收起面板。", hold: 1200 },
      { move: ".kui-glyph", ms: 700 },
      { click: ".kui-glyph" },
      { run: function () { this.stage.querySelector(".kui-panel").classList.add("kui-hidden"); }, hold: 700 },
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

  panel: {
    title: "主面板：四个页签与搜索",
    stage: 369,
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

  statistics: {
    title: "使用统计：计数、柱图、热力矩阵",
    stage: 342,
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
  }
});
