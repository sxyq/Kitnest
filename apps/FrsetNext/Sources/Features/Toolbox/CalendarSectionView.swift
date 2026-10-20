import SwiftUI
import AppKit

// MARK: - 主面板「日历」卡（原版两周视图，1:1）
//
// 原版实测（400×700 面板）：白底圆角卡，高约 112pt。
//   ‹ 2026年10月 ›                                    ⌄
//   周日   周一   周二   周三   周四   周五   周六
//    11    12    13    14    15    16   [17]
//   初二   初三   初四   初五   初六   初七   初八
//    18    19    20    21    22    23    24
//   重阳   初十   十一   十二   十三   霜降   十五
//
// 交互：‹ › 前后翻两周；点月标题回今天；⌄ 折叠（只留标题行）。
// 今天 = 蓝底白字圆角块；节气/节日 = 橙色文字。

public struct CalendarSectionView: View {
    @ObservedObject private var service = CalendarService.shared
    /// 当前两周期间的锚点（渲染时归一化到所在周的周日）
    @Stored private var anchor: Date = Date()
    @Stored private var collapsed = false
    /// 缓存 42 天数据（含农历/节气/事件），避免每帧查 EventKit
    @Stored private var cachedDays: [CalendarDay] = []
    /// 卡片在窗口内的 frame（横滑手势命中区判定）
    @Stored private var cardFrame: CGRect = .zero
    /// 横向滚动累积量（两指左右滑切周）
    @Stored private var scrollAccum: CGFloat = 0
    /// 滚动监听 token（窗口内 local monitor）
    @Stored private var scrollMonitor: Any? = nil
    @Environment(\.colorScheme) private var colorScheme

    private static let weekdayTitles = ["周日", "周一", "周二", "周三", "周四", "周五", "周六"]

    public init() {}

    public var body: some View {
        VStack(spacing: 5) {
            header
            if !collapsed {
                weekdayHeader
                weeksGrid
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .panelGlassCard()
        .background(
            GeometryReader { geo in
                Color.clear
                    .onAppear { cardFrame = geo.frame(in: .global) }
                    .onChange(of: geo.frame(in: .global)) { cardFrame = $0 }
            }
        )
        .onAppear {
            reload()
            installScrollMonitor()
        }
        .onDisappear { removeScrollMonitor() }
    }

    // MARK: 标题行

    private var header: some View {
        HStack(spacing: 4) {
            Button { shift(-7) } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.primary.opacity(0.55))
                    .frame(width: 22, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("上一周")

            Button {
                anchor = Date()
                reload()
            } label: {
                Text(monthTitle)
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(minWidth: 92, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("回到今天")

            Button { shift(7) } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.primary.opacity(0.55))
                    .frame(width: 22, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("下一周")

            Spacer(minLength: 4)

            Button {
                withAnimation(.spring(response: 0.30, dampingFraction: 0.86)) {
                    collapsed.toggle()
                }
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(collapsed ? -90 : 0))
                    .frame(width: 20, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(collapsed ? "展开日历" : "收起日历")
        }
    }

    private var weekdayHeader: some View {
        HStack(spacing: 0) {
            ForEach(Self.weekdayTitles, id: \.self) { title in
                Text(title)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(.top, 1)
    }

    // MARK: 两行日期

    private var weeksGrid: some View {
        VStack(spacing: 1) {
            ForEach(0..<2, id: \.self) { row in
                HStack(spacing: 0) {
                    ForEach(0..<7, id: \.self) { column in
                        dayCell(row: row, column: column)
                    }
                }
            }
        }
    }

    private func dayCell(row: Int, column: Int) -> some View {
        let index = row * 7 + column
        let day = index < twoWeekDays.count ? twoWeekDays[index] : nil
        let isToday = day?.isToday ?? false
        let isFestival = day.map { isFestivalDay($0) } ?? false

        return VStack(spacing: 0) {
            Text(day.map { "\(Calendar.current.component(.day, from: $0.date))" } ?? "")
                .font(.system(size: 14, weight: isToday ? .semibold : .regular))
                .foregroundStyle(isToday ? Color.white : Color.primary)
                .frame(height: 18)
            Text(day?.lunarDisplay ?? " ")
                .font(.system(size: 9))
                .foregroundStyle(isToday ? Color.white.opacity(0.92)
                                         : (isFestival ? Color.orange : Color.secondary))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(height: 12)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 34)
        .background {
            if isToday {
                // 今天：胶囊底固定 30×30，居中——不再按列宽撑满（旧版块面过大）
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Theme.accent)
                    .frame(width: 32, height: 32)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            guard let date = day?.date else { return }
            NotificationCenter.default.post(name: .calendarDidSelectDay, object: nil,
                                            userInfo: ["date": date])
        }
    }

    // MARK: 两指左右滑动切周（trackpad 横向滚动）

    /// 窗口内 local monitor：命中区限定在日历卡内、且以横向滚动为主才处理。
    /// 与箭头语义一致：向右滑（内容右移）看更早一周，向左滑看后一周。
    private func installScrollMonitor() {
        guard scrollMonitor == nil else { return }
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            // 面板是 key window 时，面板内唯一的横向滚动区域就是日历卡，
            // 因此不再做像素级命中判定（SwiftUI .global 与 AppKit 视坐标系不一致，
            // 逐次换算反而易错）：横向为主的滚动即切周。
            guard let win = event.window ?? NSApp.keyWindow,
                  win == NSApp.keyWindow else { return event }
            let dx = event.scrollingDeltaX
            let dy = event.scrollingDeltaY
            guard abs(dx) > abs(dy), abs(dx) > 0.3 else { return event }
            scrollAccum += dx
            if abs(scrollAccum) >= 12 {
                shift(scrollAccum > 0 ? -7 : 7)
                scrollAccum = 0
            }
            return nil
        }
    }

    private func removeScrollMonitor() {
        if let monitor = scrollMonitor { NSEvent.removeMonitor(monitor) }
        scrollMonitor = nil
        scrollAccum = 0
    }

    /// 面板窗口（日历只在主面板里出现）
    private var activeWindow: NSWindow? {
        NSApp.keyWindow ?? NSApp.mainWindow
    }

    // MARK: 数据

    /// 两周 14 天（按当前锚点所在周起算）
    private var twoWeekDays: [CalendarDay] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "zh_CN")
        calendar.firstWeekday = 1
        let start = calendar.dateInterval(of: .weekOfYear, for: anchor)?.start ?? anchor
        var map: [Date: CalendarDay] = [:]
        for day in cachedDays { map[calendar.startOfDay(for: day.date)] = day }
        return (0..<14).compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: offset, to: start) else { return nil }
            if let hit = map[calendar.startOfDay(for: date)] { return hit }
            return CalendarDay(date: date,
                               isToday: calendar.isDateInToday(date),
                               isWeekend: calendar.component(.weekday, from: date) == 1
                                       || calendar.component(.weekday, from: date) == 7)
        }
    }

    private var monthTitle: String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "zh_CN")
        calendar.firstWeekday = 1
        let start = calendar.dateInterval(of: .weekOfYear, for: anchor)?.start ?? anchor
        return CalendarService.monthTitle(start)
    }

    /// 节气 / 传统节日（橙色高亮）：农历节气表或节日表命中
    private func isFestivalDay(_ day: CalendarDay) -> Bool {
        if let text = day.holidayText, !text.isEmpty { return true }
        if LunarCalendar.solarTerm(day.date) != nil { return true }
        if let lunar = LunarCalendar.lunarDate(day.date),
           LunarCalendar.lunarFestival(lunar) != nil { return true }
        return false
    }

    private func shift(_ days: Int) {
        guard let next = Calendar.current.date(byAdding: .day, value: days, to: anchor) else { return }
        anchor = next
        reload()
    }

    private func reload() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "zh_CN")
        calendar.firstWeekday = 1
        let start = calendar.dateInterval(of: .weekOfYear, for: anchor)?.start ?? anchor
        var days = service.monthDays(for: start)
        if let next = calendar.date(byAdding: .day, value: 14, to: start) {
            days.append(contentsOf: service.monthDays(for: next))
        }
        cachedDays = days
    }
}

// MARK: - 农历展示

private extension CalendarDay {
    /// 单元格第二行：优先节气/节日名，其次农历日名
    /// 原版日历第二行文字更短：「重阳节」→「重阳」、「国庆节」→「国庆」
    static func shortName(_ text: String) -> String {
        text.hasSuffix("节") && text.count > 2 ? String(text.dropLast()) : text
    }

    var lunarDisplay: String {
        if let lunar = LunarCalendar.lunarDate(date) {
            if let festival = LunarCalendar.lunarFestival(lunar) { return Self.shortName(festival) }
            if let term = LunarCalendar.solarTerm(date) { return term }
        }
        if let text = lunarText, !text.isEmpty { return Self.shortName(text) }
        if let holiday = holidayText, !holiday.isEmpty { return Self.shortName(holiday) }
        return ""
    }
}

public extension Notification.Name {
    /// 点击日历某一天（userInfo["date"]）
    static let calendarDidSelectDay = Notification.Name("frset.calendar.didSelectDay")
}
