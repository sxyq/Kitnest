import Foundation

// MARK: - 轻量词法着色器（零依赖、单遍扫描）
//
// 为什么自己写而不是引第三方：本项目用 swiftc 直编、无 SPM 依赖；同时预览
// 常在 hover 时触发，不能为了一次着色去热启动一个语法库。
//
// 做法：
//   ① 第一遍沿 UTF-16 代码单元扫描，标出**注释**与**字符串**（这两种必须吃掉
//      内部所有内容，否则字符串里的 "#" / "//" 会被误判成注释）；
//   ② 第二遍扫标识符 / 数字 / 标点，按语言关键字表、位置特征（后跟 "(" 是函数、
//      前有 "." 是成员、后跟 ":" 是属性）着色；
//   ③ 压缩成「同色连续区间」，只输出非 plain 段（高亮器铺底色时不用逐字符）。
//
// 覆盖：Swift / ObjC / C / C++ / C# / Java / Kotlin / Go / Rust / Python / Ruby /
//      PHP / JS / TS / Dart / Lua / Perl / R / MATLAB / SQL / Shell / PowerShell /
//      HTML / XML / CSS / SCSS / JSON / YAML / TOML / Markdown / Diff / Asm。

public enum CodeTokenKind: UInt8 {
    case plain = 0
    case keyword
    case type
    case function
    case property
    case string
    case number
    case comment
    case attribute
    case punctuation
}

public struct CodeToken {
    public let range: NSRange
    public let kind: CodeTokenKind
}

public enum CodeLexer {

    /// 超过这个长度不再着色（长日志/大文件保流畅；纯文本也能看）
    public static let maxHighlightLength = 300_000

    // MARK: 入口

    public static func tokens(in code: String, language: String) -> [CodeToken] {
        let langID = CodeLanguageCatalog.normalize(language) ?? language
        let spec = Spec.forLanguage(langID)
        let units = Array(code.utf16)
        guard !units.isEmpty, units.count <= maxHighlightLength else { return [] }

        var marks = [UInt8](repeating: 0, count: units.count)
        if spec.diffMode {
            markDiff(units: units, marks: &marks)
        } else {
            markCommentsAndStrings(units: units, marks: &marks, spec: spec)
        }
        markWordsAndNumbers(units: units, marks: &marks, spec: spec)
        if spec.lineBasedMarkdown { markMarkdownLines(units: units, marks: &marks) }
        return compress(marks: marks)
    }

    // MARK: 第一遍：注释与字符串

    private static func markCommentsAndStrings(units: [UInt16], marks: inout [UInt8], spec: Spec) {
        let n = units.count
        let comment = CodeTokenKind.comment.rawValue
        let string = CodeTokenKind.string.rawValue
        var i = 0

        while i < n {
            // 块注释：/* */ 、<!-- --> 、""" """
            var matchedBlock = false
            for pair in spec.blockComments where matches(units, at: i, marker: pair.open) {
                let start = i
                i += pair.open.count
                while i < n && !matches(units, at: i, marker: pair.close) { i += 1 }
                if i < n { i += pair.close.count }
                fill(&marks, from: start, to: min(i, n), value: comment)
                matchedBlock = true
                break
            }
            if matchedBlock { continue }

            // 行注释：// 、# 、-- 、;
            var matchedLine = false
            for marker in spec.lineComments where matches(units, at: i, marker: marker) {
                // "#" 作为行注释时，C 系的前置指令（#include/#define）不算注释
                if marker == spec.preprocessorMarker { break }
                let start = i
                while i < n && units[i] != 10 { i += 1 }
                fill(&marks, from: start, to: i, value: comment)
                matchedLine = true
                break
            }
            if matchedLine { continue }

            // 前置指令：#include / #define / #if（整行按 attribute 着色）
            if spec.preprocessorMarker != nil,
               units[i] == 35,                       // '#'
               isFirstNonSpaceOnLine(units, index: i) {
                let start = i
                while i < n && units[i] != 10 { i += 1 }
                fill(&marks, from: start, to: i, value: CodeTokenKind.attribute.rawValue)
                continue
            }

            // 字符串
            if let quote = spec.quoteUnits.first(where: { $0 == units[i] }) {
                let start = i
                let triple = spec.supportsTripleQuote
                    && i + 2 < n && units[i + 1] == quote && units[i + 2] == quote
                if triple {
                    i += 3
                    while i < n {
                        if units[i] == quote, i + 2 < n, units[i + 1] == quote, units[i + 2] == quote {
                            i += 3
                            break
                        }
                        i += 1
                    }
                } else {
                    i += 1
                    while i < n {
                        let u = units[i]
                        if spec.escapeEnabled, u == 92 { i = min(n, i + 2); continue }  // 反斜杠转义
                        if u == quote { i += 1; break }
                        if u == 10 { break }     // 单行字符串不跨行（未闭合时到此为止）
                        i += 1
                    }
                }
                fill(&marks, from: start, to: min(i, n), value: string)
                continue
            }
            i += 1
        }
    }

    // MARK: 第二遍：标识符 / 数字 / 宏

    private static func markWordsAndNumbers(units: [UInt16], marks: inout [UInt8], spec: Spec) {
        let n = units.count
        var i = 0
        var inTag = false          // 标记语言（HTML/XML）的标签内状态
        var lastMeaningful: UInt16 = 0   // 上一个非空白字符（判成员访问 / 属性）

        while i < n {
            if marks[i] != 0 {
                if units[i] != 32 && units[i] != 9 { lastMeaningful = units[i] }
                i += 1
                continue
            }
            let u = units[i]

            // 标记语言：<tag / </tag / <tag ... >
            if spec.markup, u == 60 {   // '<'
                inTag = true
                marks[i] = CodeTokenKind.punctuation.rawValue
                lastMeaningful = u
                i += 1
                continue
            }
            if spec.markup, inTag, u == 62 {   // '>'
                inTag = false
                marks[i] = CodeTokenKind.punctuation.rawValue
                lastMeaningful = u
                i += 1
                continue
            }

            // 语言特性标记：@State / @interface / @Override（连同后面的名字一起着色）
            if u == 64, i + 1 < n, isWordStart(units[i + 1]) {
                let start = i
                i += 1
                while i < n && isWordBody(units[i]) { i += 1 }
                fill(&marks, from: start, to: i, value: CodeTokenKind.attribute.rawValue)
                lastMeaningful = units[i - 1]
                continue
            }

            if isWordStart(u) {
                let start = i
                i += 1
                while i < n && isWordBody(units[i]) { i += 1 }
                let word = String(decoding: units[start..<i], as: UTF16.self)
                let lower = spec.caseInsensitive ? word.lowercased() : word
                var kind: CodeTokenKind = .plain

                if spec.keywords.contains(lower) {
                    kind = .keyword
                } else if spec.types.contains(lower) {
                    kind = .type
                } else if spec.markup, inTag {
                    // 标签内：attr= / 紧跟 < 的标签名
                    if nextMeaningful(units, from: i) == 61 {      // '='
                        kind = .attribute
                    } else if lastMeaningful == 60 || lastMeaningful == 47 {  // '<' 或 '/'
                        kind = .type
                    }
                } else if spec.propertyBeforeColon, nextMeaningful(units, from: i) == 58 {
                    kind = .property
                } else if spec.propertyBeforeEquals, nextMeaningful(units, from: i) == 61 {
                    kind = .property
                } else if nextMeaningful(units, from: i) == 40 {   // '('
                    kind = .function
                } else if lastMeaningful == 46 {                   // '.'
                    kind = .property
                } else if spec.autoTypes, let first = word.first, first.isUppercase,
                          word.count >= 2, word != word.uppercased() {
                    kind = .type
                }

                if kind != .plain {
                    fill(&marks, from: start, to: i, value: kind.rawValue)
                }
                lastMeaningful = units[i - 1]
                continue
            }

            if isDigit(u) {
                let start = i
                i += 1
                while i < n {
                    let c = units[i]
                    let hexish = (c >= 48 && c <= 57) || (c >= 65 && c <= 70) || (c >= 97 && c <= 102)
                    if hexish || c == 46 || c == 95 || c == 120 || c == 88 { i += 1; continue }
                    break
                }
                fill(&marks, from: start, to: i, value: CodeTokenKind.number.rawValue)
                lastMeaningful = units[i - 1]
                continue
            }

            if u > 32 { lastMeaningful = u }
            i += 1
        }
    }

    // MARK: Diff / Markdown 的行级特例

    private static func markDiff(units: [UInt16], marks: inout [UInt8]) {
        let n = units.count
        var lineStart = 0
        while lineStart < n {
            var lineEnd = lineStart
            while lineEnd < n && units[lineEnd] != 10 { lineEnd += 1 }
            var first = lineStart
            while first < lineEnd && (units[first] == 32 || units[first] == 9) { first += 1 }
            guard first < lineEnd else { lineStart = lineEnd + 1; continue }
            let head = units[first]
            let kind: CodeTokenKind?
            switch head {
            case 43: kind = .string        // '+'
            case 45: kind = .keyword       // '-'
            case 64: kind = .attribute     // '@@'
            default: kind = nil
            }
            if let kind {
                fill(&marks, from: first, to: lineEnd, value: kind.rawValue)
            } else if first + 3 < lineEnd,
                      matches(units, at: first, marker: [100, 105, 102, 102]),   // diff
                      marks[first] == 0 {
                fill(&marks, from: first, to: lineEnd, value: CodeTokenKind.comment.rawValue)
            }
            lineStart = lineEnd + 1
        }
    }

    private static func markMarkdownLines(units: [UInt16], marks: inout [UInt8]) {
        let n = units.count
        var lineStart = 0
        while lineStart < n {
            var lineEnd = lineStart
            while lineEnd < n && units[lineEnd] != 10 { lineEnd += 1 }
            var first = lineStart
            while first < lineEnd && (units[first] == 32 || units[first] == 9) { first += 1 }

            if first < lineEnd, units[first] == 35 {                        // '#'
                fill(&marks, from: first, to: lineEnd, value: CodeTokenKind.keyword.rawValue)
            } else if first + 1 < lineEnd,
                      matches(units, at: first, marker: [96, 96, 96]) {     // ```
                fill(&marks, from: first, to: lineEnd, value: CodeTokenKind.comment.rawValue)
            } else if first + 2 < lineEnd,
                      matches(units, at: first, marker: [45, 45, 45]) {     // ---
                fill(&marks, from: first, to: lineEnd, value: CodeTokenKind.comment.rawValue)
            } else if first < lineEnd, units[first] == 62 {                 // '>'
                fill(&marks, from: first, to: lineEnd, value: CodeTokenKind.comment.rawValue)
            }
            lineStart = lineEnd + 1
        }
    }

    // MARK: 工具

    private static func compress(marks: [UInt8]) -> [CodeToken] {
        var out: [CodeToken] = []
        var i = 0
        let n = marks.count
        while i < n {
            let v = marks[i]
            if v == 0 { i += 1; continue }
            let start = i
            while i < n && marks[i] == v { i += 1 }
            guard let kind = CodeTokenKind(rawValue: v) else { continue }
            out.append(CodeToken(range: NSRange(location: start, length: i - start), kind: kind))
        }
        return out
    }

    private static func fill(_ marks: inout [UInt8], from start: Int, to end: Int, value: UInt8) {
        guard start < end, start >= 0 else { return }
        let upper = min(end, marks.count)
        for i in start..<upper { marks[i] = value }
    }

    private static func matches(_ units: [UInt16], at index: Int, marker: [UInt16]) -> Bool {
        guard index + marker.count <= units.count else { return false }
        for k in 0..<marker.count where units[index + k] != marker[k] { return false }
        return true
    }

    /// 字符串形态的标记（"/*"、"#" 等）转成 UTF-16 单元再匹配
    private static func matches(_ units: [UInt16], at index: Int, marker: String) -> Bool {
        matches(units, at: index, marker: Array(marker.utf16))
    }

    private static func isFirstNonSpaceOnLine(_ units: [UInt16], index: Int) -> Bool {
        var j = index - 1
        while j >= 0 {
            if units[j] == 10 { return true }
            if units[j] != 32 && units[j] != 9 { return false }
            j -= 1
        }
        return true
    }

    private static func nextMeaningful(_ units: [UInt16], from index: Int) -> UInt16? {
        var j = index
        // 最多向前看 12 个字符（跳过空白，但不跨行）
        var guardCount = 0
        while j < units.count, guardCount < 12 {
            let u = units[j]
            if u == 10 { return nil }
            if u != 32 && u != 9 { return u }
            j += 1
            guardCount += 1
        }
        return nil
    }

    private static func isWordStart(_ u: UInt16) -> Bool {
        (u >= 65 && u <= 90) || (u >= 97 && u <= 122) || u == 95 || u == 36 || u > 127
    }

    private static func isWordBody(_ u: UInt16) -> Bool {
        isWordStart(u) || (u >= 48 && u <= 57) || u == 45
    }

    private static func isDigit(_ u: UInt16) -> Bool { u >= 48 && u <= 57 }

    // MARK: 语言配置

    struct Spec {
        var keywords: Set<String> = []
        var types: Set<String> = []
        var lineComments: [String] = []
        var blockComments: [(open: String, close: String)] = []
        var quoteUnits: [UInt16] = []
        var supportsTripleQuote = false
        var escapeEnabled = true
        var caseInsensitive = false
        var autoTypes = true
        var markup = false
        var propertyBeforeColon = false
        var propertyBeforeEquals = false
        var lineBasedMarkdown = false
        var diffMode = false
        /// 用于 "#" 前置指令的语言（C 系 / Swift）
        var preprocessorMarker: String?

        static func forLanguage(_ id: String) -> Spec {
            var s = Spec()
            func q(_ chars: String) { s.quoteUnits = chars.utf16.map { $0 } }

            switch id {
            case "swift":
                s.keywords = set("func let var class struct enum protocol extension import if else guard switch case default for while repeat break continue return nil true false try catch throw throws async await actor some any in where self super init deinit public private fileprivate internal open static mutating override final lazy weak unowned typealias associatedtype subscript operator precedencegroup nonisolated convenience required dynamic indirect isolated")
                s.types = set("Int String Double Float Bool Array Dictionary Set Optional Result Void Any AnyObject Never Character UInt Int8 Int16 Int32 Int64 Error Codable Hashable Equatable Comparable Identifiable")
                s.lineComments = ["//"]
                s.blockComments = [("/*", "*/")]
                q("\"")
                s.supportsTripleQuote = true
                s.preprocessorMarker = "#"
            case "objc":
                s.keywords = set("@interface @implementation @end @property @synthesize @dynamic @protocol @class @selector @encode @try @catch @finally @throw @autoreleasepool @synchronized if else for while do switch case default break continue return self super nil YES NO id instancetype typeof sizeof")
                s.types = set("void int char float double BOOL NSInteger NSUInteger CGFloat CGRect CGPoint CGSize NSString NSArray NSDictionary NSObject NSError NSData NSURL UIView NSWindow NSColor NSFont")
                s.lineComments = ["//"]
                s.blockComments = [("/*", "*/")]
                q("\"")
                s.preprocessorMarker = "#"
            case "c":
                s.keywords = set("int char float double void struct union enum typedef static const unsigned signed long short if else for while do switch case default break continue return sizeof goto extern volatile inline register restrict true false NULL")
                s.types = set("size_t int8_t int16_t int32_t int64_t uint8_t uint16_t uint32_t uint64_t FILE va_list bool")
                s.lineComments = ["//"]
                s.blockComments = [("/*", "*/")]
                q("\"\'")
                s.preprocessorMarker = "#"
            case "cpp":
                s.keywords = set("int char float double void struct class enum typedef static const constexpr unsigned signed long short if else for while do switch case default break continue return sizeof namespace using template typename public private protected virtual override new delete nullptr auto true false try catch throw const_cast static_cast dynamic_cast reinterpret_cast this operator friend explicit mutable decltype noexcept concept requires")
                s.types = set("std string vector map set unordered_map unique_ptr shared_ptr size_t int8_t uint8_t int32_t int64_t uint64_t bool")
                s.lineComments = ["//"]
                s.blockComments = [("/*", "*/")]
                q("\"\'")
                s.preprocessorMarker = "#"
            case "csharp":
                s.keywords = set("using namespace class struct interface enum public private protected internal static readonly const sealed abstract virtual override async await var new return if else for foreach while do switch case default break continue try catch finally throw null true false this base out ref in params is as typeof sizeof lock yield get set record init")
                s.types = set("int long short byte sbyte uint ulong float double decimal bool string char object void Task List Dictionary IEnumerable Exception Console")
                s.lineComments = ["//"]
                s.blockComments = [("/*", "*/")]
                q("\"\'")
                s.preprocessorMarker = "#"
            case "java":
                s.keywords = set("public private protected class interface enum extends implements static final abstract synchronized volatile transient native void int long short byte char boolean float double if else for while do switch case default break continue return new null true false try catch finally throw throws import package this super instanceof record var yield")
                s.types = set("String Integer Long Double Float Boolean Object List Map Set ArrayList HashMap Exception System Math Thread")
                s.lineComments = ["//"]
                s.blockComments = [("/*", "*/")]
                q("\"\'")
            case "kotlin":
                s.keywords = set("fun val var class object interface data sealed enum if else when for while do break continue return try catch finally throw import package is as in null true false override open private public protected internal companion init constructor suspend inline lateinit by where this super")
                s.types = set("Int Long Short Byte Float Double Boolean String Char Any Unit List Map Set Array Exception")
                s.lineComments = ["//"]
                s.blockComments = [("/*", "*/")]
                q("\"")
                s.supportsTripleQuote = true
            case "go":
                s.keywords = set("func package import var const type struct interface map chan go defer select switch case default if else for range break continue return nil true false make new len cap append copy delete panic recover fallthrough goto")
                s.types = set("int int8 int16 int32 int64 uint uint8 uint16 uint32 uint64 float32 float64 string bool byte rune error any complex64 complex128")
                s.lineComments = ["//"]
                s.blockComments = [("/*", "*/")]
                q("\"`\'")
                s.autoTypes = false
            case "rust":
                s.keywords = set("fn let mut const static struct enum trait impl use mod pub crate self super if else match for while loop break continue return true false Some None Ok Err unsafe async await move ref type where dyn box as in extern")
                s.types = set("i8 i16 i32 i64 i128 u8 u16 u32 u64 u128 f32 f64 bool char str String Vec Option Result Box HashMap")
                s.lineComments = ["//"]
                s.blockComments = [("/*", "*/")]
                q("\"")
            case "python":
                s.keywords = set("def class import from as if elif else for while break continue return yield lambda try except finally raise with pass None True False and or not in is global nonlocal assert del async await match case")
                s.types = set("int float str bool list dict set tuple bytes bytearray object type Exception ValueError TypeError NoneType self")
                s.lineComments = ["#"]
                s.blockComments = [("\"\"\"", "\"\"\""), ("'''", "'''")]
                q("\"\'")
                s.supportsTripleQuote = true
            case "ruby":
                s.keywords = set("def end class module if elsif else unless while until for in do begin rescue ensure raise return yield break next redo retry self nil true false and or not then when case require require_relative attr_accessor attr_reader attr_writer puts")
                s.types = set("String Integer Float Array Hash Symbol Range Proc Exception")
                s.lineComments = ["#"]
                q("\"\'")
            case "php":
                s.keywords = set("function class interface trait extends implements public private protected static abstract final const new return if elseif else for foreach while do switch case default break continue try catch finally throw echo print require require_once include include_once use namespace null true false this self parent")
                s.types = set("int float string bool array object callable iterable void mixed")
                s.lineComments = ["//", "#"]
                s.blockComments = [("/*", "*/")]
                q("\"\'")
            case "javascript", "typescript":
                s.keywords = set("function const let var class extends implements interface type enum namespace import export from default if else for while do switch case break continue return new null undefined true false try catch finally throw typeof instanceof delete void in of this super yield async await static get set public private protected readonly as satisfies declare abstract constructor")
                s.types = set("String Number Boolean Object Array Promise Map Set Date RegExp Error JSON Math console document window any unknown never void string number boolean object symbol bigint")
                s.lineComments = ["//"]
                s.blockComments = [("/*", "*/")]
                q("\"\'`")
                s.supportsTripleQuote = false
            case "dart":
                s.keywords = set("void class abstract extends implements mixin with import library part export if else for while do switch case default break continue return new const final var late static async await yield try catch finally throw this super null true false get set required")
                s.types = set("int double num String bool List Map Set Future Stream Object dynamic var")
                s.lineComments = ["//"]
                s.blockComments = [("/*", "*/")]
                q("\"\'")
            case "lua":
                s.keywords = set("function end local if then else elseif for while do repeat until return break nil true false and or not in goto")
                s.types = set("string number boolean table")
                s.lineComments = ["--"]
                s.blockComments = [("--[[", "]]")]
                q("\"\'")
            case "perl":
                s.keywords = set("sub my our local if elsif else unless while until for foreach do return use require package last next redo undef true false and or not")
                s.types = set("")
                s.lineComments = ["#"]
                q("\"\'")
            case "r":
                s.keywords = set("function if else for while repeat break next return library require TRUE FALSE NULL NA Inf")
                s.types = set("numeric character logical integer double list data.frame matrix factor vector")
                s.lineComments = ["#"]
                q("\"\'")
            case "matlab":
                s.keywords = set("function if elseif else for while break continue return end switch case otherwise try catch global persistent classdef properties methods")
                s.types = set("double single int8 int16 int32 int64 uint8 uint16 uint32 uint64 logical char cell struct table")
                s.lineComments = ["%"]
                s.blockComments = [("%{", "%}")]
                q("\"\'")
            case "sql":
                s.keywords = set("select from where insert into values update set delete create table alter drop index view join left right inner outer full on group by order having limit offset as and or not null is in like between distinct union all case when then else end exists primary key foreign references default unique constraint begin commit rollback transaction")
                s.types = set("int integer bigint smallint varchar nvarchar char text date datetime timestamp decimal numeric float double boolean blob")
                s.lineComments = ["--"]
                s.blockComments = [("/*", "*/")]
                q("\"\'")
                s.caseInsensitive = true
                s.autoTypes = false
            case "shell":
                s.keywords = set("if then else elif fi for while until do done case esac function return exit export local readonly source alias unset shift set declare typeset break continue in")
                s.types = set("echo cd ls grep awk sed cat chmod mkdir pwd rm mv cp touch sudo curl wget git docker ssh scp find xargs tee head tail sort uniq wc")
                s.lineComments = ["#"]
                q("\"\'`")
            case "powershell":
                s.keywords = set("function param if else elseif foreach for while do switch return begin process end try catch finally throw filter in not and or true false null")
                s.types = set("Get-ChildItem Set-Location Get-Content Write-Host Write-Output Where-Object ForEach-Object Select-Object New-Item Remove-Item Copy-Item Move-Item Test-Path")
                s.lineComments = ["#"]
                s.blockComments = [("<#", "#>")]
                q("\"\'")
                s.caseInsensitive = true
            case "html", "xml":
                s.keywords = set("")
                s.types = set("")
                s.blockComments = [("<!--", "-->")]
                q("\"\'")
                s.markup = true
                s.autoTypes = false
            case "css", "scss":
                s.keywords = set("important media import charset keyframes font-face supports layer")
                s.types = set("px em rem vh vw percent calc var rgba rgb hsl url none auto inherit initial unset block flex grid absolute relative fixed sticky")
                s.lineComments = ["//"]
                s.blockComments = [("/*", "*/")]
                q("\"\'")
                s.propertyBeforeColon = true
                s.autoTypes = false
            case "json":
                s.keywords = set("true false null")
                s.lineComments = ["//"]
                s.blockComments = [("/*", "*/")]
                q("\"")
                s.autoTypes = false
            case "yaml":
                s.keywords = set("true false null yes no on off")
                s.lineComments = ["#"]
                q("\"\'")
                s.propertyBeforeColon = true
                s.autoTypes = false
            case "toml":
                s.keywords = set("true false")
                s.lineComments = ["#"]
                q("\"\'")
                s.propertyBeforeEquals = true
                s.autoTypes = false
            case "markdown":
                s.lineComments = []
                q("\"`")
                s.lineBasedMarkdown = true
                s.autoTypes = false
            case "diff":
                s.diffMode = true
                s.autoTypes = false
            case "asm":
                s.keywords = set("mov add sub mul div push pop call ret jmp je jne jz jnz cmp test lea inc dec and or xor not shl shr section global extern")
                s.types = set("eax ebx ecx edx esi edi esp ebp rax rbx rcx rdx rsi rdi rsp rbp")
                s.lineComments = [";", "#"]
                s.autoTypes = false
            default:
                s.keywords = set("if else for while return func function class struct let var const import def true false null nil new")
                s.lineComments = ["//"]
                s.blockComments = [("/*", "*/")]
                q("\"\'")
            }
            return s
        }

        static func set(_ text: String) -> Set<String> {
            Set(text.split(separator: " ").map(String.init))
        }

        /// 空集合（给上面 cpp 那种「先赋值再覆盖」的写法兜底）
        static var blank: Set<String> { [] }
    }
}
