import AppKit
import SwiftUI

struct IslandMediaContent: View {
    @ObservedObject var controller: IslandController
    let previewOnly: Bool
    var size: IslandWidgetSize? = nil

    var body: some View {
        if previewOnly {
            IslandMediaPlayerContent(controller: controller, previewOnly: true, size: size,
                snapshot: .init(available: true, title: "Quiet Hours", artist: "Lo-fi Session",
                                album: "Late Night", source: "音乐", isPlaying: controller.playing, duration: 240),
                artwork: nil, position: controller.seek, feedback: "", send: { command in
                    if command == 2 { controller.playing.toggle() }
                    else { controller.seek = 0; controller.feedback = command == 5 ? "预览：上一首" : "预览：下一首" }
                }, seek: { controller.seek = $0 })
        } else {
            IslandLiveMediaContent(controller: controller, previewOnly: false, size: size)
        }
    }
}

struct IslandLiveMediaContent: View {
    @ObservedObject var controller: IslandController
    let previewOnly: Bool
    var size: IslandWidgetSize? = nil
    @ObservedObject private var player = NowPlayingController.shared
    @Stored private var consumer = UUID()

    private var visible: Bool {
        !previewOnly && controller.expanded && (controller.page == .home || controller.page == .media)
    }

    var body: some View {
        Group {
            if previewOnly {
                IslandMediaContent(controller: controller, previewOnly: true, size: size)
            } else {
                IslandMediaPlayerContent(controller: controller, previewOnly: false, size: size,
                    snapshot: player.snapshot, artwork: player.artwork, position: player.position,
                    feedback: player.feedback, send: player.send, seek: { player.seek(to: $0) })
            }
        }
        .onAppear { if !previewOnly { player.setVisible(visible, consumer: consumer) } }
        .onChange(of: visible) { if !previewOnly { player.setVisible($0, consumer: consumer) } }
        .onDisappear { if !previewOnly { player.setVisible(false, consumer: consumer) } }
        .onChange(of: player.feedback) { if !previewOnly && !$0.isEmpty { controller.feedback = $0 } }
    }
}

private struct IslandMediaPlayerContent: View {
    @ObservedObject var controller: IslandController
    let previewOnly: Bool
    let size: IslandWidgetSize?
    let snapshot: NowPlayingController.Snapshot
    let artwork: NSImage?
    let position: Double?
    let feedback: String
    let send: (Int) -> Void
    let seek: (Double) -> Void
    @Stored private var scrub: Double? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var tint: Color { controller.configuration.color(for: .media) }
    private var title: String { snapshot.title.isEmpty ? (snapshot.available ? "播放器未提供标题" : "暂无播放") : snapshot.title }

    var body: some View {
        Group {
            if size == nil {
                GeometryReader { geometry in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(alignment: .top, spacing: 12) {
                                cover(side: geometry.size.width >= 480 ? 96 : 64)
                                VStack(alignment: .leading, spacing: 6) {
                                    metadata(full: true)
                                    transport(full: true)
                                }.frame(maxWidth: .infinity, alignment: .leading)
                            }
                            progress(showTimes: true)
                            IslandVolumeContent(controller: controller, previewOnly: previewOnly)
                            if !feedback.isEmpty {
                                Text(feedback).font(.system(size: 11)).foregroundStyle(.red)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .glassCard(radius: IslandLayout.cardRadius, fill: IslandLayout.cardFill, stroke: IslandLayout.cardStroke)
                    }
                }
            } else if size == .square {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) { cover(side: 30); metadata(full: false) }
                        HStack(spacing: 8) {
                            transport(full: false)
                            if let position { Text(time(position)).font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary) }
                        }
                        progress(showTimes: false)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                HStack(spacing: 6) {
                    if size != .small { cover(side: 24) }
                    metadata(full: false)
                    if size == .strip { transport(full: false) }
                    else { playButton(side: 22) }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .tint(tint)
        .animation(reduceMotion ? nil : Theme.Motion.tap, value: snapshot.isPlaying)
        .contextMenu {
            Button("上一首") { send(5) }
            Button(snapshot.isPlaying ? "暂停" : "播放") { send(2) }
            Button("下一首") { send(4) }
            Button("完整媒体页") { controller.page = .media }
        }
        .onChange(of: snapshot.title) { _ in scrub = nil }
    }

    private func cover(side: CGFloat) -> some View {
        Group {
            if let artwork { Image(nsImage: artwork).resizable().scaledToFill() }
            else {
                Image(systemName: "music.note").font(.system(size: side * 0.4)).foregroundStyle(tint)
                    .frame(maxWidth: .infinity, maxHeight: .infinity).background(tint.opacity(0.14))
            }
        }.frame(width: side, height: side).clipShape(RoundedRectangle(cornerRadius: IslandLayout.controlRadius, style: .continuous))
            .accessibilityLabel(previewOnly ? "封面预览" : artwork == nil ? "播放器未提供封面" : "当前曲目封面")
    }

    private func metadata(full: Bool) -> some View {
        VStack(alignment: .leading, spacing: full ? 3 : 1) {
            Text(title).font(.system(size: full ? 17 : 11, weight: .medium))
                .lineLimit(full ? nil : 1).fixedSize(horizontal: false, vertical: full)
            if size != .small && !snapshot.artist.isEmpty {
                Text(snapshot.artist).font(.system(size: full ? 12 : 11)).foregroundStyle(.secondary)
                    .lineLimit(full ? nil : 1)
            }
            if full && !snapshot.album.isEmpty {
                Text(snapshot.album).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            if full {
                Text(snapshot.source.isEmpty ? "系统正在播放" : snapshot.source)
                    .font(.system(size: 11)).foregroundStyle(tint).lineLimit(1)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
    }

    private func transport(full: Bool) -> some View {
        HStack(spacing: full ? 14 : 8) {
            Button { send(5) } label: { Image(systemName: "backward.end.fill").frame(width: full ? 30 : 22, height: full ? 30 : 22) }
                .accessibilityLabel("上一首")
            playButton(side: full ? 30 : 22)
            Button { send(4) } label: { Image(systemName: "forward.end.fill").frame(width: full ? 30 : 22, height: full ? 30 : 22) }
                .accessibilityLabel("下一首")
        }.buttonStyle(IslandButtonStyle()).font(.system(size: full ? 15 : 11))
    }

    private func playButton(side: CGFloat) -> some View {
        Button { send(2) } label: {
            Image(systemName: snapshot.isPlaying ? "pause.fill" : "play.fill")
                .font(.system(size: side > 22 ? 15 : 11)).foregroundStyle(tint).frame(width: side, height: side)
        }.buttonStyle(IslandButtonStyle()).accessibilityLabel(snapshot.isPlaying ? "暂停" : "播放")
    }

    @ViewBuilder private func progress(showTimes: Bool) -> some View {
        if let duration = snapshot.duration, duration > 0, let position {
            VStack(spacing: 2) {
                Slider(value: Binding(get: { scrub ?? min(duration, position) }, set: { scrub = $0 }), in: 0...duration) { editing in
                    if editing { controller.beginInteraction() }
                    else { if let scrub { seek(scrub) }; scrub = nil; controller.endInteraction() }
                }.controlSize(.mini).accessibilityLabel(previewOnly ? "预览播放进度" : "播放进度")
                if showTimes {
                    HStack {
                        Text(time(scrub ?? position))
                        Spacer()
                        Text(time(duration))
                    }.font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary)
                }
            }
        } else if showTimes {
            Text(snapshot.available ? "播放器未提供可跳转进度（直播或未知时长）" : "在播放器开始播放后显示系统曲目")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }

    private func time(_ seconds: Double) -> String {
        let value = Int(max(0, seconds))
        return value >= 3600 ? String(format: "%d:%02d:%02d", value / 3600, value / 60 % 60, value % 60)
                             : String(format: "%d:%02d", value / 60, value % 60)
    }
}

struct IslandVolumeContent: View {
    @ObservedObject var controller: IslandController
    let previewOnly: Bool
    var size: IslandWidgetSize? = nil
    @Stored private var previewMuted = false

    var body: some View {
        if previewOnly {
            IslandVolumeControls(controller: controller, size: size,
                volume: Binding(get: { controller.volume / 100 }, set: { controller.volume = $0 * 100 }),
                muted: $previewMuted, volumeReadable: true, muteReadable: true,
                devices: [.init(id: 0, name: "MacBook Pro 扬声器", isDefault: true)], feedback: "",
                select: { _ in controller.feedback = "预览：输出设备" })
        } else {
            IslandLiveVolumeContent(controller: controller, previewOnly: false, size: size)
        }
    }
}

struct IslandLiveVolumeContent: View {
    @ObservedObject var controller: IslandController
    let previewOnly: Bool
    var size: IslandWidgetSize? = nil
    @ObservedObject private var audio = AudioMixerController.shared
    @Stored private var consumer = UUID()

    private var visible: Bool {
        !previewOnly && controller.expanded && (controller.page == .home || controller.page == .media)
    }

    var body: some View {
        Group {
            if previewOnly {
                IslandVolumeContent(controller: controller, previewOnly: true, size: size)
            } else {
                IslandVolumeControls(controller: controller, size: size, volume: $audio.outputVolume, muted: $audio.outputMuted,
                    volumeReadable: audio.volumeReadable, muteReadable: audio.muteReadable,
                    devices: audio.devices, feedback: audio.outputError, select: { audio.selectDefaultDevice($0.id) })
            }
        }
        .onAppear { if !previewOnly { audio.setIslandVisible(visible, consumer: consumer) } }
        .onChange(of: visible) { if !previewOnly { audio.setIslandVisible($0, consumer: consumer) } }
        .onDisappear { if !previewOnly { audio.setIslandVisible(false, consumer: consumer) } }
        .onChange(of: audio.outputError) { if !previewOnly && !$0.isEmpty { controller.feedback = $0 } }
    }
}

private struct IslandVolumeControls: View {
    @ObservedObject var controller: IslandController
    let size: IslandWidgetSize?
    @Binding var volume: Double
    @Binding var muted: Bool
    let volumeReadable: Bool
    let muteReadable: Bool
    let devices: [AudioDeviceInfo]
    let feedback: String
    let select: (AudioDeviceInfo) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var outputName: String { devices.first(where: { $0.isDefault })?.name ?? "系统默认输出" }
    private var tint: Color { controller.configuration.color(for: .volume) }

    var body: some View {
        Group {
            if size == .square { ScrollView { controls } }
            else { controls }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .tint(tint)
        .animation(reduceMotion ? nil : Theme.Motion.tap, value: muted)
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                if muteReadable {
                    Button { muted.toggle() } label: {
                        Image(systemName: muted ? "speaker.slash.fill" : "speaker.wave.2.fill").frame(width: 22, height: 22)
                    }.buttonStyle(IslandButtonStyle()).foregroundStyle(tint)
                        .accessibilityLabel(muted ? "取消系统静音" : "系统静音")
                }
                if volumeReadable {
                    if size != .small && size != .square { volumeSlider }
                    Text("\(Int((volume * 100).rounded()))%")
                        .font(.system(size: 11)).monospacedDigit().fixedSize()
                } else {
                    Text("设备音量").font(.system(size: 11)).lineLimit(1)
                }
                Spacer(minLength: 0)
                Menu {
                    ForEach(devices) { device in
                        Button { select(device) } label: {
                            Label(device.name, systemImage: device.isDefault ? "checkmark" : "speaker.wave.2")
                        }
                    }
                } label: {
                    if size == .strip { Label(outputName, systemImage: "hifispeaker").lineLimit(1) }
                    else { Image(systemName: "hifispeaker").frame(width: 22, height: 22) }
                }.menuStyle(.borderlessButton).fixedSize().accessibilityLabel("选择系统输出设备：" + outputName)
            }
            if size == .square && volumeReadable { volumeSlider }
            if size == nil || size == .square {
                Text(outputName + (muted && muteReadable ? " · 已静音" : ""))
                    .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(size == nil ? nil : 1)
                if !volumeReadable {
                    Text("此输出设备不提供系统音量，请使用设备音量旋钮")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                if !muteReadable {
                    Text("此输出设备不提供系统静音")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            if !feedback.isEmpty {
                Text(feedback).font(.system(size: 11)).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var volumeSlider: some View {
        Slider(value: $volume, in: 0...1) { editing in
            if editing { controller.beginInteraction() } else { controller.endInteraction() }
        }.controlSize(.mini).accessibilityLabel("系统输出音量")
    }
}
