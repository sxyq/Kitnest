#!/usr/bin/env python3
"""D6 · 存储管理（第十八章）：可清理项勾选 → 合计变化。"""
import sys
sys.path.insert(0, "/tmp/giftool")
import h

CROP = (630, 38, 1080, 752)


def main():
    h.close_windows()
    h.minimize("hide")
    h.sleep(0.4)
    h.sh("open", "kitnest://storage")
    h.sleep(2.2)
    h.move(760, 300, 400)
    h.sleep(0.4)

    with h.Rec("d6", 8.4) as r:
        h.move(655, 255, 700)        # Caches 复选框
        h.sleep(0.4)
        h.click(655, 255, 100)
        h.sleep(0.9)
        h.move(655, 297, 450)
        h.sleep(0.3)
        h.click(655, 297, 100)
        h.sleep(0.9)
        h.move(655, 339, 450)
        h.sleep(0.3)
        h.click(655, 339, 100)
        h.sleep(1.2)
        h.move(900, 660, 700)        # 底部合计
        h.sleep(1.2)

    r.frames_out(CROP, 960, start=0.4, end=7.2, fps=10)
    h.gif("d6-storage", r.frames, ms=100, colors=160, hold=5)
    h.minimize("restore")


if __name__ == "__main__":
    main()
