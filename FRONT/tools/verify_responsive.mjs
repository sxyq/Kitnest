/* v231 多尺寸响应式回归：17 档宽度 × 7 个视图。
   用法：node FRONT/tools/verify_responsive.mjs [BASE_URL]
   断言：无横向溢出、无越界元素、无文本裁切；每级列数 / 导航 / 预览堆叠
   符合断点约定；主标题字号随宽度变窄单调不增。
   失败退出码 1。 */
import { createRequire } from 'node:module';
import { existsSync, readdirSync } from 'node:fs';
import { join } from 'node:path';
const require = createRequire(import.meta.url);
const H = process.env.HOME || '';
let PW = null, EXEC = null;
const npx = join(H, '.npm/_npx');
if (existsSync(npx)) for (const d of readdirSync(npx)) {
  const p = join(npx, d, 'node_modules/playwright-core');
  if (existsSync(p)) { PW = p; break; }
}
const mp = join(H, 'Library/Caches/ms-playwright');
if (existsSync(mp)) for (const d of readdirSync(mp)) {
  const p = join(mp, d, 'chrome-mac-arm64/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing');
  if (existsSync(p)) { EXEC = p; break; }
}
if (!PW || !EXEC) { console.error('缺少 playwright-core / Chrome for Testing'); process.exit(2); }
const { chromium } = require(PW);

const BASE = process.argv[2] || 'http://127.0.0.1:5173/';
const WIDTHS = [1440, 1280, 1180, 1100, 1024, 960, 900, 820, 768, 720, 700, 640, 560, 480, 430, 390, 360];
const VIEWS = ['home', 'features', 'showcase', 'download', 'changelog', 'help', 'privacy'];

function grade(w) {
  if (w >= 1100) return { g3: 3, nav: 'links', stack: false };
  if (w > 900) return { g3: 2, nav: 'links', stack: false };
  if (w > 700) return { g3: 2, nav: 'toggle', stack: false };
  return { g3: 1, nav: 'toggle', stack: true };
}

const browser = await chromium.launch({ executablePath: EXEC });
const page = await browser.newPage({ viewport: { width: 1440, height: 900 } });
const errors = [];
page.on('pageerror', e => errors.push(e.message));
await page.goto(BASE, { waitUntil: 'networkidle' });
await page.waitForTimeout(700);

let pass = 0, fail = 0;
const h1Sizes = [];
console.log('\n=== 响应式分级回归 · ' + BASE + ' ===');
console.log('宽度   列数 导航   预览   溢出 越界 裁切  h1');
for (const w of WIDTHS) {
  const g = grade(w);
  await page.setViewportSize({ width: w, height: 900 });
  await page.waitForTimeout(90);

  // 布局参数（在首页读）
  await page.evaluate(() => { location.hash = '#home'; window.scrollTo(0, 0); });
  await page.waitForTimeout(70);
  const layout = await page.evaluate(() => {
    const cols = s => {
      const e = document.querySelector(s);
      if (!e) return 0;
      const v = getComputedStyle(e).gridTemplateColumns;
      return v === 'none' ? 0 : v.trim().split(/\s+/).length;
    };
    const pm = document.getElementById('pmPreview');
    const stage = document.querySelector('.hero-stage');
    const h1 = document.querySelector('.hero-copy h1');
    const navLinks = document.querySelector('.nav-links');
    const toggle = document.getElementById('navToggle');
    return {
      g3: cols('.grid-3'),
      navLinks: navLinks ? getComputedStyle(navLinks).display !== 'none' : false,
      toggle: toggle ? getComputedStyle(toggle).display !== 'none' : false,
      stack: pm ? getComputedStyle(pm).position === 'relative' : false,
      previewRight: pm ? Math.round(pm.getBoundingClientRect().right) : 0,
      stageRight: stage ? Math.round(stage.getBoundingClientRect().right) : 0,
      h1: h1 ? parseFloat(getComputedStyle(h1).fontSize) : 0,
    };
  });
  h1Sizes.push({ w, size: layout.h1 });

  // 移动导航在该宽度下必须真的能展开
  let navOK = true;
  if (g.nav === 'toggle' && layout.toggle) {
    await page.click('#navToggle');
    await page.waitForTimeout(60);
    navOK = await page.evaluate(() =>
      getComputedStyle(document.getElementById('mobileMenu')).display !== 'none');
    await page.click('#navToggle');
    await page.waitForTimeout(40);
  }

  // 逐视图溢出 / 越界 / 裁切
  let overflow = 0, outOfView = 0, clipped = 0;
  for (const v of VIEWS) {
    await page.evaluate(v => { location.hash = '#' + v; window.scrollTo(0, 0); }, v);
    await page.waitForTimeout(70);
    const r = await page.evaluate(v => {
      const vw = window.innerWidth;
      const docW = document.documentElement.scrollWidth;
      const active = document.getElementById('view-' + v);
      let bad = 0, clip = 0;
      if (active) {
        for (const el of active.querySelectorAll('*')) {
          const cs = getComputedStyle(el);
          if (cs.display === 'none' || cs.visibility === 'hidden' || cs.opacity === '0') continue;
          if (el.closest('[hidden]')) continue;
          const b = el.getBoundingClientRect();
          if (!b.width || !b.height) continue;
          if (b.right > vw + 2 && cs.position !== 'absolute' && cs.position !== 'fixed') bad++;
        }
        for (const el of active.querySelectorAll('h1,h2,h3,p,li,td,th,button,a,code,kbd,pre')) {
          const cs = getComputedStyle(el);
          if (cs.display === 'none' || el.closest('[hidden]')) continue;
          if (el.scrollWidth > el.clientWidth + 4 && cs.overflowX !== 'auto' && cs.overflowX !== 'scroll') clip++;
        }
      }
      return { over: docW > vw + 1, bad, clip };
    }, v);
    if (r.over) overflow++;
    outOfView += r.bad;
    clipped += r.clip;
  }

  const checks = [
    [layout.g3 === g.g3, `卡片列数 ${layout.g3}≠${g.g3}`],
    [g.nav === 'links' ? layout.navLinks : layout.toggle, '导航形态不符'],
    [navOK, '移动菜单点不开'],
    [layout.stack === g.stack, '预览堆叠形态不符'],
    [layout.previewRight <= w + 2 && layout.stageRight <= w + 2, '舞台/预览越界'],
    [overflow === 0, `横向溢出视图 ${overflow}`],
    [outOfView === 0, `越界元素 ${outOfView}`],
    [clipped === 0, `文本裁切 ${clipped}`],
  ];
  const bad = checks.filter(c => !c[0]);
  if (bad.length) fail++; else pass++;
  console.log(
    String(w).padEnd(7) + String(layout.g3).padEnd(5) +
    (layout.navLinks ? 'links ' : 'toggle').padEnd(8) +
    (layout.stack ? '堆叠' : '浮窗').padEnd(7) +
    String(overflow).padEnd(5) + String(outOfView).padEnd(5) + String(clipped).padEnd(5) +
    layout.h1 + 'px' + (bad.length ? '   ✗ ' + bad.map(x => x[1]).join(' / ') : '')
  );
}

// 字号单调：宽度变窄时字号不得变大
for (let i = 1; i < h1Sizes.length; i++) {
  if (h1Sizes[i].size > h1Sizes[i - 1].size + 0.5) {
    console.log(`  ✗ 字号跳变：${h1Sizes[i - 1].w}px=${h1Sizes[i - 1].size} → ${h1Sizes[i].w}px=${h1Sizes[i].size}`);
    fail++;
  }
}
if (errors.length) { console.log('  ✗ JS 异常：' + errors.slice(0, 3).join(' | ')); fail++; }

console.log(`\n=== ${pass}/${WIDTHS.length} 档宽度通过，附加断言失败 ${fail} 项 ===\n`);
await browser.close();
process.exit(fail ? 1 : 0);
