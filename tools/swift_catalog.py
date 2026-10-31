#!/usr/bin/env python3
"""
FrsetNext 函数清单 / 调用关系导出（v171）

扫描 Swift 源码，产出：
  docs/FrsetNext-函数清单.csv     逐成员一行（模块/类型/成员/行号/规模/复杂度）
  docs/FrsetNext-模块依赖图.md     模块级 import 依赖（Mermaid）+ 统计摘要

用法：
  python3 tools/swift_catalog.py            # 默认扫描 apps/FrsetNext/Sources
  python3 tools/swift_catalog.py --root DIR

设计取舍：不追求完整语法树（没有 SwiftSyntax 依赖），用缩进 + 关键字做
**保守**解析——只统计能确定归属的成员，宁可少算也不瞎猜。
"""

import argparse
import csv
import os
import re
import sys
from collections import defaultdict, Counter

DECL_RE = re.compile(
    r"^(?P<indent>\s*)"
    r"(?:@\w+(?:\([^)]*\))?\s+)*"
    r"(?:(?:public|internal|private|fileprivate|open|final|static|class|mutating|nonmutating|override|convenience|required|lazy|weak|unowned)\s+)*"
    r"(?P<kind>class|struct|enum|protocol|actor|extension)\s+(?P<name>[\w.]+)"
)
FUNC_RE = re.compile(
    r"^(?P<indent>\s*)"
    r"(?:@\w+(?:\([^)]*\))?\s+)*"
    r"(?:(?:public|internal|private|fileprivate|open|final|static|class|mutating|nonmutating|override|convenience|required|dynamic|@objc)\s+)*"
    r"func\s+(?P<name>\w+)"
)
INIT_RE = re.compile(
    r"^(?P<indent>\s*)"
    r"(?:(?:public|internal|private|fileprivate|open|required|convenience|override)\s+)*"
    r"(?P<kind>init|deinit)\b"
)
PROP_RE = re.compile(
    r"^(?P<indent>\s*)"
    r"(?:(?:public|internal|private|fileprivate|open|final|static|class|override|lazy|weak|unowned)\s+)*"
    r"(?:var|let)\s+(?P<name>\w+)"
)
IMPORT_RE = re.compile(r"^import\s+(\w+)")

# 复杂度粗算：控制流关键字出现次数 + 1
BRANCH_RE = re.compile(r"\b(if|guard|for|while|switch|case|catch|&&|\|\||\?\.)\b|\?\s*[^:]*:|&&|\|\|")


def module_of(rel_path: str) -> str:
    """Sources/Features/Archive/X.swift → Archive；Sources/Core/X.swift → Core"""
    parts = rel_path.replace("\\", "/").split("/")
    if len(parts) >= 2 and parts[0] == "Features":
        return parts[1]
    return parts[0]


def scan_file(path: str, rel: str):
    """返回 (members, imports)"""
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            lines = fh.read().split("\n")
    except OSError:
        return [], []

    imports = []
    for line in lines:
        m = IMPORT_RE.match(line.strip())
        if m:
            imports.append(m.group(1))

    members = []
    module = module_of(rel)
    # 作用域栈：(indent, declKind, declName)
    stack = []

    def owner_at(indent: int):
        owner = ""
        for ind, _k, name in stack:
            if ind < indent:
                owner = name
        return owner

    # 记录每个成员（func/prop/init）的起始行，结尾用「下一个同级或更外层声明」来定
    pending = []  # (start_idx, indent, row)

    def close_pending(upto_idx: int):
        while pending:
            start, indent, row = pending.pop()
            body = lines[start + 1: upto_idx]
            # 只统计比它更深缩进的行，避免把后面的兄弟成员算进来
            depth = indent
            counted = 0
            branches = 0
            for bl in body:
                if not bl.strip():
                    continue
                bind = len(bl) - len(bl.lstrip())
                if bind <= depth and not bl.strip().startswith(("}", ")")):
                    break
                counted += 1
                branches += len(BRANCH_RE.findall(bl))
            row["lines"] = counted
            row["complexity"] = branches + 1
            members.append(row)

    for idx, line in enumerate(lines):
        stripped = line.strip()
        if not stripped or stripped.startswith("//") or stripped.startswith("///"):
            continue

        indent = len(line) - len(line.lstrip())

        dm = DECL_RE.match(line)
        fm = FUNC_RE.match(line)
        im = INIT_RE.match(line)
        pm = PROP_RE.match(line) if not (dm or fm or im) else None

        if dm:
            close_pending(idx)
            while stack and stack[-1][0] >= indent:
                stack.pop()
            stack.append((indent, dm.group("kind"), dm.group("name")))
            continue

        if fm:
            close_pending(idx)
            pending.append((idx, indent, {
                "module": module,
                "file": rel,
                "owner": owner_at(indent),
                "kind": "func",
                "name": fm.group("name"),
                "line": idx + 1,
                "lines": 0,
                "complexity": 0,
            }))
            continue

        if im:
            close_pending(idx)
            pending.append((idx, indent, {
                "module": module,
                "file": rel,
                "owner": owner_at(indent),
                "kind": im.group("kind"),
                "name": im.group("kind"),
                "line": idx + 1,
                "lines": 0,
                "complexity": 0,
            }))
            continue

        if pm:
            close_pending(idx)
            pending.append((idx, indent, {
                "module": module,
                "file": rel,
                "owner": owner_at(indent),
                "kind": "var" if " var " in f" {line} " else "let",
                "name": pm.group("name"),
                "line": idx + 1,
                "lines": 0,
                "complexity": 0,
            }))
            continue

    close_pending(len(lines))

    # pending 里剩下的（函数体到文件末尾）已在 close_pending 中落到 members?
    # close_pending 只改 row，不回填，这里统一补
    return members, imports


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--root", default="apps/FrsetNext/Sources")
    ap.add_argument("--outdir", default="docs")
    args = ap.parse_args()

    root = os.path.abspath(args.root)
    if not os.path.isdir(root):
        print(f"目录不存在: {root}", file=sys.stderr)
        return 1

    all_members = []
    module_imports = defaultdict(set)
    module_files = Counter()
    module_lines = Counter()

    for dirpath, _dirnames, filenames in os.walk(root):
        for fn in sorted(filenames):
            if not fn.endswith(".swift"):
                continue
            full = os.path.join(dirpath, fn)
            rel = os.path.relpath(full, root)
            mod = module_of(rel)
            try:
                with open(full, encoding="utf-8", errors="replace") as fh:
                    content = fh.read()
            except OSError:
                continue
            module_files[mod] += 1
            module_lines[mod] += content.count("\n") + 1

            members, imports = scan_file(full, rel)
            all_members.extend(members)
            for imp in imports:
                if imp[0].isupper():          # 只记模块级依赖，忽略 Foundation/AppKit
                    module_imports[mod].add(imp)

    os.makedirs(args.outdir, exist_ok=True)
    csv_path = os.path.join(args.outdir, "FrsetNext-函数清单.csv")
    fields = ["module", "file", "owner", "kind", "name", "line", "lines", "complexity"]
    with open(csv_path, "w", newline="", encoding="utf-8-sig") as fh:
        w = csv.DictWriter(fh, fieldnames=fields)
        w.writeheader()
        for row in sorted(all_members, key=lambda r: (r["module"], r["file"], r["line"])):
            w.writerow({k: row.get(k, "") for k in fields})

    # ── 类型引用依赖（单 module 工程没有内部 import，改用「谁引用了谁的顶层类型」）──
    decl_types = {}
    for dirpath, _dn, filenames in os.walk(root):
        for fn in filenames:
            if not fn.endswith(".swift"):
                continue
            full = os.path.join(dirpath, fn)
            rel = os.path.relpath(full, root)
            try:
                content = open(full, encoding="utf-8", errors="replace").read()
            except OSError:
                continue
            for line in content.split("\n"):
                dm = DECL_RE.match(line)
                if dm:
                    # 只认顶层声明（缩进 0）作为模块出口
                    if not dm.group("indent"):
                        decl_types.setdefault(dm.group("name"), module_of(rel))

    ident_re = re.compile(r"\b([A-Z][A-Za-z0-9_]{2,})\b")
    edge_weight = Counter()
    for dirpath, _dn, filenames in os.walk(root):
        for fn in filenames:
            if not fn.endswith(".swift"):
                continue
            full = os.path.join(dirpath, fn)
            rel = os.path.relpath(full, root)
            src_mod = module_of(rel)
            try:
                content = open(full, encoding="utf-8", errors="replace").read()
            except OSError:
                continue
            idents = set(ident_re.findall(content))
            for ident in idents & decl_types.keys():
                target_mod = decl_types[ident]
                if target_mod != src_mod:
                    edge_weight[(src_mod, target_mod)] += 1

    # 只留权重 ≥3 的边，去掉偶然提及
    strong = {k: v for k, v in edge_weight.items() if v >= 3}
    edges = list(strong.keys())

    # ── 模块依赖图 ──
    internal = set(module_files)
    edges = []
    for mod, imps in module_imports.items():
        for imp in imps:
            if imp in internal and imp != mod:
                edges.append((mod, imp))

    md = ["# FrsetNext 模块依赖与规模", ""]
    md.append(f"> 自动生成，重算：`python3 tools/swift_catalog.py`　"
              f"共 {len(module_files)} 个模块 / {sum(module_files.values())} 文件 / "
              f"{sum(module_lines.values()):,} 行 / {len(all_members):,} 个成员")
    md.append("")
    md.append("## 模块规模")
    md.append("")
    md.append("| 模块 | 文件 | 行数 | 成员 |")
    md.append("|---|---:|---:|---:|")
    per_mod_members = Counter(m["module"] for m in all_members)
    for mod, _ in sorted(module_files.items(), key=lambda kv: -module_lines[kv[0]]):
        md.append(f"| {mod} | {module_files[mod]} | {module_lines[mod]:,} | {per_mod_members.get(mod, 0)} |")
    md.append("")
    md.append("## 模块依赖（顶层类型被跨模块引用，边权=引用到的类型数）")
    md.append("")
    md.append("```mermaid")
    md.append("flowchart LR")
    node_ids = {}
    for i, mod in enumerate(sorted(internal)):
        node_ids[mod] = f"M{i}"
        md.append(f'  {node_ids[mod]}["{mod}"]')
    for (a, b), w in sorted(strong.items(), key=lambda kv: -kv[1])[:40]:
        md.append(f"  {node_ids[a]} -->|{w}| {node_ids[b]}")
    md.append("```")
    md.append("")
    md.append("## 高复杂度成员 Top 30")
    md.append("")
    md.append("| 复杂度 | 行数 | 成员 | 位置 |")
    md.append("|---:|---:|---|---|")
    top = sorted(all_members, key=lambda m: -m["complexity"])[:30]
    for m in top:
        owner = f'{m["owner"]}.' if m["owner"] else ""
        md.append(f'| {m["complexity"]} | {m["lines"]} | {owner}{m["name"]} | '
                  f'`{m["file"]}:{m["line"]}` |')
    md.append("")

    md_path = os.path.join(args.outdir, "FrsetNext-模块依赖图.md")
    with open(md_path, "w", encoding="utf-8") as fh:
        fh.write("\n".join(md))

    print(f"CSV  : {csv_path}  ({len(all_members):,} 行)")
    print(f"依赖图: {md_path}  ({len(strong)} 条模块引用边, 阈值>=3)")
    print(f"规模  : {sum(module_files.values())} 文件 / {sum(module_lines.values()):,} 行 / {len(module_files)} 模块")
    return 0


if __name__ == "__main__":
    sys.exit(main())
