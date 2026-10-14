import AppKit
import SwiftUI

// MARK: - 剪贴板设置页（07 号设置模块通过 SettingsPaneRegistry 消费）

public struct ClipboardSettingsPane: View {

    @ObservedObject private var manager = ClipboardManager.shared
    @Stored private var retentionDays: Double = Double(Preferences.shared.value(Preferences.Keys.clipboardRetentionDays, default: 30))
    @Stored private var storageLimitMB: Double = Double(Preferences.shared.value(Preferences.Keys.clipboardStorageLimitMB, default: 2048))
    @Stored private var autoPaste: Bool = Preferences.shared.value(Preferences.Keys.clipboardAutoPaste, default: false)
    @Stored private var eventTapEnabled: Bool = Preferences.shared.value(Preferences.Keys.clipboardEventTapEnabled, default: false)
    @Stored private var floatingVisible: Bool = Preferences.shared.value(Preferences.Keys.floatingVisible, default: false)

    private let preferences = Preferences.shared

    public init() {}

    public var body: some View {
        Form {
            Section("历史") {
                HStack {
                    Text("保留天数")
                    Spacer()
                    Text("\(Int(retentionDays)) 天")
                        .foregroundStyle(.secondary)
                }
                Slider(value: $retentionDays, in: 1...365, step: 1) { _ in
                    // 拖动停止即生效（清理会在下一 tick 执行）
                    let days = Int(retentionDays)
                    DispatchQueue.main.async {
                        preferences.set(Preferences.Keys.clipboardRetentionDays, days)
                    }
                }
                HStack {
                    Text("容量上限")
                    Spacer()
                    Text("\(Int(storageLimitMB)) MB")
                        .foregroundStyle(.secondary)
                }
                Slider(value: $storageLimitMB, in: 256...8192, step: 256) { _ in
                    let mb = Int(storageLimitMB)
                    DispatchQueue.main.async {
                        preferences.set(Preferences.Keys.clipboardStorageLimitMB, mb)
                    }
                }
                Button("立即清理") {
                    ClipboardHistoryRetentionPruneScheduler.shared.prune()
                    ClipboardStoragePruneScheduler.shared.prune()
                }
                LabeledContent("当前占用") {
                    Text(Self.bytesText(ClipboardStorageUsageProvider.shared.totalBytes))
                }
            }

            Section("捕获") {
                Toggle("启用全局按键监听（Cmd+C 触发捕获）", isOn: $eventTapEnabled)
                    .onChange(of: eventTapEnabled) { newValue in
                        preferences.set(Preferences.Keys.clipboardEventTapEnabled, newValue)
                        manager.reloadEventMonitor()
                    }
                Text("需要「辅助功能」权限；未授权时自动回退到 0.5 秒轮询，不影响正常使用。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Toggle("复制后自动粘贴到前台应用", isOn: $autoPaste)
                    .onChange(of: autoPaste) { newValue in
                        preferences.set(Preferences.Keys.clipboardAutoPaste, newValue)
                    }
                Text("需要「辅助功能」权限，**默认关闭**。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Section("浮动窗") {
                Toggle("显示浮动窗", isOn: $floatingVisible)
                    .onChange(of: floatingVisible) { newValue in
                        if newValue { FloatingClipboardWindowController.shared.show() }
                        else { FloatingClipboardWindowController.shared.hide() }
                    }
                Button("重置浮动窗位置") {
                    let centered = FloatingClipboardPinState.shared.clampedFrame()
                    FloatingClipboardWindowController.shared.window?.setFrame(centered, display: true)
                }
            }
        }
        .formStyle(.grouped)
        .padding(12)
    }

    private static func bytesText(_ bytes: Int64) -> String {
        let mb = Double(bytes) / 1024 / 1024
        if mb >= 1 { return String(format: "%.1f MB", mb) }
        return String(format: "%.0f KB", Double(bytes) / 1024)
    }
}
