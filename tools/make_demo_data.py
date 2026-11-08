#!/usr/bin/env python3
"""生成一套「纯演示」的 Kitnest 数据目录，供手册录屏使用。

为什么需要
----------
手册的 GIF 是公开的，但剪贴板历史里全是个人内容：VPN 订阅链接（含 token）、
服务器地址、SSH 备忘、工作待办…… 只要有浮层预览，就会整段被拍进去。
靠马赛克逐一遮不现实，正确做法是**录制时根本不碰真实数据**：

    KITNEST_DATA_DIR=/tmp/kitnest-demo open ...   # App 读隔离目录
    python3 tools/make_demo_data.py               # 灌演示内容
    → 录完 rm -rf /tmp/kitnest-demo，个人数据一条没动

内容约定
--------
· 域名一律 example.com / example.org；
· 路径一律 /Users/demo；
· 邮箱 demo@example.com；
· 不出现任何真实项目名、服务器 IP、token。
"""

from __future__ import annotations

import hashlib
import os
import random
import shutil
import sqlite3
import subprocess
import time
from pathlib import Path

REAL = Path.home() / "Library/Application Support/FrsetNext"
DEMO = Path("/tmp/kitnest-demo")

# 演示图片：尺寸 + 主色 + 标题，画成「看起来像截图」的卡片
IMAGES = [
    ("发布清单.html", 1280, 800, "#FFFFFF", "Release checklist"),
    ("季度用量.png", 960, 600, "#F6F8FC", "Weekly usage"),
    ("parse_demo.py", 1100, 640, "#1E1E24", "parse_demo.py"),
    ("配色参考.png", 880, 520, "#FFFFFF", "Palette"),
]

TEXTS = [
    ("text", "会议纪要 10/24\n\n1. 导出流程拆成两步：先选范围，再选格式\n"
             "2. 长截图接缝问题交给合成层处理\n3. 下周给出性能对比数据", "文本 · 会议纪要"),
    ("url", "https://example.com/docs/getting-started", "example.com"),
    ("text", "select type, count(*)\nfrom clipboard_items\n"
             "where timestamp > strftime('%s','now','-7 days')\n"
             "group by type\norder by 2 desc;", "文本 · 查询"),
    ("richtext", "需求说明\n\n面板需要支持键盘导航：Tab 在分段之间移动，"
                 "Enter 进入详情，Esc 逐层返回。列表项要能被读屏软件正确朗读，"
                 "标题与副标题分开标注。", "富文本 · 需求说明"),
    ("text", "{\n  \"name\": \"kit-demo\",\n  \"version\": \"1.0.0\",\n"
             "  \"features\": [\"capture\", \"clipboard\", \"record\"]\n}", "文本 · JSON"),
    ("url", "https://github.com/example/kit-demo", "github.com"),
    ("file", "设计稿-v2.sketch", "file"),
    ("text", "def parse(raw: str) -> list[str]:\n    \"\"\"按空白切分，保留引号内的空格。\"\"\"\n"
             "    return [p.strip('\"') for p in raw.split() if p]", "文本 · 代码"),
    ("text", "把「首选项」里的同步开关默认关掉：本地优先，"
             "需要时再手动开启。这条要在发布说明里写清楚。", "文本 · 备注"),
    ("url", "https://example.org/blog/notes-on-focus", "example.org"),
    ("file", "季度预算.xlsx", "file"),
    ("text", "demo@example.com", "文本 · 邮箱"),
    ("text", ".card {\n  border-radius: 12px;\n  border: 1px solid #EAEAEE;\n"
             "  padding: 16px 18px;\n}", "文本 · 样式"),
    ("text", "待办\n- [ ] 补齐录屏的权限说明\n- [ ] 检查长截图的接缝\n"
             "- [x] 面板搜索支持拼音首字母", "文本 · 待办"),
    ("text", "「如果用户只想要一次截图，就别让他先选模式。」——评审记录", "文本 · 摘录"),
    ("richtext", "版本说明\n\n本次更新修掉了三处会导致列表滚动卡顿的问题，"
                 "并把截图历史的缩略图改成按需生成，首次打开更快。", "富文本 · 版本说明"),
    ("url", "https://example.com/guide/shortcuts", "example.com"),
    ("text", "ssh demo@192.0.2.10", "文本 · 命令"),
    ("text", "The quick brown fox jumps over the lazy dog. "
             "中英混排的一段文字，用来检查换行与字重。", "文本 · 混排"),
    ("text", "导出格式支持 PNG / JPEG / HEIC，默认 PNG；"
             "批量导出时按创建时间命名。", "文本 · 说明"),
]

FILE_PATHS = ["/Users/demo/Documents", "/Users/demo/Desktop"]


def font(size: int):
    from PIL import ImageFont
    for p in ("/System/Library/Fonts/PingFang.ttc",
              "/System/Library/Fonts/Helvetica.ttc",
              "/System/Library/Fonts/Supplemental/Arial.ttf"):
        if os.path.exists(p):
            try:
                return ImageFont.truetype(p, size)
            except Exception:
                continue
    return ImageFont.load_default()


def make_image(path: Path, title: str, w: int, h: int, bg: str) -> None:
    """画一张「像截图」的示意图：顶栏 + 标题 + 若干内容块。"""
    from PIL import Image, ImageDraw

    dark = bg.upper() in ("#1E1E24", "#1E1E24")
    fg = "#E6E6EA" if dark else "#1B1B20"
    muted = "#8A8A94" if dark else "#9A9AA4"
    line = "#33333C" if dark else "#E6E6EC"

    im = Image.new("RGB", (w, h), bg)
    d = ImageDraw.Draw(im)

    # 顶栏
    d.rectangle([0, 0, w, 46], fill=("#26262E" if dark else "#F7F7F9"))
    d.line([0, 46, w, 46], fill=line)
    for i, c in enumerate(("#FF5F57", "#FEBC2E", "#28C840")):
        d.ellipse([18 + i * 22, 16, 30 + i * 22, 28], fill=c)
    d.text((100, 15), title, font=font(15), fill=muted)

    y = 82
    d.text((44, y), "Kitnest 演示样张", font=font(26), fill=fg)
    y += 46
    d.text((44, y), "This is sample content for the user manual.",
           font=font(15), fill=muted)
    y += 44

    if "usage" in title.lower() or "用量" in title:
        # 柱状图
        base = h - 90
        random.seed(7)
        for i in range(14):
            bh = random.randint(30, 210)
            x = 60 + i * ((w - 120) / 14)
            d.rounded_rectangle([x, base - bh, x + 34, base], radius=5,
                                fill="#2F6BFF" if i % 3 else "#C9D8FF")
        d.line([44, base + 1, w - 44, base + 1], fill=line)
        d.text((44, base + 16), "Mon … Sun", font=font(13), fill=muted)
    elif "parse" in title:
        # 代码块
        lines = [
            ('def parse(raw: str) -> list[str]:', "#C792EA"),
            ('    """按空白切分。"""', "#7FDBB6"),
            ('    return [p for p in raw.split() if p]', "#E6E6EA"),
            ('', ""),
            ('rows = parse(text)', "#82AAFF"),
            ('print(len(rows))', "#E6E6EA"),
        ]
        for i, (t, c) in enumerate(lines):
            d.text((44, y + i * 34), t, font=font(17), fill=c or fg)
    elif "palette" in title or "配色" in title:
        cols = ["#2F6BFF", "#1F9D63", "#D97706", "#C0392B", "#6B7280", "#0B0B0D"]
        for i, c in enumerate(cols):
            x = 44 + i * ((w - 88) / len(cols))
            d.rounded_rectangle([x, y, x + (w - 88) / len(cols) - 12, y + 150],
                                radius=10, fill=c)
        d.text((44, y + 176), "Primary / Success / Warning / Danger / Neutral / Ink",
               font=font(14), fill=muted)
    else:
        # 列表
        for i in range(6):
            d.rounded_rectangle([44, y, w - 44, y + 52], radius=8,
                                fill=("#26262E" if dark else "#FAFAFB"))
            d.text((62, y + 16), f"Item {i + 1} — sample row for the manual",
                   font=font(15), fill=muted)
            y += 64

    im.save(path, quality=92)


def schema_of(db: Path) -> str:
    con = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
    try:
        # sqlite_master.sql 不带结尾分号，直接换行拼会连成一句
        return ";\n".join(r[0] for r in con.execute(
            "select sql from sqlite_master where sql is not null")) + ";"
    finally:
        con.close()


def new_db(name: str, schema_src: Path) -> sqlite3.Connection:
    p = DEMO / name
    if p.exists():
        p.unlink()
    con = sqlite3.connect(p)
    con.executescript(schema_of(schema_src))
    return con


def main() -> None:
    if DEMO.exists():
        shutil.rmtree(DEMO)
    (DEMO / "images").mkdir(parents=True)
    (DEMO / "thumbnails").mkdir(parents=True)
    (DEMO / "rich_texts").mkdir(parents=True)

    now = time.time()

    # ---------------- 剪贴板
    con = new_db("clipboard.sqlite", REAL / "clipboard.sqlite")
    rows = []
    img_i = 0
    for idx, (kind, body, sub) in enumerate(TEXTS):
        ts = now - idx * 640 - random.randint(0, 240)
        uid = f"{abs(hash(body + str(idx))) % (10**16):016X}"
        item_id = f"{uid[:8]}-{uid[8:12]}-4{uid[12:15]}-A{uid[15]}-{uid[:12]}"
        digest = hashlib.sha256(body.encode()).hexdigest()
        title = body.split("\n")[0][:80]
        if kind == "file":
            title = body
            sub = FILE_PATHS[idx % len(FILE_PATHS)]
        rows.append(dict(
            id=item_id, type="url" if kind == "url" else kind,
            content=body, title=title, subtitle=sub, timestamp=ts,
            source_app="com.apple.Safari" if kind == "url" else "com.example.editor",
            image_path=None, thumbnail_path=None, is_generated_by_tool=0, is_note=0,
            source_tool_analytics_id=None, source_tool_keyword=None,
            text_path=None, rich_text_path=None, full_text_char_count=None,
            full_text_line_count=None, source_input=None, file_icon_key=None,
            image_dimension_unit="pt", payload_key=None,
            storage_bytes=len(body.encode()),
            dedupe_key=("file:" if kind == "file" else "txt:") + digest,
            alias_title=None))

    # 图片条目：穿插在文本之间，让列表看起来像真在用
    for n, (name, w, h, bg, title) in enumerate(IMAGES):
        uid = f"{abs(hash(name)) % (10**16):016X}"
        uuid = f"{uid[:8]}-{uid[8:12]}-4{uid[12:15]}-A{uid[15]}-{uid[:12]}"
        rel = f"images/{uuid}.png"
        thumb = f"thumbnails/{uuid}.png"
        make_image(DEMO / rel, title, w, h, bg)
        im = __import__("PIL.Image", fromlist=["Image"]).open(DEMO / rel)
        im.thumbnail((360, 360))
        im.save(thumb)
        rows.append(dict(
            id=uuid, type="image", content=None, title="图片",
            subtitle=f"{w}×{h} 图片", timestamp=now - (2 + n * 3) * 700,
            source_app="com.apple.Safari", image_path=rel, thumbnail_path=thumb,
            is_generated_by_tool=0, is_note=0, source_tool_analytics_id=None,
            source_tool_keyword=None, text_path=None, rich_text_path=None,
            full_text_char_count=None, full_text_line_count=None,
            source_input=None, file_icon_key=None, image_dimension_unit="pt",
            payload_key=None, storage_bytes=(DEMO / rel).stat().st_size,
            dedupe_key=f"img:{hashlib.sha256(name.encode()).hexdigest()}",
            alias_title=None))

    # 富文本要真的落一份 rtf，否则预览打开是空的
    for r in rows:
        if r["type"] == "richtext":
            uid = r["id"]
            rel = f"rich_texts/{uid}.rtf"
            rtf = (r"{\rtf1\ansi\ansicpg936{\fonttbl{\f0 PingFang SC;}}"
                   r"\f0\fs26 " + r["content"].replace("\n", r"\par ") + "}")
            (DEMO / rel).write_text(rtf, encoding="utf-8")
            r["rich_text_path"] = rel
            r["content"] = None

    cols = list(rows[0].keys())
    con.executemany(
        f"insert into clipboard_items ({','.join(cols)}) values ({','.join('?' * len(cols))})",
        [[r[c] for c in cols] for r in rows])
    con.commit()
    con.close()

    # ---------------- 截图历史
    con = new_db("capture-history.sqlite", REAL / "capture-history.sqlite")
    (DEMO / "capture-history").mkdir(parents=True, exist_ok=True)
    for n in range(6):
        uid = f"9A{n:02X}0000-1111-4222-8333-{n:012X}"
        name, w, h, bg, title = IMAGES[n % len(IMAGES)]
        rel = f"capture-history/{uid}.png"
        tw, th = (w // 2, h // 2) if n % 2 else (640, 420)
        make_image(DEMO / rel, f"{title} #{n + 1}", tw, th, bg)
        # 表里存的是**绝对路径**（真实记录就是 /tmp/shots/xxx.png），
        # 写相对路径 App 找不到文件，列表里只会显示一串 UUID。
        rel = str(DEMO / rel)
        thumb = str(DEMO / f"capture-history/{uid}-thumb.png")
        im = __import__("PIL.Image", fromlist=["Image"]).open(DEMO / rel)
        im.thumbnail((320, 320))
        im.save(thumb)
        con.execute(
            "insert into capture_history (id,path,thumb_path,created_at,mode,width,height,ocr_text,annotation_state)"
            " values (?,?,?,?,?,?,?,'','')",
            (uid, rel, thumb, now - (n + 1) * 900, "region", tw, th))
    con.commit()
    con.close()

    # ---------------- 使用统计（近 30 天）
    con = new_db("statistics.sqlite", REAL / "statistics.sqlite")
    random.seed(11)
    events = ["clipboard_copy", "capture", "ocr", "tool_run", "monitor_open"]
    for d in range(30):
        day = time.strftime("%Y-%m-%d", time.localtime(now - d * 86400))
        for e in events:
            c = random.randint(0, 16 if e == "clipboard_copy" else 6)
            if c:
                con.execute("insert into usage_daily_metrics (day,event_name,count) values (?,?,?)",
                            (day, e, c))
    con.execute("insert into app_meta (key,value) values ('installed_at',?)",
                (str(int(now - 40 * 86400)),))
    con.commit()
    con.close()

    total = sum(f.stat().st_size for f in DEMO.rglob("*") if f.is_file())
    print(f"演示数据 → {DEMO}")
    print(f"  剪贴板 {len(rows)} 条 / 截图 {6} 条 / 统计 30 天")
    print(f"  体积 {total / 1024 / 1024:.1f} MB")


if __name__ == "__main__":
    main()
