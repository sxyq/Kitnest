import AppKit
import SwiftUI

// MARK: - Agent 用量面板（v130（AndroMeld/AgentHUD）：Agent HUD 核心接入 B1/B2）
//
// 形态适配：FrsetNext 是菜单栏工具，**不做刘海**——Agent HUD 的刘海形态换成
// 独立窗 + 状态栏项。本视图同时可嵌面板/独立窗。
// 内容：各 agent 用量卡片 + Token 统计 + 最近会话 + 额度告警设置（B2）+ 待处理事件（B3）。

struct AgentHUDView: View {

    @ObservedObject private var monitor = AgentUsageMonitor.shared
    @ObservedObject private var approvals = AgentApprovalWatcher.shared
    // B2 设置（本地镜像，改完写回 UserDefaults）
    @Stored private var alertOn = AgentHUDPreferences.alertEnabled
    @Stored private var threshold = AgentHUDPreferences.alertThreshold

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                header
                quotaSection
                usageCards
                tokenSummary
                sessionsSection
                if !approvals.pending.isEmpty { approvalsSection }
                alertSettings
                footer
            }
            .padding(14)
        }
        .frame(minWidth: 460, minHeight: 420)
        .onAppear { AgentHUDModule.startIfNeeded() }
    }

    // MARK: 头部

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "gauge.with.dots.needle.67percent")
                .font(.system(size: 16))
                .foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 1) {
                Text("Agent 用量")
                    .font(.system(size: 14, weight: .semibold))
                Text(monitor.lastRefresh.map {
                    "最近刷新 \($0.formatted(date: .omitted, time: .shortened)) · 近 30 天"
                } ?? "尚未刷新")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            TransferChrome.smallAction(monitor.isRefreshing ? "刷新中…" : "刷新",
                                       icon: "arrow.clockwise") {
                monitor.refresh()
            }
        }
    }

    // MARK: 额度（B2）

    private var quotaSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            if monitor.quotas.isEmpty {
                Text("暂无额度数据（运行一次 Claude Code / Codex 后再来刷新）")
                    .font(.system(size: 9.5))
                    .foregroundStyle(.tertiary)
            } else {
                ForEach(Array(monitor.quotas.enumerated()), id: \.offset) { _, q in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(q.agent.rawValue)
                                .font(.system(size: 10, weight: .medium))
                            Spacer()
                            Text("\(Int(q.usedPercent))%")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(percentColor(q.usedPercent))
                            if q.projectedExhaustionBeforeReset {
                                Text("撑不到重置")
                                    .font(.system(size: 8, weight: .semibold))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1)
                                    .background(Color.red, in: Capsule())
                            }
                        }
                        progressBar(q.usedPercent)
                        HStack {
                            Text("来源：\(q.source)")
                                .font(.system(size: 8))
                                .foregroundStyle(.tertiary)
                            if let reset = q.resetAt {
                                Text("重置：\(reset.formatted(date: .omitted, time: .shortened))")
                                    .font(.system(size: 8))
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                }
            }
        }
    }

    private func progressBar(_ pct: Double) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08))
                Capsule().fill(percentColor(pct).gradient)
                    .frame(width: max(2, geo.size.width * min(1, pct / 100)))
            }
        }
        .frame(height: 5)
    }

    private func percentColor(_ pct: Double) -> Color {
        if pct >= 95 { return .red }
        if pct >= 80 { return .orange }
        return Theme.accent
    }

    // MARK: 用量卡片（B1）

    private var usageCards: some View {
        VStack(alignment: .leading, spacing: 6) {
            if monitor.usages.isEmpty {
                Text("未读到用量记录（~/.claude/ 与 ~/.codex/ 下无近 30 天会话）")
                    .font(.system(size: 9.5))
                    .foregroundStyle(.tertiary)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 210, maximum: .infinity), spacing: 8)],
                          spacing: 8) {
                    ForEach(monitor.usages) { u in
                        usageCard(u)
                    }
                }
            }
        }
    }

    private func usageCard(_ u: AgentUsage) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                Image(systemName: u.agent == .claude ? "sparkles" : "terminal")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.accent)
                Text(u.agent.rawValue)
                    .font(.system(size: 10.5, weight: .semibold))
                Spacer()
                if !u.model.isEmpty {
                    Text(u.model)
                        .font(.system(size: 8.5, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            HStack(spacing: 10) {
                stat("Token", formatTokens(u.totalTokens))
                stat("会话", "\(u.sessionCount)")
                if u.cost > 0 {
                    stat("成本", String(format: "$%.2f", u.cost))
                }
            }
            HStack {
                Text("↑ \(formatTokens(u.tokensIn))  ↓ \(formatTokens(u.tokensOut))")
                    .font(.system(size: 8.5, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer()
                if let t = u.lastActive {
                    Text(t.formatted(date: .abbreviated, time: .shortened))
                        .font(.system(size: 8))
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(9)
        .background(Color.primary.opacity(0.035),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
        )
    }

    private func stat(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title).font(.system(size: 8)).foregroundStyle(.tertiary)
            Text(value).font(.system(size: 11, weight: .medium, design: .rounded))
        }
    }

    /// Token 合计（B1「Token 统计」）
    private var tokenSummary: some View {
        let totalIn = monitor.usages.reduce(0) { $0 + $1.tokensIn }
        let totalOut = monitor.usages.reduce(0) { $0 + $1.tokensOut }
        let totalCost = monitor.usages.reduce(0.0) { $0 + $1.cost }
        return HStack(spacing: 14) {
            stat("输入 Token", formatTokens(totalIn))
            stat("输出 Token", formatTokens(totalOut))
            stat("合计", formatTokens(totalIn + totalOut))
            if totalCost > 0 {
                stat("总成本", String(format: "$%.2f", totalCost))
            }
            Spacer()
        }
        .padding(9)
        .background(Theme.accent.opacity(0.06),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    // MARK: 最近会话（B1）

    private var sessionsSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("最近会话")
                .font(.system(size: 10.5, weight: .semibold))
            if monitor.sessions.isEmpty {
                Text("暂无会话记录")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            } else {
                ForEach(monitor.sessions.prefix(8)) { s in
                    HStack(spacing: 6) {
                        Image(systemName: s.agent == .claude ? "sparkles" : "terminal")
                            .font(.system(size: 8))
                            .foregroundStyle(.secondary)
                            .frame(width: 12)
                        Text(s.title)
                            .font(.system(size: 9.5))
                            .lineLimit(1)
                        Spacer()
                        Text(s.date.formatted(date: .abbreviated, time: .shortened))
                            .font(.system(size: 8))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Color.primary.opacity(0.03),
                                in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
            }
        }
    }

    // MARK: B3 待处理事件

    private var approvalsSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("待处理（批准 / 提问）")
                .font(.system(size: 10.5, weight: .semibold))
            ForEach(approvals.pending.prefix(5), id: \.id) { p in
                HStack(spacing: 6) {
                    Image(systemName: p.type == "approval" ? "hand.raised.fill" : "questionmark.circle.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(Color.orange)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(p.title).font(.system(size: 9.5)).lineLimit(1)
                        Text(p.agent).font(.system(size: 8)).foregroundStyle(.tertiary)
                    }
                    Spacer()
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(Color.orange.opacity(0.08),
                            in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
        }
    }

    // MARK: B2 告警设置

    private var alertSettings: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("额度告警")
                .font(.system(size: 10.5, weight: .semibold))
            HStack(spacing: 8) {
                Toggle("启用告警", isOn: Binding(
                    get: { alertOn },
                    set: { v in alertOn = v; AgentHUDPreferences.alertEnabled = v }))
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .font(.system(size: 10))
                Text("阈值")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Picker("", selection: Binding(
                    get: { threshold },
                    set: { v in threshold = v; AgentHUDPreferences.alertThreshold = v; AgentUsageMonitor.shared.refresh() })) {
                    ForEach(AgentHUDPreferences.thresholdOptions, id: \.self) { t in
                        Text("\(t)%").tag(t)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 150)
                Spacer()
            }
            Text("达到阈值或「撑不到重置」时弹 Toast 并点亮状态栏徽标（数字/颜色）")
                .font(.system(size: 8.5))
                .foregroundStyle(.tertiary)
        }
        .padding(9)
        .background(Color.primary.opacity(0.03),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var footer: some View {
        Text("数据源：~/.claude/ 会话记录（usage/cost-state）与 ~/.codex/ rollout（token_count）；本机读取、不上传。")
            .font(.system(size: 8))
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func formatTokens(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1_000 { return String(format: "%.1fk", Double(n) / 1_000) }
        return "\(n)"
    }
}

// MARK: - 独立窗（深链 frsetnext://agenthud / 状态栏「Agent 用量」入口）

public final class AgentHUDWindowController: NSWindowController, NSWindowDelegate {

    public static let shared = AgentHUDWindowController()

    /// 内容是否已装载（每次 show 前确保有内容，关闭后重建）
    private var contentInstalled = false

    private convenience init() {
        let contentRect = NSRect(x: 0, y: 0, width: 520, height: 520)
        let window = NSWindow(contentRect: contentRect,
                              styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                              backing: .buffered,
                              defer: false)
        self.init(window: window)
        window.title = "Agent 用量"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        if #available(macOS 11.0, *) { window.titlebarSeparatorStyle = .none }
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.hidesOnDeactivate = false
        window.delegate = self
        window.applyOfficialChrome()
        installContent(in: window)
    }

    private func installContent(in window: NSWindow) {
        window.contentMinSize = NSSize(width: 460, height: 420)
        window.contentView = NSView()
        contentInstalled = false
        // 与统计窗同款：内容延后一个 runloop 装载（避免同一 display cycle 的约束异常）
        DispatchQueue.main.async { [weak self] in
            let hostingView = NSHostingView(rootView: AgentHUDView())
            hostingView.sizingOptions = []
            if #available(macOS 13.3, *) { hostingView.safeAreaRegions = [] }
            window.contentView = hostingView
            window.attachOfficialRoundCloseButton()
            self?.contentInstalled = true
        }
    }

    /// 打开（幂等；深链/状态栏/设置共用）
    public func show() {
        if let window, !contentInstalled {
            installContent(in: window)
        }
        showWindow(nil)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
        AgentUsageMonitor.shared.refresh()
        Log.info("AgentHUD", "window opened")
    }
}
