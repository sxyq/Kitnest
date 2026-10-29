import Foundation

/// 锁屏保持：投屏期间，设备一旦进入休眠（手机黑屏），自动唤醒到**锁屏界面**，
/// 让镜像里能看到密码输入页、直接在 Mac 上解锁。
///
/// 背景（2026-10-30 真机实测）：
///   · 设备熄屏后 scrcpy 只能拿到**黑帧**（截图确认全黑），因为 SurfaceFlinger 不再合成；
///   · `--turn-screen-off` 在已锁屏设备上会让 scrcpy 直接退出，不能当默认方案；
///   · 所以在检测到 `mWakefulness` 变成 Asleep/Dozing 时发一次 `input keyevent 224`
///     （WAKEUP），设备亮起到锁屏页——镜像随之显示锁屏，用户可在镜像里输密码。
///
/// 注意：这会把**物理屏幕也点亮**（这是 Android 的语义，无法只亮虚拟屏而不亮实体屏）。
/// 所以只在「投屏会话进行中」生效，且每次休眠只唤醒一次，不阻止用户主动关屏。
final class CastScreenKeeper {

    static let shared = CastScreenKeeper()

    private var timer: Timer?
    private var serial: String?
    private var lastAwake: String = ""
    private var lastWakeAt = Date.distantPast

    private init() {}

    func start(serial: String?) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.serial = serial
            self.lastAwake = ""
            self.lastWakeAt = .distantPast
            self.timer?.invalidate()
            let t = Timer(timeInterval: 3.0, repeats: true) { [weak self] _ in
                self?.tick()
            }
            RunLoop.main.add(t, forMode: .common)
            self.timer = t
        }
    }

    func stop() {
        DispatchQueue.main.async { [weak self] in
            self?.timer?.invalidate()
            self?.timer = nil
            self?.serial = nil
        }
    }

    private func tick() {
        guard let adb = ScreenCastEngine.findADB() else { return }
        let serial = self.serial
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let state = Self.wakefulness(adb: adb, serial: serial)
            guard !state.isEmpty else { return }
            DispatchQueue.main.async {
                guard let self else { return }
                defer { self.lastAwake = state }
                let asleep = state.contains("Asleep") || state.contains("Dozing")
                guard asleep else { return }
                // 每次「进入休眠」只唤醒一次；30s 内不重复，避免和用户手动关屏对着干
                guard Date().timeIntervalSince(self.lastWakeAt) > 30 else { return }
                guard self.lastAwake != state || self.lastAwake.isEmpty else { return }
                self.lastWakeAt = Date()
                Log.info("Transfer", "锁屏保持：检测到 \(state)，唤醒到锁屏")
                Self.sendWake(adb: adb, serial: serial)
            }
        }
    }

    private static func wakefulness(adb: String, serial: String?) -> String {
        let out = run(adb: adb, serial: serial,
                      args: ["shell", "dumpsys power | grep -m1 mWakefulness"], timeout: 6)
        if let r = out.range(of: "mWakefulness=") {
            return String(out[r.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return ""
    }

    private static func sendWake(adb: String, serial: String?) {
        // 224 = KEYCODE_WAKEUP：只把屏幕点亮到锁屏，不做解锁
        _ = run(adb: adb, serial: serial, args: ["shell", "input", "keyevent", "224"], timeout: 6)
    }

    @discardableResult
    private static func run(adb: String, serial: String?, args: [String],
                            timeout: TimeInterval) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: adb)
        p.arguments = (serial.map { ["-s", $0] } ?? []) + args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        do { try p.run() } catch { return "" }
        let deadline = Date().addingTimeInterval(timeout)
        while p.isRunning && Date() < deadline { usleep(50_000) }
        if p.isRunning { p.terminate() }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }
}
