import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// 模块入口适配；实际采集、传输和计算仍由原服务执行。
struct IslandFeatureContent: View {
    let page: IslandPage
    @ObservedObject var controller: IslandController
    let previewOnly: Bool
    var size: IslandWidgetSize? = nil

    var body: some View {
        Group {
            if let size {
                compact(size)
            } else {
                fullContent
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .environment(\.isSettingsPreview, previewOnly)
        .tint(controller.configuration.color(for: IslandWidget(rawValue: page.rawValue)!))
    }

    @ViewBuilder private var fullContent: some View {
        switch page {
        case .search:
            ScrollView { SearchSectionView().padding(8) }
        case .capture:
            IslandCaptureContent(controller: controller, previewOnly: previewOnly)
        case .recording:
            IslandRecordingContent(controller: controller, previewOnly: previewOnly)
        case .ocr:
            IslandOCRContent(controller: controller, previewOnly: previewOnly)
        case .transfer:
            TransferDockView()
        case .cast:
            CastView()
        case .ai:
            if previewOnly {
                VStack(alignment: .leading, spacing: 14) {
                    Label("AI 对话", systemImage: "bubble.left.and.bubble.right")
                    Text(IslandSample.clipboard[0].body).font(.system(size: 12))
                    Text("请整理成今天的任务清单").padding(8).background(IslandLayout.cardFill)
                    Button("发送预览") { controller.feedback = "预览：对话已发送" }.buttonStyle(IslandButtonStyle())
                }.padding(12)
            } else { AIChatView() }
        case .statistics:
            if previewOnly {
                HStack(spacing: 24) {
                    Label("复制 28", systemImage: "doc.on.clipboard")
                    Label("截图 6", systemImage: "viewfinder")
                    Label("工具 12", systemImage: "wrench")
                }.font(.system(size: 13)).padding(12)
            } else {
                ScrollView([.horizontal, .vertical]) { StatisticsChartsView().padding(10) }
            }
        case .archive:
            IslandArchiveContent(controller: controller, previewOnly: previewOnly)
        case .downloads:
            IslandDownloadContent(controller: controller, previewOnly: previewOnly)
        default: EmptyView()
        }
    }

    @ViewBuilder private func compact(_ size: IslandWidgetSize) -> some View {
        switch page {
        case .recording:
            IslandRecordingContent(controller: controller, previewOnly: previewOnly, compact: true)
        case .capture, .ocr:
            HStack(spacing: 8) {
                Button(page == .capture ? "截图" : "截图识字") {
                    controller.performOutside { CaptureModule.capture(page == .capture ? .area : .ocr) }
                }.buttonStyle(IslandButtonStyle()).font(.system(size: 11))
                if size != .small {
                    Button("更多") { controller.page = page }.buttonStyle(IslandButtonStyle()).font(.system(size: 11))
                }
            }
        default:
            VStack(alignment: .leading, spacing: 4) {
                if size.rows == 2 { Text(summary).font(.system(size: 11)).foregroundStyle(.secondary) }
                Button("打开") { controller.page = page }.font(.system(size: 11)).buttonStyle(IslandButtonStyle())
            }
        }
    }

    private var summary: String {
        switch page {
        case .search: return "文件、剪贴板、网页与工具"
        case .transfer: return "发送、接收、云端与本地暂存"
        case .cast: return "扫码连接、投屏与手机工具"
        case .ai: return "沿用现有模型和对话记录"
        case .statistics: return "当天用量、趋势与活动记录"
        case .archive: return "打开、预览、压缩与解压"
        case .downloads: return "网盘解析、直链下载与任务进度"
        default: return page.title
        }
    }
}

private struct IslandDownloadContent: View {
    @ObservedObject var controller: IslandController
    let previewOnly: Bool
    @ObservedObject private var downloader = CloudLinkDownloader.shared
    @Stored private var input = ""
    @Stored private var error = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                TextField("粘贴网盘分享链接或下载链接", text: $input).textFieldStyle(.roundedBorder).onSubmit(start)
                Button("解析下载", action: start).buttonStyle(IslandButtonStyle())
            }.font(.system(size: 12))
            if !error.isEmpty { Text(error).font(.system(size: 11)).foregroundStyle(.red) }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if previewOnly {
                        Label("项目素材.zip · 已完成", systemImage: "checkmark.circle")
                        ProgressView(value: 0.64) { Text("设计资料.pdf · 下载中 64%") }
                    } else if downloader.items.isEmpty {
                        Text("暂无下载任务").foregroundStyle(.secondary)
                    } else {
                        ForEach(downloader.items) { item in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(item.name).lineLimit(1)
                                    Spacer()
                                    if let url = item.localURL {
                                        Button("Finder 定位") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                                    }
                                }
                                switch item.status {
                                case .resolving: Text("正在解析")
                                case .queued: Text("排队中")
                                case .downloading: ProgressView(value: item.progress)
                                case .finished: Label("已完成", systemImage: "checkmark.circle")
                                case .failed(let reason): Text(reason).foregroundStyle(.red)
                                }
                            }.padding(8).background(IslandLayout.cardFill, in: RoundedRectangle(cornerRadius: IslandLayout.controlRadius))
                        }
                    }
                }.font(.system(size: 11))
            }
            Button("网盘解析与配置") {
                if previewOnly { controller.feedback = "解析配置预览" }
                else if let link = CloudDriveLinkDetector.detect(in: input) {
                    controller.performOutside { CloudLinkCenterController.shared.show(link: link) }
                } else { error = "先输入支持的网盘分享链接，再查看解析配置" }
            }.font(.system(size: 11)).buttonStyle(IslandButtonStyle())
        }.padding(10)
    }

    private func start() {
        if previewOnly { controller.feedback = "下载进度预览"; return }
        if let link = CloudDriveLinkDetector.detect(in: input) {
            error = ""
            CloudLinkActions.resolve(link)
        } else if let url = URL(string: input.trimmingCharacters(in: .whitespacesAndNewlines)),
                  ["http", "https"].contains(url.scheme), url.host != nil {
            error = ""
            downloader.startDirectDownload(url: url)
        } else {
            error = "未识别到链接，请输入完整的 http 或 https 地址"
        }
    }
}

private struct IslandCaptureContent: View {
    @ObservedObject var controller: IslandController
    let previewOnly: Bool
    @ObservedObject private var manager = ScreenshotManager.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 120))], spacing: 8) {
                    ForEach(CaptureMode.allCases.filter { $0 != .window }) { mode in
                        Button { controller.performOutside {
                            if mode == .annotate, !manager.annotateLatest() {
                                let panel = NSOpenPanel()
                                panel.allowedContentTypes = [.image]
                                panel.allowsMultipleSelection = false
                                if panel.runModal() == .OK, let url = panel.url { manager.annotate(url: url) }
                                else { controller.open() }
                            } else if mode != .annotate { CaptureModule.capture(mode) }
                        } } label: {
                            Label(mode.title, systemImage: mode.systemImage).font(.system(size: 12))
                                .frame(maxWidth: .infinity, alignment: .leading).padding(10)
                                .background(IslandLayout.cardFill, in: RoundedRectangle(cornerRadius: IslandLayout.controlRadius))
                        }.buttonStyle(IslandButtonStyle(help: mode.title))
                    }
                }
                HStack(spacing: 16) {
                    Button("截图历史") { controller.performOutside { CaptureHistoryWindowController.shared.show() } }
                    Button("截图设置") { controller.performOutside { ServiceLocator.settings?.open(pane: "capture") } }
                }.buttonStyle(IslandButtonStyle()).font(.system(size: 11))
                if previewOnly {
                    Text("最近截图 · 首页说明.png · 界面草图.png").font(.system(size: 11)).foregroundStyle(.secondary)
                } else {
                    Text(manager.statusMessage ?? "截完后沿用复制、标注、识别、钉图与保存动作条")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    ForEach(manager.recent.prefix(6)) { item in
                        Button {
                            controller.performOutside { manager.annotate(url: item.url) }
                        } label: {
                            Label(item.url.lastPathComponent, systemImage: "photo")
                                .font(.system(size: 11)).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                        }.buttonStyle(IslandButtonStyle()).help("标注这张截图")
                    }
                }
            }.padding(10)
        }
    }
}

private struct IslandRecordingContent: View {
    @ObservedObject var controller: IslandController
    let previewOnly: Bool
    var compact = false
    @ObservedObject private var recorder = ScreenRecorder.shared
    @Stored private var previewActive = false
    private var active: Bool { previewOnly ? previewActive : recorder.state.isActive }

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 3 : 12) {
            Text(active ? "录制中 \(previewOnly ? "00:12" : recorder.elapsedText)" : "录屏")
                .font(.system(size: compact ? 11 : 15, weight: .medium)).monospacedDigit()
            HStack(spacing: 10) {
                if active {
                    if !compact {
                        Button("暂停 / 继续") {
                            if previewOnly { controller.feedback = "暂停状态预览" } else { recorder.togglePause() }
                        }
                    }
                    Button("停止") {
                        if previewOnly { previewActive = false }
                        else { Task { await recorder.stop() } }
                    }
                } else {
                    Button(compact ? "开始" : "录整屏") {
                        if previewOnly { previewActive = true }
                        else { controller.performOutside { recorder.startDisplayRecording() } }
                    }
                    if !compact {
                        Button("录区域") { controller.performOutside { recorder.startRegionRecording() } }
                    }
                }
                if !compact {
                    Button("录屏设置") { controller.performOutside { ServiceLocator.settings?.open(pane: "recording") } }
                }
            }.font(.system(size: 11)).buttonStyle(IslandButtonStyle())
            if !compact {
                Text("摄像头、按键、点击效果与水印沿用已保存的录屏设置；停止后进入原编辑器。")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                if !previewOnly, let error = recorder.errorText { Text(error).font(.system(size: 11)).foregroundStyle(.red) }
                if !previewOnly {
                    ForEach(recorder.unavailableFeatures, id: \.self) { Text($0).font(.system(size: 11)).foregroundStyle(.orange) }
                }
            }
        }.padding(compact ? 0 : 10)
    }
}

private struct IslandOCRContent: View {
    @ObservedObject var controller: IslandController
    let previewOnly: Bool
    @ObservedObject private var manager = ScreenshotManager.shared
    @Stored private var previewText = "周五交付清单\n完成首页、预览与组件交互。"

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Button("截图识字") { controller.performOutside { CaptureModule.capture(.ocr) } }
                Button("识别图片") { chooseImage() }
                Button("屏幕翻译") { controller.performOutside { manager.captureAndScreenTranslate() } }
                if !previewOnly && manager.isRecognizing { ProgressView().controlSize(.mini) }
            }.font(.system(size: 11)).buttonStyle(IslandButtonStyle())
            HStack(spacing: 12) {
                ForEach(AISummaryAction.allCases) { action in
                    Button("划词" + action.title) {
                        controller.performOutside { AppBootstrap.runSelectionAction(action, selection: controller.selection) }
                    }
                }
                Spacer()
                Button("复制正文") {
                    if previewOnly { controller.feedback = "复制正文预览" }
                    else { manager.copyOCRText() }
                }
            }.font(.system(size: 11)).buttonStyle(IslandButtonStyle())
            TextEditor(text: previewOnly ? $previewText : $manager.ocrText)
                .font(.system(size: 12)).scrollContentBackground(.hidden)
                .background(IslandLayout.cardFill, in: RoundedRectangle(cornerRadius: IslandLayout.controlRadius))
            if !previewOnly, let message = manager.statusMessage {
                Text(message).font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }.padding(10)
    }

    private func chooseImage() {
        controller.performOutside {
            let panel = NSOpenPanel()
            panel.allowedContentTypes = [.image]
            panel.allowsMultipleSelection = false
            if panel.runModal() == .OK, let url = panel.url {
                Task { @MainActor in
                    do {
                        let data = try await Task.detached(priority: .userInitiated) { try Data(contentsOf: url) }.value
                        manager.recognize(imageData: data, inline: true)
                    } catch { controller.feedback = "无法读取图片：\(error.localizedDescription)" }
                }
            }
            controller.open()
        }
    }
}

private struct IslandArchiveContent: View {
    @ObservedObject var controller: IslandController
    let previewOnly: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 16) {
                Button("打开压缩包") { choose(create: false) }
                Button("创建压缩包") { choose(create: true) }
                Button("归档任务") { controller.performOutside { ArchiveProgressWindowController.show() } }
            }.buttonStyle(IslandButtonStyle()).font(.system(size: 12))
            Text("解压、文件预览、密码、格式与编辑回写沿用原归档界面；近期压缩包也可在剪贴板与中转页预览和拖出。")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }.padding(12)
    }
    private func choose(create: Bool) {
        controller.performOutside {
            let panel = NSOpenPanel()
            panel.allowsMultipleSelection = create
            panel.canChooseDirectories = create
            guard panel.runModal() == .OK else { controller.open(); return }
            if create { ArchiveCreateWindowController.show(files: panel.urls) }
            else if let url = panel.url { ArchiveBrowserWindowController.show(url: url) }
        }
    }
}

struct IslandMonitorFullContent: View {
    @ObservedObject var controller: IslandController
    let previewOnly: Bool
    @Binding var selectedMetric: IslandMetric
    @StateObject private var selection = MonitorDetailSelection(.cpu)
    @Stored private var trends = false

    var body: some View {
        VStack(spacing: 6) {
            Picker("监测显示", selection: $trends) {
                Text("完整详情").tag(false)
                Text("趋势对照").tag(true)
            }.pickerStyle(.segmented).frame(width: 210)
            if trends {
                IslandMonitorPage(controller: controller, selectedMetric: $selectedMetric, previewOnly: previewOnly)
            } else {
                MonitorDetailView(selection: selection, fixedWidth: nil)
            }
        }.environment(\.isSettingsPreview, previewOnly)
    }
}
