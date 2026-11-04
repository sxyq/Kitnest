import AppKit

// MARK: - 官方原版窗口外观（2026-10-18）
//
// 官方原版所有内容型窗口统一灰底：浅色实测 (221,223,223) #DDDFDF。
// 重建版此前未设窗口背景色——`fullSizeContentView` + 透明标题栏下露出的是
// **系统窗口默认白底**，而内容视图是自绘灰底且高度固定（如设置窗根视图 530
// 而内容区 562）→ 上下各露 32pt 白条（用户实测截图确认）。
//
// 修复：所有内容型窗口创建处调用 `applyOfficialChrome()`：
//   · backgroundColor = 官方灰（深色模式自适应）
//   · titlebarAppearsTransparent = true（标题栏透出同一底色）
// 仅影响窗口"露底"区域（标题栏/内容未铺满处），内容视图自绘背景不受影响。

public enum OfficialChrome {
    /// v204（用户：「需要覆盖所有界面」）：内容窗不再自己画不透明灰底。
    /// 统一玻璃底由窗口背后提供（`installUnifiedGlassBackground`）——
    /// 通透度 / 磨砂 / 卡片亮度 / 描边四个滑块从此作用于所有内容窗。
    /// 仍然引用本常量的视图会自动变透明，露出玻璃底。
    public static let windowBackground = NSColor.clear

    /// v204 前的官方灰（浅色 #DDDFDF / 深色 #252727）。
    /// 仍需要实色的局部（如截图工具条）继续用它，窗口整体不再用。
    public static let windowTint = NSColor(name: nil) { appearance in
        let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        return isDark
            ? NSColor(srgbRed: 0.145, green: 0.153, blue: 0.153, alpha: 1)   // 深色 ≈ #252727
            : NSColor(srgbRed: 0.867, green: 0.875, blue: 0.875, alpha: 1)   // #DDDFDF
    }
}

public extension NSWindow {
    /// 全 App 唯一的窗口外观入口（v209）。
    ///
    /// 用户：「把他们的玻璃态、圆角全部统一，还有红绿灯」「确保应用于全局，
    /// 并且只有这一处实现」。所有内容窗只允许调用本方法，不再各写一套：
    ///   · 玻璃：背后统一玻璃底（毛玻璃 → 通透度底衬 → 磨砂霜感）
    ///   · 圆角：自绘 0 —— 标准窗交给系统原生圆角，避免系统圆角内再套一层
    ///   · 标题栏：macOS 原生材质 + 原生分隔线 + 原生红黄绿三钮
    ///
    /// - Parameter glassBacking: 窗口内容自己已经是统一玻璃面
    ///   （主面板 / 玻璃浮层）时传 false，避免叠第二层模糊；其余窗口用默认 true。
    func applyOfficialChrome(glassBacking: Bool = true) {
        isOpaque = false
        backgroundColor = .clear
        // 全部交还 macOS 原生标题栏——原生材质 + 原生红绿灯 + 原生分隔线，
        // 不再自绘任何标题带。fullSize 窗口靠内容顶部 32pt 净空避让红绿灯。
        titlebarAppearsTransparent = false
        titlebarSeparatorStyle = .automatic
        if glassBacking {
            installUnifiedGlassBackground()
        }
        // 统一为标准红黄绿三钮（不再用自绘灰圆钮；曾被隐藏的按钮一并恢复）
        restoreStandardTrafficLights()
    }
}
