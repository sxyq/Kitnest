import AppKit
import Combine
import ImageIO
import SwiftUI

struct AppearanceSettingsEditor<Content: View>: View {
    let scope: PersonalizationSettingsPart
    let content: (AppearanceSettingsDraft) -> Content

    init(scope: PersonalizationSettingsPart, @ViewBuilder content: @escaping (AppearanceSettingsDraft) -> Content) {
        self.scope = scope
        self.content = content
    }

    var body: some View {
        SettingsDraftEditor(id: scope.draftID, makeDraft: { AppearanceSettingsDraft(scope: scope) }) { draft in
            content(draft).onAppear { draft.refreshUnownedValues() }
        }
    }
}

/// 用户要求「用真实组件，一个模块只能有一个预览」：按实际消费点归属设置。
enum PersonalizationSettingsPart: String, CaseIterable {
    case mainPanel        // 主面板：宽度 / 悬停 / 页面顺序
    case textAndRadius
    case panelBackground
    case floatingWindow   // 全局窗口材质、玻璃四参数与动效
    case floatingClipboard
    case clipboardAppearance
    case notification
    case captureToolbar
    case shared           // 主题外观与恢复全部默认

    var draftID: String { "appearance.\(rawValue)" }

    var personalizationFields: [Personalization.DraftField] {
        switch self {
        case .mainPanel:
            return [.init(\.hoverPreviewEnabled, key: "ui.hoverPreviewEnabled")]
        case .textAndRadius:
            return [.init(\.fontScale, key: Preferences.Keys.uiFontScale),
                    .init(\.cornerRadius, key: Preferences.Keys.uiCornerRadius)]
        case .panelBackground:
            return [.init(\.backgroundImagePath, key: Preferences.Keys.uiBackgroundImage),
                    .init(\.backgroundImageDim, key: Preferences.Keys.uiBackgroundDim)]
        case .floatingWindow:
            return [.init(\.material, key: Preferences.Keys.uiPanelMaterial),
                    .init(\.openAnimation, key: Preferences.Keys.uiOpenAnimation),
                    .init(\.glassOpacity, key: Preferences.Keys.uiGlassOpacity),
                    .init(\.glassBlur, key: Preferences.Keys.uiGlassBlur),
                    .init(\.glassCardLift, key: Preferences.Keys.uiGlassCardLift),
                    .init(\.glassStroke, key: Preferences.Keys.uiGlassStroke)]
        case .clipboardAppearance:
            return [.init(\.density, key: Preferences.Keys.uiListDensity),
                    .init(\.thumbOverride, key: Preferences.Keys.uiThumbSize),
                    .init(\.clipboardPreviewScale, key: Preferences.Keys.uiClipboardPreviewScale),
                    .init(\.showSourceBadge, key: Preferences.Keys.uiSourceBadge)]
        case .notification:
            return [.init(\.toastDuration, key: Preferences.Keys.uiToastDuration),
                    .init(\.toastFollowPanel, key: Preferences.Keys.uiToastPosition)]
        case .shared:
            return [.init(\.accentColorHex, key: Preferences.Keys.uiAccentColor),
                    .init(\.midnightHueShift, key: Preferences.Keys.uiMidnightHue)]
        case .floatingClipboard, .captureToolbar: return []
        }
    }
}

struct PersonalizationSettingsView: View {
    let part: PersonalizationSettingsPart
    @ObservedObject var draft: AppearanceSettingsDraft
    var compact = false
    @ObservedObject private var p: Personalization
    @EnvironmentObject private var session: SettingsEditingSession
    /// 正在拖的分段（nil = 没在拖）
    @Stored private var draggingSegment: PanelCenterPage?

    init(part: PersonalizationSettingsPart, draft: AppearanceSettingsDraft, compact: Bool = false) {
        self.part = part
        self.draft = draft
        self.compact = compact
        self.p = draft.personalization
    }

    var body: some View {
        Group {
            switch part {
            case .mainPanel:      mainPanelRows
            case .textAndRadius:
                VStack(alignment: .leading, spacing: 10) { fontScaleRow; cornerRow }
            case .panelBackground: backgroundImageRow
            case .floatingWindow: floatingWindowRows
            case .floatingClipboard: EmptyView()
            case .clipboardAppearance: clipboardRows
            case .notification: toastRow
            case .captureToolbar: toolbarStyleRow
            case .shared:         sharedRows
            }
        }
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 主面板布局与页面。
    private var mainPanelRows: some View {
        VStack(alignment: .leading, spacing: 10) {
            widthRow
            Divider().opacity(0.5)
            settingRow("悬停预览") {
                Toggle("悬停剪贴板记录时显示详情", isOn: $p.hoverPreviewEnabled)
                    .toggleStyle(.checkbox).font(.system(size: 12))
            }
            Divider().opacity(0.5)
            panelPagesRow
        }
    }

    /// 独立窗口与浮层：玻璃四参数 / 列表密度 / 缩略图 / 来源徽章 / 通知条
    private var floatingWindowRows: some View {
        VStack(alignment: .leading, spacing: 10) {
            glassRow
            Divider().opacity(0.5)
            materialRow
            animationRow
        }
    }

    private var clipboardRows: some View {
        VStack(alignment: .leading, spacing: 10) {
            densityRow
            Divider().opacity(0.5)
            thumbRow
            Divider().opacity(0.5)
            previewFontScaleRow
            Divider().opacity(0.5)
            badgeRow
        }
    }

    /// 共用外观：强调色 / Midnight 色相 / 恢复默认。
    private var sharedRows: some View {
        VStack(alignment: .leading, spacing: 10) {
            accentRow
            Divider().opacity(0.5)
            midnightHueRow
            Divider().opacity(0.5)
            resetRow
        }
    }

    /// 主面板顶部页面（v177）：勾掉的分段不出现，对应视图也不会创建。
    /// v181：同一块里拖拽排序——顶部顺序 = 这里的顺序，第一项是当前页被关掉时的回退页。
    private var panelPagesRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            settingRow("主面板页面") {
                VStack(alignment: .trailing, spacing: 6) {
                    ForEach(Array(draft.pageOrder.enumerated()), id: \.element) { index, page in
                        segmentOrderRow(page, index: index)
                    }
                    Button {
                        draft.pageOrder = PanelSegments.defaultOrder
                    } label: {
                        Text("恢复默认顺序")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.link)
                    .disabled(draft.pageOrder == PanelSegments.defaultOrder)
                }
                .frame(width: 210)
            }
        }
    }

    /// 一行：拖拽把手 + 勾选 + 名称 +（第一项标「回退页」）
    private func segmentOrderRow(_ page: PanelCenterPage, index: Int) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Theme.tertiaryText)
                .frame(width: 12, height: 18)
                .contentShape(Rectangle())
                .onDrag {
                    draggingSegment = page
                    return NSItemProvider(object: page.rawValue as NSString)
                }
                .help("拖动调整顺序")
            Toggle(PanelSegments.fullTitle(page), isOn: binding(for: page))
                .toggleStyle(.checkbox)
                .font(.system(size: 12))
            Spacer(minLength: 4)
            if index == 0 {
                Text("回退页")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.tertiaryText)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 26)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                .fill(draggingSegment == page ? Theme.accent.opacity(0.10)
                                               : Theme.cardFill)
        )
        .opacity(draggingSegment == page ? 0.6 : 1)
        .onDrop(of: [.text], delegate: SegmentDropDelegate(
            target: page, order: $draft.pageOrder, dragging: $draggingSegment))
    }

    private func binding(for page: PanelCenterPage) -> Binding<Bool> {
        switch page {
        case .home:        return $draft.segmentHome
        case .performance: return $draft.segmentMonitor
        }
    }

    // MARK: P0

    /// 强调色：6 预设 + 自定义取色（空 = 跟随系统）
    private var accentRow: some View {
        settingRow("强调色") {
            HStack(spacing: 8) {
                ForEach(Personalization.accentPresets, id: \.hex) { preset in
                    Button {
                        p.accentColorHex = preset.hex
                    } label: {
                        Circle()
                            .fill(Self.presetColor(preset.hex))
                            .frame(width: 18, height: 18)
                            .overlay(
                                Circle().stroke(
                                    p.accentColorHex == preset.hex ? Color.primary : Color.clear,
                                    lineWidth: 2)
                            )
                    }
                    .buttonStyle(.plain)
                    .help(preset.name)
                }
                ColorPicker("", selection: Binding(
                    get: { p.accentColor ?? Self.presetColor("0A66FF") },
                    set: { p.accentColorHex = Personalization.hex(fromColor: $0) }
                ), supportsOpacity: false)
                .labelsHidden()
                .controlSize(.small)
                if p.accentColor != nil {
                    Button("跟随系统") { p.accentColor = nil }
                        .buttonStyle(.link)
                        .font(.system(size: 11))
                }
            }
        }
    }

    /// 界面字号缩放（只作用主面板；窗口宽高联动）
    private var fontScaleRow: some View {
        settingRow("界面字号") {
            Picker("", selection: $p.fontScale) {
                Text("小 0.9").tag(CGFloat(0.9))
                Text("标准 1.0").tag(CGFloat(1.0))
                Text("大 1.1").tag(CGFloat(1.1))
                Text("特大 1.25").tag(CGFloat(1.25))
            }
            .pickerStyle(.segmented)
            .frame(width: 250)
            .labelsHidden()
        }
    }

    /// 列表密度（剪贴板行高 + 缩略图联动）
    private var densityRow: some View {
        settingRow("列表密度") {
            Picker("", selection: $p.density) {
                ForEach(PersonalizationDensity.allCases) { d in
                    Text(d.title).tag(d)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: compact ? 230 : 250)
            .labelsHidden()
        }
    }

    /// 剪贴板预览正文独立字号，不改变列表行和窗口标题。
    /// v269：再放大一档（100/125/160/200，默认 160）——用户「预览文字再放大一点」。
    private var previewFontScaleRow: some View {
        settingRow("预览字号") {
            Picker("", selection: $p.clipboardPreviewScale) {
                Text("100%").tag(CGFloat(1.0))
                Text("125%").tag(CGFloat(1.25))
                Text("160%").tag(CGFloat(1.6))
                Text("200%").tag(CGFloat(2.0))
            }
            .pickerStyle(.segmented)
            .frame(width: compact ? 210 : 230)
            .labelsHidden()
        }
    }

    /// 面板圆角
    private var cornerRow: some View {
        settingRow("面板圆角") {
            Picker("", selection: $p.cornerRadius) {
                Text("6pt").tag(CGFloat(6))
                Text("10pt").tag(CGFloat(10))
                Text("14pt").tag(CGFloat(14))
            }
            .pickerStyle(.segmented)
            .frame(width: 250)
            .labelsHidden()
        }
    }

    /// 打开动画
    private var animationRow: some View {
        VStack(alignment: .leading, spacing: 3) {
            settingRow("打开动画") {
                Picker("", selection: $p.openAnimation) {
                    ForEach(PersonalizationOpenAnimation.allCases) { a in
                        Text(a.title).tag(a)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 250)
                .labelsHidden()
            }
        }
    }

    /// 框选动作条样式（v219）
    ///
    /// 用户：「这三种方案都要。在设置里面……把当前的这个选项放在个性化设置里面」。
    /// 选择器更新草稿；正式动作条预览直接展示三种排布。
    private var toolbarStyleRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            settingRow("截图动作条") {
                Picker("", selection: $draft.toolbarStyle) {
                    ForEach(CaptureToolbarStyle.allCases) { style in
                        Text(style.title).tag(style.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: compact ? 250 : 300)
            }
        }
    }


    /// 面板默认宽度：只写草稿。
    private var widthRow: some View {
        settingRow("面板宽度") {
            HStack(spacing: 8) {
                Picker("", selection: $draft.panelWidth) {
                    Text("360").tag(Double(360))
                    Text("400").tag(Double(400))
                    Text("440").tag(Double(440))
                }
                .pickerStyle(.segmented)
                .frame(width: 190)
                .labelsHidden()
                Button("重置") { draft.panelWidth = 400 }
                    .buttonStyle(.link)
                    .font(.system(size: 11))
            }
        }
    }

    // MARK: P1

    /// 面板背景材质
    private var materialRow: some View {
        settingRow("背景材质") {
            Picker("", selection: $p.material) {
                ForEach(PersonalizationMaterial.allCases) { m in
                    Text(m.title).tag(m)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 250)
            .labelsHidden()
        }
    }

    /// 来源应用徽章
    private var badgeRow: some View {
        settingRow("来源徽章") {
            Toggle("剪贴板行显示来源应用徽章", isOn: $p.showSourceBadge)
                .toggleStyle(.checkbox)
                .font(.system(size: 12))
        }
    }

    /// 缩略图大小（覆盖档位优先于密度联动）
    private var thumbRow: some View {
        settingRow("缩略图") {
            Picker("", selection: Binding(
                get: { p.thumbOverride ?? 0 },
                set: { p.thumbOverride = $0 == 0 ? nil : $0 }
            )) {
                Text("随密度").tag(CGFloat(0))
                Text("44").tag(CGFloat(44))
                Text("56").tag(CGFloat(56))
                Text("72").tag(CGFloat(72))
            }
            .pickerStyle(.segmented)
            .frame(width: compact ? 230 : 250)
            .labelsHidden()
        }
    }

    /// 通知条：时长 + 定位
    private var toastRow: some View {
        settingRow("通知条") {
            if compact {
                VStack(spacing: 6) {
                    Picker("", selection: $p.toastDuration) {
                        Text("2 秒").tag(TimeInterval(2))
                        Text("3 秒").tag(TimeInterval(3))
                        Text("5 秒").tag(TimeInterval(5))
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    Picker("", selection: $p.toastFollowPanel) {
                        Text("跟随主面板").tag(true)
                        Text("屏幕中线偏下").tag(false)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
            } else {
                HStack(spacing: 10) {
                    Picker("", selection: $p.toastDuration) {
                        Text("2 秒").tag(TimeInterval(2))
                        Text("3 秒").tag(TimeInterval(3))
                        Text("5 秒").tag(TimeInterval(5))
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 150)
                    .labelsHidden()
                    Picker("", selection: $p.toastFollowPanel) {
                        Text("跟随主面板").tag(true)
                        Text("屏幕中线偏下").tag(false)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 180)
                    .labelsHidden()
                }
            }
        }
    }

    // MARK: 玻璃质感（v193）

    /// 玻璃质感滑块组
    ///
    /// 用户：「设置里面添加相关的按钮去调节玻璃的一个通透质感以及相关的参数，
    /// 弄成几个可以滑动的这种类似于音量条的这种。放在个性化里面」。
    ///
    /// 四个滑块只更新草稿与预览：
    ///   通透度 → Theme.windowSurface 的 alpha
    ///   磨砂   → Theme.glassFrost（霜感层）
    ///   卡片亮度 → Theme.cardFill 的 alpha（卡片与窗口底的明度台阶）
    ///   描边   → Theme.cardStroke 的 alpha
    ///
    /// 预览读取草稿；正式窗口在保存后读取应用值。
    private var glassRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("玻璃质感")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Button("恢复默认") { resetGlass() }
                    .buttonStyle(.link)
                    .font(.system(size: 11))
            }

            glassSlider("底衬不透明度", value: $p.glassOpacity, range: 0.55...1.0) {
                String(format: "%.0f%%", $0 * 100)
            }
            glassSlider("磨砂", value: $p.glassBlur, range: 0...1) {
                String(format: "%.0f%%", $0 * 100)
            }
            glassSlider("卡片亮度", value: $p.glassCardLift, range: 0...1) {
                String(format: "%.0f%%", $0 * 100)
            }
            glassSlider("描边", value: $p.glassStroke, range: 0...1) {
                String(format: "%.0f%%", $0 * 100)
            }

        }
    }

    /// 一条滑块（音量条样式：标签 + 滑杆 + 数值）
    @ViewBuilder private func glassSlider(_ title: String,
                                          value: Binding<Double>,
                                          range: ClosedRange<Double>,
                                          format: @escaping (Double) -> String) -> some View {
        if compact {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(title)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    Text(format(value.wrappedValue))
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Slider(value: value, in: range)
                    .frame(maxWidth: .infinity)
            }
        } else {
            HStack(spacing: 8) {
                Text(title)
                    .font(.system(size: 11))
                    .frame(width: 96, alignment: .leading)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 12)
                Slider(value: value, in: range)
                    .frame(width: 190)
                Text(format(value.wrappedValue))
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 40, alignment: .leading)
            }
        }
    }

    private func resetGlass() {
        // v205：恢复默认 = 天气 App 同款玻璃观感
        p.glassOpacity = 0.60
        p.glassBlur = 0.30
        p.glassCardLift = 0.55
        p.glassStroke = 0.30
    }

    // MARK: P2

    /// Midnight 色相偏移
    private var midnightHueRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            settingRow("Midnight 色相") {
                HStack(spacing: 8) {
                    Slider(value: $p.midnightHueShift, in: -30...30) { Text("色相") }
                        .frame(width: 180)
                    Text(String(format: "%+.0f°", p.midnightHueShift))
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 40, alignment: .leading)
                }
            }
        }
    }

    /// 面板背景图 + 遮罩
    private var backgroundImageRow: some View {
        settingRow("面板背景图") {
            HStack(spacing: 8) {
                Button(p.backgroundImagePath.isEmpty ? "选择图片…" : "重新选择…") {
                    pickBackgroundImage()
                }
                .buttonStyle(.link)
                .font(.system(size: 11))
                if !p.backgroundImagePath.isEmpty {
                    Button("移除") { p.backgroundImagePath = "" }
                        .buttonStyle(.link)
                        .font(.system(size: 11))
                    Slider(value: $p.backgroundImageDim, in: 0...0.8) { Text("遮罩") }
                        .frame(width: 110)
                }
            }
        }
    }

    /// 恢复默认：页脚动作，整行居中，不和上面的设置行混在一起。
    private var resetRow: some View {
        HStack {
            Spacer()
            Button("恢复全部个性化默认") { session.restoreAllDefaults() }
                .buttonStyle(.link)
                .font(.system(size: 11))
            Spacer()
        }
        .padding(.vertical, 2)
    }

    // MARK: 骨架

    @ViewBuilder private func settingRow(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        if compact {
            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                content()
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        } else {
            // 统一的两列：标签贴左、控件贴右。以前 content 后面才放 Spacer，
            // 控件会紧贴标签、右边留一大片空，和「外观」那种右对齐行对不上。
            HStack(alignment: .center, spacing: 12) {
                Text(title)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(width: 96, alignment: .leading)
                Spacer(minLength: 12)
                content()
            }
        }
    }

    private static func presetColor(_ hex: String) -> Color {
        Personalization.color(fromHex: hex) ?? .accentColor
    }

    /// 背景图选择（NSOpenPanel；复制到应用支持目录由消费侧处理）
    private func pickBackgroundImage() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.png, .jpeg, .heic]
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            p.backgroundImagePath = url.path
        }
    }
}

