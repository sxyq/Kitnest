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
    /// 官方窗口背景色：浅色取官方实测 (221,223,223)；深色按等效明度。
    public static let windowBackground = NSColor(name: nil) { appearance in
        let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        return isDark
            ? NSColor(srgbRed: 0.145, green: 0.153, blue: 0.153, alpha: 1)   // 深色 ≈ #252727
            : NSColor(srgbRed: 0.867, green: 0.875, blue: 0.875, alpha: 1)   // #DDDFDF
    }

    /// 批量应用（窗口数组）
    public static func applyAll(_ windows: [NSWindow?]) {
        for w in windows { w?.applyOfficialChrome() }
    }
}

public extension NSWindow {
    /// 应用官方原版窗口外观（灰底 + 透明标题栏 → 消除上下白条）
    func applyOfficialChrome() {
        backgroundColor = OfficialChrome.windowBackground
        titlebarAppearsTransparent = true
        // 官方左上角为灰色圆形关闭钮（无系统红绿灯）——自绘挂载（2026-10-18）
        attachOfficialRoundCloseButton()
    }
}
