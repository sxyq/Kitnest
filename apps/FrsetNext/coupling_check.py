#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Kitnest 合规扫描（只报告，绝不修改任何源码）

检查四项：
  A. 跨模块耦合：Features/<模块A>/ 下的文件是否直接引用了 Features/<模块B>/ 里定义的类型
     （契约 §1.3：模块之间禁止直接引用彼此具体类型，一律走 Registry / ServiceLocator）
  B. 类型名冲突：两个模块定义了同名 public 类型（全量编译时会导致 invalid redeclaration）
  C. AppModule 清单：每个模块是否提供 AppModule 实现 + identifier（与 App 层 register 列表对账）
  D. 事件总线 / Hook 注册表的实际签名（与 App/AppBootstrap.swift 的接线对账）

输出：apps/FrsetNext/build/coupling-report.txt
"""

from __future__ import annotations

import datetime
import os
import re
from collections import defaultdict

ROOT = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(ROOT, "Sources")
FEATURES = os.path.join(SRC, "Features")
SHARED = [os.path.join(SRC, d) for d in ("Core", "Models", "Storage")]
OUT = os.path.join(ROOT, "build")
REPORT = os.path.join(OUT, "coupling-report.txt")

# 通用名/系统名，不作为"某模块私有类型"处理
NOISE_NAMES = {
    "Notification", "Preferences", "Entry", "Item", "Store", "Service", "Manager",
    "View", "Cell", "Row", "State", "Result", "Error", "Kind", "Mode", "Key",
}

DECL_RE = re.compile(
    r"^[ \t]*(?:public\s+|internal\s+|private\s+|fileprivate\s+|open\s+|final\s+|indirect\s+)*"
    r"(?:final\s+)?(class|struct|enum|protocol|actor|typealias)\s+([A-Z][A-Za-z0-9_]*)",
    re.MULTILINE,
)
EXT_RE = re.compile(
    r"^[ \t]*(?:public\s+|internal\s+|private\s+|fileprivate\s+)?extension\s+([A-Z][A-Za-z0-9_]*)",
    re.MULTILINE,
)
APPMODULE_RE = re.compile(
    r"(?:public\s+|internal\s+)?(?:final\s+)?(enum|struct|class)\s+([A-Za-z0-9_]+)\s*:\s*[^{]*\bAppModule\b"
)
IDENT_RE = re.compile(
    r"identifier\s*(?::\s*String\s*)?(?:=\s*\"([^\"]+)\"|\{\s*\"([^\"]+)\"\s*\})"
)
BUS_TYPE_RE = re.compile(r"(?:EventBus|HookRegistry|Registry|EventCenter)$")
BUS_VAR_RE = re.compile(
    r"^[ \t]*(?:public\s+|internal\s+|static\s+)+var\s+([A-Za-z0-9_]+)\s*:\s*([^\n=]+?)?\s*$",
    re.MULTILINE,
)


def read_code(path: str) -> str:
    """去注释 + 清空字符串内容（用于类型引用扫描，避免字符串里的名字造成误报）"""
    with open(path, "r", encoding="utf-8", errors="replace") as handle:
        return strip_noise(handle.read(), keep_strings=False)


def read_code_keep_strings(path: str) -> str:
    """去注释但保留字符串内容（用于提取 identifier 字面量）"""
    with open(path, "r", encoding="utf-8", errors="replace") as handle:
        return strip_noise(handle.read(), keep_strings=True)


def strip_noise(text: str, keep_strings: bool = False) -> str:
    """移除注释与字符串字面量，降低误报。

    只按"行首是否为注释"来删整行，不做引号配对（中文注释里常出现不成对的
    直角引号/单引号，会导致误吞后续代码）。字符串内容整体丢弃。
    """
    out: list[str] = []
    in_block = False
    for line in text.split("\n"):
        if in_block:
            if "*/" in line:
                in_block = False
                line = line.split("*/", 1)[1]
            else:
                continue
        stripped = line.lstrip()
        if stripped.startswith("//"):
            continue
        if stripped.startswith("/*"):
            if "*/" not in stripped:
                in_block = True
            continue
        if "/*" in line and "*/" in line:  # 单行块注释
            line = re.sub(r"/\*.*?\*/", "", line)
        if keep_strings:
            out.append(line)
        else:
            # 保留字符串字面量的"壳"，内容清空（避免字符串里的名字造成误报）
            out.append(re.sub(r'"(?:\\.|[^"\\])*"', lambda m: '"' + "x" * max(0, len(m.group(0)) - 2) + '"', line))
    return "\n".join(out)


def swift_files(root: str) -> list[str]:
    result = []
    if not os.path.isdir(root):
        return result
    for dirpath, _, filenames in os.walk(root):
        for name in filenames:
            if name.endswith(".swift"):
                result.append(os.path.join(dirpath, name))
    return sorted(result)


_STR_RE = re.compile(r'"(?:[^"\\\n]|\\.)*"' + r"|'(?:[^'\\\n]|\\.)*'", re.S)

def strip_comments_and_strings(code: str) -> str:
    """把注释与字符串字面量替换为等长空格（保留换行），使类型名扫描不被
    「注释里提到某类型」或「字符串里含某类型名」污染。

    本轮第三类误报：StatisticsSettingsPane.swift:433 的偏好键白名单里有
    `"clipboard.autoPaste",  // ClipboardManager.swift 的 Keys 扩展`
    —— 扫描器把注释与字符串里的标识符当成了跨模块类型引用。
    保留换行与列宽，故行号与列号在过滤前后完全一致，报错定位不受影响。
    """
    def repl(m: re.Match) -> str:
        return re.sub(r"[^\n]", " ", m.group(0))
    out = re.sub(r"/\*.*?\*/", repl, code, flags=re.S)      # 块注释
    out = re.sub(r"//[^\n]*", repl, out)                    # 行注释
    out = _STR_RE.sub(repl, out)                             # 字符串字面量
    return out

def declared_types(code: str) -> set[str]:
    """本模块**定义**的类型名（class/struct/enum/protocol/actor/typealias）。

    注意：**不含 extension 扩展的类型名**。`extension String {}` 出现在 Clipboard 与 Panel
    并不表示「String 属于这两个模块」——扩展只是给已有类型加成员，跨模块各扩展各的系统类型
    是完全合法的。此前把 EXT_RE 的结果也算进模块类型表，导致两类长期误报：
    ①B 段报「String 同时定义于 Clipboard, Panel」（全量编译实际通过）；
    ②A 段报「Capture 的 NSTextView 被 Clipboard/Panel 引用」（NSTextView 是 AppKit 系统类型）。
    这两类误报反复出现在每轮收尾，引发重复争论，故在此从源头剔除。
    """
    return {m.group(2) for m in DECL_RE.finditer(code)}


def main() -> int:
    os.makedirs(OUT, exist_ok=True)
    L: list[str] = []

    modules: dict[str, list[str]] = {}
    if os.path.isdir(FEATURES):
        for name in sorted(os.listdir(FEATURES)):
            path = os.path.join(FEATURES, name)
            if os.path.isdir(path):
                modules[name] = swift_files(path)

    file_code: dict[str, str] = {}
    module_types: dict[str, set[str]] = defaultdict(set)
    for module, files in modules.items():
        for path in files:
            code = read_code(path)
            file_code[path] = code
            module_types[module] |= declared_types(code)

    shared_types: set[str] = set()
    for root in SHARED:
        for path in swift_files(root):
            shared_types |= declared_types(read_code(path))

    type_owners: dict[str, set[str]] = defaultdict(set)
    for module, names in module_types.items():
        for name in names:
            type_owners[name].add(module)

    # ---------- B. 类型名冲突 ----------
    collisions = {
        name: sorted(owners)
        for name, owners in type_owners.items()
        if len(owners) > 1 and name not in NOISE_NAMES and len(name) >= 6
    }

    # ---------- A. 跨模块引用 ----------
    findings: dict[tuple[str, str, str], list[tuple[int, str]]] = defaultdict(list)
    total = 0
    for module, files in modules.items():
        for path in files:
            code = strip_comments_and_strings(file_code[path])
            with open(path, "r", encoding="utf-8", errors="replace") as handle:
                raw = strip_comments_and_strings(handle.read()).split("\n")
            for owner, names in module_types.items():
                if owner == module:
                    continue
                for name in names:
                    if name in NOISE_NAMES or name in shared_types or len(name) < 6:
                        continue
                    if len(type_owners[name]) > 1:      # 重名，另在 B 段报告
                        continue
                    if name in declared_types(code):    # 本文件自己声明的同名类型
                        continue
                    for index, line in enumerate(code.split("\n"), start=1):
                        if re.search(r"\b" + re.escape(name) + r"\b", line):
                            snippet = raw[index - 1].strip() if index - 1 < len(raw) else ""
                            findings[(owner, name, path)].append((index, snippet))
                            total += 1

    # ---------- C. AppModule 清单 ----------
    appmodules: list[tuple[str, str, str, int]] = []
    for module, files in modules.items():
        for path in files:
            code = file_code[path]
            for m in APPMODULE_RE.finditer(code):
                line_no = code[: m.start()].count("\n") + 1
                raw_code = read_code_keep_strings(path)
                im = IDENT_RE.search(raw_code[m.end(): m.end() + 1500])
                ident = (im.group(1) or im.group(2)) if im else "?"
                appmodules.append((module, m.group(2), ident, line_no))

    # ---------- D. 事件总线签名 ----------
    bus_defs: list[str] = []
    for root in [FEATURES] + SHARED:
        for path in swift_files(root):
            code = read_code(path)
            rel = os.path.relpath(path, SRC)
            for m in re.finditer(
                r"^[ \t]*(?:public\s+|internal\s+)?(?:final\s+)?(enum|struct|class)\s+([A-Za-z0-9_]*(?:EventBus|HookRegistry))[A-Za-z0-9_]*",
                code,
                re.MULTILINE,
            ):
                line_no = code[: m.start()].count("\n") + 1
                bus_defs.append(f"  {rel}:{line_no}  {m.group(1)} {m.group(2)}")
            for m in BUS_VAR_RE.finditer(code):
                if m.group(1) not in {"onImageCaptured", "onTextRecognized", "onResultProduced", "handlers"}:
                    continue
                line_no = code[: m.start()].count("\n") + 1
                bus_defs.append(f"      ↳ {m.group(1)}: {m.group(2).strip()}")

    # ---------- 报告 ----------
    L.append("Kitnest 合规扫描报告（只检查，不修改源码）")
    L.append(f"生成时间: {datetime.datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")
    L.append(f"扫描范围: {os.path.relpath(FEATURES, ROOT)}（{len(modules)} 个模块）")
    L.append("=" * 74)

    L.append("")
    L.append("【A】跨模块直接引用（契约 §1.3 禁止）")
    L.append("-" * 74)
    if not findings:
        L.append("  ✅ 未发现跨模块类型引用（已排除 Core/Models/Storage 共享层与同名本地类型）。")
    else:
        for (owner, name, path), hits in sorted(findings.items()):
            L.append(f"  ⚠️ [{owner}] {name}  被 {os.path.relpath(path, SRC)} 引用 {len(hits)} 处：")
            for line_no, snippet in hits[:6]:
                L.append(f"        :{line_no}  {snippet[:110]}")
            if len(hits) > 6:
                L.append(f"        … 另有 {len(hits) - 6} 处")
        L.append("")
        L.append(f"  合计：{total} 处疑似违规引用")

    L.append("")
    L.append("【B】跨模块类型重名（全量编译会 invalid redeclaration）")
    L.append("-" * 74)
    if not collisions:
        L.append("  ✅ 未发现跨模块类型重名。")
    else:
        for name, owners in sorted(collisions.items()):
            L.append(f"  ❌ {name}  同时定义于：{', '.join(owners)}")
            for owner in owners:
                for path in modules.get(owner, []):
                    code = file_code[path]
                    if name in declared_types(code):
                        line_no = next(
                            (code[: m.start()].count("\n") + 1
                             for m in DECL_RE.finditer(code) if m.group(2) == name),
                            0,
                        )
                        L.append(f"        {os.path.relpath(path, SRC)}:{line_no}")

    L.append("")
    L.append("【C】AppModule 实现清单（对账 App/AppBootstrap.swift 的 register 列表）")
    L.append("-" * 74)
    if not appmodules:
        L.append("  ⚠️ 未发现任何 AppModule 实现。")
    else:
        for module, type_name, identifier, line_no in sorted(appmodules):
            L.append(f"  {module:<12} {type_name:<22} identifier=\"{identifier}\"   (: {line_no})")
        L.append("")
        L.append("  identifier 列表：" + ", ".join(sorted({i for _, _, i, _ in appmodules})))
    missing = sorted(set(modules) - {m for m, _, _, _ in appmodules})
    if missing:
        L.append("")
        L.append("  ❌ 以下模块目录没有 AppModule 实现：" + ", ".join(missing))

    L.append("")
    L.append("【D】事件总线 / Hook 注册表定义（与 App 层接线比对）")
    L.append("-" * 74)
    L.extend(bus_defs if bus_defs else ["  （未发现）"])

    content = "\n".join(L) + "\n"
    with open(REPORT, "w", encoding="utf-8") as handle:
        handle.write(content)
    print(content)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
