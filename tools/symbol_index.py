#!/usr/bin/env python3
"""扫描 Swift 源码，抽取 类型/函数/初始化器 声明及其所在容器与函数体行数。

用法: python3 frset_symbol_scan.py <Sources 根目录> <输出 csv>
输出列: rel_path,kind,name,container,start_line,end_line,body_lines
"""
import os
import re
import sys
import csv

TYPE_RE = re.compile(
    r'^\s*(?:@\w+(?:\([^)]*\))?\s+)*'
    r'(?:(?:public|internal|private|fileprivate|open|final|indirect)\s+)*'
    r'(class|struct|enum|protocol|extension|actor)\s+([A-Za-z_][A-Za-z0-9_]*)'
)
FUNC_RE = re.compile(
    r'^\s*(?:@\w+(?:\([^)]*\))?\s+)*'
    r'(?:(?:public|internal|private|fileprivate|open|static|class|mutating|nonmutating|override|final|dynamic)\s+)*'
    r'func\s+([A-Za-z_][A-Za-z0-9_]*)\s*[\(<]'
)
INIT_RE = re.compile(
    r'^\s*(?:@\w+(?:\([^)]*\))?\s+)*'
    r'(?:(?:public|internal|private|fileprivate|open|required|convenience|override)\s+)*'
    r'init\s*[\(\?]'
)


def strip_code(line, state):
    """去掉注释与字符串字面量，返回 (可计大括号的代码, 新状态)。"""
    out = []
    i = 0
    n = len(line)
    while i < n:
        if state['block']:
            j = line.find('*/', i)
            if j == -1:
                return ''.join(out), state
            state['block'] = False
            i = j + 2
            continue
        if state['str3']:
            j = line.find('"""', i)
            if j == -1:
                return ''.join(out), state
            state['str3'] = False
            i = j + 3
            continue
        ch = line[i]
        if ch == '/' and i + 1 < n and line[i + 1] == '/':
            break
        if ch == '/' and i + 1 < n and line[i + 1] == '*':
            state['block'] = True
            i += 2
            continue
        if line.startswith('"""', i):
            state['str3'] = True
            i += 3
            continue
        if ch == '"':
            i += 1
            while i < n:
                if line[i] == '\\':
                    i += 2
                    continue
                if line[i] == '"':
                    i += 1
                    break
                i += 1
            out.append(' ')  # 字面量整体折叠，内部括号不计
            continue
        out.append(ch)
        i += 1
    return ''.join(out), state


def scan_file(path, rel):
    rows = []
    stack = []          # [{'depth': int, 'name': str, 'kind': str, 'row': idx}]
    depth = 0
    state = {'block': False, 'str3': False}
    with open(path, encoding='utf-8', errors='replace') as f:
        lines = f.read().split('\n')

    for lineno, raw in enumerate(lines, 1):
        code, state = strip_code(raw, state)
        opened = code.count('{')
        closed = code.count('}')

        # 声明必须在本行开启作用域（单行声明如 `struct A { ... }` 也记录）
        if opened > 0:
            container = stack[-1]['name'] if stack else ''
            if TYPE_RE.match(code):
                m = TYPE_RE.match(code)
                row = [rel, m.group(1), m.group(2), container, lineno, '', 0]
                rows.append(row)
                stack.append({'depth': depth, 'name': m.group(2), 'kind': m.group(1), 'row': row})
            elif FUNC_RE.match(code):
                m = FUNC_RE.match(code)
                row = [rel, 'func', m.group(1), container, lineno, '', 0]
                rows.append(row)
                stack.append({'depth': depth, 'name': m.group(1), 'kind': 'func', 'row': row})
            elif INIT_RE.match(code):
                row = [rel, 'init', 'init', container, lineno, '', 0]
                rows.append(row)
                stack.append({'depth': depth, 'name': 'init', 'kind': 'init', 'row': row})

        depth += opened
        depth -= closed

        # 收口：任何记录在作用域闭合后结束
        while stack and depth <= stack[-1]['depth']:
            item = stack.pop()
            item['row'][5] = lineno
            item['row'][6] = max(0, lineno - item['row'][4] + 1)

    return rows


def main():
    root, out = sys.argv[1], sys.argv[2]
    all_rows = []
    for dirpath, _, files in os.walk(root):
        for name in sorted(files):
            if not name.endswith('.swift'):
                continue
            full = os.path.join(dirpath, name)
            rel = os.path.relpath(full, root)
            all_rows.extend(scan_file(full, rel))
    with open(out, 'w', newline='', encoding='utf-8') as f:
        w = csv.writer(f)
        w.writerow(['path', 'kind', 'name', 'container', 'start', 'end', 'lines'])
        w.writerows(all_rows)
    print(f'{len(all_rows)} decls -> {out}')


if __name__ == '__main__':
    main()
