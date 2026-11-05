#!/usr/bin/env python3
"""v229：重做官网预览浮层 + 功能/界面/更新记录三页排版，接入真实照片与 GIF。

改动：
  · Markdown 预览加可点目录；
  · 图片预览换成真实会议场景照片，识别结果改成两段结构化文本 + 翻译分段；
  · 预览浮层加宽并重排；
  · 补回三个页面整段缺失的专属 CSS（.chapter / .shot-* / .gif-* / .callout 等）；
  · 「界面」页截图切换加「操作动图」标签，「功能」页截图章节内嵌 GIF。
"""
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
CSS = ROOT / "FRONT/assets/site.css"
JS = ROOT / "FRONT/assets/site.js"
HTML = ROOT / "FRONT/index.html"
MARK_CSS = "/* ---------- v229 页面排版重构 ---------- */"

# ---------------------------------------------------------------- CSS
PREVIEW_CSS = r"""
/* ---------- v229 预览浮层重排（宽 258pt，真机预览窗的信息密度） ---------- */
.pm-preview { width: 258px; }
.pm-preview-bar { padding: 11px 13px 10px; gap: 8px; }
.pm-preview-kind { font-size: 10px; padding: 2px 6px; border-radius: 5px; }
.pm-preview-title { font-size: 12px; font-weight: 600; }
.pm-preview-body {
  padding: 12px 13px;
  max-height: 460px;
  font-size: 11.5px;
  line-height: 1.65;
}
.pm-preview-foot { padding: 9px 13px 11px; gap: 7px; background: rgba(0, 0, 0, 0.018); }
.pm-preview-foot button {
  flex: 1;
  padding: 5px 8px;
  font-size: 11.5px;
  border-radius: 7px;
  font-weight: 520;
}

/* JSON / 代码：给一层浅底和圆角，跟真机检查器一致 */
.pv-tree, .pv-code {
  background: var(--bg-soft);
  border: 1px solid var(--line);
  border-radius: 9px;
  padding: 9px 10px;
  font-size: 10.5px;
  line-height: 1.7;
}
.pv-code table { width: 100%; }
.pv-code .c-ln { width: 24px; padding-right: 8px; }
.pv-tree .pv-row { padding-top: 1px; padding-bottom: 1px; }

/* Markdown：目录 + 正文两块，目录可点、不占用 hash 路由 */
.pv-md { display: grid; gap: 12px; }
.pv-md-toc {
  border: 1px solid var(--line);
  border-radius: 9px;
  background: var(--bg-soft);
  padding: 9px 10px 8px;
}
.pv-md-toc > span {
  display: block;
  font-size: 9.5px;
  letter-spacing: 0.1em;
  color: var(--ink-3);
  margin-bottom: 6px;
  font-weight: 600;
}
.pv-md-toc ul { list-style: none; display: grid; gap: 1px; margin: 0; padding: 0; }
.pv-md-toc a {
  display: block;
  font-size: 11px;
  color: var(--ink-2);
  padding: 3px 7px;
  border-radius: 5px;
  border-left: 2px solid transparent;
  transition:
    background-color var(--m-fast) var(--m-ease-out),
    color var(--m-fast) var(--m-ease-out);
}
.pv-md-toc a:hover, .pv-md-toc a.on {
  background: #FFFFFF;
  color: var(--accent);
  border-left-color: var(--accent);
}
.pv-md-toc li.lvl-2 a { padding-left: 15px; }
.pv-md-toc li.lvl-3 a { padding-left: 26px; }
.pv-md-toc li.lvl-4 a { padding-left: 36px; }
.pv-md-body h1 { font-size: 15px; margin: 0 0 8px; padding-bottom: 7px; border-bottom: 1px solid var(--line); }
.pv-md-body h2 { font-size: 12.5px; margin: 14px 0 6px; }
.pv-md-body p { margin: 0 0 7px; }
.pv-md-body ul, .pv-md-body ol { margin: 0 0 9px; padding-left: 18px; }
.pv-md-body li { margin-bottom: 3px; }
.pv-md-body code.md-code { font-size: 10px; }

/* 图片：真实照片 + 文件信息 + 真机同款「识别文本 / 翻译」分段 */
.pv-img { display: grid; gap: 10px; }
.pv-img-shot {
  margin: 0;
  border-radius: 10px;
  overflow: hidden;
  border: 1px solid var(--line);
  background: var(--bg-soft);
}
.pv-img-shot img { width: 100%; height: 110px; object-fit: cover; display: block; }
.pv-img-shot figcaption {
  display: flex;
  align-items: center;
  gap: 7px;
  padding: 6px 9px;
  font-size: 10px;
  color: var(--ink-3);
  font-family: var(--mono);
  background: #FFFFFF;
  border-top: 1px solid var(--line);
}
.pv-img-badge {
  font-size: 9px;
  letter-spacing: 0.06em;
  color: var(--accent);
  background: var(--accent-soft);
  padding: 1px 5px;
  border-radius: 4px;
  font-family: var(--sans);
}
.pv-img-file { display: grid; gap: 2px; min-width: 0; }
.pv-img-file b {
  font-size: 11.5px;
  font-weight: 600;
  color: var(--ink);
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}
.pv-img-file span { font-size: 10.5px; color: var(--ink-3); }
.pv-ocr { border-top: 1px solid var(--line); padding-top: 9px; display: grid; gap: 8px; }
.pv-ocr-tabs {
  display: flex;
  gap: 3px;
  background: rgba(0, 0, 0, 0.045);
  padding: 3px;
  border-radius: 8px;
}
.pv-ocr-tabs button {
  flex: 1;
  border: 0;
  background: transparent;
  border-radius: 6px;
  padding: 4px 0;
  font-size: 10.5px;
  color: var(--ink-3);
  font-family: inherit;
  cursor: pointer;
  transition:
    background-color var(--m-fast) var(--m-ease-out),
    color var(--m-fast) var(--m-ease-out);
}
.pv-ocr-tabs button.on { background: #FFFFFF; color: var(--ink); font-weight: 600; box-shadow: var(--shadow-sm); }
.pv-ocr-block { border: 1px solid var(--line); border-radius: 8px; padding: 8px 9px; background: var(--bg-soft); }
.pv-ocr-tag {
  display: block;
  font-size: 9.5px;
  letter-spacing: 0.04em;
  color: var(--accent);
  margin-bottom: 5px;
  font-weight: 600;
}
.pv-ocr-block p { margin: 0; font-size: 11px; line-height: 1.75; color: var(--ink-2); }
.pv-text { font-size: 11.5px; line-height: 1.75; }
"""

PAGES_CSS = r"""
/* ---------- v229 页面排版重构 ----------
   功能 / 界面 / 更新记录三页原先的专属样式在重构中整个丢失，浏览器只剩默认
   块级流：章节编号、正文、列表挤成一坨，右侧大片空白。这里按纯白主题重建
   两栏章节、规格表、提示块、截图舞台、动图卡片与时间线。 */
.section-head { max-width: 780px; margin-bottom: 52px; }
.section-head h2 { font-size: 40px; line-height: 1.25; letter-spacing: -0.02em; margin-bottom: 16px; }
.section-head p.lede { font-size: 16.5px; line-height: 1.8; color: var(--ink-2); }

/* 功能页：左栏 sticky 章节号，右栏正文 */
.chapter {
  display: grid;
  grid-template-columns: 210px minmax(0, 1fr);
  gap: 52px;
  padding: 46px 0;
  border-top: 1px solid var(--line);
}
.chapter:first-of-type { border-top: none; padding-top: 6px; }
.chapter-no { position: sticky; top: 96px; align-self: start; display: grid; gap: 7px; }
.ch-title {
  font-family: var(--mono);
  font-size: 11.5px;
  font-weight: 650;
  letter-spacing: 0.09em;
  color: var(--accent);
  text-transform: uppercase;
}
.ch-sub { font-size: 17px; font-weight: 600; color: var(--ink); line-height: 1.45; }
.chapter-body { min-width: 0; }
.chapter-body h3 { font-size: 23px; font-weight: 640; line-height: 1.35; letter-spacing: -0.01em; margin: 0 0 14px; }
.chapter-body > p { font-size: 15px; line-height: 1.85; color: var(--ink-2); margin-bottom: 22px; max-width: 760px; }
.chapter-body strong { color: var(--ink); font-weight: 620; }
.chapter-body code, .callout code {
  font-family: var(--mono);
  font-size: 12px;
  background: rgba(0, 0, 0, 0.055);
  padding: 1px 5px;
  border-radius: 4px;
}
kbd {
  font-family: var(--mono);
  font-size: 11.5px;
  border: 1px solid var(--line-strong);
  border-bottom-width: 2px;
  border-radius: 5px;
  padding: 1px 5px;
  background: #FFFFFF;
  color: var(--ink);
}
.spec-list { list-style: none; display: grid; margin: 0 0 24px; border-top: 1px solid var(--line); }
.spec-list li {
  display: grid;
  grid-template-columns: 100px minmax(0, 1fr);
  gap: 20px;
  padding: 11px 2px;
  border-bottom: 1px solid var(--line);
  font-size: 14px;
  line-height: 1.75;
}
.spec-list .k { color: var(--ink-3); font-size: 12px; font-weight: 620; letter-spacing: 0.04em; padding-top: 2px; }
.spec-list .v { color: var(--ink-2); }
.callout {
  margin: 0 0 24px;
  padding: 14px 17px;
  border-radius: 10px;
  background: var(--accent-soft);
  border-left: 3px solid var(--accent);
  font-size: 13.5px;
  line-height: 1.8;
  color: var(--ink-2);
}
.callout.warn { background: #FFF8ED; border-left-color: var(--orange); }
.callout b { color: var(--ink); font-weight: 620; }
.preview-note { font-size: 12.5px !important; color: var(--ink-3) !important; margin: 10px 0 24px !important; }
.annotate-mock {
  display: flex;
  align-items: center;
  gap: 5px;
  flex-wrap: wrap;
  padding: 9px 11px;
  border: 1px solid var(--line);
  border-radius: 12px;
  background: #FFFFFF;
  box-shadow: var(--shadow-md);
  margin: 4px 0 0;
}
.am-tool {
  width: 27px;
  height: 27px;
  display: grid;
  place-items: center;
  border-radius: 7px;
  color: var(--ink-2);
}
.am-tool svg { width: 15px; height: 15px; }
.am-tool.on { background: var(--accent-soft); color: var(--accent); }
.am-sep { width: 1px; height: 18px; background: var(--line); margin: 0 4px; }
.am-swatches { display: flex; gap: 4px; align-items: center; }
.am-swatch { width: 13px; height: 13px; border-radius: 50%; }
.am-swatch.on { box-shadow: 0 0 0 2px #FFFFFF, 0 0 0 3.5px var(--ink); }
.inline-gif {
  margin: 0 0 24px;
  border: 1px solid var(--line);
  border-radius: 14px;
  overflow: hidden;
  background: var(--bg-soft);
}
.inline-gif img { width: 100%; max-height: 420px; object-fit: contain; display: block; }
.inline-gif figcaption {
  padding: 11px 16px;
  font-size: 12.5px;
  line-height: 1.7;
  color: var(--ink-2);
  border-top: 1px solid var(--line);
  background: #FFFFFF;
}

/* 界面页：胶囊标签 + 左文右图的浅灰舞台 */
.shot-tabs { display: flex; flex-wrap: wrap; gap: 8px; margin-bottom: 26px; }
.shot-tab {
  padding: 7px 15px;
  border: 1px solid var(--line-strong);
  border-radius: 999px;
  font-size: 13px;
  color: var(--ink-2);
  background: #FFFFFF;
  cursor: pointer;
  transition:
    background-color var(--m-fast) var(--m-ease-out),
    color var(--m-fast) var(--m-ease-out),
    border-color var(--m-fast) var(--m-ease-out);
}
.shot-tab:hover { border-color: var(--ink-3); color: var(--ink); }
.shot-tab.on { background: var(--ink); border-color: var(--ink); color: #FFFFFF; }
.shot-stage {
  display: grid;
  grid-template-columns: minmax(0, 0.82fr) minmax(0, 1.18fr);
  gap: 40px;
  align-items: center;
  padding: 32px;
  border: 1px solid var(--line);
  border-radius: 20px;
  background: var(--bg-soft);
}
.shot-copy { min-width: 0; }
.shot-index { font-family: var(--mono); font-size: 11px; letter-spacing: 0.12em; color: var(--accent); }
.shot-copy h3 { font-size: 25px; font-weight: 640; line-height: 1.3; margin: 12px 0; letter-spacing: -0.01em; }
.shot-copy > div > p { font-size: 14.5px; line-height: 1.85; color: var(--ink-2); margin-bottom: 20px; }
.shot-points { list-style: none; display: grid; gap: 11px; }
.shot-points li { position: relative; padding-left: 16px; font-size: 13.5px; line-height: 1.75; color: var(--ink-2); }
.shot-points li::before {
  content: "";
  position: absolute;
  left: 0;
  top: 9px;
  width: 5px;
  height: 5px;
  border-radius: 50%;
  background: var(--accent);
}
.shot-points b { color: var(--ink); font-weight: 620; margin-right: 6px; }
.shot-frame {
  background: #FFFFFF;
  border: 1px solid var(--line);
  border-radius: 14px;
  padding: 18px;
  box-shadow: var(--shadow-md);
  min-height: 350px;
  display: grid;
  place-items: center;
  overflow: hidden;
}
.shot-frame img, .shot-frame .gif-slide {
  max-width: 100%;
  max-height: 470px;
  object-fit: contain;
  border-radius: 8px;
}
.shot-figure, .gif-figure {
  margin: 0;
  border: 1px solid var(--line);
  border-radius: 18px;
  background: #FFFFFF;
  box-shadow: var(--shadow-md);
  overflow: hidden;
}
.shot-figure img, .gif-figure img { width: 100%; display: block; }
.gif-figure img { max-height: 640px; object-fit: contain; background: var(--bg-soft); }
.shot-figure figcaption, .gif-figure figcaption {
  padding: 16px 20px;
  font-size: 13.5px;
  line-height: 1.8;
  color: var(--ink-2);
  border-top: 1px solid var(--line);
}
.gif-figure figcaption b, .shot-figure figcaption b { color: var(--ink); }

/* 更新记录：时间线留白与层级 */
.tl-item { padding: 34px 0; gap: 34px; }
.tl-head h3 { font-size: 20px; font-weight: 640; letter-spacing: -0.01em; }
.tl-body p { font-size: 14.5px; line-height: 1.85; }
.tl-body li { font-size: 14px; line-height: 1.8; }
.tl-body li b { min-width: 62px; }
.version-table li { padding: 11px 0; font-size: 14px; }

@media (max-width: 1024px) {
  .chapter { grid-template-columns: 165px minmax(0, 1fr); gap: 30px; }
  .shot-stage { grid-template-columns: 1fr; gap: 26px; padding: 24px; }
  .shot-copy { order: 1; }
  .shot-frame { order: 2; min-height: 0; }
}
@media (max-width: 700px) {
  .section-head { margin-bottom: 34px; }
  .section-head h2 { font-size: 30px; }
  .chapter { grid-template-columns: 1fr; gap: 16px; padding: 30px 0; }
  .chapter-no { position: static; }
  .chapter-body h3 { font-size: 20px; }
  .spec-list li { grid-template-columns: 1fr; gap: 2px; }
  .shot-stage { padding: 16px; border-radius: 14px; }
  .shot-frame { padding: 10px; }
  .shot-frame img, .shot-frame .gif-slide { max-height: 330px; }
  .shot-copy h3 { font-size: 21px; }
  .tl-item { grid-template-columns: 1fr; gap: 14px; }
}
"""


def rewrite_css() -> None:
    text = CSS.read_text(encoding="utf-8")
    if MARK_CSS in text:
        print("site.css: 已是 v229 排版，跳过")
        return
    text = text.rstrip() + "\n" + PREVIEW_CSS + "\n" + MARK_CSS + PAGES_CSS
    CSS.write_text(text, encoding="utf-8")
    print("site.css: 预览重排 + 三页排版已追加")


# ---------------------------------------------------------------- JS
OLD_C7 = '''    { id: "c7", kind: "img", badge: "img",
      title: "屏幕快照 2026-11-05 14.32.png",
      meta: "今天 11:50 · 1024×1024 pt",
      view: "image",
      text: "1024×1024 pt",
      ocr: "订单确认\\n\\n商品：机械键盘 87 键\\n数量：1\\n金额：¥499.00\\n\\n客服电话 400-820-8820" },'''

NEW_C7 = '''    { id: "c7", kind: "img", badge: "img",
      title: "会议室现场 2026-11-05.jpg",
      meta: "今天 11:50 · 1400×935 px",
      view: "image",
      img: "assets/demo/meeting-room.jpg",
      text: "1400×935 px · JPG",
      ocr: {
        text: [
          { tag: "段落 1 · 会议信息", lines: ["Q4 产品评审会", "11 月 5 日 14:00 · 3 号会议室", "参会：产品、设计、客户端、测试"] },
          { tag: "段落 2 · 结论与待办", lines: ["结论：v1.0.0 先走稳定通道", "待办：回滚清单与 SHA-256 校验", "官网下载页与更新清单同步"] }
        ],
        en: [
          { tag: "Paragraph 1 · Meeting", lines: ["Q4 Product Review", "Nov 5, 14:00 · Meeting Room 3", "Attendees: PM, Design, Client, QA"] },
          { tag: "Paragraph 2 · Decision", lines: ["Decision: ship v1.0.0 on the stable channel", "TODO: rollback plan and SHA-256 verification", "Sync the download page and update feed"] }
        ]
      } },'''


def read_file(p):
    return p.read_text(encoding="utf-8")


def rep(text, old, new, label):
    if old not in text:
        print("  ! 未命中：" + label)
        return text
    return text.replace(old, new, 1)


def rewrite_js() -> None:
    text = read_file(JS)
    if "v229" in text:
        print("site.js: 已是 v229，跳过")
        return

    text = rep(text, OLD_C7, NEW_C7, "c7 图片数据")

    old_md_start = "  /* Markdown：渲染成正文（真机 MarkdownPreviewBody） */"
    old_img_start = '/* 图片：缩略图 + 识别文字 / 翻译（真机 PreviewImageView 的 OCR 按钮） */'
    md_start = text.index(old_md_start)
    img_start = text.index(old_img_start)
    foot_start = text.index("  /* 预览底部动作行", img_start)
    new_renderers = r'''  /* v229 Markdown：目录 + 正文（真机 MarkdownPreviewBody，目录可点跳转） */
  function inlineMD(t) {
    var html = esc(t);
    html = html.replace(/`([^`]+)`/g, '<code class="md-code">$1</code>');
    html = html.replace(/\*\*([^*]+)\*\*/g, "<strong>$1</strong>");
    html = html.replace(/\[([^\]]+)\]\(([^)]+)\)/g, '<a href="$2" target="_blank" rel="noopener">$1</a>');
    return html;
  }

  function renderMarkdown(text) {
    var lines = String(text).split("\n");
    var body = "";
    var toc = [];
    var inList = false, inQuote = false;
    function closeList() { if (inList) { body += "</ul>"; inList = false; } }
    function closeQuote() { if (inQuote) { body += "</blockquote>"; inQuote = false; } }
    lines.forEach(function (ln) {
      var t = ln.trim();
      if (!t) { closeList(); closeQuote(); return; }
      var h = t.match(/^(#{1,4})\s+(.*)$/);
      if (h) {
        closeList(); closeQuote();
        var lvl = Math.min(h[1].length, 4);
        var id = "pv-h-" + (toc.length + 1);
        toc.push({ id: id, lvl: lvl, text: h[2].replace(/[*`\[\]]/g, "") });
        body += "<h" + lvl + ' id="' + id + '">' + inlineMD(h[2]) + "</h" + lvl + ">";
        return;
      }
      if (/^(---+|\*\*\*+)$/.test(t)) { closeList(); closeQuote(); body += '<hr class="md-hr">'; return; }
      if (t.charAt(0) === ">") {
        closeList();
        if (!inQuote) { body += "<blockquote>"; inQuote = true; }
        body += "<p>" + inlineMD(t.replace(/^>\s*/, "")) + "</p>";
        return;
      }
      var li = t.match(/^[-*]\s+(.*)$/);
      if (li) {
        closeQuote();
        if (!inList) { body += "<ul>"; inList = true; }
        body += "<li>" + inlineMD(li[1]) + "</li>";
        return;
      }
      var oli = t.match(/^\d+\.\s+(.*)$/);
      if (oli) {
        closeQuote();
        if (!inList) { body += "<ol>"; inList = true; }
        body += "<li>" + inlineMD(oli[1]) + "</li>";
        return;
      }
      closeList(); closeQuote();
      body += "<p>" + inlineMD(t) + "</p>";
    });
    closeList(); closeQuote();

    // 目录不走 href="#..." —— hash 是官网的视图路由，点了会跳页
    var tocHTML = "";
    if (toc.length > 1) {
      tocHTML = '<nav class="pv-md-toc"><span>目录 · ' + toc.length + " 节</span><ul>"
        + toc.map(function (h, i) {
            return '<li class="lvl-' + h.lvl + '"><a href="#" data-md-target="' + h.id + '"'
              + (i === 0 ? ' class="on"' : "") + ">" + esc(h.text) + "</a></li>";
          }).join("")
        + "</ul></nav>";
    }
    return '<div class="pv-md">' + tocHTML
      + '<div class="pv-md-body">' + body + "</div></div>";
  }

  /* v229 图片：真实照片 + 文件信息 + 真机「识别文本 / 翻译」分段结果 */
  function ocrBlocks(list) {
    return (list || []).map(function (b) {
      return '<section class="pv-ocr-block"><span class="pv-ocr-tag">' + esc(b.tag) + "</span>"
        + "<p>" + (b.lines || []).map(esc).join("<br>") + "</p></section>";
    }).join("");
  }

  function renderImage(item) {
    var o = item.ocr || {};
    return '<div class="pv-img">'
      + '<figure class="pv-img-shot">'
      +   '<img src="' + esc(item.img || "assets/demo/meeting-room.jpg") + '" alt="会议场景照片">'
      +   '<figcaption><span class="pv-img-badge">JPG</span>' + esc(item.text || "") + "</figcaption>"
      + "</figure>"
      + '<div class="pv-img-file"><b>' + esc(item.title) + "</b><span>照片 · 本机</span></div>"
      + '<div class="pv-ocr" hidden>'
      +   '<div class="pv-ocr-tabs">'
      +     '<button type="button" class="on" data-pv-tab="text">识别文本</button>'
      +     '<button type="button" data-pv-tab="trans">翻译</button>'
      +   "</div>"
      +   '<div class="pv-ocr-pane" data-pv-pane="text">' + ocrBlocks(o.text) + "</div>"
      +   '<div class="pv-ocr-pane" data-pv-pane="trans" hidden>' + ocrBlocks(o.en) + "</div>"
      + "</div>"
      + "</div>";
  }

'''
    text = text[:md_start] + new_renderers + text[foot_start:]

    old_click = '''  if (pmPreview) {
    pmPreview.addEventListener("click", function (e) {
      var btn = e.target.closest("[data-pv-act]");
      if (!btn) return;
      e.stopPropagation();
      var act = btn.getAttribute("data-pv-act");
      if (act === "ocr") {
        var ocrBox = pmPreview.querySelector(".pv-ocr");
        var title = pmPreview.querySelector(".pm-preview-title").textContent;
        var found = null;
        for (var i = 0; i < clipState.items.length; i++) {
          if (clipState.items[i].title === title) { found = clipState.items[i]; break; }
        }
        if (ocrBox) {
          ocrBox.hidden = false;
          ocrBox.innerHTML = '<span class="pv-ocr-title">识别结果</span><pre>'
            + esc(found && found.ocr ? found.ocr : "未识别到文字") + "</pre>";
        }
        return;
      }
      if (act === "translate") { toast("翻译已开启"); return; }
      if (act === "copy") { toast("已复制"); return; }
    });
  }'''
    new_click = '''  /* v229：目录跳转、识别文本 / 翻译分段、复制 */
  function selectPvTab(root, name) {
    $$("[data-pv-tab]", root).forEach(function (b) {
      b.classList.toggle("on", b.getAttribute("data-pv-tab") === name);
    });
    $$("[data-pv-pane]", root).forEach(function (p) {
      p.hidden = p.getAttribute("data-pv-pane") !== name;
    });
  }

  if (pmPreview) {
    pmPreview.addEventListener("click", function (e) {
      var md = e.target.closest("[data-md-target]");
      if (md) {
        e.preventDefault();
        e.stopPropagation();
        var target = pmPreview.querySelector("#" + md.getAttribute("data-md-target"));
        var body = pmPreview.querySelector(".pm-preview-body");
        if (target && body) {
          // 只滚预览自己的内容区，避免连带滚动面板触发 scroll 监听收掉预览
          var delta = target.getBoundingClientRect().top - body.getBoundingClientRect().top;
          body.scrollTop += delta - 8;
        }
        $$("[data-md-target]", pmPreview).forEach(function (a) {
          a.classList.toggle("on", a === md);
        });
        return;
      }
      var tab = e.target.closest("[data-pv-tab]");
      if (tab) {
        e.stopPropagation();
        selectPvTab(pmPreview, tab.getAttribute("data-pv-tab"));
        return;
      }
      var btn = e.target.closest("[data-pv-act]");
      if (!btn) return;
      e.stopPropagation();
      var act = btn.getAttribute("data-pv-act");
      if (act === "ocr" || act === "translate") {
        var box = pmPreview.querySelector(".pv-ocr");
        if (box) {
          box.hidden = false;
          selectPvTab(pmPreview, act === "translate" ? "trans" : "text");
        }
        return;
      }
      if (act === "copy") { toast("已复制"); return; }
    });
  }'''
    text = rep(text, old_click, new_click, "预览点击委托")

    text = text.replace("var w = pmPreview.offsetWidth || 214;",
                        "var w = pmPreview.offsetWidth || 258;")
    text = text.replace("var h = pmPreview.offsetHeight || 200;",
                        "var h = pmPreview.offsetHeight || 240;")
    text = text.replace('/* ---------------- 预览渲染器（对齐真机 PreviewPopoverContentView） ---------------- */',
                        '/* ---------------- 预览渲染器（v229：对齐真机 PreviewPopoverContentView） ---------------- */')

    JS.write_text(text, encoding="utf-8")
    print("site.js: Markdown 目录 / 真实照片 / OCR 分段 / 点击委托已更新")


# ---------------------------------------------------------------- HTML
def rewrite_html() -> None:
    text = read_file(HTML)
    if 'data-shot="motion"' in text:
        print("index.html: 已接入动图标签，跳过")
        return

    text = rep(text,
               '            <button class="shot-tab" data-shot="cpu" role="tab">CPU 详情窗</button>',
               '            <button class="shot-tab" data-shot="cpu" role="tab">CPU 详情窗</button>\n'
               '            <button class="shot-tab" data-shot="motion" role="tab">操作动图</button>',
               "界面页动图标签")

    old_panel_end = '''              <div data-shot-panel="cpu" hidden>
                <span class="shot-index">06 / CPU</span>
                <h3>谁在吃 CPU</h3>
                <p>总占用环、使用历史曲线、每核心方块、集群占用、平均负载，最下面是占用最高的进程。</p>
                <ul class="shot-points">
                  <li><b>总览</b>系统 / 用户 / 空闲三段拆开算</li>
                  <li><b>集群</b>性能核与能效核分开显示</li>
                  <li><b>刷新</b>1.5 秒一次</li>
                </ul>
              </div>'''
    new_panel_end = old_panel_end + '''
              <div data-shot-panel="motion" hidden>
                <span class="shot-index">07 / MOTION</span>
                <h3>从框选到复制，一气呵成</h3>
                <p>录自真机交互流程：区域框选、动作条、矩形与箭头标注、马赛克遮盖，最后复制回剪贴板。</p>
                <ul class="shot-points">
                  <li><b>快捷键</b>⌥S 区域 / ⇧⌥W 窗口 / ⇧⌥L 长截图</li>
                  <li><b>标注</b>矩形、箭头、马赛克逐项上手</li>
                  <li><b>收尾</b>复制、贴图、识字、翻译都在动作条里</li>
                </ul>
              </div>'''
    text = rep(text, old_panel_end, new_panel_end, "界面页动图说明")

    old_slide_end = '''              <div data-shot-slide="cpu" hidden>
                <img src="assets/shots/popout-cpu.png" alt="Kitnest CPU 详情窗实机截图" data-shot-file="assets/shots/popout-cpu.png">
              </div>'''
    new_slide_end = old_slide_end + '''
              <div data-shot-slide="motion" hidden>
                <img class="gif-slide" src="assets/gifs/capture-flow.gif" alt="Kitnest 截图与标注全流程动图" data-shot-file="assets/gifs/capture-flow.gif">
              </div>'''
    text = rep(text, old_slide_end, new_slide_end, "界面页动图幻灯")

    old_note = '''              <p class="preview-note">工具区、颜色与粗细、撤销与导出，三段排布。</p>'''
    new_note = old_note + '''
              <figure class="inline-gif">
                <img src="assets/gifs/capture-flow.gif" alt="Kitnest 截图与标注全流程动图" loading="lazy">
                <figcaption>完整流程动图：⌥S 框选 → 动作条 → 标注 → 复制。画面为模拟内容，不含任何真实数据。</figcaption>
              </figure>'''
    text = rep(text, old_note, new_note, "功能页内嵌动图")

    HTML.write_text(text, encoding="utf-8")
    print("index.html: 动图标签 / 幻灯 / 功能页内嵌动图已接入")


def main() -> int:
    rewrite_css()
    rewrite_js()
    rewrite_html()
    return 0


if __name__ == "__main__":
    sys.exit(main())
