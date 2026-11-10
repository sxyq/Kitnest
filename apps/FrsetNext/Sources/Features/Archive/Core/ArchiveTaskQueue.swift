import AppKit
import Combine
import Foundation

// MARK: - 归档任务队列（v127（ArcZip P2）：进度与任务）
//
// 对应 ArcZip「进度与任务」8 条目的核心能力：
//   · 任务队列：多任务排队（串行，默认并发 1——同一归档的写操作绝不能并发），单个可取消
//   · 取消传播：cancel(taskID) → Process.terminate()，把 7zz 子进程杀掉（不留半截归档）
//   · 任务阶段：waiting（准备/排队）/ running（核对、压缩、解压…）/ done / failed / cancelled
//   · 进度值：7zz `-bsp1` 向 stdout 打 `NN%`，ArchiveCore 逐块解析后回调；
//     解析不到就保持 progress = -1 → 面板走 indeterminate 转圈（不确定进度兜底）
//
// 线程模型：所有 @Published 状态只在主线程改；7zz 子进程跑在全局队列；
//           cancelFlags 用锁保护，供后台线程安全查询（避免 main.sync 死锁）。

public final class ArchiveTaskQueue: ObservableObject {

    public static let shared = ArchiveTaskQueue()

    // MARK: 任务模型

    public enum Kind: String, CaseIterable {
        case extract, compress, add, remove, rename, encrypt

        /// 面板行图标
        public var icon: String {
            switch self {
            case .extract: return "arrow.down.circle"
            case .compress: return "archivebox"
            case .add: return "plus.square.on.square"
            case .remove: return "trash"
            case .rename: return "pencil"
            case .encrypt: return "lock"
            }
        }

        public var label: String {
            switch self {
            case .extract: return "解压"
            case .compress: return "压缩"
            case .add: return "添加"
            case .remove: return "删除"
            case .rename: return "重命名"
            case .encrypt: return "加密另存"
            }
        }
    }

    public enum State: String {
        case waiting, running, done, failed, cancelled

        public var icon: String {
            switch self {
            case .waiting: return "clock"
            case .running: return "arrow.triangle.2.circlepath"
            case .done: return "checkmark.circle.fill"
            case .failed: return "xmark.octagon.fill"
            case .cancelled: return "slash.circle"
            }
        }
    }

    public struct ArchiveTask: Identifiable, Equatable {
        public let id: UUID
        public let kind: Kind
        public let title: String
        public var state: State
        /// 0…1；-1 = 不确定进度（7zz 没输出百分比 → 面板显示 indeterminate）
        public var progress: Double
        /// 阶段/结果说明（排队中 / 核对路径… / 解压中… / 已跳过 N 个不安全路径…）
        public var message: String
        /// v181：产物位置（压缩包路径 / 解压目标目录）。完成后任务行给「在访达中显示」，
        /// 解决「压完了东西在哪」——原来任务窗只有一句「完成」，用户还得自己去找。
        public var outputURL: URL?

        public var isFinished: Bool {
            state == .done || state == .failed || state == .cancelled
        }
    }

    public typealias Done = (Bool, String) -> Void
    /// 入队体：拿到 taskID 干活，结束必须调 done（ok, message）——且只能调一次
    /// v127.2：Done 参数标 @escaping——work 体内会把它捕获进 runIn/extract 的
    /// 异步 completion（@escaping），不标会导致「escaping closure captures
    /// non-escaping parameter 'done'」编译错误。语义上正确：队列传进来的
    /// finish 闭包本就是被异步回调使用的逃逸闭包。
    public typealias Work = (UUID, @escaping Done) -> Void

    @Published public private(set) var tasks: [ArchiveTask] = []

    /// 同时运行上限（默认 1 = 串行）
    public var maxConcurrent = 1

    // MARK: 私有状态（除 cancelFlags 外只在主线程碰）

    private var pending: [(id: UUID, work: Work, onCancel: (() -> Void)?)] = []
    private var runningIDs: Set<UUID> = []
    private var processes: [UUID: Process] = [:]
    private let cancelLock = NSLock()
    private var cancelFlags: Set<UUID> = []

    private init() {}

    // MARK: 入队 / 完成

    /// 排队一个任务，立刻返回 taskID（可拿去 cancel）
    /// - Parameter output: 产物位置（压缩包 / 解压目录），任务窗据此提供「在访达中显示」
    @discardableResult
    public func enqueue(kind: Kind, title: String, output: URL? = nil,
                        onCancel: (() -> Void)? = nil,
                        work: @escaping Work) -> UUID {
        let id = UUID()
        onMain {
            self.tasks.append(ArchiveTask(id: id, kind: kind, title: title,
                                          state: .waiting, progress: -1, message: "排队中",
                                          outputURL: output))
            self.pending.append((id, work, onCancel))
            self.pump()
        }
        return id
    }

    /// 任务收尾（幂等：重复调用会被忽略，防止 work 误调两次 done）
    public func finish(taskID: UUID, ok: Bool, message: String) {
        onMain {
            guard self.runningIDs.contains(taskID) else { return }
            self.processes[taskID] = nil
            self.runningIDs.remove(taskID)
            let wasCancel = self.takeCancelFlag(taskID)
            self.mutate(taskID) { t in
                if wasCancel && !ok {
                    // 取消传播生效：进程被 terminate()，统一记「已取消」而不是失败
                    t.state = .cancelled
                    t.message = message.isEmpty ? "已取消" : "已取消（\(message)）"
                } else {
                    t.state = ok ? .done : .failed
                    t.message = message
                    if ok { t.progress = 1 }
                }
            }
            self.pump()
        }
    }

    // MARK: 取消（取消传播入口）

    public func cancel(taskID: UUID) {
        onMain {
            // 还在排队：直接出队
            if let idx = self.pending.firstIndex(where: { $0.id == taskID }) {
                let item = self.pending.remove(at: idx)
                _ = self.takeCancelFlag(taskID)
                self.mutate(taskID) { t in
                    t.state = .cancelled
                    t.message = "已取消"
                }
                item.onCancel?()
                return
            }
            guard self.runningIDs.contains(taskID) else { return }
            self.setCancelFlag(taskID)
            self.mutate(taskID) { t in t.message = "正在取消…" }
            // 取消传播：杀掉 7zz 子进程；若还没注册 Process（仍在准备阶段），
            // registerProcess 会看到取消标记并立刻 terminate。
            self.processes[taskID]?.terminate()
        }
    }

    public func cancelAll() {
        onMain {
            let ids = self.pending.map { $0.id } + Array(self.runningIDs)
            for id in ids { self.cancel(taskID: id) }
        }
    }

    /// 后台线程可安全调用：任务是否已请求取消（各阶段之间的检查点）
    public func isCancelled(_ taskID: UUID?) -> Bool {
        guard let taskID else { return false }
        cancelLock.lock(); defer { cancelLock.unlock() }
        return cancelFlags.contains(taskID)
    }

    // MARK: Process 注册（取消传播的落点）

    /// 7zz 起来后注册，cancel(taskID) 就能 terminate 它
    public func registerProcess(_ process: Process, for taskID: UUID?) {
        guard let taskID else { return }
        onMain {
            self.processes[taskID] = process
            if self.isCancelled(taskID) { process.terminate() }
        }
    }

    public func unregisterProcess(_ process: Process, for taskID: UUID?) {
        guard let taskID else { return }
        onMain {
            if self.processes[taskID] === process { self.processes[taskID] = nil }
        }
    }

    // MARK: 进度

    /// progress < 0 表示只更新 message 不动进度
    public func updateProgress(taskID: UUID?, _ progress: Double, message: String? = nil) {
        guard let taskID else { return }
        onMain {
            self.mutate(taskID) { t in
                if progress >= 0 { t.progress = max(0, min(1, progress)) }
                if let message { t.message = message }
            }
        }
    }

    // MARK: 汇总（进度面板顶部）

    public var runningCount: Int { tasks.filter { $0.state == .running }.count }
    public var waitingCount: Int { tasks.filter { $0.state == .waiting }.count }
    public var failedCount: Int { tasks.filter { $0.state == .failed }.count }
    /// 有任务未收尾（退出/关窗保护的判据）
    public var hasActiveTasks: Bool { tasks.contains { !$0.isFinished } }
    public var summaryText: String {
        "运行中 \(runningCount) · 等待 \(waitingCount) · 失败 \(failedCount)"
    }

    public func clearFinished() {
        onMain { self.tasks.removeAll { $0.isFinished } }
    }

    // MARK: 退出保护（接 NSApplicationDelegate.applicationShouldTerminate / windowShouldClose）

    /// 无进行中任务直接放行；有则弹确认。返回 true = 可以继续退出/关窗。
    /// 主代理接线：applicationShouldTerminate 里 `guard ArchiveTaskQueue.shared.confirmQuitIfNeeded()
    /// else { return .terminateCancel }`。
    public func confirmQuitIfNeeded() -> Bool {
        guard hasActiveTasks else { return true }
        let n = tasks.filter { !$0.isFinished }.count
        let alert = NSAlert()
        alert.messageText = "还有 \(n) 个归档任务未完成"
        alert.informativeText = "退出会终止正在运行的 7zz 子进程，未完成的任务将被取消。"
        alert.addButton(withTitle: "仍要退出")
        alert.addButton(withTitle: "返回")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            cancelAll()
            return true
        }
        return false
    }

    // MARK: 私有

    /// 串行泵：有空位就把 pending 头部任务推上全局队列跑
    private func pump() {
        while runningIDs.count < maxConcurrent, !pending.isEmpty {
            let item = pending.removeFirst()
            runningIDs.insert(item.id)
            mutate(item.id) { t in
                t.state = .running
                t.message = "准备中…"
            }
            let id = item.id
            let work = item.work
            DispatchQueue.global(qos: .userInitiated).async {
                work(id) { ok, message in
                    ArchiveTaskQueue.shared.finish(taskID: id, ok: ok, message: message)
                }
            }
        }
    }

    private func mutate(_ id: UUID, _ change: (inout ArchiveTask) -> Void) {
        guard let idx = tasks.firstIndex(where: { $0.id == id }) else { return }
        change(&tasks[idx])
    }

    private func onMain(_ block: @escaping () -> Void) {
        if Thread.isMainThread { block() } else { DispatchQueue.main.async(execute: block) }
    }

    private func setCancelFlag(_ id: UUID) {
        cancelLock.lock(); cancelFlags.insert(id); cancelLock.unlock()
    }

    @discardableResult
    private func takeCancelFlag(_ id: UUID) -> Bool {
        cancelLock.lock(); defer { cancelLock.unlock() }
        return cancelFlags.remove(id) != nil
    }
}
