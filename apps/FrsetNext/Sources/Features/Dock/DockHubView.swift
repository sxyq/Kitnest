import AppKit
import SwiftUI

struct DockHubView: View {
    @ObservedObject var controller: DockHubController
    let size: NSSize

    private static let tools: [DockHubTool] = [
        .init(action: .panel, title: "主面板", symbol: "rectangle.grid.1x2", detail: "打开 Kitnest 主面板"),
        .init(action: .clipboard, title: "剪贴板", symbol: "doc.on.clipboard", detail: "查找和使用剪贴记录"),
        .init(action: .transfer, title: "文件中转", symbol: "tray.and.arrow.down", detail: "暂存与传递文件"),
        .init(action: .screenshot, title: "截图", symbol: "camera.viewfinder", detail: "选择区域截取画面"),
        .init(action: .longshot, title: "长截图", symbol: "rectangle.expand.vertical", detail: "截取滚动页面"),
        .init(action: .recording, title: "录屏", symbol: "record.circle", detail: "打开屏幕录制控制"),
        .init(action: .tools, title: "工具箱", symbol: "wrench.and.screwdriver", detail: "浏览全部实用工具"),
        .init(action: .monitor, title: "性能监测", symbol: "waveform.path.ecg", detail: "查看系统资源状态"),
        .init(action: .settings, title: "设置", symbol: "gearshape", detail: "调整功能与使用偏好")
    ]

    var body: some View {
        Group {
            if controller.isExpanded {
                hubContent.padding(.top, OfficialChrome.titlebarInset)
                    .frame(width: size.width, height: size.height, alignment: .topLeading)
            } else {
                VStack(spacing: 0) {
                    notchLip
                    if !controller.isCollapsed { hubContent }
                }
                .frame(width: size.width, height: size.height, alignment: .topLeading)
                .background(.black)
                .clipShape(DockNotchShape(radius: controller.isCollapsed ? 12 : 24))
                .environment(\.colorScheme, .dark)
            }
        }
        .frsetThemeChrome()
        .onExitCommand { controller.dismiss() }
        .ignoresSafeArea()
    }

    private var notchLip: some View {
        Button { controller.open(expanded: false) } label: {
            HStack(spacing: 0) {
                Image(systemName: "square.grid.2x2.fill")
                    .frame(maxWidth: .infinity)
                if controller.notchWidth > 0 {
                    Color.clear.frame(width: controller.notchWidth)
                } else {
                    Text("Kitnest").font(.system(size: 12, weight: .semibold))
                }
                Image(systemName: controller.isCollapsed ? "chevron.down" : "chevron.up")
                    .frame(maxWidth: .infinity)
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.white.opacity(0.9))
            .frame(height: controller.topInset)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("悬停展开工具、日历、媒体与窗口；点击后可用键盘操作")
        .accessibilityLabel("展开 Kitnest 刘海组件")
    }

    private var hubContent: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(alignment: .top, spacing: 0) {
                if controller.isExpanded {
                    sidebar.frame(width: 150)
                    Divider()
                }
                VStack(spacing: 0) {
                    if !controller.isExpanded {
                        sectionTabs.padding(12)
                    }
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            if controller.isExpanded {
                                let info = sectionInfo(controller.section)
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(info.title)
                                        .font(.system(size: Theme.TextSize.metric, weight: .semibold))
                                    Text(info.detail)
                                        .font(.system(size: Theme.TextSize.small))
                                        .foregroundStyle(.secondary)
                                }
                            }
                            sectionContent
                        }
                        .padding(controller.isExpanded ? 20 : 12)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            if controller.section == .windows, let icon = controller.hoveredApplication?.icon {
                Image(nsImage: icon).resizable().scaledToFit()
                    .frame(width: 28, height: 28)
            } else {
                Image(systemName: "square.grid.2x2.fill")
                    .font(.system(size: 22)).foregroundStyle(Theme.accent)
                    .frame(width: 28, height: 28)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("Kitnest").font(.system(size: Theme.TextSize.title, weight: .semibold))
                Text(controller.section == .windows ? (controller.hoveredApplication?.localizedName ?? "切换应用窗口") : "工具 · 日历 · 媒体 · 窗口")
                    .font(.system(size: Theme.TextSize.caption)).foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            DockHubButton {
                if controller.isExpanded { controller.collapse() } else { controller.expand() }
            } label: {
                Label(controller.isExpanded ? "收起" : "完整窗",
                      systemImage: controller.isExpanded ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: Theme.TextSize.caption, weight: .medium))
                    .padding(.horizontal, 8).frame(height: 28)
            }
            .keyboardShortcut("d", modifiers: [.command, .shift])
            .help(controller.isExpanded ? "返回顶部刘海组件（⇧⌘D）" : "展开完整控制窗（⇧⌘D）")
            DockHubButton(action: { controller.run(.settings) }) {
                Image(systemName: "gearshape").frame(width: 28, height: 28)
            }
            .keyboardShortcut(",", modifiers: .command)
            .help("设置（⌘,）").accessibilityLabel("打开 Kitnest 设置")
            DockHubButton(action: { controller.run(.manual) }) {
                Image(systemName: "book.closed").frame(width: 28, height: 28)
            }
            .help("使用手册").accessibilityLabel("打开使用手册")
            if !controller.isExpanded {
                DockHubButton(action: { controller.dismiss() }) {
                    Image(systemName: "xmark").font(.system(size: 11, weight: .semibold))
                        .frame(width: 28, height: 28)
                }
                .help("收起（Esc）").accessibilityLabel("收起刘海组件")
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
    }

    private var sectionTabs: some View {
        HStack(spacing: 4) {
            ForEach(DockHubSection.allCases, id: \.rawValue) { section in
                sectionButton(section, sidebar: false)
            }
        }
        .padding(4)
        .background(Theme.insetFill, in: RoundedRectangle(cornerRadius: Theme.Radius.card))
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(DockHubSection.allCases, id: \.rawValue) { section in
                sectionButton(section, sidebar: true)
            }
            Spacer(minLength: 20)
            Text("⌘1–4 切换\n⇧⌘D 收起\nEsc 关闭")
                .font(.system(size: Theme.TextSize.caption)).foregroundStyle(.secondary)
                .lineSpacing(5).padding(.horizontal, 10)
        }
        .padding(10)
        .frame(maxHeight: .infinity, alignment: .topLeading)
    }

    private func sectionButton(_ section: DockHubSection, sidebar: Bool) -> some View {
        let info = sectionInfo(section)
        return DockHubButton(selected: controller.section == section,
                             action: { controller.section = section }) {
            HStack(spacing: 7) {
                Image(systemName: info.symbol).frame(width: 16)
                Text(info.title)
                if sidebar { Spacer(minLength: 0) }
            }
            .font(.system(size: Theme.TextSize.small, weight: .medium))
            .frame(maxWidth: .infinity).padding(.horizontal, sidebar ? 10 : 4)
            .frame(height: sidebar ? 36 : 30)
        }
        .help(info.detail)
        .keyboardShortcut(KeyEquivalent(Character(String(DockHubSection.allCases.firstIndex(of: section)! + 1))), modifiers: .command)
        .accessibilityAddTraits(controller.section == section ? .isSelected : [])
    }

    @ViewBuilder private var sectionContent: some View {
        switch controller.section {
        case .tools:
            VStack(spacing: 12) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                ForEach(Self.tools, id: \.title) { tool in toolButton(tool) }
            }
            }
        case .calendar:
            DockCalendarContent(controller: controller)
        case .media:
            DockMediaControlsView()
        case .windows:
            VStack(spacing: 12) {
                Picker("应用", selection: Binding(get: { controller.hoveredApplication?.processIdentifier },
                    set: { if let pid = $0 { controller.selectApplication(pid) } })) {
                    if controller.hoveredApplication == nil { Text("选择应用").tag(Optional<pid_t>.none) }
                    ForEach(controller.applications, id: \.processIdentifier) { app in
                        Text(app.localizedName ?? "应用").tag(Optional(app.processIdentifier))
                    }
                }
                .accessibilityLabel("选择需要切换窗口的应用")
                windowsContent
            }
        }
    }

    private func toolButton(_ tool: DockHubTool) -> some View {
        let available = controller.isAvailable(tool.action)
        return DockHubButton(action: { controller.run(tool.action) }) {
            VStack(alignment: controller.isExpanded ? .leading : .center, spacing: 8) {
                Image(systemName: tool.symbol).font(.system(size: 20, weight: .medium))
                    .foregroundStyle(Theme.accent).frame(height: 24)
                Text(tool.title).font(.system(size: Theme.TextSize.small, weight: .semibold))
                    .lineLimit(1)
                if controller.isExpanded {
                    Text(tool.detail).font(.system(size: Theme.TextSize.caption))
                        .foregroundStyle(.secondary).lineLimit(2)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, minHeight: controller.isExpanded ? 104 : 76,
                   alignment: controller.isExpanded ? .topLeading : .center)
            .glassCard(radius: Theme.Radius.control)
        }
        .disabled(!available)
        .help(available ? tool.detail : "「\(tool.title)」已在设置中关闭")
    }

    @ViewBuilder private var windowsContent: some View {
        if !controller.accessibilityGranted {
            VStack(spacing: 12) {
                emptyState(symbol: "lock.shield", title: "允许访问应用窗口",
                           detail: "授予辅助功能权限后，可读取并前置真实窗口。")
                DockHubButton(action: { controller.requestAccessibility() }) {
                    Label("授予辅助功能权限", systemImage: "hand.raised")
                        .font(.system(size: Theme.TextSize.small, weight: .medium))
                        .padding(10).frame(maxWidth: .infinity)
                        .glassCard(radius: Theme.Radius.control)
                }
            }
        } else if controller.windows.isEmpty {
            emptyState(symbol: "macwindow",
                       title: controller.hoveredApplication == nil ? "选择上方的应用" : "没有可切换的窗口",
                       detail: controller.hoveredApplication == nil
                           ? "从应用列表选择，在这里查看并切换它的窗口。"
                           : "\(controller.hoveredApplication?.localizedName ?? "当前应用")当前没有可用窗口。")
        } else {
            LazyVStack(spacing: 8) {
                ForEach(controller.windows, id: \.id) { item in windowButton(item) }
            }
        }
    }

    private func windowButton(_ item: DockWindowItem) -> some View {
        DockHubButton(action: { controller.activateWindow(item) }) {
            HStack(spacing: 12) {
                if let thumbnail = item.thumbnail {
                    Image(nsImage: thumbnail).resizable().scaledToFit()
                        .frame(width: controller.isExpanded ? 112 : 64,
                               height: controller.isExpanded ? 70 : 44)
                        .background(Theme.insetFill, in: RoundedRectangle(cornerRadius: Theme.Radius.chip))
                } else {
                    Image(systemName: "macwindow").font(.system(size: 22))
                        .foregroundStyle(.secondary).frame(width: 36, height: 44)
                }
                VStack(alignment: .leading, spacing: 5) {
                    Text(item.title).font(.system(size: Theme.TextSize.body, weight: .medium))
                        .lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                    if item.isMinimized {
                        Label("已最小化", systemImage: "minus.square")
                            .font(.system(size: Theme.TextSize.caption)).foregroundStyle(.secondary)
                    }
                }
                Image(systemName: "arrow.up.forward").font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .padding(10).frame(maxWidth: .infinity, alignment: .leading)
            .glassCard(radius: Theme.Radius.control)
        }
        .help(item.isMinimized ? "恢复并前置：\(item.title)" : "前置：\(item.title)")
    }

    private func emptyState(symbol: String, title: String, detail: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 26)).foregroundStyle(Theme.accent)
            Text(title).font(.system(size: Theme.TextSize.body, weight: .semibold))
            Text(detail).font(.system(size: Theme.TextSize.small)).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(24).frame(maxWidth: .infinity)
        .glassCard()
    }

    private func sectionInfo(_ section: DockHubSection) -> (title: String, symbol: String, detail: String) {
        switch section {
        case .tools: return ("工具", "square.grid.3x3", "常用操作直达 Kitnest 对应功能。")
        case .calendar: return ("日历", "calendar", "浏览日期与农历，选择日期查看当天日程。")
        case .media: return ("媒体", "play.rectangle", "正在播放与媒体控制。")
        case .windows: return ("窗口", "macwindow.on.rectangle", "点击窗口前置，最小化状态显示在窗口标题下。")
        }
    }
}

private struct DockNotchShape: Shape {
    let radius: CGFloat
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - radius))
        path.addQuadCurve(to: CGPoint(x: rect.maxX - radius, y: rect.maxY), control: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX + radius, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.maxY - radius), control: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

private struct DockHubTool {
    let action: DockHubAction
    let title: String
    let symbol: String
    let detail: String
}

private struct DockCalendarContent: View {
    @ObservedObject var controller: DockHubController
    @ObservedObject private var service = CalendarService.shared
    @Stored private var selectedDate = Date()
    @Stored private var events: [CalendarEvent] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            CalendarSectionView(windowProvider: { controller.window }, onSelectDay: { selectDay($0) })
            HStack {
                Text(selectedDate, format: .dateTime.month().day().weekday())
                    .font(.system(size: Theme.TextSize.body, weight: .semibold))
                Spacer(minLength: 4)
                DockHubButton(action: openCalendar) {
                    Label("打开日历", systemImage: "arrow.up.forward.app")
                        .font(.system(size: Theme.TextSize.caption)).padding(6)
                }
                .help("在系统日历中查看和编辑日程")
            }
            if !service.isAuthorized {
                Label("日历未授权，允许完整访问后可显示日程", systemImage: "calendar.badge.exclamationmark")
                    .font(.system(size: Theme.TextSize.small)).foregroundStyle(.secondary)
                    .padding(12).frame(maxWidth: .infinity, alignment: .leading).glassCard()
            } else if events.isEmpty {
                Label("当天无日程", systemImage: "calendar.badge.checkmark")
                    .font(.system(size: Theme.TextSize.small)).foregroundStyle(.secondary)
                    .padding(12).frame(maxWidth: .infinity, alignment: .leading).glassCard()
            } else {
                LazyVStack(spacing: 8) {
                    ForEach(events) { event in eventRow(event) }
                }
            }
        }
        .onAppear { selectDay(selectedDate) }
        .onChange(of: service.isAuthorized) { _ in selectDay(selectedDate) }
    }

    private func selectDay(_ date: Date) {
        selectedDate = date
        let day = Calendar.current.dateInterval(of: .day, for: date)!
        events = service.events(from: day.start, to: day.end)
    }

    private func eventRow(_ event: CalendarEvent) -> some View {
        HStack(alignment: .top, spacing: 10) {
            RoundedRectangle(cornerRadius: Theme.Radius.micro).fill(Theme.accent)
                .frame(width: 3, height: 32)
            VStack(alignment: .leading, spacing: 4) {
                Text(event.title).font(.system(size: Theme.TextSize.body, weight: .medium)).lineLimit(2)
                Group {
                    if event.isAllDay {
                        Text("全天")
                    } else {
                        HStack(spacing: 3) {
                            Text(event.startDate, format: .dateTime.hour().minute())
                            if let endDate = event.endDate {
                                Text("–")
                                Text(endDate, format: .dateTime.hour().minute())
                            }
                        }
                    }
                }
                .font(.system(size: Theme.TextSize.caption)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading).glassCard()
    }

    private func openCalendar() {
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Calendar.app"))
    }
}

private struct DockHubButton<Label: View>: View {
    var selected = false
    var action: () -> Void
    @ViewBuilder var label: () -> Label
    @Environment(\.isEnabled) private var isEnabled
    @Stored private var hovered = false

    var body: some View {
        Button(action: action) {
            label()
                .overlay {
                    RoundedRectangle(cornerRadius: Theme.Radius.control)
                        .fill(Theme.accent.opacity(selected ? 0.14 : (hovered && isEnabled ? 0.08 : 0)))
                        .allowsHitTesting(false)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(SpringyIconButtonStyle(pressedScale: 0.97))
        .opacity(isEnabled ? 1 : 0.45)
        .onHover { hovered = $0 }
        .animation(Theme.Motion.fast, value: hovered)
        .pointingHandCursor()
    }
}
