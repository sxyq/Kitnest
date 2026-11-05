/* v230 演示动图录制：只用页面里真实渲染的 DOM 交互，不做任何手绘 UI。
   用法：node FRONT/tools/record_demos.mjs [BASE_URL] [OUT_DIR]
   输出：OUT_DIR/<name>/000.png ... 由 build_demo_gifs.py 合成统一节奏的 GIF。 */
import { createRequire } from 'node:module';
import { existsSync, readdirSync, mkdirSync } from 'node:fs';
import { join } from 'node:path';
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
const OUT = process.argv[3] || '/tmp/kitnest-demo-frames';
mkdirSync(OUT, { recursive: true });

const browser = await chromium.launch({ executablePath: EXEC });
const page = await browser.newPage({ viewport: { width: 1440, height: 900 }, deviceScaleFactor: 2 });
page.on('pageerror', e => console.log('pageerror', e.message));
await page.goto(BASE, { waitUntil: 'networkidle' });
await page.waitForTimeout(700); // 等首屏入场动画结束

async function ensurePanel() {
  if (await page.evaluate(() => document.getElementById('panelMock').hidden)) {
    await page.click('#mbIcon');
    await page.waitForTimeout(320);
  }
}
async function shot(dir, i, mode) {
  const path = join(dir, String(i).padStart(3, '0') + '.png');
  if (mode === 'stage') {
    // 只截「面板 + 预览浮层」的并集，不把舞台左侧那片空白带进 GIF
    const clip = await page.evaluate(() => {
      const p = document.getElementById('panelMock').getBoundingClientRect();
      const v = document.getElementById('pmPreview');
      const r = (v && !v.hidden) ? v.getBoundingClientRect() : null;
      const left = r ? Math.min(p.left, r.left) : p.left;
      const top = Math.min(p.top, r ? r.top : p.top);
      const bottom = Math.max(p.bottom, r ? r.bottom : p.bottom);
      const pad = 12;
      return { x: Math.max(0, left - pad), y: Math.max(0, top - pad),
               width: p.right - left + pad * 2, height: bottom - top + pad * 2 };
    });
    await page.screenshot({ path, clip });
  } else {
    const el = await page.$('#panelMock');
    await el.screenshot({ path });
  }
}
async function seq(name, steps, mode) {
  const dir = join(OUT, name);
  mkdirSync(dir, { recursive: true });
  let i = 0;
  for (const fn of steps) {
    await fn();
    await page.waitForTimeout(160);
    await shot(dir, i++, mode);
  }
  console.log(name, i, 'frames', mode);
}

const hoverItem = id => page.evaluate(id => {
  const li = document.querySelector('.pm-item[data-id="' + id + '"]');
  if (li) li.dispatchEvent(new MouseEvent('mouseover', { bubbles: true }));
}, id);
const clickIf = sel => page.evaluate(sel => {
  const el = document.querySelector(sel);
  if (el) el.click();
}, sel);
const switchPage = p => page.evaluate(p => {
  const b = document.querySelector('.pm-seg[data-page="' + p + '"]');
  if (b) b.click();
}, p);
const switchMod = m => page.evaluate(m => {
  const b = document.querySelector('#pmModBar button[data-mod="' + m + '"]');
  if (b) b.click();
}, m);
const scrollBody = n => page.evaluate(n => {
  const b = document.getElementById('pmBody');
  if (b) b.scrollTop = n;
}, n);

/* 1. 剪贴板：每一帧都带预览浮层，左侧不会空一大片 */
await ensurePanel();
await switchPage('home');
await page.waitForTimeout(200);
await seq('clipboard', [
  () => hoverItem('c3'),
  () => clickIf('#pmPreview [data-md-target="pv-h-2"]'),
  () => hoverItem('c4'),
  () => hoverItem('c5'),
  () => hoverItem('c7'),
  () => clickIf('#pmPreview [data-pv-act="ocr"]'),
  () => clickIf('#pmPreview [data-pv-tab="trans"]'),
  () => clickIf('#pmPreview [data-pv-act="copy"]'),
], 'stage');

/* 2. 系统监控：切页 → 八个模块依次 */
await seq('monitor', [
  () => switchPage('monitor'),
  () => switchMod('cpu'),
  () => switchMod('memory'),
  () => switchMod('network'),
  () => switchMod('disk'),
  () => switchMod('sensors'),
  () => switchMod('battery'),
  () => switchMod('gpu'),
  () => switchMod('power'),
  () => switchMod('cpu'),
]);

/* 2b. 主面板界面：四个分段真实切换。
   v238：改成只截 #panelMock。旧版截「面板 + 左侧预览浮层」的并集，
   中间那片空隙会被一起录进去，放进「界面一览」缩略格就是一大块白；
   预览浮层的交互已由 demo-clipboard.gif 承担，这里专心展示四个页签。 */
await seq('view-panel', [
  () => switchPage('home'),
  () => switchPage('monitor'),
  () => switchPage('transfer'),
  () => switchPage('cast'),
  () => hoverItem('c3'),
  () => switchPage('home'),
], 'panel');

/* 3. 文件中转：这三个出口按钮内容不可滚动，用真实 hover + 页签切换产生变化 */
const hoverNth = (sel, n) => page.locator(sel).nth(n)
  .hover({ timeout: 3000 }).catch(() => {});
await seq('transfer', [
  () => switchPage('transfer'),
  () => hoverNth('.pm-page:not([hidden]) .pm-exit', 0),
  () => hoverNth('.pm-page:not([hidden]) .pm-exit', 1),
  () => hoverNth('.pm-page:not([hidden]) .pm-exit', 2),
  () => switchPage('home'),
  () => switchPage('monitor'),
  () => switchPage('transfer'),
]);

/* 4. 安卓投屏 */
await seq('cast', [
  () => switchPage('cast'),
  () => hoverNth('.pm-page:not([hidden]) button', 0),
  () => hoverNth('.pm-page:not([hidden]) button', 1),
  () => hoverNth('.pm-page:not([hidden]) button', 2),
  () => hoverNth('.pm-page:not([hidden]) button', 3),
  () => switchPage('home'),
  () => switchPage('cast'),
]);

/* 5. 工具箱：搜索框 / 命令 → 普通关键词 */
await seq('toolbox', [
  () => switchPage('home'),
  () => page.evaluate(() => { const i = document.getElementById('pmSearch'); i.value = '/'; i.dispatchEvent(new Event('input', { bubbles: true })); }),
  () => page.evaluate(() => { const i = document.getElementById('pmSearch'); i.value = '/hash'; i.dispatchEvent(new Event('input', { bubbles: true })); }),
  () => page.evaluate(() => { const i = document.getElementById('pmSearch'); i.value = '周报'; i.dispatchEvent(new Event('input', { bubbles: true })); }),
  () => page.evaluate(() => { const i = document.getElementById('pmSearch'); i.value = ''; i.dispatchEvent(new Event('input', { bubbles: true })); }),
  () => hoverItem('c2'),
  () => switchPage('home'),
]);

/* 6. 截图标注：首屏没有标注界面，用真机实拍的标注编辑器截图导览（真实 UI） */
// 由 build_demo_gifs.py 直接用 FRONT/assets/shots/annotate.png 生成，不在这里截帧。

console.log('frames ready at', OUT);
await browser.close();
