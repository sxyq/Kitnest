#!/usr/bin/env python3
"""分镜执行器。

    python3 tools/gifdoc/run.py ch01 ch02 --probe     # 只截图审构图
    python3 tools/gifdoc/run.py ch01 --record         # 录真机 → GIF
    python3 tools/gifdoc/run.py --list                # 列全部场景
"""
import os
import sys
import time
import traceback
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
import h
import scenes


def main():
    args = sys.argv[1:]
    if "--list" in args:
        for name, fn in scenes.SCENES.items():
            print(f"{name}: {(fn.__doc__ or '').splitlines()[0]}")
        return
    probe = "--probe" in args
    names = [a for a in args if not a.startswith("--")]
    if not names:
        print("用法：run.py ch01 ch02 --probe|--record")
        return
    h.PROBING = probe
    os.environ["GIF_PROBE"] = "1" if probe else "0"
    failed = []
    for n in names:
        fn = scenes.SCENES.get(n)
        if not fn:
            print(f"!! 没有场景 {n}")
            failed.append(n)
            continue
        h.SCENE = n
        os.environ["GIF_SCENE"] = n
        t0 = time.time()
        print(f"\n=== {n} ({'probe' if probe else 'record'}) ===")
        try:
            fn()
        except Exception as e:
            traceback.print_exc()
            failed.append(n)
        print(f"--- {n} {time.time() - t0:.1f}s")
    if failed:
        print("\n失败：", failed)
        sys.exit(1)


if __name__ == "__main__":
    main()
