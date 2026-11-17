/* ============================================================
   Kitnest 手册 · 演示场景库 · 截图与录屏（按需加载）
   ------------------------------------------------------------
   由 tools/split_manual_scenes.py 从 scenes.js 拆分生成。
   只有读者滚到本域的演示块时，demo.js 才会 fetch 这个文件；
   首屏不会加载全部场景。
   ============================================================ */
Object.assign(window.KDEMOS = window.KDEMOS || {}, {
  capture: {
    title: "截图：选区 → 动作条 → 钉住",
    stage: 258,
    body: `
      <div class="kui-screen">
        <div style="position:absolute;left:22px;top:18px;font-size:11px;color:#98A0AD">桌面</div>
        <div class="kui-select kui-hidden" style="left:120px;top:64px;width:210px;height:118px">
          <span class="kui-size">210 × 118</span>
        </div>
        <div class="kui-toolbar kui-hidden" style="position:absolute;left:96px;top:200px">
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

  annotate: {
    title: "标注：对象化箭头与马赛克",
    stage: 278,
    body: `
      <div style="position:relative;width:100%;max-width:470px">
        <div class="kui-screen" style="height:270px">
          <div style="position:absolute;left:26px;top:26px;width:200px;padding:14px;border-radius:9px;background:#fff;border:0">
            <div style="font-size:10px;color:#8A8A94;margin-bottom:7px">转账详情</div>
            <div style="display:flex;justify-content:space-between;font-size:11px;margin:5px 0"><span>收款方</span><b>示例商户</b></div>
            <div style="display:flex;justify-content:space-between;font-size:11px;margin:5px 0"><span>金额</span><b class="kui-amount" style="color:#C0392B">¥ 1,280.00</b></div>
            <div style="display:flex;justify-content:space-between;font-size:10px;color:#8A8A94;margin-top:8px"><span>订单号</span><span>20261118094012</span></div>
          </div>
          <svg class="kui-arrow" width="120" height="80" style="position:absolute;left:236px;top:64px;opacity:0;transition:opacity .25s ease">
            <defs><marker id="ah" markerWidth="8" markerHeight="8" refX="6" refY="3" orient="auto"><path d="M0,0 L6,3 L0,6 z" fill="#2F6BFF"/></marker></defs>
            <path d="M6 66 C 40 12, 80 12, 112 34" fill="none" stroke="#2F6BFF" stroke-width="2.4" marker-end="url(#ah)"/>
          </svg>
          <div class="kui-annot-bar" style="position:absolute;left:14px;top:88px;display:flex;flex-direction:column;gap:4px;padding:6px;border-radius:10px;background:rgba(255,255,255,.88);font-size:11px;opacity:0;transition:opacity .25s ease">
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

  beautify: {
    title: "美化：背景、圆角、投影",
    stage: 316,
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

  longshot: {
    title: "长截图：滚动合成，接缝无重影",
    stage: 373,
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

  pin: {
    title: "钉图：四种形态与不透明度",
    stage: 327,
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

  curtain: {
    title: "图帘：截图先挂在顶边",
    stage: 289,
    body: `
      <div style="width:100%;max-width:470px">
        <div class="kui-menubar" style="margin-bottom:0">
          <span class="kui-glyph"></span><span class="kui-mi">Kitnest</span><span class="kui-spacer"></span><span class="kui-mi">9:41</span>
        </div>
        <div style="background:linear-gradient(160deg,#EAF0FA 0%,#F6F8FC 55%,#EEF2F8 100%);height:250px;border-radius:0 0 10px 10px;position:relative;border:1px solid #E7EAF0;border-top:0">
          <div class="kui-ladder" style="position:absolute;left:50%;top:8px;transform:translateX(-50%);padding:7px 10px;background:rgba(255,255,255,.72);border:0">
            <div class="kui-shot"></div><div class="kui-shot"></div><div class="kui-shot"></div>
          </div>
          <div style="position:absolute;left:24px;bottom:26px;width:150px;height:88px;border-radius:9px;background:#fff;padding:10px;font-size:10px;color:#8A8A94">桌面文件</div>
          <div style="position:absolute;right:24px;bottom:26px;width:150px;height:88px;border-radius:9px;background:#fff;padding:10px;font-size:10px;color:#8A8A94">项目目录</div>
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

  history: {
    title: "截图历史：网格与搜索",
    stage: 336,
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

  ocr: {
    title: "文字识别：左图右文，可翻译",
    stage: 294,
    body: `
      <div class="kui-win" style="width:470px">
        <div class="kui-titlebar"><div class="kui-lights"><i></i><i></i><i></i></div><span class="kui-wtitle">识别结果</span></div>
        <div class="kui-wbody" style="display:flex;gap:12px;padding:12px">
          <div style="flex:1">
            <div style="height:190px;border-radius:8px;background:linear-gradient(135deg,#E9EFF9,#F6F8FC);position:relative;overflow:hidden">
              <div style="position:absolute;left:14px;top:16px;font-size:10px;line-height:1.7;color:#5A6473">
                出行提示<br>11 月 18 日 09:40<br>登机口 B12<br>请提前 30 分钟到达
              </div>
            </div>
            <div style="display:flex;gap:5px;margin-top:8px">
              <span class="kui-chip on">中文</span><span class="kui-chip">英文</span><span class="kui-chip">翻译</span>
            </div>
          </div>
          <div style="flex:1;display:flex;flex-direction:column">
            <div class="kui-ocrtext" style="flex:1;font-size:10.8px;line-height:1.8;color:#33333B;border:0;border-radius:8px;padding:9px;background:#F7F8FA">
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

  captureplus: {
    title: "截图设置：比例、命名、静默识别",
    stage: 319,
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

  recording: {
    title: "录屏：控制条、画中画、剪辑",
    stage: 404,
    body: `
      <div class="kui-win" style="width:440px">
        <div class="kui-titlebar"><div class="kui-lights"><i></i><i></i><i></i></div><span class="kui-wtitle">录屏</span></div>
        <div style="height:196px;background:linear-gradient(135deg,#E8EEF9,#F6F8FC);position:relative;overflow:hidden">
          <div style="position:absolute;left:24px;top:22px;width:158px;height:92px;border-radius:8px;background:#fff;padding:10px;font-size:10px;color:#5A6473">演示窗口</div>
          <div class="kui-cam" style="position:absolute;right:16px;bottom:14px;width:70px;height:92px;border-radius:8px;background:linear-gradient(145deg,#C9D6EA,#E7EDF7);opacity:0;transition:opacity .3s ease"></div>
          <div class="kui-recbar" style="position:absolute;left:50%;top:12px;transform:translateX(-50%);display:flex;align-items:center;gap:10px;padding:7px 12px;border-radius:20px;background:rgba(24,24,28,.86);color:#fff;font-size:11px;backdrop-filter:blur(10px);opacity:0;transition:opacity .3s ease">
            <span class="kui-reddot" style="width:8px;height:8px;border-radius:50%;background:#FF5F57;display:inline-block"></span>
            <span class="kui-timer">00:12</span><span style="opacity:.6">|</span><span>⏸</span><span>⏹</span>
          </div>
        </div>
        <div class="kui-wbody" style="padding:2px 14px 12px">
          <div class="kui-sect" style="padding:0">
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
  }
});
