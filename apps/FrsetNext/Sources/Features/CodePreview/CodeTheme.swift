import AppKit

// MARK: - 代码配色主题（对齐 highlightcode.com 的「框内换风格」）
//
// 每个主题是一整套**显式十六进制色**，不跟随系统语义色——代码块的观感
// 必须由主题自己决定（深色主题在浅色系统下也要是深色，否则白底彩字读不清）。
//
// 主题列表：GitHub 亮/暗、One Dark、Dracula、Nord、Solarized 亮/暗、Monokai、
//          Atom Light、Xcode、VS Code Dark+、Tokyo Night、Catppuccin Mocha、Material Ocean。

public struct CodeTheme: Identifiable, Equatable {

    public let id: String
    public let name: String
    public let isDark: Bool

    /// 代码区底色 / 行号槽底色 / 分隔线
    public let background: NSColor
    public let gutter: NSColor
    public let border: NSColor

    public let plain: NSColor
    public let keyword: NSColor
    public let type: NSColor
    public let function: NSColor
    public let property: NSColor
    public let string: NSColor
    public let number: NSColor
    public let comment: NSColor
    public let attribute: NSColor
    public let punctuation: NSColor
    /// 行号数字
    public let lineNumber: NSColor

    public static func == (lhs: CodeTheme, rhs: CodeTheme) -> Bool { lhs.id == rhs.id }

    public func color(for kind: CodeTokenKind) -> NSColor {
        switch kind {
        case .plain:      return plain
        case .keyword:    return keyword
        case .type:       return type
        case .function:   return function
        case .property:   return property
        case .string:     return string
        case .number:     return number
        case .comment:    return comment
        case .attribute:  return attribute
        case .punctuation: return punctuation
        }
    }

    /// 供工具栏做主题色板小圆点（取关键词/字符串/函数三色渐变）
    public var swatch: [NSColor] { [keyword, string, function] }
}

// MARK: - 主题目录

public enum CodeThemeCatalog {

    public static let themes: [CodeTheme] = [
        githubLight, githubDark, oneDark, dracula, nord,
        solarizedLight, solarizedDark, monokai, atomLight, xcode,
        vscodeDark, tokyoNight, catppuccinMocha, materialOcean,
    ]

    public static let fallback: CodeTheme = oneDark

    public static func theme(id: String) -> CodeTheme {
        themes.first { $0.id == id } ?? fallback
    }

    /// 首次进入时的默认主题：跟随系统明暗，但**只在深色时给深色主题**；
    /// 浅色系统给 GitHub Light（白底最不容易和面板灰底打架）
    public static var systemDefault: CodeTheme {
        let dark = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        return dark ? githubDark : githubLight
    }

    // MARK: 具体主题

    public static let githubLight = CodeTheme(
        id: "github-light", name: "GitHub Light", isDark: false,
        background: NSColor(codeHex: "#FFFFFF"),
        gutter: NSColor(codeHex: "#F6F8FA"),
        border: NSColor(codeHex: "#D0D7DE"),
        plain: NSColor(codeHex: "#24292F"),
        keyword: NSColor(codeHex: "#CF222E"),
        type: NSColor(codeHex: "#953800"),
        function: NSColor(codeHex: "#8250DF"),
        property: NSColor(codeHex: "#0550AE"),
        string: NSColor(codeHex: "#0A3069"),
        number: NSColor(codeHex: "#0550AE"),
        comment: NSColor(codeHex: "#6E7781"),
        attribute: NSColor(codeHex: "#116329"),
        punctuation: NSColor(codeHex: "#24292F"),
        lineNumber: NSColor(codeHex: "#8C959F"))

    public static let githubDark = CodeTheme(
        id: "github-dark", name: "GitHub Dark", isDark: true,
        background: NSColor(codeHex: "#0D1117"),
        gutter: NSColor(codeHex: "#161B22"),
        border: NSColor(codeHex: "#30363D"),
        plain: NSColor(codeHex: "#E6EDF3"),
        keyword: NSColor(codeHex: "#FF7B72"),
        type: NSColor(codeHex: "#FFA657"),
        function: NSColor(codeHex: "#D2A8FF"),
        property: NSColor(codeHex: "#79C0FF"),
        string: NSColor(codeHex: "#A5D6FF"),
        number: NSColor(codeHex: "#79C0FF"),
        comment: NSColor(codeHex: "#8B949E"),
        attribute: NSColor(codeHex: "#7EE787"),
        punctuation: NSColor(codeHex: "#C9D1D9"),
        lineNumber: NSColor(codeHex: "#6E7681"))

    public static let oneDark = CodeTheme(
        id: "one-dark", name: "One Dark", isDark: true,
        background: NSColor(codeHex: "#282C34"),
        gutter: NSColor(codeHex: "#21252B"),
        border: NSColor(codeHex: "#3E4451"),
        plain: NSColor(codeHex: "#ABB2BF"),
        keyword: NSColor(codeHex: "#C678DD"),
        type: NSColor(codeHex: "#E5C07B"),
        function: NSColor(codeHex: "#61AFEF"),
        property: NSColor(codeHex: "#E06C75"),
        string: NSColor(codeHex: "#98C379"),
        number: NSColor(codeHex: "#D19A66"),
        comment: NSColor(codeHex: "#5C6370"),
        attribute: NSColor(codeHex: "#56B6C2"),
        punctuation: NSColor(codeHex: "#ABB2BF"),
        lineNumber: NSColor(codeHex: "#4B5263"))

    public static let dracula = CodeTheme(
        id: "dracula", name: "Dracula", isDark: true,
        background: NSColor(codeHex: "#282A36"),
        gutter: NSColor(codeHex: "#21222C"),
        border: NSColor(codeHex: "#44475A"),
        plain: NSColor(codeHex: "#F8F8F2"),
        keyword: NSColor(codeHex: "#FF79C6"),
        type: NSColor(codeHex: "#8BE9FD"),
        function: NSColor(codeHex: "#50FA7B"),
        property: NSColor(codeHex: "#F1FA8C"),
        string: NSColor(codeHex: "#F1FA8C"),
        number: NSColor(codeHex: "#BD93F9"),
        comment: NSColor(codeHex: "#6272A4"),
        attribute: NSColor(codeHex: "#8BE9FD"),
        punctuation: NSColor(codeHex: "#F8F8F2"),
        lineNumber: NSColor(codeHex: "#6272A4"))

    public static let nord = CodeTheme(
        id: "nord", name: "Nord", isDark: true,
        background: NSColor(codeHex: "#2E3440"),
        gutter: NSColor(codeHex: "#272C36"),
        border: NSColor(codeHex: "#3B4252"),
        plain: NSColor(codeHex: "#D8DEE9"),
        keyword: NSColor(codeHex: "#81A1C1"),
        type: NSColor(codeHex: "#8FBCBB"),
        function: NSColor(codeHex: "#88C0D0"),
        property: NSColor(codeHex: "#D8DEE9"),
        string: NSColor(codeHex: "#A3BE8C"),
        number: NSColor(codeHex: "#B48EAD"),
        comment: NSColor(codeHex: "#616E88"),
        attribute: NSColor(codeHex: "#8FBCBB"),
        punctuation: NSColor(codeHex: "#ECEFF4"),
        lineNumber: NSColor(codeHex: "#4C566A"))

    public static let solarizedLight = CodeTheme(
        id: "solarized-light", name: "Solarized Light", isDark: false,
        background: NSColor(codeHex: "#FDF6E3"),
        gutter: NSColor(codeHex: "#EEE8D5"),
        border: NSColor(codeHex: "#DDD6C1"),
        plain: NSColor(codeHex: "#657B83"),
        keyword: NSColor(codeHex: "#859900"),
        type: NSColor(codeHex: "#B58900"),
        function: NSColor(codeHex: "#268BD2"),
        property: NSColor(codeHex: "#268BD2"),
        string: NSColor(codeHex: "#2AA198"),
        number: NSColor(codeHex: "#D33682"),
        comment: NSColor(codeHex: "#93A1A1"),
        attribute: NSColor(codeHex: "#CB4B16"),
        punctuation: NSColor(codeHex: "#586E75"),
        lineNumber: NSColor(codeHex: "#93A1A1"))

    public static let solarizedDark = CodeTheme(
        id: "solarized-dark", name: "Solarized Dark", isDark: true,
        background: NSColor(codeHex: "#002B36"),
        gutter: NSColor(codeHex: "#073642"),
        border: NSColor(codeHex: "#0F4B57"),
        plain: NSColor(codeHex: "#839496"),
        keyword: NSColor(codeHex: "#859900"),
        type: NSColor(codeHex: "#B58900"),
        function: NSColor(codeHex: "#268BD2"),
        property: NSColor(codeHex: "#268BD2"),
        string: NSColor(codeHex: "#2AA198"),
        number: NSColor(codeHex: "#D33682"),
        comment: NSColor(codeHex: "#586E75"),
        attribute: NSColor(codeHex: "#CB4B16"),
        punctuation: NSColor(codeHex: "#93A1A1"),
        lineNumber: NSColor(codeHex: "#586E75"))

    public static let monokai = CodeTheme(
        id: "monokai", name: "Monokai", isDark: true,
        background: NSColor(codeHex: "#272822"),
        gutter: NSColor(codeHex: "#1E1F1A"),
        border: NSColor(codeHex: "#3E3D32"),
        plain: NSColor(codeHex: "#F8F8F2"),
        keyword: NSColor(codeHex: "#F92672"),
        type: NSColor(codeHex: "#66D9EF"),
        function: NSColor(codeHex: "#A6E22E"),
        property: NSColor(codeHex: "#F8F8F2"),
        string: NSColor(codeHex: "#E6DB74"),
        number: NSColor(codeHex: "#AE81FF"),
        comment: NSColor(codeHex: "#75715E"),
        attribute: NSColor(codeHex: "#A6E22E"),
        punctuation: NSColor(codeHex: "#F8F8F2"),
        lineNumber: NSColor(codeHex: "#75715E"))

    public static let atomLight = CodeTheme(
        id: "atom-light", name: "Atom Light", isDark: false,
        background: NSColor(codeHex: "#FAFAFA"),
        gutter: NSColor(codeHex: "#F0F0F0"),
        border: NSColor(codeHex: "#DBDBDC"),
        plain: NSColor(codeHex: "#383A42"),
        keyword: NSColor(codeHex: "#A626A4"),
        type: NSColor(codeHex: "#C18401"),
        function: NSColor(codeHex: "#4078F2"),
        property: NSColor(codeHex: "#E45649"),
        string: NSColor(codeHex: "#50A14F"),
        number: NSColor(codeHex: "#986801"),
        comment: NSColor(codeHex: "#A0A1A7"),
        attribute: NSColor(codeHex: "#986801"),
        punctuation: NSColor(codeHex: "#383A42"),
        lineNumber: NSColor(codeHex: "#9D9D9F"))

    public static let xcode = CodeTheme(
        id: "xcode", name: "Xcode", isDark: false,
        background: NSColor(codeHex: "#FFFFFF"),
        gutter: NSColor(codeHex: "#F5F5F7"),
        border: NSColor(codeHex: "#E1E1E4"),
        plain: NSColor(codeHex: "#000000"),
        keyword: NSColor(codeHex: "#AD3DA4"),
        type: NSColor(codeHex: "#3E8087"),
        function: NSColor(codeHex: "#326D74"),
        property: NSColor(codeHex: "#326D74"),
        string: NSColor(codeHex: "#D12F1B"),
        number: NSColor(codeHex: "#2D38B7"),
        comment: NSColor(codeHex: "#536579"),
        attribute: NSColor(codeHex: "#815F03"),
        punctuation: NSColor(codeHex: "#000000"),
        lineNumber: NSColor(codeHex: "#A0A0A5"))

    public static let vscodeDark = CodeTheme(
        id: "vscode-dark", name: "VS Code Dark+", isDark: true,
        background: NSColor(codeHex: "#1E1E1E"),
        gutter: NSColor(codeHex: "#1E1E1E"),
        border: NSColor(codeHex: "#2B2B2B"),
        plain: NSColor(codeHex: "#D4D4D4"),
        keyword: NSColor(codeHex: "#569CD6"),
        type: NSColor(codeHex: "#4EC9B0"),
        function: NSColor(codeHex: "#DCDCAA"),
        property: NSColor(codeHex: "#9CDCFE"),
        string: NSColor(codeHex: "#CE9178"),
        number: NSColor(codeHex: "#B5CEA8"),
        comment: NSColor(codeHex: "#6A9955"),
        attribute: NSColor(codeHex: "#C586C0"),
        punctuation: NSColor(codeHex: "#D4D4D4"),
        lineNumber: NSColor(codeHex: "#858585"))

    public static let tokyoNight = CodeTheme(
        id: "tokyo-night", name: "Tokyo Night", isDark: true,
        background: NSColor(codeHex: "#1A1B26"),
        gutter: NSColor(codeHex: "#16161E"),
        border: NSColor(codeHex: "#2A2E42"),
        plain: NSColor(codeHex: "#C0CAF5"),
        keyword: NSColor(codeHex: "#BB9AF7"),
        type: NSColor(codeHex: "#2AC3DE"),
        function: NSColor(codeHex: "#7AA2F7"),
        property: NSColor(codeHex: "#7DCFFF"),
        string: NSColor(codeHex: "#9ECE6A"),
        number: NSColor(codeHex: "#FF9E64"),
        comment: NSColor(codeHex: "#565F89"),
        attribute: NSColor(codeHex: "#E0AF68"),
        punctuation: NSColor(codeHex: "#A9B1D6"),
        lineNumber: NSColor(codeHex: "#3B4261"))

    public static let catppuccinMocha = CodeTheme(
        id: "catppuccin-mocha", name: "Catppuccin Mocha", isDark: true,
        background: NSColor(codeHex: "#1E1E2E"),
        gutter: NSColor(codeHex: "#181825"),
        border: NSColor(codeHex: "#313244"),
        plain: NSColor(codeHex: "#CDD6F4"),
        keyword: NSColor(codeHex: "#CBA6F7"),
        type: NSColor(codeHex: "#F9E2AF"),
        function: NSColor(codeHex: "#89B4FA"),
        property: NSColor(codeHex: "#89DCEB"),
        string: NSColor(codeHex: "#A6E3A1"),
        number: NSColor(codeHex: "#FAB387"),
        comment: NSColor(codeHex: "#6C7086"),
        attribute: NSColor(codeHex: "#F5C2E7"),
        punctuation: NSColor(codeHex: "#BAC2DE"),
        lineNumber: NSColor(codeHex: "#585B70"))

    public static let materialOcean = CodeTheme(
        id: "material-ocean", name: "Material Ocean", isDark: true,
        background: NSColor(codeHex: "#0F111A"),
        gutter: NSColor(codeHex: "#0B0D14"),
        border: NSColor(codeHex: "#1F2233"),
        plain: NSColor(codeHex: "#A6ACCD"),
        keyword: NSColor(codeHex: "#C792EA"),
        type: NSColor(codeHex: "#FFCB6B"),
        function: NSColor(codeHex: "#82AAFF"),
        property: NSColor(codeHex: "#F07178"),
        string: NSColor(codeHex: "#C3E88D"),
        number: NSColor(codeHex: "#F78C6C"),
        comment: NSColor(codeHex: "#464B5D"),
        attribute: NSColor(codeHex: "#89DDFF"),
        punctuation: NSColor(codeHex: "#A6ACCD"),
        lineNumber: NSColor(codeHex: "#3B4048"))
}

// MARK: - 十六进制色

extension NSColor {
    /// "#RRGGBB" / "RRGGBB" / "#RGB" → sRGB 颜色（代码主题全部显式给值，不随外观反相）
    convenience init(codeHex hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        if s.count == 3 {
            s = s.map { "\($0)\($0)" }.joined()
        }
        var value: UInt64 = 0
        Scanner(string: s).scanHexInt64(&value)
        let r = CGFloat((value & 0xFF0000) >> 16) / 255
        let g = CGFloat((value & 0x00FF00) >> 8) / 255
        let b = CGFloat(value & 0x0000FF) / 255
        self.init(srgbRed: r, green: g, blue: b, alpha: 1)
    }

    /// 导出 CSS 用的 #RRGGBB（转 sRGB 再取分量，避免显示色域偏移）
    var codeHexString: String {
        let c = usingColorSpace(.sRGB) ?? self
        let r = Int((c.redComponent * 255).rounded())
        let g = Int((c.greenComponent * 255).rounded())
        let b = Int((c.blueComponent * 255).rounded())
        return String(format: "#%02X%02X%02X", r, g, b)
    }
}
