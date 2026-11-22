import AppKit

/// 一次请求最后走到了哪一步。
///
/// **这些状态都不能证明用户真的感觉到了触觉**：私有驱动返回 `KERN_SUCCESS` 只说明调用成功，
/// 公开接口更没有返回值。能证明的只有设备在不在、请求有没有发出去。
enum HapticDelivery: String, Sendable {
    /// 私有驱动调用返回成功（手指离开触控板也应当有感）
    case privateActuated
    /// 已向公开系统接口发起请求（只在手指接触触控板时才有感）
    case publicRequested
    /// 私有与公开两条路都不可用
    case unavailable
    /// 调用过但失败（含重开一次后仍失败）
    case failed
}

/// 当前设备能力。`reason` 用于设置页如实说明，不参与业务判断。
enum HapticAvailability: Equatable {
    /// 私有马达就绪：手离开触控板也能响
    case ready
    /// 只有公开接口：手指必须贴着触控板才可能有感（无内建板 / 私有框架不可用）
    case publicOnly(PrivateUnavailableReason)
    /// 连公开接口都用不了
    case unavailable
    /// 还没准备完
    case unknown

    var canRequest: Bool {
        switch self {
        case .ready, .publicOnly: return true
        case .unavailable, .unknown: return false
        }
    }
}

enum PrivateUnavailableReason: Equatable {
    /// 没有支持振动的触控板（Mac mini、无 Force Touch 的机型、外接键盘场景）
    case noDevice
    /// 私有框架或符号不可用（系统改动 / 未来版本移除）
    case frameworkUnavailable
    /// 设备在，但打开句柄失败
    case openFailed(Int32)
    /// 还没探测
    case notPrepared

    var text: String {
        switch self {
        case .noDevice: return "未发现支持振动的触控板"
        case .frameworkUnavailable: return "系统不再提供马达私有接口"
        case .openFailed(let code): return "触控板马达打开失败（\(code)）"
        case .notPrepared: return "正在检测触觉设备"
        }
    }
}

/// 一次「敲击」。强度 → 既有波形编号（3/4/6）与公开 pattern 的映射只在这里发生。
struct HapticPulse {
    let intensity: HapticIntensity

    var actuationID: Int32? { intensity.actuationID }
    var pattern: NSHapticFeedbackManager.FeedbackPattern? { intensity.pattern }
}

/// 最小驱动抽象：只回答「能不能用」「敲一下」。不做注册中心、不做插件体系。
protocol HapticDriving: AnyObject {
    var availability: HapticAvailability { get }
    func prepare(then: (() -> Void)?)
    func fire(_ pulse: HapticPulse) -> HapticDelivery
    func invalidate()
}

/// 私有马达驱动：手离开触控板也有效。
final class PrivateHapticDriver: HapticDriving {
    private let actuator = TrackpadActuator.shared

    var availability: HapticAvailability {
        switch actuator.currentState {
        case .ready:
            return .ready
        case .noDevice:
            return .publicOnly(.noDevice)
        case .frameworkUnavailable:
            return .publicOnly(.frameworkUnavailable)
        case .openFailed(let code):
            return .publicOnly(.openFailed(code))
        case .unprepared:
            return .publicOnly(.notPrepared)
        }
    }

    func prepare(then: (() -> Void)? = nil) { actuator.prepare(then: then) }
    func invalidate() { actuator.invalidate() }

    func fire(_ pulse: HapticPulse) -> HapticDelivery {
        guard let id = pulse.actuationID else { return .unavailable }
        return actuator.actuate(id: id) ? .privateActuated : .failed
    }
}

/// 公开接口驱动：`NSHapticFeedbackManager`，AppKit 要求在主线程调用。
/// 它没有返回值，所以这里只能如实返回「已请求」，不能声称已产生触感。
final class PublicHapticDriver: HapticDriving {
    var availability: HapticAvailability { .publicOnly(.notPrepared) }

    func prepare(then: (() -> Void)?) { then?() }

    func invalidate() {}

    func fire(_ pulse: HapticPulse) -> HapticDelivery {
        guard let pattern = pulse.pattern else { return .unavailable }
        let perform = {
            NSHapticFeedbackManager.defaultPerformer.perform(pattern, performanceTime: .now)
        }
        if Thread.isMainThread { perform() } else { DispatchQueue.main.async(execute: perform) }
        return .publicRequested
    }
}

/// 选择与回落：私有优先，失败即回落到公开接口，只回落一次。
final class HapticDriverRouter {
    private let privateDriver = PrivateHapticDriver()
    private let publicDriver = PublicHapticDriver()

    var availability: HapticAvailability { privateDriver.availability }

    func prepare(then: (() -> Void)? = nil) { privateDriver.prepare(then: then) }

    func invalidate() {
        privateDriver.invalidate()
    }

    func deliver(_ pulse: HapticPulse) -> HapticDelivery {
        if case .ready = privateDriver.availability {
            let result = privateDriver.fire(pulse)
            if result == .privateActuated { return result }
        }
        return publicDriver.fire(pulse)
    }
}
