#!/usr/bin/env python3
"""D1 · 截图主流程（第七章）：⌥S 框选 → 动作条 → 悬停钉住组。"""
import sys
sys.path.insert(0, "/tmp/giftool")
import h

CROP = (388, 168, 980, 922)   # x,y,w,h（点）


def main():
    h.close_windows()
    h.prep_settings("manual")
    h.setframe("设置", 400, 180, 940, 652)
    h.sleep(0.5)
    h.minimize("hide")
    h.sleep(0.8)
    h.move(640, 420, 400)
    h.sleep(0.4)

    with h.Rec("d1", 10.4) as r:
        h.move(700, 420, 500)
        h.sleep(0.2)
        h.key("1", "opt")
        h.sleep(1.0)
        h.move(520, 360, 450)
        h.sleep(0.3)
        h.drag(520, 360, 1260, 600, 2200)
        h.sleep(1.0)
        h.move(880, 960, 700)      # 钉住组图标
        h.sleep(1.7)               # 子菜单展开
        h.move(1010, 905, 450)     # 在子菜单上轻移
        h.sleep(1.0)

    r.frames_out(CROP, 1000, start=0.25, end=9.3, fps=10)
    h.gif("d1-capture", r.frames, ms=100, colors=176, hold=6)


if __name__ == "__main__":
    main()
