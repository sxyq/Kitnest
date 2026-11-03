#!/usr/bin/env python3
"""动效曲线统一守卫（v155）。

规则（见 Core/UI/Support.swift 的 Theme.Motion 注释）：
  · 连续循环（旋转/扫描/进度）→ 线性
  · 单次交互动画 → ease-out 三档
  · 收放类 → 弹簧四档
  · 曲线只允许写在 Theme.Motion 里；其它文件出现字面量即违规

用法：
  python3 tools/motion_audit.py            # 检查并打印用量表
  python3 tools/motion_audit.py --list     # 附带逐条调用点
退出码：0 通过，1 有违规。
"""
import os
import re
import sys

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "apps", "FrsetNext", "Sources")

# 允许出现字面量曲线的文件（令牌定义 / 用户可选的打开速度三档）
ALLOW = {
    os.path.join("Core", "Support.swift"),
    os.path.join("Core", "Personalization.swift"),
}

LITERAL = re.compile(
    r"\.spring\(response:|\.easeOut\(duration:|\.easeInOut\(duration:|"
    r"\.easeIn\(duration:|\.linear\(duration:|CAMediaTimingFunction\("
)
TOKEN = re.compile(r"Theme\.Motion\.([A-Za-z]+)")


def main() -> int:
    violations = []
    usage = {}
    loop_sites = []

    for dirpath, _dirs, files in os.walk(ROOT):
        for name in files:
            if not name.endswith(".swift"):
                continue
            full = os.path.join(dirpath, name)
            rel = os.path.relpath(full, ROOT)
            with open(full, encoding="utf-8", errors="ignore") as fh:
                for lineno, line in enumerate(fh, 1):
                    for m in TOKEN.finditer(line):
                        usage.setdefault(m.group(1), []).append(f"{rel}:{lineno}")
                    if LITERAL.search(line) and rel not in ALLOW:
                        violations.append(f"{rel}:{lineno}: {line.strip()}")
                    # 循环动画（repeatForever）必须来自 loop/progress
                    if "repeatForever" in line and "Theme.Motion" not in line:
                        loop_sites.append(f"{rel}:{lineno}: {line.strip()}")

    print("动效令牌用量：")
    for key in sorted(usage, key=lambda k: -len(usage[k])):
        print(f"  {key:<14} {len(usage[key]):>3} 处")
    print(f"\n合计 Theme.Motion 调用：{sum(len(v) for v in usage.values())} 处")

    if loop_sites:
        print("\n⚠️ 循环动画未取自令牌：")
        for s in loop_sites:
            print("  " + s)

    if violations:
        print("\n❌ 字面量曲线（必须改成 Theme.Motion.*）：")
        for v in violations:
            print("  " + v)
        return 1

    print("\n✅ 通过：除 Theme.Motion 与 Personalization 的三档打开速度外，没有字面量曲线。")
    if "--list" in sys.argv:
        for key in sorted(usage):
            print(f"\n[{key}]")
            for site in usage[key]:
                print("  " + site)
    return 0


if __name__ == "__main__":
    sys.exit(main())
