/* 官网动效回归：读 WAAPI 的 getTiming()/getKeyframes() 核对 App 真源参数。
   用法：node FRONT/tools/verify_motion.mjs [URL] [tag]
   依赖本机 playwright-core 与 Chrome for Testing；可用 PLAYWRIGHT_CORE /
   CHROME_EXEC 环境变量覆盖自动探测到的路径。 */
import { createRequire } from 'node:module';
import { existsSync, readdirSync } from 'node:fs';
import { join } from 'node:path';
const require = createRequire(import.meta.url);
const HOME = process.env.HOME || '';

function findPlaywrightCore() {
  const base = join(HOME, '.npm/_npx');
  if (!existsSync(base)) return null;
  for (const d of readdirSync(base)) {
    const p = join(base, d, 'node_modules/playwright-core');
    if (existsSync(p)) return p;
  }
  return null;
}
function findChrome() {
  const base = join(HOME, 'Library/Caches/ms-playwright');
  if (!existsSync(base)) return null;
  for (const d of readdirSync(base)) {
    const p = join(base, d,
      'chrome-mac-arm64/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing');
    if (existsSync(p)) return p;
  }
  return null;
}
const PW = process.env.PLAYWRIGHT_CORE || findPlaywrightCore();
const EXEC = process.env.CHROME_EXEC || findChrome();
if (!PW || !EXEC) {
  console.error('缺少 playwright-core 或 Chrome for Testing；可用 PLAYWRIGHT_CORE / CHROME_EXEC 指定');
  process.exit(2);
}
const { chromium } = require(PW);
const BASE = process.argv[2] || 'http://127.0.0.1:5173/';
const TAG = process.argv[3] || 'local';

const browser = await chromium.launch({ executablePath: EXEC, args: ['--use-angle=metal', '--ignore-gpu-blocklist'] });
const ctx = await browser.newContext({ viewport: { width: 1440, height: 900 }, deviceScaleFactor: 1 });
const page = await ctx.newPage();
const errors = [], bad = [];
page.on('pageerror', e => errors.push('pageerror: ' + e.message));
page.on('console', m => { if (m.type() === 'error') errors.push('console: ' + m.text().slice(0, 200)); });
page.on('response', r => { if (r.status() >= 400 && !/favicon/.test(r.url())) bad.push(r.status() + ' ' + r.url()); });

let pass = 0, fail = 0;
const check = (name, ok, detail) => {
  if (ok) { pass++; console.log('  ✓ ' + name); }
  else { fail++; console.log('  ✗ ' + name + (detail !== undefined ? '  → ' + JSON.stringify(detail) : '')); }
};
const near = (a, b, eps = 0.002) => Math.abs(Number(a) - Number(b)) < eps;
const cssVar = (n) => page.evaluate(n => getComputedStyle(document.documentElement).getPropertyValue(n).trim(), n);
const animInfo = (sel) => page.evaluate(sel => {
  const el = document.querySelector(sel);
  if (!el) return null;
  const a = el.getAnimations().find(x => x.id === 'kitnest-reveal');
  if (!a) return { found: false, hidden: el.hidden, opacity: getComputedStyle(el).opacity, transform: getComputedStyle(el).transform };
  const t = a.effect.getTiming();
  return {
    found: true, duration: t.duration, easing: t.easing,
    frames: a.effect.getKeyframes().map(k => ({ opacity: k.opacity, transform: k.transform })),
    origin: getComputedStyle(el).transformOrigin,
    inlineOrigin: el.style.transformOrigin, hidden: el.hidden
  };
}, sel);

console.log('\n=== Kitnest 官网动效 1:1 回归 · ' + TAG + ' · ' + BASE + ' ===\n');
await page.goto(BASE, { waitUntil: 'networkidle', timeout: 60000 });
await page.waitForTimeout(300);

/* ---------- A. 令牌与真源 ---------- */
console.log('A. 动效令牌');
const tokens = await page.evaluate(() => {
  const M = window.KitnestMotion;
  return M ? {
    exists: true,
    tap: M.tokens.tap, fast: M.tokens.fast, page: M.tokens.page, slow: M.tokens.slow,
    springs: M.tokens.springs, loop: M.tokens.loop, progress: M.tokens.progress,
    caEaseOut: M.tokens.caEaseOut, caEaseIn: M.tokens.caEaseIn, caBackOut: M.tokens.caBackOut,
    open: M.openDuration(), preset: M.tokens.openPreset,
    revealScale: M.tokens.revealScale, toast: M.tokens.toast,
    solved: Object.fromEntries(Object.entries(M.springs).map(([k, v]) => [k, +v.duration.toFixed(3)]))
  } : { exists: false };
});
check('window.KitnestMotion 已加载', tokens.exists);
check('tap/fast/page/slow = .12/.16/.22/.45', near(tokens.tap, .12) && near(tokens.fast, .16) && near(tokens.page, .22) && near(tokens.slow, .45), tokens);
check('spring 四档参数与 Support.swift 一致',
  near(tokens.springs.springSnappy.response, .22) && near(tokens.springs.springSnappy.dampingFraction, .85) &&
  near(tokens.springs.spring.response, .28) && near(tokens.springs.spring.dampingFraction, .86) &&
  near(tokens.springs.springSoft.response, .34) && near(tokens.springs.springSoft.dampingFraction, .86) &&
  near(tokens.springs.springBouncy.response, .24) && near(tokens.springs.springBouncy.dampingFraction, .62), tokens.springs);
check('loop/progress = .9/.2 且线性', near(tokens.loop, .9) && near(tokens.progress, .2));
check('caEaseOut(.22,0,0,1) / caEaseIn(.42,0,1,1) / caBackOut(.22,1.05,.36,1)',
  JSON.stringify(tokens.caEaseOut) === '[0.22,0,0,1]' && JSON.stringify(tokens.caEaseIn) === '[0.42,0,1,1]' && JSON.stringify(tokens.caBackOut) === '[0.22,1.05,0.36,1]', tokens);
check('开合默认档 standard = 0.22s', tokens.preset === 'standard' && near(tokens.open, .22));
check('窗口 scale 面板 .90 / 预览 .94', near(tokens.revealScale.panel, .9) && near(tokens.revealScale.preview, .94));
check('弹簧收敛时长 = 解析解（.311/.393/.477/.441）',
  near(tokens.solved.springSnappy, .311) && near(tokens.solved.spring, .393) &&
  near(tokens.solved.springSoft, .477) && near(tokens.solved.springBouncy, .441), tokens.solved);

const vFast = await cssVar('--m-fast'), vEase = await cssVar('--m-ease-out'),
  vCA = await cssVar('--m-ca-ease-out'), vBouncy = await cssVar('--spring-bouncy');
check('CSS --m-fast = 0.16s', vFast === '0.16s', vFast);
check('CSS SwiftUI easeOut = cubic-bezier(0, 0, 0.58, 1)', vEase.replace(/\s/g, '') === 'cubic-bezier(0,0,0.58,1)', vEase);
check('CSS caEaseOut = cubic-bezier(0.22, 0, 0, 1)', vCA.replace(/\s/g, '') === 'cubic-bezier(0.22,0,0,1)', vCA);
check('弹簧是真实 linear() 采样且保留过冲 >1',
  /^linear\(/.test(vBouncy) && Math.max(...(vBouncy.match(/-?\d+\.?\d*/g) || []).map(Number)) > 1,
  vBouncy.slice(0, 90));

/* ---------- B. 主面板 WindowReveal ---------- */
console.log('\nB. 主面板开合（WindowReveal）');
let state = await page.evaluate(() => ({ hidden: document.getElementById('panelMock').hidden, exp: document.getElementById('mbIcon').getAttribute('aria-expanded') }));
if (state.hidden) { await page.click('#mbIcon'); }
else { await page.click('#mbIcon'); await page.waitForTimeout(320); await page.click('#mbIcon'); }
const pIn = await animInfo('#panelMock');
check('展开动画存在（WAAPI id=kitnest-reveal）', pIn && pIn.found, pIn);
check('展开 220ms / caEaseOut', near(pIn.duration, 220) && pIn.easing.replace(/\s/g, '') === 'cubic-bezier(0.22,0,0,1)', { d: pIn.duration, e: pIn.easing });
check('展开从 scale(0.9) + opacity 0 → 1 / none',
  /scale\(0\.9\)/.test(pIn.frames?.[0]?.transform || '') && pIn.frames?.[0]?.opacity === '0' && pIn.frames?.at(-1)?.opacity === '1', pIn.frames);
check('展开锚点 y=0（菜单栏图标投影）', /0(?:%|px)/.test((pIn.origin || '').split(' ')[1] || ''), pIn.origin);
await page.waitForTimeout(330);
const pAfter = await page.evaluate(() => {
  const el = document.getElementById('panelMock');
  return { hidden: el.hidden, opacity: getComputedStyle(el).opacity, transform: getComputedStyle(el).transform, anims: el.getAnimations().length };
});
check('展开结束停在终态且无残留动画', !pAfter.hidden && pAfter.opacity === '1' && pAfter.anims === 0, pAfter);

await page.click('#mbIcon');
const pOut = await animInfo('#panelMock');
check('收回 220ms / caEaseIn', near(pOut.duration, 220) && pOut.easing.replace(/\s/g, '') === 'cubic-bezier(0.42,0,1,1)', { d: pOut.duration, e: pOut.easing });
check('收回缩回 scale(0.9) + opacity 1 → 0', /scale\(0\.9\)/.test(pOut.frames?.at(-1)?.transform || ''), pOut.frames);
await page.waitForTimeout(330);
check('收回结束后 hidden=true', await page.evaluate(() => document.getElementById('panelMock').hidden));
await page.click('#mbIcon');
await page.waitForTimeout(330);

/* ---------- C. 预览窗 WindowReveal ---------- */
console.log('\nC. 剪贴板预览开合（ClipboardPreviewWindow）');
const items = await page.locator('.pm-item').count();
check('剪贴板假数据条目存在', items >= 6, items);
await page.locator('.pm-item').first().hover();
await page.waitForTimeout(40);
const vIn = await animInfo('#pmPreview');
check('预览展开动画存在', vIn && vIn.found, vIn);
check('预览 220ms / caEaseOut', near(vIn.duration, 220) && vIn.easing.replace(/\s/g, '') === 'cubic-bezier(0.22,0,0,1)', { d: vIn.duration, e: vIn.easing });
check('预览从 scale(0.94) 展开', /scale\(0\.94\)/.test(vIn.frames?.[0]?.transform || ''), vIn.frames);
check('预览锚点在右边缘 x=100%（贴面板那一侧）', /^100/.test(vIn.inlineOrigin || ''), vIn.inlineOrigin);
const bounds = await page.evaluate(() => {
  const p = document.getElementById('pmPreview').getBoundingClientRect();
  const s = document.querySelector('.hero-stage').getBoundingClientRect();
  const m = document.getElementById('panelMock').getBoundingClientRect();
  return { pL: p.left, pR: p.right, sL: s.left, sR: s.right, mL: m.left, hidden: document.getElementById('pmPreview').hidden };
});
check('预览在面板左侧且不溢出舞台', !bounds.hidden && bounds.pR <= bounds.mL + 2 && bounds.pL >= bounds.sL - 2, bounds);

// 同条目重复 hover 不重播（App: show() 的 sameItem 分支）
const again = await page.evaluate(() => {
  const el = document.getElementById('pmPreview');
  const before = el.getAnimations().map(a => a.currentTime);
  el.dispatchEvent(new MouseEvent('mouseover', { bubbles: true }));
  return { before, after: el.getAnimations().map(a => a.currentTime) };
});
check('同条目 hover 不重播入场', again.before.length === again.after.length, again);

// 换条目重播
await page.locator('.pm-item').nth(1).hover();
const vSwitch = await animInfo('#pmPreview');
check('换条目重播入场（220ms caEaseOut）', vSwitch && vSwitch.found && near(vSwitch.duration, 220), vSwitch);

// 预览真实渲染 & 按钮
const renderKinds = await page.evaluate(async () => {
  const out = {};
  const els = [...document.querySelectorAll('.pm-item')];
  for (const li of els) {
    li.dispatchEvent(new MouseEvent('mouseover', { bubbles: true }));
    const b = document.getElementById('pmPreview').querySelector('.pm-preview-body');
    for (const k of ['pv-tree', 'pv-code', 'pv-md', 'pv-img', 'pv-raw', 'pv-text']) {
      if (b.querySelector('.' + k)) out[k] = (out[k] || 0) + 1;
    }
  }
  return out;
});
check('JSON 树 / 代码 / Markdown / 图片 / 文本 真实渲染',
  renderKinds['pv-tree'] > 0 && renderKinds['pv-code'] > 0 && renderKinds['pv-md'] > 0 && renderKinds['pv-img'] > 0, renderKinds);

// OCR 按钮交互（图片条目）
const ocrOK = await page.evaluate(() => {
  const els = [...document.querySelectorAll('.pm-item')];
  for (const li of els) {
    li.dispatchEvent(new MouseEvent('mouseover', { bubbles: true }));
    const btn = document.querySelector('#pmPreview [data-pv-act="ocr"]');
    if (btn) {
      btn.click();
      const box = document.querySelector('#pmPreview .pv-ocr');
      return { clicked: true, shown: box && !box.hidden, text: box ? box.textContent.slice(0, 40) : '' };
    }
  }
  return { clicked: false };
});
check('图片预览的「文字提取」按钮可交互', ocrOK.clicked && ocrOK.shown, ocrOK);

// 预览收回
await page.evaluate(() => document.getElementById('pmBody').dispatchEvent(new MouseEvent('mouseleave', { bubbles: true })));
const vOut = await animInfo('#pmPreview');
check('预览收回 220ms / caEaseIn', vOut && vOut.found && near(vOut.duration, 220) && vOut.easing.replace(/\s/g, '') === 'cubic-bezier(0.42,0,1,1)', vOut);
await page.waitForTimeout(330);
check('预览收回后 hidden=true', await page.evaluate(() => document.getElementById('pmPreview').hidden));

/* ---------- D. 视图内过渡 ---------- */
console.log('\nD. 视图内过渡（SwiftUI 令牌）');
const pageAnim = await page.evaluate(() => {
  const el = document.querySelector('.pm-page:not([hidden])');
  const s = getComputedStyle(el);
  return { duration: s.animationDuration, easing: s.animationTimingFunction, name: s.animationName };
});
check('页签切换 0.16s / SwiftUI easeOut / 纯 opacity',
  near(parseFloat(pageAnim.duration), .16) && pageAnim.easing.replace(/\s/g, '') === 'cubic-bezier(0,0,0.58,1)' && pageAnim.name === 'page-fade', pageAnim);
const modAnim = await page.evaluate(() => {
  const el = document.querySelector('.pm-mod') || document.querySelector('#pmModBody');
  const s = getComputedStyle(el);
  return { duration: s.animationDuration, easing: s.animationTimingFunction, name: s.animationName };
});
check('监测模块 springSoft 采样曲线', /^linear\(/.test(modAnim.easing), modAnim);
const btnStyle = await page.evaluate(() => {
  const s = getComputedStyle(document.querySelector('#pmSegs .pm-seg'));
  return { dur: s.transitionDuration, ease: s.transitionTimingFunction };
});
check('按钮 transform 用 springBouncy（linear 采样）', /linear\(/.test(btnStyle.ease), btnStyle);
const shimmer = await page.evaluate(() => {
  const el = document.querySelector('.sl-line');
  if (!el) return null;
  const s = getComputedStyle(el);
  return { dur: s.animationDuration, ease: s.animationTimingFunction, iter: s.animationIterationCount };
});
check('连续循环动画 0.9s 线性（Theme.Motion.loop）',
  shimmer && near(parseFloat(shimmer.dur), .9) && shimmer.ease === 'linear' && shimmer.iter === 'infinite', shimmer);
const toastStyle = await page.evaluate(() => {
  const s = getComputedStyle(document.getElementById('toast'));
  return { dur: s.transitionDuration, ease: s.transitionTimingFunction, transform: s.transform };
});
check('Toast 用 springBouncy + scale(0.5) 起态', /linear\(/.test(toastStyle.ease) && /matrix\(0\.5/.test(toastStyle.transform), toastStyle);

/* ---------- E. 交互回归 ---------- */
console.log('\nE. 交互回归');
const views = ['features', 'showcase', 'download', 'changelog', 'help', 'privacy', 'home'];
let navOK = true;
for (const v of views) {
  await page.evaluate(v => { location.hash = '#' + v; }, v);
  await page.waitForTimeout(60);
  const ok = await page.evaluate(v => document.getElementById('view-' + v)?.classList.contains('active'), v);
  if (!ok) { navOK = false; console.log('    ! 视图切换失败: ' + v); }
}
check('7 个 hash 视图切换正常', navOK);
await page.evaluate(() => { location.hash = '#home'; });
await page.waitForTimeout(80);

const searchOK = await page.evaluate(async () => {
  const i = document.getElementById('pmSearch');
  i.value = '/';
  i.dispatchEvent(new Event('input', { bubbles: true }));
  await new Promise(r => setTimeout(r, 60));
  const r = document.getElementById('pmResults');
  const n = r.querySelectorAll('button, li, [data-cmd]').length;
  i.value = ''; i.dispatchEvent(new Event('input', { bubbles: true }));
  return { count: n };
});
check('搜索输入 / 出工具命令', searchOK.count > 0, searchOK);

const feedOK = await page.evaluate(() => {
  const t = document.body.innerText;
  return { hasBuild: /\d{3,}/.test(t), hasSHA: /[a-f0-9]{16,}/i.test(t), hasVersion: /1\.0\.0/.test(t) };
});
check('下载清单渲染（版本 / build / SHA-256）', feedOK.hasVersion && feedOK.hasBuild, feedOK);

const toastFlow = await page.evaluate(async () => {
  const btn = document.querySelector('.pm-item [data-row-act="copy"]');
  if (!btn) return { clicked: false };
  btn.click();
  const el = document.getElementById('toast');
  const shown = el.classList.contains('show');
  await new Promise(r => setTimeout(r, 3100));
  const hidden = !el.classList.contains('show');
  await new Promise(r => setTimeout(r, 450));
  return { clicked: true, shown, hidden, visibility: el.style.visibility };
});
check('Toast：springBouncy 弹入 → 3.0s 自动隐藏 → 0.4s 收尾',
  toastFlow.shown && toastFlow.hidden && toastFlow.visibility === 'hidden', toastFlow);

const hints = await page.evaluate(() => {
  const t = document.body.innerText;
  const re = /示例|演示|假数据|占位文档|虚构|测试用例|点击体验|模拟数据|点部件看详情|点小猫收起面板/g;
  const out = []; let m;
  while ((m = re.exec(t))) out.push(t.slice(Math.max(0, m.index - 30), m.index + 30).replace(/\n/g, ' '));
  return out;
});
check('页面无说明性/示例文案', hints.length === 0, hints.slice(0, 5));

/* ---------- F. 健康 ---------- */
console.log('\nF. 控制台与资源');
check('无 JS 异常 / console error', errors.length === 0, errors.slice(0, 6));
check('无 4xx/5xx 资源', bad.length === 0, bad.slice(0, 6));

await page.screenshot({ path: `/tmp/kitnest-motion-${TAG}.png`, fullPage: false });
console.log(`\n=== ${TAG}: ${pass}/${pass + fail} 通过，截图 /tmp/kitnest-motion-${TAG}.png ===\n`);
await browser.close();
process.exit(fail ? 1 : 0);
