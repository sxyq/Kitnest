#!/usr/bin/env python3
"""UI 一致性静态检查（v181）

把《UI-一致性审计与规范》里那三条「防复发」规则做成可执行的检查，
否则半年后又会散成一堆各写各的圆角和自拼玻璃。

规则（对应文档第五节的第 1~3 条）：
  R1 圆角字面量      `cornerRadius: 7` 这种硬编码值 → 应取 Theme.Radius.*
                     微元素（1 / 1.5 / 2 / 3）与文档登记的 HUD 例外不报。
  R2 自拼浮层背景    `.regularMaterial` / `NSVisualEffectView(` 散落在
                     LiquidGlass 之外 → 应统一走 .glassPlate() / .glassCard()。
  R3 文档窗没上统一外观  自己 new NSWindow 却既没 applyOfficialChrome()
                     也没 glassPlate()/adoptGlassSurface() → 会出现白条/裸灰底。

用法：
  python3 tools/ui_lint.py            # 检查（有新增违规 → 退出码 1）
  python3 tools/ui_lint.py --report   # 只打印，不改变退出码
  python3 tools/ui_lint.py --update-baseline   # 把当前状态写成基线（慎用）

基线文件 tools/ui-lint-baseline.txt 按「文件 + 规则 + 条数」记账：
条数不变即通过，多出来一条就失败——这样既不会因为挪了几行就误报，
也能在有人新写一处字面量圆角时立刻拦下。
"""

import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, "Sources")
BASELINE = os.path.join(ROOT, "tools", "ui-lint-baseline.txt")

# 微元素圆角（圆点、格子、发丝条）与文档登记的 HUD 例外
ALLOWED_CORNER_LITERALS = {"1", "1.5", "2", "3"}
# 这些文件是「玻璃基础设施」本身，允许直接出现 material / NSVisualEffectView
GLASS_INFRA = {"Core/UI/LiquidGlass.swift", "Core/UI/OfficialWindowChrome.swift"}

R_EDGE = re.compile(r"cornerRadius:\s*([0-9]+(?:\.[0-9]+)?)\s*[,)]")
R_MATERIAL = re.compile(r"\.regularMaterial\b")
R_VISUAL_EFFECT = re.compile(r"NSVisualEffectView\s*\(")
R_WINDOW_NEW = re.compile(r"NSWindow\s*\(\s*contentRect:|:\s*NSWindow\s*\{")
# 文档窗特征：带标题栏/关闭/缩放；无边框浮层、NSPanel、HUD 都不在此列
R_DOC_STYLE = re.compile(r"styleMask:[^\n]*\.(titled|closable|resizable|miniaturizable)")
# 通过条件：走统一入口，或**显式**给窗口上底色（自绘 chrome 也算「不会露白条」）
R_GLASS_CALL = re.compile(
    r"applyOfficialChrome\(\)|glassPlate\(|glassCard\(|adoptGlassSurface\(|backgroundColor\s*=\s*[^\n.]")
R_BORDERLESS = re.compile(r"styleMask:[^\n]*\.borderless|NSPanel\s*\(")
R_HUD_LIKE = re.compile(r"isFloatingPanel\s*=\s*true|\.nonactivatingPanel")


def rel(path):
    return os.path.relpath(path, SRC).replace(os.sep, "/")


def swift_files():
    for root, _, files in os.walk(SRC):
        for name in sorted(files):
            if name.endswith(".swift"):
                yield os.path.join(root, name)


def scan():
    """返回 {(relpath, rule): [行号...]}"""
    hits = {}
    for path in swift_files():
        name = rel(path)
        try:
            lines = open(path, encoding="utf-8").read().splitlines()
        except UnicodeDecodeError:
            continue

        # R1 圆角字面量
        for i, line in enumerate(lines, 1):
            for m in R_EDGE.finditer(line):
                if m.group(1) not in ALLOWED_CORNER_LITERALS:
                    hits.setdefault((name, "R1"), []).append(i)

        # R2 自拼浮层背景（跳过纯注释行：说明历史做法的那种不算违规）
        if name not in GLASS_INFRA:
            for i, line in enumerate(lines, 1):
                stripped = line.lstrip()
                if stripped.startswith("//") or stripped.startswith("*"):
                    continue
                if R_MATERIAL.search(line) or R_VISUAL_EFFECT.search(line):
                    hits.setdefault((name, "R2"), []).append(i)

        # R3 文档窗没上统一外观（按文件判：建了窗但全文件没调用统一入口）
        text = "\n".join(lines)
        if R_WINDOW_NEW.search(text) and R_DOC_STYLE.search(text) and not R_GLASS_CALL.search(text):
            hits.setdefault((name, "R3"), []).append(1)
    return hits


def load_baseline():
    base = {}
    if not os.path.exists(BASELINE):
        return base
    for line in open(BASELINE, encoding="utf-8"):
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        parts = line.split("\t")
        if len(parts) != 3:
            continue
        path, rule, count = parts
        base[(path, rule)] = int(count)
    return base


def write_baseline(hits):
    rows = []
    for (path, rule), line_list in sorted(hits.items()):
        rows.append(f"{path}\t{rule}\t{len(line_list)}")
    with open(BASELINE, "w", encoding="utf-8") as f:
        f.write("# UI 一致性检查基线（v181）\n")
        f.write("# 格式：相对 Sources 的路径 <TAB> 规则 <TAB> 允许条数\n")
        f.write("# 只允许「减少」，新增一条就会让 check.sh 失败；确属例外请写清理由再改这里。\n")
        f.write("\n".join(rows) + "\n")


def main():
    args = set(sys.argv[1:])
    hits = scan()
    if "--update-baseline" in args:
        write_baseline(hits)
        print(f"基线已更新：{os.path.relpath(BASELINE, ROOT)}（{len(hits)} 条记录）")
        return 0

    base = load_baseline()
    rule_names = {"R1": "圆角字面量", "R2": "自拼浮层背景", "R3": "文档窗缺统一外观"}

    new_issues = []
    for (path, rule), line_list in sorted(hits.items()):
        allowed = base.get((path, rule), 0)
        if len(line_list) > allowed:
            extra = line_list[allowed:]
            new_issues.append((path, rule, extra, len(line_list) - allowed))

    totals = {r: 0 for r in rule_names}
    for (_, rule), line_list in hits.items():
        totals[rule] = totals.get(rule, 0) + len(line_list)

    if new_issues:
        print("  UI 一致性检查：发现新增违规")
        for path, rule, extra, n in new_issues:
            where = "、".join(str(x) for x in extra[:4])
            print(f"    ✗ [{rule_names[rule]}] {path}:{where}（本次新增 {n} 处）")
        print("    → 规则见 docs/UI-一致性审计与规范.md 第五节；"
              "确属例外就写明理由后 `--update-baseline`")
        return 0 if "--report" in args else 1

    print(f"  UI 一致性检查：通过（圆角字面量 {totals['R1']} · 自拼浮层 {totals['R2']}"
          f" · 文档窗 {totals['R3']}，均未超基线）")
    return 0


if __name__ == "__main__":
    sys.exit(main())
