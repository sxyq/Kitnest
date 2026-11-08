#!/usr/bin/env python3
"""把用户手册 Markdown 生成官网在线版（FRONT/manual/index.html）。

为什么要有这个页面：手册里的演示 GIF 只在文档目录里，装了 DMG 的人看不到，
没装 App 的人更看不到。在线版是「别人怎么读」的答案——一个链接就能看全 37 章。

用法：
    python3 tools/make_manual_site.py            # 生成 + 把 gifs 链进 FRONT/manual/gifs
    python3 tools/make_manual_site.py --no-gifs  # 只生成 html（gifs 已就位时）

设计约束：
  · 单文件 HTML，不依赖构建工具与 CDN；
  · 图片走 loading="lazy"，37 段 GIF 合计 38 MB，首屏只加载看得见的那几张；
  · 侧栏目录 + 滚动高亮 + 正文搜索，键盘 / 手机都能用；
  · 配色与官网 assets/site.css 同一套变量，视觉不割裂。
"""

from __future__ import annotations

import argparse
import html
import os
import re
import shutil
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SRC = ROOT / "docs/40-审计与核对/性能审计/用户手册-FrsetNext.md"
GIFS = ROOT / "docs/40-审计与核对/性能审计/gifs"
OUT_DIR = ROOT / "FRONT/manual"


# ---------------------------------------------------------------- 行内标记

def inline(text: str) -> str:
    """行内 Markdown → HTML。先转义，再按顺序还原标记。"""
    s = html.escape(text, quote=False)
    # 行内代码优先：先摘出来，避免里面的 * _ 被当成强调
    spans: list[str] = []

    def stash(m: re.Match) -> str:
        spans.append("<code>" + m.group(1) + "</code>")
        return f"\x00{len(spans) - 1}\x00"

    s = re.sub(r"`([^`]+)`", stash, s)
    s = re.sub(r"\*\*([^*]+)\*\*", r"<strong>\1</strong>", s)
    s = re.sub(r"(?<!\*)\*([^*]+)\*(?!\*)", r"<em>\1</em>", s)
    s = re.sub(r"\[([^\]]+)\]\(([^)\s]+)\)", r'<a href="\2">\1</a>', s)
    s = re.sub(r"(?<![\"'>])(https?://[^\s<)]+)", r'<a href="\1">\1</a>', s)

    def pop(m: re.Match) -> str:
        return spans[int(m.group(1))]

    return re.sub(r"\x00(\d+)\x00", pop, s)


# ---------------------------------------------------------------- 块级解析

def slugify(text: str, seen: dict[str, int]) -> str:
    """中文标题做锚点：保留中文（浏览器能处理），去掉标点与空白。"""
    s = re.sub(r"[`*_\[\]()（）「」【】]", "", text)
    s = re.sub(r"[^\w\u4e00-\u9fff-]+", "-", s).strip("-").lower()
    s = s or "sec"
    n = seen.get(s, 0)
    seen[s] = n + 1
    return s if n == 0 else f"{s}-{n}"


def parse(md: str) -> tuple[str, list[dict], list[dict]]:
    """返回 (文档标题, 章节列表, 正文 HTML 片段列表)。"""
    lines = md.splitlines()
    title = "Kitnest 用户手册"
    chapters: list[dict] = []
    body: list[str] = []
    seen: dict[str, int] = {}

    i, n = 0, len(lines)
    current_chapter: dict | None = None

    while i < n:
        raw = lines[i]
        line = raw.rstrip()
        stripped = line.strip()

        # 代码块
        if stripped.startswith("```"):
            i += 1
            buf = []
            while i < n and not lines[i].strip().startswith("```"):
                buf.append(lines[i])
                i += 1
            i += 1
            body.append("<pre><code>" + html.escape("\n".join(buf)) + "</code></pre>")
            continue

        # 分隔线
        if re.fullmatch(r"-{3,}|\*{3,}", stripped):
            body.append("<hr>")
            i += 1
            continue

        # 标题
        m = re.match(r"^(#{1,4})\s+(.*)$", stripped)
        if m:
            level, text = len(m.group(1)), m.group(2).strip()
            if level == 1 and i < 3:
                title = text
                i += 1
                continue
            sid = slugify(text, seen)
            if level == 2:
                current_chapter = {"id": sid, "title": text}
                chapters.append(current_chapter)
                body.append(f'<h2 id="{sid}">{inline(text)}</h2>')
            else:
                body.append(f'<h{level} id="{sid}">{inline(text)}</h{level}>')
            i += 1
            continue

        # 表格：连续以 | 开头的行
        if stripped.startswith("|") and i + 1 < n and re.match(r"^\|[\s:|-]+\|?$", lines[i + 1].strip()):
            rows: list[list[str]] = []
            while i < n and lines[i].strip().startswith("|"):
                cells = [c.strip() for c in lines[i].strip().strip("|").split("|")]
                rows.append(cells)
                i += 1
            head, *rest = rows
            rest = [r for r in rest if not re.match(r"^[\s:|-]+$", "".join(r))]
            out = ['<div class="table-wrap"><table><thead><tr>']
            out += [f"<th>{inline(c)}</th>" for c in head]
            out.append("</tr></thead><tbody>")
            for r in rest:
                out.append("<tr>" + "".join(f"<td>{inline(c)}</td>" for c in r) + "</tr>")
            out.append("</tbody></table></div>")
            body.append("".join(out))
            continue

        # 引用（连续多行合并）
        if stripped.startswith(">"):
            buf = []
            while i < n and lines[i].strip().startswith(">"):
                buf.append(lines[i].strip()[1:].strip())
                i += 1
            body.append("<blockquote>" + inline(" ".join(buf)) + "</blockquote>")
            continue

        # 图片单独成行
        m = re.fullmatch(r"!\[([^\]]*)\]\(([^)]+)\)", stripped)
        if m:
            alt, src = m.group(1), m.group(2)
            body.append(
                f'<figure><img src="{html.escape(src)}" alt="{html.escape(alt)}" loading="lazy" '
                f'decoding="async"><figcaption>{inline(alt)}</figcaption></figure>'
            )
            i += 1
            continue

        # 无序列表
        if re.match(r"^[-*]\s+", stripped):
            items = []
            while i < n and re.match(r"^[-*]\s+", lines[i].strip()):
                items.append(re.sub(r"^[-*]\s+", "", lines[i].strip()))
                i += 1
            body.append("<ul>" + "".join(f"<li>{inline(t)}</li>" for t in items) + "</ul>")
            continue

        # 有序列表
        if re.match(r"^\d+[.)]\s+", stripped):
            items = []
            while i < n and re.match(r"^\d+[.)]\s+", lines[i].strip()):
                items.append(re.sub(r"^\d+[.)]\s+", "", lines[i].strip()))
                i += 1
            body.append("<ol>" + "".join(f"<li>{inline(t)}</li>" for t in items) + "</ol>")
            continue

        # 空行
        if not stripped:
            i += 1
            continue

        # 段落：连续非空行合并
        buf = []
        while i < n:
            s2 = lines[i].strip()
            if (not s2 or s2.startswith(("#", ">", "|", "```"))
                    or re.match(r"^[-*]\s+", s2) or re.match(r"^\d+[.)]\s+", s2)
                    or re.fullmatch(r"!\[([^\]]*)\]\(([^)]+)\)", s2)):
                break
            buf.append(s2)
            i += 1
        if buf:
            body.append("<p>" + inline(" ".join(buf)) + "</p>")

    return title, chapters, body


# ---------------------------------------------------------------- 页面模板

PAGE = """<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0, viewport-fit=cover">
<meta name="theme-color" content="#ffffff">
<title>{title} · Kitnest</title>
<meta name="description" content="Kitnest 用户手册在线版：{nchap} 章，每章一段真机录屏动图。">
<link rel="icon" type="image/svg+xml" href="../assets/kitnest-mark.svg">
<style>
:root {{
  --bg:#FFFFFF; --bg-soft:#FAFAFB; --bg-mute:#F4F4F6;
  --ink:#0B0B0D; --ink-2:#4A4A52; --ink-3:#8A8A94;
  --line:#EAEAEE; --line-strong:#DCDCE2;
  --accent:#2F6BFF; --accent-deep:#1E52D6; --accent-soft:#EEF3FF;
  --radius:12px; --radius-sm:8px;
  --sans:-apple-system,BlinkMacSystemFont,"SF Pro Text","PingFang SC","HarmonyOS Sans SC","MiSans","Microsoft YaHei","Segoe UI",system-ui,sans-serif;
  --mono:ui-monospace,"SF Mono","JetBrains Mono",Menlo,Consolas,monospace;
}}
*{{box-sizing:border-box;margin:0;padding:0}}
html{{scroll-behavior:smooth;-webkit-text-size-adjust:100%;scroll-padding-top:76px}}
body{{font-family:var(--sans);background:var(--bg);color:var(--ink);line-height:1.75;font-size:15.5px;-webkit-font-smoothing:antialiased}}

.top{{position:sticky;top:0;z-index:30;background:rgba(255,255,255,.86);backdrop-filter:saturate(180%) blur(14px);border-bottom:1px solid var(--line)}}
.top-in{{max-width:1240px;margin:0 auto;padding:11px 22px;display:flex;align-items:center;gap:14px}}
.brand{{display:flex;align-items:center;gap:8px;font-weight:640;letter-spacing:-.01em;color:var(--ink);text-decoration:none;font-size:15px}}
.brand img{{width:20px;height:20px}}
.brand small{{font-weight:450;color:var(--ink-3);font-size:12px;margin-left:2px}}
.spacer{{flex:1}}
.search{{display:flex;align-items:center;gap:7px;background:var(--bg-mute);border:1px solid var(--line);border-radius:9px;padding:6px 11px;min-width:220px}}
.search input{{border:0;background:transparent;outline:0;font:inherit;font-size:13px;width:100%;color:var(--ink)}}
.search svg{{flex:none;opacity:.45}}
.back{{font-size:13px;color:var(--ink-2);text-decoration:none;padding:5px 10px;border-radius:8px}}
.back:hover{{background:var(--bg-mute);color:var(--ink)}}

.layout{{max-width:1240px;margin:0 auto;padding:0 22px;display:grid;grid-template-columns:250px minmax(0,1fr);gap:40px;align-items:start}}
aside{{position:sticky;top:69px;max-height:calc(100vh - 90px);overflow:auto;padding:24px 0 60px;font-size:13px;scrollbar-width:thin}}
aside::-webkit-scrollbar{{width:6px}}
aside::-webkit-scrollbar-thumb{{background:var(--line-strong);border-radius:3px}}
.toc-label{{font-size:11px;letter-spacing:.08em;text-transform:uppercase;color:var(--ink-3);padding:0 10px 8px;font-weight:600}}
aside a{{display:block;padding:5px 10px;border-radius:7px;color:var(--ink-2);text-decoration:none;border-left:2px solid transparent;line-height:1.45}}
aside a:hover{{background:var(--bg-soft);color:var(--ink)}}
aside a.on{{background:var(--accent-soft);color:var(--accent-deep);border-left-color:var(--accent);font-weight:550}}
aside a.hide{{display:none}}

main{{padding:30px 0 120px;max-width:820px}}
main h1{{font-size:32px;line-height:1.25;letter-spacing:-.02em;margin:8px 0 18px;font-weight:680}}
main h2{{font-size:23px;line-height:1.3;letter-spacing:-.015em;margin:56px 0 16px;padding-top:14px;border-top:1px solid var(--line);font-weight:660}}
main h2:first-of-type{{margin-top:24px}}
main h3{{font-size:17px;margin:30px 0 10px;font-weight:640;letter-spacing:-.01em}}
main h4{{font-size:14.5px;margin:22px 0 8px;font-weight:640;color:var(--ink-2)}}
main p{{margin:11px 0;color:var(--ink-2)}}
main strong{{color:var(--ink);font-weight:620}}
main ul,main ol{{margin:11px 0 11px 22px;color:var(--ink-2)}}
main li{{margin:5px 0}}
main hr{{border:0;border-top:1px solid var(--line);margin:34px 0}}
main a{{color:var(--accent);text-decoration:none;border-bottom:1px solid rgba(47,107,255,.25)}}
main a:hover{{border-bottom-color:var(--accent)}}
code{{font-family:var(--mono);font-size:.88em;background:var(--bg-mute);padding:1.5px 5px;border-radius:5px;color:#2A2A32}}
pre{{background:var(--bg-soft);border:1px solid var(--line);border-radius:var(--radius);padding:14px 16px;overflow:auto;margin:14px 0}}
pre code{{background:transparent;padding:0;font-size:12.5px;line-height:1.6}}
blockquote{{border-left:2px solid var(--line-strong);padding:2px 0 2px 14px;margin:14px 0;color:var(--ink-2);font-size:14.5px}}
blockquote code{{font-size:.9em}}

.table-wrap{{overflow-x:auto;margin:16px 0;border:1px solid var(--line);border-radius:var(--radius)}}
table{{border-collapse:collapse;width:100%;font-size:13.5px;min-width:460px}}
th,td{{text-align:left;padding:9px 13px;border-bottom:1px solid var(--line);vertical-align:top}}
th{{background:var(--bg-soft);font-weight:620;color:var(--ink);white-space:nowrap;font-size:12.5px}}
tr:last-child td{{border-bottom:0}}
td{{color:var(--ink-2)}}

figure{{margin:18px 0 22px}}
figure img{{width:100%;max-width:760px;border-radius:var(--radius);border:1px solid var(--line);display:block;cursor:zoom-in;background:var(--bg-mute)}}
figcaption{{font-size:12.5px;color:var(--ink-3);margin-top:8px;line-height:1.6}}

.empty{{color:var(--ink-3);padding:40px 0}}

.lightbox{{position:fixed;inset:0;background:rgba(11,11,13,.82);display:none;align-items:center;justify-content:center;z-index:80;padding:30px;cursor:zoom-out}}
.lightbox.on{{display:flex}}
.lightbox img{{max-width:96vw;max-height:92vh;border-radius:8px;box-shadow:0 30px 80px rgba(0,0,0,.4)}}

@media (max-width:900px){{
  .layout{{grid-template-columns:1fr;gap:0}}
  aside{{position:static;max-height:none;border-bottom:1px solid var(--line);padding:14px 0;margin-bottom:8px}}
  aside .toc-list{{display:flex;flex-wrap:wrap;gap:4px}}
  aside a{{border-left:0;padding:4px 9px;font-size:12.5px;border:1px solid var(--line)}}
  aside a.on{{border-color:var(--accent)}}
  main{{padding-top:18px}}
  main h1{{font-size:25px}}
  main h2{{font-size:19px;margin-top:38px}}
  .search{{min-width:0;flex:1}}
  .brand small{{display:none}}
}}
</style>
</head>
<body>

<header class="top">
  <div class="top-in">
    <a class="brand" href="../"><img src="../assets/kitnest-mark.svg" alt="">Kitnest<small>用户手册</small></a>
    <div class="spacer"></div>
    <label class="search">
      <svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.4"><circle cx="11" cy="11" r="7"/><path d="m20 20-3.5-3.5"/></svg>
      <input id="q" type="search" placeholder="搜索章节…" autocomplete="off">
    </label>
    <a class="back" href="../">返回官网</a>
  </div>
</header>

<div class="layout">
  <aside>
    <div class="toc-label">{nchap} 章 · 点标题跳转</div>
    <div class="toc-list" id="toc">
{toc}
    </div>
  </aside>
  <main id="doc">
{body}
  </main>
</div>

<div class="lightbox" id="lb"><img alt=""></div>

<script>
(function () {{
  var links = Array.prototype.slice.call(document.querySelectorAll('#toc a'));
  var heads = links.map(function (a) {{ return document.getElementById(a.dataset.target); }});
  var q = document.getElementById('q');

  // 滚动高亮：取最后一个越过阈值线的标题
  function spy() {{
    var y = window.scrollY + 110, idx = 0;
    for (var i = 0; i < heads.length; i++) {{
      if (heads[i] && heads[i].offsetTop <= y) idx = i;
    }}
    links.forEach(function (a, i) {{ a.classList.toggle('on', i === idx); }});
  }}
  var tick = false;
  window.addEventListener('scroll', function () {{
    if (tick) return;
    tick = true;
    requestAnimationFrame(function () {{ spy(); tick = false; }});
  }}, {{ passive: true }});
  spy();

  // 搜索：按标题过滤；有命中的章节保留
  q.addEventListener('input', function () {{
    var v = q.value.trim().toLowerCase();
    links.forEach(function (a) {{
      a.classList.toggle('hide', v && a.textContent.toLowerCase().indexOf(v) < 0);
    }});
  }});

  // 图片放大
  var lb = document.getElementById('lb'), lbImg = lb.querySelector('img');
  document.querySelectorAll('figure img').forEach(function (img) {{
    img.addEventListener('click', function () {{
      lbImg.src = img.src;
      lb.classList.add('on');
    }});
  }});
  lb.addEventListener('click', function () {{
    lb.classList.remove('on');
    lbImg.removeAttribute('src');
  }});
  document.addEventListener('keydown', function (e) {{
    if (e.key === 'Escape') {{ lb.classList.remove('on'); }}
    if (e.key === '/' && document.activeElement !== q) {{ e.preventDefault(); q.focus(); }}
  }});
}})();
</script>
</body>
</html>
"""


def build(no_gifs: bool) -> None:
    md = SRC.read_text(encoding="utf-8")
    title, chapters, body = parse(md)

    toc = "\n".join(
        f'      <a href="#{c["id"]}" data-target="{c["id"]}">{html.escape(c["title"])}</a>'
        for c in chapters
    )

    OUT_DIR.mkdir(parents=True, exist_ok=True)
    page = PAGE.format(
        title=html.escape(title),
        nchap=len(chapters),
        toc=toc,
        body="\n".join(body),
    )
    out = OUT_DIR / "index.html"
    out.write_text(page, encoding="utf-8")

    size_kb = out.stat().st_size / 1024
    print(f"  HTML: {out.relative_to(ROOT)}  {size_kb:.0f} KB  {len(chapters)} 章")

    if not no_gifs:
        dst = OUT_DIR / "gifs"
        if dst.exists():
            shutil.rmtree(dst)
        dst.mkdir(parents=True)
        n = 0
        total = 0
        for g in sorted(GIFS.glob("*.gif")):
            shutil.copy2(g, dst / g.name)
            n += 1
            total += g.stat().st_size
        print(f"  GIF:  {n} 段 → {dst.relative_to(ROOT)}  ({total / 1048576:.1f} MB)")

    # 自检：正文引用的图是否都在
    refs = re.findall(r'<img src="([^"]+)"', page)
    missing = [r for r in refs if not (OUT_DIR / r).exists()]
    print(f"  图片引用 {len(refs)} 处，缺失 {len(missing)} 处" + (f"：{missing[:3]}" if missing else ""))


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--no-gifs", action="store_true", help="不复制 GIF（已就位时用）")
    a = ap.parse_args()
    build(a.no_gifs)


if __name__ == "__main__":
    main()
