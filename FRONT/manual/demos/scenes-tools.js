/* ============================================================
   Kitnest 手册 · 演示场景库 · 文件与工具（按需加载）
   ------------------------------------------------------------
   由 tools/split_manual_scenes.py 从 scenes.js 拆分生成。
   只有读者滚到本域的演示块时，demo.js 才会 fetch 这个文件；
   首屏不会加载全部场景。
   ============================================================ */
Object.assign(window.KDEMOS = window.KDEMOS || {}, {
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
  }
});
