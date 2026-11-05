/* v233 流向图 1:1 守卫。
   真源：apps/FrsetNext/Sources/Features/Monitor/Views/MonitorFlow.swift
   用法：node FRONT/tools/verify_flow.mjs [BASE_URL] [SHOT_DIR]
   校验 Swift 常量未被改动，且网页渲染的几何 / 配色 / 字号 / 文案与之逐项一致。
   给了 SHOT_DIR 会额外输出 network / power 两页的面板截图。 */
import { createRequire } from 'node:module';
import { existsSync, readdirSync, mkdirSync, readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
const require = createRequire(import.meta.url);
const HOME = process.env.HOME || '';
let PW = null, EXEC = null;
const npx = join(HOME, '.npm/_npx');
if (existsSync(npx)) for (const d of readdirSync(npx)) {
  const p = join(npx, d, 'node_modules/playwright-core');
  if (existsSync(p)) { PW = p; break; }
}
const mp = join(HOME, 'Library/Caches/ms-playwright');
if (existsSync(mp)) for (const d of readdirSync(mp)) {
  const p = join(mp, d, 'chrome-mac-arm64/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing');
  if (existsSync(p)) { EXEC = p; break; }
}
if (!PW || !EXEC) { console.error('缺少 playwright-core / Chrome for Testing'); process.exit(2); }
const { chromium } = require(PW);

const BASE = process.argv[2] || 'http://127.0.0.1:5173/';
const SHOTS = process.argv[3] || '';
const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..', '..');
const VIEW_DIR = join(ROOT, 'apps/FrsetNext/Sources/Features/Monitor/Views');
// FlowRibbon 的几何在 BatteryPanel.swift，卡片/分支在 MonitorFlow.swift
const src = readFileSync(join(VIEW_DIR, 'MonitorFlow.swift'), 'utf8')
  + '\n' + readFileSync(join(VIEW_DIR, 'BatteryPanel.swift'), 'utf8');

let pass = 0, fail = 0;
const check = (name, ok, got) => {
  if (ok) { pass++; console.log('  ok   ' + name); }
  else { fail++; console.log('  FAIL ' + name + '  →  ' + JSON.stringify(got)); }
};
const has = (re, label) => check('Swift 真源 ' + label, re.test(src), re.source);

console.log('\n=== 流向图 1:1 守卫 · ' + BASE + ' ===');
console.log('-- Swift 常量 --');
has(/tileSpacing: CGFloat = 4\b/, '分支间距 4');
has(/maxBand: CGFloat = 34\b/, '流带最大厚度 34');
has(/minTileHeight: CGFloat = 34\b/, '分支最小格高 34');
has(/height: CGFloat = 116\b/, '卡片基准高 116');
has(/\.frame\(width: 88, height: min\(resolvedHeight, 136\)\)/, '来源格 88 / 上限 136');
has(/\.frame\(width: 134\)/, '分支列 134');
has(/let gap: CGFloat = 2\b/, '流带间距 2');
has(/max\(2, band\.width \* 0\.88\)/, '末端厚度 0.88');
has(/x0 \+ rect\.width \* 0\.45/, '贝塞尔控制点 0.45');
has(/x1 - rect\.width \* 0\.35/, '贝塞尔控制点 0.35');
has(/i == 0 \? -4 : 4/, 'bend 首条 -4 / 其余 4');
has(/node\.color\.opacity\(0\.72\)/, '流带渐变 0.72');
has(/node\.color\.opacity\(0\.42\)/, '流带渐变 0.42');
has(/node\.color\.opacity\(0\.22\)/, '发丝描边 0.22');
has(/node\.color\.opacity\(0\.16\)/, '分支底色 0.16');
has(/node\.color\.opacity\(0\.06\)/, '分支底色 0.06');
has(/size: input\.compactValue \? 12\.5 : 15/, '来源数值 12.5 / 15');
has(/size: node\.compactValue \? 10\.5 : 13/, '分支数值 10.5 / 13');
has(/size: 9\.5/, '节点名 9.5');
has(/frame\(width: 4, height: 4\)/, '活跃圆点 4');
has(/glassCard\(radius: 10\)/, '卡片圆角 10');

const browser = await chromium.launch({ executablePath: EXEC });
const page = await browser.newPage({ viewport: { width: 1440, height: 900 }, deviceScaleFactor: 2 });
const errors = [];
page.on('pageerror', e => errors.push(e.message));
// 线上有长连接资源，networkidle 偶发等不到；DOM 就绪后等脚本渲染完成即可
await page.goto(BASE, { waitUntil: 'domcontentloaded', timeout: 30000 });
await page.waitForTimeout(800);
await page.evaluate(() => document.querySelector('.pm-seg[data-page="monitor"]').click());
await page.waitForTimeout(120);

async function snapshot(mod) {
  await page.evaluate(m => document.querySelector('#pmModBar button[data-mod="' + m + '"]').click(), mod);
  await page.waitForTimeout(150);
  return page.evaluate(() => {
    const card = document.querySelector('.pm-page:not([hidden]) .mf-card');
    if (!card) return null;
    const cs = getComputedStyle(card);
    const srcEl = card.querySelector('.mf-src');
    const srcIn = card.querySelector('.mf-src-in');
    const dst = card.querySelector('.mf-dst');
    const tiles = [...card.querySelectorAll('.mf-tile')];
    const svg = card.querySelector('.mf-ribbon svg');
    const paths = [...svg.querySelectorAll('path')];
    const grad = svg.querySelector('linearGradient');
    const cov = card.parentElement.querySelector('.mf-coverage');
    const box = el => { const r = el.getBoundingClientRect(); return { w: +r.width.toFixed(2), h: +r.height.toFixed(2) }; };
    return {
      compact: card.classList.contains('mf-compact'),
      radius: cs.borderRadius, padding: cs.paddingTop,
      cardH: box(card).h,
      srcW: box(srcEl).w, srcInH: box(srcIn).h,
      dstW: box(dst).w, dstGap: getComputedStyle(dst).rowGap,
      tileH: tiles.map(t => box(t).h),
      srcFont: getComputedStyle(card.querySelector('.mf-src-in b')).fontSize,
      srcColor: getComputedStyle(card.querySelector('.mf-src-in b')).color,
      tileFont: getComputedStyle(card.querySelector('.mf-tile-top b')).fontSize,
      nameFont: getComputedStyle(card.querySelector('.mf-tile-name')).fontSize,
      tileBg: tiles[0] && getComputedStyle(tiles[0]).backgroundImage,
      tileBorder: tiles[0] && getComputedStyle(tiles[0]).borderTopColor,
      viewBox: svg.getAttribute('viewBox'),
      d0: paths[0] && paths[0].getAttribute('d'),
      pathCount: paths.length,
      stopOpacity: grad && [...grad.querySelectorAll('stop')].map(s => s.getAttribute('stop-opacity')),
      strokeOpacity: paths[0] && paths[0].getAttribute('stroke-opacity'),
      liveDots: card.querySelectorAll('.mf-live').length,
      names: [...card.querySelectorAll('.mf-tile-name')].map(e => e.textContent),
      coverage: cov ? cov.textContent : null,
      scrollWidth: card.scrollWidth, clientWidth: card.clientWidth,
      legacy: !!document.querySelector('.mon-flow')
    };
  });
}

const net = await snapshot('network');
console.log('-- 网络「流量去哪了」 --');
check('卡片已渲染且不残留旧 .mon-flow', !!net && !net.legacy, net && net.legacy);
if (net) {
  check('卡片圆角 10 / padding 8', net.radius === '10px' && net.padding === '8px', [net.radius, net.padding]);
  check('总高 = 148 + 16', Math.abs(net.cardH - 164) < 1.5, net.cardH);
  check('来源格 88 / 分支列 134 / 间距 4', net.srcW === 88 && net.dstW === 134 && net.dstGap === '4px', [net.srcW, net.dstW, net.dstGap]);
  check('来源格高 min(148,136)=136', Math.abs(net.srcInH - 136) < 1.5, net.srcInH);
  check('4 个分支格高 34', net.tileH.length === 4 && net.tileH.every(h => Math.abs(h - 34) < 1.5), net.tileH);
  check('4 条流带 / viewBox 0 0 100 148', net.pathCount === 4 && net.viewBox === '0 0 100 148', [net.pathCount, net.viewBox]);
  check('流带渐变 0.72→0.42 + 描边 0.22', JSON.stringify(net.stopOpacity) === '["0.72","0.42"]' && net.strokeOpacity === '0.22', [net.stopOpacity, net.strokeOpacity]);
  // 按 Swift 公式独立推导首条流带路径
  const H = 148, maxV = 239, w = Math.max(2, 141 / maxV * 34);
  const widths = [w, Math.max(2, 50.2 / maxV * 34), Math.max(2, 23.9 / maxV * 34), Math.max(2, 23.9 / maxV * 34)];
  const total = widths.reduce((a, b) => a + b, 0) + 2 * 3;
  const cursor = H / 2 - total / 2, start = cursor + w / 2;
  const ew = Math.max(2, w * 0.88), end = 17, bend = -4;
  const f = v => v.toFixed(2);
  const expect = 'M0 ' + f(start - w / 2) + ' C45 ' + f(start - w / 2 + bend)
    + ' 65 ' + f(end - ew / 2 + bend) + ' 100 ' + f(end - ew / 2)
    + ' L100 ' + f(end + ew / 2) + ' C65 ' + f(end + ew / 2 + bend)
    + ' 45 ' + f(start + w / 2 + bend) + ' 0 ' + f(start + w / 2) + ' Z';
  check('首条流带贝塞尔几何与 Swift 公式一致', net.d0 === expect, [net.d0, expect]);
  check('compact 字号 12.5 / 10.5 / 9.5', net.compact && net.srcFont === '12.5px' && net.tileFont === '10.5px' && net.nameFont === '9.5px', [net.srcFont, net.tileFont, net.nameFont]);
  check('来源色 = MonitorColors.download', net.srcColor === 'rgb(77, 179, 230)', net.srcColor);
  check('分支底色 0.16→0.06 / 发丝边 0.22', /0\.16/.test(net.tileBg) && /0\.06/.test(net.tileBg) && /0\.22/.test(net.tileBorder), [net.tileBg, net.tileBorder]);
  check('活跃圆点 / 分支名 / 覆盖率文案', net.liveDots === 2 && net.names.join(',') === 'verge-mihomo,WorkBuddy,python3.10,adb' && net.coverage === '最近 10 分钟', [net.liveDots, net.names, net.coverage]);
  check('无横向溢出', net.scrollWidth <= net.clientWidth + 2, [net.scrollWidth, net.clientWidth]);
}

const power = await snapshot('power');
console.log('-- 功耗「电源流向」 --');
check('功耗页复用同一张流向图', !!power, null);
if (power) {
  check('2 个分支 / viewBox 0 0 100 116', power.pathCount === 2 && power.viewBox === '0 0 100 116', [power.pathCount, power.viewBox]);
  check('非 compact 字号 15 / 13', !power.compact && power.srcFont === '15px' && power.tileFont === '13px', [power.compact, power.srcFont, power.tileFont]);
  check('来源格高 min(116,136)=116', Math.abs(power.srcInH - 116) < 1.5, power.srcInH);
  check('无横向溢出', power.scrollWidth <= power.clientWidth + 2, [power.scrollWidth, power.clientWidth]);
}

if (SHOTS) {
  mkdirSync(SHOTS, { recursive: true });
  await page.evaluate(() => document.querySelector('#pmModBar button[data-mod="network"]').click());
  await page.waitForTimeout(150);
  await (await page.$('#panelMock')).screenshot({ path: join(SHOTS, 'flow-network.png') });
  await page.evaluate(() => document.querySelector('#pmModBar button[data-mod="power"]').click());
  await page.waitForTimeout(150);
  await (await page.$('#panelMock')).screenshot({ path: join(SHOTS, 'flow-power.png') });
  console.log('截图 → ' + SHOTS);
}

check('无页面脚本错误', errors.length === 0, errors);
await browser.close();
console.log('\n结果：' + pass + ' 通过 / ' + fail + ' 失败\n');
process.exit(fail ? 1 : 0);
