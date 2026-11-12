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
        // v270：个性化拆成「主面板 / 独立窗口 / 通用」三段后，后两段在整页里要滚动才看得到。
        // 这两个区块用于单独验收：预览是否只画自己的对象、设置行是否跟在预览下面。
        case "personalization-main":
            content = AnyView(
                AppearanceSettingsEditor { draft in
                    VStack(alignment: .leading, spacing: 12) {
                        AppearancePreviewBlock(scope: .mainPanel, draft: draft)
                        SettingsDivider()
                        PersonalizationSettingsView(part: .mainPanel, draft: draft)
                    }
                }
            )
            title = "设置区块预览 · 主面板"
        case "personalization-floating":
            content = AnyView(
                AppearanceSettingsEditor { draft in
                    VStack(alignment: .leading, spacing: 12) {
                        AppearancePreviewBlock(scope: .floatingWindow, draft: draft)
                        SettingsDivider()
                        PersonalizationSettingsView(part: .floatingWindow, draft: draft)
                    }
                }
            )
            title = "设置区块预览 · 独立窗口与浮层"
        case "personalization-shared":
            content = AnyView(AppearanceSettingsEditor { draft in
                PersonalizationSettingsView(part: .shared, draft: draft)
            })
            title = "设置区块预览 · 个性化（通用）"
        default:
            content = AnyView(RecordingSettingsPane())
            title = "设置区块预览"
        }

        let host = NSHostingView(rootView: ScrollView { content.padding(24) })
        host.frame = NSRect(x: 0, y: 0, width: 760, height: 980)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 980),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = title
        window.isReleasedWhenClosed = false
        // v272：先补外观（能力位/标题栏/玻璃），再换内容重挂——只调 setOfficialContent
        // 时窗口仍是「全透明标题栏」，标题会浮在桌面上、截图里只剩一条黑带。
        window.applyOfficialChrome(lights: .standard)
        window.setOfficialContent(host)
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = window
    }
}
