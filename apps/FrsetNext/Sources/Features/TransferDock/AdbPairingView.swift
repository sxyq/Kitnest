import AppKit
import SwiftUI

// MARK: - 无线配对卡片（v130（AndroMeld/AgentHUD）：AndroMeld P0-1 配对流程 UI）
//
// 位置：投屏页（CastView）「Android 设备」区内的独立卡片。
// 内容：① 扫描发现列表（IP:端口 + 服务类型 + 配对/连接动作）；
//       ② 「配对」→ 弹框输配对码（手机「开发者选项 → 无线调试 → 使用配对码配对设备」）；
//       ③ 已连接无线设备列表 + 「断开」；
//       ④ 状态提示（配对中/已连接/失败原因）。
// 数据/命令全部走 AdbPairingService（host 级 adb，不带 -s）。

struct AdbPairingView: View {

    /// v154：内嵌模式。投屏页把「无线连接」收进折叠区后，配对卡的标题/背景/外边距
    /// 会和折叠区自己的标题重复，这里用 embedded 只保留内容（发现列表 / 手动 IP / 状态）。
    var embedded: Bool = false

    // 显式 init：本结构有 private 的 @Stored 属性，成员逐一初始化器会变成 private，
    // 外部（CastView）就构造不了。这里只暴露 embedded 一个开关。
    init(embedded: Bool = false) {
        self.embedded = embedded
    }

    @ObservedObject private var svc = AdbPairingService.shared
    /// 配对弹框（输配对码）
    @Stored private var showPairSheet = false
    @Stored private var pairTarget = ""
    @Stored private var pairCode = ""
    /// 手动连接（未被 mDNS 发现时）
    @Stored private var manualTarget = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !embedded { header }

            // 发现列表
            if !svc.discovered.isEmpty {
                VStack(spacing: 4) {
                    ForEach(svc.discovered) { dev in
                        discoveredRow(dev)
                    }
                }
                .padding(.horizontal, embedded ? 0 : 10)
            }

            // 已连接无线设备 + 断开
            if !svc.wirelessConnected.isEmpty {
                VStack(spacing: 4) {
                    ForEach(svc.wirelessConnected, id: \.self) { target in
                        HStack(spacing: 6) {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 11.5))
                                .foregroundStyle(.green)
                            Text(target)
                                .font(.system(size: 11.5, design: .monospaced))
                                .lineLimit(1)
                            Spacer(minLength: 2)
                            TransferChrome.smallAction("断开", icon: "wifi.slash") {
                                svc.disconnect(target: target)
                            }
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Color.primary.opacity(0.03),
                                    in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    }
                }
                .padding(.horizontal, embedded ? 0 : 10)
            }

            // 手动连接（mDNS 被公司网络隔离时兜底）
            HStack(spacing: 5) {
                Image(systemName: "network")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                TextField("手动 IP:连接端口", text: $manualTarget)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                    .frame(width: 150)
                    .font(.system(size: 11.5, design: .monospaced))
                TransferChrome.smallAction("连接", icon: "link") {
                    svc.connect(target: manualTarget)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, embedded ? 0 : 12)

            // 状态提示（配对中/已连接/失败原因）
            if !svc.statusText.isEmpty {
                Text(svc.statusText)
                    .font(.system(size: 11.5))
                    .foregroundStyle(svc.phase.isBusy ? Color.orange : .secondary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, embedded ? 0 : 12)
            }
        }
        .padding(.vertical, embedded ? 0 : 8)
        .background {
            if !embedded {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.primary.opacity(0.02))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.05), lineWidth: 1)
                    )
            }
        }
        .padding(.horizontal, embedded ? 0 : 10)
        // 配对码弹框（系统窗级别：面板是浮层，sheet 在其上更稳）
        .sheet(isPresented: $showPairSheet) { pairSheet }
    }

    // MARK: 头部

    private var header: some View {
        TransferChrome.sectionHeader(
            title: "无线配对",
            symbol: "wifi",
            detail: svc.phase.isBusy ? "处理中…" : "Android 11+ 无线调试",
            tint: Color(red: 0.25, green: 0.6, blue: 0.9)) {
            TransferChrome.smallAction("扫描", icon: "antenna.radiowaves.left.and.right") {
                svc.scan()
            }
        }
        .padding(.horizontal, 8)
    }

    // MARK: 发现行（IP:端口 + 服务类型 + 动作）

    private func discoveredRow(_ dev: AdbPairingService.DiscoveredDevice) -> some View {
        HStack(spacing: 6) {
            Image(systemName: dev.needsPairing ? "exclamationmark.triangle.fill" : "link")
                .font(.system(size: 11.5))
                .foregroundStyle(dev.needsPairing ? Color.orange : Color.green)
            VStack(alignment: .leading, spacing: 0) {
                Text(dev.name)
                    .font(.system(size: 11.5, design: .monospaced))
                    .lineLimit(1)
                Text("\(dev.target) · \(dev.serviceType)")
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(Theme.tertiaryText)
                    .lineLimit(1)
            }
            Spacer(minLength: 2)
            if dev.needsPairing {
                TransferChrome.smallAction("配对", icon: "number") {
                    pairTarget = dev.target
                    pairCode = ""
                    showPairSheet = true
                }
            } else {
                TransferChrome.smallAction("连接", icon: "link") {
                    svc.connect(target: dev.target)
                }
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(Color.primary.opacity(0.03),
                    in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    // MARK: 配对码弹框

    private var pairSheet: some View {
        VStack(spacing: 12) {
            Text("输入配对码")
                .font(.system(size: 13, weight: .semibold))
            Text("手机「开发者选项 → 无线调试 → 使用配对码配对设备」\n弹窗显示 IP:端口 与 6 位配对码")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            TextField("IP:配对端口", text: $pairTarget)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11.5, design: .monospaced))
                .frame(width: 220)
            TextField("6 位配对码", text: $pairCode)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 13, design: .monospaced))
                .frame(width: 120)
                .multilineTextAlignment(.center)
            HStack(spacing: 12) {
                Button("取消") { showPairSheet = false }
                    .keyboardShortcut(.cancelAction)
                Button("配对") {
                    let target = pairTarget
                    let code = pairCode
                    showPairSheet = false
                    AdbPairingService.shared.pair(target: target, code: code)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(pairCode.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 320)
    }
}
