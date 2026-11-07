#!/usr/bin/env python3
"""
模块依赖与规模（v259 重写）

历史问题：本脚本原来是**第三套**独立解析器（缩进 + 关键字猜测），产出的成员数与
`tools/func_table.py` 的函数清单一南一北（269 文件/8,679 vs 273 文件/8,762），
还顺带往 `docs/` 写一份同名 CSV，造成"一套代码三个数"。

现在：成员表直接复用 `func_table.scan_file`（唯一解析口径），本脚本只负责两件
func_table 不做的事——
  1) 每模块的文件数 / 行数 / 成员数；
  2) 模块间的**顶层类型引用**边（import 在单 target 工程里恒为空，不可用）。

产出：`docs/00-总览/模块依赖图.md`
用法：`python3 tools/swift_catalog.py`
"""

import argparse
import os
import re
import sys
from collections import Counter, defaultdict

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import func_table  # noqa: E402

DECL_RE = re.compile(
    r"^(?P<indent>\s*)"
    r"(?:@\w+(?:\([^)]*\))?\s+)*"
    r"(?:(?:public|internal|private|fileprivate|open|final|static|class|mutating|nonmutating|override|convenience|required|lazy|weak|unowned)\s+)*"
    r"(?P<kind>class|struct|enum|protocol|actor|extension)\s+(?P<name>[\w.]+)"
)
IDENT_RE = re.compile(r"\b([A-Z][A-Za-z0-9_]{2,})\b")


def module_of(rel_path: str) -> str:
    """Sources/Features/Archive/X.swift → Archive；Sources/Core/X.swift → Core"""
    parts = rel_path.replace("\\", "/").split("/")
    if len(parts) >= 2 and parts[0] == "Features":
        return parts[1]
    return parts[0]


def walk_swift(root: str):
    for dirpath, _dirnames, filenames in os.walk(root):
        for fn in sorted(filenames):
            if fn.endswith(".swift"):
                full = os.path.join(dirpath, fn)
                yield full, os.path.relpath(full, root)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--root", default="apps/FrsetNext/Sources")
    ap.add_argument("--out", default="docs/00-总览/模块依赖图.md")
    args = ap.parse_args()

    root = os.path.abspath(args.root)
    if not os.path.isdir(root):
        print(f"目录不存在: {root}", file=sys.stderr)
        return 1

    all_members = []
    module_files = Counter()
    module_lines = Counter()
    decl_types = {}          # 顶层类型名 → 所属模块（模块出口）

    for full, rel in walk_swift(root):
        mod = module_of(rel)
        try:
            content = open(full, encoding="utf-8", errors="replace").read()
        except OSError:
            continue
        module_files[mod] += 1
        module_lines[mod] += len(content.splitlines())
        all_members.extend(func_table.scan_file(full, rel))
        for line in content.split("\n"):
            dm = DECL_RE.match(line)
            if dm and not dm.group("indent"):     # 只认顶层声明作为模块出口
                decl_types.setdefault(dm.group("name"), mod)

    # ── 模块依赖：谁引用了谁的顶层类型（边权 = 引用到的类型数）──
    edge_weight = Counter()
    for full, rel in walk_swift(root):
        src = module_of(rel)
        try:
            content = open(full, encoding="utf-8", errors="replace").read()
        except OSError:
            continue
        for ident in set(IDENT_RE.findall(content)) & decl_types.keys():
            target = decl_types[ident]
            if target != src:
                edge_weight[(src, target)] += 1
    strong = {k: v for k, v in edge_weight.items() if v >= 3}

    md = ["# FrsetNext 模块依赖与规模", ""]
    md.append(f"> 自动生成，重算：`python3 tools/swift_catalog.py`　"
              f"共 {len(module_files)} 个模块 / {sum(module_files.values())} 文件 / "
              f"{sum(module_lines.values()):,} 行 / {len(all_members):,} 个声明 / "
              f"{len(strong)} 条模块引用边")
    md.append(">")
    md.append("> 成员口径复用 `tools/func_table.py`（唯一解析器）；"
              "跨模块边 = 引用到的对方顶层类型数（≥3 才画），import 在单 target 工程里恒为空。")
    md.append("")
    md.append("## 模块规模")
    md.append("")
    md.append("| 模块 | 文件 | 行数 | 声明 |")
    md.append("|---|---:|---:|---:|")
    per_mod = Counter(m["module"] for m in all_members)
    for mod, _ in sorted(module_files.items(), key=lambda kv: -module_lines[kv[0]]):
        md.append(f"| {mod} | {module_files[mod]} | {module_lines[mod]:,} | {per_mod.get(mod, 0)} |")
    md.append("")
    md.append("## 模块依赖（顶层类型被跨模块引用，边权=引用到的类型数）")
    md.append("")
    md.append("```mermaid")
    md.append("flowchart LR")
    node_ids = {}
    for i, mod in enumerate(sorted(module_files)):
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
    for m in sorted(all_members, key=lambda x: -int(x["complexity"]))[:30]:
        owner = f'{m["owner"]}.' if m["owner"] and m["owner"] != "-" else ""
        md.append(f'| {m["complexity"]} | {m["lines"]} | {owner}{m["name"]} | '
                  f'`{m["file"]}:{m["line"]}` |')
    md.append("")

    os.makedirs(os.path.dirname(args.out), exist_ok=True)
    with open(args.out, "w", encoding="utf-8") as fh:
        fh.write("\n".join(md))

    print(f"依赖图: {args.out}  ({len(strong)} 条模块引用边, 阈值>=3)")
    print(f"规模  : {sum(module_files.values())} 文件 / {sum(module_lines.values()):,} 行 / "
          f"{len(module_files)} 模块 / {len(all_members):,} 声明")
    return 0


if __name__ == "__main__":
    sys.exit(main())
