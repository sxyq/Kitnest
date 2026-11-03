import AppKit
import CoreServices
import SwiftUI

// MARK: - 原版 Stats 模块面板（性能监测页正文，1:1 版式）
//
// 版式依据：/tmp/o_cpu*.png、o_mem.png、o_gpu.png、o_disk.png、o_network.png、
// o_sensor.png（2026-10-17 原版 Frset 1.3.12 实机逐标签截图，400×700 面板）。
//
// 与旧 MonitorDetailView（292 宽 popover 版）并存：
//   · 性能页（400 宽，StatsPageView）→ 本文件的 StatsModulePage
//   · 菜单栏模块状态项 popover（292 宽）→ 旧 MonitorDetailView
//
// 版式要点（逐项对照原版）：
//   分段环 = 红(系统)/蓝(用户)/灰(空闲)，中心大号百分比 + 小字说明；
//   分区标题 = 居中文字 + 两侧细线；键值行 = 左标签灰 12 / 右数值 13 等宽；
//   进程表 = 表头「进程 / 用量」+ 行（应用图标 + 名称 + 右值）。

public struct StatsModulePage: View {
    public let module: MonitorModuleID

    public init(module: MonitorModuleID) {
        self.module = module
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch module {
            case .cpu, .power: CPUStatsPanel()
            case .memory: MemoryStatsPanel()
            case .gpu: GPUStatsPanel()
            case .disk: DiskStatsPanel()
            case .network: NetworkStatsPanel()
            case .sensors: SensorsStatsPanel()
            case .battery: BatteryStatsPanel()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - 通用组件

/// 环形进度（单色 / 分段）。原版线宽约 9pt（90pt 环）、7pt（60pt 环）。
struct StatsRing: View {
    var segments: [(value: Double, color: Color)]
    var lineWidth: CGFloat = 9
    var trackOpacity: Double = 0.12

    init(segments: [(value: Double, color: Color)], lineWidth: CGFloat = 9, trackOpacity: Double = 0.12) {
        self.segments = segments
        self.lineWidth = lineWidth
        self.trackOpacity = trackOpacity
    }

    init(value: Double, color: Color, lineWidth: CGFloat = 9) {
        self.segments = [(max(0, min(1, value)), color)]
        self.lineWidth = lineWidth
        self.trackOpacity = 0.12
    }

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            let center = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
            ZStack {
                // v84（用户反馈「环状图左侧与上侧截断」）：SwiftUI 的 stroke 居中于路径，
                // Circle 路径取 bounds 内接圆 → 描边有 lineWidth/2 画到 frame 外被裁。
                // 路径按半个线宽内缩，描边完全落在 frame 内（外径不变）。
                Circle()
                    .inset(by: lineWidth / 2)
                    .stroke(Color.primary.opacity(trackOpacity), lineWidth: lineWidth)
                ForEach(Array(segments.enumerated()), id: \.offset) { index, segment in
                    let start = segments.prefix(index).reduce(0) { $0 + max(0, $1.value) }
                    Circle()
                        .inset(by: lineWidth / 2)
                        .trim(from: max(0, min(1, start)),
                              to: max(0, min(1, start + segment.value)))
                        .stroke(segment.color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .butt))
                        .rotationEffect(.degrees(-90))
                }
            }
            .frame(width: side, height: side)
            .position(x: center.x, y: center.y)
            // v85（2026-10-20 设置页卡死根因）：此处在 GeometryReader 闭包内用
            // .environment 注入「基于 geo.size 计算出的 radius」——environment 变更
            // 会重新求值整棵子树，子树又读 geo.size，形成 render→layout→render 死循环
            // （实测 sample 栈：GeometryReader.Child.updateValue → GeometryProxy.size.getter
            //  无限递归，主线程阻塞 60s+ 只能强杀）。该 environment 键零消费方，直接移除。
        }
    }
}

/// 内存页左侧的半圆仪表（绿→黄→红 + 指针 + 下方状态文字）。
struct StatsHalfGauge: View {
    /// 0...1
    var value: Double
    var caption: String
    var captionColor: Color = .secondary

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let lineWidth: CGFloat = 8
            let radius = min(w / 2, h) - lineWidth / 2
            let center = CGPoint(x: w / 2, y: h - 4)
            ZStack {
                // 三段底色：绿 / 黄 / 红
                ForEach(Array(gaugeSegments.enumerated()), id: \.offset) { index, seg in
                    Path { path in
                        path.addArc(center: center, radius: radius,
                                    startAngle: .degrees(180 + seg.start * 180),
                                    endAngle: .degrees(180 + seg.end * 180),
                                    clockwise: false)
                    }
                    .stroke(seg.color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .butt))
                    .opacity(index == gaugeIndex ? 1 : 0.35)
                }
                // 指针
                Path { path in
                    path.move(to: center)
                    let angle = Angle.degrees(180 + max(0, min(1, value)) * 180)
                    path.addLine(to: CGPoint(x: center.x + cos(angle.radians) * (radius - 2),
                                             y: center.y + sin(angle.radians) * (radius - 2)))
                }
                .stroke(Color.primary.opacity(0.85), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                Circle()
                    .fill(Color.primary.opacity(0.85))
                    .frame(width: 5, height: 5)
                    .position(center)
            }
        }
        .overlay(alignment: .bottom) {
            Text(caption)
                .font(.system(size: 11))
                .foregroundStyle(captionColor)
                .offset(y: 14)
        }
    }

    private var gaugeSegments: [(start: Double, end: Double, color: Color)] {
        [
            (0.0, 0.5, Color(red: 0.30, green: 0.78, blue: 0.35)),
            (0.5, 0.75, Color(red: 0.96, green: 0.80, blue: 0.20)),
            (0.75, 1.0, Color(red: 0.92, green: 0.26, blue: 0.28))
        ]
    }

    private var gaugeIndex: Int {
        if value < 0.5 { return 0 }
        if value < 0.75 { return 1 }
        return 2
    }
}

/// 图例行：色点 + 标签 +（可选）右侧数值
struct StatsLegendRow: View {
    var color: Color
    var label: String
    var value: String
    var valueColor: Color = .primary
    var showsDot: Bool = true

    var body: some View {
        HStack(spacing: 8) {
            if showsDot {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(color)
                    .frame(width: 9, height: 9)
            }
            Text(label)
                .font(.system(size: 13))
                .foregroundStyle(showsDot ? .primary : .secondary)
                .lineLimit(1)
            Spacer(minLength: 6)
            Text(value)
                .font(.system(size: 13, weight: .medium).monospacedDigit())
                .foregroundStyle(valueColor)
                .lineLimit(1)
        }
    }
}

/// 面积图（原版「负载历史 / 使用历史 / 速率历史」用）：细线 + 渐变填充。
struct StatsHistoryChart: View {
    var values: [Double]
    var color: Color
    var upperBound: Double? = nil
    var height: CGFloat = 74

    var body: some View {
        MonitorAreaSparkline(values: values, color: color, upperBound: upperBound)
            .padding(.horizontal, 4)
            .padding(.vertical, 6)
            .glassCard(radius: 6)
            .frame(height: height)
    }
}

/// 双线图（网络/磁盘读写历史）。
struct StatsHistoryDualChart: View {
    var primaryValues: [Double]
    var secondaryValues: [Double]
    var primaryColor: Color
    var secondaryColor: Color
    var height: CGFloat = 74

    var body: some View {
        ZStack {
            MonitorAreaSparkline(values: primaryValues, color: primaryColor)
            MonitorSparkline(values: secondaryValues)
                .stroke(secondaryColor, style: StrokeStyle(lineWidth: 1.4, lineCap: .round))
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 6)
        .glassCard(radius: 6)
        .frame(height: height)
    }
}

/// 进程表（原版「高占用进程」）：表头 + 行（应用图标 + 名称 + 右侧一/两列数值）
///
/// v84（用户需求「归类 + 展开 + 图标 + 退出」）：
/// · 归类：数据层已按 App 合并（Helper/Renderer 归到宿主），行显示「名称 + N 个进程」；
/// · 展开：点击行展开组内子进程明细（按当前维度降序，第一行即「占得最多」的那个）；
/// · 退出：右键（或长按）行 → 菜单「退出 xxx」，结束整组全部 pid；
/// · 图标：StatsAppIcon 按 App 名解析真实 bundle 图标。
struct StatsProcTable: View {
    struct Column {
        var title: String
        var color: Color?
    }

    var title: String
    var columns: [Column]
    var items: [StatsProcItem]
    var subtitle: (StatsProcItem) -> String? = { _ in nil }
    var values: (StatsProcItem) -> [String]
    /// 展开行的数值格式（子进程用）——默认与主行相同
    var childValues: ((StatsProcItem) -> [String])? = nil

    /// 已展开的组（按 bundle 路径/进程名标识——pid 会随排序变化，不能当键）
    @Stored private var expandedIDs: Set<String> = []

    /// 数值列宽：单列 86（对齐原版），双列各 64——否则 380 宽窗里名字只剩 5~6 个字符
    private var columnWidth: CGFloat { columns.count > 1 ? 64 : 86 }

    private func childValueTexts(_ child: StatsProcItem) -> [String] {
        if let childValues { return childValues(child) }
        return values(child)
    }

    /// 子进程显示名：去掉与组名重复的前缀，让「哪个 Helper 占得多」一眼可辨。
    /// 「Microsoft Edge Helper (Renderer)」→「Helper (Renderer)」；主进程本身 → 「主进程」。
    private func childLabel(_ child: StatsProcItem, group: String) -> String {
        var name = child.name
        if name == group { return "主进程" }
        if name.hasPrefix(group) {
            name = String(name.dropFirst(group.count)).trimmingCharacters(in: .whitespaces)
            while name.hasPrefix("-") || name.hasPrefix("—") {
                name = String(name.dropFirst()).trimmingCharacters(in: .whitespaces)
            }
        }
        return name.isEmpty ? child.name : name
    }

    var body: some View {
        VStack(spacing: 6) {
            MonitorSectionTitle(title)
            HStack(spacing: 8) {
                Text("进程")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
                ForEach(Array(columns.enumerated()), id: \.offset) { _, column in
                    if let color = column.color {
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(color)
                            .frame(width: 9, height: 9)
                            .frame(width: columnWidth, alignment: .trailing)
                    } else {
                        Text(column.title)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .frame(width: columnWidth, alignment: .trailing)
                    }
                }
            }
            ForEach(items) { item in
                let expandable = !item.children.isEmpty
                let expanded = expandedIDs.contains(item.groupKey)
                // v129（内存）：values(item) 每行只算一次——原实现 body 求值里调 3 次
                //（数值列 / onTapGesture / contextMenu 各一次），每次返回新建 [String] +
                // N 个格式化字符串。tick 驱动的重绘下（1~2s 一帧 ×4 表×8 行）是
                // 32B/48B 小块（malloc 直方图峰值）的稳定churn 源之一。
                let rowValues = values(item)
                VStack(spacing: 4) {
                    HStack(spacing: 8) {
                        // 展开指示：可展开组显示 chevron，单进程组留空占位（不再用 3pt 圆点）
                        Group {
                            if expandable {
                                Image(systemName: expanded ? "chevron.down" : "chevron.right")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(Theme.tertiaryText)
                            } else {
                                Color.clear
                            }
                        }
                        .frame(width: 8)
                        StatsAppIcon(name: item.name, path: item.iconPath, size: 16)
                        Text(item.name)
                            .font(.system(size: 12))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if let note = subtitle(item), !note.isEmpty {
                            Text(note)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .fixedSize()
                        }
                        if expandable, !expanded {
                            Text("\(item.children.count) 进程")
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.tertiaryText)
                                .fixedSize()
                        }
                        Spacer(minLength: 4)
                        // v129（内存）：indices 遍历替代 Array(enumerated())——
                        // 后者每帧为每行建 [(offset, element)] 元组数组（48B 级小块）。
                        ForEach(rowValues.indices, id: \.self) { i in
                            Text(rowValues[i])
                                .font(.system(size: 12).monospacedDigit())
                                .lineLimit(1)
                                .frame(width: columnWidth, alignment: .trailing)
                        }
                        // v84：显式退出按钮（右键菜单之外的直达入口；整组 pid 一并结束）
                        Button {
                            StatsProcQuitter.confirmAndQuit(item: item)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(Color.secondary.opacity(0.5))
                        }
                        .buttonStyle(.plain)
                        .help("退出 \(item.name)（\(item.pids.count) 个进程）")
                    }
                    .contentShape(Rectangle())
                    // v84：点击展开/收起（原 v71 是点开菜单；退出改走右键，避免误触）
                    .onTapGesture {
                        guard expandable else {
                            ProcMenuPresenter.shared.present(for: item, values: rowValues, at: NSEvent.mouseLocation)
                            return
                        }
                        if expanded { expandedIDs.remove(item.groupKey) } else { expandedIDs.insert(item.groupKey) }
                    }
                    .contextMenu { StatsProcContextMenu(item: item, values: rowValues) }

                    // 展开：组内子进程明细（缩进 + 小字号 + 同列对齐）
                    if expanded, expandable {
                        ForEach(item.children) { child in
                            // v129（内存）：同上，childValueTexts 每行只算一次 + indices 遍历
                            let childTexts = childValueTexts(child)
                            HStack(spacing: 8) {
                                Color.clear.frame(width: 8)
                                Color.clear.frame(width: 16)
                                Text(childLabel(child, group: item.name))
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer(minLength: 4)
                                ForEach(childTexts.indices, id: \.self) { i in
                                    Text(childTexts[i])
                                        .font(.system(size: 11).monospacedDigit())
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                        .frame(width: columnWidth, alignment: .trailing)
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

/// 进程图标（v86 重写）：按**可执行路径**取宿主 App 图标，路径为空时才回落到名字。
///
/// 旧实现的问题（用户反馈「图标并没有正确展现」）：
///   · 按进程名查硬编码表 + 异步扫 /Applications 建索引 → 首次渲染必然落空，
///     而落空结果被永久写进缓存（`cache[name] = 通用图标`），索引就绪后也再也不刷新；
///   · 归类键是「进程名去 Helper/括号」，与真实 App 无绑定，同名不同 App 会串图标。
/// 现在：归类与图标同源——C 层给出的可执行路径截取 `.app`，NSWorkspace 直接取宿主图标，
/// 不依赖任何名字猜测，也不存在「先落空后不刷新」。缓存键 = 路径，一次解析终身复用。
struct StatsAppIcon: View {
    var name: String
    /// 宿主 `.app` 路径，或（无 bundle 的进程）可执行文件路径
    var path: String = ""
    var size: CGFloat = 16

    var body: some View {
        Group {
            if let icon = Self.cachedIcon(path: path, name: name) {
                Image(nsImage: icon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                // 连可执行路径都拿不到（内核进程等）——保持原版观感：深灰圆角方块
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(Color.primary.opacity(0.82))
            }
        }
        .frame(width: size, height: size)
    }

    /// 路径 → 图标缓存（只缓存成功结果；失败不写缓存，避免「一次落空、永不刷新」）
    // v129（内存）：原无界 [String: NSImage] 字典按进程可执行路径无限增长——
    // NSWorkspace 图标是多分辨率位图 NSImage（内部 CGImage 底座属 non-object 原始块，
    // heap：__DataStorage/位图底座随缓存条目线性驻留），FRSET_PROC_CAP=512 下
    // 采样会路过数百个不同路径。改 NSCache + countLimit=192（可视行 ~40 个，
    // 4 轮滚动余量），内存压力下自动淘汰。NSCache 线程安全，原 NSLock 一并去掉。
    private static let cache: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>()
        c.countLimit = 192
        return c
    }()

    static func cachedIcon(path: String, name: String) -> NSImage? {
        let key = (path.isEmpty ? "name:" + name : path) as NSString
        if let hit = cache.object(forKey: key) { return hit }

        var icon: NSImage?
        if !path.isEmpty, FileManager.default.fileExists(atPath: path) {
            icon = NSWorkspace.shared.icon(forFile: path)
        } else if !name.isEmpty {
            // 兜底：仅当拿不到路径时，才用名字在运行中的 App 里找同名 bundle
            icon = NSWorkspace.shared.runningApplications
                .first { ($0.localizedName ?? "") == name }
                .flatMap { $0.bundleURL?.path }
                .map { NSWorkspace.shared.icon(forFile: $0) }
        }
        guard let image = icon else { return nil }
        image.size = NSSize(width: 32, height: 32)   // 32pt 源图，16pt 显示更锐利（Retina）
        cache.setObject(image, forKey: key)
        return image
    }
}

/// 进程菜单（v71：用户需求「进程可点击→选择退出」）：点击行以 NSMenu 在鼠标位置弹出，
/// 右键走 SwiftUI contextMenu（同一菜单构造）。退出 = SIGTERM 全部合并 pid。
final class ProcMenuPresenter: NSObject {
    static let shared = ProcMenuPresenter()

    /// 在屏幕坐标处弹出菜单（onTapGesture 点击路径）
    func present(for item: StatsProcItem, values: [String], at screenPoint: NSPoint) {
        let menu = buildMenu(item: item, values: values)
        menu.popUp(positioning: nil, at: screenPoint, in: nil)
    }

    /// 构建菜单（含 target-action 退出项；菜单持有 item → 关闭后释放）
    func buildMenu(item: StatsProcItem, values: [String]) -> NSMenu {
        let menu = NSMenu()
        let pidText = item.pids.count > 1 ? "\(item.pids.count) 个进程 · PID \(item.pids.map(String.init).joined(separator: ", "))"
                                         : "PID \(item.pid)"
        let info = NSMenuItem(title: "\(item.name) · \(pidText) · \(values.joined(separator: " · "))",
                              action: nil, keyEquivalent: "")
        info.isEnabled = false
        menu.addItem(info)
        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "退出 \(item.name)",
                                  action: #selector(quit(_:)),
                                  keyEquivalent: "")
        quitItem.target = self
        quitItem.representedObject = item
        menu.addItem(quitItem)
        menu.addItem(.separator())
        let cancel = NSMenuItem(title: "取消", action: nil, keyEquivalent: "")
        menu.addItem(cancel)
        return menu
    }

    @objc private func quit(_ sender: NSMenuItem) {
        guard let item = sender.representedObject as? StatsProcItem else { return }
        StatsProcQuitter.quit(item: item)
    }
}

/// SwiftUI contextMenu（右键路径）：菜单内容与 NSMenu 版一致
struct StatsProcContextMenu: View {
    let item: StatsProcItem
    let values: [String]

    var body: some View {
        Text(verbatim: "\(item.name) · PID \(item.pids.map(String.init).joined(separator: ", "))")
            .foregroundStyle(.secondary)
        Divider()
        Button(role: .destructive) {
            StatsProcQuitter.quit(item: item)
        } label: {
            Label("退出 \(item.name)", systemImage: "xmark.circle")
        }
        Divider()
        Text(verbatim: values.joined(separator: " · "))
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
    }
}

/// 退出进程：SIGTERM 全部合并 pid（同 App 的 Helper/Renderer 一并结束）
enum StatsProcQuitter {
    static func quit(item: StatsProcItem) {
        var succeeded = 0
        for pid in item.pids where kill(pid, SIGTERM) == 0 { succeeded += 1 }
        DispatchQueue.main.async {
            if succeeded > 0 {
                Toast.show("已请求退出 \(item.name)（\(succeeded) 个进程）", icon: "xmark.circle")
            } else {
                Toast.show("无法退出 \(item.name)：权限不足或已退出", icon: "exclamationmark.triangle")
            }
        }
    }

    /// v84：行内「退出」按钮走确认框（避免误点杀掉正在编辑的 App）；
    /// 右键菜单是显式选择，仍直接退出。
    static func confirmAndQuit(item: StatsProcItem) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "退出 \(item.name)？"
        alert.informativeText = item.pids.count > 1
            ? "将结束该应用的 \(item.pids.count) 个进程，未保存的内容可能丢失。"
            : "未保存的内容可能丢失。"
        alert.addButton(withTitle: "退出")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        quit(item: item)
    }
}

/// 核心占用方块条（原版「集群占用」上方：每核一个圆角块，性能核橙 / 能效核青，亮度=占用）
struct StatsCoreGrid: View {
    var fractions: [Double]
    var performanceCount: Int

    var body: some View {
        GeometryReader { geo in
            let count = max(1, fractions.count)
            let spacing: CGFloat = 3
            let width = (geo.size.width - spacing * CGFloat(count - 1)) / CGFloat(count)
            HStack(spacing: spacing) {
                ForEach(Array(fractions.enumerated()), id: \.offset) { index, value in
                    let isPerformance = index < performanceCount
                    let color = isPerformance
                        ? Color(red: 0.98, green: 0.62, blue: 0.24)
                        : Color(red: 0.30, green: 0.78, blue: 0.78)
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(color.opacity(0.28 + 0.72 * max(0, min(1, value))))
                        .frame(width: max(3, width))
                }
            }
        }
        .frame(height: 30)
    }
}

// MARK: - CPU

private struct CPUStatsPanel: View {
    @ObservedObject private var sampler = MonitorSampler.shared

    var body: some View {
        let sample = sampler.sample
        let stats = StatsDataProvider.shared.current
        return VStack(alignment: .leading, spacing: 12) {
            // 温度环 + 总占用分段环 + 图例（系统/用户/空闲/启动时间）
            HStack(alignment: .center, spacing: 16) {
                if let temperature = primaryTemperature() {
                    ZStack {
                        StatsRing(value: min(max(temperature / 110, 0), 1),
                                  color: Color(red: 0.98, green: 0.62, blue: 0.24),
                                  lineWidth: 8)
                        Text("\(Int(temperature.rounded()))°")
                            .font(.system(size: 16, weight: .semibold).monospacedDigit())
                    }
                    .frame(width: 62, height: 62)
                }
                ZStack {
                    StatsRing(segments: [
                        (max(0, min(1, sample.systemCPU)), MonitorColors.system),
                        (max(0, min(1, sample.userCPU)), MonitorColors.user),
                        (max(0, min(1, sample.idleCPU)), MonitorColors.idle)
                    ], lineWidth: 10)
                    VStack(spacing: 0) {
                        Text(MonitorFormat.percent(sample.cpuUsage))
                            .font(.system(size: 19, weight: .semibold).monospacedDigit())
                        Text("总占用")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: 92, height: 92)

                VStack(alignment: .leading, spacing: 7) {
                    StatsLegendRow(color: MonitorColors.system, label: "系统",
                                   value: MonitorFormat.percent(sample.systemCPU))
                    StatsLegendRow(color: MonitorColors.user, label: "用户",
                                   value: MonitorFormat.percent(sample.userCPU))
                    StatsLegendRow(color: MonitorColors.idle, label: "空闲",
                                   value: MonitorFormat.percent(sample.idleCPU))
                    HStack(spacing: 8) {
                        Text("启动时间")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 6)
                        Text(Self.uptimeText())
                            .font(.system(size: 13, weight: .medium))
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity)
            }

            MonitorSectionTitle("负载历史")
            StatsHistoryChart(values: sampler.history.cpu, color: MonitorColors.user, upperBound: 1, height: 76)

            // 每核方块条（原版紧贴历史图下方，无标题）
            if !sample.perCore.isEmpty {
                StatsCoreGrid(fractions: sample.perCore,
                              performanceCount: max(0, stats.cpuSuperCores > 0 ? stats.cpuSuperCores : sample.perCore.count / 2))
                    .padding(.top, -4)
            }

            if stats.cpuSuperCores > 0 {
                MonitorSectionTitle("集群占用")
                StatsLegendRow(color: Color(red: 0.98, green: 0.62, blue: 0.24), label: "超级核心",
                               value: MonitorFormat.percent(stats.clusterSuperUsage))
                StatsLegendRow(color: Color(red: 0.30, green: 0.78, blue: 0.78), label: "能效核心",
                               value: MonitorFormat.percent(stats.clusterEffUsage))
            }

            MonitorSectionTitle("平均负载")
            HStack(spacing: 10) {
                loadCell("1 分钟", value: sample.loadAverage1m)
                loadCell("5 分钟", value: sample.loadAverage5m)
                loadCell("15 分钟", value: sample.loadAverage15m)
            }

            if !stats.procCPU.isEmpty {
                StatsProcTable(title: "高占用进程",
                               columns: [.init(title: "用量", color: nil)],
                               items: Array(stats.procCPU.prefix(5))) { item in
                    [String(format: "%.0f%%", item.cpu)]
                }
            }
        }
    }

    private func loadCell(_ title: String, value: Double) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Text(MonitorFormat.load(value))
                .font(.system(size: 14, weight: .semibold).monospacedDigit())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// CPU 温度：优先 STATS 全量 SMC 扫描（官方名表，M 系列 key 才读得到），
    /// 回退到 MonitorReader 的固定 key 表（老机型）。
    private func primaryTemperature() -> Double? {
        let stats = StatsDataProvider.shared.current
        if let hottest = stats.calcHottestCPU ?? stats.calcAverageCPU { return hottest }
        let cpuGroup = stats.sensors.filter { $0.category == 0 && $0.group == 1 }.map(\.value)
        if let peak = cpuGroup.max() { return peak }
        let temperatures = sampler.sample.temperatures
        for key in ["CPU 包温", "CPU 二极管", "CPU 邻近"] {
            if let value = temperatures[key] { return value }
        }
        return temperatures.values.first
    }

    static func uptimeText() -> String {
        let up = ProcessInfo.processInfo.systemUptime
        let days = Int(up) / 86400
        let hours = (Int(up) % 86400) / 3600
        if days > 0 { return "\(days) 天 \(hours) 小时" }
        let minutes = (Int(up) % 3600) / 60
        return hours > 0 ? "\(hours) 小时 \(minutes) 分钟" : "\(minutes) 分钟"
    }
}

// MARK: - 内存

private struct MemoryStatsPanel: View {
    @ObservedObject private var sampler = MonitorSampler.shared
    @ObservedObject private var memoryOptimizer = MemoryOptimizer.shared

    var body: some View {
        let sample = sampler.sample
        let stats = StatsDataProvider.shared.current
        let total = max(1, Double(stats.memTotal > 0 ? stats.memTotal : sample.memoryTotal))
        let used = Double(stats.memUsed > 0 ? stats.memUsed : sample.memoryUsed)
        let compressed = Double(stats.memCompressed)
        let wired = Double(stats.memWired)
        let appBytes = max(0, used - compressed - wired)
        let free = max(0, total - used)
        let pressure = max(0, min(1, used / total))
        let level = stats.memPressureLevel

        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 16) {
                StatsHalfGauge(value: pressure, caption: pressureCaption(level), captionColor: pressureColor(level))
                    .frame(width: 92, height: 62)

                ZStack {
                    StatsRing(segments: [
                        (max(0, min(1, used / total)), Color(red: 0.98, green: 0.35, blue: 0.38))
                    ], lineWidth: 10)
                    VStack(spacing: 0) {
                        Text(MonitorFormat.percent(used / total))
                            .font(.system(size: 19, weight: .semibold).monospacedDigit())
                        Text("已用")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: 92, height: 92)

                VStack(alignment: .leading, spacing: 7) {
                    StatsLegendRow(color: .clear, label: "已用",
                                   value: MonitorFormat.bytes(UInt64(used)), showsDot: false)
                    StatsLegendRow(color: .clear, label: "总量",
                                   value: MonitorFormat.bytes(UInt64(total)), showsDot: false)
                    StatsLegendRow(color: .clear, label: "交换区",
                                   value: MonitorFormat.bytes(stats.memSwapUsed > 0 ? stats.memSwapUsed : sample.swapUsed),
                                   showsDot: false)
                    StatsLegendRow(color: .clear, label: "内存压力", value: pressureCaption(level),
                                   valueColor: pressureColor(level), showsDot: false)
                }
                .frame(maxWidth: .infinity)
            }

            MemoryOptimizeSection(optimizer: memoryOptimizer)

            MonitorSectionTitle("使用历史")
            StatsHistoryChart(values: sampler.history.memory, color: MonitorColors.user, upperBound: 1, height: 72)

            MonitorSectionTitle("内存构成")
            GeometryReader { geo in
                HStack(spacing: 0) {
                    segment(width: geo.size.width * appBytes / total, color: MonitorColors.user)
                    segment(width: geo.size.width * wired / total, color: Color(red: 0.98, green: 0.62, blue: 0.24))
                    segment(width: geo.size.width * compressed / total, color: Color(red: 0.98, green: 0.35, blue: 0.38))
                    segment(width: geo.size.width * free / total, color: Color.primary.opacity(0.16))
                }
            }
            .frame(height: 10)

            VStack(alignment: .leading, spacing: 5) {
                StatsLegendRow(color: MonitorColors.user, label: "App 内存", value: MonitorFormat.bytes(MonitorFormat.u64(appBytes)))
                StatsLegendRow(color: Color(red: 0.98, green: 0.62, blue: 0.24), label: "联动内存", value: MonitorFormat.bytes(UInt64(wired)))
                StatsLegendRow(color: Color(red: 0.98, green: 0.35, blue: 0.38), label: "压缩内存", value: MonitorFormat.bytes(UInt64(compressed)))
                StatsLegendRow(color: Color.primary.opacity(0.16), label: "可用", value: MonitorFormat.bytes(UInt64(free)))
            }

            if !stats.procMem.isEmpty {
                StatsProcTable(title: "高占用进程",
                               columns: [.init(title: "内存", color: nil)],
                               items: Array(stats.procMem.prefix(5)),
                               subtitle: { _ in nil }) { item in
                    [MonitorFormat.bytes(MonitorFormat.u64(item.memBytes))]
                }
            }
        }
    }

    private func segment(width: CGFloat, color: Color) -> some View {
        Rectangle().fill(color).frame(width: max(0, width))
    }

    private func pressureCaption(_ level: Int32) -> String {
        switch level {
        case 2: return "警告"
        case 4: return "严重"
        case 1: return "正常"
        default: return sampler.sample.memoryPressure < 0.6 ? "正常" : "警告"
        }
    }

    private func pressureColor(_ level: Int32) -> Color {
        switch level {
        case 2: return Color(red: 0.95, green: 0.55, blue: 0.15)
        case 4: return MonitorColors.system
        case 1: return .primary
        default: return sampler.sample.memoryPressure < 0.6 ? .primary : Color(red: 0.95, green: 0.55, blue: 0.15)
        }
    }
}

// MARK: - GPU

private struct GPUStatsPanel: View {
    @ObservedObject private var sampler = MonitorSampler.shared

    var body: some View {
        let stats = StatsDataProvider.shared.current
        // v44（2026-10-18 修复）：`gpuUsage/gpuRenderer/gpuTiler` 已是 0…1 的比例
        // （C 层 `frset_gpu_usage` 内部做的 v/100），这里**不能再除 100**——
        // 旧代码双除导致真实 27% 显示成 0%、100% 显示成 1%（用户反馈"一直显示 1%"）。
        let usage = stats.gpuUsage >= 0 ? stats.gpuUsage : 0
        let renderer = stats.gpuRenderer >= 0 ? stats.gpuRenderer : usage
        let tiler = stats.gpuTiler >= 0 ? stats.gpuTiler : usage

        return VStack(alignment: .leading, spacing: 12) {
            // 三环横向铺满（v88：用户反馈「宽度很短」——原固定 spacing=26 把三环挤成
            // 中间一簇、两侧留白；改用 Spacer 均分，宽度自适应容器）
            HStack(alignment: .center, spacing: 0) {
                ring(value: usage, size: 66, fontSize: 15)
                Spacer(minLength: 16)
                ring(value: renderer, size: 92, fontSize: 19)
                Spacer(minLength: 16)
                ring(value: tiler, size: 66, fontSize: 15)
            }
            .frame(maxWidth: .infinity)

            MonitorSectionTitle("负载历史")
            StatsHistoryChart(values: sampler.history.gpu, color: MonitorColors.user, upperBound: 1, height: 76)

            MonitorSectionTitle("详细信息")
            StatsLegendRow(color: .clear, label: "型号", value: stats.gpuModel.isEmpty ? "—" : stats.gpuModel, showsDot: false)
            StatsLegendRow(color: .clear, label: "利用率", value: MonitorFormat.percent(usage), showsDot: false)
            StatsLegendRow(color: .clear, label: "渲染利用率", value: MonitorFormat.percent(renderer), showsDot: false)
            StatsLegendRow(color: .clear, label: "Tiler 利用率", value: MonitorFormat.percent(tiler), showsDot: false)
        }
    }

    private func ring(value: Double, size: CGFloat, fontSize: CGFloat) -> some View {
        ZStack {
            StatsRing(value: value, color: MonitorColors.user, lineWidth: size > 80 ? 10 : 8)
            Text(MonitorFormat.percent(value))
                .font(.system(size: fontSize, weight: .semibold).monospacedDigit())
        }
        .frame(width: size, height: size)
    }
}

// MARK: - 磁盘

private struct DiskStatsPanel: View {
    @ObservedObject private var sampler = MonitorSampler.shared
    @Stored private var showsDetails = true

    var body: some View {
        let sample = sampler.sample
        let stats = StatsDataProvider.shared.current
        let used = stats.diskTotalBytes > stats.diskFreeBytes ? stats.diskTotalBytes - stats.diskFreeBytes : 0
        let ratio = stats.diskTotalBytes > 0 ? Double(used) / Double(stats.diskTotalBytes) : 0

        return VStack(alignment: .leading, spacing: 12) {
            // 卷名行（原版：「Macintosh HD                    ⌄」）
            Button {
                withAnimation(Theme.Motion.fast) { showsDetails.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Text(stats.diskModel.isEmpty ? "Macintosh HD" : stats.diskModel)
                        .font(.system(size: 14, weight: .medium))
                        .lineLimit(1)
                    Spacer(minLength: 6)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(showsDetails ? 0 : -90))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if showsDetails {
                // 图例（蓝=读 / 红=写）+ 双线历史
                HStack(spacing: 12) {
                    legendValue(color: Color(red: 0.20, green: 0.52, blue: 0.98),
                                value: MonitorFormat.rate(sample.diskRead))
                    Spacer(minLength: 4)
                    legendValue(color: Color(red: 0.95, green: 0.27, blue: 0.30),
                                value: MonitorFormat.rate(sample.diskWrite))
                    Spacer(minLength: 4)
                }
                StatsHistoryDualChart(primaryValues: sampler.history.diskRead,
                                      secondaryValues: sampler.history.diskWrite,
                                      primaryColor: Color(red: 0.20, green: 0.52, blue: 0.98),
                                      secondaryColor: Color(red: 0.95, green: 0.27, blue: 0.30),
                                      height: 64)

                // 容量条
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: Theme.Radius.micro, style: .continuous)
                            .fill(Color.primary.opacity(0.12))
                        RoundedRectangle(cornerRadius: Theme.Radius.micro, style: .continuous)
                            .fill(Color(red: 0.20, green: 0.52, blue: 0.98))
                            .frame(width: geo.size.width * ratio)
                    }
                }
                .frame(height: 8)

                HStack {
                    Text("\(MonitorFormat.bytes(stats.diskTotalBytes)) 中剩余 \(MonitorFormat.bytes(stats.diskFreeBytes))")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 6)
                    Text(MonitorFormat.percent(ratio))
                        .font(.system(size: 12, weight: .medium).monospacedDigit())
                }

                VStack(alignment: .leading, spacing: 6) {
                    StatsLegendRow(color: .clear, label: "总读取量", value: MonitorFormat.bytes(stats.smart?.totalRead ?? 0), showsDot: false)
                    StatsLegendRow(color: .clear, label: "总写入量", value: MonitorFormat.bytes(stats.smart?.totalWritten ?? 0), showsDot: false)
                    StatsLegendRow(color: .clear, label: "文件系统", value: stats.diskFileSystem.isEmpty ? "—" : stats.diskFileSystem, showsDot: false)
                    StatsLegendRow(color: .clear, label: "连接类型", value: stats.diskInterconnect.isEmpty ? "—" : stats.diskInterconnect, showsDot: false)
                }

                if let smart = stats.smart, smart.available {
                    MonitorSectionTitle("SMART")
                    VStack(alignment: .leading, spacing: 6) {
                        StatsLegendRow(color: .clear, label: "温度", value: "\(smart.temperatureC)°C",
                                       valueColor: MonitorColors.temperature, showsDot: false)
                        StatsLegendRow(color: .clear, label: "健康度", value: "\(smart.life)%",
                                       valueColor: smart.life < 30 ? MonitorColors.system : .primary, showsDot: false)
                        StatsLegendRow(color: .clear, label: "上电次数", value: "\(smart.powerCycles)", showsDot: false)
                        StatsLegendRow(color: .clear, label: "上电小时数", value: "\(smart.powerOnHours)", showsDot: false)
                        StatsLegendRow(color: .clear, label: "严重警告", value: smart.criticalWarning == 0 ? "无" : "0x\(String(smart.criticalWarning, radix: 16))",
                                       valueColor: smart.criticalWarning == 0 ? .primary : MonitorColors.system, showsDot: false)
                        StatsLegendRow(color: .clear, label: "可用空间", value: "\(stats.diskTotalBytes > 0 ? Int((Double(stats.diskFreeBytes) / Double(stats.diskTotalBytes) * 100).rounded()) : 0)%", showsDot: false)
                    }
                }

                if !stats.procDisk.isEmpty {
                    StatsProcTable(title: "高占用进程",
                                   columns: [.init(title: "", color: Color(red: 0.20, green: 0.52, blue: 0.98)),
                                             .init(title: "", color: Color(red: 0.95, green: 0.27, blue: 0.30))],
                                   items: Array(stats.procDisk.prefix(5))) { item in
                        [MonitorFormat.rate(MonitorFormat.u64(item.diskRead)),
                         MonitorFormat.rate(MonitorFormat.u64(item.diskWrite))]
                    }
                }
            }
        }
    }

    private func legendValue(color: Color, value: String) -> some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 2, style: .continuous).fill(color).frame(width: 9, height: 9)
            Text(value)
                .font(.system(size: 13, weight: .medium).monospacedDigit())
                .lineLimit(1)
        }
    }
}

// MARK: - 网络

private struct NetworkStatsPanel: View {
    @ObservedObject private var sampler = MonitorSampler.shared
    @ObservedObject private var diagnostics = NetworkDiagnostics.shared
    @Stored private var showsInterfacePicker = false

    var body: some View {
        let sample = sampler.sample
        let stats = StatsDataProvider.shared.current

        return VStack(alignment: .leading, spacing: 12) {
            MonitorSectionTitle("速率历史")
            HStack(spacing: 12) {
                legendValue(color: Color(red: 0.20, green: 0.52, blue: 0.98), value: MonitorFormat.rate(sample.netDownload))
                Spacer(minLength: 4)
                legendValue(color: Color(red: 0.95, green: 0.27, blue: 0.30), value: MonitorFormat.rate(sample.netUpload))
                Spacer(minLength: 4)
            }
            StatsHistoryDualChart(primaryValues: sampler.history.netDownload,
                                  secondaryValues: sampler.history.netUpload,
                                  primaryColor: Color(red: 0.20, green: 0.52, blue: 0.98),
                                  secondaryColor: Color(red: 0.95, green: 0.27, blue: 0.30),
                                  height: 70)

            VStack(alignment: .leading, spacing: 6) {
                StatsLegendRow(color: .clear, label: "峰值下载",
                               value: MonitorFormat.rate(MonitorExtra.current.netPeakDownload), showsDot: false)
                StatsLegendRow(color: .clear, label: "峰值上传",
                               value: MonitorFormat.rate(MonitorExtra.current.netPeakUpload), showsDot: false)
                StatsLegendRow(color: .clear, label: "累计下载",
                               value: MonitorFormat.bytes(MonitorExtra.current.netTotalIn), showsDot: false)
                StatsLegendRow(color: .clear, label: "累计上传",
                               value: MonitorFormat.bytes(MonitorExtra.current.netTotalOut), showsDot: false)
            }

            if stats.connStatus != .unknown {
                MonitorSectionTitle("网络连接")
                HStack(spacing: 6) {
                    Circle()
                        .fill(stats.connStatus == .online ? Color(red: 0.30, green: 0.78, blue: 0.35) : MonitorColors.system)
                        .frame(width: 7, height: 7)
                    Text(stats.connStatus == .online ? "已连接" : "未连接")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                if !stats.connHistory.isEmpty {
                    StatsConnGrid(values: stats.connHistory)
                }
                VStack(alignment: .leading, spacing: 6) {
                    StatsLegendRow(color: .clear, label: "延迟", value: StatsFormat.ms(stats.connAvgLatencyMs), showsDot: false)
                    StatsLegendRow(color: .clear, label: "抖动", value: StatsFormat.ms(stats.connAvgJitterMs), showsDot: false)
                }
            }

            // ── 网络诊断（对照「鹅的IP」插件：内网 / 公网 / 归属 / 延迟 / DNS）
            diagnosticsSection

            if !stats.netInterface.isEmpty || !stats.netLocalIP.isEmpty {
                MonitorSectionTitle("接口")
                VStack(alignment: .leading, spacing: 6) {
                    if !stats.netInterface.isEmpty {
                        StatsLegendRow(color: .clear, label: "主接口", value: stats.netInterface, showsDot: false)
                    }
                    if !stats.netLocalIP.isEmpty {
                        StatsLegendRow(color: .clear, label: "本地 IP", value: stats.netLocalIP, showsDot: false)
                    }
                }
            }

            if !stats.procNet.isEmpty {
                StatsProcTable(title: "网络占用进程",
                               columns: [.init(title: "", color: Color(red: 0.20, green: 0.52, blue: 0.98)),
                                         .init(title: "", color: Color(red: 0.95, green: 0.27, blue: 0.30))],
                               items: Array(stats.procNet.prefix(5))) { item in
                    [MonitorFormat.rate(MonitorFormat.u64(item.diskRead)),
                     MonitorFormat.rate(MonitorFormat.u64(item.diskWrite))]
                }
            }
        }
    }

    // MARK: 网络诊断

    private var diagnosticsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            MonitorSectionTitle("IP 信息")

            // 内网：可切换网卡
            HStack(spacing: 6) {
                Text("内网")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(width: 54, alignment: .leading)
                Menu {
                    ForEach(diagnostics.interfaces) { item in
                        Button {
                            diagnostics.selectInterface(item.name)
                        } label: {
                            Text("\(item.name) · \(item.address)")
                        }
                    }
                } label: {
                    HStack(spacing: 3) {
                        Text(diagnostics.selectedAddress)
                            .font(.system(size: 12.5, weight: .medium).monospacedDigit())
                            .lineLimit(1)
                        if diagnostics.interfaces.count > 1 {
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.tertiaryText)
                        }
                    }
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                Spacer(minLength: 4)
                if !diagnostics.selectedInterface.isEmpty {
                    Text(diagnostics.selectedInterface)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.tertiaryText)
                }
            }

            StatsLegendRow(color: .clear, label: "公网",
                           value: diagnostics.publicIP ?? (diagnostics.isLoading ? "查询中…" : "—"),
                           showsDot: false)
            StatsLegendRow(color: .clear, label: "归属",
                           value: diagnostics.publicLocation ?? "—",
                           showsDot: false)
            // v45（2026-10-18 用户反馈）：代理改为读**本地真实状态**——
            // 系统代理设置 + 常见代理端口监听 + 客户端进程（Clash / mihomo / Surge…）。
            // 旧逻辑只按"公网归属非中国"推断，认不出 Clash，也读不到端口信息。
            if let label = diagnostics.proxyLabel {
                StatsLegendRow(color: .clear, label: "代理",
                               value: diagnostics.proxyAddress.map { "\(label) · \($0)" } ?? label,
                               valueColor: MonitorColors.user,
                               showsDot: false)
                if let note = diagnostics.proxyNote {
                    Text(note)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.tertiaryText)
                        .padding(.leading, 2)
                }
            } else if diagnostics.publicIP != nil {
                StatsLegendRow(color: .clear, label: "代理", value: "未检测到本地代理",
                               valueColor: .secondary, showsDot: false)
            }
            if diagnostics.isProxyLikely, let overseas = diagnostics.overseasIP {
                StatsLegendRow(color: .clear, label: "国外出口", value: overseas, showsDot: false)
                if let location = diagnostics.overseasLocation, !location.isEmpty {
                    StatsLegendRow(color: .clear, label: "位置", value: location, showsDot: false)
                }
            }

            // 站点延迟（两列，与原版键值行同字号）
            if diagnostics.latencies.contains(where: { $0.milliseconds != nil }) {
                MonitorSectionTitle("站点延迟")
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 12),
                                    GridItem(.flexible(), spacing: 12)],
                          spacing: 6) {
                    ForEach(diagnostics.latencies) { site in
                        HStack(spacing: 4) {
                            Text(site.name)
                                .font(.system(size: 11.5))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            Spacer(minLength: 2)
                            Text(site.milliseconds.map { "\($0) ms" } ?? "超时")
                                .font(.system(size: 11.5, weight: .semibold).monospacedDigit())
                                // v45：按快慢分级着色（用户要求不要纯黑）
                                .foregroundStyle(latencyColor(site.milliseconds))
                        }
                    }
                }
            }

            if !diagnostics.dnsServers.isEmpty {
                MonitorSectionTitle("DNS 出口")
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(diagnostics.dnsServers.enumerated()), id: \.offset) { _, server in
                        Text(server)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            }
        }
        .onAppear {
            // 首次进入或距上次超过 60 秒才重新探测（避免每次切页都打一轮外网请求）
            if diagnostics.lastRefresh == nil
                || Date().timeIntervalSince(diagnostics.lastRefresh!) > 60 {
                diagnostics.refresh()
            }
        }
    }

    /// 站点延迟分级配色（v45）：绿(<80ms) → 黄(<200ms) → 橙(<400ms) → 红(≥400ms)，
    /// 超时用 tertiary。用户要求"不要纯黑，多种颜色展现"。
    private func latencyColor(_ milliseconds: Int?) -> Color {
        guard let milliseconds else { return Color.primary.opacity(0.32) }   // 超时：淡灰
        switch milliseconds {
        case ..<80:  return Color(red: 0.24, green: 0.72, blue: 0.38)
        case ..<200: return Color(red: 0.93, green: 0.66, blue: 0.16)
        case ..<400: return Color(red: 0.94, green: 0.48, blue: 0.16)
        default:     return MonitorColors.system
        }
    }

    private func legendValue(color: Color, value: String) -> some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 2, style: .continuous).fill(color).frame(width: 9, height: 9)
            Text(value)
                .font(.system(size: 13, weight: .medium).monospacedDigit())
                .lineLimit(1)
        }
    }
}

/// 连通性网格（原版 30×3 绿/红方块）
///
/// v45（2026-10-18 用户反馈"字体和状态条图重叠"）：旧实现是
/// `GeometryReader` + 外部 `.frame(height: 44)`——格子边长按**宽度**算
/// （30 列 ≈ 12pt），但行数写死 5 行时总高 ≈ 130pt，远超 44pt 的框，
/// 内容向上/向下溢出，把上方「● 已连接」和下方「延迟/抖动」压住。
/// 改为 LazyVGrid + `aspectRatio(1)`：高度由内容自然撑开，不再需要外部 frame。
private struct StatsConnGrid: View {
    var values: [Int]

    private let columns = 30
    private let rows = 3
    private let spacing: CGFloat = 1.5

    var body: some View {
        let total = columns * rows
        let visible = Array(values.suffix(total))
        let offset = total - visible.count
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: spacing),
                                 count: columns),
                  spacing: spacing) {
            ForEach(0..<total, id: \.self) { index in
                let value = index >= offset ? visible[index - offset] : -1
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(color(for: value))
                    .aspectRatio(1, contentMode: .fit)
            }
        }
    }

    private func color(for value: Int) -> Color {
        switch value {
        case 1: return Color(red: 0.30, green: 0.78, blue: 0.35).opacity(0.85)
        case 0: return Color(red: 0.92, green: 0.26, blue: 0.28).opacity(0.85)
        default: return Color.primary.opacity(0.10)
        }
    }
}

// MARK: - 传感器（温度 / 电压 / 电流 / 功率）

private struct SensorsStatsPanel: View {
    var body: some View {
        let stats = StatsDataProvider.shared.current
        let temperatures = stats.sensors.filter { $0.category == 0 }
        let voltages = stats.sensors.filter { $0.category == 2 }
        let currents = stats.sensors.filter { $0.category == 3 }
        let powers = stats.sensors.filter { $0.category == 4 }

        return VStack(alignment: .leading, spacing: 12) {
            if !temperatures.isEmpty {
                SensorGroup(title: "温度", symbol: "thermometer.medium", color: MonitorColors.temperature,
                            items: orderedTemperatures(temperatures, stats: stats),
                            valueText: { String(format: "%.1f°C", $0.value) },
                            scaleMax: 110)
            }
            if !voltages.isEmpty {
                SensorGroup(title: "电压", symbol: "bolt.fill", color: Color(red: 0.20, green: 0.62, blue: 0.95),
                            items: voltages.sorted { $0.value > $1.value },
                            valueText: { String(format: "%.3f V", $0.value) },
                            scaleMax: nil)
            }
            if !currents.isEmpty {
                SensorGroup(title: "电流", symbol: "waveform.path", color: Color(red: 0.30, green: 0.70, blue: 0.40),
                            items: currents.sorted { $0.value > $1.value },
                            valueText: { String(format: "%.2f A", $0.value) },
                            scaleMax: nil)
            }
            if !powers.isEmpty {
                SensorGroup(title: "功率", symbol: "power", color: Color(red: 0.55, green: 0.40, blue: 0.85),
                            items: powers.sorted { $0.value > $1.value },
                            valueText: { String(format: "%.2f W", $0.value) },
                            scaleMax: nil)
            }
            if !stats.fans.isEmpty {
                MonitorSectionTitle("风扇")
                ForEach(stats.fans) { fan in
                    StatsLegendRow(color: .clear, label: fan.name,
                                   value: StatsFormat.rpm(fan.rpm), showsDot: false)
                }
            }
        }
    }

    /// 原版顺序：Average CPU / Hottest CPU / Average GPU / Hottest GPU / CPU Mb / 各核心
    private func orderedTemperatures(_ items: [StatsSensorItem], stats: StatsSnapshot) -> [StatsSensorItem] {
        var result: [StatsSensorItem] = []
        if let v = stats.calcAverageCPU {
            result.append(StatsSensorItem(key: "calc.avg.cpu", name: "CPU 平均温度", category: 0, group: 1, value: v))
        }
        if let v = stats.calcHottestCPU {
            result.append(StatsSensorItem(key: "calc.max.cpu", name: "CPU 最热核心", category: 0, group: 1, value: v))
        }
        if let v = stats.calcAverageGPU {
            result.append(StatsSensorItem(key: "calc.avg.gpu", name: "GPU 平均温度", category: 0, group: 2, value: v))
        }
        if let v = stats.calcHottestGPU {
            result.append(StatsSensorItem(key: "calc.max.gpu", name: "GPU 最热核心", category: 0, group: 2, value: v))
        }
        let rest = items
            .filter { !$0.name.hasPrefix("Average") && !$0.name.hasPrefix("Hottest") }
            .sorted { $0.value > $1.value }
        result.append(contentsOf: rest.prefix(12))
        return result
    }
}

private struct SensorGroup: View {
    var title: String
    var symbol: String
    var color: Color
    var items: [StatsSensorItem]
    var valueText: (StatsSensorItem) -> String
    var scaleMax: Double?

    var body: some View {
        VStack(spacing: 5) {
            HStack(spacing: 10) {
                line
                HStack(spacing: 4) {
                    Image(systemName: symbol).font(.system(size: 11))
                    Text(title).font(.system(size: 11))
                }
                .foregroundStyle(.secondary)
                .fixedSize()
                line
            }
            .padding(.vertical, 4)

            ForEach(items, id: \.key) { item in
                HStack(spacing: 10) {
                    Text(item.name)
                        .font(.system(size: 12))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .frame(width: 96, alignment: .leading)
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.primary.opacity(0.10))
                            Capsule().fill(color)
                                .frame(width: geo.size.width * fraction(item))
                        }
                    }
                    .frame(height: 7)
                    Text(valueText(item))
                        .font(.system(size: 12, weight: .medium).monospacedDigit())
                        .frame(width: 72, alignment: .trailing)
                }
            }
        }
    }

    private func fraction(_ item: StatsSensorItem) -> Double {
        if let upper = scaleMax, upper > 0 { return Swift.max(0, Swift.min(1, item.value / upper)) }
        let peak = items.map(\.value).max() ?? 1
        return peak > 0 ? Swift.max(0.04, Swift.min(1, item.value / peak)) : 0
    }

    private var line: some View {
        Rectangle().fill(Color.primary.opacity(0.12)).frame(height: 0.5)
    }
}
