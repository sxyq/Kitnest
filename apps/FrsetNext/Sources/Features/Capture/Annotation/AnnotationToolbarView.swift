import AppKit
import SwiftUI

// MARK: - 编辑器配景色
//
// 标注编辑器是「图片为主角」的界面：画布用中性灰而不是纯黑，
// 浅色下接近 macOS 的窗口底，深色下压到接近 #1D1D20，图片再叠一层投影浮起来。
enum EditorBackdrop {
    static let color = NSColor(name: nil) { appearance in
        let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        return isDark
            ? NSColor(srgbRed: 0.114, green: 0.114, blue: 0.125, alpha: 1)
            : NSColor(srgbRed: 0.933, green: 0.937, blue: 0.945, alpha: 1)
    }
}

// MARK: - 工具条状态

/// 工具条状态：当前工具、颜色、线宽、马赛克笔刷/块大小、撤销重做可用态。
final class EditorToolbarModel: ObservableObject {
    @Published var toolIndex = 2                 // 默认箭头（截图后最常用）
    @Published var color: Color = Color(nsColor: .systemRed)
    /// 形状/画笔的线宽（默认值由图片宽度决定，见 applyImageDefaults）
    @Published var lineWidth: Double = 24
    /// 文字字号（与线宽同刻度：fontSize = value * 6，默认取最小值 1 → 12pt）
    @Published var textSize: Double = 1
    /// 荧光笔宽度（实际绘制 = value * 4，默认细一点，避免一道 96px 的色带）
    @Published var highlighterWidth: Double = 4
    /// 笔刷类工具（马赛克/橡皮/抹除）的直径
    @Published var brushWidth: Double = 120
    /// 马赛克块大小（像素）
    @Published var mosaicBlock: Int = 16
    /// 成图圆角（编辑视图坐标下的点；0 = 直角，最大 40）
    /// v176（用户：「截图的边角圆角是可以调的，在编辑栏里」）
    @Published var cornerRadius: Double = 0

    /// 按图幅给默认粗细：Retina 截图（3000px 级）上 3pt 线细到看不见，
    /// 默认直接给到区间上沿附近；小图则收敛，避免一笔糊满。
    /// 字号同理：原先固定 `textSize = 1` → 12px，在 3000px 截图上只有图宽的 0.4%，
    /// 缩放显示后屏幕上不足 4pt（输入框小到看不清）。改为按图宽取 ~1.4% 作为默认字高。
    func applyImageDefaults(imageWidth: Int) {
        let w = Double(max(1, imageWidth))
        lineWidth = min(40, max(5, (w * 0.010).rounded()))
        brushWidth = min(200, max(48, (w * 0.045).rounded()))
        textSize = min(12, max(2, (w * 0.014 / 6).rounded()))
        mosaicBlock = w >= 2000 ? 16 : 10
    }
    @Published var canUndo = false
    @Published var canRedo = false
    /// 画布上是否正选中一段已有文字（此时字号滑杆改的是「这段文字」，不是下一个文字的默认值）
    @Published var textSelectionActive = false

    var activeTool: AnnotationTool {
        let all = AnnotationTool.allCases
        return all[max(0, min(toolIndex, all.count - 1))]
    }

    /// 当前工具是否用笔刷直径（而不是线宽）
    var isBrushTool: Bool {
        switch activeTool {
        case .mosaic, .eraser, .removal: return true
        default: return false
        }
    }

    /// 当前工具是否需要颜色
    var usesColor: Bool {
        switch activeTool {
        case .mosaic, .eraser, .removal: return false
        default: return true
        }
    }

    /// 当前工具是否用线宽/字号（橡皮不需要）
    var usesSize: Bool {
        switch activeTool {
        case .eraser: return false
        default: return true
        }
    }

    var sizeValue: Double {
        switch activeTool {
        case .text: return textSize
        case .highlighter: return highlighterWidth
        case .eraser, .mosaic, .removal: return brushWidth
        default: return lineWidth
        }
    }

    var sizeRange: ClosedRange<Double> {
        switch activeTool {
        case .eraser, .mosaic, .removal: return 8...200
        case .text: return 1...12
        case .highlighter: return 1...16
        default: return 1...40
        }
    }

    /// 尺寸标签：文字叫字号，笔刷叫笔刷，其余叫粗细
    var sizeLabel: String {
        switch activeTool {
        case .mosaic, .eraser, .removal: return "笔刷"
        case .text: return "字号"
        default: return "粗细"
        }
    }

    func setSize(_ value: Double) {
        switch activeTool {
        case .text: textSize = value
        case .highlighter: highlighterWidth = value
        case .eraser, .mosaic, .removal: brushWidth = value
        default: lineWidth = value
        }
    }

    func nudgeSize(by delta: Double) {
        let range = sizeRange
        setSize(min(range.upperBound, max(range.lowerBound, sizeValue + delta)))
    }
}

// MARK: - 竖排工具栏尺寸（SwiftUI 与 AppKit 共用一套数值）
//
// v181（方案 B）：9 个工具竖排浮在画布左缘，画布底部的胶囊只留样式与操作。
// 竖栏高度必须能被 AppKit 侧算出来（用于居中和最小高度校验），所以数值集中在这里，
// 两边都读同一份常量，避免「改了 SwiftUI 忘了改 NSHostingView frame」。
enum ToolRailMetrics {
    /// 单个工具按钮的命中区边长
    static let button: CGFloat = 28
    /// 胶囊左右内边距（= 按钮右缘到胶囊边）
    static let hPadding: CGFloat = 8
    /// 胶囊上下内边距
    static let vPadding: CGFloat = 7
    /// 组间分割线的上下留白
    static let groupGap: CGFloat = 5
    /// 分割线长度
    static let separatorWidth: CGFloat = 18
    /// 分组断点：第 3、6 个工具之后（形状 / 绘制 / 修复 各 3 个）
    static let groupBreaks: Set<Int> = [2, 5]
    /// 胶囊宽度
    static let width: CGFloat = button + hPadding * 2
    /// 胶囊高度（9 个按钮 + 2 条分割线 + 内边距）
    static var height: CGFloat {
        let n = CGFloat(AnnotationTool.allCases.count)
        let seps = CGFloat(groupBreaks.count)
        return n * button + seps * (groupGap * 2 + 1) + vPadding * 2
    }
}

// MARK: - 竖排工具栏
//
// 9 个工具竖着浮在画布左缘：不跟底部的样式/操作抢位置，画布底部更干净；
// 代价是多一条竖栏，与 macOS 原生截图工具（横向一条）的习惯不同。
struct AnnotationToolRailView: View {
    @ObservedObject var model: EditorToolbarModel
    var onTool: (Int) -> Void

    var body: some View {
        VStack(spacing: 6) {
            toolHint
            railCapsule
        }
    }

    /// v182（用户：「当前选中后没有对应的提示」）：
    /// 选中工具后在竖栏上方给一条小提示：工具名 · 快捷键 + 一句用法。
    private var toolHint: some View {
        let tool = AnnotationTool.allCases[max(0, min(model.toolIndex, AnnotationTool.allCases.count - 1))]
        return VStack(spacing: 1) {
            Text("\(tool.title) · \(tool.shortcut)")
                .font(.system(size: 10, weight: .semibold))
            Text(AnnotationToolRailView.usageTip(tool))
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .frame(width: ToolRailMetrics.width + 28)
        .background(
            // v207：标注工具提示浮在画布上，需要自己带玻璃底——统一用 GlassSurface
            GlassSurface(cornerRadius: Theme.Radius.chip)
        )
        .fixedSize()
    }

    static func usageTip(_ tool: AnnotationTool) -> String {
        switch tool {
        case .rectangle: return "拖动画矩形框"
        case .ellipse:   return "拖动画椭圆"
        case .arrow:     return "拖动画箭头"
        case .pen:       return "自由画线"
        case .text:      return "点画面输入文字"
        case .highlighter: return "半透明划重点"
        case .mosaic:    return "涂抹打码"
        case .eraser:    return "擦掉已画的标注"
        case .removal:   return "涂抹物体，松手自动抹除"
        }
    }

    private var railCapsule: some View {
        VStack(spacing: 0) {
            ForEach(Array(AnnotationTool.allCases.enumerated()), id: \.offset) { index, tool in
                ToolIconButton(symbol: tool.systemImage,
                               selected: model.toolIndex == index,
                               dimension: ToolRailMetrics.button,
                               help: "\(tool.title)  \(tool.shortcut)") {
                    onTool(index)
                }
                if ToolRailMetrics.groupBreaks.contains(index) {
                    Rectangle()
                        .fill(Color.primary.opacity(0.13))
                        .frame(width: ToolRailMetrics.separatorWidth, height: 1)
                        .padding(.vertical, ToolRailMetrics.groupGap)
                }
            }
        }
        .padding(.horizontal, ToolRailMetrics.hPadding)
        .padding(.vertical, ToolRailMetrics.vPadding)
        .frame(width: ToolRailMetrics.width)
        // v181：统一玻璃面（glassPlate）——原「material + 0.88 窗口色 + 自绘描边」
        // 与命令面板/云链接弹窗是同一种结构面，视觉配方不再各写一份
        .glassPlate()
        .shadow(color: .black.opacity(0.22), radius: 10, x: 0, y: 3)
        .fixedSize()
    }
}

// MARK: - 底部工具条（样式 + 操作）
//
// 设计取向（对齐 CleanShot / Snipaste / Flameshot 的共同做法）：
// - 图片是主角：控件收进一条悬浮胶囊，浮在画布底部而不是压成一条通栏工具带；
// - 工具交给左侧竖栏，这里只留「改当前工具的样子」和「对成图做什么」；
// - 常用参数（颜色、粗细、圆角）就地可调，低频参数（马赛克块）走紧凑弹层；
// - 主操作只有一个（复制），保存/更多/关闭降级为图标，避免一排同权重按钮。
struct AnnotationToolbarView: View {
    @ObservedObject var model: EditorToolbarModel
    var onColor: (Color) -> Void
    var onSize: (Double) -> Void
    var onBlock: (Int) -> Void
    var onCorner: (Double) -> Void
    var onUndo: () -> Void
    var onRedo: () -> Void
    var onClear: () -> Void
    var onLong: () -> Void
    var onCopy: () -> Void
    var onSave: () -> Void
    var onClose: () -> Void

    @Stored private var showPalette = false
    @Stored private var showBlock = false
    @Stored private var showCorner = false

    /// 预设色：macOS 系统色 + 黑白，够覆盖截图标注的绝大多数场景
    private static let palette: [String] = ["#FF3B30", "#FF9500", "#FFCC00", "#34C759",
                                            "#0A84FF", "#AF52DE", "#FFFFFF", "#1C1C1E"]

    var body: some View {
        HStack(spacing: 9) {
            styleCluster
            separator
            historyCluster
            primaryCluster
        }
        .padding(.horizontal, 10)
        .frame(height: 44)
        .glassPlate()
        .shadow(color: .black.opacity(0.22), radius: 10, x: 0, y: 3)
        .fixedSize()
    }

    // MARK: 样式组

    /// 样式组：颜色 / 粗细 / 圆角（+ 马赛克块），都作用在「当前工具」或「成图」上。
    /// 工具选择已移到左侧竖栏，这条胶囊只剩 3–4 个样式控件 + 撤销重做 + 4 个操作。
    private var styleCluster: some View {
        HStack(spacing: 7) {
            colorChip
            sizeControl
            cornerControl
            blockSlot
        }
    }

    /// 截图圆角（v176）：图标本身就是个圆角方块，圆角随数值实时变化，弹出滑杆细调。
    /// 圆角作用在「复制 / 保存」的成图上；编辑区画布同步裁切，所见即所得。
    private var cornerControl: some View {
        Button {
            showCorner.toggle()
        } label: {
            RoundedRectangle(cornerRadius: 1 + CGFloat(model.cornerRadius) * 0.26,
                             style: .continuous)
                .strokeBorder(Color.primary.opacity(0.6), lineWidth: 1.5)
                .frame(width: 15, height: 15)
                .frame(width: 26, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                        .fill(Color.primary.opacity(showCorner ? 0.08 : 0))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .help(model.cornerRadius > 0 ? "截图圆角 \(Int(model.cornerRadius))" : "截图圆角：直角")
        .accessibilityLabel("截图圆角")
        .popover(isPresented: $showCorner, arrowEdge: .bottom) { cornerPopover }
    }

    private var cornerPopover: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("截图圆角")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(model.cornerRadius > 0 ? "\(Int(model.cornerRadius.rounded()))" : "直角")
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Slider(value: Binding(
                get: { model.cornerRadius },
                set: { value in
                    model.cornerRadius = value
                    onCorner(value)
                }), in: 0...40)
                .controlSize(.small)
                .tint(Theme.accent)
                .frame(width: 176)

            HStack(spacing: 5) {
                ForEach([0, 6, 12, 20, 32], id: \.self) { preset in
                    let selected = Int(model.cornerRadius.rounded()) == preset
                    Button {
                        model.cornerRadius = Double(preset)
                        onCorner(Double(preset))
                    } label: {
                        Text(preset == 0 ? "直角" : "\(preset)")
                            .font(.system(size: 11))
                            .frame(minWidth: 30)
                            .padding(.vertical, 3)
                            .background(
                                RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous)
                                    .fill(selected ? Theme.accent.opacity(0.20)
                                                   : Color.primary.opacity(0.06))
                            )
                            .foregroundStyle(selected ? Theme.accent : Color.primary)
                    }
                    .buttonStyle(.plain)
                }
            }
            Text("作用在「复制 / 保存」的成图，编辑区实时预览")
                .font(.system(size: 10))
                .foregroundStyle(Theme.tertiaryText)
        }
        .padding(12)
        .frame(width: 220)
    }

    /// 颜色：一个色点 + 弹层调色板（不再把 8 个色点铺在工具条上）
    private var colorChip: some View {
        Button {
            guard model.usesColor else { return }
            showPalette.toggle()
        } label: {
            Circle()
                .fill(model.color)
                .frame(width: 16, height: 16)
                .overlay(Circle().strokeBorder(Color.white.opacity(0.9), lineWidth: 1))
                .overlay(Circle().strokeBorder(Color.black.opacity(0.16), lineWidth: 0.5))
                .frame(width: 26, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                        .fill(Color.primary.opacity(showPalette ? 0.08 : 0))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .disabled(!model.usesColor)
        .opacity(model.usesColor ? 1 : 0.35)
        .help("颜色")
        .accessibilityLabel("颜色")
        .popover(isPresented: $showPalette, arrowEdge: .bottom) {
            palettePopover
        }
    }

    private var palettePopover: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("标注颜色")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(26), spacing: 9), count: 4),
                      spacing: 9) {
                ForEach(Self.palette, id: \.self) { hex in
                    let color = Color(nsColor: AnnotationCompositor.color(fromHex: hex))
                    Button {
                        model.color = color
                        onColor(color)
                        showPalette = false
                    } label: {
                        Circle()
                            .fill(color)
                            .frame(width: 24, height: 24)
                            .overlay(Circle().strokeBorder(Color.black.opacity(0.16), lineWidth: 0.5))
                            .overlay {
                                if isSameColor(model.color, color) {
                                    Circle().strokeBorder(Theme.accent, lineWidth: 2)
                                        .frame(width: 28, height: 28)
                                }
                            }
                            .frame(width: 30, height: 30)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .help(hex)
                }
            }
            Divider()
            ColorPicker("自定义…", selection: Binding(
                get: { model.color },
                set: { value in
                    model.color = value
                    onColor(value)
                }
            ), supportsOpacity: false)
                .font(.system(size: 12))
        }
        .padding(12)
        .frame(width: 168)
    }

    /// 粗细 / 笔刷直径：就地滑杆 + 数值，滚轮与 [ ] 也能调
    private var sizeControl: some View {
        HStack(spacing: 6) {
            // 实时预览：笔刷是圆点（直径随数值），线条是一根粗细条
            Group {
                if model.activeTool == .text {
                    Text("A")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(model.color)
                } else if model.isBrushTool {
                    Circle()
                        .fill(model.usesColor ? model.color : Color.primary.opacity(0.55))
                        .frame(width: previewDiameter, height: previewDiameter)
                } else {
                    Capsule()
                        .fill(model.color)
                        .frame(width: 15, height: previewLineHeight)
                }
            }
            .frame(width: 16, height: 16)
            .opacity(model.usesSize ? 1 : 0.3)

            Slider(value: Binding(
                get: { model.sizeValue },
                set: { newValue in commitSize(newValue) }), in: model.sizeRange)
                .controlSize(.small)
                .tint(Theme.accent)
                .frame(width: 88)
                .disabled(!model.usesSize)

            Text("\(Int(model.sizeValue.rounded()))")
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                .foregroundStyle(model.textSelectionActive && model.activeTool == .text
                                 ? Theme.accent : Color.secondary)
                .frame(width: 20, alignment: .trailing)
        }
        .frame(height: 26)
        .help(sizeHelp)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(model.sizeLabel)
        .accessibilityValue("\(Int(model.sizeValue.rounded()))")
    }

    private var sizeHelp: String {
        if model.activeTool == .text, model.textSelectionActive {
            return "字号：正在调整选中的文字（拖动滑杆、滚轮或 [ ]）"
        }
        return "\(model.sizeLabel)：拖动滑杆、滚轮或 [ ] 调整"
    }

    /// 线宽预览条高度（1–24 → 1.5–9pt）
    private var previewLineHeight: CGFloat {
        max(1.5, min(9, CGFloat(model.sizeValue) * 0.55 + 1.5))
    }

    private var previewDiameter: CGFloat {
        let value = model.sizeValue
        let raw = model.isBrushTool ? value / 6 : value + 2
        return max(3, min(15, CGFloat(raw)))
    }

    private func commitSize(_ value: Double) {
        model.setSize(value)
        onSize(value)
    }

    /// 马赛克块大小：只在马赛克工具下出现（底部胶囊已经很轻，不需要再为它预留固定槽位）
    @ViewBuilder
    private var blockSlot: some View {
        if model.activeTool == .mosaic {
            Button {
                showBlock.toggle()
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: "squareshape.split.3x3")
                        .font(.system(size: 11))
                    Text("\(model.mosaicBlock)")
                        .font(.system(size: 11, weight: .medium).monospacedDigit())
                        .fixedSize()
                    Image(systemName: "chevron.down")
                        .font(.system(size: 7, weight: .semibold))
                }
                .foregroundStyle(Color.primary.opacity(0.75))
                .padding(.horizontal, 8)
                .frame(height: 24)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous)
                        .fill(Color.primary.opacity(showBlock ? 0.09 : 0.05))
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusable(false)
            .help("马赛克块大小")
            .accessibilityLabel("马赛克块大小")
            .popover(isPresented: $showBlock, arrowEdge: .bottom) {
                blockPopover
            }
        }
    }

    private var blockPopover: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("马赛克块大小")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            Picker("", selection: Binding(
                get: { model.mosaicBlock },
                set: { model.mosaicBlock = $0; onBlock($0) })) {
                Text("6").tag(6)
                Text("10").tag(10)
                Text("16").tag(16)
                Text("24").tag(24)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            Text("块越小越接近原图纹理，越大遮蔽越彻底。\n笔刷直径用左侧滑杆或滚轮调整。")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(width: 208)
    }

    // MARK: 历史

    private var historyCluster: some View {
        HStack(spacing: 1) {
            ToolIconButton(symbol: "arrow.uturn.backward",
                           enabled: model.canUndo, help: "撤销  ⌘Z", action: onUndo)
            ToolIconButton(symbol: "arrow.uturn.forward",
                           enabled: model.canRedo, help: "重做  ⇧⌘Z", action: onRedo)
        }
    }

    // MARK: 主操作

    private var primaryCluster: some View {
        HStack(spacing: 3) {
            Button(action: onCopy) {
                HStack(spacing: 4) {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 11, weight: .semibold))
                    Text("复制")
                        .font(.system(size: 11.5, weight: .semibold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 11)
                .frame(height: 26)
                .background(Capsule().fill(Theme.accent))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .focusable(false)
            .help("复制到剪贴板  ⌘C")
            .accessibilityLabel("复制到剪贴板")

            ToolIconButton(symbol: "square.and.arrow.down", help: "保存  ⌘S", action: onSave)

            Menu {
                Button("长截图") { onLong() }
                Divider()
                Button("清空全部标注", role: .destructive) { onClear() }
                    .disabled(!model.canUndo && !model.canRedo)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 12.5, weight: .medium))
                    .frame(width: 28, height: 28)
                    .foregroundStyle(Color.primary.opacity(0.8))
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("更多")

            ToolIconButton(symbol: "xmark", help: "关闭  Esc", action: onClose)
        }
    }

    // MARK: 基础件

    private var separator: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.14))
            .frame(width: 0.5, height: 18)
    }

    private func isSameColor(_ a: Color, _ b: Color) -> Bool {
        let na = NSColor(a).usingColorSpace(.sRGB)
        let nb = NSColor(b).usingColorSpace(.sRGB)
        guard let na, let nb else { return false }
        return abs(na.redComponent - nb.redComponent) < 0.02
            && abs(na.greenComponent - nb.greenComponent) < 0.02
            && abs(na.blueComponent - nb.blueComponent) < 0.02
    }
}

// MARK: - 工具条图标按钮

/// 图标按钮：选中态强调色、悬停浅底、禁用降透明度；默认 28×28 命中区，
/// 竖排工具栏按 `dimension` 传入自己的边长。
struct ToolIconButton: View {
    let symbol: String
    var selected: Bool = false
    var enabled: Bool = true
    var dimension: CGFloat = 28
    let help: String
    let action: () -> Void

    @Stored private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12.5, weight: .medium))
                .frame(width: dimension, height: dimension)
                .foregroundStyle(selected ? Theme.accent
                                 : Color.primary.opacity(enabled ? 0.82 : 0.30))
                .background(
                    RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                        .fill(selected ? Theme.accent.opacity(0.14)
                              : (hovering && enabled ? Color.primary.opacity(0.06) : Color.clear))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .disabled(!enabled)
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}
