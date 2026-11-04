#!/usr/bin/env python3
"""生成/刷新「函数清单」CSV（v210 重写）。

为什么重写
----------
旧表两个硬伤（2026-11-04 逐条核对，6940 行）：
  1) owner 列 739 条（26.2%）归属错误——生成器用扁平正则扫类型声明、不跟花括号深度，
     一个文件里出现嵌套 struct 之后，后面所有类级函数都被挂到那个内层 struct 上
     （例：MonitorSampler.start 记成 Buffers.start；AppBootstrap 的热键函数记成
     DefaultHotkeyEntry.*）。
  2) 行号不跟源码走：改过代码不重跑，就有 133 条对不上（集中在最近改过的 6 个文件）。

本脚本的做法
------------
* 逐行扫描，维护「花括号深度 + 类型栈」——类型的归属 = 当前仍处在其作用域内的最内层类型；
* 函数/初始化器按签名定位起点，再扫到配对右括号算行数与复杂度；
* 属性（let/var）同样记 owner，但 `kind` 区分开，便于只看函数时过滤。

列的语义
--------
module      Features/<X> → X；Core/App/Storage/Models/... 按目录名
file        相对 apps/FrsetNext/Sources
owner       真实所属类型（顶层声明为 "-"）
kind        func / init / deinit / var / let / class / struct / enum / protocol / extension
name        声明名
line        声明起始行（1-based）
lines       函数体行数（含签名与结尾大括号；属性为 0）
complexity  1 + if/guard/for/while/repeat/case/catch/&&/||/? 的粗计（同旧表口径的近似值）

用法
----
    python3 tools/func_table.py            # 写回默认 CSV
    python3 tools/func_table.py --check    # 只统计，不写文件（CI/提交前自检）
"""
from __future__ import annotations

import argparse
import csv
import os
import re
import sys
from collections import Counter

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, "apps", "FrsetNext", "Sources")
OUT = os.path.join(ROOT, "docs", "40-审计与核对", "数据表", "FrsetNext-函数清单.csv")

MODULE_DIRS = {
    "Core": "Core", "App": "App", "Storage": "Storage", "Models": "Models",
    "MemoryHelper": "MemoryHelper", "OCRHelper": "OCRHelper",
}

TYPE_RE = re.compile(
    r"^\s*(?:@\w+(?:\([^)]*\))?\s+)*"
    r"(?:(?:public|private|internal|fileprivate|open|final|indirect|static)\s+)*"
    r"(class|struct|enum|extension|protocol|actor)\s+([A-Za-z_][A-Za-z0-9_]*)"
)
FUNC_RE = re.compile(
    r"^\s*(?:@\w+(?:\([^)]*\))?\s+)*"
    r"(?:(?:public|private|internal|fileprivate|open|static|class|final|mutating|"
    r"nonmutating|override|required|convenience|@discardableResult)\s+)*"
    r"(func|init|deinit|subscript)\s*!?\s*([A-Za-z_][A-Za-z0-9_]*)?"
)
PROP_RE = re.compile(
    r"^\s*(?:@\w+(?:\([^)]*\))?\s+)*"
    r"(?:(?:public|private|internal|fileprivate|open|static|class|final|lazy|weak|"
    r"unowned|override|readonly)\s+)*"
    r"(let|var)\s+([A-Za-z_][A-Za-z0-9_]*)"
)

BRANCH_WORDS = ("if ", "guard ", "for ", "while ", "repeat ", "case ", "catch ", "&&", "||", " ? ")


def strip_code(line: str) -> str:
    """去掉字符串与行注释，只保留参与括号/关键字统计的代码部分。"""
    line = re.sub(r'"(\\.|[^"\\])*"', '""', line)
    line = re.sub(r"//.*$", "", line)
    return line


def module_of(rel: str) -> str:
    parts = rel.split(os.sep)
    if len(parts) >= 2 and parts[0] == "Features":
        return parts[1]
    return MODULE_DIRS.get(parts[0], parts[0])


def scan_file(path: str, rel: str):
    with open(path, encoding="utf-8", errors="replace") as fh:
        lines = fh.read().splitlines()

    rows = []
    # 栈元素：(类型名, 进入时的深度)
    stack: list[tuple[str, int]] = []
    depth = 0
    i = 0
    n = len(lines)

    while i < n:
        raw = lines[i]
        code = strip_code(raw)

        mtype = TYPE_RE.match(code)
        if mtype:
            name = mtype.group(2)
            # 类型声明只用于「归属栈」，不进表（表口径 = 函数 + 属性，与旧表一致）
            stack.append((name, depth))
            depth += code.count("{") - code.count("}")
            while stack and depth <= stack[-1][1]:
                stack.pop()
            i += 1
            continue

        mfun = FUNC_RE.match(code)
        if mfun:
            kind = mfun.group(1)
            name = mfun.group(2) or ("init" if kind == "init" else kind)
            start = i
            # 签名可能跨行：一路扫到出现 '{'（或声明以 '}' 结尾的协议要求）
            j = i
            body_depth = None
            while j < n:
                c = strip_code(lines[j])
                opens, closes = c.count("{"), c.count("}")
                if body_depth is None:
                    if opens > 0:
                        body_depth = 0
                        body_depth += opens - closes
                        if body_depth <= 0:
                            break
                    elif c.rstrip().endswith("}"):
                        break
                else:
                    body_depth += opens - closes
                    if body_depth <= 0:
                        break
                j += 1
            body_lines = lines[start:j + 1]
            complexity = 1
            for bl in body_lines:
                bc = strip_code(bl)
                complexity += sum(bc.count(w) for w in BRANCH_WORDS)
            rows.append({
                "module": module_of(rel), "file": rel, "owner": stack[-1][0] if stack else "-",
                "kind": "func" if kind == "func" else kind,
                "name": name, "line": start + 1, "lines": len(body_lines), "complexity": complexity,
            })
            # 跳过函数体，避免把体内嵌套闭包/局部声明记成成员
            if body_depth is not None and j > start:
                depth += sum(strip_code(lines[k]).count("{") - strip_code(lines[k]).count("}")
                             for k in range(start, j + 1))
                while stack and depth <= stack[-1][1]:
                    stack.pop()
                i = j + 1
                continue
            i += 1
            continue

        mprop = PROP_RE.match(code)
        if mprop and not code.rstrip().endswith("("):
            rows.append({
                "module": module_of(rel), "file": rel, "owner": stack[-1][0] if stack else "-",
                "kind": mprop.group(1), "name": mprop.group(2),
                "line": i + 1, "lines": 0, "complexity": 1,
            })

        depth += code.count("{") - code.count("}")
        while stack and depth <= stack[-1][1]:
            stack.pop()
        i += 1

    return rows


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true", help="只统计不写文件")
    ap.add_argument("--out", default=OUT)
    args = ap.parse_args()

    all_rows = []
    files = 0
    for base, _dirs, names in os.walk(SRC):
        for name in sorted(names):
            if not name.endswith(".swift"):
                continue
            path = os.path.join(base, name)
            rel = os.path.relpath(path, SRC)
            files += 1
            all_rows.extend(scan_file(path, rel))

    all_rows.sort(key=lambda r: (r["file"], r["line"]))
    funcs = [r for r in all_rows if r["kind"] in ("func", "init", "deinit", "subscript")]
    kinds = Counter(r["kind"] for r in all_rows)
    modules = Counter(r["module"] for r in all_rows if r["kind"] != "var" and r["kind"] != "let")

    print(f"文件 {files}；声明 {len(all_rows)}；函数 {len(funcs)}")
    print("kind:", dict(kinds))
    print("模块:", modules.most_common())

    if args.check:
        return 0

    os.makedirs(os.path.dirname(args.out), exist_ok=True)
    with open(args.out, "w", newline="", encoding="utf-8-sig") as fh:
        writer = csv.DictWriter(fh, fieldnames=["module", "file", "owner", "kind",
                                                "name", "line", "lines", "complexity"])
        writer.writeheader()
        writer.writerows(all_rows)
    print("已写入", os.path.relpath(args.out, ROOT))
    return 0


if __name__ == "__main__":
    sys.exit(main())
