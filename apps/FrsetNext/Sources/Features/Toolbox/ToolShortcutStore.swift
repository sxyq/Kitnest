import Foundation
import Carbon.HIToolbox

// MARK: - 工具级全局快捷键存储（10 号规格 A.1「工具快捷键」）
//
// 每个工具可绑定一个全局热键；触发时唤起主面板并打开对应工具。
// 组合键完全由用户在设置「快捷键」页录入——原作的默认绑定表尚未取得
// （见 specs/01 §13 待查 #7），因此这里**不预置任何默认组合**，避免臆造原作行为。
//
// 跨模块只走 ServiceLocator（唤起面板）与本模块的 ToolboxUIState，不引用其他模块具体类型。

public enum ToolShortcutStore {

    /// 录入结果
    public enum Outcome {
        case ok
        case conflict(String)       // 与已注册快捷键冲突
        case systemFailure(String)  // 被系统 / 其他应用占用
        case empty                  // 未包含有效修饰键
    }

    /// 持久化键：[toolID: [keyCode, carbonModifiers]]
    private static let storageKey = "toolbox.toolShortcuts"
    private static let lock = NSLock()

    /// ShortcutRegistry 中的注册 id（与 "app.*" / 其他模块命名空间区分）
    public static func registrationID(_ toolID: String) -> String { "tool.\(toolID)" }

    public static func title(for toolID: String) -> String {
        "工具：\(ToolRegistry.tool(id: toolID)?.name ?? toolID)"
    }

    // MARK: 持久化

    private static func loadRaw() -> [String: [Int]] {
        Preferences.shared.value(storageKey, default: [String: [Int]]())
    }

    private static func saveRaw(_ map: [String: [Int]]) {
        Preferences.shared.set(storageKey, map)
    }

    /// 某个工具当前的绑定（未绑定返回 nil）
    public static func binding(for toolID: String) -> (keyCode: UInt32, modifiers: UInt32)? {
        guard let pair = loadRaw()[toolID], pair.count == 2 else { return nil }
        return (UInt32(pair[0]), UInt32(pair[1]))
    }

    /// 全部已保存绑定，按 toolID 排序
    public static var all: [(toolID: String, keyCode: UInt32, modifiers: UInt32)] {
        loadRaw().compactMap { key, pair in
            guard pair.count == 2 else { return nil }
            return (key, UInt32(pair[0]), UInt32(pair[1]))
        }.sorted { $0.toolID < $1.toolID }
    }

    // MARK: 录入 / 清除

    /// 为工具绑定组合键：先注册，成功才持久化；失败返回分类原因
    @discardableResult
    public static func set(toolID: String, keyCode: UInt32, modifiers: UInt32) -> Outcome {
        // 至少一个强修饰键（⌘/⌥/⌃），避免把普通按键注册成全局热键
        guard modifiers & (UInt32(cmdKey) | UInt32(optionKey) | UInt32(controlKey)) != 0 else {
            return .empty
        }
        lock.lock(); defer { lock.unlock() }

        let id = registrationID(toolID)
        let definition = ShortcutDefinition(id: id,
                                            title: title(for: toolID),
                                            keyCode: keyCode,
                                            modifiers: modifiers) {
            ToolboxUIState.shared.open(toolID)
            ServiceLocator.panel?.show()
        }
        // bind：已绑定时原地重绑，冲突 / 系统占用时保留原绑定
        if ShortcutManager.shared.bind(definition) {
            var map = loadRaw()
            map[toolID] = [Int(keyCode), Int(modifiers)]
            saveRaw(map)
            return .ok
        }
        let reason = ShortcutManager.shared.failureReason(id: id) ?? "未知原因"
        return reason.contains("冲突") ? .conflict(reason) : .systemFailure(reason)
    }

    /// 清除某个工具的绑定
    public static func clear(toolID: String) {
        lock.lock(); defer { lock.unlock() }
        ShortcutRegistry.unregister(id: registrationID(toolID))
        var map = loadRaw()
        map.removeValue(forKey: toolID)
        saveRaw(map)
    }

    /// 启动时恢复已保存的绑定（ToolboxModule.start 调用）
    public static func restoreAll() {
        for item in all where ToolRegistry.tool(id: item.toolID) != nil {
            _ = set(toolID: item.toolID, keyCode: item.keyCode, modifiers: item.modifiers)
        }
    }
}
