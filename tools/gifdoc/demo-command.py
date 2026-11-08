#!/usr/bin/env python3
"""D3 · 命令面板（第二十五章）：⌥K 唤出 → 输入过滤 → Esc 关闭。"""
import sys
sys.path.insert(0, "/tmp/giftool")
import h

CROP = (560, 160, 676, 510)


def main():
    h.close_windows()
    h.minimize("hide")
    h.sleep(0.5)
    h.move(900, 420, 300)
    h.sleep(0.3)

    with h.Rec("d3", 7.0) as r:
        h.key("28", "opt")
        h.sleep(1.0)
        h.sleep(0.8)
        for _ in range(3):
            h.key("125")        # ↓ 逐项移动
            h.sleep(0.45)
        h.sleep(0.8)
        h.key(h.ESC)
        h.sleep(0.5)

    r.frames_out(CROP, 860, start=0.3, end=5.2, fps=10)
    h.gif("d3-command", r.frames, ms=100, colors=160, hold=4)
    h.minimize("restore")


if __name__ == "__main__":
    main()
