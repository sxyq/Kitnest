import Foundation
import IOKit

/// 直接驱动 Force Touch 触控板的马达（MultitouchSupport 私有接口）。
///
/// 为什么不用公开接口：`NSHapticFeedbackManager` 只在手指正贴着触控板时
/// 才真正敲得响。Kitnest 的复制、截图、传输完成大多发生在菜单栏或悬浮面板，
/// 事件回来时手指早已离开——所以日志里每次请求都在，手上却没有任何感觉。
/// 私有接口不受这个限制，手离开触控板也能敲；非 App Store 分发（DMG）可用。
///
/// 任何一步失败都返回 false，由 `HapticFeedback` 回落公开接口，不影响主流程。
final class TrackpadActuator {

    static let shared = TrackpadActuator()

    private typealias CreateFn = @convention(c) (UInt64) -> UnsafeMutableRawPointer?
    private typealias OpenFn = @convention(c) (UnsafeMutableRawPointer) -> Int32
    private typealias ActuateFn = @convention(c) (UnsafeMutableRawPointer, Int32, UInt32, Float, Float) -> Int32
    private typealias CloseFn = @convention(c) (UnsafeMutableRawPointer) -> Int32

    private var deviceID: UInt64?
    private var createFn: CreateFn?
    private var openFn: OpenFn?
    private var actuateFn: ActuateFn?
    private var closeFn: CloseFn?
    private var actuator: UnsafeMutableRawPointer?

    private init() {
        guard let handle = dlopen(
            "/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport",
            RTLD_NOW
        ),
        let create = dlsym(handle, "MTActuatorCreateFromDeviceID"),
        let open = dlsym(handle, "MTActuatorOpen"),
        let actuate = dlsym(handle, "MTActuatorActuate"),
        let close = dlsym(handle, "MTActuatorClose"),
        let id = Self.builtInTrackpadID()
        else {
            Log.info("Haptics", "马达直连不可用，回落系统接口")
            return
        }

        deviceID = id
        createFn = unsafeBitCast(create, to: CreateFn.self)
        openFn = unsafeBitCast(open, to: OpenFn.self)
        actuateFn = unsafeBitCast(actuate, to: ActuateFn.self)
        closeFn = unsafeBitCast(close, to: CloseFn.self)

        if !ensureOpen() {
            Log.info("Haptics", "马达打开失败，回落系统接口")
            return
        }
        Log.info("Haptics", "马达直连就绪 id=0x\(String(id, radix: 16))")
    }

    deinit {
        if let actuator { closeFn?(actuator) }
    }

    /// 敲一下。actuationID：3 轻、4 中、6 重（HapticKey 同款波形编号）。
    func actuate(id: Int32) -> Bool {
        guard ensureOpen(), let actuator, let actuateFn else { return false }
        if actuateFn(actuator, id, 0, 0, 2.0) == KERN_SUCCESS { return true }

        // 睡眠唤醒后旧句柄会失效：关掉重开，再给它一次机会。
        closeFn?(actuator)
        self.actuator = nil
        guard ensureOpen(), let retry = self.actuator else { return false }
        return actuateFn(retry, id, 0, 0, 2.0) == KERN_SUCCESS
    }

    private func ensureOpen() -> Bool {
        if actuator != nil { return true }
        guard let deviceID, let createFn else { return false }
        guard let fresh = createFn(deviceID) else { return false }
        guard openFn?(fresh) == KERN_SUCCESS else {
            closeFn?(fresh)
            return false
        }
        actuator = fresh
        return true
    }

    /// 只取内建触控板（外接 Magic Trackpad 的 ID 不同，取第一个可驱动的内建设备）。
    private static func builtInTrackpadID() -> UInt64? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault,
                                           IOServiceMatching("AppleMultitouchDevice"),
                                           &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }

        while true {
            let service = IOIteratorNext(iterator)
            guard service != 0 else { break }
            defer { IOObjectRelease(service) }

            var properties: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(service, &properties,
                                                    kCFAllocatorDefault, 0) == KERN_SUCCESS,
                  let dictionary = properties?.takeRetainedValue() as NSDictionary? else { continue }

            let supported = (dictionary["ActuationSupported"] as? NSNumber)?.boolValue ?? false
            let builtIn = (dictionary["MT Built-In"] as? NSNumber)?.boolValue ?? false
            guard supported, builtIn,
                  let id = dictionary["Multitouch ID"] as? NSNumber else { continue }
            return id.uint64Value
        }
        return nil
    }
}
