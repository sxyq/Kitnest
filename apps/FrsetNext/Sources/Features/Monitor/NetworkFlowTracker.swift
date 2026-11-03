import AppKit
import Foundation

// MARK: - 网络分流统计（最近 10 分钟滑动窗口）
//
// 用户需求（2026-11-03）：
//   「分流窗可以设置显示多少个；展现要跟着当前流量实时变化；要有 App 图标、
//     名字和分了多少；按过去 10 分钟的实际情况展现。」
//
// 为什么需要这一层：
//   nettop（C 层每 5s 一轮）给的是**瞬时速率** B/s，卡片上直接显示"现在多少"只能反映
//   最近 5 秒，用户切个页面回来数字就归零。要看"到底是谁吃掉了带宽"，必须把速率
//   按时间积分成**字节数**，并在滑动窗口里累计。
//
// 数据来源：
//   · 分应用：StatsDataProvider.current.procNet（nettop 差分，diskRead=下行 B/s，diskWrite=上行）
//   · 整机：NetworkPulse 的 1s 脉冲（netDownBps/netUpBps）
//   两者都只在监测页可见时采样（C 层 nettop 在隐藏时暂停），所以窗口 = "面板可见期间的最近 10 分钟"，
//   覆盖不足 10 分钟时由 UI 标明"已统计 X 分钟"，不假装是 10 分钟。

public struct NetworkFlowEntry: Identifiable, Sendable {
    public let key: String
    public let name: String
    public let iconPath: String
    /// 窗口内累计字节
    public let downBytes: Double
    public let upBytes: Double
    /// 当前瞬时速率（B/s），用于"是否正在跑"的提示
    public let liveDown: Double
    public let liveUp: Double

    public var id: String { key }
    public var totalBytes: Double { downBytes + upBytes }
    public var liveTotal: Double { liveDown + liveUp }
}

public final class NetworkFlowTracker {

    public static let shared = NetworkFlowTracker()

    /// 统计窗口：10 分钟
    public static let windowSeconds: TimeInterval = 600
    /// 分应用采样最小间隔（nettop 5s 一轮，少于 4s 的重复读会重复计费）
    private static let appMinInterval: TimeInterval = 4.0
    /// 单值上限，防脏数据把窗口撑爆
    private static let maxRate: Double = 10_000_000_000

    private struct Sample {
        let at: TimeInterval
        let down: Double
        let up: Double
    }

    private struct AppState {
        var name: String
        var iconPath: String
        var liveDown: Double
        var liveUp: Double
        var samples: [Sample]
    }

    private let lock = NSLock()
    private var apps: [String: AppState] = [:]
    private var nicSamples: [Sample] = []
    private var lastAppAt: TimeInterval = 0
    private var lastNICAt: TimeInterval = 0
    /// 上一轮 nettop 的指纹（速率合计）：数据没变就不再计一次，
    /// 否则「每 2s 读一次缓存、nettop 5s 才更新」会把同一段流量重复累计 2.5 倍
    private var lastAppSignature: Double = -1
    private var startedAt: TimeInterval = 0
    /// v191：常驻节拍（不依赖监测页可见）
    private var backgroundTimer: Timer?

    private init() {}

    // MARK: - 常驻统计（v191）
    //
    // 用户原话：「这个每次打开它都会隔一会才跳得出来。不对，应该是就跟其他的组件一样，
    //           就一直放在那，只是它会变化它的一个显示的 APP」
    //
    // 旧行为：nettop 随监测页可见性启停（v128 CPU 优化）→ 关页面就断采，
    // 再打开要从 0 累计，前几分钟只有「刚开始统计 · 已 27 秒」。
    // 新行为：app 一起来就每 5s 读一轮 nettop 缓存 + 整机速率，积分进 10 分钟窗口。
    // 打开网络页时窗口里已经有完整历史，上榜 App 随流量自然变化。

    /// 后台节拍间隔（nettop 本身就是 5s 一轮，再密只是重复读同一份缓存）
    private static let backgroundInterval: TimeInterval = 5.0

    /// 启动常驻统计（MonitorModule 启动时调用一次；幂等）
    public func startBackgroundUpdates() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard backgroundTimer == nil else { return }
        guard MonitorPreferences.networkKeepAlive else { return }
        backgroundTick()                       // 立刻采一帧，首开不用等 5s
        let timer = Timer(timeInterval: Self.backgroundInterval, repeats: true) { [weak self] _ in
            self?.backgroundTick()
        }
        timer.tolerance = 0.6
        RunLoop.main.add(timer, forMode: .common)
        backgroundTimer = timer
    }

    /// 停止常驻统计（监测总开关关闭 / 用户关掉常驻时）
    public func stopBackgroundUpdates() {
        backgroundTimer?.invalidate()
        backgroundTimer = nil
    }

    /// 常驻开关变化后重新评估（设置页改完立刻生效）
    public func applyKeepAlivePreference() {
        if MonitorPreferences.networkKeepAlive && MonitorPreferences.isEnabled {
            startBackgroundUpdates()
        } else {
            stopBackgroundUpdates()
        }
    }

    private func backgroundTick() {
        guard MonitorPreferences.isEnabled, MonitorPreferences.networkKeepAlive else { return }
        // 分应用：C 层 nettop 后台线程的缓存（线程本身由 StatsDataProvider 保活）
        let items = StatsDataProvider.readProcList(kind: 3, max: 8)
        if !items.isEmpty { ingestApps(items) }
        // 整机：C 层 1s 更新的瞬时速率 × 5s 节拍 ≈ 这一段实际收发字节
        let snapshot = g_snap
        if snapshot.valid != 0 {
            ingestNIC(down: snapshot.netDownBps, up: snapshot.netUpBps)
        }
    }

    // MARK: 采样入口

    /// 分应用采样（由 StatsDataProvider 每次读取 procNet 时调用，内部按 4s 去重）
    public func ingestApps(_ items: [StatsProcItem], now: Date = Date()) {
        let t = now.timeIntervalSince1970
        lock.lock()
        defer { lock.unlock() }
        // 与上一轮隔太久（页面关过 / 休眠）：不把两段拼成一个窗口
        if lastAppAt > 0, t - lastAppAt > 120 { resetLocked() }
        let signature = items.reduce(0.0) { $0 + $1.diskRead + $1.diskWrite } + Double(items.count) * 0.001
        let changed = signature != lastAppSignature
        let overdue = lastAppAt == 0 || t - lastAppAt >= 6.0
        // 数据变了才计一次；长时间没变（恒定速率）也补一次，防止漏计
        guard (changed || overdue), t - lastAppAt >= 3.5 || lastAppAt == 0 else { return }
        let interval = lastAppAt == 0 ? 5.0 : min(15, t - lastAppAt)
        lastAppAt = t
        lastAppSignature = signature
        if startedAt == 0 { startedAt = t }

        for item in items {
            let downRate = sanitize(item.diskRead)
            let upRate = sanitize(item.diskWrite)
            // 速率 × 间隔 = 这一档里该 App 实际收发的字节
            let downBytes = downRate * interval
            let upBytes = upRate * interval
            guard downBytes + upBytes > 0 || apps[item.groupKey] != nil else { continue }
            var state = apps[item.groupKey] ?? AppState(name: item.name,
                                                        iconPath: item.iconPath,
                                                        liveDown: 0, liveUp: 0,
                                                        samples: [])
            state.name = item.name
            if !item.iconPath.isEmpty { state.iconPath = item.iconPath }
            state.liveDown = downRate
            state.liveUp = upRate
            state.samples.append(Sample(at: t, down: downBytes, up: upBytes))
            apps[item.groupKey] = state
            if apps.count > 200 { trimApps() }
        }
        prune(t)
    }

    /// 整机采样（NetworkPulse 1s 一拍）：用来算「其他 App」= 整机 - 已列出
    public func ingestNIC(down: Double, up: Double, now: Date = Date()) {
        let t = now.timeIntervalSince1970
        lock.lock()
        defer { lock.unlock() }
        if lastNICAt > 0, t - lastNICAt > 120 { resetLocked() }
        let interval = lastNICAt == 0 ? 1.0 : min(5, t - lastNICAt)
        guard t - lastNICAt >= 0.4 else { return }
        lastNICAt = t
        if startedAt == 0 { startedAt = t }
        nicSamples.append(Sample(at: t,
                                 down: sanitize(down) * interval,
                                 up: sanitize(up) * interval))
        prune(t)
    }

    // MARK: 读取

    public struct Snapshot {
        /// 已按窗口总量降序
        public let entries: [NetworkFlowEntry]
        /// 窗口内整机累计（上下行合计）
        public let nicTotalBytes: Double
        public let nicDownBytes: Double
        public let nicUpBytes: Double
        /// 已统计时长（秒）：不足 600 秒时 UI 要如实写「已统计 X 分钟」
        public let coverage: TimeInterval
        public var isEmpty: Bool { entries.isEmpty && nicTotalBytes <= 0 }
    }

    public func snapshot(now: Date = Date()) -> Snapshot {
        let t = now.timeIntervalSince1970
        lock.lock()
        prune(t)
        let appStates = apps
        let nic = nicSamples
        let started = startedAt
        lock.unlock()

        var entries: [NetworkFlowEntry] = []
        entries.reserveCapacity(appStates.count)
        for (key, state) in appStates {
            guard !state.samples.isEmpty else { continue }
            var down = 0.0, up = 0.0
            for sample in state.samples { down += sample.down; up += sample.up }
            entries.append(NetworkFlowEntry(key: key,
                                            name: state.name,
                                            iconPath: state.iconPath,
                                            downBytes: down,
                                            upBytes: up,
                                            liveDown: state.liveDown,
                                            liveUp: state.liveUp))
        }
        entries.sort { $0.totalBytes > $1.totalBytes }

        var nicDown = 0.0, nicUp = 0.0
        for sample in nic { nicDown += sample.down; nicUp += sample.up }

        return Snapshot(entries: entries,
                        nicTotalBytes: nicDown + nicUp,
                        nicDownBytes: nicDown,
                        nicUpBytes: nicUp,
                        coverage: started > 0 ? max(0, t - started) : 0)
    }

    /// 清空（设置里的「清空历史与峰值」一并调用）
    public func reset() {
        lock.lock()
        resetLocked()
        lock.unlock()
    }

    /// 已持锁版本（内部复用）
    private func resetLocked() {
        apps.removeAll()
        nicSamples.removeAll()
        lastAppAt = 0
        lastNICAt = 0
        lastAppSignature = -1
        startedAt = 0
    }

    // MARK: 内部

    private func prune(_ now: TimeInterval) {
        let cutoff = now - Self.windowSeconds
        nicSamples.removeAll { $0.at < cutoff }
        for (key, state) in apps {
            var trimmed = state.samples
            if let firstKeep = trimmed.firstIndex(where: { $0.at >= cutoff }) {
                if firstKeep > 0 { trimmed.removeFirst(firstKeep) }
            } else {
                trimmed.removeAll()
            }
            if trimmed.isEmpty {
                // 窗口内没有流量了：保留 30s 让「刚刚很活跃」的项不要立刻消失
                if state.samples.last.map({ now - $0.at > 30 }) ?? true {
                    apps.removeValue(forKey: key)
                } else {
                    var copy = state
                    copy.samples = trimmed
                    apps[key] = copy
                }
            } else if trimmed.count != state.samples.count {
                var copy = state
                copy.samples = trimmed
                apps[key] = copy
            }
        }
    }

    /// App 数量失控时，丢掉窗口总量最小的那一半
    private func trimApps() {
        let ranked = apps.map { (key: $0.key, total: $0.value.samples.reduce(0) { $0 + $1.down + $1.up }) }
            .sorted { $0.total > $1.total }
        for item in ranked.dropFirst(120) { apps.removeValue(forKey: item.key) }
    }

    private func sanitize(_ raw: Double) -> Double {
        guard raw.isFinite, raw > 0, raw < Self.maxRate else { return 0 }
        return raw
    }
}

// MARK: - 图标缓存（App 路径 → NSImage）

enum NetworkFlowIcon {
    private static let cache: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>()
        c.countLimit = 64
        return c
    }()

    static func icon(forPath path: String) -> NSImage? {
        guard !path.isEmpty else { return nil }
        let key = path as NSString
        if let hit = cache.object(forKey: key) { return hit }
        let icon = NSWorkspace.shared.icon(forFile: path)
        cache.setObject(icon, forKey: key)
        return icon
    }
}
