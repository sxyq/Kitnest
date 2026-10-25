import AppKit
import SwiftUI

// MARK: - 剪贴板设置页（07 号设置模块通过 SettingsPaneRegistry 消费）
//
// 2026-10-20 统一版式：原实现用 `Form(.grouped)`，在 macOS 上会自绘**整页纯白底**
// + 灰色分组框，与其它设置页「灰底页面 + 浅色圆角卡片」不一致（用户反复反馈）。
// 现改用 SettingsSection / SettingsGroupBox / SettingsRow 这套共用组件，
// 与「常规」「数据」「监测设置」完全同构；外层滚动与 34/18 内边距由 SettingsRootView 提供。

public struct ClipboardSettingsPane: View {

    @Stored private var retentionDays: Double = Double(Preferences.shared.value(Preferences.Keys.clipboardRetentionDays, default: 30))
    @Stored private var storageLimitMB: Double = Double(Preferences.shared.value(Preferences.Keys.clipboardStorageLimitMB, default: 2048))
    @Stored private var autoPaste: Bool = Preferences.shared.value(Preferences.Keys.clipboardAutoPaste, default: false)
    @Stored private var floatingVisible: Bool = Preferences.shared.value(Preferences.Keys.floatingVisible, default: false)
    /// 权限状态（v111：自动粘贴行的「去授权」入口按授权态显隐）
    @ObservedObject private var permissions = PermissionCenter.shared

    private let preferences = Preferences.shared

    public init() {}

    public var body: some View {
        VStack(spacing: 20) {
            SettingsSection("历史") {
                SettingsGroupBox {
                    sliderRow("保留天数",
                              valueText: "\(Int(retentionDays)) 天",
                              value: $retentionDays,
                              range: 1...365,
                              step: 1) {
                        preferences.set(Preferences.Keys.clipboardRetentionDays, Int(retentionDays))
                    }
                    SettingsDivider()
                    sliderRow("容量上限",
                              valueText: "\(Int(storageLimitMB)) MB",
                              value: $storageLimitMB,
                              range: 256...8192,
                              step: 256) {
                        preferences.set(Preferences.Keys.clipboardStorageLimitMB, Int(storageLimitMB))
                    }
                    SettingsDivider()
                    SettingsRow(title: "当前占用") {
                        Text(Self.bytesText(ClipboardStorageUsageProvider.shared.totalBytes))
                            .font(.system(size: 13).monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    SettingsDivider()
                    SettingsRow(title: "清理历史",
                                subtitle: "按保留天数与容量上限立即执行一次清理") {
                        Button("立即清理") {
                            ClipboardHistoryRetentionPruneScheduler.shared.prune()
                            ClipboardStoragePruneScheduler.shared.prune()
                        }
                        .controlSize(.small)
                    }
                }
            }

            SettingsSection("捕获") {
                SettingsGroupBox {
                    Text("捕获为自适应轮询：闲置 1 秒，检测到新内容后 0.5 秒突发（持续 2 秒）。")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 8)
                    SettingsDivider()
                    SettingsRow(title: "复制后自动粘贴到前台应用",
                                subtitle: "需要「辅助功能」权限，默认关闭。") {
                        HStack(spacing: 8) {
                            // v111：权限引导窗统一入口（授权状态实时观察）
                            if !permissions.status(.accessibility).isGranted {
                                Button("去授权") { PermissionGuideWindowController.shared.show() }
                                    .controlSize(.small)
                                    .buttonStyle(.borderless)
                            }
                            Toggle("", isOn: $autoPaste)
                                .labelsHidden()
                                .toggleStyle(.switch)
                                .controlSize(.small)
                                .onChange(of: autoPaste) { newValue in
                                    preferences.set(Preferences.Keys.clipboardAutoPaste, newValue)
                                }
                        }
                    }
                }
            }

            SettingsSection("浮动窗") {
                SettingsGroupBox {
                    SettingsRow(title: "显示浮动窗") {
                        Toggle("", isOn: $floatingVisible)
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .controlSize(.small)
                            .onChange(of: floatingVisible) { newValue in
                                if newValue { FloatingClipboardWindowController.shared.show() }
                                else { FloatingClipboardWindowController.shared.hide() }
                            }
                    }
                    SettingsDivider()
                    SettingsRow(title: "浮动窗位置", subtitle: "重置为当前屏幕中央") {
                        Button("重置位置") {
                            let centered = FloatingClipboardPinState.shared.clampedFrame()
                            FloatingClipboardWindowController.shared.window?.setFrame(centered, display: true)
                        }
                        .controlSize(.small)
                    }
                }
            }
        }
        .font(.system(size: 13))
    }

    // MARK: - 行组件

    /// 滑块行：标题 + 右侧数值，下方通栏滑块（与卡片内其它行同一节奏）
    private func sliderRow(_ title: String,
                           valueText: String,
                           value: Binding<Double>,
                           range: ClosedRange<Double>,
                           step: Double,
                           onCommit: @escaping () -> Void) -> some View {
        VStack(spacing: 7) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                Spacer(minLength: 8)
                Text(valueText)
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Slider(value: value, in: range, step: step) { _ in
                // 拖动开始/结束都会回调；写入是幂等的整数键，无需防抖
                onCommit()
            }
            .controlSize(.small)
        }
        .padding(.vertical, 9)
    }

    private static func bytesText(_ bytes: Int64) -> String {
        let mb = Double(bytes) / 1024 / 1024
        if mb >= 1 { return String(format: "%.1f MB", mb) }
        return String(format: "%.0f KB", Double(bytes) / 1024)
    }
}
