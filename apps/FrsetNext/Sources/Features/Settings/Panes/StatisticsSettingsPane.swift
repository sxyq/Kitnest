import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - 数据与统计设置页（页签 id "statistics"）
//
// 承载 spec 17 S12「设置导出/导入携带统计数据」与 Q6/Q7/Q8 的出口：
// - Q6 total(event:)          → 「关键指标」区逐事件累计（此前零调用点）
// - Q7 reviewRequestUsage()   → 「评分请求口径」行（此前零调用点）
// - Q8 exportAll()/importMerge() → `.frsetconfig` 导出 / MAX 合并导入（此前零调用点）
//
// 导入语义（spec 17 S12 / spec 18 F8）：
// - 统计数据走 `importMerge` 的事务内 `MAX(旧, 新, 0)`，**不覆盖较新/削减后的数据**；
// - 偏好设置按白名单逐键写回 UserDefaults；不在白名单的键一律忽略，
//   解析失败的键按原作 `settings.invalid-` 前缀落标记，供「导入结果」行展示。

// MARK: - 导出文件结构（.frsetconfig / JSON）

/// `.frsetconfig` 顶层结构：格式标识 + 版本号 + 导出时间 + 偏好键值 + 事件计数数组
struct FrsetConfigFile: Codable {
    /// 格式标识（导入时校验，防止把任意 JSON 当配置导入）
    let format: String
    /// 结构版本（后续字段演进用；当前仅 1）
    let version: Int
    /// 导出时间（ISO-8601）
    let exportedAt: String
    /// 偏好键值（白名单内的键；不含凭证 / 历史 / 标签）
    let preferences: [String: PreferenceValue]
    /// 统计数据行（day + event_name + count，对应 usage_daily_metrics 窄表）
    let statistics: [FrsetConfigStatRow]

    static let formatIdentifier = "frsetconfig"
    static let currentVersion = 1

    /// 单条统计行（day / event_name / count）
    struct FrsetConfigStatRow: Codable {
        let day: String
        let event: String
        let count: Int
    }
}

/// 偏好值的可编码包装（UserDefaults 值域 → JSON）
///
/// 原作 `.frsetconfig` 内部结构 ⬜ 未探明，重建取 JSON（键面=键名，值为带类型判别的对象）。
/// Data（自定义引擎表等二进制偏好）以 base64 字符串承载，避免 JSONEncoder 失败。
enum PreferenceValue: Codable {
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case strings([String])
    /// base64 编码的 Data
    case data(String)

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
        case let v as String:   self = .string(v)
        case let v as [String]: self = .strings(v)
        case let v as Data:     self = .data(v.base64EncodedString())
        default: return nil
        }
    }

    /// 还原为可写回 UserDefaults 的原生值
    var defaultsValue: Any {
        switch self {
        case .bool(let v):        return v
        case .int(let v):         return v
        case .double(let v):      return v
        case .string(let v):      return v
        case .strings(let v):     return v
        case .data(let v):        return Data(base64Encoded: v) ?? Data()
        }
    }

    private enum CodingKeys: String, CodingKey { case type, value }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(String.self, forKey: .type)
        switch type {
        case "bool":        self = .bool(try c.decode(Bool.self, forKey: .value))
        case "int":         self = .int(try c.decode(Int.self, forKey: .value))
        case "double":      self = .double(try c.decode(Double.self, forKey: .value))
        case "string":      self = .string(try c.decode(String.self, forKey: .value))
        case "strings":     self = .strings(try c.decode([String].self, forKey: .value))
        case "data":        self = .data(try c.decode(String.self, forKey: .value))
        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: c,
                                                  debugDescription: "未知的偏好值类型: \(type)")
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .bool(let v):        try c.encode("bool", forKey: .type);    try c.encode(v, forKey: .value)
        case .int(let v):         try c.encode("int", forKey: .type);     try c.encode(v, forKey: .value)
        case .double(let v):      try c.encode("double", forKey: .type);  try c.encode(v, forKey: .value)
        case .string(let v):      try c.encode("string", forKey: .type);  try c.encode(v, forKey: .value)
        case .strings(let v):     try c.encode("strings", forKey: .type); try c.encode(v, forKey: .value)
        case .data(let v):        try c.encode("data", forKey: .type);    try c.encode(v, forKey: .value)
        }
    }
}

// MARK: - 统计与数据页

struct StatisticsSettingsPane: View {
    // 评分请求口径（Q7）
    @Stored private var reviewUsage: Int = 0
    // 关键指标（Q6：逐事件累计）
    @Stored private var clipboardCaptureTotal: Int = 0
    @Stored private var screenshotTotal: Int = 0
    @Stored private var toolTotal: Int = 0
    @Stored private var activeDays: Int = 0
    @Stored private var storedItems: Int = 0
    /// v107：各大功能累计（event → count）
    @Stored private var featureCounts: [String: Int] = [:]
    // 上次导入/导出结果提示
    @Stored private var lastActionResult: String? = nil
    @Stored private var lastActionFailed = false
    @Stored private var isBusy = false
    /// v115：图表刷新纪元——「刷新统计」时 +1 强制 StatisticsChartsView 重建重拉
    @Stored private var chartsEpoch = 0

    /// 导入前的确认弹窗（spec 18 F8：Import Settings Confirm Title/Message）
    @Stored private var pendingImportURL: URL? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            // v115：与用量统计窗同源的三层图表（指标卡 / 总览+30 天柱状 / 活动热力图）
            chartsSection
            metricsSection
            featureSection
            reviewSection
            transferSection
            infoSection
        }
        .onAppear(perform: refresh)
        .confirmationDialog("导入配置？", isPresented: importConfirmBinding, titleVisibility: .visible) {
            Button("导入", role: .destructive) { performImport(pendingImportURL) }
            Button("取消", role: .cancel) {}
        } message: {
            Text("导入会用配置文件中的偏好设置覆盖当前设置，统计数据按较大值合并（不会削减已有计数）。")
        }
    }

    // MARK: 用量图表（v115：复用统计窗 StatisticsChartsView，同源数据装载）

    private var chartsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text("用量图表")
                    .font(.system(size: 15, weight: .semibold))
                Text("与「使用统计」窗同源 · 数据仅存储在本机")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.tertiaryText)
                Spacer()
                Button("刷新") {
                    refresh()
                    chartsEpoch += 1
                }
                .controlSize(.small)
                .disabled(isBusy)
            }
            StatisticsChartsView()
                .id(chartsEpoch)
                .padding(12)
                .background(Color(NSColor.textBackgroundColor).opacity(0.5),
                            in: RoundedRectangle(cornerRadius: Theme.Radius.window, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.window, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
                )
        }
    }

    private var importConfirmBinding: Binding<Bool> {
        Binding(get: { pendingImportURL != nil },
                set: { if !$0 { pendingImportURL = nil } })
    }

    // MARK: 关键指标（Q6 total(event:) 出口）

    private var metricsSection: some View {
        SettingsSection(title: "使用统计") {
            SettingsGroupBox {
                SettingsRow(icon: "doc.on.clipboard", title: "剪贴板捕获",
                            subtitle: "累计捕获次数（clipboard_capture）") {
                    Text("\(clipboardCaptureTotal)")
                        .font(.system(size: 13, weight: .medium))
                        .monospacedDigit()
                }
                SettingsDivider()
                SettingsRow(icon: "camera.viewfinder", title: "屏幕截图",
                            subtitle: "累计截图次数（screenshot_capture）") {
                    Text("\(screenshotTotal)")
                        .font(.system(size: 13, weight: .medium))
                        .monospacedDigit()
                }
                SettingsDivider()
                SettingsRow(icon: "square.and.pencil", title: "划词工具",
                            subtitle: "累计工具执行成功次数（tool_execute_success）") {
                    Text("\(toolTotal)")
                        .font(.system(size: 13, weight: .medium))
                        .monospacedDigit()
                }
                SettingsDivider()
                SettingsRow(icon: "calendar", title: "活跃天数",
                            subtitle: "有过任意埋点事件的天数") {
                    Text("\(activeDays)")
                        .font(.system(size: 13, weight: .medium))
                        .monospacedDigit()
                }
                SettingsDivider()
                SettingsRow(icon: "square.stack.3d.up", title: "本地存储条目",
                            subtitle: "剪贴板库中的条目总数") {
                    Text("\(storedItems)")
                        .font(.system(size: 13, weight: .medium))
                        .monospacedDigit()
                }
                SettingsDivider()
                SettingsRow(icon: "arrow.clockwise", title: "刷新统计",
                            subtitle: "重新读取统计库与剪贴板库（含上方图表）") {
                    Button("刷新") {
                        refresh()
                        chartsEpoch += 1
                    }
                    .controlSize(.small)
                    .disabled(isBusy)
                }
            }
        }
    }

    // MARK: 功能明细（v107：各大功能累计，含活动监测）

    /// 大功能计数表（icon / 标题 / 事件键 / 说明）
    private static let featureMetrics: [(icon: String, title: String, event: String, note: String)] = [
        ("doc.on.doc", "历史复制", AnalyticsEvent.historyCopy.eventName, "从历史列表复制"),
        ("doc.on.clipboard.fill", "剪贴板粘贴", AnalyticsEvent.clipboardPaste.eventName, "粘贴回目标应用"),
        ("magnifyingglass", "搜索执行", AnalyticsEvent.searchExecute.eventName, "面板搜索"),
        ("safari", "网页搜索", AnalyticsEvent.webSearchOpen.eventName, "搜索引擎跳转"),
        ("sparkles", "AI 请求", "ai_request_count", "AI 对话/摘要"),
        ("character.bubble", "翻译", AnalyticsEvent.translationUse.eventName, "划词翻译"),
        ("text.viewfinder", "OCR 识别", AnalyticsEvent.ocrUse.eventName, "图片文字提取"),
        ("camera.on.rectangle", "长截图", AnalyticsEvent.longScreenshot.eventName, "滚动长截图"),
        ("pin", "贴图", AnalyticsEvent.pinImage.eventName, "图片置顶贴到桌面"),
        ("pencil.tip.crop.circle", "标注编辑", AnalyticsEvent.annotateEdit.eventName, "截图标注保存"),
        ("record.circle", "屏幕录制", AnalyticsEvent.screenRecord.eventName, "录屏"),
        ("arrow.down.circle", "网盘下载", AnalyticsEvent.fileDownload.eventName, "网盘解析下载"),
        ("paperplane", "文件发送", AnalyticsEvent.fileTransferSend.eventName, "传输与投屏·发送"),
        ("tray.and.arrow.down", "文件接收", AnalyticsEvent.fileTransferReceive.eventName, "传输与投屏·接收"),
        ("macwindow", "悬浮剪贴板", AnalyticsEvent.floatingClipboardActivate.eventName, "悬浮窗激活"),
        ("rectangle.3.group", "面板打开", AnalyticsEvent.panelOpen.eventName, "主面板唤起"),
        ("gauge", "监测中心", AnalyticsEvent.monitorPanelOpen.eventName, "性能监测页打开"),
        ("waveform.path.ecg", "活动监测", AnalyticsEvent.activityMonitorClick.eventName, "活动监测入口"),
        ("gearshape", "设置打开", AnalyticsEvent.settingsOpen.eventName, "设置窗口"),
    ]

    private var featureSection: some View {
        SettingsSection(title: "功能明细") {
            SettingsGroupBox {
                ForEach(Array(Self.featureMetrics.enumerated()), id: \.offset) { idx, m in
                    if idx > 0 { SettingsDivider() }
                    SettingsRow(icon: m.icon, title: m.title, subtitle: "\(m.note)（\(m.event)）") {
                        Text("\(featureCounts[m.event] ?? 0)")
                            .font(.system(size: 13, weight: .medium))
                            .monospacedDigit()
                    }
                }
            }
        }
    }

    // MARK: 评分请求口径（Q7 reviewRequestUsage 出口）

    private var reviewSection: some View {
        SettingsSection(title: "评分") {
            SettingsGroupBox {
                SettingsRow(icon: "star", title: "评分请求口径",
                            subtitle: "history_copy + screenshot_capture 累计次数，原作据此决定何时请求评分") {
                    Text("\(reviewUsage)")
                        .font(.system(size: 13, weight: .medium))
                        .monospacedDigit()
                }
            }
        }
    }

    // MARK: 导出 / 导入（Q8 exportAll / importMerge 出口）

    private var transferSection: some View {
        SettingsSection(title: "配置导出与导入") {
            SettingsGroupBox {
                SettingsRow(icon: "square.and.arrow.up", title: "导出配置",
                            subtitle: "将偏好设置与统计数据写入 .frsetconfig 文件") {
                    Button("导出…") { performExport() }
                        .controlSize(.small)
                        .disabled(isBusy)
                }
                SettingsDivider()
                SettingsRow(icon: "square.and.arrow.down", title: "导入配置",
                            subtitle: "从 .frsetconfig 恢复偏好设置，统计数据按较大值合并") {
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
        SettingsSection(title: "说明") {
            SettingsGroupBox {
                SettingsRow(icon: "info.circle", title: "导出内容",
                            subtitle: "仅包含偏好设置与统计数据，不含剪贴板历史、标签与 AI 凭证") {}
                SettingsDivider()
                SettingsRow(icon: "arrow.triangle.merge", title: "合并规则",
                            subtitle: "统计数据按 MAX(已有, 导入, 0) 合并，导入不会削减本机计数") {}
            }
        }
    }

    // MARK: 数据装载

    private func refresh() {
        let mgr = StatisticsManager.shared
        let events = Array(mgr.trackedEventNames)
        DispatchQueue.global(qos: .userInitiated).async {
            let review = mgr.reviewRequestUsage()                       // Q7
            let capture = mgr.total(event: AnalyticsEvent.clipboardCapture.eventName)          // Q6
            // v84：截图总数合并截图族全部事件（截图 / 长截图 / 贴图 / 标注）
            let screenshot = [AnalyticsEvent.screenshotCapture,
                              .longScreenshot, .pinImage, .annotateEdit]
                .reduce(0) { $0 + mgr.total(event: $1.eventName) }                             // Q6
            let tool = mgr.total(event: AnalyticsEvent.toolExecuteSuccess.eventName)          // Q6
            let days = mgr.activeDaysCount(events: events)                                    // Q3
            let stored = Int((try? DatabaseManager.shared.clipboard.scalarInt(
                "SELECT COUNT(*) FROM clipboard_items")) ?? 0)
            // v107：各大功能累计
            var feats: [String: Int] = [:]
            for m in Self.featureMetrics {
                feats[m.event] = mgr.total(event: m.event)
            }
            DispatchQueue.main.async {
                self.reviewUsage = review
                self.clipboardCaptureTotal = capture
                self.screenshotTotal = screenshot
                self.toolTotal = tool
                self.activeDays = days
                self.storedItems = stored
                self.featureCounts = feats
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

        isBusy = true
        // exportAll() 走 StatisticsManager 串行队列（同步查询），放后台避免卡 UI
        DispatchQueue.global(qos: .userInitiated).async {
            let rows = StatisticsManager.shared.exportAll()          // Q8
            let file = FrsetConfigFile(
                format: FrsetConfigFile.formatIdentifier,
                version: FrsetConfigFile.currentVersion,
                exportedAt: Self.iso8601Now(),
                preferences: Self.exportablePreferences(),
                statistics: rows.map { .init(day: $0.0, event: $0.1, count: $0.2) }
            )
            do {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
                try encoder.encode(file).write(to: url, options: .atomic)
                StatisticsManager.shared.record(AnalyticsEvent.settingsExportSuccess)
                DispatchQueue.main.async {
                    self.isBusy = false
                    self.lastActionFailed = false
                    self.lastActionResult = "已导出 \(rows.count) 条统计数据与 \(file.preferences.count) 项偏好到 \(url.lastPathComponent)"
                    Toast.show("导出成功", icon: "checkmark.circle.fill")
                }
            } catch {
                Log.error("Settings", "导出配置失败: \(error.localizedDescription)")
                DispatchQueue.main.async {
                    self.isBusy = false
                    self.lastActionFailed = true
                    self.lastActionResult = "写入失败：\(error.localizedDescription)"
                    Toast.show("导出失败", icon: "exclamationmark.triangle.fill", isWarning: true)
                }
            }
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
        pendingImportURL = url
    }

    private func performImport(_ url: URL?) {
        pendingImportURL = nil
        guard let url else { return }

        isBusy = true
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let data = try Data(contentsOf: url)
                let file = try JSONDecoder().decode(FrsetConfigFile.self, from: data)
                guard file.format == FrsetConfigFile.formatIdentifier else {
                    throw ConfigImportError.badFormat
                }
                guard file.version <= FrsetConfigFile.currentVersion else {
                    throw ConfigImportError.unsupportedVersion(file.version)
                }
                let invalid = Self.applyPreferences(file.preferences)
                // 统计数据走 MAX 合并事务（不覆盖较新数据）
                StatisticsManager.shared.importMerge(
                    file.statistics.map { ($0.day, $0.event, $0.count) })   // Q8
                StatisticsManager.shared.record(AnalyticsEvent.settingsImportSuccess)
                Log.info("Settings", "导入配置完成：偏好 \(file.preferences.count) 项 / 统计 \(file.statistics.count) 条")
                DispatchQueue.main.async {
                    // v126（性能审计 F1190）：搜索设置重载回主线程——SearchServiceManager 是
                    // ObservableObject，load() 会写 @Published；原来在后台队列调用会触发
                    // SwiftUI「后台线程发布变更」未定义行为。放在状态刷新之前，页面仍能立即反映导入结果。
                    SearchServiceManager.shared.reloadFromDefaults()
                    self.isBusy = false
                    self.lastActionFailed = !invalid.isEmpty
                    self.lastActionResult = invalid.isEmpty
                        ? "已导入 \(file.preferences.count) 项偏好，\(file.statistics.count) 条统计数据按较大值合并"
                        : "已导入，但有 \(invalid.count) 个键被忽略（不属于可导入的偏好键）"
                    self.refresh()
                    Toast.show("导入成功", icon: "checkmark.circle.fill")
                }
            } catch {
                Log.error("Settings", "导入配置失败: \(error.localizedDescription)")
                DispatchQueue.main.async {
                    self.isBusy = false
                    self.lastActionFailed = true
                    self.lastActionResult = "导入失败：\(error.localizedDescription)"
                    Toast.show("导入失败", icon: "exclamationmark.triangle.fill", isWarning: true)
                }
            }
        }
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
    static let exportablePreferenceKeys: [String] = [
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
        "clipboard.autoPaste",                    // ClipboardManager.swift 的 Keys 扩展
        // 悬浮剪贴板窗
        Preferences.Keys.floatingOriginX,
        Preferences.Keys.floatingOriginY,
        Preferences.Keys.floatingWidth,
        Preferences.Keys.floatingHeight,
        "floatingClipboard.visible",
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
        // AI（不含凭证：凭证在 CredentialStore 加密文件里）
        Preferences.Keys.aiProvider,
        Preferences.Keys.aiModel,
        Preferences.Keys.aiBaseURL,
        // 工具箱
        Preferences.Keys.toolboxEnabled,
        Preferences.Keys.calendarShowLunar,
        // 搜索（SearchServiceManager.Keys，为私有枚举，按字面量写）
        "clearSearchInputAfterWebAction",
        "customEngines",
        "engineOrder",
        "activeBarItems",
        // 埋点开关（D5：analyticsEnabled）
        "analyticsEnabled",
    ]

    /// 导出时读取白名单内的偏好键值（未落盘的键不写入）
    static func exportablePreferences() -> [String: PreferenceValue] {
        let defaults = UserDefaults.standard
        var out: [String: PreferenceValue] = [:]
        out.reserveCapacity(exportablePreferenceKeys.count)
        for key in exportablePreferenceKeys {
            guard let raw = defaults.object(forKey: key),
                  let value = PreferenceValue(defaultsValue: raw) else { continue }
            out[key] = value
        }
        return out
    }

    // v126（性能审计 F1190）：白名单集合缓存——applyPreferences 原来每次导入都从
    // 40+ 项数组重建一个 Set（逐项哈希），提为 static 常量后只建一次。
    private static let exportablePreferenceKeySet: Set<String> = Set(exportablePreferenceKeys)

    /// 写回导入的偏好键值
    /// - Returns: 被忽略（不在白名单内）的键名；按原作 `settings.invalid-` 前缀落标记
    @discardableResult
    static func applyPreferences(_ incoming: [String: PreferenceValue]) -> [String] {
        let whitelist = exportablePreferenceKeySet
        let defaults = UserDefaults.standard
        var ignored: [String] = []
        for (key, value) in incoming {
            if whitelist.contains(key) {
                defaults.set(value.defaultsValue, forKey: key)
            } else {
                ignored.append(key)
                // 原作无效键标记前缀（spec 18 F8 / SettingsStore @0x100b50070）
                defaults.set(true, forKey: "settings.invalid-\(key)")
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
