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


def main() -> int:
    problems = []

    fresh, files = scan_source()
    fresh.sort(key=lambda r: (r["file"], int(r["line"])))
    csv_rows = list(csv.DictReader(open(CSV, encoding="utf-8-sig")))
    csv_rows.sort(key=lambda r: (r["file"], int(r["line"])))

    # 1) CSV ↔ 源码
    if len(fresh) != len(csv_rows):
        problems.append(f"CSV 条数 {len(csv_rows)} ≠ 源码 {len(fresh)}（改了码没重跑 func_table.py？）")
    diff = 0
    for a, b in zip(csv_rows, fresh):
        for f in ("module", "file", "owner", "kind", "name", "line", "lines", "complexity"):
            if str(a.get(f)) != str(b.get(f)):
                diff += 1
                if diff <= 5:
                    problems.append(f"CSV 行不一致 {a.get('file')}:{a.get('line')} 字段 {f}: "
                                    f"表={a.get(f)} 源码={b.get(f)}")
                break
    if diff:
        problems.append(f"CSV 与源码共有 {diff} 行不一致")

    # 2) 台账覆盖率与行号
    led = list(csv.DictReader(open(LEDGER, encoding="utf-8-sig")))
    have = {key(r) for r in led}
    need = {key(r) for r in fresh if r["kind"] in FUNC_KINDS}
    missing = need - have
    extra = have - {key(r) for r in fresh}
    if missing:
        problems.append(f"台账缺 {len(missing)} 个函数，例：{sorted(missing)[:3]}")
    if extra:
        problems.append(f"台账有 {len(extra)} 条在清单里不存在，例：{sorted(extra)[:3]}")

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
        print("\n修法：python3 tools/func_table.py && "
              "python3 tools/symbol_index_md.py apps/FrsetNext/Sources "
              "docs/40-审计与核对/数据表/FrsetNext-函数清单.csv docs/00-总览/符号索引.md && "
              "python3 tools/swift_catalog.py")
        return 1

    print(f"✓ 全绿：{files} 文件 / {decls:,} 声明（函数 {funcs:,}）/ 台账 {len(led):,} 条，"
          f"行号与索引数字全部一致")
    return 0


if __name__ == "__main__":
    sys.exit(main())
