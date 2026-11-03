import SwiftUI

/// 内存详情页底部的「内存维护」区：释放按钮 + 优化前后诚实报告
struct MemoryOptimizeSection: View {
    @ObservedObject var optimizer: MemoryOptimizer

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider().opacity(0.4)

            HStack(spacing: 8) {
                Circle()
                    .fill(optimizer.helperInstalled ? Color.green : Color.orange)
                    .frame(width: 5, height: 5)
                Text("内存维护")
                    .font(.system(size: 11, weight: .semibold))
                Spacer()

                if optimizer.isOptimizing {
                    ProgressView()
                        .controlSize(.small)
                    Text(optimizer.helperInstalled ? "正在释放…" : "正在安装后台服务…")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                } else {
                    Button {
                        Task { await optimizer.optimize() }
                    } label: {
                        Label("释放内存", systemImage: "wind")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
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
            } else {
                Text("先向所有应用广播内存压力（让它们自行回收缓存），再清理文件缓存。Wired 内存无法释放。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private func reportView(_ report: MemoryOptimizationReport) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if report.hasNoticeableRelease {
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
                        .foregroundStyle(Color.green)
                }
                .font(.system(size: 11).monospacedDigit())

                VStack(spacing: 3) {
                    deltaRow("应用", report.appDelta)
                    deltaRow("压缩", report.compressedDelta)
                    deltaRow("缓存", report.cachedDelta)
                    if report.swapDelta != 0 { deltaRow("Swap", report.swapDelta) }
                }
            } else {
                Text("这次没有可回收的缓存。压缩内存属于正在运行的应用，只有它们自己响应压力时才会释放。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

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
