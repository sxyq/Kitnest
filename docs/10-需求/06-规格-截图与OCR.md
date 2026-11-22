# 06 - 规格：截图与 OCR（含权限链）

> 上游：01 号 §5/§6 ＋ 截图探针实测 ＋ 权限诊断报告（TCC 机制已透彻）。

---

## 1. 类清单（截图 8 类 + OCR 8 类）

### 1.1 截图
| 类 | 职责 |
|---|---|
| `ScreenshotManager` | 流程编排（唤起→选区→输出） |
| `ScreenshotOverlayWindow` + `ScreenshotOverlayView` | 全屏覆盖层（选区交互） |
| `ScreenshotMagnifierView` + `ScreenshotMagnifierContainerView` | 像素级放大镜 |
| `DeleteKeyMonitor` | 截图态按键（Esc/Delete） |
| `AnnotationCompositor` | 标注合成（箭头/矩形/文字绘制） |
| `ImageProcessor` | 缩放/裁剪/格式转换 |
| `ScreenshotOCRPanelView`（入口） | 「截图并 OCR」按钮分流 |

（长截图 10 类 / 钉图 8 类 / 取色器 5 类 → 见 10 号规格）

### 1.2 OCR
| 类 | 职责 |
|---|---|
| `ScreenshotOCRDirectVisionClient` | **本机 Vision OCR**（VNRecognizeTextRequest，离线） |
| `ScreenshotOCRDirectImageStore` | 直连模式的图片缓存 |
| `ScreenshotOCRWorkerClient` | Worker 模式（Helper 子进程，历史崩溃点已了解修复） |
| `ScreenshotOCRWindowController` | 结果窗管理 |
| `ScreenshotOCRResultWindow` / `ResultWindowDelegate` | 结果呈现 |
| `ScreenshotOCRSourceScrollView` / `SourceNSTextView` / `OCRReadOnlyScrollView` | 原文/结果文本视图 |

## 2. 行为清单

| # | 行为 | 细节 |
|---|---|---|
| B1 | 唤起截图 | 全局快捷键 / 主面板按钮 → 全屏 overlay（所有屏？） |
| B2 | 选区 | 拖拽选框；实时尺寸标签；放大镜取点；Esc 取消 |
| B3 | 输出分支 | ①复制到剪贴板 ②保存 ③**OCR 识别** ④钉图 ⑤长截图（滚动捕获）⑥标注编辑 |
| B4 | OCR 双通道 | 默认直连 Vision（本机、快）；Worker 模式用于兼容/后台场景 |
| B5 | OCR 结果 | 结果窗（原文对照 + 复制）；文本回流剪贴板（`ClipboardOCRTextStorage`） |
| B6 | 权限 | 屏幕录制（TCC；已建修复脚本 `frset/修屏幕录制授权.command`）；ScreenCaptureKit 需同权限 |
| B7 | 技术栈 | **ScreenCaptureKit**（框架已链接）+ CG（ApplicationServices） |

## 3. UI 规格

```
截图 overlay（全屏半透明）：
┌──────────────────────────────────────┐
│  ┌───────────选区───────────┐        │
│  │                          │  ┌──┐  │
│  │        （高亮区）          │  │放│  │  ← 放大镜（选区角）
│  │                          │  │大│  │
│  └──────────────────────────┘  └──┘  │
│   [W×H 尺寸标签]  [标注工具条] [✓][✗]  │  ← 工具条（箭头/矩形/文字/OCR/钉/长图）
└──────────────────────────────────────┘

OCR 结果窗：
┌────────────────────────────┐
│ [原文图]  │ [识别文本 · 可选中] │
│           │ [复制] [重新识别]   │
└────────────────────────────┘
```

## 4. 源码还原与代码骨架

```swift
// 4.1 截图主流程
final class ScreenshotManager {
    static let shared = ScreenshotManager()
    func capture(_ mode: CaptureMode) {          // .area/.window/.full/.ocr/.pin/.long
        // ① 建 ScreenshotOverlayWindow（每屏一个，.level = .screenSaver）
        // ② 鼠标拖拽 → 选区 rect（放大镜跟随）
        // ③ 确认 → CGWindowListCreateImage / ScreenCaptureKit 抓取
        // ④ 按 mode 分流：clipboard / save / OCR / pin / long
    }
}

// 4.2 OCR（直连 Vision——重建首选路径）
final class OCRService {
    func recognize(_ image: CGImage, completion: @escaping (String) -> Void) {
        let request = VNRecognizeTextRequest { req, _ in
            let text = (req.results as? [VNRecognizedTextObservation])?
                .compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n") ?? ""
            completion(text)
        }
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["zh-Hans", "en-US"]   // 开发时校准
        try? VNImageRequestHandler(cgImage: image).perform([request])
    }
}

// 4.3 权限检查（沿用已掌握机制）
func ensureScreenRecording() -> Bool {
    if CGPreflightScreenCaptureAccess() { return true }
    CGRequestScreenCaptureAccess()          // 触发系统弹窗 → 跳设置
    return false
}
```

## 5. 还原依据
| 依据 | 来源 |
|---|---|
| 类与流程 | 191 类清单 + 截图按钮实测（权限弹窗全流程） |
| OCR 双通道 | 类名实证（DirectVision vs Worker） |
| 权限机制 | 权限诊断报告（TCC 指纹绑定，已解决+脚本化） |
| 技术栈 | otool -L（ScreenCaptureKit/CG） |

## 6. 待查清单
| # | 待查 | 方法 |
|---|---|---|
| 1 | overlay 的窗口层级与多屏行为 | 实机（双屏若可用）+ 反汇编 |
| 2 | Worker 模式 IPC 协议（与 Helper） | 注入钩子 hook XPC/管道 |
| 3 | 标注工具完整清单与图标 | 截图工具条细看 + 本地化文案 |
| 4 | OCR 语言/精度参数 | 实机对比输出 + 反汇编 Vision 调用 |

## 7. 验收要点
- [ ] 截图（区域）→OCR→复制 全流程可用，识别率与原版一致
- [ ] Esc 取消、尺寸标签、放大镜行为对齐
- [ ] 权限首启流程与原版一致（弹窗→设置→重启生效）

## 8. 2026-10-20 标注编辑器重做（工具条 + 马赛克画笔）

### 8.1 实障：马赛克画出来是「线条/多边形」而不是笔刷

旧实现 `drawMosaicBrush` 把轨迹转成 `NSBezierPath` 后直接 `path.addClip()`。`addClip` 取的是
路径的**填充区域**，开放折线会被隐式闭合——得到的是轨迹与其弦围成的多边形，笔刷宽度完全不参与，
所以表现为一条歪斜的色块/线条；同时像素化图层在 flipped 上下文里直接 `ctx.draw`，
没有补一次翻转，马赛克内容上下镜像（块里显示的是另一处画面）。

修正（`AnnotationCompositor.strokeMosaic`）：

1. `ctx.addPath(points)` → `setLineWidth(brush)` → `setLineCap(.round)` → `setLineJoin(.round)`
   → **`replacePathWithStrokedPath()`** → `clip()`：把笔触转换成真正的圆头粗描边区域；
2. 裁剪后用「两次翻转」回到常规坐标再画像素化底图，内容与底图同向；
3. 单点单击用 0.01pt 的极小线段 + 圆头端帽，落笔即一个正圆；
4. 不做整图中间层：裁剪后只栅格化笔触覆盖区域，拖拽每帧都便宜。

参考实现（对照口径）：Snipaste 把「笔刷大小」和「单元格大小」作为两个独立参数，滚轮调笔刷；
Flameshot 滚轮调当前工具厚度；js-screenshot 的 pixelate 用 blockSize + round stroke 遮罩。

### 8.2 性能：移动橡皮擦卡顿

两处根因：

1. **底图惰性解码**：`ImageProcessor.cgImage(from:)` 走 `CGImageSourceCreateImageAtIndex`，
   返回的是惰性解码图；编辑器每帧 `draw` 都重新解 3000px 级 PNG。进入画布时一次性解成
   RGBA8 位图（`AnnotationCanvasView.decoded`），后续只做贴图。
2. **每次 mouseMoved 整画布重绘**：光标环移动触发 `needsDisplay = true`，等于每帧重画底图 + 全部标注。
   改为 `updateCursor`：只把「旧环 ∪ 新环」的并集标脏（`setNeedsDisplay(rect)`）。
   橡皮擦除命中时才整块重绘。

排障：单帧 > 40ms 时写 `[WARN][Capture] 标注画布重绘 XXms（dirty W×H）`。

### 8.3 工具条 UI 重做

- 结构：底部**悬浮胶囊**（材质 + 窗口色 + 0.5pt 描边 + 投影），不再是通栏工具带；
- 工具按「形状（矩形/椭圆/箭头）· 绘制（画笔/荧光/马赛克）· 内容（文字）· 修复（橡皮/抹除）」分组；
- 颜色：一个色点 → 弹层 8 色 + 系统取色器（不再把 8 个色点平铺）；
- 粗细：就地滑杆 + 数值 + 实时预览（笔刷圆点 / 线条粗细条 / 文字 A）；
  滚轮与 `[` `]` 同步可调，`[` `]` 不再占用撤销/重做（⌘Z / ⇧⌘Z 保留）；
- 马赛克块大小：胶囊内的紧凑 chip（图标 + 数值 + 箭头）→ 弹层 6/10/16/24；
- 撤销/重做独立成组；主操作只有「复制」，保存/更多（长截图、清空）/关闭降权为图标；
- 文字改为**画布内联输入**（原为模态 NSAlert）：点击落字、回车提交、Esc 取消、点别处提交。

### 8.4 默认粗细与区间（用户反馈：线条太细）

默认值按图幅自适应（`applyImageDefaults(imageWidth:)`）：

| 类别 | 区间 | 默认 |
|---|---|---|
| 形状 / 画笔线宽 | 1–40 | 图宽 ×1.0%（3000px 级 → 32） |
| 马赛克 / 橡皮 / 抹除笔刷 | 8–200 | 图宽 ×4.5%（3000px 级 → 154） |
| 文字字号 | 1–12（×6 = 12–72pt） | 1（最小值） |
| 荧光笔 | 1–16（×4 = 4–64px） | 4 |

文字默认取最小值（避免全局加粗后文字变成巨型字）；荧光笔独立宽度，避免 96px 色带。

### 8.5 验证

- 合成探针（`AnnotationCompositor.composite` 直出 PNG）：弯曲笔触呈连续圆头粗带，
  马赛克块内容与底图同向，笔刷宽度生效（对比图 `/tmp/anno_probe/mosaic_brush.png`）；
- 实机（`kitnest://annotate?file=…&tool=m`）：拖拽 → 日志
  `马赛克笔触：80 点，直径 36px，块 10px`；⌘S 落盘后在保存图里可见沿轨迹的马赛克；
- 橡皮擦：底图改内存位图 + 环脏矩形重绘后，移动不再触发整画布重绘（慢帧日志阈值 40ms）。
