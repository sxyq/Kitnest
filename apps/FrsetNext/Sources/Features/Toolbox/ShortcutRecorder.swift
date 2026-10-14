import SwiftUI
import AppKit
import Carbon.HIToolbox

// MARK: - 快捷键录入控件
//
// 说明：原作默认热键表未知（specs/01 §13 待查 #7），故**不预置任何默认组合**，组合键完全由用户录制。
// 为避免劫持日常输入，要求组合中至少包含 ⌘ / ⌥ / ⌃ 之一；录制期间吞掉按键，Esc 取消。

/// 录制状态与键盘监听（本地 monitor，随设置页消失而停止）
public final class ShortcutCapture: ObservableObject {
    @Published public private(set) var isRecording = false
    /// 录制到组合键时回调 (keyCode, Carbon 修饰键)
    public var onCapture: ((UInt32, UInt32) -> Void)?
    private var monitor: Any?

    public init() {}

    public func toggle() { isRecording ? stop() : start() }

    public func start() {
        stop()
        isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self else { return event }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let carbon = ShortcutManager.carbonModifiers(from: flags)
            let keyCode = UInt32(event.keyCode)
            // Esc（无修饰键）→ 取消录制
            if keyCode == UInt32(kVK_Escape), carbon == 0 { self.stop(); return nil }
            // 非修饰键 + 至少一个强修饰键 → 采纳
            if carbon & (UInt32(cmdKey) | UInt32(optionKey) | UInt32(controlKey)) != 0 {
                self.stop()
                self.onCapture?(keyCode, carbon)
            }
            return nil   // 录制期间吞掉按键，避免误触
        }
    }

    public func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if isRecording { isRecording = false }
    }

    deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
}

/// 单个快捷键录入按钮：显示当前组合 / 未设置，点击进入录制，可清除
public struct ShortcutRecorderButton: View {
    @StateObject private var capture = ShortcutCapture()
    public let display: String?
    public let onCapture: (UInt32, UInt32) -> Void
    public let onClear: () -> Void

    public init(display: String?,
                onCapture: @escaping (UInt32, UInt32) -> Void,
                onClear: @escaping () -> Void) {
        self.display = display
        self.onCapture = onCapture
        self.onClear = onClear
    }

    public var body: some View {
        HStack(spacing: 6) {
            Button {
                capture.onCapture = onCapture
                capture.toggle()
            } label: {
                Text(capture.isRecording ? "请按组合键…" : (display ?? "点击录入"))
                    .font(.system(size: 11, design: display == nil ? .default : .monospaced))
                    .frame(minWidth: 84)
            }
            .buttonStyle(.bordered)
            .help(capture.isRecording ? "按下含 ⌘/⌥/⌃ 的组合键，Esc 取消" : "点击录入全局快捷键")

            if display != nil && !capture.isRecording {
                Button { onClear() } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("清除快捷键")
            }
        }
        .onDisappear { capture.stop() }
    }
}
