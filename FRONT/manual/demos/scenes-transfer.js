/* ============================================================
   Kitnest 手册 · 演示场景库 · 传输（按需加载）
   ------------------------------------------------------------
   由 tools/split_manual_scenes.py 从 scenes.js 拆分生成。
   只有读者滚到本域的演示块时，demo.js 才会 fetch 这个文件；
   首屏不会加载全部场景。
   ============================================================ */
Object.assign(window.KDEMOS = window.KDEMOS || {}, {
  transfer: {
    title: "文件中转：三种方式发文件",
    stage: 486,
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

  cast: {
    title: "投屏：安卓与 iPhone 分栏",
    stage: 400,
    body: `
      <div class="kui-panel" style="width:390px">
        <div class="kui-panelbar">
          <span class="kui-seg">主页</span><span class="kui-seg">监测</span><span class="kui-seg">中转</span><span class="kui-seg on">投屏</span>
          <span class="kui-spacer"></span><span class="kui-ico">⚙</span>
        </div>
        <div class="kui-split" style="padding:10px 12px;gap:10px">
          <div style="flex:1;background:#F7F8FA;border-radius:10px;padding:10px">
            <div style="font-size:11px;font-weight:620;margin-bottom:6px">安卓</div>
            <div style="height:86px;border-radius:8px;background:linear-gradient(135deg,#E8EEF9,#F5F8FC);display:flex;align-items:center;justify-content:center;font-size:10px;color:#7A7A84">未连接</div>
            <div style="display:flex;gap:5px;margin-top:7px">
              <span class="kui-btn" style="flex:1;justify-content:center;padding:3px 6px;font-size:10px">USB</span>
              <span class="kui-btn primary kui-conn" style="flex:1;justify-content:center;padding:3px 6px;font-size:10px">扫码连接</span>
            </div>
          </div>
          <div style="flex:1;background:#F7F8FA;border-radius:10px;padding:10px">
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
  }
});
