#!/usr/bin/env python3
"""D7 · 标注编辑器（第八章）：画箭头 → 换马赛克 → 遮盖数字。"""
import sys
sys.path.insert(0, "/tmp/giftool")
import h

CROP = (405, 118, 976, 742)


def main():
    h.close_windows()
    h.minimize("hide")
    h.sleep(0.4)
    h.sh("open", "kitnest://annotate?file=/tmp/annot-demo.png")
    h.sleep(2.0)
    h.move(700, 300, 400)
    h.sleep(0.3)

    with h.Rec("d7", 10.2) as r:
        h.drag(700, 300, 1000, 430, 950)     # 箭头
        h.sleep(0.7)
        h.move(465, 563, 650)                # 马赛克工具
        h.sleep(0.5)
        h.click(465, 563, 100)
        h.sleep(0.7)
        h.drag(852, 318, 1006, 348, 800)     # 涂掉金额
        h.sleep(0.8)
        h.move(993, 814, 600)                # 复制按钮
        h.sleep(1.2)

    r.frames_out(CROP, 960, start=0.3, end=8.4, fps=10)
    h.gif("d7-annotate", r.frames, ms=100, colors=176, hold=5)
    h.minimize("restore")


if __name__ == "__main__":
    main()
