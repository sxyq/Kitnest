#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""把官网 mock 的剪贴板预览做成**真实渲染**，对齐真机 PreviewPopoverContentView。

真机依据（apps/FrsetNext/Sources/Features/Panel/Preview/PreviewPopoverContentView.swift）：
  JSON   → JSONInspectorView(text:compact:)  树形/表格双视图，不是纯文本
  代码   → CodePreviewView                     带行号、语法高亮、语言锁定
  Markdown→ MarkdownPreviewBody                渲染成正文（标题/列表/粗体/行内码）
  图片   → PreviewImageView                    缩略图 + 「识别文本」按钮（OCR 带 busy/error 态）
  文本   → PreviewTextContentView              纯文本

网页版按同样的分态做渲染器：
  · JSON   → 键值树，键/字符串/数字/布尔/null 分色
  · 代码   → 行号 + 关键字/字符串/注释/数字分色
  · Markdown→ 标题/列表/粗体/行内码/分隔线
  · 图片   → 缩略图占位 + 「识别文字」「翻译」两个按钮（写死内容，但可点）
"""
import io, os, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PATH = os.path.join(ROOT, 'assets', 'site.js')
s = io.open(PATH, encoding='utf-8').read()

# ---------- 1) 条目数据换成带真实内容的版本 ----------
i = s.find('  var CLIP_ITEMS = [')
j = s.find('  /*\n     搜索：真机有网页')
if i < 0 or j < 0:
    sys.exit('CLIP_ITEMS 锚点没找到 i=%d j=%d' % (i, j))

NEW_ITEMS = u'''  /*
     剪贴板条目：内容是**真实可渲染的样例**（JSON / Markdown / Swift / Python / 图片 / 链接），
     预览按真机 PreviewPopoverContentModel.classify 的分态渲染。
     数据全部虚构，不含任何真实用户内容。
  */
  var CLIP_ITEMS = [
    { id: "c1", kind: "url", badge: "chrome",
      title: "https://example.com/kitnest/release",
      meta: "今天 12:15 · 32 个字符",
      view: "url",
      text: "https://example.com/kitnest/release" },
    { id: "c2", kind: "text", badge: "code",
      title: "周报草稿：第三部分的发布流程还需要补充回滚说明",
      meta: "今天 12:08 · 45 个字符",
      view: "text",
      text: "周报草稿：第三部分的发布流程还需要补充回滚说明。" },
    { id: "c3", kind: "md", badge: "md",
      title: "# Kitnest 演示仓库（示例内容）",
      meta: "今天 12:08 · 263 个字符",
      view: "markdown",
      text: "# Kitnest 演示仓库\\n\\n这是一个**用于演示的占位文档**，内容全部虚构。\\n\\n## 功能\\n\\n- 剪贴板历史：文字 / 图片 / 文件 / 链接\\n- 截图标注：矩形、箭头、马赛克\\n- 系统监控：CPU / 内存 / 网络 / 磁盘 / 电池\\n\\n## 发布流程\\n\\n1. `bash tools/publish_update.sh`\\n2. `bash tools/deploy_site.sh`\\n3. 核对 SHA-256 与安装包大小\\n\\n> 以上为示例内容，不是真实项目文档。\\n\\n---\\n\\n相关：[Kitnest 官网](https://example.com/kitnest)" },
    { id: "c4", kind: "json", badge: "json",
      title: '{ "name": "kitnest-demo.config.json",',
      meta: "今天 12:08 · 647 个字符",
      view: "json",
      text: '{\\n  "name": "kitnest-demo.config.json",\\n  "app": "kitnest-demo",\\n  "version": "1.0.0",\\n  "features": {\\n    "clipboard": { "keepDays": 30, "maxSizeMB": 2048 },\\n    "monitor": { "refreshSeconds": 1.5, "widgets": ["cpu", "net", "batt"] },\\n    "update": { "channel": "stable", "autoCheck": true }\\n  },\\n  "screenshot": {\\n    "hotkeys": { "region": "⌥S", "window": "⇧⌥W", "longshot": "⇧⌥L" },\\n    "annotateTools": ["rect", "ellipse", "arrow", "pen", "text", "mosaic"]\\n  }\\n}' },
    { id: "c5", kind: "code", badge: "code",
      title: "// Sample.swift —— 演示用代码（假数据）",
      meta: "今天 12:08 · 412 个字符",
      view: "code",
      lang: "swift",
      text: '// Sample.swift —— 演示用代码（假数据）\\nimport Foundation\\n\\n/// 把剪贴板条目按类型分组\\nstruct ClipItem {\\n    let kind: String\\n    let title: String\\n}\\n\\nfunc groupByKind(_ items: [ClipItem]) -> [String: [ClipItem]] {\\n    items.reduce(into: [:]) { result, item in\\n        result[item.kind, default: []].append(item)\\n    }\\n}\\n\\nlet sample = [\\n    ClipItem(kind: "text", title: "周报草稿"),\\n    ClipItem(kind: "code", title: "Sample.swift"),\\n]\\nprint(groupByKind(sample))' },
    { id: "c6", kind: "code", badge: "code",
      title: "# sample.py —— 演示用代码（假数据）",
      meta: "今天 12:08 · 356 个字符",
      view: "code",
      lang: "python",
      text: '# sample.py —— 演示用代码（假数据）\\nimport hashlib\\n\\n\\ndef sha256(path: str) -> str:\\n    """计算文件的 SHA-256。""".\\n    h = hashlib.sha256()\\n    with open(path, "rb") as f:\\n        for chunk in iter(lambda: f.read(65536), b""):\\n            h.update(chunk)\\n    return h.hexdigest()\\n\\n\\nif __name__ == "__main__":\\n    print(sha256("demo-config.json"))' },
    { id: "c7", kind: "img", badge: "img",
      title: "屏幕快照 2026-11-05 14.32.png",
      meta: "今天 11:50 · 1024×1024 pt",
      view: "image",
      text: "1024×1024 pt",
      ocr: "订单确认\\n\\n商品：机械键盘 87 键\\n数量：1\\n金额：¥499.00\\n\\n客服电话 400-820-8820" },
    { id: "c8", kind: "text", badge: "code",
      title: "TODO：把安装包校验写进发版脚本",
      meta: "昨天 18:24 · 26 个字符",
      view: "text",
      text: "TODO：把安装包校验写进发版脚本，顺便把官网的下载页也更新一下。" }
  ];

'''

s = s[:i] + NEW_ITEMS + s[j:]
io.open(PATH, 'w', encoding='utf-8').write(s)
print('条目数据已换成可真实渲染的样例，JS %d 行' % len(s.split('\n')))
