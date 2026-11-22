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
                SettingsRow(title: "启用悬浮球", subtitle: "默认关闭；点击球面展开，按住拖动后左右贴边") {
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
                slider("快捷窗宽度", key: FloatingBallSettings.widthKey, range: 160...480, step: 10, suffix: " pt")
                slider("快捷窗高度", key: FloatingBallSettings.heightKey, range: 160...480, step: 10, suffix: " pt")
                slider("快捷窗组件尺寸", key: FloatingBallSettings.tileSizeKey, range: 36...64, step: 2, suffix: " pt")
                slider("透明度", key: FloatingBallSettings.opacityKey, range: 0.45...1, step: 0.05, suffix: "")
                SettingsRow(title: "快捷窗列数", subtitle: "宽度不足时减少列数，其余组件自动分页") {
                    Picker("快捷窗列数", selection: Binding(
                        get: { FloatingBallSettings.gridColumns },
                        set: { UserDefaults.standard.set($0, forKey: FloatingBallSettings.gridColumnsKey)
                            FloatingBallController.shared.applyConfiguration(); revision &+= 1 }
                    )) {
                        ForEach(2...6, id: \.self) { Text("\($0) 列").tag($0) }
                    }.labelsHidden().frame(width: 110)
                }
                SettingsRow(title: "默认打开页面", subtitle: "组件按可用宽高分页；开启页面记忆时优先恢复该屏上次页面") {
                    let count = FloatingBallSettings.pageCount(for: FloatingBallSettings.windowSize)
                    Picker("默认打开页面", selection: Binding(
                        get: { min(UserDefaults.standard.integer(forKey: FloatingBallSettings.defaultPageKey), count - 1) },
                        set: { UserDefaults.standard.set($0, forKey: FloatingBallSettings.defaultPageKey); revision &+= 1 }
                    )) {
                        ForEach(0..<count, id: \.self) { Text("第 \($0 + 1) 页").tag($0) }
                    }.labelsHidden().frame(width: 110)
                }
                SettingsRow(title: "展开方式") {
                    Picker("展开方式", selection: Binding(
                        get: { UserDefaults.standard.bool(forKey: FloatingBallSettings.expandOnHoverKey) },
                        set: { UserDefaults.standard.set($0, forKey: FloatingBallSettings.expandOnHoverKey); revision &+= 1 }
                    )) {
                        Text("点击").tag(false)
                        Text("悬停或点击").tag(true)
                    }.labelsHidden().frame(width: 140)
                }
                option("记住屏幕与位置", key: FloatingBallSettings.rememberPositionKey, fallback: true)
                option("逐屏记住上次页面", key: FloatingBallSettings.rememberPageKey, fallback: true)
                option("鼠标离开时保持小窗展开", key: FloatingBallSettings.keepOpenKey)
                option("收起后贴边半隐藏", key: FloatingBallSettings.autoHideKey, fallback: true)
                Text("按 Esc、点击小窗顶部收起按钮或小窗外部可收起，包括其他 App。所有已选组件均可翻页访问；复杂功能沿用原业务窗口。")
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .id(revision)
    }

    private func slider(_ title: String, key: String, range: ClosedRange<Double>, step: Double, suffix: String) -> some View {
        SettingsRow(title: title) {
            let fallback = key == FloatingBallSettings.sizeKey ? 48.0
                : key == FloatingBallSettings.tileSizeKey ? 44.0
                : key == FloatingBallSettings.widthKey ? 220.0
                : key == FloatingBallSettings.heightKey ? 180.0 : 0.92
            Slider(value: Binding(
                get: { UserDefaults.standard.object(forKey: key) as? Double ?? fallback },
                set: { UserDefaults.standard.set($0, forKey: key); FloatingBallController.shared.applyConfiguration(); revision &+= 1 }
            ), in: range, step: step).frame(width: 190)
            Text("\(Int((UserDefaults.standard.object(forKey: key) as? Double ?? fallback) * (suffix.isEmpty ? 100 : 1)))\(suffix)")
                .monospacedDigit().frame(width: 45, alignment: .trailing)
        }
    }

    private func option(_ title: String, key: String, fallback: Bool = false) -> some View {
        Toggle(title, isOn: Binding(
            get: { UserDefaults.standard.object(forKey: key) as? Bool ?? fallback },
            set: {
                UserDefaults.standard.set($0, forKey: key)
                FloatingBallController.shared.applyConfiguration()
                revision &+= 1
            }
        )).toggleStyle(.checkbox)
    }
}
