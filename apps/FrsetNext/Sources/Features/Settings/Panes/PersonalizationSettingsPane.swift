import AppKit
import Combine
import ImageIO
import SwiftUI

// MARK: - 外观草稿：控件只更新预览，保存才应用到正式窗口。

final class AppearanceSettingsDraft: SettingsEditableDraft {
    let scope: PersonalizationSettingsPart
    @Published var personalization = Personalization.shared.makeDraft() {
        didSet { observeChanges() }
    }
    @Published var panelWidth = Preferences.shared.value(Preferences.Keys.panelWidth, default: 400.0)
    @Published var toolbarStyle = CaptureToolbarStyle.current.rawValue
    @Published var appearance = AppearanceManager.shared.mode
    @Published var segmentHome = Preferences.shared.value(PanelSegments.homeKey, default: true)
    @Published var segmentMonitor = Preferences.shared.value(PanelSegments.monitorKey, default: true)
    @Published var segmentTransfer = Preferences.shared.value(PanelSegments.transferKey, default: false)
    @Published var segmentCast = Preferences.shared.value(PanelSegments.castKey, default: false)
    @Published var pageOrder = PanelSegments.order
    @Published var previewSelectedItemID: String? = "appearance-note"
    @Published var floating = FloatingClipDeskStore(settingsPreview: true) {
        didSet { observeChanges() }
    }
    @Published var floatingFrame: NSRect?
    private var savedPersonalization = Personalization.shared.makeDraft()
    private var savedValues: [String] = []
    private var observation: AnyCancellable?

    init(scope: PersonalizationSettingsPart) {
        self.scope = scope
        savedValues = values
        observeChanges()
    }

    var isDirty: Bool {
        (scope == .floatingClipboard && floatingFrame != nil) || values != savedValues || !scope.personalizationFields.allSatisfy {
            $0.matches(personalization, savedPersonalization)
        }
    }

    private var values: [String] {
        switch scope {
        case .mainPanel:
            return [String(panelWidth), String(segmentHome), String(segmentMonitor),
                    String(segmentTransfer), String(segmentCast), PanelSegments.encode(pageOrder)]
        case .floatingClipboard:
            return [floating.layout.rawValue, floating.cardSize.rawValue, String(Double(floating.splitRatio)),
                    String(floating.hoverPreviewEnabled)]
        case .captureToolbar: return [toolbarStyle]
        case .shared: return [appearance.rawValue]
        default: return []
        }
    }

    private func observeChanges() {
        observation = personalization.objectWillChange.merge(with: floating.objectWillChange)
            .sink { [weak self] _ in self?.objectWillChange.send() }
    }

    var previewPages: [PanelCenterPage] {
        pageOrder.filter {
            switch $0 {
            case .home: return segmentHome
            case .performance:
                return segmentMonitor
            case .transfer, .cast:
                return $0 == .transfer ? segmentTransfer : segmentCast
            }
        }
    }

    func save() -> String? {
        let preferences = Preferences.shared
        switch scope {
        case .mainPanel:
            if values[0] != savedValues[0] { preferences.set(Preferences.Keys.panelWidth, panelWidth) }
            if values[1] != savedValues[1] { preferences.set(PanelSegments.homeKey, segmentHome) }
            if values[2] != savedValues[2] { preferences.set(PanelSegments.monitorKey, segmentMonitor) }
            if values[3] != savedValues[3] { preferences.set(PanelSegments.transferKey, segmentTransfer) }
            if values[4] != savedValues[4] { preferences.set(PanelSegments.castKey, segmentCast) }
            if values[5] != savedValues[5] { PanelSegments.order = pageOrder }
        case .floatingClipboard:
            let applied = FloatingClipDeskStore.shared
            if values[0] != savedValues[0] { applied.layout = floating.layout }
            if values[1] != savedValues[1] { applied.cardSize = floating.cardSize }
            if values[2] != savedValues[2] { applied.splitRatio = floating.splitRatio; applied.persistSplitRatio() }
            if values[3] != savedValues[3] { applied.hoverPreviewEnabled = floating.hoverPreviewEnabled }
            if let frame = floatingFrame {
                FloatingClipboardWindowController.shared.window?.setFrame(frame, display: true)
                FloatingClipboardPinState.shared.save(frame: frame)
            }
        case .captureToolbar:
            if values != savedValues { preferences.set(CaptureToolbarStyle.preferenceKey, toolbarStyle) }
        case .shared:
            if values != savedValues { AppearanceManager.shared.apply(appearance) }
        default: break
        }
        let fields = scope.personalizationFields.filter { !$0.matches(personalization, savedPersonalization) }
        if !fields.isEmpty {
            Personalization.shared.applyDraft(personalization, fields: fields)
        }
        guard UserDefaults.standard.synchronize() else {
            return "外观设置写入磁盘失败，草稿已保留，请重新保存。"
        }
        savedPersonalization = personalization.makeDraft()
        savedValues = values
        floatingFrame = nil
        objectWillChange.send()
        return nil
    }

    func discard() {
        floatingFrame = nil
        reloadSavedValues(preservingOwned: false)
        savedPersonalization = personalization.makeDraft()
        savedValues = values
    }

    func refreshUnownedValues() { reloadSavedValues(preservingOwned: true) }

    private func reloadSavedValues(preservingOwned: Bool) {
        let current = Personalization.shared.makeDraft()
        if preservingOwned {
            for field in scope.personalizationFields { field.copy(current, personalization) }
        }
        // 原地刷新，不换实例：控件在 init 时捕获了 draft.personalization，
        // 换实例会让控件写旧对象、预览读新对象，点击看起来完全没反应。
        personalization.copyValues(from: current)
        if !preservingOwned || scope != .mainPanel {
            panelWidth = Preferences.shared.value(Preferences.Keys.panelWidth, default: 400.0)
            segmentHome = Preferences.shared.value(PanelSegments.homeKey, default: true)
            segmentMonitor = Preferences.shared.value(PanelSegments.monitorKey, default: true)
            segmentTransfer = Preferences.shared.value(PanelSegments.transferKey, default: false)
            segmentCast = Preferences.shared.value(PanelSegments.castKey, default: false)
            pageOrder = PanelSegments.order
        }
        if !preservingOwned || scope != .captureToolbar { toolbarStyle = CaptureToolbarStyle.current.rawValue }
        if !preservingOwned || scope != .shared { appearance = AppearanceManager.shared.mode }
        if !preservingOwned || scope != .floatingClipboard {
            floating.layout = FloatingClipPrefs.layout
            floating.cardSize = FloatingClipPrefs.cardSize
            floating.splitRatio = FloatingClipPrefs.splitRatio
            floating.hoverPreviewEnabled = FloatingClipPrefs.hoverPreviewEnabled
        }
    }

    func restoreDefaults() {
        discard()
        let defaults = Personalization.makeDefaultDraft()
        for field in scope.personalizationFields { field.copy(personalization, defaults) }
        switch scope {
        case .mainPanel:
            panelWidth = 400
            segmentHome = true
            segmentMonitor = true
            segmentTransfer = false
            segmentCast = false
            pageOrder = PanelSegments.defaultOrder
        case .floatingClipboard:
            floating.layout = .grid
            floating.cardSize = .medium
            floating.splitRatio = 0.52
            floating.hoverPreviewEnabled = true
            if let visible = FloatingClipboardWindowController.shared.window?.screen?.visibleFrame ?? NSScreen.main?.visibleFrame {
                var frame = FloatingClipboardPinState.shared.clampedFrame()
                frame.origin = NSPoint(x: visible.midX - frame.width / 2, y: visible.midY - frame.height / 2)
                floatingFrame = frame
            }
        case .captureToolbar: toolbarStyle = CaptureToolbarStyle.pillBar.rawValue
        case .shared: appearance = .system
        default: break
        }
    }
}

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
        case .transfer:    return $draft.segmentTransfer
        case .cast:        return $draft.segmentCast
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

// MARK: - 主面板分段拖拽落位（v181）
//
// 只在「拖到某一行上」时把被拖项挪到该行的位置；松手前就能看到实时重排。
private struct SegmentDropDelegate: DropDelegate {
    let target: PanelCenterPage
    @Binding var order: [PanelCenterPage]
    @Binding var dragging: PanelCenterPage?

    func dropEntered(info: DropInfo) {
        guard let dragging, dragging != target,
              let from = order.firstIndex(of: dragging),
              let to = order.firstIndex(of: target) else { return }
        withAnimation(.easeInOut(duration: 0.16)) {
            order.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        dragging = nil
        return true
    }
}

// MARK: - 设置实时预览：复用正式界面，一页一个对象

/// 固定内容供所有正式预览组件共用；图片只在内存绘制一次。
enum SettingsPreviewSamples {
    static let date = Date(timeIntervalSince1970: 1_793_491_200)
    static let clipboardItems: [ClipboardItem] = [
        ClipboardItem(id: "appearance-note", type: .text,
                      content: "周五交付\n整理截图、核对文案，再发给同事。", title: "周五交付",
                      timestamp: date, sourceApp: "com.apple.Notes", isNote: true, dedupeKey: "appearance-note"),
        ClipboardItem(id: "appearance-link", type: .url,
                      content: "https://developer.apple.com/design/", title: "Apple 设计资源",
                      timestamp: date.addingTimeInterval(-120), sourceApp: "com.apple.Safari",
                      dedupeKey: "appearance-link"),
        ClipboardItem(id: "appearance-file", type: .file,
                      content: "/SettingsPreview/设计说明.pdf", title: "设计说明.pdf", subtitle: "PDF 文档 · 240 KB",
                      timestamp: date.addingTimeInterval(-240), sourceApp: "com.apple.finder",
                      dedupeKey: "appearance-file"),
        ClipboardItem(id: "appearance-image", type: .image,
                      title: "山间日落", subtitle: "320 × 180",
                      timestamp: date.addingTimeInterval(-360), sourceApp: "com.apple.Preview",
                      dedupeKey: "appearance-image"),
        ClipboardItem(id: "appearance-code", type: .text,
                      content: """
                      import SwiftUI

                      struct ProjectNoteView: View {
                          let title = "项目笔记"
                          let tasks = ["整理截图", "完成文案", "交付设计"]

                          var body: some View {
                              VStack(alignment: .leading, spacing: 12) {
                                  Text(title).font(.headline)
                                  ForEach(tasks, id: \\.self) { task in
                                      Label(task, systemImage: "checkmark.circle")
                                  }
                              }
                              .padding(16)
                          }
                      }
                      """, title: "项目笔记.swift",
                      timestamp: date.addingTimeInterval(-480), sourceApp: "com.apple.TextEdit",
                      dedupeKey: "appearance-code"),
        ClipboardItem(id: "appearance-color", type: .text, content: "#7B5CFF", title: "#7B5CFF",
                      timestamp: date.addingTimeInterval(-600), sourceApp: "com.apple.DigitalColorMeter",
                      isGeneratedByTool: true, sourceToolAnalyticsId: "colorpicker", sourceToolKeyword: "colorpicker",
                      dedupeKey: "appearance-color"),
        ClipboardItem(id: "appearance-long", type: .text,
                      content: """
                      项目设计记录：从整理到交付

                      本周的任务是整理一套可以反复阅读的项目资料。短标题用于快速定位，长正文保留背景、讨论过程和最终决定，让接手的人能够理解每一步为什么这样安排。

                      一、信息整理
                      收集已有笔记，按内容用途归类。界面上优先展示标题、来源与摘要；完整内容保持原有段落，不为了放进卡片而删去上下文。阅读时可以滚动，字号变化仍以真实尺寸呈现。

                      二、设计细节
                      同一个按钮在不同页面使用一致名称。颜色、圆角、卡片间距与列表密度分别调整，避免一项变化掩盖另一项。长标题需要自然换行，图片保持比例，代码保留缩进和换行。

                      三、协作流程
                      每个模块保留独立草稿，切换页面时继续上一次编辑。预览选择属于当前窗口，只影响阅读内容；保存后正式界面读取已保存值，取消则重新加载模块配置。

                      四、交付说明
                      文本应让第一次打开资料的人知道当前内容、可执行动作和下一步。结果展示在动作发生的位置，失败原因直接写明，用户可以保留草稿继续编辑。

                      五、阅读体验
                      在紧凑、标准和宽松密度下，正文都应能连续阅读。较小的视口通过真实滚动容纳内容，不能把整张界面缩小后当作字号或密度的效果。图片、笔记和代码也沿用同一组正式组件。

                      交付清单
                      • 项目笔记与设计说明
                      • 图片素材与 Swift 示例
                      • 长正文的完整段落
                      • 保存结果与取消行为说明

                      以上内容仅用于设置窗口中的固定展示，不连接网络、不启动采集，也不写入真实剪贴板或文件。
                      """, title: "项目设计记录：从整理到交付",
                      timestamp: date.addingTimeInterval(-720), sourceApp: "com.apple.TextEdit",
                      dedupeKey: "appearance-long"),
    ]

    static let image: NSImage = {
        let image = NSImage(size: NSSize(width: 320, height: 180))
        image.lockFocus()
        NSColor(srgbRed: 0.25, green: 0.30, blue: 0.58, alpha: 1).setFill()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: 320, height: 180)).fill()
        NSColor(srgbRed: 1, green: 0.73, blue: 0.47, alpha: 1).setFill()
        NSBezierPath(ovalIn: NSRect(x: 222, y: 102, width: 48, height: 48)).fill()
        for (color, points) in [
            (NSColor(srgbRed: 0.35, green: 0.42, blue: 0.62, alpha: 1),
             [NSPoint(x: 0, y: 0), NSPoint(x: 0, y: 74), NSPoint(x: 82, y: 128),
              NSPoint(x: 183, y: 44), NSPoint(x: 254, y: 114), NSPoint(x: 320, y: 55), NSPoint(x: 320, y: 0)]),
            (NSColor(srgbRed: 0.13, green: 0.21, blue: 0.38, alpha: 1),
             [NSPoint(x: 0, y: 0), NSPoint(x: 0, y: 22), NSPoint(x: 130, y: 87),
              NSPoint(x: 242, y: 26), NSPoint(x: 320, y: 62), NSPoint(x: 320, y: 0)]),
        ] {
            color.setFill()
            let mountain = NSBezierPath()
            mountain.move(to: points[0])
            for point in points.dropFirst() { mountain.line(to: point) }
            mountain.close()
            mountain.fill()
        }
        image.unlockFocus()
        return image
    }()
}

struct AppearancePreviewVisibilityKey: PreferenceKey {
    static let defaultValue = true
    static func reduce(value: inout Bool, nextValue: () -> Bool) { value = nextValue() }
}

private enum AppearancePreviewWallpaper {
    private static var cachedURL: URL?
    private static var cachedImage: NSImage?

    static func image() -> NSImage? {
        guard let screen = NSScreen.main,
              let url = NSWorkspace.shared.desktopImageURL(for: screen) else { return nil }
        if cachedURL == url { return cachedImage }
        cachedURL = url
        cachedImage = nil
        if let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
           let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 1024,
                kCGImageSourceShouldCacheImmediately: true,
           ] as CFDictionary) {
            cachedImage = NSImage(cgImage: thumbnail, size: .zero)
        }
        return cachedImage
    }
}

struct AppearancePreviewBlock: View {
    enum Scope { case mainPanel, floatingWindow, clipboard, clipboardList, captureToolbar, notification }
    let scope: Scope
    @ObservedObject var draft: AppearanceSettingsDraft

    private var p: Personalization { draft.personalization }
    private var theme: ThemeAppearance {
        ThemeAppearance(personalization: p, isMidnight: draft.appearance == .midnight)
    }
    @Stored private var wallpaper: NSImage?
    @StateObject private var presentation = PanelPresentationState()
    @StateObject private var toolbarModel = CaptureToolbarModel()
    @StateObject private var toastState = MenuBarToastAnimationState()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.settingsPreviewViewport) private var viewport
    @Stored private var toastReplay = 0
    @Stored private var openReplay = 0
    @Stored private var revealed = true
    @Stored private var isVisible = true
    @Stored private var toolbarFeedback: String?

    private var previewItems: [ClipboardItem] {
        SettingsPreviewSamples.clipboardItems
    }
    private var needsWallpaper: Bool {
        p.material == .vibrancy && !reduceTransparency
    }

    var body: some View {
        SettingsSection("效果预览", alwaysExpanded: true) {
            VStack(alignment: .leading, spacing: 8) {
            GeometryReader { viewport in
                let size = previewSize
                let width = min(size.width, max(0, viewport.size.width - 12))
                // 2026-11-14：正式组件按可用宽度排版，壁纸只沿边保留 6pt，不整窗缩放。
                previewContent
                    .frame(width: width, height: size.height)
                    .environment(\.isSettingsPreview, true)
                    .environment(\.settingsPreviewClipboardItems, previewItems)
                    .environment(\.settingsPreviewImage, SettingsPreviewSamples.image)
                    .environment(\.settingsPreviewClipboardSelection, $draft.previewSelectedItemID)
                    .environment(\.settingsPreviewPersonalization, p)
                    .environment(\.settingsPreviewIsMidnight, draft.appearance == .midnight)
                    .environment(\.colorScheme, previewColorScheme)
                    .tint(theme.accent)
                    .opacity(revealed ? 1 : 0)
                    .offset(y: revealed || reduceMotion ? 0 : -8)
                    .padding(6)
                    .background {
                        if needsWallpaper {
                            wallpaperBackground
                                .frame(width: width + 12, height: size.height + 12)
                                .clipShape(RoundedRectangle(cornerRadius: theme.cornerRadius))
                        }
                    }
                    .frame(width: viewport.size.width, height: size.height + 12, alignment: .leading)
            }
            .frame(height: previewSize.height + 12)
            .background(alignment: .center) {
                GeometryReader { geo in
                    Color.clear.preference(key: AppearancePreviewVisibilityKey.self,
                        value: geo.frame(in: .named("settingsPreviewViewport")).intersects(
                            viewport))
                }
            }
            if scope == .captureToolbar, let toolbarFeedback {
                Text(toolbarFeedback).font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .onPreferenceChange(AppearancePreviewVisibilityKey.self) {
            isVisible = $0
            if !$0 { revealed = true }
        }
        .onAppear {
            if needsWallpaper { wallpaper = AppearancePreviewWallpaper.image() }
            if scope == .captureToolbar {
                toolbarModel.style = CaptureToolbarStyle(rawValue: draft.toolbarStyle)!
                toolbarModel.preview = CaptureAppearanceSample.image
                toolbarModel.isSettingsPreview = true
                toolbarModel.onPreviewFeedback = { toolbarFeedback = $0 }
            }
            if scope == .notification {
                toastState.message = "操作完成"
                toastState.icon = "checkmark"
            }
        }
        .onChange(of: needsWallpaper) { needed in
            wallpaper = needed ? AppearancePreviewWallpaper.image() : nil
        }
        .onChange(of: draft.toolbarStyle) { style in
            if scope == .captureToolbar { toolbarModel.style = CaptureToolbarStyle(rawValue: style)! }
        }
        .onChange(of: p.openAnimation) { _ in
            if scope != .notification { openReplay &+= 1 }
        }
        .onChange(of: p.toastDuration) { _ in
            if scope == .notification { toastReplay &+= 1 }
        }
        .onChange(of: p.toastFollowPanel) { _ in
            if scope == .notification { toastReplay &+= 1 }
        }
        .task(id: "\(openReplay)-\(reduceMotion)") { @MainActor in
            if openReplay == 0 || scope == .notification || !isVisible { return }
            let duration = p.openAnimation.duration
            withAnimation(reduceMotion ? nil : .easeIn(duration: duration)) { revealed = false }
            if !reduceMotion {
                do { try await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000)) }
                catch { return }
            }
            if !isVisible { return }
            withAnimation(reduceMotion ? nil : .easeOut(duration: duration)) { revealed = true }
        }
        .task(id: "\(toastReplay)-\(isVisible)") { @MainActor in
            // v274（用户：「它的这个没有展示它的一个效果」）：预览要连续演示，
            // 不能播一次就只剩壁纸。隐藏后先等一帧真正落地再弹入——false→true
            // 挤在同一帧时 SwiftUI 会合并更新，弹簧 scale 根本看不到。
            // 不按 reduceMotion 降级：正式通知条（Toast.swift）固定走 springBouncy，
            // 预览必须复现真实观感，否则系统开了「减弱动态效果」就永远看不到弹入。
            guard scope == .notification, isVisible else { return }
            toastState.isVisible = false
            do { try await Task.sleep(nanoseconds: 120_000_000) } catch { return }
            while !Task.isCancelled {
                withAnimation(Theme.Motion.springBouncy) {
                    toastState.isVisible = true
                }
                do { try await Task.sleep(nanoseconds: UInt64(p.toastDuration * 1_000_000_000)) }
                catch { return }
                withAnimation(Theme.Motion.springBouncy) {
                    toastState.isVisible = false
                }
                do { try await Task.sleep(nanoseconds: 900_000_000) }
                catch { return }
            }
        }
        .onDisappear {
            toastState.isVisible = false
            revealed = true
            toolbarModel.onPreviewFeedback = nil
            toolbarFeedback = nil
            }
        }
        .id(scope)
    }

    private var previewColorScheme: ColorScheme {
        switch draft.appearance {
        case .light: return .light
        case .dark, .midnight: return .dark
        case .system: return colorScheme
        }
    }

    private var panelSize: CGSize {
        CGSize(width: max(320, CGFloat(draft.panelWidth)), height: 360)
    }

    private var toastSize: CGSize {
        let textWidth = ("操作完成" as NSString).size(withAttributes: [
            .font: NSFont.systemFont(ofSize: 15, weight: .semibold)
        ]).width
        return CGSize(width: textWidth + 120, height: 108)
    }

    private var previewSize: CGSize {
        switch scope {
        case .mainPanel: return panelSize
        case .floatingWindow: return CGSize(width: 520, height: 250)
        case .clipboard:
            return CGSize(width: 620, height: 380)
        case .clipboardList:
            return CGSize(width: max(320, CGFloat(draft.panelWidth)),
                          height: 260)
        case .captureToolbar:
            let size = CaptureActionToolbarPanel.panelSize(
                for: toolbarModel.preview?.cgImage(forProposedRect: nil, context: nil, hints: nil),
                style: CaptureToolbarStyle(rawValue: draft.toolbarStyle)!)
            return CGSize(width: size.width, height: toolbarModel.preview == nil ? 56 : size.height)
        case .notification:
            return CGSize(width: max(panelSize.width, toastSize.width), height: toastSize.height + 36)
        }
    }

    @ViewBuilder private var previewContent: some View {
        switch scope {
        case .mainPanel:
            PanelRootView(presentation: presentation, onDismiss: {}, onOpenSettings: {},
                          personalization: p, previewPages: draft.previewPages)
                .background(LiquidGlassBackground(cornerRadius: p.cornerRadius))
                .clipShape(RoundedRectangle(cornerRadius: p.cornerRadius))
        case .floatingWindow:
            VStack(spacing: 0) {
                PreviewWindowChrome(onPress: { openReplay &+= 1 }).frame(height: 32)
                MonitorNetworkThroughputCard(down: 1_800_000, up: 240_000,
                    downHistory: [200_000, 700_000, 420_000, 1_300_000, 900_000, 1_800_000],
                    upHistory: [100_000, 180_000, 120_000, 320_000, 160_000, 240_000],
                    timeSpan: 60, slots: 6)
                    .padding(10)
            }
            .background(GlassSurface(cornerRadius: p.cornerRadius))
            .clipShape(RoundedRectangle(cornerRadius: p.cornerRadius))
        case .clipboard:
            FloatingClipboardDeskView(store: draft.floating, personalization: p)
                .overlay(alignment: .topLeading) {
                    PreviewWindowChrome(onPress: { openReplay &+= 1 }).frame(height: 32)
                }
        case .captureToolbar:
            CaptureActionToolbarView(model: toolbarModel)
        case .clipboardList:
            ClipboardSectionView(personalization: p)
                .background(GlassSurface(cornerRadius: p.cornerRadius))
                .clipShape(RoundedRectangle(cornerRadius: p.cornerRadius))
        case .notification:
            ZStack(alignment: .top) {
                VStack(spacing: 4) {
                    Text(p.toastFollowPanel ? "主面板下缘" : "屏幕中线")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                    Rectangle().fill(theme.cardStroke).frame(height: 1)
                }
                .padding(.horizontal, 12)
                .padding(.top, p.toastFollowPanel ? 0 : 14)
                MenuBarToastContentView(state: toastState)
                    .frame(width: toastSize.width, height: toastSize.height)
                    .offset(y: p.toastFollowPanel ? 18 : 30)
            }
        }
    }

    @ViewBuilder private var wallpaperBackground: some View {
        if let image = wallpaper {
            Image(nsImage: image).resizable().scaledToFill()
        } else {
            Color(nsColor: .windowBackgroundColor)
        }
    }

}

/// 使用 AppKit 的原生窗口按钮，不另画红绿灯。
private struct PreviewWindowChrome: NSViewRepresentable {
    let onPress: () -> Void

    final class Coordinator: NSObject {
        var onPress: () -> Void
        init(onPress: @escaping () -> Void) { self.onPress = onPress }
        @objc func press(_ sender: NSButton) { onPress() }
    }

    func makeCoordinator() -> Coordinator { Coordinator(onPress: onPress) }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        for (i, kind) in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].enumerated() {
            if let button = NSWindow.standardWindowButton(kind, for: [.titled, .closable, .miniaturizable, .resizable]) {
                button.target = context.coordinator
                button.action = #selector(Coordinator.press(_:))
                button.setFrameOrigin(NSPoint(x: CGFloat(14 + i * 20), y: 8))
                view.addSubview(button)
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) { context.coordinator.onPress = onPress }
}
