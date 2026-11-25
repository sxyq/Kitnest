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
            if self.previewController.page == .custom {
                next.customWidgetSizes = value.widgetSizes
                next.customWidgetPositions = value.widgetPositions ?? [:]
                next.customWidgetOrder = value.widgetOrder.filter { !value.hiddenWidgets.contains($0) }
            } else {
                next.widgetSizes = value.widgetSizes
                next.widgetPositions = value.widgetPositions
                next.hiddenWidgets = value.hiddenWidgets
                next.widgetOrder = value.widgetOrder
            }
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
            // 2026-11-25（二轮复核 medium）：布局配置只在「布局编辑中」才有比较意义。
            // IslandController 在 page == .custom 时用 customWidgetOrder/Sizes 重写 4 个
            // widget 字段，与草稿常规字段恒不等 → canvas 页永久显示未保存、侧栏橙点常亮。
            || (part == .canvas && previewController.editingLayout
                && previewController.layoutConfiguration != configuration)
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
            field(\.pageOrder); members(\.hiddenPages); field(\.openingPageMode); field(\.fixedPage)
            field(\.customPageName); field(\.commonWidgetLimit); field(\.clipboardRecentLimit)
            field(\.clipboardFavoritesOnly); field(\.searchCategory)
            keys(\.hotspots); keys(\.hotspotWidths); keys(\.entryVisibilities); keys(\.entryTriggers)
        case .peeks:
            members(\.visiblePeeks); field(\.peekOrder); field(\.peeksShowValues); field(\.peeksQuickActions)
            keys(\.peekPlacements)
        case .canvas:
            field(\.width); field(\.height); field(\.gridColumns); field(\.gridRows)
            field(\.customGridColumns); field(\.customGridRows); field(\.commonWidgetLimit)
            field(\.widgetOrder); members(\.hiddenWidgets); keys(\.widgetSizes); field(\.metricOrder)
            field(\.customWidgetOrder); keys(\.customWidgetSizes); keys(\.customWidgetPositions)
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
            switch part {
            case .activation:
                if draft.configuration.enabled {
                    pageSettings
                    behavior
                    displaySettings
                    entryPreviews
                    preview
                }
            case .peeks: peeks; preview
            case .canvas: canvas; preview; widgets; customWidgets; metrics
            case .appearance: appearance; preview; colors
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

    private var preview: some View {
        SettingsSection("实时预览", alwaysExpanded: true) {
            IslandSettingsPreview(draft: draft, controller: draft.previewController)
        }
        .id(part)
    }

    private var pageSettings: some View {
        SettingsSection("页面与默认展开") {
            SettingsGroupBox {
                ForEach(draft.configuration.pageOrder) { page in
                    SettingsRow(icon: "rectangle.on.rectangle", title: draft.configuration.pageTitle(page)) {
                        Toggle("显示\(draft.configuration.pageTitle(page))", isOn: Binding(
                            get: { !draft.configuration.hiddenPages.contains(page) },
                            set: { visible in
                                if visible { draft.configuration.hiddenPages.remove(page) }
                                else if draft.configuration.visiblePages.count > 1 {
                                    draft.configuration.hiddenPages.insert(page)
                                    if draft.configuration.fixedPage == page {
                                        draft.configuration.fixedPage = draft.configuration.visiblePages.first ?? .home
                                    }
                                }
                            }
                        )).labelsHidden()
                        IslandSettingsOrderControls(order: $draft.configuration.pageOrder,
                                                    item: page, title: draft.configuration.pageTitle(page))
                    }
                }
                SettingsDivider()
                SettingsRow(title: "展开时打开", subtitle: "只在收起后重新展开时应用") {
                    Picker("展开时打开", selection: $draft.configuration.openingPageMode) {
                        ForEach(IslandOpeningPageMode.allCases) { mode in Text(mode.title).tag(mode) }
                    }.labelsHidden().frame(width: 150)
                }
                if draft.configuration.openingPageMode == .fixed {
                    SettingsRow(title: "固定页面") {
                        Picker("固定页面", selection: $draft.configuration.fixedPage) {
                            ForEach(draft.configuration.visiblePages) { page in
                                Text(draft.configuration.pageTitle(page)).tag(page)
                            }
                        }.labelsHidden().frame(width: 150)
                    }
                }
                SettingsDivider()
                SettingsRow(title: "常用页同屏组件") {
                    Picker("常用页同屏组件", selection: $draft.configuration.commonWidgetLimit) {
                        ForEach(1...4, id: \.self) { Text("\($0) 个").tag($0) }
                    }.labelsHidden().frame(width: 110)
                }
                SettingsRow(title: "剪贴板页显示条数") {
                    Picker("剪贴板页显示条数", selection: $draft.configuration.clipboardRecentLimit) {
                        ForEach([2, 3, 4, 6, 8], id: \.self) { Text("\($0) 条").tag($0) }
                    }.labelsHidden().frame(width: 110)
                    Toggle("仅显示收藏", isOn: $draft.configuration.clipboardFavoritesOnly).labelsHidden()
                }
                SettingsRow(title: "搜索页默认范围") {
                    Picker("搜索页默认范围", selection: $draft.configuration.searchCategory) {
                        ForEach(IslandSearchCategory.allCases) { Text($0.title).tag($0) }
                    }.labelsHidden().frame(width: 110)
                }
                SettingsRow(title: "第四页名称") {
                    TextField("第四页名称", text: $draft.configuration.customPageName).frame(width: 160)
                }
            }
            .textFieldStyle(.roundedBorder)
        }
    }

    private var displaySettings: some View {
        let enabledIDs = Set(IslandDisplay.enabled(for: draft.configuration).map(\.id))
        return SettingsSection("显示屏幕") {
            SettingsGroupBox {
                SettingsRow(title: "显示范围", subtitle: "所有屏幕共用一个工作台") {
                    Picker("显示范围", selection: $draft.configuration.displayScope) {
                        ForEach(IslandDisplayScope.allCases) { scope in Text(scope.title).tag(scope) }
                    }.labelsHidden().frame(width: 190)
                }
            }
            SettingsSection("显示器详情", collapsible: true,
                            expanded: draft.configuration.displayScope == .selected,
                            summary: "\(displays.count) 块屏幕 · \(enabledIDs.count) 已启用") {
              SettingsGroupBox {
                ForEach(displays) { display in
                    SettingsRow(icon: display.isMain ? "display.2" : "display", title: display.name,
                                subtitle: "\(Int(display.frame.width)) × \(Int(display.frame.height)) pt · "
                                    + (display.hasNotch
                                       ? "刘海 \(Int(display.entrySize.width)) × \(Int(display.entrySize.height)) pt"
                                       : "普通屏 · 菜单栏入口")) {
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
                ForEach(displays) { display in
                    SettingsRow(icon: "cursorarrow.motionlines", title: "\(display.name) 顶部热区",
                                subtitle: display.hasNotch ? "刘海位置按屏幕硬件自动定位" : "只读取鼠标位置，不覆盖桌面点击") {
                        Picker("\(display.name) 热区位置", selection: Binding(
                            get: { draft.configuration.hotspots[display.id] ?? .center },
                            set: { draft.configuration.hotspots[display.id] = $0 }
                        )) {
                            ForEach(IslandHotspot.allCases) { Text($0.title).tag($0) }
                        }.labelsHidden().frame(width: 112).disabled(display.hasNotch)
                        if !display.hasNotch {
                            Picker("\(display.name) 热区宽度", selection: Binding(
                                get: { draft.configuration.hotspotWidths[display.id] ?? 210 },
                                set: { draft.configuration.hotspotWidths[display.id] = $0 }
                            )) {
                                ForEach([150, 210, 270], id: \.self) { Text("\($0) pt").tag($0) }
                            }.labelsHidden().frame(width: 88)
                            Picker("\(display.name) 胶囊", selection: Binding(
                                get: { draft.configuration.entryVisibilities[display.id] ?? .event },
                                set: { draft.configuration.entryVisibilities[display.id] = $0 }
                            )) {
                                ForEach(IslandEntryVisibility.allCases) { Text($0.title).tag($0) }
                            }.labelsHidden().frame(width: 115)
                            Picker("\(display.name) 触发", selection: Binding(
                                get: { draft.configuration.entryTriggers[display.id] ?? .hoverAndClick },
                                set: { draft.configuration.entryTriggers[display.id] = $0 }
                            )) {
                                ForEach(IslandEntryTrigger.allCases) { Text($0.title).tag($0) }
                            }.labelsHidden().frame(width: 100)
                        }
                    }
                }
              }
            }
            .id(draft.configuration.displayScope)
        }
    }

    private var entryPreviews: some View {
        SettingsSection("入口预览", alwaysExpanded: true) {
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
                SettingsRow(title: "我的空间列数", subtitle: "只改变第四页；组件保持自由排序与尺寸") {
                    Picker("我的空间列数", selection: Binding(
                        get: { draft.configuration.customColumns },
                        set: { draft.configuration.customGridColumns = $0 }
                    )) {
                        ForEach(2...6, id: \.self) { Text("\($0) 列").tag($0) }
                    }.labelsHidden().frame(width: 90)
                }
                SettingsRow(title: "我的空间行数") {
                    Picker("我的空间行数", selection: Binding(
                        get: { draft.configuration.customRows },
                        set: { draft.configuration.customGridRows = $0 }
                    )) {
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
                SettingsRow(title: "悬停停留时间", subtitle: "在对应屏幕的顶部热区停留后展开；透明热区不拦截点击") {
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
        }
    }

    private var peeks: some View {
        SettingsSection("收起态图标", collapsible: true, expanded: true) {
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
                ForEach(displays.filter(\.hasNotch)) { display in
                    SettingsRow(title: "\(display.name) 常态数据位置") {
                        Picker("\(display.name) 常态数据位置", selection: Binding(
                            get: { draft.configuration.peekPlacements[display.id] ?? .both },
                            set: { draft.configuration.peekPlacements[display.id] = $0 }
                        )) {
                            ForEach(IslandPeekPlacement.allCases) { Text($0.title).tag($0) }
                        }.labelsHidden().frame(width: 145)
                    }
                }
            }
        }
    }

    private var widgets: some View {
        SettingsSection("组件 · 显示、尺寸与顺序（行 × 列）", collapsible: true, expanded: true) {
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
        }
    }

    private var customWidgets: some View {
        SettingsSection("第四页组件 · 独立布局", collapsible: true, expanded: true,
                        summary: "\(draft.configuration.customWidgetOrder.count) 个") {
            SettingsGroupBox {
                ForEach(Array(draft.configuration.customWidgetOrder.enumerated()), id: \.element) { _, widget in
                    SettingsRow(icon: widget.icon, title: widget.title) {
                        Picker("\(widget.title)尺寸", selection: Binding(
                            get: { draft.configuration.customWidgetSizes[widget.rawValue] ?? .small },
                            set: { draft.configuration.customWidgetSizes[widget.rawValue] = $0 }
                        )) {
                            ForEach(IslandWidgetSize.allCases.filter { $0 != .strip }) { size in
                                Text(size.rawValue).tag(size)
                            }
                        }.labelsHidden().frame(width: 90)
                        IslandSettingsOrderControls(order: $draft.configuration.customWidgetOrder,
                                                    item: widget, title: widget.title)
                        Button {
                            draft.configuration.customWidgetOrder.removeAll { $0 == widget }
                        } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.plain).help("从第四页移除")
                    }
                }
                Menu {
                    ForEach(IslandWidget.allCases.filter { !draft.configuration.customWidgetOrder.contains($0) }) { widget in
                        Button(widget.title) { draft.configuration.customWidgetOrder.append(widget) }
                    }
                } label: {
                    Label("添加现有组件", systemImage: "plus")
                }.disabled(draft.configuration.customWidgetOrder.count == IslandWidget.allCases.count)
            }
        }
    }

    private var metrics: some View {
        SettingsSection("监测指标顺序", collapsible: true, summary: "\(draft.configuration.metricOrder.count) 项") {
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
        SettingsSection("组件与指标颜色", collapsible: true, summary: "自定义配色") {
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
    @Stored private var step = 0

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Text(hasNotch ? "真实刘海屏" : "普通屏").font(.system(size: 12))
                Spacer(minLength: 4)
                if !hasNotch {
                    Picker("普通屏入口状态", selection: $step) {
                        Text("隐藏").tag(0)
                        Text("短条").tag(1)
                        Text("展开").tag(2)
                    }
                    .labelsHidden().pickerStyle(.segmented).frame(width: 150)
                }
            }
            .frame(height: 28)
                ZStack(alignment: .top) {
                    RoundedRectangle(cornerRadius: Theme.Radius.control)
                        .fill(Color.primary.opacity(0.035))
                    if hasNotch {
                        RoundedRectangle(cornerRadius: Theme.Radius.chip)
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
                        // 预览里的控制层同走 floatingGlass（真玻璃），不再各写 .regularMaterial
                        .surface(.floatingGlass, radius: Theme.Radius.control)
                    } else if step == 2 {
                        Text("单一工作台")
                            .font(.system(size: 11))
                            .frame(maxWidth: .infinity)
                            .frame(height: 48)
                            .surface(.card, radius: Theme.Radius.card)
                            .padding(.horizontal, 16)
                    }
                }
                .frame(height: 78)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.control))
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.control).strokeBorder(Theme.cardStroke, lineWidth: Theme.Stroke.hairline))
                Text(hasNotch ? "沿用刘海入口 · 悬停展开" : ["① 平时隐藏 · 中央透明热区", "② 悬停停留 → 搜索短条", "③ 点击短条 → 工作台"][step])
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            Text(hasNotch
                 ? (size.map { "\(Int($0.width)) × \(Int($0.height)) pt" } ?? "按系统刘海尺寸")
                 : "热区与搜索短条均为 180 × 28 pt")
                .font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
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
        }
    }
}

/// 仅预览容器接收正式形变尺寸；每帧高度变化不发布到草稿或设置整页。
private struct IslandSettingsPreviewViewport: View {
    @ObservedObject var controller: IslandController
    @Environment(\.settingsPreviewViewport) private var viewport
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
                    viewport))
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
