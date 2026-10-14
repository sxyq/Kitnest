import Foundation

// MARK: - 中国法定节假日（内置表）
//
// 数据来源：国务院办公厅公布的年度放假安排（含调休后的实际放假区间）。
// 当前内置 2025、2026 两个年度；扩展方式：往 `holidays` 增加一年即可。
// 说明：这里记录的是"放假区间"（含调休形成的连续假期），不是法定节假日本身的名目天数。

public enum HolidayManager {
    /// 已覆盖年度（供设置页展示，对应原作偏好键 HolidayManager_coveredYears 的语义）
    public static let coveredYears = "2025-2026"

    private struct Range {
        let name: String
        let startMMdd: Int
        let endMMdd: Int
    }

    private static let holidays: [Int: [Range]] = [
        2025: [
            Range(name: "元旦", startMMdd: 101, endMMdd: 101),
            Range(name: "春节", startMMdd: 128, endMMdd: 204),
            Range(name: "清明节", startMMdd: 404, endMMdd: 406),
            Range(name: "劳动节", startMMdd: 501, endMMdd: 505),
            Range(name: "端午节", startMMdd: 531, endMMdd: 602),
            Range(name: "国庆·中秋", startMMdd: 1001, endMMdd: 1008)
        ],
        2026: [
            Range(name: "元旦", startMMdd: 101, endMMdd: 103),
            Range(name: "春节", startMMdd: 215, endMMdd: 223),
            Range(name: "清明节", startMMdd: 404, endMMdd: 406),
            Range(name: "劳动节", startMMdd: 501, endMMdd: 505),
            Range(name: "端午节", startMMdd: 619, endMMdd: 621),
            Range(name: "中秋节", startMMdd: 925, endMMdd: 927),
            Range(name: "国庆节", startMMdd: 1001, endMMdd: 1007)
        ]
    ]

    /// 公历节日（非放假的纪念日也一并标注，便于日历小字显示）
    private static let solarFestivals: [Int: String] = [
        101: "元旦", 308: "妇女节", 312: "植树节", 501: "劳动节",
        601: "儿童节", 910: "教师节", 1001: "国庆节"
    ]

    public static var coveredYearList: [Int] { holidays.keys.sorted() }

    /// 返回该日期所处的法定放假区间名（如"春节"）；不在假期内返回 nil
    public static func holiday(on date: Date) -> String? {
        let (y, m, d) = components(date)
        guard let list = holidays[y] else { return nil }
        let key = m * 100 + d
        return list.first(where: { key >= $0.startMMdd && key <= $0.endMMdd })?.name
    }

    /// 公历节日名（如"教师节"）
    public static func festival(on date: Date) -> String? {
        let (_, m, d) = components(date)
        return solarFestivals[m * 100 + d]
    }

    /// 该日期是否在法定放假区间内
    public static func isOnLeave(_ date: Date) -> Bool { holiday(on: date) != nil }

    private static func components(_ date: Date) -> (Int, Int, Int) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return (c.year ?? 1970, c.month ?? 1, c.day ?? 1)
    }
}
