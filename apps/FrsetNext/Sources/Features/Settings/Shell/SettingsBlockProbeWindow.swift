import SwiftUI
import AppKit

// MARK: - 设置区块独立预览（v264 排障）
//
// 设置总页很长，主窗口一次只显示得下一屏，验收「录屏 / 工作流」这两块时
// 很难截图（要么滚动、要么把窗口拉到比屏幕还高）。这里给一个深链：
//
//   kitnest://settingsprobe?block=recording
//   kitnest://settingsprobe?block=workflow
//
// 单独开一个窗只放这一块，尺寸自适应，截图即可入档。

@MainActor
final class SettingsBlockProbeWindowController {

    static let shared = SettingsBlockProbeWindowController()

    private var window: NSWindow?

    private init() {}

    func open(block: String) {
        let content: AnyView
        let title: String
        switch block {
        case "recording":
            content = AnyView(RecordingSettingsPane())
            title = "设置区块预览 · 录屏"
        case "workflow":
            content = AnyView(WorkflowSettingsPane())
            title = "设置区块预览 · 工作流"
        case "capture":
            content = AnyView(CaptureSettingsPane())
            title = "设置区块预览 · 截图"
        default:
            content = AnyView(RecordingSettingsPane())
            title = "设置区块预览"
        }

        let host = NSHostingView(rootView: ScrollView { content.padding(24) })
        host.frame = NSRect(x: 0, y: 0, width: 760, height: 980)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 980),
                              styleMask: [.titled, .closable, .resizable],
                              backing: .buffered, defer: false)
        window.title = title
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = window
    }
}
