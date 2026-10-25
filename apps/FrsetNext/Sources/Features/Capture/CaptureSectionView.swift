import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - 面板「截图」区段

/// 主面板里的截图区段：六个入口 + 最近截图网格 + OCR 结果区
public struct CaptureSectionView: View {
    @StateObject private var manager = ScreenshotManager.shared
    @StateObject private var picker = Eyedropper.shared

    @Stored private var isStitching = false

    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Theme.sectionHeader("截图")

            if !manager.hasPermission { permissionBanner }

            entryButtons

            if manager.isRecognizing || !manager.ocrText.isEmpty { ocrResultArea }

            if let message = manager.statusMessage ?? picker.message {
                Text(message)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            if !manager.recent.isEmpty {
                Theme.sectionHeader("最近截图")
                recentGrid
            }
        }
        .onAppear {
            manager.refreshPermission()
            manager.reloadRecent()
        }
    }

    // MARK: 权限提示

    private var permissionBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
            Text("尚未获得屏幕录制权限")
                .font(.system(size: 12))
            Spacer()
            // v111：统一权限引导窗入口（四类权限总览）
            Button("权限引导") { PermissionGuideWindowController.shared.show() }
                .buttonStyle(.borderless)
                .font(.system(size: 11))
            Button("前往授权") { Task { _ = await manager.ensureScreenRecordingPermission() } }
                .buttonStyle(.borderless)
                .font(.system(size: 11))
        }
        .padding(8)
        .background(Color.yellow.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: Theme.smallRadius))
    }

    // MARK: 入口按钮

    private var entryButtons: some View {
        let columns = [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())]
        return LazyVGrid(columns: columns, spacing: 8) {
            entryButton(mode: .area)     { manager.captureRegion() }
            entryButton(mode: .full)     { manager.captureFullScreen() }
            entryButton(mode: .window)   { manager.captureWindow() }
            entryButton(mode: .ocr)      { manager.captureAndOCR() }
            entryButton(mode: .long)     { pickAndStitch() }
            entryButton(mode: .pin)      { pinLatest() }
            entryButton(mode: .annotate) { annotateLatest() }
            entryButton(mode: .color)    { picker.start() }
            // v130（SnowShot 对齐）④：延时截图（N 秒后自动截图，设置里调秒数）
            entryButton(mode: .delayed)  { manager.captureDelayed() }
            // v130（SnowShot 对齐）②：截图历史入口
            Button {
                CaptureHistoryWindowController.shared.show()
            } label: {
                VStack(spacing: 4) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 16))
                    Text("历史")
                        .font(.system(size: 11))
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(Theme.cardBackground)
                .clipShape(RoundedRectangle(cornerRadius: Theme.smallRadius))
            }
            .buttonStyle(.plain)
            // v116：录屏提为截图区一级入口（原在 STATS 合并条/设置里）
            Button {
                StatsBarEngine.openRecorder()
            } label: {
                VStack(spacing: 4) {
                    Image(systemName: "record.circle")
                        .font(.system(size: 16))
                        .foregroundStyle(Color.red.opacity(0.85))
                    Text("录屏")
                        .font(.system(size: 11))
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(Theme.cardBackground)
                .clipShape(RoundedRectangle(cornerRadius: Theme.smallRadius))
            }
            .buttonStyle(.plain)
        }
    }

    private func entryButton(mode: CaptureMode, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: mode.systemImage)
                    .font(.system(size: 16))
                Text(mode.title)
                    .font(.system(size: 11))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(Theme.cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: Theme.smallRadius))
        }
        .buttonStyle(.plain)
    }

    // MARK: OCR 结果

    private var ocrResultArea: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Theme.sectionHeader("识别结果")
                Spacer()
                if manager.isRecognizing { ProgressView().controlSize(.small) }
                Button {
                    manager.copyOCRText()
                } label: {
                    Label("复制", systemImage: "doc.on.doc")
                        .font(.system(size: 11))
                }
                .buttonStyle(.borderless)
                Button {
                    manager.ocrText = ""
                } label: {
                    Image(systemName: "xmark.circle")
                        .font(.system(size: 11))
                }
                .buttonStyle(.borderless)
            }
            TextEditor(text: $manager.ocrText)
                .font(.system(size: 12))
                .frame(minHeight: 80, maxHeight: 160)
                .padding(6)
                .background(Theme.cardBackground)
                .clipShape(RoundedRectangle(cornerRadius: Theme.smallRadius))
        }
    }

    // MARK: 最近截图

    private var recentGrid: some View {
        let columns = [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())]
        return LazyVGrid(columns: columns, spacing: 8) {
            ForEach(manager.recent.prefix(9)) { item in
                thumbnailView(item)
            }
        }
    }

    private func thumbnailView(_ item: CapturedImage) -> some View {
        Group {
            if let image = manager.thumbnail(for: item.url, maxSide: 240) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: "photo")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(height: 68)
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: Theme.smallRadius))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.smallRadius)
                .stroke(Theme.separator, lineWidth: 0.5)
        )
        .contentShape(Rectangle())
        .onTapGesture { NSWorkspace.shared.open(item.url) }
        .contextMenu {
            Button("复制到剪贴板") { manager.apply(.clipboard, to: item.url) }
            Button("识别图中文字") { manager.apply(.ocr, to: item.url) }
            Button("标注编辑") { manager.annotate(url: item.url) }
            Button("钉在屏幕上") { manager.apply(.pin, to: item.url) }
            Button("在访达中显示") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
        }
        .help(item.createdAt.relativeText)
    }

    // MARK: 动作

    /// 长截图：选择多张有重叠的截图后拼接保存
    private func pickAndStitch() {
        guard !isStitching else { return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [UTType.image]
        panel.message = "按顺序选择多张有重叠区域的滚动截图"
        guard panel.runModal() == .OK, panel.urls.count >= 2 else { return }
        let urls = panel.urls
        // v128（内存优化）：拼接帧数上限——超限在入口拦截并明确提示（否则
        // Stitcher 拒绝后回退成「拼接失败」误导排查）。分批拼接即可。
        guard urls.count <= Stitcher.maxStitchFrames else {
            Toast.show("一次最多拼接 \(Stitcher.maxStitchFrames) 张，请分批拼接",
                       icon: "exclamationmark.triangle.fill", isWarning: true)
            return
        }
        isStitching = true
        manager.statusMessage = "正在拼接 \(urls.count) 张图片…"
        // 拼接是 CPU 密集操作，放后台；落盘与 UI 刷新回主线程
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Stitcher.stitch(urls: urls)
            DispatchQueue.main.async {
                isStitching = false
                if let result = result {
                    _ = manager.saveStitchedResult(result.image, overlaps: result.overlaps)
                } else {
                    manager.statusMessage = "拼接失败：请确认图片同宽且存在重叠内容"
                }
            }
        }
    }

    /// 钉图：优先钉最近一张截图，没有则选文件
    private func pinLatest() {
        if let first = manager.recent.first {
            manager.pin(url: first.url)
        } else if let url = chooseSingleImage() {
            manager.pin(url: url)
        }
    }

    /// 标注编辑：优先标注最近一张截图，没有则选文件
    private func annotateLatest() {
        if !manager.annotateLatest(), let url = chooseSingleImage() {
            manager.annotate(url: url)
        }
    }

    private func chooseSingleImage() -> URL? {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [UTType.image]
        return panel.runModal() == .OK ? panel.url : nil
    }
}
