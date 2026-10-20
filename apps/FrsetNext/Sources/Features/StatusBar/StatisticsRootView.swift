import Combine
import SwiftUI

// MARK: - 统计窗（specs/17，原版使用统计.png，800×562 pt）
// 顶部日期和当天计数，中段总览与 30 天柱图，底部跨年活动矩阵。
// 数据继续从原有 loadData 与 StatisticsManager 查询装载，不增加计数入口。

private enum StatisticsPalette {
    static let text = Color(red: 0.29, green: 0.32, blue: 0.39)
    static let secondary = Color(red: 0.49, green: 0.53, blue: 0.61)
    static let caption = Color(red: 0.59, green: 0.63, blue: 0.69)
}

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
    // 原版图：60 列、7 行，格子 8 pt、间隔 3 pt。
    private static let activityColumnCount = 60
    private static let activityRowCount = 7
    private static let heatmapCellSize: CGFloat = 8
    private static let heatmapSpacing: CGFloat = 3
    private static let last30BarWidth: CGFloat = 6
    private static let last30BarSpacing: CGFloat = 4
    private static let last30ChartHeight: CGFloat = 48
    /// hover 延时 tooltip 的延时秒数（S6 数值 ⬜，推断 0.4s）
    private static let hoverDelay: TimeInterval = 0.4

    // 原有查询结果与视图状态。
    @Stored private var totalInteractions: Int = 0            // __totalCounts 聚合
    @Stored private var activeDaysCount: Int = 0              // __activeDaysCount
    @Stored private var storedItemsCount: Int = 0             // __storedItemsCount
    @Stored private var todayCountsMap: [String: Int] = [:]   // __todayCounts
    @Stored private var activityTotals: [String: Int] = [:]   // __activityMatrixTotals（day → total）
    @Stored private var last30DayBreakdowns: [(day: String, event: String, count: Int)] = []  // __last30DayBreakdowns
    @Stored private var metricNumbersAnimatedIn: Bool = false
    /// 语言变更后继续刷新现有视图。
    @Stored private var l10nVersion: Int = 0
    @Environment(\.colorScheme) private var colorScheme
    // v84（2026-10-20 用户需求「个性化覆盖全局」）：统计窗此前不读个性化——
    // 强调色不生效、Midnight 主题下背景不跟随（仍用固定灰/深灰）。现接入两者。
    @ObservedObject private var personalization = Personalization.shared
    @ObservedObject private var appearance = AppearanceState.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .frame(height: 58, alignment: .top)
                .padding(.bottom, 31)
            overviewCards
                .frame(height: 50, alignment: .top)
                .padding(.bottom, 20)
            Rectangle()
                .fill(StatisticsPalette.secondary.opacity(0.25))
                .frame(height: 0.5)
                .padding(.bottom, 29)
            HStack(alignment: .top, spacing: 0) {
                overviewSummary
                    .frame(width: 284, alignment: .leading)
                Rectangle()
                    .fill(StatisticsPalette.secondary.opacity(0.25))
                    .frame(width: 0.5, height: 88)
                    .padding(.leading, 20)
                    .padding(.top, 28)
                    .padding(.trailing, 56)
                Last30BarsView(breakdowns: last30DayBreakdowns,
                               barWidth: Self.last30BarWidth,
                               barSpacing: Self.last30BarSpacing,
                               chartHeight: Self.last30ChartHeight)
            }
            .frame(height: 138, alignment: .top)
            .padding(.bottom, 24)
            ActivityHeatmapView(totals: activityTotals,
                                cellSize: Self.heatmapCellSize,
                                spacing: Self.heatmapSpacing,
                                columnCount: Self.activityColumnCount,
                                hoverDelay: Self.hoverDelay)
        }
        .frame(width: 660, alignment: .leading)
        .padding(.horizontal, 70)
        .padding(.top, 58)
        .frame(width: 800, height: 530)
        .foregroundStyle(colorScheme == .dark ? Color.primary : StatisticsPalette.text)
        .background {
            if appearance.isMidnight {
                MidnightTheme.baseBackground
            } else {
                colorScheme == .dark ? Color(white: 0.11) : Color(white: 0.87)
            }
        }
        // 强调色跟随个性化（统计页内的按钮/焦点环）
        .tint(personalization.accentColor ?? Color.accentColor)
        .ignoresSafeArea()
        .onAppear(perform: loadData)
        .onReceive(NotificationCenter.default.publisher(for: LanguageManager.languageDidChange)) { _ in
            l10nVersion &+= 1
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: "Frset")
                    .font(.custom("AvenirNextCondensed-DemiBold", size: 30))
                HStack(spacing: 6) {
                    Image(systemName: "lock.fill").font(.system(size: 9))
                    Text(verbatim: "数据仅存储在本机")
                        .font(.system(size: 8, weight: .semibold))
                        .tracking(2)
                }
                .foregroundStyle(StatisticsPalette.caption)
            }
            Spacer()
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(Calendar.current.component(.day, from: Date()))")
                    .font(.custom("DINAlternate-Bold", size: 32))
                Text(currentMonth)
                    .font(.custom("AvenirNextCondensed-DemiBold", size: 13))
            }
        }
    }

    private var currentMonth: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMMM"
        return formatter.string(from: Date())
    }

    // MARK: 当天五项计数（v84：按重建版实际功能重划分组 + 中文化）

    /// 五张指标卡：复制 / 截图 / 识别 / 工具 / 监测。
    /// v84（2026-10-20 用户需求「统计要覆盖新增功能」）：原版五卡是
    /// Pastes/Searches/Tools/Note/Capture，其中 Note 在重建版没有对应能力、
    /// 而截图族新增了长截图/贴图/标注、监测新增了性能页/中转站，故重划分组：
    /// · 复制 = 单条复制 + 批量复制 + 自动粘贴
    /// · 截图 = 截图完成 + 长截图 + 贴图 + 标注
    /// · 识别 = OCR + 翻译
    /// · 工具 = 工具执行 + 取色
    /// · 监测 = 性能监测页 + 状态栏监测部件点击 + 文件中转
    private var metricConfigs: [MetricConfig] {
        [
            MetricConfig(id: "statistics_copy", title: "复制",
                         tooltip: "今日复制次数（含批量复制与自动粘贴）",
                         eventNames: [AnalyticsEvent.historyCopy.eventName,
                                      AnalyticsEvent.historyBatchCopy.eventName,
                                      AnalyticsEvent.clipboardPaste.eventName],
                         icon: "square.on.square.fill", iconSize: 13, iconYOffset: 0),
            MetricConfig(id: "statistics_capture", title: "截图",
                         tooltip: "今日截图次数（含长截图、贴图、标注）",
                         eventNames: [AnalyticsEvent.screenshotCapture.eventName,
                                      AnalyticsEvent.longScreenshot.eventName,
                                      AnalyticsEvent.pinImage.eventName,
                                      AnalyticsEvent.annotateEdit.eventName],
                         icon: "viewfinder", iconSize: 13, iconYOffset: 0),
            MetricConfig(id: "statistics_recognize", title: "识别",
                         tooltip: "今日文字识别与翻译次数",
                         eventNames: [AnalyticsEvent.ocrUse.eventName,
                                      AnalyticsEvent.translationUse.eventName],
                         icon: "text.viewfinder", iconSize: 13, iconYOffset: 0),
            MetricConfig(id: "statistics_tools", title: "工具",
                         tooltip: "今日工具执行与取色次数",
                         eventNames: [AnalyticsEvent.toolExecuteSuccess.eventName,
                                      AnalyticsEvent.colorPickSuccess.eventName],
                         icon: "square.fill", iconSize: 13, iconYOffset: 0),
            MetricConfig(id: "statistics_monitor", title: "监测",
                         tooltip: "今日性能监测与文件中转次数",
                         eventNames: [AnalyticsEvent.monitorPanelOpen.eventName,
                                      AnalyticsEvent.activityMonitorClick.eventName,
                                      AnalyticsEvent.transferDockOpen.eventName],
                         icon: "gauge.with.dots.needle.67percent", iconSize: 13, iconYOffset: 0),
        ]
    }

    private var overviewCards: some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(metricConfigs) { config in
                MetricCardView(config: config,
                               value: cardValue(for: config),
                               animatedIn: metricNumbersAnimatedIn)
            }
        }
    }

    private func cardValue(for config: MetricConfig) -> Int {
        config.eventNames.reduce(0) { $0 + (todayCountsMap[$1] ?? 0) }
    }

    private var overviewSummary: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(verbatim: "总览")
                .font(.system(size: 12, design: .monospaced))
                .frame(height: 18)
            VStack(spacing: 0) {
                summaryRow("总交互", value: totalInteractions,
                           icon: "cursorarrow.click.2", color: .yellow)
                summaryRow("活跃天数", value: activeDaysCount,
                           icon: "calendar", color: .blue)
                summaryRow("剪贴板条目", value: storedItemsCount,
                           icon: "doc.on.clipboard.fill", color: .orange)
            }
        }
    }

    private func summaryRow(_ title: String, value: Int, icon: String, color: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(color.opacity(0.7))
                .frame(width: 18)
            Text(title)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(StatisticsPalette.secondary)
            Spacer(minLength: 8)
            Text("\(value)").font(.custom("DINAlternate-Bold", size: 16))
        }
        .padding(.trailing, 3)
        .frame(height: 32)
    }

    // MARK: 数据装载（Q1/Q2/Q3/Q4/Q5 → 三层版面；条目数读 clipboard.sqlite）

    private func loadData() {
        let dailyEvents = metricConfigs.flatMap(\.eventNames)
        DispatchQueue.global(qos: .userInitiated).async {
            let mgr = StatisticsManager.shared
            let events = Array(mgr.trackedEventNames)
            let today = StatisticsManager.dayString()
            let calendar = Calendar.current
            let todayStart = calendar.startOfDay(for: Date())

            let totals = mgr.totalCounts()                                    // Q1
            let todayCounts = mgr.todayCounts(day: today, events: dailyEvents) // Q2
            let activeDays = mgr.activeDaysCount(events: events)              // Q3
            // 与矩阵同一周日对齐区间，复用 Q4。
            let heatStart = calendar.date(byAdding: .day,
                                          value: -((Self.activityColumnCount - 1) * Self.activityRowCount
                                                   + calendar.component(.weekday, from: todayStart) - 1),
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
                // 保留原有一次性数字动画。
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
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 3) {
                Image(systemName: config.icon)
                    .font(.system(size: config.iconSize, weight: .semibold))
                    .frame(width: 18)
                    .overlay {
                        if config.id == "statistics_tools" {
                            Text("/").font(.system(size: 11, weight: .bold))
                                .foregroundStyle(Color(white: 0.87))
                        } else if config.id == "statistics_capture" {
                            RoundedRectangle(cornerRadius: 1)
                                .fill(StatisticsPalette.secondary)
                                .frame(width: 8, height: 6)
                        }
                    }
                    .offset(y: config.iconYOffset)
                Text(config.title)
                    .font(.custom("AvenirNextCondensed-DemiBold", size: 13))
            }
            .frame(height: 18)
            .foregroundStyle(StatisticsPalette.secondary)
            Text("\(value)")
                .font(Font.custom("DINAlternate-Bold", size: 20))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                // S5：数字入场动画一次
                .scaleEffect(animatedIn ? 1 : 0.6)
                .opacity(animatedIn ? 1 : 0)
                .padding(.leading, 20)
        }
        .frame(width: 136, alignment: .leading)
        .help(config.tooltip)
    }
}

// MARK: - 活动矩阵：60 列 × 7 行，保留原有 hover 延时提示。

private struct ActivityHeatmapView: View {
    let totals: [String: Int]
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
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(verbatim: "活动矩阵")
                    .font(.system(size: 12, design: .monospaced))
                Spacer()
                Text(verbatim: "少")
                HStack(spacing: 3) {
                    ForEach(0..<5) { level in
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(levelColor(level))
                            .frame(width: cellSize, height: cellSize)
                    }
                }
                Text(verbatim: "多")
            }
            .font(.custom("AvenirNextCondensed-DemiBold", size: 11))
            .foregroundStyle(StatisticsPalette.secondary)
            .frame(height: 18)
            heatmapGrid
            monthLabels
                .padding(.top, 3)
        }
    }

    private var heatmapGrid: some View {
        ZStack(alignment: .topLeading) {
            HStack(alignment: .top, spacing: 8) {
                VStack(spacing: spacing) {
                    ForEach(0..<7) { row in
                        Text(row == 0 ? "SUN" : row == 3 ? "WED" : row == 6 ? "SAT" : "")
                            .font(.system(size: 8, design: .monospaced))
                            .tracking(1.5)
                            .foregroundStyle(StatisticsPalette.secondary)
                            .frame(width: 22, height: cellSize, alignment: .leading)
                    }
                }
                HStack(alignment: .top, spacing: spacing) {
                    ForEach(columns) { column in
                        VStack(alignment: .leading, spacing: spacing) {
                            ForEach(column.cells) { cell in
                                heatCellView(cell)
                            }
                        }
                    }
                }
            }
            .fixedSize(horizontal: true, vertical: false)
            .offset(x: -30)
            .frame(width: gridWidth, alignment: .leading)
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

    private var gridWidth: CGFloat {
        CGFloat(columnCount) * cellSize + CGFloat(columnCount - 1) * spacing
    }

    private var monthLabels: some View {
        ZStack(alignment: .topLeading) {
            ForEach(columns) { column in
                if let firstOfMonth = column.cells.first(where: {
                    Calendar.current.component(.day, from: $0.day) == 1 && !$0.isFuture
                }) {
                    Text(monthLabel(firstOfMonth.day))
                        .font(.custom("AvenirNextCondensed-DemiBold", size: 11))
                        .foregroundStyle(StatisticsPalette.secondary)
                        .fixedSize()
                        .offset(x: CGFloat(column.id) * (cellSize + spacing))
                }
            }
        }
        .frame(width: gridWidth, height: 16, alignment: .topLeading)
    }

    // MARK: 列构建（首列对齐周日，最后一列到今天所在周）

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

    // MARK: 原版暖色矩阵，未来日期留空。

    private func cellColor(for cell: HeatCell) -> Color {
        cell.isFuture ? .clear : levelColor(cell.level)
    }

    private func levelColor(_ level: Int) -> Color {
        switch level {
        case 1: return Color(red: 0.98, green: 0.84, blue: 0.55)
        case 2: return Color(red: 0.96, green: 0.73, blue: 0.27)
        case 3: return Color(red: 0.94, green: 0.55, blue: 0.10)
        case 4: return Color(red: 0.88, green: 0.35, blue: 0.04)
        default: return colorScheme == .dark ? Color(white: 0.18) : Color(white: 0.80)
        }
    }

    private func monthLabel(_ day: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMM"
        return formatter.string(from: day)
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
                .position(x: min(max(tooltipFrame.midX, 44), gridWidth - 44),
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
// MARK: - 最近 30 天：复用已有每日分解结果，按日求和绘制单色细柱。

private struct Last30BarsView: View {
    let breakdowns: [(day: String, event: String, count: Int)]
    let barWidth: CGFloat
    let barSpacing: CGFloat
    let chartHeight: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            Text(verbatim: "近 30 天")
                .font(.system(size: 12, design: .monospaced))
                .frame(height: 18)
            HStack(alignment: .bottom, spacing: barSpacing) {
                ForEach(days) { day in
                    barColumn(for: day)
                }
            }
            .frame(height: 81, alignment: .bottom)
        }
    }

    // MARK: 30 天数据组装（缺数据的日补 0）

    private struct DayBucket: Identifiable {
        let id: String
        let day: Date
        let total: Int
    }

    private var days: [DayBucket] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        var byDay: [String: Int] = [:]
        for (day, _, count) in breakdowns {
            byDay[day, default: 0] += count
        }
        var result: [DayBucket] = []
        for offset in -29...0 {
            guard let d = calendar.date(byAdding: .day, value: offset, to: today) else { continue }
            let key = StatisticsManager.dayString(from: d)
            result.append(DayBucket(id: key, day: d, total: byDay[key] ?? 0))
        }
        return result
    }

    private var maxTotal: Int {
        max(days.map { $0.total }.max() ?? 1, 1)
    }

    private func barColumn(for day: DayBucket) -> some View {
        RoundedRectangle(cornerRadius: 1.5)
            .fill(StatisticsPalette.secondary.opacity(0.35))
            .frame(width: barWidth,
                   height: max(3, CGFloat(day.total) / CGFloat(maxTotal) * chartHeight))
            .help("\(prettyDay(day.day)) · \(day.total) 次")
    }

    private func prettyDay(_ day: Date) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "M月d日"
        fmt.timeZone = TimeZone.current
        return fmt.string(from: day)
    }

}
