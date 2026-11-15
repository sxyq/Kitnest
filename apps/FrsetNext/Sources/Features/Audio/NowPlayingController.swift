import AppKit
import Combine

/// MediaRemote 是系统 Now Playing（正在播放）服务，不使用有声进程推断曲目。
/// 2026-11-15：本机导出已读取；15.4 起读取要求 Apple 平台进程，使用系统 osascript。
/// 接口依据：kernoeb/mac-now-playing 的 NowPlaying.swift、theos/headers 的 MediaRemote.h。
@MainActor
final class NowPlayingController: ObservableObject {
    static let shared = NowPlayingController()

    struct Snapshot: Decodable {
        var available = false
        var title = ""
        var artist = ""
        var album = ""
        var source = ""
        var bundleID = ""
        var isPlaying = false
        var duration: Double?
        var elapsed: Double?
        var timestamp: Double?
        var rate: Double?
        var artworkData: String?
        var artworkURL: String?
        var commandAccepted: Bool?
    }

    @Published private(set) var snapshot = Snapshot()
    @Published private(set) var artwork: NSImage?
    @Published private(set) var feedback = ""
    @Published private(set) var now = Date.now
    private var consumers = Set<UUID>()
    private var timer: Timer?
    private var process: Process?
    private var artworkTask: Task<Void, Never>?

    var position: Double? {
        guard let elapsed = snapshot.elapsed else { return nil }
        let advance = snapshot.isPlaying ? now.timeIntervalSince1970 - (snapshot.timestamp ?? now.timeIntervalSince1970) : 0
        let value = max(0, elapsed + max(0, advance) * (snapshot.rate ?? 1))
        return snapshot.duration.map { min($0, value) } ?? value
    }

    func setVisible(_ visible: Bool, consumer: UUID) {
        if visible { consumers.insert(consumer) } else { consumers.remove(consumer) }
        if !consumers.isEmpty {
            guard timer == nil else { return }
            refresh()
            timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self, !self.consumers.isEmpty else { return }
                    self.now = .now; self.refresh()
                }
            }
        } else {
            timer?.invalidate(); timer = nil
            process?.terminate(); process = nil
            artworkTask?.cancel(); artworkTask = nil
            snapshot = Snapshot(); artwork = nil
        }
    }

    func refresh() {
        if process == nil { request(action: "read") }
    }

    func send(_ command: Int) {
        request(action: String(command))
    }

    func seek(to seconds: Double) {
        request(action: "24", seconds: seconds)
    }

    private func request(action: String, seconds: Double = 0) {
        process?.terminate()
        let task = Process()
        let pipe = Pipe()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        task.arguments = ["-l", "JavaScript", "-e", Self.script, action, String(seconds)]
        task.standardOutput = pipe
        task.standardError = pipe
        process = task
        do { try task.run() }
        catch { process = nil; feedback = "无法读取正在播放：\(error.localizedDescription)"; return }
        DispatchQueue.global(qos: .utility).async {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()
            Task { @MainActor [weak self] in
                guard let self, self.process === task else { return }
                self.process = nil
                do {
                    guard task.terminationStatus == 0 else {
                        throw NSError(domain: "MediaRemote", code: Int(task.terminationStatus),
                                      userInfo: [NSLocalizedDescriptionKey: String(decoding: data, as: UTF8.self)])
                    }
                    let next = try JSONDecoder().decode(Snapshot.self, from: data)
                    let changed = next.artworkData != self.snapshot.artworkData || next.artworkURL != self.snapshot.artworkURL ||
                        next.title != self.snapshot.title || next.bundleID != self.snapshot.bundleID
                    self.snapshot = next
                    self.now = .now
                    if action != "read" {
                        self.feedback = next.commandAccepted == true ? "" : "播放器未接受该操作"
                    }
                    if changed { self.loadArtwork(next) }
                } catch {
                    self.artworkTask?.cancel()
                    self.snapshot = Snapshot()
                    self.artwork = nil
                    self.feedback = "正在播放服务：\(error.localizedDescription)"
                }
            }
        }
    }

    private func loadArtwork(_ item: Snapshot) {
        artworkTask?.cancel()
        artwork = nil
        if let encoded = item.artworkData, let data = Data(base64Encoded: encoded) {
            artwork = NSImage(data: data)
        } else if let value = item.artworkURL, let url = URL(string: value) {
            // 只读取当前曲目由播放器提供的封面地址；不搜索替代唱片或生成封面。
            artworkTask = Task {
                do {
                    let data: Data
                    if url.isFileURL {
                        data = try await Task.detached(priority: .utility) { try Data(contentsOf: url) }.value
                    } else {
                        data = try await URLSession.shared.data(from: url).0
                    }
                    guard !Task.isCancelled else { return }
                    artwork = NSImage(data: data)
                } catch {
                    if !Task.isCancelled { feedback = "播放器封面读取失败：\(error.localizedDescription)" }
                }
            }
        }
    }

    // 同一路径读取及控制系统服务；不发送 Apple Events，不修改自动化或辅助功能权限。
    private static let script = #"""
    ObjC.import('Foundation');
    function present(value) { return value && !value.isNil(); }
    function text(value) { return present(value) ? ObjC.unwrap(value) : ''; }
    function run(args) {
        const framework = $.NSBundle.bundleWithPath('/System/Library/PrivateFrameworks/MediaRemote.framework');
        if (!framework.load) throw Error('MediaRemote 加载失败');
        const request = $.NSClassFromString('MRNowPlayingRequest');
        let accepted = null;
        if (args[0] !== 'read') {
            ObjC.bindFunction('MRMediaRemoteSendCommand', ['bool', ['unsigned int', 'id']]);
            const options = Number(args[0]) === 24
                ? $({'kMRMediaRemoteOptionPlaybackPosition': Number(args[1])}) : null;
            accepted = !!$.MRMediaRemoteSendCommand(Number(args[0]), options);
            $.NSRunLoop.currentRunLoop.runUntilDate($.NSDate.dateWithTimeIntervalSinceNow(0.2));
        }
        const item = request.localNowPlayingItem;
        const info = present(item) ? item.nowPlayingInfo : null;
        const metadata = present(item) ? item.metadata : null;
        const path = request.localNowPlayingPlayerPath;
        const client = present(path) ? path.client : null;
        function value(key) { return present(info) ? info.objectForKey('kMRMediaRemoteNowPlayingInfo' + key) : null; }
        function number(key) { const v = value(key); return present(v) ? Number(ObjC.unwrap(v)) : null; }
        const calculated = present(metadata) && metadata.hasElapsedTime;
        const stamp = value('Timestamp');
        let image = value('ArtworkData');
        if (!present(image) && present(item) && present(item.artwork)) image = item.artwork.imageData;
        let url = present(metadata) ? metadata.artworkFileURL : null;
        if (!present(url) && present(metadata)) url = metadata.artworkURL;
        const bundle = present(client) ? text(client.parentApplicationBundleIdentifier) || text(client.bundleIdentifier) : '';
        return JSON.stringify({
            available: present(item) ? true : false,
            title: text(value('Title')), artist: text(value('Artist')), album: text(value('Album')),
            source: present(client) ? text(client.displayName) : '', bundleID: bundle,
            isPlaying: !!request.localIsPlaying,
            duration: number('Duration'),
            elapsed: calculated ? Number(metadata.calculatedPlaybackPosition) : number('ElapsedTime'), rate: number('PlaybackRate'),
            timestamp: !calculated && present(stamp) ? Number(stamp.timeIntervalSince1970) : $.NSDate.date.timeIntervalSince1970,
            artworkData: present(image) ? text(image.base64EncodedStringWithOptions(0)) : null,
            artworkURL: present(url) ? (url.isKindOfClass($.NSURL) ? text(url.absoluteString) : text(url)) : null,
            commandAccepted: accepted
        });
    }
    """#
}
