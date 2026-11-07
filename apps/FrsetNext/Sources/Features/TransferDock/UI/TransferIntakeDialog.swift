import SwiftUI
import AppKit

// MARK: - 转入请求（拖文件到图标 / 点「转入」都走这里）

enum TransferIntakeChoice {
    case cloud   // 云端中转（OPPO 2 GiB）
    case local   // 本地中转（本机暂存 / 局域网）
}

struct TransferIntakeRequest: Identifiable {
    let id = UUID()
    let urls: [URL]
}

extension Notification.Name {
    /// userInfo: ["urls": [URL]]
    static let frsetTransferIntake = Notification.Name("frset.transfer.intake")
    /// 转入选了云端但未登录 → 让中转页把登录弹出来
    static let frsetOpenTransferLogin = Notification.Name("frset.transfer.login")
}

// MARK: - 弹框

/// 转入弹框：一眼看清「几个文件、多大」，再选云端还是本地。
///
/// 动效口径（与主面板神灯同一套语言）：
///   · 整块 0.18s 淡入 + 轻微上浮 6pt，不缩放（缩放会和系统 sheet 的位移动画叠加）；
///   · 两张卡片错开 40ms 依次进来，让视线先落在标题、再落到选项；
///   · 选中即高亮描边，不做弹跳——这是功能性选择，不需要庆祝动画。
struct TransferIntakeDialog: View {
    let request: TransferIntakeRequest
    let onConfirm: (TransferIntakeChoice) -> Void
    let onCancel: () -> Void

    @Stored private var appeared = false
    @Stored private var hovering: TransferIntakeChoice?

    private var totalBytes: Int64 {
        request.urls.reduce(0) { sum, url in
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
            return sum + size
        }
    }

    private var summary: String {
        let n = request.urls.count
        let size = ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
        if n == 1 { return "\(request.urls[0].lastPathComponent) · \(size)" }
        return "\(n) 个文件 · \(size)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.up.forward.square")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                Text("转入")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Button { onCancel() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
            }

            Text(summary)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(2)

            VStack(spacing: 8) {
                card(.cloud,
                     title: "云端中转",
                     subtitle: "传到 OPPO 云，手机/电脑都能取（2 GiB）",
                     icon: "cloud")
                card(.local,
                     title: "本地中转",
                     subtitle: "只留在本机与局域网，不上云",
                     icon: "externaldrive")
            }
            .opacity(appeared ? 1 : 0)
            .offset(y: appeared ? 0 : 6)
        }
        .padding(16)
        .frame(width: 320)
        .onAppear {
            withAnimation(.easeOut(duration: 0.18)) { appeared = true }
        }
    }

    @ViewBuilder
    private func card(_ choice: TransferIntakeChoice,
                      title: String, subtitle: String, icon: String) -> some View {
        let active = hovering == choice
        Button {
            onConfirm(choice)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 14))
                    .frame(width: 22)
                    .foregroundStyle(active ? Theme.accent : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 12, weight: .medium))
                    Text(subtitle)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                    .fill(active ? Theme.accent.opacity(0.10) : Color.primary.opacity(0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                    .strokeBorder(active ? Theme.accent.opacity(0.55) : Color.primary.opacity(0.08),
                                  lineWidth: 0.5)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 ? choice : nil }
        .animation(.easeOut(duration: 0.12), value: active)
    }
}
