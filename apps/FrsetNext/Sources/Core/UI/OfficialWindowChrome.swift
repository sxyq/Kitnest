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
    /// 应用统一窗口外观（v204）：透明窗 + 背后统一玻璃底 + 透明标题栏 + 自绘圆形关闭钮。
    func applyOfficialChrome() {
        isOpaque = false
        backgroundColor = .clear
        titlebarAppearsTransparent = true
        installUnifiedGlassBackground()
        // 官方左上角为灰色圆形关闭钮（无系统红绿灯）——自绘挂载（2026-10-18）
        attachOfficialRoundCloseButton()
    }
}
