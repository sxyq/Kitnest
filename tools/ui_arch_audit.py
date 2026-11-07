#!/usr/bin/env python3
"""全量 UI 组件 / 交互 / 分层画像生成器（v260 新增）。

与 `func_table.py` 共用同一套源码扫描口径，但回答的是另一组问题：
  * 这个文件属于哪一层（界面 / 应用 / 领域 / 基础设施）？
  * 它在 UI 上复用了共享组件，还是又自造了一套？
  * 它有没有把领域逻辑、单例、调试钩子塞进视图？

产物：`docs/40-审计与核对/数据表/源文件分层与组件画像.csv`（每文件一行，逐条可核对）。
主报告：`docs/40-审计与核对/全量UI交互与DDD架构审计报告.md`。

用法
----
    python3 tools/ui_arch_audit.py                 # 生成 CSV + 打印汇总度量
    python3 tools/ui_arch_audit.py --check        # 只打印度量，不落盘
    python3 tools/ui_arch_audit.py --out <path>   # 指定输出路径

说明
----
本脚本**实扫当前源码**，不读 `FrsetNext-函数清单.csv`：工作区有未提交改动时，
CSV 会落后于源码（v260 实测落后 41 条），用它做画像会一并对不上行号。
声明口径与 func_table 完全一致，可用 `tools/reconcile.py` 单独校验 CSV 同步状态。
"""
from __future__ import annotations

import argparse
import collections
import csv
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import func_table  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = func_table.SRC
DEFAULT_OUT = os.path.join(
    ROOT, "docs", "40-审计与核对", "数据表", "源文件分层与组件画像.csv"
)

# ---------------------------------------------------------------- 规则定义

# 目录 → 目录本身声称的层。注意：这只是"自称"，实际层由文件内容再判定。
DIR_LAYER = {
    "Core/UI": "基础设施·设计系统",
    "Core/Runtime": "基础设施·运行时",
    "Core/Motion": "基础设施·动效",
    "Storage": "基础设施·持久化",
    "Models": "领域·共享模型",
    "App": "应用·装配",
}

SHARED_COMPONENTS = {
    "SettingsSection": r"SettingsSection\(",
    "SettingsRow": r"SettingsRow\(",
    "SettingsGroupBox": r"SettingsGroupBox\b",
    "glassCard": r"\.glassCard\(",
    "glassPlate": r"\.glassPlate\(",
    "applyOfficialChrome": r"applyOfficialChrome\(",
    "Toast": r"Toast\.show",
    "RoundCloseButton": r"RoundCloseButton\b",
    "FlowLayout": r"FlowLayout\b",
    "PointingHandCursor": r"PointingHandCursor\b",
}

TOKENS = {
    "Radius": r"Theme\.Radius\.",
    "TextSize": r"Theme\.TextSize\.",
    "Space": r"Theme\.Space\.",
    "Stroke": r"Theme\.Stroke\.",
    "Motion": r"Theme\.Motion\.",
}

VIEW_MARK = re.compile(r":\s*View\b|some View\b|NSViewRepresentable|NSHostingView|NSWindow\b|NSPanel\b")
FONT_LITERAL = re.compile(r"\.system\(size:\s*([0-9.]+)")
FONT_THEME = re.compile(r"Theme\.TextSize\.")
CORNER_LITERAL = re.compile(r"cornerRadius:\s*([0-9.]+)")
SINGLETON = re.compile(r"\b[A-Z][A-Za-z]*(?:Manager|Store|Service|Registry|Presenter|Provider|Controller)\.shared\b")
PROBE = re.compile(r'"probe\.[A-Za-z0-9_.]+"')
BUTTON_STYLE = re.compile(r"\.buttonStyle\(([^)]*)\)")
INLINE_VIEW = re.compile(
    r"^\s*(?:private |fileprivate |@ViewBuilder )*(?:func|var) \w+[^\n]*?(?:-> some View|: some View)",
    re.M,
)
SQL = re.compile(r"\b(?:SELECT\s|INSERT INTO|UPDATE\s+\w+\s+SET|DELETE FROM|CREATE TABLE)")
DB_ACCESS = re.compile(r"DatabaseManager\.shared\.(?:clipboard|statistics)|\.scalarInt\(|SQLiteDatabase\(")
DOMAIN_IN_VIEW = re.compile(r"FileManager\.default|Process\(|URLSession|sqlite3_|NSWorkspace\.shared")


def module_of(rel: str) -> str:
    return func_table.module_of(rel)


def claimed_layer(rel: str) -> str:
    for prefix, layer in DIR_LAYER.items():
        if rel.startswith(prefix + "/"):
            return layer
    parts = rel.split("/")
    if parts[0] == "Features" and len(parts) >= 3:
        sub = parts[2]
        if sub in ("UI", "Views", "Presentation", "Inspector", "Preview", "Shell"):
            return "界面层"
        if sub in ("Core", "Sampling", "Transfer", "Services", "Translation"):
            return "领域/服务"
        return "混合层"
    return "未分类"


def actual_layer(rel: str, text: str) -> str:
    """按内容判断：含 SwiftUI View 声明即界面层；含 NSWindow/Manager 且无 View 归服务层。"""
    has_view = bool(re.search(r":\s*View\s*\{|some View\s*\{|NSViewRepresentable", text))
    has_window = bool(re.search(r"NSWindow\(|NSPanel\(|NSWindowController|NSHostingController", text))
    if has_view:
        return "界面层"
    if has_window:
        return "界面层·窗口宿主"
    if re.search(r"class \w*(?:Manager|Store|Service|Repository|Provider|Engine|Coordinator)", text):
        return "应用/领域服务"
    if re.search(r"^(?:public )?struct \w+", text, re.M) and re.search(r"Codable|Hashable|Sendable", text):
        return "领域模型"
    return "基础设施/工具"


def scan_file(path: str, rel: str) -> dict:
    raw = open(path, encoding="utf-8", errors="replace").read()
    lines = raw.splitlines()
    decls = func_table.scan_file(path, rel)

    fonts = [float(x) for x in FONT_LITERAL.findall(raw)]
    corners = [float(x) for x in CORNER_LITERAL.findall(raw)]
    styles = collections.Counter(BUTTON_STYLE.findall(raw))
    comps = {k: len(re.findall(v, raw)) for k, v in SHARED_COMPONENTS.items()}
    tokens = {k: len(re.findall(v, raw)) for k, v in TOKENS.items()}

    shared_hits = sum(v for k, v in comps.items() if k != "Toast")
    token_hits = sum(tokens.values())

    return {
        "module": module_of(rel),
        "file": rel,
        "loc": len(lines),
        "claimed_layer": claimed_layer(rel),
        "actual_layer": actual_layer(rel, raw),
        "decls": len(decls),
        "funcs": sum(1 for d in decls if d["kind"] in ("func", "init", "deinit", "subscript")),
        "inline_views": len(INLINE_VIEW.findall(raw)),
        "view_marks": len(VIEW_MARK.findall(raw)),
        "font_literals": len(fonts),
        "font_sizes": len(set(fonts)),
        "font_values": ";".join(str(x) for x in sorted(set(fonts))),
        "font_token": tokens["TextSize"],
        "corner_literals": len(corners),
        "radius_token": tokens["Radius"],
        "space_token": tokens["Space"],
        "stroke_token": tokens["Stroke"],
        "motion_token": tokens["Motion"],
        "token_hits": token_hits,
        "shared_hits": shared_hits,
        "shared_detail": ";".join(f"{k}={v}" for k, v in comps.items() if v),
        "button_styles": len(styles),
        "button_calls": len(re.findall(r"\bButton\(", raw)),
        "singleton_refs": len(SINGLETON.findall(raw)),
        "probe_hooks": len(PROBE.findall(raw)),
        "sql_stmts": len(SQL.findall(raw)),
        "db_access": len(DB_ACCESS.findall(raw)),
        "domain_in_view": len(DOMAIN_IN_VIEW.findall(raw)) if "界面" in actual_layer(rel, raw) else 0,
    }


def issues(r: dict) -> list[str]:
    out = []
    if r["actual_layer"].startswith("界面") and r["font_literals"] >= 10 and not r["font_token"]:
        out.append("字号全部硬编码")
    if r["actual_layer"].startswith("界面") and r["inline_views"] >= 8 and r["shared_hits"] == 0:
        out.append("大视图零共享组件")
    if r["actual_layer"].startswith("界面") and r["probe_hooks"]:
        out.append("视图内含调试钩子")
    if r["actual_layer"].startswith("界面") and r["db_access"]:
        out.append("视图直连数据库")
    if r["actual_layer"].startswith("界面") and r["singleton_refs"] >= 8:
        out.append("视图重依赖单例")
    if r["claimed_layer"].startswith("领域") and "界面" in r["actual_layer"]:
        out.append("领域目录混入视图")
    if r["corner_literals"] >= 4 and not r["radius_token"]:
        out.append("圆角字面量未收敛")
    if r["button_styles"] >= 3:
        out.append("单文件多套按钮样式")
    return out


def priority(r: dict, probs: list[str]) -> str:
    if "视图直连数据库" in probs or "领域目录混入视图" in probs:
        return "P0"
    if len(probs) >= 3 or "视图内含调试钩子" in probs:
        return "P1"
    if probs:
        return "P2"
    return "-"


def target_layer(r: dict) -> str:
    a = r["actual_layer"]
    if a.startswith("界面"):
        return "Interface（仅渲染 + 交互转发）"
    if a in ("应用/领域服务", "领域模型"):
        return "Application / Domain（按是否为业务规则再拆）"
    return "Infrastructure（保持）"


def collect() -> list[dict]:
    rows = []
    for base, _dirs, names in os.walk(SRC):
        for name in sorted(names):
            if not name.endswith(".swift"):
                continue
            full = os.path.join(base, name)
            rel = os.path.relpath(full, SRC)
            r = scan_file(full, rel)
            probs = issues(r)
            r["issues"] = "；".join(probs)
            r["priority"] = priority(r, probs)
            r["target_layer"] = target_layer(r)
            rows.append(r)
    rows.sort(key=lambda x: x["file"])
    return rows


FIELDS = [
    "module", "file", "loc", "claimed_layer", "actual_layer", "target_layer",
    "decls", "funcs", "inline_views", "view_marks",
    "font_literals", "font_sizes", "font_values", "font_token", "corner_literals", "radius_token",
    "space_token", "stroke_token", "motion_token", "token_hits",
    "shared_hits", "shared_detail", "button_calls", "button_styles",
    "singleton_refs", "probe_hooks", "sql_stmts", "db_access", "domain_in_view",
    "issues", "priority",
]


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true", help="只打印度量，不写 CSV")
    ap.add_argument("--out", default=DEFAULT_OUT)
    args = ap.parse_args()

    rows = collect()
    total = collections.Counter()
    all_font_values: set[float] = set()
    for r in rows:
        all_font_values.update(float(x) for x in r["font_values"].split(";") if x)
        for k in ("loc", "decls", "funcs", "inline_views", "font_literals", "corner_literals",
                  "token_hits", "shared_hits", "button_calls", "singleton_refs", "probe_hooks",
                  "sql_stmts", "db_access"):
            total[k] += r[k]
        for k in ("font_token", "radius_token", "space_token", "stroke_token", "motion_token"):
            total[k] += r[k]
        total["files_with_issues"] += 1 if r["issues"] else 0
        total[r["priority"]] += 1

    print(f"扫描 {len(rows)} 个 Swift 文件 / {total['loc']:,} 行 / {total['decls']:,} 声明（函数 {total['funcs']:,}）")
    print()
    print("=== 设计令牌采用率 ===")
    for k, label in (("radius_token", "Theme.Radius"), ("motion_token", "Theme.Motion"),
                     ("stroke_token", "Theme.Stroke"), ("space_token", "Theme.Space"),
                     ("font_token", "Theme.TextSize")):
        print(f"  {label:<16s} {total[k]:>5d}")
    print(f"  {'字号字面量':<16s} {total['font_literals']:>5d}（{len(all_font_values)} 种取值："
          f"{', '.join(str(x) for x in sorted(all_font_values))}）")
    print(f"  {'圆角字面量':<16s} {total['corner_literals']:>5d}")
    print()
    print("=== 结构度量 ===")
    print(f"  内联子视图 {total['inline_views']} · 共享组件命中 {total['shared_hits']} · "
          f"Button {total['button_calls']} · 单例引用 {total['singleton_refs']}")
    print(f"  probe.* 调试钩子 {total['probe_hooks']} · SQL 语句 {total['sql_stmts']} · "
          f"DB 直接访问 {total['db_access']}")
    print(f"  有问题文件 {total['files_with_issues']} / {len(rows)}"
          f"（P0 {total['P0']} · P1 {total['P1']} · P2 {total['P2']}）")

    if args.check:
        return 0

    os.makedirs(os.path.dirname(args.out), exist_ok=True)
    with open(args.out, "w", encoding="utf-8-sig", newline="") as fh:
        w = csv.DictWriter(fh, fieldnames=FIELDS, extrasaction="ignore")
        w.writeheader()
        w.writerows(rows)
    print(f"\n已写入 {os.path.relpath(args.out, ROOT)}（{len(rows)} 行）")
    return 0


if __name__ == "__main__":
    sys.exit(main())
