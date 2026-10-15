import AppKit
import SwiftUI

// MARK: - 图标彩蛋浮层（spec 13 §6.3）
//
// 还原原作 `CustomMenuBarIconEasterEggDialogOverlayView`（卡片浮层，字段表见 spec §2）
// 与 `AboutEasterEggBubbleView`（气泡提示）：
// - 对话框 = 独立 borderless 浮层窗口（level 15，在通知条 14 之上），卡片居中、可点击；
// - 气泡 = 锚定主状态项图标下方的无交互浮层（ignoresMouseEvents，3.0s 后自动消失，
//   bubbleDisplayDuration 对应 spec §6.4 的 3.0）；
// - 撒彩带 = 对话框卡片上的 CAEmitterLayer（对应原作 playCustomMenuBarIconUnlockConfetti）。
//
// 文案一律逐字取自 spec 13 §6.2 / §6.3（英文原文，原作彩蛋文案不做本地化）。

// MARK: - 对话框模型

/// 一次彩蛋对话框（对应原作 `CustomMenuBarIconEasterEggDialog`，仅 kind 字段）
struct MenuBarIconEasterEggDialog {
    let kind: MenuBarIconEasterEggDialogKind
    /// 庆祝变体：解锁成功后展示（标题 + 副标题 + 无按钮，spec §6.3「unlock（庆祝）」）
    let isCelebration: Bool
}

/// 四类对话框的逐字文案（spec 13 §6.3 原文）
enum MenuBarIconEasterEggDialogCopy {

    /// 标题（nil = 无标题，仅正文）
    static func title(for dialog: MenuBarIconEasterEggDialog) -> String? {
        switch dialog.kind {
        case .unlock:
            return dialog.isCelebration ? "🏆 Fine, You Win!" : nil
        case .regret:
            return "🧐 Changed your mind?"
        case .hide:
            return nil
        case .restore:
            return "Miss it already?"
        }
    }

    /// 副标题（仅庆祝变体有：spec §6.3「Symbol Easter Egg Unlocked」）
    static func subtitle(for dialog: MenuBarIconEasterEggDialog) -> String? {
        dialog.isCelebration ? "Symbol Easter Egg Unlocked" : nil
    }

    /// 正文：unlock 首次问询 / 庆祝两段逐字不同；regret 与 restore 同文案族
    static func body(for dialog: MenuBarIconEasterEggDialog) -> String {
        switch dialog.kind {
        case .unlock:
            return dialog.isCelebration
                ? "Congratulations, you've officially annoyed me into unlocking Symbol Mode. You can now pick a symbol you like for your menu bar. Use it wisely, you persistent human."
                : "I'll pretend you clicked 'Reject' by mistake. Do you want to unlock Symbol Mode and pick a symbol you like, or should I just go back to sleep?"
        case .regret, .restore:
            return "Want the Symbol option back? I can put it right where you left it."
        case .hide:
            return "Not feeling the symbol vibe anymore? We can hide the symbol option and pretend I never gave you anything in the first place."
        }
    }

    /// 主按钮标题（nil = 无按钮，仅庆祝态的关闭按钮由 overlay 统一提供）
    static func primaryTitle(for dialog: MenuBarIconEasterEggDialog) -> String? {
        guard !dialog.isCelebration else { return nil }
        switch dialog.kind {
        case .unlock: return "Let's pick a symbol!"
        case .regret, .restore: return "Bring it back"
        case .hide: return "Hide it"
        }
    }

    /// 次按钮标题
    static func secondaryTitle(for dialog: MenuBarIconEasterEggDialog) -> String? {
        guard !dialog.isCelebration else { return nil }
        switch dialog.kind {
        case .unlock: return "Go back to sleep"
        case .regret, .restore: return "Leave it hidden"
        case .hide:    return "Keep it"
        }
    }
}

// MARK: - 对话框卡片视图

/// 卡片式对话框（对应原作 CustomMenuBarIconEasterEggDialogOverlayView：
/// cardWidth / cardHeight / primaryBlue / onConfirm / onCancel）
struct MenuBarIconEasterEggDialogCard: View {
    let dialog: MenuBarIconEasterEggDialog
    let onConfirm: () -> Void
    let onCancel: () -> Void

    /// 卡片尺寸（原作 cardWidth/cardHeight 字段；⬜ 精确数值未探明，取圆角卡片的常规值）
    private let cardWidth: CGFloat = 380
    private let primaryBlue = Color(red: 0.0, green: 0.478, blue: 1.0)

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let title = MenuBarIconEasterEggDialogCopy.title(for: dialog) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.primary)
            }
            if let subtitle = MenuBarIconEasterEggDialogCopy.subtitle(for: dialog) {
                Text(subtitle)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(primaryBlue)
            }
            Text(MenuBarIconEasterEggDialogCopy.body(for: dialog))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .multilineTextAlignment(.leading)
            HStack(spacing: 10) {
                Spacer(minLength: 0)
                if let secondary = MenuBarIconEasterEggDialogCopy.secondaryTitle(for: dialog) {
                    Button(secondary, action: onCancel)
                        .controlSize(.small)
                }
                if let primary = MenuBarIconEasterEggDialogCopy.primaryTitle(for: dialog) {
                    Button(primary, action: onConfirm)
                        .controlSize(.small)
                        .keyboardShortcut(.defaultAction)
                }
                // 庆祝态无原文按钮（spec §6.3 记为「—」），给一个收尾按钮
                if dialog.isCelebration {
                    Button("Continue", action: onConfirm)
                        .controlSize(.small)
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(18)
        .frame(width: cardWidth)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(NSColor.windowBackgroundColor))
                .shadow(color: .black.opacity(0.28), radius: 18, y: 6)
        )
    }
}

// MARK: - 拒绝语录气泡（对应原作 AboutEasterEggBubbleView）

/// 主状态项图标下方的语录气泡（对应原作 AboutEasterEggBubble*：
/// attributedText + bubbleBodyHeight/bubbleArrowHeight）
struct MenuBarIconEasterEggBubbleCard: View {
    let text: String
    /// 气泡本体高度（bubbleBodyHeight；⬜ 数值未探明）
    private let bodyHeight: CGFloat = 34
    /// 气泡箭头高度（bubbleArrowHeight；⬜ 数值未探明）
    private let arrowHeight: CGFloat = 7

    var body: some View {
        VStack(spacing: 0) {
            Text(text)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .padding(.horizontal, 14)
                .frame(height: bodyHeight)
                .background(Capsule().fill(.ultraThinMaterial))
            // 指向状态项图标的小箭头
            Triangle()
                .fill(.ultraThinMaterial)
                .frame(width: 14, height: arrowHeight)
        }
    }
}

/// 气泡箭头（上窄下宽的等腰三角）
private struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.closeSubpath()
        return path
    }
}

// MARK: - 浮层控制器（窗口宿主 + 撒彩带）

/// 彩蛋对话框窗：borderless 窗默认 canBecomeKey = false，
/// 会导致卡片的按钮拿不到 first responder、回车（keyboardShortcut .defaultAction）失效，
/// 故显式覆写为 true（与工程内 PinWindow / Eyedropper / FloatingPanel 同一处理）。
private final class EasterEggDialogWindow: NSWindow {

    /// 主按钮（回车 / Esc 的兜底目标）；由 present(dialog:) 注入
    var onPrimaryAction: (() -> Void)?
    var onEscapeAction: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// 回车 = 主按钮、Esc = 次按钮（与 SettingsWindow 的 Esc 处理同一思路）。
    /// 不依赖 SwiftUI 焦点：卡片按钮无焦点环时 .defaultAction 可能不响应，
    /// 这里在窗口层拦一道，保证键盘行为确定（⚠️ 静态通；真机需验一次回车，specs/13 待办）。
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown else { return super.performKeyEquivalent(with: event) }
        switch event.keyCode {
        case 36:                                  // Return / Enter = 主按钮
            onPrimaryAction?()
            return true
        case 53:                                  // Esc = 次按钮
            onEscapeAction?()
            return true
        default:
            return super.performKeyEquivalent(with: event)
        }
    }
}

/// 彩蛋浮层控制器：两个可复用的 borderless 窗口
/// - 气泡窗：锚定主状态项图标正下方、不接受鼠标事件（对应原作AboutEasterEggBubbleView）；
/// - 对话框窗：屏幕居中、可点击（对应原作 CustomMenuBarIconEasterEggDialogOverlayView）。
final class MenuBarIconEasterEggOverlayController: NSObject {

    static let shared = MenuBarIconEasterEggOverlayController()

    /// 对话框窗层级：略高于通知条（level 14），保证盖在通知条之上
    private static let dialogLevel = NSWindow.Level(15)
    /// 气泡窗层级：与通知条同级
    private static let bubbleLevel = NSWindow.Level(14)

    private var dialogWindow: NSWindow?
    private var bubbleWindow: NSWindow?
    private var bubbleHosting: NSHostingController<AnyView>?
    private var bubbleDismissWorkItem: DispatchWorkItem?
    private var emitter: CAEmitterLayer?

    private override init() { super.init() }

    // MARK: 对话框

    /// 展示一张对话框卡片（reuse 单窗口，仅替换内容）
    func present(dialog: MenuBarIconEasterEggDialog,
                 onConfirm: @escaping () -> Void,
                 onCancel: @escaping () -> Void) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [self] in present(dialog: dialog, onConfirm: onConfirm, onCancel: onCancel) }
            return
        }
        // 一次展示只允许触发一次回调：回车既走窗口层 performKeyEquivalent，
        // 也可能被 SwiftUI 的 .defaultAction 按钮捕获，不去重会重复执行（例如开两次设置窗）
        var hasTriggered = false
        let fireOnce: (() -> Void) -> () -> Void = { [weak self] action in
            {
                guard let self, !hasTriggered else { return }
                hasTriggered = true
                action()
                self.dismissDialog()
            }
        }
        let confirmOnce = fireOnce(onConfirm)
        let cancelOnce = fireOnce(onCancel)

        let card = MenuBarIconEasterEggDialogCard(dialog: dialog, onConfirm: confirmOnce, onCancel: cancelOnce)
        let window = ensureDialogWindow()
        window.contentView = NSHostingView(rootView: AnyView(card))
        // 键盘兜底：回车走主按钮、Esc 走次按钮（庆祝态无次按钮则回车收窗）
        if let dialogWindow = window as? EasterEggDialogWindow {
            dialogWindow.onPrimaryAction = confirmOnce
            dialogWindow.onEscapeAction = dialog.isCelebration ? nil : cancelOnce
        }
        window.setContentSize(NSSize(width: 420, height: 240))
        window.center()
        // 对话框要接键盘（按钮 + 回车），故走 makeKeyAndOrderFront 让 first responder 落进来；
        // 气泡窗相反，只 orderFrontRegardless（ignoresMouseEvents，见下方 presentBubble）
        window.makeKeyAndOrderFront(nil)
        if dialog.isCelebration { playConfetti(in: window) }
    }

    /// 收起对话框：停彩带 + orderOut。
    /// 窗口实例保留复用（对齐 Toast / 原作浮层的复用语义），但要清掉键盘回调，
    /// 否则收窗后残留的 onPrimaryAction 仍可能被响应。
    func dismissDialog() {
        guard Thread.isMainThread else { DispatchQueue.main.async { [self] in dismissDialog() }; return }
        stopConfetti()
        (dialogWindow as? EasterEggDialogWindow)?.onPrimaryAction = nil
        (dialogWindow as? EasterEggDialogWindow)?.onEscapeAction = nil
        dialogWindow?.orderOut(nil)
    }

    private func ensureDialogWindow() -> NSWindow {
        if let dialogWindow { return dialogWindow }
        let window = EasterEggDialogWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 240),
                                           styleMask: [.borderless],
                                           backing: .buffered,
                                           defer: false)
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = false
        window.level = Self.dialogLevel
        window.ignoresMouseEvents = false
        window.hidesOnDeactivate = false
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        dialogWindow = window
        return window
    }

    // MARK: 撒彩带（CAEmitterLayer）

    /// 解锁庆祝：从卡片左右上角喷出彩色纸屑（对应原作 playCustomMenuBarIconUnlockConfetti）
    private func playConfetti(in window: NSWindow) {
        stopConfetti()
        guard let host = window.contentView else { return }
        let emitter = CAEmitterLayer()
        // 出生位置：卡片上方横跨一条线，纸屑向下落
        emitter.emitterPosition = CGPoint(x: host.bounds.midX, y: host.bounds.maxY - 12)
        emitter.emitterSize = CGSize(width: max(host.bounds.width - 40, 40), height: 1)
        emitter.emitterShape = .line
        emitter.beginTime = CACurrentMediaTime()
        emitter.emitterCells = Self.confettiCells
        host.layer?.addSublayer(emitter)
        self.emitter = emitter
        // 1.6s 后自行停止发射（落完即撤层，对应 unlockConfettiLeadDuration 的最小版）
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in self?.stopConfetti() }
    }

    private func stopConfetti() {
        emitter?.removeFromSuperlayer()
        emitter = nil
    }

    /// 彩色纸屑单元格（5 色随机、随机初速与自转，落出下沿即消失）
    private static let confettiCells: [CAEmitterCell] = makeConfettiCells()

    private static func makeConfettiCells() -> [CAEmitterCell] {
        let colors: [NSColor] = [.systemPink, .systemYellow, .systemGreen, .systemBlue, .systemPurple]
        return colors.map { color in
            let cell = CAEmitterCell()
            cell.birthRate = 26
            cell.lifetime = 3.2
            cell.velocity = 110
            cell.velocityRange = 60
            cell.emissionLongitude = .pi
            cell.emissionRange = .pi / 6
            cell.scale = 0.5
            cell.scaleRange = 0.25
            cell.spin = 2.6
            cell.spinRange = 2.0
            cell.contents = confettiImage(color: color).cgImage
            return cell
        }
    }

    /// 生成一张 6×10 的圆角色块作为纸屑贴图
    private static func confettiImage(color: NSColor) -> NSImage {
        let size = NSSize(width: 6, height: 10)
        let image = NSImage(size: size)
        image.lockFocus()
        color.setFill()
        NSBezierPath(roundedRect: NSRect(origin: .zero, size: size), xRadius: 2, yRadius: 2).fill()
        image.unlockFocus()
        return image
    }

    // MARK: 气泡

    /// 展示一条拒绝语录气泡，3.0s 后自动消失（原作 bubbleDisplayDuration = 3.0）
    func presentBubble(_ text: String, duration: TimeInterval = 3.0) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [self] in presentBubble(text, duration: duration) }
            return
        }
        bubbleDismissWorkItem?.cancel()
        let window = ensureBubbleWindow()
        let hosting = NSHostingController(rootView: AnyView(MenuBarIconEasterEggBubbleCard(text: text)))
        bubbleHosting = hosting
        window.contentView = hosting.view
        layoutBubble(window: window, text: text)
        window.orderFrontRegardless()

        let item = DispatchWorkItem { [weak self] in self?.dismissBubble() }
        bubbleDismissWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: item)
    }

    func dismissBubble() {
        guard Thread.isMainThread else { DispatchQueue.main.async { [self] in dismissBubble() }; return }
        bubbleDismissWorkItem?.cancel()
        bubbleDismissWorkItem = nil
        bubbleWindow?.orderOut(nil)
    }

    private func ensureBubbleWindow() -> NSWindow {
        if let bubbleWindow { return bubbleWindow }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 260, height: 44),
                              styleMask: [.borderless],
                              backing: .buffered,
                              defer: false)
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = false
        window.level = Self.bubbleLevel
        window.ignoresMouseEvents = true          // 气泡不拦截点击
        window.hidesOnDeactivate = false
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        bubbleWindow = window
        return window
    }

    /// 气泡定位：主状态项图标中线水平居中 + 图标正下方（锚点缺失时回落主屏顶部居中）
    private func layoutBubble(window: NSWindow, text: String) {
        guard let host = bubbleHosting?.view else { return }
        host.layoutSubtreeIfNeeded()
        var size = host.fittingSize
        size.width = min(max(size.width, 120), 320)
        size.height = max(size.height, 41)
        window.setContentSize(size)

        let button = ToastAnchor.button
        let screen = button?.window?.screen ?? NSScreen.main ?? NSScreen.screens.first
        guard let screen else { return }
        let visible = screen.visibleFrame
        let iconMidX = button?.window?.frame.midX ?? visible.midX
        let x = min(max(iconMidX - size.width / 2, visible.minX + 8), visible.maxX - size.width - 8)
        // 菜单栏正下方：visibleFrame.maxY 为菜单栏底边
        let y = visible.maxY - size.height
        window.setFrameOrigin(NSPoint(x: x, y: y))
    }
}