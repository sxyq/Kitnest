import Foundation

// MARK: - 自定义提示词工具
//
// 对应原作 `CustomAIToolStore`（规格 09 §1）。
// 用户可在「设置 → AI → 自定义工具」里定义「名称 + 系统提示词 + 提示词模板」，
// 定义后与内置的摘要/润色/翻译并列出现在文本工具面板中。
//
// 存储：沿用 Preferences（与其它 AI 偏好同源），序列化为 JSON 字符串，避免新建数据库表。

public struct CustomAITool: Codable, Identifiable, Hashable, Sendable {
    public let id: String
    /// 展示名（同时作为按钮标题）
    public var name: String
    /// 系统提示词（角色设定）
    public var systemPrompt: String
    /// 用户提示词模板，支持 `{input}` 占位符；不含占位符时自动把输入追加到末尾
    public var promptTemplate: String
    public var createdAt: Date

    public init(id: String = UUID().uuidString,
                name: String,
                systemPrompt: String,
                promptTemplate: String,
                createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.systemPrompt = systemPrompt
        self.promptTemplate = promptTemplate
        self.createdAt = createdAt
    }

    /// 把用户输入套进模板
    public func render(input: String) -> String {
        if promptTemplate.contains("{input}") {
            return promptTemplate.replacingOccurrences(of: "{input}", with: input)
        }
        return promptTemplate + "\n\n" + input
    }
}

public final class CustomAIToolStore {
    public static let shared = CustomAIToolStore()

    /// 偏好键（AI 专属键集中在这里定义，不改 Core/Preferences.Keys）
    public static let storageKey = "ai.customTools"

    private let lock = NSLock()
    private let prefs: Preferences

    public init(prefs: Preferences = .shared) {
        self.prefs = prefs
    }

    /// 全部自定义工具（按创建时间升序，便于稳定排列）
    public func all() -> [CustomAITool] {
        lock.lock(); defer { lock.unlock() }
        return Self.decode(prefs.value(Self.storageKey, default: "") as String)
    }

    /// 新增或按 id 覆盖
    public func upsert(_ tool: CustomAITool) {
        lock.lock()
        var list = Self.decode(prefs.value(Self.storageKey, default: "") as String)
        if let idx = list.firstIndex(where: { $0.id == tool.id }) { list[idx] = tool }
        else { list.append(tool) }
        persist(list)
        lock.unlock()
    }

    public func delete(id: String) {
        lock.lock()
        var list = Self.decode(prefs.value(Self.storageKey, default: "") as String)
        list.removeAll { $0.id == id }
        persist(list)
        lock.unlock()
    }

    public func replaceAll(_ tools: [CustomAITool]) {
        lock.lock(); persist(tools); lock.unlock()
    }

    // MARK: - 私有

    private func persist(_ list: [CustomAITool]) {
        guard let data = try? JSONEncoder().encode(list),
              let text = String(data: data, encoding: .utf8) else { return }
        prefs.set(Self.storageKey, text)
    }

    private static func decode(_ text: String) -> [CustomAITool] {
        guard !text.isEmpty, let data = text.data(using: .utf8),
              let list = try? JSONDecoder().decode([CustomAITool].self, from: data) else { return [] }
        return list.sorted { $0.createdAt < $1.createdAt }
    }
}
