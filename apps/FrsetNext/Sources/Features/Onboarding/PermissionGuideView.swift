import SwiftUI

// MARK: - 权限引导窗内容（重建版自研）
//
// 设计要点（对照原版 PermissionWindow 的三件套：Controller/Model/View）：
//   · 原版只有一个「屏幕录制」权限；重建版实际涉及四类（见 PermissionKind），
//     且功能面更大（自动粘贴/划词/录屏收音/日历），所以做成一屏「权限总览」；
//   • 每张卡片：为什么需要（purpose）→ 影响哪些功能（features）→ 当前状态 → 操作；
//   • 状态权威化：屏幕录制以 SCK 实探为准（preflight 假阴性，PermissionCenter 头注）；
//   • 授权后不会回调：屏幕录制/辅助功能授权后面板无回调，窗口重新激活时刷新状态；
//   • 「稍后再说」允许跳过（不强制），但核心权限未授时按钮区给出明示。

struct PermissionGuideView: View {

    @ObservedObject private var center = PermissionCenter.shared

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(PermissionKind.allCases) { kind in
                        PermissionCard(
                            kind: kind,
                            status: center.status(kind),
                            probing: kind == .screenRecording && center.probingScreenRecording,
                            onRequest: { center.request(kind) },
                            onOpenSettings: { center.openSystemSettings(kind) }
                        )
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
            }
            footer
        }
        .frame(width: 660, height: 600)
        .background(backdrop)
        .onAppear {
            center.refreshAll()
            Task { await center.probeScreenRecording() }
        }
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification)) { _ in
                // 用户从系统设置切回来：重取状态（授权无回调，只能主动刷新）
                center.refreshAll()
                Task { await center.probeScreenRecording() }
            }
    }

    // MARK: - 头部

    private var header: some View {
        VStack(spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: "lock.shield")
                    .font(.system(size: 26, weight: .medium))
                    .foregroundStyle(Color.accentColor)
                Text("权限引导")
                    .font(.system(size: 20, weight: .semibold))
                Spacer()
                progressPill
            }
            Text("FrsetNext 需要以下几项系统权限才能完整工作。所有处理都在本机完成，不上传任何数据。")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, 10)
    }

    private var progressPill: some View {
        let granted = center.grantedCount
        let total = PermissionKind.allCases.count
        return HStack(spacing: 5) {
            Image(systemName: granted == total ? "checkmark.seal.fill" : "seal")
                .foregroundStyle(granted == total ? Color(nsColor: .systemGreen) : Color.secondary)
            Text("\(granted)/\(total)")
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.quaternary.opacity(0.5), in: Capsule())
    }

    // MARK: - 底部

    private var footer: some View {
        VStack(spacing: 10) {
            if !center.allCoreGranted {
                Label("核心权限未全部授权：截图与全局快捷键暂不可用", systemImage: "exclamationmark.triangle")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.orange)
            }
            HStack(spacing: 12) {
                Button("稍后再说") {
                    PermissionGuideWindowController.shared.close()
                }
                .keyboardShortcut(.cancelAction)
                Spacer()
                Button("完成") {
                    PermissionGuideWindowController.shared.close()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var backdrop: some View {
        Color(OfficialChrome.windowBackground)
    }
}

// MARK: - 单张权限卡

private struct PermissionCard: View {

    let kind: PermissionKind
    let status: PermissionStatus
    let probing: Bool
    let onRequest: () -> Void
    let onOpenSettings: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            statusIcon
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(kind.title)
                        .font(.system(size: 14, weight: .semibold))
                    if kind.isCore {
                        Text("核心")
                            .font(.system(size: 9, weight: .medium))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1.5)
                            .background(Color.accentColor.opacity(0.15), in: Capsule())
                            .foregroundStyle(Color.accentColor)
                    }
                    Spacer()
                    statusBadge
                }
                Text(kind.purpose)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                FlowHStack(spacing: 5, lineSpacing: 4) {
                    ForEach(kind.features, id: \.self) { f in
                        Text(f)
                            .font(.system(size: 10))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.quaternary.opacity(0.6), in: Capsule())
                            .foregroundStyle(.secondary)
                    }
                }                .padding(.top, 1)
                actionRow
            }
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(kind.isCore && !status.isGranted ? Color.accentColor.opacity(0.35) : .clear, lineWidth: 1)
        )
    }

    private var statusIcon: some View {
        ZStack {
            Circle()
                .fill(status.tint.opacity(0.14))
                .frame(width: 34, height: 34)
            Image(systemName: kind.symbol)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(status.tint)
        }
    }

    private var statusBadge: some View {
        HStack(spacing: 4) {
            if probing {
                ProgressView().scaleEffect(0.6).frame(width: 12, height: 12)
            } else {
                Image(systemName: status.symbol)
                    .font(.system(size: 10))
            }
            Text(probing ? "检测中" : status.label)
                .font(.system(size: 10, weight: .medium))
        }
        .foregroundStyle(probing ? Color.secondary : status.tint)
    }

    @ViewBuilder
    private var actionRow: some View {
        switch status {
        case .granted:
            Button("打开设置") { onOpenSettings() }
                .controlSize(.small)
                .buttonStyle(.bordered)
        case .notDetermined:
            Button(kind == .accessibility ? "去设置授权" : "授权") { onRequest() }
                .controlSize(.small)
                .buttonStyle(.borderedProminent)
        case .denied:
            Button("去设置开启") { onOpenSettings() }
                .controlSize(.small)
                .buttonStyle(.borderedProminent)
        case .unsupported:
            Text("当前系统不支持")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
    }
}
