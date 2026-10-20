#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""生成「个性化接入 · 函数级核对表」。

上游：docs/perfaudit/函数清单-AST抽取.csv（reindex.py 产出，需先更新）
本脚本：按文件扫描个性化/主题消费标记，与函数清单按 (file, 函数所在行区间) 关联，
输出每个 UI 函数的接入状态，做到「函数表格全量」可核对。

标记口径：
  chrome    frsetThemeChrome()（强调色 + Midnight 统一入口，根视图挂载）
  accent    Theme.accent / Theme.accentNS（个性化强调色）
  midnight  frsetAppearanceTheme / midnightXxxOverride / MidnightTheme
  personal  Personalization.shared（材质/圆角/密度/背景图等）
  glass     panelGlassCard / panelGlassFloating / LiquidGlassBackground / LiquidGlass.makeView

用法：python3 tools/perfaudit/theme_coverage.py
"""
import csv
import os
import re
from collections import defaultdict

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
SRC = os.path.join(ROOT, "apps", "FrsetNext", "Sources")
AUDIT = os.path.join(ROOT, "docs", "perfaudit")
LIST = os.path.join(AUDIT, "函数清单-AST抽取.csv")
OUT = os.path.join(AUDIT, "个性化接入-函数级核对.csv")

MARKERS = {
    "chrome": re.compile(r"frsetThemeChrome\s*\("),
    "accent": re.compile(r"Theme\.accent(?:NS)?\b"),
    "midnight": re.compile(r"frsetAppearanceTheme|midnight\w*Override|MidnightTheme"),
    "personal": re.compile(r"Personalization\.shared"),
    "glass": re.compile(r"panelGlassCard|panelGlassFloating|LiquidGlassBackground|LiquidGlass\.makeView"),
}


def scan_file(path):
    """返回 {marker: set(line_numbers)}"""
    hits = defaultdict(set)
    with open(path, "r", encoding="utf-8", errors="replace") as fh:
        for idx, line in enumerate(fh, 1):
            if line.lstrip().startswith("//"):
                continue
            for name, rx in MARKERS.items():
                if rx.search(line):
                    hits[name].add(idx)
    return hits


def main():
    rows = []
    with open(LIST, "r", encoding="utf-8-sig", newline="") as fh:
        for row in csv.DictReader(fh):
            rows.append(row)

    by_file = defaultdict(list)
    for row in rows:
        if row.get("lang") == "swift":
            by_file[row["file"]].append(row)

    out_rows = []
    for file_rel in sorted(by_file):
        abs_path = os.path.join(SRC, file_rel)
        if not os.path.exists(abs_path):
            continue
        hits = scan_file(abs_path)
        file_markers = sorted(k for k, v in hits.items() if v)
        for row in by_file[file_rel]:
            try:
                start = int(row["start"])
                end = int(row["end"])
            except (ValueError, KeyError):
                continue
            inside = [m for m in file_markers
                      if any(start <= ln <= end for ln in hits[m])]
            out_rows.append({
                "file": file_rel,
                "scope": row.get("scope", ""),
                "name": row.get("name", ""),
                "start": start,
                "end": end,
                "函数内标记": "|".join(inside) or "",
                "文件级标记": "|".join(file_markers) or "",
                "判定": "函数内已接" if inside else ("文件已接" if file_markers else "未接"),
            })

    os.makedirs(AUDIT, exist_ok=True)
    with open(OUT, "w", encoding="utf-8-sig", newline="") as fh:
        writer = csv.DictWriter(fh, fieldnames=[
            "file", "scope", "name", "start", "end",
            "函数内标记", "文件级标记", "判定",
        ])
        writer.writeheader()
        writer.writerows(out_rows)

    stats = defaultdict(int)
    for row in out_rows:
        stats[row["判定"]] += 1
    print(f"函数级核对表: {OUT}")
    print(f"  swift 函数总数: {len(out_rows)}")
    for key in ("函数内已接", "文件已接", "未接"):
        print(f"  {key}: {stats[key]}")


if __name__ == "__main__":
    main()
