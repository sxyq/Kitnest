#!/usr/bin/env python3
"""圆角曲线守卫（v156）——全 App 只允许 G2（曲率连续）圆角。

背景：SwiftUI 的 `RoundedRectangle(cornerRadius:)` 默认 `style: .circular`，
CALayer 的 `cornerRadius` 默认 `cornerCurve = .circular`，`NSBezierPath(roundedRect:)`
也是圆弧——三者都是 G1（曲率在直边接缝处从 0 突变到 1/r）。同一个界面里混用
G1/G2，视觉上就是「有的角更方、有的更圆」。本脚本禁止新增 G1。

用法：
  python3 tools/corner_audit.py          # 检查
  python3 tools/corner_audit.py --list   # 附带全部 G2 站点
退出码：0 通过，1 有违规。
"""
import os
import re
import sys

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "apps", "FrsetNext", "Sources")

CIRCULAR_RR = re.compile(r"RoundedRectangle\(cornerRadius:")
LEGACY_PATH = re.compile(r"NSBezierPath\(roundedRect:")


def scan_rr(text):
    """找出没带 style: .continuous 的 RoundedRectangle(cornerRadius:)。"""
    bad = []
    i = 0
    while True:
        m = CIRCULAR_RR.search(text, i)
        if not m:
            break
        j = m.end()
        depth = 1
        while j < len(text) and depth:
            if text[j] == "(":
                depth += 1
            elif text[j] == ")":
                depth -= 1
            j += 1
        inner = text[m.end(): j - 1]
        if "style:" not in inner:
            bad.append(text[m.start(): j])
        i = j
    return bad


def main() -> int:
    violations = []
    counts = {"swiftui": 0, "layer": 0, "path": 0}

    for dirpath, _dirs, files in os.walk(ROOT):
        for name in files:
            if not name.endswith(".swift"):
                continue
            full = os.path.join(dirpath, name)
            rel = os.path.relpath(full, ROOT)
            text = open(full, encoding="utf-8", errors="ignore").read()
            lines = text.split("\n")

            for snippet in scan_rr(text):
                lineno = text[: text.find(snippet)].count("\n") + 1
                violations.append(f"{rel}:{lineno}: 缺 style: .continuous → {snippet[:60]}")
            counts["swiftui"] += sum(1 for line in lines if "RoundedRectangle(cornerRadius:" in line
                                     and "style: .continuous" in line)

            for idx, line in enumerate(lines):
                if LEGACY_PATH.search(line):
                    violations.append(f"{rel}:{idx+1}: NSBezierPath(roundedRect:) 是圆弧 → "
                                      f"用 NSBezierPath.continuousRoundedRect")
                if re.search(r"\.layer\??\.cornerRadius = ", line):
                    window = "\n".join(lines[idx: idx + 3])
                    if "cornerCurve" in window:
                        counts["layer"] += 1
                    else:
                        violations.append(f"{rel}:{idx+1}: layer.cornerRadius 缺 cornerCurve = .continuous")
                if "continuousRoundedRect" in line:
                    counts["path"] += 1

    print(f"G2 圆角站点：SwiftUI {counts['swiftui']} 处 / CALayer {counts['layer']} 处 / 手绘 {counts['path']} 处")
    print("注：NSVisualEffectView / NSGlassEffectView 的 cornerRadius 由系统绘制，无 cornerCurve API，不计入。")

    if violations:
        print(f"\n❌ 发现 {len(violations)} 处 G1 圆角：")
        for v in violations[:40]:
            print("  " + v)
        if len(violations) > 40:
            print(f"  … 另有 {len(violations) - 40} 处")
        return 1
    print("\n✅ 通过：没有 G1 圆角残留。")
    return 0


if __name__ == "__main__":
    sys.exit(main())
