# 交给 CodeX 的任务书：把所有窗口的「红绿灯」彻底统一

> 这份文件本身就是提示词。把整篇丢给 CodeX 即可，不需要再补充上下文。
> 写作时间：2026-11-09。对应代码版本：v272。

---

## 0. 你的任务（一句话）

在这个 macOS 应用里，**红绿灯（窗口左上角红黄绿三个按钮）仍然存在显示异常**。请你独立排查、定位、修复，并**逐窗口**给出截图证据。不要只改一个窗口就交付。

用户的原话（多次反馈，情绪已经很不好了）：

> 「红绿灯按钮还是会出现一个情况……特别是现在统一的这些所有页面里，需要一个一个统一，一个一个查，这些界面之前已经全部修过一次了，它现在还是不统一。」
>
> 「设置的第一页的常规也需要进行拆分……同时还有点，就是当前它的一个红绿灯按钮还是会出现一个情况。」

也就是说：**不是某一个窗口坏了，而是「有的窗口正常、有的窗口不正常」，且反复修过多次仍然复发。**

---

## 1. 项目是什么

- **产品**：Kitnest（旧名 FrsetNext），一个 macOS 菜单栏效率工具。功能包括：剪贴板历史、截图 / 钉图 / 图帘 / 录屏、文件中转（局域网 + 手机扫码 + 云端）、全局搜索与 AI、性能监测（CPU/内存/GPU/磁盘/网络/传感器/电池）。
- **技术栈**：纯 Swift，SwiftUI + AppKit 混写；**没有 Xcode 工程**，用 `apps/FrsetNext/build.sh` 调 `swiftc` 全量手工编译（约 3.5–4 分钟），产物 `build.noindex/Kitnest.app`，构建脚本会把产物原子部署到 `/Applications/Kitnest.app`。
- **源码根**：`apps/FrsetNext/Sources`，按 `Core/`（基础设施）与 `Features/`（业务模块）分层。
- **Bundle ID**：`com.sxyq.frsetnext`。应用是菜单栏常驻型（有主面板，不是普通文档 App）。
- **系统**：macOS 27（这是关键——它的红绿灯画法与旧版 macOS 不同）。
- **显示器**：两台（2560×1440 主屏 + 2560×1664 Retina），窗口可能落在任意一台，截图必须按窗口 ID 抓，不要按屏幕坐标猜。

### 1.1 与红绿灯直接相关的四个文件

| 文件 | 职责 |
|---|---|
| `Sources/Core/UI/OfficialWindowChrome.swift` | **全 App 唯一窗口外观入口**：`applyOfficialChrome(glassBacking:lights:titlebar:)`、`setOfficialContent(_:)`、`OfficialChrome.titlebarInset = 32` |
| `Sources/Core/UI/RoundCloseButton.swift` | `restoreStandardTrafficLights(policy:)`：恢复/隐藏系统三钮（会拆掉历史自绘圆钮） |
| `Sources/Core/UI/LiquidGlass.swift` | `installUnifiedGlassBackground()`：给窗口装统一玻璃底（v272 改过挂载位置，见 §3.2） |
| `Sources/Features/Settings/Shell/SettingsWindowController.swift` | 设置窗本身（940×752，fullSizeContentView） |

当前 `applyOfficialChrome` 的核心逻辑（v272 版）：

```swift
func applyOfficialChrome(glassBacking: Bool = true,
                         lights: OfficialChromeLights = .standard,
                         titlebar: OfficialChromeTitlebar = .native) {
    isOpaque = false
    backgroundColor = .clear
    switch lights {                       // 补齐能力位，见 §3.1
    case .standard, .fixed: styleMask.formUnion([.closable, .miniaturizable, .resizable])
    case .hidden: break
    }
    titlebarAppearsTransparent = (titlebar == .custom)
    titlebarSeparatorStyle = .none        // 统一去掉系统分隔线
    if glassBacking { installUnifiedGlassBackground() }
    restoreStandardTrafficLights(policy: lights == .hidden ? .hidden : .enabled)
}

func setOfficialContent(_ view: NSView) {  // 换内容后必须重挂玻璃
    contentView = view
    installUnifiedGlassBackground()
}
```

**设计约束（用户明确要求，不要破坏）**：所有窗口只允许通过 `applyOfficialChrome` 设置外观，不允许任何窗口自己写一套 `isOpaque / backgroundColor / titlebarAppearsTransparent / 自绘圆钮`。发现例外就是 bug。

---

## 2. 用户遇到过的问题（按时间线，帮助你理解「为什么改了这么多次」）

1. **最早**：应用用自绘灰色圆钮 + 把系统三钮 `alpha = 0` 隐藏。用户要求「其他界面也需要统一这种红绿灯，单独窗口都要加」。
2. **v205**：改成系统原生红绿灯。之后出现「一颗是粉红实心、另外两颗是空心灰圈」。
3. **v260**：怀疑玻璃底与系统标题栏材质叠加导致「颜色分层」，去掉自动分隔线、让玻璃避开标题栏。**问题仍在**。
4. **v269–v271**：发现设置窗的 `styleMask` 少了 `.miniaturizable/.resizable`，补上后三颗灯变实心。以为解决。
5. **v272（现在）**：又发现第二个根因（见 §3.2），改了玻璃底挂载位置。用户实测**仍然存在问题**。
6. 期间用户反复强调：「一个界面一个界面查」「之前已经全部修过一次了，现在还是不统一」。

**用户能看到的三个具体症状**（请以此为准去复现）：

- **症状 A**：某些窗口三颗灯是**空心灰圈**，点不动（尤其黄、绿）。
- **症状 B**：某些窗口只有**一颗灯**（或两颗），其余不见；或标题被挤到窗口左边缘、被裁掉一截。
- **症状 C**：各窗口的灯**位置 / 大小 / 间距 / 是否有分隔线**不一致；深浅色下表现不同。

---

## 3. 已经查明的三个根因（有实证，请在此之上继续，不要从零重查）

### 3.1 根因一：styleMask 缺能力位 → 系统把按钮判为禁用 → macOS 27 画成空心环

- 证据：设置窗修复前日志 `style=32771`（只有 titled + closable + fullSizeContentView），黄/绿两个按钮 `isEnabled == false`；补上 `.miniaturizable/.resizable` 后 `style=32783`，三颗灯恢复实心。
- 已处理：`applyOfficialChrome` 现在统一 `formUnion([.closable, .miniaturizable, .resizable])`。
- **仍需你确认**：有没有窗口在 `applyOfficialChrome` **之后**又覆盖了 `styleMask`（例如 `win.styleMask = [...]` 赋值，而不是 `formUnion`），把能力位又抹掉。全库搜 `styleMask =` 赋值语句。

### 3.2 根因二：玻璃底插进 NSThemeFrame → 带可见标题的窗口标题栏整体左移

- 现象：标题文字从窗口左边缘外面开始（第一个字被裁掉），三颗灯只剩一颗或不显示。
- 最小样例实证（`/tmp` 下独立 Swift 程序，四组窗口对比）：

| 组 | 配置 | 结果 |
|---|---|---|
| A | 普通 titled 窗口，无玻璃 | 标题栏正常 |
| B | 同上 + 往 `contentView.superview`（NSThemeFrame）插一个子视图 | **标题被裁、三灯消失** |
| C | B + `titlebarSeparatorStyle = .none` | 同样坏（与分隔线无关） |
| D | B + `titleVisibility = .hidden` | 灯正常（没有标题可裁） |
| E | 玻璃插进 `contentView` 最底层 | **标题栏正常、三灯正常** |

- 已修：`installUnifiedGlassBackground` 按窗口类型分流——`fullSizeContentView` 的窗口照旧铺主题框架（并避开原生标题栏），其它窗口把玻璃插进 `contentView` 最底层。
- **仍需你确认**：是否还有别的代码路径直接往 `contentView.superview` 加视图（全库搜 `contentView?.superview`、`.superview?.addSubview`）。

### 3.3 根因三：「非激活窗口三灯变空心」是系统行为，不是 bug

- 用系统原生 TextEdit 做基准：激活时三灯实心彩色，切到别的 App 后三颗统一变成空心/描边样式。本应用与之完全一致。
- **所以验收时必须先把应用激活再截图**，否则会把系统行为当成 bug（我上一轮就被这个坑过一次）。

---

## 4. 现状：v272 已经改了什么（避免你重复劳动）

- 统一入口 `applyOfficialChrome(glassBacking:lights:titlebar:)`，能力位在入口里补。
- 新增 `setOfficialContent(_:)`：先换内容、再重挂玻璃；下列窗口已改用它：统计窗、工具运行窗、全部应用库、归档任务队列、设置区块预览、截图历史、创建压缩包（部分）。
- 统一顶部净空 `OfficialChrome.titlebarInset = 32`：欢迎窗、更新说明、权限引导、全部应用库、统计窗（原来是 58）。
- 命令面板（`CommandPalette`，nonactivatingPanel）改为 **隐藏三颗灯**——它永远不是 key window，摆着只会是假按钮。
- 录屏编辑窗 `RecordingEditorWindow` 此前**完全没走**统一外观，已补。
- 玻璃底挂载位置已按 §3.2 分流。

### 4.1 当前窗口清单（21 个创建点，含常驻面板）

**内容型窗口（应该有红绿灯）**

| 窗口 | 文件:行 | styleMask | 备注 |
|---|---|---|---|
| 设置窗 | `Settings/Shell/SettingsWindowController.swift:166` | T C M R F | 940×752，fullSize |
| 统计窗 | `StatusBar/StatisticsWindowController.swift:21` | T C M R F | 固定尺寸 800×530，`lights: .fixed` |
| 截图历史 | `Capture/History/CaptureHistoryView.swift:262` | T C M R | 620×452，点外面自动关 |
| 任务队列 | `Archive/UI/ArchiveProgressPanel.swift:234` | T C M R | 400×290 |
| 创建压缩包 | `Archive/UI/ArchiveCreateSheet.swift:392` | T C | 固定 460×520，`lights: .fixed` |
| 归档浏览 | `Archive/UI/ArchiveBrowserWindow.swift:887` | 由 `contentViewController` 创建后赋值 | |
| 归档 Mini | `Archive/UI/ArchiveMiniWindow.swift:270` | 同上 | 360×420 |
| 存储管理 | `Monitor/Storage/StorageManagerWindow.swift:68` | 同上 | 1080×720 |
| 剪贴板条目编辑 | `Clipboard/UI/ClipboardItemEditWindowController.swift:105` | T C M R | 560×420，level = .floating |
| 工具运行窗 | `Toolbox/Tools/ToolRunnerWindow.swift:49` | T C M R F | |
| 全部应用库（投屏） | `TransferDock/Cast/CastAppLibraryWindow.swift:22` | T C M R F | |
| 录屏编辑窗 | `Recording/RecordingEditorWindow.swift:61` | T C M R | 纯 AppKit 布局 |
| OCR 结果窗 | `Capture/OCR/ScreenshotOCRWindow.swift:248` | T C M R F | `titlebar: .custom`（自绘标题） |
| 美化窗 | `Capture/Annotation/BeautifyPanel.swift:174` | T C M R | |
| 标注编辑窗 | `Capture/Annotation/AnnotationEditorWindow.swift:1468` | T C M R | |
| 长截图预览 | `Capture/LongScreenshot/LongScreenshotPreviewWindow.swift:228` | T C M R | |
| 云链中心 | `Panel/CloudLink/CloudLinkCenter.swift:777` | T C M R | |
| 欢迎窗 | `Onboarding/WelcomeWindowController.swift:65` | T C M R F | `lights: .fixed` |
| 更新说明 | `Onboarding/WhatsNew.swift:191` | T C M R F | `lights: .fixed` |
| 权限引导 | `Onboarding/PermissionGuideWindowController.swift:51` | T C M R F | `lights: .fixed` |
| 设置区块预览（开发用） | `Settings/Shell/SettingsBlockProbeWindow.swift:66` | T C M R | 深链 `kitnest://settingsprobe?block=` |

**有意没有红绿灯的窗口（不要给它们加灯）**

- 主面板 `PanelController`、`MonitorPopout`：borderless 浮层，靠自定义拖动/关闭。
- `Toast`、`ArchiveTaskHUD`、`LongScreenshotHUD`、`ColorValuePanel`、`RecordingHUD`、`CastControlBar`：borderless + nonactivatingPanel 的 HUD。
- `FileHoverPreview`：`utilityWindow + nonactivatingPanel`，三钮应 `isHidden = true`。
- `CommandPalette`：nonactivatingPanel，已改为 `lights: .hidden`。

---

## 5. 仍然没解决的问题（你的主战场）

用户说「还是存在问题」，但没给截图。请按下面顺序做，**每一步都要有证据**：

1. **先复现**：把 21 个窗口逐个打开，在**激活状态**下截图，标注三灯是否齐全、是否实心、是否可点、标题是否被裁、内容是否被灯压住。
   - 若发现异常窗口，先做**最小复现**（`/tmp` 下独立 Swift 程序，只保留该窗口的 styleMask + chrome 调用），确认是「窗口配置」问题还是「应用别处代码」问题。
2. **重点怀疑清单**（按概率排序，逐条验证，不要凭感觉改）：
   - a. `titlebarAppearsTransparent = true` 的窗口（OCR/命令面板/浮层）——透明标题栏下内容会画到灯下面，灯被内容盖住。
   - b. `contentView` 在窗口 show 之后被**再次替换**（SwiftUI 重建、`installContent` 二次调用），玻璃底挂在旧视图上，顺手把标题栏层级带乱。
   - c. 固定尺寸窗口：`contentMin/MaxSize` 锁死但 `styleMask` 里 `.resizable` 还在，系统可能把绿灯判成「不可用」。
   - d. `.utilityWindow` / `.nonactivatingPanel`：这类窗口无法成为 key，系统会给「未激活」画法（空心）；如果还显示灯就是错的。
   - e. 窗口在 `applyOfficialChrome` 之后又设置了 `styleMask`（赋值而非 `formUnion`）。
   - f. 深色 / Midnight 主题下，玻璃底与标题栏材质叠加出「双层颜色」。
3. **修的时候守住三条**：
   - 只在 `OfficialWindowChrome` / `LiquidGlass` / `RoundCloseButton` 三处改，不要给单个窗口写特例（除非它是「有意例外」，要写进代码注释）。
   - 每次改完必须 `./build.sh`（约 4 分钟），然后**逐窗**重截。
   - 不许用「看起来对了」当结论，要有像素级证据（见 §6.3）。

---

## 6. 环境、命令与验收方法

### 6.1 构建

```bash
cd /Users/sunyiyang/Desktop/Project/frset-rebuild/apps/FrsetNext
./build.sh          # 约 3.5–4 分钟；成功末尾会打印「签名: 已签名 ✓」
pkill -x Kitnest; sleep 2
open build.noindex/Kitnest.app
```

### 6.2 打开各个窗口（不要用鼠标点，用深链）

```bash
open "kitnest://settings?pane=general"          # 设置；pane 见下表
open "kitnest://statistics"                      # 统计窗
open "kitnest://tasks"                           # 归档任务队列
open "kitnest://capture?action=history"          # 截图历史
open "kitnest://monitor?module=cpu"              # 性能监测浮窗（borderless，无灯）
open "kitnest://demo?scene=welcome"              # 欢迎窗
open "kitnest://demo?scene=beautify&file=/tmp/x.png"  # 美化窗
open "kitnest://settingsprobe?block=recording"   # 设置区块预览（带可见标题，回归用）
osascript -e 'tell application "Kitnest" to activate'   # 激活（否则三灯是系统未激活样式）
```

设置深链全集：`general / general.startup / general.panel / general.windows / general.personalization / general.menubar / clipboard / clipboard.capture / clipboard.floating / transfer / transfer.cast / transfer.scan / transfer.cloud / transfer.local / capture / pin / curtain / recording / workflow / search / ai / tools / shortcuts / statistics / about / manual / monitor.<module>`。

### 6.3 截图与判定

```bash
# 列窗口（自己编译一次即可）
cat > /tmp/winlist.swift <<'EOF'
import CoreGraphics
import Foundation
let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
if let arr = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] {
    for w in arr where (w[kCGWindowLayer as String] as? Int ?? 0) == 0 {
        let owner = w[kCGWindowOwnerName as String] as? String ?? "?"
        let num = w[kCGWindowNumber as String] as? Int ?? -1
        let name = w[kCGWindowName as String] as? String ?? ""
        let b = w[kCGWindowBounds as String] as? [String: Any] ?? [:]
        print("\(num)\t\(owner)\t\(name)\t\(b["Width"] ?? "")x\(b["Height"] ?? "")")
    }
}
EOF
swiftc -O /tmp/winlist.swift -o /tmp/winlist

/tmp/winlist | grep Kitnest
screencapture -x -o -l <窗口ID> /tmp/win.png        # 按窗口抓（不含桌面）
screencapture -x -R<x>,<y>,<w>,<h> /tmp/region.png  # 按屏幕区域抓（看得到真实合成效果）
```

**判定标准（每窗都要过）**

1. 激活状态：三颗灯齐全、实心（红/黄/绿）、可点；位置与系统原生窗口一致（左上 20/40/60pt 附近，间距均匀）。
2. 标题：完整显示，不与灯重叠，不被窗口左边缘裁切；标题栏不出现「半透明黑带」或双层颜色。
3. 内容：顶部不被灯压住（`fullSizeContentView` 窗口内容顶部至少让出 32pt）；标题栏下分隔线只有一条或没有。
4. 非激活状态：三颗统一变空心/灰（这是系统行为），**不允许出现「一颗实心 + 两颗空心」的混合态**。
5. 深色 / Midnight 主题各截一次。

**截图陷阱（我踩过，你别踩）**

- `screencapture -l` 会把「透明标题栏」渲染成黑带，看起来像标题丢了；判定标题是否真的丢失要用 `-R` 区域截图，或再截一张激活态。
- `screencapture -l` 偶发报 `could not create image from window`，重试即可；窗口刚创建时等 2 秒。
- 两台显示器：窗口可能不在主屏，别用固定坐标猜。
- **不要用 `CGWarpMouseCursorPosition` / `CGEvent` 移动或滚动用户的鼠标**——用户明确禁止过。需要滚动就用深链（设置侧边栏会 `scrollTo` 选中项）。

---

## 7. 交付物

1. **根因说明**：每条异常对应哪一行代码、用哪个最小样例证明的。
2. **改动清单**：文件 + 行为变化（越少越好，能改一处不要改三处）。
3. **逐窗验收表**：21 个窗口 × 激活/非激活 × 浅色/深色，附截图路径；每个窗口给「灯齐全 / 实心 / 可点 / 标题正常 / 内容不被压」五项结论。
4. **回归说明**：设置深链、搜索跳页、玻璃四滑块（通透度/磨砂/卡片亮度/描边）是否仍生效。
5. 构建必须通过并部署到 `/Applications/Kitnest.app`。

---

## 8. 一句话总结给你（CodeX）

这是一个「统一外观入口已经存在、但仍有窗口没走对」的问题。请把它当成**取证任务**而不是**改样式任务**：先证明每个窗口到底哪里不对，再动最小的代码。用户已经来回修过五六次，这次要的是逐窗截图钉死的结论。
