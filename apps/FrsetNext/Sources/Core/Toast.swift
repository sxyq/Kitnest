import AppKit
import Foundation
import SwiftUI

// MARK: - 菜单栏通知条（MenuBarToast，spec 13）
//
// 还原自原作 MenuBarToastManager（classobj 0x100c6a2d0）+ MenuBarToastAnimationState（0x100c6a428）：
// - 一条出现在主状态项图标正下方、随图标水平居中（±8pt 防溢出）的毛玻璃浮层，高 32pt；
// - 窗口 borderless + clearColor + opaque:false + 无阴影 + level=14 + ignoresMouseEvents（不挡点击）；
// - 出现/消失动画 spring(response:0.35, dampingFraction:0.7)，alpha 直接置 1（非渐显）；
// - 3.0s 自动隐藏，animationGeneration 代际计数防连续 show 串台；
// - 窗口复用不销毁，appearance 跟随系统 Aqua/DarkAqua。
// 对外入口仍是 `Toast.show(_:icon:)`（全工程既有调用点签名不变）。

// MARK: - 状态项锚点（StatusBar 模块安装主图标时登记，供定位算法取图标中线）

/// ToastAnchor：主状态项按钮的弱引用锚点。
/// Core 层不引用 Features 模块，由 StatusBarController 在 installMainItem 时写入。
public enum ToastAnchor {
    public weak static var button: NSStatusBarButton?
}

// MARK: - 动画状态（对应原作 MenuBarToastAnimationState，@Published 驱动 SwiftUI 内容）

/// 通知条内容状态（原作字段：_isVisible/_message/_icon/_iconColor/_isWarning）
final class MenuBarToastAnimationState: ObservableObject {
    @Published var isVisible = false
    @Published var message = ""
    @Published var icon: String?
    @Published var iconColor: Color?
    /// 警告分态：图标回落为 exclamationmark.triangle.fill（原作 show 内 literal 0x1002bd29c）
    @Published var isWarning = false
}

// MARK: - SwiftUI 内容视图（毛玻璃胶囊 + 图标 + 单行文本，总高 32pt）

/// 通知条内容（internal：仅本文件装配使用）
struct MenuBarToastContentView: View {
    @ObservedObject var state: MenuBarToastAnimationState

    /// 实际展示的图标：调用方未指定时按警告分态回落
    private var resolvedIcon: String? {
        state.icon ?? (state.isWarning ? "exclamationmark.triangle.fill" : nil)
    }

    var body: some View {
        HStack(spacing: 6) {
            if let icon = resolvedIcon {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(state.iconColor ?? Color.primary)
            }
            Text(state.message)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color.primary)
                .lineLimit(1)
        }
        .padding(.horizontal, 14)
        .frame(height: 32)
        .background(
            Capsule().fill(.ultraThinMaterial)   // 毛玻璃：随 Aqua/DarkAqua 自动着色
        )
        .fixedSize()
        // spring 弹入/弹出：几何由窗口定位，出现感由 scale+opacity 驱动
        .scaleEffect(state.isVisible ? 1.0 : 0.5, anchor: .top)
        .opacity(state.isVisible ? 1.0 : 0.0)
    }
}

// MARK: - 通知条管理器（对应原作 MenuBarToastManager：toastWindow/hideWorkItem/animationState/animationGeneration）

/// MenuBarToastManager：复用单例窗口的菜单栏通知条（原作 show 实现 0x1002bd010）
final class MenuBarToastManager: NSObject {

    static let shared = MenuBarToastManager()

    /// 内容条高度（原作常量 32.0f，0x100964d80）
    private static let contentHeight: CGFloat = 32
    /// 自动隐藏延时（原作 3.0s，0x1002bdf54）
    private static let displayDuration: TimeInterval = 3.0
    /// 隐藏动画结束后的 orderOut 延时（窗口复用不销毁，仅视觉收尾）
    private static let orderOutDelay: TimeInterval = 0.4
    /// spring 动画（原作常量 0.35/0.7，0x1002be1c0-0x1002be200）
    private static let springAnimation = Animation.spring(response: 0.35, dampingFraction: 0.7, blendDuration: 0)

    /// 复用窗口（不销毁）
    private var toastWindow: NSWindow?
    private var hosting: NSHostingController<MenuBarToastContentView>?
    /// 自动隐藏任务（连续 show 时取消旧的）
    private var hideWorkItem: DispatchWorkItem?
    /// 动画状态（@Published 驱动内容）
    private let animationState = MenuBarToastAnimationState()
    /// 代际计数：hide 块执行前比对，不一致即放弃（防连续 show 串台）
    private var animationGeneration = 0

    private override init() { super.init() }

    // MARK: 入口

    /// 显示一条通知（线程安全：自动切主线程）
    func show(_ message: String, icon: String?, isWarning: Bool = false) {
        if Thread.isMainThread {
            present(message: message, icon: icon, isWarning: isWarning)
        } else {
            DispatchQueue.main.async { self.present(message: message, icon: icon, isWarning: isWarning) }
        }
    }

    private func present(message: String, icon: String?, isWarning: Bool) {
        guard !message.isEmpty else { return }

        // 连续 show：旧 hide 作废、代际推进
        animationGeneration += 1
        hideWorkItem?.cancel()
        hideWorkItem = nil

        ensureWindow()

        // 更新内容（窗口复用，仅替换文案与图标）
        animationState.message = message
        animationState.icon = icon
        animationState.iconColor = isWarning ? Color(red: 1.0, green: 0.78, blue: 0.25) : nil
        animationState.isWarning = isWarning

        // 先按新内容量尺寸并定位到状态项图标正下方
        layoutContent()
        positionRelativeToStatusItem()

        // alpha 直接置 1（原作 0x1002bdb88 fmov d0,#1.0），出现感交给 SwiftUI spring
        toastWindow?.alphaValue = 1
        toastWindow?.orderFrontRegardless()

        withAnimation(Self.springAnimation) {
            animationState.isVisible = true
        }

        // 3.0s 自动隐藏（代际比对防串台）
        let generation = animationGeneration
        let item = DispatchWorkItem { [weak self] in
            guard let self, generation == self.animationGeneration else { return }
            self.hideAnimated(generation: generation)
        }
        hideWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.displayDuration, execute: item)
    }

    // MARK: 隐藏

    private func hideAnimated(generation: Int) {
        withAnimation(Self.springAnimation) {
            animationState.isVisible = false
        }
        // 动画收尾后收起窗口（期间若代际变化则放弃，让新通知正常展示）
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.orderOutDelay) { [weak self] in
            guard let self, generation == self.animationGeneration else { return }
            self.toastWindow?.orderOut(nil)
        }
    }

    // MARK: 窗口

    /// 创建/复用 borderless 透明窗口（原作 show 函数 0x1002bd7b4 起的 objc stub 调用序列）
    private func ensureWindow() {
        guard toastWindow == nil else { return }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: Self.contentHeight),
                              styleMask: [.borderless],
                              backing: .buffered,
                              defer: false)
        window.backgroundColor = .clear            // clearColor
        window.isOpaque = false                    // setOpaque: false
        window.hasShadow = false                   // setHasShadow:
        window.level = NSWindow.Level(14)          // setLevel: 0xe（非标准枚举，原作实测值）
        window.ignoresMouseEvents = true           // 不挡点击（点击穿透）
        window.hidesOnDeactivate = false           // 失活不隐藏
        window.isMovable = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.contentView = makeContentView()
        toastWindow = window
        syncAppearance()
    }

    private func makeContentView() -> NSView {
        let hosting = NSHostingController(rootView: MenuBarToastContentView(state: animationState))
        hosting.view.wantsLayer = true
        hosting.view.layer?.backgroundColor = NSColor.clear.cgColor
        hosting.view.autoresizingMask = [.width, .height]
        self.hosting = hosting
        return hosting.view
    }

    /// 跟随系统明暗（原作读 AppleInterfaceStyle，Aqua/DarkAqua 分支 0x1002bd928/0x1002bd9c4）
    private func syncAppearance() {
        let isDark = UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark"
        toastWindow?.appearance = NSAppearance(named: isDark ? .darkAqua : .aqua)
    }

    /// 按内容自适应宽度（高度恒 32pt）
    private func layoutContent() {
        guard let window = toastWindow, let view = hosting?.view else { return }
        view.layoutSubtreeIfNeeded()
        var size = view.fittingSize
        size.height = Self.contentHeight
        // 单行防溢出上限
        size.width = min(max(size.width, 60), 360)
        window.setContentSize(size)
        view.frame = NSRect(origin: .zero, size: size)
    }

    // MARK: 定位（spec 13 §3：0x1002bda4c-0x1002bdb7c 汇编逐条还原）

    /// 以状态项图标 visibleFrame 中线水平居中，clamp ±8pt（26-18 合成）防溢出；垂直贴菜单栏正下方
    private func positionRelativeToStatusItem() {
        guard let window = toastWindow else { return }

        // 基准矩形：状态项按钮所在屏的 visibleFrame（锚点未登记时回落主屏）
        let screen = ToastAnchor.button?.window?.screen ?? NSScreen.main ?? NSScreen.screens.first
        guard let screen else { return }
        let visible = screen.visibleFrame

        // 原作常量集：26.0（菜单栏厚度）/ 18.0 / 10.0
        let menuBarThickness: CGFloat = 26
        let edgeInset: CGFloat = 18

        let width = window.frame.width
        let height = window.frame.height

        // 水平：理想 x = 图标中线 - toastWidth/2；clamp 到 [minX-26+18, maxX-width-18+26]
        let iconMidX = ToastAnchor.button?.window?.frame.midX ?? visible.midX
        let xLower = visible.minX - menuBarThickness + edgeInset
        let xUpper = visible.maxX - width - edgeInset + menuBarThickness
        let x = min(max(iconMidX - width / 2, xLower), xUpper)

        // 垂直：落在菜单栏正下方的窄带上沿（visibleFrame.maxY 即菜单栏底边）
        let y = visible.maxY - height

        window.setFrameOrigin(NSPoint(x: x, y: y))
    }
}

// MARK: - 静态入口（供其他模块提示；全工程既有调用点签名不变）

/// Toast：全局轻提示入口（Core 层，所有模块直接调用，无需 import 任何 Features 模块）
/// 用法：`Toast.show("已复制", icon: "checkmark.circle.fill")`；`isWarning: true` 时图标分态为 ⚠️
public enum Toast {
    public static func show(_ message: String, icon: String? = nil, isWarning: Bool = false) {
        MenuBarToastManager.shared.show(message, icon: icon, isWarning: isWarning)
    }
}
