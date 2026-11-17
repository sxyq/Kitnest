/* ============================================================
   Kitnest 手册 · 演示场景库 · 剪贴板（按需加载）
   ------------------------------------------------------------
   由 tools/split_manual_scenes.py 从 scenes.js 拆分生成。
   只有读者滚到本域的演示块时，demo.js 才会 fetch 这个文件；
   首屏不会加载全部场景。
   ============================================================ */
Object.assign(window.KDEMOS = window.KDEMOS || {}, {
  clipboard: {
    title: "剪贴板历史：滚动、悬停、筛选",
    stage: 397,
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

  floatdesk: {
    title: "悬浮剪贴板：卡片网格 + 预览",
    stage: 311,
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

  preview: {
    title: "悬停预览：内容随类型变",
    stage: 237,
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
  }
});
