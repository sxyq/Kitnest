import AppKit
import SwiftUI
import Combine

enum IslandSettingsPart: String, CaseIterable {
    case activation, peeks, canvas, appearance
}

struct IslandSettingsPane: View {
    var part = IslandSettingsPart.activation
    var body: some View {
        SettingsDraftEditor(id: "island", scope: part.rawValue, makeDraft: { IslandSettingsDraft() }) { draft in
            IslandSettingsContent(draft: draft, part: part)
        }
    }
}

/// 四页使用同一草稿和正式预览；保存只合并当前页实际改变的字段。
final class IslandSettingsDraft: SettingsEditableDraft {
    @Published var configuration: IslandConfiguration {
        didSet {
            if configuration.widgetOrder != oldValue.widgetOrder && configuration.widgetPositions == oldValue.widgetPositions {
                configuration.widgetPositions = nil
            }
            updatePreview()
        }
    }
    private var saved: IslandConfiguration
    private var defaultParts: Set<IslandSettingsPart> = []
    private var previewChanges: AnyCancellable?
    let previewController: IslandController

    init() {
        let configuration = IslandConfiguration.load()
        self.configuration = configuration
        saved = configuration
        previewController = IslandController(configuration: configuration, previewOnly: true)
        previewController.expand()
        previewController.layoutDidChange = { [weak self] value in
            guard let self else { return }
            var next = self.configuration
            next.widgetSizes = value.widgetSizes
            next.widgetPositions = value.widgetPositions
            next.hiddenWidgets = value.hiddenWidgets
            next.widgetOrder = value.widgetOrder
            next.metricOrder = value.metricOrder
            self.configuration = next
        }
        previewChanges = previewController.$layoutDraft.dropFirst().sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    var isDirty: Bool { IslandSettingsPart.allCases.contains { isDirty(in: $0.rawValue) } }
    func isDirty(in scope: String) -> Bool {
        let part = IslandSettingsPart(rawValue: scope)!
        return defaultParts.contains(part) || merged(part, from: configuration, comparedTo: saved, into: saved) != saved
            || (part == .canvas && previewController.layoutConfiguration != configuration)
    }
    func save() -> String? {
        for part in IslandSettingsPart.allCases where isDirty(in: part.rawValue) {
            if let reason = save(in: part.rawValue) { return reason }
        }
        return nil
    }
    func save(in scope: String) -> String? {
        let part = IslandSettingsPart(rawValue: scope)!
        if part == .canvas && previewController.editingLayout { previewController.finishLayoutEditing() }
        let current = IslandController.shared.configuration
        let next = merged(part, from: configuration, comparedTo: defaultParts.contains(part) ? current : saved, into: current)
        if let reason = IslandController.shared.apply(next) { return reason }
        saved = merged(part, from: next, comparedTo: saved, into: saved)
        defaultParts.remove(part)
        configuration = merged(part, from: next, comparedTo: configuration, into: configuration)
        return nil
    }
    func discard() {
        for part in IslandSettingsPart.allCases { discard(in: part.rawValue) }
    }
    func discard(in scope: String) {
        let part = IslandSettingsPart(rawValue: scope)!
        if part == .canvas && previewController.editingLayout { previewController.cancelLayoutEditing() }
        let current = IslandController.shared.configuration
        saved = merged(part, from: current, comparedTo: saved, into: saved)
        defaultParts.remove(part)
        configuration = merged(part, from: current, comparedTo: configuration, into: configuration)
    }
    func restoreDefaults() {
        for part in IslandSettingsPart.allCases { restoreDefaults(in: part.rawValue) }
    }
    func restoreDefaults(in scope: String) {
        let part = IslandSettingsPart(rawValue: scope)!
        if part == .canvas && previewController.editingLayout { previewController.cancelLayoutEditing() }
        defaultParts.insert(part)
        configuration = merged(part, from: IslandConfiguration(), comparedTo: configuration, into: configuration)
    }

    private func merged(_ part: IslandSettingsPart, from value: IslandConfiguration,
                        comparedTo original: IslandConfiguration, into current: IslandConfiguration) -> IslandConfiguration {
        var next = current
        func field<Value: Equatable>(_ key: WritableKeyPath<IslandConfiguration, Value>) {
            if value[keyPath: key] != original[keyPath: key] { next[keyPath: key] = value[keyPath: key] }
        }
        func keys<Value: Equatable>(_ key: WritableKeyPath<IslandConfiguration, [String: Value]>) {
            let values = value[keyPath: key], old = original[keyPath: key]
            for member in Set(values.keys).union(old.keys) where values[member] != old[member] {
                next[keyPath: key][member] = values[member]
            }
        }
        func members<Value: Hashable>(_ key: WritableKeyPath<IslandConfiguration, Set<Value>>) {
            let values = value[keyPath: key], old = original[keyPath: key]
            for member in values.symmetricDifference(old) {
                if values.contains(member) { next[keyPath: key].insert(member) }
                else { next[keyPath: key].remove(member) }
            }
        }
        switch part {
        case .activation:
            field(\.enabled); field(\.hoverEnabled); field(\.hoverDelay); field(\.collapseDelay)
            field(\.displayScope); members(\.selectedDisplayIDs)
        case .peeks:
            members(\.visiblePeeks); field(\.peekOrder); field(\.peeksShowValues); field(\.peeksQuickActions)
        case .canvas:
            field(\.width); field(\.height); field(\.gridColumns); field(\.gridRows)
            field(\.widgetOrder); members(\.hiddenWidgets); keys(\.widgetSizes); field(\.metricOrder)
            if value.widgetPositions != original.widgetPositions {
                if let values = value.widgetPositions {
                    let old = original.widgetPositions ?? [:]
                    var positions = next.widgetPositions ?? [:]
                    for member in Set(values.keys).union(old.keys) where values[member] != old[member] {
                        positions[member] = values[member]
                    }
                    next.widgetPositions = positions
                } else { next.widgetPositions = nil }
            }
        case .appearance:
            field(\.usesGlass); field(\.material); field(\.opacity); field(\.glowEnabled)
            keys(\.widgetColors); keys(\.metricColors)
        }
        return next
    }

    func updatePreview() { _ = previewController.apply(configuration) }
    func setGrid(columns: Int, rows: Int) {
        var next = configuration; next.gridColumns = columns; next.gridRows = rows
        configuration = next
    }
}

private struct IslandSettingsContent: View {
    @ObservedObject var draft: IslandSettingsDraft
    let part: IslandSettingsPart
    @Stored private var displays = IslandDisplay.available

    var body: some View {
        VStack(spacing: 20) {
            if part == .activation { SettingsSection("启用") {
                SettingsGroupBox {
                    SettingsRow(title: "启用刘海工作台", subtitle: "调整只更新预览；保存后应用到屏幕顶部") {
                        Toggle("启用刘海工作台", isOn: $draft.configuration.enabled).labelsHidden()
                    }
                }
            } }
            if part == .activation { displaySettings; entryPreviews }
            if part == .canvas { canvas }
            SettingsSection("实时预览") {
                IslandSettingsPreview(draft: draft, controller: draft.previewController)
            }
            switch part {
            case .activation: behavior
            case .peeks: peeks
            case .canvas: widgets; metrics
            case .appearance: appearance; colors
            }
        }
        .toggleStyle(.switch)
        .controlSize(.small)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear {
            if part == .peeks { draft.previewController.collapse() }
            else { draft.previewController.expand() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
            displays = IslandDisplay.available
        }
    }

    private var displaySettings: some View {
        let enabledIDs = Set(IslandDisplay.enabled(for: draft.configuration).map(\.id))
        return SettingsSection("显示屏幕") {
            SettingsGroupBox {
                SettingsRow(title: "显示范围", subtitle: "每屏保留轻量入口；完整工作台优先真实刘海屏，其次主屏") {
                    Picker("显示范围", selection: $draft.configuration.displayScope) {
                        ForEach(IslandDisplayScope.allCases) { scope in Text(scope.title).tag(scope) }
                    }.labelsHidden().frame(width: 190)
                }
                SettingsDivider()
                ForEach(displays) { display in
                    SettingsRow(icon: display.isMain ? "display.2" : "display", title: display.name,
                                subtitle: "\(Int(display.frame.width)) × \(Int(display.frame.height)) pt · "
                                    + (display.hasNotch
                                       ? "刘海 \(Int(display.entrySize.width)) × \(Int(display.entrySize.height)) pt"
                                       : "菜单栏中央透明热区 180 × 28 pt")) {
                        Text(enabledIDs.contains(display.id) ? "已启用" : "已停用")
                            .font(.system(size: 11))
                            .foregroundStyle(enabledIDs.contains(display.id) ? Theme.accent : Color.secondary)
                        if draft.configuration.displayScope == .selected {
                            Toggle("在\(display.name)显示", isOn: Binding(
                                get: { draft.configuration.selectedDisplayIDs.contains(display.id) },
                                set: {
                                    if $0 { draft.configuration.selectedDisplayIDs.insert(display.id) }
                                    else { draft.configuration.selectedDisplayIDs.remove(display.id) }
                                }
                            )).labelsHidden()
                        }
                    }
                }
            }
            Text("状态按当前草稿显示，保存后应用；指定屏幕离线时临时使用主屏，重新连接后恢复；镜像屏共用一个入口，所有屏幕共用单一工作台。")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }

    private var entryPreviews: some View {
        SettingsSection("入口预览") {
            HStack(alignment: .top, spacing: 12) {
                IslandEntryPreview(hasNotch: true, size: displays.first(where: \.hasNotch)?.entrySize)
                IslandEntryPreview(hasNotch: false, size: CGSize(width: 180, height: 28))
            }
        }
    }

    private var canvas: some View {
        SettingsSection("展开面积") {
            SettingsGroupBox {
                SettingsRow(title: "组件画布", subtitle: "列 × 行；组件尺寸按行 × 列标注，超出当前画布时自动分页") {
                    Picker("画布列数", selection: Binding(get: { draft.configuration.columns },
                        set: { draft.setGrid(columns: $0, rows: draft.configuration.rows) })) {
                        ForEach(2...6, id: \.self) { Text("\($0) 列").tag($0) }
                    }.labelsHidden().frame(width: 90)
                    Text("×")
                    Picker("画布行数", selection: Binding(get: { draft.configuration.rows },
                        set: { draft.setGrid(columns: draft.configuration.columns, rows: $0) })) {
                        ForEach(1...4, id: \.self) { Text("\($0) 行").tag($0) }
                    }.labelsHidden().frame(width: 90)
                }
                SettingsDivider()
                SettingsRow(title: "展开尺寸", subtitle: "保留输入值；显示时按单格至少 144 × 112pt、顶部预留 176pt及屏幕边缘适配") {
                    Text("宽")
                    TextField("宽度", value: Binding(get: { Double(draft.configuration.width) },
                        set: { draft.configuration.width = CGFloat($0) }),
                        format: .number.precision(.fractionLength(0))).frame(width: 64)
                    Text("高")
                    TextField("高度", value: Binding(get: { Double(draft.configuration.height) },
                        set: { draft.configuration.height = CGFloat($0) }),
                        format: .number.precision(.fractionLength(0))).frame(width: 64)
                    Text("pt").foregroundStyle(.secondary)
                }
            }.textFieldStyle(.roundedBorder)
        }
    }

    private var appearance: some View {
        SettingsSection("材质") {
            SettingsGroupBox {
                SettingsRow(title: "外壳材质", subtitle: "原生液态玻璃需 macOS 26；旧系统使用毛玻璃，减少透明度时使用纯色") {
                    Picker("外壳材质", selection: Binding(
                        get: { draft.configuration.effectiveMaterial },
                        set: { draft.configuration.material = $0 }
                    )) {
                        ForEach(IslandMaterial.allCases) { material in
                            Text(material.title).tag(material)
                        }
                    }.labelsHidden().frame(width: 160)
                }
                SettingsRow(title: "外壳通透度") {
                    Slider(value: Binding(
                        get: { 1 - draft.configuration.opacity },
                        set: { draft.configuration.opacity = 1 - $0 }
                    ), in: 0...1).frame(width: 180)
                    Text((1 - draft.configuration.opacity).formatted(.percent.precision(.fractionLength(0))))
                        .monospacedDigit().frame(width: 42, alignment: .trailing)
                }
                SettingsRow(title: "鼠标辉光") {
                    Toggle("鼠标辉光", isOn: $draft.configuration.glowEnabled).labelsHidden()
                }
            }
        }
    }

    private var behavior: some View {
        SettingsSection("唤出与收回") {
            SettingsGroupBox {
                SettingsRow(title: "悬停唤出", subtitle: "真实刘海屏悬停展开；普通屏悬停只显示搜索短条，点击后展开工作台") {
                    Toggle("悬停唤出", isOn: $draft.configuration.hoverEnabled).labelsHidden()
                }
                if draft.configuration.hoverEnabled {
                SettingsRow(title: "悬停停留时间", subtitle: "普通屏在菜单栏中央 180 × 28 pt 透明热区内停留后，显示同尺寸搜索短条") {
                    TextField("悬停停留时间", value: $draft.configuration.hoverDelay,
                              format: .number.precision(.fractionLength(2)))
                        .frame(width: 64)
                    Text("秒").foregroundStyle(.secondary)
                }
                }
                SettingsRow(title: "移开收回时间") {
                    TextField("移开收回时间", value: $draft.configuration.collapseDelay,
                              format: .number.precision(.fractionLength(2)))
                        .frame(width: 64)
                    Text("秒").foregroundStyle(.secondary)
                }
            }
            .textFieldStyle(.roundedBorder)
            Text("普通屏平时完全隐藏黑块；搜索短条仅含搜索图标与“搜索…”，不显示功能按钮。收回后恢复隐藏；真实刘海屏沿用原有行为。")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }

    private var peeks: some View {
        SettingsSection("收起态图标") {
            Text("以下图标用于真实刘海屏；普通屏的悬停短条仅显示搜索入口。")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            SettingsGroupBox {
                SettingsRow(title: "附带信息") {
                    Toggle("附带信息", isOn: $draft.configuration.peeksShowValues).labelsHidden()
                }
                SettingsRow(title: "点击执行快捷操作", subtitle: "关闭后点击图标打开对应页面") {
                    Toggle("点击执行快捷操作", isOn: $draft.configuration.peeksQuickActions).labelsHidden()
                }
                SettingsDivider()
                ForEach(draft.configuration.peekOrder) { peek in
                    SettingsRow(icon: peek.icon, title: peek.title) {
                        Toggle("显示\(peek.title)", isOn: Binding(
                            get: { draft.configuration.visiblePeeks.contains(peek) },
                            set: {
                                if $0 { draft.configuration.visiblePeeks.insert(peek) }
                                else { draft.configuration.visiblePeeks.remove(peek) }
                            }
                        )).labelsHidden()
                        IslandSettingsOrderControls(order: $draft.configuration.peekOrder, item: peek, title: peek.title)
                    }
                }
            }
        }
    }

    private var widgets: some View {
        SettingsSection("组件 · 显示、尺寸与顺序（行 × 列）") {
            SettingsGroupBox {
                ForEach(draft.configuration.widgetOrder) { widget in
                    SettingsRow(icon: widget.icon, title: widget.title,
                                subtitle: draft.configuration.requestedSize(for: widget) == draft.configuration.size(for: widget)
                                    ? nil
                                    : "保留 \(draft.configuration.requestedSize(for: widget).rawValue)；当前画布适配为 \(draft.configuration.size(for: widget).rawValue)，超出时分页") {
                        Toggle("显示\(widget.title)", isOn: Binding(
                            get: { !draft.configuration.hiddenWidgets.contains(widget) },
                            set: {
                                if $0 { draft.configuration.hiddenWidgets.remove(widget) }
                                else { draft.configuration.hiddenWidgets.insert(widget) }
                            }
                        )).labelsHidden()
                        Picker("\(widget.title)尺寸", selection: Binding(
                            get: { draft.configuration.requestedSize(for: widget) },
                            set: { draft.configuration.widgetSizes[widget.rawValue] = $0 }
                        )) {
                            ForEach(IslandWidgetSize.allCases) { size in
                                Text(size.rawValue).tag(size)
                            }
                        }.labelsHidden().frame(width: 90)
                        IslandSettingsOrderControls(order: $draft.configuration.widgetOrder, item: widget, title: widget.title)
                    }
                }
            }
            Text("尺寸按行 × 列；五档均可保存，画布不足时适配显示；组件溢出时分页，隐藏组件仍可从全部功能进入")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }

    private var metrics: some View {
        SettingsSection("监测指标顺序") {
            SettingsGroupBox {
                ForEach(draft.configuration.metricOrder) { metric in
                    SettingsRow(title: metric.title) {
                        IslandSettingsOrderControls(order: $draft.configuration.metricOrder, item: metric, title: metric.title)
                    }
                }
            }
        }
    }

    private var colors: some View {
        SettingsSection("组件与指标颜色") {
            SettingsGroupBox {
                ForEach(draft.configuration.widgetOrder) { widget in
                    SettingsRow(title: widget.title) {
                        ColorPicker("\(widget.title)颜色", selection: Binding(
                            get: { draft.configuration.color(for: widget) },
                            set: { draft.configuration.widgetColors[widget.rawValue] = Personalization.hex(fromColor: $0) }
                        ), supportsOpacity: false).labelsHidden()
                    }
                }
                SettingsDivider()
                ForEach(draft.configuration.metricOrder) { metric in
                    SettingsRow(title: metric.title) {
                        ColorPicker("\(metric.title)颜色", selection: Binding(
                            get: { draft.configuration.color(for: metric) },
                            set: { draft.configuration.metricColors[metric.rawValue] = Personalization.hex(fromColor: $0) }
                        ), supportsOpacity: false).labelsHidden()
                    }
                }
            }
        }
    }
}

private struct IslandEntryPreview: View {
    let hasNotch: Bool
    let size: CGSize?

    var body: some View {
        VStack(spacing: 8) {
            Text(hasNotch ? "真实刘海屏" : "普通屏").font(.system(size: 12))
            ForEach(0..<(hasNotch ? 1 : 3), id: \.self) { step in
                ZStack(alignment: .top) {
                    RoundedRectangle(cornerRadius: 7)
                        .fill(Color.primary.opacity(0.035))
                    if hasNotch {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.black)
                            .frame(width: 78, height: 16)
                            .offset(y: -3)
                    } else if step == 1 {
                        HStack(spacing: 6) {
                            Image(systemName: "magnifyingglass")
                            Text("搜索…")
                            Spacer(minLength: 0)
                        }
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 10)
                        .frame(width: 180, height: 28)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                    } else if step == 2 {
                        Text("单一工作台")
                            .font(.system(size: 11))
                            .frame(maxWidth: .infinity)
                            .frame(height: 48)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                            .padding(.horizontal, 16)
                    }
                }
                .frame(height: 64)
                .clipShape(RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color.primary.opacity(0.12)))
                Text(hasNotch ? "沿用刘海入口 · 悬停展开" : ["① 平时隐藏 · 中央透明热区", "② 悬停停留 → 搜索短条", "③ 点击短条 → 工作台"][step])
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Text(hasNotch
                 ? (size.map { "\(Int($0.width)) × \(Int($0.height)) pt" } ?? "按系统刘海尺寸")
                 : "热区与搜索短条均为 180 × 28 pt")
                .font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }
}

private struct IslandSettingsPreview: View {
    @ObservedObject var draft: IslandSettingsDraft
    @ObservedObject var controller: IslandController

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Toggle("展开预览", isOn: Binding(
                    get: { controller.expanded },
                    set: { if $0 { controller.expand() } else { controller.collapse() } }
                ))
                Spacer()
                Text("\(draft.configuration.columns) 列 × \(draft.configuration.rows) 行 · 当前显示 \(Int(controller.effectiveWidth)) × \(Int(controller.effectiveHeight))pt")
                    .font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary)
            }
            IslandSettingsPreviewViewport(controller: controller)
            Text("固定演示内容 · 点击编辑布局调整位置与尺寸；完成只更新草稿，保存后应用")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }
}

/// 仅预览容器接收正式形变尺寸；每帧高度变化不发布到草稿或设置整页。
private struct IslandSettingsPreviewViewport: View {
    @ObservedObject var controller: IslandController
    @Stored private var height: CGFloat?

    var body: some View {
        ScrollView(.horizontal) {
            IslandRootView(controller: controller)
                .transaction { if !controller.previewVisible { $0.disablesAnimations = true } }
                .environment(\.isSettingsPreview, true)
                .environment(\.settingsPreviewImage, SettingsPreviewSamples.image)
                .frame(width: max(controller.effectiveWidth, controller.collapsedWidth),
                       height: controller.effectiveHeight, alignment: .top)
        }
        .frame(height: height ?? (controller.contentVisible ? controller.effectiveHeight : controller.notchHeight))
        .clipped()
        .background(GeometryReader { geo in
            Color.clear.preference(key: AppearancePreviewVisibilityKey.self,
                value: geo.frame(in: .named("settingsPreviewViewport")).intersects(
                    CGRect(x: 0, y: 66, width: 940 - Theme.settingsSidebarWidth,
                           height: SettingsRootView.probeHeight - 98)))
        })
        .onPreferenceChange(AppearancePreviewVisibilityKey.self) { controller.previewVisible = $0 }
        .onAppear {
            controller.previewVisible = true
            height = controller.contentVisible ? controller.effectiveHeight : controller.notchHeight
            controller.previewViewportChanged = { size in
                DispatchQueue.main.async {
                    withTransaction(Transaction(animation: nil)) { height = size.height }
                }
            }
        }
        .onDisappear { controller.previewViewportChanged = nil; controller.previewVisible = false }
    }
}

private struct IslandSettingsOrderControls<Item: Equatable>: View {
    @Binding var order: [Item]
    let item: Item
    let title: String
    private var index: Int { order.firstIndex(of: item)! }

    var body: some View {
        HStack(spacing: 4) {
            Button { order.islandMove(item, to: index - 1) } label: { Image(systemName: "chevron.up") }
                .disabled(index == 0).accessibilityLabel("\(title)上移")
            Button { order.islandMove(item, to: index + 1) } label: { Image(systemName: "chevron.down") }
                .disabled(index == order.count - 1).accessibilityLabel("\(title)下移")
        }
        .buttonStyle(.bordered)
        .focusable()
        .onMoveCommand { direction in
            if direction == .up, index > 0 { order.islandMove(item, to: index - 1) }
            if direction == .down, index < order.count - 1 { order.islandMove(item, to: index + 1) }
        }
        .help("聚焦后按 ↑ / ↓ 调整\(title)顺序")
    }
}
