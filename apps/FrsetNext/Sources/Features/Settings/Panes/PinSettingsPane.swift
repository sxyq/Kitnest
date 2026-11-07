import SwiftUI
import AppKit

// MARK: - 钉图设置（v234，对齐 1Capture 的「可视化选项 + 实时预览」）
//
// 参考图里「拖放架」用的是四张**预览缩略图**而不是下拉框：
// 用户不用读文字就知道每个选项长什么样。钉图的外观（描边/圆角/阴影）
// 恰恰是「说不清、必须看」的东西，所以这一页以预览为主：
//   1. 顶部一张大预览：模拟截图 + 钉图外观 + 底部工具条；
//   2. 四个预设卡片：经典 / 无边框 / 卡片 / 强调描边；
//   3. 细项（描边宽度、颜色、圆角、阴影、不透明度、吸附、工具条自动隐藏）。

public struct PinSettingsPane: View {

    @Stored private var borderWidth: Double
    @Stored private var borderColor: String
    @Stored private var corner: Double
    @Stored private var shadow: Bool
    @Stored private var magnet: Bool
    @Stored private var opacity: Double
    @Stored private var autoHide: Double
    @Stored private var revision = 0

    public init() {
        _borderWidth = Stored(wrappedValue: PinStyle.borderWidth)
        _borderColor = Stored(wrappedValue: PinStyle.borderColorToken)
        _corner = Stored(wrappedValue: PinStyle.cornerRadius)
        _shadow = Stored(wrappedValue: PinStyle.shadow)
        _magnet = Stored(wrappedValue: PinStyle.magnet)
        _opacity = Stored(wrappedValue: PinStyle.opacity)
        _autoHide = Stored(wrappedValue: PinStyle.chromeAutoHide)
    }

    private var presets: [PinPreset] {
        [
            PinPreset(id: "classic", title: "经典", border: 1.5, color: "auto", corner: 10, shadow: true),
            PinPreset(id: "borderless", title: "无边框", border: 0, color: "auto", corner: 0, shadow: false),
            PinPreset(id: "card", title: "卡片", border: 2, color: "white", corner: 16, shadow: true),
            PinPreset(id: "accent", title: "强调", border: 2, color: "accent", corner: 12, shadow: true),
        ]
    }

    public var body: some View {
        VStack(spacing: 20) {
            SettingsSection("预览") {
                SettingsGroupBox {
                    PinLivePreview(borderWidth: borderWidth,
                                   borderColor: borderColor,
                                   corner: corner,
                                   shadow: shadow,
                                   opacity: opacity)
                        .frame(height: 236)
                        .padding(.vertical, 6)
                    Text("钉图上悬停会浮出这条控制条：拖拽柄 · 标注 · 拷贝 · 更多 · 缩放。")
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
                        Slider(value: $borderWidth, in: 0...6, step: 0.5)
                            .frame(width: 220)
                            .onChange(of: borderWidth) { PinStyle.borderWidth = $0 }
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
                                    borderColor = item.token
                                    PinStyle.borderColorToken = item.token
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
                        Slider(value: $corner, in: 0...24, step: 1)
                            .frame(width: 220)
                            .onChange(of: corner) { PinStyle.cornerRadius = $0 }
                        Text("\(Int(corner))")
                            .font(.system(size: 11.5).monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 52, alignment: .trailing)
                    }
                    SettingsDivider()
                    row("不透明度") {
                        Slider(value: $opacity, in: 0.3...1, step: 0.05)
                            .frame(width: 220)
                            .onChange(of: opacity) { PinStyle.opacity = $0 }
                        Text("\(Int((opacity * 100).rounded()))%")
                            .font(.system(size: 11.5).monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 52, alignment: .trailing)
                    }
                    SettingsDivider()
                    row("窗口阴影") {
                        Toggle("", isOn: $shadow)
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .controlSize(.small)
                            .onChange(of: shadow) { PinStyle.shadow = $0 }
                    }
                    SettingsDivider()
                    row("自动吸附") {
                        Toggle("", isOn: $magnet)
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .controlSize(.small)
                            .onChange(of: magnet) { PinStyle.magnet = $0 }
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
                        Picker("", selection: $autoHide) {
                            Text("静止 1.5 秒").tag(1.5)
                            Text("静止 2.5 秒").tag(2.5)
                            Text("静止 4 秒").tag(4.0)
                            Text("不自动收起").tag(0.0)
                        }
                        .labelsHidden()
                        .frame(width: 150)
                        .onChange(of: autoHide) { PinStyle.chromeAutoHide = $0 }
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
        borderWidth = p.border
        borderColor = p.color
        corner = p.corner
        shadow = p.shadow
        PinStyle.borderWidth = p.border
        PinStyle.borderColorToken = p.color
        PinStyle.cornerRadius = p.corner
        PinStyle.shadow = p.shadow
        revision += 1
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

// MARK: - 预设缩略图

struct PinThumb: View {
    var borderWidth: Double
    var borderColor: String
    var corner: Double
    var shadow: Bool

    var body: some View {
        ZStack {
            // 桌面底（深色，衬出浅色截图与描边）
            LinearGradient(colors: [Color(white: 0.36), Color(white: 0.22)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            VStack(alignment: .leading, spacing: 3) {
                ForEach(0..<4, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                        .fill(Color.primary.opacity(0.12))
                        .frame(width: CGFloat([52, 40, 48, 30][i]), height: 3)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color(white: 0.98))
            .clipShape(RoundedRectangle(cornerRadius: corner * 0.55, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: corner * 0.55, style: .continuous)
                    .strokeBorder(resolved(borderColor), lineWidth: borderWidth * 0.7)
            )
            .shadow(color: .black.opacity(shadow ? 0.45 : 0), radius: shadow ? 5 : 0, y: shadow ? 2 : 0)
            .padding(14)
        }
    }

    private func resolved(_ token: String) -> Color {
        switch token {
        case "white":  return Color.white
        case "black":  return Color(white: 0.08)
        case "accent": return Theme.accent
        default:       return Color(white: 0.15).opacity(0.55)
        }
    }
}

// MARK: - 大预览

struct PinLivePreview: View {
    var borderWidth: Double
    var borderColor: String
    var corner: Double
    var shadow: Bool
    var opacity: Double

    var body: some View {
        GeometryReader { geo in
            // 宽高都受容器约束：之前只按宽度算，高 214 时预览底部被裁掉、
            // 说明文字还压在图上（实测）
            let maxW = min(max(220, geo.size.width - 48), 380)
            let maxH = max(120, geo.size.height - 12)
            let width = min(maxW, maxH / 0.60)
            let height = width * 0.60
            ZStack {
                RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                    .fill(LinearGradient(colors: [Color(white: 0.34), Color(white: 0.20)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))

                ZStack(alignment: .bottom) {
                    mockScreenshot
                        .frame(width: width, height: height)
                        .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: corner, style: .continuous)
                                .strokeBorder(resolved(borderColor), lineWidth: borderWidth)
                        )
                        .opacity(opacity)
                        .shadow(color: .black.opacity(shadow ? 0.45 : 0),
                                radius: shadow ? 14 : 0,
                                y: shadow ? 6 : 0)

                    toolbarMock
                        .padding(.bottom, 12)
                }
            }
        }
    }

    private var mockScreenshot: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 6) {
                Circle().fill(Color(red: 0.95, green: 0.45, blue: 0.35)).frame(width: 6, height: 6)
                Circle().fill(Color(red: 0.95, green: 0.72, blue: 0.30)).frame(width: 6, height: 6)
                Circle().fill(Color(red: 0.40, green: 0.78, blue: 0.42)).frame(width: 6, height: 6)
                Spacer()
            }
            RoundedRectangle(cornerRadius: 2).fill(Color.primary.opacity(0.16)).frame(width: 132, height: 6)
            ForEach(0..<5, id: \.self) { i in
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.primary.opacity(0.08))
                    .frame(width: CGFloat([186, 150, 204, 120, 168][i]), height: 5)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(white: 0.985))
    }

    private var toolbarMock: some View {
        HStack(spacing: 0) {
            HStack(spacing: 2.5) {
                ForEach(0..<2, id: \.self) { _ in
                    VStack(spacing: 2.5) {
                        ForEach(0..<3, id: \.self) { _ in
                            Circle().fill(Color(white: 0.35)).frame(width: 2.6, height: 2.6)
                        }
                    }
                }
            }
            .frame(width: 22)
            Image(systemName: "scribble").font(.system(size: 11, weight: .medium))
            Spacer().frame(width: 14)
            Image(systemName: "doc.on.doc").font(.system(size: 11))
            Spacer().frame(width: 14)
            Image(systemName: "ellipsis").font(.system(size: 11))
            Spacer().frame(width: 14)
            Text("100%").font(.system(size: 9, weight: .medium).monospacedDigit())
                .foregroundStyle(Color(white: 0.3))
        }
        .foregroundStyle(Color(white: 0.18))
        .padding(.horizontal, 10)
        .frame(height: 28)
        .background(Capsule(style: .continuous).fill(Color.white.opacity(0.94)))
        .overlay(Capsule(style: .continuous).strokeBorder(Color.black.opacity(0.08), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.22), radius: 6, y: 2)
    }

    private func resolved(_ token: String) -> Color {
        switch token {
        case "white":  return Color.white.opacity(0.9)
        case "black":  return Color(white: 0.08).opacity(0.6)
        case "accent": return Theme.accent
        default:       return Color(white: 0.12).opacity(0.5)
        }
    }
}
