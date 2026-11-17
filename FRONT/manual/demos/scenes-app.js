/* ============================================================
   Kitnest 手册 · 演示场景库 · 应用与维护（按需加载）
   ------------------------------------------------------------
   由 tools/split_manual_scenes.py 从 scenes.js 拆分生成。
   只有读者滚到本域的演示块时，demo.js 才会 fetch 这个文件；
   首屏不会加载全部场景。
   ============================================================ */
Object.assign(window.KDEMOS = window.KDEMOS || {}, {
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
});
