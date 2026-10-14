import SwiftUI
import AppKit

// MARK: - 主面板「日历」区段（id "calendar", priority 60）
// 结构：月份切换条 → 7 列月视图网格（今天高亮 / 周末灰 / 农历小字 / 事件打点）→ 今日事件列表 → 授权提示

public struct CalendarSectionView: View {
    @ObservedObject private var service = CalendarService.shared
    @Stored private var monthBase: Date = Date()
    @Stored private var grid: [CalendarDay] = []
    @Stored private var todayEvents: [CalendarEvent] = []

    private static let weekdayTitles = ["日", "一", "二", "三", "四", "五", "六"]

    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            weekdayHeader
            monthGrid
            if !service.isAuthorized { authorizationBanner }
            todayEventsList
        }
        .onAppear { reload() }
        .onChange(of: monthBase) { _ in reload() }
    }

    // MARK: 顶部（月份切换）

    private var header: some View {
        HStack(spacing: 8) {
            Text(CalendarService.monthTitle(monthBase))
                .font(.system(size: 13, weight: .semibold))
            Spacer()
            Button(action: { shiftMonth(-1) }) {
                Image(systemName: "chevron.left").font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.plain)
            Button("今天") { monthBase = Date() }
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Button(action: { shiftMonth(1) }) {
                Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.plain)
        }
    }

    private var weekdayHeader: some View {
        HStack(spacing: 0) {
            ForEach(Self.weekdayTitles, id: \.self) { title in
                Text(title)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    // MARK: 月视图网格

    private var monthGrid: some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: 2), count: 7)
        return LazyVGrid(columns: columns, spacing: 2) {
            ForEach(grid) { day in
                calendarCell(day)
            }
        }
    }

    private func calendarCell(_ day: CalendarDay) -> some View {
        let inMonth = Calendar.current.component(.month, from: day.date) == Calendar.current.component(.month, from: monthBase)
        let isHoliday = day.holidayText != nil
        return VStack(spacing: 1) {
            Text("\(Calendar.current.component(.day, from: day.date))")
                .font(.system(size: 12, weight: day.isToday ? .bold : .regular))
                .foregroundStyle(cellTextColor(day, inMonth: inMonth))
            Text(day.lunarText ?? " ")
                .font(.system(size: 8))
                .foregroundStyle(isHoliday ? Color.orange : Color.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Circle()
                .fill(day.events.isEmpty ? Color.clear : Color.accentColor)
                .frame(width: 4, height: 4)
        }
        .frame(height: 34)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(day.isToday ? Color.accentColor.opacity(0.18) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 5)
                .stroke(day.isToday ? Color.accentColor.opacity(0.6) : Color.clear, lineWidth: 1)
        )
    }

    private func cellTextColor(_ day: CalendarDay, inMonth: Bool) -> Color {
        if !inMonth { return Color.secondary.opacity(0.35) }
        if day.isToday { return Color.accentColor }
        if day.holidayText != nil { return Color.orange }
        if day.isWeekend { return Color.secondary }
        return Color.primary
    }

    // MARK: 授权提示

    private var authorizationBanner: some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.system(size: 11))
            Text(service.authorizationHint ?? "日历未授权，事件列表为空")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Spacer()
            Button("去授权") { service.openCalendarPrivacySettings() }
                .buttonStyle(.plain)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color.accentColor)
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.orange.opacity(0.1)))
    }

    // MARK: 今日事件

    private var todayEventsList: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("今日事件")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            if todayEvents.isEmpty {
                Text(service.isAuthorized ? "今天没有日程" : "授权后可显示日历事件")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 2)
            } else {
                ForEach(todayEvents) { event in
                    HStack(spacing: 6) {
                        Circle().fill(Color.accentColor).frame(width: 5, height: 5)
                        Text(event.title)
                            .font(.system(size: 11))
                            .lineLimit(1)
                        Spacer()
                        Text(event.isAllDay ? "全天" : timeText(event.startDate))
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    // MARK: 数据

    private func reload() {
        grid = service.monthDays(for: monthBase)
        todayEvents = service.todayEvents
    }

    private func shiftMonth(_ delta: Int) {
        guard let next = Calendar.current.date(byAdding: .month, value: delta, to: monthBase) else { return }
        monthBase = next
    }

    private func timeText(_ date: Date) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm"
        return fmt.string(from: date)
    }
}
