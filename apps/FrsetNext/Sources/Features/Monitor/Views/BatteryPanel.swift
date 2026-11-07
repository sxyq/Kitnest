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
    @ObservedObject private var lowPower = LowPowerModeController.shared

    var body: some View {
        let stats = StatsDataProvider.shared.current
        let battery = stats.battery

        return VStack(alignment: .leading, spacing: 12) {
            if battery?.present != true && (sampler.sample.batteryLevel ?? -1) < 0 {
                noBatteryNotice
            } else {
                // v190（用户：「充电不需要单开这个界面，功能并到功耗和电池」）：
                // 电量环 / 充放电状态 / 预计时间 / 适配器规格都并到本页；
                // 电源流向图与整机功率仍在「功耗」页，不再各画一张。
                hero(battery, stats)
                healthCard(battery, stats)
                electricalCard(battery, stats)
                if battery?.externalConnected == true {
                    adapterRow(battery)
                }
                lowPowerRow
                hint(battery)
                linksRow
            }
        }
    }

    // MARK: 顶部：电量环 + 充放电状态

    private func hero(_ battery: StatsBattery?, _ stats: StatsSnapshot) -> some View {
        let percent = battery?.percent
            ?? Int(((sampler.sample.batteryLevel ?? 0) * 100).rounded())
        let charging = battery?.isCharging == true
        let connected = battery?.externalConnected == true
        let color = charging ? BatteryFlowPalette.charge
            : (connected ? MonitorColors.download : BatteryFlowPalette.discharge)

        return HStack(spacing: 14) {
            ZStack {
                MonitorRing(value: min(1, max(0, Double(percent) / 100)),
                            lineWidth: 8, color: color)
                    .frame(width: 74, height: 74)
                VStack(spacing: 0) {
                    Text("\(percent)%")
                        .font(.system(size: 20, weight: .semibold).monospacedDigit())
                    Text(charging ? "充电中" : "电量")
                        .font(.system(size: 9.5))
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(headline(battery))
                    .font(.system(size: 14, weight: .semibold))
                Text(subline(battery, stats))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    private func headline(_ battery: StatsBattery?) -> String {
        guard let battery else { return "状态未知" }
        if battery.isCharging { return "正在充电" }
        if battery.fullyCharged && battery.externalConnected { return "已充满" }
        if battery.externalConnected { return "已接电源（未充电）" }
        return "电池供电"
    }

    private func subline(_ battery: StatsBattery?, _ stats: StatsSnapshot) -> String {
        let remain = StatsFormat.remaining(stats.batteryRemainSec)
        if battery?.isCharging == true {
            return remain == "—" ? "系统正在供电并充电" : "预计 \(remain) 充满"
        }
        if battery?.fullyCharged == true, battery?.externalConnected == true { return "已充满，系统已停止充电" }
        if battery?.externalConnected == true { return "已接电源，系统暂缓充电或已到充电上限" }
        return remain == "—" ? "未接电源" : "预计还可使用 \(remain)"
    }

    /// 适配器规格（只在接电时出现）：额定功率 / 充电电压 / 充电电流
    private func adapterRow(_ battery: StatsBattery?) -> some View {
        let volts = battery?.chargingVoltageV ?? 0
        let amps = (battery?.chargingCurrentMa ?? 0) / 1000
        return HStack(spacing: 12) {
            if let rated = battery?.adapterWatts, rated > 0 {
                spec("适配器额定", String(format: "%.0f W", rated))
            }
            if volts > 0 {
                spec("充电电压", String(format: "%.2f V", volts))
            }
            if amps > 0 {
                spec("充电电流", String(format: "%.2f A", amps))
            }
            Spacer(minLength: 0)
        }
    }

    private func spec(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(.system(size: 9.5))
                .foregroundStyle(Theme.tertiaryText)
            Text(value)
                .font(.system(size: 12, weight: .medium).monospacedDigit())
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 与当前充放电状态相关的提示（原来在充电页）
    private func hint(_ battery: StatsBattery?) -> some View {
        let text: String
        if battery?.isCharging == true, (battery?.percent ?? 0) >= 80 {
            text = "电量已接近满，系统会自动降低充电功率（涓流充电）以保护电池寿命。"
        } else if battery?.isCharging == true {
            text = "充电过程中电池温度会略高于平时，属正常现象；温度过高时系统会暂缓充电。"
        } else if battery?.externalConnected == true {
            text = "已接电源但当前没有充电：可能是电量已满，或系统为保护电池暂缓充电。"
        } else {
            text = "使用电池时，降低屏幕亮度、关闭后台高耗电 App 可以延长续航。"
        }
        return Text(text)
            .font(.system(size: 10.5))
            .foregroundStyle(Theme.tertiaryText)
            .lineSpacing(1.6)
            .fixedSize(horizontal: false, vertical: true)
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
            // v216：删掉「台式机（Mac mini / Studio / Pro）没有内置电池…」解释句。
        }
    }

    // MARK: 明细

    // MARK: 健康（容量 / 循环）

    /// 健康度 = 满充容量 / 标称（额定）容量——与 macOS「系统设置 → 电池 → 电池健康」同口径。
    ///
    /// v260 修正：旧版除以**设计容量**（DesignCapacity 含保留裕量，通常比标称大 10%），
    /// 同一块电池这里显示 88%、系统显示 97%，用户一对照就认定「检测不准」。
    /// 标称容量拿不到时才回退设计容量，并在下面的明细里写明两个口径。
    private func healthRatio(_ battery: StatsBattery?) -> Double? {
        guard let battery, battery.present, battery.maxCapacity > 0 else { return nil }
        let denominator = battery.nominalCapacity > 0
            ? battery.nominalCapacity : battery.designCapacity
        guard denominator > 0 else { return nil }
        let ratio = Double(battery.maxCapacity) / Double(denominator)
        guard ratio.isFinite, ratio > 0 else { return nil }
        return min(1.2, ratio)
    }

    /// 副口径：满充容量 / 设计容量（coconutBattery 等第三方工具的算法）
    private func designHealthRatio(_ battery: StatsBattery?) -> Double? {
        guard let battery, battery.present, battery.designCapacity > 0,
              battery.maxCapacity > 0 else { return nil }
        let ratio = Double(battery.maxCapacity) / Double(battery.designCapacity)
        guard ratio.isFinite, ratio > 0 else { return nil }
        return min(1.2, ratio)
    }

    private func healthColor(_ ratio: Double?) -> Color {
        guard let ratio else { return .secondary }
        if ratio < 0.80 { return Color(red: 0.90, green: 0.25, blue: 0.28) }
        if ratio < 0.90 { return Color(red: 0.95, green: 0.62, blue: 0.18) }
        return BatteryFlowPalette.charge
    }

    private func healthCard(_ battery: StatsBattery?, _ stats: StatsSnapshot) -> some View {
        let health = healthRatio(battery)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 9) {
                Image(systemName: "heart.text.square")
                    .font(.system(size: 15))
                    .foregroundStyle(healthColor(health))
                VStack(alignment: .leading, spacing: 1) {
                    Text("电池健康")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Text(health.map { "\(Int(($0 * 100).rounded()))%" } ?? "—")
                        .font(.system(size: 18, weight: .semibold).monospacedDigit())
                        .foregroundStyle(healthColor(health))
                }
                Spacer(minLength: 6)
                // v260：键缺失时 C 层填 0，旧版会显示「循环 0 次」这种假数据
                if let battery, battery.present, battery.cycleCount > 0 {
                    Text("循环 \(battery.cycleCount) 次")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            if let health {
                MonitorStackedBar(segments: [
                    .init(id: "health", value: health * 100, color: healthColor(health)),
                    .init(id: "wear", value: max(0, 100 - health * 100),
                          color: Color.primary.opacity(0.10))
                ], height: 8)
            }
            if let battery, battery.present {
                // v260：三个容量各占一行并写清名称——原来一行写
                // 「当前最大容量 4056 mAh / 4629 mAh」，第二个数是设计容量，
                // 没有任何标签，用户只能自己猜，也没法判断哪个才是「最大容量」。
                if battery.maxCapacity > 0 {
                    BatteryDetailRow(label: "满充容量",
                                     value: StatsFormat.capacity(battery.maxCapacity))
                }
                if battery.nominalCapacity > 0 {
                    BatteryDetailRow(label: "标称容量（健康度分母）",
                                     value: StatsFormat.capacity(battery.nominalCapacity))
                }
                if battery.designCapacity > 0 {
                    BatteryDetailRow(label: "设计容量",
                                     value: StatsFormat.capacity(battery.designCapacity))
                }
                // v260：库仑计剩余电荷与系统 SoC 百分比不是同一口径，
                // 并排写「100% / 3965 mAh」会让人一除就觉得数据错。
                if battery.currentCapacity > 0 {
                    BatteryDetailRow(label: "剩余电荷（库仑计）",
                                     value: StatsFormat.capacity(battery.currentCapacity))
                }
                // 两个口径差得多时并列给出，取整方式与大字号统一为四舍五入，
                // 不再出现「大字号 88%、小字 87%」「97% 被截成 96%」的自相矛盾。
                if let nominal = healthRatio(battery),
                   let design = designHealthRatio(battery),
                   abs(nominal - design) > 0.005 {
                    Text("按标称容量计 \(Int((nominal * 100).rounded()))%（系统设置口径）；"
                         + "按设计容量计 \(Int((design * 100).rounded()))%（第三方工具口径）。"
                         + "剩余电荷为库仑计原始读数，不能直接除以满充容量当电量百分比。")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.tertiaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            // 这是 UI 刷新时刻，不是电池数据的时间戳
            BatteryDetailRow(label: "最近刷新",
                             value: Self.timeFormatter.string(from: stats.updatedAt))
        }
    }

    // MARK: 电气（电压 / 电流 / 功率 / 温度）

    private func electricalCard(_ battery: StatsBattery?, _ stats: StatsSnapshot) -> some View {
        let flow = BatteryFlowModel(battery: battery)
        let batteryPower = flow.branches.first(where: { $0.id == "charge" })?.watts
            ?? (battery?.externalConnected == false ? flow.input.watts : nil)
        return VStack(alignment: .leading, spacing: 8) {
            MonitorSectionTitle("电池状态")
            if let battery, battery.present {
                BatteryDetailRow(label: "电压",
                                 value: String(format: "%.2f V", battery.voltageMv / 1000))
                BatteryDetailRow(label: "电流",
                                 value: String(format: "%.2f A", battery.amperageMa / 1000))
                if let batteryPower, batteryPower > 0 {
                    BatteryDetailRow(label: battery.externalConnected ? "充入功率" : "放电功率",
                                     value: BatteryEnergySampler.wattsText(batteryPower))
                }
                if battery.temperature > 0 {
                    BatteryDetailRow(label: "电池温度",
                                     value: String(format: "%.1f °C", battery.temperature))
                }
            }
            // v216：删掉「电量、充放电状态…已并入本页…」导航说明。
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

    // MARK: 入口

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
            // v183（用户：「输入和支出要分开看，要有分流图」）：接电时**始终**画出
            // 「充入电池」这条分支，充满/暂缓充电时它就是 0 W——不画的话整张图只剩
            // 一条直线，看不出「输入被分成两份」的结构。
            // 只有在连电压读数都没有（电气数据缺失）时才不画，避免把「读不到」说成 0。
            if battery.voltageMv > 0 {
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


private extension BatteryFlowNode {
    /// 电池流向节点 → 通用流向节点（数值文本沿用 BatteryEnergySampler 的瓦特格式）
    @MainActor var monitorNode: MonitorFlowNode {
        MonitorFlowNode(id: id,
                        title: title,
                        value: watts,
                        valueText: available ? BatteryEnergySampler.wattsText(watts) : "—",
                        systemImage: systemImage,
                        color: color,
                        available: available)
    }
}

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
                .fixedSize(horizontal: true, vertical: false)
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
