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
