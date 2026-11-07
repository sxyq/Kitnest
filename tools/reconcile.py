#!/usr/bin/env python3
"""三方对账：函数清单 CSV ↔ 审阅台账 ↔ 索引/依赖图文档数字。

为什么有这个脚本
----------------
2026-11-07 逐条核对发现同一份源码在不同产物里有三套数字，根因是三四个各自独立的
解析器 + 一份手工维护的台账：
  · 函数清单 8,764 条（含 470 条 getter 局部 let 误记为成员，且漏了 ClipboardRepository 16 条）；
  · 符号索引写 8,679 条（旧口径，已过期）；
  · 模块依赖图写 8,679 条（另一套解析器）。
解析器已在 v259 合并为 `tools/func_table.py` 唯一口径；本脚本负责**守住**这条线——
任何一次改码后漏跑、手改表、或台账没跟上，都会在这里报红。

检查项
------
  1) CSV 与源码逐条一致（直接调 func_table.scan_file，不落盘）；
  2) 台账覆盖全部函数类声明，且 (file, owner, kind, name, line) 全部命中；
  3) `docs/00-总览/符号索引.md` 头部数字与实际一致；
  4) `docs/00-总览/模块依赖图.md` 头部数字与实际一致。

用法
----
    python3 tools/reconcile.py        # 0 = 全绿；1 = 有差异（打印明细）
"""
from __future__ import annotations

import csv
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import func_table  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CSV = os.path.join(ROOT, "docs", "40-审计与核对", "数据表", "FrsetNext-函数清单.csv")
LEDGER = os.path.join(ROOT, "docs", "40-审计与核对", "数据表", "函数审阅台账.csv")
SYMBOL_MD = os.path.join(ROOT, "docs", "00-总览", "符号索引.md")
DEP_MD = os.path.join(ROOT, "docs", "00-总览", "模块依赖图.md")
FUNC_KINDS = ("func", "init", "deinit", "subscript")


def scan_source():
    rows = []
    files = 0
    for base, _dirs, names in os.walk(func_table.SRC):
        for name in sorted(names):
            if not name.endswith(".swift"):
                continue
            full = os.path.join(base, name)
            rel = os.path.relpath(full, func_table.SRC)
            files += 1
            rows.extend(func_table.scan_file(full, rel))
    return rows, files


def key(r):
    return (r["file"], r["owner"], r["kind"], r["name"], int(r["line"]))


def name_key(k):
    """去掉行号的键：用来区分「行号漂移」与「函数真的不在」。"""
    return k[:4]


def main() -> int:
    problems = []

    fresh, files = scan_source()
    csv_rows = list(csv.DictReader(open(CSV, encoding="utf-8-sig")))

    # 1) CSV ↔ 源码
    #
    # v261：原来用 zip 逐行比，中间插一条就整体错位，报「8126 行不一致」——
    # 真实差异只有几十条，报告的人得自己再排一遍。改成按主键集合比：
    # 先看谁多谁少，再看共有项的字段差异，各报各的。
    csv_map = {key(r): r for r in csv_rows}
    src_map = {key(r): r for r in fresh}
    only_csv = sorted(set(csv_map) - set(src_map))
    only_src = sorted(set(src_map) - set(csv_map))
    if len(csv_rows) != len(fresh):
        problems.append(f"CSV 条数 {len(csv_rows)} ≠ 源码 {len(fresh)}（改了码没重跑 func_table.py？）")
    if only_csv:
        problems.append(f"CSV 有 {len(only_csv)} 条源码已不存在（真删或改名），"
                        f"例：{only_csv[:3]}")
    if only_src:
        problems.append(f"CSV 缺 {len(only_src)} 条源码声明（新函数/漏扫），"
                        f"例：{only_src[:3]}")
    field_diff = []
    for k in set(csv_map) & set(src_map):
        for f in ("module", "lines", "complexity"):
            if str(csv_map[k].get(f)) != str(src_map[k].get(f)):
                field_diff.append((k, f, csv_map[k].get(f), src_map[k].get(f)))
                break
    if field_diff:
        k, f, a, b = field_diff[0]
        problems.append(f"CSV 有 {len(field_diff)} 条字段不一致，例：{k[0]}:{k[4]} "
                        f"字段 {f} 表={a} 源码={b}")

    # 2) 台账覆盖率与行号
    led = list(csv.DictReader(open(LEDGER, encoding="utf-8-sig")))
    have = {key(r) for r in led}
    need = {key(r) for r in fresh if r["kind"] in FUNC_KINDS}
    missing = need - have
    extra = have - {key(r) for r in fresh}
    if missing or extra:
        have_n = {name_key(k) for k in have}
        need_n = {name_key(k) for k in need}
        real_missing = need_n - have_n
        real_extra = have_n - need_n
        if real_missing or real_extra:
            problems.append(f"台账真缺 {len(real_missing)} 个函数 / 多 {len(real_extra)} 个"
                            f"（不只是行号漂移），例：{sorted(real_missing)[:3]}")
        elif missing or extra:
            problems.append(f"台账行号漂移 {len(missing)} 条（函数都在，坐标过期）"
                            f"→ 跑 tools/rebuild_ledger.py")

    # 3) 符号索引头部
    decls = len(fresh)
    funcs = sum(1 for r in fresh if r["kind"] in FUNC_KINDS)
    lines_total = 0
    for base, _dirs, names in os.walk(func_table.SRC):
        for name in names:
            if name.endswith(".swift"):
                with open(os.path.join(base, name), encoding="utf-8", errors="replace") as fh:
                    lines_total += len(fh.read().splitlines())
    if os.path.isfile(SYMBOL_MD):
        head = open(SYMBOL_MD, encoding="utf-8").read(1200)
        m = re.search(r"覆盖 (\d+) 个 Swift 文件、([\d,]+) 行、([\d,]+) 个声明（函数 ([\d,]+) 个", head)
        if not m:
            problems.append("符号索引.md 头部格式无法解析（被手工改过？）")
        else:
            got = (int(m.group(1)), int(m.group(2).replace(",", "")),
                   int(m.group(3).replace(",", "")), int(m.group(4).replace(",", "")))
            want = (files, lines_total, decls, funcs)
            if got != want:
                problems.append(f"符号索引.md 数字过期：写的是 {got}，实际是 {want}"
                                f"（文件,行,声明,函数）")

    # 4) 模块依赖图头部
    if os.path.isfile(DEP_MD):
        head = open(DEP_MD, encoding="utf-8").read(1200)
        m = re.search(r"共 (\d+) 个模块 / (\d+) 文件 / ([\d,]+) 行 / ([\d,]+) 个声明", head)
        if not m:
            problems.append("模块依赖图.md 头部格式无法解析（被手工改过？）")
        else:
            got = (int(m.group(2)), int(m.group(3).replace(",", "")), int(m.group(4).replace(",", "")))
            want = (files, lines_total, decls)
            if got != want:
                problems.append(f"模块依赖图.md 数字过期：写的是 {got}，实际是 {want}（文件,行,声明）")

    if problems:
        print("✗ 对账不通过：")
        for p in problems:
            print("  -", p)
        print("\n修法（按顺序）：")
        print("  1) python3 tools/func_table.py")
        print("  2) python3 tools/rebuild_ledger.py --strict    # 行号重锚 + 补新函数证据")
        print("  3) python3 tools/symbol_index_md.py apps/FrsetNext/Sources "
              "docs/40-审计与核对/数据表/FrsetNext-函数清单.csv docs/00-总览/符号索引.md")
        print("  4) python3 tools/swift_catalog.py")
        return 1

    print(f"✓ 全绿：{files} 文件 / {decls:,} 声明（函数 {funcs:,}）/ 台账 {len(led):,} 条，"
          f"行号与索引数字全部一致")
    return 0


if __name__ == "__main__":
    sys.exit(main())
