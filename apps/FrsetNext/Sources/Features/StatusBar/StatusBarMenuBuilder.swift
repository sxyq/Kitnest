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

        menu.addItem(NSMenuItem.separator())

        menu.addItem(item("退出 Frset",
                          key: "q",
                          modifiers: [.command],
                          action: #selector(StatusBarController.quitAction(_:)),
                          target: target))

        return menu
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
