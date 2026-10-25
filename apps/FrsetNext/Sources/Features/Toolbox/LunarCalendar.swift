import Foundation

// MARK: - 农历（内置映射表实现）
//
// 实现方式说明：
// 1) 每年只需两组数据：① 正月初一对应的公历日期（"春节锚点"）；② 从正月开始的每月天数（含闰月，闰月紧跟在其同名月之后）。
//    任意公历日期 → 与春节锚点相差的天数 → 在月长数组中定位，即得农历月日。
// 2) 表覆盖 2023–2028 农历年（公历 2023-01-22 ~ 2029-02-12），满足"至少覆盖 2024-2027"的要求。
//    需要扩展年份时，只须往 `yearTable` 增加一条记录即可，无需改动算法。
// 3) 表数据来源：系统 Chinese 日历（Calendar(identifier: .chinese)）逐日导出后整理，
//    已核对 2023 闰二月、2025 闰六月、2028 闰五月等已知闰月。

public struct LunarDate {
    /// 农历年（以春节所在公历年计，用于干支/生肖换算）
    public let year: Int
    /// 农历月 1..12
    public let month: Int
    /// 农历日 1..30
    public let day: Int
    public let isLeapMonth: Bool

    public var monthName: String {
        let names = ["正月", "二月", "三月", "四月", "五月", "六月",
                     "七月", "八月", "九月", "十月", "冬月", "腊月"]
        guard month >= 1, month <= 12 else { return "\(month)月" }
        return names[month - 1]
    }

    public var dayName: String {
        let names = ["初一", "初二", "初三", "初四", "初五", "初六", "初七", "初八", "初九", "初十",
                     "十一", "十二", "十三", "十四", "十五", "十六", "十七", "十八", "十九", "二十",
                     "廿一", "廿二", "廿三", "廿四", "廿五", "廿六", "廿七", "廿八", "廿九", "三十"]
        guard day >= 1, day <= 30 else { return "\(day)日" }
        return names[day - 1]
    }

    /// 干支纪年（如 甲辰）
    public var ganzhi: String {
        let gan = ["甲", "乙", "丙", "丁", "戊", "己", "庚", "辛", "壬", "癸"]
        let zhi = ["子", "丑", "寅", "卯", "辰", "巳", "午", "未", "申", "酉", "戌", "亥"]
        let g = (year - 4) % 10
        let z = (year - 4) % 12
        return gan[(g + 10) % 10] + zhi[(z + 12) % 12]
    }

    /// 生肖（如 龙）
    public var zodiac: String {
        let animals = ["鼠", "牛", "虎", "兔", "龙", "蛇", "马", "羊", "猴", "鸡", "狗", "猪"]
        let z = (year - 4) % 12
        return animals[(z + 12) % 12]
    }

    /// 展示文本："闰六月初三" / "腊月初八"
    public var text: String {
        (isLeapMonth ? "闰" : "") + monthName + dayName
    }
}

public enum LunarCalendar {
    // MARK: 数据表

    private struct YearInfo {
        /// 正月初一的公历日期
        let spring: (year: Int, month: Int, day: Int)
        /// 从正月开始的每月天数（长度 12 或 13）
        let monthDays: [Int]
        /// 闰月在 monthDays 中的序号（1 起，0 表示无闰月）
        let leapIndex: Int
    }

    private static let yearTable: [Int: YearInfo] = [
        2023: YearInfo(spring: (2023, 1, 22),
                       monthDays: [29, 30, 29, 29, 30, 30, 29, 30, 30, 29, 30, 29, 30],
                       leapIndex: 3),                                   // 闰二月
        2024: YearInfo(spring: (2024, 2, 10),
                       monthDays: [29, 30, 29, 29, 30, 29, 30, 30, 29, 30, 30, 29],
                       leapIndex: 0),
        2025: YearInfo(spring: (2025, 1, 29),
                       monthDays: [30, 29, 30, 29, 29, 30, 29, 30, 29, 30, 30, 30, 29],
                       leapIndex: 7),                                   // 闰六月
        2026: YearInfo(spring: (2026, 2, 17),
                       monthDays: [30, 29, 30, 29, 29, 30, 29, 29, 30, 30, 30, 29],
                       leapIndex: 0),
        2027: YearInfo(spring: (2027, 2, 6),
                       monthDays: [30, 30, 29, 30, 29, 29, 30, 29, 29, 30, 30, 29],
                       leapIndex: 0),
        2028: YearInfo(spring: (2028, 1, 26),
                       monthDays: [30, 30, 30, 29, 30, 29, 29, 30, 29, 29, 30, 30, 29],
                       leapIndex: 6)                                    // 闰五月
    ]

    /// 覆盖范围上界（2028 农历年最后一个月的次日，即 2029 年春节）
    private static let upperBound = (year: 2029, month: 2, day: 13)
    private static let lowerBound = (year: 2023, month: 1, day: 22)

    /// 已覆盖年份（供设置页/调试展示）
    public static var coveredYears: ClosedRange<Int> { 2023...2028 }

    // v126（性能审计 F1395）：Calendar 构造/keys 排序外提缓存——lunarDate 被月视图
    // 42 格逐日调用，原实现每次调用都新建 3 个 Calendar 并对 yearTable.keys 全量排序。
    // （原 beijing 时区属性并入 bjCalendar，随之删除死变量）
    private static let bjCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
        return calendar
    }()
    private static let sortedYears: [Int] = yearTable.keys.sorted()

    private static func gregorianComponents(_ date: Date) -> (Int, Int, Int) {
        // v126（性能审计 F1395）：复用 bjCalendar，不再每次新建 Calendar
        let c = bjCalendar.dateComponents([.year, .month, .day], from: date)
        return (c.year ?? 1970, c.month ?? 1, c.day ?? 1)
    }

    private static func makeDate(_ y: Int, _ m: Int, _ d: Int) -> Date {
        // v126（性能审计 F1395）：复用 bjCalendar
        return bjCalendar.date(from: DateComponents(year: y, month: m, day: d)) ?? Date()
    }

    /// 两个"零时"日期之间的整日差
    private static func daysBetween(_ from: Date, _ to: Date) -> Int {
        // v126（性能审计 F1395）：复用 bjCalendar
        let a = bjCalendar.startOfDay(for: from)
        let b = bjCalendar.startOfDay(for: to)
        return bjCalendar.dateComponents([.day], from: a, to: b).day ?? 0
    }

    // MARK: 公历 → 农历

    /// 返回农历日期；超出内置表覆盖范围时返回 nil（调用方应降级为"仅显示公历"）
    public static func lunarDate(_ date: Date) -> LunarDate? {
        let (y, m, d) = gregorianComponents(date)
        // 范围判定
        if y < lowerBound.year || (y == lowerBound.year && (m, d) < (lowerBound.month, lowerBound.day)) { return nil }
        if y > upperBound.year || (y == upperBound.year && (m, d) >= (upperBound.month, upperBound.day)) { return nil }

        // 定位农历年：date ∈ [S(Y), S(Y+1))
        // v126（性能审计 F1395）：年份序改用预排序的 sortedYears（原每次调用 keys.sorted()）
        let years = Self.sortedYears
        var targetYear: Int?
        for (index, year) in years.enumerated() {
            guard let info = yearTable[year] else { continue }
            let spring = makeDate(info.spring.year, info.spring.month, info.spring.day)
            let nextSpring: Date = {
                if index + 1 < years.count, let next = yearTable[years[index + 1]] {
                    return makeDate(next.spring.year, next.spring.month, next.spring.day)
                }
                return makeDate(upperBound.year, upperBound.month, upperBound.day)
            }()
            if date >= spring && date < nextSpring { targetYear = year; break }
        }
        guard let lunarYear = targetYear, let info = yearTable[lunarYear] else { return nil }

        let spring = makeDate(info.spring.year, info.spring.month, info.spring.day)
        var offset = daysBetween(spring, date)
        for (index, length) in info.monthDays.enumerated() {
            if offset < length {
                // 月序号换算：闰月之前 index+1；闰月及其之后 index
                let month = (info.leapIndex > 0 && index >= info.leapIndex - 1) ? index : index + 1
                let isLeap = info.leapIndex > 0 && index == info.leapIndex - 1
                return LunarDate(year: lunarYear, month: month, day: offset + 1, isLeapMonth: isLeap)
            }
            offset -= length
        }
        return nil
    }

    // MARK: 二十四节气（内置表，覆盖 2024-2027；扩展只需增加年份条目）

    private static let termNames = ["小寒", "大寒", "立春", "雨水", "惊蛰", "春分", "清明", "谷雨",
                                    "立夏", "小满", "芒种", "夏至", "小暑", "大暑", "立秋", "处暑",
                                    "白露", "秋分", "寒露", "霜降", "立冬", "小雪", "大雪", "冬至"]

    /// 每年 24 个节气日期，编码为 MM*100+DD，顺序与 termNames 一致（从当年小寒起）
    private static let solarTerms: [Int: [Int]] = [
        2024: [106, 120, 204, 219, 305, 320, 404, 419, 505, 520, 605, 621,
               706, 722, 807, 822, 907, 922, 1008, 1023, 1107, 1122, 1206, 1221],
        2025: [105, 120, 203, 218, 305, 320, 404, 420, 505, 521, 605, 621,
               706, 722, 807, 823, 907, 923, 1008, 1023, 1107, 1122, 1207, 1221],
        2026: [105, 120, 204, 218, 305, 320, 405, 420, 505, 521, 605, 621,
               707, 723, 807, 823, 907, 923, 1008, 1023, 1107, 1122, 1207, 1222],
        2027: [105, 120, 204, 219, 306, 321, 405, 420, 506, 521, 606, 621,
               707, 723, 808, 823, 908, 923, 1008, 1023, 1107, 1122, 1207, 1221]
    ]

    public static var solarTermYears: [Int] { solarTerms.keys.sorted() }

    /// 返回该日期的节气名（无则返回 nil）
    public static func solarTerm(_ date: Date) -> String? {
        let (y, m, d) = gregorianComponents(date)
        guard let list = solarTerms[y] else { return nil }
        let key = m * 100 + d
        guard let index = list.firstIndex(of: key), index < termNames.count else { return nil }
        return termNames[index]
    }

    // MARK: 农历传统节日

    private static let lunarFestivals: [Int: [Int: String]] = [
        1:  [1: "春节", 15: "元宵节"],
        2:  [2: "龙抬头"],
        5:  [5: "端午节"],
        7:  [7: "七夕", 15: "中元节"],
        8:  [15: "中秋节"],
        9:  [9: "重阳节"],
        12: [8: "腊八节", 23: "小年"]
    ]

    /// 农历节日（含除夕：腊月最后一天，按当年腊月天数判定）
    public static func lunarFestival(_ lunar: LunarDate) -> String? {
        if lunar.isLeapMonth { return nil }
        if let name = lunarFestivals[lunar.month]?[lunar.day] { return name }
        if lunar.month == 12 {
            // 除夕 = 腊月最后一天（闰月年为 29 或 30）
            let days = yearTable[lunar.year]?.monthDays.last ?? 30
            if lunar.day == days { return "除夕" }
        }
        return nil
    }
}
