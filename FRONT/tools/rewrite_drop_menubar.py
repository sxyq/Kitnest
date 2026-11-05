#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""v232：整条删掉「模拟 Mac 状态栏」。

用户原话：「是模拟的这个 Mac 状态栏需要完全删掉」。
那条假状态栏 = 苹果 logo + 文件/编辑/显示 + CPU/网络/电池假组件 + 小猫开关，
外加点它弹出的部件详情浮窗。整条删掉（HTML / CSS / JS / 回归脚本四处）。

删掉后：
· 舞台里只剩**真实可交互的主面板**（PanelRootView 1:1），常驻可见；
· 面板进场时仍播一次 WindowReveal 展开，锚点 (1,0)＝状态栏右侧，
  与 App 的 PanelController.revealUnit 兜底值一致；
· 收起动画由预览浮层继续复用同一套 revealOut 参数（用户仍能看到）。
"""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
FRONT = ROOT / "FRONT"


def edit(path, pairs):
    text = path.read_text(encoding="utf-8")
    for old, new in pairs:
        if old not in text:
            raise SystemExit("未命中 %s：\n%r" % (path.name, old[:120]))
        text = text.replace(old, new, 1)
    path.write_text(text, encoding="utf-8")
    print("  ok", path.relative_to(ROOT))


# ---------------- index.html ----------------
html = FRONT / "index.html"
text = html.read_text(encoding="utf-8")
start_marker = "          <!-- 菜单栏模拟：部件与图标都可点，下面是真实可交互的主面板 -->"
end_marker = '            <!-- 可交互的主面板（结构按真机 PanelRootView 1:1 还原） -->'
if start_marker not in text:
    raise SystemExit("index.html：找不到模拟状态栏起点")
if end_marker not in text:
    raise SystemExit("index.html：找不到主面板注释")
a = text.index(start_marker)
b = text.index(end_marker)
new_head = (
    "          <!-- 可交互主面板：不再模拟 Mac 状态栏 -->\n"
    "          <div class=\"hero-stage\">\n"
    "\n"
)
text = text[:a] + new_head + text[b:]
html.write_text(text, encoding="utf-8")
print("  ok", html.relative_to(ROOT), "（删除模拟状态栏 + 部件浮窗）")

# ---------------- site.css ----------------
css = FRONT / "assets" / "site.css"
c = css.read_text(encoding="utf-8")

# 1) 菜单栏整条样式（.menubar-mock … .mb-icon::after）
a = c.index("\n.menubar-mock {")
b_marker = '.mb-icon:hover::after, .mb-icon[aria-expanded="true"]::after { opacity: 1; }\n'
b = c.index(b_marker) + len(b_marker)
c = c[:a] + "\n" + c[b:]

# 2) 部件浮窗样式（.mb-widget / .mb-pop / .mb-corebars / .mb-kv / .mb-spark / .mb-ring）
a = c.index("/* ---------- 菜单栏部件浮窗 ---------- */")
b_marker = ".mb-ring svg { width: 54px; height: 54px; flex: 0 0 auto; }\n"
b = c.index(b_marker) + len(b_marker)
c = c[:a] + c[b:]

# 3) 响应式里的两条残留
c = c.replace("  .mb-menu { display: none; }\n  .mb-widget.net { display: none; }\n", "")

# 4) 面板上方给状态栏留的 12px 间距去掉
c = c.replace(".panel-mock {\n  margin-top: 12px;\n", ".panel-mock {\n  margin-top: 0;\n", 1)

# 5) 注释同步
c = c.replace(
    "/* 开合动画：从菜单栏图标那个锚点展开 / 收回 */\n"
    "/* 开合由 assets/motion.js 的 WindowReveal 等价实现驱动（scale .90、\n"
    "   锚点 = 菜单栏图标投影、开 caEaseOut / 收 caEaseIn、时长 = openDuration）。 */",
    "/* 开合动画：从状态栏右侧那个锚点展开 / 收回 */\n"
    "/* 由 assets/motion.js 的 WindowReveal 等价实现驱动（scale .90、\n"
    "   锚点 = 状态栏右侧 (1,0)、开 caEaseOut / 收 caEaseIn、时长 = openDuration）。\n"
    "   模拟 Mac 状态栏已删除，面板常驻可见，进场播一次展开；\n"
    "   收回参数仍由预览浮层的 revealOut 复用。 */",
)
css.write_text(c, encoding="utf-8")
print("  ok", css.relative_to(ROOT), "（删除 .menubar-mock / .mb-* 样式）")

# ---------------- site.js ----------------
js = FRONT / "assets" / "site.js"
j = js.read_text(encoding="utf-8")

# 头部说明
j = j.replace(
    "   · 菜单栏模拟：点小猫展开真实面板截图\n",
    "   · 可交互主面板：常驻展示，进场播一次 WindowReveal 展开\n",
    1,
)

# 菜单栏模拟整段 → 面板常驻
a = j.index("  /* ---------------- 菜单栏模拟 ---------------- */")
b = j.index("  /* 玻璃高光跟随指针")
new_panel = '''  /* ---------------- 可交互主面板（常驻展示） ---------------- */

  var panelMock = $("#panelMock");

  /* 模拟的 Mac 状态栏已整条删除（用户：「需要完全删掉」），
     所以没有小猫开关、没有 CPU/网络/电池假部件，也没有部件详情浮窗。
     面板常驻可见；进场时仍播一次 WindowReveal 展开，锚点 (1,0)＝状态栏右侧，
     与 App 的 PanelController.revealUnit 兜底值一致。
     收起动画由预览浮层继续复用同一套 revealOut 参数（closePreview）。 */
  if (panelMock) {
    panelMock.hidden = false;
    Motion.revealIn(panelMock, {
      unit: Motion.panelAnchor(null, panelMock),
      scale: Motion.tokens.revealScale.panel,
      duration: Motion.openDuration(),
      timing: "caEaseOut"
    });
    document.addEventListener("keydown", function (e) {
      if (e.key === "Escape") closePreview();
    });
  }

'''
j = j[:a] + new_panel + j[b:]

# 部件浮窗整段删除
a = j.index("  /* ---------------- 部件浮窗 ---------------- */")
b = j.index("  /* ---------------- 可交互主面板（对齐真机 PanelRootView） ---------------- */")
j = j[:a] + j[b:]

js.write_text(j, encoding="utf-8")
print("  ok", js.relative_to(ROOT), "（删除小猫开关 / WIDGETS / 部件浮窗）")

# ---------------- 校验 ----------------
for name, needle in [
    ("index.html", "menubar-mock"),
    ("index.html", "mbIcon"),
    ("index.html", "mbPop"),
    ("assets/site.js", "WIDGETS"),
    ("assets/site.js", "mbIcon"),
    ("assets/site.js", "closeWidgetPop"),
    ("assets/site.css", ".menubar-mock"),
    ("assets/site.css", ".mb-widget"),
    ("assets/site.css", ".mb-pop"),
]:
    p = FRONT / name
    if needle in p.read_text(encoding="utf-8"):
        raise SystemExit("残留 %s in %s" % (needle, name))
print("  残留检查通过")
