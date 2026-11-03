#!/usr/bin/env python3
"""函数级审计标记工具：一次标记一个函数，立即落盘 + 写审计流水。

用法：
  python3 tools/perf_audit/mark.py --file Features/Monitor/Sampling/MonitorSampler.swift \
      --name sampleOnce --status manual --verdict optimize --cost medium \
      --note "实测 refresh 126ms/次，SMC 占 103ms；已加 UI 门控"

批量（仍逐个写盘、逐条流水）：
  python3 tools/perf_audit/mark.py --batch /tmp/marks.json

审计流水：docs/perfaudit/审计流水.csv（时间、文件、函数、判定、备注）
"""
import csv
import json
import os
import sys
import time

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
LEDGER = os.path.join(ROOT, "docs", "perfaudit", "函数性能审计台账.csv")
TRAIL = os.path.join(ROOT, "docs", "perfaudit", "审计流水.csv")
COLS = ["id", "lang", "file", "scope", "name", "start", "end", "nlines", "static_refs",
        "is_entry", "async", "has_loop", "dead_candidate", "hot_apis", "mods", "sig",
        "analysis_status", "verdict", "cost_est", "notes"]


def load():
    with open(LEDGER, encoding="utf-8") as fh:
        return list(csv.DictReader(fh))


def save(rows):
    with open(LEDGER, "w", encoding="utf-8", newline="") as fh:
        w = csv.DictWriter(fh, fieldnames=COLS)
        w.writeheader()
        for r in rows:
            w.writerow({k: r.get(k, "") for k in COLS})


def trail(file, name, verdict, note):
    new = not os.path.exists(TRAIL)
    with open(TRAIL, "a", encoding="utf-8", newline="") as fh:
        w = csv.writer(fh)
        if new:
            w.writerow(["时间", "文件", "函数", "判定", "备注"])
        w.writerow([time.strftime("%Y-%m-%d %H:%M:%S"), file, name, verdict, note])


def mark_one(rows, item):
    key_file, name = item["file"], item["name"]
    scope = item.get("scope", "")
    hit = None
    for r in rows:
        if r["file"] == key_file and r["name"] == name and (not scope or r["scope"] == scope):
            hit = r
            break
    if hit is None:
        print(f"MISS {key_file} {name}")
        return False
    hit["analysis_status"] = item.get("status", "manual")
    hit["verdict"] = item["verdict"]
    if "cost" in item:
        hit["cost_est"] = item["cost"]
    if "note" in item:
        hit["notes"] = item["note"]
    save(rows)          # 每个函数审核完立即落盘
    trail(key_file, name, item["verdict"], item.get("note", ""))
    print(f"MARK {key_file}:{hit['start']} {hit['scope']}.{name} -> {item['verdict']}")
    return True


def main():
    batch = None
    if "--batch" in sys.argv:
        batch = json.load(open(sys.argv[sys.argv.index("--batch") + 1], encoding="utf-8"))
    else:
        args = dict(zip(sys.argv[1::2], sys.argv[2::2]))
        batch = [{
            "file": args["--file"].lstrip("/"),
            "name": args["--name"],
            "scope": args.get("--scope", ""),
            "status": args.get("--status", "manual"),
            "verdict": args["--verdict"],
            "cost": args.get("--cost"),
            "note": args.get("--note", ""),
        }]
    rows = load()
    ok = 0
    for item in batch:
        ok += 1 if mark_one(rows, item) else 0
    print(f"完成 {ok}/{len(batch)}")


if __name__ == "__main__":
    main()
