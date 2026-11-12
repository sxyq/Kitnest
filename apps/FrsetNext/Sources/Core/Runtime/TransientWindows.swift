import AppKit

// MARK: - 唯一的「点外/失焦自动收起」仲裁器
//
// 背景（2026-10-20 用户实障）：状态栏图标展开的界面（主面板 / 性能监测弹窗）点击别处不收起。
// 排查发现工程里同时存在多套互不相干的实现：
//   · PanelController.windowDidResignKey（只守 resignKey，窗口没当上 key 就永不触发）
//   · MonitorPopoutWindow：resignKey + app 失活 + 全局监视器 + 本地监视器 + 按键轮询（五路冗余）
//   · ClipboardPreviewWindow.windowDidResignKey、CaptureActionChain 的 outside monitor 等各自一套
// 这里统一为一套：所有瞬态窗口注册到本中心，由中心集中判定；窗口自身不再各写一份。
//
// 收起信号（按可靠性排序）：
//   1) 本 app 失活（点其他 app / 桌面 / 其他菜单栏图标）——不依赖任何 TCC 权限，最可靠
//   2) 本 app 内点击落在注册窗口之外（菜单栏区域与菜单/弹层除外，交给各自 action）
//   3) 窗口自身 resignKey（由窗口 delegate 转发；此时窗口确实当过 key）
// 全局鼠标监视器只作为有辅助功能权限时的即时补充。

final class TransientWindowCenter {
    static let shared = TransientWindowCenter()

    private struct Entry {
        weak var window: NSWindow?
        let dismiss: () -> Void
        let isPinned: () -> Bool
        /// 点击落在这些「兄弟窗口」上时不收起（sheet / 预览窗等）
        let allowsClickIn: ((NSWindow) -> Bool)?
    }

    private var entries: [ObjectIdentifier: Entry] = [:]
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var resignObserver: NSObjectProtocol?
    /// v199：前台应用切换兜底。LSUIElement + 非激活面板的极端情况下
    /// didResignActive 可能不发，但「点别的 app」一定会换前台应用。
    private var appActivateObserver: NSObjectProtocol?

    private init() {}

    // MARK: - 注册

    /// 注册一个瞬态窗口。注册即表示「同一时刻只保留一个浮层」：会先收起其它已注册窗口。
    func register(window: NSWindow,
                  isPinned: @escaping () -> Bool = { false },
                  allowsClickIn: ((NSWindow) -> Bool)? = nil,
                  onDismiss: @escaping () -> Void) {
        entries[ObjectIdentifier(window)] = Entry(window: window,
                                                  dismiss: onDismiss,
                                                  isPinned: isPinned,
                                                  allowsClickIn: allowsClickIn)
        startMonitoringIfNeeded()
        dismissAll(except: window)
    }

    func unregister(window: NSWindow) {
        entries.removeValue(forKey: ObjectIdentifier(window))
        if entries.isEmpty { stopMonitoring() }
    }

    /// resignKey 转发入口（窗口 delegate 调用）：统一在这里判置顶与可见性
    func requestDismiss(window: NSWindow) {
        guard let entry = entries[ObjectIdentifier(window)] else { return }
        guard entry.window?.isVisible == true, !entry.isPinned() else { return }
        entry.dismiss()
    }

    /// 收起全部（可保留一个）
    func dismissAll(except keep: NSWindow? = nil) {
        for entry in entries.values {
            guard let w = entry.window, w !== keep, w.isVisible, !entry.isPinned() else { continue }
            entry.dismiss()
        }
    }

    // MARK: - 监听

    private func startMonitoringIfNeeded() {
        if localMonitor == nil {
            localMonitor = NSEvent.addLocalMonitorForEvents(
                matching: [.leftMouseDown, .rightMouseDown]
            ) { [weak self] event in
                self?.handleLocalClick(event)
                return event
            }
        }
        if globalMonitor == nil {
            globalMonitor = NSEvent.addGlobalMonitorForEvents(
                matching: [.leftMouseDown, .rightMouseDown]
            ) { [weak self] _ in
                // 能收到即代表点击投递给其它 app（已失活路径也会触发，幂等）
                self?.dismissAll()
            }
        }
        if resignObserver == nil {
            resignObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didResignActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.dismissAll()
            }
        }
        if appActivateObserver == nil {
            appActivateObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification,
                object: nil, queue: .main
            ) { [weak self] note in
                guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                      app.bundleIdentifier != Bundle.main.bundleIdentifier else { return }
                Log.info("Transient", "点外收起（前台应用切换 → \(app.localizedName ?? "?"))")
                self?.dismissAll()
            }
        }
    }

    private func stopMonitoring() {
        if let m = localMonitor { NSEvent.removeMonitor(m) }
        if let m = globalMonitor { NSEvent.removeMonitor(m) }
        if let o = resignObserver { NotificationCenter.default.removeObserver(o) }
        if let o = appActivateObserver { NSWorkspace.shared.notificationCenter.removeObserver(o) }
        localMonitor = nil
        globalMonitor = nil
        resignObserver = nil
        appActivateObserver = nil
    }

    // MARK: - 判定

    private func handleLocalClick(_ event: NSEvent) {
        guard !entries.isEmpty else { return }
        // 点击处理期间光标可能已经移动；以该次事件的位置判断，避免窗内操作被当成点外。
        let point = event.window?.convertPoint(toScreen: event.locationInWindow) ?? NSEvent.mouseLocation

        // 菜单栏区域（状态项 / 系统图标）：
        //   · 点**自家**状态项：交给各自 action（toggle / 切换模块），这里抢跑会导致
        //     「先关后开」——放行；
        //   · 点系统菜单栏别处（时钟 / WiFi / 输入法…）：这些点击不会让 app 失活，
        //     旧实现整条菜单栏一律放行 → 浮层一直挂着（用户「点其他地方又不收缩」）。
        if isInMenuBar(point) {
            if StatusBarController.shared.statusItemFrames.contains(where: { $0.contains(point) }) {
                return
            }
            Log.info("Transient", "点外收起（菜单栏非自家项）")
            dismissAll()
            return
        }

        // 菜单、弹层：不算点外
        if let win = event.window {
            let cls = String(describing: type(of: win))
            if cls.contains("Menu") || win.level == .popUpMenu || win.level == .mainMenu { return }
        }

        for entry in entries.values {
            guard let w = entry.window, w.isVisible, !entry.isPinned() else { continue }
            // v193（用户：「状态栏点开主面板后，点其他地方它消失不掉」的回归修复）：
            // 原来先判 `w.frame.contains(point)`。当另一个自家窗口（例如 680×520 的
            // 悬浮剪贴板工作台）压在面板上时，点在**悬浮窗**上、坐标又落在面板 frame
            // 内 → 被误判为「点在面板里」，面板永远不收。
            // 点事件带 window 时以**窗口归属**为准：点的是另一个窗口就是「点外」，
            // 只有 sheet/预览等明确允许的兄弟窗才放行；坐标兜底只用于无 window 的点击。
            if let clickWindow = event.window, clickWindow !== w {
                if entry.allowsClickIn?(clickWindow) == true { continue }
                Log.info("Transient", "点外收起（落在其他窗口）：\(w.title.isEmpty ? "\(type(of: w))" : w.title)")
                entry.dismiss()
                continue
            }
            if w.frame.contains(point) { continue }
            if let clickWindow = event.window, entry.allowsClickIn?(clickWindow) == true { continue }
            Log.info("Transient", "点外收起：\(w.title.isEmpty ? "\(type(of: w))" : w.title)")
            entry.dismiss()
        }
    }

    private func isInMenuBar(_ screenPoint: NSPoint) -> Bool {
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(screenPoint) })
                ?? NSScreen.main else { return false }
        return screenPoint.y >= screen.frame.maxY - NSStatusBar.system.thickness - 2
    }
}
