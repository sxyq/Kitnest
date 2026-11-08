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

import datetime
import hashlib
import json
import os
import random
import shutil
import sqlite3
import subprocess
import time
import zipfile
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

# 截图历史：时间偏移 / 模式 / 尺寸 / 底色 / 画面标题 / 卡片上那行 OCR 摘要。
#
# 文件名以前是 `9A000000-1111-4222-8333-…` 这种 UUID，列表里一列 UUID 看着就像
# 测试数据；App 真实落盘走 CaptureFileName 的默认模板
# `Screenshot-{yyyy}-{MM}-{dd}-{HH}{mm}{ss}-{random:3}.png`，这里照着造。
SHOTS = [
    (2 * 3600 + 640, "area", 1280, 800, "#FFFFFF", "Release checklist",
     "发布前检查：版本号 / 签名 / 更新说明"),
    (26 * 3600, "full", 1440, 900, "#F6F8FC", "Weekly usage",
     "Weekly usage · Mon … Sun"),
    (3 * 86400 + 1800, "window", 1100, 640, "#1E1E24", "parse_demo.py",
     "def parse(raw: str) -> list[str]"),
    (5 * 86400, "long", 900, 1400, "#FFFFFF", "Release checklist",
     "发布前检查清单 · 共 12 项"),
    (8 * 86400, "area", 1280, 800, "#FFFFFF", "Release checklist",
     "Item 1 — sample row for the manual"),
    (12 * 86400, "window", 1200, 760, "#F6F8FC", "Weekly usage",
     "Kitnest 演示样张 · sample content"),
]

# 存储管理的磁盘索引：App 只在用户点「建立索引」时扫描，平常读
# `App Support/…/disk-index/index-<scope>.json` 缓存。录制环境是隔离目录，
# 里面没有缓存 → 窗口只能显示空态。真实扫描这台机器又会把真实目录名拍进去，
# 所以这里直接造一份**虚构的**索引缓存（schema 必须与 DiskIndexScanner 一致。
GB = 1024 ** 3


def _node(path: str, name: str, own: int = 0, children: list | None = None,
          folded: int = 0) -> dict:
    """造一个 DiskNode：size = 自身文件 + 子项之和（UI 的气泡面积全看这个）。"""
    kids = children or []
    return {
        "path": path,
        "name": name,
        "isDirectory": True,
        "size": own + sum(k["size"] for k in kids),
        "ownSize": own,
        "foldedCount": folded,
        "children": kids,
    }


def _file(path: str, name: str, size: int) -> dict:
    return {"path": path, "name": name, "isDirectory": False, "size": size,
            "ownSize": size, "foldedCount": 0, "children": []}



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
        # 长截图（900×1600）要铺满整页，只画 6 行的话中间一大片白，
        # 列表卡片按 center-crop 一裁就是张空白图。
        i = 0
        while y + 52 < h - 36 and i < 40:
            d.rounded_rectangle([44, y, w - 44, y + 52], radius=8,
                                fill=("#26262E" if dark else "#FAFAFB"))
            d.text((62, y + 16), f"Item {i + 1} — sample row for the manual",
                   font=font(15), fill=muted)
            y += 64
            i += 1

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


# ---------------------------------------------------------------- 存储管理索引

def demo_disk_tree() -> dict:
    """虚构的整盘目录树（根 = Macintosh HD）。

    形状照着真机的样子搭：/ 下面是 Applications / Library / System / Users…，
    个人目录里放几个 >20MB 的缓存目录（Caches、DerivedData、node_modules、.npm、
    .Trash、Logs），这样左侧「可清理清单」有 6~7 条、右侧气泡图也不空。
    所有名字都是通用的系统目录名，没有一个来自这台机器。
    """
    home = "/Users/demo"

    caches = _node(f"{home}/Library/Caches", "Caches", own=19 * GB,
                   children=[
                       _file(f"{home}/Library/Caches/cover-art.db", "cover-art.db", 2_400_000_000),
                       _file(f"{home}/Library/Caches/thumbs.cache", "thumbs.cache", 6_100_000_000),
                       _file(f"{home}/Library/Caches/index.db", "index.db", 3_800_000_000),
                   ], folded=14)
    derived = _node(f"{home}/Library/Developer/Xcode/DerivedData", "DerivedData",
                    own=6 * GB, children=[
                        _node(f"{home}/Library/Developer/Xcode/DerivedData/Kit-demo-abcdef",
                              "Kit-demo-abcdef", own=3_200_000_000, folded=6),
                    ], folded=9)
    developer = _node(f"{home}/Library/Developer", "Developer",
                      children=[derived, _node(f"{home}/Library/Developer/CoreSimulator",
                                               "CoreSimulator", own=1_400_000_000)])
    library = _node(f"{home}/Library", "Library", own=420_000_000, children=[
        caches,
        developer,
        _node(f"{home}/Library/Containers", "Containers", own=11 * GB, folded=21),
        _node(f"{home}/Library/Application Support", "Application Support",
              own=8 * GB, folded=32),
        _node(f"{home}/Library/Logs", "Logs", own=430_000_000, folded=18),
        _node(f"{home}/Library/Preferences", "Preferences", own=92_000_000, folded=40),
    ], folded=26)

    node_modules = _node(f"{home}/Documents/Projects/kit-demo/node_modules",
                         "node_modules", own=6 * 100_000_000,
                         children=[], folded=184)
    projects = _node(f"{home}/Documents/Projects", "Projects", children=[
        _node(f"{home}/Documents/Projects/kit-demo", "kit-demo", own=118_000_000,
              children=[node_modules]),
        _node(f"{home}/Documents/Projects/site-demo", "site-demo", own=540_000_000),
    ])
    documents = _node(f"{home}/Documents", "Documents", own=210_000_000, children=[
        projects,
        _node(f"{home}/Documents/设计稿", "设计稿", own=430_000_000, folded=22),
        _node(f"{home}/Documents/报表", "报表", own=220_000_000, folded=9),
        _node(f"{home}/Documents/笔记", "笔记", own=86_000_000, folded=31),
    ])

    demo_home = _node(home, "demo", own=1_100_000_000, children=[
        library,
        _node(f"{home}/Movies", "Movies", own=13 * GB, folded=12),
        _node(f"{home}/Pictures", "Pictures", own=9 * GB, folded=31),
        _node(f"{home}/Downloads", "Downloads", own=5 * GB, folded=48),
        documents,
        _node(f"{home}/Desktop", "Desktop", own=980_000_000, folded=17),
        _node(f"{home}/Music", "Music", own=760_000_000, folded=8),
        _node(f"{home}/.npm", ".npm", own=1_240_000_000, folded=5),
        _node(f"{home}/.cache", ".cache", own=680_000_000, folded=7),
        _node(f"{home}/.Trash", ".Trash", own=3_300_000_000, folded=11),
    ])

    return _node("/", "Macintosh HD", own=0, children=[
        _node("/Applications", "Applications", own=21 * GB, folded=64),
        _node("/Library", "Library", own=30 * GB, folded=52),
        _node("/System", "System", own=12 * GB, folded=71),
        _node("/Users", "Users", children=[demo_home], folded=2),
        _node("/private", "private", own=8 * GB, folded=24),
        _node("/opt", "opt", own=2 * GB, folded=6),
        _node("/usr", "usr", own=1 * GB, folded=14),
    ])


def write_disk_index(now: float) -> dict:
    """把虚构索引写成 App 认识的缓存文件（schema 必须对，否则会被当旧缓存作废）。

    scope 用 fullDisk：窗口默认读的就是这一份，状态行显示「整块启动卷」。
    """
    root = demo_disk_tree()
    snap = {
        "scope": "fullDisk",
        "rootPath": "/",
        "scannedAt": now - 3900,
        "totalBytes": root["size"],
        "nodeCount": 118_640,
        "skippedCount": 1_204,
        "root": root,
        "truncated": False,
        "schema": 4,
    }
    out = DEMO / "disk-index"
    out.mkdir(parents=True, exist_ok=True)
    (out / "index-fullDisk.json").write_text(
        json.dumps(snap, ensure_ascii=False), encoding="utf-8")
    return snap


# ---------------------------------------------------------------- 归档演示包

def write_archive_zip(now: float) -> Path:
    """造一个「素材包.zip」：三张样张 + 说明/清单，用来演示归档浏览。

    条目名必须是 UTF-8（Python zipfile 会自动置语言标志位）；用 shell 的 zip
    打包中文名不置位，App 按 cp437 解码就成乱码/列不出来 —— 上一版 ch22 就是
    空列表。
    """
    src = DEMO / "archive-src"
    src.mkdir(parents=True, exist_ok=True)
    make_image(src / "封面.png", "Palette", 1280, 800, "#FFFFFF")
    make_image(src / "主图.png", "Weekly usage", 1100, 640, "#F6F8FC")
    make_image(src / "图标.png", "Release checklist", 512, 512, "#1E1E24")

    out = DEMO / "downloads"
    out.mkdir(parents=True, exist_ok=True)
    zp = out / "素材包.zip"

    readme = ("# 素材包\n\n"
              "演示用压缩包：三张样张 + 一份清单。\n\n"
              "- 封面.png  文章头图\n"
              "- 主图.png  正文配图\n"
              "- 图标.png  应用图标\n")
    manifest = ("文件名,尺寸,用途\n"
                "封面.png,1280×800,文章头图\n"
                "主图.png,1100×640,正文配图\n"
                "图标.png,512×512,应用图标\n")
    note = "解压后按 清单.csv 对号入座；样张可直接替换成自己的图。\n"

    with zipfile.ZipFile(zp, "w", zipfile.ZIP_DEFLATED) as z:
        z.writestr("README.md", readme)
        z.writestr("清单.csv", manifest)
        z.writestr("说明.txt", note)
        for name in ("封面.png", "主图.png", "图标.png"):
            z.write(src / name, name)
    shutil.rmtree(src, ignore_errors=True)
    return zp



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
        im.save(DEMO / thumb)
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
    for n, (ago, mode, w, h, bg, title, ocr) in enumerate(SHOTS):
        when = datetime.datetime.fromtimestamp(now - ago)
        rnd = f"{abs(hash(title + str(n))) % 4096:03x}"
        # 与 CaptureFileName 的默认模板完全同形，列表里一眼就是「自己截的图」
        fname = f"Screenshot-{when:%Y-%m-%d}-{when:%H%M%S}-{rnd}.png"
        uid = f"9A{n:02X}0000-1111-4222-8333-{n:012X}"
        rel = f"capture-history/{fname}"
        make_image(DEMO / rel, title, w, h, bg)
        # 表里存的是**绝对路径**（真实记录就是 /tmp/shots/xxx.png），
        # 写相对路径 App 找不到文件，缩略图那一格会是空的。
        rel = str(DEMO / rel)
        thumb = str(DEMO / f"capture-history/{Path(fname).stem}-thumb.png")
        im = __import__("PIL.Image", fromlist=["Image"]).open(rel)
        im.thumbnail((320, 320))
        im.save(thumb)
        con.execute(
            "insert into capture_history (id,path,thumb_path,created_at,mode,width,height,ocr_text,annotation_state)"
            " values (?,?,?,?,?,?,?,?,'')",
            (uid, rel, thumb, now - ago, mode, w, h, ocr))
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

    # ---------------- 存储管理索引（虚构整盘树）+ 归档演示包
    snap = write_disk_index(now)
    zp = write_archive_zip(now)

    total = sum(f.stat().st_size for f in DEMO.rglob("*") if f.is_file())
    print(f"演示数据 → {DEMO}")
    print(f"  剪贴板 {len(rows)} 条 / 截图 {len(SHOTS)} 条 / 统计 30 天")
    print(f"  存储索引 节点 {snap['nodeCount']} / 合计 {snap['totalBytes'] / GB:.1f} GB")
    print(f"  归档演示包 {zp}（{zp.stat().st_size / 1024:.0f} KB）")
    print(f"  体积 {total / 1024 / 1024:.1f} MB")


if __name__ == "__main__":
    main()
