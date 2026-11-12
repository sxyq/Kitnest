import AppKit
import Combine
import SwiftUI

// MARK: - 外观草稿：控件只更新预览，保存才应用到正式窗口。

final class AppearanceSettingsDraft: ObservableObject {
    @Published var personalization = Personalization.shared.makeDraft() {
        didSet { observeChanges(); previewRevision &+= 1 }
    }
    @Published var panelWidth = Preferences.shared.value(Preferences.Keys.panelWidth, default: 400.0) {
        didSet { previewRevision &+= 1 }
    }
    @Published var toolbarStyle = CaptureToolbarStyle.current.rawValue {
        didSet { previewRevision &+= 1 }
    }
    @Published var appearance = AppearanceManager.shared.mode {
        didSet { previewRevision &+= 1 }
    }
    @Published var segmentHome = Preferences.shared.value(PanelSegments.homeKey, default: true) {
        didSet { previewRevision &+= 1 }
    }
    @Published var segmentMonitor = Preferences.shared.value(PanelSegments.monitorKey, default: true) {
        didSet { previewRevision &+= 1 }
    }
    @Published var segmentTransfer = Preferences.shared.value(PanelSegments.transferKey, default: false) {
        didSet { previewRevision &+= 1 }
    }
    @Published var segmentCast = Preferences.shared.value(PanelSegments.castKey, default: false) {
        didSet { previewRevision &+= 1 }
    }
    @Published var pageOrder = PanelSegments.order {
        didSet { previewRevision &+= 1 }
    }
    @Published var floating = FloatingClipDeskStore(settingsPreview: true) {
        didSet { observeChanges(); previewRevision &+= 1 }
    }
    @Published private(set) var previewRevision = 0
    private var observation: AnyCancellable?

    init() { observeChanges() }

    private func observeChanges() {
        observation = personalization.objectWillChange.merge(with: floating.objectWillChange)
            .sink { [weak self] _ in self?.previewRevision &+= 1 }
    }

    var previewPages: [PanelCenterPage] {
        pageOrder.filter {
            switch $0 {
            case .home: return segmentHome
            case .performance: return segmentMonitor
            case .transfer: return segmentTransfer
            case .cast: return segmentCast
            }
        }
    }

    func save() {
        let preferences = Preferences.shared
        preferences.set(Preferences.Keys.panelWidth, panelWidth)
        preferences.set(CaptureToolbarStyle.preferenceKey, toolbarStyle)
        preferences.set(PanelSegments.homeKey, segmentHome)
        preferences.set(PanelSegments.monitorKey, segmentMonitor)
        preferences.set(PanelSegments.transferKey, segmentTransfer)
        preferences.set(PanelSegments.castKey, segmentCast)
        PanelSegments.order = pageOrder
        Personalization.shared.applyDraft(personalization)
        AppearanceManager.shared.apply(appearance)
        let applied = FloatingClipDeskStore.shared
        applied.layout = floating.layout
        applied.cardSize = floating.cardSize
        applied.splitRatio = floating.splitRatio
        applied.persistSplitRatio()
    }

    func discard() {
        personalization = Personalization.shared.makeDraft()
        panelWidth = Preferences.shared.value(Preferences.Keys.panelWidth, default: 400.0)
        toolbarStyle = CaptureToolbarStyle.current.rawValue
        appearance = AppearanceManager.shared.mode
        segmentHome = Preferences.shared.value(PanelSegments.homeKey, default: true)
        segmentMonitor = Preferences.shared.value(PanelSegments.monitorKey, default: true)
        segmentTransfer = Preferences.shared.value(PanelSegments.transferKey, default: false)
        segmentCast = Preferences.shared.value(PanelSegments.castKey, default: false)
        pageOrder = PanelSegments.order
        floating = FloatingClipDeskStore(settingsPreview: true)
    }
}

struct AppearanceSettingsEditor<Content: View>: View {
    @StateObject private var draft = AppearanceSettingsDraft()
    let content: (AppearanceSettingsDraft) -> Content

    init(@ViewBuilder content: @escaping (AppearanceSettingsDraft) -> Content) {
        self.content = content
    }

    var body: some View {
        VStack(spacing: 16) {
            content(draft)
            Divider()
            HStack {
                Text("预览实时更新 · 保存后生效")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Button("取消") { draft.discard() }
                Button("保存并应用") {
                    draft.save()
                    Toast.show("已保存外观", icon: "checkmark")
                }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut("s", modifiers: .command)
            }
        }
    }
}

/// 用户要求「用真实组件，一个模块只能有一个预览」：按实际消费点归属设置。
enum PersonalizationSettingsPart {
    case mainPanel        // 主面板：字号 / 圆角 / 宽度 / 动画 / 背景 / 页面顺序
    case floatingWindow   // 全局窗口材质与玻璃四参数
    case clipboardAppearance
    case notification
    case captureToolbar
    case shared           // 主题外观与恢复全部默认
}

struct PersonalizationSettingsView: View {
    let part: PersonalizationSettingsPart
    @ObservedObject var draft: AppearanceSettingsDraft
    @ObservedObject private var p: Personalization
    /// 正在拖的分段（nil = 没在拖）
    @Stored private var draggingSegment: PanelCenterPage?

    init(part: PersonalizationSettingsPart, draft: AppearanceSettingsDraft) {
        self.part = part
        self.draft = draft
        self.p = draft.personalization
    }

    var body: some View {
        Group {
            switch part {
            case .mainPanel:      mainPanelRows
            case .floatingWindow: floatingWindowRows
            case .clipboardAppearance: clipboardRows
            case .notification: toastRow
            case .captureToolbar: toolbarStyleRow
            case .shared:         sharedRows
            }
        }
        .padding(.vertical, 4)
    }

    /// 主面板：字号 / 圆角 / 宽度 / 材质 / 页面顺序
    private var mainPanelRows: some View {
        VStack(alignment: .leading, spacing: 10) {
            fontScaleRow
            cornerRow
            widthRow
            Divider().opacity(0.5)
            animationRow
            backgroundImageRow
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
        }
    }

    private var clipboardRows: some View {
        VStack(alignment: .leading, spacing: 10) {
            densityRow
            thumbRow
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
            Text("拖动左侧「≡」调整顶部顺序；勾掉的分段不出现，也不会创建对应视图——不占内存。"
                 + "全部关闭时面板只显示一句提示。中转/投屏还要「常规 → 功能 → 文件中转」"
                 + "与「设置 → 文件中转 → 启用文件中转」都开启才会出现。")
                .font(.system(size: 11))
                .foregroundStyle(Theme.tertiaryText)
                .fixedSize(horizontal: false, vertical: true)
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
            .frame(width: 250)
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
            Text("切换后预览重播开合；保存后应用于窗口动画。")
                .font(.system(size: 10))
                .foregroundStyle(Theme.tertiaryText)
                .fixedSize(horizontal: false, vertical: true)
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
                .frame(width: 300)
            }
            Text("框选完成后弹出的小面板。三种排布的功能完全一样，只是紧凑程度和子项展开方式不同；"
                 + "预览实时切换，保存后用于下一次框选。")
                .font(.system(size: 11))
                .foregroundStyle(Theme.tertiaryText)
                .fixedSize(horizontal: false, vertical: true)
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
            .frame(width: 250)
            .labelsHidden()
        }
    }

    /// 通知条：时长 + 定位
    private var toastRow: some View {
        settingRow("通知条") {
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

            glassSlider("通透度", value: $p.glassOpacity, range: 0.55...1.0) {
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

            Text("通透度决定玻璃面底衬的不透明度（越小越透出桌面）；磨砂是底衬之上的霜感；"
                 + "卡片亮度是卡片与窗口底之间的明度台阶（层与层的距离）；"
                 + "描边是玻璃边缘那圈发丝亮边。")
                .font(.system(size: 11))
                .foregroundStyle(Theme.tertiaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// 一条滑块（音量条样式：标签 + 滑杆 + 数值）
    private func glassSlider(_ title: String,
                             value: Binding<Double>,
                             range: ClosedRange<Double>,
                             format: @escaping (Double) -> String) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 11))
                .frame(width: 54, alignment: .leading)
                .foregroundStyle(.secondary)
            Slider(value: value, in: range)
                .frame(width: 190)
            Text(format(value.wrappedValue))
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 40, alignment: .leading)
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
        settingRow("Midnight 色相") {
            HStack(spacing: 8) {
                Slider(value: $p.midnightHueShift, in: -30...30) { Text("色相") }
                    .frame(width: 180)
                Text(String(format: "%+.0f", p.midnightHueShift))
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 40, alignment: .leading)
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

    /// 恢复默认
    private var resetRow: some View {
        settingRow("") {
            Button("恢复全部默认") { p.resetAll() }
            .buttonStyle(.link)
            .font(.system(size: 11))
        }
    }

    // MARK: 骨架

    private func settingRow(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Text(title)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 96, alignment: .leading)
            content()
            Spacer(minLength: 0)
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

struct AppearancePreviewBlock: View {
    enum Scope { case mainPanel, floatingWindow, clipboard, clipboardList, captureToolbar, notification }
    let scope: Scope
    @ObservedObject var draft: AppearanceSettingsDraft

    private var p: Personalization { draft.personalization }
    private var theme: ThemeAppearance {
        ThemeAppearance(personalization: p, isMidnight: draft.appearance == .midnight)
    }
    @Stored private var wallpaper: NSImage?
    @Stored private var availableWidth: CGFloat = 520
    @StateObject private var presentation = PanelPresentationState()
    @StateObject private var toolbarModel = CaptureToolbarModel()
    @StateObject private var toastState = MenuBarToastAnimationState()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Stored private var toastReplay = 0
    @Stored private var openReplay = 0
    @Stored private var revealed = false

    private static let previewItems: [ClipboardItem] = [
        ClipboardItem(id: "appearance-note", type: .text,
                      content: "周五交付\n整理截图、核对文案，再发给同事。", title: "周五交付",
                      sourceApp: "com.apple.Notes", dedupeKey: "appearance-note"),
        ClipboardItem(id: "appearance-link", type: .url,
                      content: "https://developer.apple.com/design/", title: "Apple 设计资源",
                      timestamp: Date().addingTimeInterval(-120), sourceApp: "com.apple.Safari",
                      dedupeKey: "appearance-link"),
        ClipboardItem(id: "appearance-code", type: .text,
                      content: "{\"title\": \"项目笔记\", \"ready\": true}", title: "项目笔记.json",
                      timestamp: Date().addingTimeInterval(-300), sourceApp: "com.apple.TextEdit",
                      dedupeKey: "appearance-code")
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("效果预览").font(.system(size: 12, weight: .semibold))
                Spacer()
                Button("重播") {
                    if scope == .notification { toastReplay &+= 1 }
                    else { openReplay &+= 1 }
                }.buttonStyle(.link)
                Text("模拟数据 · 外观实时更新").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            GeometryReader { geo in
                let size = previewSize
                let scale = min(1, min((geo.size.width - 28) / size.width, 280 / size.height))
                HStack(spacing: 0) {
                    Spacer(minLength: 0)
                    previewContent
                        .id(draft.previewRevision)
                        .frame(width: size.width, height: size.height)
                        .environment(\.isSettingsPreview, true)
                        .environment(\.settingsPreviewClipboardItems, Self.previewItems)
                        .environment(\.settingsPreviewPersonalization, p)
                        .environment(\.settingsPreviewIsMidnight, draft.appearance == .midnight)
                        .environment(\.colorScheme, previewColorScheme)
                        .tint(theme.accent)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                        .scaleEffect(scale)
                        .frame(width: size.width * scale, height: size.height * scale)
                        .opacity(revealed ? 1 : 0)
                        .scaleEffect(revealed || reduceMotion ? 1 : 0.90, anchor: .top)
                        .padding(14)
                        .background { wallpaperBackground }
                        .clipShape(RoundedRectangle(cornerRadius: theme.cornerRadius, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: theme.cornerRadius)
                            .strokeBorder(theme.cardStroke, lineWidth: Theme.Stroke.hairline))
                    Spacer(minLength: 0)
                }
                .onAppear { availableWidth = geo.size.width }
                .onChange(of: geo.size.width) { availableWidth = $0 }
            }
            .frame(height: canvasHeight)
            Text(caption).font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .onAppear {
            reloadWallpaper()
            toolbarModel.style = CaptureToolbarStyle(rawValue: draft.toolbarStyle)!
            toastState.message = "操作完成"
            toastState.icon = "checkmark"
        }
        .onChange(of: draft.toolbarStyle) { style in
            toolbarModel.style = CaptureToolbarStyle(rawValue: style)!
        }
        .onChange(of: p.openAnimation) { _ in openReplay &+= 1 }
        .onChange(of: p.toastDuration) { _ in toastReplay &+= 1 }
        .onChange(of: p.toastFollowPanel) { _ in toastReplay &+= 1 }
        .animation(reduceMotion ? nil : Theme.Motion.fast, value: draft.panelWidth)
        .animation(reduceMotion ? nil : Theme.Motion.fast, value: draft.toolbarStyle)
        .task(id: openReplay) { @MainActor in
            let duration = p.openAnimation.duration
            withAnimation(reduceMotion ? nil : .easeIn(duration: duration)) { revealed = false }
            if !reduceMotion {
                do { try await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000)) }
                catch { return }
            }
            withAnimation(reduceMotion ? nil : .easeOut(duration: duration)) { revealed = true }
        }
        .task(id: toastReplay) { @MainActor in
            if scope != .notification { return }
            toastState.isVisible = false
            await Task.yield()
            withAnimation(reduceMotion ? nil : Theme.Motion.springBouncy) { toastState.isVisible = true }
            do { try await Task.sleep(nanoseconds: UInt64(p.toastDuration * 1_000_000_000)) }
            catch { return }
            withAnimation(reduceMotion ? nil : Theme.Motion.springBouncy) { toastState.isVisible = false }
        }
    }

    private var caption: String {
        switch scope {
        case .mainPanel: return "固定模拟记录，不读取或写入真实剪贴板。"
        case .floatingWindow: return "窗口共用这套材质，使用性能监测界面展示效果。"
        case .clipboard: return "固定模拟记录；展示草稿的布局、卡片和详情。"
        case .clipboardList: return "固定模拟记录；密度、缩略图和徽章按真实界面展示。"
        case .captureToolbar: return "正式动作条组件；这里只演示外观，不执行截图操作。"
        case .notification: return "显示 \(Int(p.toastDuration)) 秒 · \(p.toastFollowPanel ? "跟随主面板" : "屏幕中线偏下")"
        }
    }

    private var canvasHeight: CGFloat {
        previewSize.height * min(1, min((availableWidth - 28) / previewSize.width,
                                       280 / previewSize.height)) + 28
    }

    private var previewColorScheme: ColorScheme {
        switch draft.appearance {
        case .light: return .light
        case .dark, .midnight: return .dark
        case .system:
            return UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark" ? .dark : .light
        }
    }

    private var panelSize: CGSize {
        CGSize(width: CGFloat(draft.panelWidth), height: 480 * p.fontScale)
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
            let store = draft.floating
            let rows = ceil(CGFloat(Self.previewItems.count) / CGFloat(store.cardSize.columns))
            let height = store.layout == .grid ? rows * store.cardSize.minHeight : theme.statsRowHeight * 3
            return CGSize(width: 640, height: max(380, height + 148))
        case .clipboardList:
            return CGSize(width: CGFloat(draft.panelWidth), height: theme.statsRowHeight * 3 + 4)
        case .captureToolbar:
            let size = CaptureActionToolbarPanel.panelSize(
                for: toolbarModel.preview?.cgImage(forProposedRect: nil, context: nil, hints: nil),
                style: CaptureToolbarStyle(rawValue: draft.toolbarStyle)!)
            return CGSize(width: size.width, height: toolbarModel.preview == nil ? 56 : size.height)
        case .notification:
            return CGSize(width: p.toastFollowPanel ? max(panelSize.width, toastSize.width) : toastSize.width,
                          height: p.toastFollowPanel ? panelSize.height + 8 + toastSize.height : toastSize.height + 16)
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
                PreviewWindowChrome().frame(height: 32)
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
                .overlay(alignment: .topLeading) { PreviewWindowChrome().frame(height: 32) }
        case .captureToolbar:
            CaptureActionToolbarView(model: toolbarModel)
        case .clipboardList:
            ClipboardSectionView(personalization: p)
                .background(GlassSurface(cornerRadius: p.cornerRadius))
                .clipShape(RoundedRectangle(cornerRadius: p.cornerRadius))
        case .notification:
            VStack(spacing: 8) {
                if p.toastFollowPanel {
                    PanelRootView(presentation: presentation, onDismiss: {}, onOpenSettings: {},
                                  personalization: p, previewPages: draft.previewPages)
                        .frame(width: panelSize.width, height: panelSize.height)
                        .background(LiquidGlassBackground(cornerRadius: p.cornerRadius))
                        .clipShape(RoundedRectangle(cornerRadius: p.cornerRadius))
                }
                MenuBarToastContentView(state: toastState)
                    .frame(width: toastSize.width, height: toastSize.height)
                    .offset(y: p.toastFollowPanel ? 0 : 8)
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

    private func reloadWallpaper() {
        if let screen = NSScreen.main,
                  let url = NSWorkspace.shared.desktopImageURL(for: screen) {
            wallpaper = NSImage(contentsOf: url)
        } else {
            wallpaper = nil
        }
    }
}

/// 使用 AppKit 的原生窗口按钮，不另画红绿灯。
private struct PreviewWindowChrome: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        for (i, kind) in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].enumerated() {
            if let button = NSWindow.standardWindowButton(kind, for: [.titled, .closable, .miniaturizable, .resizable]) {
                button.setFrameOrigin(NSPoint(x: CGFloat(14 + i * 20), y: 8))
                view.addSubview(button)
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
