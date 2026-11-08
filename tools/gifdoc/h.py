#!/usr/bin/env python3
"""演示 GIF 录制脚手架：真机屏幕录制 → 裁切 → 全局调色板 GIF。

v264 扩展：AX 元素定位（不写死坐标）、探针模式（只截图审构图）、
场景注册（scenes.py 一章一镜）、舞台清理（关窗/清剪贴板防抢镜）。
"""
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
PROBE = Path("/tmp/gifprobe")
for d in (WORK, PROBE):
    if not d.exists():
        d.mkdir(parents=True)

EDGE = "com.microsoft.edgemac"
QQ = "com.tencent.qq"
BUNDLE = "com.sxyq.frsetnext"

PROBING = os.environ.get("GIF_PROBE") == "1"
SCENE = os.environ.get("GIF_SCENE", "scene")
CROP = (0, 0, 0, 0)


def sh(*args, **kw):
    return subprocess.run([str(a) for a in args], capture_output=True, text=True, **kw)


def kpid() -> int:
    out = sh("pgrep", "-f", "Kitnest.app/Contents/MacOS/Kitnest").stdout.strip().splitlines()
    return int(out[0]) if out else 0


PID = kpid


def ax(*args, timeout=20):
    return sh(TOOL / "ax", *args, timeout=timeout).stdout


# 事件日志：录制时同步记下每一次输入，后期据此生成镜头关键帧
# （Screenize / OpenScreen 那条 two-pass 路子：先采鼠标数据，再算 zoom/pan）。
EVENTS = []
LAST_POS = [0, 0]


def ev(*args):
    sh(TOOL / "ev", *args)


def _log(kind, **kw):
    kw.update(kind=kind, t=time.time())
    EVENTS.append(kw)


def move(x, y, ms=320):
    x, y = int(x), int(y)
    _log("move", x=x, y=y, ms=ms, fx=LAST_POS[0], fy=LAST_POS[1])
    ev("move", x, y, ms)
    LAST_POS[0], LAST_POS[1] = x, y


def click(x, y, ms=260, kind="left"):
    x, y = int(x), int(y)
    _log("click", x=x, y=y, button=kind)
    ev("click", x, y, kind, ms)
    LAST_POS[0], LAST_POS[1] = x, y


def drag(x1, y1, x2, y2, ms=800):
    _log("drag", x=int(x1), y=int(y1), x2=int(x2), y2=int(y2), ms=ms)
    ev("drag", int(x1), int(y1), int(x2), int(y2), ms)
    LAST_POS[0], LAST_POS[1] = int(x2), int(y2)


def scroll(x, y, dy):
    _log("scroll", x=int(x), y=int(y), dy=int(dy))
    ev("scroll", int(x), int(y), int(dy))


def key(code, *mods):
    _log("key", code=code, mods=list(mods))
    ev("key", code, *mods)


def typ(text):
    _log("type", text=text)
    ev("type", text)


ESC, RET, DEL, TAB = "35", "24", "33", "30"


def sleep(s):
    time.sleep(s)


# ---------------------------------------------------------------- AX 定位

def find(role=None, desc=None, title=None, value=None):
    """返回 [(role, label, (x,y,w,h))]，同序同层（重复命中按坐标去重）。"""
    args = ["find", PID()]
    if role:
        args += ["--role", role]
    if desc:
        args += ["--desc", desc]
    if title:
        args += ["--title", title]
    if value:
        args += ["--value", value]
    out = ax(*args)
    hits, seen = [], set()
    for line in out.splitlines():
        m = re.match(r"\s*\[\d+\]\s+(\S+)\s+title=\"(.*?)\"\s+(-?\d+),(-?\d+)\s+(\d+)×(\d+)", line)
        if not m:
            continue
        r = (int(m.group(3)), int(m.group(4)), int(m.group(5)), int(m.group(6)))
        if r[2] == 0 or r[3] == 0:
            continue
        if r in seen:
            continue
        seen.add(r)
        hits.append((m.group(1), m.group(2), r))
    return hits


def center(rect):
    x, y, w, h = rect
    return (x + w // 2, y + h // 2)


def hit(role=None, desc=None, title=None, value=None, nth=0, dx=0, dy=0):
    hs = find(role=role, desc=desc, title=title, value=value)
    if len(hs) <= nth:
        raise LookupError(f"AX 未命中 role={role} desc={desc} title={title} value={value} n={nth}")
    x, y = center(hs[nth][2])
    return (x + dx, y + dy)


def click_el(ms=260, **kw):
    x, y = hit(**kw)
    move(x, y, 260)
    sleep(0.12)
    click(x, y, ms)
    return x, y


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


def mark(label="1"):
    """探针模式：在关键时刻截一张构图审图；录制模式空转。

    整屏截图后按点坐标 ×2 裁切——`screencapture -R` 的坐标口径在不同系统上
    不稳定（有时按点、有时按像素），自己裁最踏实。
    """
    if not PROBING:
        return
    p = PROBE / f"{SCENE}-{label}.png"
    full = PROBE / "_full.png"
    screen(full)
    if CROP[2]:
        from PIL import Image
        x, y, w, hh = CROP
        im = Image.open(full)
        im.crop((x * 2, y * 2, (x + w) * 2, (y + hh) * 2)).save(p)
    else:
        shutil.copy(full, p)
    print(f"[probe] {p} {CROP if CROP[2] else 'full'}")


class Rec:
    """开始/结束屏幕录制（含光标）。"""

    def __init__(self, name, secs):
        self.mov = WORK / f"{name}.mov"
        self.frames = WORK / name
        self.secs = secs
        self.proc = None

    def __enter__(self):
        if PROBING:
            return self
        if self.mov.exists():
            self.mov.unlink()
        self.proc = subprocess.Popen(
            ["screencapture", "-v", "-V", str(self.secs), "-C", "-x", str(self.mov)],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        time.sleep(0.45)   # 等录制真正起帧
        self.t0 = time.time()
        return self

    def __exit__(self, *exc):
        if PROBING:
            return False
        self.proc.wait(timeout=self.secs + 15)
        return False

    def frames_out(self, crop, width, start=0.0, end=0.0, fps=12, native=False):
        if PROBING:
            return self.frames
        if self.frames.exists():
            shutil.rmtree(self.frames)
        w = int(crop[2] * 2) if native else width
        args = [TOOL / "rec2gif", self.mov, "/tmp/ignore.gif",
                "--crop", ",".join(str(int(v)) for v in crop),
                "--width", w, "--fps", fps, "--start", f"{start:.2f}",
                "--frames", self.frames]
        if end:
            args += ["--end", f"{end:.2f}"]
        r = sh(*args)
        print(r.stdout.strip().splitlines()[-1] if r.stdout else r.stderr[-300:])
        meta = dict(t0=self.t0, crop=list(crop), fps=fps,
                    start=start, end=end or self.secs,
                    events=[dict(e, t=e["t"] - self.t0) for e in EVENTS])
        (WORK / f"{self.mov.stem}.json").write_text(
            __import__("json").dumps(meta, ensure_ascii=False))
        return self.frames


def gif(name, frames, ms=83, colors=192, badge="", hold=0, max_kb=0, merge_th=4):
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
    if merge_th:
        args += ["--merge-th", merge_th]
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


def open_app():
    sh("open", "-a", "/Applications/Kitnest.app")
    time.sleep(0.5)


def clear_stage(hard=True):
    """把所有 Kitnest 窗口关干净，回到「只剩菜单栏图标」的状态。

    某些窗（网盘解析 / 任务队列）不响应 ⌘W，且存活时会让 AX 遍历卡死，
    因此默认直接重启 App——3 秒，但换来每镜干净的起点。
    """
    if hard:
        restart()
        return
    open_app()
    for _ in range(2):
        key(ESC)
        time.sleep(0.2)
    for _ in range(8):
        if not windows():
            break
        key("13", "cmd")   # ⌘W
        time.sleep(0.3)
    close_windows()


def restart(greet=True):
    """重启 App：清掉上一镜残留窗口与状态（粘贴板防网盘抢镜）。"""
    sh("pkill", "-f", "Kitnest.app/Contents/MacOS/Kitnest")
    time.sleep(0.7)
    if greet:
        sh("bash", "-c", "printf 'kitnest demo' | pbcopy")
    sh("open", "-a", "/Applications/Kitnest.app")
    time.sleep(2.2)
    # 启动 2s 后网盘追赶会弹解析窗，直接关掉
    for _ in range(2):
        key(ESC)
        time.sleep(0.25)


def place(title, x, y, w=None, h=None):
    """把窗口挪到固定位置（宽高缺省沿用当前）。返回新 rect。"""
    r = windows().get(title)
    if not r:
        raise LookupError(f"窗口不存在：{title}（当前 {list(windows())}）")
    setframe(title, x, y, w or r[2], h or r[3])
    time.sleep(0.35)
    return windows().get(title, r)


def frame_of(title):
    return windows().get(title)
