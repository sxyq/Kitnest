import AppKit
import ApplicationServices
import CoreAudio
import SwiftUI

private enum DockMediaPlayer: String, CaseIterable, Identifiable {
    case music, spotify
    var id: String { rawValue }
    var name: String { self == .music ? "Music" : "Spotify" }
    var bundleID: String { self == .music ? "com.apple.Music" : "com.spotify.client" }
}

private struct DockMediaSnapshot {
    let player: DockMediaPlayer
    var running = false
    var hasTrack = false
    var state = "未读取"
    var title = ""
    var artist = ""
    var album = ""
    var needsAuthorization = false
    var error: String?

    var stateLabel: String {
        switch state {
        case "playing": return "正在播放"
        case "paused": return "已暂停"
        case "stopped": return "已停止"
        case "fast forwarding": return "快进中"
        case "rewinding": return "快退中"
        default: return state
        }
    }
    var canControl: Bool { running && hasTrack && error == nil && !needsAuthorization }
    var trackLabel: String {
        if hasTrack { return title.isEmpty ? "当前曲目的名称为空" : title }
        if state == "未运行" { return "\(player.name) 未运行" }
        if error != nil { return "当前曲目不可读取" }
        return running ? "暂无当前曲目" : "尚未读取当前曲目"
    }
}

/// 只保存界面状态；轮询由实际可见的宿主视图成对启停。
@MainActor
private final class DockMediaController: ObservableObject {
    static let shared = DockMediaController()
    @Published var selectedPlayer: DockMediaPlayer?
    @Published private(set) var snapshots = DockMediaPlayer.allCases.map { DockMediaSnapshot(player: $0) }
    @Published private(set) var actionError: String?
    private var timer: Timer?
    private var visibleClients = 0
    private var refreshing = false
    private let scriptQueue = DispatchQueue(label: "com.sxyq.frsetnext.dock-media", qos: .utility)

    var current: DockMediaSnapshot {
        if let selectedPlayer { return snapshots.first { $0.player == selectedPlayer }! }
        return snapshots.first { $0.state == "playing" }
            ?? snapshots.first { $0.hasTrack }
            ?? snapshots.first { $0.running }
            ?? snapshots[0]
    }

    func selectHoveredPlayer() {
        // 仅在视图出现后访问 Dock 控制器，避免两个 shared 初始化互相依赖。
        if let player = DockMediaPlayer.allCases.first(where: {
            $0.bundleID == DockHubController.shared.hoveredApplication?.bundleIdentifier
        }) { selectedPlayer = player }
    }

    func startRefreshing() {
        visibleClients += 1
        guard timer == nil else { return }
        refresh()
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            DispatchQueue.main.async { self?.refresh() }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func stopRefreshing() {
        visibleClients -= 1
        guard visibleClients == 0 else { return }
        timer?.invalidate()
        timer = nil
    }

    func refresh() {
        guard visibleClients > 0, !refreshing else { return }
        refreshing = true
        request(players: DockMediaPlayer.allCases, isRefresh: true)
    }

    /// 命令只来自三个固定按钮；授权请求只来自用户点击。
    func send(_ command: String? = nil, authorize: Bool = false) {
        actionError = nil
        request(players: [current.player], command: command, authorize: authorize)
    }

    private func request(players: [DockMediaPlayer], command: String? = nil,
                         authorize: Bool = false, isRefresh: Bool = false) {
        scriptQueue.async { [self] in
            let isVisible = { DispatchQueue.main.sync { self.visibleClients > 0 } }
            var results: [DockMediaSnapshot] = []
            for player in players {
                guard isVisible() else { break }
                results.append(autoreleasepool {
                    Self.read(player, command: command, authorize: authorize, isVisible: isVisible)
                })
            }
            DispatchQueue.main.async {
                if isRefresh { self.refreshing = false }
                guard self.visibleClients > 0 else { return }
                for result in results {
                    let index = self.snapshots.firstIndex { $0.player == result.player }!
                    self.snapshots[index] = result
                    if !isRefresh, let error = result.error { self.actionError = error }
                }
            }
        }
    }

    nonisolated private static func read(_ player: DockMediaPlayer, command: String?, authorize: Bool,
                                        isVisible: () -> Bool) -> DockMediaSnapshot {
        var snapshot = DockMediaSnapshot(player: player)
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: player.bundleID).first else {
            snapshot.state = "未运行"
            return snapshot
        }
        snapshot.running = true
        let target = NSAppleEventDescriptor(processIdentifier: app.processIdentifier)
        let status = AEDeterminePermissionToAutomateTarget(target.aeDesc!, typeWildCard, typeWildCard, authorize)
        guard status == noErr else {
            snapshot.state = "无法读取播放状态"
            snapshot.needsAuthorization = status == errAEEventWouldRequireUserConsent
            if snapshot.needsAuthorization {
                snapshot.error = "\(player.name) 尚未授权自动化（Apple Events \(status)），点击“授权”读取和控制。"
            } else if status == errAEEventNotPermitted {
                snapshot.error = "\(player.name) 自动化权限被拒绝（Apple Events \(status)）。在系统设置 → 隐私与安全性 → 自动化允许 Kitnest 控制该播放器。"
            } else {
                snapshot.error = "读取 \(player.name) 自动化权限失败：Apple Events \(status)"
            }
            return snapshot
        }
        guard isVisible() else { return snapshot }
        // 两个播放器的官方字典均提供这些属性与命令；running 判断不发送启动事件。
        let source = """
        if application id "\(player.bundleID)" is not running then return {"未运行", false, "", "", ""}
        tell application id "\(player.bundleID)"
            \(command ?? "")
            set playbackState to player state as string
            if not (exists current track) then return {playbackState, false, "", "", ""}
            set mediaTrack to current track
            return {playbackState, true, name of mediaTrack, artist of mediaTrack, album of mediaTrack}
        end tell
        """
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else {
            snapshot.error = "无法创建 \(player.name) AppleScript"
            return snapshot
        }
        let result = script.executeAndReturnError(&error)
        if let error {
            let number = error[NSAppleScript.errorNumber] as? NSNumber
            let message = error[NSAppleScript.errorMessage] as? String ?? error.description
            snapshot.error = "\(player.name) \(command ?? "读取当前曲目")失败：AppleScript \(number?.stringValue ?? "无错误码") · \(message)"
            snapshot.state = "无法读取播放状态"
            return snapshot
        }
        guard result.numberOfItems == 5, let state = result.atIndex(1)?.stringValue,
              let title = result.atIndex(3)?.stringValue, let artist = result.atIndex(4)?.stringValue,
              let album = result.atIndex(5)?.stringValue else {
            snapshot.error = "\(player.name) AppleScript 返回了无法读取的曲目列表：\(result.description)"
            return snapshot
        }
        snapshot.state = state
        snapshot.running = state != "未运行"
        snapshot.hasTrack = result.atIndex(2)!.booleanValue
        snapshot.title = title
        snapshot.artist = artist
        snapshot.album = album
        return snapshot
    }

    func openPlayer() {
        let player = current.player
        actionError = nil
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: player.bundleID) else {
            actionError = "\(player.name) 未安装，无法打开播放器。"
            return
        }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { _, error in
            DispatchQueue.main.async {
                if let error { self.actionError = "打开 \(player.name) 失败：\(error.localizedDescription)" }
                else { self.refresh() }
            }
        }
    }

    func openAutomationSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!
        if !NSWorkspace.shared.open(url) { actionError = "无法打开系统设置的“自动化”页面：\(url.absoluteString)" }
    }
}

/// orderOut 不保证 SwiftUI onDisappear；用宿主窗口通知停止隐藏窗口的刷新。
private struct DockMediaVisibility: NSViewRepresentable {
    func makeNSView(context: Context) -> VisibilityView { VisibilityView() }
    func updateNSView(_ nsView: VisibilityView, context: Context) { nsView.syncVisibility() }
    static func dismantleNSView(_ nsView: VisibilityView, coordinator: ()) {
        nsView.setVisible(false)
        NotificationCenter.default.removeObserver(nsView)
    }

    final class VisibilityView: NSView {
        private var active = false

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            NotificationCenter.default.removeObserver(self)
            if let window {
                NotificationCenter.default.addObserver(self, selector: #selector(syncVisibility),
                    name: NSWindow.didChangeOcclusionStateNotification, object: window)
                NotificationCenter.default.addObserver(self, selector: #selector(windowClosing),
                    name: NSWindow.willCloseNotification, object: window)
            }
            syncVisibility()
        }

        override func viewDidHide() { super.viewDidHide(); syncVisibility() }
        override func viewDidUnhide() { super.viewDidUnhide(); syncVisibility() }

        @objc func syncVisibility() {
            setVisible(window?.isVisible == true && window?.occlusionState.contains(.visible) == true
                && !isHiddenOrHasHiddenAncestor)
        }

        @objc private func windowClosing() { setVisible(false) }

        func setVisible(_ visible: Bool) {
            guard active != visible else { return }
            active = visible
            if visible {
                AudioMixerController.shared.startRefreshing()
                DockMediaController.shared.startRefreshing()
            } else {
                DockMediaController.shared.stopRefreshing()
                AudioMixerController.shared.stopRefreshing()
            }
        }
    }
}

@MainActor
public struct DockMediaControlsView: View {
    @ObservedObject private var mixer = AudioMixerController.shared
    @ObservedObject private var media = DockMediaController.shared

    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("系统音量", systemImage: "speaker.wave.2.fill").font(.headline)
            HStack(spacing: 8) {
                Button { mixer.outputMuted.toggle() } label: {
                    Image(systemName: mixer.muteAvailable && mixer.outputMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                }
                .disabled(!mixer.muteAdjustable)
                .help(mixer.muteAdjustable ? "切换系统静音" : "系统静音不可用")
                .accessibilityLabel(mixer.outputMuted ? "取消静音" : "静音")
                Slider(value: $mixer.outputVolume, in: 0...1)
                    .disabled(!mixer.volumeAdjustable || (mixer.muteAvailable && mixer.outputMuted))
                    .accessibilityLabel("系统输出音量")
                Text(mixer.volumeAvailable ? "\(Int(mixer.outputVolume * 100))%" : "—")
                    .monospacedDigit().frame(width: 38, alignment: .trailing)
            }
            Picker("输出", selection: $mixer.selectedDevice) {
                if mixer.selectedDevice == nil { Text("无默认输出设备").tag(Optional<AudioObjectID>.none) }
                ForEach(mixer.devices) { Text($0.name).tag(Optional($0.id)) }
            }
            .disabled(mixer.devices.isEmpty)
            if !mixer.volumeAdjustable, mixer.outputError == nil {
                Text("此输出设备不支持软件调节音量").font(.caption).foregroundStyle(.secondary)
            }
            if !mixer.muteAdjustable, mixer.outputError == nil {
                Text("此输出设备不支持软件静音").font(.caption).foregroundStyle(.secondary)
            }
            if let error = mixer.outputError { failureText(error) }

            Divider()
            Picker("播放器", selection: Binding(get: { media.current.player }, set: { media.selectedPlayer = $0 })) {
                ForEach(DockMediaPlayer.allCases) { Text($0.name).tag($0) }
            }
            .pickerStyle(.segmented)
            let current = media.current
            VStack(alignment: .leading, spacing: 4) {
                Text(current.trackLabel)
                    .font(.system(size: 13, weight: .semibold)).lineLimit(2)
                if !current.artist.isEmpty { Text(current.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                if !current.album.isEmpty { Text(current.album).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                Text(current.stateLabel).font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 12) {
                transportButton("上一首", symbol: "backward.end.fill", command: "previous track")
                transportButton(current.state == "playing" ? "暂停" : "播放", symbol: current.state == "playing" ? "pause.fill" : "play.fill", command: "playpause")
                transportButton("下一首", symbol: "forward.end.fill", command: "next track")
                Spacer(minLength: 0)
                Button("打开 \(current.player.name)") { media.openPlayer() }.font(.caption)
            }
            if let error = current.error { failureText(error) }
            if current.needsAuthorization {
                Button("授权 \(current.player.name) 自动化") { media.send(authorize: true) }
            }
            if current.error != nil {
                Button("自动化权限设置") { media.openAutomationSettings() }.font(.caption)
            }
            if let error = media.actionError, error != current.error { failureText(error) }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DockMediaVisibility().frame(width: 0, height: 0))
        .onAppear { media.selectHoveredPlayer() }
    }

    private func transportButton(_ title: String, symbol: String, command: String) -> some View {
        Button { media.send(command) } label: {
            Image(systemName: symbol).frame(width: 20, height: 20)
        }
        .disabled(!media.current.canControl)
        .help(title)
        .accessibilityLabel(title)
    }

    private func failureText(_ message: String) -> some View {
        Text(message).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
    }
}
