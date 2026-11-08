#!/usr/bin/env python3
"""手册配图分镜：一章一镜，全部真机操作。

设计
----
大部分章节的演示是同一种镜头语言——「把窗口摆到固定位置，光标依次掠过关键
控件，需要时点一下」。所以这里做一个通用节拍播放器 `play()`：一条 `BEATS`
数据 = 一节拍表，`run.py` 负责探针（只截图）或录制（真录 + 合成 GIF）。

节拍表按顺序执行，`hold` 是这一拍结束后的停留时间（秒）。位置用**窗口内相对
比例**表示（0~1），窗口换位置也不会失准——这是被 AX 坐标口径坑过之后的结论：
AX `find` 报的点和 `dump` 报的点能差 18pt，但相对比例永远是稳的。

只有少数镜头（点菜单栏图标、框选覆盖层）需要手写函数。
"""
import os
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
import h
import camera

SCENES = {}
BEATS = {}


def scene(fn):
    SCENES[fn.__name__] = fn
    return fn


def open_url(u):
    h.sh("open", f"kitnest://{u}")


def at(rect, fx, fy):
    return (rect[0] + rect[2] * fx, rect[1] + rect[3] * fy)


def play(name, rect, beats, pad=10, fps=10, colors=176, hold=5, width=0, ms=100,
         tail=0.7, head=0.15, badge="", crop_override=None, max_kb=2400,
         merge_th=4, cam=True, redact=None):
    """执行节拍表：探针模式只截图，录制模式真录 + 出 GIF。"""
    if not rect:
        raise LookupError("窗口不存在，无法开镜")
    crop = crop_override or (rect[0] - pad, rect[1] - pad,
                             rect[2] + pad * 2, rect[3] + pad * 2)
    h.CROP = crop
    total = sum(b.get("hold", 0.5) + 0.35 for b in beats)
    secs = total + tail + 0.5
    h.mark("stage")
    with h.Rec(name, secs) as r:
        for b in beats:
            if "move" in b:
                x, y = at(rect, *b["move"])
                h.move(x, y, b.get("ms", 380))
            if "click" in b:
                x, y = at(rect, *b["click"])
                h.move(x, y, b.get("ms", 320))
                h.sleep(0.14)
                h.click(x, y, b.get("click_ms", 110), b.get("button", "left"))
            if "scroll" in b:
                sx, sy = b.get("scroll_at", (0.5, 0.6))
                px, py = at(rect, sx, sy)
                h.scroll(px, py, b["scroll"])
            if "key" in b:
                k = b["key"]
                h.key(k[0], *k[1:])
            if "type" in b:
                h.typ(b["type"])
            h.sleep(b.get("hold", 0.5))
            if b.get("mark"):
                h.mark(b["mark"])
    want_cam = os.environ.get("GIF_CAMERA", "1") != "0" and cam
    # 缩放上限跟窗口尺寸走：窄窗（面板 360pt）推到 1.65× 就够，推狠了只会糊；
    # 宽窗（设置 940pt）可以到 2.0×。输出宽度再按「放大后仍不插值」反算。
    _cw, _ch = (crop_override[2], crop_override[3]) if crop_override else (rect[2], rect[3])
    zmax = max(1.45, min(2.0, min(_cw, _ch) / 200))
    w = int(max(420, min(880, _cw * 2 / zmax * 1.06)))
    if width:
        w = min(w, width)
    r.frames_out(crop, w, start=head, end=secs - tail, fps=fps, native=want_cam)
    frames = r.frames
    if want_cam and not h.PROBING:
        frames = camera.render(r.frames, h.WORK / f"{name}.json",
                               h.WORK / f"{name}-cam", width=w, max_zoom=zmax)
    if redact:
        if isinstance(redact, dict):
            h.auto_redact(frames, **redact)
        else:
            # (boxes, pixel)：给马赛克块大小，0 表示用高斯模糊
            boxes = redact[0] if isinstance(redact, tuple) else redact
            px = redact[1] if isinstance(redact, tuple) and len(redact) > 1 else 12
            h.redact(frames, boxes, pixel=px)
    h.gif(name, frames, ms=ms, colors=colors, hold=hold, badge=badge,
          max_kb=max_kb, merge_th=merge_th)
    return r


def spec(**kw):
    return kw


def custom(name, crop, secs, body, width=900, zmax=1.9, head=0.25, tail=0.6,
           colors=176, hold=5, max_kb=1200, cam=True, redact=None):
    """手写镜头：覆盖层/浮层这类没有稳定窗口的场景用。"""
    h.CROP = crop
    h.mark("stage")
    with h.Rec(name, secs) as r:
        body()
    r.frames_out(crop, width, start=head, end=secs - tail, fps=10, native=cam)
    frames = r.frames
    if cam and not h.PROBING:
        frames = camera.render(r.frames, h.WORK / f"{name}.json",
                               h.WORK / f"{name}-cam", width=width, max_zoom=zmax)
    if redact:
        if isinstance(redact, dict):
            h.auto_redact(frames, **redact)
        else:
            # (boxes, pixel)：给马赛克块大小，0 表示用高斯模糊
            boxes = redact[0] if isinstance(redact, tuple) else redact
            px = redact[1] if isinstance(redact, tuple) and len(redact) > 1 else 12
            h.redact(frames, boxes, pixel=px)
    h.gif(name, frames, ms=100, colors=colors, hold=hold,
          max_kb=max_kb, merge_th=4)


# ---------------------------------------------------------------- 第一章
@scene
def ch01():
    """菜单栏与图标：点图标 → 面板展开 → 顶栏动作行。

    图标位置不能写死：这台机器的菜单栏装了很多别的 App，重启一次位置就漂，
    写死会点到邻居（实测点开过 1Capture 的菜单）。所以先探测再开镜。
    """
    h.clear_stage()
    icon_x, pf = h.status_icon()
    if icon_x is None:
        raise LookupError("没找到菜单栏主图标")

    # 裁切紧贴面板：多留一像素就会把桌面图标带进画面
    crop = (pf[0] - 6, 0, 372, 432)
    h.CROP = crop
    h.sleep(0.4)

    def body():
        h.move(1180, 14, 400)
        h.sleep(0.25)
        h.move(icon_x, 19, 420)
        h.sleep(0.4)
        h.click(icon_x, 19, 120)
        h.sleep(1.2)
        for k in range(8):
            h.move(pf[0] + 34 + k * 38, 62, 300)
            h.sleep(0.18)
        h.sleep(0.5)
        h.key(h.ESC)
        h.sleep(0.6)

    custom("ch01-menubar", crop, 6.8, body,
           width=800, zmax=1.6, colors=176, hold=5, cam=False)


# ---------------------------------------------------------------- 第二章
BEATS["ch02"] = spec(
    open="statistics", title="", place=(430, 150, 800, 562),
    pad=12, fps=10, colors=176, hold=6,
    beats=[
        dict(move=(0.12, 0.42), hold=0.6, mark="tiles"),
        dict(move=(0.34, 0.42), hold=0.45),
        dict(move=(0.56, 0.42), hold=0.45),
        dict(move=(0.78, 0.42), hold=0.45),
        dict(move=(0.92, 0.42), hold=0.6),
        dict(move=(0.72, 0.50), hold=0.5),
        dict(move=(0.62, 0.62), hold=0.35, mark="chart"),
        dict(move=(0.70, 0.62), hold=0.3),
        dict(move=(0.78, 0.62), hold=0.3),
        dict(move=(0.86, 0.62), hold=0.3),
        dict(move=(0.90, 0.80), hold=0.4),
        dict(move=(0.72, 0.88), hold=0.6, mark="heat"),
        dict(move=(0.88, 0.88), hold=0.7),
    ])


# ---------------------------------------------------------------- 第三章
BEATS["ch03"] = spec(
    open="panel", title="", place=None,
    pad=10, fps=10, colors=176, hold=5,
    beats=[
        dict(move=(0.36, 0.03), hold=0.5),
        dict(click=(0.45, 0.03), hold=1.3, mark="monitor"),
        dict(click=(0.55, 0.03), hold=1.3, mark="transfer"),
        dict(click=(0.65, 0.03), hold=1.3, mark="cast"),
        dict(click=(0.36, 0.03), hold=1.0, mark="home"),
        dict(move=(0.45, 0.12), hold=0.4),
        dict(click=(0.45, 0.12), hold=0.4),
        dict(type="README", hold=1.8, mark="search"),
        dict(key=(h.ESC,), hold=0.6),
    ])


# ---------------------------------------------------------------- 第四章
BEATS["ch04"] = spec(
    open="panel", title="", place=None,
    pad=10, fps=10, colors=160, hold=5, crop=(1330, 30, 380, 800),
    beats=[
        dict(move=(0.5, 0.52), hold=0.5),
        dict(scroll=-8, hold=1.3, mark="scroll"),
        dict(scroll=6, hold=1.1),
        dict(move=(0.5, 0.60), hold=0.6, mark="hover"),
        dict(move=(0.5, 0.70), hold=0.6),
        dict(move=(0.5, 0.80), hold=0.6),
        dict(click=(0.46, 0.95), hold=1.3, mark="filter"),
        dict(key=(h.ESC,), hold=0.5),
    ])


# ---------------------------------------------------------------- 第五章
BEATS["ch05"] = spec(
    open="clipdesk", title="悬浮剪贴板", place=(250, 180, 1120, 720),
    pad=12, fps=10, colors=176, hold=6, width=980,
    beats=[
        dict(move=(0.20, 0.106), hold=0.7, mark="tabs"),
        dict(click=(0.20, 0.106), hold=1.2, mark="image-tab"),
        dict(click=(0.055, 0.106), hold=1.0),
        dict(move=(0.083, 0.24), hold=0.6),
        dict(click=(0.083, 0.24), hold=1.3, mark="card1"),
        dict(click=(0.245, 0.62), hold=1.3, mark="card2"),
        dict(click=(0.90, 0.955), hold=1.4, mark="size"),
        dict(key=(h.ESC,), hold=0.7),
    ])


# ---------------------------------------------------------------- 第六章
BEATS["ch06"] = spec(
    open="panel", title="", place=None,
    pad=10, fps=10, colors=176, hold=5, width=900,
    crop=(830, 280, 890, 500),
    beats=[
        dict(move=(0.50, 0.45), hold=1.9, mark="text"),
        dict(move=(0.50, 0.54), hold=1.8, mark="link"),
        dict(move=(0.50, 0.63), hold=1.6, mark="image"),
        dict(key=(h.ESC,), hold=0.5),
    ])


# ---------------------------------------------------------------- 第九章
BEATS["ch09"] = spec(
    open="demo?scene=beautify&file=/tmp/kitnest-demo.png", title="截图美化",
    place=(490, 150, 760, 592),
    pad=12, fps=10, colors=176, hold=6,
    beats=[
        dict(move=(0.82, 0.203), hold=0.9, mark="gradient"),
        dict(click=(0.755, 0.203), hold=1.3, mark="solid"),
        dict(click=(0.82, 0.203), hold=1.0),
        dict(move=(0.688, 0.264), hold=0.8),
        dict(click=(0.775, 0.264), hold=1.3, mark="swatch"),
        dict(move=(0.707, 0.343), hold=0.9, mark="slider"),
        dict(move=(0.828, 0.947), hold=1.0, mark="save"),
    ])


# ---------------------------------------------------------------- 第十二章
BEATS["ch12"] = spec(
    open="curtainprobe?count=3&shot=1", title="", place=None,
    pad=8, fps=10, colors=144, hold=5, width=900,
    beats=[
        dict(move=(0.30, 0.40), hold=1.0, mark="shelf"),
        dict(move=(0.45, 0.40), hold=1.4, mark="hover"),
        dict(move=(0.60, 0.40), hold=1.2),
        dict(move=(0.60, 0.40), hold=2.0),
    ])


# ---------------------------------------------------------------- 第十三章
BEATS["ch13"] = spec(
    open="capture?history=1", title="截图历史", place=(560, 180, 620, 452),
    pad=12, fps=10, colors=160, hold=5,
    beats=[
        dict(move=(0.30, 0.22), hold=0.6, mark="list"),
        dict(move=(0.30, 0.40), hold=0.6),
        dict(move=(0.30, 0.58), hold=0.6),
        dict(move=(0.72, 0.90), hold=0.8, mark="actions"),
    ])


# ---------------------------------------------------------------- 第二十二章
BEATS["ch22"] = spec(
    open="archive?action=mini", title="Mini", place=(700, 120, 360, 452),
    pad=12, fps=10, colors=160, hold=5,
    beats=[
        dict(move=(0.5, 0.25), hold=0.7, mark="head"),
        dict(move=(0.5, 0.55), hold=0.8, mark="body"),
        dict(move=(0.5, 0.88), hold=0.8),
    ])


# ---------------------------------------------------------------- 第三十三章
BEATS["ch33"] = spec(
    open="manual", title="设置", place=(400, 150, 940, 652),
    pad=12, fps=10, colors=176, hold=6, width=960,
    beats=[
        dict(move=(0.14, 0.22), hold=0.8, mark="toc"),
        dict(move=(0.55, 0.30), hold=0.9, mark="text"),
        dict(scroll=-4, hold=1.0),
        dict(scroll=-4, hold=1.0, mark="scroll"),
        dict(move=(0.85, 0.92), hold=0.6),
    ])



# ---------------------------------------------------------------- 第十章
BEATS["ch10"] = spec(
    open="longshotpreview", title="长截图", place=(400, 44, 920, 1000),
    pad=12, fps=10, colors=160, hold=6, width=620, cam=False,
    beats=[
        dict(move=(0.50, 0.40), hold=0.9, mark="top"),
        dict(scroll=-8, hold=1.3, mark="mid"),
        dict(scroll=-10, hold=1.3, mark="mid2"),
        dict(scroll=-16, hold=1.4, mark="bottom"),
        dict(move=(0.74, 0.955), hold=0.9, mark="save"),
    ])


# ---------------------------------------------------------------- 第十一章
BEATS["ch11"] = spec(
    open="settings?pane=pin", title="设置", place=(400, 150, 940, 652),
    pad=12, fps=10, colors=176, hold=6, width=960,
    beats=[
        dict(move=(0.30, 0.30), hold=0.9, mark="forms"),
        dict(move=(0.30, 0.45), hold=0.8),
        dict(click=(0.30, 0.45), hold=1.1, mark="pick"),
        dict(move=(0.20, 0.62), hold=0.8),
        dict(move=(0.20, 0.75), hold=0.8, mark="option"),
    ])


# ---------------------------------------------------------------- 第十五章
BEATS["ch15"] = spec(
    open="demo?scene=recorder", title="", place=None,
    pad=12, fps=10, colors=144, hold=5, width=640,
    # 保存位置显示的是 /Users/<真名>/Movies，换不掉，糊掉
    redact=dict(mode="paths"),
    beats=[
        dict(move=(0.30, 0.20), hold=0.8, mark="panel"),
        dict(move=(0.30, 0.45), hold=0.8),
        dict(move=(0.30, 0.70), hold=0.8, mark="opts"),
    ])


# ---------------------------------------------------------------- 第十六章
BEATS["ch16"] = spec(
    open="monitor?module=cpu", title="性能监测", place=(1300, 40, 380, 880),
    pad=12, fps=10, colors=160, hold=6, width=560,
    # 底部「占用进程」列的是本机真实进程
    redact=([(0.0, 0.690, 1.0, 0.31)], 12),
    beats=[
        dict(move=(0.50, 0.035), hold=0.7, mark="chips"),
        dict(click=(0.655, 0.035), hold=1.4, mark="memory"),
        dict(click=(0.80, 0.035), hold=1.4, mark="network"),
        dict(click=(0.20, 0.083), hold=1.4, mark="disk"),
        dict(click=(0.497, 0.083), hold=1.4, mark="temp"),
        dict(click=(0.655, 0.083), hold=1.4, mark="gpu"),
        dict(click=(0.497, 0.035), hold=1.3, mark="cpu"),
    ])


# ---------------------------------------------------------------- 第十七章
BEATS["ch17"] = spec(
    open="panel", title="", place=None,
    pad=10, fps=10, colors=160, hold=6, crop=(1330, 30, 380, 800),
    beats=[
        dict(click=(0.45, 0.03), hold=1.2, mark="monitor"),
        dict(click=(0.68, 0.099), hold=1.6, mark="memory"),
        dict(move=(0.50, 0.55), hold=1.2, mark="detail"),
    ])


# ---------------------------------------------------------------- 第十九章
BEATS["ch19"] = spec(
    open="monitor?module=network", title="性能监测", place=(1300, 40, 380, 880),
    pad=12, fps=10, colors=160, hold=6, width=560,
    # 「流量去哪了」按进程列出本机真实应用
    redact=([(0.0, 0.40, 1.0, 0.42)], 14),
    beats=[
        dict(move=(0.32, 0.075), hold=1.0, mark="net"),
        dict(move=(0.50, 0.35), hold=1.2, mark="graph"),
        dict(move=(0.50, 0.60), hold=1.2),
        dict(move=(0.50, 0.85), hold=1.2, mark="conn"),
    ])


# ---------------------------------------------------------------- 第二十章
BEATS["ch20"] = spec(
    open="panel", title="", place=None,
    pad=10, fps=10, colors=176, hold=6, crop=(1330, 30, 380, 800),
    # 文件列表来自磁盘索引，是本机真实文件名
    redact=([(0.0, 0.470, 1.0, 0.53)], 14),
    beats=[
        dict(click=(0.55, 0.03), hold=1.4, mark="page"),
        dict(move=(0.30, 0.20), hold=0.9),
        dict(click=(0.62, 0.20), hold=1.4, mark="mode"),
        dict(move=(0.50, 0.50), hold=1.0, mark="body"),
    ])


# ---------------------------------------------------------------- 第二十一章
BEATS["ch21"] = spec(
    open="panel", title="", place=None,
    pad=10, fps=10, colors=176, hold=6, crop=(1330, 30, 380, 800),
    beats=[
        dict(click=(0.65, 0.03), hold=1.4, mark="page"),
        dict(move=(0.28, 0.14), hold=0.9),
        dict(click=(0.72, 0.14), hold=1.4, mark="ios"),
        dict(click=(0.28, 0.14), hold=1.2),
        dict(move=(0.50, 0.35), hold=1.2, mark="connect"),
    ])


# ---------------------------------------------------------------- 第二十二章
BEATS["ch22"] = spec(
    open="archive?path=/tmp/kitnest-archive/素材包.zip", title="归档 · 素材包.zip",
    place=(560, 60, 860, 592),
    pad=12, fps=10, colors=160, hold=6, width=900,
    beats=[
        dict(move=(0.09, 0.22), hold=0.9, mark="list"),
        dict(click=(0.09, 0.22), hold=1.4, mark="preview"),
        dict(move=(0.06, 0.13), hold=1.0, mark="unzip"),
        dict(move=(0.86, 0.06), hold=1.0, mark="tools"),
    ])


# ---------------------------------------------------------------- 第二十三章
BEATS["ch23"] = spec(
    open="panel", title="", place=None,
    pad=10, fps=10, colors=160, hold=6, crop=(1330, 30, 380, 800),
    beats=[
        dict(click=(0.45, 0.12), hold=0.5),
        dict(type="/", hold=1.5, mark="tools"),
        dict(move=(0.40, 0.30), hold=0.8),
        dict(move=(0.40, 0.45), hold=0.8),
        dict(move=(0.40, 0.60), hold=0.8, mark="list"),
        dict(key=(h.ESC,), hold=0.5),
    ])


# ---------------------------------------------------------------- 第二十六章
BEATS["ch26"] = spec(
    open="panel", title="", place=None,
    pad=10, fps=10, colors=160, hold=6, crop=(1330, 170, 380, 400),
    beats=[
        dict(move=(0.36, 0.30), hold=0.8),
        dict(click=(0.425, 0.223), hold=1.2, mark="next"),
        dict(click=(0.425, 0.223), hold=1.2, mark="next2"),
        dict(click=(0.10, 0.223), hold=1.0),
        dict(move=(0.36, 0.30), hold=1.0, mark="date"),
        dict(move=(0.60, 0.36), hold=1.0),
    ])


# ---------------------------------------------------------------- 第二十七章
BEATS["ch27"] = spec(
    open="settings?pane=shortcuts", title="设置", place=(400, 150, 940, 652),
    pad=12, fps=10, colors=176, hold=6, width=960,
    beats=[
        dict(move=(0.55, 0.30), hold=0.9, mark="list"),
        dict(click=(0.72, 0.32), hold=1.2, mark="record"),
        dict(key=(h.ESC,), hold=0.7),
        dict(move=(0.55, 0.55), hold=0.9),
    ])


# ---------------------------------------------------------------- 第二十九章
BEATS["ch29"] = spec(
    open="cloudlink", title="网盘解析 · 夸克网盘", place=(560, 120, 600, 692),
    pad=12, fps=10, colors=160, hold=6, width=760,
    redact=([(0.0, 0.17, 1.0, 0.24)], 10),
    beats=[
        dict(move=(0.40, 0.18), hold=0.9, mark="head"),
        dict(move=(0.40, 0.42), hold=1.0, mark="list"),
        dict(move=(0.80, 0.90), hold=1.0, mark="download"),
    ])


# ---------------------------------------------------------------- 第三十章
BEATS["ch30"] = spec(
    open="settings?pane=ai", title="设置", place=(400, 150, 940, 652),
    pad=12, fps=10, colors=176, hold=6, width=960,
    beats=[
        dict(move=(0.35, 0.30), hold=0.9, mark="provider"),
        dict(click=(0.35, 0.30), hold=1.2, mark="pick"),
        dict(move=(0.55, 0.50), hold=0.9),
        dict(move=(0.55, 0.65), hold=0.9, mark="key"),
    ])


# ---------------------------------------------------------------- 第三十一章
BEATS["ch31"] = spec(
    open="settings?pane=general", title="设置", place=(400, 150, 940, 652),
    pad=12, fps=10, colors=176, hold=6, width=960,
    beats=[
        dict(move=(0.12, 0.22), hold=0.8),
        dict(click=(0.12, 0.30), hold=1.1, mark="clipboard"),
        dict(click=(0.12, 0.40), hold=1.1, mark="capture"),
        dict(click=(0.12, 0.55), hold=1.1, mark="tools"),
        dict(click=(0.12, 0.22), hold=1.1, mark="general"),
    ])


# ---------------------------------------------------------------- 第三十二章
BEATS["ch32"] = spec(
    open="demo?scene=welcome", title="欢迎", place=(480, 120, 760, 652),
    pad=12, fps=10, colors=176, hold=6, width=820,
    beats=[
        dict(move=(0.30, 0.30), hold=0.9, mark="intro"),
        dict(move=(0.55, 0.55), hold=1.0, mark="perm"),
        dict(move=(0.75, 0.55), hold=1.0),
        dict(move=(0.50, 0.90), hold=1.0, mark="start"),
    ])


# ---------------------------------------------------------------- 第三十四章
BEATS["ch34"] = spec(
    open="settings?pane=about", title="设置", place=(400, 150, 940, 652),
    pad=12, fps=10, colors=176, hold=6, width=960,
    beats=[
        dict(move=(0.50, 0.28), hold=0.9, mark="version"),
        dict(move=(0.50, 0.55), hold=1.0, mark="update"),
        dict(click=(0.50, 0.55), hold=1.4, mark="check"),
        dict(move=(0.50, 0.75), hold=1.0, mark="diag"),
    ])


# ---------------------------------------------------------------- 第三十五章
BEATS["ch35"] = spec(
    open="settingsprobe?block=capture", title="设置区块预览 · 截图",
    place=(500, 46, 760, 1000),
    pad=12, fps=10, colors=176, hold=6, width=700,
    beats=[
        dict(move=(0.50, 0.33), hold=0.9, mark="ratio"),
        dict(click=(0.62, 0.33), hold=1.2, mark="ratio-pick"),
        dict(move=(0.50, 0.47), hold=0.9, mark="name"),
        dict(move=(0.50, 0.62), hold=0.9, mark="badge"),
        dict(move=(0.30, 0.70), hold=0.9, mark="ocr"),
        dict(move=(0.30, 0.77), hold=0.9, mark="mosaic"),
    ])


# ---------------------------------------------------------------- 第三十六章
BEATS["ch36"] = spec(
    open="settingsprobe?block=recording", title="设置区块预览 · 录屏",
    place=(500, 46, 760, 1000),
    pad=12, fps=10, colors=176, hold=6, width=700,
    beats=[
        dict(move=(0.50, 0.25), hold=0.9, mark="source"),
        dict(move=(0.50, 0.42), hold=0.9, mark="camera"),
        dict(move=(0.50, 0.55), hold=0.9, mark="keys"),
        dict(move=(0.50, 0.68), hold=0.9, mark="quality"),
        dict(move=(0.50, 0.85), hold=1.0, mark="path"),
    ])


# ---------------------------------------------------------------- 第三十七章
BEATS["ch37"] = spec(
    open="settingsprobe?block=workflow", title="设置区块预览 · 工作流",
    place=(500, 46, 760, 1000), crop=(500, 46, 760, 350),
    redact=([(0.0, 0.13, 1.0, 0.16), (0.0, 0.56, 1.0, 0.22)], 10),
    pad=12, fps=10, colors=176, hold=6, width=700,
    beats=[
        dict(move=(0.35, 0.30), hold=1.0, mark="list"),
        dict(move=(0.35, 0.36), hold=1.0),
        dict(move=(0.35, 0.42), hold=1.0, mark="row3"),
        dict(move=(0.35, 0.52), hold=1.0, mark="token"),
        dict(move=(0.50, 0.60), hold=1.0, mark="hint"),
    ])


# ---------------------------------------------------------------- 第十四章
BEATS["ch14"] = spec(
    open="ocrwin?file=/tmp/kitnest-ocr.png", title="识别结果",
    place=(480, 180, 760, 480),
    pad=12, fps=10, colors=160, hold=6, width=900,
    beats=[
        dict(move=(0.35, 0.25), hold=1.0, mark="head"),
        dict(move=(0.35, 0.55), hold=1.2, mark="text"),
        dict(move=(0.85, 0.92), hold=1.0, mark="actions"),
    ])


# ---------------------------------------------------------------- 第二十八章
BEATS["ch28"] = spec(
    open="clipdesk", title="悬浮剪贴板", place=(250, 180, 1120, 720),
    pad=12, fps=10, colors=176, hold=6, width=980,
    beats=[
        dict(click=(0.083, 0.24), hold=1.2, mark="code"),
        dict(move=(0.62, 0.10), hold=0.9, mark="lang"),
        dict(click=(0.62, 0.10), hold=1.3, mark="menu"),
        dict(move=(0.62, 0.30), hold=1.0),
        dict(key=(h.ESC,), hold=0.8),
        dict(move=(0.88, 0.10), hold=1.0, mark="copy"),
    ])


# ---------------------------------------------------------------- 第三十三章
BEATS["ch33"] = spec(
    open="manual", title="设置", place=(400, 150, 940, 652),
    pad=12, fps=10, colors=176, hold=6, width=960,
    beats=[
        dict(move=(0.14, 0.22), hold=0.9, mark="toc"),
        dict(move=(0.55, 0.32), hold=1.0, mark="body"),
        dict(scroll=-5, hold=1.2, mark="scroll"),
        dict(scroll=-5, hold=1.2),
        dict(move=(0.86, 0.93), hold=0.8, mark="link"),
    ])


# ---------------------------------------------------------------- 第七章
@scene
def ch07():
    """截图主流程：⌥S 框选 → 动作条 → 悬停钉住组。"""
    h.clear_stage()
    h.prep_settings("manual")
    h.setframe("设置", 400, 180, 940, 652)
    h.sleep(0.5)
    h.minimize("hide")
    h.sleep(0.8)
    h.move(640, 420, 400)
    h.sleep(0.4)

    def body():
        h.move(700, 420, 500)
        h.sleep(0.2)
        h.key("1", "opt")          # ⌥S
        h.sleep(1.0)
        h.move(520, 360, 450)
        h.sleep(0.3)
        h.drag(520, 360, 1260, 600, 2200)
        h.sleep(1.0)
        h.move(880, 960, 700)      # 钉住组
        h.sleep(1.7)
        h.move(1010, 905, 450)
        h.sleep(1.0)

    # 框选覆盖层不做推拉：镜头一推，选区跟着放大，反而看不清框到哪
    custom("ch07", (388, 168, 980, 922), 10.6, body, width=720, zmax=1.0,
           max_kb=2600, cam=False)
    h.minimize("restore")


# ---------------------------------------------------------------- 第八章
@scene
def ch08():
    """标注编辑器：拖箭头 → 换马赛克 → 涂掉金额。"""
    h.clear_stage()
    h.minimize("hide")
    h.sleep(0.4)
    h.sh("open", "kitnest://annotate?file=/tmp/annot-demo.png")
    h.sleep(2.2)
    h.move(700, 300, 400)
    h.sleep(0.3)

    def body():
        h.drag(700, 300, 1000, 430, 950)
        h.sleep(0.7)
        h.move(465, 563, 650)
        h.sleep(0.5)
        h.click(465, 563, 100)
        h.sleep(0.7)
        h.drag(852, 318, 1006, 348, 800)
        h.sleep(0.8)
        h.move(993, 814, 600)
        h.sleep(1.2)

    custom("ch08", (405, 118, 976, 742), 10.4, body, width=820, zmax=1.9,
           max_kb=2400)
    h.minimize("restore")


# ---------------------------------------------------------------- 第十八章
BEATS["ch18"] = spec(
    open="storage", title="存储管理", place=(560, 50, 1080, 752),
    pad=12, fps=10, colors=160, hold=6, width=980,
    beats=[
        dict(move=(0.25, 0.35), hold=0.8, mark="chart"),
        dict(move=(0.25, 0.55), hold=0.8),
        dict(click=(0.25, 0.55), hold=1.3, mark="drill"),
        dict(move=(0.60, 0.30), hold=0.8),
        dict(move=(0.85, 0.95), hold=1.0, mark="action"),
    ])


# ---------------------------------------------------------------- 第二十四章
BEATS["ch24"] = spec(
    open="panel", title="", place=None,
    pad=10, fps=10, colors=160, hold=6, crop=(1330, 30, 380, 800),
    # 搜索会带出本机历史与索引条目
    redact=dict(mode="all", ymin=0.26),
    beats=[
        dict(click=(0.45, 0.12), hold=0.5),
        dict(type="image-html-deck", hold=2.2, mark="typing"),
        dict(move=(0.40, 0.30), hold=0.9, mark="group"),
        dict(move=(0.40, 0.45), hold=0.9),
        dict(move=(0.40, 0.60), hold=0.9, mark="file"),
        dict(key=(h.ESC,), hold=0.5),
    ])


# =================================================================== 执行
def build(name):
    sp = BEATS[name]

    def run():
        h.clear_stage()
        if sp.get("open"):
            open_url(sp["open"])
            h.sleep(1.8)
        title = sp.get("title", "")
        rect = h.windows().get(title)
        if rect is None and title:
            raise LookupError(f"{name}: 没有窗口 {title!r}，现有 {list(h.windows())}")
        if rect and sp.get("place"):
            h.setframe(title, *sp["place"])
            h.sleep(0.5)
            rect = h.windows().get(title, rect)
        play(name, rect, sp["beats"], pad=sp.get("pad", 10),
             fps=sp.get("fps", 10), colors=sp.get("colors", 176),
             hold=sp.get("hold", 5), width=sp.get("width", 0),
             ms=sp.get("ms", 100), badge=sp.get("badge", ""),
             crop_override=sp.get("crop"), max_kb=sp.get("max_kb", 2400),
             merge_th=sp.get("merge_th", 4), cam=sp.get("cam", True),
             redact=sp.get("redact"))

    run.__doc__ = sp.get("doc", name)
    return run


for _name in BEATS:
    SCENES[_name] = build(_name)
