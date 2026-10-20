import AppKit
import Foundation

// MARK: - 菜单组装

/// StatusBarMenuBuilder：把常用动作组装成 NSMenu（含快捷键显示）
/// 菜单项 target 均为 StatusBarController.shared，动作实现见其 @objc 方法
public enum StatusBarMenuBuilder {

    /// 主图标右键菜单：打开面板 / 设置 / 监测项开关 / 退出
    public static func mainMenu(target: AnyObject) -> NSMenu {
        let menu = NSMenu()

        menu.addItem(item("打开面板",
                          key: " ",
                          modifiers: [.option],
                          action: #selector(StatusBarController.openPanelAction(_:)),
                          target: target))

        menu.addItem(item("设置…",
                          key: ",",
                          modifiers: [.command],
                          action: #selector(StatusBarController.openSettingsAction(_:)),
                          target: target))

        menu.addItem(item("性能监测…", key: "", modifiers: [],
                          action: #selector(StatusBarController.openMonitorSettingsAction(_:)), target: target))

        // 统计入口（spec 17 S1：SF Symbol chart.line.uptrend.xyaxis，与记录控制区同菜单）
        let statsItem = item("使用统计",
                             key: "",
                             modifiers: [],
                             action: #selector(StatusBarController.showStatisticsAction(_:)),
                             target: target)
        statsItem.image = NSImage(systemSymbolName: "chart.line.uptrend.xyaxis",
                                  accessibilityDescription: "使用统计")
        menu.addItem(statsItem)

        menu.addItem(NSMenuItem.separator())

        // 监测项（动态状态项）显示开关
        let toggle = item("显示状态项",
                          key: "",
                          modifiers: [],
                          action: #selector(StatusBarController.toggleIconsAction(_:)),
                          target: target)
        toggle.state = Preferences.shared.menuBarIconsVisible ? .on : .off
        menu.addItem(toggle)

        let modules = NSMenuItem(title: "显示项", action: nil, keyEquivalent: "")
        let moduleMenu = NSMenu()
        for module in MonitorModuleID.allCases where module != .battery {
            let option = item(module.displayName, key: "", modifiers: [],
                              action: #selector(StatusBarController.toggleMonitorModuleAction(_:)), target: target)
            option.representedObject = module.rawValue
            option.state = MonitorPreferences.isModuleEnabled(module) ? .on : .off
            moduleMenu.addItem(option)
        }
        // 注：原「合并」项随 monitor.* 双排状态项一并退场——菜单栏合并条由
        // STATS 部件引擎管理（形态/间距/分隔线在「菜单栏部件」设置窗里）
        modules.submenu = moduleMenu
        menu.addItem(modules)

        // 「自定义菜单栏图标」选项（v83：原彩蛋解锁门控已移除——功能直接可用，
        // 不再要求「连续单击主图标 10 次」解锁，见 StatusBarController.mainItemClicked）
        menu.addItem(NSMenuItem.separator())
        menu.addItem(customIconSubmenu())

        menu.addItem(NSMenuItem.separator())

        menu.addItem(item("退出 Frset",
                          key: "q",
                          modifiers: [.command],
                          action: #selector(StatusBarController.quitAction(_:)),
                          target: target))

        return menu
    }

    /// 自定义菜单栏图标子菜单：四样式单选 + 隐藏/恢复选项
    /// （spec 13 §6：logo/fan/date/custom 四键；hide/restore 对应对话框的触发点）
    private static func customIconSubmenu() -> NSMenuItem {
        let root = NSMenuItem(title: "自定义菜单栏图标", action: nil, keyEquivalent: "")
        root.image = NSImage(systemSymbolName: MenuBarIconStyle.custom.systemImage,
                             accessibilityDescription: "自定义菜单栏图标")
        let submenu = NSMenu()
        let revealed = MenuBarIconStyleStore.revealsCustomOption
        let current = MenuBarIconStyleStore.current
        // 自定义项被隐藏时（revealCustomMenuBarIconOption = false）：只给「后悔/恢复」入口（spec §6.3 restore）
        let styles = revealed ? MenuBarIconStyle.allCases : MenuBarIconStyle.allCases.filter { $0 != .custom }
        for style in styles {
            let styleItem = NSMenuItem(title: style.title,
                                       action: #selector(MenuBarIconStyleMenuActions.selectIconStyle(_:)),
                                       keyEquivalent: "")
            styleItem.target = MenuBarIconStyleMenuActions.shared
            styleItem.representedObject = style.rawValue
            styleItem.state = (style == current) ? .on : .off
            submenu.addItem(styleItem)
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
