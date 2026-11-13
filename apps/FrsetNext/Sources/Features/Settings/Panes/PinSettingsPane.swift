import SwiftUI
import AppKit
import Combine

// MARK: - 钉图设置（v234，对齐 1Capture 的「可视化选项 + 实时预览」）
//
// 参考图里「拖放架」用的是四张**预览缩略图**而不是下拉框：
// 用户不用读文字就知道每个选项长什么样。钉图的外观（描边/圆角/阴影）
// 恰恰是「说不清、必须看」的东西，所以这一页以预览为主：
//   1. 顶部一张大预览：模拟截图 + 钉图外观 + 底部工具条；
//   2. 四个预设卡片：经典 / 无边框 / 卡片 / 强调描边；
//   3. 细项（描边宽度、颜色、圆角、阴影、不透明度、吸附、工具条自动隐藏）。

public struct PinSettingsPane: View {

    public init() {}

    public var body: some View {
        SettingsDraftEditor(id: "pin", makeDraft: { PinSettingsDraft() }) { draft in
            PinSettingsContent(draft: draft)
        }
    }
}

final class PinSettingsDraft: SettingsEditableDraft {
    @Published var appearance = PinAppearance.current
    private var saved = PinAppearance.current

    var isDirty: Bool { appearance != saved }

    func save() -> String? {
        PinStyle.borderWidth = appearance.borderWidth
        PinStyle.borderColorToken = appearance.borderColorToken
        PinStyle.cornerRadius = appearance.cornerRadius
        PinStyle.shadow = appearance.shadow
        PinStyle.magnet = appearance.magnet
        PinStyle.opacity = appearance.opacity
        PinStyle.chromeAutoHide = appearance.chromeAutoHide
        saved = appearance
        objectWillChange.send()
        return nil
    }

    func discard() { appearance = saved }
    func restoreDefaults() { appearance = .defaults }
}

private struct PinSettingsContent: View {
    @ObservedObject var draft: PinSettingsDraft
    private var borderWidth: Double { draft.appearance.borderWidth }
    private var borderColor: String { draft.appearance.borderColorToken }
    private var corner: Double { draft.appearance.cornerRadius }
    private var shadow: Bool { draft.appearance.shadow }
    private var opacity: Double { draft.appearance.opacity }

    private var presets: [PinPreset] {
        [("classic", "经典"), ("borderless", "无边框"), ("card", "卡片"), ("accent", "强调")].map { id, title in
            var appearance = PinAppearance.defaults
            appearance.applyPreset(id)
            return PinPreset(id: id, title: title, border: appearance.borderWidth,
                             color: appearance.borderColorToken, corner: appearance.cornerRadius,
                             shadow: appearance.shadow)
        }
    }

    public var body: some View {
        VStack(spacing: 20) {
            SettingsSection("预览") {
                SettingsGroupBox {
                    PinLivePreview(appearance: draft.appearance)
                        .frame(height: 220)
                        .padding(.vertical, 6)
                    Text("在场景内拖动、滚轮缩放；悬停显示正式控制条。按钮只演示反馈。")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .padding(.top, 8)
                        .padding(.bottom, 6)
                }
            }

            SettingsSection("外观预设") {
                SettingsGroupBox {
                    HStack(alignment: .top, spacing: 10) {
                        ForEach(presets) { preset in
                            VisualOptionCard(title: preset.title,
                                             selected: isActive(preset),
                                             action: { apply(preset) }) {
                                PinThumb(borderWidth: preset.border,
                                         borderColor: preset.color,
                                         corner: preset.corner,
                                         shadow: preset.shadow)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 8)
                }
            }

            SettingsSection("边框") {
                SettingsGroupBox {
                    row("描边") {
                        Slider(value: $draft.appearance.borderWidth, in: 0...6, step: 0.5)
                            .frame(width: 220)
                        Text(borderWidth == 0 ? "无" : String(format: "%.1f pt", borderWidth))
                            .font(.system(size: 11.5).monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 52, alignment: .trailing)
                    }
                    SettingsDivider()
                    row("描边颜色") {
                        HStack(spacing: 8) {
                            ForEach(borderColors, id: \.token) { item in
                                Button {
                                    draft.appearance.borderColorToken = item.token
                                } label: {
                                    HStack(spacing: 5) {
                                        Circle()
                                            .fill(item.swatch)
                                            .frame(width: 12, height: 12)
                                            .overlay(Circle().strokeBorder(Color.primary.opacity(0.18), lineWidth: 0.5))
                                        Text(item.title)
                                            .font(.system(size: 11.5))
                                            .foregroundStyle(borderColor == item.token ? Theme.accent : Color.primary.opacity(0.8))
                                    }
                                    .padding(.horizontal, 9)
                                    .frame(height: 26)
                                    .background {
                                        RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                                            .fill(borderColor == item.token ? Theme.accent.opacity(0.12) : Color.primary.opacity(0.04))
                                    }
                                    .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    Text("「自动」按截图四周的平均亮度反色：浅色文档配深边、深色 IDE 配白边。")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .padding(.bottom, 6)
                }
            }

            SettingsSection("窗口") {
                SettingsGroupBox {
                    row("圆角") {
                        Slider(value: $draft.appearance.cornerRadius, in: 0...24, step: 1)
                            .frame(width: 220)
                        Text("\(Int(corner))")
                            .font(.system(size: 11.5).monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 52, alignment: .trailing)
                    }
                    SettingsDivider()
                    row("不透明度") {
                        Slider(value: $draft.appearance.opacity, in: 0.3...1, step: 0.05)
                            .frame(width: 220)
                        Text("\(Int((opacity * 100).rounded()))%")
                            .font(.system(size: 11.5).monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 52, alignment: .trailing)
                    }
                    SettingsDivider()
                    row("窗口阴影") {
                        Toggle("", isOn: $draft.appearance.shadow)
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .controlSize(.small)

                    }
                    SettingsDivider()
                    row("自动吸附") {
                        Toggle("", isOn: $draft.appearance.magnet)
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .controlSize(.small)

                    }
                    Text("拖动钉图时，靠近屏幕边缘或其它钉图会自动对齐。")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .padding(.bottom, 6)
                }
            }

            SettingsSection("控制条") {
                SettingsGroupBox {
                    row("自动收起") {
                        Picker("", selection: $draft.appearance.chromeAutoHide) {
                            Text("静止 1.5 秒").tag(1.5)
                            Text("静止 2.5 秒").tag(2.5)
                            Text("静止 4 秒").tag(4.0)
                            Text("不自动收起").tag(0.0)
                        }
                        .labelsHidden()
                        .frame(width: 150)
                        Text("鼠标移开一定会收起")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    SettingsDivider()
                    VStack(alignment: .leading, spacing: 7) {
                        Text("快捷键（悬停控制条时气泡里也会显示）")
                            .font(.system(size: 11.5, weight: .medium))
                        LazyVGrid(columns: [GridItem(.fixed(150), alignment: .leading),
                                            GridItem(.fixed(150), alignment: .leading)],
                                  alignment: .leading, spacing: 6) {
                            shortcut("标注", "A")
                            shortcut("拷贝", "C")
                            shortcut("更多", "M")
                            shortcut("回到 100%", "0")
                            shortcut("放大 / 缩小", "+ / −")
                            shortcut("关闭", "Esc")
                        }
                    }
                    .padding(.vertical, 8)
                }
            }
        }
        .font(.system(size: 12))
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - 小工具

    private struct BorderColorItem {
        let token: String
        let title: String
        let swatch: Color
    }

    private var borderColors: [BorderColorItem] {
        [
            BorderColorItem(token: "auto", title: "自动", swatch: Color(white: 0.45)),
            BorderColorItem(token: "white", title: "白色", swatch: Color.white),
            BorderColorItem(token: "black", title: "黑色", swatch: Color(white: 0.08)),
            BorderColorItem(token: "accent", title: "强调", swatch: Theme.accent),
        ]
    }

    private func row<Content: View>(_ title: String,
                                    @ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 12) {
            Text(title)
                .font(.system(size: 12.5))
                .frame(width: 74, alignment: .leading)
            content()
            Spacer(minLength: 0)
        }
        .padding(.vertical, 7)
    }

    private func shortcut(_ title: String, _ key: String) -> some View {
        HStack(spacing: 7) {
            Text(key)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .padding(.horizontal, 5)
                .padding(.vertical, 1.5)
                .background(RoundedRectangle(cornerRadius: Theme.Radius.micro, style: .continuous)
                    .fill(Color.primary.opacity(0.08)))
            Text(title)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
        }
    }

    private func isActive(_ p: PinPreset) -> Bool {
        abs(borderWidth - p.border) < 0.01
            && borderColor == p.color
            && abs(corner - p.corner) < 0.01
            && shadow == p.shadow
    }

    private func apply(_ p: PinPreset) {
        draft.appearance.applyPreset(p.id)
    }
}

struct PinPreset: Identifiable {
    let id: String
    let title: String
    let border: Double
    let color: String
    let corner: Double
    let shadow: Bool
}

// 预设与大场景均使用正式图像组件。
struct PinThumb: View {
    var borderWidth: Double
    var borderColor: String
    var corner: Double
    var shadow: Bool

    var body: some View {
        var appearance = PinAppearance.defaults
        appearance.borderWidth = borderWidth
        appearance.borderColorToken = borderColor
        appearance.cornerRadius = corner
        appearance.shadow = shadow
        return PinLivePreview(appearance: appearance, interactive: false)
    }
}

struct PinLivePreview: NSViewRepresentable {
    var appearance: PinAppearance
    var interactive = true
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func makeNSView(context: Context) -> PinPreviewScene { PinPreviewScene(interactive: interactive) }
    func updateNSView(_ view: PinPreviewScene, context: Context) {
        view.update(appearance: appearance, reduceTransparency: reduceTransparency)
    }
    static func dismantleNSView(_ view: PinPreviewScene, coordinator: ()) { view.stop() }
}
