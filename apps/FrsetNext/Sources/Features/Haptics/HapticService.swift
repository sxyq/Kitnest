import AppKit
import Combine

/// 业务事件的唯一执行入口。
///
/// 职责：总开关与场景判断 → 设备能力 → 节奏/强度 → 去重与限频 → 线程调度 → 驱动回落。
/// 业务模块只调用 `HapticService.shared.perform(.xxx)`，不直接碰 `NSHapticFeedbackManager`
/// 或 `TrackpadActuator`。
///
/// 线程模型：`perform` 可从任意线程调用，立即返回；全部判断与驱动调用都在
/// `com.kitnest.haptics` 串行队列上完成，唯一回主线程的是状态发布（给设置页看）。
final class HapticService: ObservableObject {

    static let shared = HapticService()

    /// 当前设备能力（设置页据此如实说明，不用「试听成功」冒充真实触感）
    @Published private(set) var availability: HapticAvailability = .unknown
    /// 最近一次投递结果（只读诊断用；不发布，避免每个事件都刷新设置页）
    private(set) var lastDelivery: HapticDelivery?
    private(set) var lastEvent: HapticEvent?

    /// 不同事件之间的最小间距：**延迟**排期，而不是丢弃。
    /// 旧实现共用一个 60ms 窗口，两个真实事件会互相抑制（拖网格时把截图成功的反馈吃掉）。
    private static let minimumSpacing: TimeInterval = 0.045

    private let store = HapticSettingsStore.shared
    private let router = HapticDriverRouter()
    private let queue = DispatchQueue(label: "com.kitnest.haptics", qos: .userInitiated)
    private var lastFiredAt: [HapticEvent: TimeInterval] = [:]
    private var lastSlotAt: TimeInterval = 0
    private var started = false
    private var wakeObserver: NSObjectProtocol?

    private init() {}

    // MARK: - 生命周期

    /// 启动接线：订阅睡眠唤醒 + 后台预热驱动 + 排障探针。全部非阻塞，不进启动关键路径。
    func start() {
        guard !started else { return }
        started = true
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            // 唤醒后旧句柄会失效；重建放到后台，别在主线程枚举设备
            self.queue.async { self.router.invalidate() }
            self.queue.asyncAfter(deadline: .now() + 0.5) {
                self.router.prepare { self.publishAvailability() }
            }
        }
        // 0.8s 后才碰私有框架：避开启动路径（用户点图标到出现界面之间不做任何设备枚举）
        queue.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            guard let self else { return }
            self.router.prepare { self.publishAvailability() }
        }
        checkDebugProbe()
    }

    // MARK: - 业务入口

    /// 真实业务完成点调用。总开关关闭、场景关闭、强度为「关闭」时都不发。
    func perform(_ event: HapticEvent) {
        let configuration = store.current
        guard configuration.isEnabled(event) else { return }
        schedule(event: event, intensity: configuration.intensity, respectCooldown: true)
    }

    /// 设置页试听：用**草稿**强度与真实节奏演示，不改已保存配置、不影响业务。
    /// 试听只证明「这台设备能给出什么反馈」，不证明场景已经接线。
    func preview(event: HapticEvent, intensity: HapticIntensity) {
        guard intensity != .off else { return }
        schedule(event: event, intensity: intensity, respectCooldown: false)
    }

    /// 设置页保存后调用：写盘成功才替换内存快照。
    func apply(_ configuration: HapticConfiguration) -> Error? {
        store.save(configuration)
    }

    /// 设备能力的一句话说明（设置页/日志共用）。
    var deviceSummary: String {
        switch availability {
        case .ready:
            return "触控板马达已就绪：手指离开触控板也能反馈"
        case .publicOnly(let reason):
            return "\(reason.text)：仅向系统接口请求，手指贴着触控板时才有感"
        case .unavailable:
            return "没有可用的触觉设备"
        case .unknown:
            return "正在检测触觉设备"
        }
    }

    // MARK: - 排期

    private func schedule(event: HapticEvent, intensity: HapticIntensity,
                          respectCooldown: Bool) {
        let now = Date.timeIntervalSinceReferenceDate
        queue.async { [weak self] in
            guard let self else { return }
            if respectCooldown {
                let last = self.lastFiredAt[event] ?? -.greatestFiniteMagnitude
                guard now - last >= event.cooldown else { return }
                self.lastFiredAt[event] = now
            }
            // 全局槽位只做「错峰」：同一时刻的多个真实事件按 45ms 依次发出，不互相吞掉
            let slot = max(now, self.lastSlotAt + Self.minimumSpacing)
            self.lastSlotAt = slot
            let delay = slot - now
            if delay > 0.001 {
                self.queue.asyncAfter(deadline: .now() + delay) {
                    self.emit(event: event, intensity: intensity)
                }
            } else {
                self.emit(event: event, intensity: intensity)
            }
        }
    }

    private func emit(event: HapticEvent, intensity: HapticIntensity) {
        for step in HapticPattern.steps(for: event.patternClass, intensity: intensity) {
            let fire = { [weak self] in
                guard let self else { return }
                let delivery = self.router.deliver(HapticPulse(intensity: step.intensity))
                self.record(delivery, event: event, intensity: step.intensity)
            }
            if step.delay > 0.001 {
                queue.asyncAfter(deadline: .now() + step.delay, execute: fire)
            } else {
                fire()
            }
        }
    }

    private func record(_ delivery: HapticDelivery, event: HapticEvent, intensity: HapticIntensity) {
        let availability = router.availability
        Log.info("Haptics", "触觉 \(event.settingTitle) 类型=\(event.patternClass.label) "
            + "强度=\(intensity.rawValue) 结果=\(delivery.rawValue)")
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.lastDelivery = delivery
            self.lastEvent = event
            if self.availability != availability { self.availability = availability }
        }
    }

    private func publishAvailability() {
        let availability = router.availability
        DispatchQueue.main.async { [weak self] in
            guard let self, self.availability != availability else { return }
            self.availability = availability
        }
    }

    /// 启动探针——`defaults write com.sxyq.frsetnext probe.haptic -bool true`
    /// 后重启，2.5s 后按真实业务路径敲一次（走配置、走节流）；用完删键。
    private func checkDebugProbe() {
        guard UserDefaults.standard.bool(forKey: "probe.haptic") else { return }
        // 用完即删：探针是一次性排障开关，不删会让每次启动都敲一下
        UserDefaults.standard.removeObject(forKey: "probe.haptic")
        Log.info("Haptics", "探针：检测到 probe.haptic，2.5s 后按真实事件触发（键已自删）")
        queue.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            self?.perform(.gridMove)
        }
    }
}

/// 事件类型 → 实际节奏。硬件只有三档波形，所以这里只做「单次 / 双次 + 强度上限」，
/// 不假装 18 个事件各有独立波形。
enum HapticPattern {
    struct Step {
        let delay: TimeInterval
        let intensity: HapticIntensity
    }

    static func steps(for patternClass: HapticPatternClass,
                      intensity: HapticIntensity) -> [Step] {
        guard intensity != .off else { return [] }
        switch patternClass {
        case .boundary:
            // 高频事件：强度封顶「中」，避免拖拽时连续重击
            let capped: HapticIntensity = intensity.level > HapticIntensity.medium.level
                ? .medium : intensity
            return [Step(delay: 0, intensity: capped)]
        case .success:
            return [Step(delay: 0, intensity: intensity)]
        case .milestone:
            return [Step(delay: 0, intensity: intensity),
                    Step(delay: 0.09, intensity: intensity)]
        case .failure:
            // 失败不低于「中」：轻档下听不出「出错」的差别
            let strong = HapticIntensity.atLeast(.medium, intensity)
            return [Step(delay: 0, intensity: strong),
                    Step(delay: 0.06, intensity: strong)]
        }
    }
}

extension HapticPatternClass {
    var label: String {
        switch self {
        case .boundary: return "边界"
        case .success: return "完成"
        case .milestone: return "里程碑"
        case .failure: return "失败"
        }
    }
}

extension HapticEvent {
    /// 同一事件的去重窗口。连续网格吸附允许更快，完成/失败类慢一些。
    var cooldown: TimeInterval {
        switch patternClass {
        case .boundary: return 0.09
        case .success: return 0.25
        case .milestone, .failure: return 0.40
        }
    }
}
