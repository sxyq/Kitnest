#!/usr/bin/env python3
"""把 scenes.js 拆成按功能域的 7 个 chunk（演示按需加载）。

需求（2026-11-18 用户原话）：「需要考虑性能，这种东西不要长时间加载。
不使用的就不加载，使用的时候才进行加载，并且不是全量加载，是刷到一个
文档进去再加载」。

拆分后：
  · 首屏只加载 demo.js（运行时）+ 第一个演示所属域的 chunk（几 KB~几十 KB）；
  · 每个演示块进入视口时才 fetch 自己的 chunk，并只构建自己的迷你界面；
  · 滚远后卸载 DOM、停止时间轴，回来再重新加载播放。

本脚本一次性使用，留档可重跑（重跑会重新生成 7 个 chunk 并删 scenes.js）。
"""
from __future__ import annotations

import re
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DEMOS = ROOT / "FRONT/manual/demos"
SRC = DEMOS / "scenes.js"

GROUPS: dict[str, list[str]] = {
    "entry": ["menubar", "panel", "statistics"],
    "clipboard": ["clipboard", "floatdesk", "preview"],
    "capture": ["capture", "annotate", "beautify", "longshot", "pin",
                "curtain", "history", "ocr", "captureplus", "recording"],
    "monitor": ["monitor", "memory", "storage", "network"],
    "transfer": ["transfer", "cast"],
    "tools": ["archive", "toolbox", "search", "command", "calendar",
              "shortcuts", "codepreview", "cloudlink", "ai"],
    "app": ["settings", "onboarding", "manual", "update", "workflow"],
}

HEAD = """/* ============================================================
   Kitnest 手册 · 演示场景库 · {label}（按需加载）
   ------------------------------------------------------------
   由 tools/split_manual_scenes.py 从 scenes.js 拆分生成。
   只有读者滚到本域的演示块时，demo.js 才会 fetch 这个文件；
   首屏不会加载全部场景。
   ============================================================ */
Object.assign(window.KDEMOS = window.KDEMOS || {{}}, {{
"""

LABELS = {
    "entry": "界面与入口", "clipboard": "剪贴板", "capture": "截图与录屏",
    "monitor": "系统监测", "transfer": "传输", "tools": "文件与工具",
    "app": "应用与维护",
}


def split_scenes(text: str) -> dict[str, str]:
    """按顶层 `  id: {` 切出每个场景的源码块（含尾部逗号处理）。"""
    marks = list(re.finditer(r"^  ([a-z][a-z0-9]*): \{\n", text, re.M))
    scenes: dict[str, str] = {}
    for i, m in enumerate(marks):
        start = m.start()
        end = marks[i + 1].start() if i + 1 < len(marks) else text.rfind("\n};")
        block = text[start:end].rstrip()
        # 块尾的装饰注释（`/* ---- 下一节 ---- */`）不属于本场景，剥掉，
        # 否则拼装时会在注释后留下逗号 → Unexpected token ','
        block = re.sub(r"\n\s*/\*[^*]*\*/\s*$", "", block)
        if block.endswith(","):
            block = block[:-1]
        scenes[m.group(1)] = block
    return scenes


def main() -> None:
    text = SRC.read_text(encoding="utf-8")
    scenes = split_scenes(text)
    expect = {sid for ids in GROUPS.values() for sid in ids}
    if set(scenes) != expect:
        raise SystemExit(f"场景不匹配：多 {set(scenes) - expect} / 缺 {expect - set(scenes)}")

    total = 0
    for group, ids in GROUPS.items():
        body = ",\n\n".join(scenes[sid] for sid in ids)
        out = HEAD.format(label=LABELS[group]) + body + "\n});\n"
        path = DEMOS / f"scenes-{group}.js"
        path.write_text(out, encoding="utf-8")
        kb = path.stat().st_size / 1024
        total += kb
        print(f"  scenes-{group}.js  {len(ids)} 段  {kb:6.1f} KB")

    SRC.unlink()
    print(f"共 7 个 chunk / {total:.1f} KB（原 scenes.js 单文件 "
          f"{len(text.encode()) / 1024:.1f} KB）")


if __name__ == "__main__":
    main()
