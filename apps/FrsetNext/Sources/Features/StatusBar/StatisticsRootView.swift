import Combine
import SwiftUI

// MARK: - 统计窗根视图（spec 17 §1 S3：三层版面）
//
// ① 概览大数字卡（卡片标题为原作硬编码英文，S7c）
// ② GitHub 式活动热力图（level 0-4 自绘 RoundedRectangle，isFuture 灰格，hover 延时 tooltip，S6）
// ③ 最近 30 天分解柱图（无 Charts 框架，RoundedRectangle 自绘）
// 页脚 "DATA IS STORED LOCALLY ON YOUR MAC"（S9）
//
// 本地化状态（spec 17 §S7c 实测：原作统计窗是**英文硬编码 + 部分 L10n 混合**）：
// - ✅ 有真实 L10n 键：节头 "Last 30 Days"、图例 Screenshot / Color Picker / OCR / Tool
// - ❌ 原作 793 键全查无：卡片标题 "Total Interactions" 等、页脚、热力图节头「使用活动」、
//   「共活跃 N 天」、tooltip「N 次」——这些保持硬编码原样，**不臆造键面**。

// MARK: 指标卡配置（S4：title/tooltip/eventNames/icon/iconSize/iconYOffset）

struct MetricConfig: Identifiable {
    let id: String
    let title: String
    let tooltip: String
    let eventNames: [String]
    let icon: String
    let iconSize: CGFloat
    let iconYOffset: CGFloat
}

// MARK: 根视图

struct StatisticsRootView: View {
    // 布局常量（S7 字段簇；视图区浮点常量池 {1,2,8,10,11,14,26,29,30} 归属 ⬜，取整组合）
    private static let activityColumnCount = 26
    private static let activityRowCount = 7
    private static let heatmapCellSize: CGFloat = 11
    private static let heatmapSpacing: CGFloat = 2
    private static let overviewToDividerSpacing: CGFloat = 14
    private static let dividerToChartGap: CGFloat = 10
    private static let last30BarWidth: CGFloat = 14
    private static let last30BarSpacing: CGFloat = 10
    private static let last30ChartHeight: CGFloat = 160
    /// hover 延时 tooltip 的延时秒数（S6 数值 ⬜，推断 0.4s）
    private static let hoverDelay: TimeInterval = 0.4

    // 数据（S3 字段簇对应；@Stored 为本机 @State 替代，见 CONTRACT §7.4）
    @Stored private var totalInteractions: Int = 0            // __totalCounts 聚合
    @Stored private var activeDaysCount: Int = 0              // __activeDaysCount
    @Stored private var storedItemsCount: Int = 0             // __storedItemsCount
    @Stored private var todayCountsMap: [String: Int] = [:]   // __todayCounts
    @Stored private var activityTotals: [String: Int] = [:]   // __activityMatrixTotals（day → total）
    @Stored private var last30DayBreakdowns: [(day: String, event: String, count: Int)] = []  // __last30DayBreakdowns
    @Stored private var metricNumbersAnimatedIn: Bool = false // S5 数字入场动画门控（一次）
    /// 语言版本号：languageDidChange 到达时自增，驱动统计窗重绘（契约 §10.3；@Stored 见 §7.4）
    @Stored private var l10nVersion: Int = 0

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                overviewCards
                    .padding(.bottom, Self.overviewToDividerSpacing)
                Divider()
                    .padding(.bottom, Self.dividerToChartGap)
                ActivityHeatmapView(totals: activityTotals,
                                    activeDays: activeDaysCount,
                                    cellSize: Self.heatmapCellSize,
                                    spacing: Self.heatmapSpacing,
                                    columnCount: Self.activityColumnCount,
                                    hoverDelay: Self.hoverDelay)
                    .padding(.bottom, Self.overviewToDividerSpacing)
                Divider()
                    .padding(.bottom, Self.dividerToChartGap)
                Last30BarsView(breakdowns: last30DayBreakdowns,
                               barWidth: Self.last30BarWidth,
                               barSpacing: Self.last30BarSpacing,
                               chartHeight: Self.last30ChartHeight)
                // S9：隐私页脚（硬编码英文 + semibold）
                Text("DATA IS STORED LOCALLY ON YOUR MAC")
                    .font(Font.custom("PingFangSC-Semibold", size: 10))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.top, 18)
            }
            .padding(24)
        }
        .background(Color(NSColor.windowBackgroundColor))
        .onAppear(perform: loadData)
        // 语言切换即时刷新（契约 §10.3）：广播到达即重算 body，节头/图例重新过 L10n.t()
        .onReceive(NotificationCenter.default.publisher(for: LanguageManager.languageDidChange)) { _ in
            l10nVersion &+= 1
        }
    }

    // MARK: ① 概览大数字卡

    /// metricConfigs（S4；id 与原作可实证的聚合 id 对齐）
    private var metricConfigs: [MetricConfig] {
        [
            MetricConfig(id: "statistics_active",
                         title: "Total Interactions",
                         tooltip: "全部功能的累计互动次数",
                         eventNames: Array(StatisticsManager.shared.trackedEventNames),
                         icon: "chart.line.uptrend.xyaxis",
                         iconSize: 14, iconYOffset: 0),
            MetricConfig(id: "statistics_tools",
                         title: "Tools used today",
                         tooltip: "今日划词工具执行次数",
                         eventNames: ["tool_execute_success"],
                         icon: "square.and.pencil",
                         iconSize: 14, iconYOffset: 0),
            MetricConfig(id: "statistics_screenshots",
                         title: "Screenshots and color picks today",
                         tooltip: "今日截图 + 取色次数",
                         eventNames: ["screenshot_capture", "color_pick_success"],
                         icon: "camera.viewfinder",
                         iconSize: 14, iconYOffset: 0),
            MetricConfig(id: "statistics_items",
                         title: "Stored Items",
                         tooltip: "本地剪贴板存储条目数",
                         eventNames: [],
                         icon: "square.stack.3d.up",
                         iconSize: 14, iconYOffset: 0),
        ]
    }

    private var overviewCards: some View {
        HStack(alignment: .top, spacing: 10) {
            ForEach(metricConfigs) { config in
                MetricCardView(config: config,
                               value: cardValue(for: config),
                               animatedIn: metricNumbersAnimatedIn)
            }
        }
    }

    private func cardValue(for config: MetricConfig) -> Int {
        switch config.id {
        case "statistics_active":
            return totalInteractions
        case "statistics_tools":
            return todayCountsMap["tool_execute_success"] ?? 0
        case "statistics_screenshots":
            return (todayCountsMap["screenshot_capture"] ?? 0) + (todayCountsMap["color_pick_success"] ?? 0)
        case "statistics_items":
            return storedItemsCount
        default:
            return 0
        }
    }

    // MARK: 数据装载（Q1/Q2/Q3/Q4/Q5 → 三层版面；条目数读 clipboard.sqlite）

    private func loadData() {
        DispatchQueue.global(qos: .userInitiated).async {
            let mgr = StatisticsManager.shared
            let events = Array(mgr.trackedEventNames)
            let today = StatisticsManager.dayString()
            let calendar = Calendar.current
            let todayStart = calendar.startOfDay(for: Date())

            let totals = mgr.totalCounts()                                    // Q1
            let todayCounts = mgr.todayCounts(day: today, events: [           // Q2
                "tool_execute_success", "screenshot_capture", "color_pick_success"])
            let activeDays = mgr.activeDaysCount(events: events)              // Q3
            // 热力图区间：26 周（列数 × 7 行 - 1 天）
            let heatStart = calendar.date(byAdding: .day,
                                          value: -(Self.activityColumnCount * Self.activityRowCount - 1),
                                          to: todayStart) ?? todayStart
            let heatTotals = mgr.dailyTotals(since: StatisticsManager.dayString(from: heatStart),
                                             events: events)                  // Q4
            let since30 = StatisticsManager.dayString(
                from: calendar.date(byAdding: .day, value: -29, to: todayStart) ?? todayStart)
            let breakdowns = mgr.dailyBreakdowns(since: since30, events: events)  // Q5
            let stored = (try? DatabaseManager.shared.clipboard.scalarInt(
                "SELECT COUNT(*) FROM clipboard_items")) ?? 0

            DispatchQueue.main.async {
                totalInteractions = totals.values.reduce(0, +)
                todayCountsMap = todayCounts
                activeDaysCount = activeDays
                activityTotals = Dictionary(uniqueKeysWithValues: heatTotals)
                last30DayBreakdowns = breakdowns
                storedItemsCount = Int(stored)
                // S5：数字入场动画一次（__metricNumbersAnimatedIn 门控）
                if !metricNumbersAnimatedIn {
                    withAnimation(.easeOut(duration: 0.45)) { metricNumbersAnimatedIn = true }
                }
            }
        }
    }
}

// MARK: - 指标卡（S5：数字入场动画；S8 字体：DINAlternate-Bold / AvenirNextCondensed-DemiBold）

private struct MetricCardView: View {
    let config: MetricConfig
    let value: Int
    let animatedIn: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: config.icon)
                .font(.system(size: config.iconSize, weight: .semibold))
                .foregroundStyle(.secondary)
                .offset(y: config.iconYOffset)
            Text("\(value)")
                .font(Font.custom("DINAlternate-Bold", size: 32))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                // S5：数字入场动画一次
                .scaleEffect(animatedIn ? 1 : 0.6)
                .opacity(animatedIn ? 1 : 0)
            Text(config.title)
                .font(Font.custom("AvenirNextCondensed-DemiBold", size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: Theme.cornerRadius).fill(Theme.cardBackground))
        .help(config.tooltip)
    }
}

// MARK: - ② 活动热力图（GitHub 式：26 列 × 7 行，列对齐周日；S6 hover 延时 tooltip）

private struct ActivityHeatmapView: View {
    let totals: [String: Int]
    let activeDays: Int
    let cellSize: CGFloat
    let spacing: CGFloat
    let columnCount: Int
    let hoverDelay: TimeInterval

    /// 热力图单元格（spec cell 字段：column/id/day/count/level/isFuture）
    struct HeatCell: Identifiable {
        let id: String          // day 串（yyyy-MM-dd）
        let day: Date
        let count: Int
        let level: Int          // 0-4
        let isFuture: Bool
        let column: Int
    }

    // S6 状态：__highlightedCellID / __pendingHoveredCellID / __hoverDelayWork
    @Stored private var highlightedCellID: String?
    @Stored private var pendingHoveredCellID: String?
    @Stored private var hoverDelayWork: DispatchWorkItem?
    @Stored private var tooltipFrame: CGRect = .zero

    // S10：外观自适应（亮/暗双色板）
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Theme.sectionHeader("使用活动")   // TODO 待本地化：原作 793 键无对应键面
                Spacer()
                Text("共活跃 \(activeDays) 天")   // TODO 待本地化：同上
                    .font(Font.custom("PingFangSC-Regular", size: 11))
                    .foregroundStyle(.secondary)
            }
            heatmapGrid
        }
    }

    private var heatmapGrid: some View {
        ZStack(alignment: .topLeading) {
            HStack(alignment: .top, spacing: 0) {
                ForEach(columns) { column in
                    VStack(alignment: .leading, spacing: spacing) {
                        // 月份标签：该列首日月份与前一列不同时显示（高度占位对齐）
                        Text(monthLabel(for: column))
                            .font(Font.custom("PingFangSC-Regular", size: 9))
                            .foregroundStyle(.secondary)
                            .frame(height: 14, alignment: .bottom)
                            .opacity(showsMonthLabel(for: column) ? 1 : 0)
                        ForEach(column.cells) { cell in
                            heatCellView(cell)
                        }
                    }
                    .padding(.trailing, spacing)
                }
            }
            .coordinateSpace(name: "heatmapSpace")
            tooltipBubble
        }
    }

    private func heatCellView(_ cell: HeatCell) -> some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(cellColor(for: cell))
            .frame(width: cellSize, height: cellSize)
            .overlay(
                GeometryReader { g in
                    Color.clear
                        .contentShape(Rectangle())
                        .onHover { inside in
                            handleHover(cell, frame: g.frame(in: .named("heatmapSpace")), inside: inside)
                        }
                }
            )
    }

    // MARK: 列构建（26 列 × 7 行，首列对齐周日，最后一列到今天所在周）

    private struct HeatColumn: Identifiable {
        let id: Int
        let cells: [HeatCell]
        let firstDay: Date
    }

    private var columns: [HeatColumn] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        // 今天的 weekday（1=周日）：最后一列的 row(weekday-1) 落在今天 ⇒ 全网格首列对齐周日
        let weekday = calendar.component(.weekday, from: today)
        let startOffset = -((columnCount - 1) * 7 + weekday - 1)
        guard let startDay = calendar.date(byAdding: .day, value: startOffset, to: today) else { return [] }
        var result: [HeatColumn] = []
        for c in 0..<columnCount {
            var cells: [HeatCell] = []
            for r in 0..<7 {
                guard let d = calendar.date(byAdding: .day, value: c * 7 + r, to: startDay) else { continue }
                let dayStr = StatisticsManager.dayString(from: d)
                let future = d > today
                let count = future ? 0 : (totals[dayStr] ?? 0)
                cells.append(HeatCell(id: dayStr, day: d, count: count,
                                      level: Self.level(for: count), isFuture: future, column: c))
            }
            result.append(HeatColumn(id: c, cells: cells, firstDay: cells.first?.day ?? today))
        }
        return result
    }

    /// level 0-4 分档（spec 阈值 ⬜，推断：0 / 1-3 / 4-9 / 10-19 / ≥20）
    private static func level(for count: Int) -> Int {
        switch count {
        case 0:          return 0
        case 1...3:      return 1
        case 4...9:      return 2
        case 10...19:    return 3
        default:         return 4
        }
    }

    // MARK: 配色（S10 外观自适应；zeroColor + GitHub 四档绿）

    private func cellColor(for cell: HeatCell) -> Color {
        // isFuture：未来日期置灰（S6）
        if cell.isFuture {
            return colorScheme == .dark ? Color(white: 0.16) : Color(white: 0.93)
        }
        switch cell.level {
        case 1:  return colorScheme == .dark ? Color(red: 0.055, green: 0.267, blue: 0.161) : Color(red: 0.608, green: 0.914, blue: 0.659)
        case 2:  return colorScheme == .dark ? Color(red: 0.000, green: 0.427, blue: 0.196) : Color(red: 0.251, green: 0.769, blue: 0.388)
        case 3:  return colorScheme == .dark ? Color(red: 0.149, green: 0.651, blue: 0.255) : Color(red: 0.188, green: 0.631, blue: 0.306)
        case 4:  return colorScheme == .dark ? Color(red: 0.224, green: 0.827, blue: 0.325) : Color(red: 0.129, green: 0.431, blue: 0.224)
        default: return colorScheme == .dark ? Color(white: 0.11) : Color(white: 0.92)   // zeroColor
        }
    }

    private func monthLabel(for column: HeatColumn) -> String {
        let m = Calendar.current.component(.month, from: column.firstDay)
        return "\(m)月"
    }

    private func showsMonthLabel(for column: HeatColumn) -> Bool {
        guard let prev = columns.first(where: { $0.id == column.id - 1 }) else { return true }
        let m1 = Calendar.current.component(.month, from: column.firstDay)
        let m2 = Calendar.current.component(.month, from: prev.firstDay)
        return m1 != m2
    }

    // MARK: hover 延时 tooltip（S6）

    private func handleHover(_ cell: HeatCell, frame: CGRect, inside: Bool) {
        hoverDelayWork?.cancel()
        hoverDelayWork = nil
        guard inside, !cell.isFuture else {
            // 移出：立即清除高亮与 tooltip
            if highlightedCellID == cell.id || pendingHoveredCellID == cell.id {
                highlightedCellID = nil
                pendingHoveredCellID = nil
            }
            return
        }
        pendingHoveredCellID = cell.id
        let work = DispatchWorkItem {
            highlightedCellID = cell.id
            tooltipFrame = frame
            pendingHoveredCellID = nil
        }
        hoverDelayWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + hoverDelay, execute: work)
    }

    private var cellsByID: [String: HeatCell] {
        var map: [String: HeatCell] = [:]
        for c in columns { for cell in c.cells { map[cell.id] = cell } }
        return map
    }

    private var tooltipBubble: some View {
        Group {
            if let id = highlightedCellID, let cell = cellsByID[id] {
                VStack(spacing: 2) {
                    Text("\(cell.count) 次")   // TODO 待本地化：原作无该句式键面
                        .font(Font.custom("PingFangSC-Semibold", size: 12))
                        .foregroundStyle(.primary)
                    Text(prettyDate(cell.day))
                        .font(Font.custom("PingFangSC-Regular", size: 10))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 6)
                    .fill(Color(NSColor.controlBackgroundColor))
                    .shadow(color: .black.opacity(0.18), radius: 3, y: 1))
                .position(x: min(max(tooltipFrame.midX, 44), 800 - 44),
                          y: tooltipFrame.minY - 24)
                .transition(.opacity)
            }
        }
    }

    private func prettyDate(_ day: Date) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "M月d日"
        fmt.timeZone = TimeZone.current
        return fmt.string(from: day)
    }
}

// MARK: - ③ 最近 30 天分解柱图（RoundedRectangle 自绘，无 Charts；S7c 节头 "过去30天"）
//
// S7c 实测：节头有真实 L10n 键 "Last 30 Days"（ZH「过去30天」）→ 走 L10n；
// 图例 4 个标签在原作 793 键中有对应键面 → 走 L10n；剪贴板/AI 两个标签原作无键，保持硬编码。

private struct Last30BarsView: View {
    let breakdowns: [(day: String, event: String, count: Int)]
    let barWidth: CGFloat
    let barSpacing: CGFloat
    let chartHeight: CGFloat

    /// 柱内堆叠顺序（事件 → 分解段）
    private static let stackOrder = [
        "clipboard_capture", "screenshot_capture", "color_pick_success",
        "ocr_use", "tool_execute_success", "ai_request_count",
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Theme.sectionHeader(L10n.t("Last 30 Days"))
            HStack(alignment: .bottom, spacing: barSpacing) {
                ForEach(days) { day in
                    barColumn(for: day)
                }
            }
            legend
        }
    }

    // MARK: 30 天数据组装（缺数据的日补 0）

    private struct DayBucket: Identifiable {
        let id: String
        let day: Date
        let segments: [(event: String, count: Int)]
        var total: Int { segments.reduce(0) { $0 + $1.count } }
    }

    private var days: [DayBucket] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        var byDay: [String: [(String, Int)]] = [:]
        for (day, event, count) in breakdowns {
            byDay[day, default: []].append((event, count))
        }
        var result: [DayBucket] = []
        for offset in -29...0 {
            guard let d = calendar.date(byAdding: .day, value: offset, to: today) else { continue }
            let key = StatisticsManager.dayString(from: d)
            var segments = byDay[key] ?? []
            segments.sort { orderIndex($0.0) < orderIndex($1.0) }
            result.append(DayBucket(id: key, day: d, segments: segments))
        }
        return result
    }

    private func orderIndex(_ event: String) -> Int {
        Self.stackOrder.firstIndex(of: event) ?? Self.stackOrder.count
    }

    private var maxTotal: Int {
        max(days.map { $0.total }.max() ?? 1, 1)
    }

    private func barColumn(for day: DayBucket) -> some View {
        VStack(alignment: .center, spacing: 3) {
            VStack(spacing: 0) {
                ForEach(Array(day.segments.enumerated()), id: \.offset) { _, seg in
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(barColor(seg.event))
                        .frame(width: barWidth,
                               height: max(2, CGFloat(seg.count) / CGFloat(maxTotal) * chartHeight))
                }
                if day.total == 0 {
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(Color.secondary.opacity(0.12))
                        .frame(width: barWidth, height: 2)
                }
            }
            .frame(height: chartHeight, alignment: .bottom)
            // 轴标签：每月 1 日显示 "M月"
            Text(dayLabel(day))
                .font(Font.custom("PingFangSC-Regular", size: 9))
                .foregroundStyle(.secondary)
                .frame(width: barWidth)
                .opacity(dayLabel(day).isEmpty ? 0 : 1)
        }
        .help("\(prettyDay(day.day)) · \(day.total) 次")
    }

    private func dayLabel(_ day: DayBucket) -> String {
        let comps = Calendar.current.dateComponents([.day, .month], from: day.day)
        return comps.day == 1 ? "\(comps.month ?? 0)月" : ""
    }

    private func prettyDay(_ day: Date) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "M月d日"
        fmt.timeZone = TimeZone.current
        return fmt.string(from: day)
    }

    private func barColor(_ event: String) -> Color {
        switch event {
        case "clipboard_capture":      return Color(red: 0.30, green: 0.56, blue: 1.00)  // 蓝：剪贴板
        case "screenshot_capture":     return Color(red: 1.00, green: 0.62, blue: 0.24)  // 橙：截图
        case "color_pick_success":     return Color(red: 0.94, green: 0.36, blue: 0.62)  // 粉：取色
        case "ocr_use":                return Color(red: 0.66, green: 0.45, blue: 0.95)  // 紫：OCR
        case "tool_execute_success", "search_execute":
                                       return Color(red: 0.22, green: 0.72, blue: 0.44)  // 绿：工具
        case "ai_request_count":       return Color(red: 0.20, green: 0.72, blue: 0.76)  // 青：AI
        default:                       return Color.secondary.opacity(0.5)
        }
    }

    // MARK: 图例
    //
    // 标签走 L10n 的前提是原作 793 键中存在对应键面（已逐键核对）：
    // Screenshot=截图 / Color Picker=取色 / OCR=OCR / Tool=工具；
    // 「剪贴板」「AI」原作无独立短标签键（仅有 "Clipboard Manager"=剪切板管理 等长句，
    // 语义不等价），故保持硬编码，不臆造键面。

    private var legend: some View {
        HStack(spacing: 12) {
            legendDot(color: barColor("clipboard_capture"), label: "剪贴板")  // TODO 待本地化
            legendDot(color: barColor("screenshot_capture"), label: L10n.t("Screenshot"))
            legendDot(color: barColor("color_pick_success"), label: L10n.t("Color Picker"))
            legendDot(color: barColor("ocr_use"), label: L10n.t("OCR"))
            legendDot(color: barColor("tool_execute_success"), label: L10n.t("Tool"))
            legendDot(color: barColor("ai_request_count"), label: "AI")          // TODO 待本地化
        }
    }

    private func legendDot(color: Color, label: String) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 1.5).fill(color).frame(width: 8, height: 8)
            Text(label)
                .font(Font.custom("PingFangSC-Regular", size: 10))
                .foregroundStyle(.secondary)
        }
    }
}
