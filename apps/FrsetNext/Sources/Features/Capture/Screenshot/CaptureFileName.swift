import Foundation
import AppKit
import CoreGraphics

// MARK: - 文件名模板（v264 · 1Capture 的 57 条命名规则收成一套模板）
//
// 1Capture 的命名设置是一整个小系统（时间戳 / 随机 / 序号 / 前缀 / 后缀…）。
// 我们不做 57 个开关，而是给**一条模板**，占位符替换：
//
//   {yyyy} {MM} {dd} {HH} {mm} {ss}  时间片段
//   {date} {time} {timestamp}        组合片段
//   {seq} {seq:4}                    当日序号（可补零）
//   {random} {random:6}              随机串
//   {w} {h}                          像素宽高
//   {mode}                           截图模式（area/window/full/ocr…）
//   {app}                            当时前台 App 名
//
// 模板为空 / 全是非法字符时回退到内置默认值，绝不让截图因为命名失败而丢。
// 落盘前统一替换 macOS 不允许的字符，避免出现 `:`（Finder 会显示成 `/`）。

public enum CaptureFileName {

    static let keyTemplate = "capture.fileName.template"
    static let keyCounterDay = "capture.fileName.counter.day"
    static let keyCounterValue = "capture.fileName.counter.value"

    /// 默认模板与 v263 的命名保持一致（用户升级后不会被改名规则吓到）
    public static let defaultTemplate = "Screenshot-{yyyy}-{MM}-{dd}-{HH}{mm}{ss}-{random:3}"

    public static var template: String {
        get {
            let raw: String = Preferences.shared.value(keyTemplate, default: defaultTemplate)
            return raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? defaultTemplate : raw
        }
        set { Preferences.shared.set(keyTemplate, newValue) }
    }

    public static var isDefault: Bool {
        template == defaultTemplate
    }

    /// 生成一个文件名（含 .png）
    /// - Parameters:
    ///   - pixelSize: 出图尺寸（{w}/{h} 用）
    ///   - mode: 截图模式标签（area / window / full / long / ocr…）
    ///   - date: 生成时刻（测试可注入）
    public static func make(pixelSize: CGSize = .zero,
                            mode: String = "area",
                            date: Date = Date()) -> String {
        var name = expand(template: template, pixelSize: pixelSize, mode: mode, date: date)
        name = sanitize(name)
        if name.isEmpty { name = "Screenshot-\(Int(date.timeIntervalSince1970))" }
        // 扩展名：模板里自己带了就不重复加
        if name.lowercased().hasSuffix(".png") { return name }
        return name + ".png"
    }

    /// 预览（设置页用）：不消耗序号
    public static func preview(template: String, date: Date = Date()) -> String {
        let expanded = expand(template: template, pixelSize: CGSize(width: 2560, height: 1664),
                              mode: "area", date: date, consumeSequence: false)
        let clean = sanitize(expanded)
        return (clean.isEmpty ? "Screenshot" : clean) + ".png"
    }

    // MARK: 展开

    private static func expand(template: String, pixelSize: CGSize, mode: String,
                               date: Date, consumeSequence: Bool = true) -> String {
        var out = template
        let cal = Calendar.current
        let comps = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        func pad(_ v: Int?, _ n: Int = 2) -> String {
            String(format: "%0\(n)d", v ?? 0)
        }

        let map: [String: String] = [
            "{yyyy}": pad(comps.year, 4),
            "{MM}": pad(comps.month),
            "{dd}": pad(comps.day),
            "{HH}": pad(comps.hour),
            "{mm}": pad(comps.minute),
            "{ss}": pad(comps.second),
            "{date}": "\(pad(comps.year, 4))-\(pad(comps.month))-\(pad(comps.day))",
            "{time}": "\(pad(comps.hour))\(pad(comps.minute))\(pad(comps.second))",
            "{timestamp}": String(Int(date.timeIntervalSince1970)),
            "{w}": "\(Int(pixelSize.width.rounded()))",
            "{h}": "\(Int(pixelSize.height.rounded()))",
            "{mode}": mode,
            "{app}": NSWorkspaceFrontmost.name,
        ]
        // 长的先替换，避免 {date} 被 {dd} 之类先吃掉（这里键互不为前缀，但保持惯例）
        for key in map.keys.sorted(by: { $0.count > $1.count }) {
            out = out.replacingOccurrences(of: key, with: map[key] ?? "")
        }

        out = replacePattern("{seq", in: out) { pad in
            let value = nextSequence(date: date, consume: consumeSequence)
            return pad > 0 ? String(format: "%0\(pad)d", value) : "\(value)"
        }
        out = replacePattern("{random", in: out) { digits in
            let n = digits > 0 ? digits : 3
            var s = ""
            for _ in 0..<n { s.append(String(Int.random(in: 0...9))) }
            return s
        }
        return out
    }

    /// 处理 `{seq}` / `{seq:4}` 这类带参数的占位符。
    ///
    /// 注意 token 传的是**不含右花括号的前缀**（"{seq"）：`{seq:4}` 的 `:` 在
    /// 花括号里面，按 "{seq}" 去找永远匹配不到——v264 第一版就是这么错的，
    /// 结果文件名里留下了字面量 `{random.3}`（冒号被 sanitize 成了点）。
    private static func replacePattern(_ prefix: String, in text: String,
                                       transform: (Int) -> String) -> String {
        var out = text
        var searchStart = out.startIndex
        while let range = out.range(of: prefix, range: searchStart..<out.endIndex) {
            var cursor = range.upperBound
            var digits = 0
            var end: String.Index
            if cursor < out.endIndex, out[cursor] == "}" {
                end = out.index(after: cursor)
            } else if cursor < out.endIndex, out[cursor] == ":" {
                var i = out.index(after: cursor)
                var num = ""
                while i < out.endIndex, out[i].isNumber {
                    num.append(out[i])
                    i = out.index(after: i)
                }
                guard !num.isEmpty, i < out.endIndex, out[i] == "}" else {
                    // 不是合法的 {xxx:N} 形式（比如 "abc{seq" 这种半截文本）→ 跳过
                    searchStart = range.upperBound
                    continue
                }
                digits = Int(num) ?? 0
                end = out.index(after: i)
            } else {
                searchStart = range.upperBound
                continue
            }
            let replacement = transform(digits)
            out.replaceSubrange(range.lowerBound..<end, with: replacement)
            searchStart = out.index(range.lowerBound, offsetBy: replacement.count)
        }
        return out
    }

    // MARK: 序号

    private static func nextSequence(date: Date, consume: Bool) -> Int {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyyMMdd"
        let day = fmt.string(from: date)
        let storedDay: String = Preferences.shared.value(keyCounterDay, default: "")
        var value: Int = storedDay == day ? Preferences.shared.value(keyCounterValue, default: 0) : 0
        if consume {
            value += 1
            Preferences.shared.set(keyCounterDay, day)
            Preferences.shared.set(keyCounterValue, value)
        } else {
            value += 1
        }
        return value
    }

    // MARK: 清洗

    /// 替换 macOS HFS/APFS 不允许的字符，并把「看起来会误会」的符号换掉
    static func sanitize(_ raw: String) -> String {
        var name = raw
        let illegal: [Character: String] = [
            "/": "-", ":": ".", "\\": "-", "?": "", "*": "", "|": "-",
            "\"": "'", "<": "", ">": "", "\n": " ", "\t": " ",
        ]
        var out = ""
        for ch in name {
            if let rep = illegal[ch] { out += rep } else { out.append(ch) }
        }
        name = out
        // 首尾的点和空格在 Finder 里会被隐藏/截断
        name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        while name.hasPrefix(".") { name.removeFirst() }
        if name.count > 180 { name = String(name.prefix(180)) }
        return name
    }
}

/// 前台 App 名（{app} 用；不引 NSWorkspace 到模板核心之外）
private enum NSWorkspaceFrontmost {
    static var name: String {
        #if canImport(AppKit)
        return NSWorkspace.shared.frontmostApplication?.localizedName ?? "Kitnest"
        #else
        return "Kitnest"
        #endif
    }
}
