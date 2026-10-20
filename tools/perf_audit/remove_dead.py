#!/usr/bin/env python3
"""按台账删除已确认的死代码块（dry-run 默认，--apply 才写盘）。

安全约束：
- 只删 dead_candidate=Y 且不在 KEEP 名单里的函数；
- 删除前校验块首行确实含函数名；
- 连同紧邻上方的文档注释/属性一起删；
- 同文件从后往前删，避免行号漂移。
"""
import csv, os, re, sys

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
SRC = os.path.join(ROOT, "apps", "FrsetNext", "Sources")
LEDGER = os.path.join(ROOT, "docs", "perfaudit", "函数性能审计台账.csv")

KEEP = {
    # 框架回调 / override（由 AppKit/SwiftUI 运行时调用，静态引用为 0 是正常的）
    "applicationWillTerminate", "applicationShouldHandleReopen", "placeSubviews",
    "magnify", "textDidChange", "windowDidMove", "drawHashMarksAndLabels",
    "dropEntered", "dropUpdated", "performDrop", "dropExited", "popoverDidClose",
    # 排障探针（环境变量/自检触发，保留供排障）
    "FSBarSetDebugAnchorX", "FSBarDebugPosProbe", "FSBarDebugMergedReady",
    "FSBarDebugAppearanceProbe", "FSScreenRecDebugPanelView", "FSScreenRecDebugBarView",
    # 预留公开接口（热键接线用，文档注明预留）
    "handleGlobalShortcut",
}

def main():
    apply = "--apply" in sys.argv
    rows = [r for r in csv.DictReader(open(LEDGER, encoding="utf-8"))
            if r["dead_candidate"] == "Y" and r["name"] not in KEEP]
    by_file = {}
    for r in rows:
        by_file.setdefault(r["file"], []).append(r)

    removed = 0
    for rel, items in by_file.items():
        path = os.path.join(SRC, rel)
        lines = open(path, encoding="utf-8", errors="replace").read().splitlines()
        for r in sorted(items, key=lambda x: int(x["start"]), reverse=True):
            s, e = int(r["start"]) - 1, int(r["end"]) - 1
            if s >= len(lines) or e >= len(lines):
                print(f"SKIP 越界 {rel}:{r['start']} {r['name']}")
                continue
            block = "\n".join(lines[s:e + 1])
            if r["name"] not in block:
                print(f"SKIP 签名不符 {rel}:{r['start']} {r['name']}")
                continue
            # 向上吞掉紧邻的注释/属性（不含空行，避免误删分隔）
            top = s
            while top > 0:
                prev = lines[top - 1].strip()
                if prev.startswith("///") or prev.startswith("//") or prev.startswith("@") or prev.startswith("["):
                    top -= 1
                else:
                    break
            del lines[top:e + 1]
            removed += 1
            print(f"DEL {rel}:{top+1}-{e+1} {r['name']} ({e-top+1} 行)")
        if apply:
            # 折叠连续空行（最多保留 2 行）
            out = []
            blank = 0
            for ln in lines:
                if ln.strip() == "":
                    blank += 1
                    if blank <= 2:
                        out.append(ln)
                else:
                    blank = 0
                    out.append(ln)
            open(path, "w", encoding="utf-8").write("\n".join(out) + "\n")
    print(f"\n{'已删除' if apply else '将删除'} {removed} 个函数块")
    if not apply:
        print("（dry-run；加 --apply 执行）")

if __name__ == "__main__":
    main()
