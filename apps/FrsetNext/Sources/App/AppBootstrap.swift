import Foundation

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

        // 4) App 层工具注册（跨模块工具砖：如取色器需接 Capture 的取色会话）
        registerAppLevelTools()

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
}
