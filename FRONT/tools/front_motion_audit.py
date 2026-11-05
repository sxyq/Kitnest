#!/usr/bin/env python3
"""官网动效守卫：证明 FRONT/ 的动画参数与 App 源码 Theme.Motion 一模一样。

检查项：
  1. 从 Sources/Core/UI/Support.swift 解析 Theme.Motion 的全部时长 / spring 参数 /
     CA 控制点，从 Personalization.swift 解析开合三档与默认值；
  2. 与 FRONT/assets/motion.js 的镜像常量逐项比对（数值、控制点、档位）；
  3. CSS 除 :root 静态兜底区与 reduced-motion 段外，不得出现写死的时长或曲线；
  4. 循环动画必须线性；caBackOut 只能用于监测独立窗入场；
  5. site.js 不得写死动画时长（延时一律取自 Motion.tokens）。

用法：python3 FRONT/tools/front_motion_audit.py [--list]
退出码：0 通过，1 有漂移或违规。
"""
import math
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SUPPORT = ROOT / "apps/FrsetNext/Sources/Core/UI/Support.swift"
PERSONAL = ROOT / "apps/FrsetNext/Sources/Core/Runtime/Personalization.swift"
TOAST = ROOT / "apps/FrsetNext/Sources/Core/UI/Toast.swift"
MOTION_JS = ROOT / "FRONT/assets/motion.js"
SITE_CSS = ROOT / "FRONT/assets/site.css"
SITE_JS = ROOT / "FRONT/assets/site.js"

problems = []
checked = []


def num(s):
    return round(float(s), 6)


def read(p):
    return p.read_text(encoding="utf-8")


def parse_swift():
    src = read(SUPPORT)
    out = {}

    for key in ("tap", "fast", "page", "slow"):
        m = re.search(r"static let %s: Animation = \.easeOut\(duration: ([\d.]+)\)" % key, src)
        if m:
            out[key] = num(m.group(1))
        else:
            problems.append("Swift: 找不到 Theme.Motion.%s" % key)

    for key in ("springSnappy", "spring", "springSoft", "springBouncy"):
        m = re.search(
            r"static let %s: Animation = \.spring\(response: ([\d.]+), dampingFraction: ([\d.]+)\)" % key,
            src)
        if m:
            out[key] = (num(m.group(1)), num(m.group(2)))
        else:
            problems.append("Swift: 找不到 Theme.Motion.%s" % key)

    for key in ("loop", "progress"):
        m = re.search(r"static let %s: Animation = \.linear\(duration: ([\d.]+)\)" % key, src)
        if m:
            out[key] = num(m.group(1))
        else:
            problems.append("Swift: 找不到 Theme.Motion.%s" % key)

    ca = {
        "caEaseOut": r"static let caEaseOut = CAMediaTimingFunction\(controlPoints: ([\d.]+), ([\d.]+), ([\d.]+), ([\d.]+)\)",
        "caBackOut": r"static let caBackOut = CAMediaTimingFunction\(controlPoints: ([\d.]+), ([\d.]+), ([\d.]+), ([\d.]+)\)",
        "caEaseIn": r"static let caEaseIn = CAMediaTimingFunction\(name: \.easeIn\)",
        "caEaseInEaseOut": r"static let caEaseInEaseOut = CAMediaTimingFunction\(name: \.easeInEaseOut\)",
    }
    for key, pat in ca.items():
        m = re.search(pat, src)
        if key == "caEaseIn":
            out[key] = (0.42, 0, 1, 1) if m else None
        elif key == "caEaseInEaseOut":
            out[key] = (0.42, 0, 0.58, 1) if m else None
        elif m:
            out[key] = tuple(num(g) for g in m.groups())
        else:
            out[key] = None
        if out[key] is None:
            problems.append("Swift: 找不到 Theme.Motion.%s" % key)

    per = read(PERSONAL)
    # 只取 PersonalizationOpenAnimation 的 duration 计算属性，别的文件里同名 case 不算
    dur_block = re.search(r"public var duration: TimeInterval \{(.*?)\n    \}", per, re.S)
    if not dur_block:
        problems.append("Swift: 找不到 PersonalizationOpenAnimation.duration")
        dur_block = type("X", (), {"group": lambda self, i: ""})()
    for key in ("snappy", "standard", "soft"):
        m = re.search(r"case \.%s: return ([\d.]+)" % key, dur_block.group(1))
        if m:
            out["open." + key] = num(m.group(1))
        else:
            problems.append("Swift: 找不到 PersonalizationOpenAnimation.%s" % key)
    default = re.search(r"openAnimation: PersonalizationOpenAnimation = \.(\w+)", per)
    out["open.default"] = default.group(1) if default else "standard"

    toast = read(TOAST)
    m = re.search(r"scaleEffect\(state\.isVisible \? 1\.0 : ([\d.]+)", toast)
    out["toast.scale"] = num(m.group(1)) if m else None
    m = re.search(r"orderOutDelay: TimeInterval = ([\d.]+)", toast)
    out["toast.orderOutDelay"] = num(m.group(1)) if m else None
    return out


def parse_js():
    src = read(MOTION_JS)
    out = {}
    for key in ("tap", "fast", "page", "slow", "loop", "progress"):
        m = re.search(r"\b%s: ([\d.]+)," % key, src)
        out[key] = num(m.group(1)) if m else None
        if not m:
            problems.append("motion.js: 找不到 %s" % key)

    for key in ("springSnappy", "spring", "springSoft", "springBouncy"):
        m = re.search(
            r"\b%s:\s*\{ response: ([\d.]+), dampingFraction: ([\d.]+) \}" % key, src)
        out[key] = (num(m.group(1)), num(m.group(2))) if m else None
        if not m:
            problems.append("motion.js: 找不到 %s" % key)

    for key in ("caEaseOut", "caEaseIn", "caEaseInEaseOut", "caBackOut"):
        m = re.search(r"\b%s:\s*\[([^\]]+)\]" % key, src)
        out[key] = tuple(num(x) for x in m.group(1).split(",")) if m else None
        if not m:
            problems.append("motion.js: 找不到 %s" % key)

    block = re.search(r"openDuration: \{([^}]+)\}", src).group(1)
    for key in ("snappy", "standard", "soft"):
        m = re.search(r"%s: ([\d.]+)" % key, block)
        out["open." + key] = num(m.group(1)) if m else None
    m = re.search(r'openPreset: "(\w+)"', src)
    out["open.default"] = m.group(1) if m else None
    m = re.search(
        r"toast: \{ displayDuration: ([\d.]+), orderOutDelay: ([\d.]+), scale: ([\d.]+) \}", src)
    if m:
        out["toast.orderOutDelay"] = num(m.group(2))
        out["toast.scale"] = num(m.group(3))
    else:
        problems.append("motion.js: 找不到 MenuBarToastManager 常量")
    return out


def compare_constants(swift, js):
    for key in swift:
        a, b = swift[key], js.get(key)
        if a != b:
            problems.append("参数漂移 %-22s App=%s  官网=%s" % (key, a, b))
        else:
            checked.append("%-22s %s" % (key, a))


def spring_settle(response, damping):
    """与 motion.js solveSpring 同一条解析式，用来校验 CSS 静态兜底时长。"""
    w0 = 2 * math.pi / response
    wd = w0 * math.sqrt(max(1e-9, 1 - damping ** 2))
    k = damping * w0 / wd
    amp = math.sqrt(1 + k * k)
    return max(math.log(max(amp / 0.001, 2)) / (damping * w0), response * 1.2)


def audit_spring_fallback(swift):
    src = read(SITE_CSS)
    css_var = {
        "springSnappy": "--d-spring-snappy",
        "spring": "--d-spring",
        "springSoft": "--d-spring-soft",
        "springBouncy": "--d-spring-bouncy",
    }
    for key, var in css_var.items():
        m = re.search(re.escape(var) + r":\s*([\d.]+)s;", src)
        if not m:
            problems.append("site.css: 缺少 %s 静态兜底" % var)
            continue
        want = round(spring_settle(*swift[key]), 3)
        got = num(m.group(1))
        if got != want:
            problems.append("site.css: %s=%ss，弹簧解析解应为 %ss" % (var, got, want))
        else:
            checked.append("%-22s %ss（弹簧收敛）" % (var, want))


def audit_css():
    src = read(SITE_CSS)
    # 静态兜底区（:root 动效令牌块）与 reduced-motion 段允许字面量
    root = re.search(r"/\* ---------- 动效体系（App 源码 1:1） ----------.*?\n:root \{(.*?)\n\}",
                     src, re.S)
    root_span = root.span(1) if root else None
    reduced = src.find("@media (prefers-reduced-motion: reduce)")

    lit_duration = re.compile(r"(?<![\w-])(\d+(?:\.\d+)?)(ms|s)\b")
    lit_curve = re.compile(r"cubic-bezier\(|\b(?:ease|ease-in|ease-out|ease-in-out|linear)\b(?![-)])")

    for m in re.finditer(r"(?m)^\s*(?:transition|animation)\s*:[^;]*;", src, re.S):
        line_no = src[:m.start()].count("\n") + 1
        seg = m.group(0)
        if root_span and root_span[0] <= m.start() <= root_span[1]:
            continue
        if reduced != -1 and m.start() > reduced:
            continue
        # 先把 var(--...) 占位，避免把变量名里的 ease / linear 误判成字面曲线
        clean = re.sub(r"var\([^)]*\)", "VAR", seg)
        for d in lit_duration.finditer(clean):
            problems.append("site.css:%d 写死时长 %s → 改用 var(--m-*)" % (line_no, d.group(0)))
        for c in lit_curve.finditer(clean):
            problems.append("site.css:%d 写死曲线 %s → 改用 var(--m-*)" % (line_no, c.group(0)))

    # CSS linear() 只应由 motion.js 生成，不允许手写
    if re.search(r":\s*linear\(", src):
        problems.append("site.css: 出现手写 linear() 采样，应完全交给 motion.js")

    m = re.search(r"--m-toast-scale:\s*([\d.]+);", src)
    if not m or num(m.group(1)) != 0.5:
        problems.append("site.css: --m-toast-scale 应为 Toast.swift 的 0.5")

    # caBackOut 只允许监测独立窗入场（pop-in）一处
    uses = [i + 1 for i, l in enumerate(src.splitlines())
            if "--m-ca-back-out" in l and not l.strip().startswith("--")]
    if len(uses) > 1:
        problems.append("site.css: caBackOut 出现在 %s，应只用于监测独立窗入场" % uses)

    # 连续循环必须线性
    for m in re.finditer(r"animation:[^;]*infinite[^;]*;", src):
        if "--m-linear" not in m.group(0):
            problems.append("site.css:%d 循环动画未用线性曲线" %
                            (src[:m.start()].count("\n") + 1))


def audit_js():
    src = read(SITE_JS)
    # 允许业务延时（网络超时、GIF 等），但动画相关延时必须走 Motion.tokens
    for m in re.finditer(r"setTimeout\([^\n]*?,\s*(\d+)\)", src):
        line_no = src[:m.start()].count("\n") + 1
        line = src.splitlines()[line_no - 1]
        if any(word in line for word in ("toast", "panel", "preview", "animation")):
            problems.append("site.js:%d 动画延时写死 %sms → 用 Motion.tokens" %
                            (line_no, m.group(1)))
    if "window.KitnestMotion" not in src:
        problems.append("site.js: 未接入 KitnestMotion")
    if "assets/motion.js" not in read(ROOT / "FRONT/index.html"):
        problems.append("index.html: 未引入 assets/motion.js")


def main():
    swift, js = parse_swift(), parse_js()
    compare_constants(swift, js)
    audit_spring_fallback(swift)
    audit_css()
    audit_js()

    print("App 源码 ↔ 官网动效逐项比对（%d 项）：" % len(checked))
    if "--list" in sys.argv:
        for line in checked:
            print("  " + line)
    default = swift["open.default"]
    print("  开合默认档位：%s = %ss" % (default, swift.get("open." + default)))
    if problems:
        print("\n❌ %d 处不一致：" % len(problems))
        for p in problems:
            print("  " + p)
        return 1
    print("\n✅ 通过：时长 / 弹簧参数 / CA 控制点 / 开合档位与 App 源码一致，\n"
          "   CSS 与 JS 无自编动画字面量，循环动画为线性。")
    return 0


if __name__ == "__main__":
    sys.exit(main())
