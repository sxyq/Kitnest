import AppKit

// MARK: - 官方原版窗口外观（2026-10-18）
//
// 官方原版所有内容型窗口统一灰底：浅色实测 (221,223,223) #DDDFDF。
// 重建版此前未设窗口背景色——`fullSizeContentView` + 透明标题栏下露出的是
// **系统窗口默认白底**，而内容视图是自绘灰底且高度固定（如设置窗根视图 530
// 而内容区 562）→ 上下各露 32pt 白条（用户实测截图确认）。
//
// 修复：所有内容型窗口创建处调用 `applyOfficialChrome()`：
//   · 内容玻璃贯穿标题栏与正文，两处不再叠不同颜色的底带
//   · 标题与红绿灯仍使用 AppKit 标准控件
// 内容与标题栏背景均通过公开视图和窗口属性设置，不向 NSThemeFrame 插入视图。
//
// v272（用户：「红绿灯还是会出现问题，所有页面一个一个统一」）：
//   · 空心灰圈的根因是 styleMask 缺 .miniaturizable / .resizable —— macOS 27
//     把被禁用的按钮画成空心环。现在由 `lights` 策略统一补齐能力位，
//     调用方不再各写一份 styleMask。
//   · 标题栏分隔线统一 `.none`（此前残留 .automatic，导致红绿灯下方多一条线）。
//   · `setOfficialContent` 保证「换 contentView 之后」玻璃底重新挂到最下层，
//     修掉「apply 早于换内容 → 玻璃丢一层」的窗口（统计/工具运行/OCR…）。

/// 红绿灯策略
public enum OfficialChromeLights {
    /// 普通可缩放窗口：补齐 .closable / .miniaturizable / .resizable
    case standard
    /// 固定尺寸窗口：同样补齐三能力位，但调用方需把 min/max 锁成同一尺寸
    case fixed
    /// 瞬时面板 / 贴附预览：三颗钮隐藏（不摆假按钮）
    case hidden
}

/// 标题栏策略
public enum OfficialChromeTitlebar {
    /// 系统原生标题与按钮；背景由贯穿整窗的玻璃承托
    case native
    /// 透明标题栏 + 内容自绘标题（OCR 结果窗这类左边要固定让位的窗口）
    case custom
}

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

    /// 统一标题栏净空：所有 `.fullSizeContentView` 窗口的内容顶部至少让出这么多，
    /// 保证红绿灯不压内容。页面自己的呼吸留白写成 `titlebarInset + n`。
    public static let titlebarInset: CGFloat = 32
}

public extension NSWindow {
    /// 全 App 唯一的窗口外观入口（v209，v272 扩展策略参数）。
    ///
    /// 用户：「把他们的玻璃态、圆角全部统一，还有红绿灯」「确保应用于全局，
    /// 并且只有这一处实现」。所有内容窗只允许调用本方法，不再各写一套：
    ///   · 玻璃：背后统一玻璃底（毛玻璃 → 通透度底衬 → 磨砂霜感）
    ///   · 圆角：自绘 0 —— 标准窗交给系统原生圆角，避免系统圆角内再套一层
    ///   · 标题栏：无分隔线 + 原生红黄绿三钮，启用状态由 AppKit 决定
    ///
    /// - Parameters:
    ///   - glassBacking: 窗口内容自己已经是统一玻璃面（主面板 / 玻璃浮层）时传 false。
    ///   - lights: 红绿灯策略；`.standard/.fixed` 会补齐 styleMask 能力位，
    ///     `.hidden` 用于瞬时面板。
    ///   - titlebar: `.native` 原生标题；`.custom` 内容自绘标题；背景统一透明。
    func applyOfficialChrome(glassBacking: Bool = true,
                             lights: OfficialChromeLights = .standard,
                             titlebar: OfficialChromeTitlebar = .native) {
        // v272：能力位统一在这里补。缺 .miniaturizable / .resizable 时 AppKit 会把
        // 对应按钮判为禁用，macOS 27 对禁用态的的画法就是「空心灰圈」。
        switch lights {
        case .standard, .fixed:
            styleMask.formUnion([.closable, .miniaturizable, .resizable])
        case .hidden:
            break
        }

        // 标题栏只保留原生按钮/标题，不再单独绘制白色材质带。
        // 背景由同一个 fullSizeContentView 玻璃容器贯穿标题栏与正文。
        titlebarAppearsTransparent = true
        applyOfficialBackground()
        // v272：v260 曾统一去掉分隔线，中途为排障改回 .automatic 后忘了还原，
        // 红绿灯下方因此多出一条系统线，与玻璃发丝边叠成「双层」。这里固定 .none。
        titlebarSeparatorStyle = .none

        if glassBacking {
            installUnifiedGlassBackground()
        }
        // 统一红黄绿三钮（不再用自绘灰圆钮；曾被隐藏的按钮一并恢复）
        restoreStandardTrafficLights(policy: lights == .hidden ? .hidden : .enabled)
    }

    /// 窗口底透明，实际背景由统一玻璃容器承托，不叠另一层窗口填色。
    func applyOfficialBackground() {
        isOpaque = false
        backgroundColor = .clear
    }

    /// 替换内容视图并保持统一外观（v272）。
    ///
    /// 旧写法是「先 applyOfficialChrome()，稍后再 contentView = host」——
    /// 玻璃底是按旧 contentView 的位置插的，换完内容就压在旧层级上，
    /// 表现是标题栏下少一层玻璃、深色下发灰。这里把「换内容 + 重挂玻璃」绑成一步。
    func setOfficialContent(_ view: NSView) {
        contentView = view
        installUnifiedGlassBackground()
    }

    /// 同上，内容由 NSViewController 提供时使用。
    func setOfficialContent(_ controller: NSViewController) {
        contentViewController = controller
        installUnifiedGlassBackground()
    }
}
