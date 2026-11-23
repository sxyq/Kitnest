#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
FrsetNext（项目二）全量函数/类型抽取器
=====================================
与 tools/perf_audit/reindex.py 同源解析逻辑（作用域跟踪/多行签名/花括号配对），
增强：
  1. 捕获 init（原版二进制侧有大量 init 方法，口径需对齐）
  2. 捕获类型声明本身（class/struct/enum/protocol/extension/actor）
  3. 输出类型清单 + 函数清单两个 CSV
输出（audit-原版功能核对/）：
  FrsetNext-函数清单.csv   lang,file,scope,kind,name,start,end,nlines,mods,sig
  FrsetNext-类型清单.csv   lang,file,name,kind,start
"""
import os, re, csv

ROOT = "/Users/sunyiyang/Desktop/Project/frset-rebuild"
SRC = os.path.join(ROOT, "apps", "FrsetNext", "Sources")
OUT_DIR = os.path.join(ROOT, "docs", "audit-原版功能核对")

TYPE_RE = re.compile(
    r"^\s*(?:(?:public|internal|private|fileprivate|open|final|@objc|@MainActor|@available\([^)]*\))\s+)*"
    r"(class|struct|enum|extension|actor|protocol)\s+([A-Za-z_]\w*)"
)
FUNC_RE = re.compile(r"^\s*(.*?)\bfunc\s+([A-Za-z_]\w*)\s*(?:<[^>]*>)?\s*\(")
INIT_RE = re.compile(r"^\s*(.*?)\binit\s*[<(]")
C_FUNC_RE = re.compile(r"^([A-Za-z_][A-Za-z0-9_ \t\*]*?)\b([A-Za-z_]\w*)\s*\(")

C_KEYWORDS = {
    "if", "for", "while", "switch", "return", "sizeof", "else", "do", "case",
    "goto", "typeof", "__attribute__", "defined",
}

def strip_code(line: str) -> str:
    out = []
    i = 0; n = len(line); in_str = False; quote = ""
    while i < n:
        ch = line[i]
        if in_str:
            if ch == "\\":
                i += 2; continue
            if ch == quote:
                in_str = False
            i += 1; continue
        if ch in ('"', "'"):
            in_str = True; quote = ch; i += 1; continue
        if ch == "/" and i + 1 < n and line[i + 1] == "/":
            break
        out.append(ch)
        i += 1
    return "".join(out)

def count_top_level_commas(s: str) -> int:
    depth = 0; commas = 0
    for ch in s:
        if ch in "([{<": depth += 1
        elif ch in ")]}>": depth -= 1
        elif ch == "," and depth == 0: commas += 1
    return commas

def parse_swift(path: str, rel: str):
    lines = open(path, encoding="utf-8", errors="replace").read().splitlines()
    depth = 0
    scopes = []      # [(name, kind, depth_at_open)]
    funcs = []
    types = []
    consumed_until = -1

    for i, raw in enumerate(lines):
        code = strip_code(raw)

        m = TYPE_RE.match(code)
        if m and "func" not in code:
            kind, tname = m.group(1), m.group(2)
            scopes.append((tname, kind, depth))
            types.append({"lang": "swift", "file": rel, "name": tname,
                          "kind": kind, "start": i + 1})

        fm = FUNC_RE.match(code)
        im = INIT_RE.match(code)
        if (fm or im) and i > consumed_until:
            if fm:
                prefix, name, is_init = fm.group(1), fm.group(2), False
            else:
                prefix, name, is_init = im.group(1), "init", True
            sig_lines = [raw]
            j = i; brace_line = None; decl_only = False
            while j < len(lines) and j < i + 12:
                probe = strip_code(lines[j])
                if "{" in probe:
                    brace_line = j; break
                if ";" in probe and ")" in probe:
                    decl_only = True; break
                if j > i and (probe.strip().startswith("}") or re.search(r"\bfunc\s+\w+", probe) or re.search(r"\binit\s*[<(]", probe)):
                    decl_only = True; break
                if j > i:
                    sig_lines.append(lines[j])
                j += 1
            if brace_line is not None and not decl_only:
                d = 0; end = brace_line; started = False
                for k in range(brace_line, len(lines)):
                    c = strip_code(lines[k])
                    for ch in c:
                        if ch == "{":
                            d += 1; started = True
                        elif ch == "}":
                            d -= 1
                    if started and d <= 0:
                        end = k; break
                consumed_until = end
                sig = re.sub(r"\s+", " ", " ".join(x.strip() for x in sig_lines))
                pstart = sig.find("(")
                depth_p = 0; pend = -1
                for idx in range(pstart, len(sig)):
                    if sig[idx] == "(": depth_p += 1
                    elif sig[idx] == ")":
                        depth_p -= 1
                        if depth_p == 0:
                            pend = idx; break
                params = ""
                if pstart >= 0 and pend > pstart:
                    inner = sig[pstart + 1:pend]
                    params = count_top_level_commas(inner) + 1 if inner.strip() else 0
                mods = " ".join(
                    w for w in ["static", "class", "public", "private", "fileprivate",
                                "internal", "open", "override", "mutating", "nonmutating",
                                "@objc", "@MainActor", "async", "throws", "convenience", "required"]
                    if re.search(r"(?<![\w@])" + re.escape(w) + r"(?![\w])", prefix + " " + sig[:pstart])
                )
                scope = scopes[-1][0] if scopes else ""
                funcs.append({
                    "lang": "swift", "file": rel, "scope": scope,
                    "kind": "init" if is_init else "func", "name": name,
                    "start": i + 1, "end": end + 1, "nlines": end - i + 1,
                    "mods": mods, "sig": sig,
                })

        depth += code.count("{") - code.count("}")
        while scopes and depth <= scopes[-1][2]:
            scopes.pop()
    return funcs, types

def parse_c(path: str, rel: str, lang: str):
    lines = open(path, encoding="utf-8", errors="replace").read().splitlines()
    funcs = []
    consumed_until = -1
    for i, raw in enumerate(lines):
        if i <= consumed_until: continue
        if not raw or raw[0] in " \t#*/}": continue
        m = C_FUNC_RE.match(raw)
        if not m: continue
        name = m.group(2)
        if name in C_KEYWORDS: continue
        j = i; brace_line = None; decl = False
        while j < len(lines) and j < i + 8:
            probe = strip_code(lines[j])
            if "{" in probe:
                brace_line = j; break
            if ";" in probe:
                decl = True; break
            j += 1
        if decl or brace_line is None: continue
        d = 0; end = brace_line; started = False
        for k in range(brace_line, len(lines)):
            c = strip_code(lines[k])
            for ch in c:
                if ch == "{":
                    d += 1; started = True
                elif ch == "}":
                    d -= 1
            if started and d <= 0:
                end = k; break
        consumed_until = end
        sig = re.sub(r"\s+", " ", " ".join(x.strip() for x in lines[i:brace_line + 1]))
        pstart = sig.find("("); pend = sig.find(")", pstart)
        params = ""
        if pstart >= 0 and pend > pstart:
            inner = sig[pstart + 1:pend]
            params = count_top_level_commas(inner) + 1 if inner.strip() else 0
        mods = "static" if raw.lstrip().startswith("static") else ""
        funcs.append({
            "lang": lang, "file": rel, "scope": "",
            "kind": "func", "name": name,
            "start": i + 1, "end": end + 1, "nlines": end - i + 1,
            "mods": mods, "sig": sig,
        })
    return funcs, []

def main():
    files = []
    for dirpath, _, names in os.walk(SRC):
        for n in names:
            if n.endswith(".swift"):
                files.append((os.path.join(dirpath, n), "swift"))
            elif n.endswith(".m"):
                files.append((os.path.join(dirpath, n), "objc"))
            elif n.endswith(".c"):
                files.append((os.path.join(dirpath, n), "c"))
    files.sort()

    funcs, types = [], []
    for p, lang in files:
        rel = os.path.relpath(p, SRC)
        if lang == "swift":
            f, t = parse_swift(p, rel)
        else:
            f, t = parse_c(p, rel, lang)
        funcs.extend(f); types.extend(t)

    with open(os.path.join(OUT_DIR, "FrsetNext-函数清单.csv"), "w", newline="") as fh:
        w = csv.writer(fh)
        w.writerow(["lang", "file", "scope", "kind", "name", "start", "end", "nlines", "mods", "sig"])
        for f in funcs:
            w.writerow([f["lang"], f["file"], f["scope"], f["kind"], f["name"],
                        f["start"], f["end"], f["nlines"], f["mods"], f["sig"]])

    with open(os.path.join(OUT_DIR, "FrsetNext-类型清单.csv"), "w", newline="") as fh:
        w = csv.writer(fh)
        w.writerow(["lang", "file", "name", "kind", "start"])
        for t in types:
            w.writerow([t["lang"], t["file"], t["name"], t["kind"], t["start"]])

    n_func = sum(1 for f in funcs if f["kind"] == "func")
    n_init = sum(1 for f in funcs if f["kind"] == "init")
    print(f"FrsetNext: {len(funcs)} functions (func={n_func} init={n_init}), {len(types)} type decls")
    from collections import Counter
    print("by lang:", Counter(f["lang"] for f in funcs))
    print("types by kind:", Counter(t["kind"] for t in types))

if __name__ == "__main__":
    main()
