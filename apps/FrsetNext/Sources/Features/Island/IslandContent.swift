import SwiftUI

struct IslandRootView: View {
    @ObservedObject var controller: IslandController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Stored private var selectedRecord = 0
    @Stored private var selectedFile = 0
    @Stored private var selectedMetric = 0

    var body: some View {
        GeometryReader { geometry in
            IslandSurface(configuration: controller.configuration, expanded: controller.expanded,
                          page: $controller.page, notchWidth: controller.notchWidth,
                          notchHeight: controller.notchHeight, height: min(controller.height, geometry.size.height),
                          onCollapse: controller.collapse, onOpen: { controller.expand(takeFocus: true) }) {
                pageContent.id(controller.page)
                    .transition(.opacity.combined(with: .offset(y: reduceMotion ? 0 : 4)))
                    .animation(.easeOut(duration: reduceMotion ? 0.10 : 0.14), value: controller.page)
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .onChange(of: controller.page) { _ in controller.expand(takeFocus: true) }
    }

    @ViewBuilder private var pageContent: some View {
        switch controller.page {
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
        VStack(spacing: 9) {
            HStack(spacing: 9) {
                widget("系统监测", icon: "waveform.path.ecg", page: .monitor, height: 197) {
                    metricLine([("12%", "CPU"), ("6.4 GB", "内存"), ("18 KB/s", "网络")])
                    metricLine([("8.6 W", "整机"), ("2.1 W", "CPU"), ("0.8 W", "GPU")])
                    IslandTrend().stroke(Color.blue.opacity(0.7), style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))
                        .frame(height: 30).padding(.top, 8)
                    Text("电池 84% · 42°C").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                VStack(spacing: 9) {
                    widget("媒体", icon: "music.note", page: .media, height: 94) {
                        HStack(spacing: 9) {
                            album.frame(width: 38, height: 38)
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Quiet Hours").lineLimit(1)
                                Text("Lo-fi Session").font(.system(size: 11)).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                            inertIcon("play.fill", label: "播放 · 仅展示")
                        }
                    }
                    widget("日历", icon: "calendar", page: .calendar, height: 94) {
                        HStack(spacing: 9) {
                            Text("14").font(.system(size: 28, weight: .medium))
                            Text("周六 · 11 月\n14:00 项目同步").font(.system(size: 11)).foregroundStyle(.secondary)
                            Spacer()
                        }
                    }
                }.frame(maxWidth: .infinity)
            }
            HStack(spacing: 9) {
                widget("近期剪贴板", icon: "doc.on.clipboard", page: .clipboard, height: 94) {
                    miniRow("周五交付清单", icon: "text.alignleft", note: "刚刚")
                    miniRow("Apple 设计资源", icon: "link", note: "2 分钟")
                }
                widget("文件中转", icon: "tray", page: .transfer, height: 94) {
                    miniRow("设计资料", icon: "folder", note: "3 项")
                    miniRow("设计说明.md", icon: "doc.text", note: "12 KB")
                }
            }
            HStack(spacing: 9) {
                widget("快捷工具", icon: "square.grid.2x2", page: .tools, height: 94) {
                    HStack(spacing: 8) {
                        inertButton("截图")
                        inertButton("工具箱")
                        Spacer(minLength: 0)
                    }
                }
                widget("音量", icon: "speaker.wave.2", page: .tools, height: 94) {
                    HStack(spacing: 10) {
                        Text("56%").font(.system(size: 11)).foregroundStyle(.secondary)
                        progress(0.56).frame(height: 5)
                    }.padding(.top, 8)
                    Text("内建扬声器").font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var recordsPage: some View {
        VStack(spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                Text("搜索文字、链接、代码")
                Spacer()
            }.foregroundStyle(.secondary).padding(9).background(cardColor, in: RoundedRectangle(cornerRadius: 8))
            HStack(alignment: .top, spacing: 14) {
                VStack(spacing: 3) {
                    ForEach(IslandSample.clipboard) { sample in
                        sampleRow(sample, selected: selectedRecord == sample.id) { selectedRecord = sample.id }
                    }
                    Spacer(minLength: 0)
                }.frame(width: 210)
                divider
                let sample = IslandSample.clipboard[selectedRecord]
                VStack(alignment: .leading, spacing: 10) {
                    Text(sample.detail).font(.system(size: 11)).foregroundStyle(.secondary)
                    Text(sample.title).font(.system(size: 15, weight: .medium))
                    ScrollView {
                        Text(sample.body).font(sample.id == 2 ? .system(size: 12, design: .monospaced) : .system(size: 12))
                            .foregroundStyle(sample.id == 2 ? Color.blue : .white.opacity(0.85))
                            .lineSpacing(5).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    inertButton("复制完整内容", primary: true)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        }.font(.system(size: 12))
    }

    private var filesPage: some View {
        VStack(spacing: 12) {
            heading("本地中转", detail: "文件与文件夹")
            HStack(alignment: .top, spacing: 14) {
                VStack(spacing: 3) {
                    ForEach(IslandSample.files) { sample in
                        sampleRow(sample, selected: selectedFile == sample.id) { selectedFile = sample.id }
                    }
                    Spacer(minLength: 0)
                }.frame(width: 210)
                divider
                let sample = IslandSample.files[selectedFile]
                VStack(alignment: .leading, spacing: 10) {
                    Text(sample.detail).font(.system(size: 11)).foregroundStyle(.secondary)
                    Text(sample.title).font(.system(size: 15, weight: .medium))
                    if !sample.children.isEmpty {
                        ForEach(sample.children, id: \.self) { name in
                            Label(name, systemImage: name.hasSuffix("/") ? "folder" : "doc.text")
                                .font(.system(size: 12)).padding(.vertical, 3)
                        }
                        Text(sample.body).font(.system(size: 11)).foregroundStyle(Color.blue)
                    } else if sample.id == 2 {
                        imageSample
                    } else {
                        Text(sample.body).font(.system(size: 12)).lineSpacing(5)
                    }
                    Spacer(minLength: 0)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            Text("拖入文件暂存 · 拖出到目标应用").font(.system(size: 12)).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity).frame(height: 48)
                .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(.white.opacity(0.15), style: StrokeStyle(lineWidth: 1, dash: [4, 4])))
            HStack {
                Spacer()
                inertButton("预览文件")
                inertButton("复制所选文件", primary: true)
            }
        }
    }

    private var monitorPage: some View {
        VStack(spacing: 12) {
            subheading(.monitor)
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 9) {
                ForEach(Array(metrics.enumerated()), id: \.offset) { index, item in
                    Button { selectedMetric = index } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(item.0).font(.system(size: 12))
                            Text(item.1).font(.system(size: 18, weight: .medium)).monospacedDigit()
                            Text(item.2).font(.system(size: 11)).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
                            .background(selectedMetric == index ? Color.blue.opacity(0.15) : cardColor,
                                        in: RoundedRectangle(cornerRadius: 10))
                    }.buttonStyle(IslandButtonStyle())
                }
            }
            Text("\(metrics[selectedMetric].0) · 最近 30 秒").font(.system(size: 11)).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            IslandTrend().stroke(Color.blue, style: StrokeStyle(lineWidth: 2, lineJoin: .round)).frame(height: 42)
        }
    }

    private var mediaPage: some View {
        VStack(spacing: 12) {
            subheading(.media)
            album.frame(width: 88, height: 88)
            Text("Quiet Hours").font(.system(size: 18, weight: .medium))
            Text("Lo-fi Session").font(.system(size: 12)).foregroundStyle(.secondary)
            progress(0.36).frame(width: 300, height: 4).padding(.top, 8)
            HStack(spacing: 24) {
                inertIcon("backward.end.fill", label: "上一首 · 仅展示")
                inertIcon("play.fill", label: "播放 · 仅展示")
                inertIcon("forward.end.fill", label: "下一首 · 仅展示")
            }.font(.system(size: 20)).padding(.vertical, 8)
            Text("1:26 / 4:00").font(.system(size: 11)).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity)
    }

    private var calendarPage: some View {
        VStack(spacing: 12) {
            subheading(.calendar)
            heading("2026 年 11 月", detail: "模拟日程")
            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 7), spacing: 5) {
                ForEach(["日", "一", "二", "三", "四", "五", "六"], id: \.self) { day in
                    Text(day).font(.system(size: 11)).foregroundStyle(.secondary).frame(height: 22)
                }
                ForEach(1...35, id: \.self) { day in
                    Text(day <= 30 ? "\(day)" : "").font(.system(size: 12)).frame(maxWidth: .infinity).frame(height: 30)
                        .background(day == 14 ? Color.blue : cardColor, in: RoundedRectangle(cornerRadius: 6))
                }
            }
            HStack {
                Text("14 日").foregroundStyle(Color.blue)
                Text("14:00 项目同步 · 16:30 设计评审")
                Spacer()
            }.font(.system(size: 12)).padding(.top, 8)
        }
    }

    private var toolsPage: some View {
        VStack(spacing: 14) {
            subheading(.tools)
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 9) {
                ForEach(Array(tools.enumerated()), id: \.offset) { _, tool in
                    Button {} label: {
                        Label(tool.0, systemImage: tool.1).frame(maxWidth: .infinity, alignment: .leading)
                            .padding(13).background(cardColor, in: RoundedRectangle(cornerRadius: 9))
                    }.buttonStyle(IslandButtonStyle())
                }
            }
            heading("音量", detail: "56% · 内建扬声器")
            progress(0.56).frame(height: 5)
        }.font(.system(size: 12))
    }

    private var settingsPage: some View {
        VStack(spacing: 14) {
            subheading(.settings)
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 0) {
                ForEach(["刘海入口", "文本剪贴板", "文件中转", "系统监测", "媒体组件", "日历组件", "快捷工具", "音量组件"], id: \.self) { title in
                    HStack {
                        Text(title)
                        Spacer()
                        Image(systemName: "checkmark.square.fill").foregroundStyle(Color.blue)
                    }.font(.system(size: 12)).padding(.vertical, 11).padding(.horizontal, 6)
                        .overlay(alignment: .bottom) { Color.white.opacity(0.08).frame(height: 0.5) }
                }
            }
            heading("布局与动效", detail: "仅展示，不写入设置")
            HStack {
                Text("展开 200ms · 收回 160ms · 切页 140ms")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
            }
            HStack {
                inertButton("恢复本模块默认")
                Spacer()
                inertButton("取消")
                inertButton("保存并应用", primary: true)
            }
        }
    }

    private let cardColor = Color(white: 0.082)
    private let metrics = [("CPU", "12%", "8 个核心 · 42°C"), ("GPU", "8%", "图形负载"),
                           ("内存", "6.4 GB", "总容量 16 GB"), ("网络", "18 KB/s", "上传 2 KB/s"),
                           ("整机功耗", "8.6 W", "CPU 2.1 W · GPU 0.8 W"), ("电池", "84%", "剩余约 6 小时")]
    private let tools = [("截图", "camera.viewfinder"), ("录屏", "record.circle"), ("屏幕取字", "text.viewfinder"),
                         ("全局搜索", "magnifyingglass"), ("取色", "eyedropper"), ("压缩与解压", "archivebox")]
    private var divider: some View { Color.white.opacity(0.1).frame(width: 0.5) }
    private var album: some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(LinearGradient(colors: [Color(red: 0.16, green: 0.28, blue: 0.38), Color(red: 0.49, green: 0.56, blue: 0.53)],
                                 startPoint: .topLeading, endPoint: .bottomTrailing))
            .overlay { Image(systemName: "music.note").foregroundStyle(.white.opacity(0.8)) }
    }
    private var imageSample: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("首页交互说明", systemImage: "rectangle.tophalf.inset.filled")
            ForEach(0..<4) { index in
                RoundedRectangle(cornerRadius: 3).fill(.white.opacity(0.12))
                    .frame(width: index == 1 ? 130 : 180, height: 6)
            }
        }.font(.system(size: 12)).padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.blue.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }

    private func widget<Content: View>(_ title: String, icon: String, page: IslandPage, height: CGFloat,
                                      @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { controller.page = page } label: {
                Label(title, systemImage: icon).frame(maxWidth: .infinity, alignment: .leading)
            }.buttonStyle(IslandButtonStyle()).font(.system(size: 12))
            content().font(.system(size: 12))
            Spacer(minLength: 0)
        }.padding(10).frame(maxWidth: .infinity, alignment: .leading).frame(height: height)
            .background(cardColor, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.white.opacity(0.08), lineWidth: 0.5))
    }

    private func metricLine(_ values: [(String, String)]) -> some View {
        HStack(spacing: 4) {
            ForEach(values, id: \.1) { value, label in
                VStack(alignment: .leading, spacing: 4) {
                    Text(value).font(.system(size: 12)).monospacedDigit()
                    Text(label).font(.system(size: 10)).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func miniRow(_ title: String, icon: String, note: String) -> some View {
        HStack(spacing: 7) {
            Image(systemName: icon).foregroundStyle(.secondary)
            Text(title).lineLimit(1)
            Spacer(minLength: 0)
            Text(note).font(.system(size: 10)).foregroundStyle(.secondary)
        }.font(.system(size: 11))
    }

    private func sampleRow(_ sample: IslandSample, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: sample.icon).foregroundStyle(selected ? Color.blue : .white.opacity(0.5)).frame(width: 18)
                VStack(alignment: .leading, spacing: 4) {
                    Text(sample.title).font(.system(size: 12)).lineLimit(1)
                    Text(sample.detail).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }.padding(9).frame(maxWidth: .infinity, alignment: .leading)
                .background(selected ? Color.blue.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: 8))
        }.buttonStyle(IslandButtonStyle()).accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func heading(_ title: String, detail: String) -> some View {
        HStack {
            Text(title).font(.system(size: 12, weight: .medium))
            Spacer()
            Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }

    private func subheading(_ page: IslandPage) -> some View {
        HStack {
            Button { controller.page = .home } label: { Label("首页", systemImage: "chevron.left") }
                .buttonStyle(IslandButtonStyle()).font(.system(size: 11)).foregroundStyle(.secondary)
            Spacer()
            Text(page.title).font(.system(size: 13, weight: .medium))
            Spacer()
            Text("模拟内容").font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }

    private func progress(_ value: CGFloat) -> some View {
        GeometryReader { geometry in
            Capsule().fill(.white.opacity(0.14)).overlay(alignment: .leading) {
                Capsule().fill(Color.blue).frame(width: geometry.size.width * value)
            }
        }
    }

    private func inertButton(_ title: String, primary: Bool = false) -> some View {
        Button {} label: {
            Text(title).font(.system(size: 11)).padding(.horizontal, 10).padding(.vertical, 5)
                .background(primary ? Color.blue : cardColor, in: RoundedRectangle(cornerRadius: 7))
        }.buttonStyle(IslandButtonStyle()).help("仅展示界面与按下反馈")
    }

    private func inertIcon(_ icon: String, label: String) -> some View {
        Button {} label: { Image(systemName: icon).foregroundStyle(Color.blue) }
            .buttonStyle(IslandButtonStyle()).accessibilityLabel(label)
    }
}

private struct IslandTrend: Shape {
    func path(in rect: CGRect) -> Path {
        let values: [CGFloat] = [0.32, 0.48, 0.40, 0.55, 0.38, 0.62, 0.46, 0.50, 0.68, 0.43, 0.56, 0.40, 0.48, 0.35, 0.51, 0.42]
        return Path { path in
            for (index, value) in values.enumerated() {
                let point = CGPoint(x: CGFloat(index) / CGFloat(values.count - 1) * rect.width, y: (1 - value) * rect.height)
                if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
            }
        }
    }
}
