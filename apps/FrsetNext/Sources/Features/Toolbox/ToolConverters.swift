import Foundation
import AppKit

// MARK: - 纯逻辑转换器集合（无 UI、无副作用，便于单测）

// MARK: 时间戳转换

public enum TimestampConverter {
    /// 自动识别：纯数字 → 按位数判定秒/毫秒/微秒/纳秒并输出日期；否则按日期字符串 → 输出各精度时间戳
    /// direction: 自动 / 时间戳→日期 / 日期→时间戳
    public static func convert(_ raw: String, direction: String) -> String {
        let input = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        if direction == "日期→时间戳" { return dateToTimestamp(input) }
        if direction == "时间戳→日期" { return timestampToDate(input) }

        // 自动：空输入输出"当前时间"全景
        if input.isEmpty { return timestampToDate(String(Int64(Date().timeIntervalSince1970))) }

        // 纯整数（可带负号）视为时间戳
        let body = input.hasPrefix("-") ? String(input.dropFirst()) : input
        if !body.isEmpty && body.allSatisfy({ $0.isNumber }) {
            return timestampToDate(input)
        }
        return dateToTimestamp(input)
    }

    /// 时间戳 → 日期（同时给出各精度换算，便于对照）
    public static func timestampToDate(_ raw: String) -> String {
        guard let value = Int64(raw.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return "无法识别的时间戳：\(raw)（请输入整数，如 1700000000 或 1700000000000）"
        }
        let digits = (value < 0 ? String(-value) : String(value)).count
        let seconds: Double
        let guessed: String
        switch digits {
        case ..<11:      seconds = Double(value);               guessed = "秒"
        case 11..<14:    seconds = Double(value) / 1_000;       guessed = "毫秒"
        case 14..<17:    seconds = Double(value) / 1_000_000;   guessed = "微秒"
        default:         seconds = Double(value) / 1_000_000_000; guessed = "纳秒"
        }
        let date = Date(timeIntervalSince1970: seconds)
        var lines: [String] = []
        lines.append("识别精度：\(guessed)")
        lines.append("本地时间：\(format(date, zone: .current))")
        lines.append("UTC 时间：\(format(date, zone: TimeZone(identifier: "UTC")))")
        lines.append("相对时间：\(date.relativeText)")
        lines.append("秒：\(Int64(seconds))")
        lines.append("毫秒：\(Int64(seconds * 1_000))")
        lines.append("纳秒：\(Int64(seconds * 1_000_000_000))")
        return lines.joined(separator: "\n")
    }

    /// 日期 → 时间戳（支持常见中文 / 斜杠 / 横杠格式）
    public static func dateToTimestamp(_ raw: String) -> String {
        let input = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if input.isEmpty {
            let now = Date()
            return "当前时间戳\n秒：\(Int64(now.timeIntervalSince1970))\n毫秒：\(Int64(now.timeIntervalSince1970 * 1_000))"
        }
        let patterns = ["yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm", "yyyy-MM-dd",
                        "yyyy/MM/dd HH:mm:ss", "yyyy/MM/dd HH:mm", "yyyy/MM/dd",
                        "yyyy年M月d日 HH:mm:ss", "yyyy年M月d日", "yyyy.MM.dd"]
        for pattern in patterns {
            let fmt = DateFormatter()
            fmt.dateFormat = pattern
            fmt.locale = Locale(identifier: "zh_CN")
            fmt.timeZone = .current
            if let date = fmt.date(from: input) {
                var lines: [String] = []
                lines.append("解析格式：\(pattern)")
                lines.append("秒：\(Int64(date.timeIntervalSince1970))")
                lines.append("毫秒：\(Int64(date.timeIntervalSince1970 * 1_000))")
                lines.append("纳秒：\(Int64(date.timeIntervalSince1970 * 1_000_000_000))")
                lines.append("本地时间：\(format(date, zone: .current))")
                return lines.joined(separator: "\n")
            }
        }
        return "未能解析日期：\(input)\n支持示例：2025-03-01 12:00:00 / 2025/03/01 / 2025年3月1日"
    }

    private static func format(_ date: Date, zone: TimeZone?) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd HH:mm:ss (EEE)"
        fmt.locale = Locale(identifier: "zh_CN")
        fmt.timeZone = zone ?? .current
        return fmt.string(from: date)
    }
}

// MARK: 变量名转换

public enum VarNameStyle: String, CaseIterable, Sendable {
    case camel      = "camelCase"
    case pascal     = "PascalCase"
    case snake      = "snake_case"
    case kebab      = "kebab-case"
    case upperSnake = "UPPER_SNAKE"

    public static var titles: [String] { allCases.map { $0.rawValue } }
}

public enum VarNameConverter {
    /// 拆词：先按非字母数字切分，再在大写边界（HTTPServer → HTTP / Server）切分
    public static func tokenize(_ text: String) -> [String] {
        var rough: [String] = []
        var buffer = ""
        for ch in text {
            if ch.isLetter || ch.isNumber {
                buffer.append(ch)
            } else {
                if !buffer.isEmpty { rough.append(buffer); buffer = "" }
            }
        }
        if !buffer.isEmpty { rough.append(buffer) }

        var tokens: [String] = []
        for word in rough {
            var current = ""
            let chars = Array(word)
            for i in 0..<chars.count {
                let c = chars[i]
                let isUpper = c.isUppercase
                let prevUpper = i > 0 ? chars[i - 1].isUppercase : false
                let nextLower = i + 1 < chars.count ? chars[i + 1].isLowercase : false
                // 新词起点：大写且（前一个小写，或下一个是小写且前一个也是大写，如 HTTPServer）
                if isUpper && !current.isEmpty && (!prevUpper || nextLower) {
                    tokens.append(current); current = String(c)
                } else {
                    current.append(c)
                }
            }
            if !current.isEmpty { tokens.append(current) }
        }
        return tokens.map { $0.lowercased() }.filter { !$0.isEmpty }
    }

    public static func convert(_ text: String, to style: VarNameStyle) -> String {
        let tokens = tokenize(text)
        guard !tokens.isEmpty else { return "" }
        switch style {
        case .camel:
            return tokens.first! + tokens.dropFirst().map { $0.capitalized }.joined()
        case .pascal:
            return tokens.map { $0.capitalized }.joined()
        case .snake:
            return tokens.joined(separator: "_")
        case .kebab:
            return tokens.joined(separator: "-")
        case .upperSnake:
            return tokens.map { $0.uppercased() }.joined(separator: "_")
        }
    }
}

// MARK: Base64 编解码（UTF-8 中文）

public enum Base64Coder {
    public static func encode(_ text: String) -> String {
        Data(text.utf8).base64EncodedString()
    }

    /// 返回 (文本, 错误信息)。非法输入给出中文提示而非崩溃
    public static func decode(_ text: String) -> (String, String?) {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return ("", "请输入待解码的 Base64 文本") }
        // 补齐缺失的 '=' 填充，容忍从 URL 复制过来的场景
        var padded = cleaned
        let remainder = padded.count % 4
        if remainder == 2 { padded += "==" } else if remainder == 3 { padded += "=" }

        guard let data = Data(base64Encoded: padded, options: [.ignoreUnknownCharacters]) else {
            return ("", "Base64 解码失败：内容不是合法的 Base64（请检查是否混入空格、换行或非法字符）")
        }
        guard let text = String(data: data, encoding: .utf8) else {
            return ("", "Base64 解码成功，但结果不是 UTF-8 文本（可能是图片等二进制数据，共 \(data.count) 字节）")
        }
        return (text, nil)
    }
}

// MARK: URL 编解码

public enum URLEncoderTool {
    /// 严格字符集：只保留 unreserved（A-Z a-z 0-9 - . _ ~）
    private static var strictAllowed: CharacterSet = {
        var set = CharacterSet.alphanumerics
        set.insert(charactersIn: "-._~")
        return set
    }()

    public static func encode(_ text: String, strict: Bool) -> String {
        let allowed: CharacterSet = strict ? strictAllowed : .urlQueryAllowed
        return text.addingPercentEncoding(withAllowedCharacters: allowed) ?? text
    }

    public static func decode(_ text: String) -> (String, String?) {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return ("", "请输入待解码的 URL 文本") }
        guard let decoded = cleaned.removingPercentEncoding else {
            return ("", "URL 解码失败：存在非法的百分号转义序列（如 %zz）")
        }
        return (decoded, nil)
    }
}

// MARK: JSON 格式化 / 压缩

public enum JSONFormatterTool {
    /// 返回 (结果, 中文错误)。mode: 格式化 / 压缩
    public static func process(_ text: String, pretty: Bool) -> (String, String?) {
        let input = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return ("", "请输入 JSON 文本") }

        do {
            let object = try JSONSerialization.jsonObject(with: Data(input.utf8), options: [])
            var options: JSONSerialization.WritingOptions = [.withoutEscapingSlashes]
            if pretty { options.insert(.prettyPrinted); options.insert(.sortedKeys) }
            let data = try JSONSerialization.data(withJSONObject: object, options: options)
            guard let result = String(data: data, encoding: .utf8) else {
                return ("", "JSON 生成失败：无法以 UTF-8 输出")
            }
            return (result, nil)
        } catch {
            return ("", Self.chineseDescription(error))
        }
    }

    /// 把系统英文报错转成可理解的中文提示
    static func chineseDescription(_ error: Error) -> String {
        let ns = error as NSError
        var detail = ns.userInfo["NSDebugDescription"] as? String ?? ns.localizedDescription
        if detail.isEmpty { detail = "未知语法错误" }
        return "JSON 语法错误：\(detail)\n请检查：引号是否成对、末尾是否多出逗号、对象/数组括号是否匹配。"
    }
}

// MARK: 哈希生成（MD5 / SHA1 / SHA256，全部纯 Swift 自实现）
// 注意：MD5 / SHA1 已不适合安全用途，本实现仅用于文件/文本校验比对。
//
// 关于 SHA256：原计划直接复用 Core/Support 的 String.sha256，但实测该实现存在越界崩溃
// （每个 64 字节分组里按 16×8=128 字节读取消息，输入不足 128 字节时 Index out of range）。
// 契约禁止修改 Core，因此本模块自带一份正确的 sha256，并在注释中标注，待 Core 修复后可切回。

public enum HashGenerator {
    public static func digest(_ text: String, algorithm: String) -> String {
        let bytes = Array(text.utf8)
        switch algorithm {
        case "MD5":    return md5(bytes)
        case "SHA1":   return sha1(bytes)
        default:       return sha256(bytes)
        }
    }

    // MARK: SHA256（FIPS 180-4）

    private static let sha256K: [UInt32] = [
        0x428a2f98,0x71374491,0xb5c0fbcf,0xe9b5dba5,0x3956c25b,0x59f111f1,0x923f82a4,0xab1c5ed5,
        0xd807aa98,0x12835b01,0x243185be,0x550c7dc3,0x72be5d74,0x80deb1fe,0x9bdc06a7,0xc19bf174,
        0xe49b69c1,0xefbe4786,0x0fc19dc6,0x240ca1cc,0x2de92c6f,0x4a7484aa,0x5cb0a9dc,0x76f988da,
        0x983e5152,0xa831c66d,0xb00327c8,0xbf597fc7,0xc6e00bf3,0xd5a79147,0x06ca6351,0x14292967,
        0x27b70a85,0x2e1b2138,0x4d2c6dfc,0x53380d13,0x650a7354,0x766a0abb,0x81c2c92e,0x92722c85,
        0xa2bfe8a1,0xa81a664b,0xc24b8b70,0xc76c51a3,0xd192e819,0xd6990624,0xf40e3585,0x106aa070,
        0x19a4c116,0x1e376c08,0x2748774c,0x34b0bcb5,0x391c0cb3,0x4ed8aa4a,0x5b9cca4f,0x682e6ff3,
        0x748f82ee,0x78a5636f,0x84c87814,0x8cc70208,0x90befffa,0xa4506ceb,0xbef9a3f7,0xc67178f2
    ]

    public static func sha256(_ bytes: [UInt8]) -> String {
        var h: [UInt32] = [0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
                           0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19]
        var msg = bytes
        msg.append(0x80)
        while msg.count % 64 != 56 { msg.append(0) }
        let bitLen = UInt64(bytes.count) * 8
        for i in stride(from: 56, through: 0, by: -8) { msg.append(UInt8((bitLen >> UInt64(i)) & 0xff)) }

        for chunk in stride(from: 0, to: msg.count, by: 64) {
            var w = [UInt32](repeating: 0, count: 64)
            for i in 0..<16 {
                w[i] = (UInt32(msg[chunk + i * 4]) << 24) |
                       (UInt32(msg[chunk + i * 4 + 1]) << 16) |
                       (UInt32(msg[chunk + i * 4 + 2]) << 8) |
                        UInt32(msg[chunk + i * 4 + 3])
            }
            for i in 16..<64 {
                let s0 = rotateRight(w[i - 15], 7) ^ rotateRight(w[i - 15], 18) ^ (w[i - 15] >> 3)
                let s1 = rotateRight(w[i - 2], 17) ^ rotateRight(w[i - 2], 19) ^ (w[i - 2] >> 10)
                w[i] = w[i - 16] &+ s0 &+ w[i - 7] &+ s1
            }
            var a = h[0], b = h[1], c = h[2], d = h[3], e = h[4], f = h[5], g = h[6], hh = h[7]
            for i in 0..<64 {
                let s1 = rotateRight(e, 6) ^ rotateRight(e, 11) ^ rotateRight(e, 25)
                let ch = (e & f) ^ (~e & g)
                let t1 = hh &+ s1 &+ ch &+ sha256K[i] &+ w[i]
                let s0 = rotateRight(a, 2) ^ rotateRight(a, 13) ^ rotateRight(a, 22)
                let maj = (a & b) ^ (a & c) ^ (b & c)
                let t2 = s0 &+ maj
                hh = g; g = f; f = e; e = d &+ t1
                d = c; c = b; b = a; a = t1 &+ t2
            }
            h[0] = h[0] &+ a; h[1] = h[1] &+ b; h[2] = h[2] &+ c; h[3] = h[3] &+ d
            h[4] = h[4] &+ e; h[5] = h[5] &+ f; h[6] = h[6] &+ g; h[7] = h[7] &+ hh
        }
        return h.map { String(format: "%08x", $0) }.joined()
    }

    private static func rotateRight(_ value: UInt32, _ bits: UInt32) -> UInt32 {
        (value >> bits) | (value << (32 - bits))
    }

    // MARK: MD5（RFC 1321，纯 Swift，避免 CommonCrypto 链接问题）

    public static func md5(_ bytes: [UInt8]) -> String {
        var h: [UInt32] = [0x67452301, 0xefcdab89, 0x98badcfe, 0x10325476]
        var msg = bytes
        msg.append(0x80)
        while msg.count % 64 != 56 { msg.append(0) }
        let bitLen = UInt64(bytes.count) * 8
        for i in stride(from: 0, to: 64, by: 8) { msg.append(UInt8((bitLen >> UInt64(i)) & 0xff)) }

        let shifts: [UInt32] = [7,12,17,22, 7,12,17,22, 7,12,17,22, 7,12,17,22,
                                5,9,14,20,  5,9,14,20,  5,9,14,20,  5,9,14,20,
                                4,11,16,23, 4,11,16,23, 4,11,16,23, 4,11,16,23,
                                6,10,15,21, 6,10,15,21, 6,10,15,21, 6,10,15,21]

        for chunk in stride(from: 0, to: msg.count, by: 64) {
            var m = [UInt32](repeating: 0, count: 16)
            for i in 0..<16 {
                m[i] = UInt32(msg[chunk + i * 4]) |
                      (UInt32(msg[chunk + i * 4 + 1]) << 8) |
                      (UInt32(msg[chunk + i * 4 + 2]) << 16) |
                      (UInt32(msg[chunk + i * 4 + 3]) << 24)
            }
            var a = h[0], b = h[1], c = h[2], d = h[3]
            for i in 0..<64 {
                var f: UInt32
                var g: Int
                switch i / 16 {
                case 0: f = (b & c) | (~b & d); g = i
                case 1: f = (d & b) | (~d & c); g = (5 * i + 1) % 16
                case 2: f = b ^ c ^ d;          g = (3 * i + 5) % 16
                default: f = c ^ (b | ~d);      g = (7 * i) % 16
                }
                let k = UInt32((abs(sin(Double(i + 1))) * 4294967296.0).truncatingRemainder(dividingBy: 4294967296.0))
                f = f &+ a &+ k &+ m[g]
                a = d; d = c; c = b
                b = b &+ rotateLeft(f, shifts[i])
            }
            h[0] = h[0] &+ a; h[1] = h[1] &+ b; h[2] = h[2] &+ c; h[3] = h[3] &+ d
        }
        // MD5 输出为小端字节序
        return h.map { v in
            [UInt8(v & 0xff), UInt8((v >> 8) & 0xff), UInt8((v >> 16) & 0xff), UInt8((v >> 24) & 0xff)]
                .map { String(format: "%02x", $0) }.joined()
        }.joined()
    }

    // MARK: SHA1（RFC 3174，纯 Swift）

    public static func sha1(_ bytes: [UInt8]) -> String {
        var h: [UInt32] = [0x67452301, 0xEFCDAB89, 0x98BADCFE, 0x10325476, 0xC3D2E1F0]
        var msg = bytes
        msg.append(0x80)
        while msg.count % 64 != 56 { msg.append(0) }
        let bitLen = UInt64(bytes.count) * 8
        for i in stride(from: 56, through: 0, by: -8) { msg.append(UInt8((bitLen >> UInt64(i)) & 0xff)) }

        for chunk in stride(from: 0, to: msg.count, by: 64) {
            var w = [UInt32](repeating: 0, count: 80)
            for i in 0..<16 {
                w[i] = (UInt32(msg[chunk + i * 4]) << 24) |
                       (UInt32(msg[chunk + i * 4 + 1]) << 16) |
                       (UInt32(msg[chunk + i * 4 + 2]) << 8) |
                        UInt32(msg[chunk + i * 4 + 3])
            }
            for i in 16..<80 {
                w[i] = rotateLeft(w[i - 3] ^ w[i - 8] ^ w[i - 14] ^ w[i - 16], 1)
            }
            var a = h[0], b = h[1], c = h[2], d = h[3], e = h[4]
            for i in 0..<80 {
                var f: UInt32
                var k: UInt32
                switch i / 20 {
                case 0: f = (b & c) | (~b & d); k = 0x5A827999
                case 1: f = b ^ c ^ d;          k = 0x6ED9EBA1
                case 2: f = (b & c) | (b & d) | (c & d); k = 0x8F1BBCDC
                default: f = b ^ c ^ d;         k = 0xCA62C1D6
                }
                let temp = rotateLeft(a, 5) &+ f &+ e &+ k &+ w[i]
                e = d; d = c; c = rotateLeft(b, 30); b = a; a = temp
            }
            h[0] = h[0] &+ a; h[1] = h[1] &+ b; h[2] = h[2] &+ c
            h[3] = h[3] &+ d; h[4] = h[4] &+ e
        }
        return h.map { String(format: "%08x", $0) }.joined()
    }

    private static func rotateLeft(_ value: UInt32, _ bits: UInt32) -> UInt32 {
        (value << bits) | (value >> (32 - bits))
    }
}

// MARK: 代码预览（轻量关键字着色）

public enum CodeLanguage: String, CaseIterable, Sendable {
    case swift, python, javascript, json, plain

    public static var titles: [String] { ["swift", "python", "javascript", "json", "plain"] }

    public var keywords: Set<String> {
        switch self {
        case .swift:
            return ["import","func","var","let","class","struct","enum","protocol","extension",
                    "guard","if","else","for","in","while","return","self","init","deinit",
                    "public","private","fileprivate","internal","static","final","override",
                    "async","await","do","try","catch","throw","throws","switch","case","default",
                    "nil","true","false","typealias","where","as","is","super","lazy","weak"]
        case .python:
            return ["def","class","import","from","as","if","elif","else","for","while","return",
                    "yield","with","try","except","finally","raise","lambda","pass","break",
                    "continue","global","nonlocal","assert","del","in","is","not","and","or",
                    "None","True","False","self","async","await"]
        case .javascript:
            return ["function","const","let","var","class","extends","new","return","if","else",
                    "for","while","switch","case","default","break","continue","try","catch",
                    "finally","throw","typeof","instanceof","import","export","from","async",
                    "await","this","null","undefined","true","false","delete","in","of"]
        case .json:
            return ["true","false","null"]
        case .plain:
            return []
        }
    }

    /// 行注释前缀（python 用 #，其余用 //）
    public var lineComment: String { self == .python ? "#" : "//" }
}

public enum CodeHighlighter {
    public enum TokenKind {
        case plain, keyword, comment, string, number
    }

    /// 极简扫描器：注释 / 字符串 / 数字 / 标识符关键字
    public static func tokenize(_ code: String, language: CodeLanguage) -> [(NSRange, TokenKind)] {
        var tokens: [(NSRange, TokenKind)] = []
        let chars = Array(code)
        let n = chars.count
        var i = 0
        var plainStart = 0

        func flushPlain(_ end: Int) {
            if end > plainStart { tokens.append((NSRange(location: plainStart, length: end - plainStart), .plain)) }
        }

        while i < n {
            let c = chars[i]
            // 行注释
            if c == "/" && i + 1 < n && chars[i + 1] == "/" && language != .python {
                flushPlain(i)
                var j = i
                while j < n && chars[j] != "\n" { j += 1 }
                tokens.append((NSRange(location: i, length: j - i), .comment))
                i = j; plainStart = i; continue
            }
            // 块注释
            if c == "/" && i + 1 < n && chars[i + 1] == "*" {
                flushPlain(i)
                var j = i + 2
                while j + 1 < n && !(chars[j] == "*" && chars[j + 1] == "/") { j += 1 }
                j = min(n, j + 2)
                tokens.append((NSRange(location: i, length: j - i), .comment))
                i = j; plainStart = i; continue
            }
            if c == "#" && language == .python {
                flushPlain(i)
                var j = i
                while j < n && chars[j] != "\n" { j += 1 }
                tokens.append((NSRange(location: i, length: j - i), .comment))
                i = j; plainStart = i; continue
            }
            // 字符串（单引号 / 双引号，支持反斜杠转义）
            if c == "\"" || c == "'" {
                flushPlain(i)
                let quote = c
                var j = i + 1
                while j < n {
                    if chars[j] == "\\" { j += 2; continue }
                    if chars[j] == quote { j += 1; break }
                    j += 1
                }
                j = min(j, n)
                tokens.append((NSRange(location: i, length: j - i), .string))
                i = j; plainStart = i; continue
            }
            // 数字
            if c.isNumber {
                flushPlain(i)
                var j = i
                while j < n && (chars[j].isNumber || chars[j] == "." || chars[j] == "x") { j += 1 }
                tokens.append((NSRange(location: i, length: j - i), .number))
                i = j; plainStart = i; continue
            }
            // 标识符
            if c.isLetter || c == "_" {
                var j = i
                while j < n && (chars[j].isLetter || chars[j].isNumber || chars[j] == "_") { j += 1 }
                let word = String(chars[i..<j])
                if language.keywords.contains(word) {
                    flushPlain(i)
                    tokens.append((NSRange(location: i, length: j - i), .keyword))
                    i = j; plainStart = i; continue
                }
                i = j; continue
            }
            i += 1
        }
        flushPlain(n)
        return tokens
    }

    /// 生成带颜色的富文本（SwiftUI 用 AttributedString，AppKit 用 NSAttributedString）
    public static func attributed(_ code: String, language: CodeLanguage) -> NSAttributedString {
        let result = NSMutableAttributedString(string: code)
        // v126（性能审计 F1480）：NSString 长度只桥接计算一次（原 3 次）
        let nsLength = (code as NSString).length
        let baseFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        result.addAttribute(.font, value: baseFont, range: NSRange(location: 0, length: nsLength))
        result.addAttribute(.foregroundColor, value: NSColor.labelColor,
                            range: NSRange(location: 0, length: nsLength))
        for (range, kind) in tokenize(code, language: language) {
            guard range.location + range.length <= nsLength else { continue }
            result.addAttribute(.foregroundColor, value: color(for: kind), range: range)
        }
        return result
    }

    static func color(for kind: TokenKind) -> NSColor {
        switch kind {
        case .plain:   return NSColor.labelColor
        case .keyword: return NSColor.systemPurple
        case .comment: return NSColor.systemGreen
        case .string:  return NSColor.systemOrange
        case .number:  return NSColor.systemBlue
        }
    }

    /// 把代码渲染成一张"卡片图"（浅色卡片 + 圆角 + 行号），用于预览 / 复制为图片
    public static func cardImage(code: String, language: CodeLanguage, width: CGFloat = 640) -> NSImage? {
        let attributed = attributed(code, language: language)
        let inset: CGFloat = 16
        let maxWidth = width - inset * 2
        let measuring = NSTextStorage(attributedString: attributed)
        let layout = NSLayoutManager()
        measuring.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: maxWidth, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)
        layout.glyphRange(for: container)
        let textHeight = layout.usedRect(for: container).height
        let height = max(textHeight + inset * 2, 120)

        let image = NSImage(size: NSSize(width: width, height: height))
        image.lockFocusFlipped(false)
        let rect = NSRect(origin: .zero, size: NSSize(width: width, height: height))
        let path = NSBezierPath(roundedRect: rect, xRadius: 10, yRadius: 10)
        NSColor(calibratedWhite: 0.13, alpha: 1).setFill()
        path.fill()
        attributed.draw(in: NSRect(x: inset, y: inset, width: maxWidth, height: textHeight))
        image.unlockFocus()
        return image
    }
}
