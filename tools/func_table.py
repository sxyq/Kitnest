#!/usr/bin/env python3
"""生成/刷新「函数清单」CSV（v210 重写）。

为什么重写
----------
旧表两个硬伤（2026-11-04 逐条核对，6940 行）：
  1) owner 列 739 条（26.2%）归属错误——生成器用扁平正则扫类型声明、不跟花括号深度，
     一个文件里出现嵌套 struct 之后，后面所有类级函数都被挂到那个内层 struct 上
     （例：MonitorSampler.start 记成 Buffers.start；AppBootstrap 的热键函数记成
     DefaultHotkeyEntry.*）。
  2) 行号不跟源码走：改过代码不重跑，就有 133 条对不上（集中在最近改过的 6 个文件）。

本脚本的做法
------------
* 逐行扫描，维护「花括号深度 + 类型栈」——类型的归属 = 当前仍处在其作用域内的最内层类型；
* 函数/初始化器按签名定位起点，再扫到配对右括号算行数与复杂度；
* 属性（let/var）同样记 owner，但 `kind` 区分开，便于只看函数时过滤。

列的语义
--------
module      Features/<X> → X；Core/App/Storage/Models/... 按目录名
file        相对 apps/FrsetNext/Sources
owner       真实所属类型（顶层声明为 "-"）
kind        func / init / deinit / var / let / class / struct / enum / protocol / extension
name        声明名
line        声明起始行（1-based）
lines       函数体行数（含签名与结尾大括号；属性为 0）
complexity  1 + if/guard/for/while/repeat/case/catch/&&/||/? 的粗计（同旧表口径的近似值）
feature_id  功能归属 ID（2026-11-23 增）——按 docs/00-总览/源码与文档映射.csv 自动填入，
            匹配优先级 override_symbol > override_file > 最长 source_prefix；未命中填「未映射」
doc_path    该归属的主要实现文档（2026-11-23 增，仓库相对路径）；未命中填「未映射」，不生成假链接

用法
----
    python3 tools/func_table.py            # 写回默认 CSV
    python3 tools/func_table.py --check    # 只统计，不写文件（CI/提交前自检）
"""
from __future__ import annotations

import argparse
import csv
import os
import re
import sys
from collections import Counter

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, "apps", "FrsetNext", "Sources")
OUT = os.path.join(ROOT, "docs", "00-总览", "数据表", "FrsetNext-函数清单.csv")

# 性能热点标注（2026-11-24 v292 全链路实测）——写入 CSV 的 perf_priority 列。
# 分级：P0=实测证实为关键路径大头；P1=有实测证据的次热点/待优化；P2=已加计时或已修待复测。
# key = (file, owner, name)。CSV 只有 file#owner#name 粒度，重载共用同一标注。
# 数据出处：2026-11-24 授权实测（岛 163ms 定位 / 截图 92-257ms / 归档 0.16s 引擎 /
# 主面板 77ms / 内存 81-151MB），详见 docs/40-修改记录 对模块记录与当轮实测报告。
PERF_HOTSPOTS = {
    # ---- P0：实测证实的关键路径大头 ----
    ("Features/Island/IslandController.swift", "IslandController", "position"):
        "P0 岛展开定位：冷 163ms / 热 12-60ms，占开窗 75-94%（setFrame display:true 同步重绘；CA 提交+WindowServer）",
    ("Features/Capture/Screenshot/ScreenSnapshot.swift", "ScreenSnapshot", "captureScreenForScreenshot"):
        "P0 截图抓帧：子任务 141-214ms，决定首块覆盖层 119-164ms（通道选择+probe+画面对照）",
    ("Features/Capture/Screenshot/NativeRegionCapture.swift", "NativeRegionCapture", "run"):
        "P0 screencapture 子进程：空闲 71-149ms / 8 核满载 92-257ms（14.1MB BMP，读取 ~1ms、解码 0.1ms）",
    ("Features/Archive/UI/ArchiveBrowserWindow.swift", "ArchiveBrowserModel", "visibleEntries"):
        "P0 每次 body 求值入口：v292 已消除空搜索白算 O(N)（1万 7.7ms→<0.001ms，10万 77ms→<0.001ms），保持",
    # ---- P1：有实测证据的次热点/待优化 ----
    ("Features/Panel/Presentation/PanelController.swift", "PanelController", "show"):
        "P1 主面板开：主线程 77ms 首开/42ms 复开（快照 29+落位 19+帧构建 15+上屏 14）",
    ("Core/Motion/GenieWarp.swift", "GenieWarp", "play"):
        "P1 神灯播放：384ms/23-24 帧 60fps 零缺失；帧构建 15-47ms 是主线程最大单项",
    ("Features/Archive/UI/ArchiveBrowserWindow.swift", "ArchiveBrowserModel", "reload"):
        "P1 归档索引 UI 侧：v292 已加首批/发布次数/rebuild 计时，10k 条待复测（引擎 0.16s）",
    ("Features/Archive/Core/ArchiveCore.swift", "ArchiveCore", "listStreaming"):
        "P1 渐进索引引擎：10k 条 7zz 0.10-0.28s；v292 已加首批/完整/发布次数计时，待复测 UI 解析占比",
    ("Features/Clipboard/Store/ClipboardFileStorages.swift", "ClipboardImageStorage", "store"):
        "P1 图片入库重编码：42.1MB TIFF→HEIC 0.90 0.3MB/219ms（持久化串行队列，不阻塞主线程）；历史 TIFF 不回溯",
    ("Features/Clipboard/Store/ClipboardManager.swift", "ClipboardManager", "writeToDatabase"):
        "P1 入库落盘主路径（persist 串行队列）：图片编码/富文本写盘/去重判定；大图单次 219ms 级别",
    ("Features/Clipboard/Store/ClipboardManager.swift", "ClipboardManager", "reload"):
        "P1 三栏工作台列表刷新（fetch+截断 800 条）：滚动/搜索场景待实测",
    ("Features/FloatingBall/DesktopPetView.swift", "DesktopPetView", "petContent"):
        "P1 桌面精灵 3fps 动画时钟：v288 已加 path+mtime 图片缓存；静态/轻动/自定义三态 CPU 待实测",
    ("Features/Capture/Screenshot/ScreenshotManager.swift", "ScreenshotManager", "beginCapture"):
        "P1 截图编排：首块覆盖层 119-164ms（双屏第二块 +66-70ms），v292 已加全链分段计时",
    ("Features/Archive/Table/ArchiveEntryTable.swift", "ArchiveEntryTableRepresentable", "updateNSView"):
        "P1 归档表格行更新：万条滚动/选中刷新路径，待实测",
    ("Features/Island/IslandSurface.swift", "IslandMaterialHost", "updateNSView"):
        "P1 岛材质宿主逐帧回调：surfaceDidChange→updatePointer；layout p95 0.048ms 已低，观察每帧指针判定",
    # ---- P2：已加计时/已修的观察项 ----
    ("Features/Capture/Screenshot/ScreenshotManager.swift", "ScreenshotManager", "streamScreenSnapshots"):
        "P2 v292 已加子任务/主线程回调/流开始三段计时 + 取消传播修复；待满载复测",
    ("Features/Capture/Screenshot/ScreenshotManager.swift", "ScreenshotManager", "presentOverlay"):
        "P2 四段计时：建窗 2-13ms/状态 0/激活 0-1ms/orderFront 0-1ms（上屏非瓶颈）",
    ("Features/Island/IslandController.swift", "IslandController", "beginSelectionRefresh"):
        "P2 v292 选区异步：0-9ms 后台完成，不再阻塞开窗",
    ("Features/Island/IslandController.swift", "IslandController", "refreshClipboard"):
        "P2 v292 复用 ClipboardManager.items 内存快照（默认过滤态），消除展开时 SQLite 查询",
    ("Features/Island/IslandController.swift", "IslandController", "refreshEntries"):
        "P2 v292 入口窗状态去重（EntryWindowState），消除重复 setFrame/order 往返",
    ("Features/Island/IslandSurface.swift", "IslandMaterialView", "applyGeometry"):
        "P2 取样面更新计数（非对象重建）；layout p50 0.008ms/p95 0.053ms 已低，probe.islandMaterial 开关控制",
}
MAP_CSV = os.path.join(ROOT, "docs", "00-总览", "源码与文档映射.csv")

MODULE_DIRS = {
    "Core": "Core", "App": "App", "Storage": "Storage", "Models": "Models",
    "MemoryHelper": "MemoryHelper", "OCRHelper": "OCRHelper",
}

# 声明前缀修饰符（三个正则共用）。
#
# v261：漏一个修饰符就会**整类声明静默漏记**，且不报错、只能靠台账对账发现。
# 实测：`nonisolated private static func` 里的 nonisolated 不在旧白名单，
# ProcessFreezer.visibleWindowPIDs / collectCandidates / isProtected 三个函数
# 从 v260 起一直不在表里，台账重建时才暴露（表现为「源码已无此函数」的误判）。
# 所以这里抽成共享常量：新修饰符只改一处，三个正则同时生效。
_DECL_MODIFIER = (
    r"(?:public|private|internal|fileprivate|open|package|final|indirect|static|"
    r"dynamic|distributed|optional|mutating|nonmutating|override|required|"
    r"convenience|lazy|weak|unowned|readonly|nonisolated(?:\([^)]*\))?)"
)
_MODS = rf"(?:(?:@\w+(?:\([^)]*\))?|{_DECL_MODIFIER})\s+)*"
# `class func` 的 class 是修饰符，但它在 TYPE_RE 里是关键字——只能给 FUNC_RE 单独补。
_MODS_FUNC = rf"(?:(?:@\w+(?:\([^)]*\))?|{_DECL_MODIFIER}|class)\s+)*"

TYPE_RE = re.compile(
    rf"^\s*{_MODS}"
    r"(class|struct|enum|extension|protocol|actor)\s+([A-Za-z_][A-Za-z0-9_]*)"
)
FUNC_RE = re.compile(
    rf"^\s*{_MODS_FUNC}"
    # v241：`\b` 必须加——否则 "function" 会被 `func` 命中、把 "tion" 当成函数名
    #（CodeTheme.swift 的 "function" 键曾凭空生成 14 条假函数行）
    r"(func|init|deinit|subscript)\b\s*!?\s*([A-Za-z_][A-Za-z0-9_]*)?"
)
PROP_RE = re.compile(
    rf"^\s*{_MODS}"
    r"(let|var)\s+([A-Za-z_][A-Za-z0-9_]*)"
)

BRANCH_WORDS = ("if ", "guard ", "for ", "while ", "repeat ", "case ", "catch ", "&&", "||", " ? ")


def strip_line(line: str, state: dict) -> tuple[str, dict]:
    """去掉注释与字符串字面量，返回 (可计大括号的代码, 跨行状态)。

    v259（2026-11-07）：旧版是**逐行无状态**正则，两个硬伤都出在这里——
      1) 三引号多行字符串不识别，里面的内容被当代码计括号。实测
         `ClipboardRepository.columns` 的 SQL 里有一行 `OR content LIKE '%{%'`，
         那个 `{` 让 `appendClauses` 的括号深度永久 +1，体扫描一路吞到文件尾
         （记成 319 行，实际 59 行），把后面 fetch/count/insert/delete 等
         16 条声明整体漏掉。
      2) 块注释 `/* … */` 不识别，注释里的括号同样污染深度。
    现在按字符扫描并携带状态：块注释、多行字符串跨行续用，单行字符串整体折叠。
    """
    out = []
    i, n = 0, len(line)
    while i < n:
        if state["block"]:
            j = line.find("*/", i)
            if j < 0:
                return "".join(out), state
            state["block"] = False
            i = j + 2
            continue
        if state["str3"]:
            j = line.find('"""', i)
            if j < 0:
                return "".join(out), state
            state["str3"] = False
            i = j + 3
            continue
        ch = line[i]
        if ch == "/" and line.startswith("//", i):
            break
        if ch == "/" and line.startswith("/*", i):
            state["block"] = True
            i += 2
            continue
        if line.startswith('"""', i):
            state["str3"] = True
            i += 3
            continue
        if ch == '"':
            # 单行字符串（含 #"…"# 原始串）：整体折叠，内部括号不计
            i += 1
            while i < n:
                if line[i] == "\\":
                    i += 2
                    continue
                if line[i] == '"':
                    i += 1
                    break
                i += 1
            out.append('""')
            continue
        out.append(ch)
        i += 1
    return "".join(out), state


def strip_codes(lines: list[str]) -> list[str]:
    """把整份文件按 strip_line 预处理成「可计括号」的代码行。"""
    state = {"block": False, "str3": False}
    codes = []
    for raw in lines:
        code, state = strip_line(raw, state)
        codes.append(code)
    return codes


def module_of(rel: str) -> str:
    parts = rel.split(os.sep)
    if len(parts) >= 2 and parts[0] == "Features":
        return parts[1]
    return MODULE_DIRS.get(parts[0], parts[0])


def load_mapping(path: str = MAP_CSV):
    """读「源码与文档映射.csv」→ (符号覆盖, 文件覆盖, 前缀规则)。

    2026-11-23：函数 CSV 增 feature_id/doc_path 两列，归属由本映射唯一决定。
    匹配优先级：override_symbol（file#owner#name 三元组，覆盖同名重载整族）
    > override_file（整文件）> 最长 source_prefix（目录前缀）。
    声明的 owner/name 参与三元组，避免单纯按函数名建不可靠对应。
    """
    sym_rules: dict[str, tuple[str, str]] = {}
    file_rules: dict[str, tuple[str, str]] = {}
    prefix_rules: list[tuple[str, str, str]] = []
    if not os.path.exists(path):
        print("警告：缺映射表", os.path.relpath(path, ROOT), "——feature_id/doc_path 全部记未映射")
        return sym_rules, file_rules, prefix_rules
    with open(path, encoding="utf-8-sig") as fh:
        for r in csv.DictReader(fh):
            fid = (r.get("feature_id") or "").strip()
            doc = (r.get("doc_path") or "").strip()
            if not fid or not doc:
                continue
            sym = (r.get("override_symbol") or "").strip()
            fl = (r.get("override_file") or "").strip()
            pre = (r.get("source_prefix") or "").strip()
            if sym:
                sym_rules[sym] = (fid, doc)
            if fl:
                file_rules[fl] = (fid, doc)
            if pre:
                prefix_rules.append((pre, fid, doc))
    prefix_rules.sort(key=lambda x: -len(x[0]))  # 最长前缀优先
    return sym_rules, file_rules, prefix_rules


def map_decl(rel_file: str, owner: str, name: str, rules) -> tuple[str, str]:
    """给一条声明填 (feature_id, doc_path)。未命中显式返回「未映射」。"""
    sym_rules, file_rules, prefix_rules = rules
    full = ("apps/FrsetNext/Sources/" + rel_file.replace(os.sep, "/"))
    key = f"{full}#{owner}#{name}"
    if key in sym_rules:
        return sym_rules[key]
    if full in file_rules:
        return file_rules[full]
    for pre, fid, doc in prefix_rules:
        if full.startswith(pre):
            return (fid, doc)
    return ("未映射", "未映射")


def scan_file(path: str, rel: str):
    with open(path, encoding="utf-8", errors="replace") as fh:
        lines = fh.read().splitlines()

    codes = strip_codes(lines)   # v259：整份文件先做带状态剥离，跨行字符串/块注释不在括号上留残渣
    rows = []
    # 栈元素：(类型名, 进入时的深度)
    stack: list[tuple[str, int]] = []
    depth = 0
    i = 0
    n = len(lines)

    while i < n:
        code = codes[i]

        mtype = TYPE_RE.match(code)
        if mtype:
            name = mtype.group(2)
            # 类型声明只用于「归属栈」，不进表（表口径 = 函数 + 属性，与旧表一致）
            stack.append((name, depth))
            depth += code.count("{") - code.count("}")
            while stack and depth <= stack[-1][1]:
                stack.pop()
            i += 1
            continue

        mfun = FUNC_RE.match(code)
        if mfun:
            kind = mfun.group(1)
            name = mfun.group(2) or ("init" if kind == "init" else kind)
            start = i
            # 签名可能跨行：一路扫到出现 '{'（或声明以 '}' 结尾的协议要求）
            j = i
            body_depth = None
            while j < n:
                c = codes[j]
                opens, closes = c.count("{"), c.count("}")
                if body_depth is None:
                    if opens > 0:
                        body_depth = 0
                        body_depth += opens - closes
                        if body_depth <= 0:
                            break
                    elif c.rstrip().endswith("}"):
                        break
                else:
                    body_depth += opens - closes
                    if body_depth <= 0:
                        break
                j += 1
            body_lines = codes[start:j + 1]
            complexity = 1
            for bc in body_lines:
                complexity += sum(bc.count(w) for w in BRANCH_WORDS)
            rows.append({
                "module": module_of(rel), "file": rel, "owner": stack[-1][0] if stack else "-",
                "kind": "func" if kind == "func" else kind,
                "name": name, "line": start + 1, "lines": len(body_lines), "complexity": complexity,
            })
            # 跳过函数体，避免把体内嵌套闭包/局部声明记成成员
            if body_depth is not None and j > start:
                depth += sum(codes[k].count("{") - codes[k].count("}")
                             for k in range(start, j + 1))
                while stack and depth <= stack[-1][1]:
                    stack.pop()
                i = j + 1
                continue
            i += 1
            continue

        mprop = PROP_RE.match(code)
        if mprop and not code.rstrip().endswith("("):
            start = i
            rows.append({
                "module": module_of(rel), "file": rel, "owner": stack[-1][0] if stack else "-",
                "kind": mprop.group(1), "name": mprop.group(2),
                "line": i + 1, "lines": 0, "complexity": 1,
            })
            # v259：计算属性 / 观察器 / `= { … }()` 初始化闭包也要跳体。
            # 旧版只记属性、不跳体，于是 getter 里的 `let opacity` / 闭包里的
            # `let df` 全被当成类型成员记了一行（实测 478 条，占属性行 8.6%，
            # 例：Theme.opacity 实际是 windowSurface 的局部量）。
            opens, closes = code.count("{"), code.count("}")
            if opens > closes:
                body_depth = opens - closes
                j = i + 1
                while j < n:
                    body_depth += codes[j].count("{") - codes[j].count("}")
                    if body_depth <= 0:
                        break
                    j += 1
                depth += sum(codes[k].count("{") - codes[k].count("}")
                             for k in range(start, j + 1))
                while stack and depth <= stack[-1][1]:
                    stack.pop()
                i = j + 1
                continue

        depth += code.count("{") - code.count("}")
        while stack and depth <= stack[-1][1]:
            stack.pop()
        i += 1

    return rows


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true", help="只统计不写文件")
    ap.add_argument("--out", default=OUT)
    args = ap.parse_args()

    all_rows = []
    files = 0
    for base, _dirs, names in os.walk(SRC):
        for name in sorted(names):
            if name.startswith("._") or not name.endswith(".swift"):
                continue
            path = os.path.join(base, name)
            rel = os.path.relpath(path, SRC)
            files += 1
            all_rows.extend(scan_file(path, rel))

    all_rows.sort(key=lambda r: (r["file"], r["line"]))
    # 2026-11-23：feature_id/doc_path 由映射表自动填入（不手工逐函数填）。
    rules = load_mapping()
    unmapped = Counter()
    for r in all_rows:
        fid, doc = map_decl(r["file"], r["owner"], r["name"], rules)
        r["feature_id"], r["doc_path"] = fid, doc
        if fid == "未映射":
            unmapped[r["file"]] += 1
    funcs = [r for r in all_rows if r["kind"] in ("func", "init", "deinit", "subscript")]
    kinds = Counter(r["kind"] for r in all_rows)
    modules = Counter(r["module"] for r in all_rows if r["kind"] != "var" and r["kind"] != "let")

    print(f"文件 {files}；声明 {len(all_rows)}；函数 {len(funcs)}")
    print("kind:", dict(kinds))
    print("模块:", modules.most_common())
    if unmapped:
        print(f"未映射 {sum(unmapped.values())} 条声明，分布在 {len(unmapped)} 个文件：",
              ", ".join(sorted(unmapped)[:12]), "…" if len(unmapped) > 12 else "")

    if args.check:
        return 0

    os.makedirs(os.path.dirname(args.out), exist_ok=True)
    for r in all_rows:
        r["perf_priority"] = PERF_HOTSPOTS.get((r["file"], r["owner"], r["name"]), "")
    with open(args.out, "w", newline="", encoding="utf-8-sig") as fh:
        writer = csv.DictWriter(fh, fieldnames=["module", "file", "owner", "kind",
                                                "name", "line", "lines", "complexity",
                                                "feature_id", "doc_path", "perf_priority"])
        writer.writeheader()
        writer.writerows(all_rows)
    print("已写入", os.path.relpath(args.out, ROOT))
    return 0


if __name__ == "__main__":
    sys.exit(main())
