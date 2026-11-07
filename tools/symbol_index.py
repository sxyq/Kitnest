#!/usr/bin/env python3
"""逐声明 CSV（含结束行与体行数）——v259 起复用 func_table 的唯一解析器。

历史问题：本脚本原来自带一套正则（要求"声明行自身开大括号"），协议里**无体的要求**
（`func toggle()` 这类）和跨行签名的声明会被整条漏掉，实测比函数清单少 150 个函数；
又因为不收属性，总数只有 4,064，和索引文档写的 8,679 对不上，形成"一套代码三个数"。

现在：直接调用 `tools/func_table.py` 的 `scan_file`，口径与函数清单完全一致
（函数 + 属性都收，访问器体跳读，多行字符串按状态剥离）。

用法: python3 tools/symbol_index.py <Sources 根目录> <输出 csv>
输出列: path,kind,name,container,start,end,lines
"""
import csv
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import func_table  # noqa: E402


def main():
    if len(sys.argv) != 3:
        print(__doc__, file=sys.stderr)
        return 2
    root, out = sys.argv[1], sys.argv[2]
    rows = []
    for dirpath, _dirs, names in os.walk(root):
        for name in sorted(names):
            if not name.endswith(".swift"):
                continue
            full = os.path.join(dirpath, name)
            rel = os.path.relpath(full, root)
            for r in func_table.scan_file(full, rel):
                body = int(r["lines"])
                start = int(r["line"])
                rows.append([rel, r["kind"], r["name"], r["owner"] if r["owner"] != "-" else "",
                             start, start + body - 1 if body > 0 else start, body])
    rows.sort(key=lambda x: (x[0], int(x[4])))
    with open(out, "w", newline="", encoding="utf-8") as fh:
        w = csv.writer(fh)
        w.writerow(["path", "kind", "name", "container", "start", "end", "lines"])
        w.writerows(rows)
    funcs = sum(1 for r in rows if r[1] in ("func", "init", "deinit", "subscript"))
    print(f"{len(rows)} decls（函数 {funcs}）-> {out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
