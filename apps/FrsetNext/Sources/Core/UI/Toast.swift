import AppKit
import Foundation
import SwiftUI

// MARK: - 屏幕通知卡（原作 MenuBarToastManager，spec 13 §3/§5 + 2026-10-18 实测勘误版）
//
// ⚠️ 勘误（2026-10-18）：spec 13 §3 当年把定位基准误读为「主状态项图标正下方」。
// 本轮以原版 1.3.12 arm64 双重复核——反汇编（show=0x1002bd010 定位段、基准屏解析=0x1002bf3d0）
// + 官方原版实机自动化（双击剪贴板条目 → CGWindowList 实测），得到定位真值：
//   1) 基准矩形 = 目标屏的 visibleFrame。目标屏解析（原作 0x1002bf3d0）：
//      传入屏 → 全局主面板窗口所在屏（.screen）→ 含鼠标位置的那块屏（NSScreen.screens ×
//      NSEvent.mouseLocation）→ mainScreen。
//   2) 水平 = visibleFrame 中线居中：x = clamp(midX - w/2, minX-8, maxX-w+8)（26/18 合成 ±8）。
//   3) 垂直 —— 2026-10-20 用户需求变更：改为「屏幕中线偏下」（可见区中线下方 6%），
//      不再沿用原版「距屏底 18.3%」的底部定位；设置项「屏幕中线」与此一致。
//   4) 窗口层级 = kCGScreenSaverWindowLevel + 1（实测 CGWindowList layer=2147483631）。
//   5) 样式 = 原作 ToastView：圆形图标底（leadingColor 圆 + 白色 SF Symbol）+ 单行文本的
//      自适应深/浅色胶囊卡（实测 176×91，"文本已复制"）。
// 动画/时长：spring(0.35, 0.7) 弹入弹出（spec 13 §5）、3.0s 自动隐藏、generation 防串台、
// 窗口复用不销毁——均与原作一致，继续沿用。
// 对外入口仍是 `Toast.show(_:icon:isWarning:)`（全工程既有调用点签名不变）。

// MARK: - 锚点（Core 层不引用 Features，由 App/Panel 层注入）

public enum ToastAnchor {
    /// 主状态项按钮（旧字段，保留兼容既有引用；新定位不再使用）
    public weak static var button: NSStatusBarButton?
    /// 主面板窗口提供者：注入 PanelController 的面板窗口。
    /// 对应原作 0x1002bf3d0 的「全局主窗口 → .screen」分支（面板开着时 toast 落在面板所在屏）。
    public static var windowProvider: () -> NSWindow? = { nil }
}

// MARK: - 动画状态（对应原作 MenuBarToastAnimationState，@Published 驱动 SwiftUI 内容）

/// 通知卡内容状态（原作字段：_isVisible/_message/_icon/_iconColor/_isWarning）
final class MenuBarToastAnimationState: ObservableObject {
    @Published var isVisible = false
    @Published var message = ""
    @Published var icon: String?
    @Published var iconColor: Color?
    /// 警告分态：图标回落为 exclamationmark.triangle.fill（原作 show 内 literal 0x1002bd29c）
    @Published var isWarning = false
}

// MARK: - SwiftUI 内容视图（圆形图标底 + 单行文本的自适应胶囊卡，原作 ToastView 还原）

/// 通知卡内容（internal：仅本文件装配使用）
struct MenuBarToastContentView: View {
    @ObservedObject var state: MenuBarToastAnimationState
    @Environment(\.colorScheme) private var colorScheme

    /// 实际展示的图标：调用方未指定时按警告分态回落
    private var resolvedIcon: String? {
        state.icon ?? (state.isWarning ? "exclamationmark.triangle.fill" : nil)
    }

    /// 圆形图标底色：调用方指定色 > 警告橙 > 原版蓝
    private var circleColor: Color {
        state.iconColor ?? (state.isWarning ? Color(red: 1.0, green: 0.78, blue: 0.25)
                                            : Color(red: 0.24, green: 0.51, blue: 0.96))
    }

    var body: some View {
        HStack(spacing: 9) {
            if let icon = resolvedIcon {
                ZStack {
                    Circle().fill(circleColor)
                    Image(systemName: icon)
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white)
                }
                .frame(width: 27, height: 27)
            }
            Text(state.message)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.primary)
                .lineLimit(1)
        }
        .padding(.horizontal, 18)
        .frame(height: 60)
        // v209（用户：「其他所有外部前端界面组件都需要全部统一」）：
        // Toast 也是窗口级浮层——固定白/黑实底胶囊改为全 App 统一玻璃面，
        // 通透度 / 磨砂 / 材质 / 降低透明度跟随个性化，不再是一套单独视觉。
        .background {
            GlassSurface(cornerRadius: Theme.Radius.pill, appliesWindowShadow: false)
                .shadow(color: .black.opacity(colorScheme == .dark ? 0.35 : 0.18),
                        radius: 12, y: 4)
        }
        .overlay {
            Capsule().strokeBorder(Theme.hairlineColor, lineWidth: Theme.Stroke.hairline)
        }
        .fixedSize()
        // 阴影留白（2026-10-20 用户反馈「已复制框外面还有一层矩形」根因）：
        // 窗口尺寸原等于胶囊尺寸，radius 12 / y 4 的阴影被窗口边界裁断，
        // 四角残留非零 alpha → 视觉上是一圈方形硬边。这里加 24pt 透明边距，
        // 窗口按 fittingSize 同步扩大，阴影完整落在窗口内呈柔和胶囊光晕。
        .padding(24)
        // spring 弹入/弹出：几何由窗口定位，出现感由 scale+opacity 驱动
        .scaleEffect(state.isVisible ? 1.0 : 0.5, anchor: .center)
        .opacity(state.isVisible ? 1.0 : 0.0)
    }
}

// MARK: - 通知卡管理器（对应原作 MenuBarToastManager：toastWindow/hideWorkItem/animationState/animationGeneration）

/// MenuBarToastManager：复用单例窗口的屏幕通知卡（原作 show 实现 0x1002bd010）
final class MenuBarToastManager: NSObject {

    static let shared = MenuBarToastManager()

    /// 自动隐藏延时（原作 3.0s，0x1002bdf54）
    /// v66 个性化：停留时长（2/3/5s，设置 → 常规 →「个性化」）
    private static var displayDuration: TimeInterval { Personalization.shared.toastDuration }
    /// 隐藏动画结束后的 orderOut 延时（窗口复用不销毁，仅视觉收尾）
    private static let orderOutDelay: TimeInterval = 0.4
    /// spring 动画（原作常量 0.35/0.7，0x1002be1c0-0x1002be200）
    private static let springAnimation = Theme.Motion.springBouncy

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

        // 先按新内容量尺寸并定位到目标屏（面板屏/鼠标屏）可见区中线
        layoutContent()
        positionOnTargetScreen()

        // alpha 直接置 1（原作 0x1002bdb88 fmov d0,#1.0），出现感交给 SwiftUI spring
        toastWindow?.alphaValue = 1
        toastWindow?.orderFrontRegardless()

        // 排障日志（2026-10-18）：位置勘误后首版，观察 frame 是否落在目标屏中线
        if let w = toastWindow {
            Log.info("Toast", "显示「\(message)」 visible=\(w.isVisible) frame=\(NSStringFromRect(w.frame)) level=\(w.level.rawValue)")
        }

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
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 92),
                              styleMask: [.borderless],
                              backing: .buffered,
                              defer: false)
        window.backgroundColor = .clear            // clearColor
        window.isOpaque = false                    // setOpaque: false
        window.hasShadow = false                   // setHasShadow:（阴影由内容层绘制）
        // 原作 0x1002bd830：setLevel:(CGWindowLevelForKey(0xe))；0xe=14。
        // 本机实测 CGWindowLevelKey(rawValue:14)=2147483631（kCGUtilityWindowLevel），
        // 与官方原版 toast 的 CGWindowList layer 实测值完全一致。
        // ⚠️ 不用 Swift 符号 .utilityWindow（其桥接映射与本机 key14 不符，实测返回 19）。
        window.level = NSWindow.Level(Int(CGWindowLevelForKey(CGWindowLevelKey(rawValue: 14)!)))
        window.ignoresMouseEvents = true           // 不挡点击（点击穿透）
        window.hidesOnDeactivate = false           // 失活不隐藏
        window.isMovable = false
        // 提示卡永不进屏幕捕获：它的层级是 statusBar，SCK 的 excludingApplications
        // 对高 level 覆盖窗不生效（实测：长截图把「长截图：直接滚动目标窗口…」整条截了进去）。
        // sharingType = .none 是系统级开关，普通截图/录屏/长截图都取不到它。
        window.sharingType = .none
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

    /// 按内容自适应宽度
    private func layoutContent() {
        guard let window = toastWindow, let view = hosting?.view else { return }
        view.layoutSubtreeIfNeeded()
        let size = view.fittingSize
        window.setContentSize(size)
        view.frame = NSRect(origin: .zero, size: size)
    }

    // MARK: 定位（spec 13 §3 勘误版：0x1002bda4c-0x1002bdb7c 汇编逐条 + 实机实测）

    /// 目标屏解析（原作 0x1002bf3d0）：
    /// 主面板窗口所在屏 → 含鼠标位置的那块屏 → mainScreen
    private func resolveTargetScreen() -> NSScreen? {
        if let panelWindow = ToastAnchor.windowProvider(), panelWindow.isVisible,
           let s = panelWindow.screen {
            return s
        }
        let mouse = NSEvent.mouseLocation
        for s in NSScreen.screens where NSMouseInRect(mouse, s.frame, false) {
            return s
        }
        return NSScreen.main
    }

    /// 原作定位公式（0x1002bda4c-0x1002bdb7c 逐条还原，2026-10-18 实机验证）：
    /// - 水平：x = clamp(visibleFrame.midX - w/2, minX-8, maxX-w+8)   → 可见区水平居中
    /// - 垂直：y = max(minY-16, min(maxY-h+16, minY + frameH*0.1833 - 26))
    private func positionOnTargetScreen() {
        guard let window = toastWindow, let screen = resolveTargetScreen() else { return }
        let visible = screen.visibleFrame

        let width = window.frame.width
        let height = window.frame.height

        // v66 个性化：跟随主面板 = 面板下方 8pt 水平居中（面板不可见回退屏幕中线）
        if Personalization.shared.toastFollowPanel,
           let panelWindow = ToastAnchor.windowProvider(), panelWindow.isVisible {
            let panelFrame = panelWindow.frame
            let x = min(max(panelFrame.midX - width / 2, visible.minX + 8),
                        visible.maxX - width - 8)
            let y = max(visible.minY + 8, panelFrame.minY - height - 8)
            window.setFrameOrigin(NSPoint(x: x, y: y))
            return
        }
        // 屏幕中线偏下（2026-10-20 用户需求）：水平居中，垂直落在可见区中线下方 6%。
        // 原实现沿用原作「距屏底 18.3%」公式，与「屏幕中线」选项语义不符——
        // 选该项却显示在底部，故改为真正的中线偏下全局提示。
        let idealX = visible.midX - width / 2
        let x = min(max(idealX, visible.minX + 8), visible.maxX - width - 8)
        let belowCenter = visible.midY - height / 2 - visible.height * 0.06
        let y = min(max(belowCenter, visible.minY + 8), visible.maxY - height - 8)

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
