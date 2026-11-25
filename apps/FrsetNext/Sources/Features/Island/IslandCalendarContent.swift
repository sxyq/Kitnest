// 本文件由 IslandContent.swift 拆出（2026-11-23 文档体系整理，纯类型搬家，无行为变化）。
import AppKit
import EventKit
import SwiftUI
import UniformTypeIdentifiers

struct IslandCalendarContent: View {
    @ObservedObject var controller: IslandController
    @Binding var selectedDate: Date
    let previewOnly: Bool
    var size: IslandWidgetSize? = nil
    @AppStorage(Preferences.Keys.calendarFirstWeekday) private var firstWeekday = 1
    @Stored private var sampleDays: [CalendarDay] = []

    private var previewCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "zh_CN")
        calendar.firstWeekday = firstWeekday
        calendar.timeZone = .current
        return calendar
    }

    private var previewEvents: [CalendarEvent] {
        let calendar = previewCalendar
        let base = calendar.startOfDay(for: SettingsPreviewSamples.date)
        func event(_ id: String, _ title: String, _ offset: Int, _ hour: Int, _ minute: Int) -> CalendarEvent {
            let day = calendar.date(byAdding: .day, value: offset, to: base)!
            let start = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day)!
            return CalendarEvent(id: id, title: title, startDate: start)
        }
        return [
            event("island-preview-sync", "项目同步", 0, 14, 0),
            event("island-preview-review", "设计评审", 0, 16, 30),
            event("island-preview-plan", "交付计划", 3, 10, 0),
            event("island-preview-review-two", "需求梳理", 8, 15, 0)
        ]
    }

    private var previewDays: [CalendarDay] {
        let calendar = previewCalendar
        let components = calendar.dateComponents([.year, .month], from: selectedDate)
        guard let firstOfMonth = calendar.date(from: components) else { return [] }
        let weekday = calendar.component(.weekday, from: firstOfMonth)
        let offset = (weekday - firstWeekday + 7) % 7
        guard let start = calendar.date(byAdding: .day, value: -offset, to: firstOfMonth) else { return [] }
        let eventsByDay = Dictionary(grouping: previewEvents) { calendar.startOfDay(for: $0.startDate) }
        return (0..<42).compactMap { index in
            guard let date = calendar.date(byAdding: .day, value: index, to: start) else { return nil }
            let dayStart = calendar.startOfDay(for: date)
            let weekday = calendar.component(.weekday, from: date)
            return CalendarDay(date: date,
                              isToday: calendar.isDate(date, inSameDayAs: SettingsPreviewSamples.date),
                              isWeekend: weekday == 1 || weekday == 7,
                              events: eventsByDay[dayStart] ?? [])
        }
    }

    var body: some View {
        Group {
            if previewOnly {
                let days = sampleDays
                IslandLiveCalendarContent.calendarLayout(
                    controller: controller, selectedDate: selectedDate, size: size,
                    firstWeekday: firstWeekday, calendar: previewCalendar, days: days,
                    events: days.first(where: { previewCalendar.isDate($0.date, inSameDayAs: selectedDate) })?.events ?? [],
                    isAuthorized: true, authorizationHint: nil,
                    onSelectDate: { selectedDate = $0 },
                    onMoveDay: { movePreviewDate(.day, by: $0) },
                    onMoveMonth: { movePreviewDate(.month, by: $0) },
                    onToday: { selectedDate = SettingsPreviewSamples.date },
                    onCopyDate: copySelectedDate
                )
            } else {
                IslandLiveCalendarContent(controller: controller, selectedDate: $selectedDate,
                                          size: size, firstWeekday: firstWeekday,
                                          onCopyDate: copySelectedDate)
            }
        }
        .onAppear { if previewOnly { sampleDays = previewDays } }
        .onChange(of: firstWeekday) { _ in if previewOnly { sampleDays = previewDays } }
        .onChange(of: selectedDate) { date in
            if previewOnly, let anchor = sampleDays.dropFirst(14).first,
               !previewCalendar.isDate(anchor.date, equalTo: date, toGranularity: .month) {
                sampleDays = previewDays
            }
        }
    }

    private func movePreviewDate(_ component: Calendar.Component, by value: Int) {
        if let date = previewCalendar.date(byAdding: component, value: value, to: selectedDate) {
            selectedDate = date
        }
    }

    private func copySelectedDate() {
        let value = selectedDate.formatted(.iso8601.year().month().day().dateSeparator(.dash))
        if previewOnly {
            controller.feedback = "日期复制预览"
        } else {
            controller.feedback = ClipboardManager.shared.copyText(value, successMessage: "已复制日期 " + value)
                ?? "已复制日期 " + value
        }
    }
}

private struct IslandLiveCalendarContent: View {
    @ObservedObject var controller: IslandController
    @Binding var selectedDate: Date
    var size: IslandWidgetSize?
    let firstWeekday: Int
    let onCopyDate: () -> Void
    @ObservedObject private var calendar = CalendarService.shared
    @Stored private var days: [CalendarDay] = []
    @Stored private var events: [CalendarEvent] = []

    private var usesMonthGrid: Bool { size == nil || size == .square }

    var body: some View {
        Self.calendarLayout(
            controller: controller, selectedDate: selectedDate, size: size,
            firstWeekday: firstWeekday, calendar: CalendarService.calendar(firstWeekday: firstWeekday),
            days: days, events: events,
            isAuthorized: calendar.isAuthorized, authorizationHint: calendar.authorizationHint,
            onSelectDate: selectDate,
            onMoveDay: { moveDate(.day, by: $0) },
            onMoveMonth: { moveDate(.month, by: $0) },
            onToday: { selectedDate = Date.now; reload() },
            onCopyDate: onCopyDate
        )
        .onAppear { reload() }
        .onChange(of: size) { _ in reload() }
        .onChange(of: firstWeekday) { _ in reload() }
        .onChange(of: calendar.isAuthorized) { _ in reload() }
        .onReceive(NotificationCenter.default.publisher(for: .EKEventStoreChanged)) { _ in reload() }
    }

    fileprivate static func calendarLayout(
        controller: IslandController, selectedDate: Date, size: IslandWidgetSize?,
        firstWeekday: Int, calendar: Calendar, days: [CalendarDay], events: [CalendarEvent],
        isAuthorized: Bool, authorizationHint: String?,
        onSelectDate: @escaping (Date) -> Void,
        onMoveDay: @escaping (Int) -> Void,
        onMoveMonth: @escaping (Int) -> Void,
        onToday: @escaping () -> Void,
        onCopyDate: @escaping () -> Void
    ) -> some View {
        let accent = controller.configuration.color(for: .calendar)
        return Group {
            if size == nil {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Button { onMoveMonth(-1) } label: { Image(systemName: "chevron.left") }
                        Text(monthTitle(selectedDate)).font(.system(size: 14, weight: .medium))
                        Button { onMoveMonth(1) } label: { Image(systemName: "chevron.right") }
                        Spacer()
                        Button("今天", action: onToday)
                    }.buttonStyle(IslandButtonStyle())
                    HStack(alignment: .top, spacing: 12) {
                        monthGrid(days: days, selectedDate: selectedDate, calendar: calendar,
                                  firstWeekday: firstWeekday, accent: accent, compact: false,
                                  onSelectDate: onSelectDate)
                            .frame(maxWidth: .infinity)
                        ScrollView {
                            eventRows(events, isAuthorized: isAuthorized,
                                      authorizationHint: authorizationHint, limit: nil, compact: false)
                        }.frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    HStack {
                        Text(fullDate(selectedDate)).font(.system(size: 11)).foregroundStyle(.secondary)
                        Spacer()
                        Button("复制所选日期", action: onCopyDate)
                            .font(.system(size: 11)).buttonStyle(IslandButtonStyle())
                    }
                }
            } else if size == .small {
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(monthDay(selectedDate)).font(.system(size: 17, weight: .semibold))
                        Text(weekdayTitle(selectedDate)).font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 2)
                    HStack(spacing: 2) {
                        Button { onMoveDay(-1) } label: { Image(systemName: "chevron.left") }
                            .help("前一天")
                        Button(action: onCopyDate) { Image(systemName: "doc.on.doc") }
                            .help("复制日期")
                        Button { onMoveDay(1) } label: { Image(systemName: "chevron.right") }
                            .help("后一天")
                    }.buttonStyle(IslandButtonStyle())
                }
            } else if size == .wide {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(monthDay(selectedDate)).font(.system(size: 14, weight: .medium))
                        Text(weekdayTitle(selectedDate)).font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    Rectangle().fill(.white.opacity(0.12)).frame(width: 1).padding(.vertical, 10)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("日程摘要").font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                        eventRows(events, isAuthorized: isAuthorized,
                                  authorizationHint: authorizationHint, limit: 2, compact: true)
                    }
                    Spacer(minLength: 0)
                }
            } else if size == .tall {
                VStack(alignment: .leading, spacing: 7) {
                    HStack {
                        Text(fullDate(selectedDate)).font(.system(size: 11, weight: .medium))
                        Spacer()
                        Button(action: onCopyDate) { Image(systemName: "doc.on.doc") }
                            .help("复制日期")
                    }.buttonStyle(IslandButtonStyle())
                    eventRows(events, isAuthorized: isAuthorized,
                              authorizationHint: authorizationHint, limit: 4, compact: true)
                    Spacer(minLength: 0)
                }
            } else if size == .strip {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(monthDay(selectedDate)).font(.system(size: 13, weight: .medium))
                        Text(weekdayTitle(selectedDate)).font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    Rectangle().fill(.white.opacity(0.12)).frame(width: 1).padding(.vertical, 8)
                    if events.isEmpty {
                        eventRows(events, isAuthorized: isAuthorized,
                                  authorizationHint: authorizationHint, limit: 0, compact: true)
                    } else {
                        HStack(alignment: .top, spacing: 14) {
                            ForEach(Array(events.prefix(3))) { event in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(event.title).font(.system(size: 11)).lineLimit(1)
                                    Text(eventTime(event)).font(.system(size: 10)).foregroundStyle(.secondary)
                                }.frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                    Spacer(minLength: 0)
                }
            } else {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 5) {
                        Button { onMoveMonth(-1) } label: { Image(systemName: "chevron.left") }
                        Text(monthTitle(selectedDate)).font(.system(size: 11, weight: .medium))
                        Button { onMoveMonth(1) } label: { Image(systemName: "chevron.right") }
                        Spacer(minLength: 0)
                        Button(action: onCopyDate) { Image(systemName: "doc.on.doc") }
                            .help("复制日期")
                    }.buttonStyle(IslandButtonStyle())
                    monthGrid(days: days, selectedDate: selectedDate, calendar: calendar,
                              firstWeekday: firstWeekday, accent: accent, compact: true,
                              onSelectDate: onSelectDate)
                    HStack(spacing: 6) {
                        Text(fullDate(selectedDate)).font(.system(size: 9)).foregroundStyle(.secondary)
                        if let event = events.first {
                            Text(event.title).font(.system(size: 9)).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                }
            }
        }
    }

    private static func monthGrid(
        days: [CalendarDay], selectedDate: Date, calendar: Calendar,
        firstWeekday: Int, accent: Color, compact: Bool,
        onSelectDate: @escaping (Date) -> Void
    ) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: compact ? 1 : 3), count: 7),
                  spacing: compact ? 1 : 3) {
            ForEach(0..<7, id: \.self) { index in
                let weekday = (index + firstWeekday - 1) % 7
                Text(["日", "一", "二", "三", "四", "五", "六"][weekday])
                    .font(.system(size: compact ? 8 : 10, weight: .medium))
                    .foregroundStyle(weekday == 0 || weekday == 6 ? .secondary : .primary)
                    .frame(maxWidth: .infinity)
            }
            ForEach(days) { day in
                let inMonth = calendar.isDate(day.date, equalTo: selectedDate, toGranularity: .month)
                let selected = calendar.isDate(day.date, inSameDayAs: selectedDate)
                Button { onSelectDate(day.date) } label: {
                    VStack(spacing: compact ? 0 : 2) {
                        Text(day.date.formatted(.dateTime.day()))
                            .font(.system(size: compact ? 9 : 11, weight: day.isToday ? .bold : .regular))
                        if compact {
                            Circle().fill(day.events.isEmpty ? Color.clear : accent)
                                .frame(width: 3, height: 3)
                        } else {
                            Text(day.holidayText ?? day.lunarText ?? "")
                                .font(.system(size: 9)).lineLimit(1).foregroundStyle(.secondary)
                        }
                    }
                    .foregroundStyle(day.isWeekend || !inMonth ? .secondary : .primary)
                    .frame(maxWidth: .infinity).frame(height: compact ? 18 : 31)
                    .background(selected ? accent.opacity(0.2) : .clear,
                                in: RoundedRectangle(cornerRadius: IslandLayout.controlRadius, style: .continuous))
                }.buttonStyle(IslandButtonStyle())
            }
        }
    }

    private static func eventRows(
        _ events: [CalendarEvent], isAuthorized: Bool, authorizationHint: String?,
        limit: Int?, compact: Bool
    ) -> some View {
        Group {
            if let authorizationHint {
                Text(authorizationHint).font(.system(size: 10)).foregroundStyle(.secondary)
            } else if events.isEmpty {
                Text(isAuthorized ? "暂无日程" : "日历尚未授权")
                    .font(.system(size: compact ? 10 : 11)).foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: compact ? 4 : 8) {
                    ForEach(Array(events.prefix(limit ?? events.count))) { event in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(eventTime(event)).font(.system(size: 10)).foregroundStyle(.secondary)
                            Text(event.title).font(.system(size: compact ? 10 : 11))
                                .lineLimit(compact ? 1 : nil)
                        }
                    }
                }
            }
        }
    }

    private static func monthTitle(_ date: Date) -> String {
        date.formatted(.dateTime.year().month().locale(Locale(identifier: "zh_CN")))
    }

    private static func monthDay(_ date: Date) -> String {
        date.formatted(.dateTime.month().day().locale(Locale(identifier: "zh_CN")))
    }

    private static func weekdayTitle(_ date: Date) -> String {
        date.formatted(.dateTime.weekday(.wide).locale(Locale(identifier: "zh_CN")))
    }

    private static func fullDate(_ date: Date) -> String {
        date.formatted(.dateTime.year().month().day().weekday(.wide).locale(Locale(identifier: "zh_CN")))
    }

    private static func eventTime(_ event: CalendarEvent) -> String {
        event.isAllDay ? "全天" : event.startDate.formatted(.dateTime.hour().minute())
    }

    private func selectDate(_ date: Date) {
        let monthChanged = !Calendar.current.isDate(date, equalTo: selectedDate, toGranularity: .month)
        selectedDate = date
        if monthChanged { reload() } else { reloadEvents() }
    }

    private func moveDate(_ component: Calendar.Component, by value: Int) {
        if let date = Calendar.current.date(byAdding: component, value: value, to: selectedDate) {
            selectedDate = date
            reload()
        }
    }

    private func reload() {
        if usesMonthGrid { days = calendar.monthDays(for: selectedDate, firstWeekday: firstWeekday) }
        reloadEvents()
    }

    private func reloadEvents() {
        if usesMonthGrid, let day = days.first(where: { Calendar.current.isDate($0.date, inSameDayAs: selectedDate) }) {
            events = day.events
            return
        }
        let start = Calendar.current.startOfDay(for: selectedDate)
        if let end = Calendar.current.date(byAdding: .day, value: 1, to: start) {
            events = calendar.events(from: start, to: end)
        }
    }
}
