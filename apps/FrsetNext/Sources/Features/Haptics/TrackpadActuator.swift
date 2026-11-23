import Foundation
import IOKit

/// 直接驱动 Force Touch 触控板的马达（MultitouchSupport 私有接口）。
///
/// 为什么需要它：`NSHapticFeedbackManager` 只在手指正贴着触控板时才真正敲得响。
/// Kitnest 的复制、截图、传输完成大多发生在菜单栏 / 悬浮面板，事件回来时手指早已离开——
/// 公开接口的日志每次都在，手上却没有任何感觉。私有接口不受这个限制。
///
/// 边界（2026-11-23 重构）：
/// - 只封装 MTActuator 四个符号，**不新增**其它私有函数、不硬编码新波形；
/// - `init` 不做任何 I/O：dlopen、设备枚举、打开句柄全部在后台串行队列里完成，
///   避免第一次业务事件在主线程上枚举设备；
/// - 调用失败只做「关掉 → 重新发现 → 重开一次」，不无限重试；
/// - 睡眠唤醒 / 设备增删后 `invalidate()`，由下一次 `prepare()` 重建；
/// - 任何一步失败都返回 false，由 `HapticService` 回落公开接口，不影响业务。
final class TrackpadActuator {

    enum State: Equatable {
        /// 还没准备过（后台准备尚未开始）
        case unprepared
        /// 私有框架不存在 / 符号缺失（系统改动）
        case frameworkUnavailable
        /// 没有支持振动的触控板（Mac mini、无 Force Touch 的机型）
        case noDevice
        /// 找到设备但打开失败（返回码原样保留，便于排障）
        case openFailed(Int32)
        /// 已就绪
        case ready(deviceID: UInt64)
    }

    static let shared = TrackpadActuator()

    private typealias CreateFn = @convention(c) (UInt64) -> UnsafeMutableRawPointer?
    private typealias OpenFn = @convention(c) (UnsafeMutableRawPointer) -> Int32
    private typealias ActuateFn = @convention(c) (UnsafeMutableRawPointer, Int32, UInt32, Float, Float) -> Int32
    private typealias CloseFn = @convention(c) (UnsafeMutableRawPointer) -> Int32

    private struct Symbols {
        let create: CreateFn
        let open: OpenFn
        let actuate: ActuateFn
        let close: CloseFn
    }

    private let lock = NSLock()
    private let prepareQueue = DispatchQueue(label: "com.kitnest.haptics.actuator", qos: .userInitiated)
    private var symbols: Symbols?
    private var actuator: UnsafeMutableRawPointer?
    private var state: State = .unprepared
    private var lastDiscoveryAt: TimeInterval = 0
    /// 失败后允许重新发现的间隔；避免每个事件都去枚举 IOKit
    private static let rediscoveryInterval: TimeInterval = 20

    private init() {}

    deinit {
        if let actuator { symbols?.close(actuator) }
    }

    /// 只读快照（任意线程）。
    var currentState: State {
        lock.lock(); defer { lock.unlock() }
        return state
    }

    /// 后台准备，幂等。主线程调用立即返回；`then` 在准备结束后于后台队列回调。
    func prepare(then: (() -> Void)? = nil) {
        prepareQueue.async { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let alreadyReady = self.actuator != nil
            if !alreadyReady { self.lastDiscoveryAt = 0 }
            self.lock.unlock()
            if !alreadyReady { _ = self.openWithDiscovery() }
            then?()
        }
    }

    /// 敲一下。`id`：3 轻、4 中、6 重（既有波形编号，不扩展）。
    /// 失败时只重开一次；仍失败返回 false，由上层回落公开接口。
    @discardableResult
    func actuate(id: Int32) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        if actuator != nil, let symbols {
            if symbols.actuate(actuator!, id, 0, 0, 2.0) == KERN_SUCCESS { return true }
            // 睡眠唤醒后旧句柄会失效：先关掉，再重建一次
            closeLocked()
            state = .unprepared
        }
        guard openLocked(forceDiscovery: false), let symbols, let actuator else { return false }
        guard symbols.actuate(actuator, id, 0, 0, 2.0) == KERN_SUCCESS else {
            closeLocked()
            state = .unprepared
            return false
        }
        return true
    }

    /// 睡眠唤醒 / 设备变化后调用：释放句柄并允许下次重新发现。
    func invalidate() {
        lock.lock()
        closeLocked()
        state = .unprepared
        lastDiscoveryAt = 0
        lock.unlock()
    }

    // MARK: - 内部

    private func openWithDiscovery() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard openLocked(forceDiscovery: true) else { return false }
        Log.info("Haptics", "马达直连就绪 \(describeLocked())")
        return true
    }

    @discardableResult
    private func openLocked(forceDiscovery: Bool) -> Bool {
        if actuator != nil { return true }
        let now = Date.timeIntervalSinceReferenceDate
        if !forceDiscovery, now - lastDiscoveryAt < Self.rediscoveryInterval { return false }
        lastDiscoveryAt = now

        if symbols == nil { symbols = Self.loadSymbols(at: Self.frameworkPath) }
        guard let symbols else {
            state = .frameworkUnavailable
            // 每次真正发现尝试才记一行（重发现限频 20s，不会刷屏）：设置页的说明与日志同源
            Log.info("Haptics", "马达直连不可用：\(describeLocked())，回落公开接口")
            return false
        }
        guard let id = Self.actuationDeviceID() else {
            state = .noDevice
            Log.info("Haptics", "马达直连不可用：\(describeLocked())，回落公开接口")
            return false
        }
        guard let fresh = symbols.create(id) else {
            state = .noDevice
            Log.info("Haptics", "马达直连不可用：\(describeLocked())，回落公开接口")
            return false
        }
        let opened = symbols.open(fresh)
        guard opened == KERN_SUCCESS else {
            symbols.close(fresh)
            state = .openFailed(opened)
            Log.info("Haptics", "马达直连不可用：\(describeLocked())，回落公开接口")
            return false
        }
        actuator = fresh
        state = .ready(deviceID: id)
        return true
    }

    private func closeLocked() {
        if let actuator, let symbols { symbols.close(actuator) }
        actuator = nil
    }

    private func describeLocked() -> String {
        switch state {
        case .ready(let id): return "id=0x\(String(id, radix: 16))"
        case .frameworkUnavailable: return "私有框架/符号不可用"
        case .noDevice: return "没有支持振动的触控板"
        case .openFailed(let code): return "打开失败 code=\(code)"
        case .unprepared: return "未准备"
        }
    }

    /// 只 dlopen 一次，四个符号缺一即视为不可用。
    ///
    /// `--haptic-framework=<path>` 是验证钩子：把路径指向一个**存在但没有 MTActuator 符号**的
    /// 框架，就能在真实进程里走到「系统移除符号」那条分支（`frameworkUnavailable`）。
    /// 不传参数时行为与以前完全一致；业务路径永不带这个参数。
    private static var frameworkPath: String {
        let prefix = "--haptic-framework="
        if let argument = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix(prefix) }) {
            return String(argument.dropFirst(prefix.count))
        }
        return "/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport"
    }

    private static func loadSymbols(at path: String) -> Symbols? {
        guard let handle = dlopen(path, RTLD_NOW),
        let create = dlsym(handle, "MTActuatorCreateFromDeviceID"),
        let open = dlsym(handle, "MTActuatorOpen"),
        let actuate = dlsym(handle, "MTActuatorActuate"),
        let close = dlsym(handle, "MTActuatorClose")
        else { return nil }
        return Symbols(create: unsafeBitCast(create, to: CreateFn.self),
                       open: unsafeBitCast(open, to: OpenFn.self),
                       actuate: unsafeBitCast(actuate, to: ActuateFn.self),
                       close: unsafeBitCast(close, to: CloseFn.self))
    }

    /// 找一块支持振动的触控板：内建优先，其次外接（Magic Trackpad）。
    ///
    /// 外接设备的 ID 与内建不同，旧实现只认 `MT Built-In`，等于把外接板完全排除。
    /// 这里放宽到「ActuationSupported + 有 Multitouch ID」，仍只调用既有的四个符号。
    private static func actuationDeviceID() -> UInt64? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault,
                                           IOServiceMatching("AppleMultitouchDevice"),
                                           &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }

        var devices: [NSDictionary] = []
        while true {
            let service = IOIteratorNext(iterator)
            guard service != 0 else { break }
            defer { IOObjectRelease(service) }

            var properties: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(service, &properties,
                                                    kCFAllocatorDefault, 0) == KERN_SUCCESS,
                  let dictionary = properties?.takeRetainedValue() as NSDictionary? else { continue }
            devices.append(dictionary)
        }
        return selectDeviceID(from: devices)
    }

    /// 纯选择逻辑，不碰 IOKit（便于用合成字典验证「内建优先 / 外接兜底 / 不支持则排除」）。
    /// 判据只有两条：`ActuationSupported == true` 且带 `Multitouch ID`。
    static func selectDeviceID(from devices: [NSDictionary]) -> UInt64? {
        var fallback: UInt64?
        for dictionary in devices {
            let supported = (dictionary["ActuationSupported"] as? NSNumber)?.boolValue ?? false
            let builtIn = (dictionary["MT Built-In"] as? NSNumber)?.boolValue ?? false
            guard supported, let id = dictionary["Multitouch ID"] as? NSNumber else { continue }
            if builtIn { return id.uint64Value }
            if fallback == nil { fallback = id.uint64Value }
        }
        return fallback
    }
}
