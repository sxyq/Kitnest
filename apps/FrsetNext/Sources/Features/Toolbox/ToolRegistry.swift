import Foundation
import AppKit
import SwiftUI

// MARK: - 工具元数据与注册表
// 说明：工具箱体系（10 号规格 A）。每个工具是一条 ToolDescriptor：
//   id / 名称 / 图标 / 分类 / 选项 / 执行函数。
// 执行结果统一为 ToolOutput（文本 + 可选图片 + 备注），由 UI 负责展示"复制 / 存为剪贴板条目"。
// "存为剪贴板条目"不直接引用剪贴板模块，而是通过 ToolboxEventBus 回调交给总控接线。

/// 工具分类（面板内网格按分类分组展示）
public enum ToolCategory: String, CaseIterable, Sendable {
    case convert   // 转换类
    case encode    // 编解码类
    case network   // 网络类
    case format    // 格式化 / 预览类
    case media     // 图片类

    public var title: String {
        switch self {
        case .convert: return "转换"
        case .encode:  return "编解码"
        case .network: return "网络"
        case .format:  return "格式化"
        case .media:   return "图片"
        }
    }
}

/// 工具输入形态：文本 / 文件路径（图片类工具需要选文件）
public enum ToolInputKind: Sendable {
    case text
    case filePath
}

/// 工具执行结果
public struct ToolOutput {
    /// 结果文本（用于复制 / 存为剪贴板条目）
    public var text: String
    /// 可选的图形成果（二维码、压缩后的图片、代码预览卡片）
    public var image: NSImage?
    /// 是否是错误结果（UI 用红色样式呈现）
    public var isError: Bool
    /// 备注（如"与原作 TinyPNG 网络压缩的差异说明"）
    public var note: String?

    public init(text: String = "", image: NSImage? = nil, isError: Bool = false, note: String? = nil) {
        self.text = text; self.image = image; self.isError = isError; self.note = note
    }

    public static func error(_ message: String) -> ToolOutput {
        ToolOutput(text: message, isError: true)
    }
}

/// 工具的附加选项（如"目标格式：camelCase / snake_case"），UI 渲染为分段控件
public struct ToolOption: Identifiable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let choices: [String]
    public let defaultIndex: Int

    public init(id: String, title: String, choices: [String], defaultIndex: Int = 0) {
        self.id = id; self.title = title
        self.choices = choices
        self.defaultIndex = min(max(defaultIndex, 0), max(choices.count - 1, 0))
    }
}

/// 一条工具定义
public struct ToolDescriptor: Identifiable {
    public let identifier: String
    /// 统计归属（写入 tool_invocations.kind 与 daily_stats.tool_count）
    public let kind: ToolKind
    public let name: String
    public let keyword: String
    public let toolDescription: String
    public let systemImage: String
    public let category: ToolCategory
    public let inputKind: ToolInputKind
    public let placeholder: String
    public let options: [ToolOption]
    /// 执行函数：(输入, 选项) -> 结果
    public let execute: (String, [String: String]) async -> ToolOutput

    public var id: String { identifier }

    public init(identifier: String,
                kind: ToolKind,
                name: String,
                keyword: String? = nil,
                toolDescription: String = "",
                systemImage: String,
                category: ToolCategory,
                inputKind: ToolInputKind = .text,
                placeholder: String = "",
                options: [ToolOption] = [],
                execute: @escaping (String, [String: String]) async -> ToolOutput) {
        self.identifier = identifier; self.kind = kind; self.name = name
        self.keyword = keyword ?? identifier
        self.toolDescription = toolDescription
        self.systemImage = systemImage; self.category = category
        self.inputKind = inputKind; self.placeholder = placeholder
        self.options = options; self.execute = execute
    }

    /// 默认选项值（UI 初始化分段控件用）
    public func defaultOptions() -> [String: String] {
        var map: [String: String] = [:]
        for opt in options where opt.defaultIndex < opt.choices.count {
            map[opt.id] = opt.choices[opt.defaultIndex]
        }
        return map
    }
}

// MARK: - 结果出口（跨模块：剪贴板模块 / 总控注入实现）

public enum ToolboxEventBus {
    /// 参数：(结果文本, 工具类型)。由总控在启动时接线到"存为剪贴板条目"。
    public static var onResultProduced: ((String, ToolKind) -> Void)?

    public static func emitResult(_ text: String, kind: ToolKind) {
        guard !text.isEmpty else { return }
        Log.info("Toolbox", "result produced by \(kind.rawValue), \(min(text.count, 32)) chars")
        onResultProduced?(text, kind)
    }
}

// MARK: - 注册表

public enum ToolRegistry {
    private static let lock = NSLock()
    private static var items: [ToolDescriptor] = []

    /// 注册工具（同 id 覆盖）
    public static func register(_ tool: ToolDescriptor) {
        lock.lock(); defer { lock.unlock() }
        items.removeAll { $0.identifier == tool.identifier }
        items.append(tool)
        Log.info("Toolbox", "tool registered: \(tool.identifier)")
    }

    public static var all: [ToolDescriptor] {
        lock.lock(); defer { lock.unlock() }
        return items
    }

    public static func tool(id: String) -> ToolDescriptor? {
        all.first { $0.identifier == id }
    }

    // MARK: 启用 / 禁用（状态存 Preferences，键：toolbox.tool.<id>.enabled）

    private static func enabledKey(_ id: String) -> String { "toolbox.tool.\(id).enabled" }

    public static func isEnabled(id: String) -> Bool {
        Preferences.shared.value(enabledKey(id), default: true)
    }

    public static func setEnabled(id: String, _ on: Bool) {
        Preferences.shared.set(enabledKey(id), on)
    }

    /// 面板展示用：仅启用的工具
    public static var enabledTools: [ToolDescriptor] {
        all.filter { isEnabled(id: $0.identifier) }
    }

    /// 按分类分组（保持分类声明顺序）
    public static func grouped() -> [(ToolCategory, [ToolDescriptor])] {
        let enabled = enabledTools
        return ToolCategory.allCases.compactMap { cat in
            let list = enabled.filter { $0.category == cat }
            return list.isEmpty ? nil : (cat, list)
        }
    }

    // MARK: 执行 + 埋点

    /// 执行工具并写调用记录（tool_invocations 表 + daily_stats.tool_count）
    @discardableResult
    public static func run(_ tool: ToolDescriptor,
                           input: String,
                           options: [String: String]) async -> ToolOutput {
        let output = await tool.execute(input, options)
        recordInvocation(kind: tool.kind, input: input, output: output.text)
        return output
    }

    public static func recordInvocation(kind: ToolKind, input: String, output: String) {
        let record = ToolInvocationRecord(kind: kind,
                                          input: String(input.prefix(4000)),
                                          output: String(output.prefix(4000)))
        do {
            try DatabaseManager.shared.clipboard.run(
                "INSERT INTO tool_invocations(id,kind,input,output,created_at) VALUES(?,?,?,?,?);",
                [.text(record.id), .text(kind.rawValue), .text(record.input),
                 .text(record.output), .real(record.createdAt.timeIntervalSince1970)])
        } catch {
            Log.error("Toolbox", "write tool_invocations failed: \(error.localizedDescription)")
        }
        DatabaseManager.shared.bumpStat("tool_count")
    }

    /// 最近调用记录（设置页 / 调试用）
    public static func recentInvocations(limit: Int = 20) -> [ToolInvocationRecord] {
        guard let rows = try? DatabaseManager.shared.clipboard.query(
            "SELECT id,kind,input,output,created_at FROM tool_invocations ORDER BY created_at DESC LIMIT \(limit);"
        ) else { return [] }
        return rows.compactMap { row in
            guard let kind = ToolKind(rawValue: row.string("kind") ?? "") else { return nil }
            return ToolInvocationRecord(id: row.string("id") ?? UUID().uuidString,
                                        kind: kind,
                                        input: row.string("input") ?? "",
                                        output: row.string("output") ?? "",
                                        createdAt: Date(timeIntervalSince1970: row.real("created_at")))
        }
    }
}
