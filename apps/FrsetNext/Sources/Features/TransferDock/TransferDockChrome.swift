import SwiftUI

// MARK: - 传输与投屏共用小部件（v114：投屏页 / 文件传输页共用一套，不各写一份）
//
// 背景：v114 按用户要求把「投屏」从「文件中转」拆成独立面板页（顶部四段签名：
// 主页 │ 性能监测 │ 文件中转 │ 投屏）。两页需要同一套区块头与轻按钮样式，
// 这里是唯一实现（与 docs 系列「不做第二套」纪律一致）。

enum TransferChrome {

    /// 区块头：图标 + 标题 + 灰色说明 + 右侧动作区（高 24、淡底）
    static func sectionHeader<Trailing: View>(title: String, symbol: String,
                                              detail: String, tint: Color,
                                              @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
                .font(.system(size: 11))
                .foregroundStyle(tint)
            Text(title)
                .font(.system(size: 11, weight: .semibold))
            Text(detail)
                .font(.system(size: 11))
                .foregroundStyle(Theme.tertiaryText)
            Spacer(minLength: 2)
            trailing()
        }
        .padding(.horizontal, 8)
        .frame(height: 24)
        // v116 设计 token：区块头带主题色淡底 + 左侧 2pt 色条（不再是清一色灰）
        .background(tint.opacity(0.07))
        .overlay(alignment: .leading) {
            Rectangle().fill(tint).frame(width: 2)
        }
    }

    /// 轻按钮：小图标 + 小字（区块内的行内动作）
    static func smallAction(_ title: String, icon: String,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Image(systemName: icon)
                    .font(.system(size: 11))
                Text(title)
                    .font(.system(size: 11))
            }
            .foregroundStyle(Theme.accent)
            .padding(.horizontal, 6)
            .padding(.vertical, 2.5)
            .background(Theme.accent.opacity(0.10), in: Capsule())
        }
        .buttonStyle(.plain)
    }

    /// 设备状态行（投屏页 / 文件互传区共用）：状态点 + 序列号 + 右侧动作
    static func deviceRow(serial: String, connected: Bool,
                          @ViewBuilder trailing: () -> some View) -> some View {
        HStack(spacing: 8) {
            Image(systemName: connected ? "checkmark.circle.fill" : "exclamationmark.circle")
                .foregroundStyle(connected ? Color.green : Color.orange)
                .font(.system(size: 11))
            Text(serial)
                .font(.system(size: 11, design: .monospaced))
                .lineLimit(1)
            Spacer()
            trailing()
        }
    }
}
