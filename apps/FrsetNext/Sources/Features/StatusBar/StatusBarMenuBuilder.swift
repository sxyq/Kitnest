import AppKit
import Foundation

// MARK: - 菜单组装

/// StatusBarMenuBuilder：把常用动作组装成 NSMenu（含快捷键显示）
/// 菜单项 target 均为 StatusBarController.shared，动作实现见其 @objc 方法
public enum StatusBarMenuBuilder {

    // 图像沿菜单结构复用；勾选态在每次打开时读取。
    private static let onboardingImage = NSImage(systemSymbolName: "sparkles",
                                                 accessibilityDescription: "欢迎与权限")
    private static let updateImage = NSImage(systemSymbolName: "arrow.triangle.2.circlepath",
                                             accessibilityDescription: "检查更新")
    private static let statsImage = NSImage(systemSymbolName: "chart.line.uptrend.xyaxis",
                                            accessibilityDescription: "使用统计")
    private static let customRootImage = NSImage(systemSymbolName: MenuBarIconStyle.custom.systemImage,
                                                 accessibilityDescription: "自定义菜单栏图标")
    // v183：电池与充电不在这份「显示项」清单里——它们没有独立的状态栏部件，
    // 开关统一在「设置 → 监测」里，避免菜单里出现一个勾了也没效果的项。
    private static let monitorModules: [MonitorModuleID] = MonitorModuleID.allCases
        .filter { $0 != .battery }
    // 菜单结构随功能入口开关重建，每次打开刷新监测勾选态和暂停菜单。
    private struct MenuCache {
        let menu: NSMenu
        /// 三个全局入口开关的位图（v192）。开关变化后菜单要多/少项，
        /// 只刷勾选态不够——必须重建结构。
        let entriesSignature: Int
        /// target 为传入 responder 的菜单项（target 变更时只重设引用，不重建）
        let targetItems: [NSMenuItem]
        /// 「显示项」子菜单勾选态 ← MonitorPreferences.isModuleEnabled
        let moduleItems: [MonitorModuleID: NSMenuItem]
    }

    private static var cachedMenu: MenuCache?

    /// 主图标右键菜单：打开面板 / 设置 / 监测项开关 / 退出
    /// 入口开关位图：home=1, monitorPopout=2, statsBar=4, shelf=8
    private static func entriesSignature() -> Int {
        var sig = 0
        if GlobalEntries.isEnabled(GlobalEntries.homeKey) { sig |= 1 }
        if GlobalEntries.isEnabled(GlobalEntries.monitorPopoutKey) { sig |= 2 }
        if GlobalEntries.isEnabled(GlobalEntries.statsBarKey) { sig |= 4 }
        // v261：图帘开关会决定菜单里有没有「图帘」这一项。
        // 不纳入签名的话，用户在设置里开关完再点菜单，看到的还是旧缓存。
        if CurtainPref.enabled { sig |= 8 }
        return sig
    }

    public static func mainMenu(target: AnyObject) -> NSMenu {
        let signature = entriesSignature()
        if let cache = cachedMenu, cache.entriesSignature == signature {
            for item in cache.targetItems { item.target = target }
            for (module, item) in cache.moduleItems {
                item.state = MonitorPreferences.isModuleEnabled(module) ? .on : .off
            }
            refreshPauseMenu(cache.menu)
            return cache.menu
        }
        let cache = buildMenu(target: target, signature: signature)
        cachedMenu = cache
        refreshPauseMenu(cache.menu)
        return cache.menu
    }

    private static func refreshPauseMenu(_ menu: NSMenu) {
        let identifier = NSUserInterfaceItemIdentifier("clipboard.pause")
        if let previous = menu.items.first(where: { $0.identifier == identifier }) { menu.removeItem(previous) }
        let manager = ClipboardManager.shared
        let root = NSMenuItem(title: manager.isRecordingPaused ? manager.pauseStatus : "暂停记录剪贴板", action: nil, keyEquivalent: "")
        root.identifier = identifier
        let submenu = NSMenu()
        func action(_ title: String, minutes: Int) {
            let item = NSMenuItem(title: title, action: #selector(StatusBarController.pauseRecordingAction(_:)), keyEquivalent: "")
            item.target = StatusBarController.shared; item.tag = minutes; submenu.addItem(item)
        }
        if manager.isRecordingPaused { action("立即恢复", minutes: 0); submenu.addItem(.separator()) }
        for minutes in [5, 15, 30] { action("暂停 \(minutes) 分钟", minutes: minutes) }
        action("暂停至手动恢复", minutes: -1)
        root.submenu = submenu
        menu.insertItem(root, at: 2)
    }

    /// 缓存未命中时构造结构，并登记需刷新的项。
    private static func buildMenu(target: AnyObject, signature: Int) -> MenuCache {
        let menu = NSMenu()
        var targetItems: [NSMenuItem] = []
        var moduleItems: [MonitorModuleID: NSMenuItem] = [:]

        func track(_ m: NSMenuItem) -> NSMenuItem {
            targetItems.append(m)
            return m
        }

        // v192：入口项可关（设置 → 个性化 → 功能入口），关掉后菜单里不再出现
        if GlobalEntries.isEnabled(GlobalEntries.homeKey) {
            menu.addItem(track(item("打开面板",
                                    key: " ",
                                    modifiers: [.option],
                                    action: #selector(StatusBarController.openPanelAction(_:)),
                                    target: target)))
        }

        menu.addItem(track(item("刘海工作台", key: "", modifiers: [],
                                action: #selector(StatusBarController.openIslandAction(_:)), target: target)))

        menu.addItem(track(item("设置…",
                                key: ",",
                                modifiers: [.command],
                                action: #selector(StatusBarController.openSettingsAction(_:)),
                                target: target)))
        menu.addItem(track(item("查看收藏…", key: "", modifiers: [],
                                action: #selector(StatusBarController.openFavoritesAction(_:)), target: target)))

        if GlobalEntries.isEnabled(GlobalEntries.monitorPopoutKey) {
            menu.addItem(track(item("性能监测…", key: "", modifiers: [],
                                    action: #selector(StatusBarController.openMonitorSettingsAction(_:)), target: target)))
        }

        // v180：归档任务——压缩/解压可能在没有归档窗口时发起（访达服务、文件盒），
        // 这里给一个全局入口；任务进行中 HUD 会自动出现，这个入口用于重新打开详情。
        menu.addItem(track(item("归档任务…", key: "", modifiers: [],
                                action: #selector(StatusBarController.openArchiveTasksAction(_:)), target: target)))

        menu.addItem(track(item("新手教程…", key: "", modifiers: [],
                                action: #selector(StatusBarController.showTutorialAction(_:)), target: target)))

        // v206：代码预览独立窗已删除（代码预览改为 hover 预览内联渲染）

        // 悬浮剪贴板（v192）：给「怎么查看」一个可见入口，不用记快捷键
        menu.addItem(track(item("悬浮剪贴板…", key: "", modifiers: [],
                                action: #selector(StatusBarController.openFloatingClipboardAction(_:)), target: target)))

        // v261：图帘（设置 → 截图与钉图 → 图帘）。默认关闭时菜单里不出现，
        // 免得给一个用不上的入口；开着的时候它是「把图帘叫回来」的可见途径
        // （图帘到时会自动收起，但内容还在）。快捷键见设置页。
        if CurtainPref.enabled {
            menu.addItem(track(item("图帘", key: "", modifiers: [],
                                    action: #selector(StatusBarController.toggleCurtainAction(_:)),
                                    target: target)))
        }

        // 欢迎与权限引导（重建版 onboarding；首启自动弹，此处提供手动入口）
        let onboardingItem = track(item("欢迎与权限…", key: "", modifiers: [],
                                        action: #selector(StatusBarController.showOnboardingAction(_:)), target: target))
        onboardingItem.image = onboardingImage
        menu.addItem(onboardingItem)

        // 检查更新（v201：清单里有新版时标题直接提示，等价于状态栏红点）
        let updateTitle = AppUpdateChecker.shared.hasUpdate
            ? "发现新版本 · build \(AppUpdateChecker.shared.availableBuild)"
            : "检查更新…"
        let updateItem = track(item(updateTitle, key: "", modifiers: [],
                                    action: #selector(StatusBarController.checkForUpdatesAction(_:)), target: target))
        updateItem.image = updateImage
        menu.addItem(updateItem)

        // 统计入口（spec 17 S1：SF Symbol chart.line.uptrend.xyaxis，与记录控制区同菜单）
        let statsItem = track(item("使用统计",
                                   key: "",
                                   modifiers: [],
                                   action: #selector(StatusBarController.showStatisticsAction(_:)),
                                   target: target))
        statsItem.image = statsImage
        menu.addItem(statsItem)

        menu.addItem(NSMenuItem.separator())

        // 监测模块开关（v210：动态状态项已删除，这里只剩「采样模块开关」语义——
        // 决定面板/独立窗里显示哪几块，以及 STATS 合并条是否采该类数据）
        let modules = NSMenuItem(title: "显示项", action: nil, keyEquivalent: "")
        let moduleMenu = NSMenu()
        for module in monitorModules {
            let option = track(item(module.displayName, key: "", modifiers: [],
                                    action: #selector(StatusBarController.toggleMonitorModuleAction(_:)), target: target))
            option.representedObject = module.rawValue
            option.state = MonitorPreferences.isModuleEnabled(module) ? .on : .off
            moduleMenu.addItem(option)
            moduleItems[module] = option
        }
        // 注：原「合并」项随 monitor.* 双排状态项一并退场——菜单栏合并条由
        // STATS 部件引擎管理（形态/间距/分隔线在「菜单栏部件」设置窗里）
        modules.submenu = moduleMenu
        menu.addItem(modules)

        menu.addItem(NSMenuItem.separator())
        menu.addItem(customIconItem())

        menu.addItem(NSMenuItem.separator())

        menu.addItem(track(item("退出 Kitnest",
                                key: "q",
                                modifiers: [.command],
                                action: #selector(StatusBarController.quitAction(_:)),
                                target: target)))

        return MenuCache(menu: menu,
                         entriesSignature: signature,
                         targetItems: targetItems,
                         moduleItems: moduleItems)
    }

    /// 配置项只定位到总设置中的唯一编辑位置。
    private static func customIconItem() -> NSMenuItem {
        let root = NSMenuItem(title: "图标与入口…",
            action: #selector(MenuBarIconStyleMenuActions.openCustomIconSettings(_:)), keyEquivalent: "")
        root.target = MenuBarIconStyleMenuActions.shared
        root.image = customRootImage
        return root
    }

    /// 统一构造带快捷键显示的菜单项
    private static func item(_ title: String,
                             key: String,
                             modifiers: NSEvent.ModifierFlags,
                             action: Selector,
                             target: AnyObject) -> NSMenuItem {
        let m = NSMenuItem(title: title, action: action, keyEquivalent: key)
        m.target = target
        m.keyEquivalentModifierMask = modifiers
        return m
    }
}
