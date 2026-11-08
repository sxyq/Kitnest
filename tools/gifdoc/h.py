#!/usr/bin/env python3
"""演示 GIF 录制脚手架：真机屏幕录制 → 裁切 → 全局调色板 GIF。"""
import os
import re
import shutil
import signal
import subprocess
import sys
import time
from pathlib import Path

TOOL = Path("/tmp/giftool")
WORK = Path("/tmp/gifwork")
if not WORK.exists():
    WORK.mkdir(parents=True)

EDGE = "com.microsoft.edgemac"
QQ = "com.tencent.qq"
BUNDLE = "com.sxyq.frsetnext"


def sh(*args, **kw):
    return subprocess.run([str(a) for a in args], capture_output=True, text=True, **kw)


def kpid() -> int:
    out = sh("pgrep", "-f", "Kitnest.app/Contents/MacOS/Kitnest").stdout.strip().splitlines()
    return int(out[0]) if out else 0


PID = kpid


def ax(*args, timeout=20):
    return sh(TOOL / "ax", *args, timeout=timeout).stdout


def ev(*args):
    sh(TOOL / "ev", *args)


def move(x, y, ms=320):
    ev("move", int(x), int(y), ms)


def click(x, y, ms=260, kind="left"):
    ev("click", int(x), int(y), kind, ms)


def drag(x1, y1, x2, y2, ms=800):
    ev("drag", int(x1), int(y1), int(x2), int(y2), ms)


def key(code, *mods):
    ev("key", code, *mods)


def typ(text):
    ev("type", text)


ESC, RET, DEL, TAB = "35", "24", "33", "30"


def sleep(s):
    time.sleep(s)


def windows() -> dict:
    """{title: (x,y,w,h)} 直接读 Kitnest 的 AX 窗口表。"""
    out = {}
    for line in ax("frame", PID()).strip().splitlines():
        if "|" not in line:
            continue
        title, rect = line.rsplit("|", 1)
        nums = [int(v) for v in rect.split(",")]
        out[title] = tuple(nums)
    return out


def setframe(title, x, y, w, h):
    sh(TOOL / "setf", PID(), title, int(x), int(y), int(w), int(h))


def minimize(mode, apps=(EDGE, QQ)):
    """mode: 'hide' | 'restore'  —— 最小化别人的窗口，录完立刻还原。"""
    flag = "1" if mode == "hide" else "0"
    for b in apps:
        ids = sh("pgrep", "-f", "/MacOS/").stdout  # 占位，真正 pid 下面按名字找
        name = {"com.microsoft.edgemac": "Microsoft Edge", "com.tencent.qq": "QQ"}[b]
        pid = sh("pgrep", "-x", name).stdout.strip().splitlines()
        if not pid:
            continue
        ax("minimize", pid[0], "--on", flag)


def screen(path, rect=None):
    args = ["screencapture", "-x"]
    if rect:
        args += ["-R", ",".join(str(int(v)) for v in rect)]
    args.append(str(path))
    sh(*args)


class Rec:
    """开始/结束屏幕录制（含光标）。"""

    def __init__(self, name, secs):
        self.mov = WORK / f"{name}.mov"
        self.frames = WORK / name
        self.secs = secs
        self.proc = None

    def __enter__(self):
        if self.mov.exists():
            self.mov.unlink()
        self.proc = subprocess.Popen(
            ["screencapture", "-v", "-V", str(self.secs), "-C", "-x", str(self.mov)],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        time.sleep(0.45)   # 等录制真正起帧
        self.t0 = time.time()
        return self

    def __exit__(self, *exc):
        self.proc.wait(timeout=self.secs + 15)
        return False

    def frames_out(self, crop, width, start=0.0, end=0.0, fps=12):
        if self.frames.exists():
            shutil.rmtree(self.frames)
        args = [TOOL / "rec2gif", self.mov, "/tmp/ignore.gif",
                "--crop", ",".join(str(int(v)) for v in crop),
                "--width", width, "--fps", fps, "--start", f"{start:.2f}",
                "--frames", self.frames]
        if end:
            args += ["--end", f"{end:.2f}"]
        r = sh(*args)
        print(r.stdout.strip().splitlines()[-1] if r.stdout else r.stderr[-300:])
        return self.frames


def gif(name, frames, ms=83, colors=192, badge="", hold=0, max_kb=0):
    out = Path("/tmp/gifs_out")
    if not out.exists():
        out.mkdir(parents=True)
    dst = out / f"{name}.gif"
    args = ["python3", TOOL / "gifmake.py", frames, dst, "--ms", ms,
            "--colors", colors]
    if badge:
        args += ["--badge", badge]
    if hold:
        args += ["--hold", hold]
    if max_kb:
        args += ["--max-kb", max_kb]
    print(sh(*args).stdout.strip())
    return dst


def prep_settings(pane="manual"):
    """打开设置窗口并放到固定位置，返回窗口 rect。"""
    sh("open", f"kitnest://settings?pane={pane}")
    time.sleep(1.6)
    rect = windows().get("设置")
    if rect:
        setframe("设置", 300, 90, rect[2], rect[3])
        time.sleep(0.4)
        rect = windows().get("设置")
    return rect


def close_windows():
    """Esc 关掉覆盖层/浮层，再把 Kitnest 的普通窗口关掉。"""
    for _ in range(3):
        key(ESC)
        time.sleep(0.25)
