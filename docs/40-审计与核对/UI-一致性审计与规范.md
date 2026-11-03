# FrsetNext UI 一致性审计与设计规范（v179）

> 依据 `docs/40-审计与核对/数据表/FrsetNext-函数清单.csv`（11,562 个成员 / 144 个 View·Panel·Window 类型）
> 全量扫描源码得出，不是抽样。审计日期 2026-11-02。

## 一、审计结果（改前）

| 维度 | 实测 | 结论 |
|---|---|---|
| 圆角取值 | **17 种**：1 / 1.5 / 2 / 3 / 4 / 5 / 6 / 7 / 8 / 9 / 10 / 11 / 12 / 14 / 16 / 19 / 24 | 6 有 33 处、7 有 24 处、8 有 20 处——相邻卡片差 1pt，边界对不齐 |
| 玻璃覆盖 | 50 个含窗口定义的文件里，**只有 4 个**真正用了 NSVisualEffectView / NSGlassEffectView | 浮层各写一套：命令面板 99% 实色、云链接 14pt + regularMaterial、悬停预览私有 VisualEffectBackground、文件盒无底 |
| 窗口外观 | 文档窗分两派：13 处 `applyOfficialChrome()`，其余用系统默认样式（归档任务窗是唯一裸 NSWindow） | 「官方灰底 + 透明标题栏 + 圆钮」没覆盖全 |
| 字号 | 11pt 523 处、12pt 111 处、13pt 70 处，另有 5/7/7.5/8/9/9.5/10.5/13.5 共 26 处游离值 | 正文主力是 11/12/13，游离值多为图标尺寸，影响小 |
| 卡片底 | 三种写法：`Color.primary.opacity(0.03)`、`.regularMaterial`、`Theme.cardBackground` | 同一层级的卡片在不同模块观感不同 |
| 描边 | 0.5pt 为主，另有 1pt、0.15/0.12/0.10 三种透明度混用 | 需要统一发丝线 |

## 二、规范（实现于 `Core/UI/Support.swift` 的 Theme 与 `Core/UI/LiquidGlass.swift`）

### 1. 圆角只有五档

| 令牌 | 值 | 用途 |
|---|---:|---|
| `Theme.Radius.window` | 12 | 窗口 / 悬浮面板 |
| `Theme.Radius.card` | 10 | 内容卡片（设置分组、统计卡、流向图卡） |
| `Theme.Radius.control` | 8 | 控件底（按钮、输入框、缩略图容器） |
| `Theme.Radius.chip` | 6 | 小标签 / 徽标 |
| `Theme.Radius.micro` | 4 | 进度条端点、极小色块 |

胶囊一律 `Capsule()`，不写数值。

### 2. 玻璃分两层（HIG：玻璃表达层级，不做装饰）

| 层级 | 实现 | 用在哪 |
|---|---|---|
| 结构面 | `LiquidGlass.makeView(...)` / `.glassPlate()`：macOS 26+ 真玻璃（NSGlassEffectView），旧系统回退毛玻璃；「降低透明度」或个性化选纯色时退化为不透明底 | 主面板、监测窗、命令面板、云链接弹窗、悬停预览、文件盒、Toast、HUD |
| 内容卡片 | `.glassCard()`：极淡填充 + 0.5pt 发丝线，**不叠模糊** | 卡片、分组、统计块 |

> 为什么卡片不叠玻璃：叠层模糊既费 GPU，又会把卡片里的正文糊掉。Apple 自己在
> 控制中心/通知中心也是「结构面玻璃 + 内容面镀边」。

### 3. 描边与填充

- 发丝线：`Theme.Stroke.hairline = 0.5`，颜色 `Theme.hairlineColor = Color.primary.opacity(0.10)`（浅色=黑 10%，深色=白 10%）。
- 卡片填充：`Theme.cardFill = Color.primary.opacity(0.045)`。

### 4. 字号与间距

- 字号：micro 10 / caption 11 / small 12 / body 13 / title 15 / metric 17。正文不得低于 11。
- 间距：2 / 4 / 6 / 8 / 12 / 16 / 20（`Theme.Space`）。

### 5. 文档窗口

一律 `applyOfficialChrome()`：官方灰底（`OfficialChrome.windowBackground`）+ 透明标题栏 + 自绘圆形关闭钮。
新增窗口不调用它 = 一眼看出是"外来的"。

## 三、本批已改

| 项 | 改动 |
|---|---|
| 令牌 | 新增 `Radius.window/card/micro`、`Stroke`、`Space`、`hairlineColor`、`cardFill`、`TextSize.micro/metric` |
| 玻璃基础设施 | 新增 `.glassPlate()`、`.glassCard()`、`NSWindow.adoptGlassSurface()`；统一走 `LiquidGlass`（26+ 真玻璃） |
| 命令面板 | 99% 实色 → 统一玻璃；补 `.fullSizeContentView` + 隐藏标题（否则露出白条） |
| 云链接弹窗 | `regularMaterial + 14pt` → 统一玻璃 12pt |
| 悬停预览 | 删除私有 `VisualEffectBackground` → `LiquidGlassBackground` |
| 归档文件盒 | 补玻璃底（原来是透明窗口，浅色桌面下发灰） |
| 归档任务窗 | 裸 `NSWindow` → `applyOfficialChrome()` |
| 归档迷你窗 | 补 `applyOfficialChrome()` |
| 投放应用库 | 补 `applyOfficialChrome()` |
| JSON 检查器 | 只设底色 → `applyOfficialChrome()` |
| 圆角归一 | 44 处 `5/7/9/11/14/16` → 令牌；取值从 **17 种降到 12 种**（剩余 1/1.5/2/3 是微元素，19/24 是 HUD 与截图圆角，属有意例外） |
| 关闭钮 | 静置时只有一颗灰圆点（截图里像"脏点"）→ × 常驻（0.55），悬停加深到 0.95；**v181**：× 提到 0.8/粗 1.35 + 发丝描边 + 直径 13pt（无标题栏窗内缩 16pt），一眼认得出是关闭键 |

## 四、仍未统一（下一批，按收益排序）

| 项 | 现状 | 建议 |
|---|---|---|
| ~~卡片底三套写法~~ | **v181 已清零**：卡片/分组块/行卡 → `.glassCard()`（含裁切与发丝线）；小控件/条/胶囊 → 统一 `Theme.cardFill`；结构浮层（标注工具条/竖栏、中转二维码浮层）→ `.glassPlate()`。唯一有意例外 = 电池能量图的纹理卡底（渐变 + 网格，属设计件，不是普通卡片） | ~~逐步换成 `.glassCard()`~~ |
| 字号游离值 | 26 处 5–10.5（多为图标尺寸） | 图标不算文本，可保留；文本类统一到 10/11 |
| 圆角字面量 | **v181 已清零**（57 处 4/6/8/10/12 → `Theme.Radius.*`，像素完全等价） | — |
| Toast | 自绘胶囊（深色 0.135 / 浅色 0.99）+ 阴影 | 与浮层玻璃统一，或明确作为「HUD 例外」 |
| 投放控制条 | 固定黑 55%（视频上必须高对比） | 记为 HUD 例外，不参与玻璃统一 |
| 主面板圆角 | 走个性化 6/10/14 | 默认值建议改成 12，与窗口档一致 |
| 长截图 HUD / 延迟 HUD | 24pt 大圆角圆形 | HUD 例外，保留 |
| 归档浏览窗 | 保留系统红绿灯（主文档窗需要缩放/全屏） | 有意例外，已在文档注明 |

## 五、防复发（已落地为可执行检查）

三条规则已做成静态检查，随 `./check.sh` 一起跑，**新增一条即失败**（退出码 1）：

| 规则 | 检查什么 | 当前存量 | 通过条件 |
|---|---|---|---|
| R1 圆角字面量 | `cornerRadius: 7` 这类硬编码 | **0**（零容忍） | 取 `Theme.Radius.*`；微元素 1/1.5/2/3 放行 |
| R2 自拼浮层背景 | `.regularMaterial` / `NSVisualEffectView(` | **1**（豁免） | 走 `.glassPlate()` / `.glassCard()` / `LiquidGlass.makeView()` |
| R3 文档窗缺统一外观 | 建了 `.titled/.closable/.resizable` 窗口却既没 `applyOfficialChrome()`、也没显式 `backgroundColor` | **0** | 两者其一 |

- 脚本：`apps/FrsetNext/tools/ui_lint.py`；基线：`tools/ui-lint-baseline.txt`（按「文件 + 规则 + 条数」记账，只允许减少）。
- 确属例外（例如浮在照片上的 material 胶囊）→ 在基线里保留并写明理由，不要图省事跑 `--update-baseline` 一把刷掉。
- 单独跑：`python3 apps/FrsetNext/tools/ui_lint.py`（`--report` 只打印不改退出码）。

### 仍然靠人盯的部分

- 新浮层别自己拼 `clear + RoundedRectangle.fill(...)`：这条正则判不准，靠评审。
- 新文档窗**除** `applyOfficialChrome()` 外，窗口尺寸别再交给 SwiftUI 反推：
  `NSHostingController` 会把窗口压成 fittingSize（任务队列窗被压到 189pt 宽、122pt 高过）。
  独立小窗的正确姿势是「朴素 NSView 当 contentView + NSHostingView 铺满」，
  尺寸由 `setContentSize` 说了算。
- 记住窗口位置**只存 origin**，不要 `setFrameAutosaveName`：它连尺寸一起恢复，
  旧版本压出来的坏尺寸会被继承，而且恢复发生在 `setContentSize` 之后（设了也没用）。

### 自绘圆钮（v182 补）

- **热区 24pt、视觉 13pt**。13pt 的圆差 2px 就落到标题栏、变成拖窗口，
  用户读作「关不掉」（任务队列窗的实测反馈）。要放大只改热区，别改视觉直径。
- `acceptsFirstMouse = true`：App 在后台时首击直接生效，不再先「激活」一次。
- **别指望 `performClose`**：红绿灯是用 `alphaValue = 0` 隐藏的，而 alpha=0 会让
  AppKit 把 `isEnabled` 置回 false —— 此时 `performClose(_:)` 静默变空操作
  （实测 `isVisible` 仍为 true）。自绘圆钮就是这些窗口唯一的关闭出口，
  它的 action 走 `frsetRoundCloseTapped`（先问 `windowShouldClose`，再 `close()`）。
