#!/usr/bin/env python3
"""镜头后期：把「平铺录屏」变成带推拉、跟随、点击涟漪的演示片。

思路抄 Screenize / OpenScreen 的 two-pass：
  第一遍录屏时把鼠标/点击/打字/滚动写成事件日志（h.py 的 EVENTS → *.json），
  第二遍按事件生成镜头关键帧（segment-based camera），再逐帧裁切放大。

和它们不同的是：这里的事件是**我们自己合成**的，坐标和时刻都精确，
不需要用 Vision 去猜 UI 元素，也不会出现「镜头跟丢光标」。

镜头规则
--------
* 点击   → 推近到 1.95×，停留到下一个动作前
* 打字   → 1.75×，覆盖整段输入
* 拖拽   → 1.5×，起点终点各一个镜头
* 滚动   → 1.4×，跟着滚轮位置
* 停住看 → 1.3×（弱镜头，停顿 ≥0.65s 才算）
* 无动作 → 回 1.0×

叠加层
------
* 点击涟漪：两圈由内向外扩散，0.5s 淡出
* 光标环：放大状态下给真光标套一圈细环，方便跟眼（原光标仍来自录屏本身）
"""
import json
import math
import sys
from pathlib import Path

from PIL import Image, ImageDraw

FPS = 10
RAMP_IN, RAMP_OUT = 0.20, 0.28
SIGMA_TAU_C, SIGMA_TAU_S = 0.10, 0.12


def ease(t):
    """smoothstep：进出都不带速度突变。"""
    t = max(0.0, min(1.0, t))
    return t * t * (3 - 2 * t)


def clamp(v, lo, hi):
    return lo if v < lo else hi if v > hi else v


def cursor_at(events, t):
    """还原 t 时刻的光标位置（move 是带缓动的两点插值，和 ev 的缓动一致）。"""
    pos = None
    for e in events:
        if e["kind"] == "move":
            dur = e.get("ms", 320) / 1000.0
            if t < e["t"]:
                break
            if t <= e["t"] + dur and dur > 0:
                p = (t - e["t"]) / dur
                # ev.swift 的 ease：t<0.5 ? 2t² : 1-(-2t+2)²/2
                k = 2 * p * p if p < 0.5 else 1 - pow(-2 * p + 2, 2) / 2
                return (e["fx"] + (e["x"] - e["fx"]) * k,
                        e["fy"] + (e["y"] - e["fy"]) * k)
            pos = (e["x"], e["y"])
        elif e["kind"] in ("click", "drag", "scroll"):
            if t < e["t"]:
                break
            pos = (e["x"], e["y"])
    return pos


def segments(events, rect, dur):
    """事件 → 镜头段 (t0, t1, scale, cx, cy, weight)。"""
    x0, y0, w, h = rect
    inside = lambda x, y: x0 - 2 <= x <= x0 + w + 2 and y0 - 2 <= y <= y0 + h + 2
    evs = [e for e in events if e["t"] >= -0.6]
    segs = []
    for i, e in enumerate(evs):
        t = e["t"]
        nxt = next((evs[j]["t"] for j in range(i + 1, len(evs))
                    if evs[j]["t"] > t + 0.05), dur)
        gap = max(0.6, min(nxt - t - 0.10, 2.8))
        if e["kind"] == "click" and inside(e["x"], e["y"]):
            segs.append((t - 0.10, t + gap, 1.95, e["x"], e["y"], 1.0))
        elif e["kind"] == "move":
            # 停在某处看 ≥0.75s：给一个弱镜头，静止界面也能看出重点
            end = e["t"] + e.get("ms", 320) / 1000.0
            nxt = next((x["t"] for x in events if x["t"] > end + 0.05), dur)
            if nxt - end >= 0.75 and inside(e["x"], e["y"]):
                pts.append((end, e["x"], e["y"], 1.45))
        elif e["kind"] == "drag":
            if inside(e["x"], e["y"]):
                segs.append((t, t + max(0.9, gap), 1.5, e["x"], e["y"], 0.6))
            if inside(e["x2"], e["y2"]):
                segs.append((t + e.get("ms", 800) / 1000.0,
                             t + e.get("ms", 800) / 1000.0 + 1.2,
                             1.55, e["x2"], e["y2"], 0.7))
        elif e["kind"] == "scroll" and inside(e["x"], e["y"]):
            segs.append((t - 0.05, t + max(0.7, gap), 1.42, e["x"], e["y"], 0.55))
        elif e["kind"] == "type":
            p = cursor_at(events, t) or (x0 + w / 2, y0 + h / 2)
            segs.append((t - 0.08, t + max(1.2, gap + 0.35), 1.75, p[0], p[1], 0.9))
        elif e["kind"] == "move" and i + 1 < len(evs):
            nxt_t = evs[i + 1]["t"]
            end_t = t + e.get("ms", 320) / 1000.0
            if nxt_t - end_t >= 0.65 and inside(e["x"], e["y"]):
                segs.append((end_t, min(nxt_t - 0.05, end_t + 2.2),
                             1.30, e["x"], e["y"], 0.35))
    return segs


def ramp(t, t0, t1):
    if t < t0 or t > t1:
        return 0.0
    a = clamp((t - t0) / RAMP_IN, 0, 1)
    b = clamp((t1 - t) / RAMP_OUT, 0, 1)
    return ease(min(a, 1.0)) * ease(min(b, 1.0)) if min(a, b) < 1 else 1.0


def shots(events, rect, dur, hold=2.8):
    """事件 → 连续镜头段落。

    * 点击/打字/滚动/拖拽：强镜头，逐个成段；
    * 停顿：先按「时间近 + 距离近」聚成簇，一簇只给一个镜头——否则表单页每悬停
      一行就推拉一次，镜头乱抖，GIF 也大一倍；
    * 每段一直保持到下一个动作，空闲超过 hold 才拉回全景。
    """
    x0, y0, w, h = rect
    inside = lambda x, y: x0 - 2 <= x <= x0 + w + 2 and y0 - 2 <= y <= y0 + h + 2
    strong, settles = [], []
    for e in events:
        if e["kind"] == "click" and inside(e["x"], e["y"]):
            strong.append((e["t"], e["x"], e["y"], 1.95))
        elif e["kind"] == "type":
            p = cursor_at(events, e["t"]) or (x0 + w / 2, y0 + h / 2)
            strong.append((e["t"], p[0], p[1], 1.75))
        elif e["kind"] == "scroll" and inside(e["x"], e["y"]):
            strong.append((e["t"], e["x"], e["y"], 1.45))
        elif e["kind"] == "drag":
            d = e.get("ms", 800) / 1000.0
            strong.append((e["t"], e["x"], e["y"], 1.5))
            strong.append((e["t"] + d, e["x2"], e["y2"], 1.55))
        elif e["kind"] == "move":
            end = e["t"] + e.get("ms", 320) / 1000.0
            nxt = next((x["t"] for x in events if x["t"] > end + 0.05), dur)
            if nxt - end >= 0.75 and inside(e["x"], e["y"]):
                settles.append([end, e["x"], e["y"]])

    # 停顿聚簇
    clusters = []
    for (t, x, y) in settles:
        if clusters:
            c = clusters[-1]
            if t - c["t1"] <= 2.4 and math.hypot(x - c["cx"], y - c["cy"]) <= 170:
                n = c["n"] + 1
                c["cx"] = (c["cx"] * c["n"] + x) / n
                c["cy"] = (c["cy"] * c["n"] + y) / n
                c["n"], c["t1"] = n, t
                continue
        clusters.append(dict(t0=t, t1=t, cx=x, cy=y, n=1))
    pts = strong + [(c["t0"], c["cx"], c["cy"], 1.5) for c in clusters
                    if not any(abs(c["t0"] - s[0]) < 1.0 for s in strong)]
    pts.sort()
    out = []
    for i, (t, x, y, s) in enumerate(pts):
        nxt = pts[i + 1][0] if i + 1 < len(pts) else dur
        end = nxt + (0.55 if nxt - t <= hold else 0.0)
        end = min(end, t + hold + 0.55)
        out.append((t - 0.12, end, s, x, y))
    return out


def targets(n, start, fps, segs, rect):
    """逐帧取镜头目标：落在段落里就用段落值，否则回全景。"""
    x0, y0, w, h = rect
    base = (x0 + w / 2, y0 + h / 2)
    S, C = [], []
    for i in range(n):
        t = start + i / fps
        cur = None
        for (t0, t1, s, cx, cy) in segs:
            if t0 <= t <= t1:
                cur = (s, cx, cy)
                break
        if cur is None:
            S.append(1.0); C.append(base)
        else:
            S.append(cur[0]); C.append((cur[1], cur[2]))
    return S, C


def smooth(vals, fps, tau):
    out, acc = [], None
    for v in vals:
        if acc is None:
            acc = v
        else:
            k = 1 - math.exp(-1.0 / (tau * fps))
            if isinstance(v, tuple):
                acc = (acc[0] + (v[0] - acc[0]) * k, acc[1] + (v[1] - acc[1]) * k)
            else:
                acc = acc + (v - acc) * k
        out.append(acc)
    # 反向再滤一遍，消掉滞后
    out2, acc = [], None
    for v in reversed(out):
        if acc is None:
            acc = v
        else:
            k = 1 - math.exp(-1.0 / (tau * fps))
            if isinstance(v, tuple):
                acc = (acc[0] + (v[0] - acc[0]) * k, acc[1] + (v[1] - acc[1]) * k)
            else:
                acc = acc + (v - acc) * k
        out2.append(acc)
    return list(reversed(out2))


def render(frames_dir, meta_path, out_dir, width=0, max_zoom=2.0, ripple=True):
    meta = json.loads(Path(meta_path).read_text())
    frames = sorted(Path(frames_dir).glob("*.png"))
    if not frames:
        raise SystemExit("没有帧")
    rect = meta["crop"]
    start, fps = meta["start"], meta["fps"]
    events = meta["events"]
    dur = meta["end"] - start
    n = len(frames)

    segs = shots(events, rect, dur)
    S, C = targets(n, start, fps, segs, rect)
    S = [min(s, max_zoom) for s in smooth(S, fps, SIGMA_TAU_S)]
    C = smooth(C, fps, SIGMA_TAU_C)

    first = Image.open(frames[0])
    W2, H2 = first.size
    out_w = width or min(W2, 1100)
    out_h = int(round(out_w * H2 / W2))
    dst = Path(out_dir)
    dst.mkdir(parents=True, exist_ok=True)
    for f in dst.glob("*.png"):
        f.unlink()

    prev_s = prev_c = None
    for i, fp in enumerate(frames):
        im = Image.open(fp).convert("RGB")
        s = S[i]
        # 死区：镜头几乎不动时钉住，保证静止段逐帧完全一致，
        # 否则 GIF 的增量帧会退化成一整帧，体积翻十倍。
        if prev_s is not None:
            if abs(s - prev_s) < 0.002:
                s = prev_s
            if abs(C[i][0] - prev_c[0]) < 0.35 and abs(C[i][1] - prev_c[1]) < 0.35:
                C[i] = prev_c
        prev_s, prev_c = s, C[i]
        vw, vh = W2 / s, H2 / s
        cx, cy = C[i][0] * 2, C[i][1] * 2      # 点 → 2x 像素
        bx = clamp(cx - vw / 2, 0, W2 - vw)
        by = clamp(cy - vh / 2, 0, H2 - vh)
        view = im.crop((int(bx), int(by), int(bx + vw), int(by + vh)))
        view = view.resize((out_w, out_h), Image.LANCZOS)

        if ripple or s > 1.2:
            d = ImageDraw.Draw(view, "RGBA")
            k = out_w / vw
            t = start + i / fps
            if ripple:
                for e in events:
                    if e["kind"] != "click":
                        continue
                    dt = t - e["t"]
                    if not (0 <= dt <= 0.52):
                        continue
                    p = dt / 0.52
                    px = (e["x"] * 2 - bx) * k
                    py = (e["y"] * 2 - by) * k
                    if not (-40 < px < out_w + 40 and -40 < py < out_h + 40):
                        continue
                    a = int(210 * (1 - p) ** 1.5)
                    r = 9 + 52 * p
                    d.ellipse((px - r, py - r, px + r, py + r),
                              outline=(255, 255, 255, a), width=max(1, int(3.6 * (1 - p) + 1)))
                    r2 = r * 0.56
                    d.ellipse((px - r2, py - r2, px + r2, py + r2),
                              outline=(120, 180, 255, int(a * 0.75)), width=2)
            if s > 1.2:
                pos = cursor_at(events, t)
                if pos:
                    px = (pos[0] * 2 - bx) * k
                    py = (pos[1] * 2 - by) * k
                    if 0 < px < out_w and 0 < py < out_h:
                        rr = 15
                        d.ellipse((px - rr, py - rr, px + rr, py + rr),
                                  outline=(255, 255, 255, 90), width=2)
        view.save(dst / f"{i:04d}.png")
    print(f"camera: {n} frames, zoom {min(S):.2f}–{max(S):.2f}×, "
          f"segments {len(segs)}, out {out_w}×{out_h} → {dst}")
    return dst


if __name__ == "__main__":
    a = sys.argv[1:]
    render(a[0], a[1], a[2], width=int(a[3]) if len(a) > 3 else 0)
