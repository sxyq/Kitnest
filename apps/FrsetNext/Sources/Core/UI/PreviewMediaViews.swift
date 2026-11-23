import AVFoundation
import AVKit
import SwiftUI

// MARK: - 悬浮预览媒体播放（v290，ArcZip 1.2.5 对齐）
//
// 证据（analysis/ui-copy-zh.md）：
//   · `settings.browsing.hover.video`       在悬浮预览中播放视频（MP4、MOV、M4V…部分编码或文件无法预览）
//   · `settings.hover.video.muted`          视频默认静音，关闭后播放视频声音
//   · `settings.hover.audio.autoplay`       悬停后自动播放音频，关闭后点击播放按钮开始试听
//   · `hover.audio.play`                    播放音频
//   · 大小上限沿用 `settings.browsing.hover.video.limit` 六档（10MB…2GB，按解压后大小、含上限），
//     由调用方（ArchiveHoverPreview.schedule 的 sizeCap）先行过滤。
// ArcZip 类型系：`ArchiveHoverVideoPlayerView` / `ArchiveHoverVideoSizeControl`（02-UI组件清单 §3）；
// Kitnest 侧做成共享组件（面板文件预览与归档悬浮预览复用同一画布，同 ArcZip 复用口径）。

public enum PreviewMediaSupport {

    /// ArcZip `settings.browsing.hover.video.detail`：MP4、MOV、M4V 等格式
    public static let videoExtensions: Set<String> = ["mp4", "mov", "m4v", "webm", "mkv"]
    /// 音频试听：常见无损/有损
    public static let audioExtensions: Set<String> = ["mp3", "m4a", "aac", "wav", "flac", "aiff", "caf"]

    public static func isVideoFile(_ url: URL) -> Bool {
        isVideoExtension(url.pathExtension)
    }

    public static func isAudioFile(_ url: URL) -> Bool {
        isAudioExtension(url.pathExtension)
    }

    public static func isVideoExtension(_ ext: String) -> Bool {
        videoExtensions.contains(ext.lowercased())
    }

    public static func isAudioExtension(_ ext: String) -> Bool {
        audioExtensions.contains(ext.lowercased())
    }

    public static func isMediaFile(_ url: URL) -> Bool {
        isVideoFile(url) || isAudioFile(url)
    }

    // MARK: 设置读取（键归 Preferences.Keys.archiveHover*；这里做便捷静态读取）

    /// 在悬浮预览中播放视频（默认开）
    public static var videoEnabled: Bool {
        UserDefaults.standard.object(forKey: "archive.hover.videoEnabled") as? Bool ?? true
    }

    /// 视频默认静音（默认开）
    public static var videoMuted: Bool {
        UserDefaults.standard.object(forKey: "archive.hover.videoMuted") as? Bool ?? true
    }

    /// 自动播放音频（默认关；关闭后点击播放按钮开始试听）
    public static var audioAutoplay: Bool {
        UserDefaults.standard.object(forKey: "archive.hover.audioAutoplay") as? Bool ?? false
    }
}

// MARK: - 视频播放器（AVPlayerLayer；默认静音自动播放，右上角解除静音）

/// ArcZip `ArchiveHoverVideoPlayerView` 同位组件：悬浮预览里的内联视频。
/// 生命周期：出现即建 player（静音自动播放），消失即暂停并释放（悬浮层随时关闭，不能漏声）。
public struct PreviewMediaVideoPlayerView: View {
    let url: URL
    let muted: Bool

    @Stored private var player: AVPlayer?
    @Stored private var isMuted = true
    @Stored private var isPlaying = false

    public init(url: URL, muted: Bool) {
        self.url = url
        self.muted = muted
    }

    public var body: some View {
        ZStack(alignment: .topTrailing) {
            PlayerLayerView(player: player)
                .frame(width: 320, height: 180)
                .background(Color.black)
                .contentShape(Rectangle())
                .onTapGesture { togglePlay() }

            HStack(spacing: 6) {
                Button {
                    togglePlay()
                } label: {
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 22, height: 22)
                        .background(Circle().fill(.black.opacity(0.45)))
                }
                .buttonStyle(.plain)

                // 视频默认静音（ArcZip settings.hover.video.muted）；按钮解除/恢复
                Button {
                    isMuted.toggle()
                    player?.isMuted = isMuted
                } label: {
                    Image(systemName: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 22, height: 22)
                        .background(Circle().fill(.black.opacity(0.45)))
                }
                .buttonStyle(.plain)
            }
            .padding(6)
        }
        .onAppear {
            let p = AVPlayer(url: url)
            p.isMuted = muted
            player = p
            isMuted = muted
            p.play()
            isPlaying = true
        }
        .onDisappear {
            player?.pause()
            player = nil
            isPlaying = false
        }
    }

    private func togglePlay() {
        guard let player else { return }
        if isPlaying {
            player.pause()
        } else {
            player.play()
        }
        isPlaying.toggle()
    }
}

/// AVPlayerLayer 宿主（视频随容器缩放，不引入 AVPlayerView 的整套控制条——悬浮层只要画面）
struct PlayerLayerView: NSViewRepresentable {
    let player: AVPlayer?

    func makeNSView(context: Context) -> LayerHostView {
        let view = LayerHostView()
        view.player = player
        return view
    }

    func updateNSView(_ nsView: LayerHostView, context: Context) {
        nsView.player = player
    }

    final class LayerHostView: NSView {
        /// macOS AppKit 没有 UIView.layerClass 钩子：wantsLayer 后直接给 `layer`
        /// 赋 AVPlayerLayer（NSView 的 layer 在显示前可写）。
        private let playerLayer = AVPlayerLayer()

        var player: AVPlayer? {
            didSet { playerLayer.player = player }
        }

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
            playerLayer.videoGravity = .resizeAspect
            layer = playerLayer
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }
    }
}

// MARK: - 音频试听（播放按钮 + 进度条；自动播放受设置控制）

/// ArcZip `hover.audio.play`（播放音频）同位组件。
/// 自动播放（settings.hover.audio.autoplay 默认关）：关闭时只显示播放按钮。
public struct PreviewMediaAudioPlayerView: View {
    let url: URL
    let autoplay: Bool

    @Stored private var player: AVAudioPlayer?
    @Stored private var isPlaying = false
    @Stored private var progress: Double = 0
    @Stored private var timer: Timer?

    public init(url: URL, autoplay: Bool) {
        self.url = url
        self.autoplay = autoplay
    }

    public var body: some View {
        HStack(spacing: 10) {
            Button {
                togglePlay()
            } label: {
                Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(Theme.accent)
            }
            .buttonStyle(.plain)
            .help(isPlaying ? "暂停" : "播放音频")

            VStack(alignment: .leading, spacing: 4) {
                Text(url.lastPathComponent)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                // 播放进度（试听反馈；不提供拖动——悬浮层生命周期太短，不值得做 scrub）
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.primary.opacity(0.12))
                        Capsule().fill(Theme.accent.opacity(0.8))
                            .frame(width: max(2, geo.size.width * progress))
                    }
                }
                .frame(height: 3)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: 260)
        .background(Theme.cardFill)
        .overlay { RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous)
            .strokeBorder(Theme.hairlineColor, lineWidth: 1) }
        .onAppear { prepare() }
        .onDisappear { teardown() }
    }

    private func prepare() {
        let p = try? AVAudioPlayer(contentsOf: url)
        p?.prepareToPlay()
        p?.volume = 1.0
        player = p
        if autoplay {
            p?.play()
            isPlaying = true
            startTimer()
        }
    }

    private func togglePlay() {
        guard let player else { return }
        if isPlaying {
            player.pause()
        } else {
            if player.currentTime >= player.duration { player.currentTime = 0 }
            player.play()
        }
        isPlaying.toggle()
        if isPlaying { startTimer() } else { timer?.invalidate(); timer = nil }
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
            guard let player, player.duration > 0 else { return }
            progress = player.currentTime / player.duration
            if !player.isPlaying && isPlaying {
                isPlaying = false
                progress = 1
                timer?.invalidate()
                timer = nil
            }
        }
    }

    private func teardown() {
        timer?.invalidate()
        timer = nil
        player?.stop()
        player = nil
        isPlaying = false
        progress = 0
    }
}
