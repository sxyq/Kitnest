#!/usr/bin/env python3
# AST 函数清单抽取（供 docs/perfaudit/函数清单-AST抽取.csv 实时更新）
# 用法：python3 extract_ast_csv.py   （在任意位置运行均可，路径内置）
# 格式：lang,file,scope,name,start,end,nlines,params,mods,sig
#   mods：static/private/public 等修饰；params：参数个数；scope：最近外层类型
import os, re, csv

ROOT = "/Users/sunyiyang/Desktop/Project/frset-rebuild/apps/FrsetNext/Sources"
OUT = "/Users/sunyiyang/Desktop/Project/frset-rebuild/docs/perfaudit/函数清单-AST抽取.csv"

SWIFT_SIG = re.compile(
    r'^(?P<indent>[ \t]*)(?P<mods>(?:@\w+(?:\([^)]*\))?[ \t]+|'
    r'(?:public|private|internal|fileprivate|open|static|final|mutating|override|class|nonisolated)[ \t]+)*)'
    r'(?P<kind>func|init)[ \t]*(?P<name>[^\s({<]*)[^\n{]*?(?P<params>\(([^)]*)\))?', re.M)

def swift_scope_stack(lines, idx):
    """最近外层类型名（class/struct/enum/extension），按缩进+大括号深度推断"""
    depth = 0
    stack = []  # (indent, name)
    type_re = re.compile(r'^\s*(?:(?:public|private|internal|fileprivate|open|final|static|indirect)\s+)*'
                         r'(?:class|struct|enum|extension|actor)\s+([\w.]+)')
    for i, line in enumerate(lines[:idx+1]):
        m = type_re.match(line)
        indent = len(line) - len(line.lstrip())
        while stack and stack[-1][0] >= indent and line.strip().startswith("}"):
            stack.pop()
        if m:
            stack.append((indent, m.group(1)))
        elif line.strip().startswith("}"):
            # 收缩栈：深度下降时丢掉内层
            if stack and indent <= stack[-1][0]:
                stack.pop()
    return stack[-1][1] if stack else ""

def count_params(s):
    if not s: return 0
    parts, d, cur = 0, 0, ""
    for ch in s:
        if ch in "([{": d += 1
        elif ch in ")]}": d -= 1
        if ch == "," and d == 0:
            if cur.strip(): parts += 1
            cur = ""
        else:
            cur += ch
    if cur.strip(): parts += 1
    return parts

rows = []
for dirpath, _, files in os.walk(ROOT):
    for fn in sorted(files):
        p = os.path.join(dirpath, fn)
        rel = os.path.relpath(p, ROOT)
        if fn.endswith(".swift"):
            text = open(p, encoding="utf-8", errors="replace").read()
            lines = text.splitlines()
            for m in SWIFT_SIG.finditer(text):
                start = text[:m.start()].count("\n") + 1
                # 函数体结束：按缩进找首个同缩进 }
                sig_line = lines[start-1]
                indent = len(sig_line) - len(sig_line.lstrip())
                end = start
                # 单行体（无 {）也给 start=end
                brace = 0; seen = False
                for j in range(start-1, len(lines)):
                    brace += lines[j].count("{") - lines[j].count("}")
                    if "{" in lines[j]: seen = True
                    end = j + 1
                    if seen and brace <= 0: break
                nparams = count_params(m.group("params") or "")
                mods = " ".join(re.findall(r'public|private|internal|fileprivate|open|static|final|mutating|override|class|nonisolated',
                                           m.group("mods") or ""))
                name = m.group("name") or (m.group("kind"))
                scope = swift_scope_stack(lines, start-1)
                rows.append(("swift", rel, scope, name, start, end, end-start+1, nparams, mods,
                             sig_line.strip()[:160]))
        elif fn.endswith(".m") or fn.endswith(".h"):
            lines = open(p, encoding="utf-8", errors="replace").read().splitlines()
            impl_re = re.compile(r'^@(?:implementation|interface)\s+([\w.]+)')
            meth_re = re.compile(r'^([+-])\s*\(([^)]*)\)\s*([^;{]+)')
            func_re = re.compile(r'^(?:static\s+|inline\s+|extern\s+)*'
                                 r'(?:void|int|double|CGFloat|BOOL|NSString\s*\*|NSArray[^;{]*\*|id|uint64_t|NSImage\s*\*)\s+'
                                 r'(\w+)\s*\(')
            scope = ""
            for i, line in enumerate(lines):
                im = impl_re.match(line)
                if im:
                    scope = im.group(1); continue
                mm = meth_re.match(line)
                if mm:
                    name = mm.group(3).split(":")[0].strip()
                    nparams = mm.group(3).count(":")
                    mods = "class" if mm.group(1) == "+" else "instance"
                    rows.append(("objc", rel, scope, name, i+1, i+1, 1, nparams, mods, line.strip()[:160]))
                    continue
                fm = func_re.match(line)
                if fm:
                    sig = line
                    nparams = 0
                    rows.append(("c", rel, scope, fm.group(1), i+1, i+1, 1, nparams, "static" if line.startswith("static") else "",
                                 sig.strip()[:160]))

rows.sort(key=lambda r: (r[1], r[4]))
with open(OUT, "w", newline="", encoding="utf-8") as f:
    w = csv.writer(f)
    w.writerow(["lang","file","scope","name","start","end","nlines","params","mods","sig"])
    w.writerows(rows)
print(f"抽取 {len(rows)} 个函数 → {OUT}")
