#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""按真机 MonitorDetailView 逐模块还原网页版监测页。

真机依据（apps/FrsetNext/Sources/Features/Monitor/Views/MonitorDetailView.swift
与实机截图 /tmp/kitnest_shots/mod_*.png）：
  模块顺序 = 功耗 / 电池 / CPU / 内存 / 网络 / 磁盘 / 温度 / GPU（MonitorModuleID）
  切换条 = 图标 + 文字，选中 accent 0.18 胶囊 + accent 0.5 描边
  每个模块：环/条 + 键值行 + 分区小标题（居中灰字，两侧细线）+ 曲线/进程表
  底部栏 = 刷新间隔 6.5s + 刷新 / 调节 / 设置 三个图标
"""
import io, os, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PATH = os.path.join(ROOT, 'assets', 'site.js')

s = io.open(PATH, encoding='utf-8').read()
anchor = '  /* ---------------- 分段切换（真机 pageSegments） ---------------- */'
if anchor not in s:
    sys.exit('锚点没找到')

BLOCK = u'''  /* ---------------- 性能监测页（真机 MonitorDetailView 逐模块还原） ---------------- */

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
        + '<div class="mon-flow"><div class="mon-flow-src"><b>26.24 W</b><span>电池放电</span></div>'
        + '<svg class="mon-flow-band" viewBox="0 0 120 90" preserveAspectRatio="none">'
        + '<path d="M0 32 C30 32 34 12 60 12 L120 12 L120 52 C60 52 34 34 0 34 Z" fill="#A9C4F7"/>'
        + '<path d="M0 62 C30 62 34 72 60 72 L120 72 L120 58 C60 58 34 66 0 66 Z" fill="#C9B6F2"/>'
        + "</svg>"
        + '<div class="mon-flow-dst">'
        + '<div class="mon-flow-card blue"><span class="mon-flow-ico">🖥</span><b>26.24 W</b><i>系统供电</i></div>'
        + '<div class="mon-flow-card purple"><span class="mon-flow-ico">🔌</span><b>1.25 W</b><i>USB</i></div>'
        + "</div></div>"
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
        + '<div class="mon-flow net"><div class="mon-flow-src"><b>239 MB</b><span>合计</span></div>'
        + '<svg class="mon-flow-band" viewBox="0 0 120 90" preserveAspectRatio="none">'
        + '<path d="M0 24 C30 24 34 12 60 12 L120 12 L120 40 C60 40 34 28 0 28 Z" fill="#A9C4F7"/>'
        + '<path d="M0 48 C30 48 34 44 60 44 L120 44 L120 58 C60 58 34 52 0 52 Z" fill="#F5C9A9"/>'
        + '<path d="M0 66 C30 66 34 62 60 62 L120 62 L120 72 C60 72 34 68 0 68 Z" fill="#F0D79A"/>'
        + '<path d="M0 80 C30 80 34 78 60 78 L120 78 L120 88 C60 88 34 84 0 84 Z" fill="#C9B6F2"/>'
        + "</svg>"
        + '<div class="mon-flow-dst">'
        + '<div class="mon-flow-card"><span class="mon-flow-ico">📄</span><b>141 MB</b><i>verge-mihomo</i></div>'
        + '<div class="mon-flow-card"><span class="mon-flow-ico">📱</span><b>50.2 MB</b><i>WorkBuddy</i></div>'
        + '<div class="mon-flow-card"><span class="mon-flow-ico">🐍</span><b>23.9 MB</b><i>python3.10</i></div>'
        + '<div class="mon-flow-card"><span class="mon-flow-ico">⬛</span><b>23.9 MB</b><i>adb</i></div>'
        + "</div></div>"
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
  }

  var pmModBar = $("#pmModBar");
  if (pmModBar) {
    pmModBar.addEventListener("click", function (e) {
      var b = e.target.closest("button[data-mod]");
      if (!b) return;
      switchMonitorModule(b.getAttribute("data-mod"));
    });
  }

'''

s = s.replace(anchor, BLOCK + anchor)
io.open(PATH, 'w', encoding='utf-8').write(s)
print('监测页逻辑已写入，JS %d 行' % len(s.split('\n')))
