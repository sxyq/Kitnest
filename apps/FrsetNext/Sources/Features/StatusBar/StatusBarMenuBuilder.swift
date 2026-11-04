import AppKit
import Foundation

// MARK: - 菜单组装

/// StatusBarMenuBuilder：把常用动作组装成 NSMenu（含快捷键显示）
/// 菜单项 target 均为 StatusBarController.shared，动作实现见其 @objc 方法
public enum StatusBarMenuBuilder {

    // v126（性能审计 F1324）：SF Symbol 图与候选列表缓存——mainMenu 每次右键都重建，
    // 其中 3 张 NSImage(systemSymbolName:) 要走符号查找/解码，两个 allCases 过滤结果
    // 也是常量。提到 static 复用；菜单项本身仍每次新建（勾选态依赖实时偏好，缓存会串态）。
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
    private static let styleCases: [MenuBarIconStyle] = MenuBarIconStyle.allCases
    private static let styleCasesWithoutCustom: [MenuBarIconStyle] = MenuBarIconStyle.allCases.filter { $0 != .custom }

    // v128（流畅度）：两段式菜单——静态结构（标题/图标/target-action/快捷键）只建一次并缓存，
    // 每次右键唤起只刷新动态字段（勾选态 state、target 引用）。原实现每帧 new 20+ 个
    // NSMenuItem + 两层 NSMenu，是状态栏右键首帧卡顿点。
    // 勾选态仍实时读 Preferences（不缓存值），避免串态；结构随 revealsCustomOption 变化
    // （隐藏/恢复会增删项），故缓存按 revealed 分版本，翻转时才整体重建（罕见路径）。
    private struct MenuCache {
        let menu: NSMenu
        let revealed: Bool
        /// 三个全局入口开关的位图（v192）。开关变化后菜单要多/少项，
        /// 只刷勾选态不够——必须重建结构。
        let entriesSignature: Int
        /// target 为传入 responder 的菜单项（target 变更时只重设引用，不重建）
        let targetItems: [NSMenuItem]
        /// 「显示状态项」勾选态 ← Preferences.shared.menuBarIconsVisible
        let toggleItem: NSMenuItem
        /// 「显示项」子菜单勾选态 ← MonitorPreferences.isModuleEnabled
        let moduleItems: [MonitorModuleID: NSMenuItem]
        /// 图标样式单选态 ← MenuBarIconStyleStore.current
        let styleItems: [MenuBarIconStyle: NSMenuItem]
    }

    private static var cachedMenu: MenuCache?

    /// 主图标右键菜单：打开面板 / 设置 / 监测项开关 / 退出
    /// 入口开关位图：home=1, monitorPopout=2, statsBar=4
    private static func entriesSignature() -> Int {
        var sig = 0
        if GlobalEntries.isEnabled(GlobalEntries.homeKey) { sig |= 1 }
        if GlobalEntries.isEnabled(GlobalEntries.monitorPopoutKey) { sig |= 2 }
        if GlobalEntries.isEnabled(GlobalEntries.statsBarKey) { sig |= 4 }
        return sig
    }

    public static func mainMenu(target: AnyObject) -> NSMenu {
        let revealed = MenuBarIconStyleStore.revealsCustomOption
        let signature = entriesSignature()
        // v128（流畅度）：命中缓存 → 只刷新勾选态/target，零 alloc
        if let cache = cachedMenu, cache.revealed == revealed, cache.entriesSignature == signature {
            for item in cache.targetItems { item.target = target }
            cache.toggleItem.state = Preferences.shared.menuBarIconsVisible ? .on : .off
            for (module, item) in cache.moduleItems {
                item.state = MonitorPreferences.isModuleEnabled(module) ? .on : .off
            }
            let current = MenuBarIconStyleStore.current
            for (style, item) in cache.styleItems {
                item.state = (style == current) ? .on : .off
            }
            return cache.menu
        }
        let cache = buildMenu(target: target, revealed: revealed, signature: signature)
        cachedMenu = cache
        return cache.menu
    }

    /// v128（流畅度）：全量构造（仅缓存未命中 / revealed 翻转时走），并登记需刷新的项
    private static func buildMenu(target: AnyObject, revealed: Bool, signature: Int) -> MenuCache {
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

        menu.addItem(track(item("设置…",
                                key: ",",
                                modifiers: [.command],
                                action: #selector(StatusBarController.openSettingsAction(_:)),
                                target: target)))

        if GlobalEntries.isEnabled(GlobalEntries.monitorPopoutKey) {
            menu.addItem(track(item("性能监测…", key: "", modifiers: [],
                                    action: #selector(StatusBarController.openMonitorSettingsAction(_:)), target: target)))
        }

        // v180：归档任务——压缩/解压可能在没有归档窗口时发起（访达服务、文件盒），
        // 这里给一个全局入口；任务进行中 HUD 会自动出现，这个入口用于重新打开详情。
        menu.addItem(track(item("归档任务…", key: "", modifiers: [],
                                action: #selector(StatusBarController.openArchiveTasksAction(_:)), target: target)))

        // v206：代码预览独立窗已删除（代码预览改为 hover 预览内联渲染）

        // 悬浮剪贴板（v192）：给「怎么查看」一个可见入口，不用记快捷键
        menu.addItem(track(item("悬浮剪贴板…", key: "", modifiers: [],
                                action: #selector(StatusBarController.openFloatingClipboardAction(_:)), target: target)))

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

        // 监测项（动态状态项）显示开关
        let toggle = track(item("显示状态项",
                                key: "",
                                modifiers: [],
                                action: #selector(StatusBarController.toggleIconsAction(_:)),
                                target: target))
        toggle.state = Preferences.shared.menuBarIconsVisible ? .on : .off
        menu.addItem(toggle)

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

        // 「自定义菜单栏图标」选项（v83：原彩蛋解锁门控已移除——功能直接可用，
        // 不再要求「连续单击主图标 10 次」解锁，见 StatusBarController.mainItemClicked）
        menu.addItem(NSMenuItem.separator())
        let custom = customIconSubmenu(revealed: revealed)
        menu.addItem(custom.root)
        let styleItems = custom.styleItems

        menu.addItem(NSMenuItem.separator())

        menu.addItem(track(item("退出 Kitnest",
                                key: "q",
                                modifiers: [.command],
                                action: #selector(StatusBarController.quitAction(_:)),
                                target: target)))

        return MenuCache(menu: menu,
                         revealed: revealed,
                         entriesSignature: signature,
                         targetItems: targetItems,
                         toggleItem: toggle,
                         moduleItems: moduleItems,
                         styleItems: styleItems)
    }

    /// 自定义菜单栏图标子菜单：四样式单选 + 隐藏/恢复选项
    /// （spec 13 §6：logo/fan/date/custom 四键；hide/restore 对应对话框的触发点）
    /// v128（流畅度）：同时返回样式项引用，供缓存命中时只刷单选态
    private static func customIconSubmenu(revealed: Bool)
        -> (root: NSMenuItem, styleItems: [MenuBarIconStyle: NSMenuItem]) {
        let root = NSMenuItem(title: "自定义菜单栏图标", action: nil, keyEquivalent: "")
        root.image = customRootImage
        let submenu = NSMenu()
        let current = MenuBarIconStyleStore.current
        var styleItems: [MenuBarIconStyle: NSMenuItem] = [:]
        // 自定义项被隐藏时（revealCustomMenuBarIconOption = false）：只给「后悔/恢复」入口（spec §6.3 restore）
        // v126（性能审计 F1324）：候选样式表提为 static 常量（原每次重建都 allCases.filter）
        let styles = revealed ? styleCases : styleCasesWithoutCustom
        for style in styles {
            let styleItem = NSMenuItem(title: style.title,
                                       action: #selector(MenuBarIconStyleMenuActions.selectIconStyle(_:)),
                                       keyEquivalent: "")
            styleItem.target = MenuBarIconStyleMenuActions.shared
            styleItem.representedObject = style.rawValue
            styleItem.state = (style == current) ? .on : .off
            submenu.addItem(styleItem)
            styleItems[style] = styleItem
        }
        submenu.addItem(NSMenuItem.separator())
        // 自定义 Symbol 的名称设置入口（仅在自定义项可见时）
        if revealed {
            let nameItem = NSMenuItem(title: "设置 Symbol 名称…",
                                      action: #selector(MenuBarIconStyleMenuActions.openCustomIconSettings(_:)),
                                      keyEquivalent: "")
            nameItem.target = MenuBarIconStyleMenuActions.shared
            submenu.addItem(nameItem)
        }
        submenu.addItem(NSMenuItem.separator())
        // 隐藏 / 恢复：对应 spec 13 §6.3 的 hide / restore 两类对话框
        let toggleItem = NSMenuItem(
            title: revealed ? "隐藏这个选项…" : "把 Symbol 选项放回来…",
            action: revealed ? #selector(MenuBarIconStyleMenuActions.hideIconOption(_:))
                             : #selector(MenuBarIconStyleMenuActions.restoreIconOption(_:)),
            keyEquivalent: "")
        toggleItem.target = MenuBarIconStyleMenuActions.shared
        submenu.addItem(toggleItem)
        root.submenu = submenu
        return (root, styleItems)
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
