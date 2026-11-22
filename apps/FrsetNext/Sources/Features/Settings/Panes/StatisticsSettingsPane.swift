import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - 独立配置导入导出页
// 配置导入即时应用，仅包含偏好；旧文件的统计内容由解码器忽略。

// MARK: - 导出文件结构（.frsetconfig / JSON）

/// `.frsetconfig` 配置结构；菜单部件可选，沿用已有配置文件。
struct FrsetConfigFile: Codable {
    /// 格式标识（导入时校验，防止把任意 JSON 当配置导入）
    let format: String
    /// 版本2支持快捷键字典及数值数组，仍读取版本1。
    let version: Int
    /// 导出时间（ISO-8601）
    let exportedAt: String
    /// 偏好键值（白名单内的键；不含凭证 / 历史 / 标签）
    let preferences: [String: PreferenceValue]
    var menuBarWidgets: [String: PreferenceValue]? = nil

    static let formatIdentifier = "frsetconfig"
    static let currentVersion = 2

}

/// 偏好值的可编码包装（UserDefaults 值域 → JSON）
///
/// 原作 `.frsetconfig` 内部结构 ⬜ 未探明，重建取 JSON（键面=键名，值为带类型判别的对象）。
/// Data（自定义引擎表等二进制偏好）以 base64 字符串承载，避免 JSONEncoder 失败。
enum PreferenceValue: Codable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case strings([String])
    /// base64 编码的 Data
    case data(String)
    indirect case array([PreferenceValue])
    indirect case dictionary([String: PreferenceValue])

    /// 由 UserDefaults 原始值构造；不支持的类型返回 nil（该键将被跳过）
    ///
    /// 数值类型必须走 NSNumber.objCType 判定：UserDefaults 把 Bool 存成 NSNumber，
    /// 直接 `as? Bool` 会把整数 1/0 也吃掉（面板宽度、保留天数等整型键会被导成 true/false）。
    init?(defaultsValue: Any) {
        if let number = defaultsValue as? NSNumber {
            switch String(cString: number.objCType) {
            case "c", "B":     self = .bool(number.boolValue)      // char / C99_BOOL
            case "f", "d":     self = .double(number.doubleValue)  // float / double
            default:           self = .int(number.intValue)       // 各宽度整型（含 long long）
            }
            return
        }
        switch defaultsValue {
        case is NSNull:         self = .null
        case let v as String:   self = .string(v)
        case let v as [String]: self = .strings(v)
        case let v as Data:     self = .data(v.base64EncodedString())
        case let v as [Any]:
            let values = v.compactMap { PreferenceValue(defaultsValue: $0) }
            guard values.count == v.count else { return nil }
            self = .array(values)
        case let v as [String: Any]:
            let values = v.compactMapValues { PreferenceValue(defaultsValue: $0) }
            guard values.count == v.count else { return nil }
            self = .dictionary(values)
        default: return nil
        }
    }

    /// 还原为可写回 UserDefaults 的原生值
    var defaultsValue: Any {
        switch self {
        case .null:               return NSNull()
        case .bool(let v):        return v
        case .int(let v):         return v
        case .double(let v):      return v
        case .string(let v):      return v
        case .strings(let v):     return v
        case .data(let v):        return Data(base64Encoded: v) ?? Data()
        case .array(let v):       return v.map(\.defaultsValue)
        case .dictionary(let v):  return v.mapValues(\.defaultsValue)
        }
    }

    private enum CodingKeys: String, CodingKey { case type, value }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(String.self, forKey: .type)
        switch type {
        case "null":        self = .null
        case "bool":        self = .bool(try c.decode(Bool.self, forKey: .value))
        case "int":         self = .int(try c.decode(Int.self, forKey: .value))
        case "double":      self = .double(try c.decode(Double.self, forKey: .value))
        case "string":      self = .string(try c.decode(String.self, forKey: .value))
        case "strings":     self = .strings(try c.decode([String].self, forKey: .value))
        case "data":        self = .data(try c.decode(String.self, forKey: .value))
        case "array":       self = .array(try c.decode([PreferenceValue].self, forKey: .value))
        case "dictionary":  self = .dictionary(try c.decode([String: PreferenceValue].self, forKey: .value))
        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: c,
                                                  debugDescription: "未知的偏好值类型: \(type)")
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .null:               try c.encode("null", forKey: .type)
        case .bool(let v):        try c.encode("bool", forKey: .type);    try c.encode(v, forKey: .value)
        case .int(let v):         try c.encode("int", forKey: .type);     try c.encode(v, forKey: .value)
        case .double(let v):      try c.encode("double", forKey: .type);  try c.encode(v, forKey: .value)
        case .string(let v):      try c.encode("string", forKey: .type);  try c.encode(v, forKey: .value)
        case .strings(let v):     try c.encode("strings", forKey: .type); try c.encode(v, forKey: .value)
        case .data(let v):        try c.encode("data", forKey: .type);    try c.encode(v, forKey: .value)
        case .array(let v):       try c.encode("array", forKey: .type); try c.encode(v, forKey: .value)
        case .dictionary(let v):  try c.encode("dictionary", forKey: .type); try c.encode(v, forKey: .value)
        }
    }
}

// MARK: - 配置页


struct StatisticsSettingsPane: View {
    // 上次导入/导出结果提示
    @Stored private var lastActionResult: String? = nil
    @Stored private var lastActionFailed = false
    @Stored private var isBusy = false

    /// 导入前的确认弹窗（spec 18 F8：Import Settings Confirm Title/Message）
    @Stored private var pendingImport: FrsetConfigFile? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            transferSection
            infoSection
        }
        .confirmationDialog("导入配置？", isPresented: importConfirmBinding, titleVisibility: .visible) {
            Button("导入", role: .destructive) { performImport(pendingImport) }
            Button("取消", role: .cancel) {}
        } message: {
            Text("\(pendingImport?.preferences.count ?? 0) 项偏好、\(pendingImport?.menuBarWidgets?.count ?? 0) 项菜单部件参数。导入立即应用；旧文件中的使用统计忽略。")
        }
    }

    private var importConfirmBinding: Binding<Bool> {
        Binding(get: { pendingImport != nil },
                set: { if !$0 { pendingImport = nil } })
    }

    // MARK: 独立配置导入与导出

    private var transferSection: some View {
        SettingsSection("配置导出与导入") {
            SettingsGroupBox {
                SettingsRow(icon: "square.and.arrow.up", title: "导出配置",
                            subtitle: "将已保存偏好与菜单部件配置写入 .frsetconfig 文件") {
                    Button("导出…") { performExport() }
                        .controlSize(.small)
                        .disabled(isBusy)
                }
                SettingsDivider()
                SettingsRow(icon: "square.and.arrow.down", title: "导入配置",
                            subtitle: "独立即时操作：从 .frsetconfig 恢复偏好与菜单部件配置") {
                    Button("导入…") { chooseImportFile() }
                        .controlSize(.small)
                        .disabled(isBusy)
                }
                if let result = lastActionResult {
                    SettingsDivider()
                    SettingsRow(icon: lastActionFailed ? "exclamationmark.triangle.fill" : "checkmark.circle.fill",
                                title: lastActionFailed ? "操作未完全成功" : "操作完成",
                                subtitle: result) {}
                }
            }
        }
    }

    private var infoSection: some View {
        SettingsSection("说明") {
            SettingsGroupBox {
                SettingsRow(icon: "info.circle", title: "导出内容",
                            subtitle: "仅包含偏好与菜单部件配置，不含剪贴板内容、标签、凭证、临时预览和使用统计") {}
                SettingsDivider()
                SettingsRow(icon: "clock", title: "独立采样间隔",
                            subtitle: "各菜单部件间隔单独恢复；主监测间隔不覆盖部件间隔") {}
            }
        }
    }

    // MARK: 导出

    private func performExport() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [Self.configFileType]
        panel.nameFieldStringValue = Self.defaultExportFileName()
        panel.canCreateDirectories = true
        panel.prompt = "导出"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let file = FrsetConfigFile(format: FrsetConfigFile.formatIdentifier,
                version: FrsetConfigFile.currentVersion, exportedAt: Self.iso8601Now(),
                preferences: try Self.exportablePreferences(), menuBarWidgets: Self.exportableMenuBarConfiguration())
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            try encoder.encode(file).write(to: url, options: .atomic)
            StatisticsManager.shared.record(AnalyticsEvent.settingsExportSuccess)
            lastActionFailed = false
            lastActionResult = "已导出 \(file.preferences.count) 项偏好与 \(file.menuBarWidgets?.count ?? 0) 项菜单部件配置到 \(url.lastPathComponent)"
            Toast.show("导出成功", icon: "checkmark.circle.fill")
        } catch {
            lastActionFailed = true
            lastActionResult = "写入失败：\(error.localizedDescription)"
            Toast.show("导出失败", icon: "exclamationmark.triangle.fill", isWarning: true)
        }
    }

    // MARK: 导入

    private func chooseImportFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [Self.configFileType, .json]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "导入"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        isBusy = true
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let file = try JSONDecoder().decode(FrsetConfigFile.self, from: Data(contentsOf: url))
                guard file.format == FrsetConfigFile.formatIdentifier else { throw ConfigImportError.badFormat }
                guard file.version <= FrsetConfigFile.currentVersion else { throw ConfigImportError.unsupportedVersion(file.version) }
                DispatchQueue.main.async { self.pendingImport = file; self.isBusy = false }
            } catch {
                DispatchQueue.main.async {
                    self.isBusy = false
                    self.lastActionFailed = true
                    self.lastActionResult = "导入失败：\(error.localizedDescription)"
                }
            }
        }
    }

    private func performImport(_ file: FrsetConfigFile?) {
        pendingImport = nil
        guard let file else { return }
        let invalid = file.preferences.keys.filter { !Self.exportablePreferenceKeySet.contains($0) }
        let saved = FSBarConfigurationSnapshot() as? [String: Any] ?? [:]
        let widgets = (file.menuBarWidgets ?? [:]).filter {
            Self.isMenuBarConfigurationKey($0.key) && !($0.value.defaultsValue as! NSObject).isEqual(saved[$0.key])
        }.mapValues(\.defaultsValue)
        if !widgets.isEmpty, let reason = FSBarSaveConfiguration(widgets, []) {
            lastActionFailed = true; lastActionResult = reason
            return
        }
        if !widgets.isEmpty { FSBarReloadFromStore(); FSRunCatIconApplySavedConfiguration() }
        if let reason = Self.applyImportedPreferences(file.preferences) {
            lastActionFailed = true; lastActionResult = reason
            return
        }
        lastActionFailed = !invalid.isEmpty
        lastActionResult = "已应用 \(file.preferences.count - invalid.count) 项偏好与 \(widgets.count) 项菜单部件配置"
            + (invalid.isEmpty ? "" : "；忽略 \(invalid.count) 个偏好键")
        StatisticsManager.shared.record(AnalyticsEvent.settingsImportSuccess)
    }

    static func applyImportedPreferences(_ supplied: [String: PreferenceValue]) -> String? {
        let defaults = UserDefaults.standard
        let incoming = supplied.filter {
            exportablePreferenceKeySet.contains($0.key) && !($0.value.defaultsValue as! NSObject).isEqual(defaults.object(forKey: $0.key))
        }
        let startup = StartupSettingsDraft()
        if case .bool(let enabled)? = incoming[Preferences.Keys.launchAtLogin] { startup.launchAtLogin = enabled }
        if case .string(let language)? = incoming["language"] { startup.language = language }
        if startup.isDirty, let reason = startup.save() { return reason }
        var shortcuts: [String: AppBootstrap.ShortcutBinding] = [:]
        let combinations = supplied["shortcuts.bindings"]?.defaultsValue as? [String: [UInt32]]
        let doubleTaps = supplied["shortcuts.doubleTap"]?.defaultsValue as? [String: String]
        let toolBindings = supplied["toolbox.toolShortcuts"]?.defaultsValue as? [String: [UInt32]]
        for entry in AppBootstrap.shortcutSettingsEntries {
            let pair = entry.id.hasPrefix("tool.") ? toolBindings?[String(entry.id.dropFirst(5))] :
                (combinations?[entry.id] ?? (entry.id == "colorpicker" ? combinations?["colorPicker"] ?? toolBindings?["colorpicker"] : nil))
            let rawModifier = doubleTaps?[entry.id] ?? (entry.id == "colorpicker" ? doubleTaps?["colorPicker"] : nil)
            var value = AppBootstrap.shortcutSettingsValue(for: entry.id)
            if let pair {
                guard pair.isEmpty || pair.count == 2 else { return "\(entry.title)：导入的组合键数据格式错误" }
                value = AppBootstrap.ShortcutBinding(trigger: pair.isEmpty ? .unbound : .combination,
                                                     keyCode: pair.first, modifiers: pair.last ?? 0)
            }
            if let rawModifier {
                guard AppBootstrap.supportsDoubleTap(for: entry.id), let modifier = DoubleTapModifier(rawValue: rawModifier) else {
                    return "\(entry.title)：导入的双按修饰键无效"
                }
                value.trigger = .doubleTap; value.doubleTap = modifier
            }
            if value != AppBootstrap.shortcutSettingsValue(for: entry.id) { shortcuts[entry.id] = value }
        }
        if !shortcuts.isEmpty, let reason = AppBootstrap.applyShortcuts(shortcuts) { return reason }
        applyPreferences(incoming.filter {
            !["shortcuts.bindings", "shortcuts.doubleTap", "toolbox.toolShortcuts",
              Preferences.Keys.launchAtLogin, "language"].contains($0.key)
        })
        guard defaults.synchronize() else { return "配置写入磁盘失败" }
        if incoming["showSystemStatus"] != nil {
            PanelSegments.migrateLegacyVisibility()
            NotificationCenter.default.post(name: Personalization.didChangeNotification, object: nil)
        }
        if case .string(let raw)? = incoming["appearance"], let mode = AppearanceMode(rawValue: raw) {
            AppearanceManager.shared.apply(mode)
        }
        if incoming.keys.contains(where: { $0.hasPrefix("ui.") }) { Personalization.shared.reloadFromDefaults() }
        if incoming[Preferences.Keys.panelWidth] != nil || incoming[Preferences.Keys.panelHeight] != nil ||
            incoming.keys.contains(where: { $0.hasPrefix("panel.segment.") }) {
            NotificationCenter.default.post(name: Personalization.didChangeNotification, object: nil)
        }
        let floating = FloatingClipDeskStore.shared
        if incoming[FloatingClipPrefs.layoutKey] != nil { floating.layout = FloatingClipPrefs.layout }
        if incoming[FloatingClipPrefs.cardSizeKey] != nil { floating.cardSize = FloatingClipPrefs.cardSize }
        if incoming[FloatingClipPrefs.splitRatioKey] != nil { floating.splitRatio = FloatingClipPrefs.splitRatio }
        if incoming[FloatingClipPrefs.hoverPreviewKey] != nil { floating.hoverPreviewEnabled = FloatingClipPrefs.hoverPreviewEnabled }
        if incoming[Preferences.Keys.floatingOriginX] != nil || incoming[Preferences.Keys.floatingOriginY] != nil ||
            incoming[Preferences.Keys.floatingWidth] != nil || incoming[Preferences.Keys.floatingHeight] != nil {
            let controller = FloatingClipboardWindowController.shared
            controller.window?.setFrame(controller.state.clampedFrame(), display: true)
        }
        if case .bool(let pinned)? = incoming["floatingClipboard.pinned"] {
            let controller = FloatingClipboardWindowController.shared
            controller.store.isPinned = pinned
            controller.applyPinLevel()
        }
        let serviceChanged = incoming.keys.contains { $0 == Preferences.Keys.aiBaseURL || $0.hasPrefix("ai.baseURL.") }
        if serviceChanged {
            for provider in LLMProviderKind.allCases { AIProviderModelDiscoveryCache.shared.invalidate(provider) }
        }
        if incoming[Preferences.Keys.aiProvider] != nil || incoming[Preferences.Keys.aiModel] != nil || serviceChanged {
            LLMService.shared.reload()
        }
        if incoming.keys.contains(where: { $0.hasPrefix("monitor.") }) {
            NotificationCenter.default.post(name: MonitorPreferences.didChangeNotification, object: nil)
        }
        if incoming.keys.contains(where: { $0.hasPrefix("menu-bar-icon-") || $0.hasPrefix("entry.") }) {
            MenuBarIconStyleApplier.shared.refresh()
            NotificationCenter.default.post(name: GlobalEntries.didChangeNotification, object: nil)
        }
        if incoming.keys.contains(where: { $0.hasPrefix("shelf.") }) {
            NotificationCenter.default.post(name: .curtainPreferencesChanged, object: nil)
        }
        if incoming[Preferences.Keys.calendarShowLunar] != nil { CalendarService.shared.refreshAuthorization() }
        if incoming[Preferences.Keys.captureSavePath] != nil { ScreenshotManager.shared.reloadRecent() }
        if case .string(let feedURL)? = incoming["update.feedURL"] { AppUpdateChecker.shared.feedURL = feedURL }
        SearchServiceManager.shared.reloadFromDefaults()
        return nil
    }

    // MARK: 偏好白名单

    /// 导入失败原因
    enum ConfigImportError: LocalizedError {
        case badFormat
        case unsupportedVersion(Int)

        var errorDescription: String? {
            switch self {
            case .badFormat:               return "文件格式无效（缺少 frsetconfig 标识）"
            case .unsupportedVersion(let v): return "配置版本 \(v) 高于当前支持的 \(FrsetConfigFile.currentVersion)"
            }
        }
    }

    /// 可导出/导入的偏好键白名单。
    ///
    /// 收录范围：通用 / 外观 / 语言 / 面板 / 剪贴板 / 悬浮窗 / 监测 / 截图 / AI / 工具 / 搜索 / 埋点开关。
    /// **刻意不收录**：AI 凭证（落在加密文件 `ai-credentials.bin`，本就不在 UserDefaults）、
    /// 剪贴板历史、标签、一次性引导标记（`has*`/`*Consumed` 类）。
    ///
    /// 键名来源标注：
    /// - `Preferences.Keys.*` = Core/Runtime/Preferences.swift 声明的键；
    /// - `AppearanceManager` / `LanguageManager` 的键为各自文件内私有常量，此处按字面量写死；
    /// - 跨模块扩展键（Clipboard / Panel 的 `public extension Preferences.Keys`）在本模块
    ///   typecheck（Core+Models+Storage+本目录）下不可见，故同样写字面量并在此注释说明。
    static let exportablePreferenceKeys: [String] = {
        var keys: [String] = [
        // 通用
        Preferences.Keys.launchAtLogin,
        Preferences.Keys.menuBarIconsVisible,
        Preferences.Keys.panelWidth,
        Preferences.Keys.panelHeight,
        // 外观与语言（AppearanceManager.defaultsKey / LanguageManager.defaultsKey 均为私有常量）
        "appearance",
        "language",
        // 菜单栏图标样式（GeneralSettingsPane 内的键常量）
        GeneralSettingsPane.menuBarIconStyleLogoKey,
        GeneralSettingsPane.menuBarIconStyleFanKey,
        GeneralSettingsPane.menuBarIconStyleDateKey,
        GeneralSettingsPane.menuBarIconStyleCustomKey,
        GeneralSettingsPane.menuBarIconCustomSymbolKey,
        // 剪贴板
        Preferences.Keys.clipboardRetentionDays,
        Preferences.Keys.clipboardStorageLimitMB,
        Preferences.Keys.clipboardIgnoredApps, "automaticScreenshotOCREnabled",
        "clipboard.autoPaste",                    // ClipboardManager.swift 的 Keys 扩展
        // 悬浮剪贴板窗
        Preferences.Keys.floatingOriginX,
        Preferences.Keys.floatingOriginY,
        Preferences.Keys.floatingWidth,
        Preferences.Keys.floatingHeight,
        "floatingClipboard.pinned",
        // 悬停预览（PanelPreviewPreferences.swift 的 Keys 扩展）
        "hoverPreviewInMainWindowEnabled",
        "hoverPreviewInFloatingClipboardEnabled",
        // 监测
        Preferences.Keys.monitorRefreshInterval,
        Preferences.Keys.monitorEnabledModules,
        Preferences.Keys.monitorCombinedMode,
        // 截图 / OCR
        Preferences.Keys.captureSound,
        Preferences.Keys.captureSavePath,
        Preferences.Keys.ocrLanguages,
        "ocr.autoDetectLanguages", "capture.defaultAction", "capture.ocrShowResultWindow", "capture.delaySeconds",
        CaptureFileName.keyTemplate, MosaicTextOnly.keyEnabled, CaptureOCRNotify.keySilent, CaptureOCRNotify.keySeconds,
        Watermark.keyEnabled, Watermark.keyText, Watermark.keyOpacity, Watermark.keyAngle, Watermark.keyTile, Watermark.keyScale,
        // AI（不含凭证：凭证在 CredentialStore 加密文件里）
        Preferences.Keys.aiProvider,
        Preferences.Keys.aiModel,
        Preferences.Keys.aiBaseURL,
        AISettings.keyDefaultAction, AISettings.keyTemperature, AISettings.keyMaxTokens, AISettings.keySystemPrompt,
        AISettings.keyTranslationProvider, AISettings.keyOCRRefiner, CustomAIToolStore.storageKey,
        // 工具箱
        Preferences.Keys.toolboxEnabled,
        BuiltinTools.defaultActionKey, "shortcuts.bindings", "shortcuts.doubleTap", "toolbox.toolShortcuts",
        Preferences.Keys.calendarShowLunar,
        // 搜索（SearchServiceManager.Keys，为私有枚举，按字面量写）
        "clearSearchInputAfterWebAction",
        "customEngines",
        "engineOrder",
        "activeBarItems",
        // 埋点开关（D5：analyticsEnabled）
        "analyticsEnabled",
        FloatingClipPrefs.layoutKey, FloatingClipPrefs.cardSizeKey,
        FloatingClipPrefs.hoverPreviewKey, FloatingClipPrefs.splitRatioKey,
        PanelSegments.homeKey, PanelSegments.monitorKey, PanelSegments.orderKey,
        GlobalEntries.homeKey, GlobalEntries.monitorPopoutKey, GlobalEntries.statsBarKey,
        Preferences.Keys.panelPinned, Preferences.Keys.panelWidthV2,
        Preferences.Keys.calendarFirstWeekday, "showCalendar", "showSystemStatus",
        MonitorPreferences.keyEnabled, MonitorPreferences.keyShowTemperatures,
        MonitorPreferences.keyFlowTopN, MonitorPreferences.keyNetworkKeepAlive,
        CaptureToolbarStyle.preferenceKey, CaptureRatioStore.keyItems, CaptureRatioStore.keySelected,
        PinStyle.keyBorderWidth, PinStyle.keyBorderColor, PinStyle.keyCorner, PinStyle.keyShadow,
        PinStyle.keyMagnet, PinStyle.keyOpacity, PinStyle.keyAutoHide,
        Preferences.Keys.curtainEnabled, Preferences.Keys.curtainRopeStyle, Preferences.Keys.curtainDisplayDuration,
        Preferences.Keys.curtainMaxCards, Preferences.Keys.curtainAttachOnCapture, Preferences.Keys.curtainCardWidth,
        Preferences.Keys.curtainRailScales, Preferences.Keys.curtainRevealOnHover,
        RecordingOptions.keyCursor, RecordingOptions.keyCameraCorner, RecordingOptions.keyCameraScale,
        RecordingOptions.keyKeys, RecordingOptions.keyClicks, "update.feedURL",
        RecordingOptions.keyFPS, RecordingOptions.keyAudio, RecordingOptions.keyCamera, RecordingOptions.keyCameraDevice,
        RecordingOptions.keyExcluded, RecordingOptions.keySavePath,
        ]
        keys += PersonalizationSettingsPart.allCases.flatMap { $0.personalizationFields.map(\.key) }
        keys += MonitorModuleID.allCases.map { MonitorPreferences.keyEnabled(for: $0) }
        keys += LLMProviderKind.allCases.map { AISettings.baseURLKey(for: $0) }
        keys += ToolRegistry.all.map { "toolbox.tool.\($0.id).enabled" }
        return keys
    }()

    static func isMenuBarConfigurationKey(_ key: String) -> Bool {
        MonitorWidgetsSettingsDraft.arrangementKeys.contains(key) || key == "Bar_MainIconCat" ||
            (FSBarAllModules() as? [String] ?? []).contains {
                key.hasPrefix($0 + "_") || ($0 == "Power" && (key.hasPrefix("CPUPower_") || key.hasPrefix("GPUPower_")))
            }
    }

    static func exportableMenuBarConfiguration() -> [String: PreferenceValue] {
        var configuration = (FSBarDefaultConfiguration() as? [String: Any] ?? [:])
            .merging(FSBarConfigurationSnapshot() as? [String: Any] ?? [:]) { _, saved in saved }
        for module in FSBarAllModules() as? [String] ?? [] {
            configuration[module + "_updateInterval"] = configuration[module + "_updateInterval"] ?? "1"
        }
        configuration["Widgets_order"] = FSBarOrderedModules(configuration)
        configuration["Bar_MainIconCat"] = MenuBarIconStyleStore.current == .cat
        return configuration.filter { isMenuBarConfigurationKey($0.key) }
            .compactMapValues { PreferenceValue(defaultsValue: $0) }
    }

    /// 导出时读取白名单内的偏好键值（未落盘的键不写入）
    static func exportablePreferences() throws -> [String: PreferenceValue] {
        let defaults = UserDefaults.standard
        var out: [String: PreferenceValue] = [:]
        out.reserveCapacity(exportablePreferenceKeys.count)
        for key in exportablePreferenceKeys {
            guard let raw = defaults.object(forKey: key),
                  let value = PreferenceValue(defaultsValue: raw) else { continue }
            out[key] = value
        }
        for (key, value) in Personalization.shared.preferenceValues where exportablePreferenceKeySet.contains(key) {
            out[key] = value.flatMap { PreferenceValue(defaultsValue: $0) } ?? .null
        }
        let effective: [String: Any] = [
            "appearance": AppearanceManager.shared.mode.rawValue,
            "language": LanguageManager.shared.overrideDisplayLanguage,
            Preferences.Keys.launchAtLogin: Preferences.shared.launchAtLogin,
            MenuBarIconStyleStore.customSymbolKey: MenuBarIconStyleStore.customSymbol,
            FloatingClipPrefs.layoutKey: FloatingClipPrefs.layout.rawValue,
            FloatingClipPrefs.cardSizeKey: FloatingClipPrefs.cardSize.rawValue,
            FloatingClipPrefs.hoverPreviewKey: FloatingClipPrefs.hoverPreviewEnabled,
            FloatingClipPrefs.splitRatioKey: Double(FloatingClipPrefs.splitRatio),
            PanelSegments.homeKey: Preferences.shared.value(PanelSegments.homeKey, default: true),
            PanelSegments.monitorKey: Preferences.shared.value(PanelSegments.monitorKey, default: true),
            PanelSegments.orderKey: PanelSegments.encode(PanelSegments.order),
            Preferences.Keys.panelWidth: Preferences.shared.value(Preferences.Keys.panelWidth, default: 400.0),
            GlobalEntries.homeKey: GlobalEntries.isEnabled(GlobalEntries.homeKey),
            GlobalEntries.monitorPopoutKey: GlobalEntries.isEnabled(GlobalEntries.monitorPopoutKey),
            GlobalEntries.statsBarKey: GlobalEntries.isEnabled(GlobalEntries.statsBarKey),
            CaptureToolbarStyle.preferenceKey: CaptureToolbarStyle.current.rawValue,
            CaptureRatioStore.keySelected: CaptureRatioStore.selectedID,
            PinStyle.keyBorderWidth: PinStyle.borderWidth, PinStyle.keyBorderColor: PinStyle.borderColorToken,
            PinStyle.keyCorner: PinStyle.cornerRadius, PinStyle.keyShadow: PinStyle.shadow,
            PinStyle.keyMagnet: PinStyle.magnet, PinStyle.keyOpacity: PinStyle.opacity, PinStyle.keyAutoHide: PinStyle.chromeAutoHide,
            Preferences.Keys.curtainEnabled: CurtainPref.enabled, Preferences.Keys.curtainRopeStyle: CurtainPref.ropeStyle.rawValue,
            Preferences.Keys.curtainDisplayDuration: CurtainPref.displayDuration, Preferences.Keys.curtainMaxCards: CurtainPref.maxCards,
            Preferences.Keys.curtainAttachOnCapture: CurtainPref.attachOnCapture, Preferences.Keys.curtainCardWidth: Double(CurtainPref.cardWidth),
            Preferences.Keys.curtainRailScales: CurtainPref.railScalesWithCards, Preferences.Keys.curtainRevealOnHover: CurtainPref.revealOnHover,
            RecordingOptions.keyCursor: RecordingOptions.defaultShowsCursor, RecordingOptions.keyCameraCorner: RecordingOptions.cameraCorner.rawValue,
            RecordingOptions.keyCameraScale: RecordingOptions.cameraScale, RecordingOptions.keyKeys: RecordingOptions.showKeys,
            RecordingOptions.keyClicks: RecordingOptions.showClicks,
            Preferences.Keys.floatingOriginX: Double(FloatingClipboardPinState.shared.originX),
            Preferences.Keys.floatingOriginY: Double(FloatingClipboardPinState.shared.originY),
            Preferences.Keys.floatingWidth: Double(FloatingClipboardPinState.shared.width),
            Preferences.Keys.floatingHeight: Double(FloatingClipboardPinState.shared.height),
            "floatingClipboard.pinned": FloatingClipboardPinState.shared.isPinned,
            "update.feedURL": AppUpdateChecker.shared.feedURL,
            Preferences.Keys.clipboardRetentionDays: Preferences.shared.value(Preferences.Keys.clipboardRetentionDays, default: 30),
            Preferences.Keys.clipboardStorageLimitMB: Preferences.shared.value(Preferences.Keys.clipboardStorageLimitMB, default: 2048),
            Preferences.Keys.clipboardAutoPaste: Preferences.shared.value(Preferences.Keys.clipboardAutoPaste, default: false),
            Preferences.Keys.clipboardIgnoredApps: Preferences.shared.value(Preferences.Keys.clipboardIgnoredApps, default: [String]()),
            "automaticScreenshotOCREnabled": Preferences.shared.value("automaticScreenshotOCREnabled", default: true),
            Preferences.Keys.calendarFirstWeekday: Preferences.shared.calendarFirstWeekday,
            Preferences.Keys.calendarShowLunar: Preferences.shared.calendarShowLunar,
            "showCalendar": Preferences.shared.value("showCalendar", default: true),
            Preferences.Keys.captureSound: Preferences.shared.value(Preferences.Keys.captureSound, default: true),
            Preferences.Keys.captureSavePath: Preferences.shared.value(Preferences.Keys.captureSavePath, default: ""),
            Preferences.Keys.ocrLanguages: Preferences.shared.value(Preferences.Keys.ocrLanguages, default: ["zh-Hans", "en-US"]),
            "ocr.autoDetectLanguages": OCRService.autoDetectLanguages,
            "capture.defaultAction": ScreenshotManager.shared.defaultAction.rawValue,
            "capture.ocrShowResultWindow": ScreenshotManager.shared.ocrShowResultWindow,
            "capture.delaySeconds": ScreenshotManager.shared.delaySeconds,
            CaptureFileName.keyTemplate: CaptureFileName.template,
            CaptureOCRNotify.keySilent: CaptureOCRNotify.isSilent, CaptureOCRNotify.keySeconds: CaptureOCRNotify.seconds,
            MosaicTextOnly.keyEnabled: MosaicTextOnly.isEnabled,
            Watermark.keyEnabled: Watermark.isEnabled, Watermark.keyText: Watermark.text,
            Watermark.keyOpacity: Watermark.opacity, Watermark.keyAngle: Watermark.angle,
            Watermark.keyTile: Watermark.tile, Watermark.keyScale: Watermark.scale,
            RecordingOptions.keyFPS: RecordingOptions.defaultFPS, RecordingOptions.keyAudio: RecordingOptions.defaultAudio.rawValue,
            RecordingOptions.keyCamera: RecordingOptions.cameraEnabled, RecordingOptions.keyCameraDevice: RecordingOptions.cameraDeviceID,
            RecordingOptions.keyExcluded: RecordingOptions.excludedBundleIDs, RecordingOptions.keySavePath: RecordingOptions.savePathRaw,
            Preferences.Keys.aiProvider: AISettings.providerKind.rawValue, Preferences.Keys.aiModel: AISettings.selectedModel,
            AISettings.keyDefaultAction: AISummaryAction.storedDefault.rawValue,
            BuiltinTools.defaultActionKey: BuiltinTools.defaultAction.rawValue,
        ]
        for (key, value) in effective { out[key] = PreferenceValue(defaultsValue: value) }
        for style in MenuBarIconStyle.allCases where style != .cat {
            out[style.preferenceKey] = .bool(MenuBarIconStyleStore.current == style)
        }
        for provider in LLMProviderKind.allCases { out[AISettings.baseURLKey(for: provider)] = .string(AISettings.baseURL(for: provider).absoluteString) }
        for tool in ToolRegistry.all { out["toolbox.tool.\(tool.id).enabled"] = .bool(ToolRegistry.isEnabled(id: tool.id)) }
        var combinations: [String: PreferenceValue] = [:], doubles: [String: PreferenceValue] = [:], tools: [String: PreferenceValue] = [:]
        for entry in AppBootstrap.shortcutSettingsEntries {
            let value = AppBootstrap.shortcutSettingsValue(for: entry.id)
            let pair: [PreferenceValue] = value.keyCode.map { [.int(Int($0)), .int(Int(value.modifiers))] } ?? []
            if entry.id.hasPrefix("tool.") { tools[String(entry.id.dropFirst(5))] = .array(pair) }
            else {
                combinations[entry.id] = .array(pair)
                if value.trigger == .doubleTap { doubles[entry.id] = .string(value.doubleTap.rawValue) }
            }
        }
        out["shortcuts.bindings"] = .dictionary(combinations)
        out["shortcuts.doubleTap"] = .dictionary(doubles)
        out["toolbox.toolShortcuts"] = .dictionary(tools)
        out[CaptureRatioStore.keyItems] = .data(try JSONEncoder().encode(CaptureRatioStore.customItems).base64EncodedString())
        return out
    }

    // v126（性能审计 F1190）：白名单集合缓存——applyPreferences 原来每次导入都从
    // 40+ 项数组重建一个 Set（逐项哈希），提为 static 常量后只建一次。
    private static let exportablePreferenceKeySet: Set<String> = Set(exportablePreferenceKeys)

    /// 写回导入的偏好键值
    /// - Returns: 被忽略（不在白名单内）的键名。
    @discardableResult
    static func applyPreferences(_ incoming: [String: PreferenceValue]) -> [String] {
        let whitelist = exportablePreferenceKeySet
        let defaults = UserDefaults.standard
        var ignored: [String] = []
        for (key, value) in incoming {
            if whitelist.contains(key) {
                if case .null = value { defaults.removeObject(forKey: key) }
                else { defaults.set(value.defaultsValue, forKey: key) }
            } else {
                ignored.append(key)
            }
        }
        return ignored.sorted()
    }

    // MARK: 文件类型与命名

    /// `.frsetconfig` 文件类型（动态类型：扩展名 + JSON 父类型）
    ///
    /// 原作 Info.plist 里的 UTI 声明 ⬜ 未探明，重建用动态 UTType，
    /// 既保证保存面板自动补全扩展名，又让 JSON 工具也能识别。
    static let configFileType: UTType =
        UTType(filenameExtension: "frsetconfig", conformingTo: .json) ?? .json

    static func defaultExportFileName(now: Date = Date()) -> String {
        "Kitnest-配置-\(Self.dayStamp(now)).frsetconfig"
    }

    // v126（性能审计 F1188/F1190）：DateFormatter 复用——导出/导入各 new 一个
    // formatter（初始化要装载 locale/ICU 表），提为 static 常量。
    private static let dayStampFormatter: DateFormatter = {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyyMMdd-HHmmss"
        fmt.timeZone = TimeZone.current
        return fmt
    }()

    private static let iso8601Formatter: DateFormatter = {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZ"
        fmt.timeZone = TimeZone.current
        return fmt
    }()

    /// yyyyMMdd（导出文件名用，避免文件名里的冒号）
    private static func dayStamp(_ date: Date) -> String {
        dayStampFormatter.string(from: date)
    }

    /// ISO-8601（写进文件头的 exportedAt）
    private static func iso8601Now() -> String {
        iso8601Formatter.string(from: Date())
    }
}
