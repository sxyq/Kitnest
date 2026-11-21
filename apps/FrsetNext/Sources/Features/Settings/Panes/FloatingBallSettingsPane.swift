import SwiftUI

struct FloatingBallSettingsPane: View {
    @Stored private var revision = 0

    private var enabled: Bool {
        get { GlobalEntries.isEnabled(FloatingBallSettings.enabledKey) }
        nonmutating set { GlobalEntries.setEnabled(FloatingBallSettings.enabledKey, newValue); FloatingBallController.shared.applyEnabledState() }
    }
    private var selected: Set<String> {
        get {
            Set((UserDefaults.standard.stringArray(forKey: FloatingBallSettings.actionsKey) ?? FloatingBallSettings.defaultActions)
                .map { $0 == "toolbox" ? "tools" : $0 })
        }
        nonmutating set {
            UserDefaults.standard.set(FloatingBallSettings.orderedActions.map(\.id).filter { newValue.contains($0) },
                                      forKey: FloatingBallSettings.actionsKey)
            FloatingBallController.shared.applyConfiguration()
            revision &+= 1
        }
    }

    var body: some View {
        SettingsSection("悬浮球与快捷小窗") {
            SettingsGroupBox {
                SettingsRow(title: "启用悬浮球", subtitle: "默认关闭；可以从显示器边缘拖动，位置按显示器记忆") {
                    Toggle("启用悬浮球", isOn: Binding(get: { enabled }, set: { enabled = $0 }))
                        .labelsHidden().toggleStyle(.switch)
                }
                SettingsDivider()
                VStack(alignment: .leading, spacing: 6) {
                    Text("组件显示与顺序").font(.system(size: 12, weight: .medium))
                    ForEach(Array(FloatingBallSettings.orderedActions.enumerated()), id: \.element.id) { index, action in
                        HStack(spacing: 8) {
                            Toggle(isOn: Binding(
                                get: { selected.contains(action.id) },
                                set: { value in
                                    var next = selected
                                    if value { next.insert(action.id) } else { next.remove(action.id) }
                                    selected = next
                                })) {
                                Label(action.title, systemImage: action.symbol)
                            }.toggleStyle(.checkbox)
                            Spacer()
                            Button {
                                var order = FloatingBallSettings.orderedActions.map(\.id)
                                guard index > 0 else { return }
                                order.swapAt(index, index - 1)
                                UserDefaults.standard.set(order, forKey: FloatingBallSettings.orderKey)
                                FloatingBallController.shared.applyConfiguration()
                                revision &+= 1
                            } label: { Image(systemName: "arrow.up") }
                                .buttonStyle(.plain).disabled(index == 0).help("上移组件")
                            Button {
                                var order = FloatingBallSettings.orderedActions.map(\.id)
                                guard index + 1 < order.count else { return }
                                order.swapAt(index, index + 1)
                                UserDefaults.standard.set(order, forKey: FloatingBallSettings.orderKey)
                                FloatingBallController.shared.applyConfiguration()
                                revision &+= 1
                            } label: { Image(systemName: "arrow.down") }
                                .buttonStyle(.plain).disabled(index + 1 == FloatingBallSettings.orderedActions.count).help("下移组件")
                        }
                    }
                }
                SettingsDivider()
                slider("悬浮球尺寸", key: FloatingBallSettings.sizeKey, range: 40...72, step: 2, suffix: " pt")
                slider("快捷窗组件尺寸", key: FloatingBallSettings.tileSizeKey, range: 36...64, step: 2, suffix: " pt")
                slider("透明度", key: FloatingBallSettings.opacityKey, range: 0.45...1, step: 0.05, suffix: "")
                SettingsRow(title: "快捷窗列数") {
                    Picker("快捷窗列数", selection: Binding(
                        get: { FloatingBallSettings.gridColumns },
                        set: { UserDefaults.standard.set($0, forKey: FloatingBallSettings.gridColumnsKey)
                            FloatingBallController.shared.applyConfiguration(); revision &+= 1 }
                    )) {
                        ForEach(2...6, id: \.self) { Text("\($0) 列").tag($0) }
                    }.labelsHidden().frame(width: 110)
                }
                Toggle("鼠标离开后贴边半隐藏", isOn: Binding(
                    get: { FloatingBallSettings.autoHideEnabled },
                    set: { UserDefaults.standard.set($0, forKey: FloatingBallSettings.autoHideKey); revision &+= 1 }
                )).toggleStyle(.checkbox)
                Text("快捷操作调用既有截图、剪贴板、搜索、文件中转和监测窗口；不复制模块业务。按 Esc 或点击其他 Kitnest 窗口可收起。")
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .id(revision)
    }

    private func slider(_ title: String, key: String, range: ClosedRange<Double>, step: Double, suffix: String) -> some View {
        SettingsRow(title: title) {
            let fallback = key == FloatingBallSettings.sizeKey ? 48.0
                : key == FloatingBallSettings.tileSizeKey ? 44.0 : 0.92
            Slider(value: Binding(
                get: { UserDefaults.standard.object(forKey: key) as? Double ?? fallback },
                set: { UserDefaults.standard.set($0, forKey: key); FloatingBallController.shared.applyConfiguration(); revision &+= 1 }
            ), in: range, step: step).frame(width: 190)
            Text("\(Int((UserDefaults.standard.object(forKey: key) as? Double ?? fallback) * (suffix.isEmpty ? 100 : 1)))\(suffix)")
                .monospacedDigit().frame(width: 45, alignment: .trailing)
        }
    }
}
