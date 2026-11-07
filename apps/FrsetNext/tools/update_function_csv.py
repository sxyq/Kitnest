#!/usr/bin/env python3
"""【已废弃 —— v259 起改为转发】重生成函数清单 CSV。

历史：本文件是同一张表的第 4 份生成器（各自独立的正则），与 `tools/func_table.py`
长期并行，导致「同一份源码，几处数字不一样」：
  · 本脚本 / swift_catalog.py 各算一遍 owner 与行号；
  · 都不识别多行字符串——本文件的 `brace_delta` 注释里就写着「忽略字符串/注释里的括号
    会失真，但整体可用」，而实际后果是 `ClipboardRepository` 的 SQL 字面量 `'%{%'`
    让括号深度永久 +1，整段 16 条声明（fetch/insert/delete…）被吞掉；
  · 都不跳过计算属性的体，getter 里的局部 `let` 被记成类型成员（旧表 470 条）。

现在唯一入口是仓库根的 `tools/func_table.py`（AGENTS.md 铁律 3）。
本文件只保留转发，避免旧文档 / 旧习惯再写出一张口径不同的表。

用法（与过去一致）：
    python3 apps/FrsetNext/tools/update_function_csv.py            # 重生成
    python3 apps/FrsetNext/tools/update_function_csv.py --check    # 只统计
"""
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
# apps/FrsetNext/tools → apps/FrsetNext → apps → 仓库根
REPO = os.path.dirname(os.path.dirname(os.path.dirname(HERE)))
CANONICAL = os.path.join(REPO, "tools", "func_table.py")

if __name__ == "__main__":
    if not os.path.isfile(CANONICAL):
        sys.exit(f"找不到唯一解析器：{CANONICAL}")
    print(f"[已废弃] 转发到 {os.path.relpath(CANONICAL, REPO)}（唯一解析口径）", file=sys.stderr)
    sys.exit(subprocess.call([sys.executable, CANONICAL] + sys.argv[1:]))
