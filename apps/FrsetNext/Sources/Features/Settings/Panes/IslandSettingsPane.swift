import SwiftUI

struct IslandSettingsPane: View {
    var body: some View {
        SettingsDraftEditor(id: "island", makeDraft: { IslandSettingsDraft() }) { draft in
            IslandSettingsContent(draft: draft)
        }
    }
}

final class IslandSettingsDraft: SettingsEditableDraft {
    @Published var configuration: IslandConfiguration {
        didSet { updatePreview() }
    }
    private var saved: IslandConfiguration
    let previewController: IslandController

    init() {
        let configuration = IslandConfiguration.load()
        self.configuration = configuration
        saved = configuration
        previewController = IslandController(configuration: configuration, previewOnly: true)
        previewController.expanded = true
        previewController.layoutDidChange = { [weak self] value in
            guard let self else { return }
            var configuration = self.configuration
            configuration.widgetSizes = value.widgetSizes
            configuration.widgetOrder = value.widgetOrder
            configuration.metricOrder = value.metricOrder
            self.configuration = configuration
        }
    }

    var isDirty: Bool { configuration != saved }

    func save() -> String? {
        if let reason = IslandController.shared.apply(configuration) { return reason }
        saved = configuration
        objectWillChange.send()
        return nil
    }

    func discard() { configuration = saved }
    func restoreDefaults() { configuration = IslandConfiguration() }

    func updatePreview() { _ = previewController.apply(configuration) }

    func setGrid(columns: Int, rows: Int) {
        var next = configuration
        next.gridColumns = columns
        next.gridRows = rows
        next.width = max(next.width, next.minimumWidth)
        next.height = max(next.height, next.minimumHeight)
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
                SettingsGroupBox {
                    IslandSettingsPreview(draft: draft, controller: draft.previewController)
                }
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
                SettingsRow(title: "展开尺寸", subtitle: "小组件至少 110 × 48pt；大内容进入详情页，调整只更新预览") {
                    Text("宽")
                    TextField("宽度", value: Binding(get: { Double(draft.configuration.width) },
                        set: { draft.configuration.width = max(CGFloat($0), draft.configuration.minimumWidth) }),
                        format: .number.precision(.fractionLength(0))).frame(width: 64)
                    Text("高")
                    TextField("高度", value: Binding(get: { Double(draft.configuration.height) },
                        set: { draft.configuration.height = max(CGFloat($0), draft.configuration.minimumHeight) }),
                        format: .number.precision(.fractionLength(0))).frame(width: 64)
                    Text("pt").foregroundStyle(.secondary)
                }
            }.textFieldStyle(.roundedBorder)
        }
    }

    private var appearance: some View {
        SettingsSection("材质与悬停") {
            SettingsGroupBox {
                SettingsRow(title: "黑色玻璃") {
                    Toggle("黑色玻璃", isOn: $draft.configuration.usesGlass).labelsHidden()
                }
                SettingsRow(title: "黑色玻璃通透度") {
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
        SettingsSection("组件 · 显示、颜色、尺寸与顺序") {
            SettingsGroupBox {
                ForEach(draft.configuration.widgetOrder) { widget in
                    SettingsRow(icon: widget.icon, title: widget.title) {
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
                            get: { draft.configuration.size(for: widget) },
                            set: { draft.configuration.widgetSizes[widget.rawValue] = $0 }
                        )) {
                            ForEach(IslandWidgetSize.allCases.filter {
                                $0.columns <= draft.configuration.columns && $0.rows <= draft.configuration.rows
                            }) { size in
                                Text(size.rawValue).tag(size)
                            }
                        }.labelsHidden().frame(width: 90)
                        IslandSettingsOrderControls(order: $draft.configuration.widgetOrder, item: widget, title: widget.title)
                    }
                }
            }
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Toggle("展开预览", isOn: $controller.expanded)
                Spacer()
                Text("\(draft.configuration.columns) × \(draft.configuration.rows) 格 · \(Int(controller.effectiveWidth)) × \(Int(controller.effectiveHeight))pt")
                    .font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary)
            }
            ScrollView(.horizontal) {
                IslandRootView(controller: controller)
                    .environment(\.isSettingsPreview, true)
                    .frame(width: max(controller.effectiveWidth, controller.collapsedWidth),
                           height: controller.effectiveHeight, alignment: .top)
                    .padding(.horizontal, 8)
            }
            .frame(height: controller.expanded ? controller.effectiveHeight : controller.notchHeight + 8)
            .animation(.easeInOut(duration: reduceMotion ? 0.12 : 0.36), value: controller.expanded)
            .clipped()
            Text("固定演示内容 · 可切页、操作图表与拖动排序；横向滚动查看原尺寸，保存才应用")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
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
