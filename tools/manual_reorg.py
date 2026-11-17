#!/usr/bin/env python3
"""用户手册结构重排（一次性脚本，留档可重跑）。

需求（2026-11-18 用户原话）：
  「把用户手册全面重构……不要用 GIF，用这种设置里面那种可交互的、
   用预先设置好的动画去展示这个功能有什么用，以及怎么用，
   并且用户手册按照功能类别去重排」

本脚本做三件事：
  1. 37 章按「功能类别」重组为 7 个部分（界面与入口 / 剪贴板 / 截图与录屏 /
     系统监测 / 传输 / 文件与工具 / 应用与维护），章节编号改为「域.序号」；
  2. 合并重复的录屏章（原 15 + 36），旧「截图增强」并入截图域；
  3. 每章 `### 演示` 段的录屏 GIF 换成 `:::demo <id>` 交互演示指令。

幂等：检测到已经是新结构（出现「# 第一部分 · 界面与入口」）就直接退出。

用法：
    python3 tools/manual_reorg.py            # 就地重写
    python3 tools/manual_reorg.py --dry-run  # 只打印计划
"""
from __future__ import annotations

import argparse
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SRC = ROOT / "docs/40-审计与核对/性能审计/用户手册-FrsetNext.md"

# ---------------------------------------------------------------- 新结构
# (部分标题, [(新编号, 新标题, 原章号, demo id)])
DOMAINS = [
    ("第一部分 · 界面与入口", [
        ("1.1", "菜单栏与图标", 1, "menubar"),
        ("1.2", "主面板与首页", 3, "panel"),
        ("1.3", "使用统计", 2, "statistics"),
    ]),
    ("第二部分 · 剪贴板", [
        ("2.1", "剪贴板历史", 4, "clipboard"),
        ("2.2", "悬浮剪贴板工作台", 5, "floatdesk"),
        ("2.3", "预览与编辑", 6, "preview"),
    ]),
    ("第三部分 · 截图与录屏", [
        ("3.1", "截图主流程", 7, "capture"),
        ("3.2", "标注编辑器", 8, "annotate"),
        ("3.3", "美化与物体擦除", 9, "beautify"),
        ("3.4", "长截图", 10, "longshot"),
        ("3.5", "钉图", 11, "pin"),
        ("3.6", "图帘", 12, "curtain"),
        ("3.7", "截图历史", 13, "history"),
        ("3.8", "文字识别、翻译与二维码", 14, "ocr"),
        ("3.9", "截图增强设置", 35, "captureplus"),
        ("3.10", "录屏", 36, "recording"),          # 主体用新版第 36 章
    ]),
    ("第四部分 · 系统监测", [
        ("4.1", "系统监测", 16, "monitor"),
        ("4.2", "内存维护", 17, "memory"),
        ("4.3", "存储管理", 18, "storage"),
        ("4.4", "网络诊断与端口", 19, "network"),
    ]),
    ("第五部分 · 传输", [
        ("5.1", "文件中转", 20, "transfer"),
        ("5.2", "手机投屏", 21, "cast"),
    ]),
    ("第六部分 · 文件与工具", [
        ("6.1", "归档压缩", 22, "archive"),
        ("6.2", "工具箱", 23, "toolbox"),
        ("6.3", "全局搜索", 24, "search"),
        ("6.4", "命令面板", 25, "command"),
        ("6.5", "日历与节假日", 26, "calendar"),
        ("6.6", "快捷键", 27, "shortcuts"),
        ("6.7", "代码预览", 28, "codepreview"),
        ("6.8", "网盘链接解析", 29, "cloudlink"),
        ("6.9", "AI 助手", 30, "ai"),
    ]),
    ("第七部分 · 应用与维护", [
        ("7.1", "设置", 31, "settings"),
        ("7.2", "新手引导与权限", 32, "onboarding"),
        ("7.3", "内置用户手册", 33, "manual"),
        ("7.4", "更新与诊断", 34, "update"),
        ("7.5", "工作流", 37, "workflow"),
    ]),
]

CN_NUM = "一二三四五六七八九十"


def cn_to_int(s: str) -> int:
    s = s.replace("第", "").replace("章", "").strip()
    if s == "十":
        return 10
    if s.startswith("十"):
        return 10 + CN_NUM.index(s[1]) + 1
    if "十" in s:
        a, b = s.split("十")
        tens = CN_NUM.index(a) + 1 if a else 1
        ones = CN_NUM.index(b) + 1 if b else 0
        return tens * 10 + ones
    return CN_NUM.index(s) + 1


def split_doc(md: str):
    """返回 (头部, {章号: (原标题, 正文)}, 附录)。

    注意：原文件里「# 附录」标题出现得比 35–37 章还早（旧排版瑕疵），
    真正的附录从「## 附录 A」开始——因此附录边界以附录 A 为准。
    """
    first_part = md.find("\n# 第一部分")
    appendix_at = md.find("\n## 附录 A")
    if first_part < 0 or appendix_at < 0:
        raise SystemExit("找不到部分/附录边界，原文件结构可能已变")
    head = md[:first_part]
    body_all = md[first_part:appendix_at]
    appendix = "# 附录\n" + md[appendix_at:]

    chapters: dict[int, tuple[str, str]] = {}
    marks = list(re.finditer(r"^## 第([%s]+)章\s*(.*)$" % CN_NUM, body_all, re.M))
    for i, m in enumerate(marks):
        no = cn_to_int(m.group(1))
        start = m.start()
        end = marks[i + 1].start() if i + 1 < len(marks) else len(body_all)
        title = m.group(2).strip()
        chapters[no] = (title, body_all[start:end])
    return head, chapters, appendix


def strip_demo(text: str) -> str:
    """删掉原「### 演示」段（到下一个 ### 或章末）。"""
    return re.sub(r"\n### 演示\n.*?(?=\n### |\n## |\Z)", "\n", text, flags=re.S)


def clean_part_headers(text: str) -> str:
    """删掉夹在章块里的旧「# 第X部分」「# 附录」标题（原排版残留）。"""
    text = re.sub(r"^# 第[一二三四五六七]部分.*$\n?", "", text, flags=re.M)
    text = re.sub(r"^# 附录\s*$\n?", "", text, flags=re.M)
    return text


def add_demo(text: str, demo_id: str) -> str:
    block = f"\n### 演示\n\n:::demo {demo_id}\n:::\n\n"
    for anchor in ("\n### 关键能力点", "\n### 注意事项"):
        if anchor in text:
            return text.replace(anchor, block + anchor[1:], 1)
    return text.rstrip() + "\n" + block


def rebuild_chapter(text: str, title: str, no: str, demo_id: str) -> str:
    # 去掉原 "## 第N章 标题" 行与残留的部分标题
    text = re.sub(r"^## 第[%s]+章.*\n" % CN_NUM, "", text, count=1, flags=re.M)
    text = clean_part_headers(text)
    text = strip_demo(text).rstrip() + "\n"
    text = add_demo(text, demo_id)
    return f"## {no} {title}\n{text}"


# 第 15 章（旧版录屏）里仍有效的实现细节，并进 3.10
RECORDING_EXTRA = """
- **管线**：`SCStream`（display filter + sourceRect）→ `CMSampleBuffer` → `AVAssetWriter`（H.264 + AAC）。
- **计时窗**：毛玻璃浮层显示时长 + 停止按钮，跟着录制区域走，不进画面。
- **区域框选**（`FSRegionOverlayIsActive`）：录制选区时浮动层主动让路，不挡住框选。
- **麦克风降级**：没授权麦克风时自动只录系统音，不报错。
"""


def rebuild_head(head: str) -> str:
    head = head.replace(
        "> **版本**：v1.0.0（对应源码 v264，2026-11-08）\n"
        "> **覆盖范围**：34 个功能域 / 298 个 Swift 源文件（v264 B/C 档新增 18 个 / 3,795 行）",
        "> **版本**：v1.0.0（对应源码 2026-11-18 主分支）\n"
        "> **覆盖范围**：7 个功能类别 / 36 个功能章节 / 325 个 Swift 源文件 + C/ObjC 引擎",
    )
    head = head.replace("`FrsetNext-函数清单.csv`（8,693 条声明）",
                        "`FrsetNext-函数清单.csv`（11,107 条声明）")
    head = head.replace(
        "> **演示素材**：37 段真机录屏 GIF，一章一段，都在 `gifs/` 目录，未做加速、未删帧、未拼接",
        "> **演示素材**：每章一段可交互的预设动画（模拟数据 + 自动时间轴），不依赖录屏，"
        "可随时重播、也可以自己点着试",
    )
    head = head.replace(
        "- **想看实际怎么操作**：每章「演示」小节都是一段真机录屏 GIF（37 章全覆盖），"
        "光标、动画、耗时都是真的。",
        "- **想看实际怎么操作**：每章「演示」小节是一段可交互的预设动画——"
        "自动演一遍典型操作，也可以自己点按钮、切页签试。",
    )
    return head


APPENDIX_F = """## 附录 F · 交互演示怎么做出来的

手册里的演示不再是录屏视频，而是**用代码画出来的迷你界面 + 预设时间轴**：
和「设置 → 个性化 → 效果预览」是同一种做法——真实组件样式、模拟数据、
自动播放一遍，随时可以重播，也可以自己点着试。

演示块**直接嵌在正文里**：不套卡片外壳、不占独立一行，右侧浮起、左侧文字环绕；
说明文字浮在演示内部（字幕式），不额外占一行；右上角 `↻` 随时重播。

### 运行时与场景（按需加载）

| 文件 | 职责 |
|---|---|
| `FRONT/manual/demos/demo.js` | **运行时**：渲染界面、驱动光标与时间轴、处理重播与手动交互 |
| `FRONT/manual/demos/demo.css` | **样式**：迷你面板 / 窗口 / 菜单 / 图表等原语，配色与官网同源 |
| `FRONT/manual/demos/scenes-<域>.js` | **场景数据**（7 个 chunk）：每个演示一段迷你界面 HTML + 一条时间轴 |

### 加载策略（不用的不加载）

| 时机 | 行为 |
|---|---|
| 打开页面 | 只加载 `demo.js` + `demo.css`（约 28 KB），**不加载任何场景数据** |
| 演示块进入视口前 320px | 才 fetch 所属功能域的 `scenes-<域>.js`（7–32 KB），只构建这一个迷你界面 |
| 滚出视口 600px | 卸载该演示的 DOM、停止时间轴 |
| 滚回视口 | 重新加载/构建并播放（chunk 已在内存缓存，不重复下载） |

全页 36 段演示，任意时刻驻留的只有视口附近的 6–7 段，不再是首屏一次性构建 36 个界面。

### 为什么不用 GIF

| 维度 | 录屏 GIF | 交互演示 |
|---|---|---|
| 体积 | 37 段合计 44 MB，首屏要懒加载 | 运行时 + 7 个按需 chunk 合计约 130 KB；首屏只加载 28 KB |
| 可读性 | 只能看，看不清的字还是看不清 | 想停就停，想点就点，说明文字与界面同步出现 |
| 隐私 | 录屏会带进真实剪贴板、路径、进程名，要逐段打码 | 全程模拟数据，不接触真实环境 |
| 维护 | 界面一改就要重录、重新运镜、重新压体积 | 改一行场景数据即可 |
| 精度 | 只有像素，没有可检索文字 | 界面文字就是 DOM，搜索与无障碍都能读 |

### 新增一个演示（三步）

1. 在所属功能域的 `scenes-<域>.js` 里加一个 `KDEMOS.<id>`：写 `body`（迷你界面 HTML）与 `steps`（时间轴），
   并在 `demo.js` 的 `GROUP` 映射里登记该 id 属于哪个域；
2. 手册对应章节写：
   ```
   ### 演示

   :::demo <id>
   :::
   ```
3. `python3 tools/make_manual_site.py` 重新生成，本地打开 `FRONT/manual/index.html` 验收。

### 时间轴动作

| 动作 | 作用 |
|---|---|
| `move(sel, ms)` | 光标移到元素中心（带缓动） |
| `click` / `rclick` / `dblclick` | 点击特效 + 界面响应 |
| `type(sel, text)` | 逐字输入 |
| `scroll(sel, dy)` | 容器内滚动 |
| `cap(text)` | 显示底部说明（功能有什么用 / 怎么用） |
| `run(fn)` | 自定义界面变化（切页签、换数据、弹提示） |
| `wait(ms)` / `glow` / `show` / `hide` | 节奏控制与显隐 |

场景里所有元素都可以通过 `hit` 声明手动交互：读者点页签真的会切页，
点筛选真的会过滤——演示不只是「看」，而是可以上手试。

> 旧的录屏链路（`tools/gifdoc/`）保留未删，仅用于历史归档与需要真机像素的场合；
> 手册正文与在线站点不再引用任何 GIF。
"""


def rebuild_appendix(appendix: str) -> str:
    at = appendix.find("## 附录 F · 演示 GIF 怎么来的")
    if at < 0:
        return appendix
    return appendix[:at].rstrip() + "\n\n" + APPENDIX_F


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--dry-run", action="store_true")
    a = ap.parse_args()

    md = SRC.read_text(encoding="utf-8")
    if "# 第一部分 · 界面与入口" in md:
        print("已是新结构，跳过。")
        return

    head, chapters, appendix = split_doc(md)
    missing = [no for _, _, no, _ in
               (item for _, items in DOMAINS for item in items) if no not in chapters]
    if missing:
        raise SystemExit(f"缺章节：{missing}")

    out = [rebuild_head(head).rstrip(), ""]
    for part_title, items in DOMAINS:
        out.append(f"# {part_title}")
        out.append("")
        for no, title, old, demo in items:
            text = chapters[old][1]
            if old == 36:  # 合并旧第 15 章的实现细节
                text = re.sub(r"^## 第[%s]+章.*\n" % CN_NUM, "", text, count=1, flags=re.M)
                text = clean_part_headers(text)
                text = strip_demo(text)
                text = add_demo(text, demo)
                if "### 关键能力点" in text:
                    text = text.replace("### 关键能力点",
                                        RECORDING_EXTRA.strip() + "\n\n### 关键能力点", 1)
                out.append(f"## {no} {title}\n{text.rstrip()}")
            else:
                out.append(rebuild_chapter(text, title, no, demo))
            out.append("")

    out.append(rebuild_appendix(appendix).strip())
    new_md = "\n".join(out).rstrip() + "\n"

    if a.dry_run:
        print(f"新文档 {len(new_md.splitlines())} 行（原 {len(md.splitlines())} 行）")
        print(f"演示块 {new_md.count(':::demo')} 处")
        return

    SRC.write_text(new_md, encoding="utf-8")
    print(f"已重写 {SRC.relative_to(ROOT)}")
    print(f"  行数 {len(md.splitlines())} → {len(new_md.splitlines())}")
    print(f"  章节 {len(chapters)} → {sum(len(i) for _, i in DOMAINS)}")
    print(f"  演示块 {new_md.count(':::demo')} 处 · 残留 GIF 引用 {new_md.count('](gifs/')} 处")


if __name__ == "__main__":
    main()
