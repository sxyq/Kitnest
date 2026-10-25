import Foundation

// MARK: - Agent 用量数据模型（v130（AndroMeld/AgentHUD）：Agent HUD 核心接入 B1）
//
// 数据源探查结论（2026-10-26 本机实测）：
//   Claude Code（~/.claude/）：
//     · projects/<项目>/<会话>.jsonl —— 逐条对话记录，assistant 消息带
//       message.model（如 "sonnet-5"）与 message.usage（input_tokens /
//       output_tokens / cache_creation_input_tokens / cache_read_input_tokens）；
//     · 每个会话文件尾部有 type=="cost-state" 汇总记录（totalCostUSD / totalDuration）；
//     · history.jsonl —— {display, timestamp, project, sessionId}，最近会话/提示列表。
//   Codex（~/.codex/）：
//     · sessions/YYYY/MM/DD/rollout-*.jsonl —— 逐条记录 {timestamp, type, payload}，
//       payload.type=="token_count" 的 info.total_token_usage 是**会话累计**：
//       {input_tokens, cached_input_tokens, cache_write_input_tokens,
//        output_tokens, reasoning_output_tokens, total_tokens}；
//       同一 payload 里 rate_limits（primary/secondary/credits/plan_type），
//       本机当前多为 null，非空时含额度用量百分比（QuotaStatus 按需解析）；
//     · thread_settings_applied 事件里 thread_settings.model（如 "gpt-6.1-sol"）；
//     · session_index.jsonl —— {id, thread_name, updated_at}，最近会话名。
//   其余 agent（~/.cursor 等）：目录存在但无稳定用量格式，走通用接口按需扩展。

/// 一家 agent 的用量聚合（对应任务书 AgentUsage 模型）
public struct AgentUsage: Identifiable, Equatable {
    public enum Agent: String, CaseIterable, Identifiable {
        case claude = "Claude Code"
        case codex = "Codex"
        public var id: String { rawValue }
        /// 数据目录（~ 下）
        var homeSubdir: String {
            switch self {
            case .claude: return ".claude"
            case .codex: return ".codex"
            }
        }
    }

    public var id: String { agent.rawValue + "|" + model }
    public let agent: Agent
    public let model: String          // 模型名（同 agent 多模型时按模型拆行；"" = 未识别）
    public var tokensIn: Int          // 输入侧 token（含缓存读/写，见各解析器注释）
    public var tokensOut: Int
    public var cost: Double           // 成本 USD（仅 Claude cost-state 提供；无数据为 0）
    public var sessionCount: Int
    public var lastActive: Date?

    public init(agent: Agent, model: String, tokensIn: Int = 0, tokensOut: Int = 0,
                cost: Double = 0, sessionCount: Int = 0, lastActive: Date? = nil) {
        self.agent = agent; self.model = model
        self.tokensIn = tokensIn; self.tokensOut = tokensOut
        self.cost = cost; self.sessionCount = sessionCount; self.lastActive = lastActive
    }

    public var totalTokens: Int { tokensIn + tokensOut }
}

/// 最近会话（两家会话索引合并展示）
public struct AgentSessionEntry: Identifiable, Equatable {
    public let id: String
    public let agent: AgentUsage.Agent
    public let title: String
    public let date: Date
}

/// 额度/配额快照（B2 告警用）
public struct AgentQuotaStatus: Equatable {
    public let agent: AgentUsage.Agent
    /// 已用百分比 0-100（拿不到真实额度时按「日预算」折算）
    public let usedPercent: Double
    /// 额度重置时刻（Codex rate_limits 提供时非 nil）
    public let resetAt: Date?
    /// 数据来源说明（"rate_limits" / "日预算"）
    public let source: String
    /// 按当前消耗速率推算，重置前是否会用尽（「撑不到重置」）
    public let projectedExhaustionBeforeReset: Bool
}

/// B2 告警设置（UserDefaults；未设置 = 开 / 90%）
public enum AgentHUDPreferences {
    private static let enabledKey = "agentHud.alert.enabled"
    private static let thresholdKey = "agentHud.alert.threshold"     // 80 / 90 / 95
    private static let budgetKey = "agentHud.dailyTokenBudget"       // 0 = 自动默认

    public static let thresholdOptions: [Int] = [80, 90, 95]

    public static var alertEnabled: Bool {
        get { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }
    public static var alertThreshold: Int {
        get {
            let v = UserDefaults.standard.integer(forKey: thresholdKey)
            return thresholdOptions.contains(v) ? v : 90
        }
        set { UserDefaults.standard.set(newValue, forKey: thresholdKey) }
    }
    /// 日预算（token/天，两家合计）；0 = 用默认 300k
    public static var dailyTokenBudget: Int {
        get {
            let v = UserDefaults.standard.integer(forKey: budgetKey)
            return v > 0 ? v : 300_000
        }
        set { UserDefaults.standard.set(newValue, forKey: budgetKey) }
    }
}
