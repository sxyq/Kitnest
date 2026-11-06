import AppKit
import Foundation
import SwiftUI

// MARK: - 菜单栏状态项总控
//
// v210（修工程全图「StatusItemRegistry 空转」）：**删除** Swift 侧动态状态项整套管线。
//
// 事实：唯一注册方 `MonitorStatusItems.registerAll()` 早在 v128 就被注释掉——菜单栏监测
// 只允许 STATS 合并条一套（工程全图 §6 不变量 13）。于是 StatusBarController 里的
// 「每 5s 扫注册表 → 重建 6 个状态项 + 溢出菜单」成为永远扫空数组的空转代码，
// 连带 600 行双层视图/位置持久化/溢出菜单全是死路径。
//
// 现在只保留真正在跑的一件事：
//   1) 主图标（左键开面板、右键弹菜单、可切换图标样式与固定宽度）。
// 菜单栏监测 UI 的唯一归属仍是 C 引擎的 STATS 合并条。

/// StatusBarController：菜单栏主图标。
public final class StatusBarController: NSObject {

    public static let shared = StatusBarController()

    private var mainItem: NSStatusItem?
    private var currentPopover: NSPopover?
    private var statisticsObservation: NSObjectProtocol?
    private var didInstall = false

    private override init() { super.init() }

    // MARK: 安装

    /// 安装主图标（必须在主线程调用，内部会兜底切主线程）
    public func install() {
        if Thread.isMainThread {
            performInstall()
        } else {
            DispatchQueue.main.async { self.performInstall() }
        }
    }

    private func performInstall() {
        guard !didInstall else { return }
        didInstall = true
        installMainItem()
        statisticsObservation = NotificationCenter.default.addObserver(
            forName: Notification.Name("frset.openStatistics"), object: nil, queue: .main
        ) { [weak self] _ in self?.showStatisticsAction(nil) }
        Log.info("StatusBar", "installed")
    }

    private func installMainItem() {
        // v71（实测：菜单栏图标被挤出屏幕外）：不再钉 Preferred Position=322。
        // 322 是 2026-10-16 旧屏/旧图标数下的相邻槽位；如今菜单栏图标增多后，
        // 钉死位置导致主图标 + 合并条整组被挤到屏幕右缘外（只剩末字符残段）。
        // 清掉钉位让系统自动排布（同队列其他 app 图标右侧）。
        UserDefaults.standard.removeObject(forKey: "NSStatusItem Preferred Position \(Self.statusItemName("main"))")
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.autosaveName = Self.statusItemName("main")   // 固定 autosaveName（带前缀），位置持久化稳定
        let symbol = NSImage(systemSymbolName: "square.stack.3d.up", accessibilityDescription: "Kitnest")
        symbol?.isTemplate = true                 // 模板图：随菜单栏明暗自动变色
        item.button?.image = symbol
        item.button?.imagePosition = .imageOnly
        item.button?.toolTip = "Kitnest（右键查看更多）"
        item.button?.target = self
        item.button?.action = #selector(mainItemClicked(_:))
        // 左键开面板，右键弹菜单
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        // v250：拖文件到图标 → 转入（云端 / 本地二选一）
        if let b = item.button {
            let proxy = StatusItemDropProxy(frame: b.bounds)
            proxy.autoresizingMask = [.width, .height]
            b.addSubview(proxy)
        }
        ToastAnchor.button = item.button       // 通知条定位锚点（spec 13 §3，主状态项图标）
        mainItem = item
        // v30：把主图标项注册给 STATS 引擎（位置校准/保邻的参照物）
        StatsBarEngine.syncMainItem()
    }

    /// 主图标状态项（STATS 引擎保邻修正的参照物；只读）
    public var mainStatusItem: NSStatusItem? { mainItem }

    /// 主图标在屏幕上的 frame（TransientWindowCenter 用它区分「点自家图标」与「点菜单栏别处」）
    public var statusItemFrames: [NSRect] {
        guard let f = mainItem?.button?.window?.frame else { return [] }
        return [f]
    }

    /// 调整主图标状态项宽度（MenuBarIconStyleApplier 的 fan 样式需要固定宽度容纳旋转视图；
    /// 传 NSStatusItem.variableLength 恢复自适应）。2026-10-16：fan 的 18pt 子视图
    /// 在可变长度按钮里被裁剪成「<<」状扇叶，故 fan 期间固定 30pt 并居中。
    public func setMainItemLength(_ length: CGFloat) {
        guard Thread.isMainThread else { DispatchQueue.main.async { self.setMainItemLength(length) }; return }
        mainItem?.length = length
    }

    /// 主状态项当前长度（排障用：验证 setMainItemLength 对 variableLength 创建的项是否生效）
    public var mainItemLength: CGFloat? { mainItem?.length }

    // MARK: 位置持久化

    /// 状态项在系统位置存储中的唯一名（autosaveName + 位置键共用）。
    /// 带 `frsetnext.` 前缀：与原版 Frset.app 的状态项同名 id 隔离——两版共存时同名
    /// autosaveName 会让系统拒绝为后注册的项布局（frame=(0,0,w,0)，菜单栏不显示）。
    static func statusItemName(_ id: String) -> String { "frsetnext.\(id)" }

    // MARK: 交互

    @objc private func mainItemClicked(_ sender: Any?) {
        guard let button = sender as? NSStatusBarButton else { return }
        let isRightClick = NSApp.currentEvent?.type == .rightMouseUp
        if isRightClick {
            let menu = StatusBarMenuBuilder.mainMenu(target: self)
            menu.popUp(positioning: nil,
                       at: NSPoint(x: 0, y: button.bounds.height + 6),
                       in: button)
        } else {
            // v73：主图标左键 → 锚点展开（面板停到图标正下方 + 三角指示器 + 长出来动画）
            ServiceLocator.panel?.toggle(atAnchor: button.window?.frame)
        }
    }

    // MARK: 菜单动作（StatusBarMenuBuilder 组装的菜单目标）

    @objc func openPanelAction(_ sender: Any?) {
        // v73：菜单唤起也停到主图标正下方（与左键点击一致）
        ServiceLocator.panel?.show(atAnchor: mainItem?.button?.window?.frame)
    }

    @objc func openSettingsAction(_ sender: Any?) { ServiceLocator.settings?.open(pane: nil) }

    @objc func openMonitorSettingsAction(_ sender: Any?) {
        ServiceLocator.settings?.open(pane: "monitor")
    }

    /// v180：归档任务详情（压缩/解压队列）
    @objc func openArchiveTasksAction(_ sender: Any?) {
        ArchiveProgressWindowController.show()
    }

    /// 悬浮剪贴板工作台（v192）
    ///
    /// 用户反馈「悬浮剪贴板应该怎样查看？」——此前只有 ⇧⌘V 一个入口，
    /// 不知道快捷键就等于找不到。这里给菜单栏一个**确定性的可见入口**；
    /// 快捷键仍保留（设置 → 快捷键可改）。
    @objc func openFloatingClipboardAction(_ sender: Any?) {
        FloatingClipboardWindowController.shared.show()
    }

    /// 欢迎与权限引导（重建版 onboarding：欢迎窗 + 权限引导窗手动入口）
    @objc func showOnboardingAction(_ sender: Any?) {
        WelcomeWindowController.shared.show()
    }

    /// 检查更新（v112：手动检查，feed 在 设置 → 关于 配置）
    @objc func checkForUpdatesAction(_ sender: Any?) {
        AppUpdateChecker.shared.checkNowManual()
    }

    /// 监测模块总开关（菜单「显示项」子菜单）。
    /// v210：不再调用 syncStatusItems（动态状态项已删除）；模块开关直接决定采样与面板内容。
    @objc func toggleMonitorModuleAction(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String,
              let module = MonitorModuleID(rawValue: rawValue) else { return }
        MonitorPreferences.setModuleEnabled(module, !MonitorPreferences.isModuleEnabled(module))
        MonitorSampler.shared.refresh()
    }

    /// 打开统计窗（spec 17 S1/S2：打开即埋点 statistics_open）
    @objc func showStatisticsAction(_ sender: Any?) {
        StatisticsWindowController.shared.openStatistics()
    }

    @objc func quitAction(_ sender: Any?) { NSApp.terminate(nil) }
}

// MARK: - NSPopoverDelegate

extension StatusBarController: NSPopoverDelegate {
    public func popoverDidClose(_ notification: Notification) {
        currentPopover = nil
        // v74：popover 关闭 → 恢复隐藏态降频（与打开时的提升配对）
        MonitorSampler.shared.setSettingsActive(false)
    }
}
