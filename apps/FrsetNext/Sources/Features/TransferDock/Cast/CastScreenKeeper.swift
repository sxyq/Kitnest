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
    private var generation = 0
    private var busy = false

    private init() {}

    func start(serial: String?) {
        generation += 1
        let gen = generation
        DispatchQueue.main.async { [weak self] in
            guard let self, gen == self.generation else { return }
            self.serial = serial
            self.lastAwake = ""
            self.lastWakeAt = .distantPast
            self.busy = false
            self.timer?.invalidate()
            let t = Timer(timeInterval: 3.0, repeats: true) { [weak self] _ in
                guard let self, gen == self.generation else { return }
                self.tick()
            }
            RunLoop.main.add(t, forMode: .common)
            self.timer = t
        }
    }

    func stop() {
        generation += 1
        timer?.invalidate()
        timer = nil
        serial = nil
        busy = false
    }

    private func tick() {
        guard !busy else { return }
        busy = true
        let gen = generation
        let target = serial.map { ["-s", $0] } ?? []
        ADBExtrasEngine.run(target + ["shell", "dumpsys power | grep -m1 mWakefulness"], timeout: 6) { [weak self] out, _ in
            guard let self, gen == self.generation else { return }
            self.busy = false
            guard let out, let range = out.range(of: "mWakefulness=") else { return }
            let state = String(out[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !state.isEmpty else { return }
            defer { self.lastAwake = state }
            let asleep = state.contains("Asleep") || state.contains("Dozing")
            guard asleep else { return }
            // 每次「进入休眠」只唤醒一次；30s 内不重复，避免和用户手动关屏对着干
            guard Date().timeIntervalSince(self.lastWakeAt) > 30 else { return }
            guard self.lastAwake != state || self.lastAwake.isEmpty else { return }
            self.lastWakeAt = Date()
            Log.info("Transfer", "锁屏保持：检测到 \(state)，唤醒到锁屏")
            self.busy = true
            // 224 = KEYCODE_WAKEUP：只把屏幕点亮到锁屏，不做解锁
            ADBExtrasEngine.run(target + ["shell", "input", "keyevent", "224"], timeout: 6) { [weak self] _, _ in
                guard let self, gen == self.generation else { return }
                self.busy = false
            }
        }
    }
}
