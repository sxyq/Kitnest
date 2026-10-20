import AppKit
import SwiftUI

// MARK: - 端口占用卡片（网络监测页底部）
//
// UI 目标（2026-10-20 用户需求）：
//   · 一眼看出「哪些端口在监听、被谁占用、是否对局域网开放」；
//   · 与监测页既有语言一致：分区标题 + 玻璃卡片 + 等宽数字；
//   · 380pt 窄窗下不横向溢出：端口固定列、协议徽标、进程名可截断、地址右对齐；
//   · 默认只列 6 条（对外优先、端口升序），可展开全部；「对外」徽标可当过滤器；
//   · 点击任意行复制 `host:port`（对外端口复制回环地址），复用全局 Toast。

struct PortOccupancySection: View {
    @ObservedObject private var inspector = PortInspector.shared
    @Stored private var showAll = false
    @Stored private var onlyExposed = false

    private var filtered: [PortBinding] {
        onlyExposed ? inspector.bindings.filter(\.isExposed) : inspector.bindings
    }
    private var visible: [PortBinding] {
        showAll ? filtered : Array(filtered.prefix(6))
    }
    private var tcpCount: Int { inspector.bindings.filter { $0.proto == "TCP" }.count }
    private var udpCount: Int { inspector.bindings.filter { $0.proto == "UDP" }.count }
    private var exposedCount: Int { inspector.bindings.filter(\.isExposed).count }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                MonitorSectionTitle("端口占用")
                    .frame(maxWidth: .infinity)
                refreshButton
            }

            summary

            if inspector.bindings.isEmpty {
                emptyState
            } else {
                MonitorCard {
                    VStack(spacing: 0) {
                        ForEach(Array(visible.enumerated()), id: \.element.id) { index, item in
                            row(item)
                            if index < visible.count - 1 {
                                Rectangle()
                                    .fill(Color.primary.opacity(0.07))
                                    .frame(height: 0.5)
                            }
                        }
                    }
                }
            }

            footer
        }
        .onAppear { inspector.start() }
        .onDisappear { inspector.stop() }
    }

    // MARK: 摘要徽标

    private var summary: some View {
        HStack(spacing: 6) {
            chip("TCP \(tcpCount)", color: MonitorColors.download)
            chip("UDP \(udpCount)", color: MonitorColors.memory)
            chip("对外 \(exposedCount)", color: MonitorColors.upload, active: onlyExposed) {
                onlyExposed.toggle()
            }
            Spacer(minLength: 4)
            if inspector.isScanning {
                ProgressView()
                    .controlSize(.mini)
                    .scaleEffect(0.7)
                    .frame(width: 14, height: 14)
            }
        }
    }

    private func chip(_ text: String, color: Color, active: Bool = false, action: (() -> Void)? = nil) -> some View {
        let label = Text(text)
            .font(.system(size: 10, weight: .semibold).monospacedDigit())
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 2.5)
            .background(
                Capsule().fill(color.opacity(active ? 0.22 : 0.10))
            )
        return Group {
            if let action {
                Button(action: action) { label }
                    .buttonStyle(.plain)
                    .help(onlyExposed ? "显示全部端口" : "只看对局域网开放的端口")
            } else {
                label
            }
        }
    }

    // MARK: 行

    private func row(_ item: PortBinding) -> some View {
        Button {
            copy(item)
        } label: {
            HStack(spacing: 7) {
                // verbatim：避免整数被本地化成「59,615」而截断（5 位端口必须完整）
                Text(verbatim: "\(item.port)")
                    .font(.system(size: 12.5, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.primary)
                    .frame(width: 50, alignment: .leading)

                Text(item.proto)
                    .font(.system(size: 8.5, weight: .bold))
                    .foregroundStyle(item.proto == "TCP" ? MonitorColors.download : MonitorColors.memory)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1.5)
                    .background(
                        Capsule().fill((item.proto == "TCP" ? MonitorColors.download : MonitorColors.memory).opacity(0.12))
                    )

                Text(item.process)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.primary.opacity(0.85))
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer(minLength: 4)

                Text(item.addressLabel)
                    .font(.system(size: 10, weight: .regular).monospaced())
                    .foregroundStyle(item.isExposed ? MonitorColors.upload : Color.secondary.opacity(0.75))
                    .lineLimit(1)
                    .layoutPriority(1)

                if item.isExposed {
                    Circle()
                        .fill(MonitorColors.upload)
                        .frame(width: 5, height: 5)
                        .help("对局域网开放")
                }
            }
            .frame(height: 24)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("进程 \(item.process)（pid \(item.pids.prefix(3).map(String.init).joined(separator: ", "))）\n点击复制 \(item.copyHost):\(item.port)")
    }

    // MARK: 空态 / 页脚

    private var emptyState: some View {
        HStack(spacing: 6) {
            Image(systemName: inspector.isScanning ? "hourglass" : "checkmark.shield")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
            Text(inspector.isScanning ? "检测中…" : (onlyExposed ? "没有对局域网开放的端口" : "未检测到监听端口"))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(height: 36)
        .padding(.horizontal, 2)
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Text("对外 = 同一局域网可访问")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
            Spacer(minLength: 4)
            if filtered.count > 6 {
                Button {
                    showAll.toggle()
                } label: {
                    Text(showAll ? "收起" : "全部 \(filtered.count)")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(MonitorColors.download)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var refreshButton: some View {
        Button {
            inspector.scan(force: true)
        } label: {
            Image(systemName: "arrow.clockwise")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .rotationEffect(.degrees(inspector.isScanning ? 360 : 0))
                .animation(inspector.isScanning
                           ? .linear(duration: 0.9).repeatForever(autoreverses: false)
                           : .default,
                           value: inspector.isScanning)
        }
        .buttonStyle(.plain)
        .help("重新检测端口")
    }

    // MARK: 交互

    private func copy(_ item: PortBinding) {
        let text = "\(item.copyHost):\(item.port)"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        Toast.show("已复制 \(text)", icon: "doc.on.doc")
    }
}
