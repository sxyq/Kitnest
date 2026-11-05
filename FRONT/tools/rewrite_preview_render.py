#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""给官网 mock 的剪贴板预览写**真实渲染器**，对齐真机 PreviewPopoverContentView。

分态与真机一致（PreviewPopoverContentModel.Kind）：
  text / fileBackedText → 纯文本
  markdown              → 渲染成正文（标题 / 列表 / 粗体 / 行内码 / 引用 / 分隔线 / 链接）
  json                  → 树形（键 / 字符串 / 数字 / 布尔 / null 分色），不是纯文本
  code                  → 行号 + 语法高亮（关键字 / 字符串 / 注释 / 数字）
  image                 → 缩略图 + 「识别文字」「翻译」按钮（OCR 文本写死，但按钮可点）
  file                  → 文件信息
"""
import io, os, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PATH = os.path.join(ROOT, 'assets', 'site.js')
s = io.open(PATH, encoding='utf-8').read()

anchor = '  function showPreview(item, anchorEl, pinned) {'
if anchor not in s:
    sys.exit('锚点没找到')

BLOCK = u'''  /* ---------------- 预览渲染器（对齐真机 PreviewPopoverContentView） ---------------- */

  function esc(t) {
    return String(t == null ? "" : t)
      .replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
      .replace(/"/g, "&quot;");
  }

  /* JSON：树形视图（真机 JSONInspectorView），键与值分色 */
  function renderJSONTree(text) {
    var data;
    try {
      data = JSON.parse(text);
    } catch (e) {
      return '<pre class="pv-raw">' + esc(text) + "</pre>";
    }
    var out = '<div class="pv-tree">';
    (function walk(v, depth) {
      var pad = depth * 12;
      if (Array.isArray(v)) {
        out += '<div class="pv-row" style="padding-left:' + pad + 'px"><span class="pv-bracket">[</span></div>';
        v.forEach(function (item, i) {
          walk(item, depth + 1);
          if (i < v.length - 1) out += '<div class="pv-row" style="padding-left:' + (depth + 1) * 12 + 'px"><span class="pv-comma">,</span></div>';
        });
        out += '<div class="pv-row" style="padding-left:' + pad + 'px"><span class="pv-bracket">]</span></div>';
        return;
      }
      if (v && typeof v === "object") {
        out += '<div class="pv-row" style="padding-left:' + pad + 'px"><span class="pv-bracket">{</span></div>';
        var keys = Object.keys(v);
        keys.forEach(function (k, i) {
          out += '<div class="pv-row" style="padding-left:' + (depth + 1) * 12 + 'px">'
            + '<span class="pv-key">"' + esc(k) + '"</span><span class="pv-colon">:</span>';
          walk(v[k], depth + 1);
          if (i < keys.length - 1) out += '<span class="pv-comma">,</span>';
          out += "</div>";
        });
        out += '<div class="pv-row" style="padding-left:' + pad + 'px"><span class="pv-bracket">}</span></div>';
        return;
      }
      var cls = "pv-val";
      if (typeof v === "string") cls = "pv-str";
      else if (typeof v === "number") cls = "pv-num";
      else if (typeof v === "boolean") cls = "pv-bool";
      else if (v === null) cls = "pv-null";
      out += '<span class="' + cls + '">' + esc(String(v)) + "</span>";
    })(data, 0);
    return out + "</div>";
  }

  /* 代码：行号 + 语法高亮（真机 CodePreviewView） */
  var CODE_KW = {
    swift: ["import", "struct", "func", "let", "var", "return", "for", "in", "if", "else", "print", "default", "class", "enum", "self", "nil", "true", "false", "while", "guard", "init", "static", "public", "private"],
    python: ["import", "from", "def", "return", "for", "in", "if", "else", "with", "as", "print", "class", "None", "True", "False", "lambda", "try", "except", "while", "break", "continue", "self", "not", "and", "or", "yield", "pass"],
    json: [], text: [], md: []
  };

  function highlightLine(line, lang) {
    var html = esc(line);
    // 注释
    html = html.replace(/(#.*)$/g, '<span class="c-com">$1</span>');
    html = html.replace(/(\/\/.*)$/g, '<span class="c-com">$1</span>');
    // 字符串
    html = html.replace(/(&quot;[^&]*?&quot;|&#39;[^&]*?&#39;|"[^"\n]*"|\'[^\'\n]*\')/g,
      '<span class="c-str">$1</span>');
    // 数字
    html = html.replace(/\\b(\\d+(?:\\.\\d+)?)\\b/g, '<span class="c-num">$1</span>');
    // 关键字
    var kws = CODE_KW[lang] || [];
    if (kws.length) {
      kws.forEach(function (k) {
        html = html.replace(new RegExp("\\\\b(" + k + ")\\\\b", "g"), '<span class="c-kw">$1</span>');
      });
    }
    return html;
  }

  function renderCode(text, lang) {
    var lines = String(text).split("\\n");
    var out = '<div class="pv-code"><table>';
    lines.forEach(function (ln, i) {
      out += '<tr><td class="c-ln">' + (i + 1) + '</td><td class="c-src">'
        + (highlightLine(ln, lang) || "&nbsp;") + "</td></tr>";
    });
    return out + "</table></div>";
  }

  /* Markdown：渲染成正文（真机 MarkdownPreviewBody） */
  function inlineMD(t) {
    var html = esc(t);
    html = html.replace(/`([^`]+)`/g, '<code class="md-code">$1</code>');
    html = html.replace(/\\*\\*([^*]+)\\*\\*/g, "<strong>$1</strong>");
    html = html.replace(/\\[([^\\]]+)\\]\\(([^)]+)\\)/g, '<a href="$2" target="_blank" rel="noopener">$1</a>');
    return html;
  }

  function renderMarkdown(text) {
    var lines = String(text).split("\\n");
    var out = '<div class="pv-md">';
    var inList = false, inQuote = false;
    function closeList() { if (inList) { out += "</ul>"; inList = false; } }
    function closeQuote() { if (inQuote) { out += "</blockquote>"; inQuote = false; } }
    lines.forEach(function (ln) {
      var t = ln.trim();
      if (!t) { closeList(); closeQuote(); return; }
      var h = t.match(/^(#{1,4})\\s+(.*)$/);
      if (h) {
        closeList(); closeQuote();
        var lvl = Math.min(h[1].length, 4);
        out += "<h" + lvl + '>' + inlineMD(h[2]) + "</h" + lvl + ">";
        return;
      }
      if (/^(---+|\\*\\*\\*+)$/.test(t)) { closeList(); closeQuote(); out += '<hr class="md-hr">'; return; }
      if (t.charAt(0) === ">") {
        closeList();
        if (!inQuote) { out += "<blockquote>"; inQuote = true; }
        out += "<p>" + inlineMD(t.replace(/^>\\s*/, "")) + "</p>";
        return;
      }
      var li = t.match(/^[-*]\\s+(.*)$/);
      if (li) {
        closeQuote();
        if (!inList) { out += "<ul>"; inList = true; }
        out += "<li>" + inlineMD(li[1]) + "</li>";
        return;
      }
      var oli = t.match(/^\\d+\\.\\s+(.*)$/);
      if (oli) {
        closeQuote();
        if (!inList) { out += "<ol>"; inList = true; }
        out += "<li>" + inlineMD(oli[1]) + "</li>";
        return;
      }
      closeList(); closeQuote();
      out += "<p>" + inlineMD(t) + "</p>";
    });
    closeList(); closeQuote();
    return out + "</div>";
  }

  /* 图片：缩略图 + 识别文字 / 翻译（真机 PreviewImageView 的 OCR 按钮） */
  function renderImage(item) {
    return '<div class="pv-img">'
      + '<div class="pv-img-thumb"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.4" stroke-linecap="round" stroke-linejoin="round">'
      + '<rect x="3.5" y="4.5" width="17" height="15" rx="2"/><circle cx="9" cy="10" r="1.5"/>'
      + '<path d="m4.5 17.5 4.5-4.5 3.5 3.5 3-3 4 4"/></svg></div>'
      + '<div class="pv-img-meta">' + esc(item.text || "") + "</div>"
      + '<div class="pv-img-acts">'
      + '<button type="button" data-pv-act="ocr">识别文字</button>'
      + '<button type="button" data-pv-act="translate">翻译</button>'
      + "</div>"
      + '<div class="pv-ocr" hidden></div>'
      + "</div>";
  }

  /* 预览底部动作行：真机预览可复制，图片可识别 / 翻译 */
  function renderPreviewFoot(item) {
    var acts = [];
    if (item.view === "image") {
      acts.push('<button type="button" data-pv-act="ocr">识别文字</button>');
      acts.push('<button type="button" data-pv-act="translate">翻译</button>');
    }
    acts.push('<button type="button" data-pv-act="copy">复制</button>');
    return acts.join("");
  }

  var PREVIEW_KIND = {
    text: "文字", url: "链接", md: "Markdown", json: "JSON",
    code: "代码", img: "图片", file: "文件"
  };

  function renderPreviewBody(item) {
    if (item.view === "json") return renderJSONTree(item.text);
    if (item.view === "code") return renderCode(item.text, item.lang || "text");
    if (item.view === "markdown") return renderMarkdown(item.text);
    if (item.view === "image") return renderImage(item);
    if (item.view === "url") {
      return '<div class="pv-text"><span class="pv-url">' + esc(item.text) + "</span></div>";
    }
    return '<div class="pv-text">' + esc(item.text || item.title) + "</div>";
  }

'''

s = s.replace(anchor, BLOCK + anchor)

# showPreview 改成用渲染器
old_show = '''    pmPreview.querySelector(".pm-preview-body").innerHTML = item.preview;
    pmPreview.hidden = false;'''
new_show = '''    pmPreview.querySelector(".pm-preview-kind").textContent =
      PREVIEW_KIND[item.view] || "内容";
    pmPreview.querySelector(".pm-preview-title").textContent = item.title;
    pmPreview.querySelector(".pm-preview-body").innerHTML = renderPreviewBody(item);
    pmPreview.querySelector(".pm-preview-foot").innerHTML = renderPreviewFoot(item);
    pmPreview.hidden = false;'''
assert old_show in s
s = s.replace(old_show, new_show)

# 预览里的按钮交互：识别文字 / 翻译 / 复制
old_act = '''  if (pmPreview) {
    pmPreview.addEventListener("click", function (e) {'''
new_act = '''  if (pmPreview) {
    pmPreview.addEventListener("click", function (e) {
      var btn = e.target.closest("[data-pv-act]");
      if (btn) {
        e.stopPropagation();
        var act = btn.getAttribute("data-pv-act");
        var ocrBox = pmPreview.querySelector(".pv-ocr");
        if (act === "ocr" && ocrBox) {
          var item = clipState.ctxItem || null;
          var cur = pmPreview.querySelector(".pm-preview-title");
          var found = null;
          for (var i = 0; i < clipState.items.length; i++) {
            if (clipState.items[i].title === cur.textContent) { found = clipState.items[i]; break; }
          }
          if (found && found.ocr) {
            ocrBox.hidden = false;
            ocrBox.innerHTML = '<span class="pv-ocr-title">识别结果</span>'
              + "<pre>" + esc(found.ocr) + "</pre>";
          } else {
            ocrBox.hidden = false;
            ocrBox.innerHTML = '<span class="pv-ocr-title">识别结果</span><pre>未识别到文字</pre>';
          }
          return;
        }
        if (act === "translate") {
          toast("翻译已开启");
          return;
        }
        if (act === "copy") {
          toast("已复制");
          return;
        }
      }
    });
  }

  if (pmPreview) {
    pmPreview.addEventListener("click", function (e) {'''
if old_act in s:
    s = s.replace(old_act, new_act, 1)
else:
    print('（预览按钮交互未挂上：锚点没找到）')

io.open(PATH, 'w', encoding='utf-8').write(s)
print('渲染器已写入，JS %d 行' % len(s.split('\n')))
