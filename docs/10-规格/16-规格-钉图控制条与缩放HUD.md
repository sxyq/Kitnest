# 16 - 规格：钉图（贴图）控制条与缩放 HUD

> 2026-10-15。依据 11 号总纲 §2 任务书。全部结论来自 `/tmp/frset-re/`（Frset.arm64 arm64 切片 + disasm.txt + allstrings-addr.txt）静态反汇编，逐条附证据地址。
> 方法论突破（本次探索产出，可供后续代理复用）：
> 1. **chained-fixups selref 可解码**：`__objc_selrefs` 表项原始 u64 的低 38 位 = 目标 VA 偏移（image base 0x100000000），直接解出 `__objc_methname` 选择器名（任务书称"暂不可解码"已过时）；
> 2. **`__objc_stubs` 桩可解码**：桩首条 `adrp x1, page` + `ldr x1,[x1,#off]` → selref VA → 选择器名。全量解码表 `/tmp/frset-re/stub2sel4.txt`（2377 条）；
> 3. **相对方法表可解码**：`__objc_methlist` 头 = `u32(0x80000000|entsize12), u32(count)`；条目 `(selRel, typesRel, impRel)` 各 int32，selRel 指向 `__objc_selrefs`，impRel 有符号相对条目地址。由此获得每个 Pin 类的完整 @objc 方法表（含 imp 地址）。
> 用词勘误：原作用语为「**贴图**」（0x100b57b80 "优化截图与贴图体验。"，v1.3.12 changelog；截图动作 "Screenshot and Pin" → zh-Hans "截图并贴图"），类名 PinnedScreenshot*。
> **补丁（zh-Hans lproj 交叉验证，2026-10-15）**：钉图全部 UI 文案均为 `Localizable.strings` 本地化键（英文键面 = 代码内小串立即数，中文值实译）：
> `Zoom→缩放`、`Annotate→标注`、`Extract Text→提取文字`、`Translate→翻译`、`Save→保存`、`Close→关闭`、`Right-click for more actions→右键查看更多操作`、`Text Recognition Failed→文字识别失败`、`Failed to load image→无法加载图片`、`No text recognized→未识别到文字`。
> 重建时须走 L10n（docs/10-规格/18 基建），键面用上列英文句。

---

## 1. 功能点表

| # | 功能 | 状态 | 一句话规格 |
|---|---|---|---|
| F1 | 贴图窗（NSPanel） | ✅ | 浮动层级、无阴影、透明背景、可 join all spaces、成为 key 时通知 Manager |
| F2 | 悬停显示控制条 | ✅ | mouseEntered/moved/dragged/menu 均触发显示 + **2.0s 单发定时器自动隐藏** |
| F3 | 右键动作菜单 | ✅ | Zoom▸(200/150/100/50%) + 分隔线 + Annotate/Extract Text/Translate/Save + 分隔线 + Close |
| F4 | 滚轮/双指捏合缩放 | ✅ | scrollWheel + magnifyWithEvent，**以鼠标位置为锚点**缩放 |
| F5 | 缩放档位菜单 | ✅ | Zoom 子菜单 4 档（静态 Int 表 [200,150,100,50]，标题 "\(n)%"，scale=n/100） |
| F6 | 缩放 HUD | ✅ | 56×28 子窗口，钉图**正中心**，12pt semibold 百分比文本，click-through |
| F7 | 边缘拖拽调尺寸 | ✅ | 四边+四角 ~10pt 手柄带，leftRight/upDown/对角光标，body 区拖动=移动窗口 |
| F8 | 小模式（small mode） | ✅ | **宽<200pt 或 高<60pt** 即进入；控制条不可用，交互走右键菜单 |
| F9 | 小模式一次性提示 | ✅ | 进入小模式时弹 TipWindow："Right-click for more actions"；UserDefaults 一次性标记 |
| F10 | 键盘关闭 | ✅ | 本地 keyDown 监听 Esc(53)/Delete(51)/ForwardDelete(117) 三键 |
| F11 | 贴图内 OCR | ✅ | Extract Text 动作；失败态显示 "Text Recognition Failed" + SF Symbol exclamationmark.circle.fill |
| F12 | 多贴图管理 | ◐ | Manager 单例 + 窗口数组 + 本地事件监听；数组上限/内存策略 ⬜ |

---

## 2. 类清单（9 类，含证据地址）

类名串（`__objc_classname`，mangled）聚簇于 `0x100accc10–0x100accdd0`：

| 类 | 证据 | 职责（由方法表+函数体实证） |
|---|---|---|
| `PinnedScreenshotManager` | 类名 0x100accd70；methlist 0x100957fa0（仅 init/dealloc/.cxx_destruct @objc）；init imp 0x1003000e4；dealloc 0x1003001f8（removeMonitor: 0x10094f120） | 单例。持有窗口数组、本地 NSEvent 监听器、活动贴图弱引用； dealloc 时 removeMonitor |
| `PinnedScreenshotWindow` | 类名 0x100accda0；methlist 0x100957ed0 | NSPanel 子类。canBecomeKey/Main=true(0x100302164/0x10030216c)；becomeKeyWindow 0x100302174（super 后通知 Manager 0x10030152c）；constrainFrameRect:toScreen: 直通 super（0x1003021fc，允许任意摆放）；resignKeyWindow 0x100302350 |
| `PinnedScreenshotContentView` | 类名 0x100accc30；**methlist 0x100958200，count=26** | 核心交互视图。方法全集见 §3.1 |
| `PinnedScreenshotControlsWindow` | 类名 0x100accdd0；methlist 0x100958580 | 控制条承载窗。canBecomeKey/Main=true（0x1003024b4/0x1003024bc）；initWithContentRect 0x1003024c4 |
| `PinnedScreenshotControlsHostView` | 类名 0x100accc60；methlist 0x1009585f8（acceptsFirstMouse/initWithFrame/initWithCoder） | 控制条宿主视图（按钮布局由 ContentView 0x1002f7fc4 驱动） |
| `PinnedScreenshotSmallCloseButton` | 类名 0x100accc90；methlist 0x100958628（initWithFrame 0x1002fdd18、handleClick 0x1002fdad4、intrinsicContentSize 0x1002fdac8、rightMouseDown 0x1002fda28） | 小尺寸模式下的关闭按钮（自绘，handleClick 动作） |
| `PinnedScreenshotScaleHUD` | 类名 0x100acccc0；methlist 0x1009580b8 | HUD 视图。intrinsicContentSize=**56×28**（0x1002fe124：0x404c…=56.0, 28.0）；hitTest:=nil（0x1002fe11c，click-through）；acceptsFirstResponder=false；drawRect 0x1002fe3cc→0x1002fe134；字体 **systemFont 12pt semibold**（0x1002fe0ac/0x1002fe09c _NSFontWeightSemibold） |
| `PinnedScreenshotSmallModeTipWindow` | 类名 0x100accd40；methlist 0x1009587f0 | 提示窗。init 0x1002fef54；canBecomeKey/Main=true；windowWillClose（0x10044f858）；needsPanelToBecomeKey（0x1000d87d8） |
| `ScaleMenuButton` | **⬜ 未发现该类**。`__objc_classname`/全字符串段均无 `ScaleMenuButton` mangled 名（0x100accc10–dd0 聚簇中缺席） | 任务书所列名称在 1.3.12 arm64 中不存在；缩放档位菜单为代码内联构建（0x1002f998c），非独立按钮类 |

私有类型：`PinnedScreenshotTipHostingView`（`_TtC5FrsetP33_64E1BD…30PinnedScreenshotTipHostingView`，0x100acccf0）——TipWindow 的 SwiftUI 宿主。

---

## 3. 还原依据（四问逐条）

### 3.1 探明问题①：控制条出现条件与按钮集

**出现/消失（证据充分）**：
- `mouseEntered:` 0x1002fb60c → 0x1002fb564（显示）；`mouseExited:` 0x1002fb6b4 → 0x1002fabc4（隐藏，先做 `NSEvent.mouseLocation` 与控制条 `frame` 外扩 1pt（CGRectInset -1,-1）的包含测试 + alphaValue>0.01 判定，防抖）；
- `mouseMoved:` 0x1002f5030、`mouseDragged:` 0x1002f4a8c、右键弹菜单（0x1002f9f4c）、drawRect（0x1002f4108）、layout（0x1002f36e0）均调用显示路径 0x1002f8358（调用点共 9 处，da.py callers 实测）；
- **自动隐藏**：0x1002fb394 `scheduledTimerWithTimeInterval:repeats:block:` — `fmov d0,#2.0`（0x1002fb3e0），repeats=false，加入 `NSRunLoop.mainRunLoop` + `NSRunLoopCommonModes`（0x1002fb438/0x1002fb44c）→ **悬停停止交互 2 秒后隐藏**；
- 隐藏动画：`NSAnimationContext runAnimationGroup:`（0x1002fae6c/0x1002faffc）淡出 alpha → `setHidden:`(0x1002fb0c0) + `setIgnoresMouseEvents:true`(0x1002faebc/0x1002fb1d8)；显示路径先 cancel 旧 DispatchWorkItem（0x1002f83a4）并递增世代计数 [0xe88]（0x1002f83cc，防错序）。
- 控制条布局：按钮横排，**宽 28pt、间距 30pt**，起排 x≈85（0x1002f80b0 常量 89.0−4.0=85.0，0x1002f80e4 fmov d2,#28，0x1002f80fc fadd d10,d10,#30）；按钮视图来自 ContentView 持有的数组（0x1002f80d0 逐元素 setFrame）。

**按钮/菜单动作集（右键菜单完整实证，0x1002f9b6c）**：
```
Zoom ▸（子菜单 0x1002f998c，4 项，标题 "\(n)%"，representedObject=NSNumber(scale)，action=handleScalePreset: 0x100c3c848）
──────────
Annotate      action=annotateClicked   (selref 0x100c3c820)
Extract Text  action=ocrClicked        (selref 0x100c3c828)
Translate     action=translateClicked  (selref 0x100c3c830)
Save          action=saveClicked       (selref 0x100c3c838)
──────────（+separatorItem，0x10094ff40）
Close         action=closeClicked      (selref 0x100c3c840)
```
- 菜单标题字符串小串立即数解码：`More`(0x1002f9bac)、`Zoom`(0x1002f99cc/0x1002f9c08)、`Annotate`(0x1002f9ce8)、`Extract Text`(0x1002f9d0c–0x1002f9d34)、`Translate`(0x1002f9d38–0x1002f9d50)、`Save`(0x1002f9d5c)、`Close`(0x1002f9e64)。
- 菜单弹出：`popUpMenuPositioningItem:atLocation:inView:`（0x1002f9f4c 尾调 0x10094e1c0），弹出前调用隐藏逻辑（0x1002f8188+0x1002f8358）。
- **⬜ 控制条上悬停态按钮的图标资源名**：按钮图像经 `Int→String→NSImage(named:)` 动态取名（0x1002fc5c4：LosslessStringConvertible 描述 + `imageNamed:` 0x10094a1c0，失败则空图兜底），资源名为数字串（"1"…），具体资产目录内容未探明。

### 3.2 探明问题②：缩放档位表与 HUD 时序

**档位表（立即数组实证）**：`__DATA,__data @0x100c6bf48`：`200, 150, 100, 50`（Int64×4；数组头 count=4 @0x100c6bf38, capacity=8 @0x100c6bf40）。构建循环 0x1002f9a3c–0x1002f9b28：`scvtf d0,x28; fdiv d0,d8(=100.0)` → scale=值/100；标题 `"\(Int)%"`（CustomStringConvertible 描述 + append "%"，0x1002f9a68 mov w0,#0x25='%'）。
→ **Zoom 子菜单：200% / 150% / 100% / 50%**。

**滚轮/捏合缩放**：
- `scrollWheel:` imp 0x1002f596c；`magnifyWithEvent:` imp 0x1002f5560；共用缩放核心 0x1002f55b0：
  - 非 key 窗时先 `makeKeyAndOrderFront:`（0x1002f56b8）；
  - 读 `scrollingDeltaY`（0x1002f5734）；`hasPreciseScrollingDeltas`（0x1002f5798）分派灵敏度：精确滚轮常量 **3.5**、普通滚轮常量 **12.0**（0x1002f57a0/0x1002f57a4；⚠️ 精确除法方向为 delta/3.5，普通档为固定步进，符号已实证、系数语义按除法复原）；
  - 锚点：`locationInWindow`（0x1002f5838）+ `NSEvent.mouseLocation`（0x1002f5854）→ **以光标为锚缩放**；
  - 读 `phase`/`momentumPhase`（0x1002f5888/0x1002f5894）处理惯性；
  - 边界：最小 **50.0**（0x1002f59ec，0x4049…=50.0，最小窗宽 pt）与 1.0 比例钳制（0x1002f5a00–0x1002f5a38）。
- `handleScalePreset:` imp 0x1002fa188 → 核心 0x1002fa1d8：取 `window.screen`、计算内容内矩（0x1002faaec：rect(30,30,w−60,h−60)→convertRectToScreen）后按档位 scale 重设 `setFrame:display:`，受屏可见域钳制。
- 边缘拖拽调尺寸：`mouseDown:` 0x1002f454c 分类命中区（0x1002f4b58：内容内矩=rect(30,30,w−60,h−60)，边缘带宽 **10pt**，0x1002f4c04/0x1002f4c28 fmov ±10.0），返回 0–8 区号；`mouseDragged:` 0x1002f4a8c 按区改 frame（`setFrame:display:` 0x1002f4a50）；光标：`resizeLeftRightCursor`（0x1002f50d8）、`resizeUpDownCursor`（0x1002f5138）、两枚缓存自定义对角光标（0x1002f50c4/0x1002f510c swift_once 懒加载）、其余 `arrowCursor`。

**HUD 时序**：
- HUD 为钉图窗的**子窗口**（`addChildWindow:ordered:` 0x1002f79e4），`level` 拷贝父窗（0x1002f7910/0x1002f791c），`setIgnoresMouseEvents:true`（0x1002f7970），背景 clearColor、无阴影；
- 位置：钉图**正中心**——x=MidX(内容内矩)−28, y=MidY−14，尺寸 56×28（0x1002f961c–0x1002f9730，layout 时随窗口重算）；
- 显示/隐藏：随缩放（滚轮/捏合/档位）出现，layout `isHidden` 检查（0x1002f9648）；隐藏路径 orderOut+removeChildWindow（0x1002f7a7c/0x1002f7a98）。⬜ HUD 淡出延时定时器具体毫秒数未单独探明（疑似复用 2.0s 控制条定时器路径，未完全证实）。

### 3.3 探明问题③：小模式 TipWindow 触发与内容

**触发条件（调度器 0x1002f8838，全部实测）**：
1. 状态字节 [0xe90]==**1（小模式）**（0x1002f88a4 `cmp w8,#0x1`）；
2. 小模式判定谓词 **0x1002fe4d4**：`width < 200.0 || height < 60.0`（0x1002fe584 `0x4069…`=200.0、0x1002fe598 `0x404e…`=60.0，NaN/Inf 防御后 `mi` 判定）→ 状态 1；布尔入参直通返回 2；
3. 菜单未弹出 [0xda0]==false（0x1002f88b8）、无 pending work item（0x1002f88c8）、tip 未看过；
4. **UserDefaults 一次性标记**：key `"pinnedScreenshot.smallModeTipSeen_v2"`（字符串 0x100b4c270，引用点 0x1002f88f4 读 `boolForKey:` 0x100945960 / 0x1002f8c40 写 `setBool:forKey:` 0x100950940 w2=1）；
5. 调度：DispatchWorkItem 存字段 [0xe70]（0x1002f8a7c），DispatchQueue.main `async(execute:)`（0x1002f8ab0/0x1002f8abc）；执行块 0x1002fc5ac→0x1002f8aec（弱引用存活才显示，0x1002f8b18）；layout（0x1002f36e0→0x1002f8838）与控制条显示路径均会调度。

**Tip 内容与形态**：
- 文案：**"Right-click for more actions"**（cstring 0x100b43c30，引用 0x1002f8cfc；zh-Hans 值 **"右键查看更多操作"**，lproj 键面即此英文句）；即"贴图太小放不下控制条时，提示用户改用右键菜单"；
- 窗体：`PinnedScreenshotSmallModeTipWindow`（NSPanel，init 0x1002fef54；needsPanelToBecomeKey；windowWillClose 回调 0x10044f858）；
- 内容经 `PinnedScreenshotTipHostingView`（SwiftUI 宿主）承载，构建函数 0x1002fe828（传入文案 String + 字体 + dismiss 闭包 0x1002fc58c→淡出 0x1002fbe28+0x1002f8e40）；
- 显示时创建即写 UserDefaults 标记（0x1002f8db0–0x1002f8de0）；⬜ Tip 窗的精确尺寸/屏幕定位常量未完全解出（创建函数 0x1002ff470 内含 screen 换算 0x10094fa60 `screen`）。

### 3.4 探明问题④：多贴图管理

- **Manager 单例 + 窗口数组**：`PinnedScreenshotManager` init 0x1003000e4；dealloc 0x1003001f8 调 `removeMonitor:`（0x10094f120）——持有本地 NSEvent 监听器；
- **键监听**（0x1002ffb90 init 路径 `addLocalMonitorForEventsMatchingMask:handler:` 0x1002ffc2c）：handler 检查 `event.keyCode`：
  - **0x35=53 Esc**（0x1002fff98）、**0x33=51 Delete**（0x1002fffa8）、**0x75=117 Forward Delete**（0x1002fffbc）三键命中 → 经弱引用取 Manager（0x1002fffd8）执行关闭逻辑（0x100010628，数组操作）；
  - 另一路径（非三键）：先查鼠标位置命中的贴图（0x100385064 匹配）→ 取 `contentView` 动态cast `PinnedScreenshotContentView`（0x1002f3004 类访问器）→ 读小模式字节 [0xda0]==1 分流 —— Delete 键在贴图上的语义与"关闭全部"并存；⚠️ 三键各自语义（关闭全部 vs 关闭悬停贴图）的最终分支未逐条落地；
- **becomeKeyWindow 链**：贴图成为 key → super → 通知 Manager 0x10030152c（0x1003021d8，读 contentView 验证后更新"当前活动贴图"弱引用）；
- **⬜ 未探明**：窗口数组容量上限 / 内存（CGImage 缓存）上限 / 关闭全部的单一入口函数（疑似 0x10011c214/0x10011e034 一带的 SwiftUI 区引用，未定界）；`shouldRestorePinnedPanelAfterCapture`/`shouldRestorePinnedPanelAfterPicking`（0x100af0cf0/0x100af6150）为截图面板恢复键，与贴图联动的行为细节未展开。

### 3.5 窗口语义（NSPanel 配置，0x100300344–0x100300790 完整实证）

```swift
// PinnedScreenshotWindow（0x100300344，两份特化副本 0x10039c994）
setReleasedWhenClosed(false)            // 0x1009530e0
setFloatingPanel(true)                  // 0x100951a60, w2=1
setBecomesKeyOnlyIfNeeded(false)        // 0x100950820, w2=0
setLevel(3)                             // 0x1009523c0, w2=3 → NSFloatingWindowLevel
setCollectionBehavior(0x101)            // 0x100950ca0 → canJoinAllSpaces | fullScreenAuxiliary
setOpaque(false); setBackgroundColor(.clearColor)
setHasShadow(false)                     // 0x100951d40, w2=0（贴图窗无投影）
setIgnoresMouseEvents(false)
setAcceptsMouseMovedEvents(true)        // 0x1009501e0, w2=1
contentView = PinnedScreenshotContentView(frame:)
setFrame:display: → makeKeyAndOrderFront:
```
- 初始尺寸/落点：创建前遍历 `NSScreen.screens`（0x10094fa80）取 `frame`，fallback `mainScreen.visibleFrame`（0x10094cda0/0x1009567c0）；常量 **360.0 / 420.0 / 0.58 / 0.74 / 60.0**（0x100300540/0x1003005b4/0x10030057c/0x1003005e4/0x100300aec）——按屏幕可见域与图像长宽比计算初始窗（⚠️ 精确公式：宽高分别与屏幕尺寸×0.58/0.74 及上限 360/420 取舍的完整表达式未逐行复原）；
- 点击穿透：**否**（setIgnoresMouseEvents(false)；`acceptsFirstMouse:` 有实现；ScaleHUD 单独穿透）。

---

## 4. 控制条与 HUD 源码骨架（衔接重建 Capture 模块）

> 落点：`apps/FrsetNext/Sources/Features/Capture/`，替换现 `PinWindow.swift` 简化版。命名与原作类一一对齐。

```swift
// PinnedScreenshotManager.swift
final class PinnedScreenshotManager {
    static let shared = PinnedScreenshotManager()
    private var windows: [PinnedScreenshotWindow] = []      // 数组管理，上限 ⬜
    private var monitor: Any?
    private weak var activeWindow: PinnedScreenshotWindow?  // becomeKeyWindow 回写

    private init() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            switch e.keyCode {
            case 53, 51, 117:  /* Esc / Delete / ForwardDelete */
                self?.handleCloseKey(e); return nil   // 吞键（⚠️ 分支语义见 §3.4）
            default: return e
            }
        }
    }
    func pin(image: CGImage) { /* 建 PinnedScreenshotWindow → makeKeyAndOrderFront */ }
    func windowDidBecomeKey(_ w: PinnedScreenshotWindow) { activeWindow = w }
}

// PinnedScreenshotWindow.swift —— NSPanel
final class PinnedScreenshotWindow: NSPanel {
    override var canBecomeKeyWindow: Bool { true }
    override var canBecomeMainWindow: Bool { true }
    override func becomeKeyWindow() {
        super.becomeKeyWindow()
        PinnedScreenshotManager.shared.windowDidBecomeKey(self)
    }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        super.constrainFrameRect(frameRect, to: screen)   // 直通（实测无额外钳制）
    }
    // 配置照抄 §3.5：level .floating / canJoinAllSpaces+fullScreenAuxiliary /
    // 非不透明+clear 背景 / hasShadow=false / acceptsMouseMovedEvents=true
}

// PinnedScreenshotContentView.swift —— 26 个 @objc 方法对齐
final class PinnedScreenshotContentView: NSView {
    enum HitZone { case body, top, bottom, left, right, /* 4 角 */ … }   // 0–8
    private enum Mode { case normal, small, forced }                      // 状态字节 0/1/2
    // 小模式谓词（0x1002fe4d4 实测阈值）
    var isSmallMode: Bool { bounds.width < 200 || bounds.height < 60 }
    // 缩放档位（0x100c6bf48 静态表）
    static let scalePresets: [Int] = [200, 150, 100, 50]   // "%d%" → scale = n/100
    override func scrollWheel(_ e: NSEvent)      { zoomCore(e) }   // 0x1002f596c
    override func magnify(with e: NSEvent)       { zoomCore(e) }   // 0x1002f5560
    // zoomCore(0x1002f55b0)：非 key 先 makeKey；delta→系数（精确 3.5 档/普通 12 档）；
    // 以 event.mouseLocation 为锚；min 边 50.0pt；phase/momentumPhase 惯性
    override func mouseDown/dragged/up(_ e:)     { 移动(body 区) / 边缘 resize(10pt 带) }
    override func mouseEntered/Exited/moved(_ e:) { showControls() / hideControls() }
    override func rightMouseDown(_ e:)           { showActionsMenu() }   // 0x1002f98ac
    @objc func handleScalePreset(_ sender: NSMenuItem) { /* representedObject→scale */ }
    @objc func annotateClicked() / ocrClicked() / translateClicked() / saveClicked() / closeClicked()
    override func layout() {
        super.layout()
        repositionHUD()               // 0x1002f961c：HUD 居中 56×28
        scheduleSmallModeTipIfNeeded()// 0x1002f8838
    }
}

// 控制条：PinnedScreenshotControlsWindow(NSPanel, canBecomeKey/Main=true)
//   + ControlsHostView；按钮 28pt 宽 / 30pt 间距横排（0x1002f80d0 布局循环）
// 显示=取消旧 DispatchWorkItem+世代计数+淡入；隐藏=NSAnimationContext 淡出+setHidden+ignoresMouseEvents
// 自动隐藏：Timer(timeInterval:2.0, repeats:false) on RunLoop.main .common

// HUD：PinnedScreenshotScaleHUD(intrinsic 56×28, hitTest=nil, font .systemFont(12, .semibold))
//  addChildWindow 挂钉图窗，level 同父，ignoresMouseEvents=true，绘制 "当前缩放%"

// 小模式 Tip：一次性（UserDefaults "pinnedScreenshot.smallModeTipSeen_v2"）
//   文案 "Right-click for more actions"，TipHostingView 承载，点击/超时淡出
```

右键菜单骨架（对齐 0x1002f9b6c 字符串/选择器证据；标题为 L10n 键，中文值见文首补丁）：

```swift
let zoom = NSMenu(title: L10n("Zoom"))               // 缩放
for n in Self.scalePresets {
    let it = NSMenuItem(title: "\(n)%", action: #selector(handleScalePreset(_:)), keyEquivalent: "")
    it.representedObject = NSNumber(value: Double(n) / 100.0)
    it.target = self; zoom.addItem(it)
}
let menu = NSMenu(title: "More")            // ⚠️ 主菜单标题 "More" 为实现串，UI 呈现以系统右键为准
let zoomItem = NSMenuItem(title: L10n("Zoom")); zoomItem.submenu = zoom; menu.addItem(zoomItem)
menu.addItem(.separator())
for (key, sel) in [("Annotate", #selector(annotateClicked)),      // 标注
                   ("Extract Text", #selector(ocrClicked)),       // 提取文字
                   ("Translate", #selector(translateClicked)),    // 翻译
                   ("Save", #selector(saveClicked))] { … }        // 保存
menu.addItem(.separator())
menu.addItem(NSMenuItem(title: L10n("Close"), action: #selector(closeClicked)))  // 关闭
menu.popUp(positioning: nil, at: locationInWindow, in: self)
```

---

## 5. 行为对照条目（回填 tests/行为对照表）

| # | 条目 | 证据 |
|---|---|---|
| P-1 | 悬停贴图即显示控制条（move/drag/进入均触发），停止交互 **2 秒**后自动隐藏（淡出后 setHidden + 穿透恢复） | 0x1002fb60c/0x1002fabc4/0x1002fb3e0 |
| P-2 | 右键菜单：Zoom(200/150/100/50%)｜Annotate / Extract Text / Translate / Save｜Close，动作选择器逐一实证 | 0x1002f9b6c + selref 0x100c3c820–0x100c3c848 |
| P-3 | 滚轮/双指缩放以**光标为锚点**；贴图非 key 时先抢 key 再缩放 | 0x1002f55b0（0x1002f561c/0x1002f56b8/0x1002f5838） |
| P-4 | 缩放时 HUD（56×28 黑底白字 semibold）出现在贴图**正中心**，HUD 本身穿透点击 | 0x1002f961c/0x1002fe124/0x1002fe11c/0x1002f7970 |
| P-5 | 四边/四角 ~10pt 手柄拖拽调尺寸，光标随方向切换（含两枚自定义对角光标）；body 区拖拽=移动窗口 | 0x1002f4b58/0x1002f5080/0x1002f454c/0x1002f4a8c |
| P-6 | 贴图缩小到 **宽<200pt 或 高<60pt** 进入小模式：首次触发 "右键查看更多操作"（L10n 键 "Right-click for more actions"）提示（UserDefaults 一次性 `pinnedScreenshot.smallModeTipSeen_v2`） | 0x1002fe4d4/0x1002f8838/0x100b43c30/0x100b4c270 + zh-Hans lproj |
| P-7 | 贴图窗浮动层级（NSFloatingWindowLevel=3）、无阴影、跨 Space；constrainFrameRect 直通=可拖出屏幕边缘自由摆放 | 0x100300714/0x100300768/0x1003021fc |
| P-8 | Esc / Delete / Forward Delete 三个键（本地监听）作用于贴图关闭语义 | 0x1002fff98–0x1002fffbc |
| P-9 | Extract Text（贴图 OCR）失败时占位显示 L10n "文字识别失败"（键 "Text Recognition Failed"）+ exclamationmark.circle.fill | 0x1002fa964/0x1002fa990 + zh-Hans lproj |
| P-10 | 关闭采用 setReleasedWhenClosed(false) 的面板 close；becomeKeyWindow 同步 Manager 活动贴图 | 0x100302174/0x10030152c |

---

## 6. ⬜ 未探明清单（已尝试手段）

| # | 项 | 已尝试 | 建议 |
|---|---|---|---|
| 1 | `ScaleMenuButton` 类 | 全字符串段/类名聚簇/方法表三路检索无此名 | 判定为任务书笔误或他版本类名；缩放档位为内联 NSMenu 构建（0x1002f998c） |
| 2 | 控制条按钮图标资源名 | 取名逻辑 0x1002fc5c4（Int→NSImage(named:)） | 需资产目录（Assets.car）dump 或实机截图比对 |
| 3 | 窗口数组上限 / CGImage 内存策略 | Manager Swift 方法未全定界（0x100303000–0x100306000） | 定界 Manager 泛型/数组函数后复读 |
| 4 | Esc/Delete/ForwardDelete 三键语义差分（关全部 vs 关活动/悬停） | 监听器骨架已读（0x1002fff94 起），关闭分支 0x100010628 泛型未解 | 解 0x100010628 调用约定（Array 操作 helper） |
| 5 | HUD 淡出延时常量 | 复用了 2.0s 定时器路径的推断未证实 | 悬停 HUD 实机测时 |
| 6 | 控制条淡入/淡出精确时长 | setDuration: 调用实证（0x1002fb0f8 等），常量经 ldr d0 间接装载（0x100964d80 处 u64=0x42000000 解释存疑） | 常量池交叉验证或实机测时 |
| 7 | 初始窗尺寸公式（360/420/0.58/0.74/60 组合式） | 常量与 screens 遍历已定位（0x100300424–0x1003006b4） | 逐行复原 fcmp 树 |
| 8 | 滚轮灵敏度系数语义（3.5/12 的除/乘方向） | 指令序已抓取（0x1002f57a0–0x1002f582c） | 实机滚轮标定 |
| 9 | pin() 的截图流接线（ScreenshotManager→Manager） | 类访问器调用图查到 0x10011a114/0x10011b1a4（SwiftUI 区） | 定界 ScreenshotManager 输出分支 bl 树 |
| 10 | Tip 窗精确几何（尺寸/锚点） | 创建函数 0x1002ff470 仅读 | 窗创建参数逐行复原 |
| 11 | shouldRestorePinnedPanelAfterCapture/Picking 与截图面板联动 | 仅字符串锚点（0x100af0cf0/0x100af6150） | 归入 06 号规格待查#1 一并处理 |

## 7. 验收要点
- [ ] 悬停控制条 2s 自动隐藏、右键六动作菜单与原作逐项一致
- [ ] 滚轮/捏合锚点缩放 + 4 档位菜单 + 中心 HUD
- [ ] 小模式阈值 200/60 与一次性提示文案 "Right-click for more actions"
- [ ] 边缘手柄光标与拖拽调尺寸、Esc/Delete/ForwardDelete 关闭
- [ ] 行为对照 P-1…P-10 全部通过
