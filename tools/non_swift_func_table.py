#!/usr/bin/env python3
"""非 Swift 运行/构建代码的函数索引（2026-11-24 新增）。

为什么需要
----------
`FrsetNext-函数清单.csv` 由 `func_table.py` 生成，**只覆盖 .swift**。
但 Kitnest 实际参与运行/构建的还有：

  · `Sources/FrsetStatsBar/*.m`  —— 性能监测引擎（STATS 采集、菜单栏部件、录制）
  · `Sources/FrsetStatsBar/*.c`  —— runcat 帧、传感器名表
  · `tools/*.py`                 —— 构建/索引/对账工具（func_table、reconcile…）
  · `apps/FrsetNext/*.sh`        —— 构建与部署脚本

把纯 Swift 清单叫「整个项目的全部函数」是错的。本脚本给这些语言一份**独立**索引，
列里显式写 language 与源码位置；不与 Swift 表混在一起，也不参与 reconcile 的
Swift 台账对账。

口径与限制
----------
* 这是**声明级索引**，不是逐函数审查台账：line/lines 用于定位，不保证 ObjC 宏
  （如 `#define` 生成的访问器）与 C 静态内联全部识别；
* 正则只认「文件顶格 / 类型作用域内的函数/方法定义」，不追函数指针与 block；
* 生成物，可随时重跑；手工审查结论写 `函数审查记录-非Swift.csv`（同键合并）。

用法
----
    python3 tools/non_swift_func_table.py            # 写回默认 CSV
    python3 tools/non_swift_func_table.py --check    # 只统计
"""
from __future__ import annotations

import argparse
import csv
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, "apps", "FrsetNext", "Sources")
OUT = os.path.join(ROOT, "docs", "00-总览", "数据表", "FrsetNext-函数清单-非Swift.csv")

OBJC_TYPE = re.compile(r"^\s*@(?:interface|implementation)\s+([A-Za-z_]\w*)")
OBJC_METHOD = re.compile(r"^\s*([-+])\s*\(([^)]*)\)\s*([A-Za-z_][\w:]*)")
C_FUNC = re.compile(
    r"^[A-Za-z_][\w \t\*]*?\b([A-Za-z_]\w*)\s*\([^;{}]*\)\s*\{?\s*$")
PY_DEF = re.compile(r"^(\s*)def\s+([A-Za-z_]\w*)\s*\(")
PY_CLASS = re.compile(r"^(\s*)class\s+([A-Za-z_]\w*)")


def scan_objc(lines: list[str]) -> list[dict]:
    owner = "-"
    rows = []
    depth = 0
    i = 0
    while i < len(lines):
        line = lines[i]
        m = OBJC_TYPE.match(line)
        if m:
            owner = m.group(1)
        m = OBJC_METHOD.match(line)
        if m and depth == 0:
            start = i
            body = 0
            j = i
            while j < len(lines):
                body += lines[j].count("{") - lines[j].count("}")
                if "{" in lines[j] and body <= 0:
                    break
                if body > 0 and body <= 0:
                    break
                j += 1
            rows.append({"owner": owner, "name": m.group(3).rstrip(":"),
                         "kind": "method", "line": start + 1,
                         "lines": max(1, j - start + 1)})
            i = j + 1
            continue
        depth += line.count("{") - line.count("}")
        depth = max(0, depth)
        i += 1
    return rows


def scan_c(lines: list[str]) -> list[dict]:
    rows = []
    for i, line in enumerate(lines):
        if not line or line[0].isspace():
            continue
        if line.lstrip().startswith(("//", "/*", "*", "#")):
            continue
        m = C_FUNC.match(line)
        if not m:
            continue
        name = m.group(1)
        if name in ("if", "for", "while", "switch", "return", "sizeof"):
            continue
        if ";" in line:
            continue
        rows.append({"owner": "-", "name": name, "kind": "func",
                     "line": i + 1, "lines": 1})
    return rows


def scan_py(lines: list[str]) -> list[dict]:
    stack: list[tuple[int, str]] = []
    rows = []
    for i, line in enumerate(lines):
        mc = PY_CLASS.match(line)
        if mc:
            indent = len(mc.group(1))
            while stack and stack[-1][0] >= indent:
                stack.pop()
            stack.append((indent, mc.group(2)))
            continue
        md = PY_DEF.match(line)
        if md:
            indent = len(md.group(1))
            while stack and stack[-1][0] >= indent:
                stack.pop()
            owner = stack[-1][1] if stack else "-"
            rows.append({"owner": owner, "name": md.group(2), "kind": "func",
                         "line": i + 1, "lines": 1})
    return rows


def scan(path: str, rel: str, language: str) -> list[dict]:
    with open(path, encoding="utf-8", errors="replace") as fh:
        lines = fh.read().splitlines()
    if language == "objc":
        # .m 里既有 ObjC 方法也有大量 C 函数（本工程 STATS 引擎就是 C 风格），
        # 两种都要索引，否则会把真实实现漏掉。
        out = scan_objc(lines) + scan_c(lines)
    elif language == "c":
        out = scan_c(lines)
    else:
        out = scan_py(lines)
    for r in out:
        r["language"] = language
        r["file"] = rel
    return out


def collect() -> tuple[list[dict], int]:
    rows = []
    files = 0
    for base, _dirs, names in os.walk(SRC):
        for name in sorted(names):
            if name.startswith("._"):
                continue
            ext = os.path.splitext(name)[1]
            language = {".m": "objc", ".mm": "objc", ".c": "c", ".h": None}.get(ext)
            if not language:
                continue
            full = os.path.join(base, name)
            rel = os.path.relpath(full, ROOT)
            files += 1
            rows.extend(scan(full, rel, language))
    tools_dir = os.path.join(ROOT, "tools")
    if os.path.isdir(tools_dir):
        for name in sorted(os.listdir(tools_dir)):
            if not name.endswith(".py"):
                continue
            full = os.path.join(tools_dir, name)
            files += 1
            rows.extend(scan(full, os.path.relpath(full, ROOT), "python"))
    rows.sort(key=lambda r: (r["language"], r["file"], r["line"]))
    return rows, files


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true")
    args = ap.parse_args()
    rows, files = collect()
    from collections import Counter
    by_lang = Counter(r["language"] for r in rows)
    print(f"文件 {files}；声明 {len(rows)}；" + " · ".join(f"{k} {v}" for k, v in by_lang.items()))
    if args.check:
        return 0
    with open(OUT, "w", newline="", encoding="utf-8-sig") as fh:
        w = csv.DictWriter(fh, fieldnames=["language", "file", "owner", "kind",
                                           "name", "line", "lines"])
        w.writeheader()
        w.writerows(rows)
    print("已写入", os.path.relpath(OUT, ROOT))
    return 0


if __name__ == "__main__":
    sys.exit(main())
