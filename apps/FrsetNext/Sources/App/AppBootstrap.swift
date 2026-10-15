import Foundation
import AppKit
import Carbon.HIToolbox

/// 总控接线：注册全部模块 → 启动 → 连接跨模块事件总线
enum AppBootstrap {
    private static var started = false

    static func start() {
        guard !started else { return }
        started = true

        // 1) 注册模块（顺序 = 依赖顺序：基础服务 → UI 容器 → 功能）
        ModuleRegistry.register(PanelModule.self)
        ModuleRegistry.register(SettingsModule.self)
        ModuleRegistry.register(StatusBarModule.self)
        ModuleRegistry.register(MonitorModule.self)
        ModuleRegistry.register(ClipboardModule.self)
        ModuleRegistry.register(CaptureModule.self)
        ModuleRegistry.register(AIModule.self)
        ModuleRegistry.register(ToolboxModule.self)

        // 2) 启动（各模块在 start() 内完成自我注册与服务注入）
        ModuleRegistry.startAll()

        // 3) 跨模块事件接线（总控统一连，模块之间不互相引用）
        wireEventBuses()

        // 3.5) 预览数据桥接线（specs/12）：Panel 侧预览内容消费 ClipboardManager 的全文/OCR 文本。
        //      未接线时走数据桥内置后备（直读 textPath / richTextPath / content），但 OCR 附加区块缺失。
        PreviewPopoverDataBridge.shared.fullTextProvider = { ClipboardManager.shared.fullText(for: $0) }
        PreviewPopoverDataBridge.shared.ocrTextProvider = { ClipboardManager.shared.ocrText(for: $0) }

        // 4) App 层工具注册（跨模块工具砖：如取色器需接 Capture 的取色会话）
        registerAppLevelTools()

        // 5) 全局快捷键默认绑定表（specs/19）：须在 ModuleRegistry.startAll() 之后调用，
        //    handler 为懒分发，触发时才经 ServiceLocator / 各模块公开 API 执行
        registerDefaultHotkeys()

        Log.info("Bootstrap", "全部模块已启动")
    }

    static func stop() {
        Log.info("Bootstrap", "应用退出")
    }

    // MARK: - 事件总线接线

    private static func wireEventBuses() {
        // 截图完成 → 写入剪贴板历史（若剪贴板模块可用）
        CaptureEventBus.onImageCaptured = { url, data in
            ClipboardManager.shared.insertImage(data: data, fileURL: url, sourceApp: "FrsetNext")
            DatabaseManager.shared.bumpStat("screenshot_count")
        }

        // OCR 完成 → 写入剪贴板历史（文本条目）
        CaptureEventBus.onTextRecognized = { text in
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            ClipboardManager.shared.insertText(text, sourceApp: "FrsetNext.OCR", subtitle: "截图 OCR")
            DatabaseManager.shared.bumpStat("ocr_count")

            // 截图翻译会话（specs/19 screenshotTranslate 默认热键）：OCR 文本产出后交给划词翻译会话，
            // 译文以工具产出回流剪贴板历史（App 层接线，模块间不互相引用）
            if takeScreenshotTranslatePending() {
                translateAndIngest(text, successTip: "截图翻译完成，译文已写入剪贴板")
            }
        }

        // AI 产出 → 写入剪贴板历史（标记为工具生成：is_generated_by_tool=1）
        // 注：ai_request_count 由 LLMService.send 统一计数（每次请求一处），此处不重复 bump
        AIEventBus.onResultProduced = { text in
            ClipboardManager.shared.ingestToolOutput(text: text, sourceToolKeyword: "ai")
        }

        // 工具箱产出 → 写入剪贴板历史（标记为工具生成）
        // 注：tool_count 由 ToolRegistry.run → recordInvocation 统一计数（每次运行一处），此处不重复 bump
        ToolboxEventBus.onResultProduced = { text, kind in
            ClipboardManager.shared.ingestToolOutput(text: text, sourceToolKeyword: kind.rawValue)
        }

        // 全局搜索源：剪贴板条目检索（映射为工具箱的 SearchResultItem，注册进检索框架）
        SearchHookRegistry.register { query in
            await ClipboardManager.shared.searchGlobal(query: query, limit: 8).map { hit in
                SearchResultItem(id: "clipboard-" + hit.item.dedupeKey,
                                 title: hit.title,
                                 subtitle: hit.subtitle,
                                 icon: "doc.on.clipboard") {
                    ClipboardManager.shared.copy(hit.item)
                    ServiceLocator.panel?.hide()
                }
            }
        }
    }

    // MARK: - App 层工具注册（跨模块工具砖）

    /// 跨模块协作的工具（如取色器要接 Capture 的取色会话）统一在总控注册，
    /// Toolbox 模块不直接引用其他模块具体类型（契约 §1.3）。
    private static func registerAppLevelTools() {
        // 取色器（对应原作 ToolKind.colorPicker）：触发 Capture 取色会话，HEX 作为工具结果回流。
        // 取色 UI 复用 Eyedropper 既有会话（同一套 overlay / 放大镜 / 取消判定），此处仅程序化入口。
        ToolRegistry.register(ToolDescriptor(
            identifier: "colorpicker",
            kind: .colorPicker,
            name: "取色器",
            systemImage: "eyedropper",
            category: .media,
            inputKind: .text,
            placeholder: "点击运行后到屏幕任意位置取色（Esc / 右键取消）",
            execute: { _, _ in
                guard let hex = await EyedropperPickBridge.pickColor() else {
                    return ToolOutput(text: "已取消取色", isError: true)
                }
                return ToolOutput(text: hex, note: "取色结果（HEX）")
            }))
        Log.info("Bootstrap", "App 层工具已注册：colorpicker")
    }

    // MARK: - 全局快捷键默认绑定表（specs/19）

    /// 默认热键表条目（组合键依据原作注册函数 0x1005c1094 还原，Carbon 掩码）
    private struct DefaultHotkeyEntry {
        let id: String
        let title: String
        let keyCode: UInt32
        let modifiers: UInt32
        let action: () -> Void
    }

    /// 出厂默认表（specs/19 §4 全量 10 条）。
    /// 注册语义（对齐原作）：先查用户自定义，命中则跳过该条默认注册；
    /// 组合键物理冲突时后注册者失败（restoreAll 先注册用户绑定，默认表后注册 →
    /// 冲突时默认条目失败并计入 ShortcutManager.failureReason，用户绑定胜出）。
    /// handler 只做懒分发：触发时才经 ServiceLocator / 各模块公开 API 执行。
    private static let defaultHotkeys: [DefaultHotkeyEntry] = [
        DefaultHotkeyEntry(id: "openFrset", title: "呼出主面板",
                           keyCode: 0x00, modifiers: UInt32(optionKey)) {
            ServiceLocator.panel?.toggle()
        },
        DefaultHotkeyEntry(id: "screenshot", title: "截图",
                           keyCode: 0x01, modifiers: UInt32(optionKey)) {
            ScreenshotManager.shared.captureRegion()
        },
        DefaultHotkeyEntry(id: "colorPicker", title: "取色器",
                           keyCode: 0x08, modifiers: UInt32(optionKey)) {
            Eyedropper.shared.start()
        },
        DefaultHotkeyEntry(id: "openAndSearch", title: "打开并搜索",
                           keyCode: 0x03, modifiers: UInt32(optionKey)) {
            ServiceLocator.panel?.show()
            NotificationCenter.default.post(name: .frsetFocusPanelSearch, object: nil)
        },
        DefaultHotkeyEntry(id: "floatingClipboard", title: "悬浮剪贴板",
                           keyCode: 0x09, modifiers: UInt32(shiftKey | cmdKey)) {
            FloatingClipboardWindowController.shared.toggle()
        },
        DefaultHotkeyEntry(id: "screenshotOCR", title: "截图 OCR",
                           keyCode: 0x01, modifiers: UInt32(shiftKey | optionKey)) {
            ScreenshotManager.shared.captureAndOCR()
        },
        DefaultHotkeyEntry(id: "screenshotTranslate", title: "截图翻译",
                           keyCode: 0x11, modifiers: UInt32(shiftKey | optionKey)) {
            beginScreenshotTranslate()
        },
        DefaultHotkeyEntry(id: "screenshotCopy", title: "截图复制",
                           keyCode: 0x08, modifiers: UInt32(shiftKey | optionKey)) {
            ScreenshotManager.shared.captureAndCopy()
        },
        DefaultHotkeyEntry(id: "screenshotPin", title: "截图钉图",
                           keyCode: 0x23, modifiers: UInt32(shiftKey | optionKey)) {
            ScreenshotManager.shared.captureAndPin()
        },
        DefaultHotkeyEntry(id: "translateSelection", title: "划词翻译",
                           keyCode: 0x02, modifiers: UInt32(shiftKey | optionKey)) {
            runTranslateSelection()
        },
    ]

    /// 批量注册默认热键表（specs/19 §4）。
    /// 前置：ModuleRegistry.startAll() 已完成（handler 懒分发，触发时模块均已注入）。
    private static func registerDefaultHotkeys() {
        for entry in defaultHotkeys {
            // 用户自定义优先：该工具已有用户录入的绑定 → 跳过默认注册（原作「已自定义清单命中即跳过」）
            if let toolID = userCustomizableToolID(for: entry.id),
               ToolShortcutStore.binding(for: toolID) != nil {
                Log.info("Shortcut", "跳过默认绑定 \(entry.id)：已有用户自定义绑定")
                continue
            }
            ShortcutRegistry.register(id: entry.id, title: entry.title,
                                      keyCode: entry.keyCode, modifiers: entry.modifiers,
                                      handler: entry.action)
        }
        Log.info("Bootstrap", "默认热键表注册完成（共 \(defaultHotkeys.count) 条）")
    }

    /// 默认表 id → ToolShortcutStore 工具 id 映射。
    /// 默认表 10 项中只有工具箱域内的工具存在用户自定义通道（其余 8 项为全局功能，无录入入口）。
    private static func userCustomizableToolID(for defaultID: String) -> String? {
        switch defaultID {
        case "colorPicker": return "colorpicker"
        default:            return nil
        }
    }

    // MARK: 截图翻译会话（screenshotTranslate 热键 → 截图 OCR → TranslationToolSession）

    /// 截图翻译会话挂起标志（事件接线处一次性消费）
    private static let screenshotTranslateLock = NSLock()
    private static var screenshotTranslatePending = false

    /// 热键触发：激活一次性翻译会话并启动截图 OCR；OCR 文本产出后在事件接线处自动翻译
    private static func beginScreenshotTranslate() {
        screenshotTranslateLock.lock()
        screenshotTranslatePending = true
        screenshotTranslateLock.unlock()
        ScreenshotManager.shared.captureAndOCR()
    }

    /// 取出挂起标志（一次性消费）；非挂起态返回 false
    private static func takeScreenshotTranslatePending() -> Bool {
        screenshotTranslateLock.lock(); defer { screenshotTranslateLock.unlock() }
        guard screenshotTranslatePending else { return false }
        screenshotTranslatePending = false
        return true
    }

    // MARK: 划词翻译（translateSelection 热键）

    /// 翻译一段文本并把译文以工具产出回流剪贴板历史（is_generated_by_tool=1，与摘要回写同模式）
    private static func translateAndIngest(_ text: String, successTip: String) {
        Task { @MainActor in
            do {
                let result = try await TranslationToolSession.shared.complete(text)
                ClipboardManager.shared.ingestToolOutput(text: result, sourceToolKeyword: "AI翻译")
                Toast.show(successTip, icon: "character.book.closed")
            } catch {
                Toast.show(error.localizedDescription, icon: "exclamationmark.triangle", isWarning: true)
            }
        }
    }

    /// 划词翻译热键。重建侧暂无「抓取选中文本」的辅助功能链路
    /// （原作经 CGEventTap 模拟取词，specs/19 未取得完整实现），
    /// 降级为翻译剪贴板当前文本；译文以工具产出回流剪贴板历史。
    private static func runTranslateSelection() {
        Task { @MainActor in
            guard let text = NSPasteboard.general.string(forType: .string)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
                Toast.show("没有可翻译的文本", icon: "character.book.closed", isWarning: true)
                return
            }
            translateAndIngest(text, successTip: "划词翻译完成，译文已写入剪贴板")
        }
    }
}
