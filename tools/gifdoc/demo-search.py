#!/usr/bin/env python3
"""D2 · 主面板搜索（第三章 / 第二十四章）：⌥A 唤出 → 输入关键词 → 文件结果。"""
import sys
sys.path.insert(0, "/tmp/giftool")
import h

CROP = (1332, 40, 376, 486)


def main():
    h.close_windows()
    h.minimize("hide")
    h.sleep(0.4)
    h.sh("open", "kitnest://panel")
    h.sleep(1.4)
    h.move(1517, 97, 300)
    h.sleep(0.3)

    with h.Rec("d2", 7.6) as r:
        h.click(1517, 97, 200)
        h.sleep(0.35)
        h.typ("image-html-deck")
        h.sleep(2.0)              # 等索引结果
        h.move(1450, 250, 500)    # 移到结果行
        h.sleep(1.4)
        h.move(1500, 300, 400)
        h.sleep(1.2)

    r.frames_out(CROP, 600, start=0.35, end=6.4, fps=10)
    h.gif("d2-search", r.frames, ms=100, colors=144, hold=5)
    h.minimize("restore")


if __name__ == "__main__":
    main()
