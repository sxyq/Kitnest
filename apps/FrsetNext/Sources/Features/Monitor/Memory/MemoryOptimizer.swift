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

/// 一次「深度释放」的两个阶段，UI 据此显示不同文案
public enum MemoryOptimizationStage: Sendable, Equatable {
    case idle
    case freezing
    case purging
}

public struct MemoryOptimizationReport: Sendable {
    /// 小于 32MB 的变化与正常分配器抖动无法区分，不当作“释放成功”
    public static let noticeableChange: UInt64 = 32 * 1_048_576

    public let before: MemoryBreakdown
    public let after: MemoryBreakdown
    public let steps: Set<MemoryOptimizationStep>
    public let releases: [AppMemoryRelease]
    /// 本次被暂停的应用。注意：这是「暂停的常驻量」，不是「释放量」——
    /// 页要等系统受压才会被压缩/换出，UI 必须分开写，不能加进 released。
    public let frozen: [FrozenApp]

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
    @Published public private(set) var stage: MemoryOptimizationStage = .idle
    @Published public private(set) var report: MemoryOptimizationReport?
    @Published public private(set) var message: String?
    @Published public private(set) var helperInstalled: Bool = MemoryHelperClient.isInstalled
    /// 当前仍处于暂停状态的 App（切回、超时、手动唤醒都会实时变）
    @Published public private(set) var frozenNow: [FrozenApp] = []

    private init() {
        ProcessFreezer.shared.$frozen
            .receive(on: DispatchQueue.main)
            .assign(to: &$frozenNow)
    }


    /// 一个按钮，两段动作：
    ///   ① 暂停闲置应用（SIGSTOP）——不动文件缓存，改的是匿名页
    ///   ② 压力广播 + purge——清干净页，动不到匿名页
    /// 两段互补，所以合成一次点击；但报告必须分开写，不能把「暂停的常驻量」
    /// 当成「释放量」，否则用户点完发现空闲没涨，就再也不信这个按钮了。
    public func optimize(freezeIdle: Bool = true) async {
        guard !isOptimizing else { return }
        isOptimizing = true
        report = nil
        message = nil
        stage = .idle
        defer {
            isOptimizing = false
            stage = .idle
            helperInstalled = MemoryHelperClient.isInstalled
        }

        // 先确保服务就绪（首次会弹一次管理员授权），再采基线——
        // 否则首次运行会把安装耗时算进“优化前/后”的对比里，报告失真。
        let readiness = await MemoryHelperClient.ensureReady()
        guard readiness.ready else {
            message = readiness.message
            return
        }

        // 采样前（后台线程，避免 proc_listpids 阻塞 UI）。必须在冻结之前采，
        // 否则「优化前」已经是冻结后的状态，差值会被自己抹平。
        let before = await Task.detached(priority: .utility) {
            (MemoryBreakdownReader.read(), ProcessMemoryInspector.topConsumers(limit: 40))
        }.value

        // 第一段：暂停闲置应用。判闲置要跨 0.7 秒采两次 CPU，所以是 async。
        var frozen: [FrozenApp] = []
        if freezeIdle {
            stage = .freezing
            frozen = await ProcessFreezer.shared.freezeIdle()
        }

        // 第二段：压力广播 + purge
        stage = .purging
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
                releases: MemoryOptimizationReport.releases(before: before.1, after: after.1),
                frozen: frozen
            )
            Log.info("内存", "深度释放完成 " + summary(report!))
        case let .failure(text):
            // 缓存这步失败就把暂停也撤掉：只冻不释放，用户看到的是一个「变卡了
            // 但没报错」的状态，比整体失败更糟。
            ProcessFreezer.shared.thawAll(reason: "缓存清理失败，回滚")
            message = text
        case .unavailable:
            ProcessFreezer.shared.thawAll(reason: "服务不可用，回滚")
            message = "内存服务连接中断，请重新打开 app 后重试"
        }
    }

    /// 排障日志用：必须四个分项都打出来，只看「已用」会被压缩内存抵消掉
    private func summary(_ report: MemoryOptimizationReport) -> String {
        func mb(_ value: Int64) -> String {
            String(format: "%+.0fMB", Double(value) / 1_048_576)
        }
        let available = Int64(clamping: report.after.available) - Int64(clamping: report.before.available)
        let names = report.frozen.map(\.name).joined(separator: "、")
        return "应用 \(mb(report.appDelta)) 缓存 \(mb(report.cachedDelta)) 压缩 \(mb(report.compressedDelta))"
            + " 空闲 \(mb(available)) 暂停 \(report.frozen.count) 个[\(names)]"
    }
}
