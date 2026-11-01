import AppKit

// MARK: - 斜杠命令（v172）
//
// 用户需求：把工具箱做成「输入 / 就列出命令」的形态——
//   1. 命令面板里打 `/` 直接进命令模式，只列工具命令；
//   2. 给一个按钮，点一下自动补上 `/` 并列出全部命令；
//   3. 选中即调用对应工具。
//
// 命令名对齐原版 Frset 的 `/xxx`（原版二进制里的工具类：
// Base64Tool / IPAddressTool / JSONFormatterTool / QRCodeTool / SummaryTool /
// TimestampTool / TinyPNGTool / TranslateTool / URLCodecTool / UUIDTool / VariableNameTool），
// 原版用的是 `/Apollo`（二维码）和 `/tinyimg`（TinyPNG），这里作为别名一并认。

/// 一条斜杠命令
public struct SlashCommand: Identifiable {
    public let id: String
    /// 命令 token（不含斜杠）
    public let token: String
    public let title: String
    public let subtitle: String
    public let systemImage: String
    /// 其它可命中的写法（原版命令名 / 工具 id）
    public let aliases: [String]
    /// 选中后是否让工具窗自动跑一次（无输入类工具）
    public let autoRun: Bool
    public let run: () -> Void
}

public enum SlashCommandCatalog {

    /// 工具 id → 额外别名。原版命令名放这里，保证 `/apollo`、`/tinyimg` 也能用。
    private static let aliases: [String: [String]] = [
        "qrcode": ["apollo", "qr"],
        "timestamp": ["time", "date"],
        "urlencode": ["url", "urlcodec", "urldecode"],
        "varname": ["var", "varname"],
        "imagecompress": ["tinypng", "tinyimg", "img"],
        "codepreview": ["code", "snippet"],
        "hash": ["sha", "md5"],
        "base64": ["b64"],
        "json": ["jsonformat"],
        "ip": ["ipaddress"],
        "uuid": ["guid"],
    ]

    /// 不需要输入就能出结果的工具：命令选中后直接跑一次
    private static let zeroInputTools: Set<String> = ["uuid", "ip", "timestamp", "colorpicker"]

    /// 全量命令（每次打开面板时构建：工具启停状态可能是新的）
    @MainActor
    public static func build() -> [SlashCommand] {
        var out: [SlashCommand] = []
        out.reserveCapacity(ToolRegistry.enabledTools.count + 2)

        // ① 工具命令
        for tool in ToolRegistry.enabledTools {
            let token = tool.keyword.isEmpty ? tool.identifier : tool.keyword
            var terms = aliases[tool.identifier] ?? []
            terms.append(tool.identifier)
            out.append(SlashCommand(
                id: "tool.\(tool.identifier)",
                token: token,
                title: "/\(token)",
                subtitle: tool.toolDescription.isEmpty ? tool.name : tool.toolDescription,
                systemImage: tool.systemImage,
                aliases: terms,
                autoRun: Self.zeroInputTools.contains(tool.identifier)
            ) {
                CommandPaletteController.shared.dismissForCommand()
                ToolRunnerWindowController.shared.show(
                    toolID: tool.identifier,
                    autoRun: Self.zeroInputTools.contains(tool.identifier))
            })
        }

        // ② 日历（原版 /calendar）：打开主面板，日历代办卡就在主页上
        out.append(SlashCommand(
            id: "panel.calendar",
            token: "calendar",
            title: "/calendar",
            subtitle: "打开日历，查看日程、节假日与农历",
            systemImage: "calendar",
            aliases: ["cal", "日程"],
            autoRun: false
        ) {
            CommandPaletteController.shared.dismissForCommand()
            PanelController.shared.show()
        })

        // ③ 工具面板（无参数直达）
        out.append(SlashCommand(
            id: "panel.tools",
            token: "tools",
            title: "/tools",
            subtitle: "打开工具箱（全部工具的九宫格）",
            systemImage: "wrench.and.screwdriver",
            aliases: ["toolbox", "工具"],
            autoRun: false
        ) {
            CommandPaletteController.shared.dismissForCommand()
            PanelController.shared.show()
        })

        return out
    }

    /// 按 token / 别名筛选（前缀优先，其次子序列模糊）。
    /// 面板搜索框输入 `/` 后走这里——与 ⌥K 面板共用同一份目录，避免两套实现。
    @MainActor
    public static func match(_ token: String) -> [SlashCommand] {
        let all = build()
        let q = token.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return all }

        var scored: [(command: SlashCommand, score: Int)] = []
        for cmd in all {
            var best: Int?
            for term in ([cmd.token] + cmd.aliases).map({ $0.lowercased() }) {
                if term == q { best = 10_000; break }
                if term.hasPrefix(q) {
                    best = max(best ?? 0, 5_000 - (term.count - q.count))
                } else if let m = FuzzyMatcher.match(q, in: term) {
                    best = max(best ?? 0, m.score)
                }
            }
            if let b = best { scored.append((cmd, b)) }
        }
        return scored.sorted { $0.score > $1.score }.map { $0.command }
    }

}
