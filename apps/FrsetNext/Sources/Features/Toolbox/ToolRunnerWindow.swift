import AppKit
import SwiftUI

// MARK: - 工具运行窗（全局，任何入口可开）
//
// 2026-10-20 修复（用户：「首页搜索 / 后的工具无法使用——点击与展开都没有反应」）：
//
// 根因：工具面板原是 `ToolboxSectionView` 的 `.sheet`，而主面板 homePage 只渲染
// search / calendar / clipboard 三个区段——「工具」区段（id "tools"）**不挂载**。
// 于是搜索结果、命令面板、工具快捷键、设置页里点工具时，`ToolboxUIState.open`
// 只把 activeToolID 置了值，sheet 无宿主视图 → 什么都不弹，表现为「点了没反应」。
//
// 修法：工具面板改为**独立 NSWindow**——
//   · 任何入口 open() 都能弹出（不再依赖某个页面是否挂着）；
//   · 窗口可缩放（工具输出长内容时能展开看）；
//   · 切换工具 = 原地换内容；关闭窗口复位 activeToolID。
//
// 视觉沿用 frsetThemeChrome（强调色 + Midnight），与其它独立窗一致。

final class ToolRunnerWindowController: NSObject, NSWindowDelegate {

    static let shared = ToolRunnerWindowController()

    private var window: NSWindow?
    private var currentToolID: String?

    /// 打开工具（幂等：同工具置前，换工具原地替换内容）
    func show(toolID: String, autoRun: Bool = false) {
        guard let tool = ToolRegistry.tool(id: toolID) else {
            Log.warn("Toolbox", "打开工具失败：未注册 id=\(toolID)")
            return
        }
        currentToolID = toolID

        if let window {
            window.title = tool.name
            installContent(tool: tool, autoRun: autoRun, in: window)
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 560),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false)
        window.title = tool.name
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        // v181（UI 一致性检查 R3）：统一灰底 + 自绘圆钮，别再露系统白底
        window.applyOfficialChrome()
        window.center()
        window.delegate = self
        installContent(tool: tool, autoRun: autoRun, in: window)
        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        Log.info("Toolbox", "工具窗已打开：\(tool.name)")
    }

    func close() {
        window?.close()
    }

    /// 关闭时复位共享状态（工具格/搜索高亮依赖它）
    func windowWillClose(_ notification: Notification) {
        currentToolID = nil
        if ToolboxUIState.shared.activeToolID != nil {
            ToolboxUIState.shared.activeToolID = nil
        }
    }

    private func installContent(tool: ToolDescriptor, autoRun: Bool, in window: NSWindow) {
        let root = ToolRunnerView(tool: tool, onClose: { [weak self] in
            self?.close()
        }, autoRun: autoRun)
        .frsetThemeChrome()
        let host = NSHostingView(rootView: AnyView(root))
        host.sizingOptions = []
        if #available(macOS 13.3, *) { host.safeAreaRegions = [] }
        window.contentView = host
    }
}
