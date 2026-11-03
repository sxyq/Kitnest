import Foundation
import AppKit
import Carbon.HIToolbox

// MARK: - 全局快捷键管理
//
// 实现：Carbon RegisterEventHotKey（真正的全局热键，App 未激活时同样生效），
// 配合一个 Carbon 事件处理器分发到各模块注册的 handler。
// 各模块通过 ShortcutRegistry.register(...) 注册，本模块负责注册 / 注销 / 冲突检测 / 列表数据。

public struct ShortcutDefinition: Identifiable {
    public let id: String
    public let title: String
    /// 虚拟键码（Carbon kVK_*，如 kVK_ANSI_T）
    public let keyCode: UInt32
    /// Carbon 修饰键（cmdKey / shiftKey / optionKey / controlKey 的按位或）
    public let modifiers: UInt32
    public let handler: () -> Void

    public init(id: String, title: String, keyCode: UInt32, modifiers: UInt32, handler: @escaping () -> Void) {
        self.id = id; self.title = title; self.keyCode = keyCode
        self.modifiers = modifiers; self.handler = handler
    }

    /// 展示文本："⌘⇧T"
    public var display: String { ShortcutManager.display(keyCode: keyCode, modifiers: modifiers) }
}

public final class ShortcutManager {
    public static let shared = ShortcutManager()

    /// Carbon 事件签名 'FRST'
    private static let signature: OSType = 0x46525354

    private let lock = NSLock()
    private var definitions: [String: ShortcutDefinition] = [:]
    private var hotKeyRefs: [String: EventHotKeyRef] = [:]
    private var hotKeyIDToDefinitionID: [UInt32: String] = [:]
    private var nextHotKeyID: UInt32 = 1
    /// 注册失败原因（如与系统快捷键冲突）
    private var failures: [String: String] = [:]

    private init() { installEventHandler() }

    // MARK: Carbon 事件处理器

    private func installEventHandler() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        // 闭包无捕获，可安全转换为 C 函数指针
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            ShortcutManager.shared.handleCarbonEvent(event)
            return OSStatus(noErr)
        }, 1, &spec, nil, nil)
    }

    private func handleCarbonEvent(_ event: EventRef?) {
        guard let event else { return }
        var hotKeyID = EventHotKeyID()
        let status = GetEventParameter(event,
                                       EventParamName(kEventParamDirectObject),
                                       EventParamType(typeEventHotKeyID),
                                       nil,
                                       MemoryLayout<EventHotKeyID>.size,
                                       nil,
                                       &hotKeyID)
        guard status == noErr else { return }
        guard hotKeyID.signature == ShortcutManager.signature else { return }

        lock.lock()
        let definitionID = hotKeyIDToDefinitionID[hotKeyID.id]
        let definition = definitionID.flatMap { definitions[$0] }
        lock.unlock()

        guard let definition else { return }
        Log.debug("Shortcut", "hotkey fired: \(definition.id)")
        // handler 通常涉及 UI，统一回主线程
        DispatchQueue.main.async { definition.handler() }
    }

    // MARK: 注册 / 注销

    /// 注册全局快捷键。返回是否成功（冲突或系统占用时返回 false 并记录原因）
    @discardableResult
    public func register(_ definition: ShortcutDefinition) -> Bool {
        lock.lock(); defer { lock.unlock() }
        unregisterLocked(id: definition.id)

        if let conflict = conflictsLocked(keyCode: definition.keyCode, modifiers: definition.modifiers).first {
            let reason = "与已注册快捷键「\(conflict.title)」冲突"
            failures[definition.id] = reason
            Log.warn("Shortcut", "register failed [\(definition.id)]：\(reason)")
            return false
        }

        let hotKeyID = EventHotKeyID(signature: ShortcutManager.signature, id: nextHotKeyID)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(definition.keyCode, definition.modifiers, hotKeyID,
                                         GetEventDispatcherTarget(), 0, &ref)
        guard status == noErr, let ref else {
            let reason = "系统注册失败（可能已被系统或其他应用占用），状态码 \(status)"
            failures[definition.id] = reason
            Log.error("Shortcut", "register failed [\(definition.id)]：\(reason)")
            return false
        }

        definitions[definition.id] = definition
        hotKeyRefs[definition.id] = ref
        hotKeyIDToDefinitionID[hotKeyID.id] = definition.id
        failures.removeValue(forKey: definition.id)
        nextHotKeyID += 1
        Log.info("Shortcut", "registered \(definition.id) \(definition.display)")
        return true
    }

    public func unregister(id: String) {
        lock.lock(); defer { lock.unlock() }
        unregisterLocked(id: id)
    }

    /// 绑定：id 不存在则注册；已存在则**原地重绑**（保留原 handler/title，失败时旧绑定保持不变）
    @discardableResult
    public func bind(_ definition: ShortcutDefinition) -> Bool {
        lock.lock()
        let exists = definitions[definition.id] != nil
        lock.unlock()
        if exists {
            return reconfigure(id: definition.id,
                               keyCode: definition.keyCode,
                               modifiers: definition.modifiers)
        }
        return register(definition)
    }

    /// 重新绑定已存在快捷键的组合键。仅在新组合注册成功后才撤销旧热键，
    /// 因此冲突 / 被系统占用时**不会破坏原有可用绑定**。
    @discardableResult
    public func reconfigure(id: String, keyCode: UInt32, modifiers: UInt32) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let existing = definitions[id], let oldRef = hotKeyRefs[id] else {
            failures[id] = "该快捷键尚未注册，无法重绑"
            return false
        }
        if let conflict = conflictsLocked(keyCode: keyCode, modifiers: modifiers).first(where: { $0.id != id }) {
            let reason = "与已注册快捷键「\(conflict.title)」冲突"
            failures[id] = reason
            Log.warn("Shortcut", "reconfigure failed [\(id)]：\(reason)")
            return false
        }

        let hotKeyID = EventHotKeyID(signature: ShortcutManager.signature, id: nextHotKeyID)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(keyCode, modifiers, hotKeyID,
                                         GetEventDispatcherTarget(), 0, &ref)
        guard status == noErr, let ref else {
            let reason = "系统注册失败（可能已被系统或其他应用占用），状态码 \(status)"
            failures[id] = reason
            Log.error("Shortcut", "reconfigure failed [\(id)]：\(reason)")
            return false
        }

        // 新组合注册成功，才撤销旧热键
        UnregisterEventHotKey(oldRef)
        hotKeyRefs.removeValue(forKey: id)
        for (hotID, definitionID) in hotKeyIDToDefinitionID where definitionID == id {
            hotKeyIDToDefinitionID.removeValue(forKey: hotID)
        }
        definitions[id] = ShortcutDefinition(id: id, title: existing.title,
                                             keyCode: keyCode, modifiers: modifiers,
                                             handler: existing.handler)
        hotKeyRefs[id] = ref
        hotKeyIDToDefinitionID[hotKeyID.id] = id
        failures.removeValue(forKey: id)
        nextHotKeyID += 1
        Log.info("Shortcut", "reconfigured \(id) \(ShortcutManager.display(keyCode: keyCode, modifiers: modifiers))")
        return true
    }

    /// 调用方必须已持锁
    private func unregisterLocked(id: String) {
        if let ref = hotKeyRefs.removeValue(forKey: id) {
            UnregisterEventHotKey(ref)
        }
        if let definition = definitions.removeValue(forKey: id) {
            Log.info("Shortcut", "unregistered \(definition.id)")
        }
        for (hotID, definitionID) in hotKeyIDToDefinitionID where definitionID == id {
            hotKeyIDToDefinitionID.removeValue(forKey: hotID)
        }
        failures.removeValue(forKey: id)
    }

    // MARK: 查询

    public var all: [ShortcutDefinition] {
        lock.lock(); defer { lock.unlock() }
        return definitions.values.sorted { $0.title < $1.title }
    }

    public func failureReason(id: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return failures[id]
    }


    private func conflictsLocked(keyCode: UInt32, modifiers: UInt32) -> [ShortcutDefinition] {
        definitions.values.filter { $0.keyCode == keyCode && $0.modifiers == modifiers }
    }

    // MARK: 展示辅助

    /// Carbon 修饰键 → "⌃⇧⌥⌘"
    public static func modifierText(_ modifiers: UInt32) -> String {
        var text = ""
        if modifiers & UInt32(controlKey) != 0 { text += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { text += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { text += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { text += "⌘" }
        return text
    }

    /// 常用虚拟键码 → 可读文本
    public static func keyText(_ keyCode: UInt32) -> String {
        switch Int(keyCode) {
        case kVK_ANSI_A: return "A"
        case kVK_ANSI_B: return "B"
        case kVK_ANSI_C: return "C"
        case kVK_ANSI_D: return "D"
        case kVK_ANSI_E: return "E"
        case kVK_ANSI_F: return "F"
        case kVK_ANSI_G: return "G"
        case kVK_ANSI_H: return "H"
        case kVK_ANSI_I: return "I"
        case kVK_ANSI_J: return "J"
        case kVK_ANSI_K: return "K"
        case kVK_ANSI_L: return "L"
        case kVK_ANSI_M: return "M"
        case kVK_ANSI_N: return "N"
        case kVK_ANSI_O: return "O"
        case kVK_ANSI_P: return "P"
        case kVK_ANSI_Q: return "Q"
        case kVK_ANSI_R: return "R"
        case kVK_ANSI_S: return "S"
        case kVK_ANSI_T: return "T"
        case kVK_ANSI_U: return "U"
        case kVK_ANSI_V: return "V"
        case kVK_ANSI_W: return "W"
        case kVK_ANSI_X: return "X"
        case kVK_ANSI_Y: return "Y"
        case kVK_ANSI_Z: return "Z"
        case kVK_ANSI_0: return "0"
        case kVK_ANSI_1: return "1"
        case kVK_ANSI_2: return "2"
        case kVK_ANSI_3: return "3"
        case kVK_ANSI_4: return "4"
        case kVK_ANSI_5: return "5"
        case kVK_ANSI_6: return "6"
        case kVK_ANSI_7: return "7"
        case kVK_ANSI_8: return "8"
        case kVK_ANSI_9: return "9"
        case kVK_Space: return "Space"
        case kVK_Return: return "↩"
        case kVK_Escape: return "⎋"
        case kVK_Tab: return "⇥"
        case kVK_Delete: return "⌫"
        case kVK_LeftArrow: return "←"
        case kVK_RightArrow: return "→"
        case kVK_UpArrow: return "↑"
        case kVK_DownArrow: return "↓"
        case kVK_F1: return "F1"
        case kVK_F2: return "F2"
        case kVK_F3: return "F3"
        case kVK_F4: return "F4"
        case kVK_F5: return "F5"
        case kVK_F6: return "F6"
        case kVK_F7: return "F7"
        case kVK_F8: return "F8"
        case kVK_F9: return "F9"
        case kVK_F10: return "F10"
        case kVK_F11: return "F11"
        case kVK_F12: return "F12"
        default: return "键码\(keyCode)"
        }
    }

    public static func display(keyCode: UInt32, modifiers: UInt32) -> String {
        // 原版设置页的展示格式为「⌥ A」「⌘ 2」「⌥ ⇧ T」——修饰键之间、修饰键与主键之间都有空格
        // （2026-10-18 原版 AX 实测 AXStaticText 值），这里按同格式拼接。
        let symbols = modifierText(modifiers).map { String($0) }
        let key = keyText(keyCode)
        return symbols.isEmpty ? key : symbols.joined(separator: " ") + " " + key
    }

    /// NSEvent 修饰键 → Carbon 修饰键
    public static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var result: UInt32 = 0
        if flags.contains(.command) { result |= UInt32(cmdKey) }
        if flags.contains(.shift) { result |= UInt32(shiftKey) }
        if flags.contains(.option) { result |= UInt32(optionKey) }
        if flags.contains(.control) { result |= UInt32(controlKey) }
        return result
    }
}

// MARK: 对外注册表（各模块调用这里注册快捷键，无需引用 ShortcutManager 实例）

public enum ShortcutRegistry {
    public static func register(id: String,
                                title: String,
                                keyCode: UInt32,
                                modifiers: UInt32,
                                handler: @escaping () -> Void) {
        let definition = ShortcutDefinition(id: id, title: title, keyCode: keyCode,
                                            modifiers: modifiers, handler: handler)
        _ = ShortcutManager.shared.register(definition)
    }

    public static func unregister(id: String) {
        ShortcutManager.shared.unregister(id: id)
    }

    public static var all: [ShortcutDefinition] { ShortcutManager.shared.all }
}
