import SwiftUI
import AppKit

/// 应用入口（菜单栏常驻应用：LSUIElement=1，不显示 Dock 图标）
@main
struct FrsetNextApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    var body: some Scene {
        // 主界面由各模块自管理窗口（面板/设置/截图选区等），这里只保留一个空场景
        Settings { EmptyView() }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // 不显示 Dock 图标（菜单栏应用）
        NSApp.setActivationPolicy(.accessory)
        AppBootstrap.start()
        Log.info("App", "启动完成")
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppBootstrap.stop()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        ServiceLocator.panel?.show()
        return true
    }
}
