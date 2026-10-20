import Combine
import Foundation

// ============================================================================
// 内存优化：采样前 → root helper（压力广播 + purge）→ 采样后 → 诚实报告
// ============================================================================

public enum MemoryOptimizationStep: String, Sendable {
    case pressure
    case purge

    static func parse(_ payload: String) -> Set<MemoryOptimizationStep> {
        Set(payload.split(separator: " ").compactMap { MemoryOptimizationStep(rawValue: String($0)) })
    }

    public var title: String {
        switch self {
        case .pressure: return "内存压力广播"
        case .purge: return "文件缓存清理"
        }
    }
}

public struct AppMemoryRelease: Sendable, Equatable {
    public let name: String
    public let bytes: UInt64
}

public struct MemoryOptimizationReport: Sendable {
    /// 小于 32MB 的变化与正常分配器抖动无法区分，不当作“释放成功”
    public static let noticeableChange: UInt64 = 32 * 1_048_576

    public let before: MemoryBreakdown
    public let after: MemoryBreakdown
    public let steps: Set<MemoryOptimizationStep>
    public let releases: [AppMemoryRelease]

    public var usedDelta: Int64 { delta(\.used) }
    public var appDelta: Int64 { delta(\.app) }
    public var compressedDelta: Int64 { delta(\.compressed) }
    public var cachedDelta: Int64 { delta(\.cached) }
    public var swapDelta: Int64 { delta(\.swapUsed) }

    public func isNoticeable(_ value: Int64) -> Bool {
        value < 0 && value.magnitude >= Self.noticeableChange
    }

    /// 是否有任何一项达到“可感知释放”
    public var hasNoticeableRelease: Bool {
        isNoticeable(usedDelta) || isNoticeable(cachedDelta) || isNoticeable(appDelta) || isNoticeable(compressedDelta)
    }

    static func releases(before: [AppMemoryUsage], after: [AppMemoryUsage]) -> [AppMemoryRelease] {
        let previous = Dictionary(before.map { ($0.id, $0.footprint) }, uniquingKeysWith: { first, _ in first })
        return after.compactMap { usage -> AppMemoryRelease? in
            guard let earlier = previous[usage.id], earlier > usage.footprint else { return nil }
            let released = earlier - usage.footprint
            guard released >= noticeableChange else { return nil }
            return AppMemoryRelease(name: usage.name, bytes: released)
        }
        .sorted { $0.bytes > $1.bytes }
    }

    private func delta(_ keyPath: KeyPath<MemoryBreakdown, UInt64>) -> Int64 {
        Int64(clamping: after[keyPath: keyPath]) - Int64(clamping: before[keyPath: keyPath])
    }
}

@MainActor
public final class MemoryOptimizer: ObservableObject {
    public static let shared = MemoryOptimizer()

    @Published public private(set) var isOptimizing = false
    @Published public private(set) var report: MemoryOptimizationReport?
    @Published public private(set) var message: String?
    @Published public private(set) var helperInstalled: Bool = MemoryHelperClient.isInstalled

    private init() {}


    public func optimize() async {
        guard !isOptimizing else { return }
        isOptimizing = true
        report = nil
        message = nil
        defer {
            isOptimizing = false
            helperInstalled = MemoryHelperClient.isInstalled
        }

        // 先确保服务就绪（首次会弹一次管理员授权），再采基线——
        // 否则首次运行会把安装耗时算进“优化前/后”的对比里，报告失真。
        let readiness = await MemoryHelperClient.ensureReady()
        guard readiness.ready else {
            message = readiness.message
            return
        }

        // 采样前（后台线程，避免 proc_listpids 阻塞 UI）
        let before = await Task.detached(priority: .utility) {
            (MemoryBreakdownReader.read(), ProcessMemoryInspector.topConsumers(limit: 40))
        }.value

        switch await MemoryHelperClient.optimize() {
        case let .success(payload):
            // 等内核完成页统计结算
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            let after = await Task.detached(priority: .utility) {
                (MemoryBreakdownReader.read(), ProcessMemoryInspector.topConsumers(limit: 40))
            }.value
            report = MemoryOptimizationReport(
                before: before.0,
                after: after.0,
                steps: MemoryOptimizationStep.parse(payload),
                releases: MemoryOptimizationReport.releases(before: before.1, after: after.1)
            )
        case let .failure(text):
            message = text
        case .unavailable:
            message = "内存服务连接中断，请重新打开 app 后重试"
        }
    }


}
