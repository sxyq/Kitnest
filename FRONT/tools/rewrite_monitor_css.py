#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""按真机 MonitorDetailView 写网页版监测页的样式。

配色取自真机截图：
  强调蓝 #2F6BFF（选中胶囊 / 曲线）、橙 #F5A623（电池 / 偏热）、
  绿 #3FCB7F（正常 / 读取）、红 #E8443B（过热 / 高占用）、
  紫 #A78BFA（联动）、灰底 rgba(0,0,0,.036)
分区小标题 = 居中灰字 + 两侧细线
"""
import io, os, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PATH = os.path.join(ROOT, 'assets', 'site.css')

s = io.open(PATH, encoding='utf-8').read()
anchor = '/* ---------- 监测 / 中转 / 投屏 页内元素 ---------- */'
if anchor not in s:
    sys.exit('锚点没找到')

BLOCK = u'''/* ---------- 性能监测页（真机 MonitorDetailView） ---------- */

/* 模块切换条：真机 FlowHStack，图标 + 文字，选中 accent 0.18 胶囊 + 描边 */
.pm-modbar {
  display: flex;
  gap: 6px;
  flex-wrap: wrap;
  margin: 12px 14px 0;
}
.pm-modbar button {
  display: inline-flex;
  align-items: center;
  gap: 4px;
  border: none;
  background: none;
  padding: 5px 8px;
  border-radius: 999px;
  font-size: 11px;
  font-weight: 500;
  color: var(--ink-2);
  cursor: pointer;
  transition: background 0.14s ease, color 0.14s ease;
}
.pm-modbar button svg { width: 12px; height: 12px; }
.pm-modbar button:hover { background: rgba(0, 0, 0, 0.04); }
.pm-modbar button.on {
  background: rgba(47, 107, 255, 0.18);
  color: var(--ink);
  box-shadow: inset 0 0 0 0.5px rgba(47, 107, 255, 0.5);
}

.pm-mod { padding: 0 14px; }

/* 环（真机的占用环） */
.mon-ring {
  position: relative;
  width: 84px;
  height: 84px;
  flex: 0 0 auto;
  display: inline-block;
}
.mon-ring svg { width: 100%; height: 100%; transform: rotate(-90deg); }
.mon-ring .ring-bg { fill: none; stroke: rgba(0, 0, 0, 0.07); stroke-width: 7; }
.mon-ring .ring-fg {
  fill: none;
  stroke: var(--ring-c, #2F6BFF);
  stroke-width: 7;
  stroke-linecap: round;
}
.mon-ring-in {
  position: absolute;
  inset: 0;
  display: flex;
  flex-direction: column;
  align-items: center;
  justify-content: center;
  gap: 1px;
}
.mon-ring-in b { font-size: 20px; font-weight: 620; color: var(--ink); line-height: 1; }
.mon-ring-in i { font-style: normal; font-size: 10.5px; color: var(--ink-3); }

/* 分区小标题：居中灰字 + 两侧细线 */
.mon-title {
  display: flex;
  align-items: center;
  gap: 10px;
  margin: 16px 0 10px;
  color: var(--ink-3);
  font-size: 11.5px;
}
.mon-title::before,
.mon-title::after {
  content: "";
  flex: 1;
  height: 0.5px;
  background: var(--line);
}
.mon-title span { flex: 0 0 auto; }

/* 键值行 */
.mon-rows { display: grid; gap: 7px; }
.mon-row {
  display: flex;
  align-items: baseline;
  justify-content: space-between;
  gap: 12px;
  font-size: 12px;
}
.mon-row .mon-k { color: var(--ink-2); }
.mon-row .mon-v { color: var(--ink); font-weight: 550; font-family: var(--mono); }
.mon-row .mon-v.red { color: #E8443B; }
.mon-row .mon-v.orange { color: #F5A623; }
.mon-row .mon-v.green { color: #1F9D63; }
.mon-row .mon-v.blue { color: #2F6BFF; }

/* 曲线 */
.mon-spark { display: block; width: 100%; height: 62px; }

/* 构成条 + 图例 */
.mon-segbar {
  display: flex;
  height: 10px;
  border-radius: 5px;
  overflow: hidden;
}
.mon-segbar i { display: block; height: 100%; }
.mon-legend {
  display: flex;
  gap: 12px;
  flex-wrap: wrap;
  margin-top: 8px;
  font-size: 10.5px;
  color: var(--ink-3);
}
.mon-legend span { display: inline-flex; align-items: center; gap: 4px; }
.mon-legend i { width: 6px; height: 6px; border-radius: 50%; }

/* 进程表 */
.mon-procs { display: grid; gap: 2px; }
.mon-proc-head {
  display: flex;
  gap: 10px;
  font-size: 10.5px;
  color: var(--ink-3);
  padding-bottom: 4px;
}
.mon-proc-head span:last-child { margin-left: auto; }
.mon-proc {
  display: flex;
  align-items: center;
  gap: 8px;
  padding: 4px 2px;
  font-size: 12px;
}
.mon-proc + .mon-proc { border-top: 0.5px solid rgba(0, 0, 0, 0.05); }
.mon-proc-ico {
  width: 16px;
  height: 16px;
  border-radius: 5px;
  flex: 0 0 auto;
  opacity: 0.85;
}
.mon-proc-name { min-width: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.mon-proc-name em { font-style: normal; font-size: 10.5px; color: var(--ink-3); }
.mon-proc-v { margin-left: auto; font-family: var(--mono); font-size: 11.5px; color: var(--ink); }
.mon-proc-x {
  width: 14px;
  height: 14px;
  border-radius: 50%;
  background: rgba(0, 0, 0, 0.09);
  color: #FFFFFF;
  font-size: 9px;
  display: inline-flex;
  align-items: center;
  justify-content: center;
  flex: 0 0 auto;
}

/* 通用小件 */
.mon-cap { display: block; font-size: 11px; color: var(--ink-3); }
.mon-cap.down { color: #2F6BFF; }
.mon-cap.up { color: #F5A623; }
.mon-big { display: block; font-size: 26px; font-weight: 650; color: var(--ink); letter-spacing: -0.02em; }
.mon-big.orange { color: #F5A623; }
.mon-note { font-size: 11px; color: var(--ink-3); margin: 8px 0 0; line-height: 1.55; }
.mon-sub {
  display: flex;
  align-items: baseline;
  justify-content: space-between;
  margin: 16px 0 6px;
  font-size: 12px;
  font-weight: 600;
  color: var(--ink-2);
}
.mon-sub-right { font-size: 11px; font-weight: 400; color: var(--ink-3); }
.mon-pressure {
  display: flex;
  align-items: baseline;
  justify-content: space-between;
  margin-top: 12px;
  font-size: 12px;
  color: var(--ink-2);
}
.mon-pressure b { font-size: 13px; font-weight: 600; color: var(--ink); }
.mon-pressure b.green { color: #1F9D63; }
.mon-progress {
  height: 9px;
  border-radius: 5px;
  background: rgba(0, 0, 0, 0.07);
  overflow: hidden;
  margin-top: 8px;
}
.mon-progress i { display: block; height: 100%; background: #F5A623; }
.mon-toggle {
  display: flex;
  align-items: center;
  justify-content: space-between;
  margin-top: 14px;
  font-size: 12.5px;
  font-weight: 550;
  color: var(--ink);
}
.mon-toggle i {
  width: 34px;
  height: 19px;
  border-radius: 999px;
  background: rgba(0, 0, 0, 0.13);
  position: relative;
}
.mon-toggle i::after {
  content: "";
  position: absolute;
  top: 2px;
  left: 2px;
  width: 15px;
  height: 15px;
  border-radius: 50%;
  background: #FFFFFF;
  box-shadow: 0 1px 2px rgba(0, 0, 0, 0.2);
}
.mon-links { display: grid; gap: 6px; margin-top: 12px; }
.mon-links a { font-size: 12px; color: #2F6BFF; cursor: pointer; }
.mon-links a:hover { text-decoration: underline; }

/* 功耗页 */
.mon-power-top { display: flex; align-items: center; gap: 14px; padding-top: 12px; }
.mon-bolt {
  width: 42px;
  height: 42px;
  display: inline-flex;
  align-items: center;
  justify-content: center;
}
.mon-bolt svg { width: 30px; height: 30px; }
.mon-flow {
  display: flex;
  align-items: stretch;
  gap: 6px;
  background: rgba(255, 255, 255, 0.62);
  border: 0.5px solid rgba(0, 0, 0, 0.05);
  border-radius: 12px;
  padding: 12px;
}
.mon-flow-src {
  flex: 0 0 84px;
  display: flex;
  flex-direction: column;
  align-items: center;
  justify-content: center;
  gap: 2px;
  background: #FFFFFF;
  border-radius: 10px;
  text-align: center;
}
.mon-flow-src b { font-size: 15px; font-weight: 650; color: #F5A623; }
.mon-flow-src span { font-size: 10.5px; color: var(--ink-3); }
.mon-flow.net .mon-flow-src b { color: #2F6BFF; }
.mon-flow-band { flex: 1 1 auto; min-width: 40px; height: 90px; }
.mon-flow-dst { flex: 0 0 118px; display: grid; gap: 6px; }
.mon-flow-card {
  border-radius: 9px;
  padding: 7px 9px;
  background: rgba(234, 241, 255, 0.75);
  display: grid;
  grid-template-columns: 16px 1fr;
  grid-template-rows: auto auto;
  column-gap: 6px;
  align-items: center;
}
.mon-flow-card.blue { background: rgba(234, 241, 255, 0.85); }
.mon-flow-card.purple { background: rgba(243, 238, 255, 0.85); }
.mon-flow-ico { grid-row: 1 / 3; font-size: 12px; }
.mon-flow-card b { font-size: 13px; font-weight: 620; color: var(--ink); }
.mon-flow-card i { font-style: normal; font-size: 10px; color: var(--ink-3); }

/* 电池页 */
.mon-batt-top { display: flex; align-items: center; gap: 14px; padding-top: 14px; }
.mon-batt-cap b { display: block; font-size: 15px; font-weight: 600; color: var(--ink); }
.mon-batt-cap span { font-size: 11.5px; color: var(--ink-3); }
.mon-batt-health {
  display: flex;
  align-items: flex-end;
  justify-content: space-between;
  margin-top: 18px;
}

/* CPU 页 */
.mon-cpu-top { display: flex; align-items: center; gap: 14px; padding-top: 14px; }
.mon-cpu-kv, .mon-mem-kv, .mon-gpu-top .mon-mem-kv {
  flex: 1;
  min-width: 0;
  display: grid;
  gap: 5px;
}
.mon-cpu-kv > div, .mon-mem-kv > div {
  display: flex;
  align-items: baseline;
  justify-content: space-between;
  gap: 8px;
  font-size: 11.5px;
}
.mon-cpu-kv span, .mon-mem-kv span { color: var(--ink-3); }
.mon-cpu-kv b, .mon-mem-kv b { font-weight: 600; color: var(--ink); }
.mon-cpu-kv b.red { color: #E8443B; }
.mon-cpu-kv b.blue { color: #2F6BFF; }
.mon-mem-kv b.orange { color: #F5A623; }
.mon-mem-kv b.green { color: #1F9D63; }
.mon-mem-kv b.blue { color: #2F6BFF; }
.mon-chip-row {
  display: flex;
  align-items: center;
  gap: 6px;
  margin-top: 16px;
  font-size: 11.5px;
  color: var(--ink-2);
}
.mon-chip-ico { color: var(--ink-3); }
.mon-thermal {
  margin-left: auto;
  background: rgba(245, 166, 35, 0.16);
  color: #D97706;
  border-radius: 999px;
  padding: 2px 8px;
  font-size: 10.5px;
}
.mon-hist-head {
  display: flex;
  justify-content: space-between;
  align-items: baseline;
  font-size: 11.5px;
  color: var(--ink-3);
  margin-bottom: 4px;
}
.mon-hist-head .blue { color: #2F6BFF; font-weight: 600; }
.mon-cores {
  display: grid;
  grid-template-columns: repeat(5, 1fr);
  gap: 10px 8px;
}
.mon-core { text-align: center; }
.mon-core-box {
  height: 34px;
  border-radius: 4px;
  background: rgba(0, 0, 0, 0.06);
}
.mon-core-box.hot { background: #E8443B; }
.mon-core span { display: block; font-size: 10.5px; color: var(--ink-3); margin-top: 4px; }
.mon-core b { display: block; font-size: 11px; font-weight: 550; }
.mon-core b.red { color: #E8443B; }
.mon-clusters { display: flex; gap: 8px; margin-top: 14px; }
.mon-clusters > div {
  flex: 1;
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 6px;
  background: rgba(234, 241, 255, 0.8);
  border-radius: 8px;
  padding: 6px 9px;
  font-size: 11px;
  color: var(--ink-2);
}
.mon-clusters span { display: inline-flex; align-items: center; gap: 5px; }
.mon-clusters i { width: 6px; height: 6px; border-radius: 50%; }
.mon-clusters b { color: #2F6BFF; font-weight: 620; }

/* 内存页 */
.mon-mem-top { display: flex; align-items: center; gap: 14px; padding-top: 14px; }
.mon-memory-cta {
  display: flex;
  align-items: center;
  justify-content: space-between;
  margin-top: 14px;
  font-size: 12px;
  font-weight: 550;
  color: var(--ink);
}
.mon-memory-cta span { display: inline-flex; align-items: center; gap: 6px; }
.mon-memory-cta span i { width: 6px; height: 6px; border-radius: 50%; background: #3FCB7F; }
.mon-memory-cta button {
  border: none;
  background: #2F6BFF;
  color: #FFFFFF;
  border-radius: 7px;
  padding: 5px 11px;
  font-size: 11.5px;
  cursor: pointer;
  font-family: inherit;
}
.mon-memory-cta button:hover { background: #2560E8; }

/* 网络页 */
.mon-net-card {
  margin-top: 12px;
  background: rgba(255, 255, 255, 0.66);
  border: 0.5px solid rgba(0, 0, 0, 0.05);
  border-radius: 12px;
  padding: 11px 12px;
}
.mon-net-top { display: flex; gap: 22px; }
.mon-net-top b { display: block; font-size: 19px; font-weight: 620; color: var(--ink); }
.mon-net-chart { margin-top: 8px; }
.mon-net-chart .mon-spark { height: 74px; }
.mon-net-legend {
  display: flex;
  justify-content: space-between;
  font-size: 10px;
  color: var(--ink-3);
}
.mon-net-state { display: flex; align-items: center; gap: 6px; font-size: 12px; color: var(--ink-2); }
.dot-red { width: 8px; height: 8px; border-radius: 50%; background: #E8443B; }
.mon-pinggrid {
  display: grid;
  grid-template-columns: repeat(30, 1fr);
  gap: 2px;
  margin-top: 10px;
}
.mon-pinggrid i { height: 10px; border-radius: 2px; background: rgba(0, 0, 0, 0.08); }
.mon-pinggrid i.green { background: #3FCB7F; }
.mon-pinggrid i.orange { background: #F5A623; }
.mon-pinggrid i.red { background: #E8443B; }

/* 磁盘页 */
.mon-disk-chart { margin-bottom: 4px; }
.mon-disk-two { display: flex; justify-content: space-between; font-size: 11.5px; }
.mon-disk-two .green { color: #1F9D63; }
.mon-disk-two .red { color: #E8443B; }
.mon-disk-two span:last-child { margin-left: auto; }

/* 温度页 */
.mon-zones { display: grid; gap: 9px; }
.mon-zone {
  display: grid;
  grid-template-columns: 16px 42px 1fr 40px;
  align-items: center;
  gap: 8px;
  font-size: 12px;
}
.mon-zone-ico { font-size: 12px; text-align: center; }
.mon-zone-ico.cpu { color: #E8443B; }
.mon-zone-ico.gpu { color: #F5A623; }
.mon-zone-ico.batt { color: #3FCB7F; }
.mon-zone-name { color: var(--ink-2); }
.mon-zone-bar {
  height: 8px;
  border-radius: 4px;
  background: rgba(0, 0, 0, 0.07);
  overflow: hidden;
  display: block;
}
.mon-zone-bar i { display: block; height: 100%; border-radius: 4px; }
.mon-zone-bar i.hot { background: #E8443B; }
.mon-zone-bar i.warm { background: #F5A623; }
.mon-zone-bar i.cool { background: #3FCB7F; }
.mon-zone b { text-align: right; font-weight: 600; }
.mon-zone b.red { color: #E8443B; }
.mon-zone b.orange { color: #F5A623; }
.mon-zone b.green { color: #1F9D63; }
.mon-disclosure {
  margin-top: 12px;
  font-size: 12px;
  color: var(--ink-2);
  cursor: pointer;
}

/* GPU 页 */
.mon-gpu-top { display: flex; align-items: center; gap: 14px; padding-top: 14px; }

/* 底部栏（真机 footer） */
.pm-modfoot {
  display: flex;
  align-items: center;
  justify-content: space-between;
  margin: 16px 14px 0;
  padding-top: 10px;
  border-top: 0.5px solid var(--line);
  font-size: 11px;
  color: var(--ink-3);
}
.pm-modfoot-ico { display: flex; gap: 10px; }
.pm-modfoot-ico button {
  width: 20px;
  height: 20px;
  border: none;
  background: none;
  padding: 0;
  cursor: pointer;
  color: var(--ink-3);
  display: inline-flex;
  align-items: center;
  justify-content: center;
  border-radius: 5px;
}
.pm-modfoot-ico button svg { width: 15px; height: 15px; }
.pm-modfoot-ico button:hover { color: var(--ink); background: rgba(0, 0, 0, 0.05); }

'''

s = s.replace(anchor, BLOCK + anchor)
io.open(PATH, 'w', encoding='utf-8').write(s)
print('监测页样式已写入，CSS %d 行' % len(s.split('\n')))
