# C1 · Capture 模块逐行测绘

> 范围：`apps/FrsetNext/Sources/Features/Capture/`，39 个 `.swift`，**12 929 行**。  
> 全部文件整读，无抽样。符号对账：CSV 中该目录 697 条声明，其中 **500 func + 69 init = 569 个函数级符号**，本文表格逐条覆盖（嵌套闭包/局部 func 也在 CSV 中，一并列出）。  
> 只读测绘，未修改源码、未执行构建。



---

## 1. 文件清单

| #  | 路径                                  | 行数   | 一句话职责                                                                           |
| -- | ----------------------------------- | ---- | ------------------------------------------------------------------------------- |
| 1  | `AnnotationCompositor.swift`        | 421  | 标注数据模型 + 把标注烧录进底图的合成器（形状/箭头/画笔/荧光/马赛克/文字）                                       |
| 2  | `AnnotationEditorWindow.swift`      | 1453 | 标注编辑器：画布（含内联文字、控制点缩放、橡皮、物体抹除）+ 浮动工具条 + 单例控制器                                    |
| 3  | `AnnotationToolbarView.swift`       | 516  | 标注工具条 SwiftUI 视图 + `EditorToolbarModel`（工具/颜色/粗细/马赛克块状态机）+ 配景色                  |
| 4  | `BeautifyPanel.swift`               | 303  | 截图美化（背景/圆角/投影）渲染器 + 预览窗                                                         |
| 5  | `CaptureActionChain.swift`          | 307  | 框选后动作工具条：工具注册表 + 浮条 NSPanel + 键位                                                |
| 6  | `CaptureEventBus.swift`             | 119  | 跨模块静态回调总线 + `CaptureMode`/`CaptureDefaultAction`/`CapturedImage`/`CaptureError` |
| 7  | `CaptureHistoryStore.swift`         | 297  | 截图历史 SQLite 存储（500 条上限、缩略图、OCR 文本、未完成标注快照）                                      |
| 8  | `CaptureHistoryView.swift`          | 350  | 历史窗（网格+搜索+模式过滤）+ 点外即关的窗口控制器 + `frsetnext://capture` 深链                          |
| 9  | `CaptureModule.swift`               | 163  | 模块启动装配、面板/设置注册、抓屏诊断探针、使用统计埋点收口                                                  |
| 10 | `CaptureSectionView.swift`          | 266  | 主面板「截图」区段（10 个入口 + 最近截图网格 + OCR 结果区）                                            |
| 11 | `CaptureSettingsPane.swift`         | 136  | 设置→截图页签（保存路径/提示音/默认动作/延时秒数/OCR 语言/权限）                                           |
| 12 | `ColorValuePanel.swift`             | 208  | 取色后的色值面板（HEX/RGB/HSB + 最近 10 色）                                                 |
| 13 | `DelayedCaptureHUD.swift`           | 128  | 延时截图倒计时控制器 + 居中大数字窗                                                             |
| 14 | `ElementSnap.swift`                 | 152  | AX 元素级吸附引擎（点→元素帧，cocoa 全局坐标）                                                    |
| 15 | `Eyedropper.swift`                  | 348  | 取色器：全屏取色视图/窗口 + 单例会话（手动/程序化共用）                                                  |
| 16 | `EyedropperBridge.swift`            | 34   | 取色器的 async 接缝（工具箱复用，单次 resume 保证）                                               |
| 17 | `ImageProcessor.swift`              | 128  | 图像工具：PNG 编码/缩放/按点坐标裁剪/解码/RGBA 缓冲                                                |
| 18 | `LongScreenshotCoordinator.swift`   | 311  | 长截图编排：选区覆盖层→会话→HUD/边框→收尾；含全局监视器流                                                |
| 19 | `LongScreenshotDiagnostics.swift`   | 161  | 拼接器合成数据自检（`frsetnext://longshotcheck`）                                          |
| 20 | `LongScreenshotFrameStream.swift`   | 143  | SCK 30fps 连续帧流（排除本 App 窗口，只留最新帧）                                                |
| 21 | `LongScreenshotHUD.swift`           | 218  | 采集期 HUD（红点/高度/完成取消）+ 选区边框窗（`sharingType=.none`）                                 |
| 22 | `LongScreenshotMotionCrop.swift`    | 153  | 逐列差异检测「正在滚动」的列区间，裁掉静止背景                                                         |
| 23 | `LongScreenshotPreviewWindow.swift` | 238  | 长截图预览/编辑器窗（文档视图等比缩放 + 底部工具条）                                                    |
| 24 | `LongScreenshotSession.swift`       | 474  | 长截图会话状态机：定时采样 tick、帧流/同步兜底、运动裁剪、收尾                                              |
| 25 | `LongScreenshotStitcher.swift` | 732 | 定宽画布流式拼接器（1D 行投影 NCC 粗搜 + 2D NCC 精校 + 重同步）           |
| 26 | `OCRDiagnostics.swift`         | 157 | OCR 全链路自检（Vision vs +PP-OCR，耗时/内存/小字链接样本）            |
| 27 | `OCRRefiner.swift`             | 78  | OCR 复核层协议 + system/local 两实现 + 注册表                   |
| 28 | `OCRService.swift`             | 613 | Vision OCR 主通道：多遍变体、小字增强、行级合并、阅读顺序、URL 清洗、PP-OCR 复核  |
| 29 | `ObjectRemovalEngine.swift`    | 359 | 物体抹除：扩散（SOR 调和填充）修复引擎 + LaMa 插槽协议                    |
| 30 | `PPOCROCR.swift`               | 229 | 进程内 PP-OCR（ONNX Runtime + CTC 解码）——现仅 OCRHelper 目标使用 |
| 31 | `PPOCROCREmote.swift`          | 185 | 起一次性 `FrsetOCRHelper` 子进程做本地 OCR（空闲零占用）              |
| 32 | `PinWindow.swift`              | 964 | 钉图窗全家族：缩放 HUD/控制条/内容视图/窗口/多贴图管理器                     |
| 33 | `QRCodeRecognizer.swift`       | 54  | Vision 条码/二维码识别 + 结果弹窗                               |
| 34 | `ScreenTranslator.swift`       | 311 | 屏幕翻译：OCR→LLM 批量翻译→按坐标画回→钉回原位                         |
| 35 | `ScreenshotManager.swift`      | 821 | 截图总控：抓屏通道兼容层、权限、区域/全屏/窗口/延时、落盘、动作分流、OCR              |
| 36 | `ScreenshotOCRWindow.swift`    | 507 | OCR 结果窗（原文图 / 识别文本 / 二维码 / 翻译 四块）+ 窗口控制器（失焦即关）       |
| 37 | `ScreenshotOverlay.swift`      | 597 | 全屏选区覆盖层：拖拽选区、放大镜、窗口拾取、AX 吸附、绘制                       |
| 38 | `Stitcher.swift`               | 154 | 多图拼接（用户手选 N 张重叠截图）——与滚动长截图是两条独立路径                    |
| 39 | `TextFontPopover.swift`        | 140 | 选中文字后的字体配置弹层（字号/字重/颜色/删除）                            |

合计 12 929 行，与 `wc -l` 一致。

---

## 2. 类型清单

### 2.1 `ScreenSnapshot`（enum，ScreenshotManager.swift:12）

- **职责**：唯一的抓屏通道抽象。三条路径：① `legacyCapture` 用 `dlsym("CGWindowListCreateImage")` 动态解析（SDK 在 macOS 15 已 obsoleted，运行时符号仍在，实测返回有效 2x 图）；② `sckCapture(displayID:)` 单帧整屏；③ `sckCapture(windowID:)` 单窗口（`desktopIndependentWindow`，天然排除遮挡）。
- **状态**：仅一个 `static let legacyCreateImage: LegacyCreateImageFn?`（一次性 dlopen，永不释放）。
- **生命周期**：纯静态，随进程。
- **依赖**：CoreGraphics / ScreenCaptureKit / `CaptureError`。
- **被依赖**：`ScreenshotManager`（区域/全屏/窗口）、`Eyedropper`、`LongScreenshotSession.captureFrameSync`、`LongScreenshotCoordinator`、`CaptureModule.runCaptureProbe`。
- **注**：`sckCaptureSync` 用 `DispatchSemaphore.wait()` 桥接异步 SCK，**注释明确禁止主线程调用**，实现里没有任何运行时断言保护。

### 2.2 `ScreenshotManager`（final class，`ObservableObject` 单例）

- **职责**：截图流程编排与唯一落盘/登记入口。
- **内部状态**：`recent: [CapturedImage]`（上限 60）、`isCapturing`、`ocrText`、`isRecognizing`、`statusMessage`、`hasPermission`、`qrPayloads`；私有 `overlays: [ScreenshotOverlayWindow]`、`thumbCache: NSCache`（48 项 / 20 MB）、`pendingFlow`、`lastSelectionAppKit`、`lastHistoryPath`、`currentModeTag`、`permissionProbed/Probing`、`didRequestScreenRecordingThisLaunch`、`didShowPermissionAlertThisLaunch`。
- **生命周期**：`init()` 里 `reloadRecent()` + 打权限实况日志 + 读 `FRSET_TCC_REQUEST`/`/tmp/frset_tcc_request_once` 做一次性 TCC 重试；进程期常驻。
- **依赖**：`ScreenSnapshot`、`ScreenshotOverlayWindow`、`ImageProcessor`、`CaptureActionChain`、`CaptureHistoryStore`、`CaptureEventBus`、`OCRService`、`QRCodeRecognizer`、`PinnedScreenshotManager`、`AnnotationEditorController`、`BeautifyController`、`ScreenTranslator`、`LongScreenshotCoordinator`、`Preferences`、`AppDirectories`、`Toast`、`PermissionGuideWindowController`。
- **被依赖**：`CaptureModule`、`CaptureSectionView`、`CaptureActionChain` 全部 12 个 handler、`Eyedropper`、`ScreenTranslator`、`AnnotationEditorController`、`BeautifyController`、`LongScreenshotPreviewController`、`PinWindow.saveClicked`、`DelayedCaptureController`、`CaptureHistoryView`。

### 2.3 `ScreenshotOverlayWindow` / `ScreenshotOverlayView` / `DeleteKeyMonitor` / 放大镜两件套

- **职责**：每屏一个 `.screenSaver` 级 borderless 窗口；视图负责拖拽选区/窗口拾取/AX 吸附/放大镜/尺寸标签/十字准星。
- **状态**：`snapshot`（覆盖层出现**前**抓的底图）、`startPoint/currentPoint`、`windowHits: [WindowHit]`（init 时一次性枚举）、`highlightedWindow/highlightedElement/snapHighlight`、`lastAXQuery`（90ms 节流）、`dragStartWindowFrame` 等。
- **生命周期**：`ScreenshotManager`/`LongScreenshotCoordinator` 创建并持有 `overlays` 数组，`closeOverlays()` 逐个 `orderOut` 后清空（**不 close**）；视图 `deinit` 时 `DeleteKeyMonitor` 释放监视器。
- **依赖**：`ElementSnapEngine`、`ScreenSnapshot`、`Theme`。
- **被依赖**：`ScreenshotManager`（区域/窗口）、`LongScreenshotCoordinator`（选区）。

### 2.4 `CaptureActionChain` + `CaptureActionToolbarPanel` + `CaptureActionToolbarView`

- **职责**：框选后的动作注册表与浮条。`tools` 是**计算属性**，每次访问重建 12 个 tool（含闭包）。
- **状态**：`static var toolbar: CaptureActionToolbarPanel?`（@MainActor，强引用），Preferences 键 `capture.afterSelect.showToolbar`。
- **生命周期**：`present` → 主线程建 panel → `onClose` 里把静态引用置 nil。
- **依赖**：ScreenshotManager/Pin/OCR/QR/ScreenTranslator/AnnotationEditor/Beautify/CaptureHistory/LongScreenshotCoordinator/通知 `.frsetAirDropFiles`。
- **被依赖**：`ScreenshotManager.commitRegion/commitWindow`。

### 2.5 长截图家族（6 个类型 + 1 结构体）

- `LongScreenshotCoordinator`（单例）：编排 + 持有 `session/hud/borderWindow/stream/selectionOverlays`。
- `LongScreenshotCaptureStream`：3 个 NSEvent 监视器（global scrollWheel、global keyDown、local keyDown）。
- `LongScreenshotSession`：状态机 + 串行队列 `com.surfrset.long-screenshot`（实为 `com.frset.long-screenshot`）+ `NSLock` + `DispatchSourceTimer`。
- `LongScreenshotFrameStream`（macOS 14+）：`SCStream` @30fps + `com.frset.long-screenshot.frames` 队列 + `NSLock`。
- `LongScreenshotStitcher`：定宽画布、`bytes/gray/rowMeans` 三套缓冲、`anchorFrame`、`didDropContent`。
- `LongShotRGBA`：一帧的 RGBA 缓冲（显式 malloc，避免 `&array` 桥接 UB）。
- `LongScreenshotMotionCrop`（enum，纯函数）、`LongScreenshotDiagnostics`（enum）、`LongScreenshotHUDController`、`LongScreenshotSelectionBorderWindow`、`LongScreenshotPreviewController` + 编辑器三个视图、`ClosureButtonAction`。

### 2.6 OCR 家族

- `OCRService`（单例，实现 `OCRServiceProtocol`）：`ScreenshotOCRDirectImageStore` 内容缓存（12 项）、单遍/多遍/小字增强三条路径、`refineWithPPOCR` 采纳规则、`readingOrder/assemble/cleanLine/sanitizeURL`。
- `OCRRefiner` 协议 + `SystemOCRRefiner` / `LocalOCRRefiner` + `OCRRefinerRegistry.active`（读 `AISettings.ocrRefinerPreference`）。
- `PPOCROCREmote`（enum）：`Process` 起 `Contents/Helpers/FrsetOCRHelper`，BGRA raw + boxes.json，10s 超时。
- `PPOCROCR`（单例，进程内 ONNX）：现仅被 `OCRHelper/main.swift` 使用；主 App 里是死重量。
- `OCRDiagnostics` / `LongScreenshotDiagnostics`：可被深链/环境变量触发的自检代码，编译进生产包。

### 2.7 标注家族

- `AnnotationTool`（9 种工具枚举）、`Annotation`（struct，坐标一律**图像像素、左上原点**）。
- `AnnotationCompositor`（enum）：`composite` 先画底图再翻转 CTM，然后用 AppKit 画标注；马赛克走 `replacePathWithStrokedPath` 裁剪。
- `AnnotationCanvasView`：flipped NSView，`EditOp` 三态撤销栈（annotation / modify / imageSnapshot）+ 重做栈。
- `AnnotationEditorWindow` / `AnnotationEditorController`（单例，`NSApp.windows` 里同类窗口全关）。
- `AnnotationStateSnapshot`（Codable，存在 `CaptureHistoryStore` 文件里）→ 历史「继续标注」。

### 2.8 钉图家族（PinWindow.swift 内 8 个类型）

`PinnedScreenshotScaleHUD`（点击穿透子视图）、`PinnedScreenshotSmallCloseButton`、`PinnedScreenshotSmallModeTipWindow`（一次性提示 + 4s 淡出）、`PinnedScreenshotControlsHostView`、`PinnedScreenshotControlsWindow`（childWindow，2s 自动隐藏，世代计数防错序）、`PinnedScreenshotContentView`（命中区 9 分法、锚点缩放、右键菜单）、`PinnedScreenshotWindow`（`.floating`，`canBecomeKey/Main=true`）、`PinnedScreenshotManager`（单例，窗口数组 + 本地 keyDown 监视器）。

### 2.9 其它

`Eyedropper` / `EyedropperView` / `EyedropperWindow` / `EyedropperPickBridge`、`DelayedCaptureController` / `DelayedCountdownWindow`、`CaptureHistoryStore` / `CaptureHistoryVM` / `CaptureHistoryWindowController` / `CaptureDeepLink`、`BeautifyRenderer` / `BeautifyController` / `BeautifyWindow`、`ObjectRemovalEngine` / `DiffusionInpainter`、`Stitcher`、`ScreenTranslator`、`ScreenshotOCRResultWindow` + 三个 NSScrollView/NSTextView 子类 + `ScreenshotOCRWindowController`、`ElementSnapEngine`、`QRCodeRecognizer`、`ImageProcessor` / `RGBABuffer`、`CaptureModule`、`CaptureSectionView`、`CaptureSettingsPane`、`ColorValueFormats`/`ColorValueView`/`ColorValuePanelController`。

---

## 3. 函数级清单

|   |   |   |
| - | - | - |

> 列：`函数名 | 行 | 说明`。行号为声明起始行（来自 `/tmp/frset_symbols.csv`）。仅列 func/init；class/enum/struct 归入第 2 节。

### 3.1 AnnotationCompositor.swift

| 函数名            | 行   | 说明                                                                                                                 |
| -------------- | --- | ------------------------------------------------------------------------------------------------------------------ |
| `composite`    | 110 | 建 RGBA 上下文→画底图→`translate/scale` 翻成左上原点→`NSGraphicsContext(flipped:true)`→`draw`；无标注直接返回底图；马赛克层按块大小缓存一次（导出路径无画布缓存） |
| `pixelated`    | 291 | 缩小到 `w/block` 再放大（nearest 语义），块内取均值；块最小 4px                                                                        |
| `drawArrow`    | 304 | 直线 + 两条 `±0.82π` 箭头翼，头长 `max(10, lineWidth*4)`                                                                     |
| `apply`        | 321 | 统一描边：圆头圆角、线宽 ≥1                                                                                                    |
| `rect`         | 330 | 取首末点规范化矩形；点数 <2 返回 nil                                                                                             |
| `fontSize`     | 338 | 线宽 ×6，钳制 12…72                                                                                                     |
| `textFontSize` | 343 | `fontSize` 的语义别名（画布/输入框/合成共用一个口径）                                                                                  |
| `fontWeight`   | 348 | 0→regular / 2→bold / 其余 semibold                                                                                   |
| `textBounds`   | 359 | 按 `wrapWidth` 软换行后 `boundingRect` 求高；选中框/命中/字号联动共用                                                                 |
| `displayText`  | 375 | `wrapWidth>8` 才折行                                                                                                  |
| `wrapText`     | 382 | 逐字符硬折行（CJK 友好），与输入框 `.byCharWrapping` 同算法                                                                          |
| `color`        | 404 | `#RRGGBB` → sRGB NSColor，失败回退 systemRed                                                                            |
| `hex`          | 414 | NSColor → `#RRGGBB`，非 sRGB 回退 `#FF3B30`                                                                            |


**散文补充（composite / drawMosaicBrush 的坑）**
- `composite` 必须"先画底图、再翻转"，否则底图上下颠倒；翻转后 `NSGraphicsContext(flipped: true)` 才能让 `NSString.draw` 正立。
- 马赛克不能直接 `addClip` 开放折线——会被隐式闭合成多边形，表现为"三角色块"且笔刷宽度失效。必须 `replacePathWithStrokedPath()` 后再 `clip()`。
- `strokeMosaic` 里画像素化图层前**要再翻一次 y**，否则马赛克块里是镜像画面（历史实障）。
- `composite` 的马赛克缓存是函数内局部变量（每次导出重算），画布侧另有 `mosaicPixelCache`，两套缓存不共享。

### 3.2 AnnotationEditorWindow.swift

| 函数名 | 行 | 说明 |
|---|---|---|
| `init(image:)` | 63 | **一次性解码**底图为 RGBA 位图（惰性 CGImage 会让橡皮移动时每帧重解码、直接卡死） |
| `decoded` | 73 | 上述解码实现，失败返回原图 |
| `init(coder:)` | 87 | `fatalError` |
| `restore(annotations:)` | 90 | 历史「继续标注」恢复快照，追加到现有列表 |
| `imagePoint` | 116 | 视图点 → 图像像素点（经 `fitRect`/`imageScale`） |
| `draw` | 124 | 背景→图片投影→底图（临时反翻转）→1px 描边→标注（CTM 映射）→笔刷环→抹除预览→文字选中框；>40ms 打 warn |
| `hitTest(_:at:)` | 253 | 按工具类型分派命中：矩形/椭圆包围盒、马赛克折线距离、箭头/画笔邻近点、文字包围盒 |
| `distanceToPolyline` | 275 | 点到折线最短距离（逐段投影） |
| `mouseDown` | 292 | 先提交未完成文字；橡皮按下即擦；文字工具先测控制点→再测文字命中→否则起输入框；抹除起笔 |
| `mouseDragged` | 349 | 橡皮连续擦；抹除累积轨迹；文字控制点按比例改字号（`d1/d0`）；文字拖动改锚点；画笔 1.2px 抽稀后追加点 |
| `mouseUp` | 409 | 提交抹除修复 / 文字拖动入撤销栈 / 图形落库（`isValid` 过滤误点） |
| `strokeWidth` | 472 | 马赛克用笔刷直径，荧光用 lineWidth，其余 ≥1 |
| `updateTrackingAreas` | 493 | 重建 `.mouseMoved` 跟踪区 |
| `mouseMoved` | 504 | 文字工具切十字/抓手/iBeam；笔刷工具只标脏环区 |
| `mouseEntered` | 520 | 进入时设光标 + 定位环 |
| `mouseExited` | 531 | 清光标环、复位箭头 |
| `updateCursor` | 539 | 只 `setNeedsDisplay(old∪new)`，避免每次 mouseMoved 全画布重绘（2K/4K 上是致命性能项） |
| `cursorRingRect` | 553 | 笔刷环视图矩形（半径×scale + 4pt 余量） |
| `keyDown` | 562 | 选中文字时 Delete/⌫ 删、Esc 取消选中；否则交 `onKey`（窗口级快捷键） |
| `eraseAt` | 580 | 从后往前删第一个命中标注，入撤销栈 |
| `applyRemoval` | 589 | 轨迹→灰度 mask（malloc 缓冲，y 翻转）→`ObjectRemovalEngine.inpaint`→替换底图并记 `imageSnapshot` |
| `isValid` | 635 | 过滤过小图形（矩形 2px、箭头 6px、画笔 ≥2 点、马赛克 ≥1 点） |
| `textAnnotation` | 694 | 最上层文字命中（包围盒外扩 6px） |
| `textSelectionViewRect` | 702 | 选中框视图矩形（与 draw 同口径） |
| `handleRects` | 712 | 8 个控制点矩形（角 12×12，边中点 12×10/10×12） |
| `square` | 714 | `handleRects` 内部：以点为中心的方框 |
| `pill` | 717 | `handleRects` 内部：边中点扁框 |
| `handleHit` | 733 | 控制点命中（外扩 4pt） |
| `selectText` | 739 | 设/清 `selectedTextID`，回调工具条同步 |
| `applyTextSizeToSelection` | 747 | 改选中文字字号并合并撤销 |
| `applyColorToSelection` | 752 | 改选中文字颜色 |
| `applyWeightToSelection` | 757 | 改选中文字字重 |
| `deleteSelectedText` | 762 | 删除选中文字（入撤销栈）+ 关弹层 |
| `mutateSelectedText` | 771 | 统一的"改选中文字"入口：去重、入撤销、回写弹层 model、标脏 |
| `showFontPopover` | 793 | 绑定 model 回调并 `show(relativeTo:)` |
| `makeFontPopover` | 812 | `.applicationDefined` 行为（`.transient` 会吞掉第二次点击，导致"拖边框没反应"） |
| `closeFontPopover` | 824 | 关闭弹层 |
| `roundedRectPath` | 831 | 手工 CGPath 圆角（`NSBezierPath.cgPath` 需 macOS 14） |
| `beginTextEditing` | 837 | 建虚线框 + NSTextField（多行 `.byCharWrapping`），钳制到画布内 |
| `textWrapWidth` | 896 | 换行宽度 = min(画布 82%, 锚点右侧剩余)，≥240px |
| `updateEditorBoxSize` | 905 | 逐字生长：单行加宽，超限封顶换行、向下长高；贴边时反向生长 |
| `displayFontSize` | 953 | 取字体 pointSize |
| `textFieldSubmitted` | 955 | 回车 → 提交 |
| `finishTextEditing` | 960 | 提交/取消文字：空串等于取消；提交后自动选中并弹字体配置 |
| `record` | 997 | 入撤销栈并清重做；连续 `modify` 同一 id 合并为一条 |
| `undo` | 1013 | 弹栈→反向 apply→推重做 |
| `redo` | 1021 | 弹重做→正向 apply→推撤销 |
| `apply(_:forward:)` | 1029 | 三态应用：增删标注 / 还原属性 / 替换底图（清马赛克缓存） |
| `clear` | 1048 | 清空标注与两栈 |
| `composite` | 1059 | 交给 `AnnotationCompositor.composite` |
| `scrollWheel` | 1064 | 纵向滚轮调粗细（`onSizeDelta`），横向交还 super |
| `runAnnotateTextProbe` | 1077 | 无鼠标验收探针（`probe.annotate`），1.2s 后落长文本并调字号 |
| `controlTextDidEndEditing` | 1100 | 失焦即落字 |
| `controlTextDidChange` | 1105 | 每次输入刷新框尺寸 |
| `control(_:textView:doCommandBy:)` | 1110 | Esc 取消 / 回车确认（⇧回车保留换行） |
| `init(image:)` | 1140 | 建窗：画布 + 工具条；尺寸按图幅钳制；`acceptsMouseMovedEvents = true`（否则橡皮圈不跟手） |
| `buildToolbar` | 1197 | NSHostingView 包 SwiftUI 工具条 |
| `toolbarDidSelectTool` | 1228 | 切工具并把对应尺寸同步给画布 |
| `toolbarDidChangeColor` | 1241 | 改色；有选中文字时直接落到文字上 |
| `toolbarDidChangeSize` | 1250 | 按当前工具分派到 textSize/lineWidth/brushWidth |
| `toolbarDidChangeBlock` | 1263 | 改马赛克块大小 |
| `adjustSize` | 1269 | 滚轮/`[`/`]` 调尺寸，同步工具条数值 |
| `refreshActions` | 1275 | 同步撤销/重做可用态 |
| `refocusCanvas` | 1282 | 工具条操作后把第一响应者还给画布（否则快捷键与光标失效） |
| `selectTool` | 1290 | 快捷键选工具（不经过 SwiftUI） |
| `undoTapped` / `redoTapped` / `clearTapped` | 1302/1303/1304 | 工具条按钮转发 |
| `longScreenshotTapped` | 1307 | 有标注先确认清除→关窗→进长截图选区 |
| `copyTapped` / `saveTapped` / `closeTapped` | 1314/1319/1324 | 合成后复制/保存/关窗 |
| `handleKey` | 1328 | ⌘Z/⇧⌘Z/⌘C/⌘S/Esc/R O A P H M T E D/`[`/`]` |
| `init` | 1377 | 单例私有初始化 |
| `openLatest` | 1381 | 打开最近一张截图，无则 false |
| `open(url:)` | 1387 | 打开文件（无快照） |
| `open(url:annotationState:)` | 1393 | 打开文件并恢复未完成标注 |
| `open(image:tool:)` | 1406 | 关掉所有同类窗后开新窗；接线复制/保存；`probe.annotate` 钩子 |
| `windowWillClose` | 1441 | 有未保存标注时把快照写回历史库 |

**散文（applyRemoval 与 record 的坑）**
- `applyRemoval` 的 mask 用 `CGBitmapInfo(none)` + DeviceGray，绘制时**必须** `y = h - p.y` 翻转，否则抹除区域与笔迹上下镜像。
- `applyRemoval` 在鼠标松开时同步在主线程跑 SOR 迭代（工作分辨率 ≤384，400 轮），384×384 内一般 30–120ms；大笔刷（直径 200）会明显卡一下。
- `record` 的合并规则只对 `modify` 且"上一条也是同 id 的 modify"生效，因此拖动文字只在松手时入栈一次，但拖字号滑杆的每一步都会被合并进同一条——撤销粒度是"一次连续操作"。
- 撤销栈**无上限**，`imageSnapshot` 会持有整张底图 CGImage；反复抹除多张 4K 图会显著吃内存。

### 3.3 AnnotationToolbarView.swift

| 函数名 | 行 | 说明 |
|---|---|---|
| `applyImageDefaults` | 38 | 按图宽给默认线宽（1%）、笔刷（4.5%）、字号（1.4%/6）、马赛克块 |
| `setSize` | 106 | 按当前工具写回对应尺寸字段 |
| `nudgeSize` | 115 | 按 range 钳制后 ±delta |
| `commitSize` | 341 | 滑杆提交：写 model + 回调窗口 |
| `isSameColor` | 473 | sRGB 分量差 <0.02 视为同色 |

### 3.4 BeautifyPanel.swift

| 函数名 | 行 | 说明 |
|---|---|---|
| `init` | 29 | 默认参数（渐变橙红、padding 32、圆角 14、阴影 18） |
| `render` | 35 | 画布 = 图 + 2×(padding + 2×shadow)；≥1400px 宽按 2x 归一；背景/圆角/投影 |
| `init` | 106 | 单例 |
| `show(image:)` | 109 | 非隔离入口，内部跳主线程 |
| `showOnMain` | 119 | 复用窗口或新建；接线复制/保存/贴图 |
| `windowWillClose` | 149 | 清引用 |
| `init(image:)` | 171 | 760×560 窗 |
| `update(image:)` | 184 | 换图并重渲染 |
| `buildUI` | 189 | 左预览右 SwiftUI 控件 + 底部三按钮 |
| `rerender` | 225 | 20ms 防抖 + 后台渲染回主线程贴图 |
| `copyTapped` / `saveTapped` / `pinTapped` | 238/239/240 | 转发 |
| `sliderRow` | 290 | 带数值的滑杆行 |

### 3.5 CaptureActionChain.swift

| 函数名 | 行 | 说明 |
|---|---|---|
| `tool(id:)` | 104 | 按 id 查注册表 |
| `toolID(for:)` | 109 | 默认动作 → 工具 id（高亮环） |
| `perform(id:image:url:)` | 122 | 执行工具 handler |
| `present` | 130 | 异步跳主线程后 `presentOnMain` |
| `presentOnMain` | 137 | 关闭旧条；若关闭了"显示工具条"偏好则直接执行默认动作 |
| `init` | 172 | 建非激活 NSPanel；装 keyDown（Esc/Return/⌘+字母）与内外点击监视器 |
| `cancelOperation` | 236 | responder chain 兜底 Esc |
| `place(near:)` | 239 | 选区下方 10pt，放不下翻上方，钳制可视区 |
| `execute(toolID:)` | 251 | 先关条再执行（避免动作弹窗被条遮挡） |
| `close` | 256 | 移除 3 个监视器 + `onClose` 回调清静态强引用 |

**散文（panel 生命周期）**
- `CaptureActionChain.tools` 是计算属性，每次 `tools.first{}`/渲染都重建 12 个带闭包的 struct；`present`/`perform`/`toolID` 各访问一次，属于可优化点但非缺陷。
- 面板 `close()` 里的 `onClose` 把 `CaptureActionChain.toolbar` 置 nil——若忘记调用 `close()` 而直接 `orderOut`，静态强引用会一直吊着 panel 与其中闭包捕获的 image/url。
- global 点击监视器需要辅助功能授权；未授权时"点外部关闭"只在本 App 内生效。

### 3.6 CaptureEventBus.swift

| 函数名 | 行 | 说明 |
|---|---|---|
| `init` | 95 | `CapturedImage` 的默认 id/时间 |

（其余为枚举/结构体声明，无函数。）

### 3.7 CaptureHistoryStore.swift

| 函数名 | 行 | 说明 |
|---|---|---|
| `encode` | 51 | 标注列表 → JSON（点扁平化为 `[x0,y0,…]`） |
| `decode` | 65 | JSON → 标注列表；未知工具名整条丢弃 |
| `init` | 101 | 打开 `AppDirectories.base/capture-history.sqlite`；**打不开直接 `fatalError`**；建表 + 索引 |
| `record(url:mode:)` | 128 | 异步：读像素尺寸→生成 240px 缩略图→INSERT→prune→通知 |
| `updateOCR(path:text:)` | 147 | 按 path 取最新一条回填 OCR 文本 |
| `updateAnnotationState(path:json:)` | 159 | 回填未完成标注快照（**不 notifyChange**，故意不刷新历史窗） |
| `items(query:mode:limit:)` | 172 | `queue.sync` 查询；OCR/路径/模式/日期四路 LIKE |
| `delete(id:)` | 195 | 异步删记录 + 删缩略图文件 |
| `item(id:)` | 211 | `queue.sync` 单条查询 |
| `pruneLocked` | 221 | 超 500 条淘汰最旧 + 清孤儿缩略图 |
| `cleanOrphanThumbnails` | 241 | 目录里 `thumb-*` 但库里无引用的文件删除 |
| `item(from:)` | 256 | SQLiteValue → `CaptureHistoryItem` |
| `pixelSize` | 270 | 只读文件头取像素尺寸（不解码整图） |
| `makeThumbnail` | 279 | 解码→缩放到 240→PNG 落盘，返回路径 |
| `notifyChange` | 292 | 主线程 post `frset.captureHistory.changed` |

### 3.8 CaptureHistoryView.swift

| 函数名 | 行 | 说明 |
|---|---|---|
| `init` | 29 | 首次 `reload` + 订阅历史变化通知 |
| `reload` | 36 | 带 query/mode 重新查询 |
| `clearOnDismiss` | 41 | 清空搜索/过滤/列表 |
| `delete` | 47 | 删库 + 本地移除 |
| `continueAnnotate` | 53 | 打开标注编辑器并恢复快照 |
| `copy` | 57 | 读图→剪贴板 |
| `revealInFinder` | 66 | 文件存在才 reveal，否则 Toast |
| `init(vm:)` | 83 | 注入 VM |
| `cell` | 165 | 单元格：缩略图/文件名/模式/尺寸/相对时间/OCR 摘要；双击继续标注；右键菜单 |
| `thumbnail` | 227 | 优先缩略图文件，回退原图；`@Stored` 字典缓存 |
| `modeTitle` | 235 | `CaptureMode` → 中文标题 |
| `init` | 251 | 单例 |
| `show` | 254 | 已有窗则前置 + reload + 重装监视器 |
| `installOutsideMonitors` | 280 | global + local 双监听；Esc 关闭；点窗外关闭 |
| `removeOutsideMonitors` | 302 | 移除两监听 |
| `dismiss` | 310 | 关窗 + 清 VM 状态（下次重建） |
| `windowWillClose` | 317 | 清引用 + 卸监听 |
| `handle(url:)` | 331 | `frsetnext://capture?action=history|delayed|region` |

**散文（历史窗的关闭语义）**
- `dismiss()` 把 `window` 置 nil，下次 `show()` 重建窗口；但 `vm` 是控制器持有的，重装订阅不会重复（VM 的 observer 只在 init 装一次）。
- `dismiss` → `vm.clearOnDismiss()` 会 `items = []`；如果此刻 `didChangeNotification` 到达，`reload()` 会把列表重新填回——因为 observer 是常驻的。窗口已关，数据被无谓重查一次（小浪费，不影响正确性）。

### 3.9 CaptureModule.swift

| 函数名 | 行 | 说明 |
|---|---|---|
| `start` | 12 | 订阅 `frset.clipboard.editImage`；注入 `ServiceLocator.ocrService`；预热 recent；注册面板区段 + 设置页签；`FRSET_CAPTURE_PROBE` 探针 |
| `runCaptureProbe` | 60 | 3s 后分别用 dlsym 与 SCK 抓图，算平均亮度并落 `/tmp/frset_probe_*.png` |
| `averageBrightness` | 94 | 缩到 64×64 求 BT.601 加权均值 |
| `capture(_:)` | 115 | `CaptureMode` → 具体入口，唯一收口（面板/菜单栏/热键/深链） |
| `recordUsage` | 131 | 只对 pin/long/annotate 埋点（其余有完成回调），避免双计 |
| `captureCopy` | 148 | 截图并复制 |
| `captureTranslate` | 153 | 埋点 + post `.frsetScreenshotTranslate` |
| `translateSelection` | 159 | 埋点 + post `.frsetTranslateSelection` |

### 3.10 CaptureSectionView.swift

| 函数名 | 行 | 说明 |
|---|---|---|
| `init` | 14 | 空初始化 |
| `entryButton(mode:action:)` | 118 | 统一入口按钮样式 |
| `thumbnailView` | 178 | 最近截图缩略图 + 右键菜单（复制/OCR/标注/钉图/访达） |
| `pickAndStitch` | 211 | NSOpenPanel 多选（≤24 张）→ 后台 `Stitcher.stitch` → 主线程落盘 |
| `pinLatest` | 244 | 钉最近一张，无则选文件 |
| `annotateLatest` | 253 | 标注最近一张，无则选文件 |
| `chooseSingleImage` | 259 | 单文件选择面板 |


**⚠ 注意**：本视图的「长截图」按钮走的是 `pickAndStitch()`（**多图拼接**），而 `CaptureModule.capture(.long)` 走的是 `LongScreenshotCoordinator`（**滚动长截图**）。同一个 `CaptureMode.long` 在两个入口有不同语义，见第 7 节。

### 3.11 CaptureSettingsPane.swift

| 函数名 | 行 | 说明 |
|---|---|---|
| `init` | 25 | 从 Preferences 读 7 个 `@Stored` 初值 |
| `chooseDirectory` | 127 | 目录选择面板 |

### 3.12 ColorValuePanel.swift

| 函数名 | 行 | 说明 |
|---|---|---|
| `hex` | 15 | 复用 EyedropperView.hex |
| `rgb` | 18 | 复用 EyedropperView.rgbText |
| `hsb` | 21 | sRGB → H/S/B 百分比 |
| `formatRow` | 98 | 一行格式（点击复制） |
| `init` | 132 | 单例 |
| `show(color:recentColors:at:)` | 135 | 光标右下弹出，钳制可视区，装 global 点击监视器 |
| `close` | 184 | 移除监视器 + orderOut |
| `init(hexString:)` | 196 | `Color` 扩展：`#RRGGBB` 解析，失败回退灰 |

### 3.13 DelayedCaptureHUD.swift

| 函数名 | 行 | 说明 |
|---|---|---|
| `init` | 19 | 单例 |
| `start(seconds:)` | 22 | 先 cancel；建居中 HUD；装 Esc/Delete/右键监视器；1s 重复 Timer |
| `cancel(withToast:)` | 52 | 拆 Timer/monitor/窗 |
| `finish` | 63 | 拆资源后调 `captureFullScreen()` |
| `currentScreen` | 72 | 鼠标所在屏 → main → 首屏（**强解包 `screens.first!`**） |
| `init(screen:)` | 84 | 160×160 居中圆角窗，`ignoresMouseEvents = true` |
| `showValue` | 125 | 更新数字 |

**散文（延时截图的取消路径）**
- `DelayedCountdownWindow` 设了 `ignoresMouseEvents = true`，所以右键取消依赖的是 **local** monitor（`DeleteKeyMonitor` 用 `addLocalMonitorForEvents`）——只有本 App 是前台时才生效。其它 App 在前台时，用户按 Esc 只会取消那个 App 的操作，倒计时继续。
- `currentScreen()` 在 `NSScreen.screens` 为空时强制解包崩溃（虚拟机/远程会话极少见）。

### 3.14 ElementSnap.swift

| 函数名 | 行 | 说明 |
|---|---|---|
| `snap(atCocoaGlobal:)` | 37 | cocoa 左下 → AX 左上；`AXUIElementCopyElementAtPosition` → ①最深子元素 ②命中元素自身 ③窗口级 ④父链回退；无辅助功能权限直接 nil |
| `copyAttribute` | 102 | 读 AX 属性 |
| `copyElement` | 110 | 读并校验 `AXUIElementGetTypeID` 后强转 |
| `frame` | 119 | 读原始字符串 `"AXFrame"`（该常量未进 Swift 导入面） |
| `depth` | 127 | 沿父链计数到 window 角色 |
| `label` | 138 | `role · title`，title 取 24 字符 |
| `toCocoa` | 148 | AX 左上 → cocoa 左下 |

**散文（AX 扫描成本）**
- 每次 `snap` 都会 `AXUIElementCreateSystemWide()` + 一次跨进程 IPC；`deepestElement` 递归深度上限 12，最坏 12 次跨进程调用。调用方（覆盖层）以 90ms 节流，拖拽时每 90ms 一次，属于可接受但不便宜。
- 最小吸附尺寸 24×12：小于此的控件会被跳过，回退到祖先——这是"吸附到手感更好"的经验值，不是原版常量。

### 3.15 Eyedropper.swift

| 函数名 | 行 | 说明 |
|---|---|---|
| `init(frame:snapshot:)` | 24 | 一次性把快照解成 RGBABuffer（取色只读缓冲，不再碰 CGImage） |
| `init(coder:)` | 34 | fatalError |
| `pixel(at:)` | 37 | 视图点 → 缓冲像素（y 翻转 + 钳制） |
| `makeColor` | 48 | 三元组 → sRGB NSColor |
| `mouseMoved` | 56 | 更新采样点与当前色，重绘 |
| `mouseDown` | 65 | 提交颜色 |
| `rightMouseDown` | 75 | 取消 |
| `draw` | 79 | 只画 96pt 放大镜 + 像素网格 + 十字 + 色值标签（**不压暗全屏**，否则取色不准） |
| `hex` | 164 | `#RRGGBB` |
| `rgbText` | 173 | `R, G, B` |
| `init(screen:snapshot:)` | 184 | `.screenSaver` 级 borderless 窗 |
| `keyDown` | 201 | Esc 取消 |
| `init` | 227 | 读 `capture.eyedropper.recent` |
| `start()` | 232 | 手动取色：先以 nil 结算挂起请求；`wantsValuePanel = true`；鉴权后开会话 |
| `pickColor(completion:)` | 248 | 程序化取色：**保证 completion 恰好一次**；`wantsValuePanel = false`；`pendingPick` 必须在 `finish` 之后登记 |
| `finish(_:)` | 271 | 关窗 + 兜底 `resolvePending(nil)` |
| `beginSession` | 281 | 手动路径的会话建立 |
| `screenUnderMouse` | 288 | 鼠标所在屏 |
| `presentPicker` | 293 | 同步抓屏 → 建窗 → 取色回调里：复制 HEX、广播、Toast、入历史、（手动时）弹色值面板、结算 pending、关窗 |
| `resolvePending` | 325 | 取出并清空挂起回调 |
| `pushRecentColor` | 332 | 去重置顶，上限 10，落 UserDefaults |
| `copyHexToPasteboard` | 341 | 写剪贴板 |

**散文（Eyedropper 的挂起回调正确性）**
- 这是本模块唯一有"恰好一次 resume"契约的地方：`pickColor` 先把旧 pending 以 nil 结算，再 `finish(nil)`（内部 resolve 此时已空），然后才登记 `pendingPick`。顺序错了就会出现 continuation 悬挂或双重 resume。
- `start()` 会以 nil 结算挂起的程序化请求——即用户在工具箱取色中途手动取色，工具箱那次 `await` 会拿到 nil（语义上可接受，但调用方要能处理 nil）。

### 3.16 EyedropperBridge.swift

| 函数名 | 行 | 说明 |
|---|---|---|
| `pickColor()` | 24 | `withCheckedContinuation` + 主线程启动 `Eyedropper.shared.pickColor`，返回 HEX 或 nil |

### 3.17 ImageProcessor.swift

| 函数名 | 行 | 说明 |
|---|---|---|
| `pngData` | 12 | ImageIO 编码 PNG（无损、支持透明） |
| `scaled` | 24 | 等比缩到最长边；不放大 |
| `resized` | 33 | 强制缩放（长截图统一宽度用），high 插值 |
| `crop` | 53 | **点坐标**矩形 → 像素：按 `image/screenFrame` 双轴比例缩放、y 翻成左上原点、`integral`、裁剪并二次钳制；< 1px 返回 nil |
| `nsImage` | 72 | 按像素尺寸建 NSImage（避免 72dpi 缩放错觉） |
| `cgImage(from data:)` | 77 | ImageIO 解码（比 NSImage 线程安全） |
| `cgImage(from url:)` | 83 | 同上，文件 |
| `init(width:height:pixels:)` | 97 | `RGBABuffer` 构造 |
| `colorAt` | 105 | 越界返 nil，返回 (r,g,b) |
| `rgbaBuffer` | 114 | 解码到 RGBA 缓冲，可顺带缩放到指定宽度 |

**散文（crop 的倍率）**
- `crop` 的 sx/sy 分别用 `image.width/screenFrame.width` 与 `image.height/screenFrame.height` 计算，**不假设二者相等**。这是修 v149 拉伸问题的关键：SCK 输出尺寸与选区点尺寸可能不同轴（尤其外部显示器）。
- 双轴独立缩放在某些"非等比 1x/2x 混排"场景会引入亚像素偏移，但因为最终 `integral` 并二次钳制，误差不超过 1px。

### 3.18 LongScreenshotCoordinator.swift

| 函数名 | 行 | 说明 |
|---|---|---|
| `start(session:)` | 25 | 先 `stop()` 清旧监视器再挂新会话；global scrollWheel 只累积位移；global keyDown 仅 Esc；local keyDown 支持 Esc/Return |
| `stop` | 62 | 移除三监视器并把 session 置 nil |
| `init` | 93 | 单例 |
| `confirmClearAnnotations(hasAnnotations:)` | 99 | 有标注时弹"清除标注并开始长截图？" |
| `beginSelection` | 113 | 提示 + 查重入 + **权限失败也继续**（v139：权限探测假阴性会让覆盖层永不出现） |
| `beginSelectionUI` | 134 | 闭旧覆盖层→逐屏建覆盖层→`orderFrontRegardless` + `makeKey`（后台态 `makeKeyAndOrderFront` 会被忽略） |
| `commitSelection(rect:window:)` | 168 | 视图坐标→AppKit 全局；选区 <8pt 取消；启动会话 |
| `beginFromLastSelection` | 187 | 复用 `lastSelectionAppKit` 直接起会话（动作条「长截图」入口） |
| `startSession(appKit:displayID:)` | 201 | AppKit→CG 坐标；建 Session、接线 onFinish/onProgress、起监视器、选区边框窗、HUD（避开选区） |
| `cancelSelection` | 239 | 关覆盖层 |
| `closeSelectionOverlays` | 243 | orderOut 全部并清空（v139：必须 orderOut，只 removeAll 会留下旧层抢事件） |
| `handleSessionFinished` | 252 | 拆资源；finished→复制到剪贴板 + 预览窗；failed→Toast 提示权限 |
| `beginDemoSession` | 290 | 固定 600×500 选区起会话（排障） |
| `finishCurrentSession` | 300 | 排障：收尾 |
| `cancelCurrentSession` | 305 | 排障：取消 |

**散文（长截图为什么"定时采样"而不是"事件驱动"）**
- v150 之前是全局 scrollWheel + 55ms 去抖驱动采帧：滚动一快就漏帧；光标移出选区就静默停采（旧版最隐蔽的坑）；事件到达时画面还在动，抓到的帧滞后。现参照 ScrollSnap 改成 0.25s 定时器（按帧高自适应 60–200ms），滚轮事件只做"位移提示"。
- 全局 Return 被删除（旧实现会在目标 App 里也触发一次 Return，可能提交表单），完成改为点 HUD 按钮；本 App 聚焦时 local monitor 仍支持 Return。

### 3.19 LongScreenshotDiagnostics.swift

| 函数名 | 行 | 说明 |
|---|---|---|
| `runStitcherCheck` | 17 | 后台：合成 480×3600 长图→按已知位移切 14 帧喂拼接器→验证宽高与逐行差 <8→写日志 |
| `showPreviewDemo` | 99 | 后台合成 480×3600 → 主线程开预览窗 |
| `describe` | 109 | `Outcome` → 中文描述 |
| `makeSource` | 118 | 合成长图（随机行高/缩进/字号/色块 + 唯一编号，避免周期性误配） |
| `rnd` | 129 | xorshift 伪随机（`makeSource` 内） |
| `r` | 130 | 取模（`makeSource` 内） |

### 3.20 LongScreenshotFrameStream.swift

| 函数名 | 行 | 说明 |
|---|---|---|
| `start(displayID:selectionRectCG:)` | 33 | 后台 Task：枚举 SCK 内容→排除本 App 全部应用→`sourceRect` = 选区（display 局部坐标）→**pixelRatio = display.width / display.frame.width**（不能用 backingScaleFactor）→30fps、`scalesToFit=false`、`queueDepth=5` |
| `stop` | 92 | 锁内清 stream/latest/connected，锁外 `stopCapture()` |
| `latestFrame(maxAge:)` | 103 | 帧龄超阈值返回 nil（画面静止时 SCK 不出帧） |
| `latestFrameAge` | 113 | 帧龄查询 |
| `stream(_:didOutputSampleBuffer:of:)` | 123 | 校验 `.complete` 状态 → `VTCreateCGImageFromCVPixelBuffer` → 锁内更新 latest |

**散文（倍率事故，v149）**
- 用户机器上 `backingScaleFactor` 报 2.0，但 `SCDisplay` 像素宽 == 点宽（有效 1x）。按 2 倍申请输出尺寸后，SCK 把 431×505 的选区**放大成 850×999**，整幅长截图被拉伸发虚——就是用户说的"十分怪异、有拉伸效果"。
- 正确口径与 ShareX 一致：`scalingFactor = PhysicalScreenHeight / LogicalScreenHeight`，即 `display.width / display.frame.width`。
- 帧率固定 30fps + `queueDepth=5`：静画面时 SCK 不产帧，`latestFrame(maxAge: 0.15)` 会返回 nil，这是**正常**的（不是采帧失败），`captureTick` 里专门区分了 `streamStale` 与 `captureFailures`。

### 3.21 LongScreenshotHUD.swift

| 函数名 | 行 | 说明 |
|---|---|---|
| `init(rect:)` | 17 | 选区边框窗：`.statusBar` 级、点击穿透、`sharingType = .none`（系统级禁止被捕获） |
| `draw` | 40 | 橙色 1.5pt 圆角描边 + 四角 3pt 角标 |
| `show(near:avoiding:)` | 79 | 光标附近；越界翻转；与选区相交时改放选区外（否则每帧把 HUD 截进图里） |
| `fits` | 93 | `show` 内：候选点是否既在屏内又不压选区 |
| `update(height:status:)` | 187 | 像素高度 + 四态文案（采集/静止/太快/丢段） |
| `close` | 209 | orderOut + 清控件引用 |
| `finishTapped` | 216 | 转发 onFinish |
| `cancelTapped` | 217 | 转发 onCancel |

### 3.22 LongScreenshotMotionCrop.swift

| 函数名 | 行 | 说明 |
|---|---|---|
| `movingColumns(previous:current:)` | 26 | 4×4 降采样灰度→逐列平均绝对差→阈值 `max(5, 全图均值×2)`→闭运算填 ≤8 列空隙→取最长段→移动区 ≥25% 宽且 ≥160px、静止区 ≥8% 宽才返回；向外吸附到最强竖直边缘 |
| `edgeSearch` | 98 | `movingColumns` 内：在区间内找列均值突变最大的位置 |
| `similar` | 118 | 两区间 IoU ≥0.8（连续两次一致才锁定） |
| `columnMeans` | 126 | 全分辨率逐列均值（按行抽样 ≤240 行） |
| `gray` | 143 | DeviceGray 重绘 |

### 3.23 LongScreenshotPreviewWindow.swift

| 函数名 | 行 | 说明 |
|---|---|---|
| `init(image:)` | 15 | 文档视图按图像像素尺寸初始化 |
| `init(coder:)` | 22 | fatalError |
| `draw` | 26 | 深色底 + 高质插值画图 |
| `fitCentered(in:)` | 40 | 按容器宽度等比缩放；**不改 frame.origin**（NSClipView 会再偏移一次，否则整窗空白）；图片水平居中 |
| `init(document:)` | 59 | 带横竖滚动条 + 允许缩放 |
| `init(coder:)` | 69 | fatalError |
| `init(document:onSave:onCopy:onClose:)` | 118 | 滚动视图 + 底部工具条；按钮闭包用 `ClosureButtonAction` 桥接 |
| `layout` | 120 | 布局 + `fitCentered` + **首次**滚到顶部（等 clip 尺寸就绪，否则滚到上方空白） |
| `layoutEditor` | 140 | 工具条贴底、三按钮右对齐 |
| `init(handler:)` | 158 | 私有，持有闭包 |
| `bind(_:handler:)` | 160 | `objc_setAssociatedObject` 保活 target |
| `fire` | 167 | 触发闭包 |
| `init` | 209 | 单例 |
| `show(image:)` | 211 | 关旧窗开新窗；保存走 `savePNG` + `registerCaptured(mode:"long")` |
| `windowWillClose` | 235 | 清引用 |

### 3.24 LongScreenshotSession.swift

| 函数名 | 行 | 说明 |
|---|---|---|
| `samplingInterval(frameHeight:)` | 68 | `0.45×帧高/4000`，钳制 60–200ms（目标：单次位移 ≤45% 帧高） |
| `start` | 160 | 起帧流（macOS 14+）→串行队列里等首帧（≤1200ms）→`captureTick(force:true)`→启动定时采样 |
| `startSampling` | 194 | `DispatchSourceTimer`，串行队列，leeway 15ms |
| `stopSampling` | 210 | 清 handler 后 cancel |
| `cancel` | 219 | 置 stopped/cancelled、停采样与帧流、主线程回调 `.cancelled` |
| `finish` | 230 | 停采样→**强制补采一帧**→停帧流→主线程回调 `.finished` + canvas |
| `stopFrameStream` | 248 | 停并清引用 |
| `onScroll(deltaY:deltaX:)` | 259 | 锁内累积位移提示（不决定是否采帧） |
| `logOnce` | 271 | 同一 tag 2s 内只记一条；**静态字典无锁** |
| `captureTick(force:)` | 280 | 取帧（优先新鲜帧流，静止则跳过；帧流卡住且确有滚动→同步兜底；否则同步抓屏）→运动裁剪→`stitcher.append`→失败计数（连续 3 次判 failed）→HUD 进度 |
| `updateMotionCrop` | 403 | 连续两次检测一致才 `stitcher.recrop` 锁定滚动列区间 |
| `captureFrame` | 423 | 优先帧流最新帧；内容缩放写 `contentScale` 并钳制 |
| `captureFrameSync` | 436 | dlsym 旧 API（option 0x14）→ 失败回退 `sckCaptureSync`；按 CGDisplayBounds 换算裁剪 |

**散文（captureTick 的三态与锁）**
- `lock` 只保护 `pendingDelta/pendingDeltaX/isStopped/isCancelled`；`frameStream`、`captureFailures`、`stitcher` 全部在 session 串行队列上独占访问，靠"只有一个队列"而不是锁来保证。
- 但 `logOnce` 的 `logPacedAt` 是 `static var`，多个 Session 实例（理论上同一时刻只有一个，但排障入口/深链可能绕过 `guard session == nil`）会并发写同一个字典 → 潜在数据竞争。
- `streamStale` 分支刻意不增加 `captureFailures`：静画面时 SCK 不出帧是正常现象，把它当失败会导致"滚到底部就报错"。
- 同步兜底限流 3 次/秒（`lastSyncFallbackAt`），且只在"确有滚动提示"或 `force` 时才走——避免静止时每 tick 都做一次 100–400ms 的 `SCShareableContent` 枚举。


### 3.25 LongScreenshotStitcher.swift

| 函数名 | 行 | 说明 |
|---|---|---|
| `drawToBuffer` | 30 | 用 `UnsafeMutableRawPointer` + `memset` 建上下文（`&array` 桥接生命周期不保证） |
| `init(image:)` | 45 | 一帧 → RGBA 缓冲 |
| `init(w:h:bytes:)` | 52 | 直接构造 |
| `graySignature` | 161 | 缩到指定宽生成灰度签名（恒等帧判定用） |
| `meanAbsDiff` | 177 | 行列步长 2 抽稀的平均绝对差 |
| `append(frame:hintDY:scrollSinceAppend:)` | 204 | 主入口：宽度归一（±4px 重绘）→恒等判定→首帧建画布→`searchOffset`（画布→anchor 兜底）→横向漂移拦截→向上滚动不追加→追加条带；失败时按"是否真跳了一屏"决定整帧重同步（≤2 次） |
| `recrop(xRange:)` | 368 | 把画布横向裁到滚动区（memcpy 逐行），作废 anchor |
| `strip` | 414 | 取帧的 `[startRow, startRow+rows)` 条带；dx≠0 时逐行平移并钳制边缘（补 255 透明） |
| `redraw` | 469 | 帧宽归一到画布宽（±4px 场景） |
| `grayBuffer` | 482 | RGBA → 整数灰度（BT.601 近似，`>>8`） |
| `rowMeans` | 497 | 每行灰度均值（每行最多采 320 点） |
| `isLowTexture` | 515 | 行均值方差 <1 判为空白（无可对齐纹理） |
| `usableRows` | 554 | `searchOffset` 内：某 dy 下实际可比对的行区间（吸顶跳过量按剩余重叠自适应收缩） |
| `ncc1D` | 564 | 行均值一维 NCC |
| `ncc2D` | 612 | 逐像素二维 NCC（xStep 抽稀） |

**散文（对齐内核，v151-v152 重做）**
- 历史教训：v68–v149 用"世界坐标并集画布"，每帧重绘整张 O(n²) 且宽度漂移；v150 改定宽只追加条带（方向对）但用"绝对像素差 + 最差行惩罚"，阈值 `maxAlignScore=8` 对真实网页几乎不可能满足，吸顶导航 dy=0 反而高分，一旦某帧失败下一帧会因"和上次采样帧相同"被静默跳过——实测滚动十几屏画布停在首帧 1015×445。
- 现行四步：① 行投影 1D NCC 在 ±(帧高−最小重叠) 全范围粗搜；② top-5 种子（间隔 >6px）+ 滚动量提示/上次位移（正负两向）进候选；③ 每个种子 ±7px 内 2D NCC 精校；④ 阈值判定用"分数够高 或 峰值显著高于次峰 或 唯一孤峰且 ≥0.86"。
- `minOverlapFraction` 从 0.25 降到 0.18：25% 时最大可对齐位移只有 75% 帧高，扣掉 13% 吸顶栏后重叠不足阈值 → 快速滚动整段丢失（实测 5320px 处开始连续失败）。
- `maxHorizontalDrift = 1`：长截图不该横移，dx 只有在能把 NCC 拉高 >0.02 且 ≤1px 时才采纳——否则文字页 ±1px 分数抖动会"漂"出 3px 再被整帧丢弃，一丢就落后一屏，整场采集再也接不上。
- `pendingDelta` 的符号存疑（滚轮方向可能被系统反转），所以 hint 与 prior 的**正负两向**都进候选，交给 NCC 裁决。

### 3.26 OCRDiagnostics.swift

| 函数名 | 行 | 说明 |
|---|---|---|
| `runPipelineCheck` | 25 | 合成三行中文样张→只跑 Vision→再跑 thorough→对比文本/耗时/内存→再跑小链接检查 |
| `makeSmallURLDump` | 70 | 1600×900 深色画布 + 原生尺寸贴 `sample-url.png`（复现"大图里的小链接认不出"） |
| `runSmallURLCheck` | 91 | fast/thorough 各跑一次，判断是否命中真值 URL |
| `makeSample` | 106 | PingFang 14pt 三行样张 |
| `oneLine` | 135 | 换行转 ` / ` |
| `normalized` | 139 | 小写去空白 |
| `fmt` | 143 | 保留 1 位小数 |
| `residentMB` | 147 | `task_info(MACH_TASK_BASIC_INFO)` 取 RSS |

### 3.27 OCRRefiner.swift

| 函数名 | 行 | 说明 |
|---|---|---|
| `init` | 28 | SystemOCRRefiner |
| `refine` | 30 | 原样返回（不做加工） |
| `init` | 42 | LocalOCRRefiner |
| `refine` | 44 | 转 `OCRService.refineWithPPOCR` |
| `init(refiners:)` | 56 | 注册表构造（默认 system + local） |
| `refiner(id:)` | 62 | 按 id 查 |
| `resolve(preference:)` | 65 | `auto` → 本地可用就本地，否则 system；指定 id 找不到也回退 system |

### 3.28 OCRService.swift

| 函数名 | 行 | 说明 |
|---|---|---|
| `init` | 17 | 图片缓存 countLimit 12 |
| `image(for:)` | 20 | 按 Data 内容命中缓存，未命中解码后缓存 |
| `init` | 55 | 单例 |
| `recognizeText(imageData:)` | 70 | 协议实现 → `.fast` |
| `recognizeObservations(imageData:)` | 74 | 协议实现 → `.fast` |
| `recognizeText(imageData:quality:)` | 79 | observations → readingOrder → assemble |
| `recognizeText(image:quality:)` | 97 | 同上，CGImage 入口 |
| `recognizeObservations(image:quality:)` | 101 | `.fast`→`singlePass`；`.thorough`→`Task.detached` 跑 `multiPassSync`（几百 ms 不能占主线程） |
| `singlePass` | 116 | 自动语言一遍→空则 zh+1.6× 重试→仍空则自适应放大重试→置信度过滤（<0.3 且 ≤2 字丢弃） |
| `passVariants` | 162 | 三档绝对倍率 1.0/1.6/2.4（倍率是互补性最大来源）；图宽×倍率 >3200 的档位剔除 |
| `enhancementScale` | 186 | 无行→2×；行高中位数 <14px→放大到约 18px（2–3×）；按 24MP / 6000px 上限收口 |
| `mergeEnhanced` | 209 | 锚与增强版按 IoU ≥0.4 配对；增强版"多出字"或置信度高 0.08 才采纳；增强独有行 conf ≥0.5 且 ≥2 字才补；被增强行覆盖 ≥60% 的锚碎片丢弃 |
| `coverage` | 252 | `a ∩ b / a` |
| `multiPassSync` | 259 | 先跑锚→小字/空结果走增强合并→否则判"可信"（≥3 行且低置信占比 <30%）→不可信则多遍合并→最后统一 `OCRRefinerRegistry.active.refine` |
| `refineWithPPOCR` | 327 | 逐行裁图给子进程；只在"中文更多"或"中文数相同且内容不同"时替换；只差标点不换；英文/代码行一律留 Vision |
| `cjkCount` | 380 | CJK + 假名 + 谚文字数 |
| `contentKey` | 394 | 小写去空白/标点/符号的内容指纹 |
| `containsCJK` | 406 | 是否含 CJK |
| `merge` | 424 | 锚定式合并：只补锚里没有的 y 带，**不做替换**（实测替换会把正确结果换成高置信度错误） |
| `iou` | 453 | 归一化矩形 IoU |
| `runPass` | 463 | 一遍 Vision：accurate + revision3 + 自动语言或指定语言 + 放大预处理 |
| `preparedForOCR` | 491 | 按 scale 放大（≤4×、边长 <12000），high 插值 |
| `readingOrder` | 516 | 自上而下（容差 = 半个行高）、行内从左到右 |
| `assemble` | 527 | 行距 > 行高 0.85 倍时插空行分段 |
| `cleanLine` | 548 | 去 CJK 之间空格（正则已静态缓存）+ `sanitizeURL` |
| `sanitizeURL` | 571 | 去网址前的图标垃圾字符、去内部空格、去尾部标点，仅在"整行基本是网址"时改写 |
| `isURLShaped` | 597 | 域名形态正则匹配 |
| `setLanguages` | 610 | 写 `Preferences.Keys.ocrLanguages` |

**散文（OCR 质量策略的演进与坑）**
- 纯 Vision 中文小字/中英混排 CER 偏高（实测 9pt 混排 7.1%），错字集中在形近字与标点；纯 PP-OCR 需要自己做 DB 检测后处理（连通域+轮廓+unclip），工程量大。折中：**Vision 定位 + PP-OCR 认字**，绕开最难的检测后处理。
- 多遍合并一开始按"多数投票/最高置信度"做，基准反而更差（1.8%→2.6%）：1.6×/2.4× 会把「继续」认成「总续」、「的路径」认成「时路径」，而它们置信度并不低。所以最终改成**锚定式**：原尺寸+自动语言那一遍为锚，其余遍只补行不替换。
- 复核必须在**所有合并之后**做：合并分支会用锚的原始文本重建结果，先复核会被冲掉（实测「杂底小字」复核 3/3 行但最终文本仍是 Vision 的）。
- `preparedForOCR` 用 `scale >= 1.15` 才真的放大，`1.0` 直接返回原图——避免无谓的大图分配。

### 3.29 ObjectRemovalEngine.swift

| 函数名 | 行 | 说明 |
|---|---|---|
| `inpaint(image:mask:)` | 35 | 取首个引擎 |
| `init` | 45 | DiffusionInpainter |
| `inpaint(image:mask:)` | 52 | 降采样到 ≤384→标洞→多级 SOR→回写 UInt8→上采样→羽化 mask 混合回原图 |
| `solveLevels` | 110 | 按洞包围盒长边决定是否加 1/2、1/4 层；从最粗层向细层解，粗层解上采样作细层初值 |
| `nearestMask` | 217 | 最近邻缩放 mask |
| `nearestUpsample` | 230 | Double 缓冲最近邻上采样 |
| `resampleRGBA` | 245 | RGBA 缩放（经 CG medium 插值） |
| `bufferToImage` | 255 | bytes → CGImage |
| `rgbaBytes` | 265 | 任意图 → RGBA bytes（malloc 缓冲） |
| `rgbaGray` | 281 | 灰度图 → bytes |
| `downsample` | 298 | 降到指定尺寸 |
| `upsample` | 313 | 升到指定尺寸（high 插值） |
| `featherMask` | 324 | 两次盒模糊近似高斯 |
| `boxBlurGray` | 339 | 朴素灰度盒模糊（O(w·h·r²)，半径 2 时可接受） |

**散文（Double 缓冲的教训）**
- 迭代全程必须用 `Double`：`UInt8` 每轮量化截断会构成"单向棘轮"（上升增量 <1 被吞、下降至少降 1），实测会把整个解拖向 0。
- 工作分辨率上限 384 + 最多 3 层 + 400/220 轮 SOR：中等笔刷下主线程约 30–120ms；但 `ObjectRemovalEngine.inpaint` 是在 `mouseUp` 里**同步**调用的，笔刷直径 200、多次连续涂抹会累积卡顿。
- `boxBlurGray` 是 O(r²) 朴素实现，radius 固定 2，代价可控；换成大半径会立刻爆掉。

### 3.30 PPOCROCR.swift（进程内，现仅 OCRHelper 使用）

| 函数名 | 行 | 说明 |
|---|---|---|
| `init` | 49 | 私有单例 |
| `prepare` | 61 | 预热会话（主 App 已不再调用） |
| `ensureSession` | 73 | 懒加载：查模型/字典 → `FSPPOCRSessionCreate` → 读字典（去尾部空行，否则类别映射整体错一位） |
| `defaultLibraryPath` | 115 | `Contents/Frameworks/libonnxruntime.dylib` |
| `defaultModelPath` | 119 | `Resources/OCR/ppocr_rec.onnx` |
| `defaultDictionaryPath` | 123 | `Resources/OCR/ppocr_keys_v1.txt` |
| `recognize(line:)` | 130 | 预处理 → `FSPPOCRRun` → CTC 解码 |
| `recognize(lines:)` | 146 | 逐行映射 |
| `makeInput` | 154 | 等比缩到高 48、宽 ≤960（320 会压扁长行掉字），RGB `(x/255-0.5)/0.5`，输出 CHW |
| `decode` | 189 | CTC 贪心：取最大类、去重、跳 blank、算平均置信度；值域 [0,1] 时当概率直用 |

### 3.31 PPOCROCREmote.swift

| 函数名 | 行 | 说明 |
|---|---|---|
| `recognize(image:boxes:)` | 55 | 建临时目录→写 `frame.raw`（FOCR1 头 + BGRA）+ `boxes.json`→起 `Process`→后台读管道 + 10s 超时→解析 JSON |
| `selfCheck` | 130 | 合成"自检 OCR 123"样张跑一次全链路，日志记录往返 ms |
| `writeRaw` | 162 | 自定格式：`"FOCR1"` + w/h 小端 UInt32 + RGBA 像素 |

**散文（为什么从进程内改成子进程）**
- ONNX Runtime 不支持卸载：主进程里 `ReleaseSession` + `dlclose` 后 dyld 镜像仍在，RSS 从 100.9MB 一点不降，`malloc_zone_pressure_relief` 也救不回来。只有**进程退出**才能把运行时/模型/内存池整块还给系统。
- 代价：每次识别多一次进程启动 + 模型加载（实测 ~110–150ms）。相对整次 OCR（几百 ms 到 1s）可接受。
- `writeRaw` 用紧凑 BGRA 而不是 PNG：PNG 编码在小图上比像素拷贝慢一个量级。
- 超时后只 `terminate()` 不 `waitUntilExit()` 二次确认，`defer` 里的临时目录删除可能与仍存活的子进程竞争（子进程此时已读完全部输入，风险低）。

### 3.32 PinWindow.swift

| 函数名 | 行 | 说明 |
|---|---|---|
| `pinL10n` | 9 | `NSLocalizedString` 包装（L10n 基建未落地前回退英文键面） |
| `init` | 29 | HUD 56×28 |
| `init(coder:)` | 33 | fatalError |
| `update(percent:)` | 35 | 更新百分比文本 |
| `hitTest` | 43 | 返回 nil（点击穿透） |
| `draw` | 46 | 黑底圆角 + 白字居中 |
| `init` | 66 | 小模式关闭钮 18×18 |
| `init(coder:)` | 70 | fatalError |
| `draw` | 74 | 深色圆 + 白色叉 |
| `mouseDown` | 86 | 吞掉（避免拖动窗口） |
| `mouseUp` | 87 | 触发关闭 |
| `rightMouseDown` | 90 | 转交父视图弹动作菜单 |
| `init(near:text:)` | 104 | 一次性提示面板，贴图上方居中 |
| `present(autoDismissAfter:)` | 129 | orderFront + 4s 定时淡出 |
| `mouseDown` | 136 | 点击即淡出 |
| `fadeOut` | 139 | 0.25s 淡出后 orderOut |
| `acceptsFirstMouse` | 155 | 返回 true（首次点击即生效） |
| `init(coder:)` | 156 | fatalError |
| `init(frame:)` | 157 | 控件宿主视图 |
| `init` | 179 | 控制条 320×44、`.floating`、`hidesOnDeactivate=false` |
| `present(at:)` | 197 | 取消耗时隐藏、世代 +1、淡入、重置 2s 自动隐藏 |
| `dismiss(animated:)` | 213 | 世代比对防错序；动画/非动画两路；结束时置 `ignoresMouseEvents = true` |
| `scheduleAutoHide` | 241 | 2.0s 单发 Timer 加入 `.common` 模式 |
| `init(image:frame:)` | 312 | 装 tracking area、HUD、小模式关闭钮 |
| `init(coder:)` | 327 | fatalError |
| `draw` | 340 | 圆角裁剪画图 + 1px 白描边 |
| `layout` | 354 | 小模式切关闭钮；HUD 居中；调度一次性提示 |
| `repositionHUD` | 372 | HUD 居中 |
| `showHUD` | 379 | 更新百分比 + 2s 后隐藏 |
| `controlsFrame` | 392 | 贴图上方 6pt 居中 |
| `showControls` | 403 | 首次 `addChildWindow` 并装按钮，之后 `present` |
| `installControlButtons` | 416 | 5 个 SF Symbol 按钮，整组水平居中（旧布局第 5 个按钮超出 320pt 被裁掉） |
| `mouseEntered` | 446 | 显示控制条 |
| `mouseExited` | 447 | 鼠标是否仍落在控制条（外扩 1pt）内决定重显或隐藏 |
| `mouseMoved` | 458 | 更新光标 + 显示控制条 |
| `mouseDragged` | 462 | 显示控制条 + 拖动处理 |
| `makeCursor` | 472 | 用字形绘制的自定义对角光标 |
| `updateCursor` | 484 | 按命中区设光标 |
| `hitZone` | 497 | 9 分法命中区（边缘带宽 10pt） |
| `keyDown` | 523 | Esc/Delete/ForwardDelete 关闭当前贴图 |
| `mouseDown` | 532 | 记录起始 frame/鼠标/命中区 |
| `handleDrag` | 538 | body 移动窗口；边缘/对角改尺寸并保底 50pt |
| `mouseUp` | 583 | 清拖动状态 |
| `scrollWheel` | 591 | 缩放 |
| `magnify` | 592 | 捏合缩放 |
| `zoomCore` | 594 | 非 key 先抢 key；精确滚轮 delta/3.5、普通滚轮 ±12；向上=放大 |
| `applyZoom` | 620 | 以光标为锚点缩放（保持光标相对位置）；**无上限**（原作 `0x1002f5a00` 实为下限钳制 1.0/50pt） |
| `rightMouseDown` | 643 | 弹动作菜单 |
| `showActionsMenu` | 645 | Zoom 四档子菜单 + 标注/提取文字/翻译/保存 + 关闭；弹前隐藏控制条 |
| `handleScalePreset` | 680 | 档位缩放，以贴图中心为准并受屏可见域钳制 |
| `annotateClicked` | 705 | 送标注编辑器 |
| `ocrClicked` | 711 | 贴图 OCR：合并行→复制→弹结果（失败态 `Text Recognition Failed`） |
| `translateClicked` | 733 | OCR → `ServiceLocator.llmService` 翻译（无服务则原样展示） |
| `saveClicked` | 758 | 落盘 + `registerCaptured(mode:"pin")` |
| `closeClicked` | 766 | 关窗 |
| `showTextResultAlert` | 771 | 结果/失败弹窗（失败带 SF Symbol 图标） |
| `scheduleSmallModeTipIfNeeded` | 796 | 小模式 + 菜单未弹 + 无 pending + 未看过 → 异步调度 |
| `presentSmallModeTip` | 808 | 写一次性标记 + 展示 |
| `init(image:origin:)` | 827 | `.floating(3)`、无阴影、透明、`canJoinAllSpaces`、`acceptsMouseMovedEvents` |
| `initialSize` | 853 | 等比放入 `min(0.58×屏宽,420) × min(0.74×屏高,360)`，最小 60 |
| `becomeKey` | 867 | 把第一响应者交给 contentView（Esc 才可达）+ 通知 Manager |
| `constrainFrameRect` | 875 | 直通 super（允许拖出屏幕边缘） |
| `init` | 895 | 单例 + 装全局 local keyDown 监视器 |
| `show(image:at:)` | 920 | 错位平铺（`count%6 × 24`）+ 订阅 willClose |
| `show(url:)` | 934 | 文件 → 图 → 钉图 |
| `closeAll` | 940 | 关闭全部 |
| `closeActive` | 946 | 关闭活动贴图 |
| `windowDidBecomeKey` | 954 | 校验 contentView 类型后更新弱引用 |
| `windowDidClose` | 959 | 从数组移除 + 反注册通知 |


**散文（贴图窗三处历史 bug 与现解）**
- **HUD 一直飘着**（v83）：旧实现用独立 NSPanel + `addChildWindow`，childWindow 会在父窗每次 `orderFront`/成为 key 时被系统重新带出，于是 2s 后 `orderOut` 的 HUD 又复活且没有新 timer 收尾。现改为**内容视图内的子视图**，随贴图绘制、随 2s 定时器隐藏。
- **点叉号关不掉**（v83）：旧布局 `start=85, index×58`，第 5 个按钮 x=317、右缘 345，超出 320pt 窗口被裁掉。现整组居中：`5×28 + 4×30 = 260`，起点 30。
- **Esc 关不掉**（v83）：贴图窗是 nonactivating panel，点击不激活本 App，`PinnedScreenshotManager` 的 **local** keyDown 监视器收不到事件。现在内容视图 `acceptsFirstResponder = true` 并在 `becomeKey` 里把焦点交给它。
- ⚠ 副作用：`PinnedScreenshotManager` 的 local monitor 对 Esc 是 `closeAll()` 并吞键。用户在标注编辑器里按 Esc 时若贴图窗恰好存在，会**先关掉所有贴图**（monitor 不区分 key window，只判断本 App 是活动应用）。

### 3.33 QRCodeRecognizer.swift

| 函数名 | 行 | 说明 |
|---|---|---|
| `recognize(_:completion:)` | 14 | `VNDetectBarcodesRequest`（qr/aztec/ean13/ean8/code128/code39/pdf417/dataMatrix）在 global 队列跑，结果去重后回主线程 |
| `run(image:)` | 29 | 识别→复制到剪贴板→Toast→NSAlert（有 http 链接时给"打开链接"） |

### 3.34 ScreenTranslator.swift

| 函数名 | 行 | 说明 |
|---|---|---|
| `run(image:pinOrigin:)` | 38 | 非隔离入口，跳主线程 |
| `runAsync(image:pinOrigin:)` | 45 | OCR(thorough)→取前 80 块、每块 ≤600 字→判译入语言→批量翻译→后台渲染→落盘 + 钉回原位 |
| `translateBlocks(_:to:)` | 106 | 按 24 块分批 |
| `translateBatch(_:to:)` | 121 | 优先「⟦n⟧ 行号协议」批量翻译；不对齐则回退逐块（质量差但可用） |
| `parseNumberedLines(_:expected:)` | 139 | 解析「1. 译文」；行数不齐或有空行返回空数组（触发回退） |
| `render(image:blocks:)` | 161 | 规范化 RGBA→翻转左上原点→逐块：外沿环带采样底色→填圆角块→字号按块高自适应（装不下逐级 ×0.82，下限 9）→CoreText 逐行绘制 |
| `rgbaBuffer` | 224 | 规范化 RGBA8888 |
| `sampleBackground` | 237 | 块外沿上下/左右环带均值（避开文字本身） |
| `pixel` | 244 | `sampleBackground` 内：带钳制取像素 |
| `foregroundColor` | 270 | 亮度 >0.6 用近黑，否则近白 |
| `layout(_:font:fontSize:maxWidth:)` | 285 | CoreText 测宽逐字折行 |
| `width` | 287 | `layout` 内：单串排版宽度 |

**散文（为什么用 CoreText 而不是 NSString.draw）**
- `render` 直接在 `CGContext` 上画，没有 `NSGraphicsContext.current`，`NSString.draw` 不可用。CoreText 的 `CTLineDraw` 在裸 CGContext 上可以直接工作。
- 底色采样必须走"规范化 RGBA 缓冲 + 已知通道序"，不能直接读原图 `dataProvider`——原图可能是 BGRA/ARGB/带 padding，通道序不确定会取到错色。
- 译文替换而不是另开窗（对齐 eSearch 语义）：产出一张"翻译后截图"钉在原选区，用户看到的是"原文位置变成译文"。

### 3.35 ScreenshotManager.swift

| 函数名 | 行 | 说明 |
|---|---|---|
| `cgCapture(rect:)` | 41 | 走 dlsym 兼容层，`optionOnScreenOnly` + `bestResolution` |
| `cgRect(for:)` | 47 | NSScreen.frame（左下原点）→ CG 全局（主屏左上原点）；垂直堆叠多屏必须转换 |
| `cgCapture(screen:)` | 56 | 整屏抓取 |
| `displayID(of:)` | 61 | 从 `NSScreenNumber` 取 `CGDirectDisplayID` |
| `sckCaptureSync` | 71 | 信号量桥接异步 SCK，**禁止主线程** |
| `sckCapture(displayID:)` | 84 | 单帧整屏，`scalesToFit=false` |
| `sckCapture(windowID:)` | 101 | 单窗口（排除遮挡） |
| `init` | 163 | reloadRecent + 权限实况日志 + TCC 一次性重试探针 |
| `refreshPermission` | 230 | 只查 preflight（不弹窗） |
| `probePermission` | 252 | preflight 为真直接返回；否则用 `SCShareableContent` 能否枚举到 display 作权威判据；防重入 |
| `ensureScreenRecordingPermission` | 293 | 每次启动只请求一次 TCC、只弹一次说明；后续只 Toast |
| `showPermissionAlert` | 312 | 三按钮（权限引导 / 打开系统设置 / 稍后） |
| `captureRegion` | 339 | 区域截图（工具条流程） |
| `captureAndOCR` | 342 | 区域截图 → 直接 OCR |
| `captureAndPin` | 345 | 区域截图 → 直接钉图 |
| `captureAndCopy` | 348 | 区域截图 → 直接复制 |
| `captureAndScreenTranslate` | 351 | 区域截图 → 屏幕翻译 |
| `startRegionCapture` | 353 | 鉴权后进主线程 |
| `beginRegionCapture` | 361 | 逐屏抓快照 → 建覆盖层 → 接线 commit/cancel；`makeKeyAndOrderFront` 前先 `NSApp.activate`（v109 防首击被吃） |
| `commitRegion` | 389 | 关层 → 视图矩形转全局 → `lastSelectionAppKit` → 裁剪；direct 走 `handle`，toolbar 先落盘再弹条 |
| `cancelCapture` | 422 | 关层 + 清 isCapturing |
| `closeOverlays` | 427 | orderOut 全部并清数组 |
| `captureFullScreen` | 435 | 鼠标所在屏；优先 SCK，失败回退 CG |
| `captureDelayed` | 460 | 交给 `DelayedCaptureController` |
| `currentScreen` | 464 | 鼠标所在屏 |
| `captureWindow` | 481 | 鉴权 → 窗口拾取覆盖层 |
| `beginWindowCapture` | 489 | 同区域但 `pickMode: .window` |
| `commitWindow` | 515 | 优先 SCK 窗口级（windowID≠0），否则快照裁剪；收尾同区域路径 |
| `handle(_:action:)` | 557 | 统一收尾：PNG→落盘→登记→识码→按动作分流 |
| `registerCaptured` | 576 | recent 插队（≤60）+ 提示音 + 写历史库 + 记 `lastHistoryPath` + `onImageCaptured` 广播 |
| `apply(_:to:url:)` | 588 | 七种默认动作分派（含 Toast） |
| `apply(_:to url:)` | 618 | 文件版 |
| `savePNG` | 627 | 建目录 + 写文件，失败记日志返回 nil |
| `newFileName` | 640 | `Screenshot-yyyy-MM-dd-HHmmss-NNN.png` |
| `copyToPasteboard` | 649 | 同时写 PNG Data 与 NSImage |
| `playShutterSound` | 658 | `NSSound(named: "Pop")` |
| `reloadRecent` | 665 | 扫目录按修改时间倒序取 60 |
| `thumbnail` | 681 | 带 NSCache（48 项/20MB），`autoreleasepool` 包住解码 |
| `recognize(_ image:)` | 698 | PNG→`recognize(imageData:)` |
| `recognizeAndTranslate` | 704 | 识别后自动开结果窗翻译页签 |
| `recognize(imageData:autoTranslate:)` | 709 | 主线程 Task：OCR(thorough)→写 ocrText→空则 Toast→非空广播 + 回填历史 + 弹结果窗 |
| `copyOCRText` | 744 | 复制 ocrText + 广播 |
| `autoDetectQR` | 760 | 后台识码→命中则 Toast + 开结果窗二维码页签 |
| `saveStitchedResult` | 777 | 拼图落盘 + 入历史（mode long）+ 广播 + 状态文案 |
| `pin(url:)` | 797 | 文件 → 钉图 |
| `captureLongScreenshot` | 805 | 交给 `LongScreenshotCoordinator.beginSelection()` |
| `annotate(url:)` | 812 | 打开标注编辑器（文件） |
| `annotateLatest` | 818 | 打开最近一张 |

**散文（权限判据与 dlsym 兼容层）**
- `CGWindowListCreateImage` 在 macOS 15 SDK 里已 obsoleted（运行时直接返回 nil），而长截图采帧、区域截图底图全依赖它。修复方式与引擎侧 `frset_barwidgets.m` 同款：`dlopen` CoreGraphics + `dlsym` 拿符号，`unsafeBitCast` 成 `@convention(c)` 函数指针。系统兼容实现仍在（实测 macOS 15 返回有效 2x 图）。
- `CGPreflightScreenCaptureAccess` 返回的是 **TCC 记录与当前进程 code identity 的匹配结果**，会假阴性：刚重签名/替换、自签证书 csreq 与记录不完全一致、经 LaunchServices 双击启动 vs 终端启动（responsible process 归属不同）。直接拿它当硬闸门 → 用户明明授权了却反复被提示。
- 权威判据改用 SCK：`SCShareableContent` 只在系统**真正拒绝**录屏时抛错，能枚举到 display = 权限真实可用。
- `init` 里刻意**不做** SCK 探测：`SCShareableContent` 属屏幕录制 TCC 授权 API，放 init 会导致**每次启动都请求一次权限**（用户实测"一直重复请求"）。启动只做 `CGPreflight`（纯查询、不弹窗）。

### 3.36 ScreenshotOCRWindow.swift

| 函数名 | 行 | 说明 |
|---|---|---|
| `init(frame:textContainer:)` | 8 | 原文文本视图：只读可选、无背景 |
| `init(coder:)` | 18 | fatalError |
| `init(frame:)` | 27 | 原文滚动容器 |
| `init(coder:)` | 36 | fatalError |
| `setImage(_:)` | 39 | 按图像像素尺寸铺满文档区 |
| `configureInside` | 51 | 文本视图放进滚动视图的常规配置（宽度跟随、纵向自适应） |
| `init(frame:)` | 66 | 结果只读滚动容器（等宽 12pt） |
| `init(coder:)` | 79 | fatalError |
| `init(sourceImage:text:qrPayloads:)` | 130 | 760×480 窗；左右分栏 + 底部页签与按钮 |
| `setupRightPane` | 189 | 三页（文本/二维码/翻译）同位叠放切换 |
| `labelledRightPane` | 222 | 右栏套标题（标题随页签改名） |
| `labelled(_:content:)` | 235 | 滚动视图套标题容器 |
| `setResultText` | 254 | 替换识别文本（`text` setter 会把 URL 变成可点链接） |
| `setQRPayloads` | 259 | 更新 payload + 页签标题「二维码(N)」 |
| `selectQRTab` | 266 | 切到二维码页 |
| `tabChanged` | 271 | 三页显隐 + 标题 + 切翻译时请求译文 |
| `selectTranslateTab` | 281 | 外部入口切翻译页 |
| `setTranslatedText` | 287 | 译文或「翻译中…」 |
| `rebuildQRRows` | 297 | 重建二维码列表 |
| `qrRow` | 314 | 一行 payload + 复制/打开按钮 |
| `copyQR` | 344 | 复制单条 |
| `openQR` | 352 | 打开单条链接，失败 Toast |
| `copyTapped` | 362 | 转发 onCopy |
| `redoWrapped` | 363 | 转发 onReRecognize |
| `init` | 382 | 单例 |
| `show(sourceImage:imageData:text:qrPayloads:selectQR:autoTranslate:)` | 386 | 已有窗时增量更新（不用空文本覆盖）；否则建窗 + 装 `didResignKey` 失效关闭 |
| `translateCurrentText` | 426 | 复用缓存译文 / 调 `TranslationToolSession.translateDocument` |
| `close` | 455 | 卸监听 + 关窗 |
| `copyResult` | 466 | 复制结果 + 广播 |
| `reRecognize` | 474 | 重新 thorough 识别（空结果 Toast） |
| `windowWillClose` | 498 | 清引用 + 卸监听 |

**散文（失焦即关的代价）**
- v139 用户反馈"点其他地方不消失"，现用 `didResignKey` + 0.12s 延迟再判断 `isKeyWindow`。点窗内按钮不会失焦；但 NSAlert（"未读取到文字"等）会短暂夺 key，0.12s 的宽限能挡掉绝大多数误关，不是 100%。
- 已有窗口时 `show` 用"非空才写"策略避免 `autoDetectQR` 传空 text 把 OCR 结果冲掉。

### 3.37 ScreenshotOverlay.swift

| 函数名 | 行 | 说明 |
|---|---|---|
| `init(handler:)` | 14 | 本地监视器：keyDown + rightMouseDown，handler 返回 true 则吞事件 |
| `draw` | 39 | 放大镜：`interpolationQuality=.none` 整数倍放大 + 中心红十字；越界留白 |
| `init(frame:)` | 76 | 圆角 + 白边 + 阴影容器 |
| `init(coder:)` | 90 | fatalError |
| `layout` | 92 | 内缩 4pt 布局 |
| `follow(pointInView:viewSize:snapshot:)` | 98 | 更新采样点（视图左下→快照左上）+ 贴边翻到另一侧 |
| `snapshotWindowHits` | 184 | 枚举 on-screen 窗口（layer==0、排除本进程、≥80×60），CG→cocoa 坐标，生成标签 |
| `viewRect(of:)` | 208 | 全局 rect → 视图 rect |
| `init(frame:)` | 212 | 装放大镜 + 一次性窗口枚举 + Esc/Delete/右键取消监视器 |
| `init(coder:)` | 226 | fatalError |
| `mouseDown` | 239 | 窗口模式只记高亮；区域模式记起点 |
| `mouseDragged` | 251 | 更新终点 + 吸附 + 放大镜 |
| `mouseMoved` | 265 | 窗口模式：悬停高亮 + 90ms 节流 AX 探测；区域模式：吸附 + 放大镜 |
| `flagsChanged` | 291 | ⌥ 按下/松开立即重绘（吸附开关反馈） |
| `mouseUp` | 295 | 窗口模式：优先更细的 AX 元素（windowID=0），否则窗口；区域模式：单击命中吸附元素直接截取，<4pt 视为误点取消 |
| `refreshSnap` | 338 | 90ms 节流查询吸附元素 |
| `snappedPoint` | 350 | 8pt 内对齐吸附矩形边缘 |
| `elementHit` | 362 | 视图点 → 全局 → `ElementSnapEngine` → 视图 rect |
| `draw` | 371 | 选区外 4 矩形压暗（**不用 evenOdd 全屏填充**，v109 性能修复）+ 边框 + 四角 + 尺寸标签 / 窗口模式高亮 / 十字 / 吸附高亮 |
| `drawSnapHighlight` | 424 | 橙色半透明填充 + 1.5pt 描边 + 标签气泡 |
| `drawElementHighlight` | 448 | 黄色虚线 + 标签 |
| `drawWindowModeHint` | 472 | 顶部居中提示「悬停窗口以识别 · 单击截取 · Esc 取消」 |
| `drawWindowHighlight` | 486 | 白色 10% 填充 + 强调色 2pt 描边 + 窗口名标签 |
| `drawHandles` | 518 | 四角 5pt 方块 |
| `drawSizeLabel` | 529 | **像素**单位（点×backingScale），贴选区右下角、越界翻面 |
| `drawCrosshair` | 556 | 贯穿全屏 1px，先黑 35% 再白 75%（任何背景都读得出） |
| `init(screen:snapshot:pickMode:)` | 576 | `.screenSaver` 级 borderless、透明、`canJoinAllSpaces`、`canBecomeKey=true` |

**散文（overlay 的性能与坐标）**
- v109 用户反馈「第一次拉伸十分卡顿、没反应要第二次」：旧实现用 evenOdd 路径填充压暗，每次拖拽重绘遍历 7.6M 像素。现改为"选区外 4 个矩形"，成本降到边框级。
- 同一个 v109 还修了"首击被激活吃掉"：每个覆盖层 `makeKeyAndOrderFront` 前都 `NSApp.activate(ignoringOtherApps: true)`。
- 窗口枚举在 `init` 里只做一次（`windowHits` 缓存），悬停时零 CG 调用；但这也意味着**打开覆盖层后新出现的窗口识别不到**（实际使用中影响很小）。
- 每屏一个 overlay → 每屏一个 `DeleteKeyMonitor`（N 个本地监视器同时存在）；`ScreenshotManager.closeOverlays()` 只 `orderOut`，监视器要等视图 deinit 才释放——`overlays.removeAll()` 后窗口对象若无其它强引用即释放，监视器随之移除。

### 3.38 Stitcher.swift（多图拼接，独立于滚动长截图）

| 函数名 | 行 | 说明 |
|---|---|---|
| `stitch(_:)` | 42 | 统一宽度（只留高度不留像素，v128 内存优化）→逐对 `detectOverlap`→算总高→RGBA 画布从下往上画；上限 24 张 |
| `stitch(urls:)` | 106 | 文件版；有任一张解码失败则整体返回 nil |
| `detectOverlap(top:bottom:)` | 115 | 重叠从 60% 到 2% 全枚举，取平均绝对差最小者；差异 >22 判为不连续（重叠 0） |
| `sig(_:rows:fromTop:)` | 122 | 取上/下若干行裁片生成 128 宽灰度签名 |
| `meanAbsDiff` | 151 | 复用 `LongScreenshotStitcher.meanAbsDiff` |

### 3.39 TextFontPopover.swift

（无 func/init 符号；`TextFontModel` 为纯数据 + 闭包，`TextFontPopoverView` 为 SwiftUI 视图。）

---

## 4. 关键数据流

### 4.1 区域截图（最主链路）

```
⌥S / 面板按钮 / 菜单栏 / 深链 region
  → CaptureModule.capture(.area)          [埋点记录]
  → ScreenshotManager.captureRegion()
  → startRegionCapture(flow: .toolbar)
  → ensureScreenRecordingPermission()      [preflight → SCK 权威探测 → 每启动仅一次 TCC 请求]
  → beginRegionCapture()                   [@MainActor]
      ├─ 每屏 ScreenSnapshot.cgCapture(screen:)   ← dlsym CGWindowListCreateImage（同步，主线程）
      └─ ScreenshotOverlayWindow × N（.screenSaver 级）
  → 用户拖拽 → ScreenshotOverlayView.mouseUp → onCommit(rect)
  → commitRegion(rect:window:)
      ├─ 视图 rect + window.frame → AppKit 全局 rect（存 lastSelectionAppKit）
      ├─ ImageProcessor.crop(snapshot, rectInPoints:screenFrame:)   ← 双轴倍率换算
      ├─ ImageProcessor.pngData → savePNG(→ ~/Library/Application Support/FrsetNext/screenshots)
      ├─ registerCaptured(url:data:playSound:true)
      │    ├─ recent 插队（≤60）
      │    ├─ CaptureHistoryStore.record(url:mode:"area")   [异步 SQLite + 缩略图]
      │    └─ CaptureEventBus.onImageCaptured?(url, data)   ← App 层接到剪贴板历史
      ├─ autoDetectQR(in:)                                 [后台 Vision]
      └─ CaptureActionChain.present(image:url:selectionAppKit:)
            └─ 12 个工具之一 → perform(id:) → 各模块入口
```


跨模块边界：`CaptureEventBus`（静态闭包）、`Notification.frsetAirDropFiles`（空投）、`TranslationToolSession`（AI 模块，**直接引用，违反文件头声称的 CONTRACT §1.3**）。

### 4.2 长截图（滚动）

```
动作条「长截图」/ CaptureMode.long / 深链
  → LongScreenshotCoordinator.beginSelection()
  → beginSelectionUI()  [每屏 overlay，orderFrontRegardless + makeKey]
  → commitSelection → startSession(appKit:displayID:)
      ├─ LongScreenshotSession(selectionRectAppKit/CG, displayID)
      ├─ LongScreenshotCaptureStream.start(session:)   [global scrollWheel / global keyDown / local keyDown]
      ├─ session.start()
      │    ├─ LongScreenshotFrameStream.start()  [SCStream 30fps, sourceRect=选区(内收3pt), 排除本 App]
      │    ├─ 等首帧 ≤1200ms
      │    ├─ captureTick(force:true)  → stitcher 建画布
      │    └─ startSampling(60–200ms)
      ├─ LongScreenshotSelectionBorderWindow（sharingType=.none）
      └─ LongScreenshotHUDController.show(near:avoiding:选区)
每个 tick：
  latestFrame(maxAge:0.15) 或 captureFrameSync()
  → updateMotionCrop（连续两次一致才 recrop 锁定滚动列）
  → stitcher.append → 1D NCC 粗搜 → 2D NCC 精校 → 追加条带 / 重同步
  → onProgress(height, status) [主线程 HUD]
完成：
  → HUD「完成」/ 本 App 内 Return
  → session.finish() → 强制补采一帧 → canvas
  → handleSessionFinished → copyToPasteboard + LongScreenshotPreviewController.show
  → 预览窗「保存」→ savePNG + registerCaptured(mode:"long")
```

### 4.3 截图识字

```
动作条「识字」/ CaptureMode.ocr / 钉图右键「提取文字」
  → ScreenshotManager.recognize(image:)
  → recognize(imageData:autoTranslate:false)   [@MainActor Task]
      → OCRService.recognizeText(imageData:quality:.thorough)   [Task.detached]
          ├─ multiPassSync：锚遍 → 小字增强 或 多遍合并
          └─ OCRRefinerRegistry.active.refine
                └─ LocalOCRRefiner → PPOCROCREmote.recognize
                      └─ Process: Contents/Helpers/FrsetOCRHelper（一次性，10s 超时）
      → ocrText / Toast / CaptureEventBus.onTextRecognized
      → CaptureHistoryStore.updateOCR(path:text:)
      → ScreenshotOCRWindowController.show(sourceImage:text:)
            → 翻译页签 → TranslationToolSession.translateDocument
```

### 4.4 标注编辑

```
动作条「编辑」/ 最近截图右键 / 剪贴板「编辑图片」通知 / 历史双击（带快照）
  → AnnotationEditorController.open(image:/url:annotationState:)
       └─ 关掉所有 AnnotationEditorWindow → 新窗 → makeFirstResponder(canvas)
  → 画布交互（鼠标/keyDown）→ EditOp 撤销栈
  → 工具条「复制」→ canvas.composite() → AnnotationCompositor.composite
                  → ScreenshotManager.copyToPasteboard
  → 工具条「保存」→ pngData → savePNG → registerCaptured(mode:"annotate")
  → 关窗 → 若 sourcePath 非空且有标注 → CaptureHistoryStore.updateAnnotationState
```

### 4.5 钉图

```
动作条「贴图」/ CaptureMode.pin / 右键「钉在屏幕上」/ 屏幕翻译
  → PinnedScreenshotManager.show(image:at:)
  → PinnedScreenshotWindow（.floating）
  → 悬停 → showControls（childWindow + 2s 自动隐藏）
  → 滚轮/捏合 → zoomCore → applyZoom（锚点=光标）
  → 右键 → Zoom 四档 / 标注 / 提取文字 / 翻译 / 保存 / 关闭
  → Esc(local monitor) → closeAll；Delete → closeActive
```

### 4.6 取色

```
CaptureMode.color / 工具箱（EyedropperPickBridge.pickColor）
  → Eyedropper.start() / pickColor(completion:)
  → ensureScreenRecordingPermission
  → presentPicker: ScreenSnapshot.cgCapture(screen:) → RGBABuffer
  → 点击 → hex → 复制 + onColorPicked + Toast + pushRecentColor(UserDefaults)
        → 手动路径额外 ColorValuePanelController.show
```

---

## 5. 资源清单

### 5.1 定时器 / DispatchSource
| 资源 | 位置 | 周期 | 归属 |
|---|---|---|---|
| `sampleTimer`（DispatchSourceTimer） | `LongScreenshotSession.startSampling` | 60–200ms 自适应 | session 串行队列 |
| `Timer` 倒计时 | `DelayedCaptureController.start` | 1.0s 重复 | main runloop（默认模式） |
| `hideTimer` | `PinnedScreenshotControlsWindow.scheduleAutoHide` | 2.0s 单发 | **RunLoop.main .common** |
| `hudHideTimer` | `PinnedScreenshotContentView.showHUD` | 2.0s 单发 | main |
| `dismissTimer` | `PinnedScreenshotSmallModeTipWindow.present` | 4.0s 单发 | main |
| `DispatchWorkItem` 防抖 | `BeautifyWindow.rerender` | 20ms | global 队列 |
| `asyncAfter 1.2s` | `ScreenshotManager.init`（TCC 探针） | 一次性 | main |
| `asyncAfter 3.0s` | `CaptureModule.start`（抓屏探针） | 一次性 | main |
| `asyncAfter 0.12s` | `ScreenshotOCRWindowController`（失焦判定） | 一次性 | main |

### 5.2 线程 / 队列
- `com.frset.long-screenshot`（串行，`.userInitiated`）— session 全部计算。
- `com.frset.long-screenshot.frames`（串行，`.userInitiated`）— SCStream 采样回调。
- `com.frset.capture-history`（串行）— SQLite 全部读写。
- `DispatchQueue.global(.userInitiated)` — Beautify 渲染、QR 识别、多图拼接、诊断自检。
- `Task.detached(.userInitiated)` — OCR thorough、屏幕翻译渲染。
- `DispatchSemaphore` — `sckCaptureSync`（同步桥接）、`PPOCROCREmote` 管道超时。

### 5.3 子进程
| 进程 | 位置 | 参数 | 超时 |
|---|---|---|---|
| `Contents/Helpers/FrsetOCRHelper` | `PPOCROCREmote.recognize` | lib / model / dict / frame.raw / boxes.json | 10s → `terminate()` |

### 5.4 文件路径
- `AppDirectories.sub("screenshots")` — 默认截图目录（`Preferences.captureSavePath` 可覆盖，支持 `~`）。
- `AppDirectories.base/capture-history.sqlite` — 历史库。
- `AppDirectories.sub("capture-history")/thumb-<uuid>.png` — 缩略图。
- `Bundle/Contents/Frameworks/libonnxruntime.dylib`、`Bundle/Resources/OCR/ppocr_rec.onnx`、`ppocr_keys_v1.txt`、`sample-url.png`。
- `/tmp/frset_tcc_request_once`（探针标记）、`/tmp/frset_probe_dlsym.png`、`/tmp/frset_probe_sck.png`。
- `FileManager.temporaryDirectory/frset-ocr-<uuid>/`（每次 OCR 的临时目录，`defer` 删除）。

### 5.5 端口
无。本模块不起监听端口（传输类在 TransferDock）。

### 5.6 UserDefaults / Preferences 键
| 键 | 写入点 | 默认 |
|---|---|---|
| `capture.defaultAction` | `ScreenshotManager.defaultAction` | `save` |
| `capture.ocrShowResultWindow` | `ScreenshotManager.ocrShowResultWindow` | `true` |
| `capture.delaySeconds` | `ScreenshotManager.delaySeconds` | `5` |
| `capture.afterSelect.showToolbar` | `CaptureActionChain.showToolbarAfterSelection` | `true` |
| `capture.eyedropper.recent` | `Eyedropper.pushRecentColor` | `[]`（上限 10） |
| `Preferences.Keys.captureSavePath` | `CaptureSettingsPane` | `""` |
| `Preferences.Keys.captureSound` | `CaptureSettingsPane` | `true` |
| `Preferences.Keys.ocrLanguages` | `OCRService.setLanguages` | `["zh-Hans","en-US"]` |
| `ocr.autoDetectLanguages` | `OCRService.autoDetectLanguages` | `true` |
| `pinnedScreenshot.smallModeTipSeen_v2` | `presentSmallModeTip` | `false` |
| `probe.annotate` | 外部写入，`AnnotationEditorController` 读 | `false` |

### 5.7 通知名
- `frset.captureHistory.changed`（`CaptureHistoryStore.didChangeNotification`）
- `frset.screenshotTranslate.request` / `frset.translateSelection.request`
- `frset.clipboard.editImage`（观察者）
- `frsetAirDropFiles`（post，userInfo `["urls": [URL]]`）
- `NSWindow.didResignKeyNotification`（OCR 结果窗）
- `NSWindow.willCloseNotification`（贴图窗）

### 5.8 环境变量
`FRSET_TCC_REQUEST=1`、`FRSET_CAPTURE_PROBE=1`。

### 5.9 深链
|  |  |  |
| --- | --- | --- |
- `frsetnext://capture?action=history|delayed|region[&seconds=N]`
- `frsetnext://longshotcheck`（拼接自检，入口在 App 层）

### 5.10 NSEvent 监视器
| 监视器 | 位置 | 类型 |
|---|---|---|
| scrollWheel（global） | `LongScreenshotCaptureStream` | 全局 |
| keyDown（global，仅 Esc） | 同上 | 全局 |
| keyDown（local，Esc/Return） | 同上 | 本地 |
| keyDown + rightMouseDown | `DeleteKeyMonitor`（每 overlay 一个、延时 HUD 一个） | 本地 |
| keyDown（local，Esc/Delete） | `PinnedScreenshotManager` | 本地（**常驻**） |
| keyDown/鼠标记 | `CaptureActionToolbarPanel`（3 个） | 本地 ×2 + 全局 ×1 |
| 鼠标（global + local） | `CaptureHistoryWindowController` | 全局 + 本地 |
| 鼠标（global） | `ColorValuePanelController` | 全局 |

---

## 6. 不变量与陷阱

1. **标注坐标恒为「图像像素、左上原点」**。任何把视图坐标/点坐标直接塞进 `Annotation.points` 的改动都会导致导出图错位（画布按 `imageScale` 映射，compositor 按 1:1 绘制）。
2. **`wrapWidth` 与字号解耦**。存"逻辑文本 + 换行宽度"，绘制时才软换行；若改成"提交时硬换行存入 text"，调字号后不会重排，长文会溢出画面（2026-10-20 实障）。
3. **长截图帧宽必须与画布同宽**。±4px 内重绘归一，超过必须丢帧——宽度不一致继续拼会把整幅图横向拉伸。
4. **长截图采样间隔按帧高自适应**。固定 250ms 在快速滑动时一帧跨过整屏，无重叠可对齐（必然丢帧）。
5. **SCK 输出尺寸的倍率必须用 `display.width / display.frame.width`**。用 `backingScaleFactor` 会在"报 2.0 但实际 1x"的机器上把选区放大 2 倍（v149 拉伸事故）。
6. **采集矩形内收 3pt + 边框窗/HUD `sharingType = .none`**。缺任一条，结果图每帧顶边会多一条橙线、左右各一条竖线。
7. **`sckCaptureSync` 禁止主线程调用**（信号量阻塞）。目前只有 `LongScreenshotSession.captureFrameSync` 在会话串行队列上调用。
8. **马赛克必须 `replacePathWithStrokedPath` 后裁剪**，并且画像素化层前要再翻 y。
9. **贴图窗是非激活面板**：键盘路径只能靠 contentView 的 `keyDown`（`becomeKey` 里移交第一响应者），Manager 的 local monitor 只在本 App 活动时有效。
10. **`CaptureHistoryStore.init` 打不开 DB 直接 `fatalError`**——磁盘满/权限异常会让 App 启动即崩。
11. **OCR 复核必须在所有合并之后**，否则结果被锚的原始文本覆盖。
12. **`Eyedropper.pendingPick` 的登记顺序**（先 `finish` 再登记）决定 continuation 是否悬挂。

---

## 7. 重复实现 / 死代码 / 风险

### 7.1 重复实现
| 项 | 说明 |
|---|---|
| **两条长截图实现** | `Stitcher`（多图手选拼接）与 `LongScreenshotSession+LongScreenshotStitcher`（滚动采捕）并存。`CaptureSectionView.pickAndStitch` 用前者，`CaptureModule.capture(.long)` 用后者——**同一个 `CaptureMode.long` 在两个入口语义不同**。`ScreenshotManager.captureLongScreenshot` 只走后者，前者只能从面板按钮进。 |
| **两套马赛克缓存** | `AnnotationCompositor.composite` 内部 `mosaicCache`（每次导出重算）+ `AnnotationCanvasView.mosaicPixelCache`（按块大小缓存，底图变化失效）。 |
| **两套灰度签名/均差** | `LongScreenshotStitcher.graySignature/meanAbsDiff` 被 `Stitcher` 复用（合理）；但 `LongScreenshotMotionCrop.gray` 是第三份灰度转换。 |
| **两个 OCR 引擎入口** | `PPOCROCR`（进程内）与 `PPOCROCREmote`（子进程）。主 App 只用后者；前者只有 `OCRHelper` 目标引用，但源文件在主模块也编译（死重量，含 `lock`/`dictionary`/`session` 状态）。 |
| **两个 `getPixel`/坐标换算实现** | `ScreenSnapshot.cgRect(for:)`、`LongScreenshotCoordinator.startSession` 内的 AppKit→CG、`ElementSnapEngine.toCocoa`（AX→cocoa）、`ScreenshotOverlayView.snapshotWindowHits`（CG→cocoa）——四处独立实现同一族变换。 |

### 7.2 死代码 / 半死代码
- `PPOCROCR.prepare()`：注释说明 v143 已取消启动预热，无调用方。
- `LongScreenshotSession.captureFrame()`（public，无调用方；`captureTick` 自己内联了同样的逻辑）。
- `LongScreenshotSession.contentScale`：只写不读（仅诊断用，无日志输出）。
- `PPOCROCR.recognize(lines:)`、`rgbaGray`、`resampleRGBA` 等辅助在特定路径生效，但 `rgbaGray` 只被 `featherMask` 用。
- `ScreenshotMagnifierContainerView` 的 `follow` 中 `viewSize` 参数与 `bounds` 混用（调用方传 `bounds.size`，等价，属冗余参数）。
- `CaptureMode.ocr` 与 `CaptureDefaultAction.ocr` 语义重叠。

### 7.3 风险（按危险度）
1. **`CaptureHistoryStore.init` fatalError**（高）：DB 打开失败 → 启动崩溃，无降级路径。
2. **`PinnedScreenshotManager` 的 Esc 全局 `closeAll()`**（高）：在标注编辑器/其他窗口按 Esc 时，只要贴图存在就会全部关闭，且事件被吞。
3. **主线程同步抓屏**（中高）：`beginRegionCapture` / `beginWindowCapture` / `LongScreenshotCoordinator.beginSelectionUI` / `Eyedropper.presentPicker` 都逐屏 `ScreenshotSnapshot.cgCapture`（同步 dlsym 调用）。多屏 4K 时首帧延迟可达数百 ms，覆盖层"延迟出现"。
4. **`ObjectRemovalEngine.inpaint` 在 mouseUp 同步执行**（中）：大笔刷 + 多次连续涂抹会累积卡顿（每次 30–120ms）。
5. **`logOnce` 的静态字典无锁**（中）：`LongScreenshotSession.logPacedAt` 是 `static var`，跨实例并发写有数据竞争（当前靠"同时只一个会话"约束，但排障入口 `beginDemoSession` 绕过 `guard session == nil` 的路径不同——它检查了，所以实际安全边界依赖调用纪律）。
6. **`LongScreenshotStitcher.trace` / `lastNote` 是 `static var`**（中）：诊断自检与真实会话共享，并发时互相踩。
7. **`DelayedCountdownWindow` `ignoresMouseEvents = true`**（中）：右键取消实际收不到（只在 local monitor 覆盖的场景有效），用户可能以为能取消。
8. **`DelayedCaptureController.currentScreen()` 强解包 `screens.first!`**（低）。
9. **`ScreenshotOCRWindowController` 失焦即关**（低-中）：NSAlert 弹出会短暂夺 key，0.12s 宽限后判定可能误关结果窗。
10. **`CaptureActionChain.tools` 每次访问重建 12 个闭包**（低）：SwiftUI 每帧调用 `tools` 用于渲染，产生无谓分配。
11. **`AnnotationCanvasView` 撤销栈无上限**（低-中）：`imageSnapshot` 持有整图，反复抹除多张 4K 图内存显著增长。
12. **本模块直接引用 AI 模块**（架构性）：`ScreenTranslator` / `ScreenshotOCRWindow` → `TranslationToolSession`；`OCRRefiner` → `AISettings`；`PinWindow.translateClicked` → `ServiceLocator.llmService`；`CaptureSectionView` → `StatsBarEngine`。与 `CaptureEventBus` 头注"模块之间不互相引用具体类型"的声明不一致。
