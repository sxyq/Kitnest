import AppKit
import SwiftUI

// MARK: - 文字字体配置弹层（选中文字后点开）
//
// 交互取向（参考 Snipaste / CleanShot 的文字工具条）：
//   点已有文字 → 选中 + 弹出这条配置；改完即刻作用在选中文字上（撤销栈合并成一条）。
//   三块就够用：字号（滑杆 + 数值）、字重（标准/中粗/粗）、颜色（色板 + 自定义），
//   外加「删除文字」。不做字体族/斜体/下划线——截图标注场景用不上，控件一多反而难找。

/// 弹层数据源：画布把当前选中文字的样式填进来，回调直接落回画布
final class TextFontModel: ObservableObject {
    @Published var size: Double = 1
    @Published var weight: Int = 1
    @Published var colorHex: String = "#FF3B30"

    var onSize: ((Double) -> Void)?
    var onWeight: ((Int) -> Void)?
    var onColor: ((String) -> Void)?
    var onDelete: (() -> Void)?
    /// 关闭弹层（Esc / 显式关闭；弹层是 .applicationDefined，不会自己吞点击）
    var onClose: (() -> Void)?

    /// 字号刻度：与工具条一致（1…12 → 6…72px）
    static let sizeRange: ClosedRange<Double> = 1...12
}

struct TextFontPopoverView: View {
    @ObservedObject var model: TextFontModel

    private static let palette: [String] = ["#FF3B30", "#FF9500", "#FFCC00", "#34C759",
                                            "#0A84FF", "#AF52DE", "#FFFFFF", "#1C1C1E"]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("文字样式")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    model.onClose?()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("关闭（Esc）")
            }

            // 字号：滑杆 + 数值
            HStack(spacing: 8) {
                Text("字号")
                    .font(.system(size: 11))
                    .frame(width: 28, alignment: .leading)
                Slider(value: Binding(
                    get: { model.size },
                    set: { model.size = $0; model.onSize?($0) }
                ), in: TextFontModel.sizeRange)
                .controlSize(.small)
                Text("\(Int(model.size.rounded()))")
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 18, alignment: .trailing)
            }

            // 字重
            HStack(spacing: 8) {
                Text("字重")
                    .font(.system(size: 11))
                    .frame(width: 28, alignment: .leading)
                Picker("", selection: Binding(
                    get: { model.weight },
                    set: { model.weight = $0; model.onWeight?($0) }
                )) {
                    Text("标准").tag(0)
                    Text("中粗").tag(1)
                    Text("加粗").tag(2)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
            }

            // 颜色
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    ForEach(Self.palette, id: \.self) { hex in
                        let color = Color(nsColor: AnnotationCompositor.color(fromHex: hex))
                        Button {
                            model.colorHex = hex
                            model.onColor?(hex)
                        } label: {
                            Circle()
                                .fill(color)
                                .frame(width: 16, height: 16)
                                .overlay(Circle().strokeBorder(Color.black.opacity(0.15), lineWidth: 0.5))
                                .overlay {
                                    if model.colorHex.uppercased() == hex.uppercased() {
                                        Circle().strokeBorder(Color.accentColor, lineWidth: 2)
                                    }
                                }
                                .frame(width: 22, height: 22)
                                .contentShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .help(hex)
                    }
                }
                ColorPicker("自定义…", selection: Binding(
                    get: { Color(nsColor: AnnotationCompositor.color(fromHex: model.colorHex)) },
                    set: { color in
                        let hex = AnnotationCompositor.hex(of: NSColor(color))
                        model.colorHex = hex
                        model.onColor?(hex)
                    }
                ), supportsOpacity: false)
                    .font(.system(size: 11))
            }

            Divider()
            HStack {
                Button(role: .destructive) {
                    model.onDelete?()
                } label: {
                    Label("删除文字", systemImage: "trash")
                        .font(.system(size: 11))
                }
                .buttonStyle(.borderless)
                Spacer()
            }
        }
        .padding(12)
        .frame(width: 228)
        .onExitCommand { model.onClose?() }
    }
}
