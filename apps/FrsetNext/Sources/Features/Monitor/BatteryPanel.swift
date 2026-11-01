import AppKit
import SwiftUI

// MARK: - 电池面板（v178）
//
// 版式对照：Status Trio 1.8 的电池详情页（用户 2026-11-02 指定）。
//
// 结构（自上而下，与原版一致）：
//   1. 标题行「电池 · 80%」+ 当前状态
//   2. **功耗流向图**：左侧「充电器输入」，右侧「充入电池 / 系统供电」，
//      两条流带宽度按瓦数成比例——一眼看出「输入的电都去哪了」
//   3. 明细行：读取时间 / 电压 / 电流 / 额定功率 / 循环次数 / 健康度 / 低电量模式
//   4. 口径说明（功率是估算值，三项不一定相加）
//   5. **CPU 能耗影响**：按 APP 归类的能耗排名（mW/W）
//   6. 低电量模式开关
//   7. 充电状态行 + 两个系统设置入口
//
// 数据口径（与 Status Trio 对齐，本地实测过）：
//   · 充电器输入 = SMC `PDTR`（读不到时回退 ChargingVoltage × ChargingCurrent）
//   · 充入电池   = 电池电压 × 电池电流（仅正向电流，即真正在充）
//   · 系统供电   = 输入 − 充入电池（差额，含 SoC/内存/显示控制器等未单独测量的负载）
//   三者来自不同传感器、更新时刻不同，**不一定完全相加**——这是原版也承认的事实，
//   所以界面上不做「为了让图形守恒而改写数值」。
//
// 拔电时：左侧改「电池放电」，右侧只剩「系统供电」= 放电功率。

struct BatteryStatsPanel: View {
    @ObservedObject private var sampler = MonitorSampler.shared
    @ObservedObject private var energy = BatteryEnergySampler.shared
    @ObservedObject private var lowPower = LowPowerModeController.shared

    var body: some View {
        let stats = StatsDataProvider.shared.current
        let battery = stats.battery
        let flow = BatteryFlowModel(battery: battery)

        return VStack(alignment: .leading, spacing: 12) {
            if battery?.present != true && (sampler.sample.batteryLevel ?? -1) < 0 {
                noBatteryNotice
            } else {
                header(battery)
                BatteryPowerFlowCard(input: flow.input, branches: flow.branches)
                detailRows(battery, stats)
                footnote(battery)
                energySection(stats)
                lowPowerRow
                chargeRow(battery, stats)
                linksRow
            }
        }
        .onAppear { energy.start() }
        .onDisappear { energy.stop() }
    }

    // MARK: 标题

    private func header(_ battery: StatsBattery?) -> some View {
        let percent = battery?.percent ?? Int(((sampler.sample.batteryLevel ?? 0) * 100).rounded())
        let color = levelColor(battery)
        return HStack(spacing: 9) {
            Image(systemName: batterySymbol(battery))
                .font(.system(size: 17))
                .foregroundStyle(color)
            Text("电池 · \(percent)%")
                .font(.system(size: 15, weight: .semibold))
                .monospacedDigit()
            Spacer(minLength: 6)
            Text(statusText(battery))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    private var noBatteryNotice: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 9) {
                Image(systemName: "battery.0percent")
                    .font(.system(size: 17))
                    .foregroundStyle(.secondary)
                Text("本机没有电池")
                    .font(.system(size: 15, weight: .semibold))
            }
            Text("台式机（Mac mini / Studio / Pro）没有内置电池，因此不显示功耗流向与能耗明细。")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: 明细

    private func detailRows(_ battery: StatsBattery?, _ stats: StatsSnapshot) -> some View {
        VStack(spacing: 7) {
            BatteryDetailRow(label: "整机读取时间", value: Self.timeFormatter.string(from: stats.updatedAt))
            if let battery, battery.present {
                BatteryDetailRow(label: "电池电压",
                                 value: String(format: "%.2f V", battery.voltageMv / 1000))
                BatteryDetailRow(label: "电池电流",
                                 value: String(format: "%.2f A", battery.amperageMa / 1000))
                if battery.adapterWatts > 0 {
                    BatteryDetailRow(label: "适配器额定功率",
                                     value: String(format: "%.0f W", battery.adapterWatts))
                }
                BatteryDetailRow(label: "循环次数", value: "\(battery.cycleCount)")
                if battery.designCapacity > 0 {
                    let health = min(1.2, Double(battery.maxCapacity) / Double(battery.designCapacity))
                    BatteryDetailRow(label: "电池健康度", value: String(format: "%.0f%%", health * 100))
                }
                if battery.designCapacity > 0 {
                    BatteryDetailRow(label: "当前容量",
                                     value: "\(StatsFormat.capacity(battery.currentCapacity)) / \(StatsFormat.capacity(battery.designCapacity))")
                }
            }
            BatteryDetailRow(label: "低电量模式", value: lowPower.enabled ? "开启" : "关闭")
        }
    }

    private func footnote(_ battery: StatsBattery?) -> some View {
        let text = (battery?.externalConnected ?? false)
            ? "功率为估算值，各传感器读数可能延迟或存在差异，三项功率不一定完全相加。额定功率并非实际输入。"
            : "功率为估算值，各传感器读数可能延迟或存在差异。拔电后显示的是电池放电功率；部分机型的电池数据可能延迟约一分钟。"
        return Text(text)
            .font(.system(size: 10.5))
            .foregroundStyle(Theme.tertiaryText)
            .lineSpacing(1.8)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: CPU 能耗影响

    @ViewBuilder
    private func energySection(_ stats: StatsSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("CPU 能耗影响")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
                if energy.phase == .sampling {
                    Text("正在建立基线…")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.tertiaryText)
                } else if energy.phase == .ready, energy.window > 0 {
                    Text(String(format: "近 %.0f 秒", energy.window))
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.tertiaryText)
                }
            }

            switch energy.phase {
            case .unavailable:
                // 量纲回退：绝不在同一个表里混排 mW 与 %，整块换口径并说明
                ForEach(Array(stats.procCPU.prefix(5))) { item in
                    HStack(spacing: 7) {
                        Image(nsImage: BatteryEnergyIconCache.icon(for: item.iconPath, pid: item.pid))
                            .resizable()
                            .frame(width: 15, height: 15)
                        Text(item.name)
                            .font(.system(size: 11.5))
                            .lineLimit(1)
                        Spacer(minLength: 6)
                        Text(String(format: "%.0f%%", item.cpu))
                            .font(.system(size: 11.5, weight: .medium).monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                Text("当前系统不支持能耗计数，改按 CPU 活跃度显示（百分比与 mW 不是同一量纲，故不混排）。")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.tertiaryText)
                    .fixedSize(horizontal: false, vertical: true)
            case .idle, .sampling:
                if energy.items.isEmpty {
                    Text("正在采样…（约 1–2 秒）")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.tertiaryText)
                } else {
                    energyRows
                }
            case .ready:
                energyRows
            }

            if energy.phase == .ready || !energy.items.isEmpty {
                Text("按当前用户可见进程的 CPU 能耗计数排序，不等同于活动监视器的综合能耗影响（后者还含磁盘、网络等因素）。")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.tertiaryText)
                    .lineSpacing(1.4)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var energyRows: some View {
        ForEach(Array(energy.items.prefix(5))) { item in
            HStack(spacing: 7) {
                Image(nsImage: BatteryEnergyIconCache.icon(for: item.iconPath, pid: item.pid))
                    .resizable()
                    .frame(width: 15, height: 15)
                Text(item.name)
                    .font(.system(size: 11.5))
                    .lineLimit(1)
                Spacer(minLength: 6)
                Text(BatteryEnergySampler.wattsText(item.watts))
                    .font(.system(size: 11.5, weight: .medium).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: 低电量模式

    private var lowPowerRow: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Text("低电量模式")
                    .font(.system(size: 11.5))
                if lowPower.busy {
                    ProgressView()
                        .controlSize(.mini)
                        .scaleEffect(0.7)
                }
                Spacer(minLength: 6)
                Toggle("", isOn: Binding(
                    get: { lowPower.enabled },
                    set: { lowPower.set($0) }))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .disabled(lowPower.busy)
                    .help("切换需要管理员授权（macOS 限制：修改电源策略必须提权）")
            }
            if let hint = lowPower.hint {
                Text(hint)
                    .font(.system(size: 10))
                    .foregroundStyle(Color.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: 充电状态 + 入口

    private func chargeRow(_ battery: StatsBattery?, _ stats: StatsSnapshot) -> some View {
        HStack(spacing: 6) {
            Text(chargeText(battery, stats))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer(minLength: 4)
        }
    }

    private var linksRow: some View {
        VStack(alignment: .leading, spacing: 5) {
            Button {
                if let url = URL(string: "x-apple.systempreferences:com.apple.Battery-Settings.extension") {
                    NSWorkspace.shared.open(url)
                }
            } label: {
                Text("打开系统电源设置")
                    .font(.system(size: 11))
            }
            .buttonStyle(.link)

            Button {
                SettingsWindowController.shared.open(pane: "monitor")
            } label: {
                Text("打开应用电池设置")
                    .font(.system(size: 11))
            }
            .buttonStyle(.link)
        }
    }

    // MARK: 文案

    private func chargeText(_ battery: StatsBattery?, _ stats: StatsSnapshot) -> String {
        guard let battery, battery.present else { return "电源：未检测到电池" }
        if battery.fullyCharged { return "已充满 · 已接电源" }
        if battery.isCharging {
            let remain = StatsFormat.remaining(stats.batteryRemainSec)
            return remain == "—" ? "正在充电" : "正在充电 · 预计 \(remain) 充满"
        }
        if battery.externalConnected { return "已接电源（未在充电）" }
        let remain = StatsFormat.remaining(stats.batteryRemainSec)
        return remain == "—" ? "电池供电中" : "电池供电 · 剩余 \(remain)"
    }

    private func statusText(_ battery: StatsBattery?) -> String {
        guard let battery else { return "—" }
        if !battery.present { return "无电池" }
        if battery.isCharging { return "充电中" }
        if battery.fullyCharged && battery.externalConnected { return "已充满" }
        if battery.externalConnected { return "已接电源" }
        return "放电中"
    }

    private func batterySymbol(_ battery: StatsBattery?) -> String {
        let percent = battery?.percent ?? Int(((sampler.sample.batteryLevel ?? 0) * 100).rounded())
        if battery?.isCharging == true { return "battery.100percent.bolt" }
        switch percent {
        case ..<13: return "battery.0percent"
        case ..<38: return "battery.25percent"
        case ..<63: return "battery.50percent"
        case ..<88: return "battery.75percent"
        default:    return "battery.100percent"
        }
    }

    private func levelColor(_ battery: StatsBattery?) -> Color {
        if battery?.isCharging == true { return BatteryFlowPalette.charge }
        let percent = battery?.percent ?? 100
        if percent <= 10 { return Color(red: 0.95, green: 0.27, blue: 0.30) }
        if percent <= 20 { return Color(red: 0.95, green: 0.62, blue: 0.18) }
        return BatteryFlowPalette.system
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()
}

// MARK: - 功耗流向模型

enum BatteryFlowPalette {
    static let charge = Color(red: 0.28, green: 0.76, blue: 0.42)
    static let system = Color(red: 0.22, green: 0.55, blue: 0.95)
    static let discharge = Color(red: 0.95, green: 0.62, blue: 0.18)
}

struct BatteryFlowNode: Identifiable {
    let id: String
    let title: String
    let watts: Double
    let systemImage: String
    let color: Color
    /// false = 传感器没给读数（显示「—」，绝不补 0 W）
    let available: Bool
}

struct BatteryFlowModel {
    let input: BatteryFlowNode
    let branches: [BatteryFlowNode]

    init(battery: StatsBattery?) {
        guard let battery, battery.present else {
            input = BatteryFlowNode(id: "in", title: "充电器输入", watts: 0,
                                    systemImage: "powerplug.fill",
                                    color: BatteryFlowPalette.charge, available: false)
            branches = []
            return
        }

        let volts = battery.voltageMv / 1000
        let amps = battery.amperageMa / 1000
        let batteryFlowW = volts * amps      // >0 充入电池；<0 放电

        if battery.externalConnected {
            var inputW = battery.adapterPowerW
            if inputW <= 0 {
                // PDTR 读不到 → 充电电压 × 充电电流（官方同一条回退链）
                inputW = max(0, battery.chargingVoltageV * battery.chargingCurrentMa / 1000)
            }
            let chargeW = max(0, batteryFlowW)
            let systemW = inputW > 0 ? max(0, inputW - chargeW) : max(0, -batteryFlowW)

            input = BatteryFlowNode(id: "in", title: "充电器输入", watts: inputW,
                                    systemImage: "powerplug.fill",
                                    color: BatteryFlowPalette.charge,
                                    available: inputW > 0)

            var list: [BatteryFlowNode] = []
            if chargeW > 0.05 {
                list.append(BatteryFlowNode(id: "charge", title: "充入电池", watts: chargeW,
                                            systemImage: "battery.75percent",
                                            color: BatteryFlowPalette.charge, available: true))
            }
            list.append(BatteryFlowNode(id: "system", title: "系统供电", watts: systemW,
                                        systemImage: "desktopcomputer",
                                        color: BatteryFlowPalette.system,
                                        available: systemW > 0.05 || inputW > 0))
            branches = list
        } else {
            var dischargeW = abs(min(0, batteryFlowW))
            if dischargeW <= 0 { dischargeW = max(0, battery.batteryPowerW) }
            input = BatteryFlowNode(id: "in", title: "电池放电", watts: dischargeW,
                                    systemImage: "battery.50percent",
                                    color: BatteryFlowPalette.discharge,
                                    available: dischargeW > 0)
            branches = [BatteryFlowNode(id: "system", title: "系统供电", watts: dischargeW,
                                        systemImage: "desktopcomputer",
                                        color: BatteryFlowPalette.system,
                                        available: dischargeW > 0)]
        }
    }
}

// MARK: - 流向图

struct BatteryPowerFlowCard: View {
    let input: BatteryFlowNode
    let branches: [BatteryFlowNode]

    private let innerHeight: CGFloat = 116
    private let tileSpacing: CGFloat = 6
    private let maxBand: CGFloat = 34

    private var maxWatts: Double {
        max(0.001, max(input.watts, branches.reduce(0) { $0 + $1.watts }))
    }

    private func thickness(_ watts: Double) -> CGFloat {
        guard watts > 0 else { return 0 }
        return max(2, CGFloat(watts / maxWatts) * maxBand)
    }

    private var tileHeight: CGFloat {
        let n = max(1, branches.count)
        return (innerHeight - CGFloat(n - 1) * tileSpacing) / CGFloat(n)
    }

    var body: some View {
        HStack(spacing: 0) {
            inputTile
                .frame(width: 86)
            ribbonArea
                .frame(maxWidth: .infinity)
            VStack(spacing: tileSpacing) {
                ForEach(branches) { node in
                    branchTile(node)
                }
            }
            .frame(width: 132)
        }
        .frame(height: innerHeight)
        .padding(8)
        .background(cardBackground)
    }

    // 左侧：供电来源
    private var inputTile: some View {
        VStack(spacing: 2) {
            Image(systemName: input.systemImage)
                .font(.system(size: 11))
                .foregroundStyle(input.color)
                .padding(.bottom, 2)
            Text(input.available ? BatteryEnergySampler.wattsText(input.watts) : "—")
                .font(.system(size: 15, weight: .semibold).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.65)
            Text(input.title)
                .font(.system(size: 9.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.05))
        )
        .padding(.trailing, 6)
    }

    private func branchTile(_ node: BatteryFlowNode) -> some View {
        VStack(spacing: 1) {
            Image(systemName: node.systemImage)
                .font(.system(size: 10))
                .foregroundStyle(node.color)
            Text(node.available ? BatteryEnergySampler.wattsText(node.watts) : "—")
                .font(.system(size: 13.5, weight: .semibold).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.65)
            Text(node.title)
                .font(.system(size: 9.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(node.color.opacity(0.10))
        )
    }

    // 中间的流带：宽度按瓦数比例
    private var ribbonArea: some View {
        GeometryReader { geo in
            let h = geo.size.height
            let gap: CGFloat = 2
            let widths = branches.map { thickness($0.watts) }
            let total = widths.reduce(0, +) + gap * CGFloat(max(0, branches.count - 1))

            let bands: [(node: BatteryFlowNode, start: CGFloat, end: CGFloat, width: CGFloat)] = {
                var out: [(BatteryFlowNode, CGFloat, CGFloat, CGFloat)] = []
                var cursor = h / 2 - total / 2
                for (index, node) in branches.enumerated() {
                    let w = widths[index]
                    let endCenter = CGFloat(index) * (tileHeight + tileSpacing) + tileHeight / 2
                    out.append((node, cursor + w / 2, endCenter, w))
                    cursor += w + gap
                }
                return out
            }()

            ZStack {
                ForEach(bands.indices, id: \.self) { i in
                    let band = bands[i]
                    let bend: CGFloat = branches.count == 1
                        ? 6
                        : (i == 0 ? -4 : 4)
                    let shape = FlowRibbon(startCenter: band.start,
                                           endCenter: band.end,
                                           startThickness: band.width,
                                           endThickness: max(2, band.width * 0.88),
                                           bend: bend)
                    shape
                        .fill(LinearGradient(colors: [band.node.color.opacity(0.72),
                                                      band.node.color.opacity(0.42)],
                                             startPoint: .leading, endPoint: .trailing))
                        .overlay(
                            shape.stroke(band.node.color.opacity(0.22), lineWidth: 0.5)
                        )
                }
            }
        }
        .padding(.horizontal, 2)
    }

    private var cardBackground: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(LinearGradient(colors: [Color.primary.opacity(0.055),
                                              Color.primary.opacity(0.015)],
                                     startPoint: .top, endPoint: .bottom))
            // 参考图里那张极淡的坐标网格：只做背景纹理，不表达数据
            GeometryReader { geo in
                Path { p in
                    for i in 1...3 {
                        let y = geo.size.height * CGFloat(i) / 4
                        p.move(to: CGPoint(x: 10, y: y))
                        p.addLine(to: CGPoint(x: geo.size.width - 10, y: y))
                    }
                }
                .stroke(Color.primary.opacity(0.045), lineWidth: 0.5)
            }
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5)
        }
    }
}

/// 两条贝塞尔边围成的流带（宽度从 startThickness 渐变到 endThickness）。
/// `bend` 是控制点的纵向偏移：起点终点等高时（单分支）也能画出柔和的弧形，
/// 否则就是一整条直线方块，看起来像占位图而不是「能量在流」。
struct FlowRibbon: Shape {
    var startCenter: CGFloat
    var endCenter: CGFloat
    var startThickness: CGFloat
    var endThickness: CGFloat
    var bend: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        let x0 = rect.minX, x1 = rect.maxX
        let s0 = startCenter - startThickness / 2
        let s1 = startCenter + startThickness / 2
        let e0 = endCenter - endThickness / 2
        let e1 = endCenter + endThickness / 2

        var p = Path()
        p.move(to: CGPoint(x: x0, y: s0))
        p.addCurve(to: CGPoint(x: x1, y: e0),
                   control1: CGPoint(x: x0 + rect.width * 0.45, y: s0 + bend),
                   control2: CGPoint(x: x1 - rect.width * 0.35, y: e0 + bend))
        p.addLine(to: CGPoint(x: x1, y: e1))
        p.addCurve(to: CGPoint(x: x0, y: s1),
                   control1: CGPoint(x: x1 - rect.width * 0.35, y: e1 + bend),
                   control2: CGPoint(x: x0 + rect.width * 0.45, y: s1 + bend))
        p.closeSubpath()
        return p
    }
}

// MARK: - 明细行

private struct BatteryDetailRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
            Spacer(minLength: 6)
            Text(value)
                .font(.system(size: 11.5, weight: .medium).monospacedDigit())
                .lineLimit(1)
        }
    }
}

// MARK: - 图标缓存

enum BatteryEnergyIconCache {
    private static let cache = NSCache<NSString, NSImage>()

    /// 取应用图标。三级兜底（实测：部分 helper 进程 proc_pidpath 拿不到路径，
    /// 只靠 iconPath 会退化成一张通用白图标——用户看到的就是「图标是空白的」）：
    ///   1. `.app` bundle 路径 → NSWorkspace（最准，含用户自定义图标）
    ///   2. NSRunningApplication(pid).bundleURL → 同进程的宿主 App
    ///   3. 通用应用图标
    static func icon(for path: String, pid: Int32) -> NSImage {
        let key = (path.isEmpty ? "pid:\(pid)" : path) as NSString
        if let hit = cache.object(forKey: key) { return hit }

        let image: NSImage
        if path.hasSuffix(".app"), FileManager.default.fileExists(atPath: path) {
            image = NSWorkspace.shared.icon(forFile: path)
        } else if let app = NSRunningApplication(processIdentifier: pid),
                  let bundleURL = app.bundleURL {
            image = NSWorkspace.shared.icon(forFile: bundleURL.path)
        } else if !path.isEmpty, FileManager.default.fileExists(atPath: path) {
            image = NSWorkspace.shared.icon(forFile: path)
        } else {
            image = NSWorkspace.shared.icon(for: .application)
        }
        cache.setObject(image, forKey: key)
        return image
    }
}

// MARK: - 低电量模式（读 ProcessInfo，写走 pmset 提权）

/// 低电量模式的读写。
///
/// 读：`ProcessInfo.isLowPowerModeEnabled`（系统通知驱动，零轮询）。
/// 写：macOS **没有**公开的切换 API，`pmset` 改电源策略必须 root。
///     所以这里走一次 `osascript … with administrator privileges`，
///     用户在系统弹窗里授权后立即生效；取消授权则开关按系统真实状态回滚，
///     不给「看起来开了其实没开」的假象。
///
/// 与 Status Trio 的差别：它装了一个常驻特权 helper 来免密切换；我们不做常驻
/// 提权组件（安全代价大于收益），改为「每次切换弹一次系统授权」。
@MainActor
public final class LowPowerModeController: ObservableObject {
    public static let shared = LowPowerModeController()

    @Published public private(set) var enabled = ProcessInfo.processInfo.isLowPowerModeEnabled
    @Published public private(set) var busy = false
    @Published public private(set) var hint: String?

    private var observer: NSObjectProtocol?
    private var hintClear: DispatchWorkItem?

    private init() {
        observer = NotificationCenter.default.addObserver(
            forName: .NSProcessInfoPowerStateDidChange,
            object: nil,
            queue: .main) { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            }
    }

    public func refresh() {
        enabled = ProcessInfo.processInfo.isLowPowerModeEnabled
    }

    public func set(_ on: Bool) {
        guard !busy, on != enabled else { return }
        busy = true
        hint = nil

        let script = "do shell script \"/usr/bin/pmset -a lowpowermode \(on ? 1 : 0)\" with administrator privileges"
        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", script]
            let errPipe = Pipe()
            process.standardError = errPipe
            process.standardOutput = Pipe()

            var ok = false
            var message = ""
            do {
                try process.run()
                process.waitUntilExit()
                ok = process.terminationStatus == 0
                if !ok {
                    let data = errPipe.fileHandleForReading.readDataToEndOfFile()
                    message = String(data: data, encoding: .utf8) ?? ""
                }
            } catch {
                message = error.localizedDescription
            }

            DispatchQueue.main.async {
                self.busy = false
                self.refresh()
                if !ok {
                    let cancelled = message.contains("-128") || message.contains("User canceled")
                    self.flash(cancelled ? "已取消授权，低电量模式未改变"
                                         : "切换失败：需要管理员授权")
                }
            }
        }
    }

    private func flash(_ text: String) {
        hint = text
        hintClear?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.hint = nil }
        hintClear = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 6, execute: work)
    }
}
