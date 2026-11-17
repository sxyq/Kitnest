/* ============================================================
   Kitnest 手册 · 演示场景库 · 系统监测（按需加载）
   ------------------------------------------------------------
   由 tools/split_manual_scenes.py 从 scenes.js 拆分生成。
   只有读者滚到本域的演示块时，demo.js 才会 fetch 这个文件；
   首屏不会加载全部场景。
   ============================================================ */
Object.assign(window.KDEMOS = window.KDEMOS || {}, {
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
  }
});
