import AppKit
import Combine
import SwiftUI

// MARK: - 个性化设置（v66：设置 → 常规 →「个性化」分组）
//
// 全档即改即生效：Binding 写 Personalization.shared（@Published + persist），
// 视图侧（主面板/剪贴板表格/窗口尺寸）经 objectWillChange 与
// Personalization.didChangeNotification 即时响应。恢复默认一键回滚。

struct PersonalizationSettingsView: View {
    @ObservedObject private var p = Personalization.shared
    // v177：主面板顶部页面开关（与 PanelRootView 共用同一批键）
    @AppStorage(PanelSegments.homeKey) private var segmentHome = true
    @AppStorage(PanelSegments.monitorKey) private var segmentMonitor = true
    @AppStorage(PanelSegments.transferKey) private var segmentTransfer = false
    @AppStorage(PanelSegments.castKey) private var segmentCast = false
    /// v260：面板宽度改成真正的 SwiftUI 状态驱动。
    /// 原来 widthRow 用手写 Binding，getter 直接读 UserDefaults、setter 不写任何 state，
    /// segmented 选中态会弹回，看起来就是「点了没反应」。
    @AppStorage(Preferences.Keys.panelWidth) private var panelWidthValue: Double = 400
    /// 背景图选择器呈现
    @Stored private var isPickingImage = false
    /// v181：分段顺序（本地镜像 → 拖拽时即时重排 → onChange 落盘）
    @Stored private var pageOrder: [PanelCenterPage] = PanelSegments.order
    /// 正在拖的分段（nil = 没在拖）
    @Stored private var draggingSegment: PanelCenterPage?
    /// v219：框选后动作条的排布样式（Capture 模块读同一个键；此处只存字符串，
    /// 不引用 Capture 模块类型，遵守跨模块纪律）
    @AppStorage("capture.toolbar.style") private var toolbarStyle = "pillBar"

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            accentRow
            Divider().opacity(0.5)
            fontScaleRow
            densityRow
            cornerRow
            animationRow
            toolbarStyleRow
            widthRow
            Divider().opacity(0.5)
            materialRow
            Divider().opacity(0.5)
            glassRow
            Divider().opacity(0.5)
            badgeRow
            thumbRow
            toastRow
            dividerRow
            Divider().opacity(0.5)
            midnightHueRow
            backgroundImageRow
            Divider().opacity(0.5)
            panelPagesRow
            Divider().opacity(0.5)
            globalEntriesRow
            Divider().opacity(0.5)
            resetRow
        }
        .padding(.vertical, 4)
        // 拖完顺序落盘（PanelRootView 用 @AppStorage 观察同一个键，面板立即重排）
        .onChange(of: pageOrder) { newOrder in
            PanelSegments.order = newOrder
        }
    }

    /// 主面板顶部页面（v177）：勾掉的分段不出现，对应视图也不会创建。
    /// v181：同一块里拖拽排序——顶部顺序 = 这里的顺序，第一项是当前页被关掉时的回退页。
    private var panelPagesRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            settingRow("主面板页面") {
                VStack(alignment: .trailing, spacing: 6) {
                    ForEach(Array(pageOrder.enumerated()), id: \.element) { index, page in
                        segmentOrderRow(page, index: index)
                    }
                    Button {
                        pageOrder = PanelSegments.defaultOrder
                    } label: {
                        Text("恢复默认顺序")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.link)
                    .disabled(pageOrder == PanelSegments.defaultOrder)
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

    /// 全局入口（v192）：菜单栏（状态栏）里的入口项与两个独立窗口的开关。
    /// 用户要求「跟中转和投屏一样」——所以放在同一页、同样的勾选交互；
    /// 但它管的是**菜单栏入口**，不是主面板顶部的分段按钮（那是上面那一组）。
    private var globalEntriesRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            settingRow("功能入口") {
                VStack(alignment: .trailing, spacing: 6) {
                    Toggle("主页（打开面板）", isOn: Binding(
                        get: { GlobalEntries.isEnabled(GlobalEntries.homeKey) },
                        set: { GlobalEntries.setEnabled(GlobalEntries.homeKey, $0) }))
                        .toggleStyle(.checkbox)
                        .font(.system(size: 12))
                    Toggle("性能监测独立窗", isOn: Binding(
                        get: { GlobalEntries.isEnabled(GlobalEntries.monitorPopoutKey) },
                        set: { GlobalEntries.setEnabled(GlobalEntries.monitorPopoutKey, $0) }))
                        .toggleStyle(.checkbox)
                        .font(.system(size: 12))
                    Toggle("菜单栏性能部件（STATS）", isOn: Binding(
                        get: { GlobalEntries.isEnabled(GlobalEntries.statsBarKey) },
                        set: { GlobalEntries.setEnabled(GlobalEntries.statsBarKey, $0) }))
                        .toggleStyle(.checkbox)
                        .font(.system(size: 12))
                }
                .frame(width: 210)
            }
            Text("控制菜单栏图标下拉菜单里的「打开面板 / 性能监测…」两项，以及菜单栏上的性能合并条。"
                 + "关掉只是收起入口，数据和历史都还在，随时可以再打开；"
                 + "全部关掉时主面板仍可用 ⌥A 打开，不会把界面锁死。")
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
            target: page, order: $pageOrder, dragging: $draggingSegment))
    }

    private func binding(for page: PanelCenterPage) -> Binding<Bool> {
        switch page {
        case .home:        return $segmentHome
        case .performance: return $segmentMonitor
        case .transfer:    return $segmentTransfer
        case .cast:        return $segmentCast
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
            Text("下一次打开面板时生效（动画只在开窗/关窗那一刻读取），不在上方静态预览里变化。")
                .font(.system(size: 10))
                .foregroundStyle(Theme.tertiaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// 框选动作条样式（v219）
    ///
    /// 用户：「这三种方案都要。在设置里面……把当前的这个选项放在个性化设置里面」。
    /// 三张卡片直接画出排布差异（不是纯文字单选），选中的一张用 accent 描边；
    /// 写 `capture.toolbar.style`，Capture 侧每次 present 重新读——不用重启。
    private var toolbarStyleRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            settingRow("截图动作条") {
                HStack(spacing: 8) {
                    toolbarStyleCard("iconBar", title: "图标条", caption: "最紧凑，悬停显名")
                    toolbarStyleCard("pillBar", title: "药丸条", caption: "图标加文字，一眼看懂")
                    toolbarStyleCard("primarySplit", title: "主次分离", caption: "默认动作放大")
                }
            }
            Text("框选完成后弹出的小面板。三种排布的功能完全一样，只是紧凑程度和子项展开方式不同；"
                 + "切换后下一次框选即生效，不用重启。")
                .font(.system(size: 11))
                .foregroundStyle(Theme.tertiaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func toolbarStyleCard(_ id: String, title: String, caption: String) -> some View {
        let on = toolbarStyle == id
        return Button {
            toolbarStyle = id
        } label: {
            VStack(spacing: 6) {
                miniToolbar(id)
                    .frame(height: 12)
                Text(title)
                    .font(.system(size: 11, weight: on ? .medium : .regular))
                    .foregroundStyle(on ? Theme.accent : Color.primary)
                    .lineLimit(1)
            }
            .frame(width: 88, height: 54)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                    .fill(on ? Theme.accent.opacity(0.08) : Theme.cardFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                    .strokeBorder(on ? Theme.accent.opacity(0.55) : Color.primary.opacity(0.10),
                                  lineWidth: on ? 1 : 0.5)
            )
            .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
        }
        .buttonStyle(.plain)
        .focusable(false)
        .help(caption)
    }

    /// 卡片里的迷你示意：用几何块表达三种排布，不用图标字体（避免和真实含义错位）
    @ViewBuilder
    private func miniToolbar(_ id: String) -> some View {
        if id == "iconBar" {
            HStack(spacing: 3) {
                ForEach(0..<5, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(i == 0 ? Theme.accent : Color.primary.opacity(0.22))
                        .frame(width: 9, height: 9)
                }
            }
        } else if id == "pillBar" {
            HStack(spacing: 2) {
                ForEach(0..<5, id: \.self) { i in
                    Capsule(style: .continuous)
                        .fill(i == 0 ? Theme.accent : Color.primary.opacity(0.16))
                        .frame(width: i == 2 ? 17 : 13, height: 9)
                }
            }
        } else {
            HStack(spacing: 4) {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(Theme.accent)
                    .frame(width: 24, height: 10)
                Rectangle()
                    .fill(Color.primary.opacity(0.20))
                    .frame(width: 0.5, height: 8)
                ForEach(0..<3, id: \.self) { _ in
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(Color.primary.opacity(0.22))
                        .frame(width: 9, height: 9)
                }
            }
        }
    }

    /// 面板默认宽度（写 panelWidth 持久化键；已开面板即时 setFrame，保持顶边）
    private var widthRow: some View {
        settingRow("面板宽度") {
            HStack(spacing: 8) {
                Picker("", selection: $panelWidthValue) {
                    Text("360").tag(Double(360))
                    Text("400").tag(Double(400))
                    Text("440").tag(Double(440))
                }
                .pickerStyle(.segmented)
                .frame(width: 190)
                .labelsHidden()
                Button("重置") { panelWidthValue = 400 }
                    .buttonStyle(.link)
                    .font(.system(size: 11))
            }
        }
        // 已打开的面板靠通知即时 setFrame（顶边不动）；选中态由 @AppStorage 自己保持
        .onChange(of: panelWidthValue) { _ in
            NotificationCenter.default.post(name: Personalization.didChangeNotification, object: nil)
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

    /// 合并条分隔线（v66：显隐快捷开关写引擎既有键；颜色档位接引擎渲染链后开放）
    private var dividerRow: some View {
        settingRow("合并条分隔线") {
            HStack(spacing: 10) {
                Toggle("模块间画 1pt 竖线", isOn: Binding(
                    get: { UserDefaults.standard.object(forKey: "CombinedModules_separator") == nil
                        ? true
                        : UserDefaults.standard.bool(forKey: "CombinedModules_separator") },
                    set: { UserDefaults.standard.set($0, forKey: "CombinedModules_separator") }
                ))
                .toggleStyle(.checkbox)
                .font(.system(size: 12))
                Text("颜色自定义将随引擎渲染链开放")
                    .font(.system(size: 11))
                    .foregroundStyle(Color(NSColor.tertiaryLabelColor))
            }
        }
    }

    // MARK: 玻璃质感（v193）

    /// 玻璃质感滑块组
    ///
    /// 用户：「设置里面添加相关的按钮去调节玻璃的一个通透质感以及相关的参数，
    /// 弄成几个可以滑动的这种类似于音量条的这种。放在个性化里面」。
    ///
    /// 四个滑块对应 v192 的四层表面口径，全部即改即生效：
    ///   通透度 → Theme.windowSurface 的 alpha
    ///   磨砂   → Theme.glassFrost（霜感层）
    ///   卡片亮度 → Theme.cardFill 的 alpha（卡片与窗口底的明度台阶）
    ///   描边   → Theme.cardStroke 的 alpha
    ///
    /// 生效链路：滑块写 Personalization.shared（@Published）→
    /// ThemeChromeModifier 观察它 → 整棵子树重算 → Theme 的计算属性取到新值。
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
            Button("恢复全部默认") {
                Personalization.shared.resetAll()
            }
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

// MARK: - 实时预览（v260 独立区块，按生效对象拆分）
//
// 用户原话：「把下面的那个实时预览拆分一下，因为它的一个最终设置生效项是不同的，
// 需要拆分预览，包括把实时预览放在它的一个上面，下面才是这个分开的一个这种个性化」。
//
// 旧版一张「悬浮剪贴板」缩略窗被拿来验证主面板的字号/密度/圆角/宽度/动画，
// 生效对象不同却共用一张图；再叠加「预览在整页最底部滚不到」「壁纸只在首次
// onAppear 加载一次」「宽度 segmented 没有 SwiftUI 状态支撑」，用户的主观感受
// 就是「调节之后这边没有实时更新」。
// 现在：① 独立区块置顶（GeneralSettingsPane 里在「个性化」之前）；
//       ② 按生效对象拆成「主面板」「独立窗口」两张缩略窗并标注各自作用域；
//       ③ 自带 @ObservedObject + 通知订阅 + 壁纸缓存失效。
struct AppearancePreviewBlock: View {
    @ObservedObject private var p = Personalization.shared
    @AppStorage(Preferences.Keys.panelWidth) private var panelWidth: Double = 400
    @AppStorage("capture.toolbar.style") private var toolbarStyle = "pillBar"
    @Stored private var wallpaper: NSImage?
    /// AppKit 侧玻璃底靠 150ms 防抖通知刷新；这里收到后自增一次让 body 重算
    @Stored private var revision = 0

    var body: some View {
        let _ = revision
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("外观预览")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Text("实时")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Theme.accent)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Capsule(style: .continuous).fill(Theme.accent.opacity(0.14)))
            }
            previewCanvas
            Text("打开动画「\(p.openAnimation.title)」与截图动作条「\(toolbarTitle)」"
                 + "只在下一次打开面板 / 下一次框选时生效，不在这两张静态缩略窗里变化。")
                .font(.system(size: 10))
                .foregroundStyle(Theme.tertiaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onAppear { reloadWallpaper() }
        // v260：旧版 `if previewWallpaper == nil` 只加载一次，换背景图/换桌面壁纸
        // 后预览底图永远停在首次那张 —— 改成路径变化即重载。
        .onChange(of: p.backgroundImagePath) { _ in reloadWallpaper() }
        .onReceive(NotificationCenter.default.publisher(for: Personalization.didChangeNotification)) { _ in
            revision &+= 1
        }
    }

    private var previewCanvas: some View {
        ZStack {
            wallpaperBackground
            HStack(alignment: .top, spacing: 14) {
                previewItem(title: "主面板", scope: "字号 · 密度 · 圆角 · 宽度 · 材质") {
                    mainPanelMock
                }
                previewItem(title: "独立窗口", scope: "强调色 · 通透度 · 磨砂 · 描边") {
                    floatingWindowMock
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 208)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.window, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.window, style: .continuous)
                .strokeBorder(Theme.cardStroke, lineWidth: Theme.Stroke.hairline)
        )
    }

    private func previewItem<Content: View>(title: String, scope: String,
                                            @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            content()
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white)
                Text(scope)
                    .font(.system(size: 9))
                    .foregroundStyle(.white.opacity(0.80))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(Capsule(style: .continuous).fill(Color.black.opacity(0.38)))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 生效对象 = 主面板：宽度 / 圆角 / 密度 / 字号 / 材质都在这里体现
    private var mainPanelMock: some View {
        VStack(spacing: 5) {
            HStack(spacing: 4) {
                trafficLight(Color(red: 1.00, green: 0.37, blue: 0.34))
                trafficLight(Color(red: 1.00, green: 0.74, blue: 0.18))
                trafficLight(Color(red: 0.16, green: 0.78, blue: 0.25))
                Spacer(minLength: 0)
                Text("主页  监测  中转")
                    .font(.system(size: 8 * p.fontScale))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            ForEach(0..<3, id: \.self) { _ in
                HStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.primary.opacity(0.16))
                        .frame(width: 26, height: 5)
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.primary.opacity(0.10))
                        .frame(width: 54, height: 4)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 7)
                .frame(height: max(15, p.density.statsRowHeight * 0.40))
                .background(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                    .fill(Theme.cardFill))
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                    .strokeBorder(Theme.cardStroke, lineWidth: 0.5))
            }
            Spacer(minLength: 0)
        }
        .padding(8)
        .frame(width: max(150, min(230, CGFloat(panelWidth) * 0.46)), height: 130)
        .background {
            ZStack {
                if p.material == .solid {
                    Rectangle().fill(Color(nsColor: .windowBackgroundColor))
                } else {
                    Rectangle().fill(.ultraThinMaterial)
                }
                Theme.windowSurface
                Theme.glassFrost
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: p.cornerRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: p.cornerRadius, style: .continuous)
            .strokeBorder(Theme.cardStroke, lineWidth: 0.5))
        .shadow(color: .black.opacity(0.28), radius: 12, x: 0, y: 6)
    }

    /// 生效对象 = 独立窗口 / 悬浮剪贴板：强调色与玻璃四参数
    private var floatingWindowMock: some View {
        VStack(spacing: 6) {
            HStack(spacing: 4) {
                trafficLight(Color(red: 1.00, green: 0.37, blue: 0.34))
                trafficLight(Color(red: 1.00, green: 0.74, blue: 0.18))
                trafficLight(Color(red: 0.16, green: 0.78, blue: 0.25))
                Spacer(minLength: 0)
                Text("剪贴板")
                    .font(.system(size: 8 * p.fontScale))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            HStack(spacing: 4) {
                Text("全部")
                    .font(.system(size: 8 * p.fontScale, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule(style: .continuous).fill(Theme.accent.opacity(0.16)))
                Text("文本")
                    .font(.system(size: 8 * p.fontScale))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            VStack(alignment: .leading, spacing: 4) {
                ForEach(0..<2, id: \.self) { _ in
                    RoundedRectangle(cornerRadius: 1.5).fill(Color.primary.opacity(0.16))
                        .frame(width: 88, height: 4)
                    RoundedRectangle(cornerRadius: 1.5).fill(Color.primary.opacity(0.10))
                        .frame(width: 62, height: 4)
                }
            }
            .padding(7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                .fill(Theme.cardFill))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                .strokeBorder(Theme.cardStroke, lineWidth: 0.5))
            Spacer(minLength: 0)
        }
        .padding(8)
        .frame(width: 176, height: 130)
        .background {
            ZStack {
                Rectangle().fill(.ultraThinMaterial)
                Theme.windowSurface
                Theme.glassFrost
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: p.cornerRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: p.cornerRadius, style: .continuous)
            .strokeBorder(Theme.cardStroke, lineWidth: 0.5))
        .shadow(color: .black.opacity(0.28), radius: 12, x: 0, y: 6)
    }

    private func trafficLight(_ color: Color) -> some View {
        Circle().fill(color).frame(width: 7, height: 7)
    }

    @ViewBuilder private var wallpaperBackground: some View {
        if let image = wallpaper {
            Image(nsImage: image).resizable().scaledToFill()
        } else {
            LinearGradient(colors: [Color(red: 0.16, green: 0.24, blue: 0.45),
                                    Color(red: 0.42, green: 0.28, blue: 0.55),
                                    Color(red: 0.86, green: 0.52, blue: 0.30)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
        }
    }

    private func reloadWallpaper() {
        let path = p.backgroundImagePath
        if !path.isEmpty, let image = NSImage(contentsOfFile: path) {
            wallpaper = image
            return
        }
        guard let screen = NSScreen.main,
              let url = NSWorkspace.shared.desktopImageURL(for: screen) else {
            wallpaper = nil
            return
        }
        wallpaper = NSImage(contentsOf: url)
    }

    private var toolbarTitle: String {
        switch toolbarStyle {
        case "iconBar": return "图标条"
        case "primarySplit": return "主次分离"
        default: return "药丸条"
        }
    }
}
