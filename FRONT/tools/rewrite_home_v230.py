#!/usr/bin/env python3
"""v230：首页基础样式回补 + 产品级动效 + 六个功能各配一段真实交互动图。

背景：
  · home 视图有 16 个 class 只在 @media 里出现或完全没定义（feature-card /
    fc-icon / grid-3 / sysbar / privacy-* 等），六个 SVG 图标被默认 300×150 撑爆；
  · 原 capture-flow.gif 是 PIL 手绘 UI（960×600、帧时长 50/360/540/800ms 混用、
    大片白框、假箭头），本轮改由 Playwright 录制真实渲染的交互（见 record_demos.py）；
  · 界面页不再用「静态真机截图 + 模拟界面」混排，改成六个功能各一段动图。
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
CSS = ROOT / "FRONT/assets/site.css"
JS = ROOT / "FRONT/assets/site.js"
HTML = ROOT / "FRONT/index.html"
MARK = "/* ---------- v230 首页基础样式与动效 ---------- */"

DEMOS = [
    ("clipboard", "剪贴板", "复制过的东西，随手就能翻回来",
     "搜索框模糊匹配、JSON / Markdown / 代码 / 图片分态预览，识别文字和翻译都在浮层里。",
     ["模糊搜索，输入应用名也能筛", "双击直接回贴", "预览里能识字、翻译、复制"]),
    ("capture", "截图标注", "三种截法，截完就能改",
     "区域、窗口、长截图；动作条里复制、贴图、识字、翻译、编辑、空投一次到位。",
     ["⌥S 区域 / ⇧⌥W 窗口 / ⇧⌥L 长截图", "矩形、箭头、马赛克、抹除", "本地 OCR，图片不出本机"]),
    ("monitor", "系统监控", "八个模块，一屏看完",
     "功耗、CPU、内存、网络、磁盘、传感器、电池、GPU 用一排标签切换，数据来自同一套读取引擎。",
     ["核心占用 / 集群 / 平均负载", "流量去哪了、逐进程占用", "1.5 秒刷新一次"]),
    ("transfer", "文件中转", "先收进暂存，再选出口",
     "隔空投送、扫码直传、ADB 直传三条路，接收和云端各占一栏，文件统一进本地暂存。",
     ["苹果设备走系统隔空投送", "安卓 / Windows 扫码就传", "USB 直连批量倒文件"]),
    ("cast", "安卓投屏", "手机接上就投",
     "USB 调试或一键无线，镜像、通知、存储、应用窗口都能在 Mac 上看。",
     ["镜像期间剪贴板双向同步", "通知每 6 秒同步", "可选 MCP 与 WebDAV，只绑回环"]),
    ("toolbox", "工具箱", "一个 / 就是启动器",
     "搜索框输入 / 切成工具列表，哈希、二维码、日历这类小工具即用即走。",
     ["命令面板 ⌥K", "日历、农历、节气同屏", "AI 总结 / 翻译，Key 存钥匙串"]),
]

CSS_BLOCK = r"""
/* ---------- v230 首页基础样式与动效 ---------- */
/* 六个功能卡片：图标固定 40×40 圆角容器，SVG 固定 20×20，不再被默认尺寸撑爆 */
.grid-3 { display: grid; grid-template-columns: repeat(3, minmax(0, 1fr)); gap: 18px; }
.feature-card {
  display: flex;
  flex-direction: column;
  padding: 24px 22px;
  border: 1px solid var(--line);
  border-radius: 16px;
  background: #FFFFFF;
  box-shadow: var(--shadow-sm);
  transition:
    transform var(--d-spring) var(--spring),
    box-shadow var(--m-fast) var(--m-ease-out),
    border-color var(--m-fast) var(--m-ease-out);
}
.feature-card:hover {
  transform: translateY(-3px);
  border-color: var(--line-strong);
  box-shadow: var(--shadow-md);
}
.fc-icon {
  width: 40px;
  height: 40px;
  border-radius: 11px;
  display: grid;
  place-items: center;
  margin-bottom: 16px;
  flex: 0 0 auto;
}
.fc-icon svg { width: 20px; height: 20px; display: block; }
.tint-blue { background: #EEF3FF; color: #2F6BFF; }
.tint-purple { background: #F3EEFF; color: #7A5AF8; }
.tint-green { background: #EAF8F0; color: #1F9D63; }
.tint-orange { background: #FFF4E6; color: #D97706; }
.tint-pink { background: #FFEDF4; color: #DB4C8B; }
.tint-gray { background: #F1F1F4; color: #4A4A52; }
.feature-card h3 { font-size: 17px; font-weight: 640; margin: 0 0 8px; letter-spacing: -0.01em; }
.feature-card p { font-size: 13.5px; line-height: 1.8; color: var(--ink-2); margin: 0 0 14px; }
.feature-card ul { list-style: none; display: grid; gap: 6px; margin: 0 0 18px; }
.feature-card li { position: relative; padding-left: 14px; font-size: 12.5px; line-height: 1.7; color: var(--ink-3); }
.feature-card li::before {
  content: "";
  position: absolute;
  left: 0;
  top: 8px;
  width: 4px;
  height: 4px;
  border-radius: 50%;
  background: var(--accent);
  opacity: 0.55;
}
.feature-card kbd, .feature-card code { font-size: 11px; }
.fc-demo-link {
  margin-top: auto;
  align-self: flex-start;
  padding: 0;
  font-size: 12.5px;
  font-weight: 620;
  color: var(--accent);
  cursor: pointer;
  transition: color var(--m-fast) var(--m-ease-out);
}
.fc-demo-link:hover { color: var(--accent-deep); }

/* 隐私条与系统要求条 */
.privacy-banner {
  display: grid;
  grid-template-columns: minmax(0, 1fr) minmax(0, 1fr);
  gap: 48px;
  padding: 38px 40px;
  border: 1px solid var(--line);
  border-radius: 20px;
  background: var(--bg-soft);
}
.privacy-banner h3 { font-size: 25px; line-height: 1.4; letter-spacing: -0.01em; margin: 12px 0; }
.privacy-banner > div > p { font-size: 14px; line-height: 1.85; color: var(--ink-2); }
.privacy-points { display: grid; gap: 16px; align-content: center; }
.privacy-point { display: flex; align-items: flex-start; gap: 12px; }
.pp-ico {
  flex: 0 0 34px;
  width: 34px;
  height: 34px;
  border-radius: 10px;
  display: grid;
  place-items: center;
  background: #FFFFFF;
  border: 1px solid var(--line);
  color: var(--accent);
}
.pp-ico svg { width: 17px; height: 17px; display: block; }
.privacy-point b { display: block; font-size: 13.5px; font-weight: 620; margin-bottom: 2px; }
.privacy-point span { font-size: 12.5px; line-height: 1.7; color: var(--ink-2); }
.sysbar { border-top: 1px solid var(--line); border-bottom: 1px solid var(--line); background: var(--bg-soft); }
.sysbar-inner {
  max-width: var(--maxw);
  margin: 0 auto;
  padding: 18px 24px;
  display: flex;
  flex-wrap: wrap;
  gap: 14px 36px;
  font-size: 13px;
  color: var(--ink-2);
}
.sysbar-inner b { color: var(--ink-3); font-size: 11px; letter-spacing: 0.08em; font-weight: 600; margin-right: 8px; }
.hero-copy { display: flex; flex-direction: column; align-items: flex-start; }

/* 「流量去哪了」：原来左侧白块把流线截断，看起来像位置错乱 */
.mon-flow { gap: 0; padding: 10px; }
.mon-flow-src { background: transparent; flex: 0 0 76px; }
.mon-flow-band { min-width: 54px; }
.mon-flow-dst { flex: 0 0 120px; }

/* 六个功能的动图舞台 */
.demo-stage-note { font-size: 13px; color: var(--ink-3); margin: 14px 0 0; }
.shot-frame .gif-slide { width: 100%; max-height: 520px; object-fit: contain; border-radius: 10px; }
.more-shots {
  margin-top: 22px;
  border: 1px solid var(--line);
  border-radius: 12px;
  background: #FFFFFF;
  padding: 12px 16px;
}
.more-shots summary { font-size: 13px; color: var(--ink-2); cursor: pointer; font-weight: 560; }
.more-shots-grid {
  display: grid;
  grid-template-columns: repeat(3, minmax(0, 1fr));
  gap: 14px;
  margin-top: 16px;
}
.more-shots-grid img { width: 100%; border-radius: 8px; border: 1px solid var(--line); }
.more-shots-grid figcaption { font-size: 11.5px; color: var(--ink-3); margin-top: 5px; }

/* ---------- 产品宣传页级首页动效（全部取 App 动效令牌） ---------- */
.hero { position: relative; overflow: hidden; }
.hero::before {
  content: "";
  position: absolute;
  inset: -30% -12% auto -12%;
  height: 82%;
  pointer-events: none;
  background:
    radial-gradient(55% 55% at 72% 24%, rgba(47, 107, 255, 0.11), transparent 70%),
    radial-gradient(48% 48% at 18% 62%, rgba(122, 90, 248, 0.08), transparent 72%);
  animation: hero-glow calc(var(--m-loop) * 12) var(--m-linear) infinite alternate;
}
@keyframes hero-glow {
  from { transform: translate3d(0, 0, 0) scale(1); opacity: 0.7; }
  to { transform: translate3d(0, 2%, 0) scale(1.06); opacity: 1; }
}
.hero-copy > * { animation: hero-rise var(--m-slow) var(--m-ease-out) both; }
.hero-copy > :nth-child(1) { animation-delay: calc(var(--m-tap) * 0); }
.hero-copy > :nth-child(2) { animation-delay: calc(var(--m-tap) * 1); }
.hero-copy > :nth-child(3) { animation-delay: calc(var(--m-tap) * 2); }
.hero-copy > :nth-child(4) { animation-delay: calc(var(--m-tap) * 3); }
.hero-copy > :nth-child(5) { animation-delay: calc(var(--m-tap) * 4); }
@keyframes hero-rise {
  from { opacity: 0; transform: translateY(14px); }
  to { opacity: 1; transform: none; }
}
/* JS 未启用时内容必须可见；只有挂上 js-motion 才启用滚动揭示 */
.js-motion [data-reveal] {
  opacity: 0;
  transform: translateY(18px);
  transition:
    opacity var(--m-slow) var(--m-ease-out),
    transform var(--m-slow) var(--m-ease-out);
}
.js-motion [data-reveal].in { opacity: 1; transform: none; }
.js-motion .feature-card[data-reveal]:nth-child(2) { transition-delay: calc(var(--m-tap) * 0.5); }
.js-motion .feature-card[data-reveal]:nth-child(3) { transition-delay: calc(var(--m-tap) * 1); }
@media (prefers-reduced-motion: reduce) {
  .js-motion [data-reveal] { opacity: 1; transform: none; }
}

@media (max-width: 1024px) {
  .privacy-banner { grid-template-columns: 1fr; gap: 26px; padding: 28px; }
  .more-shots-grid { grid-template-columns: repeat(2, minmax(0, 1fr)); }
}
@media (max-width: 700px) {
  .grid-3 { grid-template-columns: 1fr; }
  .feature-card { padding: 20px; }
  .privacy-banner { padding: 20px; }
  .more-shots-grid { grid-template-columns: 1fr; }
  .sysbar-inner { padding: 16px; gap: 10px 20px; }
}
"""

JS_BLOCK = r"""
  /* ---------------- v230 首页动效（参数全部来自 motion.js） ---------------- */
  (function () {
    var Motion = window.KitnestMotion;
    document.documentElement.classList.add("js-motion");

    // 首屏舞台按 WindowReveal 的口径从右上角展开（与真机主面板一致）
    var stage = $(".hero-stage");
    if (stage && Motion) {
      Motion.revealIn(stage, {
        unit: { x: 1, y: 0 },
        scale: Motion.tokens.revealScale.preview,
        duration: Motion.openDuration(),
        timing: "caEaseOut"
      });
    }

    // 滚动揭示：进入视口才播，只播一次
    var els = $$("[data-reveal]");
    if ("IntersectionObserver" in window) {
      var io = new IntersectionObserver(function (entries) {
        entries.forEach(function (e) {
          if (!e.isIntersecting) return;
          e.target.classList.add("in");
          io.unobserve(e.target);
        });
      }, { threshold: 0.1, rootMargin: "0px 0px -40px 0px" });
      els.forEach(function (el) { io.observe(el); });
    } else {
      els.forEach(function (el) { el.classList.add("in"); });
    }

    // 六个功能卡片的「看演示」跳到界面页对应动图
    $$("[data-demo-jump]").forEach(function (btn) {
      btn.addEventListener("click", function () {
        var name = btn.getAttribute("data-demo-jump");
        location.hash = "#showcase";
        setTimeout(function () {
          var tab = $('.shot-tab[data-shot="' + name + '"]');
          if (tab) tab.click();
          var st = $("#shotStage");
          if (st) st.scrollIntoView({ behavior: "smooth", block: "center" });
        }, 60);
      });
    });
  })();
"""


def rewrite_css() -> None:
    text = CSS.read_text(encoding="utf-8")
    if MARK in text:
        print("site.css: 已是 v230，跳过")
        return
    CSS.write_text(text.rstrip() + "\n" + CSS_BLOCK, encoding="utf-8")
    print("site.css: 首页基础样式 + 动效已追加")


def rewrite_js() -> None:
    text = JS.read_text(encoding="utf-8")
    if "v230 首页动效" in text:
        print("site.js: 已是 v230，跳过")
        return
    idx = text.rfind("})();")
    assert idx > 0, "找不到 site.js 的 IIFE 结尾"
    JS.write_text(text[:idx] + JS_BLOCK + "\n" + text[idx:], encoding="utf-8")
    print("site.js: 首页动效 + 演示跳转已插入")


def build_demo_html() -> str:
    tabs, panels, slides = [], [], []
    for i, (key, name, title, desc, points) in enumerate(DEMOS):
        tabs.append('            <button class="shot-tab%s" data-shot="%s" role="tab">%s</button>'
                    % (" on" if i == 0 else "", key, name))
        panels.append(
            '              <div data-shot-panel="%s"%s>\n'
            '                <span class="shot-index">%02d / DEMO</span>\n'
            '                <h3>%s</h3>\n'
            '                <p>%s</p>\n'
            '                <ul class="shot-points">%s</ul>\n'
            '              </div>' % (
                key, " hidden" if i else "", i + 1, title, desc,
                "".join("<li>" + p + "</li>" for p in points)))
        slides.append(
            '              <div data-shot-slide="%s"%s>\n'
            '                <img class="gif-slide" src="assets/gifs/demo-%s.gif" alt="%s 操作演示动图" loading="lazy">\n'
            '              </div>' % (key, " hidden" if i else "", key, name))
    shots = [
        ("panel.png", "主面板"), ("panel-performance.png", "监测页"),
        ("panel-transfer.png", "文件中转"), ("panel-cast.png", "投屏"),
        ("annotate.png", "标注编辑器"), ("popout-cpu.png", "CPU 详情窗"),
    ]
    grid = "".join(
        '          <figure><img src="assets/shots/%s" alt="%s实机截图" loading="lazy"><figcaption>%s</figcaption></figure>'
        % (f, n, n) for f, n in shots)
    return (
        '          <div class="shot-tabs" data-stage="shotStage" role="tablist" aria-label="功能演示切换">\n'
        + "\n".join(tabs) + "\n"
        '          </div>\n\n'
        '          <div class="shot-stage" id="shotStage">\n'
        '            <div class="shot-copy">\n' + "\n".join(panels) + "\n"
        '            </div>\n\n'
        '            <div class="shot-frame">\n' + "\n".join(slides) + "\n"
        '            </div>\n'
        '          </div>\n'
        ''
        '          <details class="more-shots">\n'
        '            <summary>更多实机截图</summary>\n'
        '            <div class="more-shots-grid">\n' + grid + '\n'
        '            </div>\n'
        '          </details>\n'
    )


def rewrite_html() -> None:
    text = HTML.read_text(encoding="utf-8")
    if 'data-shot="toolbox"' in text:
        print("index.html: 已是 v230，跳过")
        return

    # 1) 六个功能卡片加「看演示」入口 + 滚动揭示标记
    order = ["clipboard", "capture", "monitor", "transfer", "cast", "toolbox"]
    parts = text.split("            <article class=\"feature-card\">")
    assert len(parts) == 7, "feature-card 数量不对：%d" % (len(parts) - 1)
    out = [parts[0]]
    for i, chunk in enumerate(parts[1:]):
        end = chunk.index("            </article>")
        body = chunk[:end]
        if "fc-demo-link" not in body:
            body = body.rstrip() + "\n"
            body += ('              <button type="button" class="fc-demo-link" '
                     'data-demo-jump="%s">看演示 →</button>\n' % order[i])
        out.append('            <article class="feature-card" data-reveal>' + body + chunk[end:])
    text = "".join(out)

    # 2) 首页其它区块的滚动揭示标记
    home_start = text.index('id="view-home"')
    home_end = text.index('id="view-features"')
    home = text[home_start:home_end]
    home = home.replace('<div class="section-head">', '<div class="section-head" data-reveal>', 1)
    home = home.replace('<div class="privacy-banner">', '<div class="privacy-banner" data-reveal>', 1)
    home = home.replace('<div class="sysbar">', '<div class="sysbar" data-reveal>', 1)
    text = text[:home_start] + home + text[home_end:]

    # 3) 界面页：六个功能动图替代「静态截图 + 模拟界面」混排
    start = text.index('          <div class="shot-tabs" data-stage="shotStage"')
    end = text.index('          <div style="margin-top:26px">', start)
    # 保留原来的设置大图区块，但去掉它前面的内联 margin 包装，统一放到 details 之后
    after = text[end:]
    text = text[:start] + build_demo_html() + "\n" + after

    # 4) 删掉旧的手绘 GIF 那个 Motion 整段。
    #    必须按 <div> 深度配对找闭合：曾因用「下一个 .section」当终点，
    #    把中间的 view-download 整段一起删掉过（v230 实测踩过）。
    marker = '      <div class="section soft">'
    m = re.search(re.escape(marker), text)
    if m and '<span class="kicker">Motion</span>' in text[m.start():m.start() + 400]:
        depth, i = 0, m.start()
        for tok in re.finditer(r'</?div\b', text[m.start():]):
            if tok.group(0) == '<div':
                depth += 1
            else:
                depth -= 1
                if depth == 0:
                    end = m.start() + tok.end()
                    # 吃掉该行剩余部分
                    nl = text.find('\n', end)
                    end = nl + 1 if nl != -1 else end
                    text = text[:m.start()] + text[end:]
                    break
    # 功能页里内嵌的旧手绘 GIF 也换成新动图
    text = text.replace('src="assets/gifs/capture-flow.gif" alt="Kitnest 截图与标注全流程动图" loading="lazy"',
                        'src="assets/gifs/demo-capture.gif" alt="截图与标注操作演示动图" loading="lazy"')

    HTML.write_text(text, encoding="utf-8")
    print("index.html: 六功能演示入口 / 动图舞台 / 首页动效标记已接入")


def main() -> int:
    rewrite_css()
    rewrite_js()
    rewrite_html()
    return 0


if __name__ == "__main__":
    sys.exit(main())
