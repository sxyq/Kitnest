import Combine
import Foundation

// MARK: - Agent 用量监控（v130（AndroMeld/AgentHUD）：Agent HUD 核心接入 B1）
//
// 思路与 Agent HUD 一致：**读 agent 自己在本机留的记录**，不抓网络、不需要插件。
//   · Claude Code：~/.claude/projects/*/*.jsonl 的 assistant 消息 usage + cost-state 汇总
//   · Codex：~/.codex/sessions/**/rollout-*.jsonl 的 token_count（会话累计）
// 两家格式差异大，抽象 AgentUsageSource 协议，后续 Cursor/Gemini 等按同协议扩展。
//
// 性能约束（菜单栏常驻）：扫描全部放后台队列；每个源只扫「最近 N 天内修改过」的文件，
// 且单文件读取带上限（超大 rollout 只读尾部 2MB——token_count 是累计值，取最后一条即可）。

/// 一家 agent 的用量数据源（通用接口：拿不准的 agent 先空实现占位）
public protocol AgentUsageSource {
    var agent: AgentUsage.Agent { get }
    /// 是否已安装（目录存在）
    var isInstalled: Bool { get }
    /// 抓取用量（后台线程调用，回调回主线程）
    func fetchUsage(since: Date, completion: @escaping ([AgentUsage]) -> Void)
    /// 最近会话（后台线程调用，回调回主线程）
    func fetchRecentSessions(limit: Int, completion: @escaping ([AgentSessionEntry]) -> Void)
    /// 额度快照（拿不到返回 nil）
    func fetchQuota(completion: @escaping (AgentQuotaStatus?) -> Void)
}

// MARK: - Claude Code（~/.claude/）

public struct ClaudeUsageSource: AgentUsageSource {
    public let agent = AgentUsage.Agent.claude

    public var isInstalled: Bool {
        FileManager.default.fileExists(atPath: NSHomeDirectory() + "/.claude")
    }

    public func fetchUsage(since: Date, completion: @escaping ([AgentUsage]) -> Void) {
        let fm = FileManager.default
        let projectsRoot = NSHomeDirectory() + "/.claude/projects"
        guard let enumerator = fm.enumerator(atPath: projectsRoot) else {
            DispatchQueue.main.async { completion([]) }; return
        }
        var files: [(String, Date)] = []
        while let rel = enumerator.nextObject() as? String {
            guard rel.hasSuffix(".jsonl") else { continue }
            let path = projectsRoot + "/" + rel
            guard let attrs = try? fm.attributesOfItem(atPath: path),
                  let mdate = attrs[.modificationDate] as? Date, mdate >= since else { continue }
            files.append((path, mdate))
        }
        // 只处理最近 400 个会话文件（更旧的对「近期用量」无意义）
        files.sort { $0.1 > $1.1 }

        // (model) -> 聚合；usage 逐条累加，cost 取 cost-state 的 totalCostUSD（每文件一条）
        var agg: [String: AgentUsage] = [:]
        for (path, mdate) in files.prefix(400) {
            autoreleasepool {
                guard let data = FileManager.default.contents(atPath: path) else { return }
                var fileCost: Double = 0
                var modelsInFile = Set<String>()
                // 逐行解析（JSONL）；assistant 消息带 message.usage
                var offset = 0
                while offset < data.count {
                    let chunk = data[offset...]
                    guard let nl = chunk.firstIndex(of: UInt8(ascii: "\n")) else { break }
                    let lineData = data[offset..<nl]
                    offset = nl + 1
                    guard let obj = try? JSONSerialization.jsonObject(with: Data(lineData)) as? [String: Any] else { continue }
                    if obj["type"] as? String == "cost-state",
                       let cost = obj["totalCostUSD"] as? Double {
                        fileCost = max(fileCost, cost)   // 汇总行，取末值
                        continue
                    }
                    guard obj["type"] as? String == "assistant",
                          let msg = obj["message"] as? [String: Any],
                          let usage = msg["usage"] as? [String: Any] else { continue }
                    let model = (msg["model"] as? String) ?? ""
                    let tin = (usage["input_tokens"] as? Int) ?? 0
                    let cacheCreate = (usage["cache_creation_input_tokens"] as? Int) ?? 0
                    let cacheRead = (usage["cache_read_input_tokens"] as? Int) ?? 0
                    let tout = (usage["output_tokens"] as? Int) ?? 0
                    guard tin + tout + cacheCreate + cacheRead > 0 else { continue }
                    modelsInFile.insert(model)
                    var u = agg[model] ?? AgentUsage(agent: .claude, model: model)
                    u.tokensIn += tin + cacheCreate + cacheRead
                    u.tokensOut += tout
                    u.sessionCount = 0    // 文件计数最后统一加
                    u.lastActive = max(u.lastActive ?? .distantPast, mdate)
                    agg[model] = u
                }
                // 会话数按文件计（一个文件 = 一个会话）；cost 是文件级，挂到该文件主模型上
                if let primary = modelsInFile.first {
                    var u = agg[primary]!
                    u.sessionCount += 1
                    u.cost += fileCost
                    agg[primary] = u
                }
            }
        }
        let list = Array(agg.values).sorted { $0.totalTokens > $1.totalTokens }
        DispatchQueue.main.async { completion(list) }
    }

    public func fetchRecentSessions(limit: Int, completion: @escaping ([AgentSessionEntry]) -> Void) {
        // history.jsonl：{display, timestamp, project, sessionId}
        let path = NSHomeDirectory() + "/.claude/history.jsonl"
        guard let data = FileManager.default.contents(atPath: path) else {
            DispatchQueue.main.async { completion([]) }; return
        }
        var entries: [AgentSessionEntry] = []
        var seen = Set<String>()
        let fmt = ISO8601DateFormatter()
        for line in data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true).suffix(500) {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { continue }
            let sid = (obj["sessionId"] as? String) ?? UUID().uuidString
            guard !seen.contains(sid), let display = obj["display"] as? String, !display.isEmpty else { continue }
            seen.insert(sid)
            let ts = (obj["timestamp"] as? String).flatMap { fmt.date(from: $0) } ?? Date()
            entries.append(AgentSessionEntry(id: "claude-" + sid,
                                             agent: .claude,
                                             title: String(display.prefix(60)),
                                             date: ts))
        }
        let sorted = entries.sorted { $0.date > $1.date }.prefix(limit)
        DispatchQueue.main.async { completion(Array(sorted)) }
    }

    public func fetchQuota(completion: @escaping (AgentQuotaStatus?) -> Void) {
        // Claude 本地记录无官方额度字段 → 按「日预算」折算（见 AgentHUDPreferences）
        fetchUsage(since: Calendar.current.startOfDay(for: Date())) { usages in
            let today = usages.reduce(0) { $0 + $1.totalTokens }
            let budget = AgentHUDPreferences.dailyTokenBudget
            let pct = min(100, Double(today) / Double(budget) * 100)
            // 「撑不到重置」：今日剩余小时数外推会超过预算
            let hoursElapsed = max(1, Date().timeIntervalSince(Calendar.current.startOfDay(for: Date())) / 3600)
            let projected = Double(today) / hoursElapsed * 24
            completion(AgentQuotaStatus(agent: .claude,
                                        usedPercent: pct,
                                        resetAt: Calendar.current.date(byAdding: .day, value: 1,
                                                                        to: Calendar.current.startOfDay(for: Date())),
                                        source: "日预算",
                                        projectedExhaustionBeforeReset: projected > Double(budget)))
        }
    }
}

// MARK: - Codex（~/.codex/）

public struct CodexUsageSource: AgentUsageSource {
    public let agent = AgentUsage.Agent.codex

    /// 单文件最大读取字节（超大 rollout 只读尾部——token_count 是累计值）
    private static let maxReadBytes = 2 * 1024 * 1024

    public var isInstalled: Bool {
        FileManager.default.fileExists(atPath: NSHomeDirectory() + "/.codex")
    }

    public func fetchUsage(since: Date, completion: @escaping ([AgentUsage]) -> Void) {
        let fm = FileManager.default
        let root = NSHomeDirectory() + "/.codex/sessions"
        guard let enumerator = fm.enumerator(atPath: root) else {
            DispatchQueue.main.async { completion([]) }; return
        }
        var files: [(String, Date)] = []
        while let rel = enumerator.nextObject() as? String {
            guard rel.hasSuffix(".jsonl") else { continue }
            let path = root + "/" + rel
            guard let attrs = try? fm.attributesOfItem(atPath: path),
                  let mdate = attrs[.modificationDate] as? Date, mdate >= since else { continue }
            files.append((path, mdate))
        }
        files.sort { $0.1 > $1.1 }

        var agg: [String: AgentUsage] = [:]
        for (path, mdate) in files.prefix(400) {
            autoreleasepool {
                guard let raw = Self.readTail(path: path, maxBytes: Self.maxReadBytes) else { return }
                // 取**最后一条** token_count（会话累计）与 thread_settings 的模型名
                var lastUsage: [String: Int]?
                var model = ""
                for line in raw.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true) {
                    guard let obj = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                          let payload = obj["payload"] as? [String: Any] else { continue }
                    switch payload["type"] as? String {
                    case "token_count":
                        if let info = payload["info"] as? [String: Any],
                           let total = info["total_token_usage"] as? [String: Any] {
                            lastUsage = [
                                "in": (total["input_tokens"] as? Int) ?? 0,
                                "cached": (total["cached_input_tokens"] as? Int) ?? 0,
                                "cacheWrite": (total["cache_write_input_tokens"] as? Int) ?? 0,
                                "out": (total["output_tokens"] as? Int) ?? 0,
                                "reasoning": (total["reasoning_output_tokens"] as? Int) ?? 0,
                            ]
                        }
                    case "thread_settings_applied":
                        if let settings = payload["thread_settings"] as? [String: Any],
                           let m = settings["model"] as? String, !m.isEmpty {
                            model = m
                        }
                    default:
                        break
                    }
                }
                guard let u = lastUsage else { return }
                let key = model.isEmpty ? "" : model
                var aggU = agg[key] ?? AgentUsage(agent: .codex, model: key)
                aggU.tokensIn += (u["in"] ?? 0) + (u["cached"] ?? 0) + (u["cacheWrite"] ?? 0)
                aggU.tokensOut += (u["out"] ?? 0) + (u["reasoning"] ?? 0)
                aggU.sessionCount += 1
                aggU.lastActive = max(aggU.lastActive ?? .distantPast, mdate)
                agg[key] = aggU
            }
        }
        let list = Array(agg.values).sorted { $0.totalTokens > $1.totalTokens }
        DispatchQueue.main.async { completion(list) }
    }

    public func fetchRecentSessions(limit: Int, completion: @escaping ([AgentSessionEntry]) -> Void) {
        // session_index.jsonl：{id, thread_name, updated_at}
        let path = NSHomeDirectory() + "/.codex/session_index.jsonl"
        guard let data = FileManager.default.contents(atPath: path) else {
            DispatchQueue.main.async { completion([]) }; return
        }
        var entries: [AgentSessionEntry] = []
        let fmt = ISO8601DateFormatter()
        for line in data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true).suffix(500) {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let id = obj["id"] as? String,
                  let name = obj["thread_name"] as? String else { continue }
            let ts = (obj["updated_at"] as? String).flatMap { fmt.date(from: $0) } ?? Date()
            entries.append(AgentSessionEntry(id: "codex-" + id,
                                             agent: .codex,
                                             title: String(name.prefix(60)),
                                             date: ts))
        }
        let sorted = entries.sorted { $0.date > $1.date }.prefix(limit)
        DispatchQueue.main.async { completion(Array(sorted)) }
    }

    public func fetchQuota(completion: @escaping (AgentQuotaStatus?) -> Void) {
        // Codex rate_limits：primary/secondary 结构含 used_percent 之类字段（本机多为 null）。
        // 非空时优先用官方额度；否则回落日预算。
        DispatchQueue.global(qos: .utility).async {
            let root = NSHomeDirectory() + "/.codex/sessions"
            let fm = FileManager.default
            var newest: (String, Date)?
            if let en = fm.enumerator(atPath: root) {
                while let rel = en.nextObject() as? String {
                    guard rel.hasSuffix(".jsonl") else { continue }
                    let path = root + "/" + rel
                    guard let attrs = try? fm.attributesOfItem(atPath: path),
                          let mdate = attrs[.modificationDate] as? Date else { continue }
                    if newest == nil || mdate > newest!.1 { newest = (path, mdate) }
                }
            }
            var usedPercent: Double?
            var resetAt: Date?
            if let (path, _) = newest, let raw = Self.readTail(path: path, maxBytes: Self.maxReadBytes) {
                for line in raw.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true) {
                    guard let obj = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                          let payload = obj["payload"] as? [String: Any],
                          payload["type"] as? String == "token_count",
                          let rl = payload["rate_limits"] as? [String: Any] else { continue }
                    // primary/secondary 可能是 {used_percent, resets_in_seconds, ...} 形态
                    for key in ["primary", "secondary"] {
                        if let block = rl[key] as? [String: Any] {
                            for pk in ["used_percent", "utilization", "percent"] {
                                if let v = block[pk] as? Double { usedPercent = max(usedPercent ?? 0, v) }
                                if let v = block[pk] as? Int { usedPercent = max(usedPercent ?? 0, Double(v)) }
                            }
                            for rk in ["resets_in_seconds", "reset_after_seconds"] {
                                if let s = block[rk] as? Double { resetAt = Date().addingTimeInterval(s) }
                                if let s = block[rk] as? Int { resetAt = Date().addingTimeInterval(Double(s)) }
                            }
                        }
                    }
                }
            }
            if let pct = usedPercent {
                let status = AgentQuotaStatus(agent: .codex,
                                              usedPercent: min(100, pct),
                                              resetAt: resetAt,
                                              source: "rate_limits",
                                              projectedExhaustionBeforeReset: false)
                DispatchQueue.main.async { completion(status) }
                return
            }
            // 回落：日预算折算（只算 Codex 今日量；扫描放后台队列，避免主线程读文件）
            DispatchQueue.global(qos: .utility).async {
                CodexUsageSource().fetchUsage(since: Calendar.current.startOfDay(for: Date())) { usages in
                    let today = usages.reduce(0) { $0 + $1.totalTokens }
                    let budget = AgentHUDPreferences.dailyTokenBudget
                    let pct = min(100, Double(today) / Double(budget) * 100)
                    let hoursElapsed = max(1, Date().timeIntervalSince(Calendar.current.startOfDay(for: Date())) / 3600)
                    let projected = Double(today) / hoursElapsed * 24
                    completion(AgentQuotaStatus(agent: .codex,
                                                usedPercent: pct,
                                                resetAt: Calendar.current.date(byAdding: .day, value: 1,
                                                                                to: Calendar.current.startOfDay(for: Date())),
                                                source: "日预算",
                                                projectedExhaustionBeforeReset: projected > Double(budget)))
                }
            }
        }
    }

    /// 读文件尾部（大 rollout 不能整读；token_count 取最后一条即可）
    private static func readTail(path: String, maxBytes: Int) -> [UInt8]? {
        guard let fh = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? fh.close() }
        let size = (try? fh.seekToEnd()) ?? 0
        let start = size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0
        try? fh.seek(toOffset: start)
        guard let data = try? fh.readToEnd() else { return nil }
        return [UInt8](data)
    }
}

// MARK: - 监控总控（B1 聚合 + B2 告警）

/// Agent 用量监控总控：周期抓取两家用量、聚合、驱动告警与状态栏徽标。
/// UI 层（AgentHUDView）与状态层（AgentHUDModule）都只依赖本类。
public final class AgentUsageMonitor: ObservableObject {
    public static let shared = AgentUsageMonitor()

    @Published public private(set) var usages: [AgentUsage] = []
    @Published public private(set) var sessions: [AgentSessionEntry] = []
    @Published public private(set) var quotas: [AgentQuotaStatus] = []
    @Published public private(set) var lastRefresh: Date?
    @Published public private(set) var isRefreshing = false
    /// B2：当前告警级别（0=正常，1=达阈值，2=撑不到重置）；状态栏徽标据此着色
    @Published public private(set) var alertLevel = 0

    public var sources: [AgentUsageSource] {
        // 拿不准的 agent（Cursor 等）后续按同协议追加；先只挂已探明的两家
        [ClaudeUsageSource(), CodexUsageSource()]
    }

    private var timer: Timer?
    /// 已提示过的告警级别（避免每次刷新重复 Toast）
    private var lastToastedLevel = 0

    private init() {}

    /// 启动周期刷新（默认 5 分钟；后台抓取不卡主线程）
    public func start(interval: TimeInterval = 300) {
        guard timer == nil else { return }
        refresh()
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            autoreleasepool { self?.refresh() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// 手动/周期刷新（幂等；并发调用合并）
    public func refresh() {
        guard !isRefreshing else { return }
        isRefreshing = true
        let group = DispatchGroup()
        var allUsage: [AgentUsage] = []
        var allSessions: [AgentSessionEntry] = []
        var allQuotas: [AgentQuotaStatus] = []
        let since = Date().addingTimeInterval(-30 * 24 * 3600)   // 近 30 天

        let queue = DispatchQueue(label: "frset.agenthud.refresh", qos: .utility)
        for src in sources where src.isInstalled {
            group.enter()
            queue.async {
                src.fetchUsage(since: since) { list in
                    allUsage.append(contentsOf: list); group.leave()
                }
            }
            group.enter()
            queue.async {
                src.fetchRecentSessions(limit: 8) { list in
                    allSessions.append(contentsOf: list); group.leave()
                }
            }
            group.enter()
            queue.async {
                src.fetchQuota { q in
                    if let q { allQuotas.append(q) }; group.leave()
                }
            }
        }
        group.notify(queue: .main) { [weak self] in
            guard let self else { return }
            self.usages = allUsage.sorted { $0.totalTokens > $1.totalTokens }
            self.sessions = allSessions.sorted { $0.date > $1.date }
            self.quotas = allQuotas
            self.lastRefresh = Date()
            self.isRefreshing = false
            self.evaluateAlerts()
        }
    }

    // MARK: B2 额度告警

    /// 阈值 / 「撑不到重置」→ Toast + 状态栏徽标（AgentHUDModule 读 alertLevel 渲染）
    private func evaluateAlerts() {
        guard AgentHUDPreferences.alertEnabled else {
            alertLevel = 0
            lastToastedLevel = 0
            return
        }
        let threshold = Double(AgentHUDPreferences.alertThreshold)
        let maxPct = quotas.map(\.usedPercent).max() ?? 0
        let willExhaust = quotas.contains { $0.projectedExhaustionBeforeReset }
        let level = willExhaust ? 2 : (maxPct >= threshold ? 1 : 0)
        alertLevel = level
        guard level > 0, level > lastToastedLevel else {
            if level == 0 { lastToastedLevel = 0 }
            return
        }
        lastToastedLevel = level
        if level == 2 {
            Toast.show("Agent 额度告警：按当前速率撑不到重置（已用 \(Int(maxPct))%）",
                       icon: "exclamationmark.triangle.fill", isWarning: true)
        } else {
            Toast.show("Agent 用量已达 \(AgentHUDPreferences.alertThreshold)%（\(Int(maxPct))%）",
                       icon: "gauge.with.dots.needle.67percent", isWarning: true)
        }
    }
}
