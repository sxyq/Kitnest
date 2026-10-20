#!/usr/bin/env python3
"""重新索引 FrsetNext 函数清单与性能审计台账。

设计要点：
- 解析 Swift（含类型作用域跟踪、多行签名）与 C/ObjC（顶层 C 函数）。
- 引用数 = 全仓源码中标识符出现次数 - 1（定义处）；用于死代码候选判定。
- 台账按 (file, scope, name) 与旧台账合并：**已人工审核的行保留结论**，
  其余行按当前源码重算静态判定。
- 输出前先打印变更摘要（新增/消失/死代码候选），便于分批审核。

用法：
  python3 tools/perf_audit/reindex.py
"""
import csv
import os
import re
import sys
from collections import Counter, defaultdict

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
SRC = os.path.join(ROOT, "apps", "FrsetNext", "Sources")
AUDIT_DIR = os.path.join(ROOT, "docs", "perfaudit")
LEDGER = os.path.join(AUDIT_DIR, "函数性能审计台账.csv")
LIST = os.path.join(AUDIT_DIR, "函数清单-AST抽取.csv")

TYPE_RE = re.compile(
    r"^\s*(?:(?:public|internal|private|fileprivate|open|final|@objc|@MainActor|@available\([^)]*\))\s+)*"
    r"(class|struct|enum|extension|actor|protocol)\s+([A-Za-z_]\w*)"
)
FUNC_RE = re.compile(r"^\s*(.*?)\bfunc\s+([A-Za-z_]\w*)\s*(?:<[^>]*>)?\s*\(")

C_KEYWORDS = {
    "if", "for", "while", "switch", "return", "sizeof", "else", "do", "case",
    "goto", "typeof", "__attribute__", "defined", "while",
}

# 函数体热点 API（子串匹配，宁可多报不漏报）
HOT_RULES = [
    ("timer", ["Timer", "scheduledTimer", "DispatchSourceTimer", "NSTimer", "CFRunLoopTimer"]),
    ("animation", ["NSAnimationContext", "withAnimation", "CABasicAnimation", "CAAnimation", ".animator()", "CADisplayLink"]),
    ("cgImage", ["CGImage", "CGContext", "NSBitmapImageRep", "draw(", "NSGraphicsContext"]),
    ("fileIO", ["FileManager", "Data(contentsOf", "write(to", "NSData(", "contentsOfFile"]),
    ("network", ["URLSession", "NWConnection", "socket(", "getaddrinfo", "CFStream"]),
    ("mainThread", ["DispatchQueue.main", "NSApp", "NSWindow", "NSStatusBar", "NSMenu"]),
    ("screenCapture", ["SCScreenshotManager", "CGWindowListCreateImage", "SCStream", "SCShareableContent"]),
    ("sortFilter", [".sort(", ".sorted(", ".filter(", ".map(", ".reduce("]),
    ("database", ["sqlite3_", "SQLite", "Database."]),
    ("process", ["Process(", "posix_spawn", "proc_listpids", "task_info"]),
    ("iokit", ["IOServiceGetMatchingServices", "IORegistryEntry", "IOConnectCallStructMethod", "IOHID"]),
    ("smc", ["SMCReadKey", "SMCCall", "AppleSMC"]),
    ("json", ["JSONSerialization", "JSONDecoder", "JSONEncoder"]),
    ("regex", ["NSRegularExpression", "Regex(", "range(of:"]),
]


def strip_code(line: str) -> str:
    """去掉行注释与字符串字面量，避免花括号/标识符误计。"""
    out = []
    i = 0
    n = len(line)
    in_str = False
    quote = ""
    while i < n:
        ch = line[i]
        if in_str:
            if ch == "\\":
                i += 2
                continue
            if ch == quote:
                in_str = False
            i += 1
            continue
        if ch in ('"', "'"):
            in_str = True
            quote = ch
            i += 1
            continue
        if ch == "/" and i + 1 < n and line[i + 1] == "/":
            break
        out.append(ch)
        i += 1
    return "".join(out)


def count_top_level_commas(s: str) -> int:
    depth = 0
    commas = 0
    for ch in s:
        if ch in "([{<":
            depth += 1
        elif ch in ")]}>":
            depth -= 1
        elif ch == "," and depth == 0:
            commas += 1
    return commas


def parse_swift(path: str, rel: str):
    lines = open(path, encoding="utf-8", errors="replace").read().splitlines()
    depth = 0
    scopes = []  # [(name, depth_at_open)]
    funcs = []
    consumed_until = -1

    for i, raw in enumerate(lines):
        code = strip_code(raw)

        # 类型作用域入栈（在当前深度上）
        m = TYPE_RE.match(code)
        if m and "func" not in code:
            scopes.append((m.group(2), depth))

        fm = FUNC_RE.match(code)
        if fm and i > consumed_until:
            prefix, name = fm.group(1), fm.group(2)
            # 函数签名可能跨行：向后找 '{' 或 ';'
            sig_lines = [raw]
            j = i
            brace_line = None
            decl_only = False
            while j < len(lines) and j < i + 12:
                probe = strip_code(lines[j])
                if "{" in probe:
                    brace_line = j
                    break
                if ";" in probe and ")" in probe:
                    decl_only = True
                    break
                # 协议要求没有函数体：遇到作用域闭合或下一个声明即收手，
                # 否则会把下一个函数的 `{` 误当成自己的函数体（连带吞掉该函数）
                if j > i and (probe.strip().startswith("}") or re.search(r"\bfunc\s+\w+", probe)):
                    decl_only = True
                    break
                if j > i:
                    sig_lines.append(lines[j])
                j += 1
            if brace_line is not None and not decl_only:
                # 花括号配对找函数结束
                d = 0
                end = brace_line
                started = False
                for k in range(brace_line, len(lines)):
                    c = strip_code(lines[k])
                    for ch in c:
                        if ch == "{":
                            d += 1
                            started = True
                        elif ch == "}":
                            d -= 1
                    if started and d <= 0:
                        end = k
                        break
                consumed_until = end
                sig = " ".join(x.strip() for x in sig_lines)
                sig = re.sub(r"\s+", " ", sig)
                # 参数
                pstart = sig.find("(")
                depth_p = 0
                pend = -1
                for idx in range(pstart, len(sig)):
                    if sig[idx] == "(":
                        depth_p += 1
                    elif sig[idx] == ")":
                        depth_p -= 1
                        if depth_p == 0:
                            pend = idx
                            break
                params = ""
                if pstart >= 0 and pend > pstart:
                    inner = sig[pstart + 1:pend]
                    params = count_top_level_commas(inner) + 1 if inner.strip() else 0
                mods = " ".join(
                    w for w in ["static", "class", "public", "private", "fileprivate",
                                "internal", "open", "override", "mutating", "nonmutating",
                                "@objc", "@MainActor", "async", "throws"]
                    if re.search(r"(?<![\w@])" + re.escape(w) + r"(?![\w])", prefix + " " + sig[:pstart])
                )
                scope = scopes[-1][0] if scopes else ""
                body = "\n".join(lines[i:end + 1])
                funcs.append({
                    "lang": "swift", "file": rel, "scope": scope, "name": name,
                    "start": i + 1, "end": end + 1, "nlines": end - i + 1,
                    "params": str(params), "mods": mods, "sig": sig,
                    "body": body,
                })

        # 深度更新 + 作用域出栈
        depth += code.count("{") - code.count("}")
        while scopes and depth <= scopes[-1][1]:
            scopes.pop()
    return funcs


C_FUNC_RE = re.compile(r"^([A-Za-z_][A-Za-z0-9_ \t\*]*?)\b([A-Za-z_]\w*)\s*\(")


def parse_c(path: str, rel: str, lang: str):
    lines = open(path, encoding="utf-8", errors="replace").read().splitlines()
    funcs = []
    consumed_until = -1
    for i, raw in enumerate(lines):
        if i <= consumed_until:
            continue
        if not raw or raw[0] in " \t#*/}":
            continue
        m = C_FUNC_RE.match(raw)
        if not m:
            continue
        name = m.group(2)
        if name in C_KEYWORDS:
            continue
        # 找函数体起点；遇到 ';' 先到 → 声明，跳过
        j = i
        brace_line = None
        decl = False
        while j < len(lines) and j < i + 8:
            probe = strip_code(lines[j])
            if "{" in probe:
                brace_line = j
                break
            if ";" in probe:
                decl = True
                break
            j += 1
        if decl or brace_line is None:
            continue
        d = 0
        end = brace_line
        started = False
        for k in range(brace_line, len(lines)):
            c = strip_code(lines[k])
            for ch in c:
                if ch == "{":
                    d += 1
                    started = True
                elif ch == "}":
                    d -= 1
            if started and d <= 0:
                end = k
                break
        consumed_until = end
        sig = " ".join(x.strip() for x in lines[i:brace_line + 1])
        sig = re.sub(r"\s+", " ", sig)
        params = ""
        pstart = sig.find("(")
        pend = sig.find(")", pstart)
        if pstart >= 0 and pend > pstart:
            inner = sig[pstart + 1:pend]
            params = count_top_level_commas(inner) + 1 if inner.strip() else 0
        mods = "static" if raw.lstrip().startswith("static") else ""
        funcs.append({
            "lang": lang, "file": rel, "scope": "", "name": name,
            "start": i + 1, "end": end + 1, "nlines": end - i + 1,
            "params": str(params), "mods": mods, "sig": sig,
            "body": "\n".join(lines[i:end + 1]),
        })
    return funcs


def hot_apis(body: str):
    found = []
    for tag, keys in HOT_RULES:
        if any(k in body for k in keys):
            found.append(tag)
    # 循环判定：for/while/repeat 关键字（粗判）
    has_loop = bool(re.search(r"\b(for|while|repeat)\b", body))
    return ",".join(found), has_loop


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

    all_text = {}
    for p, _ in files:
        all_text[os.path.relpath(p, SRC)] = open(p, encoding="utf-8", errors="replace").read()

    funcs = []
    for p, lang in files:
        rel = os.path.relpath(p, SRC)
        if lang == "swift":
            funcs.extend(parse_swift(p, rel))
        else:
            funcs.extend(parse_c(p, rel, lang))

    # 引用计数（全仓源码，含 C 头文件在 Sources 内）
    name_total = Counter()
    ident = re.compile(r"\b[A-Za-z_]\w*\b")
    for rel, text in all_text.items():
        for name in ident.findall(text):
            name_total[name] += 1

    # 旧台账合并
    old = {}
    old_ids = []
    if os.path.exists(LEDGER):
        for row in csv.DictReader(open(LEDGER, encoding="utf-8")):
            old[(row["file"], row["scope"], row["name"])] = row
            old_ids.append(row["id"])
    max_id = max([int(x[1:]) for x in old_ids if x.startswith("F") and x[1:].isdigit()] or [0])

    rows = []
    removed_keys = []
    seen = set()
    for f in funcs:
        key = (f["file"], f["scope"], f["name"])
        if key in seen:
            continue  # 同一作用域重载/重名：只记首个（台账粒度）
        seen.add(key)
        refs = max(0, name_total.get(f["name"], 1) - 1)
        hot, loop = hot_apis(f["body"])
        prev = old.get(key)
        if prev:
            fid = prev["id"]
            status = prev.get("analysis_status") or "static"
            verdict = prev.get("verdict") or ""
            cost = prev.get("cost_est") or ""
            notes = prev.get("notes") or ""
            is_entry = prev.get("is_entry") or ""
            dead_cand = prev.get("dead_candidate") or ""
            if status == "static":
                # 未审核行：按当前源码重算静态判定
                dead_cand = "Y" if (refs == 0 and not is_entry) else ""
                verdict = "dead_suspect" if dead_cand else ("review" if len(hot.split(",")) >= 5 else "normal")
                cost = "high" if f["nlines"] > 80 and len(hot.split(",")) >= 4 else ("medium" if len(hot.split(",")) >= 3 else "low")
                notes = "静态判定：热点=" + (hot or "无") + ("；零引用" if dead_cand else "")
        else:
            max_id += 1
            fid = f"F{max_id:04d}"
            is_entry = ""
            dead_cand = "Y" if refs == 0 else ""
            verdict = "dead_suspect" if dead_cand else ("review" if len(hot.split(",")) >= 5 else "normal")
            cost = "high" if f["nlines"] > 80 and len(hot.split(",")) >= 4 else ("medium" if len(hot.split(",")) >= 3 else "low")
            notes = "静态判定：热点=" + (hot or "无") + ("；零引用" if dead_cand else "")
        rows.append({
            "id": fid, "lang": f["lang"], "file": f["file"], "scope": f["scope"],
            "name": f["name"], "start": f["start"], "end": f["end"], "nlines": f["nlines"],
            "static_refs": refs, "is_entry": is_entry or "", "async": "Y" if "async" in f["mods"] else "",
            "has_loop": "Y" if loop else "", "dead_candidate": dead_cand or "",
            "hot_apis": hot, "mods": f["mods"], "sig": f["sig"],
            "analysis_status": status if prev else "static",
            "verdict": verdict, "cost_est": cost or "low", "notes": notes,
        })

    for key in old:
        if key not in seen:
            removed_keys.append(key)

    # 写清单
    with open(LIST, "w", encoding="utf-8", newline="") as fh:
        w = csv.DictWriter(fh, fieldnames=["lang", "file", "scope", "name", "start", "end",
                                           "nlines", "params", "mods", "sig"])
        w.writeheader()
        for f in funcs:
            w.writerow({k: f[k] for k in w.fieldnames})

    # 写台账
    cols = ["id", "lang", "file", "scope", "name", "start", "end", "nlines", "static_refs",
            "is_entry", "async", "has_loop", "dead_candidate", "hot_apis", "mods", "sig",
            "analysis_status", "verdict", "cost_est", "notes"]
    rows.sort(key=lambda r: (r["file"], int(r["start"])))
    with open(LEDGER, "w", encoding="utf-8", newline="") as fh:
        w = csv.DictWriter(fh, fieldnames=cols)
        w.writeheader()
        for r in rows:
            w.writerow({k: r[k] for k in cols})

    # 摘要
    print(f"函数总数: {len(rows)}  (swift={sum(1 for r in rows if r['lang']=='swift')} "
          f"objc={sum(1 for r in rows if r['lang']=='objc')} c={sum(1 for r in rows if r['lang']=='c')})")
    print(f"已人工审核保留: {sum(1 for r in rows if r['analysis_status']=='manual')}")
    print(f"死代码候选(零引用): {sum(1 for r in rows if r['dead_candidate']=='Y')}")
    print(f"旧台账有、当前无: {len(removed_keys)}")
    for k in removed_keys[:20]:
        print("  消失:", k[0], k[1] + "." + k[2] if k[1] else k[2])


if __name__ == "__main__":
    main()
