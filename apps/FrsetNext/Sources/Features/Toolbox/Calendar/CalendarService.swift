import Foundation
import AppKit
import EventKit

// MARK: - 日历服务（EventKit + 农历 + 节假日）
// 未授权时降级：事件列表为空，并在 UI 提供"去系统设置授权"的入口。

public final class CalendarService: ObservableObject {
    public static let shared = CalendarService()

    private let store = EKEventStore()

    @Published public private(set) var isAuthorized = false
    /// 授权相关提示（未授权 / 被拒绝时给出中文说明）
    @Published public private(set) var authorizationHint: String?

    private init() {}

    // MARK: 授权

    public var authorizationStatus: EKAuthorizationStatus {
        EKEventStore.authorizationStatus(for: .event)
    }

    /// 启动时调用：已授权直接用；未决定则请求；被拒绝则给出提示
    public func requestAccessIfNeeded() {
        refreshAuthorization()
        if authorizationStatus == .notDetermined {
            requestAccess()
        }
    }

    /// authorized 是 fullAccess 的别名；writeOnly 不允许读取日程。
    public func refreshAuthorization() {
        let granted = authorizationStatus == .authorized
        update(authorized: granted,
               hint: granted ? nil : "日历未获得读权限，事件列表将为空。可在「系统设置 → 隐私与安全性 → 日历」中开启完整访问。")
    }

    /// 启动与权限引导共用同一 EventKit Store，完成后同步日历视图。
    public func requestAccess(completion: (() -> Void)? = nil) {
        let handler: EKEventStoreRequestAccessCompletionHandler = { [weak self] _, error in
            DispatchQueue.main.async {
                self?.refreshAuthorization()
                if let error { Log.warn("Calendar", "日历授权失败：\(error.localizedDescription)") }
                completion?()
            }
        }
        if #available(macOS 14.0, *) {
            store.requestFullAccessToEvents(completion: handler)
        } else {
            store.requestAccess(to: .event, completion: handler)
        }
    }


    private func update(authorized: Bool, hint: String?) {
        isAuthorized = authorized
        authorizationHint = hint
        if !authorized, let hint { Log.warn("Calendar", hint) }
        objectWillChange.send()
    }

    // MARK: 事件读取

    public func events(from start: Date, to end: Date) -> [CalendarEvent] {
        guard isAuthorized else { return [] }
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        let ekEvents = store.events(matching: predicate)
        return ekEvents.map { e in
            CalendarEvent(id: e.eventIdentifier ?? e.calendarItemIdentifier,
                          title: e.title ?? "(无标题)",
                          startDate: e.startDate,
                          endDate: e.endDate,
                          isAllDay: e.isAllDay)
        }.sorted { $0.startDate < $1.startDate }
    }

    // MARK: 月视图数据

    /// 生成月视图网格（固定 6 行 × 7 列 = 42 天，周日起始）
    /// - Parameter base: 目标月份内的任意日期
    public func monthDays(for base: Date) -> [CalendarDay] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "zh_CN")
        calendar.firstWeekday = 1          // 周日为一周起点
        calendar.timeZone = .current

        let comps = calendar.dateComponents([.year, .month], from: base)
        guard let firstOfMonth = calendar.date(from: comps),
              let range = calendar.range(of: .day, in: .month, for: base) else { return [] }

        // 网格起点：包含 1 号的那一周的周日
        let firstWeekday = calendar.component(.weekday, from: firstOfMonth)
        guard let gridStart = calendar.date(byAdding: .day, value: -(firstWeekday - 1), to: firstOfMonth) else { return [] }

        let showLunar = Preferences.shared.calendarShowLunar
        let today = Date()

        // 一次性查询整块网格（42 天）的事件并按天分桶，避免逐日最多 31 次 EventKit 查询
        let gridEnd = calendar.date(byAdding: .day, value: 42, to: gridStart) ?? gridStart
        var eventsByDay: [Date: [CalendarEvent]] = [:]
        for event in events(from: gridStart, to: gridEnd) {
            eventsByDay[calendar.startOfDay(for: event.startDate), default: []].append(event)
        }

        var days: [CalendarDay] = []
        for index in 0..<42 {
            guard let date = calendar.date(byAdding: .day, value: index, to: gridStart) else { continue }
            let weekday = calendar.component(.weekday, from: date)
            let dayNumber = calendar.component(.day, from: date)
            let isInMonth = range.contains(dayNumber) &&
                calendar.component(.month, from: date) == (comps.month ?? 0)

            var lunarText: String?
            // v126（性能审计 F1354）：holiday(on:) 每格只算一次——原实现 lunarText 分支
            // 与 holidayText 字段各调一次（42 格 × 2 = 84 次查表 + Calendar 分量换算）。
            let holidayName = HolidayManager.holiday(on: date)
            if showLunar {
                if let holiday = holidayName {
                    lunarText = holiday
                } else if let lunar = LunarCalendar.lunarDate(date) {
                    if let festival = LunarCalendar.lunarFestival(lunar) {
                        lunarText = festival
                    } else if let term = LunarCalendar.solarTerm(date) {
                        lunarText = term
                    } else if lunar.day == 1 {
                        lunarText = lunar.isLeapMonth ? "闰\(lunar.monthName)" : lunar.monthName
                    } else {
                        lunarText = lunar.dayName
                    }
                } else if let festival = HolidayManager.festival(on: date) {
                    lunarText = festival
                }
            }

            let day = CalendarDay(date: date,
                                  isToday: calendar.isDate(date, inSameDayAs: today),
                                  isWeekend: weekday == 1 || weekday == 7,
                                  lunarText: lunarText,
                                  holidayText: holidayName,
                                  events: isInMonth ? (eventsByDay[calendar.startOfDay(for: date)] ?? []) : [])
            days.append(day)
        }
        return days
    }

    /// 月份标题："2026年10月"
    public static func monthTitle(_ date: Date) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy年M月"
        fmt.locale = Locale(identifier: "zh_CN")
        return fmt.string(from: date)
    }
}
