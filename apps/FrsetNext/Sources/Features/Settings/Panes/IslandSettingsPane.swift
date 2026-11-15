import SwiftUI
import Combine

struct IslandSettingsPane: View {
    var body: some View {
        SettingsDraftEditor(id: "island", makeDraft: { IslandSettingsDraft() }) { draft in
            IslandSettingsContent(draft: draft)
        }
    }
}

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
    private var restoringDefaults = false
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
            var configuration = self.configuration
            configuration.widgetSizes = value.widgetSizes
            configuration.widgetPositions = value.widgetPositions
            configuration.hiddenWidgets = value.hiddenWidgets
            configuration.widgetOrder = value.widgetOrder
            configuration.metricOrder = value.metricOrder
            self.configuration = configuration
        }
        previewChanges = previewController.$layoutDraft.dropFirst().sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    var isDirty: Bool { restoringDefaults || configuration != saved || previewController.layoutConfiguration != configuration }

    func save() -> String? {
        if previewController.editingLayout { previewController.finishLayoutEditing() }
        var next = IslandController.shared.configuration
        if restoringDefaults {
            next = configuration
        } else {
            // 草稿未改的字段保留正式现场；字典仅覆盖本次改变的键。
            func merge<Value: Equatable>(_ field: WritableKeyPath<IslandConfiguration, Value>) {
                if configuration[keyPath: field] != saved[keyPath: field] {
                    next[keyPath: field] = configuration[keyPath: field]
                }
            }
            func mergeKeys<Value: Equatable>(_ field: WritableKeyPath<IslandConfiguration, [String: Value]>) {
                let values = configuration[keyPath: field], original = saved[keyPath: field]
                for key in Set(values.keys).union(original.keys) where values[key] != original[key] {
                    next[keyPath: field][key] = values[key]
                }
            }
            merge(\.enabled)
            merge(\.width)
            merge(\.height)
            merge(\.gridColumns)
            merge(\.gridRows)
            merge(\.hoverEnabled)
            merge(\.hoverDelay)
            merge(\.collapseDelay)
            merge(\.usesGlass)
            merge(\.material)
            merge(\.opacity)
            merge(\.glowEnabled)
            merge(\.visiblePeeks)
            merge(\.peeksShowValues)
            merge(\.peeksQuickActions)
            merge(\.peekOrder)
            merge(\.widgetPositions)
            merge(\.widgetOrder)
            merge(\.hiddenWidgets)
            mergeKeys(\.widgetSizes)
            mergeKeys(\.widgetColors)
            merge(\.metricOrder)
            mergeKeys(\.metricColors)
        }
        if let reason = IslandController.shared.apply(next) { return reason }
        saved = next
        restoringDefaults = false
        configuration = next
        return nil
    }

    func discard() {
        if previewController.editingLayout { previewController.cancelLayoutEditing() }
        saved = IslandController.shared.configuration
        restoringDefaults = false
        configuration = saved
    }
    func restoreDefaults() {
        if previewController.editingLayout { previewController.cancelLayoutEditing() }
        restoringDefaults = true
        configuration = IslandConfiguration()
    }

    func updatePreview() { _ = previewController.apply(configuration) }

    func setGrid(columns: Int, rows: Int) {
        var next = configuration
        next.gridColumns = columns
        next.gridRows = rows
        configuration = next
    }
}

private struct IslandSettingsContent: View {
    @ObservedObject var draft: IslandSettingsDraft

    var body: some View {
        VStack(spacing: 20) {
            SettingsSection("启用") {
                SettingsGroupBox {
                    SettingsRow(title: "启用刘海工作台", subtitle: "调整只更新预览；保存后应用到屏幕顶部") {
                        Toggle("启用刘海工作台", isOn: $draft.configuration.enabled).labelsHidden()
                    }
                }
            }
            canvas
            SettingsSection("实时预览") {
                IslandSettingsPreview(draft: draft, controller: draft.previewController)
            }
            appearance
            peeks
            widgets
            metrics
        }
        .toggleStyle(.switch)
        .controlSize(.small)
        .frame(maxWidth: .infinity, alignment: .leading)
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
        SettingsSection("材质与悬停") {
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
                SettingsDivider()
                SettingsRow(title: "悬停展开") {
                    Toggle("悬停展开", isOn: $draft.configuration.hoverEnabled).labelsHidden()
                }
                SettingsRow(title: "悬停展开时间") {
                    TextField("悬停展开时间", value: $draft.configuration.hoverDelay,
                              format: .number.precision(.fractionLength(2)))
                        .frame(width: 64)
                    Text("秒").foregroundStyle(.secondary)
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
        SettingsSection("收起态图标") {
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
        SettingsSection("组件 · 显示、颜色、尺寸与顺序（行 × 列）") {
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
                        ColorPicker("\(widget.title)颜色", selection: Binding(
                            get: { draft.configuration.color(for: widget) },
                            set: { draft.configuration.widgetColors[widget.rawValue] = Personalization.hex(fromColor: $0) }
                        ), supportsOpacity: false).labelsHidden()
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
        SettingsSection("监测指标 · 颜色与顺序") {
            SettingsGroupBox {
                ForEach(draft.configuration.metricOrder) { metric in
                    SettingsRow(title: metric.title) {
                        ColorPicker("\(metric.title)颜色", selection: Binding(
                            get: { draft.configuration.color(for: metric) },
                            set: { draft.configuration.metricColors[metric.rawValue] = Personalization.hex(fromColor: $0) }
                        ), supportsOpacity: false).labelsHidden()
                        IslandSettingsOrderControls(order: $draft.configuration.metricOrder, item: metric, title: metric.title)
                    }
                }
            }
        }
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
