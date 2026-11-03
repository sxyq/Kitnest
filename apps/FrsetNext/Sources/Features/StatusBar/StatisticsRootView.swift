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
    /// hover 延时 tooltip 的延时秒数（S6 数值 ⬜，推断 0.4s）
    private static let hoverDelay: TimeInterval = 0.4

    @Environment(\.colorScheme) private var colorScheme
    // v84（2026-10-20 用户需求「个性化覆盖全局」）：统计窗此前不读个性化——
    // 强调色不生效、Midnight 主题下背景不跟随（仍用固定灰/深灰）。现接入两者。
    @ObservedObject private var appearance = AppearanceState.shared
    /// 语言变更后继续刷新现有视图。
    @Stored private var l10nVersion: Int = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .frame(height: 58, alignment: .top)
                .padding(.bottom, 31)
            // v115：三层图表抽成 StatisticsChartsView（设置 → 数据 页同源嵌入）
            StatisticsChartsView()
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
                // v206：去掉不透明底色，露出统一玻璃底（通透度/磨砂跟随个性化）
                Color.clear
            }
        }
        .background(alignment: .top) {
            // v206：标题栏独立分层（红绿灯不再是一条白条）
            if !appearance.isMidnight { WindowTitleBand() }
        }
        // 强调色跟随个性化（统计页内的按钮/焦点环）
        // 强调色 + Midnight 统一主题入口（统计窗同源；个性化改色即生效）
        .frsetThemeChrome()
        .ignoresSafeArea()
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
                    Image(systemName: "lock.fill").font(.system(size: 11))
                    Text(verbatim: "数据仅存储在本机")
                        .font(.system(size: 11, weight: .semibold))
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

    // v126（性能审计 F1275）：DateFormatter 复用——原来 body 每次求值都 new 一个
    // DateFormatter（初始化要装载 locale/ICU 表，是重量级操作）。改为 static 缓存。
    private static let monthFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMMM"
        return formatter
    }()

    private var currentMonth: String {
        Self.monthFormatter.string(from: Date())
    }
}

// MARK: - 用量图表块（v115 从统计窗抽出：统计窗与设置 → 数据 页共用）
//
// 三层版面（specs/17 S5/S8）：五张指标卡 → 总览 + 最近 30 天柱状图 → 活动热力图。
// 数据装载（Q1/Q2/Q3/Q4/Q5）随视图自带：onAppear 即拉取，Settings 页嵌入零额外接线。

struct StatisticsChartsView: View {
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

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
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
        .onAppear(perform: loadData)
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
    // v126（性能审计 F1275）：配置表从计算属性改为 static let——五张卡的配置是常量，
    // 原来 body 每次求值都重建 5 个 MetricConfig + 重算 15 次 AnalyticsEvent.eventName。
    private static let metricConfigs: [MetricConfig] = [
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
                     tooltip: "今日性能监测、文件中转与投屏次数",
                     eventNames: [AnalyticsEvent.monitorPanelOpen.eventName,
                                  AnalyticsEvent.activityMonitorClick.eventName,
                                  AnalyticsEvent.transferDockOpen.eventName,
                                  AnalyticsEvent.screenCastOpen.eventName],
                     icon: "gauge.with.dots.needle.67percent", iconSize: 13, iconYOffset: 0),
    ]

    private var overviewCards: some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(Self.metricConfigs) { config in
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
        let dailyEvents = Self.metricConfigs.flatMap(\.eventNames)
        DispatchQueue.global(qos: .userInitiated).async {
            // v128（流畅度）：后台查询块整体进 autoreleasepool——5 条 SQL 查询会产生大量
            // 临时 NSNumber/NSString，池不排空会拖到 runloop 回收，堆峰值偏高。
            let result = autoreleasepool { () -> (totals: [String: Int], todayCounts: [String: Int],
                                                 activeDays: Int, heatTotals: [(String, Int)],
                                                 breakdowns: [(day: String, event: String, count: Int)],
                                                 stored: Int64) in
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
                return (totals, todayCounts, activeDays, heatTotals, breakdowns, stored)
            }

            DispatchQueue.main.async {
                totalInteractions = result.totals.values.reduce(0, +)
                todayCountsMap = result.todayCounts
                activeDaysCount = result.activeDays
                activityTotals = Dictionary(uniqueKeysWithValues: result.heatTotals)
                last30DayBreakdowns = result.breakdowns
                storedItemsCount = Int(result.stored)
                // 保留原有一次性数字动画。
                if !metricNumbersAnimatedIn {
                    withAnimation(Theme.Motion.slow) { metricNumbersAnimatedIn = true }
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
                            RoundedRectangle(cornerRadius: 1, style: .continuous)
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
                        RoundedRectangle(cornerRadius: 1.5, style: .continuous)
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
            // v128（流畅度）：月份标签同为纯数据视图——hover 态变更时一并跳过 body
            MonthLabelsView(totals: totals,
                            cellSize: cellSize,
                            spacing: spacing,
                            columnCount: columnCount,
                            colorScheme: colorScheme)
                .equatable()
                .padding(.top, 3)
        }
    }

    private var heatmapGrid: some View {
        ZStack(alignment: .topLeading) {
            // v128（流畅度）：网格拆成独立 Equatable 子视图——hover 高亮/tooltip 状态
            // 一变就重算 ActivityHeatmapView.body，原路径每遍都要重建 60×7=420 个格子
            // 视图树（每个含 GeometryReader + onHover 闭包），是统计窗悬停长尾卡顿。
            // 网格只依赖 totals/尺寸/列数/配色，与 hover 态无关；数据不变即跳过其 body。
            HeatmapGridView(totals: totals,
                            cellSize: cellSize,
                            spacing: spacing,
                            columnCount: columnCount,
                            colorScheme: colorScheme,
                            onHoverCell: handleHover)
                .equatable()
            tooltipBubble
        }
    }

    private var gridWidth: CGFloat {
        CGFloat(columnCount) * cellSize + CGFloat(columnCount - 1) * spacing
    }

    // MARK: 列构建（首列对齐周日，最后一列到今天所在周）
    //
    // v128（流畅度）：列网格缓存/buildColumns 已下沉到 HeatmapGridView，
    // 此处只留 tooltip 查找所需的 byID 转发（同一条缓存，不重复建）。

    private func levelColor(_ level: Int) -> Color {
        HeatmapGridView.levelColor(level, colorScheme: colorScheme)
    }

    // MARK: hover 延时 tooltip（S6）

    private func handleHover(_ cell: HeatmapGridView.HeatCell, frame: CGRect, inside: Bool) {
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

    private var cellsByID: [String: HeatmapGridView.HeatCell] {
        // v126（性能审计 F1275）：随 grid 一并缓存，tooltip 查找不再每次重建 420 项字典
        // v128（流畅度）：改为与 HeatmapGridView 共享同一条缓存
        HeatmapGridView.grid(totals: totals, columnCount: columnCount).byID
    }

    private var tooltipBubble: some View {
        Group {
            if let id = highlightedCellID, let cell = cellsByID[id] {
                VStack(spacing: 2) {
                    Text("\(cell.count) 次")   // TODO 待本地化：原作无该句式键面
                        .font(Font.custom("PingFangSC-Semibold", size: 12))
                        .foregroundStyle(.primary)
                    Text(prettyDate(cell.day))
                        .font(Font.custom("PingFangSC-Regular", size: 11))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous)
                    .fill(Color(NSColor.controlBackgroundColor))
                    .shadow(color: .black.opacity(0.18), radius: 3, y: 1))
                .position(x: min(max(tooltipFrame.midX, 44), gridWidth - 44),
                          y: tooltipFrame.minY - 24)
                .transition(.opacity)
            }
        }
    }

    // v126（性能审计 F1275）：DateFormatter 复用——tooltip 文案每次悬停都 new 一个。
    private static let prettyDateFormatter: DateFormatter = {
        let fmt = DateFormatter()
        fmt.dateFormat = "M月d日"
        fmt.timeZone = TimeZone.current
        return fmt
    }()

    private func prettyDate(_ day: Date) -> String {
        Self.prettyDateFormatter.string(from: day)
    }
}

// MARK: - 网格本体（v128 拆出：与 hover 态解耦的纯数据视图）

/// v128（流畅度）：60×7 网格从 ActivityHeatmapView 拆出——原实现里 hover 高亮/tooltip
/// 一变就重算父 body，每遍重建 420 个格子视图树（每个含 GeometryReader + onHover）。
/// 此视图只依赖数据字段，声明 Equatable 后父级 hover 状态变更直接跳过其 body。
private struct HeatmapGridView: View, Equatable {
    let totals: [String: Int]
    let cellSize: CGFloat
    let spacing: CGFloat
    let columnCount: Int
    let colorScheme: ColorScheme
    let onHoverCell: (HeatCell, CGRect, Bool) -> Void

    // v128（流畅度）：闭包不参与比较——父级 body 重算时生成的新闭包不触发网格重绘，
    // 已装上的旧闭包仍指向同一 @Stored 存储盒，悬停回调写入依旧生效。
    static func == (lhs: HeatmapGridView, rhs: HeatmapGridView) -> Bool {
        lhs.totals == rhs.totals
            && lhs.cellSize == rhs.cellSize
            && lhs.spacing == rhs.spacing
            && lhs.columnCount == rhs.columnCount
            && lhs.colorScheme == rhs.colorScheme
    }

    /// 热力图单元格（spec cell 字段：column/id/day/count/level/isFuture）
    struct HeatCell: Identifiable {
        let id: String          // day 串（yyyy-MM-dd）
        let day: Date
        let count: Int
        let level: Int          // 0-4
        let isFuture: Bool
        let column: Int
    }

    struct HeatColumn: Identifiable {
        let id: Int
        let cells: [HeatCell]
        let firstDay: Date
    }

    // v126（性能审计 F1275）：列网格结果缓存——`columns` 原来是计算属性，而 body 每次
    // 求值会在 heatmapGrid / monthLabels / tooltipBubble 三处各算一遍，每遍重建 60×7=420
    // 个 HeatCell + 420 次 dayString + 420 次 Calendar 取日，hover 高亮一动就整窗重算三遍
    // （实测是统计窗悬停卡顿主因）。改为按「totals + 列数 + 当天」记忆化，命中后只读缓存；
    // cellsByID（420 项字典）一并缓存，tooltip 查找不再重建。
    private static var columnsCache: (key: Int, columns: [HeatColumn], byID: [String: HeatCell])?

    static func grid(totals: [String: Int], columnCount: Int)
        -> (columns: [HeatColumn], byID: [String: HeatCell]) {
        var hasher = Hasher()
        hasher.combine(totals)
        hasher.combine(columnCount)
        hasher.combine(StatisticsManager.dayString())
        let key = hasher.finalize()
        if let cached = columnsCache, cached.key == key {
            return (cached.columns, cached.byID)
        }
        let built = buildColumns(totals: totals, columnCount: columnCount)
        var byID: [String: HeatCell] = [:]
        byID.reserveCapacity(built.count * 7)
        for col in built { for cell in col.cells { byID[cell.id] = cell } }
        columnsCache = (key, built, byID)
        return (built, byID)
    }

    private static func buildColumns(totals: [String: Int], columnCount: Int) -> [HeatColumn] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        // 今天的 weekday（1=周日）：最后一列的 row(weekday-1) 落在今天 ⇒ 全网格首列对齐周日
        let weekday = calendar.component(.weekday, from: today)
        let startOffset = -((columnCount - 1) * 7 + weekday - 1)
        guard let startDay = calendar.date(byAdding: .day, value: startOffset, to: today) else { return [] }
        var result: [HeatColumn] = []
        result.reserveCapacity(columnCount)
        for c in 0..<columnCount {
            var cells: [HeatCell] = []
            cells.reserveCapacity(7)
            for r in 0..<7 {
                guard let d = calendar.date(byAdding: .day, value: c * 7 + r, to: startDay) else { continue }
                let dayStr = StatisticsManager.dayString(from: d)
                let future = d > today
                let count = future ? 0 : (totals[dayStr] ?? 0)
                cells.append(HeatCell(id: dayStr, day: d, count: count,
                                      level: level(for: count), isFuture: future, column: c))
            }
            result.append(HeatColumn(id: c, cells: cells, firstDay: cells.first?.day ?? today))
        }
        return result
    }

    /// level 0-4 分档
    /// v95（2026-10-21 用户：「颜色区分要跨度大，当前这么点使用量都是最高等级，
    /// 要把当前等级改为中等颜色」）：旧档 ≥20 即最高——轻度使用几天就满格。
    /// v98 拉大：0 / 1-15 / 16-250 / 251-1000 / ≥1001（用户：「跨度进一步拉大」）——
    /// 当前日常量落 16-250 中间色；高/最高留作重度日，量级再翻 4 倍才升档。
    static func level(for count: Int) -> Int {
        switch count {
        case 0:          return 0
        case 1...15:     return 1
        case 16...250:   return 2
        case 251...1000: return 3
        default:         return 4
        }
    }

    // MARK: 原版暖色矩阵，未来日期留空。

    static func levelColor(_ level: Int, colorScheme: ColorScheme) -> Color {
        switch level {
        case 1: return Color(red: 0.98, green: 0.84, blue: 0.55)
        case 2: return Color(red: 0.96, green: 0.73, blue: 0.27)
        case 3: return Color(red: 0.94, green: 0.55, blue: 0.10)
        case 4: return Color(red: 0.88, green: 0.35, blue: 0.04)
        default: return colorScheme == .dark ? Color(white: 0.18) : Color(white: 0.80)
        }
    }

    private func cellColor(for cell: HeatCell) -> Color {
        cell.isFuture ? .clear : Self.levelColor(cell.level, colorScheme: colorScheme)
    }

    private var gridWidth: CGFloat {
        CGFloat(columnCount) * cellSize + CGFloat(columnCount - 1) * spacing
    }

    var body: some View {
        let columns = Self.grid(totals: totals, columnCount: columnCount).columns
        return HStack(alignment: .top, spacing: 8) {
            VStack(spacing: spacing) {
                ForEach(0..<7) { row in
                    Text(row == 0 ? "SUN" : row == 3 ? "WED" : row == 6 ? "SAT" : "")
                        .font(.system(size: 11, design: .monospaced))
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
    }

    private func heatCellView(_ cell: HeatCell) -> some View {
        RoundedRectangle(cornerRadius: 2, style: .continuous)
            .fill(cellColor(for: cell))
            .frame(width: cellSize, height: cellSize)
            .overlay(
                GeometryReader { g in
                    Color.clear
                        .contentShape(Rectangle())
                        .onHover { inside in
                            onHoverCell(cell, g.frame(in: .named("heatmapSpace")), inside)
                        }
                }
            )
    }
}

// MARK: - 月份标签（v128 拆出：与 hover 态解耦的纯数据视图）

/// v128（流畅度）：月份标签行从 ActivityHeatmapView 拆出——与 HeatmapGridView 同理，
/// hover 态变更时父 body 重算不再连带重建月份标签（60 列扫描 + 文本视图）。
private struct MonthLabelsView: View, Equatable {
    let totals: [String: Int]
    let cellSize: CGFloat
    let spacing: CGFloat
    let columnCount: Int
    let colorScheme: ColorScheme

    static func == (lhs: MonthLabelsView, rhs: MonthLabelsView) -> Bool {
        lhs.totals == rhs.totals
            && lhs.cellSize == rhs.cellSize
            && lhs.spacing == rhs.spacing
            && lhs.columnCount == rhs.columnCount
            && lhs.colorScheme == rhs.colorScheme
    }

    // v126（性能审计 F1275）：DateFormatter 复用——monthLabel 原来对每个月标签都
    // new 一个 formatter，body 重算时反复创建。
    private static let monthLabelFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMM"
        return formatter
    }()

    var body: some View {
        let columns = HeatmapGridView.grid(totals: totals, columnCount: columnCount).columns
        let gridWidth = CGFloat(columnCount) * cellSize + CGFloat(columnCount - 1) * spacing
        return ZStack(alignment: .topLeading) {
            ForEach(columns) { column in
                // v126（性能审计 F1275）：月初判定改用 day 串后缀——dayString 就是
                // yyyy-MM-dd，`-01` 即月初；原来对每格都 Calendar.current.component(.day)
                // 取一次（420 次/遍），纯属重复计算。
                if let firstOfMonth = column.cells.first(where: {
                    !$0.isFuture && $0.id.hasSuffix("-01")
                }) {
                    Text(Self.monthLabelFormatter.string(from: firstOfMonth.day))
                        .font(.custom("AvenirNextCondensed-DemiBold", size: 11))
                        .foregroundStyle(StatisticsPalette.secondary)
                        .fixedSize()
                        .offset(x: CGFloat(column.id) * (cellSize + spacing))
                }
            }
        }
        .frame(width: gridWidth, height: 16, alignment: .topLeading)
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
        RoundedRectangle(cornerRadius: 1.5, style: .continuous)
            .fill(StatisticsPalette.secondary.opacity(0.35))
            .frame(width: barWidth,
                   height: max(3, CGFloat(day.total) / CGFloat(maxTotal) * chartHeight))
            .help("\(prettyDay(day.day)) · \(day.total) 次")
    }

    // v126（性能审计 F1275）：DateFormatter 复用——30 根柱子的 .help 文案原来每次 body
    // 求值都 new 30 个 DateFormatter（初始化开销远大于取串本身）。
    private static let prettyDayFormatter: DateFormatter = {
        let fmt = DateFormatter()
        fmt.dateFormat = "M月d日"
        fmt.timeZone = TimeZone.current
        return fmt
    }()

    private func prettyDay(_ day: Date) -> String {
        Self.prettyDayFormatter.string(from: day)
    }

}
