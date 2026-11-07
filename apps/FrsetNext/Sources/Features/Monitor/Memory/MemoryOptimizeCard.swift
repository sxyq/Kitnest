import SwiftUI

/// 内存详情页底部的「内存维护」区：一个按钮做两件事
///   ① 暂停闲置应用（冻结，切回即恢复）
///   ② 广播内存压力 + 清理文件缓存
/// 报告必须分两段写：冻结的常驻量不是释放量。
struct MemoryOptimizeSection: View {
    @ObservedObject var optimizer: MemoryOptimizer

    @Stored private var freezeIdle = Preferences.shared.value(
        Preferences.Keys.memoryFreezeIdle, default: true)

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider().opacity(0.4)

            HStack(spacing: 6) {
                Circle()
                    .fill(optimizer.helperInstalled ? Color.green : Color.orange)
                    .frame(width: 5, height: 5)
                Text("内存维护")
                    .font(.system(size: 11, weight: .semibold))
                Spacer()

                if optimizer.isOptimizing {
                    ProgressView().controlSize(.small)
                    Text(busyText)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else {
                    Toggle("暂停闲置", isOn: $freezeIdle)
                        .toggleStyle(.checkbox)
                        .controlSize(.mini)
                        .font(.system(size: 10))
                        .fixedSize()
                        .help("顺带用 SIGSTOP 暂停一段时间没动过的应用，切回它时自动恢复")
                        .onChange(of: freezeIdle) { value in
                            Preferences.shared.set(Preferences.Keys.memoryFreezeIdle, value)
                        }

                    Button {
                        Task { await optimizer.optimize(freezeIdle: freezeIdle) }
                    } label: {
                        Label("深度释放", systemImage: "wind")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .help("先暂停闲置应用，再广播内存压力并清理文件缓存")
                }
            }

            if !optimizer.frozenNow.isEmpty {
                frozenPanel
            }

            if let report = optimizer.report {
                reportView(report)
            } else if let message = optimizer.message {
                Text(message)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if !optimizer.helperInstalled {
                Text("首次使用需要一次管理员授权安装后台服务（只安装固定的内存维护命令，之后不再询问）。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var busyText: String {
        switch optimizer.stage {
        case .freezing: return "正在暂停闲置应用…"
        case .purging: return "正在清理缓存…"
        case .idle: return "正在准备…"
        }
    }

    /// 暂停中的 App：给名字 + 常驻量 + 一键全部唤醒。
    /// 这里刻意不写「已释放 X」，因为页还在内存里，只是冷了。
    private var frozenPanel: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "pause.circle")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Text("已暂停 \(optimizer.frozenNow.count) 个应用")
                    .font(.system(size: 11, weight: .medium))
                Text("共 \(MonitorFormat.bytes(optimizer.frozenNow.reduce(0) { $0 + $1.footprint })) 常驻")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("全部唤醒") {
                    ProcessFreezer.shared.thawAll()
                }
                .buttonStyle(.link)
                .font(.system(size: 10))
            }

            Text(optimizer.frozenNow.map(\.name).joined(separator: "、"))
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            Text("切回该应用或 30 分钟后自动恢复")
                .font(.system(size: 10))
                .foregroundStyle(Theme.tertiaryText)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(radius: 6)
    }

    @ViewBuilder
    private func reportView(_ report: MemoryOptimizationReport) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(MonitorFormat.bytes(report.before.used))
                    .foregroundStyle(.secondary)
                Image(systemName: "arrow.right")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text(MonitorFormat.bytes(report.after.used))
                    .fontWeight(.semibold)
                Spacer()
                Text(signed(report.usedDelta))
                    .fontWeight(.semibold)
                    .foregroundStyle(report.usedDelta < 0 ? Color.green : Color.secondary)
            }
            .font(.system(size: 11).monospacedDigit())

            VStack(spacing: 3) {
                deltaRow("应用", report.appDelta)
                deltaRow("压缩", report.compressedDelta)
                deltaRow("缓存", report.cachedDelta)
                if report.swapDelta != 0 { deltaRow("Swap", report.swapDelta) }
            }

            // 已用合计不降很正常：清掉的干净页会立刻被压缩内存吃掉。
            // 不解释这一句，用户会以为按钮没生效。
            Text(report.hasNoticeableRelease
                 ? "缓存与可回收内存已交还系统，几分钟后会重新长回来"
                 : "这次没有可回收的缓存；暂停的应用会在系统缺内存时才真正让出物理页")
                .font(.system(size: 10))
                .foregroundStyle(Theme.tertiaryText)
                .fixedSize(horizontal: false, vertical: true)

            if !report.releases.isEmpty {
                Text("响应应用")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.top, 1)
                ForEach(report.releases.prefix(3), id: \.name) { item in
                    HStack {
                        Text(item.name)
                            .lineLimit(1)
                        Spacer()
                        Text("-" + MonitorFormat.bytes(item.bytes))
                            .monospacedDigit()
                            .foregroundStyle(Color.green)
                    }
                    .font(.system(size: 11))
                }
            }

            if !report.steps.isEmpty {
                Text(report.steps.map(\.title).sorted().joined(separator: " + "))
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.tertiaryText)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(radius: 6)
    }

    private func deltaRow(_ title: String, _ delta: Int64) -> some View {
        HStack {
            Text(title)
                .foregroundStyle(.secondary)
            Spacer()
            Text(signed(delta))
                .monospacedDigit()
                .foregroundStyle(delta < 0 ? Color.green : Color.secondary)
        }
        .font(.system(size: 11))
    }

    private func signed(_ delta: Int64) -> String {
        guard delta != 0 else { return "±0" }
        let sign = delta > 0 ? "+" : "-"
        return sign + MonitorFormat.bytes(UInt64(abs(delta)))
    }
}
