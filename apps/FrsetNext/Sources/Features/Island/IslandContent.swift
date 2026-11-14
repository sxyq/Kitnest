import SwiftUI

struct IslandRootView: View {
    @ObservedObject var controller: IslandController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Stored private var selectedRecord = 0
    @Stored private var selectedFile = 0
    @Stored private var selectedMetric = IslandMetric.cpu
    @Stored private var settingsSection = 0
    @Stored private var chartStyle = IslandChartStyle.area
    @Stored private var chartSeconds = 60
    @Stored private var selectedDay = 14
    @Stored private var selectedTool = 0
    @Stored private var widgetDropTarget: IslandWidget? = nil

    var body: some View {
        IslandSurface(controller: controller, height: controller.configuration.height) {
            ZStack(alignment: .top) {
                pageContent(controller.page)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .id(controller.page)
                    .transition(.opacity)
            }
            .animation(reduceMotion ? nil : Theme.Motion.page, value: controller.page)
            .clipped()
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onChange(of: controller.page) { _ in controller.expand(takeFocus: true) }
    }

    @ViewBuilder private func pageContent(_ page: IslandPage) -> some View {
        switch page {
        case .home: home
        case .clipboard: recordsPage
        case .transfer: filesPage
        case .monitor: monitorPage
        case .media: mediaPage
        case .calendar: calendarPage
        case .tools: toolsPage
        case .settings: settingsPage
        }
    }

    private var home: some View {
        GeometryReader { geometry in
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
                ForEach(controller.widgetOrder) { item in
                    widget(item) { widgetContent(item) }
                        .frame(height: (geometry.size.height - 6) / 2)
                }
            }.animation(reduceMotion ? nil : Theme.Motion.springSnappy, value: controller.widgetOrder)
        }
    }

    @ViewBuilder private func widgetContent(_ item: IslandWidget) -> some View {
        switch item {
        case .media:
            HStack(spacing: 8) {
                album.frame(width: 40, height: 40)
                VStack(alignment: .leading, spacing: 3) {
                    Text(controller.tracks[controller.track].0).fontWeight(.medium).lineLimit(1)
                    Text(controller.tracks[controller.track].1).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            HStack(spacing: 6) {
                mediaButton("backward.end.fill", label: "模拟上一首") { controller.changeTrack(-1) }
                mediaButton(controller.playing ? "pause.fill" : "play.fill", label: "模拟播放或暂停") { controller.playing.toggle() }
                mediaButton("forward.end.fill", label: "模拟下一首") { controller.changeTrack(1) }
                Slider(value: $controller.volume, in: 0...100).controlSize(.mini).accessibilityLabel("首页模拟音量")
            }
        case .monitor:
            HStack(spacing: 8) {
                ForEach([IslandMetric.cpu, .gpu, .power]) { metric in
                    Button { selectedMetric = metric } label: {
                        Text(metric == .power ? "功耗" : metric.title).font(.system(size: 11))
                            .foregroundStyle(selectedMetric == metric ? metric.color : .secondary)
                    }.buttonStyle(IslandButtonStyle()).accessibilityLabel("首页\(metric.title)趋势")
                }
                Spacer()
                Text("6.4 GB").font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary)
            }
            IslandMonitorChart(metric: selectedMetric, compact: true).frame(maxHeight: .infinity)
        case .clipboard:
            ForEach(IslandSample.clipboard.prefix(2)) { sample in
                Button { selectedRecord = sample.id; controller.page = .clipboard } label: {
                    miniRow(sample.title, icon: sample.icon, note: "")
                }.buttonStyle(IslandButtonStyle())
            }
            HStack {
                Text("系统最近内容").font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Button(action: controller.copyLatest) { Label("复制", systemImage: "doc.on.doc") }
                    .buttonStyle(IslandButtonStyle()).accessibilityLabel("复制系统剪贴板最近内容")
            }
        case .transfer:
            ForEach(IslandSample.files) { sample in
                Button { selectedFile = sample.id; controller.page = .transfer } label: {
                    miniRow(sample.title, icon: sample.icon, note: sample.detail.components(separatedBy: " · ").last!)
                }.buttonStyle(IslandButtonStyle())
            }
        case .calendar:
            HStack(alignment: .top, spacing: 10) {
                VStack(spacing: 2) {
                    Text("\(selectedDay)").font(.system(size: 27, weight: .medium)).monospacedDigit()
                    Text("11 月").font(.system(size: 11)).foregroundStyle(.secondary)
                }.frame(width: 40)
                VStack(alignment: .leading, spacing: 8) {
                    eventRow(0, title: "14:00 项目同步")
                    eventRow(1, title: "16:30 设计评审")
                    Text("\(2 - controller.completedEvents.count) 项待办").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
        case .tools:
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 3), spacing: 6) {
                ForEach(tools.indices, id: \.self) { index in
                    Button { selectedTool = index; controller.page = .tools } label: {
                        VStack(spacing: 3) {
                            Image(systemName: tools[index].1).font(.system(size: 15))
                            Text(tools[index].0).font(.system(size: 10)).lineLimit(1)
                        }.frame(maxWidth: .infinity).frame(height: 32)
                    }.buttonStyle(IslandButtonStyle())
                }
            }
        }
    }

    private var recordsPage: some View {
        VStack(spacing: 8) {
            HStack(spacing: Theme.Space.md) {
                Image(systemName: "magnifyingglass")
                Text("搜索文字、链接、代码")
                Spacer()
            }.foregroundStyle(.secondary).padding(.horizontal, 10).frame(height: 30).background(cardColor, in: RoundedRectangle(cornerRadius: IslandLayout.controlRadius, style: .continuous))
            HStack(alignment: .top, spacing: 12) {
                ScrollView {
                LazyVStack(spacing: Theme.Space.xs) {
                    ForEach(IslandSample.clipboard) { sample in
                        sampleRow(sample, selected: selectedRecord == sample.id) { selectedRecord = sample.id }
                    }
                }
                }.frame(maxWidth: .infinity)
                    .onMoveCommand { direction in
                        if direction == .down { selectedRecord = min(selectedRecord + 1, IslandSample.clipboard.count - 1) }
                        if direction == .up { selectedRecord = max(selectedRecord - 1, 0) }
                    }
                divider
                let sample = IslandSample.clipboard[selectedRecord]
                VStack(alignment: .leading, spacing: Theme.Space.lg) {
                    Text(sample.detail).font(.system(size: Theme.TextSize.caption)).foregroundStyle(.secondary)
                    Text(sample.title).font(.system(size: Theme.TextSize.title, weight: .medium))
                    ScrollView {
                        if sample.id == 4 {
                            imageSample
                        } else if !sample.children.isEmpty {
                            ForEach(sample.children, id: \.self) { Label($0, systemImage: "doc") }
                        } else {
                            Text(sample.body).font(sample.id == 2 ? .system(size: Theme.TextSize.small, design: .monospaced) : .system(size: Theme.TextSize.small))
                                .foregroundStyle(.primary)
                                .lineSpacing(Theme.Space.sm).frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    Text("演示记录 · 不写入系统剪贴板").font(.system(size: Theme.TextSize.caption)).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(maxHeight: .infinity)
        }.font(.system(size: Theme.TextSize.small))
    }

    private var filesPage: some View {
        VStack(spacing: 8) {
            heading("本地中转", detail: "文件与文件夹")
            HStack(alignment: .top, spacing: 12) {
                ScrollView {
                LazyVStack(spacing: Theme.Space.xs) {
                    ForEach(IslandSample.files) { sample in
                        sampleRow(sample, selected: selectedFile == sample.id) { selectedFile = sample.id }
                    }
                }
                }.frame(maxWidth: .infinity)
                    .onMoveCommand { direction in
                        if direction == .down { selectedFile = min(selectedFile + 1, IslandSample.files.count - 1) }
                        if direction == .up { selectedFile = max(selectedFile - 1, 0) }
                    }
                divider
                let sample = IslandSample.files[selectedFile]
                VStack(alignment: .leading, spacing: Theme.Space.lg) {
                    Text(sample.detail).font(.system(size: Theme.TextSize.caption)).foregroundStyle(.secondary)
                    Text(sample.title).font(.system(size: Theme.TextSize.title, weight: .medium))
                    ScrollView {
                        VStack(alignment: .leading, spacing: Theme.Space.md) {
                            if !sample.children.isEmpty {
                                ForEach(sample.children, id: \.self) { name in
                                    Label(name, systemImage: name.hasSuffix("/") ? "folder" : "doc.text")
                                        .font(.system(size: Theme.TextSize.small)).padding(.vertical, Theme.Space.xxs)
                                }
                                Text(sample.body).font(.system(size: Theme.TextSize.caption)).foregroundStyle(.secondary)
                            } else if sample.id == 2 {
                                imageSample
                            } else {
                                Text(sample.body).font(.system(size: Theme.TextSize.small)).lineSpacing(Theme.Space.sm)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(maxHeight: .infinity)
            Text("固定演示 · 选择文件查看详情").font(.system(size: Theme.TextSize.caption)).foregroundStyle(.secondary)
        }
    }

    private var monitorPage: some View {
        GeometryReader { geometry in
            HStack(spacing: 10) {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 2), spacing: 6) {
                    ForEach(controller.metricOrder) { metric in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Button { selectedMetric = metric } label: { Text(metric.title).font(.system(size: 11)) }
                                    .buttonStyle(IslandButtonStyle()).accessibilityLabel("选择\(metric.title)指标")
                                Spacer(minLength: 0)
                                Image(systemName: "line.3.horizontal").font(.system(size: 10)).foregroundStyle(.secondary)
                                    .draggable("metric:" + metric.rawValue).accessibilityLabel("拖动\(metric.title)指标")
                            }
                            Button { selectedMetric = metric } label: {
                                Text(metric.format(metric.values.last!)).font(.system(size: 15, weight: .medium)).monospacedDigit()
                                    .foregroundStyle(metric.color).frame(maxWidth: .infinity, alignment: .leading)
                            }.buttonStyle(IslandButtonStyle())
                            MonitorAreaSparkline(values: metric.values, color: metric.color, upperBound: metric.upperBound)
                                .frame(height: 18).allowsHitTesting(false)
                        }.padding(10).frame(height: (geometry.size.height - 12) / 3)
                            .background(selectedMetric == metric ? metric.color.opacity(0.10) : cardColor)
                            .islandGlow(enabled: controller.glowEnabled && controller.expanded && controller.page == .monitor)
                            .glassCard(radius: 16, fill: .clear, stroke: selectedMetric == metric ? metric.color.opacity(0.55) : IslandLayout.cardStroke)
                            .dropDestination(for: String.self) { values, _ in
                                guard let value = values.first, value.hasPrefix("metric:"), let source = IslandMetric(rawValue: String(value.dropFirst(7))) else { return false }
                                controller.metricOrder.islandMove(source, to: controller.metricOrder.firstIndex(of: metric)!)
                                return true
                            }
                    }
                }.frame(width: 236).animation(reduceMotion ? nil : Theme.Motion.springSnappy, value: controller.metricOrder)
                VStack(spacing: 10) {
                    heading(selectedMetric.title + " · " + selectedMetric.unit, detail: "固定演示数据")
                    HStack(spacing: 12) {
                        Picker("图形", selection: $chartStyle) {
                            ForEach(IslandChartStyle.allCases) { style in Text(style.rawValue).tag(style) }
                        }.pickerStyle(.segmented).labelsHidden()
                        Picker("时段", selection: $chartSeconds) {
                            Text("30 秒").tag(30)
                            Text("60 秒").tag(60)
                        }.pickerStyle(.segmented).labelsHidden().frame(width: 112)
                    }
                    IslandMonitorChart(metric: selectedMetric, style: chartStyle, seconds: chartSeconds)
                    let values = chartSeconds == 30 ? Array(selectedMetric.values.suffix(12)) : selectedMetric.values
                    HStack {
                        statistic("平均", value: selectedMetric.format(values.reduce(0, +) / Double(values.count)))
                        statistic("峰值", value: selectedMetric.format(values.max()!))
                        statistic("当前", value: selectedMetric.format(values.last!))
                    }
                    Text("悬停查看 · 点击固定 · 拖动或方向键定位").font(.system(size: 10)).foregroundStyle(.secondary)
                }.padding(12).frame(maxWidth: .infinity, maxHeight: .infinity)
                    .glassCard(radius: IslandLayout.cardRadius, fill: cardColor, stroke: IslandLayout.cardStroke)
            }
        }
    }

    private func statistic(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).foregroundStyle(.secondary)
            Text(value).monospacedDigit().fontWeight(.medium)
        }.font(.system(size: 11)).frame(maxWidth: .infinity, alignment: .leading)
    }

    private var mediaPage: some View {
        HStack(spacing: 0) {
            album.frame(width: 190, height: 190).padding(20)
            divider
            VStack(alignment: .leading, spacing: 12) {
                Text(controller.tracks[controller.track].0).font(.system(size: Theme.TextSize.metric, weight: .medium))
                Text(controller.tracks[controller.track].1 + " · 模拟媒体").font(.system(size: Theme.TextSize.small)).foregroundStyle(.secondary)
                Slider(value: $controller.seek, in: 0...240).accessibilityLabel("模拟播放进度")
                HStack(spacing: 24) {
                    mediaButton("backward.end.fill", label: "模拟上一首") { controller.changeTrack(-1) }
                    Button { controller.playing.toggle() } label: {
                        Image(systemName: controller.playing ? "pause.fill" : "play.fill").frame(width: 36, height: 36)
                    }.buttonStyle(IslandButtonStyle()).accessibilityLabel("模拟播放或暂停")
                    mediaButton("forward.end.fill", label: "模拟下一首") { controller.changeTrack(1) }
                    Spacer()
                    Text("\(Int(controller.seek) / 60):\(String(format: "%02d", Int(controller.seek) % 60)) / 4:00").font(.system(size: Theme.TextSize.caption)).foregroundStyle(.secondary)
                }
                Divider()
                HStack {
                    Label("音量", systemImage: "speaker.wave.2")
                    Slider(value: $controller.volume, in: 0...100).accessibilityLabel("模拟音量")
                    Text("\(Int(controller.volume))%").monospacedDigit().frame(width: 36)
                }.font(.system(size: Theme.TextSize.small))
                Text("仅演示控制状态，不改变系统音量").font(.system(size: Theme.TextSize.caption)).foregroundStyle(.secondary)
            }.padding(18).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                .islandGlow(enabled: controller.glowEnabled && controller.expanded && controller.page == .media)
        }.glassCard(radius: IslandLayout.cardRadius, fill: cardColor, stroke: IslandLayout.cardStroke)
    }

    private var calendarPage: some View {
        HStack(spacing: 0) {
            VStack(spacing: 8) {
            heading("2026 年 11 月", detail: "模拟日程")
            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 7), spacing: Theme.Space.sm) {
                ForEach(["日", "一", "二", "三", "四", "五", "六"], id: \.self) { day in
                    Text(day).font(.system(size: Theme.TextSize.caption)).foregroundStyle(.secondary).frame(height: 18)
                }
                ForEach(1...35, id: \.self) { day in
                    Button { selectedDay = day } label: {
                        Text(day <= 30 ? "\(day)" : "").font(.system(size: Theme.TextSize.small)).frame(maxWidth: .infinity).frame(height: 26)
                            .background(day == selectedDay ? Theme.accent(for: nil) : cardColor, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }.buttonStyle(IslandButtonStyle()).disabled(day > 30)
                }
            }
            }.padding(12).frame(maxWidth: .infinity)
                .islandGlow(enabled: controller.glowEnabled && controller.expanded && controller.page == .calendar)
            divider
            VStack(alignment: .leading, spacing: 18) {
                Text("\(selectedDay) 日 · 日程").font(.system(size: Theme.TextSize.title, weight: .medium))
                eventRow(0, title: "14:00 项目同步")
                eventRow(1, title: "16:30 设计评审")
                Spacer(minLength: 0)
                Button(action: controller.copyDate) { Label("复制今天日期", systemImage: "doc.on.doc").padding(8) }
                    .buttonStyle(IslandButtonStyle())
            }.font(.system(size: Theme.TextSize.small)).padding(18).frame(width: 270)
                .islandGlow(enabled: controller.glowEnabled && controller.expanded && controller.page == .calendar)
        }.glassCard(radius: IslandLayout.cardRadius, fill: cardColor, stroke: IslandLayout.cardStroke)
    }

    private var toolsPage: some View {
        HStack(spacing: 10) {
            VStack(spacing: 6) {
                ForEach(tools.indices, id: \.self) { index in
                    Button { selectedTool = index } label: {
                        Label(tools[index].0, systemImage: tools[index].1).frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10).background(selectedTool == index ? Theme.accent(for: nil).opacity(0.15) : cardColor,
                                                        in: RoundedRectangle(cornerRadius: IslandLayout.controlRadius, style: .continuous))
                    }.buttonStyle(IslandButtonStyle()).accessibilityLabel("演示" + tools[index].0)
                }
            }.frame(width: 180)
            VStack(alignment: .leading, spacing: 14) {
                Label(tools[selectedTool].0, systemImage: tools[selectedTool].1).font(.system(size: 17, weight: .medium))
                Text(toolDescriptions[selectedTool]).foregroundStyle(.secondary)
                imageSample.frame(maxHeight: .infinity)
                HStack {
                    Text("仅演示界面，不启动采集").font(.system(size: 11)).foregroundStyle(.secondary)
                    Spacer()
                    Button { controller.feedback = tools[selectedTool].0 + " · 已演示操作反馈" } label: {
                        Text("演示操作").padding(8).background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: IslandLayout.controlRadius))
                    }.buttonStyle(IslandButtonStyle())
                }
            }.padding(16).frame(maxWidth: .infinity, maxHeight: .infinity)
                .islandGlow(enabled: controller.glowEnabled && controller.expanded && controller.page == .tools)
                .glassCard(radius: IslandLayout.cardRadius, fill: cardColor, stroke: IslandLayout.cardStroke)
        }.font(.system(size: Theme.TextSize.small))
    }

    private var settingsPage: some View {
        VStack(spacing: 10) {
            Picker("设置分组", selection: $settingsSection) {
                Text("收起态图标").tag(0)
                Text("材质与交互").tag(1)
                Text("组件排列").tag(2)
            }.pickerStyle(.segmented).labelsHidden()
            if settingsSection == 2 {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 6) {
                    ForEach(controller.widgetOrder) { item in
                        let index = controller.widgetOrder.firstIndex(of: item)!
                        HStack(spacing: 6) {
                            Text("\(index + 1)").monospacedDigit().foregroundStyle(.secondary)
                            Label(item.title, systemImage: item.icon).lineLimit(1)
                            Spacer(minLength: 0)
                            Button { moveWidget(item, by: -1) } label: { Image(systemName: "chevron.left") }
                                .buttonStyle(IslandButtonStyle()).disabled(index == 0).accessibilityLabel("\(item.title)向前排列")
                            Button { moveWidget(item, by: 1) } label: { Image(systemName: "chevron.right") }
                                .buttonStyle(IslandButtonStyle()).disabled(index == controller.widgetOrder.count - 1).accessibilityLabel("\(item.title)向后排列")
                            Image(systemName: "line.3.horizontal").foregroundStyle(.secondary).draggable("widget:" + item.rawValue)
                        }.font(.system(size: 12)).padding(12).frame(height: 56)
                            .glassCard(radius: 16, fill: cardColor, stroke: IslandLayout.cardStroke)
                            .dropDestination(for: String.self) { values, _ in reorderWidget(values, before: item) }
                    }
                }.animation(reduceMotion ? nil : Theme.Motion.springSnappy, value: controller.widgetOrder)
                Text("拖动把手调整首页顺序，也可使用左右按钮。排列在关闭、重新展开后保留。").font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer(minLength: 0)
            } else {
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 12) {
                    if settingsSection == 0 {
                        ForEach(controller.peekOrder) { peek in
                            Toggle(isOn: Binding(
                                get: { controller.visiblePeeks.contains(peek) },
                                set: { if $0 { controller.visiblePeeks.insert(peek) } else { controller.visiblePeeks.remove(peek) } }
                            )) { Label(peek.title, systemImage: peek.icon).draggable("peek:" + peek.rawValue) }
                            .dropDestination(for: String.self) { values, _ in
                                guard let value = values.first, value.hasPrefix("peek:"), let source = IslandPeek(rawValue: String(value.dropFirst(5))) else { return false }
                                controller.peekOrder.islandMove(source, to: controller.peekOrder.firstIndex(of: peek)!)
                                return true
                            }
                        }
                    } else {
                        Toggle("通透黑色玻璃", isOn: $controller.usesGlass)
                        Toggle("组件鼠标辉光", isOn: $controller.glowEnabled)
                        Toggle("图标附带信息", isOn: $controller.peeksShowValues)
                        Toggle("点击图标直接操作", isOn: $controller.peeksQuickActions)
                    }
                }.toggleStyle(.switch).controlSize(.small).padding(16)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                divider
                VStack(alignment: .leading, spacing: 12) {
                    Text(settingsSection == 0 ? "收起态保持贴合刘海" : "焦点前后材质一致")
                        .font(.system(size: Theme.TextSize.title, weight: .medium))
                    Text(settingsSection == 0 ? "关闭所有图标时恢复硬件刘海尺寸。启用后图标分列刘海两侧，不覆盖摄像头。" : "点击不会改变通透度。辉光只在鼠标所在组件绘制，离开后停止。")
                    Text("复制 → 系统剪贴板最近内容\n播放 → 模拟播放／暂停\n日期 → 复制今天日期\n功耗 → 打开模拟监测页")
                    Text("关闭直接操作后，图标改为打开对应页面。").foregroundStyle(.secondary)
                }.font(.system(size: Theme.TextSize.caption)).padding(16)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }.glassCard(radius: IslandLayout.cardRadius, fill: cardColor, stroke: IslandLayout.cardStroke)
            }
            HStack {
                Button("恢复默认") {
                    controller.usesGlass = true
                    controller.visiblePeeks.removeAll()
                    controller.peeksShowValues = true
                    controller.peeksQuickActions = true
                    controller.glowEnabled = true
                    controller.widgetOrder = IslandWidget.allCases
                    controller.metricOrder = IslandMetric.allCases
                    controller.peekOrder = IslandPeek.allCases
                }.buttonStyle(IslandButtonStyle())
                Spacer()
                Text("仅当前 Demo 生效").foregroundStyle(.secondary)
            }.font(.system(size: Theme.TextSize.caption))
        }
    }

    private let cardColor = IslandLayout.cardFill
    private let tools = [("截图", "camera.viewfinder"), ("录屏", "record.circle"), ("屏幕取字", "text.viewfinder"),
                         ("全局搜索", "magnifyingglass"), ("取色", "eyedropper"), ("压缩与解压", "archivebox")]
    private let toolDescriptions = ["框选、标注、复制；沿用截图动作条。", "区域录制、指针与按键效果。", "识别区域内的文字并整理正文。", "搜索文件、近期内容和应用入口。", "查看颜色值并切换颜色格式。", "查看归档目录、压缩与解压进度。"]
    private var divider: some View { Color.white.opacity(0.1).frame(width: Theme.Stroke.hairline) }
    private var album: some View {
        RoundedRectangle(cornerRadius: IslandLayout.cardRadius, style: .continuous)
            .fill(LinearGradient(colors: [Color(red: 0.16, green: 0.28, blue: 0.38), Color(red: 0.49, green: 0.56, blue: 0.53)],
                                 startPoint: .topLeading, endPoint: .bottomTrailing))
            .overlay { Image(systemName: "music.note").foregroundStyle(.white.opacity(0.8)) }
    }
    private var imageSample: some View {
        VStack(alignment: .leading, spacing: Theme.Space.lg) {
            Label("首页交互说明", systemImage: "rectangle.tophalf.inset.filled")
            ForEach(0..<4) { index in
                RoundedRectangle(cornerRadius: Theme.Radius.micro, style: .continuous).fill(.white.opacity(0.12))
                    .frame(width: index == 1 ? 130 : 180, height: 6)
            }
        }.font(.system(size: Theme.TextSize.small)).padding(Theme.Space.xl).frame(maxWidth: .infinity, alignment: .center)
            .background(Theme.accent(for: nil).opacity(0.12), in: RoundedRectangle(cornerRadius: IslandLayout.controlRadius, style: .continuous))
    }

    private func widget<Content: View>(_ item: IslandWidget,
                                      @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Button { controller.page = item.page } label: {
                    Label(item.title, systemImage: item.icon).fontWeight(.medium)
                }.buttonStyle(IslandButtonStyle()).accessibilityLabel("打开" + item.title)
                Spacer(minLength: 0)
                Button { controller.feedback = "拖动把手或用方向键排列" } label: {
                    Image(systemName: "line.3.horizontal").font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 18, height: 18)
                }.buttonStyle(IslandButtonStyle()).draggable("widget:" + item.rawValue)
                    .onMoveCommand { direction in
                        if direction == .left || direction == .up { moveWidget(item, by: -1) }
                        if direction == .right || direction == .down { moveWidget(item, by: 1) }
                    }.accessibilityLabel("拖动排列" + item.title)
            }.font(.system(size: 12))
            content().font(.system(size: Theme.TextSize.small))
            Spacer(minLength: 0)
        }.padding(10).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .islandGlow(enabled: controller.glowEnabled && controller.expanded && controller.page == .home)
            .glassCard(radius: IslandLayout.cardRadius, fill: cardColor, stroke: widgetDropTarget == item ? .white.opacity(0.5) : IslandLayout.cardStroke)
            .dropDestination(for: String.self) { values, _ in reorderWidget(values, before: item) }
                isTargeted: { targeted in widgetDropTarget = targeted ? item : nil }
    }

    private func reorderWidget(_ values: [String], before item: IslandWidget) -> Bool {
        guard let value = values.first, value.hasPrefix("widget:"), let source = IslandWidget(rawValue: String(value.dropFirst(7))) else { return false }
        controller.widgetOrder.islandMove(source, to: controller.widgetOrder.firstIndex(of: item)!)
        widgetDropTarget = nil
        return true
    }

    private func moveWidget(_ item: IslandWidget, by step: Int) {
        let index = controller.widgetOrder.firstIndex(of: item)!
        controller.widgetOrder.islandMove(item, to: min(max(index + step, 0), controller.widgetOrder.count - 1))
    }

    private func eventRow(_ index: Int, title: String) -> some View {
        let completed = controller.completedEvents.contains(index)
        return Button {
            if completed { controller.completedEvents.remove(index) } else { controller.completedEvents.insert(index) }
        } label: {
            Label(title, systemImage: completed ? "checkmark.circle.fill" : "circle")
                .strikethrough(completed).foregroundStyle(completed ? .secondary : .primary).font(.system(size: 11))
        }.buttonStyle(IslandButtonStyle()).accessibilityLabel(title + (completed ? "，已完成" : "，待完成"))
    }

    private func miniRow(_ title: String, icon: String, note: String) -> some View {
        HStack(spacing: Theme.Space.md) {
            Image(systemName: icon).foregroundStyle(.secondary)
            Text(title).lineLimit(1)
            Spacer(minLength: 0)
            Text(note).font(.system(size: Theme.TextSize.caption)).foregroundStyle(.secondary)
        }.font(.system(size: Theme.TextSize.caption))
    }

    private func sampleRow(_ sample: IslandSample, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: Theme.Space.md) {
                Image(systemName: sample.icon).foregroundStyle(selected ? Theme.accent(for: nil) : .white.opacity(0.5)).frame(width: 18)
                VStack(alignment: .leading, spacing: Theme.Space.xs) {
                    Text(sample.title).font(.system(size: Theme.TextSize.small)).lineLimit(1)
                    Text(sample.detail).font(.system(size: Theme.TextSize.caption)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }.padding(Theme.Space.lg).frame(maxWidth: .infinity, alignment: .leading)
                .background(selected ? Theme.accent(for: nil).opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: IslandLayout.controlRadius, style: .continuous))
        }.buttonStyle(IslandButtonStyle()).accessibilityLabel(sample.title)
            .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func heading(_ title: String, detail: String) -> some View {
        HStack {
            Text(title).font(.system(size: Theme.TextSize.small, weight: .medium))
            Spacer()
            Text(detail).font(.system(size: Theme.TextSize.caption)).foregroundStyle(.secondary)
        }
    }

    private func mediaButton(_ icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: icon).frame(width: 24, height: 24) }
            .buttonStyle(IslandButtonStyle(help: label)).accessibilityLabel(label)
    }
}

