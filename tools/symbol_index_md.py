#!/usr/bin/env python3
"""把符号扫描结果渲染成 Markdown 索引（按目录/文件分组）。"""
import csv
import os
import sys
from collections import defaultdict, OrderedDict

MODULE_NAMES = {
    'App': '应用装配', 'Core': '基础设施', 'Models': '数据模型', 'Storage': '存储层',
    'FrsetStatsBar': 'STATS 菜单栏引擎（C/ObjC）', 'MemoryHelper': '内存探针子进程',
    'OCRHelper': 'OCR 子进程',
}


def module_of(rel):
    parts = rel.split(os.sep)
    if len(parts) == 1:
        return '（根）'
    if parts[0] == 'Features' and len(parts) > 1:
        return 'Features/' + parts[1]
    return parts[0]


def main():
    src, csv_path, out = sys.argv[1], sys.argv[2], sys.argv[3]
    rows = list(csv.DictReader(open(csv_path, encoding='utf-8')))
    files = OrderedDict()
    for dirpath, _, names in os.walk(src):
        for n in sorted(names):
            if n.endswith('.swift'):
                rel = os.path.relpath(os.path.join(dirpath, n), src)
                files[rel] = sum(1 for _ in open(os.path.join(dirpath, n), encoding='utf-8', errors='replace'))

    by_file = defaultdict(list)
    for r in rows:
        by_file[r['path']].append(r)

    by_module = defaultdict(list)
    for rel in sorted(files):
        by_module[module_of(rel)].append(rel)

    total_files = len(files)
    total_lines = sum(files.values())
    total_decls = len(rows)
    total_funcs = sum(1 for r in rows if r['kind'] == 'func')

    lines = []
    lines.append('# FrsetNext 符号索引（自动生成，逐函数）')
    lines.append('')
    lines.append('> 由 `tools/symbol_index.py` 扫描 `apps/FrsetNext/Sources` 生成，**用于反查与对账，不手工编辑**。')
    lines.append(f'> 覆盖 {total_files} 个 Swift 文件、{total_lines} 行、{total_decls} 个声明（其中函数 {total_funcs} 个）。')
    lines.append('> 「行数」= 函数体占用行数（含签名行与右花括号），用于判断复杂度，不是 LOC 统计。')
    lines.append('>')
    lines.append('> **口径（下界，不是全量）**：① 只扫 `.swift`，`FrsetStatsBar/` 的 C/ObjC 约 1 万行不在其中；')
    lines.append('> ② 正则要求"声明行自身开启大括号"，**多行签名的函数会漏约 50 个**。')
    lines.append('> 逐行级细节以 `docs/deepread/` 的 11 份测绘报告为准（报告逐文件标注了 CSV 对账数）。')
    lines.append('')
    lines.append('## 总量分布')
    lines.append('')
    lines.append('| 模块 | 文件 | 行数 | 声明 | 函数 |')
    lines.append('|---|---|---|---|---|')
    for mod in sorted(by_module, key=lambda m: -sum(files[f] for f in by_module[m])):
        fs = by_module[mod]
        decls = sum(len(by_file[f]) for f in fs)
        funcs = sum(1 for f in fs for r in by_file[f] if r['kind'] == 'func')
        lines.append(f'| {mod} | {len(fs)} | {sum(files[f] for f in fs)} | {decls} | {funcs} |')
    lines.append('')

    for mod in sorted(by_module, key=lambda m: -sum(files[f] for f in by_module[m])):
        lines.append(f'## {mod}')
        lines.append('')
        for rel in by_module[mod]:
            decls = by_file.get(rel, [])
            lines.append(f'### `{rel}` · {files[rel]} 行 · {len(decls)} 声明')
            lines.append('')
            if not decls:
                lines.append('（无类型/函数声明，纯扩展或常量）')
                lines.append('')
                continue
            lines.append('| 行 | 类型 | 名称 | 所属 | 体行数 |')
            lines.append('|---|---|---|---|---|')
            kind_cn = {'func': '函数', 'init': '初始化', 'struct': '结构体', 'class': '类',
                       'enum': '枚举', 'protocol': '协议', 'extension': '扩展', 'actor': 'actor'}
            for r in decls:
                start = r['start']
                name = r['name'] if r['kind'] in ('func', 'init') else f"**{r['name']}**"
                lines.append(f"| {start} | {kind_cn.get(r['kind'], r['kind'])} | {name} | {r['container'] or '—'} | {r['lines'] or '—'} |")
            lines.append('')

    with open(out, 'w', encoding='utf-8') as f:
        f.write('\n'.join(lines))
    print(f'wrote {out}: {len(lines)} lines, {total_decls} decls, {total_files} files')


if __name__ == '__main__':
    main()
