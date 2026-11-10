import AppKit
import AVFoundation
import UniformTypeIdentifiers

// MARK: - 录屏后期编辑器（v264 · 对标 1Capture STUDIO 的「最小可用集」）
//
// 1Capture 的 STUDIO 有 207 条文案（转场、缩放、字幕轨、光标美化…），那是半个独立 App。
// 这里只做三件真正每天会用的事：**剪头剪尾、静音、导出**。
// 不做时间轴拼接 / 多轨 / 转场——那些功能没有 2000 行代码做不出可用体验，
// 硬塞一个残缺版只会让用户觉得「还不如录完就用 QuickTime 剪」。

@MainActor
final class RecordingEditorController {

    static let shared = RecordingEditorController()

    private var window: NSWindow?
    private var player: AVPlayer?
    private var playerLayer: AVPlayerLayer?
    private var asset: AVURLAsset?
    private var duration: Double = 0
    private var startSlider: NSSlider?
    private var endSlider: NSSlider?
    private var startLabel: NSTextField?
    private var endLabel: NSTextField?
    private var muteCheck: NSButton?
    private var exporting = false

    private init() {}

    func open(url: URL) {
        let asset = AVURLAsset(url: url)
        self.asset = asset
        duration = max(0.1, asset.duration.seconds)
        if !duration.isFinite { duration = 0.1 }

        let window = self.window ?? makeWindow()
        self.window = window
        window.title = "录屏编辑 · \(url.lastPathComponent)"
        window.subtitle = String(format: "%.1f 秒", duration)

        player?.pause()
        let player = AVPlayer(url: url)
        self.player = player
        playerLayer?.player = player

        startSlider?.maxValue = duration
        startSlider?.doubleValue = 0
        endSlider?.maxValue = duration
        endSlider?.doubleValue = duration
        updateLabels()

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: 窗口

    private func makeWindow() -> NSWindow {
        let size = NSSize(width: 720, height: 520)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        // v272：录屏编辑窗此前完全没走统一外观（裸窗口 + 自绘控件），
        // 是「所有界面都修过但还漏一个」的最后一处。
        window.applyOfficialChrome(lights: .standard)
        window.center()
        window.minSize = NSSize(width: 560, height: 420)

        let host = NSView(frame: NSRect(origin: .zero, size: size))
        host.autoresizingMask = [.width, .height]

        // 预览
        let preview = NSView(frame: NSRect(x: 16, y: 132, width: size.width - 32, height: size.height - 148))
        preview.autoresizingMask = [.width, .height]
        preview.wantsLayer = true
        preview.layer?.backgroundColor = NSColor.black.cgColor
        preview.layer?.cornerRadius = 10
        preview.layer?.masksToBounds = true
        let layer = AVPlayerLayer()
        layer.videoGravity = .resizeAspect
        layer.frame = preview.bounds
        preview.layer?.addSublayer(layer)
        playerLayer = layer
        host.addSubview(preview)

        // 起止滑块
        let start = NSSlider(value: 0, minValue: 0, maxValue: 1, target: self, action: #selector(trimChanged))
        start.frame = NSRect(x: 16, y: 96, width: size.width - 32, height: 20)
        start.autoresizingMask = [.width]
        host.addSubview(start)
        startSlider = start

        let end = NSSlider(value: 1, minValue: 0, maxValue: 1, target: self, action: #selector(trimChanged))
        end.frame = NSRect(x: 16, y: 68, width: size.width - 32, height: 20)
        end.autoresizingMask = [.width]
        host.addSubview(end)
        endSlider = end

        let startLabel = makeLabel("0.0s", x: 16, y: 48)
        let endLabel = makeLabel(String(format: "%.1fs", duration), x: 120, y: 48)
        host.addSubview(startLabel); host.addSubview(endLabel)
        startLabel.frame.size.width = 100
        endLabel.frame.origin.x = 110
        self.startLabel = startLabel
        self.endLabel = endLabel

        let rangeHint = makeLabel("拖动两条滑块选择保留区间（头 → 尾）", x: 220, y: 48)
        rangeHint.textColor = .secondaryLabelColor
        host.addSubview(rangeHint)

        // 按钮
        let play = makeButton("播放", action: #selector(togglePlay), x: 16, y: 14, width: 70)
        host.addSubview(play)
        let mute = NSButton(checkboxWithTitle: "导出时静音", target: nil, action: nil)
        mute.frame = NSRect(x: 100, y: 18, width: 130, height: 20)
        host.addSubview(mute)
        muteCheck = mute
        let export = makeButton("导出…", action: #selector(exportMovie), x: size.width - 106, y: 12, width: 90)
        export.keyEquivalent = "\r"
        export.autoresizingMask = [.minXMargin]
        host.addSubview(export)
        let reveal = makeButton("在访达中显示", action: #selector(revealInFinder), x: size.width - 226, y: 12, width: 110)
        reveal.autoresizingMask = [.minXMargin]
        host.addSubview(reveal)

        window.setOfficialContent(host)
        return window
    }

    private func makeLabel(_ text: String, x: CGFloat, y: CGFloat) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        label.frame = NSRect(x: x, y: y, width: 80, height: 16)
        return label
    }

    private func makeButton(_ title: String, action: Selector, x: CGFloat, y: CGFloat, width: CGFloat) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        button.frame = NSRect(x: x, y: y, width: width, height: 26)
        return button
    }

    // MARK: 交互

    @objc private func trimChanged() {
        guard let startSlider, let endSlider else { return }
        // 两个滑块不允许交叉：动一个把另一个推着走
        if startSlider.doubleValue > endSlider.doubleValue - 0.1 {
            startSlider.doubleValue = max(0, endSlider.doubleValue - 0.1)
        }
        updateLabels()
        player?.seek(to: CMTime(seconds: startSlider.doubleValue, preferredTimescale: 600))
    }

    private func updateLabels() {
        guard let startSlider, let endSlider else { return }
        startLabel?.stringValue = String(format: "入点 %.1fs", startSlider.doubleValue)
        endLabel?.stringValue = String(format: "出点 %.1fs", endSlider.doubleValue)
        endLabel?.frame.origin.x = 110
    }

    @objc private func togglePlay() {
        guard let player else { return }
        if player.rate == 0 {
            if let start = startSlider?.doubleValue,
               player.currentTime().seconds < start - 0.2 || player.currentTime().seconds > (endSlider?.doubleValue ?? duration) {
                player.seek(to: CMTime(seconds: start, preferredTimescale: 600))
            }
            player.play()
        } else {
            player.pause()
        }
    }

    @objc private func revealInFinder() {
        guard let url = asset?.url else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    @objc private func exportMovie() {
        guard !exporting, let asset, let startSlider, let endSlider else { return }
        let start = startSlider.doubleValue
        let end = max(start + 0.1, endSlider.doubleValue)

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.nameFieldStringValue = asset.url.deletingPathExtension().lastPathComponent + "-trimmed.mp4"
        panel.canCreateDirectories = true
        panel.begin { [weak self] response in
            guard response == .OK, let dest = panel.url, let self else { return }
            self.performExport(asset: asset, to: dest,
                               range: CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600),
                                                  end: CMTime(seconds: end, preferredTimescale: 600)),
                               mute: self.muteCheck?.state == .on)
        }
    }

    private func performExport(asset: AVAsset, to dest: URL, range: CMTimeRange, mute: Bool) {
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality) else {
            Toast.show("导出失败：无法创建导出会话", icon: "exclamationmark.triangle", isWarning: true)
            return
        }
        exporting = true
        let temporary = dest.deletingLastPathComponent()
            .appendingPathComponent("Recording-export-\(UUID().uuidString).mp4")
        session.outputURL = temporary
        session.outputFileType = .mp4
        session.timeRange = range
        session.shouldOptimizeForNetworkUse = true
        if mute {
            let mix = AVMutableAudioMix()
            mix.inputParameters = asset.tracks(withMediaType: .audio).map {
                let params = AVMutableAudioMixInputParameters(track: $0)
                params.setVolume(0, at: .zero)
                return params
            }
            session.audioMix = mix
        }
        let seconds = range.duration.seconds
        Toast.show(String(format: "开始导出 %.1f 秒…", seconds), icon: "square.and.arrow.up")
        session.exportAsynchronously { [weak self] in
            Task { @MainActor in
                self?.exporting = false
                switch session.status {
                case .completed:
                    do {
                        if FileManager.default.fileExists(atPath: dest.path) {
                            _ = try FileManager.default.replaceItemAt(dest, withItemAt: temporary)
                        } else {
                            try FileManager.default.moveItem(at: temporary, to: dest)
                        }
                        Toast.show("已导出 \(dest.lastPathComponent)", icon: "checkmark.circle.fill")
                        NSWorkspace.shared.activateFileViewerSelecting([dest])
                    } catch {
                        Toast.show("导出保存失败：\(error.localizedDescription)", icon: "exclamationmark.triangle", isWarning: true)
                    }
                case .cancelled:
                    Toast.show("导出已取消", icon: "xmark.circle")
                default:
                    let message = session.error?.localizedDescription ?? "未知错误"
                    Log.error("Recording", "导出失败：\(message)")
                    Toast.show("导出失败：\(message)", icon: "exclamationmark.triangle", isWarning: true)
                }
                try? FileManager.default.removeItem(at: temporary)
            }
        }
    }
}
