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
    # v241：`\b` 必须加——否则 "function" 会被 `func` 命中、把 "tion" 当成函数名
    #（CodeTheme.swift 的 "function" 键曾凭空生成 14 条假函数行）
    r"(func|init|deinit|subscript)\b\s*!?\s*([A-Za-z_][A-Za-z0-9_]*)?"
)
PROP_RE = re.compile(
    r"^\s*(?:@\w+(?:\([^)]*\))?\s+)*"
    r"(?:(?:public|private|internal|fileprivate|open|static|class|final|lazy|weak|"
    r"unowned|override|readonly)\s+)*"
    r"(let|var)\s+([A-Za-z_][A-Za-z0-9_]*)"
)

BRANCH_WORDS = ("if ", "guard ", "for ", "while ", "repeat ", "case ", "catch ", "&&", "||", " ? ")


def strip_line(line: str, state: dict) -> tuple[str, dict]:
    """去掉注释与字符串字面量，返回 (可计大括号的代码, 跨行状态)。

    v259（2026-11-07）：旧版是**逐行无状态**正则，两个硬伤都出在这里——
      1) 三引号多行字符串不识别，里面的内容被当代码计括号。实测
         `ClipboardRepository.columns` 的 SQL 里有一行 `OR content LIKE '%{%'`，
         那个 `{` 让 `appendClauses` 的括号深度永久 +1，体扫描一路吞到文件尾
         （记成 319 行，实际 59 行），把后面 fetch/count/insert/delete 等
         16 条声明整体漏掉。
      2) 块注释 `/* … */` 不识别，注释里的括号同样污染深度。
    现在按字符扫描并携带状态：块注释、多行字符串跨行续用，单行字符串整体折叠。
    """
    out = []
    i, n = 0, len(line)
    while i < n:
        if state["block"]:
            j = line.find("*/", i)
            if j < 0:
                return "".join(out), state
            state["block"] = False
            i = j + 2
            continue
        if state["str3"]:
            j = line.find('"""', i)
            if j < 0:
                return "".join(out), state
            state["str3"] = False
            i = j + 3
            continue
        ch = line[i]
        if ch == "/" and line.startswith("//", i):
            break
        if ch == "/" and line.startswith("/*", i):
            state["block"] = True
            i += 2
            continue
        if line.startswith('"""', i):
            state["str3"] = True
            i += 3
            continue
        if ch == '"':
            # 单行字符串（含 #"…"# 原始串）：整体折叠，内部括号不计
            i += 1
            while i < n:
                if line[i] == "\\":
                    i += 2
                    continue
                if line[i] == '"':
                    i += 1
                    break
                i += 1
            out.append('""')
            continue
        out.append(ch)
        i += 1
    return "".join(out), state


def strip_codes(lines: list[str]) -> list[str]:
    """把整份文件按 strip_line 预处理成「可计括号」的代码行。"""
    state = {"block": False, "str3": False}
    codes = []
    for raw in lines:
        code, state = strip_line(raw, state)
        codes.append(code)
    return codes


def module_of(rel: str) -> str:
    parts = rel.split(os.sep)
    if len(parts) >= 2 and parts[0] == "Features":
        return parts[1]
    return MODULE_DIRS.get(parts[0], parts[0])


def scan_file(path: str, rel: str):
    with open(path, encoding="utf-8", errors="replace") as fh:
        lines = fh.read().splitlines()

    codes = strip_codes(lines)   # v259：整份文件先做带状态剥离，跨行字符串/块注释不在括号上留残渣
    rows = []
    # 栈元素：(类型名, 进入时的深度)
    stack: list[tuple[str, int]] = []
    depth = 0
    i = 0
    n = len(lines)

    while i < n:
        code = codes[i]

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
                c = codes[j]
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
            body_lines = codes[start:j + 1]
            complexity = 1
            for bc in body_lines:
                complexity += sum(bc.count(w) for w in BRANCH_WORDS)
            rows.append({
                "module": module_of(rel), "file": rel, "owner": stack[-1][0] if stack else "-",
                "kind": "func" if kind == "func" else kind,
                "name": name, "line": start + 1, "lines": len(body_lines), "complexity": complexity,
            })
            # 跳过函数体，避免把体内嵌套闭包/局部声明记成成员
            if body_depth is not None and j > start:
                depth += sum(codes[k].count("{") - codes[k].count("}")
                             for k in range(start, j + 1))
                while stack and depth <= stack[-1][1]:
                    stack.pop()
                i = j + 1
                continue
            i += 1
            continue

        mprop = PROP_RE.match(code)
        if mprop and not code.rstrip().endswith("("):
            start = i
            rows.append({
                "module": module_of(rel), "file": rel, "owner": stack[-1][0] if stack else "-",
                "kind": mprop.group(1), "name": mprop.group(2),
                "line": i + 1, "lines": 0, "complexity": 1,
            })
            # v259：计算属性 / 观察器 / `= { … }()` 初始化闭包也要跳体。
            # 旧版只记属性、不跳体，于是 getter 里的 `let opacity` / 闭包里的
            # `let df` 全被当成类型成员记了一行（实测 478 条，占属性行 8.6%，
            # 例：Theme.opacity 实际是 windowSurface 的局部量）。
            opens, closes = code.count("{"), code.count("}")
            if opens > closes:
                body_depth = opens - closes
                j = i + 1
                while j < n:
                    body_depth += codes[j].count("{") - codes[j].count("}")
                    if body_depth <= 0:
                        break
                    j += 1
                depth += sum(codes[k].count("{") - codes[k].count("}")
                             for k in range(start, j + 1))
                while stack and depth <= stack[-1][1]:
                    stack.pop()
                i = j + 1
                continue

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
