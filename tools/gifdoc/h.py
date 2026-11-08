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


def panel_frame():
    """主面板窗口的 (x, y, w, h)；没开返回 None。

    走 CGWindowList 而不是 AX：主面板是 NSPanel，AX 里看不见（windows() 返回空），
    但 CGWindowList 能看到它 360×700 的窗口和 alpha。
    """
    out = sh(TOOL / "winlist").stdout
    for line in out.splitlines():
        if '"Width": 360' in line and '"Height": 700' in line:
            m = re.search(r"alpha=([\d.]+)", line)
            if not m or float(m.group(1)) <= 0.9:
                return None
            x = re.search(r'"X": (-?\d+)', line)
            y = re.search(r'"Y": (-?\d+)', line)
            return (int(x.group(1)), int(y.group(1)), 360, 700)
    return None


def try_icon(x):
    """点一下某个候选位置，返回打开的主面板 frame（没开则 None）。"""
    for _ in range(2):
        key(ESC)
        time.sleep(0.18)
    move(x, 19, 90)
    time.sleep(0.12)
    click(x, 19, 90)
    time.sleep(0.9)
    pf = panel_frame()
    if pf and abs(pf[0] - x) < 260 and pf[1] < 200:
        return pf
    return None


def status_icon(preferred=1363, span=6):
    """找出菜单栏主图标当前的 x，返回 (x, 面板 frame)。

    菜单栏图标位置不固定：装的 App 一变或重启一次，Kitnest 的图标就被挤到别处，
    写死会点到邻居（实测点开过 1Capture 的菜单）。

    但也不能盲目大范围扫描：连续点几十次会把 App 的窗口状态搅乱，之后再也点不开。
    所以先试首选位置，只在失败时向两侧各试几个。
    """
    pf = try_icon(preferred)
    if pf:
        key(ESC)
        time.sleep(0.4)
        return preferred, pf
    for d in range(1, 5):
        for x in (preferred - d * span, preferred + d * span):
            pf = try_icon(x)
            if pf:
                key(ESC)
                time.sleep(0.4)
                return x, pf
    return None, None


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


_HIDDEN: list[str] = []


def hide_others():
    """把所有前台应用（Kitnest / Finder 除外）隐藏起来。

    分镜只框应用自己，但面板是半透明玻璃、覆盖层又是全屏——后面开着浏览器，
    标签页标题就会透出来（实测 ch01 拍进过 Safari 的「手册-Frset...」）。
    录完用 restore_others() 还原。返回被隐藏的应用名。
    """
    global _HIDDEN
    script = (
        'tell application "System Events"\n'
        '  set names to {}\n'
        '  repeat with p in (every process whose background only is false)\n'
        '    set n to name of p\n'
        '    if n is not "Kitnest" and n is not "Finder" and n is not "Dock" '
        'and n is not "SystemUIServer" and n is not "ControlCenter" '
        'and n is not "WorkBuddy" then\n'
        '      try\n'
        '        if visible of p is true then\n'
        '          set visible of p to false\n'
        '          set end of names to n\n'
        '        end if\n'
        '      end try\n'
        '    end if\n'
        '  end repeat\n'
        '  return names\n'
        'end tell'
    )
    out = sh("osascript", "-e", script, timeout=30).stdout.strip()
    _HIDDEN = [s.strip() for s in out.split(",") if s.strip()]
    return _HIDDEN


def restore_others():
    for n in _HIDDEN:
        sh("osascript", "-e",
           f'tell application "System Events" to set visible of process "{n}" to true',
           timeout=15)


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


def redact(frames, boxes, radius=9, pixel=0):
    """对画面里的指定区域做模糊。

    有些内容是换不掉的：磁盘索引里的真实文件名、系统监测的进程名、
    `~/Movies` 这类系统路径——它们来自 App 运行环境而不是数据目录。
    演示数据覆盖不到，就在出图前糊掉，别让它们进公开文档。

    boxes 用**画面比例** (x, y, w, h)，0~1：各章输出分辨率不同，写像素会错位。
    """
    from PIL import Image, ImageFilter
    paths = sorted(Path(frames).glob("*.png")) if isinstance(frames, (str, Path)) else frames
    for p in paths:
        im = Image.open(p).convert("RGB")
        W, H = im.size
        dirty = False
        for (fx, fy, fw, fh) in boxes:
            box = (int(fx * W), int(fy * H),
                   int((fx + fw) * W), int((fy + fh) * H))
            if box[2] - box[0] < 2 or box[3] - box[1] < 2:
                continue
            piece = im.crop(box)
            if pixel:
                # 马赛克比模糊可靠：模糊留低频信息，缩到 1/12 再放大就什么都读不出
                small = piece.resize((max(1, piece.width // pixel),
                                      max(1, piece.height // pixel)), Image.BILINEAR)
                piece = small.resize(piece.size, Image.NEAREST)
            else:
                piece = piece.filter(ImageFilter.GaussianBlur(radius))
            im.paste(piece, box)
            dirty = True
        if dirty:
            im.save(p)
    return frames


def auto_redact(frames, mode="all", ymin=0.0, ymax=1.0, radius=9):
    """用 OCR 找文字位置再模糊——比手写比例准。

    手量区域试过，误差能有 5%：路径那行没盖住、下面的按钮倒被糊了。
    这里读取中间帧的文字框，按规则挑出要处理的块：

      mode="all"    区域内所有文字（整块内容都不该公开时用）
      mode="paths"  只处理含本机路径 / 用户名的行
      mode="names"  只处理区域内的短行（进程名、文件名，通常没有空格）
    """
    from PIL import Image, ImageFilter
    import re as _re

    paths = sorted(Path(frames).glob("*.png")) if isinstance(frames, (str, Path)) else list(frames)
    if not paths:
        return frames
    probe = str(paths[len(paths) // 2])
    out = sh(TOOL / "ocrbox", probe, timeout=60).stdout

    boxes = []
    for line in out.splitlines():
        parts = line.split("\t")
        if len(parts) < 5:
            continue
        try:
            x, y, w, hh = (float(v) for v in parts[:4])
        except ValueError:
            continue
        text = parts[4]
        if not (ymin <= y + hh / 2 <= ymax):
            continue
        if mode == "paths":
            if not _re.search(r"/Users/|sunyiyang|/home/|~/\w", text):
                continue
        elif mode == "names":
            if len(text) > 44 or " " in text.strip():
                continue
        # 留一点余量，别把字形边缘露出来
        boxes.append((max(0.0, x - 0.004), max(0.0, y - 0.004),
                      w + 0.008, hh + 0.010))

    if boxes:
        redact(paths, boxes, radius=radius)
        print(f"  自动打码 {len(boxes)} 处（{mode}）")
    return frames
