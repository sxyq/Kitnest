import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// 模块入口适配；实际采集、传输和计算仍由原服务执行。
struct IslandFeatureContent: View {
    let page: IslandPage
    @ObservedObject var controller: IslandController
    let previewOnly: Bool
    var size: IslandWidgetSize? = nil
    @Environment(\.isSettingsPreview) private var isSettingsPreview
    private var preview: Bool { previewOnly || controller.previewOnly || isSettingsPreview }

    var body: some View {
        Group {
            if let size {
                compact(size)
            } else {
                fullContent
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .environment(\.isSettingsPreview, preview)
        .tint(controller.configuration.color(for: IslandWidget(rawValue: page.rawValue)!))
    }

    @ViewBuilder private var fullContent: some View {
        switch page {
        case .search:
            ScrollView { SearchSectionView(islandCategory: controller.configuration.searchCategory).padding(8) }
        case .capture:
            IslandCaptureContent(controller: controller, previewOnly: preview)
        case .recording:
            IslandRecordingContent(controller: controller, previewOnly: preview, size: size)
        case .ocr:
            IslandOCRContent(controller: controller, previewOnly: preview)
        case .transfer:
            ScrollView(.vertical) {
                TransferDockView(utilitiesOnly: true)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .cast:
            CastView()
        case .ai:
            if preview {
                IslandAIChatPreview(controller: controller)
            } else { AIChatView() }
        case .statistics:
            ScrollView([.horizontal, .vertical]) { StatisticsChartsView().padding(10) }
        case .archive:
            IslandArchiveContent(controller: controller, previewOnly: preview)
        case .downloads:
            IslandDownloadContent(controller: controller, previewOnly: preview, size: size)
        default: EmptyView()
        }
    }

    @ViewBuilder private func compact(_ size: IslandWidgetSize) -> some View {
        if size == .square {
            fullContent
        } else { switch page {
        case .recording:
            IslandRecordingContent(controller: controller, previewOnly: preview, size: size)
        case .downloads where size != .small:
            IslandDownloadContent(controller: controller, previewOnly: preview, size: size)
        case .capture, .ocr:
            HStack(spacing: 8) {
                Button(page == .capture ? "截图" : "截图识字") {
                    if preview { controller.feedback = page == .capture ? "截图预览" : "截图识字预览" }
                    else { controller.performOutside { CaptureModule.capture(page == .capture ? .area : .ocr) } }
                }.buttonStyle(IslandButtonStyle()).font(.system(size: 11))
                if size != .small {
                    Button("更多") { controller.selectPage(page) }.buttonStyle(IslandButtonStyle()).font(.system(size: 11))
                }
            }
        default:
            if size == .strip {
                HStack(spacing: 12) {
                    Text(summary).font(.system(size: 11)).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    entryButton
                }
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    if size != .small { Text(summary).font(.system(size: 11)).foregroundStyle(.secondary) }
                    entryButton
                }
            }
        } }
    }

    private var entryButton: some View {
        Button("打开") { controller.selectPage(page) }.font(.system(size: 11)).buttonStyle(IslandButtonStyle())
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

private struct IslandAIChatPreview: View {
    @ObservedObject var controller: IslandController
    @Stored private var input = "请整理成今天的任务清单"
    @Stored private var submitted = false
    var body: some View {
        VStack(spacing: 8) {
            Label("AI 对话预览", systemImage: "bubble.left.and.bubble.right").font(.system(size: 13))
            Divider()
            ScrollView {
                ChatBubble(role: .user, content: IslandSample.clipboard[0].body)
                ChatBubble(role: .assistant, content: "**今天的任务**\n1. 完成首页交互\n2. 统一预览与动效\n3. 更新使用手册")
                if submitted { ChatBubble(role: .user, content: input) }
            }
            Divider()
            TextField("输入演示消息", text: $input).textFieldStyle(.roundedBorder).onSubmit(submit)
            Button("发送", action: submit).buttonStyle(IslandButtonStyle())
            Text("固定演示内容，不请求模型").font(.system(size: 11)).foregroundStyle(.secondary)
        }.padding(10)
    }
    private func submit() { submitted = true; controller.feedback = "消息发送效果预览，不请求模型" }
}

private struct IslandDownloadContent: View {
    @ObservedObject var controller: IslandController
    let previewOnly: Bool
    var size: IslandWidgetSize? = nil
    @ObservedObject private var downloader = CloudLinkDownloader.shared
    @Stored private var input = ""
    @Stored private var error = ""
    private static let previewItems: [CloudLinkDownloader.Item] = [
        .init(name: "项目素材.zip", sourceURL: URL(string: "https://kitnest-preview.invalid/materials.zip")!, progress: 1, status: .finished),
        .init(name: "设计资料.pdf", sourceURL: URL(string: "https://kitnest-preview.invalid/design.pdf")!, progress: 0.64, status: .downloading)
    ]
    private var items: [CloudLinkDownloader.Item] { previewOnly ? Self.previewItems : downloader.items }

    var body: some View {
        Group {
            if size == .strip {
                HStack(spacing: 12) {
                    inputControls
                    taskList.frame(maxWidth: .infinity)
                }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    inputControls
                    taskList
                    if size == nil || size == .square { configurationButton }
                }
            }
        }.padding(size == nil || size == .square ? 10 : 0)
    }

    private var inputControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("粘贴网盘分享链接或下载链接", text: $input).textFieldStyle(.roundedBorder).onSubmit(start)
            Button("解析下载", action: start).buttonStyle(IslandButtonStyle())
            if !error.isEmpty { Text(error).font(.system(size: 11)).foregroundStyle(.red) }
        }.font(.system(size: 12))
    }

    /// 相同任务行展示实际下载状态或设置预览的固定状态。
    private var taskList: some View {
        ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if items.isEmpty {
                        Text("暂无下载任务").foregroundStyle(.secondary)
                    } else {
                        ForEach(Array(items.prefix(size == .wide || size == .strip ? 1 : items.count))) { item in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(item.name).lineLimit(1)
                                    Spacer()
                                    if let url = item.localURL {
                                        Button("Finder 定位") { controller.performOutside { NSWorkspace.shared.activateFileViewerSelecting([url]) } }
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
    }

    private var configurationButton: some View {
            Button("网盘解析与配置") {
                if previewOnly { controller.feedback = "解析配置预览" }
                else if let link = CloudDriveLinkDetector.detect(in: input) {
                    controller.performOutside { CloudLinkCenterController.shared.show(link: link) }
                } else { error = "先输入支持的网盘分享链接，再查看解析配置" }
            }.font(.system(size: 11)).buttonStyle(IslandButtonStyle())
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

    var body: some View {
        if previewOnly { IslandCaptureControls(controller: controller, previewOnly: true) }
        else { IslandLiveCaptureContent(controller: controller) }
    }
}

private struct IslandLiveCaptureContent: View {
    @ObservedObject var controller: IslandController
    @ObservedObject private var manager = ScreenshotManager.shared
    var body: some View { IslandCaptureControls(controller: controller, previewOnly: false, manager: manager) }
}

/// 固定截图与实际历史共用布局；预览不实例化截图服务。
private struct IslandCaptureControls: View {
    @ObservedObject var controller: IslandController
    let previewOnly: Bool
    var manager: ScreenshotManager? = nil

    var body: some View {
        let recent = previewOnly ? [(name: "首页说明.png", url: Optional<URL>.none), (name: "界面草图.png", url: Optional<URL>.none)] :
            manager!.recent.prefix(6).map { (name: $0.url.lastPathComponent, url: Optional($0.url)) }
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 120))], spacing: 8) {
                    ForEach(CaptureMode.allCases.filter { $0 != .window }) { mode in
                        Button {
                            if previewOnly { controller.feedback = mode.title + "预览"; return }
                            controller.performOutside {
                            if mode == .annotate, !manager!.annotateLatest() {
                                let panel = NSOpenPanel()
                                panel.allowedContentTypes = [.image]
                                panel.allowsMultipleSelection = false
                                if panel.runModal() == .OK, let url = panel.url { manager!.annotate(url: url) }
                                else { controller.resumeAfterOutside() }
                            } else if mode != .annotate { CaptureModule.capture(mode) }
                        } } label: {
                            Label(mode.title, systemImage: mode.systemImage).font(.system(size: 12))
                                .frame(maxWidth: .infinity, alignment: .leading).padding(10)
                                .background(IslandLayout.cardFill, in: RoundedRectangle(cornerRadius: IslandLayout.controlRadius))
                        }.buttonStyle(IslandButtonStyle(help: mode.title))
                    }
                }
                HStack(spacing: 16) {
                    Button("截图历史") {
                        if previewOnly { controller.feedback = "截图历史预览" }
                        else { controller.performOutside { CaptureHistoryWindowController.shared.show() } }
                    }
                    Button("截图设置") {
                        if previewOnly { controller.feedback = "截图设置预览" }
                        else { controller.performOutside { ServiceLocator.settings?.open(pane: "capture") } }
                    }
                }.buttonStyle(IslandButtonStyle()).font(.system(size: 11))
                    Text(previewOnly ? "最近截图 · 固定演示内容" : manager!.statusMessage ?? "截完后沿用复制、标注、识别、钉图与保存动作条")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    ForEach(Array(recent.enumerated()), id: \.offset) { _, item in
                        Button {
                            if let url = item.url { controller.performOutside { manager!.annotate(url: url) } }
                            else { controller.feedback = "标注预览：" + item.name }
                        } label: {
                            Label(item.name, systemImage: "photo")
                                .font(.system(size: 11)).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                        }.buttonStyle(IslandButtonStyle()).help("标注这张截图")
                    }
            }.padding(10)
        }
    }
}

private struct IslandRecordingContent: View {
    @ObservedObject var controller: IslandController
    let previewOnly: Bool
    var size: IslandWidgetSize? = nil
    @ObservedObject private var recorder = ScreenRecorder.shared
    @Stored private var previewActive = false
    private var active: Bool { previewOnly ? previewActive : recorder.state.isActive }
    private var compact: Bool { size == .small || size == .wide || size == .strip }

    var body: some View {
        Group {
            if size == .strip || size == .wide {
                HStack(spacing: 12) { status; actions }
            } else if compact {
                VStack(alignment: .leading, spacing: 4) { status; actions }
            } else { ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    status
                    actions
                    Text("摄像头、按键、点击效果与水印沿用已保存的录屏设置；停止后进入原编辑器。")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    if !previewOnly, let error = recorder.errorText { Text(error).font(.system(size: 11)).foregroundStyle(.red) }
                    if !previewOnly {
                        ForEach(recorder.unavailableFeatures, id: \.self) { Text($0).font(.system(size: 11)).foregroundStyle(.orange) }
                    }
                }
            } }
        }.padding(size == nil ? 10 : 0)
    }

    private var status: some View {
            Text(active ? "录制中 \(previewOnly ? "00:12" : recorder.elapsedText)" : "录屏")
                .font(.system(size: compact ? 11 : 15, weight: .medium)).monospacedDigit()
    }

    private var actions: some View {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 76), spacing: 6)], alignment: .leading, spacing: 6) {
                if active {
                    if !compact {
                        Button("暂停 / 继续") {
                            if previewOnly { controller.feedback = "暂停状态预览" } else { recorder.togglePause() }
                        }
                    }
                    Button("停止") {
                        if previewOnly { previewActive = false }
                        else { controller.performOutside { Task { await recorder.stop() } } }
                    }
                } else {
                    Button(compact ? "开始" : "录整屏") {
                        if previewOnly { previewActive = true }
                        else {
                            let displayID = ScreenSnapshot.displayID(of: controller.displayScreen)
                            controller.performOutside { recorder.startDisplayRecording(displayID: displayID) }
                        }
                    }
                    if !compact {
                        Button("录区域") {
                            if previewOnly { previewActive = true }
                            else { controller.performOutside { recorder.startRegionRecording() } }
                        }
                    }
                }
                if !compact {
                    Button("录屏设置") {
                        if previewOnly { controller.feedback = "录屏设置预览" }
                        else { controller.performOutside { ServiceLocator.settings?.open(pane: "recording") } }
                    }
                }
            }.font(.system(size: 11)).buttonStyle(IslandButtonStyle())
    }
}

private struct IslandOCRContent: View {
    @ObservedObject var controller: IslandController
    let previewOnly: Bool
    @Stored private var previewText = "周五交付清单\n完成首页、预览与组件交互。"

    var body: some View {
        if previewOnly { IslandOCRControls(controller: controller, previewOnly: true, text: $previewText) }
        else { IslandLiveOCRContent(controller: controller) }
    }
}

private struct IslandLiveOCRContent: View {
    @ObservedObject var controller: IslandController
    @ObservedObject private var manager = ScreenshotManager.shared
    var body: some View { IslandOCRControls(controller: controller, previewOnly: false, text: $manager.ocrText, manager: manager) }
}

/// 文本编辑与动作共用布局；实际识别仅由正式服务执行。
private struct IslandOCRControls: View {
    @ObservedObject var controller: IslandController
    let previewOnly: Bool
    @Binding var text: String
    var manager: ScreenshotManager? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 86))], alignment: .leading, spacing: 8) {
                Button("截图识字") {
                    if previewOnly { controller.feedback = "截图识字预览" }
                    else { controller.performOutside { CaptureModule.capture(.ocr) } }
                }
                Button("识别图片") { chooseImage() }
                Button("屏幕翻译") {
                    if previewOnly { controller.feedback = "屏幕翻译预览" }
                    else { controller.performOutside { manager!.captureAndScreenTranslate() } }
                }
                if !previewOnly && manager!.isRecognizing { ProgressView().controlSize(.mini) }
            }.font(.system(size: 11)).buttonStyle(IslandButtonStyle())
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 86))], alignment: .leading, spacing: 8) {
                ForEach(AISummaryAction.allCases) { action in
                    Button("划词" + action.title) {
                        if previewOnly { controller.feedback = action.title + "预览" }
                        else { controller.performOutside { AppBootstrap.runSelectionAction(action, selection: controller.selection) } }
                    }
                }
                Button("复制正文") {
                    if previewOnly { controller.feedback = "复制正文预览" }
                    else { manager!.copyOCRText() }
                }
                .keyboardShortcut("c", modifiers: [.command, .shift])
            }.font(.system(size: 11)).buttonStyle(IslandButtonStyle())
            TextEditor(text: $text)
                .font(.system(size: 12)).scrollContentBackground(.hidden)
                .background(IslandLayout.cardFill, in: RoundedRectangle(cornerRadius: IslandLayout.controlRadius))
            if !previewOnly, let message = manager!.statusMessage {
                Text(message).font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }.padding(10)
    }

    private func chooseImage() {
        if previewOnly { controller.feedback = "识别图片预览"; return }
        controller.performOutside {
            let panel = NSOpenPanel()
            panel.allowedContentTypes = [.image]
            panel.allowsMultipleSelection = false
            if panel.runModal() == .OK, let url = panel.url {
                Task { @MainActor in
                    do {
                        let data = try await Task.detached(priority: .userInitiated) { try Data(contentsOf: url) }.value
                        manager!.recognize(imageData: data, inline: true)
                    } catch { controller.feedback = "无法读取图片：\(error.localizedDescription)" }
                }
                controller.resumeAfterOutside()
            } else { controller.resumeAfterOutside() }
        }
    }
}

private struct IslandArchiveContent: View {
    @ObservedObject var controller: IslandController
    let previewOnly: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 100))], alignment: .leading, spacing: 8) {
                Button("打开压缩包") { choose(create: false) }
                Button("创建压缩包") { choose(create: true) }
                Button("归档任务") {
                    if previewOnly { controller.feedback = "归档任务预览" }
                    else { controller.performOutside { ArchiveProgressWindowController.show() } }
                }
            }.buttonStyle(IslandButtonStyle()).font(.system(size: 12))
            Text("解压、文件预览、密码、格式与编辑回写沿用原归档界面；近期压缩包也可在剪贴板与中转页预览和拖出。")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }.padding(12)
    }
    private func choose(create: Bool) {
        if previewOnly { controller.feedback = create ? "创建压缩包预览" : "打开压缩包预览"; return }
        controller.performOutside {
            let panel = NSOpenPanel()
            panel.allowsMultipleSelection = create
            panel.canChooseDirectories = create
            guard panel.runModal() == .OK else { controller.resumeAfterOutside(); return }
            if create { ArchiveCreateWindowController.show(files: panel.urls) }
            else if let url = panel.url { ArchiveBrowserWindowController.show(url: url) }
        }
    }
}

struct IslandMonitorFullContent: View {
    @ObservedObject var controller: IslandController
    let previewOnly: Bool

    var body: some View {
        MonitorPerformanceContent()
            .environment(\.isSettingsPreview, previewOnly)
            .environment(\.monitorPresentation, presentation)
    }

    private var presentation: MonitorPresentation {
        // v270：与 controller.monitorDetailOrder 同源，卡片点进来的指标和详情顺序一致。
        let order = controller.monitorDetailOrder
        let colors = Dictionary(uniqueKeysWithValues: controller.metricOrder.map {
            (MonitorModuleID(rawValue: $0.rawValue)!, controller.configuration.color(for: $0))
        })
        return MonitorPresentation(order: order, colors: colors, interaction: {
            if $0 { controller.beginInteraction() } else { controller.endInteraction() }
        })
    }
}
