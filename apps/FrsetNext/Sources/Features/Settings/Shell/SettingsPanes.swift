import AppKit
import Combine
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

// MARK: - 设置模块自带的基础页签（通用 / 快捷键 / 关于）
// 其他模块（监测/剪贴板/搜索/AI/工具）的页签由各自模块注册，此处不引用。

// MARK: - 通用页

final class StartupSettingsDraft: SettingsEditableDraft {
    @Published var launchAtLogin = Preferences.shared.launchAtLogin
    @Published var language = LanguageManager.shared.overrideDisplayLanguage
    private var savedLaunchAtLogin = Preferences.shared.launchAtLogin
    private var savedLanguage = LanguageManager.shared.overrideDisplayLanguage
    var isDirty: Bool { launchAtLogin != savedLaunchAtLogin || language != savedLanguage }
    func save() -> String? {
        if launchAtLogin != savedLaunchAtLogin {
            do {
                if launchAtLogin { try SMAppService.mainApp.register() }
                else { try SMAppService.mainApp.unregister() }
            } catch { return "开机启动未应用：\(error.localizedDescription)" }
            Preferences.shared.launchAtLogin = launchAtLogin
        }
        if language != savedLanguage {
            LanguageManager.shared.apply(language)
            language = LanguageManager.shared.overrideDisplayLanguage
        }
        guard UserDefaults.standard.synchronize() else { return "启动与语言设置写入磁盘失败，调整已保留" }
        savedLaunchAtLogin = launchAtLogin; savedLanguage = language
        objectWillChange.send()
        return nil
    }
    func discard() {
        launchAtLogin = Preferences.shared.launchAtLogin
        language = LanguageManager.shared.overrideDisplayLanguage
        savedLaunchAtLogin = launchAtLogin
        savedLanguage = language
    }
    func restoreDefaults() { discard(); launchAtLogin = false; language = "auto" }
}

final class AboutSettingsDraft: SettingsEditableDraft {
    @Published var feedURL = AppUpdateChecker.shared.feedURL
    private var savedFeedURL = AppUpdateChecker.shared.feedURL
    var isDirty: Bool { feedURL != savedFeedURL }
    func save() -> String? {
        if isDirty { AppUpdateChecker.shared.feedURL = feedURL }
        guard UserDefaults.standard.synchronize() else { return "更新设置写入磁盘失败，调整已保留" }
        savedFeedURL = feedURL
        objectWillChange.send()
        return nil
    }
    func discard() { feedURL = AppUpdateChecker.shared.feedURL; savedFeedURL = feedURL }
    func restoreDefaults() { discard(); feedURL = "" }
}

final class MenuBarSettingsDraft: SettingsEditableDraft {
    @Published var iconStyle = MenuBarIconStyleStore.current
    @Published var customSymbol = MenuBarIconStyleStore.customSymbol
    var cat: Bool { iconStyle == .cat }
    @Published var flags: [String: Bool]
    private var saved: [String: Any]
    private static let keys = [GlobalEntries.homeKey, GlobalEntries.monitorPopoutKey, GlobalEntries.statsBarKey]

    init() {
        flags = Dictionary(uniqueKeysWithValues: Self.keys.map { ($0, GlobalEntries.isEnabled($0)) })
        saved = [:]
        saved = values
    }

    private var values: [String: Any] {
        var result: [String: Any] = flags
        result["style"] = iconStyle.rawValue
        result["symbol"] = customSymbol
        result["cat"] = cat
        return result
    }
    var isDirty: Bool { !NSDictionary(dictionary: values).isEqual(to: saved) }
    func select(_ style: MenuBarIconStyle) { iconStyle = style }
    func restoreDefaults() {
        discard()
        iconStyle = .logo
        customSymbol = MenuBarIconStyleStore.defaultCustomSymbol
        flags = Dictionary(uniqueKeysWithValues: Self.keys.map { ($0, true) })
    }
    func discard() {
        iconStyle = MenuBarIconStyleStore.current
        customSymbol = MenuBarIconStyleStore.customSymbol
        flags = Dictionary(uniqueKeysWithValues: Self.keys.map { ($0, GlobalEntries.isEnabled($0)) })
        saved = values
    }
    func save() -> String? {
        let symbol = customSymbol.trimmingCharacters(in: .whitespacesAndNewlines)
        if iconStyle == .custom && NSImage(systemSymbolName: symbol, accessibilityDescription: nil) == nil {
            return "自定义 SF Symbol 不存在：" + symbol
        }
        if cat != saved["cat"] as? Bool {
            if let reason = FSBarSaveConfiguration(["Bar_MainIconCat": cat], []) { return reason }
        }
        if iconStyle.rawValue != saved["style"] as? String { MenuBarIconStyleStore.select(iconStyle) }
        if customSymbol != saved["symbol"] as? String {
            UserDefaults.standard.set(symbol, forKey: MenuBarIconStyleStore.customSymbolKey)
            customSymbol = symbol
        }
        if iconStyle == .custom { MenuBarIconStyleStore.setRevealsCustomOption(true) }
        for key in Self.keys where flags[key] != saved[key] as? Bool {
            Preferences.shared.set(key, flags[key]!)
        }
        guard UserDefaults.standard.synchronize() else { return "菜单栏设置写入磁盘失败，调整已保留" }
        NotificationCenter.default.post(name: GlobalEntries.didChangeNotification, object: nil)
        MenuBarIconStyleApplier.shared.refresh()
        FSRunCatIconApplySavedConfiguration()
        saved = values
        return nil
    }
}

struct GeneralSettingsPane: View {
    // 数据页清理偏好时使用的既有名称；键定义仍归图标存储。
    static let menuBarIconStyleLogoKey = MenuBarIconStyle.logo.preferenceKey
    static let menuBarIconStyleFanKey = MenuBarIconStyle.fan.preferenceKey
    static let menuBarIconStyleDateKey = MenuBarIconStyle.date.preferenceKey
    static let menuBarIconStyleCustomKey = MenuBarIconStyle.custom.preferenceKey
    static let menuBarIconCustomSymbolKey = MenuBarIconStyleStore.customSymbolKey
    /// v272（用户：「常规也需要拆分，个性化这些设置全都要拆」）：常规拆成五个二级页，
    /// 一个二级页只渲染自己那一段，侧边栏一项对一页，不再一页滚到底。
    enum Section: Hashable {
        case startup          // 启动与外观
        case mainPanel        // 主面板
        case floating         // 独立窗口与浮层
        case personalization  // 个性化（通用）
        case appearanceText
        case background
        case permissions
        case menuBar          // 菜单栏
        case menuBarArrangement
        case notifications
        case captureToolbar
    }
    var section: Section = .startup
    /// v40 面板内嵌模式（主面板「主页 → 常规」）：左侧标题列收窄、宽行改分行布局——
    /// 面板内容区约 576pt，原 800pt 窗口版式（190pt 标题列 + 4 图标横排）放不下。
    var compact: Bool = false

    @ObservedObject private var permissions = PermissionCenter.shared
    /// 语言版本号：languageDidChange 到达时自增，驱动本视图重绘（契约 §10.3；
    /// 用 @Stored 而非 @State，见 CONTRACT §7.4）
    @Stored private var l10nVersion: Int = 0

    var body: some View {
        // v71（用户：各设置界面版式不一致，需统一组件）：统一 SettingsSection + SettingsGroupBox。
        // 外层滚动由 SettingsRootView.panePage 提供；v272 起按二级页只渲染一段。
        VStack(spacing: 20) {
            switch section {
            case .startup:         startupSection
            case .mainPanel:       mainPanelSection
            case .floating:        floatingSection
            case .personalization: personalizationSection
            case .appearanceText: appearanceSection(.textAndRadius)
            case .background: appearanceSection(.panelBackground)
            case .permissions: permissionsSection
            case .menuBar:         menuBarSection
            case .menuBarArrangement: MenuBarArrangementPane()
            case .notifications:
                AppearanceSettingsEditor(scope: .notification) { draft in
                    SettingsGroupBox {
                        SettingsPreviewColumns {
                            AppearancePreviewBlock(scope: .notification, draft: draft)
                        } controls: {
                            PersonalizationSettingsView(part: .notification, draft: draft, compact: true)
                        }
                    }
                }
            case .captureToolbar:
                AppearanceSettingsEditor(scope: .captureToolbar) { draft in
                    SettingsGroupBox {
                        SettingsPreviewColumns {
                            AppearancePreviewBlock(scope: .captureToolbar, draft: draft)
                        } controls: {
                            PersonalizationSettingsView(part: .captureToolbar, draft: draft, compact: true)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .font(.system(size: 12))
        .onReceive(NotificationCenter.default.publisher(for: LanguageManager.languageDidChange)) { _ in
            l10nVersion &+= 1
        }
    }

    // MARK: - 二级页内容

    /// 启动与外观：登录启动 / 外观四选一 / 语言
    private var startupSection: some View {
        SettingsDraftEditor(id: "startup", makeDraft: { StartupSettingsDraft() }) { draft in
            SettingsGroupBox {
                formRow(L10n.t("Start"), height: 40) {
                    Toggle(L10n.t("Launch Kitnest at login"), isOn: Binding(
                        get: { draft.launchAtLogin }, set: { draft.launchAtLogin = $0 }))
                        .toggleStyle(.checkbox)
                }
                SettingsDivider()
                formRow(L10n.t("Language"), height: 48) {
                    Picker("", selection: Binding(get: { draft.language }, set: { draft.language = $0 })) {
                        Text(L10n.t("Auto")).tag("auto")
                        ForEach(LanguageManager.availableLanguages, id: \.self) { code in
                            Text(LanguageManager.displayNames[code] ?? code).tag(code)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 157)
                }
            }
        }
    }

    private func appearanceSection(_ part: PersonalizationSettingsPart) -> some View {
        AppearanceSettingsEditor(scope: part) { draft in
            SettingsGroupBox {
                SettingsPreviewColumns {
                    AppearancePreviewBlock(scope: .mainPanel, draft: draft)
                } controls: {
                    PersonalizationSettingsView(part: part, draft: draft, compact: true)
                }
            }
        }
    }

    private var permissionsSection: some View {
        VStack(spacing: 12) {
            SettingsGroupBox {
                ForEach(PermissionKind.allCases) { kind in
                    SettingsRow(icon: kind.symbol, title: kind.title, subtitle: kind.purpose) {
                        Text(permissions.status(kind).label).foregroundStyle(permissions.status(kind).tint)
                        Button("授权") { permissions.request(kind) }.controlSize(.small)
                        Button("系统设置") { permissions.openSystemSettings(kind) }.controlSize(.small)
                    }
                }
            }
            SettingsGroupBox { ArchiveDefaultApplicationOption() }
        }
        .onAppear { permissions.refreshAll() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            permissions.refreshAll()
        }
    }

    /// 主面板：预览 + 只作用于主面板的字号/圆角/宽度/材质/页面顺序
    private var mainPanelSection: some View {
        AppearanceSettingsEditor(scope: .mainPanel) { draft in
            SettingsSection("") {
                SettingsGroupBox {
                    SettingsPreviewColumns {
                        AppearancePreviewBlock(scope: .mainPanel, draft: draft)
                    } controls: {
                        PersonalizationSettingsView(part: .mainPanel, draft: draft, compact: true)
                    }
                }
            }
        }
    }

    /// 独立窗口与浮层：预览 + 玻璃四参数/密度/缩略图/徽章/通知条
    private var floatingSection: some View {
        AppearanceSettingsEditor(scope: .floatingWindow) { draft in
            SettingsSection("") {
                SettingsGroupBox {
                    SettingsPreviewColumns {
                        AppearancePreviewBlock(scope: .floatingWindow, draft: draft)
                    } controls: {
                        PersonalizationSettingsView(part: .floatingWindow, draft: draft, compact: true)
                    }
                }
            }
        }
    }

    /// 个性化（通用）：两边都生效的强调色/动画/动作条/背景图/入口
    private var personalizationSection: some View {
        AppearanceSettingsEditor(scope: .shared) { draft in
            SettingsSection("") {
                SettingsGroupBox {
                    SettingsPreviewColumns {
                        AppearancePreviewBlock(scope: .mainPanel, draft: draft)
                    } controls: {
                        VStack(alignment: .leading, spacing: 10) {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(L10n.t("Appearance"))
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                                appearanceChoices(draft)
                            }
                            SettingsDivider()
                            PersonalizationSettingsView(part: .shared, draft: draft, compact: true)
                        }
                    }
                }
            }
        }
    }

    /// 外观四选一（系统/浅色/深色/Midnight）
    /// v234：从「四个圆点」换成预览卡片——和钉图预设共用 VisualOptionCard，
    /// 用户不用试就知道深色/Midnight 长什么样。
    private func appearanceChoices(_ draft: AppearanceSettingsDraft) -> some View {
        Picker("", selection: Binding(get: { draft.appearance }, set: { draft.appearance = $0 })) {
            ForEach(AppearanceMode.allCases) { mode in
                Text(appearanceTitle(mode)).tag(mode)
            }
        }
        // 两栏的右列只有 270pt，四段控件至少 315pt 会顶出卡片；
        // 这里用菜单，四项都点得到，也不会越界。
        .pickerStyle(.menu)
        .labelsHidden()
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private var menuBarSection: some View {
        VStack(spacing: 12) {
            SettingsDraftEditor(id: "menuBar", makeDraft: { MenuBarSettingsDraft() }) { draft in
                SettingsGroupBox {
                    HStack(spacing: 12) {
                        ForEach([false, true], id: \.self) { dark in
                            VStack(spacing: 4) {
                                MenuBarIconPreview(style: draft.iconStyle, customSymbol: draft.customSymbol, dark: dark)
                                    .frame(width: 56, height: 30)
                                    .background(dark ? Color(.sRGB, white: 0.12, opacity: 1) : Color(.sRGB, white: 0.94, opacity: 1))
                                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.chip))
                                    .allowsHitTesting(false)
                                    .accessibilityLabel(dark ? "深色背景图标预览" : "浅色背景图标预览")
                                Text(dark ? "深色背景" : "浅色背景").font(.system(size: 11)).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                    }
                    SettingsDivider()
                    formRow("图标样式") {
                        Picker("图标样式", selection: Binding(get: { draft.iconStyle }, set: { draft.select($0) })) {
                            ForEach(MenuBarIconStyle.allCases, id: \.self) { style in
                                Text(style.title).tag(style)
                            }
                        }.labelsHidden().pickerStyle(.segmented).frame(maxWidth: 430)
                    }
                    if draft.iconStyle == .custom {
                        formRow("自定义 SF Symbol") {
                            TextField("例如 sparkles", text: Binding(get: { draft.customSymbol }, set: { draft.customSymbol = $0 }))
                                .textFieldStyle(.roundedBorder).frame(width: 200)
                        }
                    }
                    SettingsDivider()
                    entryRow("菜单：打开面板", key: GlobalEntries.homeKey, draft: draft)
                    entryRow("菜单：性能监测设置", key: GlobalEntries.monitorPopoutKey, draft: draft)
                    entryRow("菜单栏：性能部件", key: GlobalEntries.statsBarKey, draft: draft)
                    // v282（用户：「这种前端上的说明性小词全部去掉，只留最基本的介绍」；
                    // 「状态栏的部件……应该放在性能监测那部分，而不是放在这个入口」）：
                    // 这里原来还有一段「图标与入口在本页保存……分别在对应页面保存」的
                    // 解释文字，以及一行「前往部件设置」的跳转。部件设置现在就在
                    // 「性能监测 › 菜单栏部件」里，入口页不该再挂第四个与部件相关的入口。
                    // 解释文字同样删掉——侧栏已经说明了层级，界面里再讲一遍就是噪音。
                }
            }
        }
    }

    private func entryRow(_ title: String, key: String, draft: MenuBarSettingsDraft, detail: String? = nil) -> some View {
        SettingsRow(title: title, subtitle: detail) {
            Toggle(title, isOn: Binding(get: { draft.flags[key]! }, set: { draft.flags[key] = $0 }))
                .labelsHidden().toggleStyle(.switch).controlSize(.small)
        }
    }


    /// v272（用户：「所有页面一个一个统一」）：行样式统一成 SettingsRow 的
    /// 「左标题 + 右控件」。此前这里是「右对齐 190pt 标题列」，与剪贴板/数据页的
    /// 左标题行同窗并存，两种版式一眼可见。
    private func formRow<Content: View>(_ title: String, height: CGFloat = 40,
                                      @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: compact ? 10 : 14) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
                .fixedSize()
            Spacer(minLength: compact ? 8 : 16)
            content()
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .frame(minHeight: height)
    }



    // MARK: 外观四选一 radio（specs/18 §5：系统/浅色/深色/Midnight，键 appearance）

    /// 外观档位的本地化标题。
    /// AppearanceManager.swift 属他人领地不可改，故在此消费点按原始值映射到原作 L10n 键面
    /// （"Auto"=跟随系统 / "System"=系统 / "Light"=浅色 / "Dark"=深色 / "Midnight"）。
    private func appearanceTitle(_ mode: AppearanceMode) -> String {
        switch mode {
        case .system:   return L10n.t("System")
        case .light:    return L10n.t("Light")
        case .dark:     return L10n.t("Dark")
        case .midnight: return L10n.t("Midnight")
        }
    }

}

// MARK: - 关于页
//
// 对齐原版截图（original-settings-tabs/关于.png，1600×1124 = 800×562pt @2x）：
//   居中布局：App 图标(≈64pt) → "Kitnest"(≈20pt semibold) → "v1.3.12 · 更新日志"(12pt) →
//   双蓝按钮「给我们评分」「帮助与反馈」→「隐私政策 · 使用条款」(12pt) →
//   "Copyright © 2026, All rights reserved."(11pt tertiary)
// 文案全部走 L10n.t() 原版键面（Rate us / Help & Feedback / Privacy Policy /
// Terms of Service / Changelog），语言切换随 languageDidChange 重绘（同通用页机制）。
// 显示名固定 "Kitnest"、版本行固定 "v1.3.12" —— 像素级 1:1 验收要求与原版一致；
// Bundle 真实版本（1.0.0）不参与此页显示，避免双开 diff 出现可见差异。

struct AboutSettingsPane: View {
    /// 语言版本号：languageDidChange 到达时自增，驱动本视图重绘（同 GeneralSettingsPane 机制）
    @Stored private var l10nVersion: Int = 0

    var body: some View {
        SettingsDraftEditor(id: "about", makeDraft: { AboutSettingsDraft() }) { draft in
            aboutContent(draft)
        }
    }

    private func aboutContent(_ draft: AboutSettingsDraft) -> some View {
        VStack(spacing: 0) {
            Spacer(minLength: 24)

            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 64, height: 64)
                .cornerRadius(14.5)

            Text("Kitnest")
                .font(.system(size: 21, weight: .semibold))
                .padding(.top, 18)

            // v90（2026-10-20 用户要求）：外链全部移除，版本号回退 1.0.0
            Text("v\(Self.displayVersion)")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .padding(.top, 6)

            Spacer(minLength: 24)

            // v260（关于页重做）：原来两个按钮直接上下堆在 spacing: 0 的 VStack 里，
            // 视觉上贴成一块（用户截图里看着像重叠）；更新源那一行又写死 320 宽，
            // 内容区稍窄就溢出到窗口外。改成：按钮并排 + 更新源收进自适应宽度的卡片。
            HStack(spacing: 10) {
                aboutButton("导出使用记录") { DiagnosticsExporter.export() }
                aboutButton("检查更新") { AppUpdateChecker.shared.checkNowManual() }
            }
            .padding(.bottom, 18)

            // v201 在线更新：默认源内置，留空 = 回到默认（calorieai.sxyq27.online/kitnest/）。
            // 内部按 CFBundleVersion 的 build 号比较，与显示版本 1.0.0 无关。
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text("更新源")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    TextField(AppUpdateChecker.defaultFeedURL,
                              text: Binding(
                                get: { draft.feedURL },
                                set: { draft.feedURL = $0 }))
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.small)
                        .frame(maxWidth: 300)
                        .font(.system(size: 11, design: .monospaced))
                    Spacer(minLength: 0)
                }
                Text("当前 build \(AppUpdateChecker.shared.currentBuild) · 启动与每 6 小时自动检查 · 留空恢复默认源")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.tertiaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .frame(maxWidth: 460)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                    .fill(Theme.cardFill)
            )

            Spacer(minLength: 24)

            Text("Copyright © 2026, All rights reserved.")
                .font(.system(size: 11))
                .foregroundStyle(Theme.tertiaryText)
                .padding(.top, 10)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .onReceive(NotificationCenter.default.publisher(for: LanguageManager.languageDidChange)) { _ in
            l10nVersion &+= 1
        }
    }

    /// 版本号（v90 用户要求回退 1.0.0；原对齐原版截图的 1.3.12 不再使用）
    static let displayVersion = "1.0.0"

    /// 外链目标（原版分别走 App Store 评分 / 帮助站 / 隐私与条款页；
    /// 重建无 App Store 与独立站点，统一降级为 GitHub 占位链接 —— 有意差异，记录在 specs/07）
    static let rateURL = URL(string: "https://github.com/frset/frset-next")
    static let feedbackURL = URL(string: "https://github.com/frset/frset-next/issues")
    static let changelogURL = URL(string: "https://github.com/frset/frset-next/releases")
    static let privacyURL = URL(string: "https://github.com/frset/frset-next")
    static let termsURL = URL(string: "https://github.com/frset/frset-next")

    private func aboutButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 112, height: 32)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.regular)
    }
}

// MARK: - 标签管理 sheet（原版「标签管理 [编辑]」入口）
//
// 原版标签管理界面未采到参考图（§8.3 未覆盖类），此处按原版键面搭建最小可用 UI：
// 列表 + 新建 + 删除，全部复用现有 TagStore；详细布局留待补采后对齐。

struct TagManagementSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = TagStore.shared
    @Stored private var l10nVersion: Int = 0
    // @Stored 替代 @State：本机工具链缺 SwiftUIMacros 插件（见 Core/Runtime/StateCompat.swift）
    @Stored private var newTagName = ""
    @Stored private var isAdding = false
    @Stored private var editingTagID: String?
    @Stored private var editingTagName = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(L10n.t("Tag Management")).font(.headline)
                Spacer()
                Button(L10n.t("Done")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(20)
            Divider()
            List {
                ForEach(store.tags, id: \.id) { tag in
                    HStack(spacing: 10) {
                        Circle()
                            .fill(Color(hex: tag.colorHex) ?? .gray)
                            .frame(width: 10, height: 10)
                        if editingTagID == tag.id {
                            TextField("标签名称", text: $editingTagName)
                                .textFieldStyle(.roundedBorder)
                                .onSubmit { saveRename(id: tag.id) }
                            Button("保存") { saveRename(id: tag.id) }
                                .controlSize(.small)
                        } else {
                            Text(tag.name)
                        }
                        Spacer()
                        if editingTagID != tag.id {
                            Button {
                                editingTagID = tag.id
                                editingTagName = tag.name
                            } label: {
                                Image(systemName: "pencil")
                            }
                            .buttonStyle(.plain)
                            .help("重命名标签")
                        }
                        Button {
                            store.delete(id: tag.id)
                        } label: {
                            Image(systemName: "trash")
                                .foregroundStyle(.red)
                        }
                        .buttonStyle(.plain)
                    }
                }
                if store.tags.isEmpty && !isAdding {
                    Text(L10n.t("No tags yet"))
                        .foregroundStyle(.secondary)
                }
                if isAdding {
                    HStack(spacing: 10) {
                        TextField(L10n.t("New Tag"), text: $newTagName)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 200)
                            .onSubmit(createTag)
                        Button(L10n.t("Add Tag")) { createTag() }
                            .controlSize(.small)
                            .disabled(newTagName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
            .listStyle(.inset)
            Divider()
            HStack {
                Spacer()
                Button {
                    isAdding = true
                } label: {
                    Label(L10n.t("Add Tag"), systemImage: "plus")
                }
                .controlSize(.small)
            }
            .padding(16)
        }
        .frame(width: 480, height: 360)
        .onReceive(NotificationCenter.default.publisher(for: LanguageManager.languageDidChange)) { _ in
            l10nVersion &+= 1
        }
    }

    private func createTag() {
        let name = newTagName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        store.create(name: name)
        newTagName = ""
        isAdding = false
    }

    private func saveRename(id: String) {
        guard store.rename(id: id, name: editingTagName) else {
            Toast.show("标签名称无效或已存在", icon: "exclamationmark.triangle", isWarning: true)
            return
        }
        editingTagID = nil
        editingTagName = ""
    }
}


// MARK: - 忽略应用（隐私名单）编辑器（原版缺失功能 §3-2）

/// 名单内的来源 App 不写入剪贴板历史；名单存 Preferences（bundle id 数组）。
/// UI 沿用设置页风格：formRow 行 + 12pt 字号 + 细边框胶囊按钮。
struct IgnoredAppsEditor: View {
    @Binding var apps: [String]
    @Stored private var expanded = false

    init(apps: Binding<[String]>) { _apps = apps }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Button {
                    expanded.toggle()
                } label: {
                    Text(expanded ? "收起（\(apps.count)）" : "管理（\(apps.count)）")
                        .font(.system(size: 11.5, weight: .medium))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .overlay {
                            RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous)
                                .strokeBorder(Theme.cardStroke, lineWidth: Theme.Stroke.hairline)
                        }
                }
                .buttonStyle(.plain)

                Button {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = false
                    panel.allowsMultipleSelection = true
                    panel.allowedContentTypes = [.application]
                    panel.directoryURL = URL(fileURLWithPath: "/Applications")
                    panel.prompt = "添加"
                    guard panel.runModal() == .OK else { return }
                    var list = apps
                    for url in panel.urls {
                        guard let bundle = Bundle(url: url)?.bundleIdentifier else { continue }
                        if !list.contains(bundle) { list.append(bundle) }
                    }
                    apps = list
                } label: {
                    Text("+ 添加应用…")
                        .font(.system(size: 11.5, weight: .medium))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .overlay {
                            RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous)
                                .strokeBorder(Theme.cardStroke, lineWidth: Theme.Stroke.hairline)
                        }
                }
                .buttonStyle(.plain)
                .help("选择不采集剪贴板内容的应用")
            }

            if expanded {
                if apps.isEmpty {
                    Text("名单为空——所有应用的复制内容都会被采集")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(apps, id: \.self) { bundle in
                        HStack {
                            Text(bundle)
                                .font(.system(size: 11.5).monospaced())
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer(minLength: 8)
                            Button {
                                apps.removeAll { $0 == bundle }
                            } label: {
                                Image(systemName: "minus.circle")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .help("从名单移除")
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
        }
    }
}


