#!/usr/bin/env python3
"""重新生成 docs/FrsetNext-函数清单.csv。

用途（用户 2026-11-03 要求）：「每轮都要及时更新 codegraph 索引，以及本地那个函数 CSV 表格」。

口径与旧表一致：module,file,owner,kind,name,line,lines,complexity
  · module   —— Sources/ 下的一级目录名（Features/xxx 取 xxx，Core/Models 取自身）
  · owner    —— 最近的类型声明（struct/class/enum/extension/protocol 的名字）
  · kind     —— func / init / var / let / subscript
  · line     —— 声明所在行号（1 基）
  · lines    —— 函数体行数（无花括号的属性为 0）
  · complexity —— 1 + 函数体内 if/for/while/guard/case/&&/|| 的出现次数（粗估）

这是轻量正则扫描，不依赖 SwiftSyntax（本机只有 Command Line Tools）。
它不追求编译器级精度，只求**每次大改后这张表跟着动**，便于检索与审计。

用法：
    python3 tools/update_function_csv.py            # 写 docs/FrsetNext-函数清单.csv
    python3 tools/update_function_csv.py --check    # 只统计，不写文件
"""

import csv
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, "Sources")
OUT = os.path.join(ROOT, "docs", "FrsetNext-函数清单.csv")

# 类型声明（用于 owner 归属）
TYPE_RE = re.compile(
    r"^\s*(?:@\w+\s+)*(?:public\s+|internal\s+|private\s+|fileprivate\s+|final\s+|open\s+)*"
    r"(struct|class|enum|protocol|extension)\s+([A-Za-z_][\w]*)"
)
# 函数 / 初始化器 / 下标
FUNC_RE = re.compile(
    r"^(\s*)(?:@\w+(?:\([^)]*\))?\s+)*"
    r"(?:public\s+|internal\s+|private\s+|fileprivate\s+|open\s+|static\s+|class\s+|override\s+|mutating\s+|"
    r"nonmutating\s+|@discardableResult\s+|@objc\s+|@MainActor\s+)*"
    r"(func|init|subscript)\s+([A-Za-z_][\w]*)"
)
# 存储属性（只要带类型注解的 var/let，避免把局部变量也算进来）
PROP_RE = re.compile(
    r"^(\s*)(?:@\w+(?:\([^)]*\))?\s+)*"
    r"(?:public\s+|internal\s+|private\s+|fileprivate\s+|open\s+|static\s+|class\s+|"
    r"@Published\s+|@AppStorage\([^)]*\)\s+|@Stored\s+)*"
    r"(var|let)\s+([A-Za-z_][\w]*)\s*:\s*"
)

BRANCH_RE = re.compile(r"\b(if|for|while|guard|case|catch)\b|&&|\|\|")


def module_of(rel_path: str) -> str:
    parts = rel_path.split(os.sep)
    if len(parts) >= 2 and parts[0] == "Features":
        return parts[1]
    return parts[0].replace(".swift", "")


def brace_delta(line: str) -> int:
    """粗略数花括号（忽略字符串/注释里的括号会失真，但整体可用）"""
    stripped = line.split("//")[0]
    return stripped.count("{") - stripped.count("}")


def body_span(lines, start_index):
    """从声明行往下找配对的 }，返回 (结束行下标, 行数, 分支数)"""
    depth = 0
    opened = False
    branch = 0
    for i in range(start_index, min(len(lines), start_index + 4000)):
        line = lines[i]
        d = brace_delta(line)
        if "{" in line.split("//")[0]:
            opened = True
        depth += d
        branch += len(BRANCH_RE.findall(line))
        if opened and depth <= 0:
            return i, i - start_index + 1, max(1, branch)
        if not opened and i > start_index:
            return start_index, 0, 1   # 单行属性/协议要求
    return start_index, 0, 1


def scan_file(path: str, rel: str, rows: list):
    with open(path, encoding="utf-8", errors="ignore") as f:
        lines = f.read().split("\n")

    module = module_of(rel)
    owner = ""
    type_depth = 0
    pending_type = None

    for idx, line in enumerate(lines):
        if not line.strip() or line.lstrip().startswith("//"):
            # 注释行仍然可能带着 { }（比如注释里的示例代码），直接跳过以免破坏深度
            continue

        m = TYPE_RE.match(line)
        if m:
            owner = m.group(2)
            type_depth += brace_delta(line)
            continue

        fm = FUNC_RE.match(line)
        if fm:
            kind, name = fm.group(2), fm.group(3)
            end, span, complexity = body_span(lines, idx)
            rows.append([module, rel, owner, kind, name, idx + 1, span, complexity])
            continue

        pm = PROP_RE.match(line)
        if pm:
            kind, name = pm.group(2), pm.group(3)
            rows.append([module, rel, owner, kind, name, idx + 1, 0, 1])
            continue

        type_depth += brace_delta(line)


def main():
    check_only = "--check" in sys.argv
    rows = []
    files = 0
    for dirpath, _, filenames in os.walk(SRC):
        for fn in sorted(filenames):
            if not fn.endswith(".swift"):
                continue
            full = os.path.join(dirpath, fn)
            rel = os.path.relpath(full, SRC)
            scan_file(full, rel, rows)
            files += 1

    rows.sort(key=lambda r: (r[0], r[1], r[5]))
    print(f"扫描 {files} 个 swift 文件，得到 {len(rows)} 条函数/属性记录")

    if check_only:
        return

    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    with open(OUT, "w", encoding="utf-8-sig", newline="") as f:
        w = csv.writer(f)
        w.writerow(["module", "file", "owner", "kind", "name", "line", "lines", "complexity"])
        w.writerows(rows)
    print(f"已写入 {os.path.relpath(OUT, ROOT)}")


if __name__ == "__main__":
    main()
