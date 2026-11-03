import AppKit
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
    /// v206：外观预览要跟「面板宽度」实时联动（写入偏好 → 预览窗宽度同步）
    @AppStorage(Preferences.Keys.panelWidth) private var previewPanelWidth: Double = 400
    /// 背景图选择器呈现
    @Stored private var isPickingImage = false
    /// v203：玻璃实时预览用的真实桌面壁纸（首次出现时读取，失败回退渐变）
    /// 注：本机工具链缺 SwiftUIMacros，`@State` 无法展开，统一用工程兼容层 `@Stored`
    @Stored private var previewWallpaper: NSImage? = nil
    /// v181：分段顺序（本地镜像 → 拖拽时即时重排 → onChange 落盘）
    @Stored private var pageOrder: [PanelCenterPage] = PanelSegments.order
    /// 正在拖的分段（nil = 没在拖）
    @Stored private var draggingSegment: PanelCenterPage?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            accentRow
            Divider().opacity(0.5)
            fontScaleRow
            densityRow
            cornerRow
            animationRow
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
            Divider().opacity(0.5)
            // v206（用户：「把上面那个玻璃质感的预览图放到最底上来，这些调节之后
            // 也要去实时展现」）：预览移到整页最底部，上面的所有外观调节都即时反映
            appearancePreviewRow
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
                 + "全部关闭时面板只显示一句提示。中转/投屏的显隐只看这里的勾选，"
                 + "与「文件中转」功能开关无关。")
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

    /// 面板默认宽度（写 panelWidth 持久化键；已开面板即时 setFrame，保持顶边）
    private var widthRow: some View {
        settingRow("面板宽度") {
            HStack(spacing: 8) {
                Picker("", selection: Binding(
                    get: { CGFloat(UserDefaults.standard.double(forKey: Preferences.Keys.panelWidth)) },
                    set: { applyPanelWidth($0) }
                )) {
                    Text("360").tag(CGFloat(360))
                    Text("400").tag(CGFloat(400))
                    Text("440").tag(CGFloat(440))
                }
                .pickerStyle(.segmented)
                .frame(width: 190)
                .labelsHidden()
                Button("重置") { applyPanelWidth(400) }
                    .buttonStyle(.link)
                    .font(.system(size: 11))
            }
        }
    }

    /// 写宽度偏好并对可见面板即时生效（顶边不动）
    private func applyPanelWidth(_ width: CGFloat) {
        UserDefaults.standard.set(Double(width), forKey: Preferences.Keys.panelWidth)
        NotificationCenter.default.post(name: Personalization.didChangeNotification, object: nil)
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

    /// v206：整页最底部的「外观预览」——强调色 / 字号 / 列表密度 / 面板圆角 /
    /// 面板宽度 / 背景材质 / 玻璃四参数全部实时反映在这一扇缩略窗上。
    private var appearancePreviewRow: some View {
        VStack(alignment: .leading, spacing: 8) {
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
            glassPreview
        }
    }

    /// 实时预览：真实桌面壁纸 + 悬浮剪贴板窗口缩略图
    ///
    /// v203（用户：「在上方添加一个背景图，然后放上我们的一个这个窗口的一个实际效果，
    /// 可以进行实时预览」）：窗口里的通透度底衬 / 霜感 / 卡片亮度 / 描边
    /// 全部读同一批 Theme 令牌，拖滑块当场就能看到最终效果。
    private var glassPreview: some View {
        ZStack {
            previewWallpaperBackground
            mockClipboardWindow
        }
        .frame(maxWidth: .infinity)
        .frame(height: 210)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.window, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.window, style: .continuous)
                .strokeBorder(Theme.cardStroke, lineWidth: Theme.Stroke.hairline)
        )
        .overlay(alignment: .bottomTrailing) {
            Text("实时预览 · 悬浮剪贴板")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule(style: .continuous).fill(Color.black.opacity(0.38)))
                .padding(8)
        }
        .onAppear {
            // 真实背景优先：应用自己选的背景图 → 当前桌面壁纸 → 渐变兜底
            if previewWallpaper == nil { previewWallpaper = Self.currentPreviewBackground() }
        }
    }

    @ViewBuilder private var previewWallpaperBackground: some View {
        if let image = previewWallpaper {
            Image(nsImage: image)
                .resizable()
                .scaledToFill()
        } else {
            LinearGradient(colors: [Color(red: 0.16, green: 0.24, blue: 0.45),
                                    Color(red: 0.42, green: 0.28, blue: 0.55),
                                    Color(red: 0.86, green: 0.52, blue: 0.30)],
                           startPoint: .topLeading,
                           endPoint: .bottomTrailing)
        }
    }

    /// 悬浮剪贴板窗口缩略图：交通灯 + 搜索 + 分类 + 两张卡（按真实窗口结构缩小）
    private var mockClipboardWindow: some View {
        VStack(spacing: 7) {
            HStack(spacing: 5) {
                trafficLight(Color(red: 1.00, green: 0.37, blue: 0.34))
                trafficLight(Color(red: 1.00, green: 0.74, blue: 0.18))
                trafficLight(Color(red: 0.16, green: 0.78, blue: 0.25))
                Spacer(minLength: 0)
                Text("剪贴板")
                    .font(.system(size: 10 * p.fontScale, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Color.clear.frame(width: 27)   // 与红绿灯等宽，标题居中
            }
            .frame(height: 26)

            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass").font(.system(size: 8 * p.fontScale))
                Text("搜索剪贴板").font(.system(size: 9 * p.fontScale))
                Spacer(minLength: 0)
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 7)
            .frame(height: 20)
            .background(Capsule(style: .continuous).fill(Color.primary.opacity(0.06)))

            HStack(spacing: 5) {
                mockChip("全部", selected: true)
                mockChip("文本")
                mockChip("图片")
                mockChip("链接")
                Spacer(minLength: 0)
            }

            HStack(spacing: 6) {
                mockCard(lineWidths: [1.0, 0.72, 0.45])
                mockCard(lineWidths: [0.82, 0.60, 0.30])
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        // v206：宽度跟随「面板宽度」档位；圆角跟随「面板圆角」档位
        .frame(width: max(300, min(420, CGFloat(previewPanelWidth) * 0.85)), height: 174)
        .background {
            // 与 App 内同一套语义：纯色卡片 = 不透明底；毛玻璃 = 模糊壁纸 + 底衬 + 霜感
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
        .overlay(
            RoundedRectangle(cornerRadius: p.cornerRadius, style: .continuous)
                .strokeBorder(Theme.cardStroke, lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.30), radius: 18, x: 0, y: 9)
    }

    private func trafficLight(_ color: Color) -> some View {
        Circle().fill(color).frame(width: 8, height: 8)
    }

    private func mockChip(_ text: String, selected: Bool = false) -> some View {
        Text(text)
            .font(.system(size: 8 * p.fontScale, weight: selected ? .semibold : .regular))
            .foregroundStyle(selected ? Theme.accent : Color.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                Capsule(style: .continuous)
                    .fill(selected ? Theme.accent.opacity(0.16) : Color.primary.opacity(0.05))
            )
    }

    private func mockCard(lineWidths: [CGFloat]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(lineWidths.indices, id: \.self) { i in
                GeometryReader { geo in
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(Color.primary.opacity(0.16))
                        .frame(width: geo.size.width * lineWidths[i], height: 4)
                }
                .frame(height: 4)
            }
        }
        .padding(7)
        // v206：卡片高度跟随「列表密度」档位（紧凑/标准/宽松）
        .frame(maxWidth: .infinity,
               minHeight: p.density.statsRowHeight * 0.62,
               alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.cardFill))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Theme.cardStroke, lineWidth: 0.5)
        )
    }

    /// 真实预览背景：应用自己选的背景图优先，其次当前桌面壁纸（取不到回退渐变）
    private static func currentPreviewBackground() -> NSImage? {
        let path = Personalization.shared.backgroundImagePath
        if !path.isEmpty, let image = NSImage(contentsOfFile: path) { return image }
        guard let screen = NSScreen.main,
              let url = NSWorkspace.shared.desktopImageURL(for: screen) else { return nil }
        return NSImage(contentsOf: url)
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
