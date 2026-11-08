#!/usr/bin/env python3
"""入口勘景：逐个打开深链 → 单窗截图 → 拼成联系表，供分镜设计参考。

用法：python3 tools/gifdoc/survey.py <tag> <url1> <url2> ...
产物：/tmp/survey/<tag>-<i>-<slug>.png 与 /tmp/survey/<tag>-sheet.png
"""
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
import h

OUT = Path("/tmp/survey")
OUT.mkdir(parents=True, exist_ok=True)


def grab(tag, i, url):
    h.clear_stage()
    h.sleep(0.6)
    slug = url.replace("kitnest://", "").replace("?", "-").replace("=", "-").replace("&", "-")
    slug = slug.replace("/", "_")[:40] or "root"
    h.sh("open", f"kitnest://{url}")
    time.sleep(2.0)
    ws = h.windows()
    print(f"[{i}] {url} -> {ws}")
    name = OUT / f"{tag}-{i:02d}-{slug}.png"
    h.screen(name)
    return name, ws


def main():
    tag = sys.argv[1]
    urls = sys.argv[2:]
    shots = [grab(tag, i, u) for i, u in enumerate(urls, 1)]
    # 联系表：每张缩到 800 宽，2 列排
    from PIL import Image
    thumbs = []
    for p, _ in shots:
        im = Image.open(p).convert("RGB")
        w = 760
        im = im.resize((w, int(im.height * w / im.width)), Image.LANCZOS)
        thumbs.append((p.name, im))
    cols, pad, label = 2, 14, 26
    rows = (len(thumbs) + cols - 1) // cols
    cw = max(t[1].width for t in thumbs)
    ch = max(t[1].height for t in thumbs)
    sheet = Image.new("RGB", (cols * cw + pad * (cols + 1),
                              rows * (ch + label) + pad * (rows + 1)), (24, 24, 26))
    from PIL import ImageDraw
    d = ImageDraw.Draw(sheet)
    for i, (nm, im) in enumerate(thumbs):
        r, c = divmod(i, cols)
        x = pad + c * (cw + pad)
        y = pad + r * (ch + label + pad)
        d.text((x + 2, y + 4), nm, fill=(230, 230, 230))
        sheet.paste(im, (x, y + label))
    p = OUT / f"{tag}-sheet.png"
    sheet.save(p)
    print("sheet:", p)


if __name__ == "__main__":
    main()
